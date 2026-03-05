import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../api/core_client.dart";
import "../theme/tokens.dart";
import "../utils/desktop_agent.dart";
import "../utils/format.dart";
import "../utils/startup.dart";
import "../utils/update_manager.dart";

enum _PrivacyLevel { l1, l2, l3 }

enum _RuleFilter { all, domains, apps }

enum _SettingsPanel { overview, diagnostics, trackingPrivacy, data }

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.client,
    required this.serverUrl,
    required this.onServerUrlChanged,
    this.isActive = false,
    this.onOpenTutorial,
    this.tutorialPrivacyKey,
  });

  final CoreClient client;
  final String serverUrl;
  final Future<void> Function(String url) onServerUrlChanged;
  final bool isActive;
  final VoidCallback? onOpenTutorial;
  final GlobalKey? tutorialPrivacyKey;

  @override
  State<SettingsScreen> createState() => SettingsScreenState();
}

class SettingsScreenState extends State<SettingsScreen> {
  static const _prefUpdateRepo = "updateGitHubRepo";
  static const _prefUpdateAutoCheck = "updateAutoCheck";
  static const _prefUpdateLastCheckIso = "updateLastCheckIso";

  late final TextEditingController _dateLocal;
  late final TextEditingController _blockMinutes;
  late final TextEditingController _idleCutoffMinutes;
  late final TextEditingController _reviewMinMinutes;
  late final TextEditingController _reviewToastRepeatMinutes;
  late final TextEditingController _ruleQuery;
  late final TextEditingController _updateRepo;
  _RuleFilter _ruleFilter = _RuleFilter.all;
  _SettingsPanel _settingsPanel = _SettingsPanel.overview;
  final ScrollController _scrollV = ScrollController();

  bool _healthLoading = false;
  bool? _healthOk;
  String? _healthError;
  HealthInfo? _healthInfo;

  bool _coreSettingsLoading = false;
  bool _coreSettingsSaving = false;
  bool _coreNumbersSaving = false;
  bool _privacySaving = false;
  bool _reviewSaving = false;
  Timer? _reviewSaveDebounce;
  String? _coreSettingsError;
  CoreSettings? _coreSettings;
  bool _storeTitles = false;
  bool _storeExePath = false;
  bool _reviewNotifyWhenPaused = false;
  bool _reviewNotifyWhenIdle = false;

  bool _rulesLoading = false;
  String? _rulesError;
  List<PrivacyRule> _rules = const [];

  bool _nowLoading = false;
  String? _nowError;
  NowSnapshot? _now;

  bool _eventsLoading = false;
  String? _eventsError;
  List<EventRecord> _events = const [];

  bool _deleteDayLoading = false;
  bool _wipeAllLoading = false;

  bool _agentBusy = false;
  String? _agentRepoRoot;

  bool _startupBusy = false;
  bool? _startupEnabled;
  String? _startupError;

  bool _updatesLoading = false;
  bool _updatesInstalling = false;
  bool _updateAutoCheck = true;
  DateTime? _updateLastCheckedAt;
  String? _updatesError;
  BuildInfo? _buildInfo;
  UpdateRelease? _latestRelease;
  bool _updateAvailable = false;
  Timer? _updateRepoSaveDebounce;

  Future<void> refresh() async {
    await _refreshAll();
  }

  @override
  void initState() {
    super.initState();
    _dateLocal = TextEditingController(text: _todayLocal());
    _blockMinutes = TextEditingController(text: "45");
    _idleCutoffMinutes = TextEditingController(text: "5");
    _reviewMinMinutes = TextEditingController(text: "5");
    _reviewToastRepeatMinutes = TextEditingController(text: "10");
    _ruleQuery = TextEditingController();
    _updateRepo = TextEditingController();
    _refreshAll();
    _loadAgentInfo();
    _loadStartup();
    _loadUpdatePrefsAndInfo();
  }

