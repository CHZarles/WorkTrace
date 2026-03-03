use axum::{
    extract::{Path, Query, State},
    http::{HeaderValue, Method, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use clap::Parser;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    net::{IpAddr, SocketAddr},
    path::PathBuf,
    sync::Arc,
};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};
use tokio::sync::Mutex;
use tower_http::cors::CorsLayer;
use tracing::{error, info};

const DEFAULT_PORT: u16 = 17600;
const TZ_OFFSET_MINUTES_MIN: i32 = -14 * 60;
const TZ_OFFSET_MINUTES_MAX: i32 = 14 * 60;
// How long a tab/domain attribution remains valid while a browser app stays focused.
// This must be >= browser extension heartbeat (default 60s), with slack for MV3 background throttling.
const DOMAIN_FRESHNESS_SECONDS: i64 = 300;
const AUDIO_IDLE_CUTOFF_SECONDS: i64 = 120;
const DEFAULT_REVIEW_MIN_SECONDS: i64 = 5 * 60;
const DEFAULT_REVIEW_NOTIFY_REPEAT_MINUTES: i64 = 10;
const REVIEW_MIN_SECONDS_MIN: i64 = 60;
const REVIEW_MIN_SECONDS_MAX: i64 = 4 * 60 * 60;
const REVIEW_NOTIFY_REPEAT_MINUTES_MIN: i64 = 1;
const REVIEW_NOTIFY_REPEAT_MINUTES_MAX: i64 = 24 * 60;
const REVIEW_LAST_BLOCK_END_GRACE_SECONDS: i64 = 30;

const DEFAULT_DAILY_PROMPT: &str = r#"
你是严格的“TODO 驱动”复盘助手。只能使用输入 JSON，不允许猜测；缺失信息写 N/A。
只输出 Markdown（不要代码围栏），不要输出推理过程。

核心要求（必须遵守）：
1) 报告重点是“TODO 进展与下一步决策”，不是流水账。
2) 禁止逐条复述 app/site 或 block 明细，除非该明细直接支撑某个 TODO 的判断。
3) 若 input.todo.open 为空，才退化为通用效率复盘。
4) 对有时间安排的 TODO（due_date/start_ts/end_ts），优先给出“按时间执行”的建议。

输出结构：
1) 标题：# {{date}} 日报（TODO 驱动）
2) TODO 进展表（必须优先输出）：
| TODO | 当前状态(推进/受阻/待启动) | 证据(引用数据) | 风险/阻塞 | 下一步(一句动作) |
规则：基于 input.todo.open；若为空写“当前无开放 TODO”。
3) 核心指标表（6~10 行，不要冗长）：
| 指标 | 值 | 解读 |
建议指标：Focus 总时长、Audio 总时长、Top1 占比、上下文切换次数、黑名单 Focus 时长、未复盘 Blocks、最晚活动时间。
4) 决策建议（3~5 条，每条以 `Action:` 开头）：
- 必须按优先级排序（P1/P2/P3）。
- 每条建议必须绑定某个 TODO（若无 TODO，绑定一个“本周新 TODO”）。
- 每条建议必须可执行、可验证，避免空话。
5) 明日计划（表格，最多 5 行）：
| 优先级 | 动作 | 预估时长 | 成功标准 |

输入 JSON：
{{json}}
"#;

const DEFAULT_WEEKLY_PROMPT: &str = r#"
你是严格的“TODO 驱动”周复盘助手。只能使用输入 JSON，不允许猜测；缺失信息写 N/A。
只输出 Markdown（不要代码围栏），不要输出推理过程。

核心要求（必须遵守）：
1) 报告围绕 TODO 的周进展、阻塞与下周计划，不做流水账汇总。
2) 禁止堆砌 Top 列表细节，除非用于支撑某个 TODO 结论。
3) 建议必须可执行、可量化、可在下周验证。
4) 优先利用 TODO 的计划时间（due_date/start_ts/end_ts）给出“下周日历化安排”。

输出结构：
1) 标题：# 周报 {{week_start}} ~ {{week_end}}（TODO 驱动）
2) TODO 周进展表（优先输出）：
| TODO | 本周状态(完成/推进/停滞) | 数据证据 | 主要阻塞 | 下周动作 |
规则：优先使用 input.todo.open 与 input.todo.done_recent。
3) 周度关键指标（精简表格）：
| 指标 | 本周值 | 变化/解读 |
4) 下周执行计划（3~6 条，以 `Action:` 开头）：
- 每条标注优先级（P1/P2/P3）和预计投入时间。
- 每条都要对应 TODO（已有或新建）。
5) 一个可量化实验：
| 假设 | 执行方式 | 量化指标 | 验收阈值 |

输入 JSON：
{{json}}
"#;

#[derive(Parser, Debug)]
#[command(name = "recorder_core", version)]
struct Args {
    /// Listen address.
    ///
    /// Accepts:
    /// - ip:port (recommended), e.g. 127.0.0.1:17600
    /// - ip (implies port 17600), e.g. 127.0.0.1
    ///
    /// In WSL, if Windows cannot reach it via localhost, try 0.0.0.0:17600.
    #[arg(long, default_value = "127.0.0.1:17600")]
    listen: String,

    /// SQLite database path.
    #[arg(long, default_value = "./data/recorder-core.db")]
    db: PathBuf,

    /// Block length in seconds.
    #[arg(long, default_value_t = 45 * 60)]
    block_seconds: i64,

    /// Idle cutoff for attributing duration between events (seconds).
    #[arg(long, default_value_t = 5 * 60)]
    idle_cutoff_seconds: i64,
}

#[derive(Clone)]
struct AppState {
    conn: Arc<Mutex<Connection>>,
    settings: Arc<Mutex<Settings>>,
    report_settings: Arc<Mutex<ReportSettings>>,
    data_dir: PathBuf,
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
struct Settings {
    block_seconds: i64,
    idle_cutoff_seconds: i64,
    store_titles: bool,
    store_exe_path: bool,
    /// Minimum block duration before it can become "due" for review.
    review_min_seconds: i64,
    /// Minimum minutes between repeated review notifications for the same due block (Windows toast).
    review_notify_repeat_minutes: i64,
    /// Whether reminders are allowed even when tracking is paused.
    review_notify_when_paused: bool,
    /// Whether reminders are allowed even when the machine is idle (Windows toast).
    review_notify_when_idle: bool,
}

#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
struct ReportSettings {
    enabled: bool,
    api_base_url: String, // e.g. https://api.openai.com/v1
    api_key: String,
    model: String,
    daily_enabled: bool,
    daily_at_minutes: i64, // 0..1439 (local)
    daily_prompt: String,
    weekly_enabled: bool,
    weekly_weekday: i32,    // 1=Mon..7=Sun
    weekly_at_minutes: i64, // 0..1439 (local)
    weekly_prompt: String,
    save_md: bool,
    save_csv: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    output_dir: Option<String>,
    updated_at: String,
}

#[derive(Serialize)]
struct ReportSettingsWithResolved {
    #[serde(flatten)]
    settings: ReportSettings,
    effective_output_dir: String,
    default_daily_prompt: &'static str,
    default_weekly_prompt: &'static str,
}

impl ReportSettings {
    fn defaults(updated_at: &str) -> Self {
        Self {
            enabled: false,
            api_base_url: "https://api.openai.com/v1".to_string(),
            api_key: String::new(),
            model: "gpt-4o-mini".to_string(),
            daily_enabled: false,
            daily_at_minutes: 10,
            daily_prompt: DEFAULT_DAILY_PROMPT.to_string(),
            weekly_enabled: false,
            weekly_weekday: 1, // Monday
            weekly_at_minutes: 20,
            weekly_prompt: DEFAULT_WEEKLY_PROMPT.to_string(),
            save_md: true,
            save_csv: false,
            output_dir: None,
            updated_at: updated_at.to_string(),
        }
    }
}

#[derive(Serialize)]
struct OkResponse<T: Serialize> {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<T>,
}

#[derive(Serialize)]
struct ErrResponse {
    ok: bool,
    error: &'static str,
}

#[derive(Deserialize)]
struct IngestEvent {
    v: i32,
    ts: String,
    source: String,
    event: String,
    #[serde(default)]
    domain: Option<String>,
    #[serde(default)]
    app: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    browser: Option<String>,
    #[serde(rename = "tabId", default)]
    #[allow(dead_code)]
    tab_id: Option<i64>,
    #[serde(rename = "windowId", default)]
    #[allow(dead_code)]
    window_id: Option<i64>,
    #[serde(flatten)]
    #[allow(dead_code)]
    extra: HashMap<String, Value>,
}

#[derive(Clone, Serialize)]
struct EventRecord {
    id: i64,
    ts: String,
    source: String,
    event: String,
    entity: Option<String>,
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    activity: Option<String>,
}

#[derive(Deserialize)]
struct EventsQuery {
    #[serde(default = "default_limit")]
    limit: usize,
}

fn default_limit() -> usize {
    50
}

#[derive(Deserialize)]
struct NowQuery {
    #[serde(default = "default_now_limit")]
    limit: usize,
}

fn default_now_limit() -> usize {
    200
}

#[derive(Serialize)]
struct NowSnapshot {
    server_ts: String,
    /// When a focus/tab event is older than this, it is considered stale for "Now".
    focus_ttl_seconds: i64,
    /// Background audio is considered stale after this (helps avoid over-attribution).
    audio_ttl_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    latest_event_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    latest_event: Option<EventRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    latest_event_age_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    app_active: Option<EventRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    app_active_age_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tab_focus: Option<EventRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tab_focus_age_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tab_audio: Option<EventRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tab_audio_stop: Option<EventRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tab_audio_age_seconds: Option<i64>,
    tab_audio_active: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    app_audio: Option<EventRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    app_audio_stop: Option<EventRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    app_audio_age_seconds: Option<i64>,
    app_audio_active: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    now_focus_app: Option<EventRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    now_using_tab: Option<EventRecord>,
    #[serde(skip_serializing_if = "Option::is_none")]
    now_background_audio: Option<EventRecord>,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    latest_titles: HashMap<String, String>, // key: "app|<entity>" or "domain|<hostname>"
}

#[derive(Clone)]
struct EventRow {
    id: i64,
    ts: String,
    source: String,
    event: String,
    entity: Option<String>,
    title: Option<String>,
    payload_json: String,
}

fn parse_activity_from_payload(payload_json: &str) -> Option<String> {
    serde_json::from_str::<Value>(payload_json)
        .ok()
        .and_then(|v| {
            v.get("activity")
                .and_then(|a| a.as_str())
                .map(|s| s.to_string())
        })
}

fn event_record_from_row(row: &EventRow) -> EventRecord {
    EventRecord {
        id: row.id,
        ts: row.ts.clone(),
        source: row.source.clone(),
        event: row.event.clone(),
        entity: row.entity.clone(),
        title: row.title.clone(),
        activity: parse_activity_from_payload(&row.payload_json),
    }
}

fn apply_privacy_to_event(mut e: EventRecord, privacy: &PrivacyIndex) -> Option<EventRecord> {
    if let Some(entity) = e.entity.as_deref() {
        match privacy.decision_for(&e.event, entity) {
            PrivacyDecision::Allow => {}
            PrivacyDecision::Drop => return None,
            PrivacyDecision::Mask => {
                e.entity = Some("__hidden__".to_string());
                e.title = None;
            }
        }
    }
    Some(e)
}

fn load_now_snapshot(
    conn: &mut Connection,
    privacy: &PrivacyIndex,
    settings: Settings,
    now: OffsetDateTime,
    scan_limit: usize,
) -> rusqlite::Result<NowSnapshot> {
    let scan_limit = scan_limit.clamp(1, 2000);

    let mut latest_event_id: Option<i64> = None;
    let mut latest_event: Option<EventRecord> = None;

    let mut app_active: Option<EventRecord> = None;
    let mut tab_focus: Option<EventRecord> = None;
    let mut tab_audio: Option<EventRecord> = None;
    let mut tab_audio_stop: Option<EventRecord> = None;
    let mut app_audio: Option<EventRecord> = None;
    let mut app_audio_stop: Option<EventRecord> = None;

    // 1) latest_event (after privacy)
    {
        let mut stmt = conn.prepare(
            "SELECT id, ts, source, event, entity, title, payload_json FROM events ORDER BY ts DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map([scan_limit as i64], |row| {
            Ok(EventRow {
                id: row.get(0)?,
                ts: row.get(1)?,
                source: row.get(2)?,
                event: row.get(3)?,
                entity: row.get(4)?,
                title: row.get(5)?,
                payload_json: row.get(6)?,
            })
        })?;
        for r in rows {
            let row = r?;
            let e = event_record_from_row(&row);
            let Some(e) = apply_privacy_to_event(e, privacy) else {
                continue;
            };
            latest_event_id = Some(e.id);
            latest_event = Some(e);
            break;
        }
    }

    // 2) app_active
    {
        let mut stmt = conn.prepare(
            "SELECT id, ts, source, event, entity, title, payload_json FROM events WHERE event = 'app_active' ORDER BY ts DESC LIMIT 50",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(EventRow {
                id: row.get(0)?,
                ts: row.get(1)?,
                source: row.get(2)?,
                event: row.get(3)?,
                entity: row.get(4)?,
                title: row.get(5)?,
                payload_json: row.get(6)?,
            })
        })?;
        for r in rows {
            let row = r?;
            let e = event_record_from_row(&row);
            let Some(e) = apply_privacy_to_event(e, privacy) else {
                continue;
            };
            app_active = Some(e);
            break;
        }
    }

    // 3) tab_active focus/audio (scan recent)
    {
        let mut stmt = conn.prepare(
            "SELECT id, ts, source, event, entity, title, payload_json FROM events WHERE event = 'tab_active' ORDER BY ts DESC LIMIT 200",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(EventRow {
                id: row.get(0)?,
                ts: row.get(1)?,
                source: row.get(2)?,
                event: row.get(3)?,
                entity: row.get(4)?,
                title: row.get(5)?,
                payload_json: row.get(6)?,
            })
        })?;
        for r in rows {
            let row = r?;
            let e = event_record_from_row(&row);
            let Some(e) = apply_privacy_to_event(e, privacy) else {
                continue;
            };
            if e.activity.as_deref() == Some("audio") {
                if tab_audio.is_none() {
                    tab_audio = Some(e);
                }
            } else if tab_focus.is_none() {
                tab_focus = Some(e);
            }
            if tab_focus.is_some() && tab_audio.is_some() {
                break;
            }
        }
    }

    // 4) tab_audio_stop
    {
        let mut stmt = conn.prepare(
            "SELECT id, ts, source, event, entity, title, payload_json FROM events WHERE event = 'tab_audio_stop' ORDER BY ts DESC LIMIT 50",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(EventRow {
                id: row.get(0)?,
                ts: row.get(1)?,
                source: row.get(2)?,
                event: row.get(3)?,
                entity: row.get(4)?,
                title: row.get(5)?,
                payload_json: row.get(6)?,
            })
        })?;
        for r in rows {
            let row = r?;
            let e = event_record_from_row(&row);
            let Some(e) = apply_privacy_to_event(e, privacy) else {
                continue;
            };
            tab_audio_stop = Some(e);
            break;
        }
    }

    // 5) app_audio / app_audio_stop
    for (ev, out) in [
        ("app_audio", &mut app_audio),
        ("app_audio_stop", &mut app_audio_stop),
    ] {
        let mut stmt = conn.prepare(
            "SELECT id, ts, source, event, entity, title, payload_json FROM events WHERE event = ?1 ORDER BY ts DESC LIMIT 50",
        )?;
        let rows = stmt.query_map([ev], |row| {
            Ok(EventRow {
                id: row.get(0)?,
                ts: row.get(1)?,
                source: row.get(2)?,
                event: row.get(3)?,
                entity: row.get(4)?,
                title: row.get(5)?,
                payload_json: row.get(6)?,
            })
        })?;
        for r in rows {
            let row = r?;
            let e = event_record_from_row(&row);
            let Some(e) = apply_privacy_to_event(e, privacy) else {
                continue;
            };
            *out = Some(e);
            break;
        }
    }

    // 6) latest_titles (best-effort hints for UI). Only from stored titles.
    let mut latest_titles: HashMap<String, String> = HashMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT event, entity, title FROM events WHERE title IS NOT NULL AND title != '' AND entity IS NOT NULL AND entity != '' AND (event = 'tab_active' OR event = 'app_active') ORDER BY ts DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map([scan_limit as i64], |row| {
            let event: String = row.get(0)?;
            let entity: String = row.get(1)?;
            let title: String = row.get(2)?;
            Ok((event, entity, title))
        })?;
        for r in rows {
            let (event, entity, title) = r?;
            let ent = entity.trim();
            let t = title.trim();
            if ent.is_empty() || t.is_empty() {
                continue;
            }

            // Apply privacy retroactively.
            match privacy.decision_for(&event, ent) {
                PrivacyDecision::Allow => {}
                PrivacyDecision::Drop | PrivacyDecision::Mask => continue,
            }

            if event == "tab_active" {
                latest_titles
                    .entry(format!("domain|{}", ent.to_lowercase()))
                    .or_insert_with(|| t.to_string());
            } else if event == "app_active" {
                latest_titles
                    .entry(format!("app|{}", ent))
                    .or_insert_with(|| t.to_string());
            }

            if latest_titles.len() >= 64 {
                break;
            }
        }
    }

    fn age_seconds(rfc3339: &str, now: OffsetDateTime) -> Option<i64> {
        let t = OffsetDateTime::parse(rfc3339, &Rfc3339).ok()?;
        let diff = now - t;
        Some(diff.whole_seconds().max(0))
    }

    fn parse_ts(rfc3339: &str) -> Option<OffsetDateTime> {
        OffsetDateTime::parse(rfc3339, &Rfc3339).ok()
    }

    let focus_ttl_seconds = settings.idle_cutoff_seconds.max(10);
    let audio_ttl_seconds = AUDIO_IDLE_CUTOFF_SECONDS.max(10);

    let latest_event_age_seconds = latest_event.as_ref().and_then(|e| age_seconds(&e.ts, now));
    let app_active_age_seconds = app_active.as_ref().and_then(|e| age_seconds(&e.ts, now));
    let tab_focus_age_seconds = tab_focus.as_ref().and_then(|e| age_seconds(&e.ts, now));
    let tab_audio_age_seconds = tab_audio.as_ref().and_then(|e| age_seconds(&e.ts, now));
    let app_audio_age_seconds = app_audio.as_ref().and_then(|e| age_seconds(&e.ts, now));

    let mut tab_audio_active = false;
    if let Some(a) = tab_audio.as_ref() {
        tab_audio_active = true;
        if let Some(age) = tab_audio_age_seconds {
            if age > audio_ttl_seconds {
                tab_audio_active = false;
            }
        }
        if tab_audio_active {
            if let (Some(stop), Some(a_ts)) = (tab_audio_stop.as_ref(), parse_ts(&a.ts)) {
                if let Some(s_ts) = parse_ts(&stop.ts) {
                    if s_ts >= a_ts {
                        tab_audio_active = false;
                    }
                }
            }
        }
    }

    let mut app_audio_active = false;
    if let Some(a) = app_audio.as_ref() {
        app_audio_active = true;
        if let Some(age) = app_audio_age_seconds {
            if age > audio_ttl_seconds {
                app_audio_active = false;
            }
        }
        if app_audio_active {
            if let (Some(stop), Some(a_ts)) = (app_audio_stop.as_ref(), parse_ts(&a.ts)) {
                if let Some(s_ts) = parse_ts(&stop.ts) {
                    if s_ts >= a_ts {
                        app_audio_active = false;
                    }
                }
            }
        }
    }

    let app_fresh = app_active_age_seconds
        .map(|age| age <= focus_ttl_seconds)
        .unwrap_or(false);
    let tab_fresh = tab_focus_age_seconds
        .map(|age| age <= focus_ttl_seconds)
        .unwrap_or(false);

    let now_focus_app = if app_fresh { app_active.clone() } else { None };

    let browser_focused = now_focus_app
        .as_ref()
        .and_then(|e| e.entity.as_deref())
        .map(is_browser_app)
        .unwrap_or(false)
        || (now_focus_app.is_none() && tab_fresh);

    let now_using_tab = if browser_focused {
        if tab_fresh {
            tab_focus.clone()
        } else {
            None
        }
    } else if tab_audio_active {
        tab_audio.clone()
    } else {
        None
    };

    let now_background_audio = if app_audio_active {
        app_audio.clone()
    } else {
        None
    };

    let server_ts = now.format(&Rfc3339).unwrap_or_default();

    Ok(NowSnapshot {
        server_ts,
        focus_ttl_seconds,
        audio_ttl_seconds,
        latest_event_id,
        latest_event,
        latest_event_age_seconds,
        app_active,
        app_active_age_seconds,
        tab_focus,
        tab_focus_age_seconds,
        tab_audio,
        tab_audio_stop,
        tab_audio_age_seconds,
        tab_audio_active,
        app_audio,
        app_audio_stop,
        app_audio_age_seconds,
        app_audio_active,
        now_focus_app,
        now_using_tab,
        now_background_audio,
        latest_titles,
    })
}

#[derive(Deserialize)]
struct BlocksQuery {
    /// Date in YYYY-MM-DD.
    date: Option<String>,
    /// Client local offset minutes, e.g. 480 for UTC+8.
    tz_offset_minutes: Option<i32>,
}

#[derive(Serialize)]
struct TrackingStatus {
    paused: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    paused_until_ts: Option<String>,
    updated_at: String,
}

#[derive(Deserialize)]
struct PauseRequest {
    #[serde(default)]
    minutes: Option<i64>,
    #[serde(default)]
    until_ts: Option<String>,
}

#[derive(Deserialize)]
struct SettingsUpdate {
    #[serde(default)]
    block_seconds: Option<i64>,
    #[serde(default)]
    idle_cutoff_seconds: Option<i64>,
    #[serde(default)]
    store_titles: Option<bool>,
    #[serde(default)]
    store_exe_path: Option<bool>,
    #[serde(default)]
    review_min_seconds: Option<i64>,
    #[serde(default)]
    review_notify_repeat_minutes: Option<i64>,
    #[serde(default)]
    review_notify_when_paused: Option<bool>,
    #[serde(default)]
    review_notify_when_idle: Option<bool>,
}

#[derive(Deserialize)]
struct ReportSettingsUpdate {
    #[serde(default)]
    enabled: Option<bool>,
    #[serde(default)]
    api_base_url: Option<String>,
    #[serde(default)]
    api_key: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    daily_enabled: Option<bool>,
    #[serde(default)]
    daily_at_minutes: Option<i64>,
    #[serde(default)]
    daily_prompt: Option<String>,
    #[serde(default)]
    weekly_enabled: Option<bool>,
    #[serde(default)]
    weekly_weekday: Option<i32>,
    #[serde(default)]
    weekly_at_minutes: Option<i64>,
    #[serde(default)]
    weekly_prompt: Option<String>,
    #[serde(default)]
    save_md: Option<bool>,
    #[serde(default)]
    save_csv: Option<bool>,
    #[serde(default)]
    output_dir: Option<String>,
}

#[derive(Deserialize)]
struct BlockDeleteRequest {
    #[serde(default)]
    block_id: Option<String>,
    #[serde(default)]
    start_ts: Option<String>,
    #[serde(default)]
    end_ts: Option<String>,
}

#[derive(Serialize)]
struct DeleteRangeResult {
    start_ts: String,
    end_ts: String,
    events_deleted: i64,
    reviews_deleted: i64,
}

#[derive(Deserialize)]
struct DeleteDayRequest {
    date: String,
    #[serde(default)]
    tz_offset_minutes: Option<i32>,
}

