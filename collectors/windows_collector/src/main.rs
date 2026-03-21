use clap::Parser;

#[derive(Parser, Debug)]
#[command(name = "windows_collector", version)]
struct Args {
    /// Core base URL, e.g. http://127.0.0.1:17600
    #[arg(long, default_value = "http://127.0.0.1:17600")]
    core_url: String,

    /// Poll interval (milliseconds).
    #[arg(long, default_value_t = 1000)]
    poll_ms: u64,

    /// Send window title (privacy level L2). Default is off.
    #[arg(long, default_value_t = false)]
    send_title: bool,

    /// Send full executable path (higher sensitivity). Default is off.
    #[arg(long, default_value_t = false)]
    send_exe_path: bool,

    /// Heartbeat (seconds): resend even if app unchanged, for duration attribution.
    #[arg(long, default_value_t = 60)]
    heartbeat_seconds: u64,

    /// Track background app audio (e.g. QQ Music) via Windows CoreAudio sessions.
    ///
    /// This emits `app_audio` while some non-browser app is producing sound, and `app_audio_stop`
    /// when it stops. Default is on; disable via `--track-audio=false`.
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    track_audio: bool,

    /// Show a Windows toast when a review block is due (best-effort).
    ///
    /// This is useful when the UI is not in the foreground. Disable via `--review-notify=false`.
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    review_notify: bool,

    /// Still show review notifications even when tracking is paused.
    ///
    /// Default is off (do not notify when paused).
    #[arg(long, default_value_t = false, action = clap::ArgAction::Set)]
    review_notify_when_paused: bool,

    /// Still show review notifications even when the machine is idle.
    ///
    /// Default is off (do not notify when idle).
    #[arg(long, default_value_t = false, action = clap::ArgAction::Set)]
    review_notify_when_idle: bool,

    /// Review notification poll interval (seconds).
    #[arg(long, default_value_t = 30)]
    review_notify_check_seconds: u64,

    /// Minimum minutes between repeated notifications for the same due block.
    #[arg(long, default_value_t = 10)]
    review_notify_repeat_minutes: u64,

    /// Stop sending events when the machine is idle for >= this many seconds.
    ///
    /// This prevents attributing long idle time to the last foreground app.
    #[arg(long, default_value_t = 5 * 60)]
    idle_cutoff_seconds: u64,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "windows_collector=info".into()),
        )
        .init();

    let args = Args::parse();

    #[cfg(not(windows))]
    {
        eprintln!("windows_collector only runs on Windows.");
        eprintln!("Core URL would be: {}", args.core_url);
        Ok(())
    }

    #[cfg(windows)]
    {
        windows_main(args).await
    }
}

#[cfg(windows)]
#[derive(Clone, Debug)]
struct AudioAppInfo {
    app: String,
    pid: u32,
    exe_path: Option<String>,
}

