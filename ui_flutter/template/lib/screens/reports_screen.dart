import "dart:async";
import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_markdown/flutter_markdown.dart";
import "package:flutter/services.dart";
import "package:markdown/markdown.dart" as md;

import "../api/core_client.dart";
import "../theme/tokens.dart";
import "../utils/desktop_agent.dart";
import "../widgets/recorder_tooltip.dart";

enum _ReportKindFilter { daily, weekly }

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    required this.client,
    required this.serverUrl,
    this.onOpenSettings,
    this.isActive = false,
  });

  final CoreClient client;
  final String serverUrl;
  final VoidCallback? onOpenSettings;
  final bool isActive;

  @override
  State<ReportsScreen> createState() => ReportsScreenState();
}

class ReportsScreenState extends State<ReportsScreen> {
  bool _loading = false;
  String? _error;
  List<ReportSummary> _reports = const [];

  ReportSettings? _settings;
  String? _effectiveOutputDir;
  String? _defaultDailyPrompt;
  String? _defaultWeeklyPrompt;

  _ReportKindFilter _filter = _ReportKindFilter.daily;

  bool _enabled = false;
  bool _dailyEnabled = false;
  int _dailyAtMinutes = 10;
  bool _weeklyEnabled = false;
  int _weeklyWeekday = DateTime.monday;
  int _weeklyAtMinutes = 20;
  bool _saveMd = true;
  bool _saveCsv = false;

  late final TextEditingController _apiBaseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _dailyPrompt;
  late final TextEditingController _weeklyPrompt;
  late final TextEditingController _outputDir;

  Timer? _saveDebounce;
  bool _apiKeyObscure = true;
  bool _saving = false;
  String? _saveError;

  bool _generating = false;

  Timer? _autoRetryTimer;
  int _autoRetryAttempts = 0;

  bool _agentBusy = false;

  @override
  void initState() {
    super.initState();
    _apiBaseUrl = TextEditingController();
    _apiKey = TextEditingController();
    _model = TextEditingController();
    _dailyPrompt = TextEditingController();
    _weeklyPrompt = TextEditingController();
    _outputDir = TextEditingController();
    if (widget.isActive) {
      refresh(silent: true);
    }
  }