#[derive(Serialize)]
struct DeleteDayResult {
    date: String,
    tz_offset_minutes: i32,
    start_ts: String,
    end_ts: String,
    events_deleted: i64,
    reviews_deleted: i64,
    reports_deleted: i64,
}

#[derive(Serialize)]
struct WipeAllResult {
    events_deleted: i64,
    reviews_deleted: i64,
    reports_deleted: i64,
}

#[derive(Clone, Serialize)]
struct TopItem {
    kind: String,
    entity: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    seconds: i64,
}

#[derive(Clone, Serialize)]
struct BlockReview {
    skipped: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    skip_reason: Option<String>,
    doing: Option<String>,
    output: Option<String>,
    next: Option<String>,
    tags: Vec<String>,
    updated_at: String,
}

#[derive(Clone, Serialize)]
struct BlockSummary {
    id: String,
    start_ts: String,
    end_ts: String,
    total_seconds: i64,
    top_items: Vec<TopItem>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    background_top_items: Vec<TopItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    background_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    review: Option<BlockReview>,
}

#[derive(Serialize)]
struct TimelineSegment {
    kind: String,   // "app" | "domain"
    entity: String, // app id or hostname
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    activity: Option<String>, // "focus" | "audio"
    start_ts: String,
    end_ts: String,
    seconds: i64,
}

#[derive(Deserialize)]
struct ReviewUpsert {
    block_id: String,
    #[serde(default)]
    skipped: bool,
    #[serde(default)]
    skip_reason: Option<String>,
    #[serde(default)]
    doing: Option<String>,
    #[serde(default)]
    output: Option<String>,
    #[serde(default)]
    next: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
}

#[derive(Serialize)]
struct PrivacyRuleRow {
    id: i64,
    kind: String,
    value: String,
    action: String,
    created_at: String,
}

#[derive(Deserialize)]
struct PrivacyRuleUpsert {
    kind: String,
    value: String,
    action: String,
}

#[derive(Default)]
struct PrivacyIndex {
    // (kind, value) -> action ("drop" | "mask")
    action_by_kind_value: HashMap<(String, String), String>,
}

impl PrivacyIndex {
    fn load(conn: &mut Connection) -> rusqlite::Result<Self> {
        let rules = list_privacy_rules(conn)?;
        let mut idx = PrivacyIndex::default();
        for r in rules {
            idx.action_by_kind_value.insert((r.kind, r.value), r.action);
        }
        Ok(idx)
    }

    fn decision_for(&self, event: &str, entity: &str) -> PrivacyDecision {
        let kind = privacy_kind_for_event(event);
        let value = if kind == "domain" {
            entity.trim().to_lowercase()
        } else {
            entity.trim().to_string()
        };
        match self
            .action_by_kind_value
            .get(&(kind.to_string(), value))
            .map(|s| s.as_str())
        {
            Some("drop") => PrivacyDecision::Drop,
            Some("mask") => PrivacyDecision::Mask,
            _ => PrivacyDecision::Allow,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum PrivacyDecision {
    Allow,
    Drop,
    Mask,
}

fn privacy_kind_for_event(event: &str) -> &'static str {
    match event {
        "tab_active" | "tab_audio_stop" => "domain",
        "app_active" | "app_audio" | "app_audio_stop" => "app",
        _ => "app",
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "recorder_core=info,tower_http=info".into()),
        )
        .init();

    let args = Args::parse();
    let default_settings = Settings {
        block_seconds: args.block_seconds,
        idle_cutoff_seconds: args.idle_cutoff_seconds,
        store_titles: false,
        store_exe_path: false,
        review_min_seconds: DEFAULT_REVIEW_MIN_SECONDS,
        review_notify_repeat_minutes: DEFAULT_REVIEW_NOTIFY_REPEAT_MINUTES,
        review_notify_when_paused: false,
        review_notify_when_idle: false,
    };

    if let Some(parent) = args.db.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let data_dir = args
        .db
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."));

    let mut conn = Connection::open(&args.db)?;
    init_db(&conn)?;
    let settings = load_or_init_settings(&mut conn, default_settings)?;
    let report_settings = load_or_init_report_settings(&mut conn)?;

    let state = AppState {
        conn: Arc::new(Mutex::new(conn)),
        settings: Arc::new(Mutex::new(settings)),
        report_settings: Arc::new(Mutex::new(report_settings)),
        data_dir,
    };
    let scheduler_state = state.clone();

    let cors = CorsLayer::new()
        .allow_origin(HeaderValue::from_static("*"))
        .allow_methods([Method::GET, Method::POST, Method::DELETE, Method::OPTIONS])
        .allow_headers([axum::http::header::CONTENT_TYPE]);

    let app = Router::new()
        .route("/health", get(health))
        .route("/event", post(post_event).options(options_ok))
        .route("/events", get(get_events))
        .route("/now", get(get_now))
        .route("/tracking/status", get(get_tracking_status))
        .route(
            "/tracking/pause",
            post(post_tracking_pause).options(options_ok),
        )
        .route(
            "/tracking/resume",
            post(post_tracking_resume).options(options_ok),
        )
        .route(
            "/settings",
            get(get_settings).post(post_settings).options(options_ok),
        )
        .route("/timeline/day", get(get_timeline_day))
        .route("/blocks/today", get(get_blocks_today))
        .route("/blocks/due", get(get_blocks_due))
        .route(
            "/blocks/review",
            post(post_block_review).options(options_ok),
        )
        .route(
            "/blocks/delete",
            post(post_block_delete).options(options_ok),
        )
        .route(
            "/privacy/rules",
            get(get_privacy_rules)
                .post(post_privacy_rule)
                .options(options_ok),
        )
        .route(
            "/privacy/rules/:id",
            delete(delete_privacy_rule).options(options_ok),
        )
        .route(
            "/data/delete_day",
            post(post_data_delete_day).options(options_ok),
        )
        .route("/data/wipe", post(post_data_wipe).options(options_ok))
        .route("/export/markdown", get(get_export_markdown))
        .route("/export/csv", get(get_export_csv))
        .route(
            "/reports/settings",
            get(get_report_settings)
                .post(post_report_settings)
                .options(options_ok),
        )
        .route(
            "/reports/generate/daily",
            post(post_generate_daily_report).options(options_ok),
        )
        .route(
            "/reports/generate/weekly",
            post(post_generate_weekly_report).options(options_ok),
        )
        .route(
            "/reports/todos",
            get(get_report_todos)
                .post(post_report_todo)
                .options(options_ok),
        )
        .route(
            "/reports/todos/:id",
            delete(delete_report_todo).options(options_ok),
        )
        .route(
            "/reports",
            get(get_reports).post(post_report).options(options_ok),
        )
        .route(
            "/reports/:id",
            get(get_report_by_id)
                .delete(delete_report)
                .options(options_ok),
        )
        .with_state(state)
        .layer(cors);

    // Background reports scheduler: runs even if the UI is closed (as long as Core keeps running).
    tokio::spawn(async move {
        report_scheduler_loop(scheduler_state).await;
    });

    let addr = parse_listen(&args.listen)?;
    info!("Core listening on http://{addr}");
    info!("DB: {}", args.db.display());

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

fn parse_listen(input: &str) -> anyhow::Result<SocketAddr> {
    if let Ok(addr) = input.parse::<SocketAddr>() {
        return Ok(addr);
    }

    if let Ok(ip) = input.parse::<IpAddr>() {
        return Ok(SocketAddr::new(ip, DEFAULT_PORT));
    }

    // Support host:port for localhost (handy for docs/UX).
    if let Some((host, port_str)) = input.rsplit_once(':') {
        if host == "localhost" {
            let port: u16 = port_str.parse().map_err(|_| {
                anyhow::anyhow!(
                    "invalid --listen '{}': bad port. Example: 127.0.0.1:{}",
                    input,
                    DEFAULT_PORT
                )
            })?;
            return Ok(SocketAddr::new(IpAddr::from([127, 0, 0, 1]), port));
        }

        // Also accept IPv6 without brackets (best effort): ::1:17600
        if let Ok(ip) = host.parse::<IpAddr>() {
            let port: u16 = port_str.parse().map_err(|_| {
                anyhow::anyhow!(
                    "invalid --listen '{}': bad port. Example: 127.0.0.1:{}",
                    input,
                    DEFAULT_PORT
                )
            })?;
            return Ok(SocketAddr::new(ip, port));
        }
    }

    if input == "localhost" {
        return Ok(SocketAddr::new(IpAddr::from([127, 0, 0, 1]), DEFAULT_PORT));
    }

    Err(anyhow::anyhow!(
        "invalid --listen '{}'. Use ip:port (e.g. 127.0.0.1:{}) or ip (e.g. 127.0.0.1).",
        input,
        DEFAULT_PORT
    ))
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    info!("shutdown requested");
}

async fn options_ok() -> impl IntoResponse {
    StatusCode::OK
}

#[derive(Serialize)]
struct HealthInfo {
    service: &'static str,
    version: &'static str,
}

async fn health() -> impl IntoResponse {
    Json(OkResponse {
        ok: true,
        data: Some(HealthInfo {
            service: "recorder_core",
            version: env!("CARGO_PKG_VERSION"),
        }),
    })
}

async fn post_event(State(state): State<AppState>, Json(payload): Json<Value>) -> Response {
    let e: IngestEvent = match serde_json::from_value(payload.clone()) {
        Ok(v) => v,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_json",
                }),
            )
                .into_response();
        }
    };

    if e.v < 1 {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "invalid_version",
            }),
        )
            .into_response();
    }

    // Validate timestamp format early (store as-is, but ensure parseable).
    if OffsetDateTime::parse(&e.ts, &Rfc3339).is_err() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "invalid_ts",
            }),
        )
            .into_response();
    }

    // Minimal event validation:
    // - tab_active/tab_audio_stop requires domain
    // - app_active/app_audio/app_audio_stop requires app
    let mut entity = match e.event.as_str() {
        "tab_active" => e.domain.clone().filter(|d| !d.trim().is_empty()),
        "app_active" => e.app.clone().filter(|a| !a.trim().is_empty()),
        _ => e
            .domain
            .clone()
            .filter(|d| !d.trim().is_empty())
            .or_else(|| e.app.clone().filter(|a| !a.trim().is_empty())),
    };
    if e.event == "tab_active" && entity.is_none() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "missing_domain",
            }),
        )
            .into_response();
    }
    if e.event == "tab_audio_stop" && entity.is_none() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "missing_domain",
            }),
        )
            .into_response();
    }
    if (e.event == "app_active" || e.event == "app_audio" || e.event == "app_audio_stop")
        && entity.is_none()
    {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "missing_app",
            }),
        )
            .into_response();
    }

    let mut title = e.title.clone();
    let mut payload_to_store = payload;

    let settings = { *state.settings.lock().await };

    let mut conn = state.conn.lock().await;

    match tracking_is_paused(&mut conn, OffsetDateTime::now_utc()) {
        Ok(true) => {
            return Json(OkResponse::<Value> {
                ok: true,
                data: None,
            })
            .into_response();
        }
        Ok(false) => {}
        Err(err) => {
            error!("tracking_is_paused failed: {err}");
        }
    }

    // Apply privacy rules (exact match, MVP).
    if let Some(action) = match privacy_action_for_event(&mut conn, &e) {
        Ok(v) => v,
        Err(err) => {
            error!("privacy_action_for_event failed: {err}");
            None
        }
    } {
        match action.as_str() {
            "drop" => {
                return Json(OkResponse::<Value> {
                    ok: true,
                    data: None,
                })
                .into_response();
            }
            "mask" => {
                entity = Some("__hidden__".to_string());
                title = None;
                if let Some(obj) = payload_to_store.as_object_mut() {
                    obj.insert("masked".to_string(), Value::Bool(true));
                    // Mask all supported entity fields, not just specific event types.
                    // (e.g. tab_audio_stop/app_audio must not leak their domain/app in payload_json.)
                    if obj.contains_key("domain") {
                        obj.insert(
                            "domain".to_string(),
                            Value::String("__hidden__".to_string()),
                        );
                        obj.remove("title");
                    }
                    if obj.contains_key("app") {
                        obj.insert("app".to_string(), Value::String("__hidden__".to_string()));
                        obj.remove("title");
                        obj.remove("exePath");
                        obj.remove("pid");
                    }
                }
            }
            _ => {}
        }
    }

    // Apply global privacy settings (L1/L2). Even if collectors/extensions send more fields,
    // the Core controls what is actually persisted.
    if !settings.store_titles {
        title = None;
        if let Some(obj) = payload_to_store.as_object_mut() {
            obj.remove("title");
        }
    }
    if !settings.store_exe_path {
        if let Some(obj) = payload_to_store.as_object_mut() {
            obj.remove("exePath");
            obj.remove("pid");
        }
    }

    let payload_json = match serde_json::to_string(&payload_to_store) {
        Ok(s) => s,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_json",
                }),
            )
                .into_response();
        }
    };

    if let Err(err) = insert_event(
        &mut conn,
        &e,
        entity.as_deref(),
        title.as_deref(),
        &payload_json,
    ) {
        error!("insert_event failed: {err}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrResponse {
                ok: false,
                error: "db_error",
            }),
        )
            .into_response();
    }

    Json(OkResponse::<Value> {
        ok: true,
        data: None,
    })
    .into_response()
}

async fn get_events(State(state): State<AppState>, Query(q): Query<EventsQuery>) -> Response {
    let limit = q.limit.clamp(1, 500);
    let mut conn = state.conn.lock().await;
    let privacy = PrivacyIndex::load(&mut conn).unwrap_or_default();
    match list_events(&mut conn, limit, &privacy) {
        Ok(events) => Json(OkResponse {
            ok: true,
            data: Some(events),
        })
        .into_response(),
        Err(err) => {
            error!("list_events failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

async fn get_now(State(state): State<AppState>, Query(q): Query<NowQuery>) -> Response {
    let now = OffsetDateTime::now_utc();
    let settings = { *state.settings.lock().await };
    let mut conn = state.conn.lock().await;
    let privacy = PrivacyIndex::load(&mut conn).unwrap_or_default();

    let snap = match load_now_snapshot(&mut conn, &privacy, settings, now, q.limit) {
        Ok(v) => v,
        Err(err) => {
            error!("load_now_snapshot failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response();
        }
    };

    Json(OkResponse {
        ok: true,
        data: Some(snap),
    })
    .into_response()
}

async fn get_tracking_status(State(state): State<AppState>) -> Response {
    let now = OffsetDateTime::now_utc();
    let mut conn = state.conn.lock().await;
    if let Err(err) = tracking_is_paused(&mut conn, now) {
        error!("tracking_is_paused failed: {err}");
    }

    match load_tracking_status(&mut conn) {
        Ok(status) => Json(OkResponse {
            ok: true,
            data: Some(status),
        })
        .into_response(),
        Err(err) => {
            error!("load_tracking_status failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

async fn post_tracking_pause(
    State(state): State<AppState>,
    Json(req): Json<PauseRequest>,
) -> Response {
    let now = OffsetDateTime::now_utc();
    let updated_at = now.format(&Rfc3339).unwrap_or_default();

    let paused_until_ts = if let Some(until_ts) = req.until_ts.as_deref() {
        if OffsetDateTime::parse(until_ts, &Rfc3339).is_err() {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_until_ts",
                }),
            )
                .into_response();
        }
        Some(until_ts.to_string())
    } else if let Some(minutes) = req.minutes {
        if minutes <= 0 {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_minutes",
                }),
            )
                .into_response();
        }
        let until = now + time::Duration::minutes(minutes);
        Some(until.format(&Rfc3339).unwrap_or_default())
    } else {
        None
    };

    let mut conn = state.conn.lock().await;
    if let Err(err) = set_tracking_pause(&mut conn, paused_until_ts.as_deref(), &updated_at) {
        error!("set_tracking_pause failed: {err}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrResponse {
                ok: false,
                error: "db_error",
            }),
        )
            .into_response();
    }

    match load_tracking_status(&mut conn) {
        Ok(status) => Json(OkResponse {
            ok: true,
            data: Some(status),
        })
        .into_response(),
        Err(err) => {
            error!("load_tracking_status failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

async fn post_tracking_resume(State(state): State<AppState>) -> Response {
    let now = OffsetDateTime::now_utc();
    let updated_at = now.format(&Rfc3339).unwrap_or_default();

    let mut conn = state.conn.lock().await;
    if let Err(err) = set_tracking_resume(&mut conn, &updated_at) {
        error!("set_tracking_resume failed: {err}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrResponse {
                ok: false,
                error: "db_error",
            }),
        )
            .into_response();
    }

    match load_tracking_status(&mut conn) {
        Ok(status) => Json(OkResponse {
            ok: true,
            data: Some(status),
        })
        .into_response(),
        Err(err) => {
            error!("load_tracking_status failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

async fn get_settings(State(state): State<AppState>) -> Response {
    let settings = { *state.settings.lock().await };
    Json(OkResponse {
        ok: true,
        data: Some(settings),
    })
    .into_response()
}

async fn post_settings(State(state): State<AppState>, Json(req): Json<SettingsUpdate>) -> Response {
    if let Some(block_seconds) = req.block_seconds {
        if block_seconds < 60 {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_block_seconds",
                }),
            )
                .into_response();
        }
    }
    if let Some(idle_cutoff_seconds) = req.idle_cutoff_seconds {
        if idle_cutoff_seconds < 10 {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_idle_cutoff_seconds",
                }),
            )
                .into_response();
        }
    }
    if let Some(review_min_seconds) = req.review_min_seconds {
        if !(REVIEW_MIN_SECONDS_MIN..=REVIEW_MIN_SECONDS_MAX).contains(&review_min_seconds) {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_review_min_seconds",
                }),
            )
                .into_response();
        }
    }
    if let Some(repeat_minutes) = req.review_notify_repeat_minutes {
        if !(REVIEW_NOTIFY_REPEAT_MINUTES_MIN..=REVIEW_NOTIFY_REPEAT_MINUTES_MAX)
            .contains(&repeat_minutes)
        {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_review_notify_repeat_minutes",
                }),
            )
                .into_response();
        }
    }

    let mut settings = { *state.settings.lock().await };
    if let Some(v) = req.block_seconds {
        settings.block_seconds = v;
    }
    if let Some(v) = req.idle_cutoff_seconds {
        settings.idle_cutoff_seconds = v;
    }
    if let Some(v) = req.store_titles {
        settings.store_titles = v;
    }
    if let Some(v) = req.store_exe_path {
        settings.store_exe_path = v;
    }
    if let Some(v) = req.review_min_seconds {
        settings.review_min_seconds = v.clamp(REVIEW_MIN_SECONDS_MIN, REVIEW_MIN_SECONDS_MAX);
    }
    if let Some(v) = req.review_notify_repeat_minutes {
        settings.review_notify_repeat_minutes = v.clamp(
            REVIEW_NOTIFY_REPEAT_MINUTES_MIN,
            REVIEW_NOTIFY_REPEAT_MINUTES_MAX,
        );
    }
    if let Some(v) = req.review_notify_when_paused {
        settings.review_notify_when_paused = v;
    }
    if let Some(v) = req.review_notify_when_idle {
        settings.review_notify_when_idle = v;
    }

    let updated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_default();
    {
        let mut conn = state.conn.lock().await;
        if let Err(err) = upsert_app_settings(&mut conn, settings, &updated_at) {
            error!("upsert_app_settings failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response();
        }
    }

    {
        let mut guard = state.settings.lock().await;
        *guard = settings;
    }

    Json(OkResponse {
        ok: true,
        data: Some(settings),
    })
    .into_response()
}

async fn get_report_settings(State(state): State<AppState>) -> Response {
    let settings = { state.report_settings.lock().await.clone() };
    let effective_output_dir = resolve_reports_output_dir(&state, &settings)
        .display()
        .to_string();
    Json(OkResponse {
        ok: true,
        data: Some(ReportSettingsWithResolved {
            settings,
            effective_output_dir,
            default_daily_prompt: DEFAULT_DAILY_PROMPT,
            default_weekly_prompt: DEFAULT_WEEKLY_PROMPT,
        }),
    })
    .into_response()
}

async fn post_report_settings(
    State(state): State<AppState>,
    Json(req): Json<ReportSettingsUpdate>,
) -> Response {
    if let Some(v) = req.daily_at_minutes {
        if !(0..=1439).contains(&v) {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_daily_at_minutes",
                }),
            )
                .into_response();
        }
    }
    if let Some(v) = req.weekly_weekday {
        if !(1..=7).contains(&v) {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_weekly_weekday",
                }),
            )
                .into_response();
        }
    }
    if let Some(v) = req.weekly_at_minutes {
        if !(0..=1439).contains(&v) {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_weekly_at_minutes",
                }),
            )
                .into_response();
        }
    }

    let mut settings = { state.report_settings.lock().await.clone() };
    if let Some(v) = req.enabled {
        settings.enabled = v;
    }
    if let Some(v) = req.api_base_url {
        settings.api_base_url = v.trim().to_string();
    }
    if let Some(v) = req.api_key {
        settings.api_key = v.trim().to_string();
    }
    if let Some(v) = req.model {
        settings.model = v.trim().to_string();
    }
    if let Some(v) = req.daily_enabled {
        settings.daily_enabled = v;
    }
    if let Some(v) = req.daily_at_minutes {
        settings.daily_at_minutes = v;
    }
    if let Some(v) = req.daily_prompt {
        settings.daily_prompt = v;
    }
    if let Some(v) = req.weekly_enabled {
        settings.weekly_enabled = v;
    }
    if let Some(v) = req.weekly_weekday {
        settings.weekly_weekday = v;
    }
    if let Some(v) = req.weekly_at_minutes {
        settings.weekly_at_minutes = v;
    }
    if let Some(v) = req.weekly_prompt {
        settings.weekly_prompt = v;
    }
    if let Some(v) = req.save_md {
        settings.save_md = v;
    }
    if let Some(v) = req.save_csv {
        settings.save_csv = v;
    }
    if let Some(v) = req.output_dir {
        let t = v.trim().to_string();
        settings.output_dir = if t.is_empty() { None } else { Some(t) };
    }

    settings.updated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_default();

    {
        let mut conn = state.conn.lock().await;
        if let Err(err) = upsert_report_settings(&mut conn, &settings) {
            error!("upsert_report_settings failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response();
        }
    }

    {
        let mut guard = state.report_settings.lock().await;
        *guard = settings.clone();
    }

    let effective_output_dir = resolve_reports_output_dir(&state, &settings)
        .display()
        .to_string();
    Json(OkResponse {
        ok: true,
        data: Some(ReportSettingsWithResolved {
            settings,
            effective_output_dir,
            default_daily_prompt: DEFAULT_DAILY_PROMPT,
            default_weekly_prompt: DEFAULT_WEEKLY_PROMPT,
        }),
    })
    .into_response()
}