#[cfg(windows)]
async fn windows_main(args: Args) -> anyhow::Result<()> {
    use chrono::{SecondsFormat, Utc};
    use reqwest::Client;
    use serde::Serialize;
    use std::path::Path;
    use std::time::Instant;
    use tokio::time::{sleep, Duration};
    use tracing::{error, info};

    // Prevent duplicate collectors (which would double-count usage).
    let _mutex = match ensure_single_instance_mutex() {
        Ok(g) => g,
        Err(e) => {
            info!("windows_collector already running; exit ({e})");
            return Ok(());
        }
    };

    #[derive(Serialize)]
    struct AppActiveEvent<'a> {
        v: i32,
        ts: &'a str,
        source: &'static str,
        event: &'static str,
        app: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<&'a str>,
        #[serde(skip_serializing_if = "Option::is_none")]
        exePath: Option<&'a str>,
        pid: u32,
    }

    #[derive(Serialize)]
    struct AppAudioEvent<'a> {
        v: i32,
        ts: &'a str,
        source: &'static str,
        event: &'static str,
        activity: &'static str,
        app: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        exePath: Option<&'a str>,
        pid: u32,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<&'a str>,
    }

    let client = Client::new();
    let endpoint = format!("{}/event", args.core_url.trim_end_matches('/'));

    info!("Windows collector started. Posting to {endpoint}");

    let mut last_key: Option<(String, u32, String)> = None; // (app, pid, title)
    let mut last_sent_at = Instant::now();

    let mut last_audio: Option<AudioAppInfo> = None;
    let mut last_audio_sent_at = Instant::now();

    let mut last_review_check = Instant::now()
        .checked_sub(Duration::from_secs(args.review_notify_check_seconds))
        .unwrap_or_else(Instant::now);
    let mut review_snooze_until: Option<Instant> = None;
    let mut last_review_notified_block_id: Option<String> = None;

    loop {
        let idle_s = system_idle_seconds();
        if idle_s >= args.idle_cutoff_seconds {
            // Reset key so we emit immediately on resume even if heartbeat isn't due.
            last_key = None;
        } else {
            let fg = foreground_app();
            let pid = fg.pid;
            let title = fg.title;
            let exe_path = fg.exe_path;

            let app = exe_path
                .as_deref()
                .and_then(|p| Path::new(p).file_name())
                .and_then(|s| s.to_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| format!("pid:{pid}"));
            if pid != 0 {
                let title_for_key = if args.send_title {
                    title.clone()
                } else {
                    String::new()
                };
                let key = (app.clone(), pid, title_for_key);
                let due_heartbeat =
                    last_sent_at.elapsed() >= Duration::from_secs(args.heartbeat_seconds);
                if last_key.as_ref() != Some(&key) || due_heartbeat {
                    let ts = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
                    let payload = AppActiveEvent {
                        v: 1,
                        ts: &ts,
                        source: "windows_collector",
                        event: "app_active",
                        app: &app,
                        title: if args.send_title && !title.trim().is_empty() {
                            Some(title.as_str())
                        } else {
                            None
                        },
                        exePath: if args.send_exe_path {
                            exe_path.as_deref()
                        } else {
                            None
                        },
                        pid,
                    };
                    if let Err(e) = client.post(&endpoint).json(&payload).send().await {
                        error!("post failed: {e}");
                    }
                    last_key = Some(key);
                    last_sent_at = Instant::now();
                }
            }
        }

        if args.track_audio {
            let preferred_pid = last_audio.as_ref().map(|a| a.pid);
            let mut audio_poll_failed = false;
            let audio = match active_audio_app(preferred_pid) {
                Ok(v) => v,
                Err(e) => {
                    // Important: do NOT emit app_audio_stop on a transient polling error.
                    // Otherwise Now/Timeline will flicker and falsely end an ongoing audio session.
                    error!("audio poll failed: {e}");
                    audio_poll_failed = true;
                    None
                }
            };

            if audio_poll_failed {
                // Keep previous state until the next successful poll.
            } else if let Some(key) = audio {
                let due_heartbeat =
                    last_audio_sent_at.elapsed() >= Duration::from_secs(args.heartbeat_seconds);
                if last_audio.as_ref().map(|k| (k.pid, k.app.as_str()))
                    != Some((key.pid, key.app.as_str()))
                    || due_heartbeat
                {
                    if last_audio.as_ref().map(|k| (k.pid, k.app.as_str()))
                        != Some((key.pid, key.app.as_str()))
                    {
                        info!("audio app changed: {} (pid {})", key.app, key.pid);
                    }
                    let ts = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
                    let payload = AppAudioEvent {
                        v: 1,
                        ts: &ts,
                        source: "windows_collector",
                        event: "app_audio",
                        activity: "audio",
                        app: &key.app,
                        exePath: if args.send_exe_path {
                            key.exe_path.as_deref()
                        } else {
                            None
                        },
                        pid: key.pid,
                        reason: None,
                    };
                    if let Err(e) = client.post(&endpoint).json(&payload).send().await {
                        error!("post failed: {e}");
                    }
                    last_audio = Some(key);
                    last_audio_sent_at = Instant::now();
                }
            } else if let Some(prev) = last_audio.take() {
                // Explicit stop marker so Core/UI can end background audio immediately.
                info!("audio app stopped: {} (pid {})", prev.app, prev.pid);
                let ts = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
                let payload = AppAudioEvent {
                    v: 1,
                    ts: &ts,
                    source: "windows_collector",
                    event: "app_audio_stop",
                    activity: "audio",
                    app: &prev.app,
                    exePath: if args.send_exe_path {
                        prev.exe_path.as_deref()
                    } else {
                        None
                    },
                    pid: prev.pid,
                    reason: Some("no_active_audio_sessions"),
                };
                if let Err(e) = client.post(&endpoint).json(&payload).send().await {
                    error!("post failed: {e}");
                }
                last_audio_sent_at = Instant::now();
            }
        }

        if args.review_notify && (args.review_notify_when_idle || idle_s < args.idle_cutoff_seconds)
        {
            let check_due = last_review_check.elapsed()
                >= Duration::from_secs(args.review_notify_check_seconds);
            if check_due {
                last_review_check = Instant::now();
                if let Err(e) = maybe_notify_due_review_block(
                    &client,
                    args.core_url.trim_end_matches('/'),
                    args.review_notify_repeat_minutes,
                    args.review_notify_when_paused,
                    &mut last_review_notified_block_id,
                    &mut review_snooze_until,
                )
                .await
                {
                    error!("review notify failed: {e}");
                }
            }
        }

        sleep(Duration::from_millis(args.poll_ms)).await;
    }
}