  @override
  void didUpdateWidget(covariant ReportsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverUrl != widget.serverUrl) {
      _autoRetryTimer?.cancel();
      _autoRetryTimer = null;
      _autoRetryAttempts = 0;
      if (widget.isActive) {
        refresh();
      } else if (mounted) {
        setState(() {
          _loading = false;
          _error = null;
          _reports = const [];
          _settings = null;
        });
      }
      return;
    }
    if (!oldWidget.isActive && widget.isActive) {
      refresh(silent: true);
    }
  }

  @override
  void dispose() {
    _autoRetryTimer?.cancel();
    _apiBaseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _dailyPrompt.dispose();
    _weeklyPrompt.dispose();
    _outputDir.dispose();
    _saveDebounce?.cancel();
    super.dispose();
  }

  String _ageText(DateTime ts) {
    final d = DateTime.now().difference(ts);
    if (d.inSeconds < 60) return "${d.inSeconds}s ago";
    if (d.inMinutes < 60) return "${d.inMinutes}m ago";
    if (d.inHours < 24) return "${d.inHours}h ago";
    return "${d.inDays}d ago";
  }

  bool _serverLooksLikeLocalhost() {
    final uri = Uri.tryParse(widget.serverUrl.trim());
    if (uri == null) return false;
    final host = uri.host.trim().toLowerCase();
    return host == "127.0.0.1" ||
        host == "localhost" ||
        host == "0.0.0.0" ||
        host == "::1";
  }

  Future<void> _restartAgent() async {
    final agent = DesktopAgent.instance;
    if (!agent.isAvailable) return;
    if (!_serverLooksLikeLocalhost()) return;
    if (!mounted) return;
    setState(() => _agentBusy = true);
    try {
      final res = await agent.start(
        coreUrl: widget.serverUrl,
        restart: true,
        // Collector can always send titles; Core decides whether to store them via Privacy.
        sendTitle: true,
      );
      if (!mounted) return;
      final msg = res.ok ? "Agent restarted" : "Agent restart failed";
      final details = (res.message ?? "").trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          showCloseIcon: true,
          content: Text(details.isEmpty ? msg : "$msg: $details"),
        ),
      );
      await refresh(silent: true);
    } finally {
      if (mounted) setState(() => _agentBusy = false);
    }
  }

  int _tzOffsetMinutesForDay(DateTime d) {
    final noon = DateTime(d.year, d.month, d.day, 12);
    return noon.timeZoneOffset.inMinutes;
  }

  bool _configuredFromInputs() {
    if (!_enabled) return false;
    final apiBase = _apiBaseUrl.text.trim();
    final apiKey = _apiKey.text.trim();
    final model = _model.text.trim();
    if (apiBase.isEmpty || apiKey.isEmpty || model.isEmpty) return false;
    final uri = Uri.tryParse(apiBase);
    if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) return false;
    if (uri.scheme != "http" && uri.scheme != "https") return false;
    return true;
  }

  void _applySettingsToControllers(ReportSettings s) {
    if (_apiBaseUrl.text != s.apiBaseUrl) _apiBaseUrl.text = s.apiBaseUrl;
    if (_apiKey.text != s.apiKey) _apiKey.text = s.apiKey;
    if (_model.text != s.model) _model.text = s.model;
    if (_dailyPrompt.text != s.dailyPrompt) _dailyPrompt.text = s.dailyPrompt;
    if (_weeklyPrompt.text != s.weeklyPrompt)
      _weeklyPrompt.text = s.weeklyPrompt;
    final outDir = s.outputDir ?? "";
    if (_outputDir.text != outDir) _outputDir.text = outDir;
  }

  void _applySettingsToState(ReportSettings s) {
    _enabled = s.enabled;
    _dailyEnabled = s.dailyEnabled;
    _dailyAtMinutes = s.dailyAtMinutes;
    _weeklyEnabled = s.weeklyEnabled;
    _weeklyWeekday = s.weeklyWeekday;
    _weeklyAtMinutes = s.weeklyAtMinutes;
    _saveMd = s.saveMd;
    _saveCsv = s.saveCsv;
    _effectiveOutputDir = s.effectiveOutputDir;
    _defaultDailyPrompt = s.defaultDailyPrompt;
    _defaultWeeklyPrompt = s.defaultWeeklyPrompt;
  }

  void _scheduleSave({Duration delay = const Duration(milliseconds: 700)}) {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(delay, () {
      _saveSettings().catchError((_) {});
    });
  }

  bool _settingsChanged(ReportSettings base) {
    final outDir = _outputDir.text.trim();
    final baseOutDir = (base.outputDir ?? "").trim();

    return base.enabled != _enabled ||
        base.apiBaseUrl.trim() != _apiBaseUrl.text.trim() ||
        base.apiKey.trim() != _apiKey.text.trim() ||
        base.model.trim() != _model.text.trim() ||
        base.dailyEnabled != _dailyEnabled ||
        base.dailyAtMinutes != _dailyAtMinutes ||
        base.dailyPrompt != _dailyPrompt.text ||
        base.weeklyEnabled != _weeklyEnabled ||
        base.weeklyWeekday != _weeklyWeekday ||
        base.weeklyAtMinutes != _weeklyAtMinutes ||
        base.weeklyPrompt != _weeklyPrompt.text ||
        base.saveMd != _saveMd ||
        base.saveCsv != _saveCsv ||
        baseOutDir != outDir;
  }

  Future<void> _saveSettings() async {
    final base = _settings;
    if (base == null) return;
    if (!_settingsChanged(base)) return;
    if (_saving) return;

    if (!mounted) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });

    try {
      final outDir = _outputDir.text.trim();
      final saved = await widget.client.updateReportSettings(
        enabled: _enabled,
        apiBaseUrl: _apiBaseUrl.text.trim(),
        apiKey: _apiKey.text.trim(),
        model: _model.text.trim(),
        dailyEnabled: _dailyEnabled,
        dailyAtMinutes: _dailyAtMinutes.clamp(0, 1439),
        dailyPrompt: _dailyPrompt.text,
        weeklyEnabled: _weeklyEnabled,
        weeklyWeekday: _weeklyWeekday.clamp(1, 7),
        weeklyAtMinutes: _weeklyAtMinutes.clamp(0, 1439),
        weeklyPrompt: _weeklyPrompt.text,
        saveMd: _saveMd,
        saveCsv: _saveCsv,
        outputDir: outDir, // empty -> reset to default
      );
      if (!mounted) return;
      setState(() {
        _settings = saved;
        _applySettingsToState(saved);
      });
      _applySettingsToControllers(saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saveError = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> refresh({bool silent = false}) async {
    if (!widget.isActive && !silent) return;
    final showLoadingUi = !silent || _error != null;
    if (showLoadingUi) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final ok = await widget.client.waitUntilHealthy(
        timeout: showLoadingUi
            ? (_serverLooksLikeLocalhost()
                ? const Duration(seconds: 15)
                : const Duration(seconds: 6))
            : const Duration(milliseconds: 900),
      );
      if (!ok) {
        if (showLoadingUi) throw Exception("health_failed");
        _scheduleAutoRetryIfNeeded("health_failed");
        return;
      }

      final settingsFuture = widget.client.reportSettings();
      final listFuture = widget.client.reports(limit: 200);
      final settings = await settingsFuture;
      final list = await listFuture;

      if (!mounted) return;
      setState(() {
        _settings = settings;
        _reports = list;
        _applySettingsToState(settings);
        _error = null;
      });
      _applySettingsToControllers(settings);
      _autoRetryAttempts = 0;
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      if (showLoadingUi) setState(() => _error = msg);
      _scheduleAutoRetryIfNeeded(msg);
    } finally {
      if (mounted && showLoadingUi) setState(() => _loading = false);
    }
  }

  bool _isTransientError(String msg) {
    final s = msg.toLowerCase();
    if (s.contains("health_failed")) return true;
    if (s.contains("connection") || s.contains("socket")) return true;
    if (s.contains("refused") ||
        s.contains("timed out") ||
        s.contains("timeout")) return true;
    if (s.contains("http_502") ||
        s.contains("http_503") ||
        s.contains("http_504")) return true;
    return false;
  }

  void _scheduleAutoRetryIfNeeded(String msg) {
    if (!mounted) return;
    if (_autoRetryTimer != null) return;
    if (!_serverLooksLikeLocalhost()) return;
    if (!_isTransientError(msg)) return;
    if (_autoRetryAttempts >= 8) return;

    final backoffMs = (350 * (1 << _autoRetryAttempts)).clamp(350, 5000);
    _autoRetryAttempts += 1;
    _autoRetryTimer = Timer(Duration(milliseconds: backoffMs), () {
      _autoRetryTimer = null;
      if (!mounted) return;
      refresh(silent: true);
    });
  }

  DateTime _normalizeDay(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTime _startOfWeekMonday(DateTime d) {
    final day = _normalizeDay(d);
    return day.subtract(Duration(days: day.weekday - DateTime.monday));
  }

  String _dateLocal(DateTime d) {
    final y = d.year.toString().padLeft(4, "0");
    final m = d.month.toString().padLeft(2, "0");
    final dd = d.day.toString().padLeft(2, "0");
    return "$y-$m-$dd";
  }

  String _weekdayLabel(int weekday) {
    switch (weekday) {
      case DateTime.monday:
        return "Mon";
      case DateTime.tuesday:
        return "Tue";
      case DateTime.wednesday:
        return "Wed";
      case DateTime.thursday:
        return "Thu";
      case DateTime.friday:
        return "Fri";
      case DateTime.saturday:
        return "Sat";
      case DateTime.sunday:
        return "Sun";
      default:
        return "$weekday";
    }
  }

  String _hhmmFromMinutes(int minutes) {
    final h = (minutes ~/ 60).clamp(0, 23).toString().padLeft(2, "0");
    final m = (minutes % 60).clamp(0, 59).toString().padLeft(2, "0");
    return "$h:$m";
  }

  Future<void> _generateDaily(DateTime day) async {
    // Ensure Core has the latest settings before generating.
    await _saveSettings();

    final s = _settings;
    if (s == null || !s.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "LLM reports are not configured. Enable it and set provider/model/key first."),
        ),
      );
      return;
    }

    setState(() => _generating = true);
    try {
      final tz = _tzOffsetMinutesForDay(day);
      await widget.client.generateDailyReport(
        date: _dateLocal(day),
        tzOffsetMinutes: tz,
        force: true,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Generated daily report: ${_dateLocal(day)}")),
      );
      await refresh(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Generate failed: $e")));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _generateWeekly(DateTime weekStartAnyDay) async {
    await _saveSettings();

    final s = _settings;
    if (s == null || !s.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "LLM reports are not configured. Enable it and set provider/model/key first."),
        ),
      );
      return;
    }

    setState(() => _generating = true);
    try {
      final start = _startOfWeekMonday(weekStartAnyDay);
      final tz = _tzOffsetMinutesForDay(start);
      await widget.client.generateWeeklyReport(
        weekStart: _dateLocal(start),
        tzOffsetMinutes: tz,
        force: true,
      );
      if (!mounted) return;
      final startS = _dateLocal(start);
      final endS = _dateLocal(start.add(const Duration(days: 6)));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Generated weekly report: $startS ~ $endS")),
      );
      await refresh(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Generate failed: $e")));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _openReport(ReportSummary s) async {
    final record = await showModalBottomSheet<ReportRecord>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _ReportDetailSheet(
        client: widget.client,
        summary: s,
        onGenerateDaily: _generateDaily,
        onGenerateWeekly: _generateWeekly,
      ),
    );
    if (record != null) {
      await refresh(silent: true);
    }
  }

  List<ReportSummary> _filtered() {
    Iterable<ReportSummary> out = _reports;
    if (_filter == _ReportKindFilter.daily) {
      out = out.where((r) => r.kind == "daily");
    } else {
      out = out.where((r) => r.kind == "weekly");
    }
    return out.toList();
  }

  Widget _configCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final configured = _configuredFromInputs();
    final incomplete = _enabled && !configured;

    final dailyLabel = _dailyEnabled
        ? "Daily: ${_hhmmFromMinutes(_dailyAtMinutes)} (yesterday)"
        : "Daily: OFF";
    final weeklyLabel = _weeklyEnabled
        ? "Weekly: ${_weekdayLabel(_weeklyWeekday)} ${_hhmmFromMinutes(_weeklyAtMinutes)} (last week)"
        : "Weekly: OFF";

    final statusTitle = configured
        ? "Enabled"
        : incomplete
            ? "Enabled (needs setup)"
            : "Off";

    final modelLine =
        _model.text.trim().isEmpty ? "" : "Model: ${_model.text.trim()}\n";
    final statusBody = configured
        ? "${modelLine}$dailyLabel\n$weeklyLabel"
        : "Connect a provider to enable daily/weekly auto reports (Core runs automation even if UI is closed).\n$dailyLabel\n$weeklyLabel";

    final outputDirLine = (_effectiveOutputDir ?? "").trim().isEmpty
        ? null
        : "Output: ${_effectiveOutputDir!.trim()}";

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text("Reports",
                        style: Theme.of(context).textTheme.titleMedium)),
                if (widget.onOpenSettings != null)
                  TextButton.icon(
                    onPressed: widget.onOpenSettings,
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text("Core settings"),
                  ),
              ],
            ),
            const SizedBox(height: RecorderTokens.space2),
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
                border:
                    Border.all(color: scheme.outline.withValues(alpha: 0.10)),
              ),
              padding: const EdgeInsets.all(RecorderTokens.space3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    configured
                        ? Icons.check_circle_outline
                        : incomplete
                            ? Icons.warning_amber_rounded
                            : Icons.info_outline,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: RecorderTokens.space2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(statusTitle,
                            style: Theme.of(context).textTheme.labelLarge),
                        const SizedBox(height: 4),
                        Text(statusBody,
                            style: Theme.of(context).textTheme.labelMedium),
                        if (outputDirLine != null) ...[
                          const SizedBox(height: 6),
                          Text(outputDirLine,
                              style: Theme.of(context).textTheme.labelMedium),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: RecorderTokens.space3),
            Wrap(
              spacing: RecorderTokens.space2,
              runSpacing: RecorderTokens.space2,
              children: [
                OutlinedButton.icon(
                  onPressed: !configured || _generating
                      ? null
                      : () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _normalizeDay(
                              DateTime.now().subtract(const Duration(days: 1)),
                            ),
                            firstDate: DateTime(2020, 1, 1),
                            lastDate: DateTime.now(),
                          );
                          if (picked == null) return;
                          await _generateDaily(picked);
                        },
                  icon: const Icon(Icons.today_outlined),
                  label: Text(_generating ? "Generating…" : "Generate daily"),
                ),
                OutlinedButton.icon(
                  onPressed: !configured || _generating
                      ? null
                      : () async {
                          final base = _normalizeDay(
                              DateTime.now().subtract(const Duration(days: 7)));
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: base,
                            firstDate: DateTime(2020, 1, 1),
                            lastDate: DateTime.now(),
                          );
                          if (picked == null) return;
                          await _generateWeekly(picked);
                        },
                  icon: const Icon(Icons.date_range_outlined),
                  label: Text(_generating ? "Generating…" : "Generate weekly"),
                ),
              ],
            ),
            const SizedBox(height: RecorderTokens.space2),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text("Report settings"),
              subtitle: Text(
                _enabled
                    ? (configured
                        ? "Enabled · ${_model.text.trim()}"
                        : "Enabled but not configured")
                    : "Off",
              ),
              children: [
                const SizedBox(height: RecorderTokens.space2),
                SwitchListTile(
                  title: const Text("Enable LLM reports"),
                  subtitle: const Text(
                      "Core runs auto-generation while it is running (UI can be closed)."),
                  value: _enabled,
                  onChanged: (v) {
                    setState(() => _enabled = v);
                    _scheduleSave(delay: const Duration(milliseconds: 200));
                  },
                ),
                const SizedBox(height: RecorderTokens.space2),
                TextField(
                  controller: _apiBaseUrl,
                  decoration: const InputDecoration(
                    labelText: "Provider base URL",
                    hintText: "https://api.openai.com/v1",
                  ),
                  onChanged: (_) => _scheduleSave(),
                ),
                const SizedBox(height: RecorderTokens.space3),
                TextField(
                  controller: _apiKey,
                  obscureText: _apiKeyObscure,
                  decoration: InputDecoration(
                    labelText: "API key",
                    suffixIcon: IconButton(
                      tooltip: _apiKeyObscure ? "Show" : "Hide",
                      onPressed: () =>
                          setState(() => _apiKeyObscure = !_apiKeyObscure),
                      icon: Icon(_apiKeyObscure
                          ? Icons.visibility
                          : Icons.visibility_off),
                    ),
                  ),
                  onChanged: (_) => _scheduleSave(),
                ),
                const SizedBox(height: RecorderTokens.space3),
                TextField(
                  controller: _model,
                  decoration: const InputDecoration(
                    labelText: "Model",
                    hintText: "gpt-4o-mini",
                  ),
                  onChanged: (_) => _scheduleSave(),
                ),
                const SizedBox(height: RecorderTokens.space3),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Daily schedule"),
                  subtitle: Text(
                    _dailyEnabled
                        ? "At ${_hhmmFromMinutes(_dailyAtMinutes)} (yesterday)"
                        : "OFF",
                  ),
                  trailing: Switch(
                    value: _dailyEnabled,
                    onChanged: (v) {
                      setState(() => _dailyEnabled = v);
                      _scheduleSave(delay: const Duration(milliseconds: 200));
                    },
                  ),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(
                        hour: (_dailyAtMinutes ~/ 60).clamp(0, 23),
                        minute: (_dailyAtMinutes % 60).clamp(0, 59),
                      ),
                    );
                    if (picked == null) return;
                    final minutes =
                        (picked.hour * 60 + picked.minute).clamp(0, 1439);
                    setState(() {
                      _dailyAtMinutes = minutes;
                      _dailyEnabled = true;
                    });
                    _scheduleSave(delay: const Duration(milliseconds: 200));
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Weekly schedule"),
                  subtitle: Text(
                    _weeklyEnabled
                        ? "${_weekdayLabel(_weeklyWeekday)} ${_hhmmFromMinutes(_weeklyAtMinutes)} (last week)"
                        : "OFF",
                  ),
                  trailing: Switch(
                    value: _weeklyEnabled,
                    onChanged: (v) {
                      setState(() => _weeklyEnabled = v);
                      _scheduleSave(delay: const Duration(milliseconds: 200));
                    },
                  ),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(
                        hour: (_weeklyAtMinutes ~/ 60).clamp(0, 23),
                        minute: (_weeklyAtMinutes % 60).clamp(0, 59),
                      ),
                    );
                    if (picked == null) return;
                    final minutes =
                        (picked.hour * 60 + picked.minute).clamp(0, 1439);
                    setState(() {
                      _weeklyAtMinutes = minutes;
                      _weeklyEnabled = true;
                    });
                    _scheduleSave(delay: const Duration(milliseconds: 200));
                  },
                ),
                Row(
                  children: [
                    const SizedBox(width: 38),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _weeklyWeekday,
                        decoration: const InputDecoration(
                          labelText: "Weekly weekday",
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: DateTime.monday, child: Text("Mon")),
                          DropdownMenuItem(
                              value: DateTime.tuesday, child: Text("Tue")),
                          DropdownMenuItem(
                              value: DateTime.wednesday, child: Text("Wed")),
                          DropdownMenuItem(
                              value: DateTime.thursday, child: Text("Thu")),
                          DropdownMenuItem(
                              value: DateTime.friday, child: Text("Fri")),
                          DropdownMenuItem(
                              value: DateTime.saturday, child: Text("Sat")),
                          DropdownMenuItem(
                              value: DateTime.sunday, child: Text("Sun")),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _weeklyWeekday = v);
                          _scheduleSave(
                              delay: const Duration(milliseconds: 200));
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: RecorderTokens.space3),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text("Storage"),
                  subtitle: Text(_effectiveOutputDir == null
                      ? "Default path"
                      : "Output folder configured"),
                  children: [
                    SwitchListTile(
                      title: const Text("Save Markdown (.md)"),
                      subtitle: const Text("Recommended (readable)."),
                      value: _saveMd,
                      onChanged: (v) {
                        setState(() => _saveMd = v);
                        _scheduleSave(delay: const Duration(milliseconds: 200));
                      },
                    ),
                    SwitchListTile(
                      title: const Text("Also save CSV (.csv)"),
                      subtitle: const Text("Optional (analysis/import)."),
                      value: _saveCsv,
                      onChanged: (v) {
                        setState(() => _saveCsv = v);
                        _scheduleSave(delay: const Duration(milliseconds: 200));
                      },
                    ),
                    const SizedBox(height: RecorderTokens.space2),
                    TextField(
                      controller: _outputDir,
                      decoration: const InputDecoration(
                        labelText: "Output folder (optional)",
                        hintText: "Leave empty for default",
                      ),
                      onChanged: (_) => _scheduleSave(),
                    ),
                    const SizedBox(height: RecorderTokens.space2),
                    Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 16, color: scheme.onSurfaceVariant),
                        const SizedBox(width: RecorderTokens.space2),
                        Expanded(
                          child: Text(
                            (_effectiveOutputDir ?? "").trim().isEmpty
                                ? "Files are saved under Core data directory."
                                : "Effective output: ${_effectiveOutputDir!.trim()}",
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ),
                        if ((_effectiveOutputDir ?? "").trim().isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: () async {
                              final s = (_effectiveOutputDir ?? "").trim();
                              if (s.isEmpty) return;
                              await Clipboard.setData(ClipboardData(text: s));
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Path copied")),
                              );
                            },
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text("Copy"),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: RecorderTokens.space2),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text("Prompts (advanced)"),
                  subtitle:
                      const Text("Customize the Markdown table templates."),
                  children: [
                    const SizedBox(height: RecorderTokens.space2),
                    TextField(
                      controller: _dailyPrompt,
                      minLines: 6,
                      maxLines: 12,
                      decoration: const InputDecoration(
                        labelText: "Daily prompt",
                        hintText: "Must output Markdown only.",
                      ),
                      onChanged: (_) => _scheduleSave(),
                    ),
                    const SizedBox(height: RecorderTokens.space3),
                    TextField(
                      controller: _weeklyPrompt,
                      minLines: 6,
                      maxLines: 12,
                      decoration: const InputDecoration(
                        labelText: "Weekly prompt",
                        hintText: "Must output Markdown only.",
                      ),
                      onChanged: (_) => _scheduleSave(),
                    ),
                    const SizedBox(height: RecorderTokens.space2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          final d = _defaultDailyPrompt;
                          final w = _defaultWeeklyPrompt;
                          if (d == null || w == null) return;
                          setState(() {
                            _dailyPrompt.text = d;
                            _weeklyPrompt.text = w;
                          });
                          _scheduleSave(
                              delay: const Duration(milliseconds: 200));
                        },
                        icon: const Icon(Icons.restore, size: 18),
                        label: const Text("Reset prompts to default"),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: RecorderTokens.space2),
                Row(
                  children: [
                    if (_saving)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        _saveError == null
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 16,
                        color: _saveError == null
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.error,
                      ),
                    const SizedBox(width: RecorderTokens.space2),
                    Expanded(
                      child: Text(
                        _saveError != null
                            ? "Error: $_saveError"
                            : _saving
                                ? "Saving…"
                                : "Saved.",
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ],
                ),
                if (widget.onOpenSettings != null) ...[
                  const SizedBox(height: RecorderTokens.space2),
                  Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: RecorderTokens.space2),
                      const Expanded(
                        child: Text(
                            "Need tab titles / app details? Enable Privacy L2/L3 in Core settings."),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      final msg = _error ?? "";
      final auto = _serverLooksLikeLocalhost() && _isTransientError(msg);
      final is404 = msg.contains("http_404");
      final canRestartAgent =
          _serverLooksLikeLocalhost() && DesktopAgent.instance.isAvailable;
      return Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Reports unavailable",
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: RecorderTokens.space2),
            Text("Server URL: ${widget.serverUrl}",
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: RecorderTokens.space2),
            Text("Error: $msg", style: Theme.of(context).textTheme.labelMedium),
            if (is404) ...[
              const SizedBox(height: RecorderTokens.space2),
              const Text(
                "Tip: this server does not implement Reports endpoints yet. Update/restart recorder_core (or restart the desktop agent).",
              ),
            ],
            if (auto) ...[
              const SizedBox(height: RecorderTokens.space2),
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: RecorderTokens.space2),
                  const Expanded(child: Text("Retrying automatically…")),
                ],
              ),
            ],
            const SizedBox(height: RecorderTokens.space4),
            Wrap(
              spacing: RecorderTokens.space2,
              runSpacing: RecorderTokens.space2,
              children: [
                FilledButton.icon(
                  onPressed: refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Retry"),
                ),
                if (canRestartAgent)
                  OutlinedButton.icon(
                    onPressed: _agentBusy ? null : _restartAgent,
                    icon: const Icon(Icons.restart_alt),
                    label: Text(_agentBusy ? "Restarting…" : "Restart agent"),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    final filtered = _filtered();

    return RefreshIndicator(
      onRefresh: () => refresh(silent: true),
      child: ListView.separated(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        itemCount: filtered.length + 2,
        separatorBuilder: (_, __) =>
            const SizedBox(height: RecorderTokens.space3),
        itemBuilder: (context, i) {
          if (i == 0) return _configCard(context);
          if (i == 1) {
            return Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<_ReportKindFilter>(
                segments: const [
                  ButtonSegment(
                      value: _ReportKindFilter.daily, label: Text("Daily")),
                  ButtonSegment(
                      value: _ReportKindFilter.weekly, label: Text("Weekly")),
                ],
                selected: {_filter},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _filter = s.first),
              ),
            );
          }
          final s = filtered[i - 2];
          final title = s.kind == "daily"
              ? s.periodStart
              : "${s.periodStart} ~ ${s.periodEnd}";
          final subtitle =
              "Generated ${_ageText(DateTime.parse(s.generatedAt).toLocal())}"
              "${s.model == null || s.model!.trim().isEmpty ? "" : " · ${s.model}"}";

          return ListTile(
            tileColor: Theme.of(context).colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
            ),
            leading: Icon(s.kind == "daily"
                ? Icons.today_outlined
                : Icons.date_range_outlined),
            title: Text(title),
            subtitle: Text(subtitle),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (s.hasError)
                  const RecorderTooltip(
                      message: "Has error",
                      child: Icon(Icons.error_outline, size: 18)),
                if (s.hasOutput)
                  const RecorderTooltip(
                      message: "Has output",
                      child: Icon(Icons.article_outlined, size: 18)),
              ],
            ),
            onTap: () => _openReport(s),
          );
        },
      ),
    );
  }
}