async fn get_report_todos(
    State(state): State<AppState>,
    Query(q): Query<ReportTodosQuery>,
) -> Response {
    let limit = q.limit.clamp(1, 500);
    let mut conn = state.conn.lock().await;
    match list_report_todos(&mut conn, limit) {
        Ok(todos) => Json(OkResponse {
            ok: true,
            data: Some(todos),
        })
        .into_response(),
        Err(err) => {
            error!("list_report_todos failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

fn normalize_todo_due_date(raw: Option<&str>) -> Result<Option<String>, &'static str> {
    let Some(v) = raw else {
        return Ok(None);
    };
    let t = v.trim();
    if t.is_empty() {
        return Ok(None);
    }
    if !validate_yyyy_mm_dd(t) {
        return Err("invalid_due_date");
    }
    Ok(Some(t.to_string()))
}

fn normalize_todo_ts(raw: Option<&str>, err: &'static str) -> Result<Option<String>, &'static str> {
    let Some(v) = raw else {
        return Ok(None);
    };
    let t = v.trim();
    if t.is_empty() {
        return Ok(None);
    }
    let ts = OffsetDateTime::parse(t, &Rfc3339).map_err(|_| err)?;
    Ok(Some(ts.format(&Rfc3339).unwrap_or_else(|_| t.to_string())))
}

fn validate_todo_schedule(
    start_ts: Option<&str>,
    end_ts: Option<&str>,
) -> Result<(), &'static str> {
    if start_ts.is_none() && end_ts.is_none() {
        return Ok(());
    }
    let Some(st_raw) = start_ts else {
        return Err("invalid_schedule_range");
    };
    let Some(en_raw) = end_ts else {
        return Err("invalid_schedule_range");
    };
    let st = OffsetDateTime::parse(st_raw, &Rfc3339).map_err(|_| "invalid_start_ts")?;
    let en = OffsetDateTime::parse(en_raw, &Rfc3339).map_err(|_| "invalid_end_ts")?;
    if en <= st {
        return Err("invalid_schedule_range");
    }
    Ok(())
}

async fn post_report_todo(
    State(state): State<AppState>,
    Json(req): Json<ReportTodoUpsert>,
) -> Response {
    let now = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_default();

    let mut conn = state.conn.lock().await;

    let todo = if let Some(id) = req.id {
        let existing = match get_report_todo_by_id(&mut conn, id) {
            Ok(Some(v)) => v,
            Ok(None) => {
                return (
                    StatusCode::NOT_FOUND,
                    Json(ErrResponse {
                        ok: false,
                        error: "not_found",
                    }),
                )
                    .into_response();
            }
            Err(err) => {
                error!("get_report_todo_by_id failed: {err}");
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
        };

        let content = if let Some(v) = req.content.as_deref() {
            let t = v.trim();
            if t.is_empty() {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(ErrResponse {
                        ok: false,
                        error: "invalid_content",
                    }),
                )
                    .into_response();
            }
            t.to_string()
        } else {
            existing.content.clone()
        };

        let done = req.done.unwrap_or(existing.done);
        let done_at = if done {
            if existing.done {
                existing.done_at.clone().or_else(|| Some(now.clone()))
            } else {
                Some(now.clone())
            }
        } else {
            None
        };
        let due_date = if let Some(v) = req.due_date.as_deref() {
            match normalize_todo_due_date(Some(v)) {
                Ok(x) => x,
                Err(code) => {
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(ErrResponse {
                            ok: false,
                            error: code,
                        }),
                    )
                        .into_response();
                }
            }
        } else {
            existing.due_date.clone()
        };
        let start_ts = if let Some(v) = req.start_ts.as_deref() {
            match normalize_todo_ts(Some(v), "invalid_start_ts") {
                Ok(x) => x,
                Err(code) => {
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(ErrResponse {
                            ok: false,
                            error: code,
                        }),
                    )
                        .into_response();
                }
            }
        } else {
            existing.start_ts.clone()
        };
        let end_ts = if let Some(v) = req.end_ts.as_deref() {
            match normalize_todo_ts(Some(v), "invalid_end_ts") {
                Ok(x) => x,
                Err(code) => {
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(ErrResponse {
                            ok: false,
                            error: code,
                        }),
                    )
                        .into_response();
                }
            }
        } else {
            existing.end_ts.clone()
        };
        if let Err(code) = validate_todo_schedule(start_ts.as_deref(), end_ts.as_deref()) {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: code,
                }),
            )
                .into_response();
        }

        if let Err(err) = update_report_todo(
            &mut conn,
            id,
            &content,
            done,
            due_date.as_deref(),
            start_ts.as_deref(),
            end_ts.as_deref(),
            done_at.as_deref(),
            &now,
        ) {
            error!("update_report_todo failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response();
        }

        match get_report_todo_by_id(&mut conn, id) {
            Ok(Some(v)) => v,
            Ok(None) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
            Err(err) => {
                error!("get_report_todo_by_id after update failed: {err}");
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
        }
    } else {
        let content = match req.content.as_deref().map(str::trim) {
            Some(v) if !v.is_empty() => v.to_string(),
            _ => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(ErrResponse {
                        ok: false,
                        error: "missing_content",
                    }),
                )
                    .into_response();
            }
        };
        let done = req.done.unwrap_or(false);
        let done_at = if done { Some(now.as_str()) } else { None };
        let due_date = match normalize_todo_due_date(req.due_date.as_deref()) {
            Ok(x) => x,
            Err(code) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(ErrResponse {
                        ok: false,
                        error: code,
                    }),
                )
                    .into_response();
            }
        };
        let start_ts = match normalize_todo_ts(req.start_ts.as_deref(), "invalid_start_ts") {
            Ok(x) => x,
            Err(code) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(ErrResponse {
                        ok: false,
                        error: code,
                    }),
                )
                    .into_response();
            }
        };
        let end_ts = match normalize_todo_ts(req.end_ts.as_deref(), "invalid_end_ts") {
            Ok(x) => x,
            Err(code) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(ErrResponse {
                        ok: false,
                        error: code,
                    }),
                )
                    .into_response();
            }
        };
        if let Err(code) = validate_todo_schedule(start_ts.as_deref(), end_ts.as_deref()) {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: code,
                }),
            )
                .into_response();
        }

        let id = match insert_report_todo(
            &mut conn,
            &content,
            done,
            due_date.as_deref(),
            start_ts.as_deref(),
            end_ts.as_deref(),
            done_at,
            &now,
        ) {
            Ok(v) => v,
            Err(err) => {
                error!("insert_report_todo failed: {err}");
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
        };

        match get_report_todo_by_id(&mut conn, id) {
            Ok(Some(v)) => v,
            Ok(None) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
            Err(err) => {
                error!("get_report_todo_by_id after insert failed: {err}");
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
        }
    };

    Json(OkResponse {
        ok: true,
        data: Some(todo),
    })
    .into_response()
}

async fn delete_report_todo(State(state): State<AppState>, Path(id): Path<i64>) -> Response {
    let mut conn = state.conn.lock().await;
    match delete_report_todo_by_id(&mut conn, id) {
        Ok(0) => (
            StatusCode::NOT_FOUND,
            Json(ErrResponse {
                ok: false,
                error: "not_found",
            }),
        )
            .into_response(),
        Ok(_) => Json(OkResponse::<Value> {
            ok: true,
            data: None,
        })
        .into_response(),
        Err(err) => {
            error!("delete_report_todo_by_id failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

async fn get_blocks_today(State(state): State<AppState>, Query(q): Query<BlocksQuery>) -> Response {
    let tz_offset_minutes = normalize_tz_offset_minutes(q.tz_offset_minutes);
    let tz_offset = tz_offset_from_minutes(tz_offset_minutes);

    let date = match q.date {
        Some(s) => s,
        None => OffsetDateTime::now_utc()
            .to_offset(tz_offset)
            .date()
            .to_string(),
    };

    let day_start = match parse_day_start_utc_for_offset(&date, tz_offset) {
        Ok(t) => t,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_date",
                }),
            )
                .into_response();
        }
    };
    let day_end = day_start + time::Duration::days(1);

    let events = {
        let mut conn = state.conn.lock().await;
        let privacy = PrivacyIndex::load(&mut conn).unwrap_or_default();
        match list_events_between(&mut conn, day_start, day_end, &privacy) {
            Ok(v) => v,
            Err(err) => {
                error!("list_events_between failed: {err}");
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
        }
    };

    let settings = { *state.settings.lock().await };
    let blocks = build_blocks(&events, settings, OffsetDateTime::now_utc().min(day_end));

    let blocks_with_reviews = {
        let mut conn = state.conn.lock().await;
        attach_reviews(&mut conn, blocks).unwrap_or_else(|err| {
            error!("attach_reviews failed: {err}");
            Vec::new()
        })
    };

    Json(OkResponse {
        ok: true,
        data: Some(blocks_with_reviews),
    })
    .into_response()
}

fn block_is_reviewed(r: &BlockReview) -> bool {
    if r.skipped {
        return true;
    }
    if !r.doing.as_deref().unwrap_or("").trim().is_empty() {
        return true;
    }
    if !r.output.as_deref().unwrap_or("").trim().is_empty() {
        return true;
    }
    if !r.next.as_deref().unwrap_or("").trim().is_empty() {
        return true;
    }
    !r.tags.is_empty()
}

fn find_due_block(
    blocks: &[BlockSummary],
    settings: Settings,
    now: OffsetDateTime,
) -> Option<BlockSummary> {
    if blocks.is_empty() {
        return None;
    }
    let min_seconds = settings
        .review_min_seconds
        .clamp(REVIEW_MIN_SECONDS_MIN, REVIEW_MIN_SECONDS_MAX);
    let block_seconds = settings.block_seconds.max(60);

    for i in (0..blocks.len()).rev() {
        let b = &blocks[i];
        if b.total_seconds < min_seconds {
            continue;
        }
        if let Some(r) = &b.review {
            if block_is_reviewed(r) {
                continue;
            }
        }

        let has_next = i < blocks.len() - 1;
        if has_next {
            return Some(b.clone());
        }

        if b.total_seconds >= block_seconds {
            return Some(b.clone());
        }

        if let Ok(end) = OffsetDateTime::parse(&b.end_ts, &Rfc3339) {
            if now - end > time::Duration::seconds(REVIEW_LAST_BLOCK_END_GRACE_SECONDS) {
                return Some(b.clone());
            }
        }
    }

    None
}

async fn get_blocks_due(State(state): State<AppState>, Query(q): Query<BlocksQuery>) -> Response {
    let tz_offset_minutes = normalize_tz_offset_minutes(q.tz_offset_minutes);
    let tz_offset = tz_offset_from_minutes(tz_offset_minutes);

    let date = match q.date {
        Some(s) => s,
        None => OffsetDateTime::now_utc()
            .to_offset(tz_offset)
            .date()
            .to_string(),
    };

    let day_start = match parse_day_start_utc_for_offset(&date, tz_offset) {
        Ok(t) => t,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_date",
                }),
            )
                .into_response();
        }
    };
    let day_end = day_start + time::Duration::days(1);

    let now = OffsetDateTime::now_utc().min(day_end);

    let events = {
        let mut conn = state.conn.lock().await;
        let privacy = PrivacyIndex::load(&mut conn).unwrap_or_default();
        match list_events_between(&mut conn, day_start, day_end, &privacy) {
            Ok(v) => v,
            Err(err) => {
                error!("list_events_between failed: {err}");
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
        }
    };

    let settings = { *state.settings.lock().await };
    let blocks = build_blocks(&events, settings, now);

    let blocks_with_reviews = {
        let mut conn = state.conn.lock().await;
        attach_reviews(&mut conn, blocks).unwrap_or_else(|err| {
            error!("attach_reviews failed: {err}");
            Vec::new()
        })
    };

    let due = find_due_block(&blocks_with_reviews, settings, now);

    Json(OkResponse {
        ok: true,
        data: due,
    })
    .into_response()
}

async fn get_timeline_day(State(state): State<AppState>, Query(q): Query<BlocksQuery>) -> Response {
    let tz_offset_minutes = normalize_tz_offset_minutes(q.tz_offset_minutes);
    let tz_offset = tz_offset_from_minutes(tz_offset_minutes);

    let date = match q.date {
        Some(s) => s,
        None => OffsetDateTime::now_utc()
            .to_offset(tz_offset)
            .date()
            .to_string(),
    };

    let day_start = match parse_day_start_utc_for_offset(&date, tz_offset) {
        Ok(t) => t,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_date",
                }),
            )
                .into_response();
        }
    };
    let day_end = day_start + time::Duration::days(1);

    let events = {
        let mut conn = state.conn.lock().await;
        let privacy = PrivacyIndex::load(&mut conn).unwrap_or_default();
        match list_events_between(&mut conn, day_start, day_end, &privacy) {
            Ok(v) => v,
            Err(err) => {
                error!("list_events_between failed: {err}");
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
        }
    };

    let settings = { *state.settings.lock().await };
    let segments =
        build_timeline_segments(&events, settings, OffsetDateTime::now_utc().min(day_end));

    Json(OkResponse {
        ok: true,
        data: Some(segments),
    })
    .into_response()
}

async fn post_block_review(State(state): State<AppState>, Json(r): Json<ReviewUpsert>) -> Response {
    if r.block_id.trim().is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "missing_block_id",
            }),
        )
            .into_response();
    }

    let updated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| r.block_id.clone());
    let tags_json = serde_json::to_string(&r.tags).unwrap_or_else(|_| "[]".to_string());
    let skip_reason = if r.skipped {
        r.skip_reason
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToString::to_string)
    } else {
        None
    };

    let mut conn = state.conn.lock().await;
    if let Err(err) = upsert_review(
        &mut conn,
        &r,
        skip_reason.as_deref(),
        &tags_json,
        &updated_at,
    ) {
        error!("upsert_review failed: {err}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrResponse {
                ok: false,
                error: "db_error",
            }),
        )
            .into_response();
    }

    Json(OkResponse::<Value> {
        ok: true,
        data: None,
    })
    .into_response()
}

async fn post_block_delete(
    State(state): State<AppState>,
    Json(req): Json<BlockDeleteRequest>,
) -> Response {
    let start_ts = req
        .start_ts
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| req.block_id.as_deref().filter(|s| !s.trim().is_empty()));

    let start_ts = match start_ts {
        Some(s) => s,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "missing_start_ts",
                }),
            )
                .into_response();
        }
    };

    let start = match OffsetDateTime::parse(start_ts, &Rfc3339) {
        Ok(t) => t,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_start_ts",
                }),
            )
                .into_response();
        }
    };

    let end = if let Some(end_ts) = req.end_ts.as_deref().filter(|s| !s.trim().is_empty()) {
        match OffsetDateTime::parse(end_ts, &Rfc3339) {
            Ok(t) => t,
            Err(_) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(ErrResponse {
                        ok: false,
                        error: "invalid_end_ts",
                    }),
                )
                    .into_response();
            }
        }
    } else {
        let settings = { *state.settings.lock().await };
        start + time::Duration::seconds(settings.block_seconds.max(60))
    };

    if end <= start {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "invalid_range",
            }),
        )
            .into_response();
    }

    let start_s = start.format(&Rfc3339).unwrap_or_default();
    let end_s = end.format(&Rfc3339).unwrap_or_default();

    let conn = state.conn.lock().await;
    let events_deleted = match conn.execute(
        "DELETE FROM events WHERE ts >= ?1 AND ts < ?2",
        (&start_s, &end_s),
    ) {
        Ok(n) => n as i64,
        Err(err) => {
            error!("delete events failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response();
        }
    };

    let reviews_deleted =
        match conn.execute("DELETE FROM block_reviews WHERE block_id = ?1", [&start_s]) {
            Ok(n) => n as i64,
            Err(err) => {
                error!("delete block_review failed: {err}");
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
        };

    Json(OkResponse {
        ok: true,
        data: Some(DeleteRangeResult {
            start_ts: start_s,
            end_ts: end_s,
            events_deleted,
            reviews_deleted,
        }),
    })
    .into_response()
}

async fn get_privacy_rules(State(state): State<AppState>) -> Response {
    let mut conn = state.conn.lock().await;
    match list_privacy_rules(&mut conn) {
        Ok(rules) => Json(OkResponse {
            ok: true,
            data: Some(rules),
        })
        .into_response(),
        Err(err) => {
            error!("list_privacy_rules failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

async fn post_privacy_rule(
    State(state): State<AppState>,
    Json(r): Json<PrivacyRuleUpsert>,
) -> Response {
    let kind = r.kind.trim().to_lowercase();
    let action = r.action.trim().to_lowercase();
    let mut value = r.value.trim().to_string();

    if kind.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "missing_kind",
            }),
        )
            .into_response();
    }
    if value.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "missing_value",
            }),
        )
            .into_response();
    }

    match kind.as_str() {
        "domain" => {
            value = value.to_lowercase();
        }
        "app" => {}
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_kind",
                }),
            )
                .into_response();
        }
    }

    match action.as_str() {
        "drop" | "mask" => {}
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_action",
                }),
            )
                .into_response();
        }
    }

    let created_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_default();

    let mut conn = state.conn.lock().await;
    match upsert_privacy_rule(&mut conn, &kind, &value, &action, &created_at) {
        Ok(rule) => Json(OkResponse {
            ok: true,
            data: Some(rule),
        })
        .into_response(),
        Err(err) => {
            error!("upsert_privacy_rule failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

async fn delete_privacy_rule(State(state): State<AppState>, Path(id): Path<i64>) -> Response {
    let mut conn = state.conn.lock().await;
    match delete_privacy_rule_by_id(&mut conn, id) {
        Ok(0) => (
            StatusCode::NOT_FOUND,
            Json(ErrResponse {
                ok: false,
                error: "not_found",
            }),
        )
            .into_response(),
        Ok(_) => Json(OkResponse::<Value> {
            ok: true,
            data: None,
        })
        .into_response(),
        Err(err) => {
            error!("delete_privacy_rule_by_id failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

async fn post_data_delete_day(
    State(state): State<AppState>,
    Json(req): Json<DeleteDayRequest>,
) -> Response {
    let tz_offset_minutes = normalize_tz_offset_minutes(req.tz_offset_minutes);
    let tz_offset = tz_offset_from_minutes(tz_offset_minutes);

    let day_start = match parse_day_start_utc_for_offset(&req.date, tz_offset) {
        Ok(t) => t,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_date",
                }),
            )
                .into_response();
        }
    };
    let day_end = day_start + time::Duration::days(1);

    let start_s = day_start.format(&Rfc3339).unwrap_or_default();
    let end_s = day_end.format(&Rfc3339).unwrap_or_default();

    let conn = state.conn.lock().await;
    let events_deleted = match conn.execute(
        "DELETE FROM events WHERE ts >= ?1 AND ts < ?2",
        (&start_s, &end_s),
    ) {
        Ok(n) => n as i64,
        Err(err) => {
            error!("delete events failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response();
        }
    };

    let reviews_deleted = match conn.execute(
        "DELETE FROM block_reviews WHERE block_id >= ?1 AND block_id < ?2",
        (&start_s, &end_s),
    ) {
        Ok(n) => n as i64,
        Err(err) => {
            error!("delete block_reviews failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response();
        }
    };

    let reports_deleted = match conn.execute(
        "DELETE FROM reports WHERE period_start <= ?1 AND period_end >= ?1",
        [&req.date],
    ) {
        Ok(n) => n as i64,
        Err(err) => {
            error!("delete reports failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response();
        }
    };

    Json(OkResponse {
        ok: true,
        data: Some(DeleteDayResult {
            date: req.date,
            tz_offset_minutes,
            start_ts: start_s,
            end_ts: end_s,
            events_deleted,
            reviews_deleted,
            reports_deleted,
        }),
    })
    .into_response()
}

async fn post_data_wipe(State(state): State<AppState>) -> Response {
    let conn = state.conn.lock().await;

    let events_deleted = match conn.execute("DELETE FROM events", []) {
        Ok(n) => n as i64,
        Err(err) => {
            error!("wipe events failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response();
        }
    };

    let reviews_deleted = match conn.execute("DELETE FROM block_reviews", []) {
        Ok(n) => n as i64,
        Err(err) => {
            error!("wipe block_reviews failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response();
        }
    };

    let reports_deleted = match conn.execute("DELETE FROM reports", []) {
        Ok(n) => n as i64,
        Err(err) => {
            error!("wipe reports failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response();
        }
    };

    // Best effort: reset AUTOINCREMENT sequence so ids start small again.
    // Ignore errors (sqlite_sequence may not exist depending on build/pragma).
    let _ = conn.execute("DELETE FROM sqlite_sequence WHERE name = 'events'", []);

    Json(OkResponse {
        ok: true,
        data: Some(WipeAllResult {
            events_deleted,
            reviews_deleted,
            reports_deleted,
        }),
    })
    .into_response()
}

#[derive(Deserialize)]
struct ExportQuery {
    date: Option<String>,
    tz_offset_minutes: Option<i32>,
}

async fn get_export_markdown(
    State(state): State<AppState>,
    Query(q): Query<ExportQuery>,
) -> Response {
    let tz_offset_minutes = normalize_tz_offset_minutes(q.tz_offset_minutes);
    let tz_offset = tz_offset_from_minutes(tz_offset_minutes);

    let date = match q.date {
        Some(s) => s,
        None => OffsetDateTime::now_utc()
            .to_offset(tz_offset)
            .date()
            .to_string(),
    };

    let day_start = match parse_day_start_utc_for_offset(&date, tz_offset) {
        Ok(t) => t,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_date",
                }),
            )
                .into_response();
        }
    };
    let day_end = day_start + time::Duration::days(1);

    let events = {
        let mut conn = state.conn.lock().await;
        let privacy = PrivacyIndex::load(&mut conn).unwrap_or_default();
        match list_events_between(&mut conn, day_start, day_end, &privacy) {
            Ok(v) => v,
            Err(err) => {
                error!("list_events_between failed: {err}");
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
        }
    };
    let settings = { *state.settings.lock().await };
    let blocks = build_blocks(&events, settings, OffsetDateTime::now_utc().min(day_end));
    let blocks = {
        let mut conn = state.conn.lock().await;
        attach_reviews(&mut conn, blocks).unwrap_or_default()
    };

    let md = export_markdown(&date, &blocks, tz_offset);
    (
        StatusCode::OK,
        [("content-type", "text/markdown; charset=utf-8")],
        md,
    )
        .into_response()
}

async fn get_export_csv(State(state): State<AppState>, Query(q): Query<ExportQuery>) -> Response {
    let tz_offset_minutes = normalize_tz_offset_minutes(q.tz_offset_minutes);
    let tz_offset = tz_offset_from_minutes(tz_offset_minutes);

    let date = match q.date {
        Some(s) => s,
        None => OffsetDateTime::now_utc()
            .to_offset(tz_offset)
            .date()
            .to_string(),
    };

    let day_start = match parse_day_start_utc_for_offset(&date, tz_offset) {
        Ok(t) => t,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrResponse {
                    ok: false,
                    error: "invalid_date",
                }),
            )
                .into_response();
        }
    };
    let day_end = day_start + time::Duration::days(1);

    let events = {
        let mut conn = state.conn.lock().await;
        let privacy = PrivacyIndex::load(&mut conn).unwrap_or_default();
        match list_events_between(&mut conn, day_start, day_end, &privacy) {
            Ok(v) => v,
            Err(err) => {
                error!("list_events_between failed: {err}");
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrResponse {
                        ok: false,
                        error: "db_error",
                    }),
                )
                    .into_response();
            }
        }
    };
    let settings = { *state.settings.lock().await };
    let blocks = build_blocks(&events, settings, OffsetDateTime::now_utc().min(day_end));
    let blocks = {
        let mut conn = state.conn.lock().await;
        attach_reviews(&mut conn, blocks).unwrap_or_default()
    };

    let csv = export_csv(&date, &blocks);
    (
        StatusCode::OK,
        [("content-type", "text/csv; charset=utf-8")],
        csv,
    )
        .into_response()
}

#[derive(Deserialize)]
struct ReportsQuery {
    #[serde(default = "default_reports_limit")]
    limit: usize,
}

fn default_reports_limit() -> usize {
    50
}

#[derive(Clone, Serialize)]
struct ReportSummary {
    id: String,
    kind: String,         // "daily" | "weekly"
    period_start: String, // YYYY-MM-DD
    period_end: String,   // YYYY-MM-DD
    generated_at: String, // RFC3339
    #[serde(skip_serializing_if = "Option::is_none")]
    provider_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    has_output: bool,
    has_error: bool,
}

#[derive(Clone, Serialize)]
struct ReportRecord {
    id: String,
    kind: String,
    period_start: String,
    period_end: String,
    generated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    provider_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    input_json: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    output_md: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Clone, Serialize)]