#[cfg(windows)]
struct MutexGuard(windows_sys::Win32::Foundation::HANDLE);

#[cfg(windows)]
impl Drop for MutexGuard {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(self.0);
        }
    }
}

#[cfg(windows)]
fn ensure_single_instance_mutex() -> anyhow::Result<MutexGuard> {
    use std::ffi::c_void;
    use std::iter;
    use windows_sys::Win32::Foundation::{GetLastError, BOOL, ERROR_ALREADY_EXISTS, HANDLE};

    // Use a direct kernel32 binding instead of relying on windows-sys re-exports.
    // Some toolchains/locks may end up with a windows-sys build that doesn't expose CreateMutexW.
    #[link(name = "kernel32")]
    extern "system" {
        fn CreateMutexW(
            lp_mutex_attributes: *const c_void,
            b_initial_owner: BOOL,
            lp_name: *const u16,
        ) -> HANDLE;
    }

    let name: Vec<u16> = "Local\\WorkTrace.windows_collector"
        .encode_utf16()
        .chain(iter::once(0))
        .collect();

    unsafe {
        let h = CreateMutexW(std::ptr::null(), 0, name.as_ptr());
        if h == std::ptr::null_mut() {
            anyhow::bail!("CreateMutexW_failed");
        }
        let err = GetLastError();
        if err == ERROR_ALREADY_EXISTS {
            windows_sys::Win32::Foundation::CloseHandle(h);
            anyhow::bail!("already_exists");
        }
        Ok(MutexGuard(h))
    }
}

