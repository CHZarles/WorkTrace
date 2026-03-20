import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:system_tray/system_tray.dart";
import "package:window_manager/window_manager.dart";

import "../api/core_client.dart";
import "desktop_agent.dart";
import "tray_controller.dart";

TrayController getTrayController() => _IoTrayController();

class _TrayStatus {
  const _TrayStatus({
    required this.coreHealthy,
    required this.trackingLabel,
  });

  final bool coreHealthy;
  final String trackingLabel;
}

class _IoTrayController with WindowListener implements TrayController {
  final SystemTray _tray = SystemTray();
  final Menu _menu = Menu();

  bool _initialized = false;
  bool _allowClose = false;
  bool _busy = false;

  String Function()? _getServerUrl;
  Future<void> Function()? _onQuickReview;

  Timer? _timer;
  _TrayStatus _status =
      const _TrayStatus(coreHealthy: false, trackingLabel: "…");

  @override
  bool get isAvailable => !kIsWeb && Platform.isWindows;

  String _join(String a, String b) {
    final sep = Platform.pathSeparator;
    if (a.endsWith(sep)) return "$a$b";
    return "$a$sep$b";
  }

  String _appDirPath() {
    try {
      return File(Platform.resolvedExecutable).parent.path;
    } catch (_) {
      return "";
    }
  }

  String _userDataDirPath(String name) {
    final sep = Platform.pathSeparator;
    final base = (Platform.environment["LOCALAPPDATA"] ?? "").trim();
    final fallback = (Platform.environment["APPDATA"] ?? "").trim();
    final root = base.isNotEmpty
        ? base
        : (fallback.isNotEmpty ? fallback : Directory.systemTemp.path);
    return "$root${sep}$name";
  }

  String _defaultDataDirPath() {
    final current = _userDataDirPath("WorkTrace");
    if (Directory(current).existsSync()) return current;

    final legacy = _userDataDirPath("RecorderPhone");
    if (!Directory(legacy).existsSync()) return current;

    try {
      return Directory(legacy).renameSync(current).path;
    } catch (_) {
      return legacy;
    }
  }

  Future<void> _openPathInExplorer(String path,
      {bool ensureDirectoryExists = false}) async {
    final p = path.trim();
    if (p.isEmpty) return;
    if (ensureDirectoryExists) {
      try {
        await Directory(p).create(recursive: true);
      } catch (_) {
        // ignore
      }
    }
    try {
      await Process.start("explorer.exe", [p], mode: ProcessStartMode.detached);
      return;
    } catch (_) {
      // fallback
    }
    try {
      await Process.run("explorer.exe", [p]);
    } catch (_) {
      // ignore
    }
  }