struct ReportTodo {
    id: i64,
    content: String,
    done: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    due_date: Option<String>, // YYYY-MM-DD
    #[serde(skip_serializing_if = "Option::is_none")]
    start_ts: Option<String>, // RFC3339
    #[serde(skip_serializing_if = "Option::is_none")]
    end_ts: Option<String>, // RFC3339
    created_at: String,
    updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    done_at: Option<String>,
}

#[derive(Deserialize)]
struct ReportTodoUpsert {
    #[serde(default)]
    id: Option<i64>,
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    done: Option<bool>,
    #[serde(default)]
    due_date: Option<String>,
    #[serde(default)]
    start_ts: Option<String>,
    #[serde(default)]
    end_ts: Option<String>,
}

#[derive(Deserialize)]
struct ReportTodosQuery {
    #[serde(default = "default_report_todos_limit")]
    limit: usize,
}

fn default_report_todos_limit() -> usize {
    200
}

#[derive(Deserialize)]
struct ReportUpsert {
    id: String,
    kind: String,
    period_start: String,
    period_end: String,
    #[serde(default)]
    generated_at: Option<String>,
    #[serde(default)]
    provider_url: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    input_json: Option<String>,
    #[serde(default)]
    output_md: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

fn validate_report_kind(kind: &str) -> bool {
    kind == "daily" || kind == "weekly"
}

fn validate_yyyy_mm_dd(s: &str) -> bool {
    // Minimal, fast validation; lexicographic order matches chronological order for YYYY-MM-DD.
    if s.len() != 10 {
        return false;
    }
    let bytes = s.as_bytes();
    if bytes[4] != b'-' || bytes[7] != b'-' {
        return false;
    }
    bytes
        .iter()
        .enumerate()
        .all(|(i, b)| i == 4 || i == 7 || (*b >= b'0' && *b <= b'9'))
}

#[derive(Deserialize)]
struct GenerateDailyReportRequest {
    /// Local date in YYYY-MM-DD. If omitted, defaults to yesterday (local).
    #[serde(default)]
    date: Option<String>,
    /// Optional override when Core is not running in the user's local timezone.
    #[serde(default)]
    tz_offset_minutes: Option<i32>,
    #[serde(default)]
    force: bool,
}

#[derive(Deserialize)]
struct GenerateWeeklyReportRequest {
    /// Any local date within the target week (YYYY-MM-DD). If omitted, defaults to last week.
    #[serde(default)]
    week_start: Option<String>,
    /// Optional override when Core is not running in the user's local timezone.
    #[serde(default)]
    tz_offset_minutes: Option<i32>,
    #[serde(default)]
    force: bool,
}

fn report_id_daily(date: &str) -> String {
    format!("daily-{date}")
}

fn report_id_weekly(start: &str, end: &str) -> String {
    format!("weekly-{start}-{end}")
}

fn report_is_good(r: &ReportRecord) -> bool {
    let out_ok = r
        .output_md
        .as_deref()
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false);
    let err_ok = r
        .error
        .as_deref()
        .map(|s| s.trim().is_empty())
        .unwrap_or(true);
    out_ok && err_ok
}

fn report_settings_is_configured(s: &ReportSettings) -> bool {
    if !s.enabled {
        return false;
    }
    let base = s.api_base_url.trim();
    if base.is_empty() {
        return false;
    }
    if s.api_key.trim().is_empty() {
        return false;
    }
    if s.model.trim().is_empty() {
        return false;
    }
    let Ok(u) = base.parse::<reqwest::Url>() else {
        return false;
    };
    if u.scheme() != "http" && u.scheme() != "https" {
        return false;
    }
    if u.host_str().unwrap_or("").trim().is_empty() {
        return false;
    }
    true
}

fn privacy_level_label(s: Settings) -> &'static str {
    if s.store_exe_path {
        "L3"
    } else if s.store_titles {
        "L2"
    } else {
        "L1"
    }
}

fn extract_vscode_workspace(title: &str) -> Option<String> {
    let mut s = title.trim().to_string();
    if s.is_empty() {
        return None;
    }

    // Strip suffix like " - Visual Studio Code" (and any variants).
    for suffix in [
        " - Visual Studio Code",
        " — Visual Studio Code",
        " – Visual Studio Code",
        " - Visual Studio Code Insiders",
        " — Visual Studio Code Insiders",
        " – Visual Studio Code Insiders",
    ] {
        if s.ends_with(suffix) {
            let cut = s.len().saturating_sub(suffix.len());
            s.truncate(cut);
            break;
        }
    }
    s = s.trim().to_string();
    if s.is_empty() {
        return None;
    }

    // Titles are often "file - folder" or "workspace - file - folder".
    let parts: Vec<String> = s
        .split(['-', '—', '–'])
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
        .map(|p| p.to_string())
        .collect();
    if parts.is_empty() {
        return None;
    }
    if parts.len() >= 2 {
        return Some(parts[parts.len() - 1].clone());
    }
    Some(parts[0].clone())
}

fn display_entity(raw: &str) -> String {
    let v = raw.trim();
    if v.is_empty() {
        return "(unknown)".to_string();
    }
    if v == "__hidden__" {
        return "(hidden)".to_string();
    }
    let base = v.rsplit(['\\', '/']).next().unwrap_or(v);
    let lower = base.to_lowercase();
    if lower.ends_with(".exe") && base.len() >= 4 {
        return base[..base.len() - 4].to_string();
    }
    base.to_string()
}

fn is_blocked_domain(domain: &str, blocked: &HashSet<String>) -> bool {
    let d = domain.trim().to_lowercase();
    if d.is_empty() {
        return false;
    }
    if blocked.contains(&d) {
        return true;
    }
    // Suffix match like Core privacy rules: youtube.com matches m.youtube.com.
    let mut candidate: &str = d.as_str();
    loop {
        let Some((_left, rest)) = candidate.split_once('.') else {
            break;
        };
        if !rest.contains('.') {
            break;
        }
        candidate = rest;
        if blocked.contains(candidate) {
            return true;
        }
    }
    false
}

fn tz_offset_minutes_for_day_local(date: &str) -> Option<i32> {
    use chrono::{Local, NaiveDate, TimeZone};
    let parts: Vec<&str> = date.trim().split('-').collect();
    if parts.len() != 3 {
        return None;
    }
    let y: i32 = parts[0].parse().ok()?;
    let m: u32 = parts[1].parse().ok()?;
    let d: u32 = parts[2].parse().ok()?;
    let day = NaiveDate::from_ymd_opt(y, m, d)?;
    let noon = day.and_hms_opt(12, 0, 0)?;
    let dt = Local.from_local_datetime(&noon).single()?;
    Some(dt.offset().local_minus_utc() / 60)
}

fn date_local_today() -> String {
    use chrono::Local;
    Local::now().format("%Y-%m-%d").to_string()
}

fn date_local_yesterday() -> String {
    use chrono::{Duration, Local};
    (Local::now() - Duration::days(1))
        .format("%Y-%m-%d")
        .to_string()
}

fn start_of_week_monday(date_local: &str) -> Option<String> {
    use chrono::{Datelike, Duration, NaiveDate};
    let parts: Vec<&str> = date_local.trim().split('-').collect();
    if parts.len() != 3 {
        return None;
    }
    let y: i32 = parts[0].parse().ok()?;
    let m: u32 = parts[1].parse().ok()?;
    let d: u32 = parts[2].parse().ok()?;
    let day = NaiveDate::from_ymd_opt(y, m, d)?;
    let weekday = day.weekday().number_from_monday() as i64; // 1..7
    let monday = day - Duration::days(weekday - 1);
    Some(monday.format("%Y-%m-%d").to_string())
}

async fn get_reports(State(state): State<AppState>, Query(q): Query<ReportsQuery>) -> Response {
    let limit = q.limit.clamp(1, 200);
    let mut conn = state.conn.lock().await;
    match list_reports(&mut conn, limit) {
        Ok(list) => Json(OkResponse {
            ok: true,
            data: Some(list),
        })
        .into_response(),
        Err(err) => {
            error!("list_reports failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

async fn post_generate_daily_report(
    State(state): State<AppState>,
    Json(req): Json<GenerateDailyReportRequest>,
) -> Response {
    let report_settings = { state.report_settings.lock().await.clone() };
    if !report_settings_is_configured(&report_settings) {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "llm_not_configured",
            }),
        )
            .into_response();
    }

    let date = req
        .date
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .unwrap_or_else(date_local_yesterday);
    if !validate_yyyy_mm_dd(&date) {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "invalid_date",
            }),
        )
            .into_response();
    }

    let tz_offset_minutes = req
        .tz_offset_minutes
        .or_else(|| tz_offset_minutes_for_day_local(&date))
        .unwrap_or(0)
        .clamp(TZ_OFFSET_MINUTES_MIN, TZ_OFFSET_MINUTES_MAX);

    let res = match generate_daily_report(
        &state,
        &report_settings,
        &date,
        tz_offset_minutes,
        req.force,
    )
    .await
    {
        Ok(r) => r,
        Err(err) => {
            error!("generate_daily_report failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "internal_error",
                }),
            )
                .into_response();
        }
    };

    Json(OkResponse {
        ok: true,
        data: Some(res),
    })
    .into_response()
}

async fn post_generate_weekly_report(
    State(state): State<AppState>,
    Json(req): Json<GenerateWeeklyReportRequest>,
) -> Response {
    let report_settings = { state.report_settings.lock().await.clone() };
    if !report_settings_is_configured(&report_settings) {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "llm_not_configured",
            }),
        )
            .into_response();
    }

    let base_date = req
        .week_start
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .unwrap_or_else(date_local_today);
    if !validate_yyyy_mm_dd(&base_date) {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "invalid_week_start",
            }),
        )
            .into_response();
    }

    let Some(week_start) = start_of_week_monday(&base_date) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "invalid_week_start",
            }),
        )
            .into_response();
    };
    let week_end = {
        use chrono::{Duration, NaiveDate};
        let parts: Vec<&str> = week_start.split('-').collect();
        let y: i32 = parts[0].parse().unwrap_or(1970);
        let m: u32 = parts[1].parse().unwrap_or(1);
        let d: u32 = parts[2].parse().unwrap_or(1);
        let day = NaiveDate::from_ymd_opt(y, m, d).unwrap();
        (day + Duration::days(6)).format("%Y-%m-%d").to_string()
    };

    let tz_offset_minutes = req
        .tz_offset_minutes
        .or_else(|| tz_offset_minutes_for_day_local(&week_start))
        .unwrap_or(0)
        .clamp(TZ_OFFSET_MINUTES_MIN, TZ_OFFSET_MINUTES_MAX);

    let res = match generate_weekly_report(
        &state,
        &report_settings,
        &week_start,
        &week_end,
        tz_offset_minutes,
        req.force,
    )
    .await
    {
        Ok(r) => r,
        Err(err) => {
            error!("generate_weekly_report failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "internal_error",
                }),
            )
                .into_response();
        }
    };

    Json(OkResponse {
        ok: true,
        data: Some(res),
    })
    .into_response()
}

async fn get_report_by_id(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let id = id.trim().to_string();
    if id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "invalid_id",
            }),
        )
            .into_response();
    }

    let mut conn = state.conn.lock().await;
    match get_report(&mut conn, &id) {
        Ok(Some(r)) => Json(OkResponse {
            ok: true,
            data: Some(r),
        })
        .into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(ErrResponse {
                ok: false,
                error: "not_found",
            }),
        )
            .into_response(),
        Err(err) => {
            error!("get_report failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

async fn post_report(State(state): State<AppState>, Json(req): Json<ReportUpsert>) -> Response {
    let id = req.id.trim().to_string();
    if id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "invalid_id",
            }),
        )
            .into_response();
    }
    let kind = req.kind.trim().to_string();
    if !validate_report_kind(&kind) {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "invalid_kind",
            }),
        )
            .into_response();
    }
    let start = req.period_start.trim().to_string();
    let end = req.period_end.trim().to_string();
    if !validate_yyyy_mm_dd(&start) || !validate_yyyy_mm_dd(&end) || end < start {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "invalid_period",
            }),
        )
            .into_response();
    }

    let generated_at = req
        .generated_at
        .as_deref()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .unwrap_or_default()
        });

    let record = ReportRecord {
        id: id.clone(),
        kind,
        period_start: start,
        period_end: end,
        generated_at,
        provider_url: req
            .provider_url
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        model: req
            .model
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        prompt: req.prompt,
        input_json: req.input_json,
        output_md: req.output_md,
        error: req.error,
    };

    let mut conn = state.conn.lock().await;
    if let Err(err) = upsert_report(&mut conn, &record) {
        error!("upsert_report failed: {err}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrResponse {
                ok: false,
                error: "db_error",
            }),
        )
            .into_response();
    }

    match get_report(&mut conn, &id) {
        Ok(Some(r)) => Json(OkResponse {
            ok: true,
            data: Some(r),
        })
        .into_response(),
        Ok(None) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrResponse {
                ok: false,
                error: "db_error",
            }),
        )
            .into_response(),
        Err(err) => {
            error!("get_report after upsert failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

async fn delete_report(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let id = id.trim().to_string();
    if id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrResponse {
                ok: false,
                error: "invalid_id",
            }),
        )
            .into_response();
    }
    let mut conn = state.conn.lock().await;
    match delete_report_by_id(&mut conn, &id) {
        Ok(0) => (
            StatusCode::NOT_FOUND,
            Json(ErrResponse {
                ok: false,
                error: "not_found",
            }),
        )
            .into_response(),
        Ok(_) => Json(OkResponse::<Value> {
            ok: true,
            data: None,
        })
        .into_response(),
        Err(err) => {
            error!("delete_report_by_id failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrResponse {
                    ok: false,
                    error: "db_error",
                }),
            )
                .into_response()
        }
    }
}

fn blocked_sets(rules: &[PrivacyRuleRow]) -> (HashSet<String>, HashSet<String>) {
    let mut apps: HashSet<String> = HashSet::new();
    let mut domains: HashSet<String> = HashSet::new();
    for r in rules {
        if r.action != "drop" {
            continue;
        }
        if r.kind == "app" {
            let v = r.value.trim();
            if !v.is_empty() {
                apps.insert(v.to_string());
            }
        } else if r.kind == "domain" {
            let v = r.value.trim().to_lowercase();
            if !v.is_empty() {
                domains.insert(v);
            }
        }
    }
    (apps, domains)
}

fn block_summary_is_reviewed(b: &BlockSummary) -> bool {
    let Some(r) = &b.review else {
        return false;
    };
    block_is_reviewed(r)
}

fn render_prompt_template(template: &str, vars: &[(&str, &str)], json_text: &str) -> String {
    let mut out = template.to_string();
    for (k, v) in vars {
        out = out.replace(&format!("{{{{{k}}}}}"), v);
    }
    if out.contains("{{json}}") {
        out = out.replace("{{json}}", json_text);
        return out;
    }
    format!("{out}\n\nInput JSON:\n{json_text}")
}

fn extract_text_from_openai_compat_content(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.to_string()),
        Value::Array(arr) => {
            // Some providers (or future compat modes) return structured content parts:
            //   [{ "type": "text", "text": "..." }, ...]
            // We best-effort concatenate any textual fragments.
            let mut out = String::new();
            for it in arr {
                if let Some(s) = it.as_str() {
                    out.push_str(s);
                    continue;
                }
                let Some(obj) = it.as_object() else {
                    continue;
                };
                if let Some(s) = obj.get("text").and_then(|t| t.as_str()) {
                    out.push_str(s);
                    continue;
                }
                if let Some(s) = obj
                    .get("text")
                    .and_then(|t| t.get("value"))
                    .and_then(|t| t.as_str())
                {
                    out.push_str(s);
                    continue;
                }
                if let Some(s) = obj.get("content").and_then(|t| t.as_str()) {
                    out.push_str(s);
                    continue;
                }
            }
            if out.trim().is_empty() {
                None
            } else {
                Some(out)
            }
        }
        _ => None,
    }
}

fn strip_tag_blocks(input: &str, open: &str, close: &str) -> String {
    let mut s = input.to_string();
    loop {
        let Some(start) = s.find(open) else {
            break;
        };
        let search_from = start + open.len();
        let Some(rel_end) = s[search_from..].find(close) else {
            // No closing tag; remove the opening tag only.
            s.replace_range(start..search_from, "");
            break;
        };
        let end = search_from + rel_end + close.len();
        s.replace_range(start..end, "");
    }
    s
}

fn strip_wrapping_code_fence(input: &str) -> String {
    let t = input.trim();
    if !t.starts_with("```") {
        return t.to_string();
    }
    let Some(first_nl) = t.find('\n') else {
        return t.to_string();
    };
    let after_open = &t[first_nl + 1..];
    let after_open_trimmed = after_open.trim_end();
    if !after_open_trimmed.ends_with("```") {
        return t.to_string();
    }
    if let Some(close_start) = after_open_trimmed.rfind("\n```") {
        return after_open_trimmed[..close_start].trim().to_string();
    }
    // Body might be empty (```...\n```).
    let body = after_open_trimmed.trim_end_matches("```");
    body.trim().to_string()
}

fn extract_tag_block(input: &str, open: &str, close: &str) -> Option<String> {
    let t = input;
    let start = t.find(open)?;
    let search_from = start + open.len();
    let rel_end = t[search_from..].find(close)?;
    let end = search_from + rel_end;
    Some(t[search_from..end].to_string())
}

fn sanitize_llm_markdown_output(input: &str) -> String {
    let mut s = input.to_string();

    // Some chain-of-thought models output <final>...</final>. If present, prefer the final block.
    if let Some(final_block) = extract_tag_block(&s, "<final>", "</final>") {
        s = final_block;
    }

    // Common reasoning tags used by some chain-of-thought models.
    s = strip_tag_blocks(&s, "<think>", "</think>");
    s = strip_tag_blocks(&s, "<analysis>", "</analysis>");

    // Some providers wrap the whole result in a single code fence.
    s = strip_wrapping_code_fence(&s);

    s.trim().to_string()
}

async fn openai_chat_completions_markdown(
    cfg: &ReportSettings,
    prompt: &str,
    max_tokens: i64,
) -> anyhow::Result<String> {
    let base = cfg.api_base_url.trim().trim_end_matches('/');
    let url = format!("{base}/chat/completions");
    let api_key = cfg.api_key.trim();
    let model = cfg.model.trim();

    let body = json!({
      "model": model,
      "messages": [
        {
          "role": "system",
          "content": "You are a strict personal review assistant. Output ONLY the final Markdown. Do NOT include any reasoning, scratchpad, <think>/<analysis> tags, or code fences.",
        },
        { "role": "user", "content": prompt },
      ],
      "temperature": 0.2,
      "max_tokens": max_tokens,
    });

    let client = reqwest::Client::new();
    let mut req = client
        .post(url)
        .header("content-type", "application/json")
        .json(&body);
    if !api_key.is_empty() {
        req = req.bearer_auth(api_key);
    }
    let res = req.send().await?;
    let status = res.status();
    if !status.is_success() {
        return Err(anyhow::anyhow!("http_{}", status.as_u16()));
    }

    let v: Value = res.json().await?;
    let raw = v
        .get("choices")
        .and_then(|c| c.get(0))
        .and_then(|c0| {
            c0.get("message")
                .and_then(|m| m.get("content"))
                .and_then(extract_text_from_openai_compat_content)
                .or_else(|| {
                    // Some compat providers might still return `text`.
                    c0.get("text")
                        .and_then(extract_text_from_openai_compat_content)
                })
        })
        .or_else(|| {
            // Some compat providers might still return `text` at the choice level.
            v.get("choices")
                .and_then(|c| c.get(0))
                .and_then(|c0| c0.get("text"))
                .and_then(extract_text_from_openai_compat_content)
        })
        .ok_or_else(|| anyhow::anyhow!("missing_content"))?;

    let out = sanitize_llm_markdown_output(&raw);
    if out.trim().is_empty() {
        return Err(anyhow::anyhow!("empty_output"));
    }
    Ok(out)
}

fn resolve_reports_output_dir(state: &AppState, cfg: &ReportSettings) -> PathBuf {
    if let Some(dir) = cfg
        .output_dir
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        return PathBuf::from(dir);
    }
    state.data_dir.join("reports")
}

fn atomic_write_text(path: &std::path::Path, content: &str) -> anyhow::Result<()> {
    let parent = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    std::fs::create_dir_all(parent)?;

    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, content)?;
    if path.exists() {
        let _ = std::fs::remove_file(path);
    }
    std::fs::rename(&tmp, path)?;
    Ok(())
}

fn aggregate_top_from_segments(
    segments: &[TimelineSegment],
    store_titles: bool,
    audio: bool,
    blocked_apps: &HashSet<String>,
    blocked_domains: &HashSet<String>,
    limit: usize,
) -> Vec<Value> {
    #[derive(Clone)]
    struct Acc {
        kind: String,
        entity: String,
        label: String,
        subtitle: Option<String>,
        seconds: i64,
        blocked: bool,
        audio: bool,
    }

    let mut by_key: HashMap<String, Acc> = HashMap::new();

    for s in segments {
        let is_audio = s.activity.as_deref() == Some("audio");
        if audio != is_audio {
            continue;
        }
        if s.kind != "app" && s.kind != "domain" {
            continue;
        }
        let raw_entity = s.entity.trim();
        if raw_entity.is_empty() {
            continue;
        }
        if s.seconds <= 0 {
            continue;
        }

        if s.kind == "domain" {
            let entity = raw_entity.to_lowercase();
            let title_norm = s
                .title
                .as_deref()
                .map(|t| normalize_web_title(&entity, t))
                .unwrap_or_default();
            let (label, subtitle, key) = if store_titles && !title_norm.trim().is_empty() {
                let label = title_norm.trim().to_string();
                let key = format!("domain|{entity}|{label}");
                (label, Some(entity.clone()), key)
            } else {
                let label = display_entity(&entity);
                let key = format!("domain|{entity}");
                (label, None, key)
            };
            let blocked = is_blocked_domain(&entity, blocked_domains);

            by_key
                .entry(key)
                .and_modify(|a| a.seconds += s.seconds)
                .or_insert_with(|| Acc {
                    kind: "domain".to_string(),
                    entity,
                    label,
                    subtitle,
                    seconds: s.seconds,
                    blocked,
                    audio,
                });
        } else {
            let entity = raw_entity.to_string();
            let label = display_entity(&entity);
            let subtitle = if store_titles {
                if is_browser_app(&entity) {
                    None
                } else {
                    let t = s.title.as_deref().unwrap_or("").trim();
                    if t.is_empty() {
                        None
                    } else {
                        let is_vscode = entity
                            .rsplit(['\\', '/'])
                            .next()
                            .unwrap_or(entity.as_str())
                            .eq_ignore_ascii_case("code.exe");
                        if is_vscode {
                            extract_vscode_workspace(t)
                                .map(|ws| format!("Workspace: {ws}"))
                                .or_else(|| Some(t.to_string()))
                        } else {
                            Some(t.to_string())
                        }
                    }
                }
            } else {
                None
            };
            let blocked = blocked_apps.contains(&entity);
            let key = format!("app|{entity}");

            by_key
                .entry(key)
                .and_modify(|a| a.seconds += s.seconds)
                .or_insert_with(|| Acc {
                    kind: "app".to_string(),
                    entity,
                    label,
                    subtitle,
                    seconds: s.seconds,
                    blocked,
                    audio,
                });
        }
    }

    let mut items: Vec<Acc> = by_key.into_values().collect();
    items.sort_by(|a, b| b.seconds.cmp(&a.seconds));
    items.truncate(limit);

    items
        .into_iter()
        .map(|it| {
            json!({
              "kind": it.kind,
              "entity": it.entity,
              "label": it.label,
              "subtitle": it.subtitle,
              "seconds": it.seconds,
              "blocked": it.blocked,
              "audio": it.audio,
            })
        })
        .collect()
}