#[cfg(windows)]
async fn maybe_notify_due_review_block(
    client: &reqwest::Client,
    base_url: &str,
    repeat_minutes: u64,
    notify_when_paused: bool,
    last_block_id: &mut Option<String>,
    snooze_until: &mut Option<std::time::Instant>,
) -> anyhow::Result<()> {
    use chrono::Local;
    use serde::de::DeserializeOwned;
    use tokio::time::Duration;

    if let Some(until) = snooze_until {
        if std::time::Instant::now() < *until {
            return Ok(());
        }
    }

    async fn get_ok<T: DeserializeOwned>(client: &reqwest::Client, url: &str) -> anyhow::Result<T> {
        #[derive(serde::Deserialize)]
        struct OkResponse<T> {
            ok: bool,
            data: Option<T>,
        }

        let res = client.get(url).send().await?;
        if !res.status().is_success() {
            anyhow::bail!("http_{}", res.status().as_u16());
        }
        let body: OkResponse<T> = res.json().await?;
        if !body.ok {
            anyhow::bail!("not_ok");
        }
        body.data.ok_or_else(|| anyhow::anyhow!("missing_data"))
    }

    async fn get_ok_opt<T: DeserializeOwned>(
        client: &reqwest::Client,
        url: &str,
    ) -> anyhow::Result<Option<T>> {
        #[derive(serde::Deserialize)]
        struct OkResponse<T> {
            ok: bool,
            data: Option<T>,
        }

        let res = client.get(url).send().await?;
        if !res.status().is_success() {
            anyhow::bail!("http_{}", res.status().as_u16());
        }
        let body: OkResponse<T> = res.json().await?;
        if !body.ok {
            anyhow::bail!("not_ok");
        }
        Ok(body.data)
    }

    #[derive(serde::Deserialize)]
    struct TrackingStatus {
        paused: bool,
    }

    #[derive(serde::Deserialize, Clone)]
    struct TopItem {
        kind: String,
        #[serde(default, alias = "name")]
        entity: String,
        #[serde(default)]
        title: Option<String>,
        seconds: i64,
    }

    #[derive(serde::Deserialize)]
    struct BlockSummary {
        id: String,
        start_ts: String,
        end_ts: String,
        top_items: Vec<TopItem>,
    }

    fn format_hhmm(rfc3339: &str) -> String {
        chrono::DateTime::parse_from_rfc3339(rfc3339)
            .map(|t| t.with_timezone(&Local).format("%H:%M").to_string())
            .unwrap_or_else(|_| "??:??".to_string())
    }

    fn format_duration(seconds: i64) -> String {
        let m = ((seconds + 30) / 60).max(0);
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

    fn display_top_name(it: &TopItem) -> String {
        if it.kind == "domain" {
            let title = it.title.as_deref().unwrap_or("").trim();
            let domain = it.entity.trim();
            if !title.is_empty() && !domain.is_empty() && domain != "__hidden__" {
                return format!("{title} ({domain})");
            }
            if !title.is_empty() {
                return title.to_string();
            }
            if domain == "__hidden__" {
                return "(hidden)".to_string();
            }
            return if domain.is_empty() {
                "(unknown)".to_string()
            } else {
                domain.to_string()
            };
        }

        let raw = it.entity.trim();
        if raw == "__hidden__" {
            return "(hidden)".to_string();
        }
        if raw.is_empty() {
            return "(unknown)".to_string();
        }
        let base = raw.split(|c| c == '\\' || c == '/').last().unwrap_or(raw);
        let lower = base.to_lowercase();
        if lower.ends_with(".exe") {
            base[..base.len().saturating_sub(4)].to_string()
        } else {
            base.to_string()
        }
    }

    let tracking: TrackingStatus = get_ok(client, &format!("{base_url}/tracking/status")).await?;
    if tracking.paused && !notify_when_paused {
        return Ok(());
    }

    let now = Local::now();
    let date = now.format("%Y-%m-%d").to_string();
    let tz_offset_minutes = now.offset().local_minus_utc() / 60;

    let due: Option<BlockSummary> = get_ok_opt(
        client,
        &format!("{base_url}/blocks/due?date={date}&tz_offset_minutes={tz_offset_minutes}"),
    )
    .await?;

    let Some(due) = due else {
        return Ok(());
    };

    let should_notify = match last_block_id.as_deref() {
        None => true,
        Some(prev) => prev != due.id.as_str(),
    };

    if !should_notify && snooze_until.is_some() {
        // Same block, and we're still snoozed (guarded above).
        return Ok(());
    }

    let range = format!(
        "{}–{}",
        format_hhmm(&due.start_ts),
        format_hhmm(&due.end_ts)
    );
    let top = due
        .top_items
        .iter()
        .take(3)
        .map(|it| format!("{} {}", display_top_name(it), format_duration(it.seconds)))
        .collect::<Vec<_>>()
        .join(" · ");
    let top_line = if top.trim().is_empty() {
        "Top: (none)".to_string()
    } else {
        format!("Top: {top}")
    };

    // Best-effort toast notification (click -> open Quick Review via custom protocol).
    //
    // Requires registering `worktrace://` on Windows once (see `dev/install-worktrace-protocol.ps1`).
    // Uses PowerShell AUMID fallback so it works without installer packaging; the toast may show as coming from PowerShell.
    #[cfg(windows)]
    {
        use win_toast_notify::{Action, ActivationType, Duration, Scenario, WinToastNotify};

        let deep_link = format!("worktrace://review?block={}", due.id.as_str());
        let skip_link = format!(
            "worktrace://review?action=skip&block={}",
            due.id.as_str()
        );
        let pause_link = "worktrace://review?action=pause&minutes=15".to_string();
        let _ = WinToastNotify::new()
            .set_open(deep_link.as_str())
            .set_duration(Duration::Long)
            .set_scenario(Scenario::Reminder)
            .set_title("Time to review")
            .set_messages(vec![range.as_str(), top_line.as_str()])
            .set_actions(vec![
                Action {
                    activation_type: ActivationType::Protocol,
                    action_content: "Quick Review".to_string(),
                    arguments: deep_link,
                    image_url: None,
                },
                Action {
                    activation_type: ActivationType::Protocol,
                    action_content: "Skip".to_string(),
                    arguments: skip_link,
                    image_url: None,
                },
                Action {
                    activation_type: ActivationType::Protocol,
                    action_content: "Pause 15m".to_string(),
                    arguments: pause_link,
                    image_url: None,
                },
            ])
            .show();
    }

    *last_block_id = Some(due.id.clone());
    *snooze_until =
        Some(std::time::Instant::now() + Duration::from_secs(repeat_minutes.max(1) * 60));
    Ok(())
}

#[cfg(windows)]
struct ForegroundApp {
    pid: u32,
    title: String,
    exe_path: Option<String>,
}

#[cfg(windows)]
fn system_idle_seconds() -> u64 {
    use windows_sys::Win32::System::SystemInformation::GetTickCount64;
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};

    unsafe {
        let mut lii = LASTINPUTINFO {
            cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
            dwTime: 0,
        };
        if GetLastInputInfo(&mut lii as *mut _) == 0 {
            return 0;
        }

        let now_low = (GetTickCount64() & 0xFFFF_FFFF) as u32;
        let diff_ms = now_low.wrapping_sub(lii.dwTime) as u64;
        diff_ms / 1000
    }
}