  String _trayIconPath() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final candidate = _join(_join(_join(exeDir, "data"), "flutter_assets"),
          "assets${Platform.pathSeparator}tray.ico");
      if (File(candidate).existsSync()) return candidate;
    } catch (_) {
      // ignore
    }
    // Best-effort fallback: use default app icon.
    return "";
  }

  bool _isLocalhostServer(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null) return false;
    final host = u.host.trim().toLowerCase();
    return host == "127.0.0.1" ||
        host == "localhost" ||
        host == "0.0.0.0" ||
        host == "::1";
  }

  String _trackingLabel(TrackingStatus? s) {
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

  Future<_TrayStatus> _fetchStatus() async {
    final url = _getServerUrl?.call() ?? "";
    if (url.trim().isEmpty) {
      return const _TrayStatus(coreHealthy: false, trackingLabel: "…");
    }

    final c = CoreClient(baseUrl: url);
    try {
      final info = await c.healthInfo();
      final ok = info.service == "recorder_core";
      if (!ok) return const _TrayStatus(coreHealthy: false, trackingLabel: "…");
      final tracking = await c.trackingStatus();
      return _TrayStatus(
          coreHealthy: true, trackingLabel: _trackingLabel(tracking));
    } catch (_) {
      return const _TrayStatus(coreHealthy: false, trackingLabel: "…");
    } finally {
      c.close();
    }
  }

  Future<void> _showWindow() async {
    try {
      await windowManager.show();
      await windowManager.restore();
      await windowManager.focus();
    } catch (_) {
      // ignore
    }
  }

  Future<void> _hideWindow() async {
    try {
      await windowManager.hide();
    } catch (_) {
      // ignore
    }
  }

  Future<void> _toggleWindow() async {
    try {
      final visible = await windowManager.isVisible();
      if (visible) {
        await _hideWindow();
      } else {
        await _showWindow();
      }
    } catch (_) {
      await _showWindow();
    }
  }

  Future<void> _pauseTracking({int? minutes}) async {
    final url = _getServerUrl?.call() ?? "";
    final c = CoreClient(baseUrl: url);
    try {
      await c.pauseTracking(minutes: minutes);
    } catch (_) {
      // ignore
    } finally {
      c.close();
      unawaited(refreshStatus());
    }
  }

  Future<void> _resumeTracking() async {
    final url = _getServerUrl?.call() ?? "";
    final c = CoreClient(baseUrl: url);
    try {
      await c.resumeTracking();
    } catch (_) {
      // ignore
    } finally {
      c.close();
      unawaited(refreshStatus());
    }
  }

  Future<void> _startAgent({required bool restart}) async {
    if (_busy) return;
    final url = _getServerUrl?.call() ?? "";
    if (!_isLocalhostServer(url)) return;
    final agent = DesktopAgent.instance;
    if (!agent.isAvailable) return;

    _busy = true;
    try {
      await agent.start(
          coreUrl: url,
          restart: restart,
          sendTitle: true,
          trackAudio: true,
          reviewNotify: true);
    } catch (_) {
      // ignore
    } finally {
      _busy = false;
      unawaited(refreshStatus());
    }
  }

  Future<void> _stopAgent() async {
    if (_busy) return;
    final agent = DesktopAgent.instance;
    if (!agent.isAvailable) return;
    _busy = true;
    try {
      await agent.stop(killAllByName: true);
    } catch (_) {
      // ignore
    } finally {
      _busy = false;
      unawaited(refreshStatus());
    }
  }

  Future<void> _exitApp() async {
    _allowClose = true;
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {
      // ignore
    }
    try {
      await windowManager.close();
    } catch (_) {
      exit(0);
    }
  }

  Future<void> _rebuildMenu() async {
    final url = _getServerUrl?.call() ?? "";
    final canStartAgent =
        _isLocalhostServer(url) && DesktopAgent.instance.isAvailable;

    final statusLine = _status.coreHealthy ? "Core: OK" : "Core: DOWN";
    final trackingLine = "Tracking: ${_status.trackingLabel}";

    await _menu.buildFrom([
      MenuItemLabel(label: "WorkTrace", enabled: false),
      MenuItemLabel(label: statusLine, enabled: false),
      MenuItemLabel(label: trackingLine, enabled: false),
      if (url.trim().isNotEmpty)
        MenuItemLabel(label: "Server: $url", enabled: false),
      MenuSeparator(),
      MenuItemLabel(label: "Open / Hide", onClicked: (_) => _toggleWindow()),
      MenuItemLabel(
        label: "Open app folder",
        onClicked: (_) => _openPathInExplorer(_appDirPath()),
      ),
      MenuItemLabel(
        label: "Open data folder",
        onClicked: (_) => _openPathInExplorer(_defaultDataDirPath(),
            ensureDirectoryExists: true),
      ),
      MenuItemLabel(
        label: "Quick Review",
        onClicked: (_) async {
          await _showWindow();
          await (_onQuickReview?.call() ?? Future<void>.value());
        },
      ),
      MenuSeparator(),
      MenuItemLabel(
          label: "Pause 15m", onClicked: (_) => _pauseTracking(minutes: 15)),
      MenuItemLabel(
          label: "Pause 1h", onClicked: (_) => _pauseTracking(minutes: 60)),
      MenuItemLabel(
          label: "Pause (manual)", onClicked: (_) => _pauseTracking()),
      MenuItemLabel(label: "Resume", onClicked: (_) => _resumeTracking()),
      MenuSeparator(),
      MenuItemLabel(
        label: _busy ? "Starting…" : "Start Agent",
        enabled: !_busy && canStartAgent,
        onClicked: (_) => _startAgent(restart: false),
      ),
      MenuItemLabel(
        label: _busy ? "Restarting…" : "Restart Agent",
        enabled: !_busy && canStartAgent,
        onClicked: (_) => _startAgent(restart: true),
      ),
      MenuItemLabel(
        label: _busy ? "Stopping…" : "Stop Agent",
        enabled: !_busy && DesktopAgent.instance.isAvailable,
        onClicked: (_) => _stopAgent(),
      ),
      MenuSeparator(),
      MenuItemLabel(label: "Exit", onClicked: (_) => _exitApp()),
    ]);

    await _tray.setContextMenu(_menu);
  }

  @override
  Future<void> ensureInitialized({
    required String Function() getServerUrl,
    required Future<void> Function() onQuickReview,
    bool startHidden = false,
  }) async {
    if (_initialized) return;
    if (!isAvailable) return;

    _initialized = true;
    _getServerUrl = getServerUrl;
    _onQuickReview = onQuickReview;

    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    final iconPath = _trayIconPath();
    await _tray.initSystemTray(title: "WorkTrace", iconPath: iconPath);

    _tray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick ||
          eventName == kSystemTrayEventDoubleClick) {
        // Keep this simple and reliable: click always brings the window to front.
        unawaited(_showWindow());
        return;
      }

      if (eventName == kSystemTrayEventRightClick) {
        // On Windows, right-click does not automatically show the context menu.
        unawaited(_tray.popUpContextMenu());
      }
    });

    _timer?.cancel();
    _timer =
        Timer.periodic(const Duration(seconds: 15), (_) => refreshStatus());
    await refreshStatus();

    if (startHidden) {
      // Give the window a moment to be created before hiding.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await _hideWindow();
    }
  }

  @override
  Future<void> refreshStatus() async {
    if (!isAvailable) return;
    _status = await _fetchStatus();
    await _rebuildMenu();
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    if (!isAvailable) return;
    try {
      windowManager.removeListener(this);
    } catch (_) {
      // ignore
    }
  }

  @override
  void onWindowClose() {
    if (_allowClose) {
      windowManager.destroy();
      return;
    }
    unawaited(_hideWindow());
  }
}
