import "dart:async";

import "package:flutter/material.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:window_manager/window_manager.dart";

import "../api/core_client.dart";
import "../tutorial/app_tutorial.dart";
import "../utils/desktop_agent.dart";
import "../utils/tray_controller.dart";
import "../utils/update_manager.dart";
import "reports_screen.dart";
import "search_screen.dart";
import "settings_screen.dart";
import "today_screen.dart";

enum _TrackingAction { resume, pause15, pause60, pauseManual }

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.initialDeepLink,
    this.startMinimized = false,
    this.externalCommands,
  });

  final String? initialDeepLink;
  final bool startMinimized;
  final Stream<String>? externalCommands;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const _prefServerUrl = "serverUrl";
  static const _defaultServerUrl = "http://127.0.0.1:17600";
  static const _prefUpdateRepo = "updateGitHubRepo";
  static const _prefUpdateAutoCheck = "updateAutoCheck";
  static const _prefUpdateLastCheckIso = "updateLastCheckIso";

  final _todayKey = GlobalKey<TodayScreenState>();
  final _searchKey = GlobalKey<SearchScreenState>();
  final _plannerKey = GlobalKey<ReportsScreenState>();
  final _reportsKey = GlobalKey<ReportsScreenState>();
  final _settingsKey = GlobalKey<SettingsScreenState>();
  final _tutorialNavRailKey = GlobalKey();
  final _tutorialBottomNavKey = GlobalKey();
  final _tutorialTrackingKey = GlobalKey();
  final _tutorialNowKey = GlobalKey();
  final _tutorialTimelineKey = GlobalKey();
  final _tutorialReviewHeaderKey = GlobalKey();
  final _tutorialPrivacyKey = GlobalKey();

  bool _ready = false;
  int _index = 0;
  bool _handledInitialDeepLink = false;
  bool _tutorialRunning = false;

  String _serverUrl = _defaultServerUrl;
  late CoreClient _client = CoreClient(baseUrl: _serverUrl);
  TrackingStatus? _tracking;
  Timer? _trackingTimer;
  bool _agentStartAttempted = false;
  StreamSubscription<String>? _externalSub;
  bool _updateCheckAttempted = false;

  String _normalizeServerUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return trimmed;

    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return trimmed;

    final host = uri.host.contains(":") ? "[${uri.host}]" : uri.host;
    final port = uri.hasPort ? ":${uri.port}" : "";
    return "${uri.scheme}://$host$port";
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _externalSub = widget.externalCommands?.listen((msg) {
      _handleExternalCommand(msg);
    });
  }

  @override
  void dispose() {
    _trackingTimer?.cancel();
    _externalSub?.cancel();
    TrayController.instance.dispose();
    _client.close();
    super.dispose();
  }

  Future<void> _showAndFocusWindow() async {
    try {
      await windowManager.show();
      await windowManager.restore();
      await windowManager.focus();
    } catch (_) {
      // ignore
    }
  }

  void _handleExternalCommand(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return;

    if (s == "__show__") {
      unawaited(_showAndFocusWindow());
      return;
    }

    if (s.startsWith("recorderphone://")) {
      if (_deepLinkWantsForeground(s)) {
        unawaited(_showAndFocusWindow());
      }
      _handleDeepLink(s);
      return;
    }

    // Unknown command: best-effort just bring the app to front.
    unawaited(_showAndFocusWindow());
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_prefServerUrl);
    if (v != null && v.trim().isNotEmpty) {
      _serverUrl = _normalizeServerUrl(v);
      final old = _client;
      _client = CoreClient(baseUrl: _serverUrl);
      old.close();
    }
    if (!mounted) return;
    setState(() => _ready = true);

    // Windows tray: close-to-tray + quick actions.
    unawaited(
      TrayController.instance.ensureInitialized(
        getServerUrl: () => _serverUrl,
        onQuickReview: () async {
          if (!mounted) return;
          setState(() => _index = 1);
          _searchKey.currentState?.refresh(silent: false);
        },
        startHidden: widget.startMinimized,
      ),
    );

    // Best-effort: if Core is down and we're on Windows, try starting the local agent so the user
    // doesn't need to run Core/Collector separately.
    unawaited(_maybeStartLocalAgent());
    unawaited(_maybeAutoCheckUpdates());

    await _refreshTracking();
    _trackingTimer?.cancel();
    _trackingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshTracking();
      TrayController.instance.refreshStatus();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeHandleInitialDeepLink();
    });
  }

  bool _isLocalhostServer() {
    final uri = Uri.tryParse(_serverUrl.trim());
    if (uri == null) return false;
    final host = uri.host.trim().toLowerCase();
    return host == "127.0.0.1" ||
        host == "localhost" ||
        host == "0.0.0.0" ||
        host == "::1";
  }

  Future<void> _maybeStartLocalAgent() async {
    if (_agentStartAttempted) return;
    _agentStartAttempted = true;

    final agent = DesktopAgent.instance;
    if (!agent.isAvailable) return;
    if (!_isLocalhostServer()) return;

    // Always best-effort "ensure" Core + Collector are running locally.
    // This gives the one-click desktop experience in packaged mode.
    final res =
        await agent.start(coreUrl: _serverUrl, restart: false, sendTitle: true);
    if (!mounted) return;
    if (!res.ok) {
      final details = (res.message ?? "").trim();
      if (details.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              duration: const Duration(seconds: 6),
              showCloseIcon: true,
              content: Text("Agent start failed: $details")),
        );
      }
      return;
    }

    // Refresh tracking state after Core comes up.
    await _refreshTracking();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _todayKey.currentState?.refresh(silent: true, triggerReminder: true);
      _searchKey.currentState?.refresh(silent: true);
      _plannerKey.currentState?.refresh(silent: true);
      _reportsKey.currentState?.refresh(silent: true);
    });
  }

  Future<void> _maybeAutoCheckUpdates() async {
    if (_updateCheckAttempted) return;
    _updateCheckAttempted = true;

    final mgr = UpdateManager.instance;
    if (!mgr.isAvailable) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final auto = prefs.getBool(_prefUpdateAutoCheck) ?? true;
      if (!auto) return;

      var repo = (prefs.getString(_prefUpdateRepo) ?? "").trim();
      repo =
          repo.isEmpty ? ((await mgr.defaultGitHubRepo()) ?? "").trim() : repo;
      if (repo.isEmpty) return;

      final lastIso = (prefs.getString(_prefUpdateLastCheckIso) ?? "").trim();
      if (lastIso.isNotEmpty) {
        try {
          final last = DateTime.parse(lastIso).toLocal();
          if (DateTime.now().difference(last) < const Duration(hours: 6))
            return;
        } catch (_) {
          // ignore
        }
      }

      final res = await mgr.checkLatest(gitHubRepo: repo);
      try {
        await prefs.setString(
            _prefUpdateLastCheckIso, DateTime.now().toIso8601String());
      } catch (_) {
        // ignore
      }
      if (!res.ok || !res.updateAvailable) return;
      if (!mounted) return;

      // If the app started minimized to tray, don't spam a snackbar the user won't see.
      if (widget.startMinimized) return;

      final tag = res.latest?.tag ?? "latest";
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          persist: false,
          showCloseIcon: true,
          content: Text("Update available: $tag"),
          action: SnackBarAction(
            label: "Open Settings",
            onPressed: () => _setIndex(4),
          ),
        ),
      );
    } catch (_) {
      // best effort
    }
  }

  void _maybeHandleInitialDeepLink() {
    if (_handledInitialDeepLink) return;
    _handledInitialDeepLink = true;

    final raw = widget.initialDeepLink;
    if (raw == null || raw.trim().isEmpty) return;
    _handleDeepLink(raw.trim());
  }

  void _handleDeepLink(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != "recorderphone") return;

    final route = uri.host.isNotEmpty
        ? uri.host
        : (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : "");
    if (route != "review" && route != "quick-review") return;

    final blockId =
        (uri.queryParameters["block"] ?? uri.queryParameters["block_id"])
            ?.trim();
    final action = uri.queryParameters["action"]?.trim().toLowerCase();

    if (action == "skip") {
      final id = (blockId ?? "").trim();
      if (id.isEmpty) return;
      _skipBlock(id);
      return;
    }

    if (action == "pause") {
      final minutes =
          int.tryParse((uri.queryParameters["minutes"] ?? "").trim());
      _pauseTrackingFromDeepLink(minutes: minutes);
      return;
    }

    if (action == "resume") {
      _resumeTrackingFromDeepLink();
      return;
    }

    setState(() => _index = 1);
    final review = _searchKey.currentState;
    if (review == null) return;

    if (blockId != null && blockId.isNotEmpty) {
      review.openBlockById(blockId, quick: true).catchError((_) {});
    } else {
      review.refresh().catchError((_) {});
    }
  }

  bool _deepLinkWantsForeground(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != "recorderphone") return true;
    final action = (uri.queryParameters["action"] ?? "").trim().toLowerCase();
    if (action == "skip" || action == "pause" || action == "resume")
      return false;
    return true;
  }

  Future<void> _skipBlock(String blockId) async {
    try {
      await _client.upsertReview(
        ReviewUpsert(
          blockId: blockId,
          skipped: true,
          skipReason: null,
          doing: null,
          output: null,
          next: null,
          tags: const [],
        ),
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        const SnackBar(
            duration: Duration(seconds: 4),
            showCloseIcon: true,
            content: Text("Skipped the block")),
      );
      _todayKey.currentState?.refresh(silent: true, triggerReminder: false);
      _searchKey.currentState?.refresh(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Skip failed: $e")));
    }
  }

  Future<void> _pauseTrackingFromDeepLink({int? minutes}) async {
    try {
      final status = await _client.pauseTracking(minutes: minutes);
      if (!mounted) return;
      setState(() => _tracking = status);
      final label = minutes == null ? "Paused" : "Paused ${minutes}m";
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
            duration: const Duration(seconds: 4),
            showCloseIcon: true,
            content: Text(label)),
      );
      _todayKey.currentState?.refresh(silent: true, triggerReminder: false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Pause failed: $e")));
    }
  }

  Future<void> _resumeTrackingFromDeepLink() async {
    try {
      final status = await _client.resumeTracking();
      if (!mounted) return;
      setState(() => _tracking = status);
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        const SnackBar(
            duration: Duration(seconds: 4),
            showCloseIcon: true,
            content: Text("Resumed")),
      );
      _todayKey.currentState?.refresh(silent: true, triggerReminder: false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Resume failed: $e")));
    }
  }

  Future<void> _refreshTracking() async {
    try {
      final status = await _client.trackingStatus();
      if (!mounted) return;
      setState(() => _tracking = status);
    } catch (_) {
      // best effort
    }
  }

  Future<void> _openTrackingMenu() async {
    try {
      final status = await _client.trackingStatus();
      if (!mounted) return;
      setState(() => _tracking = status);

      final paused = status.paused;
      final action = await showDialog<_TrackingAction>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text("Tracking"),
          children: [
            if (paused)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, _TrackingAction.resume),
                child: const Text("Resume"),
              )
            else ...[
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, _TrackingAction.pause15),
                child: const Text("Pause 15m"),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, _TrackingAction.pause60),
                child: const Text("Pause 1h"),
              ),
              SimpleDialogOption(
                onPressed: () =>
                    Navigator.pop(ctx, _TrackingAction.pauseManual),
                child: const Text("Pause until resume"),
              ),
            ],
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel"),
            ),
          ],
        ),
      );
      if (action == null) return;

      TrackingStatus next;
      switch (action) {
        case _TrackingAction.resume:
          next = await _client.resumeTracking();
          break;
        case _TrackingAction.pause15:
          next = await _client.pauseTracking(minutes: 15);
          break;
        case _TrackingAction.pause60:
          next = await _client.pauseTracking(minutes: 60);
          break;
        case _TrackingAction.pauseManual:
          next = await _client.pauseTracking();
          break;
      }
      if (!mounted) return;
      setState(() => _tracking = next);
      _todayKey.currentState?.refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Tracking action failed: $e")),
      );
    }
  }

  Future<void> _setServerUrl(String url) async {
    final normalized = _normalizeServerUrl(url);
    if (normalized.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefServerUrl, normalized);
    if (!mounted) return;
    setState(() {
      _serverUrl = normalized;
      final old = _client;
      _client = CoreClient(baseUrl: _serverUrl);
      old.close();
      _agentStartAttempted = false;
    });

    unawaited(_maybeStartLocalAgent());
    unawaited(TrayController.instance.refreshStatus());
    await _refreshTracking();
    _todayKey.currentState?.refresh();
    _searchKey.currentState?.refresh();
  }

  void _setIndex(int i) => setState(() => _index = i);

  Future<void> _goToTab(int i) async {
    if (!mounted) return;
    setState(() => _index = i);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _ensureVisible(GlobalKey key) async {
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

  Future<void> _openTutorial() async {
    if (_tutorialRunning) return;
    setState(() => _tutorialRunning = true);
    try {
      final isWide = MediaQuery.of(context).size.width >= 720;
      final navKey = isWide ? _tutorialNavRailKey : _tutorialBottomNavKey;
      final runner = TutorialRunner(
        context: context,
        steps: [
          const TutorialStep(
            title: "欢迎使用 RecorderPhone",
            body:
                "RecorderPhone 会在本地记录你在电脑/浏览器上的使用情况，并按时间段（Block）帮你复盘。\n\n接下来用 1 分钟了解核心功能。",
          ),
          TutorialStep(
            title: "页面导航",
            body:
                "这里是页面导航：\n- Today：今日概览（Now + 时间轴）\n- Review：复盘你的 Block\n- Planner：日程与待办（日/周/月）\n- Reports：日报/周报导出\n- Settings：隐私/提醒/更新\n\n你可以随时点击右上角“？”重新打开教程。",
            targetKey: navKey,
            targetHint: "用这里切换页面",
            allowInteraction: true,
          ),
          TutorialStep(
            title: "采集开关（Tracking）",
            body: "这里可以暂停/恢复采集。需要临时不记录时，建议先 Pause，避免“空白/噪音”数据进入复盘。",
            targetKey: _tutorialTrackingKey,
            targetHint: "点这里暂停/恢复",
            allowInteraction: true,
          ),
          TutorialStep(
            title: "Now：你正在用什么",
            body:
                "Now 代表“正在使用”的信息：\n- Focus app：当前前台应用\n- Using tab：你正在看的网页 Tab（或后台播放且有声音的 Tab）\n\n想看到 YouTube 视频名等标题，需要在设置里开启隐私 L2，并在扩展/采集器开启发送标题。",
            targetKey: _tutorialNowKey,
            targetHint: "这里看“正在用”",
            allowInteraction: true,
            beforeShow: () async {
              await _goToTab(0);
              await _todayKey.currentState?.scrollToTutorialNow();
            },
          ),
          TutorialStep(
            title: "首页时间轴（0:00–24:00）",
            body:
                "时间轴用“泳道”展示今天的应用/网站使用分布：\n- 横轴是时间\n- 纵轴是应用/网站（按总时长或按时间排序）\n- 点某段可直达对应 Block 详情/快速复盘\n\n小技巧：Ctrl + 鼠标滚轮可缩放，拖动可平移。",
            targetKey: _tutorialTimelineKey,
            targetHint: "拖动/缩放试试",
            allowInteraction: true,
            beforeShow: () async {
              await _goToTab(0);
              await _todayKey.currentState?.scrollToTutorialTimeline();
            },
          ),
          TutorialStep(
            title: "Review：复盘你的 Block",
            body:
                "Review 页面会列出需要复盘的 Block。\n进入某个 Block 后可以快速写：Doing / Output / Next 或打标签。\n\n如果这段不值得复盘，可以点 Skip：标记为已处理，之后不会再提醒（也可撤销）。",
            targetKey: _tutorialReviewHeaderKey,
            targetHint: "这里是待复盘列表",
            allowInteraction: true,
            beforeShow: () async {
              await _goToTab(1);
              await _ensureVisible(_tutorialReviewHeaderKey);
            },
          ),
          TutorialStep(
            title: "隐私级别：标题粒度的开关",
            body:
                "隐私级别决定“记录的细粒度”：\n- L1：不存标题（只看域名/应用名）\n- L2：存窗口/Tab 标题（可区分 YouTube 不同视频、VS Code workspace 等）\n- L3：额外存 exePath（更敏感）\n\n建议先用 L2，体验更完整。",
            targetKey: _tutorialPrivacyKey,
            targetHint: "建议选 L2",
            allowInteraction: true,
            beforeShow: () async {
              await _goToTab(4);
              await _settingsKey.currentState?.scrollToTutorialPrivacy();
            },
          ),
          const TutorialStep(
            title: "完成",
            body:
                "你随时可以在设置里重新打开新手引导。\n\n接下来建议：先开 1 天，让数据“跑起来”，再回到 Review 做一次快速复盘。",
          ),
        ],
      );
      await runner.start();
      await runner.done;
    } finally {
      if (mounted) setState(() => _tutorialRunning = false);
    }
  }

  String _trackingChipLabel(TrackingStatus? s) {
    if (s == null) return "采集…";
    if (!s.paused) return "采集中";

    final until = s.pausedUntilTs;
    if (until == null || until.trim().isEmpty) return "已暂停";
    try {
      final t = DateTime.parse(until).toLocal();
      final diff = t.difference(DateTime.now());
      if (diff.inSeconds <= 0) return "已暂停";
      final m = (diff.inSeconds / 60).ceil().clamp(1, 9999);
      return "已暂停 ${m}m";
    } catch (_) {
      return "已暂停";
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isWide = MediaQuery.of(context).size.width >= 720;
    final titles = ["Today", "Review", "Planner", "Reports", "Settings"];

    final pages = [
      TodayScreen(
        key: _todayKey,
        client: _client,
        serverUrl: _serverUrl,
        isActive: _index == 0,
        onOpenReview: () => _setIndex(1),
        onOpenSettings: () => _setIndex(4),
        tutorialNowKey: _tutorialNowKey,
        tutorialTimelineKey: _tutorialTimelineKey,
        onOpenReviewQuery: (q, day) async {
          _setIndex(1);
          final review = _searchKey.currentState;
          if (review != null) {
            await review.setDay(day, refresh: false);
            await review.applyQuery(q);
          }
        },
      ),
      SearchScreen(
        key: _searchKey,
        client: _client,
        serverUrl: _serverUrl,
        isActive: _index == 1,
        tutorialHeaderKey: _tutorialReviewHeaderKey,
      ),
      ReportsScreen(
        key: _plannerKey,
        client: _client,
        serverUrl: _serverUrl,
        onOpenSettings: () => _setIndex(4),
        isActive: _index == 2,
        plannerMode: true,
      ),
      ReportsScreen(
        key: _reportsKey,
        client: _client,
        serverUrl: _serverUrl,
        onOpenSettings: () => _setIndex(4),
        isActive: _index == 3,
      ),
      SettingsScreen(
        key: _settingsKey,
        client: _client,
        serverUrl: _serverUrl,
        onServerUrlChanged: _setServerUrl,
        isActive: _index == 4,
        onOpenTutorial: _openTutorial,
        tutorialPrivacyKey: _tutorialPrivacyKey,
      ),
    ];

    final trackingLabel = _trackingChipLabel(_tracking);
    final scheme = Theme.of(context).colorScheme;
    final paused = _tracking?.paused == true;

    final actions = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: ActionChip(
          key: _tutorialTrackingKey,
          label: Text(trackingLabel),
          avatar: Icon(
            paused ? Icons.pause_circle_filled : Icons.fiber_manual_record,
            size: 16,
            color: paused ? scheme.onSurfaceVariant : scheme.primary,
          ),
          onPressed: _openTrackingMenu,
        ),
      ),
      IconButton(
        onPressed: _tutorialRunning ? null : _openTutorial,
        tooltip: "教程",
        icon: const Icon(Icons.help_outline),
      ),
      if (_index == 0)
        IconButton(
          onPressed: () => _todayKey.currentState?.refresh(),
          tooltip: "Refresh",
          icon: const Icon(Icons.refresh),
        ),
      if (_index == 1)
        IconButton(
          onPressed: () => _searchKey.currentState?.refresh(),
          tooltip: "Refresh",
          icon: const Icon(Icons.refresh),
        ),
      if (_index == 2)
        IconButton(
          onPressed: () => _plannerKey.currentState?.refresh(),
          tooltip: "Refresh",
          icon: const Icon(Icons.refresh),
        ),
      if (_index == 3)
        IconButton(
          onPressed: () => _reportsKey.currentState?.refresh(),
          tooltip: "Refresh",
          icon: const Icon(Icons.refresh),
        ),
    ];

    if (isWide) {
      return Scaffold(
        appBar: AppBar(title: Text(titles[_index]), actions: actions),
        body: Row(
          children: [
            Container(
              key: _tutorialNavRailKey,
              child: NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: _setIndex,
                labelType: NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.today_outlined),
                    selectedIcon: Icon(Icons.today),
                    label: Text("Today"),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.list_alt_outlined),
                    selectedIcon: Icon(Icons.list_alt),
                    label: Text("Review"),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.calendar_month_outlined),
                    selectedIcon: Icon(Icons.calendar_month),
                    label: Text("Planner"),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.article_outlined),
                    selectedIcon: Icon(Icons.article),
                    label: Text("Reports"),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: Text("Settings"),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: IndexedStack(index: _index, children: pages)),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(titles[_index]), actions: actions),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        key: _tutorialBottomNavKey,
        selectedIndex: _index,
        onDestinationSelected: _setIndex,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.today_outlined),
            selectedIcon: Icon(Icons.today),
            label: "Today",
          ),
          NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: "Review",
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: "Planner",
          ),
          NavigationDestination(
            icon: Icon(Icons.article_outlined),
            selectedIcon: Icon(Icons.article),
            label: "Reports",
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: "Settings",
          ),
        ],
      ),
    );
  }
}