#[cfg(windows)]
fn foreground_app() -> ForegroundApp {
    use windows_sys::Win32::Foundation::{CloseHandle, HWND};
    use windows_sys::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetForegroundWindow, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId,
    };

    unsafe {
        let hwnd: HWND = GetForegroundWindow();
        if hwnd == std::ptr::null_mut() {
            return ForegroundApp {
                pid: 0,
                title: String::new(),
                exe_path: None,
            };
        }

        let mut pid: u32 = 0;
        GetWindowThreadProcessId(hwnd, &mut pid);

        let len = GetWindowTextLengthW(hwnd);
        let title = if len > 0 {
            let mut buf = vec![0u16; (len as usize) + 1];
            let read = GetWindowTextW(hwnd, buf.as_mut_ptr(), buf.len() as i32);
            if read > 0 {
                buf.truncate(read as usize);
                String::from_utf16_lossy(&buf)
            } else {
                String::new()
            }
        } else {
            String::new()
        };

        let exe_path = {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if handle == std::ptr::null_mut() {
                None
            } else {
                let mut buf = vec![0u16; 1024];
                let mut size: u32 = buf.len() as u32;
                let ok = QueryFullProcessImageNameW(handle, 0, buf.as_mut_ptr(), &mut size);
                let _ = CloseHandle(handle);
                if ok == 0 || size == 0 {
                    None
                } else {
                    buf.truncate(size as usize);
                    Some(String::from_utf16_lossy(&buf))
                }
            }
        };

        ForegroundApp {
            pid,
            title,
            exe_path,
        }
    }
}

