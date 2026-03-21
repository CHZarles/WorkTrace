import "dart:async";

import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../api/core_client.dart";
import "block_detail_page.dart";
import "../theme/tokens.dart";
import "../utils/desktop_agent.dart";
import "../utils/format.dart";
import "../widgets/day_timeline.dart";
import "../widgets/entity_avatar.dart";
import "../widgets/quick_review_sheet.dart";
import "../widgets/recorder_tooltip.dart";

class TodayScreen extends StatefulWidget {
  const TodayScreen({
    super.key,
    required this.client,
    required this.serverUrl,
    required this.onOpenReview,
    this.onOpenSettings,
    this.onOpenReviewQuery,
    this.tutorialNowKey,
    this.tutorialTimelineKey,
    this.isActive = true,
  });

  final CoreClient client;
  final String serverUrl;
  final VoidCallback onOpenReview;
  final VoidCallback? onOpenSettings;
  final Future<void> Function(String query, DateTime day)? onOpenReviewQuery;
  final GlobalKey? tutorialNowKey;
  final GlobalKey? tutorialTimelineKey;
  final bool isActive;

  @override
  State<TodayScreen> createState() => TodayScreenState();
}

enum _TopFilter { all, apps, web }

class _StatItem {
  const _StatItem({
    required this.kind,
    required this.entity,
    required this.label,
    required this.subtitle,
    required this.seconds,
    required this.hasAudio,
  });

  final String kind; // "app" | "domain"
  final String entity; // app id or hostname (for blacklist rules)
  final String label;
  final String? subtitle;
  final int seconds;
  final bool hasAudio;
}

class _TopAgg {
  const _TopAgg({
    required this.focusSeconds,
    required this.audioSeconds,
    required this.items,
    required this.focusSwitches,
    required this.longestFocusStreakSeconds,
  });

  final int focusSeconds;
  final int audioSeconds;
  final List<_StatItem> items;
  final int focusSwitches;
  final int longestFocusStreakSeconds;
}

class _LaneAcc {
  _LaneAcc({
    required this.kind,
    required this.entity,
    required this.label,
    required this.subtitle,
    required this.icon,
  });

  final String kind;
  final String entity;
  final String label;
  final String? subtitle;
  final IconData icon;
  int totalSeconds = 0;
  int firstStartMinute = 1440;
  final List<DayTimelineBar> bars = [];
}

class _FlowItem {
  const _FlowItem({
    required this.kind,
    required this.entity,
    required this.label,
    required this.subtitle,
    required this.start,
    required this.end,
    required this.seconds,
    required this.icon,
  });

  final String kind; // "app" | "domain"
  final String entity;
  final String label;
  final String? subtitle;
  final DateTime start;
  final DateTime end;
  final int seconds;
  final IconData icon;
}

class _TimelineViewState {
  const _TimelineViewState({required this.zoom, required this.centerFrac});

  final double zoom;
  final double centerFrac;
}

class TodayScreenState extends State<TodayScreen> {
  static const _prefSnoozeUntilMs = "reviewSnoozeUntilMs";
  static const _prefSnoozeBlockId = "reviewSnoozeBlockId";
  static const _reviewLastBlockEndGraceSeconds = 30;

  static const _nowPollSeconds = 5;
  static const _blocksPollSeconds = 60;

  _TopFilter _topFilter = _TopFilter.all;

  DateTime _day = DateTime.now();

  bool _coreStoreTitles = false;
  bool _coreStoreExePath = false;
  int _blockSeconds = 45 * 60;
  int _reviewMinSeconds = 5 * 60;
  int _reviewRepeatMinutes = 10;
  bool _reviewNotifyWhenPaused = false;
  bool _loading = false;
  String? _error;
  DateTime? _coreSettingsUpdatedAt;
  List<TimelineSegment> _segments = const [];
  int _segmentsVersion = 0;
  bool _hasWebSeg = false;
  bool _hasWebTitleSeg = false;
  List<BlockSummary> _blocks = const [];
  BlockSummary? _dueBlock;
  int _nowFocusTtlSeconds = 3 * 60;
  int _nowAudioTtlSeconds = 120;
  int? _latestAnyAgeSeconds;
  EventRecord? _nowFocusApp;
  EventRecord? _nowUsingTab;
  EventRecord? _nowBackgroundAudio;
  EventRecord? _latestAppEvent;
  EventRecord? _latestTabEvent;
  EventRecord? _latestAudioEvent;
  EventRecord? _latestAudioStopEvent;
  EventRecord? _latestAppAudioEvent;
  EventRecord? _latestAppAudioStopEvent;
  final Map<String, String> _latestTitleByKey = {};

  Timer? _nowTimer;
  Timer? _blocksTimer;
  Timer? _autoRetryTimer;
  int _autoRetryAttempts = 0;
  bool _promptShowing = false;
  bool _refreshingNow = false;
  bool _refreshingBlocks = false;
  bool _timelineLoading = false;
  bool _timelineShowAll = false;
  bool _timelineSortByTime = false;
  double _timelineZoom = 1.0;
  final ScrollController _scrollV = ScrollController();
  final ScrollController _timelineH = ScrollController();
  _TimelineViewState? _timelineSavedView;
  DateTime? _nowUpdatedAt;
  DateTime? _blocksUpdatedAt;
  int? _lastAnyEventId;
  DateTime? _lastAutoBlocksRefreshAt;
  int? _snoozeUntilMs;
  String? _snoozeBlockId;
  String? _loadedDayKey;
  String? _timelineDayKey;
  int _timelineRequestSeq = 0;

  bool _rulesLoading = true;
  final Map<String, int> _ruleIdByKey = {};
  final Set<String> _blockedKeys = {};

  bool _agentBusy = false;

  String _topAggCacheKey = "";
  _TopAgg? _topAggCache;

  String _timelineCacheKey = "";
  ({List<DayTimelineLane> lanes, int totalCount})? _timelineCache;

  String _flowCacheKey = "";
  List<_FlowItem>? _flowCache;

  String _dayTimelineWidgetKey = "";
  Widget? _dayTimelineWidgetCache;

  @override
  void initState() {
    super.initState();
    _loadReminderPrefs();
    _loadCoreSettings();
    _loadRules();
    refresh(silent: true, triggerReminder: _viewingToday());
    _nowTimer = Timer.periodic(const Duration(seconds: _nowPollSeconds), (_) {
      if (!widget.isActive) return;
      if (!_viewingToday()) return;
      _refreshNow(silent: true, kickBlocksOnChange: true);
    });
    _blocksTimer =
        Timer.periodic(const Duration(seconds: _blocksPollSeconds), (_) {
      if (!widget.isActive) return;
      if (!_viewingToday()) return;
      _refreshBlocks(silent: true, triggerReminder: true);
    });
  }