async fn generate_daily_report(
    state: &AppState,
    cfg: &ReportSettings,
    date_local: &str,
    tz_offset_minutes: i32,
    force: bool,
) -> anyhow::Result<ReportRecord> {
    let date = date_local.trim();
    let report_id = report_id_daily(date);

    if !force {
        let mut conn = state.conn.lock().await;
        if let Ok(Some(existing)) = get_report(&mut conn, &report_id) {
            if report_is_good(&existing) {
                return Ok(existing);
            }
        }
    }

    let tz_offset = tz_offset_from_minutes(tz_offset_minutes);
    let day_start = parse_day_start_utc_for_offset(date, tz_offset)
        .map_err(|_| anyhow::anyhow!("invalid_date"))?;
    let day_end = day_start + time::Duration::days(1);
    let now = OffsetDateTime::now_utc().min(day_end);

    // Load DB data needed for input JSON.
    let (settings, rules, blocks, segments, todos) = {
        let settings = { *state.settings.lock().await };
        let mut conn = state.conn.lock().await;
        let rules = list_privacy_rules(&mut conn).unwrap_or_default();
        let todos = list_report_todos(&mut conn, 300).unwrap_or_default();
        let privacy = PrivacyIndex::load(&mut conn).unwrap_or_default();
        let events = list_events_between(&mut conn, day_start, day_end, &privacy)?;
        let blocks = attach_reviews(&mut conn, build_blocks(&events, settings, now))?;
        let segments = build_timeline_segments(&events, settings, now);
        (settings, rules, blocks, segments, todos)
    };

    let focus_seconds: i64 = segments
        .iter()
        .filter(|s| s.activity.as_deref() != Some("audio"))
        .map(|s| s.seconds)
        .sum();
    let audio_seconds: i64 = segments
        .iter()
        .filter(|s| s.activity.as_deref() == Some("audio"))
        .map(|s| s.seconds)
        .sum();

    let reviewed = blocks
        .iter()
        .filter(|b| block_summary_is_reviewed(b))
        .count() as i64;
    let skipped = blocks
        .iter()
        .filter(|b| b.review.as_ref().map(|r| r.skipped).unwrap_or(false))
        .count() as i64;
    let pending = (blocks.len() as i64).saturating_sub(reviewed);

    let last_activity_ts_local: Option<String> = segments
        .iter()
        .filter_map(|s| OffsetDateTime::parse(&s.end_ts, &Rfc3339).ok())
        .max()
        .map(|t| t.to_offset(tz_offset).format(&Rfc3339).unwrap_or_default());

    let (blocked_apps, blocked_domains) = blocked_sets(&rules);
    let mut blocked_apps_list: Vec<String> = blocked_apps.iter().cloned().collect();
    blocked_apps_list.sort();
    let mut blocked_domains_list: Vec<String> = blocked_domains.iter().cloned().collect();
    blocked_domains_list.sort();
    let top_focus = aggregate_top_from_segments(
        &segments,
        settings.store_titles,
        false,
        &blocked_apps,
        &blocked_domains,
        15,
    );
    let top_audio = aggregate_top_from_segments(
        &segments,
        settings.store_titles,
        true,
        &blocked_apps,
        &blocked_domains,
        10,
    );

    let top1_seconds = top_focus
        .get(0)
        .and_then(|v| v.get("seconds"))
        .and_then(|n| n.as_i64())
        .unwrap_or(0);
    let top1_share = if focus_seconds <= 0 {
        0.0
    } else {
        (top1_seconds as f64) / (focus_seconds as f64)
    };

    // Derived stats to help LLM produce richer, data-grounded insights.
    let focus_segments_count = segments
        .iter()
        .filter(|s| s.activity.as_deref() != Some("audio"))
        .count() as i64;
    let audio_segments_count = segments
        .iter()
        .filter(|s| s.activity.as_deref() == Some("audio"))
        .count() as i64;

    let tz_offset_seconds = (tz_offset_minutes as i64) * 60;
    let mut focus_by_hour_seconds = [0i64; 24];
    let mut audio_by_hour_seconds = [0i64; 24];

    let mut focus_context_switches: i64 = 0;
    let mut focus_unique_contexts: HashSet<String> = HashSet::new();
    let mut audio_unique_contexts: HashSet<String> = HashSet::new();
    let mut last_focus_key: Option<String> = None;

    let mut blocked_focus_seconds: i64 = 0;
    let mut blocked_audio_seconds: i64 = 0;

    let mut longest_focus: Option<&TimelineSegment> = None;
    let mut longest_audio: Option<&TimelineSegment> = None;

    for s in &segments {
        let is_audio = s.activity.as_deref() == Some("audio");

        let key = if s.kind == "domain" {
            format!("domain|{}", s.entity.trim().to_lowercase())
        } else if s.kind == "app" {
            format!("app|{}", s.entity.trim())
        } else {
            format!("{}|{}", s.kind.trim(), s.entity.trim())
        };

        if is_audio {
            audio_unique_contexts.insert(key.clone());
            if longest_audio.map(|x| x.seconds).unwrap_or(0) < s.seconds {
                longest_audio = Some(s);
            }
        } else {
            focus_unique_contexts.insert(key.clone());
            if let Some(prev) = &last_focus_key {
                if prev != &key {
                    focus_context_switches += 1;
                }
            }
            last_focus_key = Some(key.clone());
            if longest_focus.map(|x| x.seconds).unwrap_or(0) < s.seconds {
                longest_focus = Some(s);
            }
        }

        let blocked = if s.kind == "domain" {
            is_blocked_domain(&s.entity, &blocked_domains)
        } else if s.kind == "app" {
            blocked_apps.contains(s.entity.trim())
        } else {
            false
        };
        if blocked {
            if is_audio {
                blocked_audio_seconds += s.seconds;
            } else {
                blocked_focus_seconds += s.seconds;
            }
        }

        let (Ok(st), Ok(en)) = (
            OffsetDateTime::parse(&s.start_ts, &Rfc3339),
            OffsetDateTime::parse(&s.end_ts, &Rfc3339),
        ) else {
            continue;
        };
        if en <= st {
            continue;
        }

        let mut cur = st.unix_timestamp() + tz_offset_seconds;
        let end = en.unix_timestamp() + tz_offset_seconds;
        let bins = if is_audio {
            &mut audio_by_hour_seconds
        } else {
            &mut focus_by_hour_seconds
        };
        while cur < end {
            let hour = ((cur.rem_euclid(86400)) / 3600) as usize;
            let next_boundary = (cur.div_euclid(3600) + 1) * 3600;
            let slice_end = next_boundary.min(end);
            let delta = slice_end - cur;
            if hour < 24 && delta > 0 {
                bins[hour] += delta;
            }
            cur = slice_end;
        }
    }

    let focus_peak_hour = focus_by_hour_seconds
        .iter()
        .enumerate()
        .max_by_key(|(_, v)| *v)
        .map(|(h, v)| json!({ "hour": h, "seconds": *v }));
    let audio_peak_hour = audio_by_hour_seconds
        .iter()
        .enumerate()
        .max_by_key(|(_, v)| *v)
        .map(|(h, v)| json!({ "hour": h, "seconds": *v }));

    let mut focus_top_hours: Vec<(usize, i64, i64)> = (0..24)
        .map(|h| (h, focus_by_hour_seconds[h], audio_by_hour_seconds[h]))
        .collect();
    focus_top_hours.sort_by(|a, b| b.1.cmp(&a.1));
    let focus_top_hours_json: Vec<Value> = focus_top_hours
        .into_iter()
        .filter(|(_, focus_s, _)| *focus_s > 0)
        .take(6)
        .map(|(hour, focus_s, audio_s)| {
            json!({
              "hour": hour,
              "focus_seconds": focus_s,
              "audio_seconds": audio_s,
            })
        })
        .collect();

    let todos_open_count = todos.iter().filter(|t| !t.done).count();
    let todos_done_count = todos.iter().filter(|t| t.done).count();
    let todos_open: Vec<Value> = todos
        .iter()
        .filter(|t| !t.done)
        .take(30)
        .map(|t| {
            json!({
              "id": t.id,
              "content": t.content,
              "due_date": t.due_date,
              "start_ts": t.start_ts,
              "end_ts": t.end_ts,
              "created_at": t.created_at,
              "updated_at": t.updated_at,
            })
        })
        .collect();
    let todos_done_recent: Vec<Value> = todos
        .iter()
        .filter(|t| t.done)
        .take(15)
        .map(|t| {
            json!({
              "id": t.id,
              "content": t.content,
              "due_date": t.due_date,
              "start_ts": t.start_ts,
              "end_ts": t.end_ts,
              "done_at": t.done_at,
              "updated_at": t.updated_at,
            })
        })
        .collect();

    let longest_focus_json = longest_focus.map(|s| {
        json!({
          "kind": s.kind,
          "entity": s.entity,
          "title": s.title,
          "seconds": s.seconds,
          "start_ts": s.start_ts,
          "end_ts": s.end_ts,
        })
    });
    let longest_audio_json = longest_audio.map(|s| {
        json!({
          "kind": s.kind,
          "entity": s.entity,
          "title": s.title,
          "seconds": s.seconds,
          "start_ts": s.start_ts,
          "end_ts": s.end_ts,
        })
    });

    let blocks_json: Vec<Value> = blocks
        .iter()
        .map(|b| {
            let top_items: Vec<Value> = b
                .top_items
                .iter()
                .take(6)
                .map(|it| {
                    json!({
                      "kind": it.kind,
                      "entity": it.entity,
                      "title": it.title,
                      "seconds": it.seconds,
                    })
                })
                .collect();

            let bg_items: Vec<Value> = b
                .background_top_items
                .iter()
                .take(4)
                .map(|it| {
                    json!({
                      "kind": it.kind,
                      "entity": it.entity,
                      "title": it.title,
                      "seconds": it.seconds,
                    })
                })
                .collect();

            let review = b.review.as_ref().map(|r| {
                json!({
                  "skipped": r.skipped,
                  "skip_reason": r.skip_reason,
                  "doing": r.doing,
                  "output": r.output,
                  "next": r.next,
                  "tags": r.tags,
                  "updated_at": r.updated_at,
                })
            });

            json!({
              "id": b.id,
              "start_ts": b.start_ts,
              "end_ts": b.end_ts,
              "total_seconds": b.total_seconds,
              "top_items": top_items,
              "background_seconds": b.background_seconds,
              "background_top_items": bg_items,
              "review": review,
            })
        })
        .collect();

    let daily_csv = if cfg.save_csv {
        Some(export_csv(date, &blocks))
    } else {
        None
    };

    let input = json!({
      "schema": "recorderphone_report_v1",
      "kind": "daily",
      "date": date,
      "tz_offset_minutes": tz_offset_minutes,
      "privacy_level": privacy_level_label(settings),
      "settings": {
        "block_seconds": settings.block_seconds,
        "idle_cutoff_seconds": settings.idle_cutoff_seconds,
        "store_titles": settings.store_titles,
        "store_exe_path": settings.store_exe_path,
      },
      "stats": {
        "focus_seconds": focus_seconds,
        "audio_seconds": audio_seconds,
        "focus_segments": focus_segments_count,
        "audio_segments": audio_segments_count,
        "focus_unique_contexts": focus_unique_contexts.len(),
        "audio_unique_contexts": audio_unique_contexts.len(),
        "focus_context_switches": focus_context_switches,
        "blocked_focus_seconds": blocked_focus_seconds,
        "blocked_audio_seconds": blocked_audio_seconds,
        "focus_by_hour_seconds": focus_by_hour_seconds,
        "audio_by_hour_seconds": audio_by_hour_seconds,
        "focus_peak_hour": focus_peak_hour,
        "audio_peak_hour": audio_peak_hour,
        "focus_top_hours": focus_top_hours_json,
        "longest_focus_segment": longest_focus_json,
        "longest_audio_segment": longest_audio_json,
        "blocks_total": blocks.len(),
        "blocks_reviewed": reviewed,
        "blocks_pending": pending,
        "blocks_skipped": skipped,
        "top1_seconds": top1_seconds,
        "top1_share": top1_share,
        "last_activity_ts_local": last_activity_ts_local,
      },
      "blacklist": {
        "apps": blocked_apps_list,
        "domains": blocked_domains_list,
      },
      "todo": {
        "open_count": todos_open_count,
        "done_count": todos_done_count,
        "open": todos_open,
        "done_recent": todos_done_recent,
      },
      "top_focus": top_focus,
      "top_audio": top_audio,
      "blocks": blocks_json,
    });

    let input_json = serde_json::to_string_pretty(&input)?;
    let prompt = render_prompt_template(&cfg.daily_prompt, &[("date", date)], &input_json);

    let generated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_default();
    let provider_url = cfg.api_base_url.trim().to_string();
    let model = cfg.model.trim().to_string();

    match openai_chat_completions_markdown(cfg, &prompt, 1400).await {
        Ok(output_md) => {
            let record = ReportRecord {
                id: report_id.clone(),
                kind: "daily".to_string(),
                period_start: date.to_string(),
                period_end: date.to_string(),
                generated_at,
                provider_url: Some(provider_url),
                model: Some(model),
                prompt: Some(cfg.daily_prompt.clone()),
                input_json: Some(input_json),
                output_md: Some(output_md),
                error: None,
            };

            {
                let mut conn = state.conn.lock().await;
                upsert_report(&mut conn, &record)?;
            }
            let out_dir = resolve_reports_output_dir(state, cfg);
            if cfg.save_md {
                let p = out_dir.join(format!("report-daily-{date}.md"));
                if let Some(md) = record.output_md.as_deref() {
                    if let Err(e) = atomic_write_text(&p, format!("{}\n", md.trim_end()).as_str()) {
                        error!("write report md failed: {e}");
                    }
                }
            }
            if let Some(csv) = daily_csv.as_deref() {
                let p = out_dir.join(format!("report-daily-{date}.csv"));
                if let Err(e) = atomic_write_text(&p, csv) {
                    error!("write report csv failed: {e}");
                }
            }
            Ok(record)
        }
        Err(e) => {
            let err_s = e.to_string();
            let mut conn = state.conn.lock().await;
            let existing = get_report(&mut conn, &report_id).ok().flatten();
            let record = ReportRecord {
                id: report_id.clone(),
                kind: "daily".to_string(),
                period_start: date.to_string(),
                period_end: date.to_string(),
                generated_at,
                provider_url: Some(provider_url),
                model: Some(model),
                prompt: Some(cfg.daily_prompt.clone()),
                input_json: Some(input_json),
                output_md: existing.and_then(|r| r.output_md),
                error: Some(err_s),
            };
            upsert_report(&mut conn, &record)?;
            drop(conn);

            // Even if LLM fails, best-effort write the structured CSV if enabled.
            if let Some(csv) = daily_csv.as_deref() {
                let out_dir = resolve_reports_output_dir(state, cfg);
                let p = out_dir.join(format!("report-daily-{date}.csv"));
                if let Err(e) = atomic_write_text(&p, csv) {
                    error!("write report csv failed: {e}");
                }
            }
            Ok(record)
        }
    }
}

async fn generate_weekly_report(
    state: &AppState,
    cfg: &ReportSettings,
    week_start_local: &str,
    week_end_local: &str,
    tz_offset_minutes: i32,
    force: bool,
) -> anyhow::Result<ReportRecord> {
    let start = week_start_local.trim();
    let end = week_end_local.trim();
    let report_id = report_id_weekly(start, end);

    if !force {
        let mut conn = state.conn.lock().await;
        if let Ok(Some(existing)) = get_report(&mut conn, &report_id) {
            if report_is_good(&existing) {
                return Ok(existing);
            }
        }
    }

    let settings = { *state.settings.lock().await };
    let (blocked_apps, blocked_domains, todos) = {
        let mut conn = state.conn.lock().await;
        let rules = list_privacy_rules(&mut conn).unwrap_or_default();
        let todos = list_report_todos(&mut conn, 300).unwrap_or_default();
        let (apps, domains) = blocked_sets(&rules);
        (apps, domains, todos)
    };
    let mut blocked_apps_list: Vec<String> = blocked_apps.iter().cloned().collect();
    blocked_apps_list.sort();
    let mut blocked_domains_list: Vec<String> = blocked_domains.iter().cloned().collect();
    blocked_domains_list.sort();

    let mut weekly_csv = if cfg.save_csv {
        Some(String::new())
    } else {
        None
    };

    // Build per-day summaries + collect segments for weekly top.
    let mut daily: Vec<Value> = Vec::new();
    let mut all_segments: Vec<TimelineSegment> = Vec::new();
    let mut pending_blocks: Vec<Value> = Vec::new();

    // Iterate 7 days starting from Monday.
    use chrono::{Duration, NaiveDate};
    let parts: Vec<&str> = start.split('-').collect();
    let y: i32 = parts
        .get(0)
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| anyhow::anyhow!("invalid_week_start"))?;
    let m: u32 = parts
        .get(1)
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| anyhow::anyhow!("invalid_week_start"))?;
    let d: u32 = parts
        .get(2)
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| anyhow::anyhow!("invalid_week_start"))?;
    let week_start_day =
        NaiveDate::from_ymd_opt(y, m, d).ok_or_else(|| anyhow::anyhow!("invalid_week_start"))?;

    for i in 0..7 {
        let day = week_start_day + Duration::days(i);
        let date = day.format("%Y-%m-%d").to_string();
        let day_tz_offset_minutes =
            tz_offset_minutes_for_day_local(&date).unwrap_or(tz_offset_minutes);
        let tz_offset = tz_offset_from_minutes(day_tz_offset_minutes);
        let day_start = parse_day_start_utc_for_offset(&date, tz_offset)
            .map_err(|_| anyhow::anyhow!("invalid_date"))?;
        let day_end = day_start + time::Duration::days(1);
        let now = OffsetDateTime::now_utc().min(day_end);

        let (blocks, segments) = {
            let mut conn = state.conn.lock().await;
            let privacy = PrivacyIndex::load(&mut conn).unwrap_or_default();
            let events = list_events_between(&mut conn, day_start, day_end, &privacy)?;
            let blocks = attach_reviews(&mut conn, build_blocks(&events, settings, now))?;
            let segments = build_timeline_segments(&events, settings, now);
            (blocks, segments)
        };

        if let Some(buf) = weekly_csv.as_mut() {
            let day_csv = export_csv(&date, &blocks);
            if buf.is_empty() {
                buf.push_str(&day_csv);
            } else if let Some(pos) = day_csv.find('\n') {
                buf.push_str(&day_csv[(pos + 1)..]);
            }
        }

        let focus_seconds: i64 = segments
            .iter()
            .filter(|s| s.activity.as_deref() != Some("audio"))
            .map(|s| s.seconds)
            .sum();
        let audio_seconds: i64 = segments
            .iter()
            .filter(|s| s.activity.as_deref() == Some("audio"))
            .map(|s| s.seconds)
            .sum();
        let reviewed = blocks
            .iter()
            .filter(|b| block_summary_is_reviewed(b))
            .count() as i64;

        let top1 = aggregate_top_from_segments(
            &segments,
            settings.store_titles,
            false,
            &blocked_apps,
            &blocked_domains,
            1,
        );
        let top1_label = top1
            .get(0)
            .and_then(|v| v.get("label"))
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string();
        let top1_seconds = top1
            .get(0)
            .and_then(|v| v.get("seconds"))
            .and_then(|n| n.as_i64())
            .unwrap_or(0);
        let top1_share = if focus_seconds <= 0 {
            0.0
        } else {
            (top1_seconds as f64) / (focus_seconds as f64)
        };

        daily.push(json!({
          "date": date,
          "focus_seconds": focus_seconds,
          "audio_seconds": audio_seconds,
          "blocks_total": blocks.len(),
          "blocks_reviewed": reviewed,
          "top1": top1_label,
          "top1_share": top1_share,
        }));

        // Move segments into the weekly accumulator after all per-day stats are computed.
        all_segments.extend(segments);

        for b in blocks.iter() {
            if block_summary_is_reviewed(b) {
                continue;
            }
            if b.total_seconds < 5 * 60 {
                continue;
            }
            let top = b.top_items.get(0).map(|it| {
                if it.kind == "domain" {
                    let title = it.title.as_deref().unwrap_or("").trim();
                    if !title.is_empty() {
                        normalize_web_title(&it.entity.to_lowercase(), title)
                    } else {
                        display_entity(&it.entity)
                    }
                } else {
                    display_entity(&it.entity)
                }
            });

            let time_range = format!(
                "{}–{}",
                fmt_hhmm(&b.start_ts, tz_offset),
                fmt_hhmm(&b.end_ts, tz_offset)
            );
            pending_blocks.push(json!({
              "date": date,
              "block_id": b.id,
              "time_range": time_range,
              "top_focus": top,
              "focus_seconds": b.total_seconds,
            }));
        }
    }

    // Weekly top focus.
    let week_top = aggregate_top_from_segments(
        &all_segments,
        settings.store_titles,
        false,
        &blocked_apps,
        &blocked_domains,
        15,
    );

    let todos_open_count = todos.iter().filter(|t| !t.done).count();
    let todos_done_count = todos.iter().filter(|t| t.done).count();
    let todos_open: Vec<Value> = todos
        .iter()
        .filter(|t| !t.done)
        .take(30)
        .map(|t| {
            json!({
              "id": t.id,
              "content": t.content,
              "due_date": t.due_date,
              "start_ts": t.start_ts,
              "end_ts": t.end_ts,
              "created_at": t.created_at,
              "updated_at": t.updated_at,
            })
        })
        .collect();
    let todos_done_recent: Vec<Value> = todos
        .iter()
        .filter(|t| t.done)
        .take(15)
        .map(|t| {
            json!({
              "id": t.id,
              "content": t.content,
              "due_date": t.due_date,
              "start_ts": t.start_ts,
              "end_ts": t.end_ts,
              "done_at": t.done_at,
              "updated_at": t.updated_at,
            })
        })
        .collect();

    let input = json!({
      "schema": "recorderphone_report_v1",
      "kind": "weekly",
      "week_start": start,
      "week_end": end,
      "privacy_level": privacy_level_label(settings),
      "settings": {
        "block_seconds": settings.block_seconds,
        "idle_cutoff_seconds": settings.idle_cutoff_seconds,
        "store_titles": settings.store_titles,
        "store_exe_path": settings.store_exe_path,
      },
      "blacklist": {
        "apps": blocked_apps_list,
        "domains": blocked_domains_list,
      },
      "todo": {
        "open_count": todos_open_count,
        "done_count": todos_done_count,
        "open": todos_open,
        "done_recent": todos_done_recent,
      },
      "daily": daily,
      "top_focus_week": week_top,
      "pending_blocks": pending_blocks.into_iter().take(10).collect::<Vec<_>>(),
    });

    let input_json = serde_json::to_string_pretty(&input)?;
    let prompt = render_prompt_template(
        &cfg.weekly_prompt,
        &[("week_start", start), ("week_end", end)],
        &input_json,
    );

    let generated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_default();
    let provider_url = cfg.api_base_url.trim().to_string();
    let model = cfg.model.trim().to_string();

    match openai_chat_completions_markdown(cfg, &prompt, 1700).await {
        Ok(output_md) => {
            let record = ReportRecord {
                id: report_id.clone(),
                kind: "weekly".to_string(),
                period_start: start.to_string(),
                period_end: end.to_string(),
                generated_at,
                provider_url: Some(provider_url),
                model: Some(model),
                prompt: Some(cfg.weekly_prompt.clone()),
                input_json: Some(input_json),
                output_md: Some(output_md),
                error: None,
            };

            {
                let mut conn = state.conn.lock().await;
                upsert_report(&mut conn, &record)?;
            }

            let out_dir = resolve_reports_output_dir(state, cfg);
            if cfg.save_md {
                let p = out_dir.join(format!("report-weekly-{start}_to_{end}.md"));
                if let Some(md) = record.output_md.as_deref() {
                    if let Err(e) = atomic_write_text(&p, format!("{}\n", md.trim_end()).as_str()) {
                        error!("write report md failed: {e}");
                    }
                }
            }
            if let Some(csv) = weekly_csv.as_deref() {
                let p = out_dir.join(format!("report-weekly-{start}_to_{end}.csv"));
                if let Err(e) = atomic_write_text(&p, csv) {
                    error!("write report csv failed: {e}");
                }
            }
            Ok(record)
        }
        Err(e) => {
            let err_s = e.to_string();
            let mut conn = state.conn.lock().await;
            let existing = get_report(&mut conn, &report_id).ok().flatten();
            let record = ReportRecord {
                id: report_id.clone(),
                kind: "weekly".to_string(),
                period_start: start.to_string(),
                period_end: end.to_string(),
                generated_at,
                provider_url: Some(provider_url),
                model: Some(model),
                prompt: Some(cfg.weekly_prompt.clone()),
                input_json: Some(input_json),
                output_md: existing.and_then(|r| r.output_md),
                error: Some(err_s),
            };
            upsert_report(&mut conn, &record)?;
            drop(conn);

            // Best-effort CSV export even when LLM fails.
            if let Some(csv) = weekly_csv.as_deref() {
                let out_dir = resolve_reports_output_dir(state, cfg);
                let p = out_dir.join(format!("report-weekly-{start}_to_{end}.csv"));
                if let Err(e) = atomic_write_text(&p, csv) {
                    error!("write report csv failed: {e}");
                }
            }
            Ok(record)
        }
    }
}

