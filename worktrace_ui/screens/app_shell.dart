import "dart:async";

import "package:flutter/material.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../api/core_client.dart";
import "settings_screen.dart";
import "today_screen.dart";

enum _TrackingAction { resume, pause15, pause60, pauseManual }

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const _prefServerUrl = "serverUrl";
  static const _defaultServerUrl = "http://127.0.0.1:17600";

  final _todayKey = GlobalKey<TodayScreenState>();

  bool _ready = false;
  int _index = 0;

  String _serverUrl = _defaultServerUrl;
  late CoreClient _client = CoreClient(baseUrl: _serverUrl);
  TrackingStatus? _tracking;
  Timer? _trackingTimer;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _trackingTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_prefServerUrl);
    if (v != null && v.trim().isNotEmpty) {
      _serverUrl = v.trim();
      _client = CoreClient(baseUrl: _serverUrl);
    }
    if (!mounted) return;
    setState(() => _ready = true);
    await _refreshTracking();
    _trackingTimer?.cancel();
    _trackingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshTracking();
    });
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
                onPressed: () => Navigator.pop(ctx, _TrackingAction.pauseManual),
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
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefServerUrl, trimmed);
    if (!mounted) return;
    setState(() {
      _serverUrl = trimmed;
      _client = CoreClient(baseUrl: _serverUrl);
    });

    await _refreshTracking();
    _todayKey.currentState?.refresh();
  }

  void _setIndex(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isWide = MediaQuery.of(context).size.width >= 720;
    final titles = ["Today", "Settings"];

    final pages = [
      TodayScreen(key: _todayKey, client: _client, serverUrl: _serverUrl),
      SettingsScreen(
        client: _client,
        serverUrl: _serverUrl,
        onServerUrlChanged: _setServerUrl,
      ),
    ];

    final trackingLabel = _tracking == null
        ? "…"
        : _tracking!.paused
            ? "PAUSED"
            : "ON";

    final actions = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: ActionChip(
          label: Text(trackingLabel),
          avatar: Icon(
            _tracking?.paused == true ? Icons.pause : Icons.play_arrow,
            size: 18,
          ),
          onPressed: _openTrackingMenu,
        ),
      ),
      if (_index == 0)
        IconButton(
          onPressed: () => _todayKey.currentState?.refresh(),
          tooltip: "Refresh",
          icon: const Icon(Icons.refresh),
        ),
    ];

    if (isWide) {
      return Scaffold(
        appBar: AppBar(title: Text(titles[_index]), actions: actions),
        body: Row(
          children: [
            NavigationRail(
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
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: Text("Settings"),
                ),
              ],
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
        selectedIndex: _index,
        onDestinationSelected: _setIndex,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.today_outlined),
            selectedIcon: Icon(Icons.today),
            label: "Today",
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
