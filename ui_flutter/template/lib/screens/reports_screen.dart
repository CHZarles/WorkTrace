import "dart:async";
import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../api/core_client.dart";
import "../theme/tokens.dart";
import "../utils/desktop_agent.dart";
import "../widgets/recorder_tooltip.dart";

enum _ReportKindFilter { daily, weekly }

enum _PlannerDimension { todo, calendar }

enum _TodoCalendarView { week, month }

enum _ReportSettingsSection {
  connection,
  automation,
  planner,
  storage,
  prompts
}

enum _ReportSettingsLayer { basic, automation, prompts }

class _ScheduledTodoLayout {
  const _ScheduledTodoLayout({
    required this.todo,
    required this.dayIndex,
    required this.startMinute,
    required this.endMinute,
    required this.columnIndex,
    required this.columnCount,
  });

  final ReportTodo todo;
  final int dayIndex;
  final int startMinute;
  final int endMinute;
  final int columnIndex;
  final int columnCount;

  _ScheduledTodoLayout withColumnCount(int value) {
    return _ScheduledTodoLayout(
      todo: todo,
      dayIndex: dayIndex,
      startMinute: startMinute,
      endMinute: endMinute,
      columnIndex: columnIndex,
      columnCount: value,
    );
  }
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    required this.client,
    required this.serverUrl,
    this.onOpenSettings,
    this.isActive = false,
    this.plannerMode = false,
  });

  final CoreClient client;
  final String serverUrl;
  final VoidCallback? onOpenSettings;
  final bool isActive;
  final bool plannerMode;

  @override
  State<ReportsScreen> createState() => ReportsScreenState();
}

class ReportsScreenState extends State<ReportsScreen> {
  bool _loading = false;
  String? _error;
  DateTime? _lastRefreshedAt;
  List<ReportSummary> _reports = const [];

  ReportSettings? _settings;
  String? _effectiveOutputDir;
  String? _defaultDailyPrompt;
  String? _defaultWeeklyPrompt;
  List<ReportTodo> _todos = const [];

  _ReportKindFilter _filter = _ReportKindFilter.daily;
  _PlannerDimension _plannerDimension = _PlannerDimension.todo;
  _TodoCalendarView _todoCalendarView = _TodoCalendarView.week;
  _ReportSettingsSection _reportSettingsSection =
      _ReportSettingsSection.connection;
  _ReportSettingsLayer _reportSettingsLayer = _ReportSettingsLayer.basic;
  DateTime _todoAnchorDay = DateTime.now();

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
  late final TextEditingController _todoSearch;

  Timer? _saveDebounce;
  bool _apiKeyObscure = true;
  bool _saving = false;
  String? _saveError;

  bool _generating = false;
  bool _todoBusy = false;

  Timer? _autoRetryTimer;
  int _autoRetryAttempts = 0;

  bool _agentBusy = false;
  Timer? _calendarTicker;
  final Set<String> _firedReminderKeys = <String>{};
  int? _dragTodoId;
  int? _dragOriginDayIndex;
  int? _dragOriginStartMinute;
  int? _dragCurrentDayIndex;
  int? _dragCurrentStartMinute;
  int? _dragDurationMinutes;
  Offset? _dragStartGlobalPosition;