  @override
  void didUpdateWidget(covariant TodayScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverUrl != widget.serverUrl) {
      _loadRules();
      refresh(triggerReminder: _viewingToday());
    }
    if (!oldWidget.isActive && widget.isActive) {
      refresh(silent: true, triggerReminder: _viewingToday());
    }
  }

  @override
  void dispose() {
    _nowTimer?.cancel();
    _blocksTimer?.cancel();
    _autoRetryTimer?.cancel();
    _scrollV.dispose();
    _timelineH.dispose();
    super.dispose();
  }

  Future<void> _scrollToTutorialKey(GlobalKey? key) async {
    if (key == null) return;
    for (var i = 0; i < 20; i++) {
      if (_scrollV.hasClients) break;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!_scrollV.hasClients) return;

    Future<void> ensureIfPossible() async {
      final ctx = key.currentContext;
      if (ctx == null) return;
      try {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.15,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await WidgetsBinding.instance.endOfFrame;
      } catch (_) {
        // best effort
      }
    }

    await ensureIfPossible();
    if (key.currentContext != null) return;

    // Deterministic: start near top, then gradually scroll down until the target is built.
    try {
      _scrollV.jumpTo(0);
    } catch (_) {
      // ignore
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await WidgetsBinding.instance.endOfFrame;

    for (var i = 0; i < 18; i++) {
      await ensureIfPossible();
      if (key.currentContext != null) return;
      if (!_scrollV.hasClients) return;

      final pos = _scrollV.position;
      final step = (pos.viewportDimension * 0.85).clamp(180.0, 900.0);
      final next =
          (pos.pixels + step).clamp(0.0, pos.maxScrollExtent).toDouble();
      if ((next - pos.pixels).abs() < 1) return;

      try {
        await _scrollV.animateTo(
          next,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        );
      } catch (_) {
        return;
      }
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<void> scrollToTutorialNow() async {
    await _scrollToTutorialKey(widget.tutorialNowKey);
  }

  Future<void> scrollToTutorialTimeline() async {
    await _scrollToTutorialKey(widget.tutorialTimelineKey);
  }

  DateTime _normalizeDay(DateTime d) => DateTime(d.year, d.month, d.day);

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  DateTime _todayDay() => _normalizeDay(DateTime.now());

  bool _viewingToday() => _isSameDay(_normalizeDay(_day), _todayDay());

  bool _serverLooksLikeLocalhost() {
    final uri = Uri.tryParse(widget.serverUrl.trim());
    if (uri == null) return false;
    final host = uri.host.trim().toLowerCase();
    return host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0";
  }

  String _dateLocal(DateTime d) {
    final y = d.year.toString().padLeft(4, "0");
    final m = d.month.toString().padLeft(2, "0");
    final dd = d.day.toString().padLeft(2, "0");
    return "$y-$m-$dd";
  }

  bool _isLocalServerUrl() {
    final u = Uri.tryParse(widget.serverUrl.trim());
    if (u == null) return false;
    final host = u.host.trim().toLowerCase();
    return host == "127.0.0.1" ||
        host == "localhost" ||
        host == "0.0.0.0" ||
        host == "::1";
  }

  Future<void> _startLocalAgent() async {
    final agent = DesktopAgent.instance;
    if (!agent.isAvailable) return;
    if (!_isLocalServerUrl()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text("Agent can only start when Server URL is localhost.")),
      );
      return;
    }

    setState(() => _agentBusy = true);
    try {
      final res = await agent.start(
          coreUrl: widget.serverUrl, restart: false, sendTitle: false);
      if (!mounted) return;
      final msg = res.ok ? "Agent started" : "Agent start failed";
      final details = (res.message ?? "").trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          showCloseIcon: true,
          content: Text(details.isEmpty ? msg : "$msg: $details"),
        ),
      );
      await refresh(silent: false, triggerReminder: _viewingToday());
    } finally {
      if (mounted) setState(() => _agentBusy = false);
    }
  }

  int _tzOffsetMinutesForDay(DateTime d) {
    // Prefer noon to avoid DST edge cases near midnight.
    final noon = DateTime(d.year, d.month, d.day, 12);
    return noon.timeZoneOffset.inMinutes;
  }

  bool _canGoNextDay() {
    final day = _normalizeDay(_day);
    return day.isBefore(_todayDay());
  }

  Future<void> _setDay(DateTime d) async {
    final next = _normalizeDay(d);
    final viewingToday = _isSameDay(next, _todayDay());

    setState(() {
      _day = next;
      if (!viewingToday) {
        _latestAnyAgeSeconds = null;
        _nowFocusApp = null;
        _nowUsingTab = null;
        _nowBackgroundAudio = null;
        _latestAppEvent = null;
        _latestTabEvent = null;
        _latestAudioEvent = null;
        _latestAudioStopEvent = null;
        _latestAppAudioEvent = null;
        _latestAppAudioStopEvent = null;
        _latestTitleByKey.clear();
        _nowUpdatedAt = null;
      }
    });

    await refresh(silent: false, triggerReminder: viewingToday);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _normalizeDay(_day),
      firstDate: DateTime(2020, 1, 1),
      lastDate: _todayDay(),
    );
    if (picked == null) return;
    await _setDay(picked);
  }

  bool _isReviewed(BlockSummary b) {
    final r = b.review;
    if (r == null) return false;
    if (r.skipped) return true;
    final doing = (r.doing ?? "").trim();
    final output = (r.output ?? "").trim();
    final next = (r.next ?? "").trim();
    return doing.isNotEmpty ||
        output.isNotEmpty ||
        next.isNotEmpty ||
        r.tags.isNotEmpty;
  }

  BlockSummary? _computeDueBlock(List<BlockSummary> blocks) {
    if (!_viewingToday() || blocks.isEmpty) return null;

    final now = DateTime.now();
    final minSeconds = _reviewMinSecondsSafe();
    final blockSeconds = _blockLengthSecondsSafe();

    for (var i = blocks.length - 1; i >= 0; i--) {
      final block = blocks[i];
      if (block.totalSeconds < minSeconds) continue;
      if (_isReviewed(block)) continue;

      final hasNext = i < blocks.length - 1;
      if (hasNext) return block;

      if (block.totalSeconds >= blockSeconds) return block;

      final end = DateTime.tryParse(block.endTs)?.toLocal();
      if (end == null) continue;
      if (now.difference(end).inSeconds > _reviewLastBlockEndGraceSeconds) {
        return block;
      }
    }

    return null;
  }

  _TopAgg _buildTopAggFromBlocks() {
    final accSeconds = <String, int>{};
    final accHasAudio = <String, bool>{};
    final accKind = <String, String>{};
    final accEntity = <String, String>{};
    final accLabel = <String, String>{};
    final accSubtitle = <String, String?>{};

    var focusSeconds = 0;
    var audioSeconds = 0;
    var longestFocusStreakSeconds = 0;

    void addItem(TopItem it, {required bool hasAudio}) {
      final kind = it.kind == "domain" ? "domain" : "app";
      final rawEntity = it.entity.trim();
      if (rawEntity.isEmpty) return;

      final entity = kind == "domain" ? rawEntity.toLowerCase() : rawEntity;
      final label = displayTopItemName(it).trim();
      if (label.isEmpty) return;

      String? subtitle;
      if (kind == "domain") {
        final domainLabel = displayEntity(entity);
        if (label.toLowerCase() != domainLabel.toLowerCase()) {
          subtitle = domainLabel;
        }
      } else if (_coreStoreTitles) {
        final title = (it.title ?? "").trim();
        if (title.isNotEmpty) {
          final appLabel = displayEntity(entity);
          if (!_isBrowserLabel(appLabel)) {
            final appLc = appLabel.toLowerCase();
            final isVscode = appLc == "code" ||
                appLc == "vscode" ||
                title.contains("Visual Studio Code");
            if (isVscode) {
              final ws = extractVscodeWorkspace(title);
              subtitle = (ws != null && ws.trim().isNotEmpty)
                  ? "Workspace: ${ws.trim()}"
                  : title;
            } else {
              subtitle = title;
            }
          }
        }
      }

      final key = "$kind|$entity|$label";
      accSeconds[key] = (accSeconds[key] ?? 0) + it.seconds;
      accHasAudio[key] = (accHasAudio[key] ?? false) || hasAudio;
      accKind[key] = kind;
      accEntity[key] = entity;
      accLabel[key] = label;
      accSubtitle[key] = subtitle;
    }

    for (final block in _blocks) {
      focusSeconds += block.totalSeconds;
      if (block.totalSeconds > longestFocusStreakSeconds) {
        longestFocusStreakSeconds = block.totalSeconds;
      }
      for (final item in block.topItems) {
        addItem(item, hasAudio: false);
      }

      final bgSeconds = block.backgroundSeconds ?? 0;
      if (bgSeconds > 0) {
        audioSeconds += bgSeconds;
      }
      for (final item in block.backgroundTopItems) {
        addItem(item, hasAudio: true);
      }
    }

    final items = <_StatItem>[];
    for (final key in accSeconds.keys) {
      items.add(
        _StatItem(
          kind: accKind[key] ?? "",
          entity: accEntity[key] ?? "",
          label: accLabel[key] ?? "",
          subtitle: accSubtitle[key],
          seconds: accSeconds[key] ?? 0,
          hasAudio: accHasAudio[key] ?? false,
        ),
      );
    }
    items.sort((a, b) => b.seconds.compareTo(a.seconds));

    return _TopAgg(
      focusSeconds: focusSeconds,
      audioSeconds: audioSeconds,
      items: items,
      focusSwitches: 0,
      longestFocusStreakSeconds: longestFocusStreakSeconds,
    );
  }

  Future<void> _loadReminderPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _snoozeUntilMs = prefs.getInt(_prefSnoozeUntilMs);
        _snoozeBlockId = prefs.getString(_prefSnoozeBlockId);
      });
    } catch (_) {
      // best effort
    }
  }

  Future<void> _loadCoreSettings({bool force = false}) async {
    if (!force && _coreSettingsUpdatedAt != null) {
      final d = DateTime.now().difference(_coreSettingsUpdatedAt!);
      if (d < const Duration(seconds: 45)) return;
    }
    try {
      final s = await widget.client.settings();
      if (!mounted) return;
      setState(() {
        _coreStoreTitles = s.storeTitles;
        _coreStoreExePath = s.storeExePath;
        _blockSeconds = s.blockSeconds;
        _reviewMinSeconds = s.reviewMinSeconds;
        _reviewRepeatMinutes = s.reviewNotifyRepeatMinutes;
        _reviewNotifyWhenPaused = s.reviewNotifyWhenPaused;
        _dueBlock = _computeDueBlock(_blocks);
        _coreSettingsUpdatedAt = DateTime.now();
      });
    } catch (_) {
      // best effort
    }
  }

  bool _isTransientError(String msg) {
    final s = msg.toLowerCase();
    if (s.contains("health_failed")) return true;
    if (s.contains("connection") || s.contains("socket")) return true;
    if (s.contains("refused") ||
        s.contains("timed out") ||
        s.contains("timeout")) {
      return true;
    }
    if (s.contains("http_502") ||
        s.contains("http_503") ||
        s.contains("http_504")) {
      return true;
    }
    return false;
  }

  void _scheduleAutoRetryIfNeeded(String msg) {
    if (!mounted) return;
    if (_autoRetryTimer != null) return;
    if (!_serverLooksLikeLocalhost()) return;
    if (!_isTransientError(msg)) return;
    if (_autoRetryAttempts >= 9) return;

    final backoffMs = (350 * (1 << _autoRetryAttempts)).clamp(350, 5000);
    _autoRetryAttempts += 1;
    _autoRetryTimer = Timer(Duration(milliseconds: backoffMs), () {
      _autoRetryTimer = null;
      if (!mounted) return;
      refresh(silent: true, triggerReminder: false);
    });
  }

  int _blockLengthSecondsSafe() {
    final s = _blockSeconds;
    if (s <= 0) return 45 * 60;
    return s.clamp(60, 24 * 60 * 60);
  }

  int _reviewMinSecondsSafe() {
    final s = _reviewMinSeconds;
    if (s <= 0) return 5 * 60;
    return s.clamp(60, 4 * 60 * 60);
  }

  int _reviewRepeatMinutesSafe() {
    final m = _reviewRepeatMinutes;
    if (m <= 0) return 10;
    return m.clamp(1, 24 * 60);
  }

  String _dueReasonLong(BlockSummary b) {
    final idx = _blocks.indexWhere((x) => x.id == b.id);
    final hasNext = idx >= 0 && idx < (_blocks.length - 1);
    if (hasNext) {
      return "You already moved on to a new block after this one.";
    }
    if (b.totalSeconds >= _blockLengthSecondsSafe()) {
      final blockMin = (_blockLengthSecondsSafe() / 60).round().clamp(1, 9999);
      return "The current block reached the block length (${blockMin}m).";
    }
    final age = _ageText(b.endTs);
    if (age.isNotEmpty) {
      return "The last block ended ($age) and is still pending.";
    }
    return "The last block ended and is still pending.";
  }

  String _dueReasonShort(BlockSummary b) {
    final idx = _blocks.indexWhere((x) => x.id == b.id);
    final hasNext = idx >= 0 && idx < (_blocks.length - 1);
    if (hasNext) return "You moved on to the next block";
    if (b.totalSeconds >= _blockLengthSecondsSafe())
      return "Current block reached block length";
    return "Last block ended";
  }

  String _ruleKey(String kind, String value) => "$kind|$value";

  String _normalizeDomainForRule(String raw) {
    var d = raw.trim().toLowerCase();
    if (d.startsWith("www.") && d.length > 4) d = d.substring(4);
    return d;
  }

  bool _isBlockedDomain(String domain) {
    final d = domain.trim().toLowerCase();
    if (d.isEmpty) return false;

    if (_blockedKeys.contains(_ruleKey("domain", d))) return true;

    // Suffix match: a rule for `youtube.com` should also flag `www.youtube.com` / `m.youtube.com` as blocked.
    var candidate = d;
    while (true) {
      final i = candidate.indexOf(".");
      if (i <= 0) break;
      final rest = candidate.substring(i + 1);
      if (!rest.contains(".")) break;
      candidate = rest;
      if (_blockedKeys.contains(_ruleKey("domain", candidate))) return true;
    }

    return false;
  }

  bool _isBlockedEntity({required String kind, required String entity}) {
    if (kind != "domain" && kind != "app") return false;
    if (kind == "domain") return _isBlockedDomain(entity);
    return _blockedKeys.contains(_ruleKey("app", entity));
  }

  Future<void> _loadRules() async {
    setState(() => _rulesLoading = true);
    try {
      final rules = await widget.client.privacyRules();
      if (!mounted) return;
      setState(() {
        _ruleIdByKey.clear();
        _blockedKeys.clear();
        for (final r in rules) {
          final value = r.kind == "domain" ? r.value.toLowerCase() : r.value;
          final key = _ruleKey(r.kind, value);
          _ruleIdByKey[key] = r.id;
          _blockedKeys.add(key);
        }
      });
    } catch (_) {
      // best effort
    } finally {
      if (mounted) setState(() => _rulesLoading = false);
    }
  }

  Future<void> _blacklistEntity({
    required String kind,
    required String entity,
    required String displayName,
  }) async {
    if (kind != "domain" && kind != "app") return;
    final value = kind == "domain" ? _normalizeDomainForRule(entity) : entity;
    final key = _ruleKey(kind, value);

    if (_blockedKeys.contains(key)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Already blacklisted: $displayName")),
      );
      return;
    }

    try {
      final rule = await widget.client.upsertPrivacyRule(
        PrivacyRuleUpsert(kind: kind, value: value, action: "drop"),
      );
      if (!mounted) return;
      setState(() {
        _blockedKeys.add(key);
        _ruleIdByKey[key] = rule.id;
      });
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          persist: false,
          showCloseIcon: true,
          content: Text("Blacklisted: $displayName"),
          action: SnackBarAction(
            label: "Undo",
            onPressed: () async {
              final id = _ruleIdByKey[key];
              if (id == null) return;
              try {
                await widget.client.deletePrivacyRule(id);
                if (!mounted) return;
                setState(() {
                  _blockedKeys.remove(key);
                  _ruleIdByKey.remove(key);
                });
              } catch (_) {}
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Blacklist failed: $e")),
      );
    }
  }

  String? _subtitleForAppEntity(String appEntity) {
    if (!_coreStoreTitles || !_viewingToday()) return null;
    final title = _latestTitleByKey[_ruleKey("app", appEntity)];
    if (title == null || title.trim().isEmpty) return null;

    final app = displayEntity(appEntity).toLowerCase();
    final isBrowser = app == "chrome" ||
        app == "msedge" ||
        app == "edge" ||
        app == "brave" ||
        app == "vivaldi" ||
        app == "opera" ||
        app == "firefox";
    if (isBrowser) return null;

    final t = title.trim();
    if (t.contains("Visual Studio Code") || app == "code" || app == "vscode") {
      final ws = extractVscodeWorkspace(t);
      if (ws != null && ws.trim().isNotEmpty) return "Workspace: ${ws.trim()}";
    }
    return t;
  }

  String? _subtitleForDomainEntity(String domain) {
    if (!_coreStoreTitles || !_viewingToday()) return null;
    final title = _latestTitleByKey[_ruleKey("domain", domain.toLowerCase())];
    if (title == null || title.trim().isEmpty) return null;
    final t = normalizeWebTitle(domain, title);
    return t.isEmpty ? null : t;
  }

  _TopAgg _topAggCached() {
    final dayKey = "${_day.year}-${_day.month}-${_day.day}";
    final key = "$dayKey|$_segmentsVersion|${_coreStoreTitles ? 1 : 0}";
    final cached = _topAggCache;
    if (cached != null && key == _topAggCacheKey) return cached;

    final next = _buildTopAgg();
    _topAggCacheKey = key;
    _topAggCache = next;
    return next;
  }

  _TopAgg _buildTopAgg() {
    if (_segments.isEmpty) {
      return _buildTopAggFromBlocks();
    }

    final accSeconds = <String, int>{};
    final accHasAudio = <String, bool>{};
    final accKind = <String, String>{};
    final accEntity = <String, String>{};
    final accLabel = <String, String>{};
    final accSubtitle = <String, String?>{};

    var focusSeconds = 0;
    var audioSeconds = 0;
    var focusSwitches = 0;
    var longestFocusStreakSeconds = 0;
    String? lastFocusKey;

    for (final s in _segments) {
      final kind = s.kind;
      final entity = s.entity.trim();
      if (kind != "app" && kind != "domain") continue;
      if (entity.isEmpty) continue;
      if (s.seconds <= 0) continue;

      final isAudio = s.activity == "audio";
      if (isAudio) {
        audioSeconds += s.seconds;
      } else {
        focusSeconds += s.seconds;
      }

      String key;
      String label;
      String? subtitle;

      if (kind == "domain") {
        final domain = entity.toLowerCase();
        final rawTitle = (s.title ?? "").trim();
        final normTitle =
            _coreStoreTitles ? normalizeWebTitle(domain, rawTitle) : "";
        if (_coreStoreTitles && normTitle.isNotEmpty) {
          key = "domain|$domain|$normTitle";
          label = normTitle;
          subtitle = displayEntity(domain);
        } else {
          key = "domain|$domain";
          label = displayEntity(domain);
          subtitle = null;
        }
      } else {
        key = "app|$entity";
        label = displayEntity(entity);
        subtitle = null;
      }

      if (!isAudio) {
        if (s.seconds > longestFocusStreakSeconds) {
          longestFocusStreakSeconds = s.seconds;
        }
        if (lastFocusKey != null && key != lastFocusKey) {
          focusSwitches += 1;
        }
        lastFocusKey = key;
      }

      accSeconds[key] = (accSeconds[key] ?? 0) + s.seconds;
      accHasAudio[key] = (accHasAudio[key] ?? false) || isAudio;
      accKind[key] = kind;
      accEntity[key] = kind == "domain" ? entity.toLowerCase() : entity;
      accLabel[key] = label;
      accSubtitle[key] = subtitle;
    }

    final items = <_StatItem>[];
    for (final key in accSeconds.keys) {
      items.add(
        _StatItem(
          kind: accKind[key] ?? "",
          entity: accEntity[key] ?? "",
          label: accLabel[key] ?? "",
          subtitle: accSubtitle[key],
          seconds: accSeconds[key] ?? 0,
          hasAudio: accHasAudio[key] ?? false,
        ),
      );
    }
    items.sort((a, b) => b.seconds.compareTo(a.seconds));
    return _TopAgg(
      focusSeconds: focusSeconds,
      audioSeconds: audioSeconds,
      items: items,
      focusSwitches: focusSwitches,
      longestFocusStreakSeconds: longestFocusStreakSeconds,
    );
  }

  IconData _iconForAppLabel(String label) {
    final name = label.toLowerCase();
    if (name.contains("code") || name.contains("vscode")) return Icons.code;
    if (name.contains("chrome") ||
        name.contains("edge") ||
        name.contains("brave") ||
        name.contains("vivaldi") ||
        name.contains("opera") ||
        name.contains("firefox")) {
      return Icons.public;
    }
    if (name.contains("explorer") || name == "files" || name.contains("finder"))
      return Icons.folder_outlined;
    if (name.contains("powershell") ||
        name == "pwsh" ||
        name == "cmd" ||
        name.contains("terminal")) return Icons.terminal;
    if (name.contains("qqmusic") ||
        name.contains("music") ||
        name.contains("spotify")) return Icons.music_note_outlined;
    if (name.contains("wechat") ||
        name.contains("weixin") ||
        name == "qq" ||
        name.contains("telegram")) return Icons.chat_bubble_outline;
    if (name.contains("slack") ||
        name.contains("discord") ||
        name.contains("teams") ||
        name.contains("telegram")) {
      return Icons.chat_bubble_outline;
    }
    if (name.contains("zoom") ||
        name.contains("meet") ||
        name.contains("webex")) return Icons.video_call_outlined;
    if (name.contains("figma") ||
        name.contains("sketch") ||
        name.contains("xd")) return Icons.design_services_outlined;
    if (name.contains("notion") ||
        name.contains("obsidian") ||
        name.contains("notes")) return Icons.note_alt_outlined;
    if (name.contains("excel") ||
        name.contains("word") ||
        name.contains("powerpoint")) return Icons.description_outlined;
    if (name.contains("steam") ||
        name.contains("epic") ||
        name.contains("battle.net")) return Icons.sports_esports_outlined;
    return Icons.apps;
  }

  bool _isBrowserLabel(String label) {
    final v = label.toLowerCase();
    return v == "chrome" ||
        v == "msedge" ||
        v == "edge" ||
        v == "brave" ||
        v == "vivaldi" ||
        v == "opera" ||
        v == "firefox";
  }

  IconData _iconForStatItem(_StatItem it) {
    if (it.kind == "domain") return Icons.public;
    if (it.kind == "app") return _iconForAppLabel(it.label);
    return Icons.category_outlined;
  }

  String? _subtitleForStatItem(_StatItem it) {
    if (!_coreStoreTitles) return null;
    if (!_viewingToday()) return it.subtitle;

    if (it.kind == "app") {
      final v = _subtitleForAppEntity(it.entity);
      return (v == null || v.trim().isEmpty) ? it.subtitle : v;
    }

    if (it.kind == "domain") {
      final domain = it.entity.toLowerCase();
      final domainLabel = displayEntity(domain);
      final label = it.label.trim();
      final looksLikeTitle =
          label.isNotEmpty && label.toLowerCase() != domainLabel.toLowerCase();
      if (looksLikeTitle) return domainLabel;
      final v = _subtitleForDomainEntity(domain);
      return (v == null || v.trim().isEmpty) ? it.subtitle : v;
    }

    return it.subtitle;
  }

  List<_StatItem> _applyTopFilter(List<_StatItem> items) {
    switch (_topFilter) {
      case _TopFilter.all:
        return items;
      case _TopFilter.apps:
        return items.where((it) => it.kind == "app").toList();
      case _TopFilter.web:
        return items.where((it) => it.kind == "domain").toList();
    }
  }

  Future<void> _setSnooze(
      {required String blockId, required Duration duration}) async {
    final until = DateTime.now().add(duration).millisecondsSinceEpoch;
    _snoozeUntilMs = until;
    _snoozeBlockId = blockId;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefSnoozeUntilMs, until);
      await prefs.setString(_prefSnoozeBlockId, blockId);
    } catch (_) {
      // best effort
    }
  }

  Future<void> _setSkipped(BlockSummary b, {required bool skipped}) async {
    try {
      final r = b.review;
      await widget.client.upsertReview(
        ReviewUpsert(
          blockId: b.id,
          skipped: skipped,
          skipReason: null,
          doing: r?.doing,
          output: r?.output,
          next: r?.next,
          tags: r?.tags ?? const [],
        ),
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          persist: false,
          showCloseIcon: true,
          content: Text(skipped ? "Skipped this block" : "Restored this block"),
          action: SnackBarAction(
            label: "Undo",
            onPressed: () => _setSkipped(b, skipped: !skipped),
          ),
        ),
      );
      await refresh(silent: true, triggerReminder: false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Action failed: $e")));
    }
  }

  Future<void> _openBlock(BlockSummary b) async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BlockDetailPage(client: widget.client, block: b),
      ),
    );
    if (ok == true) {
      await refresh(silent: true, triggerReminder: false);
    }
  }

  Future<void> _openQuickReview(BlockSummary b) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => QuickReviewSheet(client: widget.client, block: b),
    );
    if (ok == true) {
      await refresh(silent: true, triggerReminder: false);
    }
  }

  BlockSummary? _findBlockForTimelineBar(DayTimelineBar bar) {
    DateTime startUtc;
    DateTime endUtc;
    try {
      startUtc = DateTime.parse(bar.startTs).toUtc();
      endUtc = DateTime.parse(bar.endTs).toUtc();
    } catch (_) {
      return null;
    }
    if (!endUtc.isAfter(startUtc)) return null;

    var bestOverlap = 0;
    BlockSummary? best;
    for (final b in _blocks) {
      DateTime bs;
      DateTime be;
      try {
        bs = DateTime.parse(b.startTs).toUtc();
        be = DateTime.parse(b.endTs).toUtc();
      } catch (_) {
        continue;
      }
      if (!be.isAfter(bs)) continue;

      final overlapStart = startUtc.isAfter(bs) ? startUtc : bs;
      final overlapEnd = endUtc.isBefore(be) ? endUtc : be;
      final sec = overlapEnd.difference(overlapStart).inSeconds;
      if (sec > bestOverlap) {
        bestOverlap = sec;
        best = b;
      }
    }
    return bestOverlap > 0 ? best : null;
  }

  Future<void> _maybePromptDueBlock(BlockSummary b) async {
    if (_promptShowing) return;
    final snoozeUntil = _snoozeUntilMs;
    if (_snoozeBlockId == b.id && snoozeUntil != null) {
      if (DateTime.now().millisecondsSinceEpoch < snoozeUntil) return;
    }

    if (!_reviewNotifyWhenPaused) {
      try {
        final status = await widget.client.trackingStatus();
        if (status.paused) return;
      } catch (_) {
        // best effort: if tracking status can't be loaded, keep current behavior.
      }
    }

    _promptShowing = true;
    try {
      final top = _blockTopLine(b);
      final title = "${formatHHMM(b.startTs)}–${formatHHMM(b.endTs)}";
      final dur = formatDuration(b.totalSeconds);
      final minMin = (_reviewMinSecondsSafe() / 60).ceil().clamp(1, 9999);
      final blockMin = (_blockLengthSecondsSafe() / 60).round().clamp(1, 9999);
      final repeatM = _reviewRepeatMinutesSafe();
      final why = _dueReasonLong(b);

      final action = await showDialog<String>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          title: const Text("Time to review"),
          content: Text(
            "$title · $dur\n\nTop: $top\n\n"
            "Why now:\n"
            "• A block becomes due when it's ≥ ${minMin}m and not reviewed/skipped.\n"
            "• Triggers when you move on to a new block, or when the current block reaches ${blockMin}m.\n"
            "• This reminder: $why\n\n"
            "Repeat limit: ${repeatM}m per block.\n"
            "Tune: Settings → Review reminders.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, "settings"),
              child: const Text("Settings"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, "skip"),
              child: const Text("Skip"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, "pause15"),
              child: const Text("Pause 15m"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, "snooze"),
              child: Text("Snooze ${repeatM}m"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, "review"),
              child: const Text("Quick review"),
            ),
          ],
        ),
      );

      if (!mounted) return;
      if (action == "review") {
        await _openQuickReview(b);
      } else if (action == "settings") {
        await _setSnooze(blockId: b.id, duration: Duration(minutes: repeatM));
        widget.onOpenSettings?.call();
      } else if (action == "skip") {
        await _setSkipped(b, skipped: true);
      } else if (action == "pause15") {
        try {
          await widget.client.pauseTracking(minutes: 15);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                duration: Duration(seconds: 4),
                showCloseIcon: true,
                content: Text("Paused 15m")),
          );
          await refresh(silent: true, triggerReminder: false);
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text("Pause failed: $e")));
        }
      } else if (action == "snooze") {
        await _setSnooze(blockId: b.id, duration: Duration(minutes: repeatM));
      } else {
        // Treat dismiss as snooze to avoid nagging.
        await _setSnooze(blockId: b.id, duration: Duration(minutes: repeatM));
      }
    } finally {
      _promptShowing = false;
    }
  }

  Future<void> _refreshNow(
      {bool silent = false, bool kickBlocksOnChange = false}) async {
    if (_refreshingNow) return;
    _refreshingNow = true;
    try {
      final snap = await widget.client.now();
      final latestAnyId = snap.latestEventId;
      final shouldUpdate =
          latestAnyId != _lastAnyEventId || _nowUpdatedAt == null;
      if (!shouldUpdate) return;

      final latestAnyAgeSeconds = snap.latestEventAgeSeconds;
      final focusTtlSeconds = snap.focusTtlSeconds;
      final audioTtlSeconds = snap.audioTtlSeconds;
      final nowFocusApp = snap.nowFocusApp;
      final nowUsingTab = snap.nowUsingTab;
      final nowBackgroundAudio = snap.nowBackgroundAudio;
      final latestApp = snap.appActive;
      final latestTab = snap.tabFocus;
      final latestAudio = snap.tabAudio;
      final latestAudioStop = snap.tabAudioStop;
      final latestAppAudio = snap.appAudio;
      final latestAppAudioStop = snap.appAudioStop;
      final latestTitles = snap.latestTitles;
      if (!mounted) return;
      final now = DateTime.now();
      final anyChanged = latestAnyId != null && latestAnyId != _lastAnyEventId;
      final canAutoRefreshBlocks = kickBlocksOnChange &&
          anyChanged &&
          _viewingToday() &&
          !_refreshingBlocks &&
          _blocksUpdatedAt != null &&
          (_lastAutoBlocksRefreshAt == null ||
              now.difference(_lastAutoBlocksRefreshAt!) >
                  const Duration(seconds: 10));
      setState(() {
        _nowFocusTtlSeconds = focusTtlSeconds;
        _nowAudioTtlSeconds = audioTtlSeconds;
        _latestAnyAgeSeconds = latestAnyAgeSeconds;
        _nowFocusApp = nowFocusApp;
        _nowUsingTab = nowUsingTab;
        _nowBackgroundAudio = nowBackgroundAudio;
        _latestAppEvent = latestApp;
        _latestTabEvent = latestTab;
        _latestAudioEvent = latestAudio;
        _latestAudioStopEvent = latestAudioStop;
        _latestAppAudioEvent = latestAppAudio;
        _latestAppAudioStopEvent = latestAppAudioStop;
        _latestTitleByKey
          ..clear()
          ..addAll(latestTitles);
        _nowUpdatedAt = now;
        _lastAnyEventId = latestAnyId;
        if (canAutoRefreshBlocks) _lastAutoBlocksRefreshAt = now;
      });

      if (canAutoRefreshBlocks) {
        unawaited(_refreshBlocks(silent: true, triggerReminder: false));
      }
    } catch (_) {
      // best effort (Now card shouldn't hard-fail)
    } finally {
      _refreshingNow = false;
    }
  }

  Future<void> _refreshTimeline({required DateTime day}) async {
    final date = _dateLocal(day);
    final tzOffsetMinutes = _tzOffsetMinutesForDay(day);
    final requestSeq = ++_timelineRequestSeq;

    if (mounted) {
      setState(() {
        _timelineLoading = true;
      });
    }

    try {
      final segments = await widget.client.timelineDay(
        date: date,
        tzOffsetMinutes: tzOffsetMinutes,
      );
      if (!mounted) return;
      if (requestSeq != _timelineRequestSeq) return;
      if (!_isSameDay(_normalizeDay(day), _normalizeDay(_day))) return;

      final hasWebSeg = segments.any((s) => s.kind == "domain");
      final hasWebTitleSeg = segments.any(
        (s) => s.kind == "domain" && (s.title ?? "").trim().isNotEmpty,
      );

      setState(() {
        _segments = segments;
        _segmentsVersion += 1;
        _hasWebSeg = hasWebSeg;
        _hasWebTitleSeg = hasWebTitleSeg;
        _timelineDayKey = date;
        _timelineLoading = false;
        _topAggCacheKey = "";
        _topAggCache = null;
        _timelineCacheKey = "";
        _timelineCache = null;
        _flowCacheKey = "";
        _flowCache = null;
        _dayTimelineWidgetKey = "";
        _dayTimelineWidgetCache = null;
      });
    } catch (_) {
      if (!mounted) return;
      if (requestSeq != _timelineRequestSeq) return;
      setState(() {
        _timelineLoading = false;
      });
    }
  }

  Future<void> _refreshBlocks(
      {bool silent = false, bool triggerReminder = false}) async {
    if (_refreshingBlocks) return;
    _refreshingBlocks = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      unawaited(_loadCoreSettings());

      if (!silent) {
        final ok = await widget.client.waitUntilHealthy(
          timeout: _serverLooksLikeLocalhost()
              ? const Duration(seconds: 15)
              : const Duration(seconds: 6),
        );
        if (!ok) throw Exception("health_failed");
      }

      final date = _dateLocal(_day);
      final tzOffsetMinutes = _tzOffsetMinutesForDay(_day);
      final viewingToday = _viewingToday();
      final shouldClearTimeline = _timelineDayKey != date;

      final blocks = await widget.client.blocksToday(
        date: date,
        tzOffsetMinutes: tzOffsetMinutes,
      );
      if (!mounted) return;
      final due = viewingToday ? _computeDueBlock(blocks) : null;
      setState(() {
        _blocks = blocks;
        _dueBlock = due;
        _blocksUpdatedAt = DateTime.now();
        _loadedDayKey = date;
        _error = null;
        _topAggCacheKey = "";
        _topAggCache = null;
        if (shouldClearTimeline) {
          _segments = const [];
          _segmentsVersion += 1;
          _hasWebSeg = false;
          _hasWebTitleSeg = false;
          _timelineDayKey = null;
          _timelineCacheKey = "";
          _timelineCache = null;
          _flowCacheKey = "";
          _flowCache = null;
          _dayTimelineWidgetKey = "";
          _dayTimelineWidgetCache = null;
        }
      });
      _autoRetryAttempts = 0;
      if (triggerReminder && viewingToday && due != null) {
        await _maybePromptDueBlock(due);
      }
      unawaited(_refreshTimeline(day: _normalizeDay(_day)));
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      if (!silent) setState(() => _error = msg);
      _scheduleAutoRetryIfNeeded(msg);
    } finally {
      if (!silent && mounted) {
        setState(() {
          _loading = false;
        });
      }
      _refreshingBlocks = false;
    }
  }

  Future<void> refresh(
      {bool silent = false, bool triggerReminder = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final viewingToday = _viewingToday();
    final futures = <Future<void>>[
      _refreshBlocks(
          silent: silent, triggerReminder: triggerReminder && viewingToday),
      if (viewingToday) _refreshNow(silent: true),
    ];
    await Future.wait(futures);
  }

  String _ageText(String rfc3339) {
    try {
      final ts = DateTime.parse(rfc3339).toLocal();
      final d = DateTime.now().difference(ts);
      if (d.inSeconds < 60) return "${d.inSeconds}s ago";
      if (d.inMinutes < 60) return "${d.inMinutes}m ago";
      if (d.inHours < 24) return "${d.inHours}h ago";
      return "${d.inDays}d ago";
    } catch (_) {
      return "";
    }
  }

  Future<void> _openReview({String query = ""}) async {
    final cb = widget.onOpenReviewQuery;
    if (cb != null) {
      await cb(query, _normalizeDay(_day));
    } else {
      widget.onOpenReview();
    }
  }

  Future<void> _openReviewForEntity(
      {required String kind, required String? entity, String? label}) async {
    final e = (entity ?? "").trim();
    if (e.isEmpty) return;
    String query;
    if (kind == "domain") {
      final l = (label ?? "").trim();
      final looksLikeTitle = _coreStoreTitles &&
          l.isNotEmpty &&
          l.toLowerCase() != e.toLowerCase();
      query = looksLikeTitle ? l : e;
    } else {
      var l = (label ?? displayEntity(e)).trim();
      if (l.toLowerCase().startsWith("workspace:")) {
        l = l.substring("workspace:".length).trim();
      }
      query = l.isEmpty ? displayEntity(e) : l;
    }
    await _openReview(query: query);
  }

  String _updatedAge(DateTime? t) {
    if (t == null) return "—";
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 10) return "just now";
    if (d.inMinutes < 1) return "${d.inSeconds}s ago";
    if (d.inHours < 1) return "${d.inMinutes}m ago";
    return "${d.inHours}h ago";
  }

  String _shortAgeFromSeconds(int seconds) {
    final s = seconds.clamp(0, 365 * 24 * 60 * 60);
    if (s < 60) return "${s}s";
    final m = (s / 60).floor();
    if (m < 60) return "${m}m";
    final h = (m / 60).floor();
    if (h < 24) return "${h}h";
    final d = (h / 24).floor();
    return "${d}d";
  }

  int _countReviewedBlocks() {
    var c = 0;
    for (final b in _blocks) {
      if (_isReviewed(b)) c += 1;
    }
    return c;
  }

  String _privacyLevelLabel() {
    if (!_coreStoreTitles && !_coreStoreExePath) return "L1";
    if (_coreStoreTitles && !_coreStoreExePath) return "L2";
    return "L3";
  }

  Widget _overviewCard(BuildContext context, _TopAgg topAgg) {
    final dayLabel = _dateLocal(_day);
    final viewingToday = _viewingToday();
    final focusSeconds = topAgg.focusSeconds;
    final audioSeconds = topAgg.audioSeconds;
    final trackedSeconds = focusSeconds + audioSeconds;
    final focusSwitches = topAgg.focusSwitches;
    final longestStreak = topAgg.longestFocusStreakSeconds;

    final totalBlocks = _blocks.length;
    final reviewedBlocks = _countReviewedBlocks();
    final pendingBlocks = (totalBlocks - reviewedBlocks).clamp(0, 99999);
    final progress =
        totalBlocks <= 0 ? 0.0 : (reviewedBlocks / totalBlocks).clamp(0.0, 1.0);

    final due = _dueBlock;
    final dueRange = due == null
        ? null
        : "${formatHHMM(due.startTs)}–${formatHHMM(due.endTs)}";
    final dueTop = due == null ? null : _blockTopLine(due);
    final dueAudioTop = due == null ? null : _blockAudioTopItem(due);

    final scheme = Theme.of(context).colorScheme;

    Widget metric({
      required IconData icon,
      required String label,
      required String value,
      String? tooltip,
      VoidCallback? onTap,
    }) {
      final tile = InkWell(
        borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: RecorderTokens.space3,
            vertical: RecorderTokens.space2,
          ),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
            border: Border.all(color: scheme.outline.withValues(alpha: 0.10)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: RecorderTokens.space2),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.labelMedium),
                  Text(value, style: Theme.of(context).textTheme.bodyLarge),
                ],
              ),
            ],
          ),
        ),
      );

      if (tooltip == null || tooltip.trim().isEmpty) return tile;
      return RecorderTooltip(message: tooltip, child: tile);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(viewingToday ? "Today overview" : "Day overview",
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: "Previous day",
                  onPressed: () =>
                      _setDay(_day.subtract(const Duration(days: 1))),
                  icon: const Icon(Icons.chevron_left),
                ),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today_outlined, size: 18),
                  label: Text(dayLabel),
                ),
                IconButton(
                  tooltip: "Next day",
                  onPressed: _canGoNextDay()
                      ? () => _setDay(_day.add(const Duration(days: 1)))
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
                const SizedBox(width: RecorderTokens.space2),
                Text(
                  "Updated ${_updatedAge(_blocksUpdatedAt)}",
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
            const SizedBox(height: RecorderTokens.space3),
            Wrap(
              spacing: RecorderTokens.space2,
              runSpacing: RecorderTokens.space2,
              children: [
                metric(
                  icon: Icons.timer_outlined,
                  label: "Tracked",
                  value: trackedSeconds <= 0
                      ? "—"
                      : formatDuration(trackedSeconds),
                  tooltip: "Focus + background audio",
                ),
                metric(
                  icon: Icons.apps_outlined,
                  label: "Focus",
                  value: focusSeconds <= 0 ? "—" : formatDuration(focusSeconds),
                ),
                metric(
                  icon: Icons.swap_horiz,
                  label: "Switches",
                  value: focusSwitches.toString(),
                  tooltip: "Focus context switches today",
                ),
                metric(
                  icon: Icons.center_focus_strong_outlined,
                  label: "Deep focus",
                  value:
                      longestStreak <= 0 ? "—" : formatDuration(longestStreak),
                  tooltip: "Longest continuous focus segment",
                ),
                metric(
                  icon: Icons.list_alt_outlined,
                  label: "Blocks",
                  value:
                      totalBlocks <= 0 ? "—" : "$reviewedBlocks/$totalBlocks",
                  tooltip: pendingBlocks <= 0
                      ? "All reviewed"
                      : "$pendingBlocks pending",
                  onTap: () {
                    _openReview();
                  },
                ),
                metric(
                  icon: Icons.lock_outline,
                  label: "Privacy",
                  value: _privacyLevelLabel(),
                  tooltip: _coreStoreTitles ? "Titles stored" : "Titles off",
                  onTap: widget.onOpenSettings,
                ),
              ],
            ),
            if (totalBlocks > 0) ...[
              const SizedBox(height: RecorderTokens.space3),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 10,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                  const SizedBox(width: RecorderTokens.space2),
                  Text("$pendingBlocks pending",
                      style: Theme.of(context).textTheme.labelMedium),
                ],
              ),
            ],
            const SizedBox(height: RecorderTokens.space3),
            if (due != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      "Review due: $dueRange",
                      style: Theme.of(context).textTheme.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () => _openQuickReview(due),
                    icon: const Icon(Icons.rate_review_outlined, size: 18),
                    label: const Text("Quick review"),
                  ),
                ],
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    _openReview();
                  },
                  icon: const Icon(Icons.list_alt_outlined, size: 18),
                  label: const Text("Review blocks"),
                ),
              ),
            if (dueTop != null && dueTop.trim().isNotEmpty) ...[
              const SizedBox(height: RecorderTokens.space2),
              Text(
                "Top: $dueTop",
                style: Theme.of(context).textTheme.labelMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (dueAudioTop != null && dueAudioTop.seconds > 0) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(Icons.headphones,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: RecorderTokens.space1),
                  Expanded(
                    child: Text(
                      "${displayTopItemName(dueAudioTop)} ${formatDuration(dueAudioTop.seconds)}",
                      style: Theme.of(context).textTheme.labelMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _reviewDueCard(BuildContext context, BlockSummary due) {
    final top = _blockTopLine(due);
    final audioTop = _blockAudioTopItem(due);
    final title = "${formatHHMM(due.startTs)}–${formatHHMM(due.endTs)}";
    final audioSuffix = audioTop == null
        ? ""
        : " · 🎧 ${displayTopItemName(audioTop)} ${formatDuration(audioTop.seconds)}";
    final reason = _dueReasonShort(due);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RecorderTokens.space2),
        child: ListTile(
          isThreeLine: true,
          minVerticalPadding: RecorderTokens.space2,
          leading: const Icon(Icons.notifications_active_outlined),
          title: const Text("Review due"),
          subtitle: Text(
            "$title\nTop: $top$audioSuffix\nWhy now: $reason",
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _openBlock(due),
          trailing: FilledButton(
            onPressed: () => _openQuickReview(due),
            child: const Text("Quick review"),
          ),
        ),
      ),
    );
  }

  Widget _nowUnavailableCard(BuildContext context) {
    final dayLabel = _dateLocal(_day);
    return Card(
      key: widget.tutorialNowKey,
      child: Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Now", style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: RecorderTokens.space2),
            Text(
              "You’re viewing $dayLabel.\nNow shows live activity for Today only.",
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: RecorderTokens.space2),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => _setDay(DateTime.now()),
                child: const Text("Go to Today"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nowCard(BuildContext context) {
    bool isFresh(EventRecord e, Duration maxAge) {
      try {
        final t = DateTime.parse(e.ts).toLocal();
        return DateTime.now().difference(t) <= maxAge;
      } catch (_) {
        return false;
      }
    }

    final focusFreshness =
        Duration(seconds: _nowFocusTtlSeconds.clamp(10, 3600));
    final rawApp =
        (_latestAppEvent != null && isFresh(_latestAppEvent!, focusFreshness))
            ? _latestAppEvent
            : null;
    final rawTab =
        (_latestTabEvent != null && isFresh(_latestTabEvent!, focusFreshness))
            ? _latestTabEvent
            : null;
    final audio = _latestAudioEvent;
    final audioStop = _latestAudioStopEvent;
    final appAudio = _latestAppAudioEvent;
    final appAudioStop = _latestAppAudioStopEvent;

    final app = _nowFocusApp ?? rawApp;

    bool showAudioNow() {
      if (audio == null) return false;

      // If we have an explicit stop marker that is newer than the last audio event, treat audio as stopped.
      if (audioStop != null) {
        try {
          final a = DateTime.parse(audio.ts).toUtc();
          final s = DateTime.parse(audioStop.ts).toUtc();
          if (!s.isBefore(a)) return false;
        } catch (_) {
          // ignore
        }
      }

      // Fallback: hide "now" audio when the last audio event is stale.
      try {
        final a = DateTime.parse(audio.ts).toLocal();
        if (DateTime.now().difference(a) >
            Duration(seconds: _nowAudioTtlSeconds.clamp(30, 3600)))
          return false;
      } catch (_) {
        // ignore
      }

      return true;
    }

    final showAudio = showAudioNow();

    bool showAppAudioNow() {
      if (appAudio == null) return false;

      if (appAudioStop != null) {
        try {
          final a = DateTime.parse(appAudio.ts).toUtc();
          final s = DateTime.parse(appAudioStop.ts).toUtc();
          if (!s.isBefore(a)) return false;
        } catch (_) {
          // ignore
        }
      }

      try {
        final a = DateTime.parse(appAudio.ts).toLocal();
        if (DateTime.now().difference(a) >
            Duration(seconds: _nowAudioTtlSeconds.clamp(30, 3600)))
          return false;
      } catch (_) {
        // ignore
      }

      return true;
    }

    final showAppAudio = showAppAudioNow();

    final rawUsingTab = (() {
      final appLabelLc =
          rawApp == null ? "" : displayEntity(rawApp.entity).toLowerCase();
      final appSaysBrowserFocused = rawApp != null &&
          (appLabelLc == "chrome" ||
              appLabelLc == "msedge" ||
              appLabelLc == "edge" ||
              appLabelLc == "brave" ||
              appLabelLc == "vivaldi" ||
              appLabelLc == "opera" ||
              appLabelLc == "firefox");
      final browserFocused =
          appSaysBrowserFocused || (rawApp == null && rawTab != null);
      return browserFocused ? rawTab : (showAudio ? audio : null);
    })();

    final usingTab = _nowUsingTab ?? rawUsingTab;
    final usingTabIcon =
        usingTab?.activity == "audio" ? Icons.headphones : Icons.public;

    final usingTabMissingTitle = usingTab != null &&
        usingTab.event == "tab_active" &&
        ((usingTab.title ?? "").trim().isEmpty);

    final bgAudio = _nowBackgroundAudio ?? (showAppAudio ? appAudio : null);
    final showBgAudio = bgAudio != null;

    if (app == null && usingTab == null && !showBgAudio) {
      final age = _latestAnyAgeSeconds;
      final ageHint =
          age == null ? "" : "Last event: ${_shortAgeFromSeconds(age)} ago.";
      return Card(
        key: widget.tutorialNowKey,
        child: Padding(
          padding: const EdgeInsets.all(RecorderTokens.space4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Now", style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: RecorderTokens.space2),
              Text(
                ageHint.isEmpty
                    ? "No recent activity yet.\nTip: switch apps or tabs to generate events."
                    : "No fresh activity right now.\n$ageHint",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: RecorderTokens.space2),
              Text(
                "We record the focused app + “using tab” (focused tab, or an audible tab while the browser is in background) + background app audio (e.g. music player).",
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ),
      );
    }

    Widget row({
      required String kind, // "app" | "domain"
      required String label,
      required EventRecord e,
      required VoidCallback onTap,
      IconData? leadingIcon,
      IconData? trailingIcon,
    }) {
      final entityRaw = (e.entity ?? "").trim();
      final entity = kind == "domain" ? entityRaw.toLowerCase() : entityRaw;
      final base = displayEntity(entityRaw);
      final when = _ageText(e.ts);
      final rawDetail = (e.title ?? "").trim();

      String titleText = "$label · $base";
      String subtitleText = rawDetail.isEmpty ? when : "$when · $rawDetail";

      if (kind == "domain") {
        final domain = entity;
        final normTitle = (_coreStoreTitles && rawDetail.isNotEmpty)
            ? normalizeWebTitle(domain, rawDetail)
            : "";
        if (normTitle.isNotEmpty) {
          titleText = "$label · $normTitle";
          subtitleText = "$when · ${displayEntity(domain)}";
        } else {
          titleText = "$label · ${displayEntity(domain)}";
        }
      } else {
        final appLabel = displayEntity(entity);
        final isBrowser = _isBrowserLabel(appLabel);
        if (_coreStoreTitles && rawDetail.isNotEmpty && !isBrowser) {
          final labelLc = appLabel.toLowerCase();
          final isVscode = labelLc == "code" ||
              labelLc == "vscode" ||
              rawDetail.contains("Visual Studio Code");
          if (isVscode) {
            final ws = extractVscodeWorkspace(rawDetail);
            if (ws != null && ws.trim().isNotEmpty) {
              subtitleText = "$when · Workspace: ${ws.trim()}";
            }
          }
        }
      }

      final scheme = Theme.of(context).colorScheme;
      return ListTile(
        isThreeLine: true,
        minVerticalPadding: RecorderTokens.space2,
        contentPadding: EdgeInsets.zero,
        leading: EntityAvatar(
          kind: kind,
          entity: entity,
          label: base,
          icon: kind == "app" ? leadingIcon : null,
        ),
        trailing: trailingIcon == null
            ? null
            : Icon(trailingIcon, size: 18, color: scheme.onSurfaceVariant),
        title: Text(
          titleText,
          style: Theme.of(context).textTheme.bodyLarge,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitleText,
          style: Theme.of(context).textTheme.labelMedium,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: onTap,
      );
    }

    final hideAppAudio = app != null &&
        bgAudio != null &&
        displayEntity(app.entity) == displayEntity(bgAudio.entity);

    return Card(
      key: widget.tutorialNowKey,
      child: Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text("Now",
                        style: Theme.of(context).textTheme.titleMedium)),
                Text(
                  "Updated ${_updatedAge(_nowUpdatedAt)}",
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
            if (app != null)
              row(
                kind: "app",
                label: "Focus app",
                e: app,
                leadingIcon: _iconForAppLabel(displayEntity(app.entity)),
                onTap: () => _openReviewForEntity(
                    kind: "app",
                    entity: app.entity,
                    label: displayEntity(app.entity)),
              ),
            if (usingTab != null)
              row(
                kind: "domain",
                label: "Using tab",
                e: usingTab,
                trailingIcon: usingTabIcon,
                onTap: () {
                  final domain = (usingTab.entity ?? "").trim();
                  final rawTitle = (usingTab.title ?? "").trim();
                  final title = (_coreStoreTitles && domain.isNotEmpty)
                      ? normalizeWebTitle(domain, rawTitle)
                      : rawTitle;
                  _openReviewForEntity(
                      kind: "domain",
                      entity: usingTab.entity,
                      label: title.isEmpty ? null : title);
                },
              ),
            if (usingTabMissingTitle)
              Padding(
                padding: const EdgeInsets.only(left: 44, top: 4),
                child: Text(
                  _coreStoreTitles
                      ? "Tip: enable “Send tab title” in the browser extension popup, then click “Force send”."
                      : "Tip: titles are OFF (L1). Enable L2 in Settings to see tab titles (e.g. YouTube video names).",
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            if (bgAudio != null && !hideAppAudio)
              row(
                kind: "app",
                label: "Background audio",
                e: bgAudio,
                leadingIcon: _iconForAppLabel(displayEntity(bgAudio.entity)),
                trailingIcon: Icons.headphones,
                onTap: () => _openReviewForEntity(
                  kind: "app",
                  entity: bgAudio.entity,
                  label: displayEntity(bgAudio.entity),
                ),
              ),
          ],
        ),
      ),
    );
  }

  int _minuteOfDay(DateTime t, DateTime dayStart) {
    return t.difference(dayStart).inMinutes.clamp(0, 1440);
  }

  String _hhmmFromMinute(int minute) {
    final h = (minute ~/ 60).clamp(0, 24).toString().padLeft(2, "0");
    final m = (minute % 60).clamp(0, 59).toString().padLeft(2, "0");
    return "$h:$m";
  }

  double? _timelineCenterFrac() {
    if (!_timelineH.hasClients) return null;
    final pos = _timelineH.position;
    final viewport = pos.viewportDimension;
    final content = pos.maxScrollExtent + viewport;
    if (content <= 0) return null;
    return ((pos.pixels + viewport / 2) / content).clamp(0.0, 1.0);
  }

  void _saveTimelineView() {
    final frac = _timelineCenterFrac() ?? 0.0;
    setState(() {
      _timelineSavedView =
          _TimelineViewState(zoom: _timelineZoom, centerFrac: frac);
    });
  }

  void _restoreTimelineView() {
    final v = _timelineSavedView;
    if (v == null) return;
    setState(() => _timelineSavedView = null);
    _setTimelineZoom(
      v.zoom,
      preserveCenter: false,
      resetScroll: v.zoom <= 1.01,
      centerFracOverride: v.centerFrac,
    );
  }

  void _setTimelineZoom(
    double z, {
    bool preserveCenter = true,
    bool resetScroll = false,
    double? centerFracOverride,
  }) {
    final next = z.clamp(1.0, 4.0);
    final zoomUnchanged = (next - _timelineZoom).abs() < 0.001;
    if (zoomUnchanged && !resetScroll && centerFracOverride == null) return;

    final double? centerFrac = centerFracOverride?.clamp(0.0, 1.0) ??
        (() {
          if (!preserveCenter) return null;
          return _timelineCenterFrac();
        })();

    if (!zoomUnchanged) {
      setState(() => _timelineZoom = next);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_timelineH.hasClients) return;
      final pos = _timelineH.position;
      if (resetScroll || next <= 1.01) {
        pos.jumpTo(0.0);
        return;
      }
      final frac = centerFrac;
      if (frac == null) return;
      final viewport = pos.viewportDimension;
      final content = pos.maxScrollExtent + viewport;
      final centerX = content * frac;
      final target = (centerX - viewport / 2).clamp(0.0, pos.maxScrollExtent);
      pos.jumpTo(target);
    });
  }

  void _timelineZoomIn() => _setTimelineZoom(_timelineZoom * 1.25);

  void _timelineZoomOut() => _setTimelineZoom(_timelineZoom / 1.25);

  void _timelineResetView() =>
      _setTimelineZoom(1.0, preserveCenter: false, resetScroll: true);

  void _timelineCenterOnNow() {
    if (!_timelineH.hasClients) return;
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    final nowMin = now.difference(dayStart).inMinutes.clamp(0, 1440);
    final pos = _timelineH.position;
    final viewport = pos.viewportDimension;
    final content = pos.maxScrollExtent + viewport;
    final x = content * (nowMin / 1440.0);
    final target = (x - viewport / 2).clamp(0.0, pos.maxScrollExtent);
    pos.animateTo(target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic);
  }

  ({
    String laneKey,
    String kind,
    String entity,
    String label,
    String? subtitle,
    IconData icon,
  })? _timelineLaneMeta(TimelineSegment s) {
    final kind = s.kind;
    if (kind != "app" && kind != "domain") return null;
    final rawEntity = s.entity.trim();
    if (rawEntity.isEmpty) return null;

    if (kind == "domain") {
      final domain = rawEntity.toLowerCase();
      final rawTitle = (s.title ?? "").trim();
      final normTitle =
          _coreStoreTitles ? normalizeWebTitle(domain, rawTitle) : "";
      if (_coreStoreTitles && normTitle.isNotEmpty) {
        return (
          laneKey: "domain|$domain|$normTitle",
          kind: kind,
          entity: domain,
          label: normTitle,
          subtitle: displayEntity(domain),
          icon: Icons.public,
        );
      }
      return (
        laneKey: "domain|$domain",
        kind: kind,
        entity: domain,
        label: displayEntity(domain),
        subtitle: null,
        icon: Icons.public,
      );
    }

    final appEntity = rawEntity;
    final label = displayEntity(appEntity);
    final icon = _iconForAppLabel(label);
    final title = (s.title ?? "").trim();
    final labelLc = label.toLowerCase();
    final isVscode = labelLc == "code" ||
        labelLc == "vscode" ||
        title.contains("Visual Studio Code");
    if (_coreStoreTitles && isVscode && title.isNotEmpty) {
      final ws = extractVscodeWorkspace(title);
      if (ws != null && ws.trim().isNotEmpty) {
        final w = ws.trim();
        return (
          laneKey: "app|$appEntity|$w",
          kind: kind,
          entity: appEntity,
          label: label,
          subtitle: "Workspace: $w",
          icon: icon,
        );
      }
    }

    return (
      laneKey: "app|$appEntity",
      kind: kind,
      entity: appEntity,
      label: label,
      subtitle: null,
      icon: icon,
    );
  }

  ({List<DayTimelineLane> lanes, int totalCount}) _timelineModelCached({
    required bool showAll,
  }) {
    final dayKey = "${_day.year}-${_day.month}-${_day.day}";
    final key =
        "$dayKey|$_segmentsVersion|${_topFilter.index}|${_timelineSortByTime ? 1 : 0}|${_coreStoreTitles ? 1 : 0}|${showAll ? 1 : 0}";
    final cached = _timelineCache;
    if (cached != null && key == _timelineCacheKey) return cached;

    final next = _buildTimelineModel(showAll: showAll);
    _timelineCacheKey = key;
    _timelineCache = next;
    return next;
  }

  ({List<DayTimelineLane> lanes, int totalCount}) _buildTimelineModel({
    required bool showAll,
  }) {
    final dayStart = DateTime(_day.year, _day.month, _day.day);

    Iterable<TimelineSegment> segs;
    switch (_topFilter) {
      case _TopFilter.apps:
        segs = _segments.where((s) => s.kind == "app");
        break;
      case _TopFilter.web:
        segs = _segments.where((s) => s.kind == "domain");
        break;
      case _TopFilter.all:
        segs = _segments;
        break;
    }

    final lanesByKey = <String, _LaneAcc>{};

    for (final s in segs) {
      final meta = _timelineLaneMeta(s);
      if (meta == null) continue;

      final start = s.startLocal;
      final end = s.endLocal;
      if (start == null || end == null) continue;
      if (!end.isAfter(start)) continue;

      final startMin = _minuteOfDay(start, dayStart);
      final endMin = _minuteOfDay(end, dayStart);
      if (endMin <= startMin) continue;

      final lane = lanesByKey.putIfAbsent(
        meta.laneKey,
        () => _LaneAcc(
          kind: meta.kind,
          entity: meta.entity,
          label: meta.label,
          subtitle: meta.subtitle,
          icon: meta.icon,
        ),
      );
      lane.totalSeconds += s.seconds;
      if (startMin < lane.firstStartMinute) lane.firstStartMinute = startMin;
    }

    final totalCount = lanesByKey.length;
    final entries = lanesByKey.entries.toList();
    entries.sort((a, b) {
      final la = a.value;
      final lb = b.value;
      if (_timelineSortByTime) {
        final byTime = la.firstStartMinute.compareTo(lb.firstStartMinute);
        if (byTime != 0) return byTime;
      }
      final byTotal = lb.totalSeconds.compareTo(la.totalSeconds);
      if (byTotal != 0) return byTotal;
      return la.label.toLowerCase().compareTo(lb.label.toLowerCase());
    });

    final visibleEntries = showAll ? entries : entries.take(12).toList();
    final visibleKeys = visibleEntries.map((e) => e.key).toSet();

    for (final s in segs) {
      final meta = _timelineLaneMeta(s);
      if (meta == null) continue;
      if (!visibleKeys.contains(meta.laneKey)) continue;

      final lane = lanesByKey[meta.laneKey];
      if (lane == null) continue;

      final start = s.startLocal;
      final end = s.endLocal;
      if (start == null || end == null) continue;
      if (!end.isAfter(start)) continue;

      final startMin = _minuteOfDay(start, dayStart);
      final endMin = _minuteOfDay(end, dayStart);
      if (endMin <= startMin) continue;

      final audio = s.activity == "audio";
      final time = "${_hhmmFromMinute(startMin)}–${_hhmmFromMinute(endMin)}";
      final tipHead = lane.subtitle == null
          ? lane.label
          : "${lane.label}\n${lane.subtitle}";
      lane.bars.add(
        DayTimelineBar(
          startMinute: startMin,
          endMinute: endMin,
          audio: audio,
          tooltip: audio ? "$tipHead\n$time · audio" : "$tipHead\n$time",
          startTs: s.startTs,
          endTs: s.endTs,
        ),
      );
    }

    final out = <DayTimelineLane>[];
    for (final e in visibleEntries) {
      final l = e.value;
      l.bars.sort((a, b) => a.startMinute.compareTo(b.startMinute));
      out.add(
        DayTimelineLane(
          kind: l.kind,
          entity: l.entity,
          label: l.label,
          subtitle: l.subtitle,
          icon: l.icon,
          totalSeconds: l.totalSeconds,
          bars: l.bars,
        ),
      );
    }

    return (lanes: out, totalCount: totalCount);
  }

  Widget _dayTimelineWidgetCached({
    required BuildContext context,
    required List<DayTimelineLane> lanes,
    required bool viewingToday,
  }) {
    final key = "${_timelineCacheKey}|z:${_timelineZoom.toStringAsFixed(2)}"
        "|now:${viewingToday ? 1 : 0}";
    final cached = _dayTimelineWidgetCache;
    if (cached != null && key == _dayTimelineWidgetKey) return cached;

    final w = DayTimeline(
      lanes: lanes,
      showNowIndicator: viewingToday,
      zoom: _timelineZoom,
      horizontalController: _timelineH,
      onLaneTap: (lane) {
        final subtitle = (lane.subtitle ?? "").trim();
        final preferWorkspace = lane.kind == "app" &&
            subtitle.toLowerCase().startsWith("workspace:");
        final label = preferWorkspace ? subtitle : lane.label;
        _openReviewForEntity(
            kind: lane.kind, entity: lane.entity, label: label);
      },
      onBarTap: (_, bar) {
        final b = _findBlockForTimelineBar(bar);
        if (b == null) {
          final messenger = ScaffoldMessenger.of(context);
          messenger.clearSnackBars();
          messenger.showSnackBar(
            const SnackBar(
              duration: Duration(seconds: 3),
              showCloseIcon: true,
              content: Text("No matching block"),
            ),
          );
          return;
        }
        unawaited(_openBlock(b));
      },
    );

    _dayTimelineWidgetKey = key;
    _dayTimelineWidgetCache = w;
    return w;
  }

  List<_FlowItem> _flowItemsCached() {
    final dayKey = "${_day.year}-${_day.month}-${_day.day}";
    final key =
        "$dayKey|$_segmentsVersion|${_topFilter.index}|${_coreStoreTitles ? 1 : 0}";
    final cached = _flowCache;
    if (cached != null && key == _flowCacheKey) return cached;

    final next = _buildFlowItems();
    _flowCacheKey = key;
    _flowCache = next;
    return next;
  }

  List<_FlowItem> _buildFlowItems() {
    final items = <_FlowItem>[];

    Iterable<TimelineSegment> segs;
    switch (_topFilter) {
      case _TopFilter.apps:
        segs = _segments.where((s) => s.kind == "app" && s.activity != "audio");
        break;
      case _TopFilter.web:
        segs =
            _segments.where((s) => s.kind == "domain" && s.activity != "audio");
        break;
      case _TopFilter.all:
        segs = _segments.where((s) => s.activity != "audio");
        break;
    }

    for (final s in segs) {
      final kind = s.kind;
      if (kind != "app" && kind != "domain") continue;
      final rawEntity = s.entity.trim();
      if (rawEntity.isEmpty) continue;

      final start = s.startLocal;
      final end = s.endLocal;
      if (start == null || end == null) continue;
      if (!end.isAfter(start)) continue;

      String entity;
      String label;
      String? subtitle;
      IconData icon;

      if (kind == "domain") {
        final domain = rawEntity.toLowerCase();
        final rawTitle = (s.title ?? "").trim();
        final normTitle =
            _coreStoreTitles ? normalizeWebTitle(domain, rawTitle) : "";
        if (_coreStoreTitles && normTitle.isNotEmpty) {
          entity = domain;
          label = normTitle;
          subtitle = displayEntity(domain);
        } else {
          entity = domain;
          label = displayEntity(domain);
          subtitle = null;
        }
        icon = Icons.public;
      } else {
        entity = rawEntity;
        label = displayEntity(entity);
        icon = _iconForAppLabel(label);
        subtitle = null;

        if (_coreStoreTitles) {
          final t = (s.title ?? "").trim();
          if (t.isNotEmpty && !_isBrowserLabel(label)) {
            final labelLc = label.toLowerCase();
            final isVscode = labelLc == "code" ||
                labelLc == "vscode" ||
                t.contains("Visual Studio Code");
            if (isVscode) {
              final ws = extractVscodeWorkspace(t);
              subtitle = (ws != null && ws.trim().isNotEmpty)
                  ? "Workspace: ${ws.trim()}"
                  : t;
            } else {
              subtitle = t;
            }
          }
        }
      }

      items.add(
        _FlowItem(
          kind: kind,
          entity: entity,
          label: label,
          subtitle: subtitle,
          start: start,
          end: end,
          seconds: s.seconds,
          icon: icon,
        ),
      );
    }

    final show = items.length <= 10 ? items : items.sublist(items.length - 10);
    return show.reversed.toList();
  }

  String _displayTopItemForBlockLine(TopItem it) {
    final kind = it.kind;
    if (kind != "app") return displayTopItemName(it);

    final appEntity = it.entity.trim();
    final appLabel = displayEntity(appEntity);
    if (!_coreStoreTitles) return appLabel;

    final title = (it.title ?? "").trim();
    if (title.isEmpty) return appLabel;

    final labelLc = appLabel.toLowerCase();
    final isVscode = labelLc == "code" ||
        labelLc == "vscode" ||
        title.contains("Visual Studio Code");
    if (isVscode) {
      final ws = extractVscodeWorkspace(title);
      if (ws != null && ws.trim().isNotEmpty) {
        return "Workspace: ${ws.trim()}";
      }
    }

    // Avoid showing document-level titles for general apps in the top line.
    return appLabel;
  }

  String _blockTopLine(BlockSummary b) {
    final items = b.topItems;
    if (items.isEmpty) return "";
    return items
        .take(3)
        .map((it) =>
            "${_displayTopItemForBlockLine(it)} ${formatDuration(it.seconds)}")
        .join(" · ");
  }

  TopItem? _blockAudioTopItem(BlockSummary b) {
    final bg = b.backgroundTopItems;
    if (bg.isEmpty) return null;
    return bg.first;
  }

  String _hhmm(DateTime t) =>
      "${t.hour.toString().padLeft(2, "0")}:${t.minute.toString().padLeft(2, "0")}";

  Widget _flowCard(BuildContext context) {
    final latestFirst = _flowItemsCached();
    final timelinePending = _timelineLoading && _segments.isEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text("Flow",
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Text(
                  "Updated ${_updatedAge(_blocksUpdatedAt)}",
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
            const SizedBox(height: RecorderTokens.space2),
            if (timelinePending)
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: RecorderTokens.space2),
                  Expanded(
                    child: Text(
                      "Loading recent flow…",
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              )
            else if (latestFirst.isEmpty)
              Text(
                "No focus activity yet.\nTip: switch apps or tabs to generate events.",
                style: Theme.of(context).textTheme.bodyMedium,
              )
            else
              ...latestFirst.map((it) {
                final sub = (it.subtitle ?? "").trim();
                final meta =
                    "${_hhmm(it.start)}–${_hhmm(it.end)} · ${formatDuration(it.seconds)}";
                final subtitleText = sub.isEmpty ? meta : "$meta\n$sub";
                return ListTile(
                  isThreeLine: true,
                  minVerticalPadding: RecorderTokens.space2,
                  contentPadding: EdgeInsets.zero,
                  leading: EntityAvatar(
                    kind: it.kind,
                    entity: it.entity,
                    label: it.label,
                    icon: it.kind == "app" ? it.icon : null,
                  ),
                  title: Text(
                    it.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  subtitle: Text(
                    subtitleText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  onTap: () {
                    final preferWorkspace = it.kind == "app" &&
                        sub.toLowerCase().startsWith("workspace:");
                    final label = preferWorkspace ? sub : it.label;
                    _openReviewForEntity(
                        kind: it.kind, entity: it.entity, label: label);
                  },
                );
              }),
            if (!_coreStoreTitles) ...[
              const SizedBox(height: RecorderTokens.space2),
              Row(
                children: [
                  Icon(Icons.lock_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: RecorderTokens.space1),
                  Expanded(
                    child: Text(
                      "Titles are off (L1). Enable L2 in Settings to see page/workspace names.",
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  if (widget.onOpenSettings != null)
                    TextButton(
                      onPressed: widget.onOpenSettings,
                      child: const Text("Settings"),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _timelineCard(BuildContext context) {
    final model = _timelineModelCached(showAll: _timelineShowAll);
    final hasMore = model.totalCount > 12;
    final lanes = model.lanes;
    final viewingToday = _viewingToday();
    final showWeb = _topFilter != _TopFilter.apps;
    final hasWebSeg = _hasWebSeg;
    final hasWebTitleSeg = _hasWebTitleSeg;
    final canScrollH = _timelineZoom > 1.01;
    final timelinePending = _timelineLoading && lanes.isEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text("Timeline",
                        style: Theme.of(context).textTheme.titleMedium)),
                Text("Updated ${_updatedAge(_blocksUpdatedAt)}",
                    style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
            const SizedBox(height: RecorderTokens.space2),
            Wrap(
              spacing: RecorderTokens.space2,
              runSpacing: 0,
              children: [
                TextButton.icon(
                  onPressed: () => setState(
                      () => _timelineSortByTime = !_timelineSortByTime),
                  icon: Icon(
                      _timelineSortByTime ? Icons.schedule : Icons.bar_chart,
                      size: 18),
                  label: Text(_timelineSortByTime ? "By time" : "By total"),
                ),
                if (viewingToday)
                  TextButton.icon(
                    onPressed: canScrollH
                        ? () {
                            _saveTimelineView();
                            _timelineCenterOnNow();
                          }
                        : null,
                    icon: const Icon(Icons.my_location, size: 18),
                    label: const Text("Now"),
                  ),
                if (_timelineSavedView != null)
                  TextButton.icon(
                    onPressed: _restoreTimelineView,
                    icon: const Icon(Icons.undo, size: 18),
                    label: const Text("Back"),
                  ),
                RecorderTooltip(
                  message: "Zoom out",
                  child: IconButton(
                    onPressed: _timelineZoom <= 1.01 ? null : _timelineZoomOut,
                    icon: const Icon(Icons.zoom_out, size: 20),
                  ),
                ),
                OutlinedButton(
                  onPressed: (_timelineZoom - 1.0).abs() < 0.01
                      ? null
                      : _timelineResetView,
                  child: Text("x${_timelineZoom.toStringAsFixed(1)}"),
                ),
                RecorderTooltip(
                  message: "Zoom in",
                  child: IconButton(
                    onPressed: _timelineZoom >= 3.99 ? null : _timelineZoomIn,
                    icon: const Icon(Icons.zoom_in, size: 20),
                  ),
                ),
                if (hasMore)
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _timelineShowAll = !_timelineShowAll),
                    icon: Icon(
                        _timelineShowAll
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18),
                    label: Text(_timelineShowAll ? "Top 12" : "Show all"),
                  ),
              ],
            ),
            const SizedBox(height: RecorderTokens.space2),
            if (timelinePending)
              Container(
                key: widget.tutorialTimelineKey,
                padding: const EdgeInsets.symmetric(
                  vertical: RecorderTokens.space5,
                  horizontal: RecorderTokens.space3,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .outline
                        .withValues(alpha: 0.10),
                  ),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                    const SizedBox(width: RecorderTokens.space3),
                    Expanded(
                      child: Text(
                        "Timeline is loading in the background…",
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              )
            else
              Listener(
                key: widget.tutorialTimelineKey,
                onPointerSignal: (e) {
                  if (e is! PointerScrollEvent) return;
                  if (!HardwareKeyboard.instance.isControlPressed) return;
                  GestureBinding.instance.pointerSignalResolver.register(e,
                      (_) {
                    final dy = e.scrollDelta.dy;
                    if (dy == 0) return;
                    final factor = dy < 0 ? 1.10 : 0.90;
                    _setTimelineZoom(_timelineZoom * factor);
                  });
                },
                child: _dayTimelineWidgetCached(
                  context: context,
                  lanes: lanes,
                  viewingToday: viewingToday,
                ),
              ),
            if (lanes.isNotEmpty) ...[
              const SizedBox(height: RecorderTokens.space2),
              Row(
                children: [
                  Icon(Icons.touch_app_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: RecorderTokens.space1),
                  Expanded(
                    child: Text(
                      canScrollH
                          ? "Tip: Ctrl + mouse wheel to zoom, drag to pan. Tap a bar to open its block. View doesn't reset when you close the sheet."
                          : "Tip: tap a bar to open its block. Tap a lane to filter Review.",
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ],
              ),
            ],
            if (!_coreStoreTitles) ...[
              const SizedBox(height: RecorderTokens.space2),
              Row(
                children: [
                  Icon(Icons.lock_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: RecorderTokens.space1),
                  Expanded(
                    child: Text(
                      "Titles are off (L1). Enable L2 in Settings to see page/workspace names.",
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  if (widget.onOpenSettings != null)
                    TextButton(
                      onPressed: widget.onOpenSettings,
                      child: const Text("Settings"),
                    ),
                ],
              ),
            ] else if (viewingToday &&
                showWeb &&
                hasWebSeg &&
                !hasWebTitleSeg) ...[
              const SizedBox(height: RecorderTokens.space2),
              Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: RecorderTokens.space1),
                  Expanded(
                    child: Text(
                      "Tab titles not received yet. Turn on “Send tab title”, then reload the extension.",
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _todayTopCard(BuildContext context, _TopAgg topAgg) {
    final focusSeconds = topAgg.focusSeconds;
    final items = _applyTopFilter(topAgg.items);
    final displayItems = items.take(10).toList();
    final maxSeconds =
        displayItems.fold<int>(0, (m, it) => it.seconds > m ? it.seconds : m);
    final viewingToday = _viewingToday();
    final hasWebSeg = _hasWebSeg;
    final hasWebTitleSeg = _hasWebTitleSeg;

    Widget filters() {
      return Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<_TopFilter>(
            segments: const [
              ButtonSegment(value: _TopFilter.all, label: Text("All")),
              ButtonSegment(value: _TopFilter.apps, label: Text("Apps")),
              ButtonSegment(value: _TopFilter.web, label: Text("Web")),
            ],
            selected: {_topFilter},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _topFilter = s.first),
          ),
        ),
      );
    }

    Widget list() {
      if (displayItems.isEmpty) {
        return Text(
          "No activity yet.\nTip: switch apps or tabs to generate events.",
          style: Theme.of(context).textTheme.bodyMedium,
        );
      }

      return Column(
        children: [
          for (final it in displayItems)
            Padding(
              padding: const EdgeInsets.only(bottom: RecorderTokens.space3),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
                  onTap: () {
                    final subtitle = (_subtitleForStatItem(it) ?? "").trim();
                    final preferWorkspace = it.kind == "app" &&
                        subtitle.toLowerCase().startsWith("workspace:");
                    final label = preferWorkspace ? subtitle : it.label;
                    _openReviewForEntity(
                        kind: it.kind, entity: it.entity, label: label);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(RecorderTokens.space2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            EntityAvatar(
                              kind: it.kind,
                              entity: it.entity,
                              label: it.label,
                              icon: it.kind == "app"
                                  ? _iconForStatItem(it)
                                  : null,
                            ),
                            const SizedBox(width: RecorderTokens.space2),
                            Expanded(
                              child: Builder(
                                builder: (context) {
                                  final subtitle = _subtitleForStatItem(it);
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        it.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyLarge,
                                      ),
                                      if (subtitle != null) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          subtitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium,
                                        ),
                                      ],
                                    ],
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: RecorderTokens.space2),
                            Text(formatDuration(it.seconds),
                                style: Theme.of(context).textTheme.labelMedium),
                            if (it.hasAudio) ...[
                              const SizedBox(width: RecorderTokens.space1),
                              Icon(Icons.headphones,
                                  size: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                            ],
                            if (it.kind == "domain" || it.kind == "app") ...[
                              const SizedBox(width: RecorderTokens.space1),
                              IconButton(
                                onPressed: _isBlockedEntity(
                                            kind: it.kind, entity: it.entity) ||
                                        _rulesLoading
                                    ? null
                                    : () => _blacklistEntity(
                                          kind: it.kind,
                                          entity: it.entity,
                                          displayName: it.kind == "domain"
                                              ? it.entity
                                              : it.label,
                                        ),
                                tooltip: _isBlockedEntity(
                                        kind: it.kind, entity: it.entity)
                                    ? "Blacklisted"
                                    : (it.kind == "domain"
                                        ? "Blacklist domain"
                                        : "Blacklist app"),
                                icon: Icon(
                                  _isBlockedEntity(
                                          kind: it.kind, entity: it.entity)
                                      ? Icons.block
                                      : Icons.block_outlined,
                                ),
                              ),
                            ],
                          ],
                        ),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: maxSeconds <= 0
                                ? 0.0
                                : (it.seconds / maxSeconds).clamp(0.0, 1.0),
                            minHeight: 10,
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text("Today Top",
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (focusSeconds > 0)
                  Text(formatDuration(focusSeconds),
                      style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
            const SizedBox(height: RecorderTokens.space2),
            filters(),
            const SizedBox(height: RecorderTokens.space3),
            list(),
            if (displayItems.isNotEmpty) ...[
              const SizedBox(height: RecorderTokens.space2),
              Row(
                children: [
                  Icon(Icons.touch_app_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: RecorderTokens.space1),
                  Expanded(
                    child: Text(
                      "Tip: tap an item to filter blocks in Review.",
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ],
              ),
            ],
            if (!_coreStoreTitles) ...[
              const SizedBox(height: RecorderTokens.space2),
              Row(
                children: [
                  Icon(Icons.lock_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: RecorderTokens.space1),
                  Expanded(
                    child: Text(
                      "Titles are off (L1). Enable “Store window/tab titles (L2)” in Settings to see page/workspace names.",
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  if (widget.onOpenSettings != null)
                    TextButton(
                      onPressed: widget.onOpenSettings,
                      child: const Text("Settings"),
                    ),
                ],
              ),
            ] else if (viewingToday && hasWebSeg && !hasWebTitleSeg) ...[
              const SizedBox(height: RecorderTokens.space2),
              Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: RecorderTokens.space1),
                  Expanded(
                    child: Text(
                      "Titles enabled, but tab titles are not coming through yet. Turn on “Send tab title”, then reload the extension.",
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: RecorderTokens.space2),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  _openReview();
                },
                icon: const Icon(Icons.list_alt_outlined, size: 18),
                label: const Text("Review blocks"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentDayKey = _dateLocal(_day);
    final hasCurrentContent = _loadedDayKey == currentDayKey &&
        (_blocksUpdatedAt != null ||
            _blocks.isNotEmpty ||
            _segments.isNotEmpty);

    if (_loading && !hasCurrentContent) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && !hasCurrentContent) {
      return _ErrorState(
        serverUrl: widget.serverUrl,
        error: _error!,
        onRetry: refresh,
        showAgent: DesktopAgent.instance.isAvailable,
        agentBusy: _agentBusy,
        onStartAgent: _startLocalAgent,
      );
    }

    final viewingToday = _viewingToday();
    final due = _dueBlock;
    final topAgg = _topAggCached();
    final showEmpty = topAgg.focusSeconds <= 0 && topAgg.audioSeconds <= 0;

    final isWide = MediaQuery.of(context).size.width >= 1100;

    return RefreshIndicator(
      onRefresh: () => refresh(triggerReminder: viewingToday),
      child: isWide
          ? ListView(
              controller: _scrollV,
              padding: const EdgeInsets.all(RecorderTokens.space4),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        children: [
                          _overviewCard(context, topAgg),
                          const SizedBox(height: RecorderTokens.space3),
                          _todayTopCard(context, topAgg),
                        ],
                      ),
                    ),
                    const SizedBox(width: RecorderTokens.space3),
                    Expanded(
                      flex: 2,
                      child: Column(
                        children: [
                          if (due != null) ...[
                            _reviewDueCard(context, due),
                            const SizedBox(height: RecorderTokens.space3),
                          ],
                          viewingToday
                              ? _nowCard(context)
                              : _nowUnavailableCard(context),
                          if (!showEmpty) ...[
                            const SizedBox(height: RecorderTokens.space3),
                            _flowCard(context),
                          ] else ...[
                            const SizedBox(height: RecorderTokens.space3),
                            _EmptyState(
                              dayLabel: _dateLocal(_day),
                              serverUrl: widget.serverUrl,
                              onRefresh: () =>
                                  refresh(triggerReminder: viewingToday),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: RecorderTokens.space3),
                _timelineCard(context),
              ],
            )
          : ListView.separated(
              controller: _scrollV,
              padding: const EdgeInsets.all(RecorderTokens.space4),
              itemCount: 1 +
                  1 +
                  (due != null ? 1 : 0) +
                  1 +
                  1 +
                  (!showEmpty ? 1 : 0) +
                  (showEmpty ? 1 : 0),
              separatorBuilder: (_, __) =>
                  const SizedBox(height: RecorderTokens.space3),
              itemBuilder: (context, i) {
                var idx = 0;
                if (i == idx) return _overviewCard(context, topAgg);
                idx += 1;
                if (i == idx)
                  return viewingToday
                      ? _nowCard(context)
                      : _nowUnavailableCard(context);
                idx += 1;
                if (due != null) {
                  if (i == idx) return _reviewDueCard(context, due);
                  idx += 1;
                }
                if (i == idx) return _todayTopCard(context, topAgg);
                idx += 1;
                if (!showEmpty) {
                  if (i == idx) return _flowCard(context);
                  idx += 1;
                }
                if (i == idx) return _timelineCard(context);
                idx += 1;
                return _EmptyState(
                  dayLabel: _dateLocal(_day),
                  serverUrl: widget.serverUrl,
                  onRefresh: () => refresh(triggerReminder: viewingToday),
                );
              },
            ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.serverUrl,
    required this.error,
    required this.onRetry,
    required this.showAgent,
    required this.agentBusy,
    required this.onStartAgent,
  });

  final String serverUrl;
  final String error;
  final VoidCallback onRetry;
  final bool showAgent;
  final bool agentBusy;
  final VoidCallback onStartAgent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RecorderTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Cannot reach Core",
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: RecorderTokens.space2),
          Text("Server URL: $serverUrl",
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: RecorderTokens.space2),
          Text("Error: $error", style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: RecorderTokens.space4),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text("Retry"),
          ),
          if (showAgent) ...[
            const SizedBox(height: RecorderTokens.space2),
            OutlinedButton.icon(
              onPressed: agentBusy ? null : onStartAgent,
              icon: const Icon(Icons.memory),
              label: Text(agentBusy ? "Starting agent…" : "Start local agent"),
            ),
          ],
          const SizedBox(height: RecorderTokens.space4),
          const Text(
            "Tip:\n"
            "- Start local Core/Collector from Settings → Desktop agent\n"
            "- Or run Core manually:\n  cargo run -p recorder_core -- --listen 127.0.0.1:17600",
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState(
      {required this.dayLabel,
      required this.serverUrl,
      required this.onRefresh});

  final String dayLabel;
  final String serverUrl;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RecorderTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("No activity", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: RecorderTokens.space2),
          Text("Day: $dayLabel", style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: RecorderTokens.space2),
          Text("Server URL: $serverUrl",
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: RecorderTokens.space4),
          FilledButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text("Refresh"),
          ),
          const SizedBox(height: RecorderTokens.space4),
          const Text(
            "Generate some activity:\n- Run Core\n- Install browser extension\n- Switch apps / tabs a few times",
          ),
        ],
      ),
    );
  }
}