async fn report_scheduler_loop(state: AppState) {
    use chrono::{Datelike, Duration as ChronoDuration, Local, TimeZone, Timelike};
    use std::collections::HashMap;
    use std::time::{Duration, Instant};
    use tokio::time::sleep;

    let mut last_attempt: HashMap<String, Instant> = HashMap::new();
    let tick = Duration::from_secs(30);

    loop {
        let cfg = { state.report_settings.lock().await.clone() };
        if report_settings_is_configured(&cfg) {
            // Daily: generate yesterday after local time >= daily_at_minutes.
            if cfg.daily_enabled {
                let now = Local::now();
                let minutes_now = (now.hour() as i64) * 60 + (now.minute() as i64);
                if minutes_now >= cfg.daily_at_minutes.clamp(0, 1439) {
                    let target = (now - ChronoDuration::days(1))
                        .format("%Y-%m-%d")
                        .to_string();
                    let rid = report_id_daily(&target);

                    let needs = {
                        let mut conn = state.conn.lock().await;
                        match get_report(&mut conn, &rid) {
                            Ok(Some(r)) => !report_is_good(&r),
                            Ok(None) => true,
                            Err(_) => true,
                        }
                    };

                    if needs {
                        let cooldown = Duration::from_secs(60 * 60);
                        let now_i = Instant::now();
                        let throttled = last_attempt
                            .get(&rid)
                            .map(|t| now_i.duration_since(*t) < cooldown)
                            .unwrap_or(false);
                        if !throttled {
                            last_attempt.insert(rid.clone(), now_i);
                            let tz = tz_offset_minutes_for_day_local(&target).unwrap_or(0);
                            let _ = generate_daily_report(&state, &cfg, &target, tz, false).await;
                        }
                    }
                }
            }

            // Weekly: generate last week after local time >= (weekday + at_minutes) in current week.
            if cfg.weekly_enabled {
                let now = Local::now();
                let weekday_now = now.weekday().number_from_monday() as i64; // 1..7
                let start_of_week = now.date_naive() - ChronoDuration::days(weekday_now - 1);
                let scheduled_weekday = (cfg.weekly_weekday as i64).clamp(1, 7);
                let due_date = start_of_week + ChronoDuration::days(scheduled_weekday - 1);
                let due_minutes = cfg.weekly_at_minutes.clamp(0, 1439);
                let due_h = (due_minutes / 60) as u32;
                let due_m = (due_minutes % 60) as u32;
                let due_naive = match due_date.and_hms_opt(due_h, due_m, 0) {
                    Some(v) => v,
                    None => {
                        sleep(tick).await;
                        continue;
                    }
                };
                let Some(due_local) = Local.from_local_datetime(&due_naive).single() else {
                    sleep(tick).await;
                    continue;
                };

                if now >= due_local {
                    let last_week_start = start_of_week - ChronoDuration::days(7);
                    let last_week_end = last_week_start + ChronoDuration::days(6);
                    let start = last_week_start.format("%Y-%m-%d").to_string();
                    let end = last_week_end.format("%Y-%m-%d").to_string();
                    let rid = report_id_weekly(&start, &end);

                    let needs = {
                        let mut conn = state.conn.lock().await;
                        match get_report(&mut conn, &rid) {
                            Ok(Some(r)) => !report_is_good(&r),
                            Ok(None) => true,
                            Err(_) => true,
                        }
                    };

                    if needs {
                        let cooldown = Duration::from_secs(6 * 60 * 60);
                        let now_i = Instant::now();
                        let throttled = last_attempt
                            .get(&rid)
                            .map(|t| now_i.duration_since(*t) < cooldown)
                            .unwrap_or(false);
                        if !throttled {
                            last_attempt.insert(rid.clone(), now_i);
                            let tz = tz_offset_minutes_for_day_local(&start).unwrap_or(0);
                            let _ =
                                generate_weekly_report(&state, &cfg, &start, &end, tz, false).await;
                        }
                    }
                }
            }
        }

        sleep(tick).await;
    }
}

fn init_db(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        r#"
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  source TEXT NOT NULL,
  event TEXT NOT NULL,
  entity TEXT,
  title TEXT,
  payload_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_event_ts ON events(event, ts);

CREATE TABLE IF NOT EXISTS block_reviews (
  block_id TEXT PRIMARY KEY,
  skipped INTEGER NOT NULL DEFAULT 0,
  skip_reason TEXT,
  doing TEXT,
  output TEXT,
  next TEXT,
  tags_json TEXT,
  updated_at TEXT NOT NULL
);

	CREATE TABLE IF NOT EXISTS app_settings (
	  id INTEGER PRIMARY KEY CHECK (id = 1),
	  block_seconds INTEGER NOT NULL,
	  idle_cutoff_seconds INTEGER NOT NULL,
	  store_titles INTEGER NOT NULL DEFAULT 0,
	  store_exe_path INTEGER NOT NULL DEFAULT 0,
	  review_min_seconds INTEGER NOT NULL DEFAULT 300,
	  review_notify_repeat_minutes INTEGER NOT NULL DEFAULT 10,
	  review_notify_when_paused INTEGER NOT NULL DEFAULT 0,
	  review_notify_when_idle INTEGER NOT NULL DEFAULT 0,
	  updated_at TEXT NOT NULL
	);

CREATE TABLE IF NOT EXISTS privacy_rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  value TEXT NOT NULL,
  action TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(kind, value)
);
CREATE INDEX IF NOT EXISTS idx_privacy_rules_kind_value ON privacy_rules(kind, value);

CREATE TABLE IF NOT EXISTS tracking_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  paused INTEGER NOT NULL DEFAULT 0,
  paused_until_ts TEXT,
  updated_at TEXT NOT NULL
);
INSERT INTO tracking_state (id, paused, paused_until_ts, updated_at)
VALUES (1, 0, NULL, '1970-01-01T00:00:00Z')
ON CONFLICT(id) DO NOTHING;

CREATE TABLE IF NOT EXISTS report_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  enabled INTEGER NOT NULL DEFAULT 0,
  api_base_url TEXT NOT NULL DEFAULT '',
  api_key TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT '',
  daily_enabled INTEGER NOT NULL DEFAULT 0,
  daily_at_minutes INTEGER NOT NULL DEFAULT 10,
  daily_prompt TEXT NOT NULL DEFAULT '',
  weekly_enabled INTEGER NOT NULL DEFAULT 0,
  weekly_weekday INTEGER NOT NULL DEFAULT 1,
  weekly_at_minutes INTEGER NOT NULL DEFAULT 20,
  weekly_prompt TEXT NOT NULL DEFAULT '',
  save_md INTEGER NOT NULL DEFAULT 1,
  save_csv INTEGER NOT NULL DEFAULT 0,
  output_dir TEXT,
  updated_at TEXT NOT NULL
);
INSERT INTO report_settings (
  id, enabled, api_base_url, api_key, model,
  daily_enabled, daily_at_minutes, daily_prompt,
  weekly_enabled, weekly_weekday, weekly_at_minutes, weekly_prompt,
  save_md, save_csv, output_dir, updated_at
)
VALUES (1, 0, '', '', '', 0, 10, '', 0, 1, 20, '', 1, 0, NULL, '1970-01-01T00:00:00Z')
ON CONFLICT(id) DO NOTHING;

CREATE TABLE IF NOT EXISTS reports (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  period_start TEXT NOT NULL,
  period_end TEXT NOT NULL,
  generated_at TEXT NOT NULL,
  provider_url TEXT,
  model TEXT,
  prompt TEXT,
  input_json TEXT,
  output_md TEXT,
  error TEXT
);
CREATE INDEX IF NOT EXISTS idx_reports_kind_end ON reports(kind, period_end);

CREATE TABLE IF NOT EXISTS report_todos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  content TEXT NOT NULL,
  done INTEGER NOT NULL DEFAULT 0,
  due_date TEXT,
  start_ts TEXT,
  end_ts TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  done_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_report_todos_done_updated ON report_todos(done, updated_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_report_todos_due_date ON report_todos(due_date, done, updated_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_report_todos_start_ts ON report_todos(start_ts, done, updated_at DESC, id DESC);
"#,
    )?;
    ensure_app_settings_columns(conn)?;
    ensure_block_reviews_columns(conn)?;
    ensure_report_todos_columns(conn)?;
    Ok(())
}