  Future<void> _loadUpdatePrefsAndInfo() async {
    final mgr = UpdateManager.instance;
    if (!mgr.isAvailable) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final repoPref = (prefs.getString(_prefUpdateRepo) ?? "").trim();
      final auto = prefs.getBool(_prefUpdateAutoCheck);
      final lastIso = (prefs.getString(_prefUpdateLastCheckIso) ?? "").trim();
      DateTime? last;
      if (lastIso.isNotEmpty) {
        try {
          last = DateTime.parse(lastIso).toLocal();
        } catch (_) {
          last = null;
        }
      }

      final build = await mgr.readBuildInfo();
      final repoDefault = (build?.updateGitHubRepo ?? "").trim();
      final repo = repoPref.isNotEmpty ? repoPref : repoDefault;

      if (!mounted) return;
      setState(() {
        _buildInfo = build;
        _updateAutoCheck = auto ?? true;
        _updateLastCheckedAt = last;
        if (_updateRepo.text.trim().isEmpty) _updateRepo.text = repo;
      });

      if (_updateAutoCheck && repo.trim().isNotEmpty) {
        await _checkUpdates(force: false);
      }
    } catch (_) {
      // best effort
    }
  }

  Future<void> _saveUpdateRepo(String repo) async {
    final mgr = UpdateManager.instance;
    if (!mgr.isAvailable) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = repo.trim();
      if (v.isEmpty) {
        await prefs.remove(_prefUpdateRepo);
      } else {
        await prefs.setString(_prefUpdateRepo, v);
      }
    } catch (_) {
      // ignore
    }
  }

  void _scheduleSaveUpdateRepo() {
    _updateRepoSaveDebounce?.cancel();
    _updateRepoSaveDebounce = Timer(const Duration(milliseconds: 650), () {
      _saveUpdateRepo(_updateRepo.text);
    });
  }

  Future<void> _setUpdateAutoCheck(bool enabled) async {
    final mgr = UpdateManager.instance;
    if (!mgr.isAvailable) return;
    setState(() => _updateAutoCheck = enabled);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefUpdateAutoCheck, enabled);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _setUpdateLastChecked(DateTime t) async {
    final mgr = UpdateManager.instance;
    if (!mgr.isAvailable) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefUpdateLastCheckIso, t.toIso8601String());
    } catch (_) {
      // ignore
    }
  }

  Future<void> _checkUpdates({required bool force}) async {
    final mgr = UpdateManager.instance;
    if (!mgr.isAvailable) return;
    if (_updatesLoading || _updatesInstalling) return;

    final repo = _updateRepo.text.trim();
    if (repo.isEmpty) {
      setState(() {
        _latestRelease = null;
        _updateAvailable = false;
        _updatesError = "Set GitHub repo (owner/name) to enable updates.";
      });
      return;
    }

    final now = DateTime.now();
    if (!force && _updateLastCheckedAt != null) {
      final d = now.difference(_updateLastCheckedAt!);
      if (d < const Duration(hours: 6)) return;
    }

    setState(() {
      _updatesLoading = true;
      _updatesError = null;
    });
    try {
      final res = await mgr.checkLatest(gitHubRepo: repo);
      if (!mounted) return;
      setState(() {
        _buildInfo = res.current ?? _buildInfo;
        _latestRelease = res.latest;
        _updateAvailable = res.ok && res.updateAvailable;
        _updatesError = res.ok ? null : (res.error ?? "update_check_failed");
        _updateLastCheckedAt = now;
      });
      await _setUpdateLastChecked(now);
    } finally {
      if (mounted) setState(() => _updatesLoading = false);
    }
  }

  String _shortSha(String? sha) {
    final s = (sha ?? "").trim();
    if (s.isEmpty) return "";
    return s.length <= 12 ? s : s.substring(0, 12);
  }

  String _formatLocalTime(DateTime? t) {
    if (t == null) return "";
    final y = t.year.toString().padLeft(4, "0");
    final m = t.month.toString().padLeft(2, "0");
    final d = t.day.toString().padLeft(2, "0");
    final hh = t.hour.toString().padLeft(2, "0");
    final mm = t.minute.toString().padLeft(2, "0");
    return "$y-$m-$d $hh:$mm";
  }

  Future<void> _installUpdate() async {
    final mgr = UpdateManager.instance;
    if (!mgr.isAvailable) return;
    final latest = _latestRelease;
    final url = (latest?.assetUrl ?? "").trim();
    if (latest == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No update asset found.")));
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Update to ${latest.tag}?"),
        content: const Text(
            "RecorderPhone will close, install the update, then restart."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Cancel")),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Update & restart")),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _updatesInstalling = true;
      _updatesError = null;
    });
    try {
      final agent = DesktopAgent.instance;
      if (agent.isAvailable) {
        await agent.stop(killAllByName: true);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      final res = await mgr.installUpdate(latest: latest, installAssetUrl: url);
      if (!mounted) return;
      if (!res.ok) {
        setState(() => _updatesError = res.error ?? "install_failed");
        return;
      }

      // Updater will restart the app; exit this process immediately.
      mgr.exitApp();
    } finally {
      if (mounted) setState(() => _updatesInstalling = false);
    }
  }

  Future<void> _loadAgentInfo() async {
    final agent = DesktopAgent.instance;
    if (!agent.isAvailable) return;
    try {
      final root = await agent.findRepoRoot();
      if (!mounted) return;
      setState(() => _agentRepoRoot = root);
    } catch (_) {
      // best effort
    }
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

  Future<void> _startAgent({required bool restart}) async {
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
        coreUrl: widget.serverUrl,
        restart: restart,
        // Collector can always send titles; Core controls whether to store them via privacy level.
        sendTitle: true,
      );
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
      await _refreshAll();
    } finally {
      if (mounted) setState(() => _agentBusy = false);
    }
  }

  Future<void> _stopAgent() async {
    final agent = DesktopAgent.instance;
    if (!agent.isAvailable) return;
    setState(() => _agentBusy = true);
    try {
      final res = await agent.stop(killAllByName: true);
      if (!mounted) return;
      final msg = res.ok ? "Agent stopped" : "Agent stop failed";
      final details = (res.message ?? "").trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          showCloseIcon: true,
          content: Text(details.isEmpty ? msg : "$msg: $details"),
        ),
      );
      await _refreshAll();
    } finally {
      if (mounted) setState(() => _agentBusy = false);
    }
  }

  Future<void> _loadStartup() async {
    final startup = StartupController.instance;
    if (!startup.isAvailable) return;
    try {
      final enabled = await startup.isEnabled();
      if (!mounted) return;
      setState(() {
        _startupEnabled = enabled;
        _startupError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _startupError = e.toString());
    }
  }

  Future<void> _setStartupEnabled(bool enabled) async {
    final startup = StartupController.instance;
    if (!startup.isAvailable) return;
    setState(() {
      _startupBusy = true;
      _startupError = null;
    });
    try {
      await startup.setEnabled(enabled, startHidden: true);
      await _loadStartup();
    } catch (e) {
      if (!mounted) return;
      setState(() => _startupError = e.toString());
      rethrow;
    } finally {
      if (mounted) setState(() => _startupBusy = false);
    }
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverUrl != widget.serverUrl) {
      _refreshAll();
    }
    if (!oldWidget.isActive && widget.isActive) {
      // Settings is shown via IndexedStack. Refresh on entry so users don't have to manually
      // click "Refresh" after Core becomes healthy (e.g. when the desktop agent starts up).
      _refreshAll();
      if (UpdateManager.instance.isAvailable && _updateAutoCheck) {
        unawaited(_checkUpdates(force: false));
      }
    }
  }

  @override
  void dispose() {
    _dateLocal.dispose();
    _blockMinutes.dispose();
    _idleCutoffMinutes.dispose();
    _reviewMinMinutes.dispose();
    _reviewToastRepeatMinutes.dispose();
    _reviewSaveDebounce?.cancel();
    _ruleQuery.dispose();
    _updateRepo.dispose();
    _updateRepoSaveDebounce?.cancel();
    _scrollV.dispose();
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

    try {
      _scrollV.jumpTo(0);
    } catch (_) {
      // ignore
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await WidgetsBinding.instance.endOfFrame;

    for (var i = 0; i < 20; i++) {
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

  Future<void> scrollToTutorialPrivacy() async {
    await _scrollToTutorialKey(widget.tutorialPrivacyKey);
  }

  String _todayLocal() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, "0");
    final m = now.month.toString().padLeft(2, "0");
    final d = now.day.toString().padLeft(2, "0");
    return "$y-$m-$d";
  }

  Future<void> _refreshAll() async {
    await widget.client.waitUntilHealthy(
      timeout: _isLocalServerUrl()
          ? const Duration(seconds: 15)
          : const Duration(seconds: 6),
    );
    await Future.wait([
      _checkHealth(),
      _loadCoreSettings(),
      _loadRules(),
      _loadNow(),
      _loadEvents()
    ]);
  }

  Future<void> _checkHealth() async {
    setState(() {
      _healthLoading = true;
      _healthError = null;
    });
    try {
      if (!mounted) return;
      setState(() {
        _healthOk = true;
        _healthInfo = null;
      });
      final info = await widget.client.healthInfo();
      if (!mounted) return;
      setState(() => _healthInfo = info);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _healthOk = false;
        _healthError = e.toString();
        _healthInfo = null;
      });
    } finally {
      if (mounted) setState(() => _healthLoading = false);
    }
  }

  int _minsFromSeconds(int seconds) {
    return ((seconds + 30) / 60).floor();
  }

  Future<void> _loadCoreSettings() async {
    setState(() {
      _coreSettingsLoading = true;
      _coreSettingsError = null;
    });
    try {
      final s = await widget.client.settings();
      if (!mounted) return;
      setState(() {
        _coreSettings = s;
        _blockMinutes.text = _minsFromSeconds(s.blockSeconds).toString();
        _idleCutoffMinutes.text =
            _minsFromSeconds(s.idleCutoffSeconds).toString();
        _reviewMinMinutes.text =
            _minsFromSeconds(s.reviewMinSeconds).toString();
        _reviewToastRepeatMinutes.text = s.reviewNotifyRepeatMinutes.toString();
        _reviewNotifyWhenPaused = s.reviewNotifyWhenPaused;
        _reviewNotifyWhenIdle = s.reviewNotifyWhenIdle;
        _storeTitles = s.storeTitles;
        _storeExePath = s.storeExePath;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _coreSettingsError = e.toString();
      });
    } finally {
      if (mounted) setState(() => _coreSettingsLoading = false);
    }
  }

  Future<void> _saveCoreSettings() async {
    final blockMin = int.tryParse(_blockMinutes.text.trim());
    final idleMin = int.tryParse(_idleCutoffMinutes.text.trim());
    if (blockMin == null || blockMin < 1) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Invalid block minutes")));
      return;
    }
    if (idleMin == null || idleMin < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Invalid idle cutoff minutes")));
      return;
    }

    setState(() {
      _coreSettingsSaving = true;
      _coreNumbersSaving = true;
      _privacySaving = false;
      _coreSettingsError = null;
    });

    try {
      final s = await widget.client.updateSettings(
        blockSeconds: blockMin * 60,
        idleCutoffSeconds: idleMin * 60,
      );
      if (!mounted) return;
      setState(() {
        _coreSettings = s;
        _blockMinutes.text = _minsFromSeconds(s.blockSeconds).toString();
        _idleCutoffMinutes.text =
            _minsFromSeconds(s.idleCutoffSeconds).toString();
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Core settings saved")));
    } catch (e) {
      if (!mounted) return;
      setState(() => _coreSettingsError = e.toString());
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Save failed: $e")));
    } finally {
      if (mounted) {
        setState(() {
          _coreSettingsSaving = false;
          _coreNumbersSaving = false;
        });
      }
    }
  }

  bool _privacyDirty() {
    final s = _coreSettings;
    if (s == null) return false;
    return s.storeTitles != _storeTitles || s.storeExePath != _storeExePath;
  }

  Future<void> _savePrivacySettings() async {
    if (_coreSettingsSaving) return;
    if (_coreSettings == null) return;
    if (!_privacyDirty()) return;

    setState(() {
      _coreSettingsSaving = true;
      _coreNumbersSaving = false;
      _privacySaving = true;
      _coreSettingsError = null;
    });

    try {
      final s = await widget.client.updateSettings(
        storeTitles: _storeTitles,
        storeExePath: _storeExePath,
      );
      if (!mounted) return;
      setState(() => _coreSettings = s);
    } catch (e) {
      if (!mounted) return;
      setState(() => _coreSettingsError = e.toString());
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Privacy save failed: $e")));
      // Best-effort: reload persisted state to avoid UI drift.
      unawaited(_loadCoreSettings());
    } finally {
      if (mounted) {
        setState(() {
          _coreSettingsSaving = false;
          _privacySaving = false;
        });
      }
    }
  }

  bool _blockIdleDirty() {
    final s = _coreSettings;
    if (s == null) return false;
    final expectedBlock = _minsFromSeconds(s.blockSeconds).toString();
    final expectedIdle = _minsFromSeconds(s.idleCutoffSeconds).toString();
    return _blockMinutes.text.trim() != expectedBlock ||
        _idleCutoffMinutes.text.trim() != expectedIdle;
  }

  bool _reviewDirty() {
    final s = _coreSettings;
    if (s == null) return false;
    final expectedMin = _minsFromSeconds(s.reviewMinSeconds).toString();
    final expectedRepeat = s.reviewNotifyRepeatMinutes.toString();
    return _reviewMinMinutes.text.trim() != expectedMin ||
        _reviewToastRepeatMinutes.text.trim() != expectedRepeat ||
        _reviewNotifyWhenPaused != s.reviewNotifyWhenPaused ||
        _reviewNotifyWhenIdle != s.reviewNotifyWhenIdle;
  }

  void _scheduleReviewSave(
      {Duration delay = const Duration(milliseconds: 700)}) {
    _reviewSaveDebounce?.cancel();
    _reviewSaveDebounce = Timer(delay, () {
      _saveReviewSettings().catchError((_) {});
    });
  }

  Future<void> _saveReviewSettings() async {
    if (_coreSettings == null) return;
    if (_coreSettingsSaving) {
      _scheduleReviewSave(delay: const Duration(milliseconds: 400));
      return;
    }
    if (!_reviewDirty()) return;

    final minM = int.tryParse(_reviewMinMinutes.text.trim());
    final repeatM = int.tryParse(_reviewToastRepeatMinutes.text.trim());
    if (minM == null || minM < 1) return;
    if (repeatM == null || repeatM < 1) return;

    setState(() {
      _coreSettingsSaving = true;
      _reviewSaving = true;
      _coreSettingsError = null;
    });

    try {
      final s = await widget.client.updateSettings(
        reviewMinSeconds: (minM * 60).clamp(60, 4 * 60 * 60),
        reviewNotifyRepeatMinutes: repeatM.clamp(1, 24 * 60),
        reviewNotifyWhenPaused: _reviewNotifyWhenPaused,
        reviewNotifyWhenIdle: _reviewNotifyWhenIdle,
      );
      if (!mounted) return;
      setState(() {
        _coreSettings = s;
        _reviewMinMinutes.text =
            _minsFromSeconds(s.reviewMinSeconds).toString();
        _reviewToastRepeatMinutes.text = s.reviewNotifyRepeatMinutes.toString();
        _reviewNotifyWhenPaused = s.reviewNotifyWhenPaused;
        _reviewNotifyWhenIdle = s.reviewNotifyWhenIdle;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _coreSettingsError = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _coreSettingsSaving = false;
          _reviewSaving = false;
        });
      }
    }
  }

  _PrivacyLevel _privacyLevel() {
    if (!_storeTitles && !_storeExePath) return _PrivacyLevel.l1;
    if (_storeTitles && !_storeExePath) return _PrivacyLevel.l2;
    return _PrivacyLevel.l3;
  }

  String _privacyLevelExplain(_PrivacyLevel level) {
    switch (level) {
      case _PrivacyLevel.l1:
        return "L1: Store only app/domain + duration. Titles and exe paths are dropped.";
      case _PrivacyLevel.l2:
        return "L2: Also store window/tab titles (extension: enable Send tab title; collector: use --send-title). Old data won't be backfilled.";
      case _PrivacyLevel.l3:
        return "L3: Also store full exe path (high sensitivity).";
    }
  }

  Future<void> _choosePrivacyLevel(_PrivacyLevel level) async {
    if (level == _PrivacyLevel.l3) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Enable L3 (high sensitivity)?"),
          content: const Text(
            "This stores full executable paths (and may contain usernames / project folders).\n\nYou can always turn it off later.",
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("Cancel")),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("Enable")),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() {
      _storeTitles = level != _PrivacyLevel.l1;
      _storeExePath = level == _PrivacyLevel.l3;
    });
    await _savePrivacySettings();
  }

  Future<void> _loadRules() async {
    setState(() {
      _rulesLoading = true;
      _rulesError = null;
    });
    try {
      final rules = await widget.client.privacyRules();
      if (!mounted) return;
      setState(() {
        _rules = rules;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rulesError = e.toString();
      });
    } finally {
      if (mounted) setState(() => _rulesLoading = false);
    }
  }

  Future<void> _loadEvents() async {
    setState(() {
      _eventsLoading = true;
      _eventsError = null;
    });
    try {
      final events = await widget.client.events(limit: 50);
      if (!mounted) return;
      setState(() {
        _events = events;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _eventsError = e.toString();
      });
    } finally {
      if (mounted) setState(() => _eventsLoading = false);
    }
  }

  Future<void> _loadNow() async {
    setState(() {
      _nowLoading = true;
      _nowError = null;
    });
    try {
      final snap = await widget.client.now(limit: 400);
      if (!mounted) return;
      setState(() => _now = snap);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _nowError = e.toString();
        _now = null;
      });
    } finally {
      if (mounted) setState(() => _nowLoading = false);
    }
  }

  List<PrivacyRule> _filteredRules() {
    var out = _rules;
    switch (_ruleFilter) {
      case _RuleFilter.all:
        break;
      case _RuleFilter.domains:
        out = out.where((r) => r.kind == "domain").toList();
        break;
      case _RuleFilter.apps:
        out = out.where((r) => r.kind == "app").toList();
        break;
    }

    final q = _ruleQuery.text.trim().toLowerCase();
    if (q.isEmpty) return out;

    return out
        .where(
            (r) => "${r.kind} ${r.value} ${r.action}".toLowerCase().contains(q))
        .toList();
  }

  String _hhmm(String rfc3339) {
    try {
      final t = DateTime.parse(rfc3339).toLocal();
      final hh = t.hour.toString().padLeft(2, "0");
      final mm = t.minute.toString().padLeft(2, "0");
      return "$hh:$mm";
    } catch (_) {
      final parts = rfc3339.split("T");
      if (parts.length < 2) return rfc3339;
      final hhmm = parts[1];
      return hhmm.length >= 5 ? hhmm.substring(0, 5) : rfc3339;
    }
  }

  DateTime? _parseLocalTs(String rfc3339) {
    try {
      return DateTime.parse(rfc3339).toLocal();
    } catch (_) {
      return null;
    }
  }

  String _ageText(DateTime ts) {
    final d = DateTime.now().difference(ts);
    if (d.inSeconds < 60) return "${d.inSeconds}s ago";
    if (d.inMinutes < 60) return "${d.inMinutes}m ago";
    if (d.inHours < 24) return "${d.inHours}h ago";
    return "${d.inDays}d ago";
  }

  EventRecord? _latestEvent({String? event, String? source, String? activity}) {
    for (final e in _events) {
      if (event != null && e.event != event) continue;
      if (source != null && e.source != source) continue;
      if (activity != null && e.activity != activity) continue;
      return e;
    }
    return null;
  }

  Future<void> _editServerUrl() async {
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final controller = TextEditingController(text: widget.serverUrl);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Server URL"),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  hintText: "http://127.0.0.1:17600",
                ),
              ),
              if (isAndroid) ...[
                const SizedBox(height: RecorderTokens.space3),
                Text(
                  "Android tips",
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: RecorderTokens.space1),
                Text(
                  "• Emulator: use http://10.0.2.2:17600\n"
                  "• Physical device: use your desktop LAN IP\n"
                  "• Dev shortcut: run `adb reverse tcp:17600 tcp:17600`, then keep using http://127.0.0.1:17600",
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: RecorderTokens.space2),
                Wrap(
                  spacing: RecorderTokens.space2,
                  runSpacing: RecorderTokens.space2,
                  children: [
                    OutlinedButton(
                      onPressed: () =>
                          controller.text = "http://10.0.2.2:17600",
                      child: const Text("Use 10.0.2.2"),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          controller.text = "http://127.0.0.1:17600",
                      child: const Text("Use 127.0.0.1"),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text("Save"),
          ),
        ],
      ),
    );
    if (saved == null || saved.trim().isEmpty) return;
    await widget.onServerUrlChanged(saved.trim());
  }

  Future<void> _addRule() async {
    final valueController = TextEditingController();
    String kind = "domain";
    String action = "drop";

    final upsert = await showDialog<PrivacyRuleUpsert>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text("Add privacy rule"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: "Kind"),
                items: const [
                  DropdownMenuItem(value: "domain", child: Text("Domain")),
                  DropdownMenuItem(value: "app", child: Text("App")),
                ],
                onChanged: (v) => setLocal(() => kind = v ?? "domain"),
              ),
              const SizedBox(height: RecorderTokens.space3),
              TextField(
                controller: valueController,
                decoration: const InputDecoration(
                  labelText: "Value",
                  hintText: "e.g. youtube.com or C:\\\\Program Files\\\\...",
                ),
              ),
              const SizedBox(height: RecorderTokens.space3),
              DropdownButtonFormField<String>(
                initialValue: action,
                decoration: const InputDecoration(labelText: "Action"),
                items: const [
                  DropdownMenuItem(
                      value: "drop", child: Text("Drop (do not store)")),
                  DropdownMenuItem(
                      value: "mask", child: Text("Mask (store as __hidden__)")),
                ],
                onChanged: (v) => setLocal(() => action = v ?? "drop"),
              ),
              const SizedBox(height: RecorderTokens.space3),
              const Text(
                "Tip: Domain rules match subdomains (e.g. youtube.com matches m.youtube.com).",
                textAlign: TextAlign.left,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Cancel")),
            FilledButton(
              onPressed: () {
                final value = valueController.text.trim();
                if (value.isEmpty) return;
                Navigator.pop(
                  ctx,
                  PrivacyRuleUpsert(kind: kind, value: value, action: action),
                );
              },
              child: const Text("Add"),
            ),
          ],
        ),
      ),
    );
    valueController.dispose();
    if (upsert == null) return;

    try {
      await widget.client.upsertPrivacyRule(upsert);
      await _loadRules();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Rule saved")));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Save failed: $e")));
    }
  }

  Future<void> _deleteRule(PrivacyRule rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete rule?"),
        content: Text("${rule.kind}: ${rule.value}\nAction: ${rule.action}"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Cancel")),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await widget.client.deletePrivacyRule(rule.id);
      await _loadRules();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Rule deleted")));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Delete failed: $e")));
    }
  }

  Future<void> _deleteDayData() async {
    final date = _dateLocal.text.trim();
    if (date.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete this day?"),
        content: Text(
            "This will delete all events and reviews for:\n$date\n\nThis cannot be undone."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Cancel")),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _deleteDayLoading = true);
    try {
      final res = await widget.client.deleteDay(
        date: date,
        tzOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
      );
      if (!mounted) return;
      await _loadEvents();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                "Deleted ${res.eventsDeleted} events, ${res.reviewsDeleted} reviews")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Delete failed: $e")));
    } finally {
      if (mounted) setState(() => _deleteDayLoading = false);
    }
  }

  Future<void> _wipeAllData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Wipe ALL data?"),
        content: const Text(
          "This will delete all events and all block reviews.\n\nPrivacy rules and Core settings will be kept.\n\nThis cannot be undone.",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Cancel")),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Wipe all"),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _wipeAllLoading = true);
    try {
      final res = await widget.client.wipeAllData();
      if (!mounted) return;
      await _loadEvents();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                "Wiped ${res.eventsDeleted} events, ${res.reviewsDeleted} reviews")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Wipe failed: $e")));
    } finally {
      if (mounted) setState(() => _wipeAllLoading = false);
    }
  }

  Future<void> _showTextExport(
      {required String title, required Future<String> Function() load}) async {
    try {
      final text = await load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(child: SelectableText(text)),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Copied to clipboard")));
              },
              child: const Text("Copy"),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Close")),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Export failed: $e")));
    }
  }

  String _settingsPanelLabel(_SettingsPanel panel) {
    switch (panel) {
      case _SettingsPanel.overview:
        return "Overview";
      case _SettingsPanel.diagnostics:
        return "Diagnostics";
      case _SettingsPanel.trackingPrivacy:
        return "Tracking & Privacy";
      case _SettingsPanel.data:
        return "Data";
    }
  }

  IconData _settingsPanelIcon(_SettingsPanel panel) {
    switch (panel) {
      case _SettingsPanel.overview:
        return Icons.dashboard_outlined;
      case _SettingsPanel.diagnostics:
        return Icons.health_and_safety_outlined;
      case _SettingsPanel.trackingPrivacy:
        return Icons.shield_outlined;
      case _SettingsPanel.data:
        return Icons.folder_open_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final healthText = _healthLoading
        ? "Checking…"
        : _healthOk == true
            ? "OK"
            : "Error";

    final healthMeta = _healthOk == true
        ? [
            _healthInfo?.service,
            _healthInfo?.version,
          ].whereType<String>().where((s) => s.trim().isNotEmpty).join(" ")
        : "";

    final healthColor = _healthOk == true
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;

    return ListView(
      controller: _scrollV,
      padding: const EdgeInsets.all(RecorderTokens.space4),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.school_outlined),
            title: const Text("新手引导"),
            subtitle: const Text("用 1 分钟了解 Now、时间轴、复盘和隐私设置。"),
            trailing: FilledButton(
              onPressed: widget.onOpenTutorial,
              child: const Text("开始"),
            ),
            onTap: widget.onOpenTutorial,
          ),
        ),
        const SizedBox(height: RecorderTokens.space3),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(RecorderTokens.space3),
            child: Wrap(
              spacing: RecorderTokens.space2,
              runSpacing: RecorderTokens.space1,
              children: [
                for (final panel in _SettingsPanel.values)
                  ChoiceChip(
                    avatar: Icon(_settingsPanelIcon(panel), size: 16),
                    label: Text(_settingsPanelLabel(panel)),
                    selected: _settingsPanel == panel,
                    onSelected: (_) => setState(() => _settingsPanel = panel),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: RecorderTokens.space6),
        if (_settingsPanel == _SettingsPanel.overview)
          Text("Server", style: Theme.of(context).textTheme.titleMedium),
        if (_settingsPanel == _SettingsPanel.overview)
          const SizedBox(height: RecorderTokens.space3),
        if (_settingsPanel == _SettingsPanel.overview)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(RecorderTokens.space2),
              child: Column(
                children: [
                  ListTile(
                    title: const Text("Server URL"),
                    subtitle: Text(widget.serverUrl),
                    trailing: IconButton(
                      onPressed: _editServerUrl,
                      tooltip: "Edit",
                      icon: const Icon(Icons.edit),
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(RecorderTokens.space2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            healthMeta.isEmpty
                                ? "Health: $healthText"
                                : "Health: $healthText · $healthMeta",
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: healthColor),
                          ),
                        ),
                        if (_healthError != null)
                          IconButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text("Health error"),
                                content: Text(_healthError!),
                                actions: [
                                  FilledButton(
                                      onPressed: () => Navigator.pop(ctx),
                                      child: const Text("Close")),
                                ],
                              ),
                            ),
                            tooltip: "Details",
                            icon: const Icon(Icons.info_outline),
                          ),
                        FilledButton.icon(
                          onPressed: _healthLoading ? null : _checkHealth,
                          icon: const Icon(Icons.refresh),
                          label: const Text("Test /health"),
                        ),
                      ],
                    ),
                  ),
                  if (DesktopAgent.instance.isAvailable) ...[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(RecorderTokens.space2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.memory,
                            size: 18,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: RecorderTokens.space2),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "Desktop agent (Windows)",
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _agentRepoRoot == null
                                      ? "Repo root not detected. This is OK in packaged mode.\nIf you're running from source, run UI from the repo or set env RECORDERPHONE_REPO_ROOT."
                                      : "Repo: $_agentRepoRoot",
                                  style:
                                      Theme.of(context).textTheme.labelMedium,
                                ),
                                const SizedBox(height: RecorderTokens.space2),
                                Wrap(
                                  spacing: RecorderTokens.space2,
                                  runSpacing: RecorderTokens.space2,
                                  children: [
                                    Builder(
                                      builder: (context) {
                                        final service = _healthInfo?.service;
                                        final coreLooksHealthy =
                                            _healthOk == true &&
                                                service == "recorder_core";
                                        final alreadyRunning =
                                            _isLocalServerUrl() &&
                                                coreLooksHealthy;
                                        final startEnabled = !_agentBusy &&
                                            _isLocalServerUrl() &&
                                            !alreadyRunning;
                                        return FilledButton.icon(
                                          onPressed: startEnabled
                                              ? () =>
                                                  _startAgent(restart: false)
                                              : null,
                                          icon: Icon(alreadyRunning
                                              ? Icons.check_circle_outline
                                              : Icons.play_arrow),
                                          label: Text(
                                            _agentBusy
                                                ? "Starting…"
                                                : alreadyRunning
                                                    ? "Running"
                                                    : "Start",
                                          ),
                                        );
                                      },
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: _agentBusy
                                          ? null
                                          : () => _startAgent(restart: true),
                                      icon: const Icon(Icons.restart_alt),
                                      label: const Text("Restart"),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: _agentBusy ? null : _stopAgent,
                                      icon: const Icon(Icons.stop),
                                      label: const Text("Stop"),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: RecorderTokens.space2),
                                Text(
                                  _isLocalServerUrl()
                                      ? "Starts local Core + windows_collector so you don't need to run WSL Core."
                                      : "Set Server URL to http://127.0.0.1:17600 to use the local agent.",
                                  style:
                                      Theme.of(context).textTheme.labelMedium,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "Tip: enable Privacy L2 (Store titles) to see YouTube video titles / VS Code workspace names.",
                                  style:
                                      Theme.of(context).textTheme.labelMedium,
                                ),
                                const SizedBox(height: RecorderTokens.space2),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.folder_open_outlined,
                                      size: 16,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                    const SizedBox(
                                        width: RecorderTokens.space1),
                                    Expanded(
                                      child: Text(
                                        "Installer path: %LOCALAPPDATA%\\Programs\\RecorderPhone\nDatabase: %LOCALAPPDATA%\\RecorderPhone\\recorder-core.db",
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium,
                                      ),
                                    ),
                                  ],
                                ),
                                if (StartupController.instance.isAvailable) ...[
                                  const SizedBox(height: RecorderTokens.space2),
                                  const Divider(height: 16),
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                      Icons.power_settings_new,
                                      size: 18,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                    title: const Text("Start with Windows"),
                                    subtitle: Text(
                                      _startupError != null
                                          ? "Error: $_startupError"
                                          : _startupEnabled == null
                                              ? "Checking…"
                                              : "Launches RecorderPhone on login (minimized to tray).",
                                    ),
                                    trailing: _startupBusy
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : Switch(
                                            value: _startupEnabled == true,
                                            onChanged: _startupEnabled == null
                                                ? null
                                                : (v) {
                                                    _setStartupEnabled(v)
                                                        .catchError((e) {
                                                      final msg = e.toString();
                                                      ScaffoldMessenger.of(
                                                              context)
                                                          .showSnackBar(
                                                        SnackBar(
                                                            content: Text(
                                                                "Startup update failed: $msg")),
                                                      );
                                                    });
                                                  },
                                          ),
                                  ),
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(left: 2, top: 2),
                                    child: Text(
                                      "Close window → keeps running in tray. Use tray menu → Exit to quit.",
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (_settingsPanel == _SettingsPanel.overview) ...[
          const SizedBox(height: RecorderTokens.space6),
        ],
        if (_settingsPanel == _SettingsPanel.overview &&
            UpdateManager.instance.isAvailable) ...[
          Text("Updates", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: RecorderTokens.space3),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(RecorderTokens.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Builder(
                    builder: (context) {
                      final b = _buildInfo;
                      final tag = (b?.gitTag ?? "").trim();
                      final desc = (b?.gitDescribe ?? "").trim();
                      final sha = _shortSha(b?.git);
                      final cur = tag.isNotEmpty
                          ? tag
                          : (desc.isNotEmpty
                              ? desc
                              : (sha.isNotEmpty ? sha : "unknown"));

                      final coreV = (b?.coreVersion ?? "").trim();
                      final colV = (b?.collectorVersion ?? "").trim();
                      final meta = [
                        if (sha.isNotEmpty) "git:$sha",
                        if (coreV.isNotEmpty) "core:$coreV",
                        if (colV.isNotEmpty) "collector:$colV",
                      ].join(" · ");

                      return Text(
                        meta.isEmpty ? "Current: $cur" : "Current: $cur\n$meta",
                        style: Theme.of(context).textTheme.bodyMedium,
                      );
                    },
                  ),
                  const SizedBox(height: RecorderTokens.space3),
                  TextField(
                    controller: _updateRepo,
                    enabled: !_updatesInstalling,
                    decoration: const InputDecoration(
                      labelText: "GitHub repo (owner/name)",
                      helperText:
                          "Used for update checks via GitHub Releases (public repos work without tokens).",
                    ),
                    onChanged: (_) => _scheduleSaveUpdateRepo(),
                    onSubmitted: (_) => _saveUpdateRepo(_updateRepo.text),
                  ),
                  const SizedBox(height: RecorderTokens.space2),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _updateAutoCheck,
                    onChanged: _updatesInstalling
                        ? null
                        : (v) async {
                            await _setUpdateAutoCheck(v);
                            if (v) {
                              unawaited(_checkUpdates(force: false));
                            }
                          },
                    title: const Text("Auto-check updates"),
                    subtitle: const Text("Checks at most every 6 hours."),
                  ),
                  const SizedBox(height: RecorderTokens.space2),
                  Row(
                    children: [
                      if (_updatesLoading || _updatesInstalling)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(
                          _updateAvailable
                              ? Icons.system_update_alt
                              : Icons.check_circle_outline,
                          size: 18,
                          color: _updateAvailable
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      const SizedBox(width: RecorderTokens.space2),
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            final latest = _latestRelease;
                            final latestTag = latest?.tag ?? "";
                            final last = _formatLocalTime(_updateLastCheckedAt);
                            final status = _updateAvailable
                                ? (latestTag.isEmpty
                                    ? "Update available"
                                    : "Update available: $latestTag")
                                : (latestTag.isEmpty
                                    ? "No update info yet"
                                    : "Latest: $latestTag");
                            return Text(
                              last.isEmpty ? status : "$status · checked $last",
                              style: Theme.of(context).textTheme.labelMedium,
                            );
                          },
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: (_updatesLoading || _updatesInstalling)
                            ? null
                            : () => _checkUpdates(force: true),
                        icon: const Icon(Icons.refresh),
                        label: const Text("Check"),
                      ),
                    ],
                  ),
                  if (_updateAvailable) ...[
                    const SizedBox(height: RecorderTokens.space2),
                    FilledButton.icon(
                      onPressed: _updatesInstalling ? null : _installUpdate,
                      icon: const Icon(Icons.system_update_alt),
                      label: Text(_updatesInstalling
                          ? "Updating…"
                          : "Update & restart"),
                    ),
                  ],
                  if (_updatesError != null) ...[
                    const SizedBox(height: RecorderTokens.space2),
                    Text(
                      _updatesError!,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: RecorderTokens.space6),
        ],
        if (_settingsPanel == _SettingsPanel.diagnostics)
          Row(
            children: [
              Expanded(
                  child: Text("Diagnostics",
                      style: Theme.of(context).textTheme.titleMedium)),
              OutlinedButton.icon(
                onPressed: _refreshAll,
                icon: const Icon(Icons.refresh),
                label: const Text("Refresh"),
              ),
            ],
          ),
        if (_settingsPanel == _SettingsPanel.diagnostics)
          const SizedBox(height: RecorderTokens.space3),
        if (_settingsPanel == _SettingsPanel.diagnostics)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(RecorderTokens.space2),
              child: Builder(
                builder: (context) {
                  if (_nowLoading && _now == null) {
                    return const Padding(
                      padding: EdgeInsets.all(RecorderTokens.space4),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  final snap = _now;
                  final usingFallbackEvents = snap == null;

                  EventRecord? lastTabFocus;
                  EventRecord? lastTabAudio;
                  EventRecord? lastTabAudioStop;
                  EventRecord? lastApp;
                  EventRecord? lastAppAudio;
                  EventRecord? lastAppAudioStop;
                  EventRecord? lastAny;

                  if (snap != null) {
                    lastTabFocus = snap.tabFocus;
                    lastTabAudio = snap.tabAudio;
                    lastTabAudioStop = snap.tabAudioStop;
                    lastApp = snap.appActive;
                    lastAppAudio = snap.appAudio;
                    lastAppAudioStop = snap.appAudioStop;
                    lastAny = snap.latestEvent;
                  } else {
                    if (_eventsLoading && _events.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(RecorderTokens.space4),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }

                    for (final e in _events) {
                      if (e.source == "browser_extension" &&
                          e.event == "tab_active" &&
                          e.activity != "audio") {
                        lastTabFocus = e;
                        break;
                      }
                    }
                    lastTabAudio = _latestEvent(
                        event: "tab_active",
                        source: "browser_extension",
                        activity: "audio");
                    lastTabAudioStop = _latestEvent(
                        event: "tab_audio_stop", source: "browser_extension");
                    lastApp = _latestEvent(
                        event: "app_active", source: "windows_collector");
                    lastAppAudio = _latestEvent(
                        event: "app_audio", source: "windows_collector");
                    lastAppAudioStop = _latestEvent(
                        event: "app_audio_stop", source: "windows_collector");
                    lastAny = _events.isEmpty ? null : _events.first;
                  }

                  bool isBrowserLabel(String label) {
                    final v = label.trim().toLowerCase();
                    return v == "chrome" ||
                        v == "msedge" ||
                        v == "edge" ||
                        v == "brave" ||
                        v == "vivaldi" ||
                        v == "opera" ||
                        v == "firefox";
                  }

                  final focusTtlSeconds = snap?.focusTtlSeconds ?? (3 * 60);
                  final focusTtl =
                      Duration(seconds: focusTtlSeconds.clamp(30, 3600));
                  final focusFreshMinutes =
                      (focusTtl.inSeconds / 60).ceil().clamp(1, 120);

                  final lastAppTs =
                      lastApp == null ? null : _parseLocalTs(lastApp.ts);
                  final lastAppAge = lastAppTs == null
                      ? null
                      : DateTime.now().difference(lastAppTs);
                  final lastAppLabel = displayEntity(lastApp?.entity);
                  final appLooksLikeBrowser =
                      lastApp != null && isBrowserLabel(lastAppLabel);
                  final appIsFresh =
                      lastAppAge != null && lastAppAge <= focusTtl;
                  final browserLooksActive = appLooksLikeBrowser && appIsFresh;

                  final lastTabTs = lastTabFocus == null
                      ? null
                      : _parseLocalTs(lastTabFocus.ts);
                  final lastTabAge = lastTabTs == null
                      ? null
                      : DateTime.now().difference(lastTabTs);
                  final tabLooksStale = lastTabAge == null ||
                      lastTabAge > (focusTtl + const Duration(seconds: 60));

                  bool hasAnyTabEvent =
                      lastTabFocus != null || lastTabAudio != null;
                  String anyTabTitle() {
                    final t1 = (lastTabFocus?.title ?? "").trim();
                    if (t1.isNotEmpty) return t1;
                    final t2 = (lastTabAudio?.title ?? "").trim();
                    if (t2.isNotEmpty) return t2;
                    return "";
                  }

                  final tabHasTitle = anyTabTitle().isNotEmpty;
                  final appHasTitle =
                      ((lastApp?.title ?? "").trim()).isNotEmpty;
                  final appTitleUseful = lastApp != null &&
                      !appLooksLikeBrowser; // browser window titles are noisy

                  Widget titleGuide() {
                    final scheme = Theme.of(context).colorScheme;

                    String title;
                    String subtitle;
                    IconData icon;
                    List<Widget> actions = [];

                    if (!_storeTitles) {
                      title = "Titles: OFF (L1)";
                      subtitle =
                          "To split sites like YouTube by video title and to show VS Code workspace/window titles, enable L2.\nOld data won't be backfilled.";
                      icon = Icons.lock_outline;
                      actions = [
                        FilledButton(
                          onPressed: _coreSettingsSaving
                              ? null
                              : () async {
                                  setState(() {
                                    _storeTitles = true;
                                    _storeExePath = false;
                                  });
                                  await _savePrivacySettings();
                                },
                          child: const Text("Enable L2"),
                        ),
                      ];
                    } else {
                      title = "Titles: ON (L2)";
                      icon = Icons.check_circle_outline;

                      final tips = <String>[];
                      if (hasAnyTabEvent && !tabHasTitle) {
                        tips.add(
                            "Browser: enable “Send tab title” in the extension popup, then click “Force send”.");
                      }
                      if (!hasAnyTabEvent) {
                        tips.add(
                            "Browser: no tab events yet. Switch a tab or click “Force send” in the extension popup.");
                      }
                      if (appTitleUseful && !appHasTitle) {
                        tips.add(
                            "Windows: start windows_collector with --send-title to capture window titles/workspaces.");
                      }

                      subtitle = tips.isEmpty
                          ? "Looks good. You should see per-tab titles (when available) and better app context (e.g. VS Code workspace)."
                          : tips.join("\n");

                      actions = [
                        OutlinedButton.icon(
                          onPressed: _deleteDayLoading
                              ? null
                              : () async {
                                  setState(() {
                                    _dateLocal.text = _todayLocal();
                                  });
                                  await _deleteDayData();
                                },
                          icon: const Icon(Icons.delete_outline),
                          label: const Text("Reset today"),
                        ),
                      ];
                    }

                    return Padding(
                      padding: const EdgeInsets.all(RecorderTokens.space2),
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius:
                              BorderRadius.circular(RecorderTokens.radiusM),
                          border: Border.all(
                              color: scheme.outline.withValues(alpha: 0.10)),
                        ),
                        padding: const EdgeInsets.all(RecorderTokens.space3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(icon,
                                size: 18, color: scheme.onSurfaceVariant),
                            const SizedBox(width: RecorderTokens.space2),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(title,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge),
                                  const SizedBox(height: 4),
                                  Text(subtitle,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium),
                                ],
                              ),
                            ),
                            if (actions.isNotEmpty) ...[
                              const SizedBox(width: RecorderTokens.space2),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: actions,
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  }

                  Widget tile({
                    required String title,
                    required EventRecord? e,
                    required String emptyHint,
                    String? staleHint,
                    String? missingTitleHint,
                    int freshnessMinutes = 3,
                  }) {
                    if (e == null) {
                      return ListTile(
                        minVerticalPadding: RecorderTokens.space2,
                        leading: const Icon(Icons.help_outline),
                        title: Text(title),
                        subtitle: Text(emptyHint),
                      );
                    }

                    final ts = _parseLocalTs(e.ts);
                    final age =
                        ts == null ? null : DateTime.now().difference(ts);
                    final entity = (e.entity ?? "").trim().isEmpty
                        ? "(no entity)"
                        : e.entity!.trim();
                    final fresh =
                        age != null && age.inMinutes < freshnessMinutes;

                    final act = (e.activity ?? "").trim();
                    final tag = act.isEmpty ? e.event : "${e.event}/$act";
                    final baseSubtitle = ts == null
                        ? "${e.source} · $tag"
                        : "${_ageText(ts)} · ${_hhmm(e.ts)} · $tag · $entity";
                    final titleText = (e.title ?? "").trim();
                    final secondLine = titleText.isNotEmpty
                        ? titleText
                        : (missingTitleHint != null &&
                                missingTitleHint.trim().isNotEmpty)
                            ? missingTitleHint
                            : (!fresh && staleHint != null ? staleHint : null);
                    final subtitle = secondLine == null
                        ? baseSubtitle
                        : "$baseSubtitle\n$secondLine";
                    final scheme = Theme.of(context).colorScheme;

                    return ListTile(
                      minVerticalPadding: RecorderTokens.space2,
                      leading: Icon(
                        fresh ? Icons.check_circle_outline : Icons.info_outline,
                        color: fresh ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                      title: Text(title),
                      subtitle: Text(subtitle,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    );
                  }

                  return Column(
                    children: [
                      titleGuide(),
                      if (snap != null && snap.latestEventAgeSeconds != null)
                        Padding(
                          padding: const EdgeInsets.all(RecorderTokens.space2),
                          child: Row(
                            children: [
                              Icon(Icons.schedule,
                                  size: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                              const SizedBox(width: RecorderTokens.space1),
                              Expanded(
                                child: Text(
                                  "Latest event: ${snap.latestEventAgeSeconds}s ago · focus TTL ${focusTtl.inMinutes}m · audio TTL ${snap.audioTtlSeconds}s",
                                  style:
                                      Theme.of(context).textTheme.labelMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_nowError != null && snap == null)
                        Padding(
                          padding: const EdgeInsets.all(RecorderTokens.space2),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline,
                                  size: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                              const SizedBox(width: RecorderTokens.space1),
                              Expanded(
                                child: Text(
                                  (_nowError ?? "").contains("http_404")
                                      ? "Tip: this Core does not implement /now. Restart recorder_core and refresh."
                                      : "Now endpoint error: $_nowError${usingFallbackEvents ? ' (fallback to /events)' : ''}",
                                  style:
                                      Theme.of(context).textTheme.labelMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (browserLooksActive &&
                          (lastTabFocus == null || tabLooksStale))
                        Padding(
                          padding: const EdgeInsets.all(RecorderTokens.space2),
                          child: Row(
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  size: 16,
                                  color:
                                      Theme.of(context).colorScheme.tertiary),
                              const SizedBox(width: RecorderTokens.space1),
                              const Expanded(
                                child: Text(
                                  "Browser looks active, but tab tracking is stale.\nOpen the extension popup → check Enable tracking + Server URL, then click “Force send”. If it keeps happening, enable “Keep alive (stability)” and click “Repair”.",
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      tile(
                        title: "Browser tab (focus)",
                        e: lastTabFocus,
                        emptyHint:
                            "No tab_active yet. Open the extension popup and ensure Enable tracking is ON.",
                        missingTitleHint: _storeTitles
                            ? "No title field. Enable “Send tab title” in the extension, then click “Force send”."
                            : "Titles are OFF (L1). Turn on “Store window/tab titles (L2)” below to see tab titles.",
                        staleHint: browserLooksActive
                            ? "If you’re using the browser right now, this should be fresh. Open the extension popup → Force send."
                            : "This can be normal if you're not using the browser. Switch a tab to trigger a fresh event.",
                        freshnessMinutes: focusFreshMinutes,
                      ),
                      const Divider(height: 1),
                      tile(
                        title: "Browser tab (background audio)",
                        e: lastTabAudio ?? lastTabAudioStop,
                        emptyHint:
                            "No background-audio tab yet. Enable “Track background audio” in the extension, then play audio with the browser in background.",
                        missingTitleHint: _storeTitles
                            ? "No title field. Enable “Send tab title” in the extension, then click “Force send”."
                            : "Titles are OFF (L1). Turn on “Store window/tab titles (L2)” below to see tab titles.",
                        staleHint:
                            "This only reports when the browser is not focused but an audible tab is playing.",
                        freshnessMinutes: 2,
                      ),
                      const Divider(height: 1),
                      tile(
                        title: "Windows app events",
                        e: lastApp,
                        emptyHint:
                            "No app_active yet. Start windows_collector.exe and switch apps a few times.",
                        missingTitleHint: _storeTitles
                            ? "No title field. Start windows_collector with --send-title."
                            : "Titles are OFF (L1). Turn on “Store window/tab titles (L2)” below to see window titles/workspaces.",
                        staleHint:
                            "If windows_collector isn't running, this will go stale. Restart it to resume events.",
                        freshnessMinutes: focusFreshMinutes,
                      ),
                      const Divider(height: 1),
                      tile(
                        title: "Windows background audio (app)",
                        e: lastAppAudio ?? lastAppAudioStop,
                        emptyHint:
                            "No app_audio yet. Start windows_collector.exe (default track-audio ON) and play music in a desktop app (e.g. QQ Music).",
                        staleHint:
                            "This only reports when a non-browser app is producing audio. If you're only using browser audio, check the extension's background-audio tile instead.",
                        freshnessMinutes: 2,
                      ),
                      const Divider(height: 1),
                      tile(
                        title: "Latest event (any)",
                        e: lastAny,
                        emptyHint:
                            "No events yet. Install the extension / run collectors, then switch apps or tabs.",
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          const SizedBox(height: RecorderTokens.space6),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          Text("Core settings", style: Theme.of(context).textTheme.titleMedium),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          const SizedBox(height: RecorderTokens.space3),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(RecorderTokens.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_coreSettingsLoading && _coreSettings == null)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    TextField(
                      controller: _blockMinutes,
                      decoration: const InputDecoration(
                        labelText: "Block length (minutes)",
                        helperText:
                            "Controls block segmentation and review cadence (including history).",
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                    const SizedBox(height: RecorderTokens.space3),
                    TextField(
                      controller: _idleCutoffMinutes,
                      decoration: const InputDecoration(
                        labelText: "Idle cutoff (minutes)",
                        helperText: "Long gaps beyond this end a block early.",
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                    Builder(
                      builder: (context) {
                        final dirty = _blockIdleDirty();
                        if (!dirty && !_coreNumbersSaving)
                          return const SizedBox.shrink();
                        return Padding(
                          padding:
                              const EdgeInsets.only(top: RecorderTokens.space3),
                          child: FilledButton.icon(
                            onPressed: (_coreNumbersSaving || !dirty)
                                ? null
                                : _saveCoreSettings,
                            icon: const Icon(Icons.save_outlined),
                            label: _coreNumbersSaving
                                ? const Text("Saving…")
                                : const Text("Save block/idle"),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: RecorderTokens.space3),
                    const Divider(),
                    const SizedBox(height: RecorderTokens.space2),
                    Text("Review reminders",
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: RecorderTokens.space2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline,
                            size: 16,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(width: RecorderTokens.space1),
                        Expanded(
                          child: Text(
                            "“Time to review” triggers when Core finds the most recent due block: long enough (min duration), not reviewed/skipped, and either you already moved on to a new block or the current block reached Block length. To reduce prompts: increase Block length / min duration / repeat.",
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: RecorderTokens.space2),
                    TextField(
                      controller: _reviewMinMinutes,
                      enabled: !_coreSettingsSaving,
                      decoration: const InputDecoration(
                        labelText:
                            "Min block duration to require review (minutes)",
                        helperText:
                            "Only blocks longer than this can become due (default 5m).",
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => _scheduleReviewSave(),
                    ),
                    const SizedBox(height: RecorderTokens.space3),
                    TextField(
                      controller: _reviewToastRepeatMinutes,
                      enabled: !_coreSettingsSaving,
                      decoration: const InputDecoration(
                        labelText: "Repeat interval (minutes)",
                        helperText:
                            "Minimum minutes between reminders for the same due block (toast + in-app prompt). Default 10m.",
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => _scheduleReviewSave(),
                    ),
                    const SizedBox(height: RecorderTokens.space2),
                    SwitchListTile.adaptive(
                      value: _reviewNotifyWhenPaused,
                      onChanged: _coreSettingsSaving
                          ? null
                          : (v) {
                              setState(() => _reviewNotifyWhenPaused = v);
                              _scheduleReviewSave(
                                  delay: const Duration(milliseconds: 200));
                            },
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Notify even when tracking is paused"),
                      subtitle: const Text(
                          "Applies to Windows toast + in-app prompt."),
                    ),
                    SwitchListTile.adaptive(
                      value: _reviewNotifyWhenIdle,
                      onChanged: _coreSettingsSaving
                          ? null
                          : (v) {
                              setState(() => _reviewNotifyWhenIdle = v);
                              _scheduleReviewSave(
                                  delay: const Duration(milliseconds: 200));
                            },
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Notify even when PC is idle"),
                      subtitle:
                          const Text("Applies to Windows toast (collector)."),
                    ),
                    Padding(
                      padding:
                          const EdgeInsets.only(top: RecorderTokens.space1),
                      child: Text(
                        _reviewSaving
                            ? "Saving review reminders…"
                            : "Review reminder changes are saved automatically.",
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    const SizedBox(height: RecorderTokens.space1),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline,
                            size: 16,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(width: RecorderTokens.space1),
                        Expanded(
                          child: Text(
                            "Windows toast settings take effect after restarting the desktop agent / collector.",
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: RecorderTokens.space3),
                    const Divider(),
                    const SizedBox(height: RecorderTokens.space2),
                    Text("Privacy (Core)",
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: RecorderTokens.space2),
                    Container(
                      key: widget.tutorialPrivacyKey,
                      child: SegmentedButton<_PrivacyLevel>(
                        segments: const [
                          ButtonSegment(
                              value: _PrivacyLevel.l1, label: Text("L1")),
                          ButtonSegment(
                              value: _PrivacyLevel.l2, label: Text("L2")),
                          ButtonSegment(
                              value: _PrivacyLevel.l3, label: Text("L3")),
                        ],
                        selected: {_privacyLevel()},
                        onSelectionChanged: _coreSettingsSaving
                            ? null
                            : (v) {
                                final next =
                                    v.isEmpty ? _privacyLevel() : v.first;
                                _choosePrivacyLevel(next);
                              },
                      ),
                    ),
                    const SizedBox(height: RecorderTokens.space2),
                    Text(
                      _privacyLevelExplain(_privacyLevel()),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: RecorderTokens.space2),
                    SwitchListTile.adaptive(
                      value: _storeTitles,
                      onChanged: _coreSettingsSaving
                          ? null
                          : (v) {
                              setState(() {
                                _storeTitles = v;
                                if (!v) _storeExePath = false;
                              });
                              unawaited(_savePrivacySettings());
                            },
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Store window/tab titles (L2)"),
                      subtitle: const Text(
                        "If off, Core drops any title fields even if collectors/extensions send them.",
                      ),
                    ),
                    SwitchListTile.adaptive(
                      value: _storeExePath,
                      onChanged: _coreSettingsSaving
                          ? null
                          : (v) async {
                              if (v && !_storeExePath) {
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text(
                                        "Enable L3 (high sensitivity)?"),
                                    content: const Text(
                                      "This stores full executable paths (and may contain usernames / project folders).\n\nYou can always turn it off later.",
                                    ),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text("Cancel")),
                                      FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text("Enable")),
                                    ],
                                  ),
                                );
                                if (ok != true) return;
                              }

                              setState(() {
                                _storeExePath = v;
                                if (v) _storeTitles = true;
                              });
                              await _savePrivacySettings();
                            },
                      contentPadding: EdgeInsets.zero,
                      title:
                          const Text("Store full exe path (high sensitivity)"),
                      subtitle:
                          const Text("If off, Core drops exePath/pid fields."),
                    ),
                    Padding(
                      padding:
                          const EdgeInsets.only(top: RecorderTokens.space1),
                      child: Text(
                        _privacySaving
                            ? "Saving privacy…"
                            : "Privacy changes are saved automatically.",
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    if (_privacyLevel() != _PrivacyLevel.l1) ...[
                      const SizedBox(height: RecorderTokens.space1),
                      Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 16,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                          const SizedBox(width: RecorderTokens.space1),
                          Expanded(
                            child: Text(
                              "To see titles in UI: enable “Send tab title” in the extension, and run windows_collector with --send-title.",
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_coreSettingsError != null) ...[
                      const SizedBox(height: RecorderTokens.space3),
                      Text("Load/save error: $_coreSettingsError"),
                      if ((_coreSettingsError ?? "").contains("http_404")) ...[
                        const SizedBox(height: RecorderTokens.space1),
                        Text(
                          "Tip: 404 means this server does not implement /settings (dev ingest server or an older recorder_core). Restart recorder_core and re-check /settings.",
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ],
                  ],
                ],
              ),
            ),
          ),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          const SizedBox(height: RecorderTokens.space6),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          Row(
            children: [
              Expanded(
                  child: Text("Privacy rules",
                      style: Theme.of(context).textTheme.titleMedium)),
              FilledButton.icon(
                  onPressed: _addRule,
                  icon: const Icon(Icons.add),
                  label: const Text("Add")),
            ],
          ),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          const SizedBox(height: RecorderTokens.space2),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          TextField(
            controller: _ruleQuery,
            decoration: InputDecoration(
              hintText: "Search rules…",
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _ruleQuery.text.trim().isEmpty
                  ? null
                  : IconButton(
                      tooltip: "Clear",
                      onPressed: () => setState(() => _ruleQuery.text = ""),
                      icon: const Icon(Icons.clear),
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          const SizedBox(height: RecorderTokens.space2),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          Wrap(
            spacing: RecorderTokens.space2,
            runSpacing: RecorderTokens.space2,
            children: [
              ChoiceChip(
                label: const Text("All"),
                selected: _ruleFilter == _RuleFilter.all,
                onSelected: (_) =>
                    setState(() => _ruleFilter = _RuleFilter.all),
              ),
              ChoiceChip(
                label: const Text("Domains"),
                selected: _ruleFilter == _RuleFilter.domains,
                onSelected: (_) =>
                    setState(() => _ruleFilter = _RuleFilter.domains),
              ),
              ChoiceChip(
                label: const Text("Apps"),
                selected: _ruleFilter == _RuleFilter.apps,
                onSelected: (_) =>
                    setState(() => _ruleFilter = _RuleFilter.apps),
              ),
            ],
          ),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          const SizedBox(height: RecorderTokens.space3),
        if (_settingsPanel == _SettingsPanel.trackingPrivacy)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(RecorderTokens.space2),
              child: Column(
                children: [
                  if (_rulesLoading)
                    const Padding(
                      padding: EdgeInsets.all(RecorderTokens.space4),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_rulesError != null)
                    Padding(
                      padding: const EdgeInsets.all(RecorderTokens.space4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Load failed: $_rulesError"),
                          const SizedBox(height: RecorderTokens.space3),
                          FilledButton.icon(
                            onPressed: _loadRules,
                            icon: const Icon(Icons.refresh),
                            label: const Text("Retry"),
                          ),
                        ],
                      ),
                    )
                  else if (_rules.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(RecorderTokens.space4),
                      child: Text(
                          "No rules yet. Add a domain/app to drop or mask."),
                    )
                  else
                    ...(() {
                      final filtered = _filteredRules();
                      if (filtered.isEmpty) {
                        return [
                          const Padding(
                            padding: EdgeInsets.all(RecorderTokens.space4),
                            child: Text("No matching rules."),
                          ),
                        ];
                      }

                      IconData icon(PrivacyRule r) {
                        if (r.action == "mask")
                          return Icons.visibility_off_outlined;
                        return Icons.block;
                      }

                      String kindLabel(PrivacyRule r) {
                        return r.kind == "domain" ? "Domain" : "App";
                      }

                      String actionLabel(PrivacyRule r) {
                        return r.action == "mask" ? "Mask" : "Drop";
                      }

                      return [
                        Padding(
                          padding: const EdgeInsets.only(
                            left: RecorderTokens.space3,
                            right: RecorderTokens.space3,
                            top: RecorderTokens.space2,
                            bottom: RecorderTokens.space1,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              "${filtered.length} / ${_rules.length}",
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                        ),
                        ...filtered.map(
                          (r) => ListTile(
                            minVerticalPadding: RecorderTokens.space2,
                            leading: Icon(icon(r), size: 18),
                            title: Text(r.value,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle:
                                Text("${kindLabel(r)} · ${actionLabel(r)}"),
                            trailing: IconButton(
                              onPressed: () => _deleteRule(r),
                              tooltip: "Delete",
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ),
                        ),
                      ];
                    })(),
                ],
              ),
            ),
          ),
        if (_settingsPanel == _SettingsPanel.diagnostics)
          const SizedBox(height: RecorderTokens.space6),
        if (_settingsPanel == _SettingsPanel.diagnostics)
          Row(
            children: [
              Expanded(
                  child: Text("Recent events",
                      style: Theme.of(context).textTheme.titleMedium)),
              OutlinedButton.icon(
                onPressed: _eventsLoading ? null : _loadEvents,
                icon: const Icon(Icons.refresh),
                label: const Text("Refresh"),
              ),
            ],
          ),
        if (_settingsPanel == _SettingsPanel.diagnostics)
          const SizedBox(height: RecorderTokens.space3),
        if (_settingsPanel == _SettingsPanel.diagnostics)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(RecorderTokens.space2),
              child: Column(
                children: [
                  if (_eventsLoading)
                    const Padding(
                      padding: EdgeInsets.all(RecorderTokens.space4),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_eventsError != null)
                    Padding(
                      padding: const EdgeInsets.all(RecorderTokens.space4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Load failed: $_eventsError"),
                          const SizedBox(height: RecorderTokens.space3),
                          FilledButton.icon(
                            onPressed: _loadEvents,
                            icon: const Icon(Icons.refresh),
                            label: const Text("Retry"),
                          ),
                        ],
                      ),
                    )
                  else if (_events.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(RecorderTokens.space4),
                      child: Text(
                          "No events yet. Install the extension / run collectors, then switch apps or tabs."),
                    )
                  else
                    ..._events.take(20).map((e) {
                      final entity = e.entity ?? "(no entity)";
                      final meta = "${_hhmm(e.ts)} · ${e.source} · ${e.event}";
                      final t = (e.title ?? "").trim();
                      final subtitle = t.isEmpty ? meta : "$meta\n$t";
                      return ListTile(
                        minVerticalPadding: RecorderTokens.space2,
                        title: Text(entity,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(subtitle,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: IconButton(
                          onPressed: e.entity == null
                              ? null
                              : () async {
                                  await Clipboard.setData(
                                      ClipboardData(text: e.entity!));
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content:
                                            Text("Copied entity to clipboard")),
                                  );
                                },
                          tooltip: "Copy",
                          icon: const Icon(Icons.content_copy),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        if (_settingsPanel == _SettingsPanel.data)
          const SizedBox(height: RecorderTokens.space6),
        if (_settingsPanel == _SettingsPanel.data)
          Text("Export", style: Theme.of(context).textTheme.titleMedium),
        if (_settingsPanel == _SettingsPanel.data)
          const SizedBox(height: RecorderTokens.space3),
        if (_settingsPanel == _SettingsPanel.data)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(RecorderTokens.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _dateLocal,
                    decoration: const InputDecoration(
                      labelText: "Date (Local)",
                      hintText: "YYYY-MM-DD",
                    ),
                  ),
                  const SizedBox(height: RecorderTokens.space4),
                  Wrap(
                    spacing: RecorderTokens.space3,
                    runSpacing: RecorderTokens.space2,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _showTextExport(
                          title: "Markdown export",
                          load: () => widget.client.exportMarkdown(
                            date: _dateLocal.text.trim(),
                            tzOffsetMinutes:
                                DateTime.now().timeZoneOffset.inMinutes,
                          ),
                        ),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text("Markdown"),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _showTextExport(
                          title: "CSV export",
                          load: () => widget.client.exportCsv(
                            date: _dateLocal.text.trim(),
                            tzOffsetMinutes:
                                DateTime.now().timeZoneOffset.inMinutes,
                          ),
                        ),
                        icon: const Icon(Icons.table_chart_outlined),
                        label: const Text("CSV"),
                      ),
                    ],
                  ),
                  const SizedBox(height: RecorderTokens.space4),
                  const Divider(),
                  const SizedBox(height: RecorderTokens.space2),
                  Text("Danger zone",
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: RecorderTokens.space2),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          Theme.of(context).colorScheme.errorContainer,
                      foregroundColor:
                          Theme.of(context).colorScheme.onErrorContainer,
                    ),
                    onPressed: _wipeAllLoading || _deleteDayLoading
                        ? null
                        : _wipeAllData,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: _wipeAllLoading
                        ? const Text("Wiping…")
                        : const Text("Wipe ALL data"),
                  ),
                  const SizedBox(height: RecorderTokens.space2),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          Theme.of(context).colorScheme.errorContainer,
                      foregroundColor:
                          Theme.of(context).colorScheme.onErrorContainer,
                    ),
                    onPressed: _deleteDayLoading ? null : _deleteDayData,
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: _deleteDayLoading
                        ? const Text("Deleting…")
                        : const Text("Delete this day"),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