#[cfg(windows)]
fn active_audio_app(preferred_pid: Option<u32>) -> anyhow::Result<Option<AudioAppInfo>> {
    use std::path::Path;
    use windows::core::Interface;
    use windows::Win32::Media::Audio::{
        eMultimedia, eRender, AudioSessionStateActive, IAudioSessionControl2,
        IAudioSessionManager2, IMMDeviceEnumerator, MMDeviceEnumerator,
    };
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED,
    };

    struct ComGuard;
    impl Drop for ComGuard {
        fn drop(&mut self) {
            unsafe { CoUninitialize() };
        }
    }

    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok()? };
    let _guard = ComGuard;

    let enumerator: IMMDeviceEnumerator =
        unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)? };
    let device = unsafe { enumerator.GetDefaultAudioEndpoint(eRender, eMultimedia)? };
    let manager: IAudioSessionManager2 = unsafe { device.Activate(CLSCTX_ALL, None)? };
    let sessions = unsafe { manager.GetSessionEnumerator()? };
    let count = unsafe { sessions.GetCount()? };

    let mut pids: Vec<u32> = Vec::new();
    for i in 0..count {
        let control = unsafe { sessions.GetSession(i)? };
        let state = unsafe { control.GetState()? };
        if state != AudioSessionStateActive {
            continue;
        }
        let Ok(control2) = control.cast::<IAudioSessionControl2>() else {
            continue;
        };
        let pid: u32 = unsafe { control2.GetProcessId()? };
        if pid != 0 {
            pids.push(pid);
        }
    }

    if pids.is_empty() {
        return Ok(None);
    }

    pids.sort_unstable();
    pids.dedup();
    let mut candidates: Vec<AudioAppInfo> = Vec::new();
    for pid in pids {
        let exe_path = query_process_exe_path(pid);
        let app = exe_path
            .as_deref()
            .and_then(|p| Path::new(p).file_name())
            .and_then(|s| s.to_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| format!("pid:{pid}"));

        let lower = app.to_lowercase();
        if lower == "audiodg.exe" || is_browser_exe(lower.as_str()) {
            continue;
        }

        candidates.push(AudioAppInfo { app, pid, exe_path });
    }

    if candidates.is_empty() {
        return Ok(None);
    }

    if let Some(pid) = preferred_pid {
        if let Some(found) = candidates.iter().find(|c| c.pid == pid) {
            return Ok(Some(found.clone()));
        }
    }

    candidates.sort_by_key(|c| c.pid);
    Ok(Some(candidates[0].clone()))
}

#[cfg(windows)]
fn query_process_exe_path(pid: u32) -> Option<String> {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle == std::ptr::null_mut() {
            return None;
        }

        let mut buf = vec![0u16; 1024];
        let mut size: u32 = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(handle, 0, buf.as_mut_ptr(), &mut size);
        let _ = CloseHandle(handle);
        if ok == 0 || size == 0 {
            None
        } else {
            buf.truncate(size as usize);
            Some(String::from_utf16_lossy(&buf))
        }
    }
}

#[cfg(windows)]
fn is_browser_exe(lower_exe: &str) -> bool {
    matches!(
        lower_exe,
        "chrome.exe" | "msedge.exe" | "brave.exe" | "vivaldi.exe" | "opera.exe" | "firefox.exe"
    )
}