class _ReportDetailSheet extends StatefulWidget {
  const _ReportDetailSheet({
    required this.client,
    required this.summary,
    required this.onGenerateDaily,
    required this.onGenerateWeekly,
  });

  final CoreClient client;
  final ReportSummary summary;
  final Future<void> Function(DateTime day) onGenerateDaily;
  final Future<void> Function(DateTime weekStart) onGenerateWeekly;

  @override
  State<_ReportDetailSheet> createState() => _ReportDetailSheetState();
}

class _ReportDetailSheetState extends State<_ReportDetailSheet> {
  bool _loading = true;
  String? _error;
  ReportRecord? _record;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ok = await widget.client
          .waitUntilHealthy(timeout: const Duration(seconds: 6));
      if (!ok) throw Exception("health_failed");
      final r = await widget.client.reportById(widget.summary.id);
      if (!mounted) return;
      setState(() => _record = r);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text("Copied")));
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    try {
      await widget.client.deleteReport(widget.summary.id);
      if (!mounted) return;
      Navigator.pop(
        context,
        ReportRecord(
          id: "",
          kind: "",
          periodStart: "",
          periodEnd: "",
          generatedAt: "",
          providerUrl: null,
          model: null,
          prompt: null,
          inputJson: null,
          outputMd: null,
          error: null,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Delete failed: $e")));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _regenerate() async {
    final s = widget.summary;
    setState(() => _busy = true);
    try {
      if (s.kind == "daily") {
        final day = DateTime.parse("${s.periodStart}T00:00:00");
        await widget.onGenerateDaily(day);
      } else {
        final day = DateTime.parse("${s.periodStart}T00:00:00");
        await widget.onGenerateWeekly(day);
      }
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _periodText(ReportRecord r) {
    if (r.kind == "daily") return r.periodStart;
    return "${r.periodStart} ~ ${r.periodEnd}";
  }

  String _generatedAtLocal(String raw) {
    final ts = DateTime.tryParse(raw);
    if (ts == null) return raw;
    final local = ts.toLocal();
    String two(int v) => v.toString().padLeft(2, "0");
    return "${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}";
  }

  String _providerHost(String? rawUrl) {
    final s = (rawUrl ?? "").trim();
    if (s.isEmpty) return "";
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.trim().isEmpty) return s;
    return uri.host.trim();
  }

  String _prettyJson(String raw) {
    if (raw.trim().isEmpty) return raw;
    try {
      final decoded = jsonDecode(raw);
      const encoder = JsonEncoder.withIndent("  ");
      return encoder.convert(decoded);
    } catch (_) {
      return raw;
    }
  }

  Widget _metaChip({
    required BuildContext context,
    required IconData icon,
    required String label,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.outline.withValues(alpha: 0.10)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: RecorderTokens.space2,
        vertical: 6,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _textPanel(BuildContext context, String text,
      {bool monospace = false}) {
    final style = monospace
        ? Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(fontFamily: "monospace")
        : Theme.of(context).textTheme.bodyMedium;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(RecorderTokens.space3),
      child: SelectableText(text, style: style),
    );
  }

  bool _isWideDesktop(BuildContext context) {
    return MediaQuery.sizeOf(context).width >= 1080;
  }

  Widget _tabbedContent(
    BuildContext context,
    ColorScheme scheme,
    List<_ReportTabData> tabs,
  ) {
    return DefaultTabController(
      length: tabs.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TabBar(
            isScrollable: true,
            tabs: [
              for (final tab in tabs)
                Tab(
                  icon: Icon(tab.icon, size: 16),
                  text: tab.label,
                ),
            ],
          ),
          const SizedBox(height: RecorderTokens.space2),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
                border: Border.all(
                  color: scheme.outline.withValues(alpha: 0.10),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: TabBarView(
                children: [
                  for (final tab in tabs) tab.child,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactActions(String out) {
    return Wrap(
      spacing: RecorderTokens.space2,
      runSpacing: RecorderTokens.space2,
      children: [
        FilledButton.icon(
          onPressed: _busy || out.isEmpty ? null : () => _copy(out),
          icon: const Icon(Icons.copy, size: 18),
          label: const Text("Copy markdown"),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _regenerate,
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(_busy ? "Working…" : "Regenerate"),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh_outlined, size: 18),
          label: const Text("Reload"),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _delete,
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text("Delete"),
        ),
      ],
    );
  }

  Widget _wideActionPanel(BuildContext context, String out) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.12)),
      ),
      padding: const EdgeInsets.all(RecorderTokens.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Actions", style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: RecorderTokens.space2),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy || out.isEmpty ? null : () => _copy(out),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text("Copy markdown"),
            ),
          ),
          const SizedBox(height: RecorderTokens.space2),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _regenerate,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(_busy ? "Working…" : "Regenerate"),
            ),
          ),
          const SizedBox(height: RecorderTokens.space2),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh_outlined, size: 18),
              label: const Text("Reload"),
            ),
          ),
          const SizedBox(height: RecorderTokens.space2),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text("Delete"),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wideMetaRow({
    required BuildContext context,
    required IconData icon,
    required String label,
    required String value,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: RecorderTokens.space2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 2),
              Text(value, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }

  Widget _wideMetaPanel({
    required BuildContext context,
    required ReportRecord report,
    required String generatedAt,
    required String providerHost,
    required String outputMarkdown,
    required String errorText,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.12)),
      ),
      padding: const EdgeInsets.all(RecorderTokens.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Details", style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: RecorderTokens.space2),
          _wideMetaRow(
            context: context,
            icon: report.kind == "daily"
                ? Icons.today_outlined
                : Icons.date_range_outlined,
            label: "Type",
            value: report.kind == "daily" ? "Daily" : "Weekly",
          ),
          const SizedBox(height: RecorderTokens.space2),
          _wideMetaRow(
            context: context,
            icon: Icons.calendar_month_outlined,
            label: "Period",
            value: _periodText(report),
          ),
          const SizedBox(height: RecorderTokens.space2),
          _wideMetaRow(
            context: context,
            icon: Icons.schedule_outlined,
            label: "Generated At",
            value: generatedAt,
          ),
          if ((report.model ?? "").trim().isNotEmpty) ...[
            const SizedBox(height: RecorderTokens.space2),
            _wideMetaRow(
              context: context,
              icon: Icons.memory_outlined,
              label: "Model",
              value: report.model!.trim(),
            ),
          ],
          if (providerHost.isNotEmpty) ...[
            const SizedBox(height: RecorderTokens.space2),
            _wideMetaRow(
              context: context,
              icon: Icons.cloud_outlined,
              label: "Provider",
              value: providerHost,
            ),
          ],
          const SizedBox(height: RecorderTokens.space2),
          _wideMetaRow(
            context: context,
            icon: outputMarkdown.isEmpty
                ? Icons.hourglass_empty_outlined
                : Icons.check_circle_outline,
            label: "Output",
            value: outputMarkdown.isEmpty ? "No output" : "Output ready",
          ),
          if (errorText.isNotEmpty) ...[
            const SizedBox(height: RecorderTokens.space2),
            _wideMetaRow(
              context: context,
              icon: Icons.error_outline,
              label: "Error",
              value: "Present",
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.92,
        child: Padding(
          padding: EdgeInsets.only(
            left: RecorderTokens.space4,
            right: RecorderTokens.space4,
            bottom: RecorderTokens.space4 +
                MediaQuery.of(context).viewInsets.bottom,
            top: RecorderTokens.space2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_loading)
                const Expanded(
                    child: Center(child: CircularProgressIndicator()))
              else if (_error != null)
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.errorContainer.withValues(alpha: 0.35),
                          borderRadius:
                              BorderRadius.circular(RecorderTokens.radiusM),
                          border: Border.all(
                              color: scheme.error.withValues(alpha: 0.25)),
                        ),
                        padding: const EdgeInsets.all(RecorderTokens.space3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.error_outline,
                                size: 18, color: scheme.error),
                            const SizedBox(width: RecorderTokens.space2),
                            Expanded(child: Text("Load failed: $_error")),
                            const SizedBox(width: RecorderTokens.space2),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _load,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text("Retry"),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              else ...[
                Builder(
                  builder: (context) {
                    final r = _record;
                    if (r == null) {
                      return const Expanded(child: SizedBox.shrink());
                    }

                    final out = (r.outputMd ?? "").trim();
                    final prompt = (r.prompt ?? "").trim();
                    final inputJson = (r.inputJson ?? "").trim();
                    final err = (r.error ?? "").trim();
                    final generatedAt = _generatedAtLocal(r.generatedAt);
                    final providerHost = _providerHost(r.providerUrl);
                    final isWideDesktop = _isWideDesktop(context);

                    final tabs = <_ReportTabData>[
                      _ReportTabData(
                        label: "Markdown",
                        icon: Icons.article_outlined,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(RecorderTokens.space3),
                          child: MarkdownBody(
                            data: out.isEmpty ? "*(No output)*" : out,
                            selectable: true,
                            extensionSet: md.ExtensionSet.gitHubFlavored,
                            styleSheet: MarkdownStyleSheet.fromTheme(
                              Theme.of(context),
                            ).copyWith(
                              code: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(fontFamily: "monospace"),
                            ),
                          ),
                        ),
                      ),
                    ];
                    if (prompt.isNotEmpty) {
                      tabs.add(
                        _ReportTabData(
                          label: "Prompt",
                          icon: Icons.tune_outlined,
                          child: _textPanel(context, prompt, monospace: true),
                        ),
                      );
                    }
                    if (inputJson.isNotEmpty) {
                      tabs.add(
                        _ReportTabData(
                          label: "Input",
                          icon: Icons.data_object_outlined,
                          child: _textPanel(context, _prettyJson(inputJson),
                              monospace: true),
                        ),
                      );
                    }
                    if (err.isNotEmpty) {
                      tabs.add(
                        _ReportTabData(
                          label: "Error",
                          icon: Icons.warning_amber_rounded,
                          child: _textPanel(context, err),
                        ),
                      );
                    }

                    return Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Report",
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: RecorderTokens.space1),
                          Text(
                            _periodText(r),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: RecorderTokens.space2),
                          if (!isWideDesktop) ...[
                            Wrap(
                              spacing: RecorderTokens.space2,
                              runSpacing: RecorderTokens.space2,
                              children: [
                                _metaChip(
                                  context: context,
                                  icon: r.kind == "daily"
                                      ? Icons.today_outlined
                                      : Icons.date_range_outlined,
                                  label: r.kind == "daily" ? "Daily" : "Weekly",
                                ),
                                _metaChip(
                                  context: context,
                                  icon: Icons.schedule_outlined,
                                  label: "Generated $generatedAt",
                                ),
                                if ((r.model ?? "").trim().isNotEmpty)
                                  _metaChip(
                                    context: context,
                                    icon: Icons.memory_outlined,
                                    label: r.model!.trim(),
                                  ),
                                if (providerHost.isNotEmpty)
                                  _metaChip(
                                    context: context,
                                    icon: Icons.cloud_outlined,
                                    label: providerHost,
                                  ),
                                _metaChip(
                                  context: context,
                                  icon: out.isEmpty
                                      ? Icons.hourglass_empty_outlined
                                      : Icons.check_circle_outline,
                                  label: out.isEmpty
                                      ? "No output"
                                      : "Output ready",
                                ),
                                if (err.isNotEmpty)
                                  _metaChip(
                                    context: context,
                                    icon: Icons.error_outline,
                                    label: "Has error",
                                  ),
                              ],
                            ),
                            const SizedBox(height: RecorderTokens.space2),
                            _compactActions(out),
                            const SizedBox(height: RecorderTokens.space2),
                            Expanded(
                              child: _tabbedContent(context, scheme, tabs),
                            ),
                          ] else ...[
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child:
                                        _tabbedContent(context, scheme, tabs),
                                  ),
                                  const SizedBox(width: RecorderTokens.space3),
                                  SizedBox(
                                    width: 320,
                                    child: SingleChildScrollView(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _wideMetaPanel(
                                            context: context,
                                            report: r,
                                            generatedAt: generatedAt,
                                            providerHost: providerHost,
                                            outputMarkdown: out,
                                            errorText: err,
                                          ),
                                          const SizedBox(
                                              height: RecorderTokens.space2),
                                          _wideActionPanel(context, out),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportTabData {
  const _ReportTabData({
    required this.label,
    required this.icon,
    required this.child,
  });

  final String label;
  final IconData icon;
  final Widget child;
}