  @override
  void initState() {
    super.initState();
    _apiBaseUrl = TextEditingController();
    _apiKey = TextEditingController();
    _model = TextEditingController();
    _dailyPrompt = TextEditingController();
    _weeklyPrompt = TextEditingController();
    _outputDir = TextEditingController();
    _todoSearch = TextEditingController();
    _todoAnchorDay = _normalizeDay(DateTime.now());
    if (widget.plannerMode) {
      _plannerDimension = _PlannerDimension.calendar;
    }
    _calendarTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted || !widget.isActive) return;
      _checkTodoReminders();
      if (_plannerDimension == _PlannerDimension.calendar &&
          _todoCalendarView == _TodoCalendarView.week) {
        setState(() {});
      }
    });
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
    _calendarTicker?.cancel();
    _apiBaseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _dailyPrompt.dispose();
    _weeklyPrompt.dispose();
    _outputDir.dispose();
    _todoSearch.dispose();
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
      List<ReportTodo> todos = const [];
      try {
        todos = await widget.client.reportTodos(limit: 300);
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _settings = settings;
        _reports = list;
        _todos = todos;
        _applySettingsToState(settings);
        _error = null;
        _lastRefreshedAt = DateTime.now();
      });
      _applySettingsToControllers(settings);
      _compactReminderFiredKeys();
      _checkTodoReminders();
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

  String _updatedAgoText(DateTime? t) {
    if (t == null) return "";
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return "已更新 ${d.inSeconds}s 前";
    if (d.inMinutes < 60) return "已更新 ${d.inMinutes}m 前";
    if (d.inHours < 24) return "已更新 ${d.inHours}h 前";
    return "已更新 ${d.inDays}d 前";
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

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  int _snapToQuarterHour(int minute) {
    return ((minute + 7) ~/ 15) * 15;
  }

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

  String _hhmmFromDateTime(DateTime dt) {
    return "${dt.hour.toString().padLeft(2, "0")}:${dt.minute.toString().padLeft(2, "0")}";
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

  Widget _plannerCompactStats(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final open = _todos.where((t) => !t.done).length;
    final today = _todos.where((t) => !t.done && _todoIsToday(t)).length;
    final scheduled =
        _todos.where((t) => !t.done && _todoHasSchedule(t)).length;
    final overdue = _todos.where(_todoIsOverdue).length;

    return Wrap(
      spacing: RecorderTokens.space2,
      runSpacing: RecorderTokens.space2,
      children: [
        _plannerInfoPill(
          context,
          icon: Icons.inbox_outlined,
          label: "Open $open",
          compact: true,
        ),
        _plannerInfoPill(
          context,
          icon: Icons.today_outlined,
          label: "Today $today",
          compact: true,
          bgColor: scheme.primaryContainer.withValues(alpha: 0.42),
          fgColor: scheme.primary,
          borderColor: scheme.primary.withValues(alpha: 0.18),
        ),
        _plannerInfoPill(
          context,
          icon: Icons.schedule_outlined,
          label: "Timed $scheduled",
          compact: true,
        ),
        _plannerInfoPill(
          context,
          icon: Icons.warning_amber_rounded,
          label: "Overdue $overdue",
          compact: true,
          bgColor: overdue > 0
              ? scheme.errorContainer.withValues(alpha: 0.48)
              : scheme.surfaceContainerLowest,
          fgColor: overdue > 0 ? scheme.error : scheme.onSurfaceVariant,
          borderColor: overdue > 0
              ? scheme.error.withValues(alpha: 0.18)
              : scheme.outline.withValues(alpha: 0.16),
        ),
      ],
    );
  }

  Color _todoAccent(BuildContext context, ReportTodo todo) {
    final scheme = Theme.of(context).colorScheme;
    if (todo.done) return scheme.outline;
    if (_todoIsOverdue(todo)) return scheme.error;
    if (_todoHasSchedule(todo)) return scheme.primary;
    return scheme.tertiary;
  }

  Color _todoFill(BuildContext context, ReportTodo todo) {
    final scheme = Theme.of(context).colorScheme;
    if (todo.done) {
      return scheme.surfaceContainerLow;
    }
    if (_todoIsOverdue(todo)) {
      return scheme.errorContainer.withValues(alpha: 0.54);
    }
    if (_todoHasSchedule(todo)) {
      return scheme.primaryContainer.withValues(alpha: 0.46);
    }
    return scheme.surface;
  }

  String _todoSummaryLine(ReportTodo todo, {bool includeDay = true}) {
    final parts = <String>[];
    if (includeDay) {
      if (_todoIsToday(todo)) {
        parts.add("Today");
      } else {
        parts.add(_todoDayTitle(_todoDay(todo)));
      }
    }
    parts.add(
        _todoHasSchedule(todo) ? _todoScheduleRangeLabel(todo) : "No time");
    final reminder = _todoReminderLocal(todo);
    if (reminder != null) {
      parts.add("Reminder ${_hhmmFromDateTime(reminder)}");
    }
    return parts.join(" · ");
  }

  String _todoStatusLabel(ReportTodo todo) {
    if (todo.done) return "Done";
    if (_todoIsOverdue(todo)) return "Overdue";
    if (_todoIsToday(todo)) return "Today";
    if (_todoHasSchedule(todo)) return "Scheduled";
    return "Backlog";
  }

  bool _todoIsToday(ReportTodo todo) {
    return _isSameDay(_todoDay(todo), DateTime.now());
  }

  DateTime? _todoDueAtLocal(ReportTodo todo) {
    final end = todo.endLocal;
    if (end != null) return end;
    final start = todo.startLocal;
    if (start != null) return start;
    final due = (todo.dueDate ?? "").trim();
    if (due.isEmpty) return null;
    final parsed = DateTime.tryParse("${due}T23:59:59");
    if (parsed == null) return null;
    return parsed;
  }

  bool _todoIsOverdue(ReportTodo todo) {
    if (todo.done) return false;
    final dueAt = _todoDueAtLocal(todo);
    if (dueAt == null) return false;
    return dueAt.isBefore(DateTime.now());
  }

  bool _todoMatchesSearch(ReportTodo todo) {
    final query = _todoSearch.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    final content = todo.content.toLowerCase();
    final dateText = (todo.dueDate ?? "").toLowerCase();
    return content.contains(query) || dateText.contains(query);
  }

  DateTime _todoUpdatedAtLocal(ReportTodo todo) {
    return DateTime.tryParse(todo.updatedAt)?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  int _compareTodoByDueSoon(ReportTodo a, ReportTodo b) {
    if (a.done != b.done) return a.done ? 1 : -1;
    final aDue = _todoDueAtLocal(a);
    final bDue = _todoDueAtLocal(b);
    if (aDue == null && bDue != null) return 1;
    if (aDue != null && bDue == null) return -1;
    if (aDue != null && bDue != null) {
      final cmp = aDue.compareTo(bDue);
      if (cmp != 0) return cmp;
    }
    return _todoUpdatedAtLocal(b).compareTo(_todoUpdatedAtLocal(a));
  }

  int _compareTodoSmart(ReportTodo a, ReportTodo b) {
    if (a.done != b.done) return a.done ? 1 : -1;
    final aOverdue = _todoIsOverdue(a);
    final bOverdue = _todoIsOverdue(b);
    if (aOverdue != bOverdue) return aOverdue ? -1 : 1;
    final aToday = _todoIsToday(a);
    final bToday = _todoIsToday(b);
    if (aToday != bToday) return aToday ? -1 : 1;
    final aScheduled = _todoHasSchedule(a);
    final bScheduled = _todoHasSchedule(b);
    if (aScheduled != bScheduled) return aScheduled ? -1 : 1;
    return _compareTodoByDueSoon(a, b);
  }

  List<ReportTodo> _sortPlannerTodos(Iterable<ReportTodo> todos) {
    final out = todos.toList();
    out.sort(_compareTodoSmart);
    return out;
  }

  List<ReportTodo> _todosForListPanel() {
    return _sortPlannerTodos(
      _todos.where((todo) => _todoMatchesSearch(todo)),
    );
  }

  double _weekCalendarHourHeight(BuildContext context) {
    final viewport = (MediaQuery.of(context).size.height * 0.82)
        .clamp(760.0, 1040.0)
        .toDouble();
    return ((viewport - 84) / 24).clamp(32.0, 42.0).toDouble();
  }

  String _plannerSubtitleText() {
    final open = _todos.where((t) => !t.done).length;
    if (_plannerDimension == _PlannerDimension.calendar) {
      final focusLabel = _todoCalendarView == _TodoCalendarView.week
          ? "Week focus"
          : "Month focus";
      return "$focusLabel · ${_todoRangeLabel()} · $open open";
    }
    final query = _todoSearch.text.trim();
    if (query.isNotEmpty) {
      final matched = _todosForListPanel().length;
      return "Tasks · $matched match${matched == 1 ? "" : "es"} for \"$query\"";
    }
    return "Tasks · $open open";
  }

  String _plannerCalendarHint() {
    if (_todoCalendarView == _TodoCalendarView.week) {
      return "Click an empty slot to add a task. Drag a block to reschedule it.";
    }
    return "Click a day to focus it. Double click a date to open its week.";
  }

  String _reportSettingsSectionLabel(_ReportSettingsSection section) {
    switch (section) {
      case _ReportSettingsSection.connection:
        return "Connection";
      case _ReportSettingsSection.automation:
        return "Automation";
      case _ReportSettingsSection.planner:
        return "Planner";
      case _ReportSettingsSection.storage:
        return "Storage";
      case _ReportSettingsSection.prompts:
        return "Prompts";
    }
  }

  String _reportSettingsLayerLabel(_ReportSettingsLayer layer) {
    switch (layer) {
      case _ReportSettingsLayer.basic:
        return "Basic";
      case _ReportSettingsLayer.automation:
        return "Automation";
      case _ReportSettingsLayer.prompts:
        return "Prompts";
    }
  }

  IconData _reportSettingsLayerIcon(_ReportSettingsLayer layer) {
    switch (layer) {
      case _ReportSettingsLayer.basic:
        return Icons.tune_outlined;
      case _ReportSettingsLayer.automation:
        return Icons.schedule_outlined;
      case _ReportSettingsLayer.prompts:
        return Icons.psychology_outlined;
    }
  }

  List<_ReportSettingsSection> _sectionsForLayer(_ReportSettingsLayer layer) {
    switch (layer) {
      case _ReportSettingsLayer.basic:
        return const [
          _ReportSettingsSection.connection,
          _ReportSettingsSection.planner,
          _ReportSettingsSection.storage,
        ];
      case _ReportSettingsLayer.automation:
        return const [_ReportSettingsSection.automation];
      case _ReportSettingsLayer.prompts:
        return const [_ReportSettingsSection.prompts];
    }
  }

  String _reportSettingsLayerHint(_ReportSettingsLayer layer) {
    switch (layer) {
      case _ReportSettingsLayer.basic:
        return "Provider, planner behavior and file output.";
      case _ReportSettingsLayer.automation:
        return "Daily/weekly schedule and generation timing.";
      case _ReportSettingsLayer.prompts:
        return "Advanced prompt tuning for report writing style.";
    }
  }

  IconData _reportSettingsSectionIcon(_ReportSettingsSection section) {
    switch (section) {
      case _ReportSettingsSection.connection:
        return Icons.link_outlined;
      case _ReportSettingsSection.automation:
        return Icons.schedule_outlined;
      case _ReportSettingsSection.planner:
        return Icons.calendar_view_week_outlined;
      case _ReportSettingsSection.storage:
        return Icons.folder_open_outlined;
      case _ReportSettingsSection.prompts:
        return Icons.auto_awesome_outlined;
    }
  }

  String _todoReminderKey(ReportTodo todo) {
    final raw = (todo.reminderTs ?? "").trim();
    return "${todo.id}|$raw";
  }

  void _compactReminderFiredKeys() {
    if (_firedReminderKeys.isEmpty) return;
    final alive = <String>{};
    for (final todo in _todos) {
      if (todo.done) continue;
      final rem = (todo.reminderTs ?? "").trim();
      if (rem.isEmpty) continue;
      alive.add(_todoReminderKey(todo));
    }
    _firedReminderKeys.retainAll(alive);
  }

  void _checkTodoReminders() {
    if (!mounted || !widget.isActive) return;
    final nowUtc = DateTime.now().toUtc();
    final due = _todos.where((todo) {
      if (todo.done) return false;
      final reminder = todo.reminderUtc;
      if (reminder == null) return false;
      if (reminder.isAfter(nowUtc)) return false;
      final age = nowUtc.difference(reminder);
      return age <= const Duration(hours: 12);
    }).toList()
      ..sort((a, b) {
        final ar = a.reminderUtc ?? DateTime.fromMillisecondsSinceEpoch(0);
        final br = b.reminderUtc ?? DateTime.fromMillisecondsSinceEpoch(0);
        return ar.compareTo(br);
      });
    for (final todo in due) {
      final key = _todoReminderKey(todo);
      if (_firedReminderKeys.contains(key)) continue;
      _firedReminderKeys.add(key);
      final label = _todoReminderLabel(todo);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          showCloseIcon: true,
          content: Text("Reminder · $label\n${todo.content}"),
          action: SnackBarAction(
            label: "Open",
            onPressed: () => _openTodoEditor(todo: todo),
          ),
        ),
      );
      break;
    }
  }

  DateTime _todoDay(ReportTodo todo) {
    final start = todo.startLocal;
    if (start != null) return _normalizeDay(start);
    final due = (todo.dueDate ?? "").trim();
    if (due.isNotEmpty) {
      final parsed = DateTime.tryParse("${due}T00:00:00");
      if (parsed != null) return _normalizeDay(parsed);
    }
    final updated = DateTime.tryParse(todo.updatedAt)?.toLocal();
    return _normalizeDay(updated ?? DateTime.now());
  }

  bool _todoHasSchedule(ReportTodo todo) {
    final st = todo.startLocal;
    final en = todo.endLocal;
    if (st == null || en == null) return false;
    return en.isAfter(st);
  }

  int _todoStartMinute(ReportTodo todo) {
    final st = todo.startLocal;
    if (st == null) return 9 * 60;
    return (st.hour * 60 + st.minute).clamp(0, 23 * 60 + 59);
  }

  int _todoDurationMinutes(ReportTodo todo) {
    final st = todo.startLocal;
    final en = todo.endLocal;
    if (st == null || en == null || !en.isAfter(st)) return 60;
    return en.difference(st).inMinutes.clamp(15, 12 * 60);
  }

  DateTime? _todoReminderLocal(ReportTodo todo) {
    return todo.reminderLocal;
  }

  String _todoReminderLabel(ReportTodo todo) {
    final reminder = _todoReminderLocal(todo);
    if (reminder == null) return "No reminder";
    final y = reminder.year.toString().padLeft(4, "0");
    final m = reminder.month.toString().padLeft(2, "0");
    final d = reminder.day.toString().padLeft(2, "0");
    final hh = reminder.hour.toString().padLeft(2, "0");
    final mm = reminder.minute.toString().padLeft(2, "0");
    return "$y-$m-$d $hh:$mm";
  }

  String _todoHourLabel(int hour) => "${hour.toString().padLeft(2, "0")}:00";

  String _todoDayTitle(DateTime day) {
    const wd = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    final d = _normalizeDay(day);
    final m = d.month.toString().padLeft(2, "0");
    final dd = d.day.toString().padLeft(2, "0");
    return "${wd[d.weekday - 1]} $m-$dd";
  }

  String _todoRangeLabel() {
    if (_todoCalendarView == _TodoCalendarView.week) {
      final start = _startOfWeekMonday(_todoAnchorDay);
      final end = start.add(const Duration(days: 6));
      return "${_dateLocal(start)} ~ ${_dateLocal(end)}";
    }
    final month = DateTime(_todoAnchorDay.year, _todoAnchorDay.month, 1);
    return "${month.year}-${month.month.toString().padLeft(2, "0")}";
  }

  void _resetPlannerDragDraft() {
    _dragTodoId = null;
    _dragOriginDayIndex = null;
    _dragOriginStartMinute = null;
    _dragCurrentDayIndex = null;
    _dragCurrentStartMinute = null;
    _dragDurationMinutes = null;
    _dragStartGlobalPosition = null;
  }

  void _selectPlannerDay(
    DateTime day, {
    bool openWeek = false,
  }) {
    if (!mounted) return;
    setState(() {
      _resetPlannerDragDraft();
      _todoAnchorDay = _normalizeDay(day);
      if (openWeek) {
        _todoCalendarView = _TodoCalendarView.week;
      }
    });
  }

  void _jumpPlannerToToday() {
    _selectPlannerDay(DateTime.now());
  }

  void _shiftTodoRange(int step) {
    setState(() {
      _resetPlannerDragDraft();
      if (_todoCalendarView == _TodoCalendarView.week) {
        _todoAnchorDay =
            _normalizeDay(_todoAnchorDay.add(Duration(days: 7 * step)));
        return;
      }
      final month =
          DateTime(_todoAnchorDay.year, _todoAnchorDay.month + step, 1);
      _todoAnchorDay = _normalizeDay(month);
    });
  }

  List<ReportTodo> _sortTodos(Iterable<ReportTodo> todos) {
    final out = todos.toList();
    out.sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      final aScheduled = _todoHasSchedule(a);
      final bScheduled = _todoHasSchedule(b);
      if (aScheduled != bScheduled) return aScheduled ? -1 : 1;
      final aMin = _todoStartMinute(a);
      final bMin = _todoStartMinute(b);
      if (aMin != bMin) return aMin.compareTo(bMin);
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return out;
  }

  List<ReportTodo> _todosForMonth(DateTime anchor) {
    final first = DateTime(anchor.year, anchor.month, 1);
    final next = DateTime(anchor.year, anchor.month + 1, 1);
    return _sortTodos(
      _todos.where((t) {
        final d = _todoDay(t);
        return !d.isBefore(first) && d.isBefore(next);
      }),
    );
  }

  int _compareScheduledTodo(ReportTodo a, ReportTodo b) {
    final aStart = _todoStartMinute(a);
    final bStart = _todoStartMinute(b);
    if (aStart != bStart) return aStart.compareTo(bStart);
    final aEnd = aStart + _todoDurationMinutes(a);
    final bEnd = bStart + _todoDurationMinutes(b);
    if (aEnd != bEnd) return aEnd.compareTo(bEnd);
    if (a.done != b.done) return a.done ? 1 : -1;
    return b.updatedAt.compareTo(a.updatedAt);
  }

  List<_ScheduledTodoLayout> _buildScheduledLayoutsForDay(
      int dayIndex, Iterable<ReportTodo> todos) {
    final scheduled = todos.where(_todoHasSchedule).toList()
      ..sort(_compareScheduledTodo);
    if (scheduled.isEmpty) return const [];

    final out = <_ScheduledTodoLayout>[];
    final group = <ReportTodo>[];
    var groupEnd = -1;

    void flushGroup() {
      if (group.isEmpty) return;
      final columnEnds = <int>[];
      final provisional = <_ScheduledTodoLayout>[];
      for (final todo in group) {
        final start = _todoStartMinute(todo);
        final end = (start + _todoDurationMinutes(todo)).clamp(start + 1, 1440);
        var columnIndex = -1;
        for (var i = 0; i < columnEnds.length; i++) {
          if (columnEnds[i] <= start) {
            columnIndex = i;
            columnEnds[i] = end;
            break;
          }
        }
        if (columnIndex == -1) {
          columnEnds.add(end);
          columnIndex = columnEnds.length - 1;
        }
        provisional.add(
          _ScheduledTodoLayout(
            todo: todo,
            dayIndex: dayIndex,
            startMinute: start,
            endMinute: end,
            columnIndex: columnIndex,
            columnCount: 1,
          ),
        );
      }
      final columns = columnEnds.length.clamp(1, 6);
      out.addAll(provisional.map((it) => it.withColumnCount(columns)));
      group.clear();
      groupEnd = -1;
    }

    for (final todo in scheduled) {
      final start = _todoStartMinute(todo);
      final end = (start + _todoDurationMinutes(todo)).clamp(start + 1, 1440);
      if (group.isNotEmpty && start >= groupEnd) {
        flushGroup();
      }
      group.add(todo);
      groupEnd = groupEnd < 0 ? end : (end > groupEnd ? end : groupEnd);
    }
    flushGroup();
    return out;
  }

  List<_ScheduledTodoLayout> _buildWeekLayouts(DateTime weekStart) {
    final endExclusive = weekStart.add(const Duration(days: 7));
    final byDay = List.generate(7, (_) => <ReportTodo>[]);
    for (final todo in _todos) {
      if (!_todoHasSchedule(todo)) continue;
      final d = _todoDay(todo);
      if (d.isBefore(weekStart) || !d.isBefore(endExclusive)) continue;
      final dayIndex = d.difference(weekStart).inDays;
      if (dayIndex >= 0 && dayIndex < 7) byDay[dayIndex].add(todo);
    }
    final out = <_ScheduledTodoLayout>[];
    for (var i = 0; i < 7; i++) {
      out.addAll(_buildScheduledLayoutsForDay(i, byDay[i]));
    }
    return out;
  }

  void _clearTodoDrag() {
    if (!mounted) return;
    setState(() {
      _resetPlannerDragDraft();
    });
  }

  void _beginTodoDrag({
    required ReportTodo todo,
    required int dayIndex,
    required int startMinute,
    required int durationMinutes,
    required Offset globalPosition,
  }) {
    if (_todoBusy) return;
    setState(() {
      _dragTodoId = todo.id;
      _dragOriginDayIndex = dayIndex;
      _dragOriginStartMinute = startMinute;
      _dragCurrentDayIndex = dayIndex;
      _dragCurrentStartMinute = startMinute;
      _dragDurationMinutes = durationMinutes;
      _dragStartGlobalPosition = globalPosition;
    });
  }

  void _updateTodoDrag({
    required Offset globalPosition,
    required double dayWidth,
    required double hourHeight,
  }) {
    final dragTodoId = _dragTodoId;
    final dragOriginDayIndex = _dragOriginDayIndex;
    final dragOriginStartMinute = _dragOriginStartMinute;
    final dragDurationMinutes = _dragDurationMinutes;
    final dragStartGlobalPosition = _dragStartGlobalPosition;
    if (dragTodoId == null ||
        dragOriginDayIndex == null ||
        dragOriginStartMinute == null ||
        dragDurationMinutes == null ||
        dragStartGlobalPosition == null) {
      return;
    }

    final dx = globalPosition.dx - dragStartGlobalPosition.dx;
    final dy = globalPosition.dy - dragStartGlobalPosition.dy;
    final dayDelta = (dx / dayWidth).round();
    final minuteDelta = (dy / hourHeight * 60).round();
    final targetDay = (dragOriginDayIndex + dayDelta).clamp(0, 6);
    final latestStart = (24 * 60 - dragDurationMinutes).clamp(0, 24 * 60);
    final snappedMinute =
        _snapToQuarterHour(dragOriginStartMinute + minuteDelta)
            .clamp(0, latestStart);

    if (_dragCurrentDayIndex == targetDay &&
        _dragCurrentStartMinute == snappedMinute) {
      return;
    }

    setState(() {
      _dragCurrentDayIndex = targetDay;
      _dragCurrentStartMinute = snappedMinute;
    });
  }

  Future<void> _finishTodoDrag({
    required DateTime weekStart,
    required ReportTodo todo,
  }) async {
    final dragTodoId = _dragTodoId;
    if (dragTodoId == null || dragTodoId != todo.id) {
      _clearTodoDrag();
      return;
    }

    final sourceDay = _dragOriginDayIndex;
    final sourceMinute = _dragOriginStartMinute;
    final targetDay = _dragCurrentDayIndex;
    final targetMinute = _dragCurrentStartMinute;
    final duration = _dragDurationMinutes;
    _clearTodoDrag();

    if (sourceDay == null ||
        sourceMinute == null ||
        targetDay == null ||
        targetMinute == null ||
        duration == null) {
      return;
    }

    final changed = sourceDay != targetDay || sourceMinute != targetMinute;
    if (!changed) return;

    final day = weekStart.add(Duration(days: targetDay));
    final startLocal = DateTime(
      day.year,
      day.month,
      day.day,
      targetMinute ~/ 60,
      targetMinute % 60,
    );
    final endLocal = startLocal.add(Duration(minutes: duration));

    setState(() => _todoBusy = true);
    try {
      await widget.client.upsertReportTodo(
        id: todo.id,
        dueDate: _dateLocal(day),
        startTs: startLocal.toUtc().toIso8601String(),
        endTs: endLocal.toUtc().toIso8601String(),
      );
      await refresh(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Reschedule TODO failed: $e")),
      );
    } finally {
      if (mounted) setState(() => _todoBusy = false);
    }
  }

  Future<void> _openTodoEditor({
    ReportTodo? todo,
    DateTime? suggestedDay,
    int? suggestedStartMinute,
    bool forceSchedule = false,
  }) async {
    if (_todoBusy) return;

    final contentController = TextEditingController(text: todo?.content ?? "");
    var done = todo?.done ?? false;
    var day = _normalizeDay(
        suggestedDay ?? (todo != null ? _todoDay(todo) : _todoAnchorDay));
    final existingStartLocal = todo?.startLocal;
    var withSchedule =
        forceSchedule || (todo != null && _todoHasSchedule(todo));
    var startTime = withSchedule && existingStartLocal != null
        ? TimeOfDay.fromDateTime(existingStartLocal)
        : const TimeOfDay(hour: 9, minute: 0);
    if (suggestedStartMinute != null && todo == null) {
      final startMinute = suggestedStartMinute.clamp(0, 24 * 60 - 15);
      startTime = TimeOfDay(hour: startMinute ~/ 60, minute: startMinute % 60);
      withSchedule = true;
    }
    var durationMinutes =
        withSchedule && todo != null ? _todoDurationMinutes(todo) : 60;
    final existingReminderLocal = todo?.reminderLocal;
    var withReminder = existingReminderLocal != null;
    var reminderDay = _normalizeDay(existingReminderLocal ?? day);
    var reminderTime = existingReminderLocal != null
        ? TimeOfDay.fromDateTime(existingReminderLocal)
        : const TimeOfDay(hour: 8, minute: 45);
    const durationOptions = <int>[15, 30, 45, 60, 90, 120, 180];

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(todo == null ? "Add task" : "Edit task"),
              const SizedBox(height: 4),
              Text(
                "Keep the plan concrete. Add time only when it helps execution.",
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: contentController,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: "Task",
                      hintText: "Describe a concrete next step",
                    ),
                  ),
                  const SizedBox(height: RecorderTokens.space3),
                  Text(
                    "Day",
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _plannerMetaBadge(
                        context,
                        icon: Icons.calendar_today_outlined,
                        label: _dateLocal(day),
                        tint: Theme.of(context).colorScheme.primary,
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: day,
                            firstDate: DateTime(2020, 1, 1),
                            lastDate: DateTime(2100, 12, 31),
                          );
                          if (picked == null) return;
                          setLocal(() => day = _normalizeDay(picked));
                        },
                        icon:
                            const Icon(Icons.edit_calendar_outlined, size: 18),
                        label: const Text("Pick date"),
                      ),
                    ],
                  ),
                  const SizedBox(height: RecorderTokens.space3),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Time block"),
                    subtitle: const Text(
                        "Turn this on when the task should live on the calendar."),
                    value: withSchedule,
                    onChanged: (v) => setLocal(() => withSchedule = v),
                  ),
                  if (withSchedule) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: ctx,
                                initialTime: startTime,
                              );
                              if (picked == null) return;
                              setLocal(() => startTime = picked);
                            },
                            icon: const Icon(Icons.schedule_outlined, size: 18),
                            label: Text(
                              "Start ${startTime.hour.toString().padLeft(2, "0")}:${startTime.minute.toString().padLeft(2, "0")}",
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "Duration",
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in durationOptions)
                          ChoiceChip(
                            label: Text("$option min"),
                            selected: durationMinutes == option,
                            onSelected: (_) =>
                                setLocal(() => durationMinutes = option),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: RecorderTokens.space2),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Reminder"),
                    subtitle: const Text(
                        "Works for both the task list and calendar views."),
                    value: withReminder,
                    onChanged: (v) => setLocal(() => withReminder = v),
                  ),
                  if (withReminder) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: ctx,
                                initialDate: reminderDay,
                                firstDate: DateTime(2020, 1, 1),
                                lastDate: DateTime(2100, 12, 31),
                              );
                              if (picked == null) return;
                              setLocal(
                                  () => reminderDay = _normalizeDay(picked));
                            },
                            icon: const Icon(Icons.calendar_month_outlined,
                                size: 18),
                            label: Text(_dateLocal(reminderDay)),
                          ),
                        ),
                        const SizedBox(width: RecorderTokens.space2),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: ctx,
                                initialTime: reminderTime,
                              );
                              if (picked == null) return;
                              setLocal(() => reminderTime = picked);
                            },
                            icon: const Icon(Icons.alarm_outlined, size: 18),
                            label: Text(
                              "${reminderTime.hour.toString().padLeft(2, "0")}:${reminderTime.minute.toString().padLeft(2, "0")}",
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: RecorderTokens.space2),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Mark as done"),
                    value: done,
                    onChanged: (v) => setLocal(() => done = v ?? false),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Save"),
            ),
          ],
        ),
      ),
    );

    if (ok != true) {
      contentController.dispose();
      return;
    }

    final content = contentController.text.trim();
    contentController.dispose();
    if (content.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("TODO content cannot be empty")),
      );
      return;
    }

    String? startTs;
    String? endTs;
    if (withSchedule) {
      final startLocal = DateTime(
          day.year, day.month, day.day, startTime.hour, startTime.minute);
      final endLocal = startLocal.add(Duration(minutes: durationMinutes));
      startTs = startLocal.toUtc().toIso8601String();
      endTs = endLocal.toUtc().toIso8601String();
    }
    String? reminderTs;
    if (withReminder) {
      final reminderLocal = DateTime(
        reminderDay.year,
        reminderDay.month,
        reminderDay.day,
        reminderTime.hour,
        reminderTime.minute,
      );
      reminderTs = reminderLocal.toUtc().toIso8601String();
    }

    setState(() => _todoBusy = true);
    try {
      await widget.client.upsertReportTodo(
        id: todo?.id,
        content: content,
        done: done,
        dueDate: _dateLocal(day),
        startTs: startTs ?? "",
        endTs: endTs ?? "",
        reminderTs: reminderTs ?? "",
      );
      await refresh(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Save TODO failed: $e")));
    } finally {
      if (mounted) setState(() => _todoBusy = false);
    }
  }

  Future<void> _toggleTodo(ReportTodo todo, bool done) async {
    if (_todoBusy) return;
    setState(() => _todoBusy = true);
    try {
      await widget.client.upsertReportTodo(id: todo.id, done: done);
      await refresh(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Update TODO failed: $e")));
    } finally {
      if (mounted) setState(() => _todoBusy = false);
    }
  }

  Future<void> _deleteTodo(ReportTodo todo) async {
    if (_todoBusy) return;
    setState(() => _todoBusy = true);
    try {
      await widget.client.deleteReportTodo(todo.id);
      await refresh(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Delete TODO failed: $e")));
    } finally {
      if (mounted) setState(() => _todoBusy = false);
    }
  }

  Widget _todoChip(BuildContext context, ReportTodo todo) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _todoAccent(context, todo);
    final fill = _todoFill(context, todo);
    final status = _todoStatusLabel(todo);
    final muted = todo.done
        ? scheme.onSurfaceVariant
        : scheme.onSurfaceVariant.withValues(alpha: 0.92);
    final badges = <Widget>[
      _plannerMetaBadge(
        context,
        icon: Icons.calendar_today_outlined,
        label: _todoIsToday(todo) ? "Today" : _todoDayTitle(_todoDay(todo)),
        tint: _todoIsToday(todo) ? scheme.primary : scheme.onSurfaceVariant,
      ),
      _plannerMetaBadge(
        context,
        icon: _todoHasSchedule(todo)
            ? Icons.schedule_outlined
            : Icons.hourglass_empty_outlined,
        label:
            _todoHasSchedule(todo) ? _todoScheduleRangeLabel(todo) : "Anytime",
        tint: _todoHasSchedule(todo) ? accent : scheme.onSurfaceVariant,
      ),
    ];
    final reminder = _todoReminderLocal(todo);
    if (reminder != null) {
      badges.add(
        _plannerMetaBadge(
          context,
          icon: Icons.alarm_outlined,
          label: _hhmmFromDateTime(reminder),
          tint: scheme.tertiary,
        ),
      );
    }

    Future<void> onAction(String action) async {
      switch (action) {
        case "edit":
          await _openTodoEditor(todo: todo);
          break;
        case "toggle":
          await _toggleTodo(todo, !todo.done);
          break;
        case "delete":
          await _deleteTodo(todo);
          break;
      }
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _todoBusy ? null : () => _openTodoEditor(todo: todo),
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accent.withValues(alpha: 0.14)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                tooltip: todo.done ? "Mark open" : "Mark done",
                onPressed: _todoBusy ? null : () => onAction("toggle"),
                icon: Icon(
                  todo.done ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 22,
                  color: accent,
                ),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        todo.content,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                              decoration: todo.done
                                  ? TextDecoration.lineThrough
                                  : TextDecoration.none,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: badges,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _todoSummaryLine(todo),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: muted,
                                ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      status,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  PopupMenuButton<String>(
                    tooltip: "More",
                    onSelected: _todoBusy ? null : onAction,
                    itemBuilder: (context) => [
                      const PopupMenuItem<String>(
                        value: "edit",
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.edit_outlined, size: 18),
                          title: Text("Edit"),
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: "toggle",
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            todo.done
                                ? Icons.check_circle_outline
                                : Icons.radio_button_unchecked,
                            size: 18,
                          ),
                          title: Text(todo.done ? "Mark open" : "Mark done"),
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem<String>(
                        value: "delete",
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.delete_outline, size: 18),
                          title: Text("Delete"),
                        ),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.more_horiz,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _todoScheduleRangeLabel(ReportTodo todo) {
    if (!_todoHasSchedule(todo)) return "No time";
    final startMinute = _todoStartMinute(todo);
    final endMinute = (startMinute + _todoDurationMinutes(todo))
        .clamp(startMinute + 1, 24 * 60);
    final endLabel =
        endMinute == 24 * 60 ? "24:00" : _hhmmFromMinutes(endMinute);
    return "${_hhmmFromMinutes(startMinute)}-$endLabel";
  }

  String _todoCalendarTooltip(ReportTodo todo) {
    final parts = <String>[
      todo.content,
      "Day · ${_dateLocal(_todoDay(todo))}",
      "Schedule · ${_todoScheduleRangeLabel(todo)}",
    ];
    final reminder = _todoReminderLocal(todo);
    if (reminder != null) {
      parts.add("Reminder · ${_todoReminderLabel(todo)}");
    }
    if (todo.done) {
      parts.add("Status · Done");
    } else if (_todoIsOverdue(todo)) {
      parts.add("Status · Overdue");
    }
    return parts.join("\n");
  }

  List<ReportTodo> _todosForDayPanel(DateTime day) {
    final target = _normalizeDay(day);
    return _sortTodos(
      _todos.where((todo) => _isSameDay(_todoDay(todo), target)),
    );
  }

  Widget _plannerInfoPill(
    BuildContext context, {
    required IconData icon,
    required String label,
    Color? bgColor,
    Color? fgColor,
    Color? borderColor,
    bool compact = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final resolvedBg = bgColor ?? scheme.surfaceContainerLowest;
    final resolvedFg = fgColor ?? scheme.onSurfaceVariant;
    final resolvedBorder =
        borderColor ?? scheme.outline.withValues(alpha: 0.16);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 10,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: resolvedBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: resolvedBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 12 : 14, color: resolvedFg),
          SizedBox(width: compact ? 4 : 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: resolvedFg,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }

  Widget _plannerMetaBadge(
    BuildContext context, {
    required IconData icon,
    required String label,
    Color? tint,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final resolvedTint = tint ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: resolvedTint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: resolvedTint.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: resolvedTint),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: resolvedTint,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }

  Widget _calendarAgendaRow(BuildContext context, ReportTodo todo) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _todoAccent(context, todo);
    final fill = _todoFill(context, todo);
    final timeLabel =
        _todoHasSchedule(todo) ? _todoScheduleRangeLabel(todo) : "Anytime";

    return RecorderTooltip(
      message: _todoCalendarTooltip(todo),
      preferBelow: false,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _todoBusy ? null : () => _openTodoEditor(todo: todo),
            child: Container(
              margin: const EdgeInsets.only(bottom: RecorderTokens.space2),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: accent.withValues(alpha: 0.16)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 68,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.84),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      timeLabel,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          todo.content,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    decoration: todo.done
                                        ? TextDecoration.lineThrough
                                        : TextDecoration.none,
                                  ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _todoSummaryLine(todo, includeDay: false),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.labelMedium?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: RecorderTokens.space1),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _todoStatusLabel(todo),
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: accent,
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      IconButton(
                        tooltip: todo.done ? "Mark open" : "Mark done",
                        onPressed: _todoBusy
                            ? null
                            : () => _toggleTodo(todo, !todo.done),
                        icon: Icon(
                          todo.done
                              ? Icons.check_circle
                              : Icons.check_circle_outline,
                          size: 20,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _calendarFocusDayCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final day = _normalizeDay(_todoAnchorDay);
    final todos = _todosForDayPanel(day);
    final openCount = todos.where((todo) => !todo.done).length;
    final scheduledCount =
        todos.where((todo) => !todo.done && _todoHasSchedule(todo)).length;
    final reminderCount = todos
        .where((todo) => !todo.done && _todoReminderLocal(todo) != null)
        .length;
    final viewingToday = _isSameDay(day, DateTime.now());

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
      ),
      padding: const EdgeInsets.all(RecorderTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 720;
              final title = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Agenda",
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _todoDayTitle(day),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _plannerMetaBadge(
                        context,
                        icon: Icons.inbox_outlined,
                        label: "$openCount open",
                      ),
                      _plannerMetaBadge(
                        context,
                        icon: Icons.schedule_outlined,
                        label: "$scheduledCount timed",
                        tint: scheme.primary,
                      ),
                      if (reminderCount > 0)
                        _plannerMetaBadge(
                          context,
                          icon: Icons.alarm_outlined,
                          label: "$reminderCount reminder",
                          tint: scheme.tertiary,
                        ),
                    ],
                  ),
                ],
              );
              final actionBar = Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  if (!viewingToday)
                    OutlinedButton(
                      onPressed: _todoBusy ? null : _jumpPlannerToToday,
                      child: const Text("Today"),
                    ),
                  OutlinedButton.icon(
                    onPressed: _todoBusy
                        ? null
                        : () => _openTodoEditor(
                              suggestedDay: day,
                              forceSchedule: true,
                            ),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text("Add task"),
                  ),
                ],
              );
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title,
                    const SizedBox(height: RecorderTokens.space2),
                    actionBar,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 12),
                  Flexible(child: actionBar),
                ],
              );
            },
          ),
          const SizedBox(height: RecorderTokens.space3),
          if (todos.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(RecorderTokens.space3),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border:
                    Border.all(color: scheme.outline.withValues(alpha: 0.12)),
              ),
              child: Text(
                "Nothing scheduled for this day yet.",
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            )
          else
            Column(
              children: [
                for (final todo in todos) _calendarAgendaRow(context, todo),
              ],
            ),
        ],
      ),
    );
  }

  Widget _todoWeekView(
    BuildContext context,
    DateTime day, {
    required double hourHeight,
  }) {
    final start = _startOfWeekMonday(day);
    final days = List.generate(7, (i) => start.add(Duration(days: i)));
    final endExclusive = start.add(const Duration(days: 7));
    final scheduledLayouts = _buildWeekLayouts(start);
    final dayTodos = List.generate(7, (i) => _todosForDayPanel(days[i]));
    final unscheduled = _sortTodos(
      _todos.where((t) {
        if (_todoHasSchedule(t)) return false;
        final d = _todoDay(t);
        return !d.isBefore(start) && d.isBefore(endExclusive);
      }),
    );

    const leftAxisWidth = 72.0;
    const headerHeight = 74.0;
    final gridHeight = 24 * hourHeight;
    final today = _normalizeDay(DateTime.now());
    final selectedDay = _normalizeDay(_todoAnchorDay);
    final now = DateTime.now();
    final todayIndex = (!today.isBefore(start) && today.isBefore(endExclusive))
        ? today.difference(start).inDays
        : -1;
    final nowMinute = now.hour * 60 + now.minute + now.second / 60.0;
    final dragDayIndex = _dragCurrentDayIndex;
    final dragMinute = _dragCurrentStartMinute;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: headerHeight + gridHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final dayWidth = (((constraints.maxWidth - leftAxisWidth) / 7)
                      .clamp(156.0, 300.0))
                  .toDouble();
              final minWidth = leftAxisWidth + dayWidth * 7;
              final width = constraints.maxWidth > minWidth
                  ? constraints.maxWidth
                  : minWidth;

              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width,
                  child: SingleChildScrollView(
                    child: SizedBox(
                      height: headerHeight + gridHeight,
                      child: Stack(
                        children: [
                          for (var i = 0; i < 7; i++)
                            if (days[i].weekday >= DateTime.saturday)
                              Positioned(
                                left: leftAxisWidth + i * dayWidth,
                                top: 0,
                                width: dayWidth,
                                height: headerHeight + gridHeight,
                                child: Container(
                                  color:
                                      scheme.secondary.withValues(alpha: 0.035),
                                ),
                              ),
                          for (var i = 0; i < 7; i++)
                            if (_isSameDay(days[i], selectedDay))
                              Positioned(
                                left: leftAxisWidth + i * dayWidth,
                                top: 0,
                                width: dayWidth,
                                height: headerHeight + gridHeight,
                                child: Container(
                                  color:
                                      scheme.secondary.withValues(alpha: 0.045),
                                ),
                              ),
                          for (var i = 0; i < 7; i++)
                            if (_isSameDay(days[i], today))
                              Positioned(
                                left: leftAxisWidth + i * dayWidth,
                                top: 0,
                                width: dayWidth,
                                height: headerHeight + gridHeight,
                                child: Container(
                                  color: scheme.primary.withValues(alpha: 0.05),
                                ),
                              ),
                          for (var slot = 0; slot <= 48; slot++)
                            Positioned(
                              left: leftAxisWidth,
                              right: 0,
                              top: headerHeight + slot * (hourHeight / 2),
                              child: Divider(
                                height: 1,
                                thickness: slot % 2 == 0 ? 1 : 0.7,
                                color: scheme.outline.withValues(
                                    alpha: slot % 2 == 0 ? 0.12 : 0.07),
                              ),
                            ),
                          for (var i = 0; i <= 7; i++)
                            Positioned(
                              top: 0,
                              bottom: 0,
                              left: leftAxisWidth + i * dayWidth,
                              child: VerticalDivider(
                                width: 1,
                                thickness: 1,
                                color: scheme.outline.withValues(alpha: 0.12),
                              ),
                            ),
                          for (var i = 0; i < 7; i++)
                            Positioned(
                              left: leftAxisWidth + i * dayWidth,
                              top: 0,
                              width: dayWidth,
                              height: headerHeight,
                              child: Builder(
                                builder: (context) {
                                  final isToday = _isSameDay(days[i], today);
                                  final isSelected =
                                      _isSameDay(days[i], selectedDay);
                                  final openCount = dayTodos[i]
                                      .where((todo) => !todo.done)
                                      .length;
                                  final scheduledCount = dayTodos[i]
                                      .where((todo) =>
                                          !todo.done && _todoHasSchedule(todo))
                                      .length;
                                  final reminderCount = dayTodos[i]
                                      .where((todo) =>
                                          !todo.done &&
                                          _todoReminderLocal(todo) != null)
                                      .length;
                                  final headerBg = isSelected
                                      ? scheme.secondaryContainer
                                          .withValues(alpha: 0.72)
                                      : isToday
                                          ? scheme.primaryContainer
                                              .withValues(alpha: 0.72)
                                          : scheme.surfaceContainerLowest
                                              .withValues(alpha: 0.82);
                                  final headerFg = isSelected
                                      ? scheme.onSecondaryContainer
                                      : isToday
                                          ? scheme.onPrimaryContainer
                                          : scheme.onSurface;
                                  final headerBorder = isSelected
                                      ? scheme.secondary.withValues(alpha: 0.24)
                                      : isToday
                                          ? scheme.primary
                                              .withValues(alpha: 0.22)
                                          : scheme.outline
                                              .withValues(alpha: 0.14);

                                  return RecorderTooltip(
                                    message:
                                        "${_todoDayTitle(days[i])}\n$openCount open · $scheduledCount scheduled${reminderCount > 0 ? "\n$reminderCount reminder" : ""}",
                                    preferBelow: false,
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          onTap: () =>
                                              _selectPlannerDay(days[i]),
                                          child: Container(
                                            margin: const EdgeInsets.fromLTRB(
                                                4, 4, 4, 6),
                                            padding: const EdgeInsets.fromLTRB(
                                              10,
                                              8,
                                              10,
                                              9,
                                            ),
                                            decoration: BoxDecoration(
                                              color: headerBg,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              border: Border.all(
                                                  color: headerBorder),
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  _weekdayLabel(
                                                      days[i].weekday),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .labelSmall
                                                      ?.copyWith(
                                                        color:
                                                            headerFg.withValues(
                                                                alpha: 0.86),
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                ),
                                                const SizedBox(height: 4),
                                                Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Container(
                                                      width: 30,
                                                      height: 30,
                                                      alignment:
                                                          Alignment.center,
                                                      decoration: BoxDecoration(
                                                        color: scheme.surface
                                                            .withValues(
                                                                alpha: isToday ||
                                                                        isSelected
                                                                    ? 0.92
                                                                    : 0.74),
                                                        shape: BoxShape.circle,
                                                      ),
                                                      child: Text(
                                                        days[i].day.toString(),
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .labelLarge
                                                            ?.copyWith(
                                                              color: headerFg,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                            ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          Text(
                                                            openCount == 0
                                                                ? "Clear day"
                                                                : "$openCount open",
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                Theme.of(
                                                                        context)
                                                                    .textTheme
                                                                    .labelSmall
                                                                    ?.copyWith(
                                                                      color: headerFg.withValues(
                                                                          alpha:
                                                                              0.82),
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w700,
                                                                    ),
                                                          ),
                                                          const SizedBox(
                                                              height: 3),
                                                          Text(
                                                            scheduledCount == 0
                                                                ? "No timed tasks"
                                                                : "$scheduledCount timed${reminderCount > 0 ? " · $reminderCount reminder" : ""}",
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                Theme.of(
                                                                        context)
                                                                    .textTheme
                                                                    .labelSmall
                                                                    ?.copyWith(
                                                                      color: headerFg.withValues(
                                                                          alpha:
                                                                              0.72),
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w600,
                                                                    ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          for (var i = 0; i < 7; i++)
                            Positioned(
                              left: leftAxisWidth + i * dayWidth,
                              top: headerHeight,
                              width: dayWidth,
                              height: gridHeight,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTapUp: _todoBusy
                                      ? null
                                      : (details) async {
                                          final minute = _snapToQuarterHour(
                                            ((details.localPosition.dy /
                                                        hourHeight) *
                                                    60)
                                                .round(),
                                          ).clamp(0, 23 * 60 + 45);
                                          _selectPlannerDay(days[i]);
                                          await _openTodoEditor(
                                            suggestedDay: days[i],
                                            suggestedStartMinute: minute,
                                            forceSchedule: true,
                                          );
                                        },
                                ),
                              ),
                            ),
                          for (var h = 0; h < 24; h++)
                            Positioned(
                              left: 0,
                              top: headerHeight + h * hourHeight - 8,
                              width: leftAxisWidth - 6,
                              child: Text(
                                _todoHourLabel(h),
                                textAlign: TextAlign.right,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                              ),
                            ),
                          for (final layout in scheduledLayouts)
                            Builder(
                              builder: (context) {
                                final todo = layout.todo;
                                final isDraggingTodo = _dragTodoId == todo.id;
                                final visualDayIndex = isDraggingTodo
                                    ? (_dragCurrentDayIndex ?? layout.dayIndex)
                                    : layout.dayIndex;
                                final visualStartMinute = isDraggingTodo
                                    ? (_dragCurrentStartMinute ??
                                        layout.startMinute)
                                    : layout.startMinute;
                                final visualDurationMinute = isDraggingTodo
                                    ? (_dragDurationMinutes ??
                                        (layout.endMinute - layout.startMinute))
                                    : (layout.endMinute - layout.startMinute);

                                final top = headerHeight +
                                    (visualStartMinute / 60.0) * hourHeight;
                                final height =
                                    (visualDurationMinute / 60.0) * hourHeight;
                                final blockHeight =
                                    height.clamp(30, 9999).toDouble();
                                final columns = isDraggingTodo
                                    ? 1
                                    : (layout.columnCount <= 0
                                        ? 1
                                        : layout.columnCount);
                                final innerWidth =
                                    (dayWidth - 12).clamp(56.0, 9999.0);
                                final rawColumnWidth = innerWidth / columns;
                                final eventWidth = (rawColumnWidth - 6)
                                    .clamp(64.0, innerWidth)
                                    .toDouble();
                                final startLabel = _hhmmFromMinutes(
                                    visualStartMinute.clamp(0, 24 * 60 - 1));
                                final endLabel = _hhmmFromMinutes(
                                    (visualStartMinute + visualDurationMinute)
                                        .clamp(0, 24 * 60 - 1));
                                final reminderLabel = _todoReminderLocal(todo);
                                final overdue = _todoIsOverdue(todo);
                                final compact =
                                    blockHeight < 60 || eventWidth < 110;
                                final accent = overdue
                                    ? scheme.error
                                    : todo.done
                                        ? scheme.outline
                                        : scheme.primary;
                                final fill = todo.done
                                    ? scheme.surfaceContainerHighest
                                    : overdue
                                        ? scheme.errorContainer
                                            .withValues(alpha: 0.86)
                                        : scheme.primaryContainer
                                            .withValues(alpha: 0.88);
                                return Positioned(
                                  left: leftAxisWidth +
                                      visualDayIndex * dayWidth +
                                      4 +
                                      rawColumnWidth *
                                          (isDraggingTodo
                                              ? 0
                                              : layout.columnIndex),
                                  top: top,
                                  width: eventWidth,
                                  height: blockHeight,
                                  child: RecorderTooltip(
                                    message: _todoCalendarTooltip(todo),
                                    preferBelow: false,
                                    child: MouseRegion(
                                      cursor: isDraggingTodo
                                          ? SystemMouseCursors.grabbing
                                          : SystemMouseCursors.grab,
                                      child: GestureDetector(
                                        onTap: _todoBusy
                                            ? null
                                            : () => _openTodoEditor(todo: todo),
                                        onPanStart: _todoBusy
                                            ? null
                                            : (details) => _beginTodoDrag(
                                                  todo: todo,
                                                  dayIndex: layout.dayIndex,
                                                  startMinute:
                                                      layout.startMinute,
                                                  durationMinutes:
                                                      layout.endMinute -
                                                          layout.startMinute,
                                                  globalPosition:
                                                      details.globalPosition,
                                                ),
                                        onPanUpdate: _todoBusy
                                            ? null
                                            : (details) => _updateTodoDrag(
                                                  globalPosition:
                                                      details.globalPosition,
                                                  dayWidth: dayWidth,
                                                  hourHeight: hourHeight,
                                                ),
                                        onPanEnd: _todoBusy
                                            ? null
                                            : (_) => _finishTodoDrag(
                                                  weekStart: start,
                                                  todo: todo,
                                                ),
                                        onPanCancel: _clearTodoDrag,
                                        child: AnimatedOpacity(
                                          duration:
                                              const Duration(milliseconds: 120),
                                          opacity: isDraggingTodo ? 0.92 : 1,
                                          child: AnimatedContainer(
                                            duration: const Duration(
                                                milliseconds: 120),
                                            decoration: BoxDecoration(
                                              color: fill,
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              border: Border.all(
                                                color: accent.withValues(
                                                    alpha: isDraggingTodo
                                                        ? 0.38
                                                        : 0.22),
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: scheme.shadow
                                                      .withValues(
                                                          alpha: isDraggingTodo
                                                              ? 0.10
                                                              : 0.04),
                                                  blurRadius:
                                                      isDraggingTodo ? 12 : 8,
                                                  offset: Offset(0,
                                                      isDraggingTodo ? 6 : 3),
                                                ),
                                              ],
                                            ),
                                            child: Stack(
                                              children: [
                                                Positioned(
                                                  left: 0,
                                                  top: 0,
                                                  bottom: 0,
                                                  child: Container(
                                                    width: 4,
                                                    decoration: BoxDecoration(
                                                      color: accent,
                                                      borderRadius:
                                                          const BorderRadius
                                                              .horizontal(
                                                        left:
                                                            Radius.circular(10),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                          10, 7, 7, 7),
                                                  child: compact
                                                      ? Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Text(
                                                              "$startLabel-$endLabel",
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: Theme.of(
                                                                      context)
                                                                  .textTheme
                                                                  .labelSmall
                                                                  ?.copyWith(
                                                                    color:
                                                                        accent,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w700,
                                                                  ),
                                                            ),
                                                            const SizedBox(
                                                                height: 3),
                                                            Expanded(
                                                              child: Text(
                                                                todo.content,
                                                                maxLines:
                                                                    blockHeight <
                                                                            44
                                                                        ? 1
                                                                        : 2,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: Theme.of(
                                                                        context)
                                                                    .textTheme
                                                                    .labelSmall
                                                                    ?.copyWith(
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w600,
                                                                      height:
                                                                          1.18,
                                                                      decoration: todo.done
                                                                          ? TextDecoration
                                                                              .lineThrough
                                                                          : TextDecoration
                                                                              .none,
                                                                    ),
                                                              ),
                                                            ),
                                                            if (reminderLabel !=
                                                                    null &&
                                                                blockHeight >=
                                                                    56)
                                                              Padding(
                                                                padding:
                                                                    const EdgeInsets
                                                                        .only(
                                                                        top: 3),
                                                                child: Icon(
                                                                  Icons
                                                                      .alarm_outlined,
                                                                  size: 11,
                                                                  color: scheme
                                                                      .onSurfaceVariant,
                                                                ),
                                                              ),
                                                          ],
                                                        )
                                                      : Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Row(
                                                              children: [
                                                                Icon(
                                                                  Icons
                                                                      .schedule_outlined,
                                                                  size: 11,
                                                                  color: accent,
                                                                ),
                                                                const SizedBox(
                                                                    width: 4),
                                                                Expanded(
                                                                  child: Text(
                                                                    "$startLabel-$endLabel",
                                                                    maxLines: 1,
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                    style: Theme.of(
                                                                            context)
                                                                        .textTheme
                                                                        .labelSmall
                                                                        ?.copyWith(
                                                                          color:
                                                                              accent,
                                                                          fontWeight:
                                                                              FontWeight.w700,
                                                                        ),
                                                                  ),
                                                                ),
                                                                if (reminderLabel !=
                                                                    null)
                                                                  Icon(
                                                                    Icons
                                                                        .alarm_outlined,
                                                                    size: 11,
                                                                    color: scheme
                                                                        .onSurfaceVariant,
                                                                  ),
                                                              ],
                                                            ),
                                                            const SizedBox(
                                                                height: 4),
                                                            Expanded(
                                                              child: Text(
                                                                todo.content,
                                                                maxLines:
                                                                    blockHeight <
                                                                            78
                                                                        ? 2
                                                                        : 4,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: Theme.of(
                                                                        context)
                                                                    .textTheme
                                                                    .labelSmall
                                                                    ?.copyWith(
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w600,
                                                                      height:
                                                                          1.22,
                                                                      decoration: todo.done
                                                                          ? TextDecoration
                                                                              .lineThrough
                                                                          : TextDecoration
                                                                              .none,
                                                                    ),
                                                              ),
                                                            ),
                                                            if (reminderLabel !=
                                                                null)
                                                              Text(
                                                                "Reminder ${_hhmmFromDateTime(reminderLabel)}",
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: Theme.of(
                                                                        context)
                                                                    .textTheme
                                                                    .labelSmall
                                                                    ?.copyWith(
                                                                      color: scheme
                                                                          .onSurfaceVariant,
                                                                    ),
                                                              ),
                                                          ],
                                                        ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          if (todayIndex >= 0)
                            Positioned(
                              left: leftAxisWidth + todayIndex * dayWidth + 2,
                              width: dayWidth - 4,
                              top: headerHeight +
                                  (nowMinute / 60.0) * hourHeight,
                              child: Row(
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: scheme.error,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: scheme.errorContainer,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      _hhmmFromMinutes(nowMinute.floor()),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: scheme.error,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Container(
                                      height: 1.4,
                                      color: scheme.error,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (_dragTodoId != null &&
                              dragDayIndex != null &&
                              dragMinute != null)
                            Positioned(
                              right: 10,
                              top: 10,
                              child: IgnorePointer(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: scheme.outline
                                          .withValues(alpha: 0.16),
                                    ),
                                  ),
                                  child: Text(
                                    "${_todoDayTitle(days[dragDayIndex])} · ${_hhmmFromMinutes(dragMinute)}",
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (unscheduled.isNotEmpty) ...[
          const SizedBox(height: RecorderTokens.space2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(RecorderTokens.space3),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Unscheduled",
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: RecorderTokens.space2),
                Wrap(
                  spacing: RecorderTokens.space2,
                  runSpacing: RecorderTokens.space2,
                  children: [
                    for (final t in unscheduled)
                      RecorderTooltip(
                        message: _todoCalendarTooltip(t),
                        preferBelow: false,
                        child: ActionChip(
                          avatar: Icon(
                            Icons.calendar_today_outlined,
                            size: 14,
                            color: _isSameDay(_todoDay(t), selectedDay)
                                ? scheme.secondary
                                : scheme.onSurfaceVariant,
                          ),
                          label: Text(
                            "${_weekdayLabel(_todoDay(t).weekday)} · ${t.content}",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          side: BorderSide(
                            color: _isSameDay(_todoDay(t), selectedDay)
                                ? scheme.secondary.withValues(alpha: 0.22)
                                : scheme.outline.withValues(alpha: 0.14),
                          ),
                          backgroundColor: _isSameDay(_todoDay(t), selectedDay)
                              ? scheme.secondaryContainer
                                  .withValues(alpha: 0.74)
                              : scheme.surface,
                          onPressed: _todoBusy
                              ? null
                              : () async {
                                  setState(() => _todoAnchorDay = _todoDay(t));
                                  await _openTodoEditor(todo: t);
                                },
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _todoMonthView(BuildContext context, DateTime anchor) {
    final firstDay = DateTime(anchor.year, anchor.month, 1);
    final monthStartGrid = _startOfWeekMonday(firstDay);
    final cells =
        List.generate(42, (i) => monthStartGrid.add(Duration(days: i)));
    const weekday = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    final today = _normalizeDay(DateTime.now());
    final byDay = <DateTime, List<ReportTodo>>{};
    final scheme = Theme.of(context).colorScheme;
    for (final t in _todosForMonth(anchor)) {
      final d = _todoDay(t);
      byDay.putIfAbsent(d, () => []).add(t);
    }

    return Column(
      children: [
        Row(
          children: [
            for (final wd in weekday)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      wd,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
              ),
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final maxPreviewItems = width < 760 ? 2 : 3;
            final aspectRatio = width < 700
                ? 0.92
                : width < 980
                    ? 1.02
                    : 1.12;
            return GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: aspectRatio,
              ),
              itemCount: cells.length,
              itemBuilder: (context, index) {
                final day = _normalizeDay(cells[index]);
                final inMonth = day.month == anchor.month;
                final list = _sortTodos(byDay[day] ?? const []);
                final openCount = list.where((t) => !t.done).length;
                final scheduledCount =
                    list.where((t) => !t.done && _todoHasSchedule(t)).length;
                final isToday = _isSameDay(day, today);
                final isSelected = _isSameDay(day, _todoAnchorDay);
                final visibleTodos = list.take(maxPreviewItems).toList();
                final remaining = list.length - visibleTodos.length;
                final cellBg = isSelected
                    ? scheme.primaryContainer.withValues(alpha: 0.50)
                    : isToday
                        ? scheme.secondaryContainer.withValues(alpha: 0.34)
                        : scheme.surfaceContainerLowest;
                final cellBorder = isSelected
                    ? scheme.primary.withValues(alpha: 0.24)
                    : isToday
                        ? scheme.secondary.withValues(alpha: 0.20)
                        : scheme.outline.withValues(alpha: 0.14);

                return RecorderTooltip(
                  message:
                      "${_todoDayTitle(day)}\n${list.length} item${list.length == 1 ? "" : "s"}",
                  preferBelow: false,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius:
                            BorderRadius.circular(RecorderTokens.radiusM),
                        onTap: () => _selectPlannerDay(day,
                            openWeek: isSelected && inMonth),
                        onDoubleTap: inMonth
                            ? () => _selectPlannerDay(day, openWeek: true)
                            : null,
                        onLongPress: _todoBusy || !inMonth
                            ? null
                            : () => _openTodoEditor(suggestedDay: day),
                        child: Container(
                          decoration: BoxDecoration(
                            color: cellBg,
                            borderRadius:
                                BorderRadius.circular(RecorderTokens.radiusM),
                            border: Border.all(color: cellBorder),
                          ),
                          padding: const EdgeInsets.all(RecorderTokens.space2),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 28,
                                    height: 28,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? scheme.primary
                                          : isToday
                                              ? scheme.primaryContainer
                                              : Colors.transparent,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text(
                                      day.day.toString(),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge
                                          ?.copyWith(
                                            color: isSelected
                                                ? scheme.onPrimary
                                                : inMonth
                                                    ? (isToday
                                                        ? scheme.primary
                                                        : scheme.onSurface)
                                                    : scheme.onSurfaceVariant,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ),
                                  const Spacer(),
                                  if (openCount > 0)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: scheme.surface.withValues(
                                          alpha: inMonth ? 0.92 : 0.72,
                                        ),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        scheduledCount > 0
                                            ? "$openCount · $scheduledCount"
                                            : "$openCount",
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: list.isEmpty
                                    ? Align(
                                        alignment: Alignment.topLeft,
                                        child: Text(
                                          isSelected && inMonth
                                              ? "Double click to open week"
                                              : "",
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      )
                                    : Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          for (final todo in visibleTodos)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  bottom: 4),
                                              child: RecorderTooltip(
                                                message:
                                                    _todoCalendarTooltip(todo),
                                                preferBelow: false,
                                                child: Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Container(
                                                      width: 6,
                                                      height: 6,
                                                      margin:
                                                          const EdgeInsets.only(
                                                        top: 5,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: _todoAccent(
                                                            context, todo),
                                                        shape: BoxShape.circle,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Expanded(
                                                      child: Text(
                                                        "${_todoHasSchedule(todo) ? "${_hhmmFromMinutes(_todoStartMinute(todo))} " : ""}${todo.content}",
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .labelSmall
                                                            ?.copyWith(
                                                              color: inMonth
                                                                  ? scheme
                                                                      .onSurface
                                                                  : scheme
                                                                      .onSurfaceVariant,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              decoration: todo
                                                                      .done
                                                                  ? TextDecoration
                                                                      .lineThrough
                                                                  : TextDecoration
                                                                      .none,
                                                            ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          if (remaining > 0)
                                            Container(
                                              margin:
                                                  const EdgeInsets.only(top: 2),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 7,
                                                vertical: 4,
                                              ),
                                              decoration: BoxDecoration(
                                                color: scheme.surface
                                                    .withValues(alpha: 0.72),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: Text(
                                                "+$remaining more",
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: scheme
                                                          .onSurfaceVariant,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                            ),
                                        ],
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _todoSectionCard(
    BuildContext context, {
    required String title,
    required List<ReportTodo> todos,
    Color? accent,
    String? note,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final sectionAccent = accent ?? scheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: RecorderTokens.space2),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: sectionAccent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: sectionAccent,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Text(
                "${todos.length}",
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(
              note,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
          const SizedBox(height: 10),
          for (final todo in todos) _todoChip(context, todo),
        ],
      ),
    );
  }

  Widget _todoListDimension(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sorted = _todosForListPanel();
    final open = sorted.where((t) => !t.done).toList();
    final done = sorted.where((t) => t.done).toList();
    final overdue = open.where(_todoIsOverdue).toList();
    final today =
        open.where((t) => !_todoIsOverdue(t) && _todoIsToday(t)).toList();
    final scheduled = open
        .where((t) =>
            !_todoIsOverdue(t) && !_todoIsToday(t) && _todoHasSchedule(t))
        .toList();
    final backlog = open
        .where((t) =>
            !_todoIsOverdue(t) && !_todoIsToday(t) && !_todoHasSchedule(t))
        .toList();
    final hasQuery = _todoSearch.text.trim().isNotEmpty;
    final noResult =
        open.isEmpty && done.isEmpty && (_todos.isNotEmpty || hasQuery);
    final showAllDone = hasQuery || done.length <= 8;
    final doneVisible = showAllDone ? done : done.take(8).toList();
    final totalMatches = open.length + done.length;

    final searchField = TextField(
      controller: _todoSearch,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: "Search tasks",
        suffixIcon: _todoSearch.text.trim().isEmpty
            ? null
            : IconButton(
                tooltip: "Clear",
                onPressed: () => setState(() => _todoSearch.clear()),
                icon: const Icon(Icons.close),
              ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              searchField,
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _plannerMetaBadge(
                    context,
                    icon: Icons.search_outlined,
                    label: hasQuery
                        ? "$totalMatches result${totalMatches == 1 ? "" : "s"}"
                        : "Search by task or date",
                  ),
                  if (hasQuery)
                    _plannerMetaBadge(
                      context,
                      icon: Icons.filter_alt_outlined,
                      label: _todoSearch.text.trim(),
                      tint: scheme.primary,
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: RecorderTokens.space2),
        if (_todos.isEmpty)
          Text(
            "No tasks yet.",
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          )
        else if (noResult)
          Text(
            "No matching tasks.",
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          )
        else ...[
          if (overdue.isNotEmpty)
            _todoSectionCard(
              context,
              title: "Overdue",
              todos: overdue,
              accent: scheme.error,
              note: "Tasks whose day or time has already passed.",
            ),
          if (today.isNotEmpty)
            _todoSectionCard(
              context,
              title: "Today",
              todos: today,
              accent: scheme.primary,
              note: "Open tasks that belong to today.",
            ),
          if (scheduled.isNotEmpty)
            _todoSectionCard(
              context,
              title: "Upcoming",
              todos: scheduled,
              accent: scheme.secondary,
              note: "Scheduled tasks that are still ahead.",
            ),
          if (backlog.isNotEmpty)
            _todoSectionCard(
              context,
              title: "Backlog",
              todos: backlog,
              accent: scheme.tertiary,
              note: "Tasks without a concrete time block yet.",
            ),
          if (done.isNotEmpty) ...[
            _todoSectionCard(
              context,
              title: "Done",
              todos: doneVisible,
              accent: scheme.onSurfaceVariant,
              note: showAllDone
                  ? "Completed tasks."
                  : "Showing ${doneVisible.length} of ${done.length} completed tasks.",
            ),
          ],
        ],
      ],
    );
  }

  Widget _todoCalendarDimension(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hourHeight = _weekCalendarHourHeight(context);
    final calendarCanvas = _todoCalendarView == _TodoCalendarView.week
        ? _todoWeekView(
            context,
            _todoAnchorDay,
            hourHeight: hourHeight,
          )
        : _todoMonthView(context, _todoAnchorDay);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
          ),
          padding: const EdgeInsets.all(RecorderTokens.space4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 920;
              final calendarModeSwitch = SegmentedButton<_TodoCalendarView>(
                segments: const [
                  ButtonSegment(
                      value: _TodoCalendarView.week, label: Text("Week")),
                  ButtonSegment(
                      value: _TodoCalendarView.month, label: Text("Month")),
                ],
                selected: {_todoCalendarView},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() {
                  _resetPlannerDragDraft();
                  _todoCalendarView = s.first;
                }),
              );
              final titleBlock = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Calendar",
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _plannerCalendarHint(),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              );
              final rangeNavigator = SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: "Previous",
                      onPressed: _todoBusy ? null : () => _shiftTodoRange(-1),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Text(
                      _todoRangeLabel(),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    IconButton(
                      tooltip: "Next",
                      onPressed: _todoBusy ? null : () => _shiftTodoRange(1),
                      icon: const Icon(Icons.chevron_right),
                    ),
                    TextButton(
                      onPressed: _todoBusy ? null : _jumpPlannerToToday,
                      child: const Text("Today"),
                    ),
                  ],
                ),
              );
              final addButton = FilledButton.icon(
                onPressed: _todoBusy
                    ? null
                    : () => _openTodoEditor(
                          suggestedDay: _todoAnchorDay,
                          forceSchedule:
                              _todoCalendarView == _TodoCalendarView.week,
                        ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text("New task"),
              );

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    titleBlock,
                    const SizedBox(height: RecorderTokens.space3),
                    calendarModeSwitch,
                    const SizedBox(height: RecorderTokens.space2),
                    rangeNavigator,
                    const SizedBox(height: RecorderTokens.space2),
                    addButton,
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: titleBlock),
                      const SizedBox(width: RecorderTokens.space3),
                      Flexible(child: calendarModeSwitch),
                    ],
                  ),
                  const SizedBox(height: RecorderTokens.space3),
                  Row(
                    children: [
                      Expanded(child: rangeNavigator),
                      const SizedBox(width: RecorderTokens.space2),
                      addButton,
                    ],
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: RecorderTokens.space2),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 1180) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: calendarCanvas),
                  const SizedBox(width: RecorderTokens.space3),
                  SizedBox(
                    width: 320,
                    child: _calendarFocusDayCard(context),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                calendarCanvas,
                const SizedBox(height: RecorderTokens.space2),
                _calendarFocusDayCard(context),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _todoPlannerSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mainPanel = _plannerDimension == _PlannerDimension.todo
        ? _todoListDimension(context)
        : _todoCalendarDimension(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
          ),
          padding: const EdgeInsets.all(RecorderTokens.space4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final modeSwitch = SegmentedButton<_PlannerDimension>(
                    segments: const [
                      ButtonSegment(
                        value: _PlannerDimension.todo,
                        icon: Icon(Icons.checklist_outlined),
                        label: Text("Tasks"),
                      ),
                      ButtonSegment(
                        value: _PlannerDimension.calendar,
                        icon: Icon(Icons.calendar_month_outlined),
                        label: Text("Calendar"),
                      ),
                    ],
                    selected: {_plannerDimension},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        setState(() => _plannerDimension = s.first),
                  );
                  final newTodoButton = FilledButton.icon(
                    onPressed: _todoBusy ? null : () => _openTodoEditor(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text("New task"),
                  );
                  final todayButton = OutlinedButton.icon(
                    onPressed: _todoBusy ? null : _jumpPlannerToToday,
                    icon: const Icon(Icons.today_outlined, size: 18),
                    label: const Text("Today"),
                  );
                  final titleBlock = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Planner",
                        style:
                            Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _plannerSubtitleText(),
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      if (_lastRefreshedAt != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _updatedAgoText(_lastRefreshedAt),
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  );

                  if (constraints.maxWidth < 840) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: titleBlock),
                            const SizedBox(width: RecorderTokens.space2),
                            todayButton,
                            const SizedBox(width: RecorderTokens.space2),
                            newTodoButton,
                          ],
                        ),
                        const SizedBox(height: RecorderTokens.space2),
                        modeSwitch,
                      ],
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: titleBlock),
                      modeSwitch,
                      const SizedBox(width: RecorderTokens.space2),
                      todayButton,
                      const SizedBox(width: RecorderTokens.space2),
                      newTodoButton,
                    ],
                  );
                },
              ),
              const SizedBox(height: RecorderTokens.space3),
              _plannerCompactStats(context),
            ],
          ),
        ),
        const SizedBox(height: RecorderTokens.space3),
        mainPanel,
      ],
    );
  }

  Future<void> _openReport(ReportSummary s) async {
    final record = await Navigator.of(context).push<ReportRecord>(
      MaterialPageRoute(
        builder: (_) => _ReportDetailPage(
          client: widget.client,
          summary: s,
          onGenerateDaily: _generateDaily,
          onGenerateWeekly: _generateWeekly,
        ),
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
    final visibleSections = _sectionsForLayer(_reportSettingsLayer);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Reports",
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      "Reports：复盘总结与策略建议（洞察视图）",
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (_lastRefreshedAt != null)
                      Text(
                        _updatedAgoText(_lastRefreshedAt),
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                  ],
                )),
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
                SegmentedButton<_ReportSettingsLayer>(
                  segments: [
                    for (final layer in _ReportSettingsLayer.values)
                      ButtonSegment<_ReportSettingsLayer>(
                        value: layer,
                        icon: Icon(_reportSettingsLayerIcon(layer)),
                        label: Text(_reportSettingsLayerLabel(layer)),
                      ),
                  ],
                  selected: {_reportSettingsLayer},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) {
                    final layer = s.first;
                    final sections = _sectionsForLayer(layer);
                    setState(() {
                      _reportSettingsLayer = layer;
                      _reportSettingsSection = sections.first;
                    });
                  },
                ),
                const SizedBox(height: RecorderTokens.space2),
                Text(
                  _reportSettingsLayerHint(_reportSettingsLayer),
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: RecorderTokens.space2),
                Wrap(
                  spacing: RecorderTokens.space2,
                  runSpacing: RecorderTokens.space1,
                  children: [
                    for (final section in visibleSections)
                      ChoiceChip(
                        avatar: Icon(
                          _reportSettingsSectionIcon(section),
                          size: 16,
                        ),
                        label: Text(_reportSettingsSectionLabel(section)),
                        selected: _reportSettingsSection == section,
                        onSelected: (_) =>
                            setState(() => _reportSettingsSection = section),
                      ),
                  ],
                ),
                const SizedBox(height: RecorderTokens.space2),
                if (_reportSettingsSection ==
                    _ReportSettingsSection.connection) ...[
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
                ],
                if (_reportSettingsSection ==
                    _ReportSettingsSection.automation) ...[
                  Text(
                    "Automation window",
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Set report generation schedule. Core executes this in background.",
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: RecorderTokens.space2),
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
                ],
                if (_reportSettingsSection ==
                    _ReportSettingsSection.planner) ...[
                  Text(
                    "Planner",
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Tasks and calendar in one compact planner view.",
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: RecorderTokens.space2),
                  _todoPlannerSection(context),
                ],
                if (_reportSettingsSection ==
                    _ReportSettingsSection.storage) ...[
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
                if (_reportSettingsSection ==
                    _ReportSettingsSection.prompts) ...[
                  Text(
                    "Prompts (advanced)",
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
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
                        _scheduleSave(delay: const Duration(milliseconds: 200));
                      },
                      icon: const Icon(Icons.restore, size: 18),
                      label: const Text("Reset prompts to default"),
                    ),
                  ),
                ],
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

  Widget _plannerPrimaryCard(BuildContext context) {
    return _todoPlannerSection(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      final unavailableTitle =
          widget.plannerMode ? "Planner unavailable" : "Reports unavailable";
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
            Text(unavailableTitle,
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

    if (widget.plannerMode) {
      return RefreshIndicator(
        onRefresh: () => refresh(silent: true),
        child: ListView(
          padding: const EdgeInsets.all(RecorderTokens.space4),
          children: [
            _plannerPrimaryCard(context),
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

class _ReportDetailPage extends StatelessWidget {
  const _ReportDetailPage({
    required this.client,
    required this.summary,
    required this.onGenerateDaily,
    required this.onGenerateWeekly,
  });

  final CoreClient client;
  final ReportSummary summary;
  final Future<void> Function(DateTime day) onGenerateDaily;
  final Future<void> Function(DateTime weekStart) onGenerateWeekly;

  String _periodText() {
    if (summary.kind == "daily") return summary.periodStart;
    return "${summary.periodStart} ~ ${summary.periodEnd}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Report ${_periodText()}")),
      body: SafeArea(
        child: _ReportDetailSheet(
          client: client,
          summary: summary,
          onGenerateDaily: onGenerateDaily,
          onGenerateWeekly: onGenerateWeekly,
        ),
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

    return Padding(
      padding: EdgeInsets.only(
        left: RecorderTokens.space4,
        right: RecorderTokens.space4,
        bottom:
            RecorderTokens.space4 + MediaQuery.of(context).viewInsets.bottom,
        top: RecorderTokens.space2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
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
                    child: _textPanel(
                      context,
                      out.isEmpty ? "(No output)" : out,
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
                              label: out.isEmpty ? "No output" : "Output ready",
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
                                child: _tabbedContent(context, scheme, tabs),
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