fn ensure_app_settings_columns(conn: &Connection) -> rusqlite::Result<()> {
    let mut stmt = conn.prepare("PRAGMA table_info(app_settings)")?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
    let mut cols: HashSet<String> = HashSet::new();
    for r in rows {
        cols.insert(r?);
    }

    if !cols.contains("store_titles") {
        conn.execute(
            "ALTER TABLE app_settings ADD COLUMN store_titles INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }
    if !cols.contains("store_exe_path") {
        conn.execute(
            "ALTER TABLE app_settings ADD COLUMN store_exe_path INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }
    if !cols.contains("review_min_seconds") {
        conn.execute(
            "ALTER TABLE app_settings ADD COLUMN review_min_seconds INTEGER NOT NULL DEFAULT 300",
            [],
        )?;
    }
    if !cols.contains("review_notify_repeat_minutes") {
        conn.execute(
            "ALTER TABLE app_settings ADD COLUMN review_notify_repeat_minutes INTEGER NOT NULL DEFAULT 10",
            [],
        )?;
    }
    if !cols.contains("review_notify_when_paused") {
        conn.execute(
            "ALTER TABLE app_settings ADD COLUMN review_notify_when_paused INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }
    if !cols.contains("review_notify_when_idle") {
        conn.execute(
            "ALTER TABLE app_settings ADD COLUMN review_notify_when_idle INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }

    Ok(())
}

fn ensure_block_reviews_columns(conn: &Connection) -> rusqlite::Result<()> {
    let mut stmt = conn.prepare("PRAGMA table_info(block_reviews)")?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
    let mut cols: HashSet<String> = HashSet::new();
    for r in rows {
        cols.insert(r?);
    }

    if !cols.contains("skipped") {
        conn.execute(
            "ALTER TABLE block_reviews ADD COLUMN skipped INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }
    if !cols.contains("skip_reason") {
        conn.execute("ALTER TABLE block_reviews ADD COLUMN skip_reason TEXT", [])?;
    }

    Ok(())
}

fn ensure_report_todos_columns(conn: &Connection) -> rusqlite::Result<()> {
    let mut stmt = conn.prepare("PRAGMA table_info(report_todos)")?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
    let mut cols: HashSet<String> = HashSet::new();
    for r in rows {
        cols.insert(r?);
    }

    if !cols.contains("due_date") {
        conn.execute("ALTER TABLE report_todos ADD COLUMN due_date TEXT", [])?;
    }
    if !cols.contains("start_ts") {
        conn.execute("ALTER TABLE report_todos ADD COLUMN start_ts TEXT", [])?;
    }
    if !cols.contains("end_ts") {
        conn.execute("ALTER TABLE report_todos ADD COLUMN end_ts TEXT", [])?;
    }

    Ok(())
}

fn looks_like_legacy_daily_prompt(raw: &str) -> bool {
    raw.contains("目标：把 {{date}} 的使用记录整理成可直接贴到笔记里的“日报表格”")
        && raw.contains("洞察与建议：3~6 条 bullet")
}

fn looks_like_legacy_weekly_prompt(raw: &str) -> bool {
    raw.contains("目标：把 {{week_start}}~{{week_end}} 的记录整理成“周报表格 + 下周实验建议”")
        && raw.contains("下周建议（3~5 条 bullet，以 “Action:” 开头）")
}

fn load_or_init_settings(conn: &mut Connection, defaults: Settings) -> rusqlite::Result<Settings> {
    if let Some(settings) = load_app_settings(conn)? {
        let fixed = Settings {
            block_seconds: settings.block_seconds.max(60),
            idle_cutoff_seconds: settings.idle_cutoff_seconds.max(10),
            store_titles: settings.store_titles,
            store_exe_path: settings.store_exe_path,
            review_min_seconds: settings
                .review_min_seconds
                .clamp(REVIEW_MIN_SECONDS_MIN, REVIEW_MIN_SECONDS_MAX),
            review_notify_repeat_minutes: settings.review_notify_repeat_minutes.clamp(
                REVIEW_NOTIFY_REPEAT_MINUTES_MIN,
                REVIEW_NOTIFY_REPEAT_MINUTES_MAX,
            ),
            review_notify_when_paused: settings.review_notify_when_paused,
            review_notify_when_idle: settings.review_notify_when_idle,
        };
        if fixed != settings {
            let updated_at = OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .unwrap_or_default();
            upsert_app_settings(conn, fixed, &updated_at)?;
        }
        return Ok(fixed);
    }

    let fixed = Settings {
        block_seconds: defaults.block_seconds.max(60),
        idle_cutoff_seconds: defaults.idle_cutoff_seconds.max(10),
        store_titles: defaults.store_titles,
        store_exe_path: defaults.store_exe_path,
        review_min_seconds: defaults
            .review_min_seconds
            .clamp(REVIEW_MIN_SECONDS_MIN, REVIEW_MIN_SECONDS_MAX),
        review_notify_repeat_minutes: defaults.review_notify_repeat_minutes.clamp(
            REVIEW_NOTIFY_REPEAT_MINUTES_MIN,
            REVIEW_NOTIFY_REPEAT_MINUTES_MAX,
        ),
        review_notify_when_paused: defaults.review_notify_when_paused,
        review_notify_when_idle: defaults.review_notify_when_idle,
    };
    let updated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_default();
    upsert_app_settings(conn, fixed, &updated_at)?;
    Ok(fixed)
}

fn load_or_init_report_settings(conn: &mut Connection) -> rusqlite::Result<ReportSettings> {
    let now = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_default();
    let defaults = ReportSettings::defaults(&now);

    if let Some(settings) = load_report_settings(conn)? {
        let fixed = ReportSettings {
            enabled: settings.enabled,
            api_base_url: {
                let v = settings.api_base_url.trim();
                if v.is_empty() {
                    defaults.api_base_url.clone()
                } else {
                    v.to_string()
                }
            },
            api_key: settings.api_key.trim().to_string(),
            model: {
                let v = settings.model.trim();
                if v.is_empty() {
                    defaults.model.clone()
                } else {
                    v.to_string()
                }
            },
            daily_enabled: settings.daily_enabled,
            daily_at_minutes: settings.daily_at_minutes.clamp(0, 1439),
            daily_prompt: {
                let v = settings.daily_prompt.trim();
                if v.is_empty() || looks_like_legacy_daily_prompt(v) {
                    defaults.daily_prompt.clone()
                } else {
                    settings.daily_prompt.clone()
                }
            },
            weekly_enabled: settings.weekly_enabled,
            weekly_weekday: settings.weekly_weekday.clamp(1, 7),
            weekly_at_minutes: settings.weekly_at_minutes.clamp(0, 1439),
            weekly_prompt: {
                let v = settings.weekly_prompt.trim();
                if v.is_empty() || looks_like_legacy_weekly_prompt(v) {
                    defaults.weekly_prompt.clone()
                } else {
                    settings.weekly_prompt.clone()
                }
            },
            save_md: settings.save_md,
            save_csv: settings.save_csv,
            output_dir: settings
                .output_dir
                .as_deref()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
            updated_at: settings.updated_at.clone(),
        };

        if fixed != settings {
            upsert_report_settings(conn, &fixed)?;
            return Ok(fixed);
        }

        return Ok(settings);
    }

    upsert_report_settings(conn, &defaults)?;
    Ok(defaults)
}

fn load_app_settings(conn: &mut Connection) -> rusqlite::Result<Option<Settings>> {
    let mut stmt = conn.prepare(
        r#"
SELECT
  block_seconds,
  idle_cutoff_seconds,
  store_titles,
  store_exe_path,
  review_min_seconds,
  review_notify_repeat_minutes,
  review_notify_when_paused,
  review_notify_when_idle
FROM app_settings
WHERE id = 1
LIMIT 1
"#,
    )?;
    match stmt.query_row([], |row| {
        let store_titles: i64 = row.get(2)?;
        let store_exe_path: i64 = row.get(3)?;
        let review_notify_when_paused: i64 = row.get(6)?;
        let review_notify_when_idle: i64 = row.get(7)?;
        Ok(Settings {
            block_seconds: row.get(0)?,
            idle_cutoff_seconds: row.get(1)?,
            store_titles: store_titles != 0,
            store_exe_path: store_exe_path != 0,
            review_min_seconds: row.get(4)?,
            review_notify_repeat_minutes: row.get(5)?,
            review_notify_when_paused: review_notify_when_paused != 0,
            review_notify_when_idle: review_notify_when_idle != 0,
        })
    }) {
        Ok(v) => Ok(Some(v)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(err) => Err(err),
    }
}

fn load_report_settings(conn: &mut Connection) -> rusqlite::Result<Option<ReportSettings>> {
    let mut stmt = conn.prepare(
        r#"
SELECT
  enabled,
  api_base_url,
  api_key,
  model,
  daily_enabled,
  daily_at_minutes,
  daily_prompt,
  weekly_enabled,
  weekly_weekday,
  weekly_at_minutes,
  weekly_prompt,
  save_md,
  save_csv,
  output_dir,
  updated_at
FROM report_settings
WHERE id = 1
LIMIT 1
"#,
    )?;

    match stmt.query_row([], |row| {
        let enabled: i64 = row.get(0)?;
        let daily_enabled: i64 = row.get(4)?;
        let weekly_enabled: i64 = row.get(7)?;
        let save_md: i64 = row.get(11)?;
        let save_csv: i64 = row.get(12)?;

        Ok(ReportSettings {
            enabled: enabled != 0,
            api_base_url: row.get(1)?,
            api_key: row.get(2)?,
            model: row.get(3)?,
            daily_enabled: daily_enabled != 0,
            daily_at_minutes: row.get(5)?,
            daily_prompt: row.get(6)?,
            weekly_enabled: weekly_enabled != 0,
            weekly_weekday: row.get(8)?,
            weekly_at_minutes: row.get(9)?,
            weekly_prompt: row.get(10)?,
            save_md: save_md != 0,
            save_csv: save_csv != 0,
            output_dir: row.get(13)?,
            updated_at: row.get(14)?,
        })
    }) {
        Ok(v) => Ok(Some(v)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(err) => Err(err),
    }
}

fn upsert_report_settings(conn: &mut Connection, s: &ReportSettings) -> rusqlite::Result<()> {
    conn.execute(
        r#"
INSERT INTO report_settings (
  id,
  enabled, api_base_url, api_key, model,
  daily_enabled, daily_at_minutes, daily_prompt,
  weekly_enabled, weekly_weekday, weekly_at_minutes, weekly_prompt,
  save_md, save_csv, output_dir,
  updated_at
)
VALUES (
  1,
  ?1, ?2, ?3, ?4,
  ?5, ?6, ?7,
  ?8, ?9, ?10, ?11,
  ?12, ?13, ?14,
  ?15
)
ON CONFLICT(id) DO UPDATE SET
  enabled=excluded.enabled,
  api_base_url=excluded.api_base_url,
  api_key=excluded.api_key,
  model=excluded.model,
  daily_enabled=excluded.daily_enabled,
  daily_at_minutes=excluded.daily_at_minutes,
  daily_prompt=excluded.daily_prompt,
  weekly_enabled=excluded.weekly_enabled,
  weekly_weekday=excluded.weekly_weekday,
  weekly_at_minutes=excluded.weekly_at_minutes,
  weekly_prompt=excluded.weekly_prompt,
  save_md=excluded.save_md,
  save_csv=excluded.save_csv,
  output_dir=excluded.output_dir,
  updated_at=excluded.updated_at
"#,
        (
            if s.enabled { 1i64 } else { 0i64 },
            s.api_base_url.trim(),
            s.api_key.trim(),
            s.model.trim(),
            if s.daily_enabled { 1i64 } else { 0i64 },
            s.daily_at_minutes.clamp(0, 1439),
            s.daily_prompt.as_str(),
            if s.weekly_enabled { 1i64 } else { 0i64 },
            s.weekly_weekday.clamp(1, 7),
            s.weekly_at_minutes.clamp(0, 1439),
            s.weekly_prompt.as_str(),
            if s.save_md { 1i64 } else { 0i64 },
            if s.save_csv { 1i64 } else { 0i64 },
            s.output_dir.as_deref(),
            s.updated_at.as_str(),
        ),
    )?;
    Ok(())
}

fn upsert_app_settings(
    conn: &mut Connection,
    settings: Settings,
    updated_at: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        r#"
INSERT INTO app_settings (
  id,
  block_seconds,
  idle_cutoff_seconds,
  store_titles,
  store_exe_path,
  review_min_seconds,
  review_notify_repeat_minutes,
  review_notify_when_paused,
  review_notify_when_idle,
  updated_at
)
VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
ON CONFLICT(id) DO UPDATE SET
  block_seconds=excluded.block_seconds,
  idle_cutoff_seconds=excluded.idle_cutoff_seconds,
  store_titles=excluded.store_titles,
  store_exe_path=excluded.store_exe_path,
  review_min_seconds=excluded.review_min_seconds,
  review_notify_repeat_minutes=excluded.review_notify_repeat_minutes,
  review_notify_when_paused=excluded.review_notify_when_paused,
  review_notify_when_idle=excluded.review_notify_when_idle,
  updated_at=excluded.updated_at
        "#,
        (
            settings.block_seconds,
            settings.idle_cutoff_seconds,
            settings.store_titles as i64,
            settings.store_exe_path as i64,
            settings.review_min_seconds,
            settings.review_notify_repeat_minutes,
            if settings.review_notify_when_paused {
                1i64
            } else {
                0i64
            },
            if settings.review_notify_when_idle {
                1i64
            } else {
                0i64
            },
            updated_at,
        ),
    )?;
    Ok(())
}

fn insert_event(
    conn: &mut Connection,
    e: &IngestEvent,
    entity: Option<&str>,
    title: Option<&str>,
    payload_json: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO events (ts, source, event, entity, title, payload_json) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        (
            &e.ts,
            &e.source,
            &e.event,
            entity,
            title,
            payload_json,
        ),
    )?;
    Ok(())
}

fn list_privacy_rules(conn: &mut Connection) -> rusqlite::Result<Vec<PrivacyRuleRow>> {
    let mut stmt = conn.prepare(
        "SELECT id, kind, value, action, created_at FROM privacy_rules ORDER BY id DESC",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(PrivacyRuleRow {
            id: row.get(0)?,
            kind: row.get(1)?,
            value: row.get(2)?,
            action: row.get(3)?,
            created_at: row.get(4)?,
        })
    })?;

    let mut out = Vec::new();
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

fn upsert_privacy_rule(
    conn: &mut Connection,
    kind: &str,
    value: &str,
    action: &str,
    created_at: &str,
) -> rusqlite::Result<PrivacyRuleRow> {
    conn.execute(
        r#"
INSERT INTO privacy_rules (kind, value, action, created_at)
VALUES (?1, ?2, ?3, ?4)
ON CONFLICT(kind, value) DO UPDATE SET
  action=excluded.action
"#,
        (kind, value, action, created_at),
    )?;

    let mut stmt = conn.prepare(
        "SELECT id, kind, value, action, created_at FROM privacy_rules WHERE kind = ?1 AND value = ?2",
    )?;
    stmt.query_row((kind, value), |row| {
        Ok(PrivacyRuleRow {
            id: row.get(0)?,
            kind: row.get(1)?,
            value: row.get(2)?,
            action: row.get(3)?,
            created_at: row.get(4)?,
        })
    })
}

fn delete_privacy_rule_by_id(conn: &mut Connection, id: i64) -> rusqlite::Result<usize> {
    conn.execute("DELETE FROM privacy_rules WHERE id = ?1", [id])
}

fn list_report_todos(conn: &mut Connection, limit: usize) -> rusqlite::Result<Vec<ReportTodo>> {
    let mut stmt = conn.prepare(
        r#"
SELECT
  id,
  content,
  done,
  due_date,
  start_ts,
  end_ts,
  created_at,
  updated_at,
  done_at
FROM report_todos
ORDER BY done ASC, updated_at DESC, id DESC
LIMIT ?1
"#,
    )?;
    let rows = stmt.query_map([limit as i64], |row| {
        let done: i64 = row.get(2)?;
        Ok(ReportTodo {
            id: row.get(0)?,
            content: row.get(1)?,
            done: done != 0,
            due_date: row.get(3)?,
            start_ts: row.get(4)?,
            end_ts: row.get(5)?,
            created_at: row.get(6)?,
            updated_at: row.get(7)?,
            done_at: row.get(8)?,
        })
    })?;

    let mut out = Vec::new();
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

fn get_report_todo_by_id(conn: &mut Connection, id: i64) -> rusqlite::Result<Option<ReportTodo>> {
    let mut stmt = conn.prepare(
        r#"
SELECT
  id,
  content,
  done,
  due_date,
  start_ts,
  end_ts,
  created_at,
  updated_at,
  done_at
FROM report_todos
WHERE id = ?1
LIMIT 1
"#,
    )?;
    match stmt.query_row([id], |row| {
        let done: i64 = row.get(2)?;
        Ok(ReportTodo {
            id: row.get(0)?,
            content: row.get(1)?,
            done: done != 0,
            due_date: row.get(3)?,
            start_ts: row.get(4)?,
            end_ts: row.get(5)?,
            created_at: row.get(6)?,
            updated_at: row.get(7)?,
            done_at: row.get(8)?,
        })
    }) {
        Ok(v) => Ok(Some(v)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(err) => Err(err),
    }
}

fn insert_report_todo(
    conn: &mut Connection,
    content: &str,
    done: bool,
    due_date: Option<&str>,
    start_ts: Option<&str>,
    end_ts: Option<&str>,
    done_at: Option<&str>,
    now: &str,
) -> rusqlite::Result<i64> {
    conn.execute(
        "INSERT INTO report_todos (content, done, due_date, start_ts, end_ts, created_at, updated_at, done_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        (
            content,
            if done { 1i64 } else { 0i64 },
            due_date,
            start_ts,
            end_ts,
            now,
            now,
            done_at,
        ),
    )?;
    Ok(conn.last_insert_rowid())
}

fn update_report_todo(
    conn: &mut Connection,
    id: i64,
    content: &str,
    done: bool,
    due_date: Option<&str>,
    start_ts: Option<&str>,
    end_ts: Option<&str>,
    done_at: Option<&str>,
    now: &str,
) -> rusqlite::Result<usize> {
    conn.execute(
        "UPDATE report_todos SET content = ?1, done = ?2, due_date = ?3, start_ts = ?4, end_ts = ?5, done_at = ?6, updated_at = ?7 WHERE id = ?8",
        (
            content,
            if done { 1i64 } else { 0i64 },
            due_date,
            start_ts,
            end_ts,
            done_at,
            now,
            id,
        ),
    )
}

fn delete_report_todo_by_id(conn: &mut Connection, id: i64) -> rusqlite::Result<usize> {
    conn.execute("DELETE FROM report_todos WHERE id = ?1", [id])
}

fn list_reports(conn: &mut Connection, limit: usize) -> rusqlite::Result<Vec<ReportSummary>> {
    let mut stmt = conn.prepare(
        r#"
SELECT
  id,
  kind,
  period_start,
  period_end,
  generated_at,
  provider_url,
  model,
  output_md,
  error
FROM reports
ORDER BY period_end DESC, generated_at DESC
LIMIT ?1
"#,
    )?;

    let rows = stmt.query_map([limit as i64], |row| {
        let output_md: Option<String> = row.get(7)?;
        let error: Option<String> = row.get(8)?;
        let has_output = output_md
            .as_deref()
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false);
        let has_error = error
            .as_deref()
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false);

        Ok(ReportSummary {
            id: row.get(0)?,
            kind: row.get(1)?,
            period_start: row.get(2)?,
            period_end: row.get(3)?,
            generated_at: row.get(4)?,
            provider_url: row.get(5)?,
            model: row.get(6)?,
            has_output,
            has_error,
        })
    })?;

    let mut out = Vec::new();
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

fn get_report(conn: &mut Connection, id: &str) -> rusqlite::Result<Option<ReportRecord>> {
    let mut stmt = conn.prepare(
        r#"
SELECT
  id,
  kind,
  period_start,
  period_end,
  generated_at,
  provider_url,
  model,
  prompt,
  input_json,
  output_md,
  error
FROM reports
WHERE id = ?1
LIMIT 1
"#,
    )?;
    match stmt.query_row([id], |row| {
        Ok(ReportRecord {
            id: row.get(0)?,
            kind: row.get(1)?,
            period_start: row.get(2)?,
            period_end: row.get(3)?,
            generated_at: row.get(4)?,
            provider_url: row.get(5)?,
            model: row.get(6)?,
            prompt: row.get(7)?,
            input_json: row.get(8)?,
            output_md: row.get(9)?,
            error: row.get(10)?,
        })
    }) {
        Ok(v) => Ok(Some(v)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(err) => Err(err),
    }
}

fn upsert_report(conn: &mut Connection, r: &ReportRecord) -> rusqlite::Result<()> {
    conn.execute(
        r#"
INSERT INTO reports (
  id, kind, period_start, period_end, generated_at,
  provider_url, model, prompt, input_json, output_md, error
)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
ON CONFLICT(id) DO UPDATE SET
  kind=excluded.kind,
  period_start=excluded.period_start,
  period_end=excluded.period_end,
  generated_at=excluded.generated_at,
  provider_url=excluded.provider_url,
  model=excluded.model,
  prompt=excluded.prompt,
  input_json=excluded.input_json,
  output_md=excluded.output_md,
  error=excluded.error
"#,
        (
            &r.id,
            &r.kind,
            &r.period_start,
            &r.period_end,
            &r.generated_at,
            r.provider_url.as_deref(),
            r.model.as_deref(),
            r.prompt.as_deref(),
            r.input_json.as_deref(),
            r.output_md.as_deref(),
            r.error.as_deref(),
        ),
    )?;
    Ok(())
}

fn delete_report_by_id(conn: &mut Connection, id: &str) -> rusqlite::Result<usize> {
    conn.execute("DELETE FROM reports WHERE id = ?1", [id])
}

fn privacy_action_for_event(
    conn: &mut Connection,
    e: &IngestEvent,
) -> rusqlite::Result<Option<String>> {
    let check = |kind: &str, value: &str| -> rusqlite::Result<Option<String>> {
        let mut stmt = conn
            .prepare("SELECT action FROM privacy_rules WHERE kind = ?1 AND value = ?2 LIMIT 1")?;
        let mut rows = stmt.query((kind, value))?;
        if let Some(row) = rows.next()? {
            Ok(Some(row.get(0)?))
        } else {
            Ok(None)
        }
    };

    let check_domain = |domain: &str| -> rusqlite::Result<Option<String>> {
        let domain_lc = domain.to_lowercase();
        if !domain_lc.contains('.') {
            return check("domain", &domain_lc);
        }

        // Suffix match: a rule for `youtube.com` also matches `m.youtube.com`.
        // (We intentionally stop before top-level domains like `com`.)
        let mut candidate: &str = domain_lc.as_str();
        loop {
            if let Some(action) = check("domain", candidate)? {
                return Ok(Some(action));
            }
            let Some((_left, rest)) = candidate.split_once('.') else {
                break;
            };
            if !rest.contains('.') {
                break;
            }
            candidate = rest;
        }
        Ok(None)
    };

    match e.event.as_str() {
        "tab_active" => {
            if let Some(domain) = e.domain.as_deref().filter(|s| !s.trim().is_empty()) {
                return check_domain(domain);
            }
        }
        "app_active" => {
            if let Some(app) = e.app.as_deref().filter(|s| !s.trim().is_empty()) {
                return check("app", app);
            }
        }
        _ => {}
    }

    if let Some(domain) = e.domain.as_deref().filter(|s| !s.trim().is_empty()) {
        if let Some(action) = check_domain(domain)? {
            return Ok(Some(action));
        }
    }
    if let Some(app) = e.app.as_deref().filter(|s| !s.trim().is_empty()) {
        if let Some(action) = check("app", app)? {
            return Ok(Some(action));
        }
    }
    Ok(None)
}

fn load_tracking_status(conn: &mut Connection) -> rusqlite::Result<TrackingStatus> {
    let mut stmt = conn
        .prepare("SELECT paused, paused_until_ts, updated_at FROM tracking_state WHERE id = 1")?;
    stmt.query_row([], |row| {
        let paused: i64 = row.get(0)?;
        Ok(TrackingStatus {
            paused: paused != 0,
            paused_until_ts: row.get(1)?,
            updated_at: row.get(2)?,
        })
    })
}

fn set_tracking_pause(
    conn: &mut Connection,
    paused_until_ts: Option<&str>,
    updated_at: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE tracking_state SET paused = 1, paused_until_ts = ?1, updated_at = ?2 WHERE id = 1",
        (paused_until_ts, updated_at),
    )?;
    Ok(())
}

fn set_tracking_resume(conn: &mut Connection, updated_at: &str) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE tracking_state SET paused = 0, paused_until_ts = NULL, updated_at = ?1 WHERE id = 1",
        [updated_at],
    )?;
    Ok(())
}

fn tracking_is_paused(conn: &mut Connection, now: OffsetDateTime) -> rusqlite::Result<bool> {
    let (paused, paused_until_ts): (i64, Option<String>) = {
        let mut stmt =
            conn.prepare("SELECT paused, paused_until_ts FROM tracking_state WHERE id = 1")?;
        stmt.query_row([], |row| Ok((row.get(0)?, row.get(1)?)))?
    };

    if paused == 0 {
        return Ok(false);
    }

    if let Some(until_ts) = paused_until_ts.as_deref() {
        match OffsetDateTime::parse(until_ts, &Rfc3339) {
            Ok(until) => {
                if until <= now {
                    let updated_at = now.format(&Rfc3339).unwrap_or_default();
                    set_tracking_resume(conn, &updated_at)?;
                    return Ok(false);
                }
            }
            Err(_) => {
                // Corrupted row: auto-resume to avoid being stuck.
                let updated_at = now.format(&Rfc3339).unwrap_or_default();
                set_tracking_resume(conn, &updated_at)?;
                return Ok(false);
            }
        }
    }

    Ok(true)
}

fn list_events(
    conn: &mut Connection,
    limit: usize,
    privacy: &PrivacyIndex,
) -> rusqlite::Result<Vec<EventRecord>> {
    let mut stmt = conn.prepare(
        "SELECT id, ts, source, event, entity, title, payload_json FROM events ORDER BY ts DESC LIMIT ?1",
    )?;
    let rows = stmt.query_map([limit as i64], |row| {
        let payload_json: String = row.get(6)?;
        let activity = serde_json::from_str::<Value>(&payload_json)
            .ok()
            .and_then(|v| {
                v.get("activity")
                    .and_then(|a| a.as_str())
                    .map(|s| s.to_string())
            });
        Ok(EventRecord {
            id: row.get(0)?,
            ts: row.get(1)?,
            source: row.get(2)?,
            event: row.get(3)?,
            entity: row.get(4)?,
            title: row.get(5)?,
            activity,
        })
    })?;

    let mut out = Vec::new();
    for r in rows {
        let mut e = r?;
        if let Some(entity) = e.entity.as_deref() {
            match privacy.decision_for(&e.event, entity) {
                PrivacyDecision::Allow => {}
                PrivacyDecision::Drop => continue,
                PrivacyDecision::Mask => {
                    e.entity = Some("__hidden__".to_string());
                    e.title = None;
                }
            }
        }
        out.push(e);
    }
    Ok(out)
}

#[derive(Clone)]
struct EventForBlocks {
    ts: OffsetDateTime,
    #[allow(dead_code)]
    source: String,
    event: String,
    entity: String,
    #[allow(dead_code)]
    title: Option<String>,
    #[allow(dead_code)]
    activity: Option<String>,
}

fn list_events_between(
    conn: &mut Connection,
    start: OffsetDateTime,
    end: OffsetDateTime,
    privacy: &PrivacyIndex,
) -> rusqlite::Result<Vec<EventForBlocks>> {
    let start_s = start.format(&Rfc3339).unwrap_or_default();
    let end_s = end.format(&Rfc3339).unwrap_or_default();

    let mut stmt = conn.prepare(
        "SELECT ts, source, event, entity, title, payload_json FROM events WHERE ts >= ?1 AND ts < ?2 AND entity IS NOT NULL ORDER BY ts ASC",
    )?;
    let rows = stmt.query_map((start_s, end_s), |row| {
        let ts_s: String = row.get(0)?;
        let ts = OffsetDateTime::parse(&ts_s, &Rfc3339).map_err(|_| {
            rusqlite::Error::FromSqlConversionFailure(
                0,
                rusqlite::types::Type::Text,
                Box::new(std::fmt::Error),
            )
        })?;
        let payload_json: String = row.get(5)?;
        let activity = serde_json::from_str::<Value>(&payload_json)
            .ok()
            .and_then(|v| {
                v.get("activity")
                    .and_then(|a| a.as_str())
                    .map(|s| s.to_string())
            });
        Ok(EventForBlocks {
            ts,
            source: row.get(1)?,
            event: row.get(2)?,
            entity: row.get(3)?,
            title: row.get(4)?,
            activity,
        })
    })?;

    let mut out = Vec::new();
    for r in rows {
        let mut e = r?;
        match privacy.decision_for(&e.event, &e.entity) {
            PrivacyDecision::Allow => {}
            PrivacyDecision::Drop | PrivacyDecision::Mask => {
                // For timeline/blocks/export: keep timing continuity, but hide sensitive entities retroactively.
                e.entity = "__hidden__".to_string();
                e.title = None;
            }
        }
        out.push(e);
    }
    Ok(out)
}

fn normalize_tz_offset_minutes(v: Option<i32>) -> i32 {
    v.unwrap_or(0)
        .clamp(TZ_OFFSET_MINUTES_MIN, TZ_OFFSET_MINUTES_MAX)
}

fn tz_offset_from_minutes(minutes: i32) -> time::UtcOffset {
    time::UtcOffset::from_whole_seconds(minutes.saturating_mul(60)).unwrap_or(time::UtcOffset::UTC)
}

fn parse_day_start_utc_for_offset(
    date: &str,
    tz_offset: time::UtcOffset,
) -> Result<OffsetDateTime, ()> {
    // YYYY-MM-DD in the provided offset; converted to UTC start.
    let parts: Vec<&str> = date.split('-').collect();
    if parts.len() != 3 {
        return Err(());
    }
    let y: i32 = parts[0].parse().map_err(|_| ())?;
    let m: u8 = parts[1].parse().map_err(|_| ())?;
    let d: u8 = parts[2].parse().map_err(|_| ())?;
    let month = time::Month::try_from(m).map_err(|_| ())?;
    let dt = time::Date::from_calendar_date(y, month, d).map_err(|_| ())?;
    Ok(dt
        .with_hms(0, 0, 0)
        .map_err(|_| ())?
        .assume_offset(tz_offset)
        .to_offset(time::UtcOffset::UTC))
}

fn is_browser_app(app: &str) -> bool {
    let name = app.rsplit(['\\', '/']).next().unwrap_or(app).to_lowercase();
    matches!(
        name.as_str(),
        "chrome.exe" | "msedge.exe" | "brave.exe" | "vivaldi.exe" | "opera.exe" | "firefox.exe"
    )
}

#[derive(Clone, Copy, Hash, PartialEq, Eq)]
enum EntityKind {
    App,
    Domain,
}

impl EntityKind {
    fn as_str(self) -> &'static str {
        match self {
            EntityKind::App => "app",
            EntityKind::Domain => "domain",
        }
    }
}

#[derive(Clone, Hash, PartialEq, Eq)]
struct BucketKey {
    kind: EntityKind,
    entity: String,
    title: Option<String>,
}

fn normalize_web_title(domain: &str, raw: &str) -> String {
    let mut t = raw.trim().to_string();
    if t.is_empty() {
        return String::new();
    }
    let d = domain.to_lowercase();
    if d.contains("youtube.") && t.ends_with(" - YouTube") {
        t.truncate(t.len().saturating_sub(" - YouTube".len()));
    }
    t.trim().to_string()
}

fn normalized_title_for_domain(
    domain: &str,
    raw: Option<&str>,
    store_titles: bool,
) -> Option<String> {
    if !store_titles {
        return None;
    }
    let r = raw?.trim();
    if r.is_empty() {
        return None;
    }
    let t = normalize_web_title(domain, r);
    if t.is_empty() {
        None
    } else {
        Some(t)
    }
}

fn build_blocks(
    events: &[EventForBlocks],
    settings: Settings,
    now: OffsetDateTime,
) -> Vec<BlockSummary> {
    if events.is_empty() {
        return Vec::new();
    }

    // Background audio (audible tab) should not disturb the primary focus timeline:
    // - primary blocks are built from the focus stream (app_active + tab_active when browser is focused)
    // - background audio is computed separately and attached to blocks as secondary usage
    let mut focus_events: Vec<EventForBlocks> = Vec::new();
    let mut audio_events: Vec<EventForBlocks> = Vec::new();
    let mut audio_primary = false;
    for e in events {
        if (e.event == "tab_active" && e.activity.as_deref() == Some("audio"))
            || e.event == "tab_audio_stop"
            || e.event == "app_audio"
            || e.event == "app_audio_stop"
        {
            audio_events.push(e.clone());
        } else {
            focus_events.push(e.clone());
        }
    }

    // Fallback: if we only have background-audio events (e.g. extension-only setup),
    // still build blocks so the UI can show something useful.
    if focus_events.is_empty() {
        if audio_events.is_empty() {
            return Vec::new();
        }
        audio_primary = true;
        focus_events = std::mem::take(&mut audio_events);
    }

    let block_len = time::Duration::seconds(settings.block_seconds.max(60));
    let default_idle_cutoff = time::Duration::seconds(settings.idle_cutoff_seconds.max(10));
    let audio_idle_cutoff =
        default_idle_cutoff.min(time::Duration::seconds(AUDIO_IDLE_CUTOFF_SECONDS));
    let idle_cutoff = if audio_primary {
        audio_idle_cutoff
    } else {
        default_idle_cutoff
    };
    let domain_freshness = time::Duration::seconds(DOMAIN_FRESHNESS_SECONDS);

    let mut blocks: Vec<BlockSummary> = Vec::new();

    let mut current_start = focus_events[0].ts;
    let mut current_end = current_start;
    let mut active_seconds: i64 = 0;
    let mut bucket: HashMap<BucketKey, i64> = HashMap::new();

    let mut current_app: Option<String> = None;
    let mut current_domain: Option<String> = None;
    let mut current_domain_title: Option<String> = None;
    let mut current_domain_ts: Option<OffsetDateTime> = None;

    for i in 0..focus_events.len() {
        let cur = &focus_events[i];
        let next_ts = focus_events.get(i + 1).map(|e| e.ts).unwrap_or(now);
        if next_ts <= cur.ts {
            continue;
        }

        match cur.event.as_str() {
            "app_active" => {
                current_app = Some(cur.entity.clone());
            }
            "tab_active" => {
                current_domain = Some(cur.entity.clone());
                current_domain_title = cur.title.clone();
                current_domain_ts = Some(cur.ts);
            }
            "tab_audio_stop" => {
                // Stop marker: clear domain so subsequent time isn't attributed to any tab.
                current_domain = None;
                current_domain_title = None;
                current_domain_ts = None;
            }
            "app_audio_stop" => {
                // Stop marker: clear app so subsequent time isn't attributed to any app audio.
                current_app = None;
            }
            _ => {
                // Fallback: treat as app-like entity for attribution.
                current_app = Some(cur.entity.clone());
            }
        }

        let raw_gap = next_ts - cur.ts;
        let mut seg = raw_gap.min(idle_cutoff);
        if seg.is_negative() || seg.is_zero() {
            continue;
        }

        let mut seg_start = cur.ts;

        let resolve_entity = |at: OffsetDateTime| -> Option<(EntityKind, &str, Option<&str>)> {
            if let Some(app) = current_app.as_deref() {
                if is_browser_app(app) {
                    if let (Some(domain), Some(domain_ts)) =
                        (current_domain.as_deref(), current_domain_ts)
                    {
                        if at - domain_ts <= domain_freshness {
                            Some((EntityKind::Domain, domain, current_domain_title.as_deref()))
                        } else {
                            Some((EntityKind::App, app, None))
                        }
                    } else {
                        Some((EntityKind::App, app, None))
                    }
                } else {
                    Some((EntityKind::App, app, None))
                }
            } else {
                current_domain
                    .as_deref()
                    .map(|d| (EntityKind::Domain, d, current_domain_title.as_deref()))
            }
        };

        while seg > time::Duration::ZERO {
            let resolved_entity = resolve_entity(seg_start);
            let remaining = block_len - time::Duration::seconds(active_seconds);
            let take = seg.min(remaining);

            let take_s = take.whole_seconds();
            if take_s > 0 {
                if let Some((kind, entity, title)) = resolved_entity {
                    let key = BucketKey {
                        kind,
                        entity: entity.to_string(),
                        title: if kind == EntityKind::Domain {
                            normalized_title_for_domain(entity, title, settings.store_titles)
                        } else {
                            None
                        },
                    };
                    *bucket.entry(key).or_insert(0) += take_s;
                    active_seconds += take_s;
                    seg_start += take;
                    current_end = seg_start;
                }
            } else {
                break;
            }

            seg -= take;

            if time::Duration::seconds(active_seconds) >= block_len {
                blocks.push(finalize_block(
                    current_start,
                    current_end,
                    &bucket,
                    active_seconds,
                ));
                // next block starts exactly at the boundary
                current_start = current_end;
                bucket.clear();
                active_seconds = 0;
            }
        }

        // If there was a long gap, close the current block (do not attribute idle to any entity).
        if raw_gap > idle_cutoff {
            if active_seconds > 0 {
                blocks.push(finalize_block(
                    current_start,
                    current_end,
                    &bucket,
                    active_seconds,
                ));
            }
            // Start a new block at next_ts (there may be idle gap).
            current_start = next_ts;
            current_end = next_ts;
            bucket.clear();
            active_seconds = 0;
            current_app = None;
            current_domain = None;
            current_domain_title = None;
            current_domain_ts = None;
        }
    }

    if active_seconds > 0 {
        blocks.push(finalize_block(
            current_start,
            current_end,
            &bucket,
            active_seconds,
        ));
    }

    if !audio_events.is_empty() && !blocks.is_empty() {
        // Audio events are heartbeated by the extension (default 60s). Use a tighter cutoff than the
        // primary focus idle cutoff to avoid over-attributing when audio stops but no "stop" event is sent.
        attach_background_audio(
            &mut blocks,
            &audio_events,
            settings.store_titles,
            audio_idle_cutoff,
            now,
        );
    }

    blocks
}

#[derive(Clone)]
struct SegmentAcc {
    kind: EntityKind,
    entity: String,
    title: Option<String>,
    activity: &'static str, // "focus" | "audio"
    start: OffsetDateTime,
    end: OffsetDateTime,
}

fn push_or_merge_segment(out: &mut Vec<SegmentAcc>, seg: SegmentAcc) {
    if seg.end <= seg.start {
        return;
    }
    if let Some(last) = out.last_mut() {
        if last.kind == seg.kind
            && last.entity == seg.entity
            && last.title == seg.title
            && last.activity == seg.activity
            && last.end == seg.start
        {
            last.end = seg.end;
            return;
        }
    }
    out.push(seg);
}

fn build_timeline_segments(
    events: &[EventForBlocks],
    settings: Settings,
    now: OffsetDateTime,
) -> Vec<TimelineSegment> {
    if events.is_empty() {
        return Vec::new();
    }

    let default_idle_cutoff = time::Duration::seconds(settings.idle_cutoff_seconds.max(10));
    let focus_idle_cutoff = default_idle_cutoff;
    let audio_idle_cutoff =
        default_idle_cutoff.min(time::Duration::seconds(AUDIO_IDLE_CUTOFF_SECONDS));
    let domain_freshness = time::Duration::seconds(DOMAIN_FRESHNESS_SECONDS);

    // Split streams.
    let mut focus_events: Vec<EventForBlocks> = Vec::new();
    let mut audio_events: Vec<EventForBlocks> = Vec::new();
    for e in events {
        if (e.event == "tab_active" && e.activity.as_deref() == Some("audio"))
            || e.event == "tab_audio_stop"
            || e.event == "app_audio"
            || e.event == "app_audio_stop"
        {
            audio_events.push(e.clone());
        } else {
            focus_events.push(e.clone());
        }
    }

    // Focus stream segments (foreground usage).
    let mut focus_out: Vec<SegmentAcc> = Vec::new();
    if !focus_events.is_empty() {
        let mut current_app: Option<String> = None;
        let mut current_app_title: Option<String> = None;
        let mut current_domain: Option<String> = None;
        let mut current_domain_title: Option<String> = None;
        let mut current_domain_ts: Option<OffsetDateTime> = None;

        for i in 0..focus_events.len() {
            let cur = &focus_events[i];
            let next_ts = focus_events.get(i + 1).map(|e| e.ts).unwrap_or(now);
            if next_ts <= cur.ts {
                continue;
            }

            match cur.event.as_str() {
                "app_active" => {
                    current_app = Some(cur.entity.clone());
                    current_app_title = cur.title.clone();
                }
                "tab_active" => {
                    current_domain = Some(cur.entity.clone());
                    current_domain_title = cur.title.clone();
                    current_domain_ts = Some(cur.ts);
                }
                _ => {
                    // Fallback: treat as app-like.
                    current_app = Some(cur.entity.clone());
                    current_app_title = cur.title.clone();
                }
            }

            let raw_gap = next_ts - cur.ts;
            let seg = raw_gap.min(focus_idle_cutoff);
            if seg.is_negative() || seg.is_zero() {
                continue;
            }
            let seg_end = cur.ts + seg;

            let resolved = if let Some(app) = current_app.as_deref() {
                if is_browser_app(app) {
                    if let (Some(domain), Some(domain_ts)) =
                        (current_domain.as_deref(), current_domain_ts)
                    {
                        if cur.ts - domain_ts <= domain_freshness {
                            Some((
                                EntityKind::Domain,
                                domain.to_string(),
                                current_domain_title.clone(),
                            ))
                        } else {
                            Some((EntityKind::App, app.to_string(), current_app_title.clone()))
                        }
                    } else {
                        Some((EntityKind::App, app.to_string(), current_app_title.clone()))
                    }
                } else {
                    Some((EntityKind::App, app.to_string(), current_app_title.clone()))
                }
            } else {
                current_domain.as_deref().map(|d| {
                    (
                        EntityKind::Domain,
                        d.to_string(),
                        current_domain_title.clone(),
                    )
                })
            };

            if let Some((kind, entity, title)) = resolved {
                push_or_merge_segment(
                    &mut focus_out,
                    SegmentAcc {
                        kind,
                        entity,
                        title,
                        activity: "focus",
                        start: cur.ts,
                        end: seg_end,
                    },
                );
            }

            if raw_gap > focus_idle_cutoff {
                current_app = None;
                current_app_title = None;
                current_domain = None;
                current_domain_title = None;
                current_domain_ts = None;
            }
        }
    }

    // Background audio stream segments (audible tab while browser not focused).
    let mut audio_out: Vec<SegmentAcc> = Vec::new();
    if !audio_events.is_empty() {
        for i in 0..audio_events.len() {
            let cur = &audio_events[i];
            let kind = match cur.event.as_str() {
                "tab_active" => EntityKind::Domain,
                "app_audio" => EntityKind::App,
                _ => continue,
            };
            let next_ts = audio_events.get(i + 1).map(|e| e.ts).unwrap_or(now);
            if next_ts <= cur.ts {
                continue;
            }
            let raw_gap = next_ts - cur.ts;
            let seg = raw_gap.min(audio_idle_cutoff);
            if seg.is_negative() || seg.is_zero() {
                continue;
            }
            let seg_end = cur.ts + seg;
            push_or_merge_segment(
                &mut audio_out,
                SegmentAcc {
                    kind,
                    entity: cur.entity.clone(),
                    title: cur.title.clone(),
                    activity: "audio",
                    start: cur.ts,
                    end: seg_end,
                },
            );
        }
    }

    let mut all = Vec::new();
    all.extend(focus_out);
    all.extend(audio_out);
    all.sort_by(|a, b| a.start.cmp(&b.start));

    all.into_iter()
        .filter_map(|s| {
            let seconds = (s.end - s.start).whole_seconds();
            if seconds <= 0 {
                return None;
            }
            Some(TimelineSegment {
                kind: s.kind.as_str().to_string(),
                entity: s.entity,
                title: s.title,
                activity: Some(s.activity.to_string()),
                start_ts: s.start.format(&Rfc3339).unwrap_or_default(),
                end_ts: s.end.format(&Rfc3339).unwrap_or_default(),
                seconds,
            })
        })
        .collect()
}

fn attach_background_audio(
    blocks: &mut [BlockSummary],
    audio_events: &[EventForBlocks],
    store_titles: bool,
    idle_cutoff: time::Duration,
    now: OffsetDateTime,
) {
    let mut block_times: Vec<(OffsetDateTime, OffsetDateTime)> = Vec::with_capacity(blocks.len());
    for b in blocks.iter() {
        let Ok(start) = OffsetDateTime::parse(&b.start_ts, &Rfc3339) else {
            return;
        };
        let Ok(end) = OffsetDateTime::parse(&b.end_ts, &Rfc3339) else {
            return;
        };
        block_times.push((start, end));
    }

    let mut per_block: Vec<HashMap<BucketKey, i64>> = vec![HashMap::new(); blocks.len()];
    let mut per_total: Vec<i64> = vec![0; blocks.len()];

    let mut bi: usize = 0;
    for i in 0..audio_events.len() {
        let cur = &audio_events[i];
        let next_ts = audio_events.get(i + 1).map(|e| e.ts).unwrap_or(now);
        if next_ts <= cur.ts {
            continue;
        }

        // Stop marker: it exists only to end the previous segment early.
        // Do not attribute any usage after it.
        if cur.event == "tab_audio_stop" || cur.event == "app_audio_stop" {
            continue;
        }

        let raw_gap = next_ts - cur.ts;
        let seg = raw_gap.min(idle_cutoff);
        if seg.is_negative() || seg.is_zero() {
            continue;
        }

        let seg_start = cur.ts;
        let seg_end = cur.ts + seg;
        let key = BucketKey {
            kind: if cur.event == "app_audio" {
                EntityKind::App
            } else {
                EntityKind::Domain
            },
            entity: cur.entity.clone(),
            title: if cur.event == "tab_active" {
                normalized_title_for_domain(&cur.entity, cur.title.as_deref(), store_titles)
            } else {
                None
            },
        };

        while bi < block_times.len() && block_times[bi].1 <= seg_start {
            bi += 1;
        }

        let mut j = bi;
        while j < block_times.len() && block_times[j].0 < seg_end {
            let overlap_start = if seg_start > block_times[j].0 {
                seg_start
            } else {
                block_times[j].0
            };
            let overlap_end = if seg_end < block_times[j].1 {
                seg_end
            } else {
                block_times[j].1
            };
            let sec = (overlap_end - overlap_start).whole_seconds();
            if sec > 0 {
                *per_block[j].entry(key.clone()).or_insert(0) += sec;
                per_total[j] += sec;
            }
            j += 1;
        }
    }

    for i in 0..blocks.len() {
        if per_total[i] <= 0 {
            continue;
        }
        let mut items: Vec<TopItem> = per_block[i]
            .iter()
            .map(|(k, sec)| TopItem {
                kind: k.kind.as_str().to_string(),
                entity: k.entity.clone(),
                title: if k.kind == EntityKind::Domain {
                    k.title.clone()
                } else {
                    None
                },
                seconds: *sec,
            })
            .collect();
        items.sort_by(|a, b| b.seconds.cmp(&a.seconds));
        items.truncate(5);
        blocks[i].background_seconds = Some(per_total[i]);
        blocks[i].background_top_items = items;
    }
}

fn finalize_block(
    start: OffsetDateTime,
    end: OffsetDateTime,
    bucket: &HashMap<BucketKey, i64>,
    total_seconds: i64,
) -> BlockSummary {
    let start_ts = start.format(&Rfc3339).unwrap_or_default();
    let end_ts = end.format(&Rfc3339).unwrap_or_default();
    let id = start_ts.clone();

    let mut items: Vec<TopItem> = bucket
        .iter()
        .map(|(k, v)| TopItem {
            kind: k.kind.as_str().to_string(),
            entity: k.entity.clone(),
            title: if k.kind == EntityKind::Domain {
                k.title.clone()
            } else {
                None
            },
            seconds: *v,
        })
        .collect();
    items.sort_by(|a, b| b.seconds.cmp(&a.seconds));
    items.truncate(5);

    BlockSummary {
        id,
        start_ts,
        end_ts,
        total_seconds,
        top_items: items,
        background_top_items: Vec::new(),
        background_seconds: None,
        review: None,
    }
}

fn upsert_review(
    conn: &mut Connection,
    r: &ReviewUpsert,
    skip_reason: Option<&str>,
    tags_json: &str,
    updated_at: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        r#"
INSERT INTO block_reviews (block_id, skipped, skip_reason, doing, output, next, tags_json, updated_at)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
ON CONFLICT(block_id) DO UPDATE SET
  skipped=excluded.skipped,
  skip_reason=excluded.skip_reason,
  doing=excluded.doing,
  output=excluded.output,
  next=excluded.next,
  tags_json=excluded.tags_json,
  updated_at=excluded.updated_at
"#,
        (
            &r.block_id,
            if r.skipped { 1_i64 } else { 0_i64 },
            skip_reason,
            r.doing.as_deref(),
            r.output.as_deref(),
            r.next.as_deref(),
            tags_json,
            updated_at,
        ),
    )?;
    Ok(())
}

fn attach_reviews(
    conn: &mut Connection,
    mut blocks: Vec<BlockSummary>,
) -> rusqlite::Result<Vec<BlockSummary>> {
    for b in &mut blocks {
        if let Some(r) = get_review(conn, &b.id)? {
            b.review = Some(r);
        }
    }
    Ok(blocks)
}

fn get_review(conn: &mut Connection, block_id: &str) -> rusqlite::Result<Option<BlockReview>> {
    let mut stmt = conn.prepare(
        "SELECT skipped, skip_reason, doing, output, next, tags_json, updated_at FROM block_reviews WHERE block_id = ?1",
    )?;
    let mut rows = stmt.query([block_id])?;
    if let Some(row) = rows.next()? {
        let tags_json: Option<String> = row.get(5)?;
        let tags: Vec<String> = tags_json
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        let skipped: i64 = row.get(0)?;
        return Ok(Some(BlockReview {
            skipped: skipped != 0,
            skip_reason: row.get(1)?,
            doing: row.get(2)?,
            output: row.get(3)?,
            next: row.get(4)?,
            tags,
            updated_at: row.get(6)?,
        }));
    }
    Ok(None)
}

fn export_markdown(date: &str, blocks: &[BlockSummary], tz_offset: time::UtcOffset) -> String {
    fn top_label(it: &TopItem) -> String {
        let entity = it.entity.trim();
        if entity.is_empty() {
            return "(unknown)".to_string();
        }
        if entity == "__hidden__" {
            return "(hidden)".to_string();
        }
        if it.kind == "domain" {
            if let Some(title) = it.title.as_deref() {
                let t = title.trim();
                if !t.is_empty() {
                    return format!("{t} ({entity})");
                }
            }
        }
        entity.to_string()
    }

    let mut out = String::new();
    out.push_str(&format!("# {date}\n\n"));

    for b in blocks {
        let start = fmt_hhmm(&b.start_ts, tz_offset);
        let end = fmt_hhmm(&b.end_ts, tz_offset);
        out.push_str(&format!("## {start}–{end}\n"));

        if !b.top_items.is_empty() {
            out.push_str("Top: ");
            out.push_str(
                &b.top_items
                    .iter()
                    .map(|it| format!("{} {}", top_label(it), fmt_duration(it.seconds)))
                    .collect::<Vec<_>>()
                    .join(" · "),
            );
            out.push('\n');
        }

        if let Some(r) = &b.review {
            if r.skipped {
                if let Some(reason) = &r.skip_reason {
                    if !reason.trim().is_empty() {
                        out.push_str(&format!("- Skipped: {reason}\n"));
                    } else {
                        out.push_str("- Skipped\n");
                    }
                } else {
                    out.push_str("- Skipped\n");
                }
            }
            if let Some(v) = &r.doing {
                if !v.trim().is_empty() {
                    out.push_str(&format!("- Doing: {v}\n"));
                }
            }
            if let Some(v) = &r.output {
                if !v.trim().is_empty() {
                    out.push_str(&format!("- Output: {v}\n"));
                }
            }
            if let Some(v) = &r.next {
                if !v.trim().is_empty() {
                    out.push_str(&format!("- Next: {v}\n"));
                }
            }
            if !r.tags.is_empty() {
                out.push_str(&format!("- Tags: {}\n", r.tags.join(", ")));
            }
        }

        out.push('\n');
    }

    out
}

fn export_csv(date: &str, blocks: &[BlockSummary]) -> String {
    fn top_label(it: &TopItem) -> String {
        let entity = it.entity.trim();
        if entity.is_empty() {
            return "(unknown)".to_string();
        }
        if entity == "__hidden__" {
            return "(hidden)".to_string();
        }
        if it.kind == "domain" {
            if let Some(title) = it.title.as_deref() {
                let t = title.trim();
                if !t.is_empty() {
                    return format!("{t} ({entity})");
                }
            }
        }
        entity.to_string()
    }

    let mut out = String::new();
    out.push_str("date,block_id,start_ts,end_ts,total_seconds,top1_name,top1_seconds,top2_name,top2_seconds,top3_name,top3_seconds,top4_name,top4_seconds,top5_name,top5_seconds,skipped,skip_reason,doing,output,next,tags,review_updated_at\n");

    for b in blocks {
        let (skipped, skip_reason, doing, output, next, tags, updated_at) = match &b.review {
            Some(r) => (
                if r.skipped { "1" } else { "0" },
                r.skip_reason.as_deref().unwrap_or(""),
                r.doing.as_deref().unwrap_or(""),
                r.output.as_deref().unwrap_or(""),
                r.next.as_deref().unwrap_or(""),
                r.tags.join(";"),
                r.updated_at.as_str(),
            ),
            None => ("", "", "", "", "", String::new(), ""),
        };

        let mut row: Vec<String> = Vec::with_capacity(24);
        row.push(csv_escape(date));
        row.push(csv_escape(&b.id));
        row.push(csv_escape(&b.start_ts));
        row.push(csv_escape(&b.end_ts));
        row.push(b.total_seconds.to_string());

        for i in 0..5 {
            if let Some(it) = b.top_items.get(i) {
                row.push(csv_escape(&top_label(it)));
                row.push(it.seconds.to_string());
            } else {
                row.push(String::new());
                row.push(String::new());
            }
        }

        row.push(skipped.to_string());
        row.push(csv_escape(skip_reason));
        row.push(csv_escape(doing));
        row.push(csv_escape(output));
        row.push(csv_escape(next));
        row.push(csv_escape(&tags));
        row.push(csv_escape(updated_at));

        out.push_str(&row.join(","));
        out.push('\n');
    }

    out
}

fn csv_escape(s: &str) -> String {
    let needs_quote = s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r');
    if !needs_quote {
        return s.to_string();
    }
    format!("\"{}\"", s.replace('"', "\"\""))
}

fn fmt_duration(seconds: i64) -> String {
    if seconds <= 0 {
        return "0m".to_string();
    }
    let m = (seconds + 30) / 60;
    if m < 60 {
        return format!("{m}m");
    }
    let h = m / 60;
    let rm = m % 60;
    if rm == 0 {
        format!("{h}h")
    } else {
        format!("{h}h {rm}m")
    }
}

fn fmt_hhmm(rfc3339: &str, tz_offset: time::UtcOffset) -> String {
    if let Ok(t) = OffsetDateTime::parse(rfc3339, &Rfc3339) {
        let local = t.to_offset(tz_offset);
        return format!("{:02}:{:02}", local.hour(), local.minute());
    }
    // fallback
    rfc3339
        .split('T')
        .nth(1)
        .and_then(|s| s.get(0..5))
        .unwrap_or("??:??")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_day_start_utc_for_offset_works() {
        let tz = tz_offset_from_minutes(8 * 60);
        let start = parse_day_start_utc_for_offset("2026-02-15", tz).unwrap();
        assert_eq!(start.offset(), time::UtcOffset::UTC);
        assert_eq!(start.date().to_string(), "2026-02-14");
        assert_eq!(start.hour(), 16);
        assert_eq!(start.minute(), 0);

        let tz = tz_offset_from_minutes(-5 * 60);
        let start = parse_day_start_utc_for_offset("2026-02-15", tz).unwrap();
        assert_eq!(start.date().to_string(), "2026-02-15");
        assert_eq!(start.hour(), 5);
        assert_eq!(start.minute(), 0);
    }

    #[test]
    fn build_blocks_prefers_domain_when_browser_active() {
        let base = OffsetDateTime::parse("2026-02-15T00:00:00Z", &Rfc3339).unwrap();
        let m = |mins: i64| base + time::Duration::minutes(mins);

        let events = vec![
            EventForBlocks {
                ts: m(0),
                source: "windows_collector".to_string(),
                event: "app_active".to_string(),
                entity: "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe".to_string(),
                title: None,
                activity: None,
            },
            EventForBlocks {
                ts: m(1),
                source: "browser_extension".to_string(),
                event: "tab_active".to_string(),
                entity: "github.com".to_string(),
                title: None,
                activity: None,
            },
            EventForBlocks {
                ts: m(2),
                source: "windows_collector".to_string(),
                event: "app_active".to_string(),
                entity: "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe".to_string(),
                title: None,
                activity: None,
            },
            EventForBlocks {
                ts: m(3),
                source: "browser_extension".to_string(),
                event: "tab_active".to_string(),
                entity: "github.com".to_string(),
                title: None,
                activity: None,
            },
            EventForBlocks {
                ts: m(4),
                source: "windows_collector".to_string(),
                event: "app_active".to_string(),
                entity: "C:\\Program Files\\Microsoft VS Code\\Code.exe".to_string(),
                title: None,
                activity: None,
            },
        ];

        let settings = Settings {
            block_seconds: 45 * 60,
            idle_cutoff_seconds: 10 * 60,
            store_titles: false,
            store_exe_path: false,
            review_min_seconds: DEFAULT_REVIEW_MIN_SECONDS,
            review_notify_repeat_minutes: DEFAULT_REVIEW_NOTIFY_REPEAT_MINUTES,
            review_notify_when_paused: false,
            review_notify_when_idle: false,
        };
        let blocks = build_blocks(&events, settings, m(5));
        assert_eq!(blocks.len(), 1);
        let b = &blocks[0];
        assert_eq!(b.total_seconds, 5 * 60);

        let sec = |entity: &str| {
            b.top_items
                .iter()
                .find(|it| it.entity == entity)
                .map(|it| it.seconds)
                .unwrap_or(0)
        };
        assert_eq!(sec("github.com"), 3 * 60);
        assert_eq!(
            sec("C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"),
            60
        );
        assert_eq!(sec("C:\\Program Files\\Microsoft VS Code\\Code.exe"), 60);
    }

    #[test]
    fn build_blocks_splits_domain_by_title_when_store_titles() {
        let base = OffsetDateTime::parse("2026-02-15T00:00:00Z", &Rfc3339).unwrap();
        let m = |mins: i64| base + time::Duration::minutes(mins);

        let events = vec![
            EventForBlocks {
                ts: m(0),
                source: "windows_collector".to_string(),
                event: "app_active".to_string(),
                entity: "chrome.exe".to_string(),
                title: None,
                activity: None,
            },
            EventForBlocks {
                ts: m(1),
                source: "browser_extension".to_string(),
                event: "tab_active".to_string(),
                entity: "www.youtube.com".to_string(),
                title: Some("Video A - YouTube".to_string()),
                activity: None,
            },
            EventForBlocks {
                ts: m(2),
                source: "browser_extension".to_string(),
                event: "tab_active".to_string(),
                entity: "www.youtube.com".to_string(),
                title: Some("Video B - YouTube".to_string()),
                activity: None,
            },
        ];

        let settings = Settings {
            block_seconds: 45 * 60,
            idle_cutoff_seconds: 10 * 60,
            store_titles: true,
            store_exe_path: false,
            review_min_seconds: DEFAULT_REVIEW_MIN_SECONDS,
            review_notify_repeat_minutes: DEFAULT_REVIEW_NOTIFY_REPEAT_MINUTES,
            review_notify_when_paused: false,
            review_notify_when_idle: false,
        };
        let blocks = build_blocks(&events, settings, m(3));
        assert_eq!(blocks.len(), 1);
        let b = &blocks[0];

        let sec_domain = |title: &str| {
            b.top_items
                .iter()
                .find(|it| {
                    it.kind == "domain"
                        && it.entity == "www.youtube.com"
                        && it.title.as_deref() == Some(title)
                })
                .map(|it| it.seconds)
                .unwrap_or(0)
        };

        assert_eq!(sec_domain("Video A"), 60);
        assert_eq!(sec_domain("Video B"), 60);
        assert!(b.top_items.iter().any(|it| it.entity == "www.youtube.com"));
    }
}
