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

enum _TodoCalendarView { day, week, month }

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
  List<ReportSummary> _reports = const [];

  ReportSettings? _settings;
  String? _effectiveOutputDir;
  String? _defaultDailyPrompt;
  String? _defaultWeeklyPrompt;
  List<ReportTodo> _todos = const [];

  _ReportKindFilter _filter = _ReportKindFilter.daily;
  _TodoCalendarView _todoView = _TodoCalendarView.week;
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
    _todoAnchorDay = _normalizeDay(DateTime.now());
    _calendarTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted || !widget.isActive) return;
      if (_todoView == _TodoCalendarView.week ||
          _todoView == _TodoCalendarView.day) {
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

  String _todoSummaryText() {
    final open = _todos.where((t) => !t.done).length;
    final done = _todos.where((t) => t.done).length;
    if (_todos.isEmpty) return "No TODO yet";
    return "$open open · $done done";
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

  String _todoHourLabel(int hour) => "${hour.toString().padLeft(2, "0")}:00";

  String _todoDayTitle(DateTime day) {
    const wd = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    final d = _normalizeDay(day);
    final m = d.month.toString().padLeft(2, "0");
    final dd = d.day.toString().padLeft(2, "0");
    return "${wd[d.weekday - 1]} $m-$dd";
  }

  String _todoRangeLabel() {
    if (_todoView == _TodoCalendarView.day) {
      return _dateLocal(_todoAnchorDay);
    }
    if (_todoView == _TodoCalendarView.week) {
      final start = _startOfWeekMonday(_todoAnchorDay);
      final end = start.add(const Duration(days: 6));
      return "${_dateLocal(start)} ~ ${_dateLocal(end)}";
    }
    final month = DateTime(_todoAnchorDay.year, _todoAnchorDay.month, 1);
    return "${month.year}-${month.month.toString().padLeft(2, "0")}";
  }

  void _shiftTodoRange(int step) {
    setState(() {
      _dragTodoId = null;
      _dragOriginDayIndex = null;
      _dragOriginStartMinute = null;
      _dragCurrentDayIndex = null;
      _dragCurrentStartMinute = null;
      _dragDurationMinutes = null;
      _dragStartGlobalPosition = null;
      if (_todoView == _TodoCalendarView.day) {
        _todoAnchorDay = _normalizeDay(
            _todoAnchorDay.add(Duration(days: step.sign == 0 ? 0 : step)));
        return;
      }
      if (_todoView == _TodoCalendarView.week) {
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

  List<ReportTodo> _todosForDay(DateTime day) {
    final d = _normalizeDay(day);
    return _sortTodos(_todos.where((t) => _todoDay(t) == d));
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
      _dragTodoId = null;
      _dragOriginDayIndex = null;
      _dragOriginStartMinute = null;
      _dragCurrentDayIndex = null;
      _dragCurrentStartMinute = null;
      _dragDurationMinutes = null;
      _dragStartGlobalPosition = null;
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
  }) async {
    if (_todoBusy) return;

    final contentController = TextEditingController(text: todo?.content ?? "");
    var done = todo?.done ?? false;
    var day = _normalizeDay(
        suggestedDay ?? (todo != null ? _todoDay(todo) : _todoAnchorDay));
    final existingStartLocal = todo?.startLocal;
    var withSchedule = todo != null && _todoHasSchedule(todo);
    var startTime = withSchedule && existingStartLocal != null
        ? TimeOfDay.fromDateTime(existingStartLocal)
        : const TimeOfDay(hour: 9, minute: 0);
    var durationMinutes = withSchedule ? _todoDurationMinutes(todo) : 60;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(todo == null ? "Add TODO" : "Edit TODO"),
          content: SizedBox(
            width: 520,
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
                    hintText: "Describe a concrete task",
                  ),
                ),
                const SizedBox(height: RecorderTokens.space2),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        "Date: ${_dateLocal(day)}",
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    OutlinedButton.icon(
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
                      icon: const Icon(Icons.calendar_today_outlined, size: 16),
                      label: const Text("Pick date"),
                    ),
                  ],
                ),
                const SizedBox(height: RecorderTokens.space1),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Set time schedule"),
                  value: withSchedule,
                  onChanged: (v) => setLocal(() => withSchedule = v),
                ),
                if (withSchedule) ...[
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await showTimePicker(
                              context: ctx,
                              initialTime: startTime,
                            );
                            if (picked == null) return;
                            setLocal(() => startTime = picked);
                          },
                          icon: const Icon(Icons.schedule_outlined, size: 16),
                          label: Text(
                              "Start ${startTime.hour.toString().padLeft(2, "0")}:${startTime.minute.toString().padLeft(2, "0")}"),
                        ),
                      ),
                      const SizedBox(width: RecorderTokens.space2),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: durationMinutes,
                          decoration: const InputDecoration(
                            labelText: "Duration",
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(value: 15, child: Text("15 min")),
                            DropdownMenuItem(value: 30, child: Text("30 min")),
                            DropdownMenuItem(value: 45, child: Text("45 min")),
                            DropdownMenuItem(value: 60, child: Text("60 min")),
                            DropdownMenuItem(value: 90, child: Text("90 min")),
                            DropdownMenuItem(
                                value: 120, child: Text("120 min")),
                            DropdownMenuItem(
                                value: 180, child: Text("180 min")),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setLocal(() => durationMinutes = v);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: RecorderTokens.space1),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Done"),
                  value: done,
                  onChanged: (v) => setLocal(() => done = v ?? false),
                ),
              ],
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

    setState(() => _todoBusy = true);
    try {
      await widget.client.upsertReportTodo(
        id: todo?.id,
        content: content,
        done: done,
        dueDate: _dateLocal(day),
        startTs: startTs ?? "",
        endTs: endTs ?? "",
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
    final hasSchedule = _todoHasSchedule(todo);
    final startMinute = _todoStartMinute(todo);
    final hh = (startMinute ~/ 60).toString().padLeft(2, "0");
    final mm = (startMinute % 60).toString().padLeft(2, "0");
    final subtitle =
        hasSchedule ? "$hh:$mm · ${_todoDurationMinutes(todo)}m" : "All-day";
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: todo.done
            ? scheme.surfaceContainerHighest
            : scheme.primaryContainer.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  todo.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        decoration: todo.done
                            ? TextDecoration.lineThrough
                            : TextDecoration.none,
                      ),
                ),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: "Edit",
            onPressed: _todoBusy ? null : () => _openTodoEditor(todo: todo),
            icon: const Icon(Icons.edit_outlined, size: 16),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
          IconButton(
            tooltip: todo.done ? "Mark open" : "Mark done",
            onPressed: _todoBusy ? null : () => _toggleTodo(todo, !todo.done),
            icon: Icon(
              todo.done
                  ? Icons.check_circle_outline
                  : Icons.radio_button_unchecked,
              size: 16,
            ),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
          IconButton(
            tooltip: "Delete",
            onPressed: _todoBusy ? null : () => _deleteTodo(todo),
            icon: const Icon(Icons.delete_outline, size: 16),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
        ],
      ),
    );
  }

  Widget _todoDayView(BuildContext context, DateTime day) {
    final todos = _todosForDay(day);
    if (todos.isEmpty) {
      return Center(
        child: Text(
          "No TODO on ${_dateLocal(day)}",
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    final scheduled = todos.where(_todoHasSchedule).toList();
    final unscheduled = todos.where((t) => !_todoHasSchedule(t)).toList();
    const leftAxisWidth = 54.0;
    const hourHeight = 54.0;
    const headerHeight = 8.0;
    final gridHeight = 24 * hourHeight;
    final layouts = _buildScheduledLayoutsForDay(0, scheduled);
    final isToday = _isSameDay(day, DateTime.now());
    final now = DateTime.now();
    final nowMinute = now.hour * 60 + now.minute + now.second / 60.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (scheduled.isNotEmpty)
          Expanded(
            child: SingleChildScrollView(
              child: SizedBox(
                height: headerHeight + gridHeight,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final dayWidth = (constraints.maxWidth - leftAxisWidth)
                        .clamp(180.0, 9999.0);
                    return Stack(
                      children: [
                        for (var slot = 0; slot <= 48; slot++)
                          Positioned(
                            left: leftAxisWidth,
                            right: 0,
                            top: headerHeight + slot * (hourHeight / 2),
                            child: Divider(
                              height: 1,
                              thickness: slot % 2 == 0 ? 1 : 0.7,
                              color: Theme.of(context)
                                  .colorScheme
                                  .outline
                                  .withValues(
                                      alpha: slot % 2 == 0 ? 0.12 : 0.07),
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ),
                        for (final layout in layouts)
                          Builder(
                            builder: (context) {
                              final top = headerHeight +
                                  (layout.startMinute / 60.0) * hourHeight;
                              final height =
                                  ((layout.endMinute - layout.startMinute) /
                                          60.0) *
                                      hourHeight;
                              final columns = layout.columnCount <= 0
                                  ? 1
                                  : layout.columnCount;
                              final innerWidth =
                                  (dayWidth - 8).clamp(40.0, 9999.0);
                              final rawColumnWidth = innerWidth / columns;
                              final eventWidth =
                                  (rawColumnWidth - 4).clamp(36.0, innerWidth);
                              final left = leftAxisWidth +
                                  4 +
                                  rawColumnWidth * layout.columnIndex;
                              final todo = layout.todo;
                              return Positioned(
                                left: left,
                                top: top,
                                width: eventWidth.toDouble(),
                                height: height.clamp(26, 9999),
                                child: InkWell(
                                  onTap: _todoBusy
                                      ? null
                                      : () => _openTodoEditor(todo: todo),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: todo.done
                                          ? Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest
                                          : Theme.of(context)
                                              .colorScheme
                                              .primaryContainer,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outline
                                            .withValues(alpha: 0.18),
                                      ),
                                    ),
                                    padding: const EdgeInsets.all(6),
                                    child: Text(
                                      todo.content,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            decoration: todo.done
                                                ? TextDecoration.lineThrough
                                                : TextDecoration.none,
                                          ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        if (isToday)
                          Positioned(
                            left: leftAxisWidth + 2,
                            right: 2,
                            top: headerHeight + (nowMinute / 60.0) * hourHeight,
                            child: Row(
                              children: [
                                Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.error,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Container(
                                    height: 1.4,
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          )
        else
          Padding(
            padding:
                const EdgeInsets.symmetric(vertical: RecorderTokens.space2),
            child: Text(
              "No scheduled TODO",
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        if (unscheduled.isNotEmpty) ...[
          const SizedBox(height: RecorderTokens.space2),
          Text("Unscheduled", style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          Column(
            children: [
              for (final t in unscheduled) _todoChip(context, t),
            ],
          ),
        ],
      ],
    );
  }

  Widget _todoWeekView(BuildContext context, DateTime day) {
    final start = _startOfWeekMonday(day);
    final days = List.generate(7, (i) => start.add(Duration(days: i)));
    final endExclusive = start.add(const Duration(days: 7));
    final scheduledLayouts = _buildWeekLayouts(start);
    final unscheduled = _sortTodos(
      _todos.where((t) {
        if (_todoHasSchedule(t)) return false;
        final d = _todoDay(t);
        return !d.isBefore(start) && d.isBefore(endExclusive);
      }),
    );

    const leftAxisWidth = 56.0;
    const headerHeight = 38.0;
    const hourHeight = 56.0;
    final gridHeight = 24 * hourHeight;
    final today = _normalizeDay(DateTime.now());
    final now = DateTime.now();
    final todayIndex = (!today.isBefore(start) && today.isBefore(endExclusive))
        ? today.difference(start).inDays
        : -1;
    final nowMinute = now.hour * 60 + now.minute + now.second / 60.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final dayWidth = (((constraints.maxWidth - leftAxisWidth) / 7)
                      .clamp(112.0, 220.0))
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
                            if (_isSameDay(days[i], today))
                              Positioned(
                                left: leftAxisWidth + i * dayWidth,
                                top: 0,
                                width: dayWidth,
                                height: headerHeight + gridHeight,
                                child: Container(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withValues(alpha: 0.045),
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
                                color: Theme.of(context)
                                    .colorScheme
                                    .outline
                                    .withValues(
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
                                color: Theme.of(context)
                                    .colorScheme
                                    .outline
                                    .withValues(alpha: 0.12),
                              ),
                            ),
                          for (var i = 0; i < 7; i++)
                            Positioned(
                              left: leftAxisWidth + i * dayWidth,
                              top: 0,
                              width: dayWidth,
                              height: headerHeight,
                              child: InkWell(
                                onTap: () => setState(() {
                                  _dragTodoId = null;
                                  _dragOriginDayIndex = null;
                                  _dragOriginStartMinute = null;
                                  _dragCurrentDayIndex = null;
                                  _dragCurrentStartMinute = null;
                                  _dragDurationMinutes = null;
                                  _dragStartGlobalPosition = null;
                                  _todoAnchorDay = days[i];
                                  _todoView = _TodoCalendarView.day;
                                }),
                                child: Center(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: _isSameDay(days[i], today)
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primaryContainer
                                              .withValues(alpha: 0.75)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    child: Text(
                                      _todoDayTitle(days[i]),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium
                                          ?.copyWith(
                                            color: _isSameDay(days[i], today)
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .onPrimaryContainer
                                                : null,
                                          ),
                                    ),
                                  ),
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
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
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
                                final columns = isDraggingTodo
                                    ? 1
                                    : (layout.columnCount <= 0
                                        ? 1
                                        : layout.columnCount);
                                final innerWidth =
                                    (dayWidth - 8).clamp(40.0, 9999.0);
                                final rawColumnWidth = innerWidth / columns;
                                final eventWidth = (rawColumnWidth - 4)
                                    .clamp(30.0, innerWidth)
                                    .toDouble();
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
                                  height: height.clamp(24, 9999),
                                  child: GestureDetector(
                                    onTap: _todoBusy
                                        ? null
                                        : () => _openTodoEditor(todo: todo),
                                    onPanStart: _todoBusy
                                        ? null
                                        : (details) => _beginTodoDrag(
                                              todo: todo,
                                              dayIndex: layout.dayIndex,
                                              startMinute: layout.startMinute,
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
                                      opacity: isDraggingTodo ? 0.9 : 1,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: todo.done
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerHighest
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .primaryContainer,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          border: Border.all(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .outline
                                                .withValues(alpha: 0.18),
                                          ),
                                        ),
                                        padding: const EdgeInsets.all(6),
                                        child: Text(
                                          todo.content,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                decoration: todo.done
                                                    ? TextDecoration.lineThrough
                                                    : TextDecoration.none,
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
                                      color:
                                          Theme.of(context).colorScheme.error,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Container(
                                      height: 1.4,
                                      color:
                                          Theme.of(context).colorScheme.error,
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
              );
            },
          ),
        ),
        if (unscheduled.isNotEmpty) ...[
          const SizedBox(height: RecorderTokens.space2),
          Text("Unscheduled", style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Wrap(
            spacing: RecorderTokens.space2,
            runSpacing: RecorderTokens.space2,
            children: [
              for (final t in unscheduled)
                ActionChip(
                  label: Text(
                    t.content,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: _todoBusy ? null : () => _openTodoEditor(todo: t),
                ),
            ],
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
        GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.12,
          ),
          itemCount: cells.length,
          itemBuilder: (context, index) {
            final day = _normalizeDay(cells[index]);
            final inMonth = day.month == anchor.month;
            final list = _sortTodos(byDay[day] ?? const []);
            final openCount = list.where((t) => !t.done).length;
            final doneCount = list.length - openCount;
            final isToday = _isSameDay(day, today);
            return InkWell(
              onTap: () => setState(() {
                _dragTodoId = null;
                _dragOriginDayIndex = null;
                _dragOriginStartMinute = null;
                _dragCurrentDayIndex = null;
                _dragCurrentStartMinute = null;
                _dragDurationMinutes = null;
                _dragStartGlobalPosition = null;
                _todoAnchorDay = day;
                _todoView = _TodoCalendarView.day;
              }),
              child: Container(
                decoration: BoxDecoration(
                  color: isToday
                      ? Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withValues(alpha: 0.35)
                      : null,
                  borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
                  border: Border.all(
                    color: isToday
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.14),
                  ),
                ),
                padding: const EdgeInsets.all(RecorderTokens.space2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      day.day.toString(),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: inMonth
                                ? null
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 4),
                    for (final t in list.take(2))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          "• ${t.content}",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    if (list.length > 2)
                      Text(
                        "+${list.length - 2}",
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    if (list.isNotEmpty) ...[
                      const Spacer(),
                      Text(
                        "$openCount open · $doneCount done",
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _todoPlannerSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      initiallyExpanded: true,
      title: const Text("TODO planner"),
      subtitle: Text(_todoSummaryText()),
      children: [
        const SizedBox(height: RecorderTokens.space2),
        Row(
          children: [
            Expanded(
              child: SegmentedButton<_TodoCalendarView>(
                segments: const [
                  ButtonSegment(
                      value: _TodoCalendarView.day, label: Text("Day")),
                  ButtonSegment(
                      value: _TodoCalendarView.week, label: Text("Week")),
                  ButtonSegment(
                      value: _TodoCalendarView.month, label: Text("Month")),
                ],
                selected: {_todoView},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() {
                  _dragTodoId = null;
                  _dragOriginDayIndex = null;
                  _dragOriginStartMinute = null;
                  _dragCurrentDayIndex = null;
                  _dragCurrentStartMinute = null;
                  _dragDurationMinutes = null;
                  _dragStartGlobalPosition = null;
                  _todoView = s.first;
                }),
              ),
            ),
            const SizedBox(width: RecorderTokens.space2),
            FilledButton.icon(
              onPressed: _todoBusy ? null : () => _openTodoEditor(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text("Add"),
            ),
          ],
        ),
        if (_todoView == _TodoCalendarView.week) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "Tip: drag a scheduled block to reschedule (snap: 15m).",
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
        const SizedBox(height: RecorderTokens.space2),
        Row(
          children: [
            IconButton(
              tooltip: "Previous",
              onPressed: _todoBusy ? null : () => _shiftTodoRange(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                _todoRangeLabel(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            IconButton(
              tooltip: "Next",
              onPressed: _todoBusy ? null : () => _shiftTodoRange(1),
              icon: const Icon(Icons.chevron_right),
            ),
            const SizedBox(width: RecorderTokens.space1),
            OutlinedButton(
              onPressed: _todoBusy
                  ? null
                  : () => setState(() {
                        _dragTodoId = null;
                        _dragOriginDayIndex = null;
                        _dragOriginStartMinute = null;
                        _dragCurrentDayIndex = null;
                        _dragCurrentStartMinute = null;
                        _dragDurationMinutes = null;
                        _dragStartGlobalPosition = null;
                        _todoAnchorDay = _normalizeDay(DateTime.now());
                      }),
              child: const Text("Today"),
            ),
          ],
        ),
        const SizedBox(height: RecorderTokens.space2),
        if (_todoView == _TodoCalendarView.day)
          SizedBox(height: 420, child: _todoDayView(context, _todoAnchorDay))
        else if (_todoView == _TodoCalendarView.week)
          SizedBox(height: 460, child: _todoWeekView(context, _todoAnchorDay))
        else
          _todoMonthView(context, _todoAnchorDay),
        const SizedBox(height: RecorderTokens.space2),
        if (_todos.isNotEmpty)
          Wrap(
            spacing: RecorderTokens.space2,
            runSpacing: RecorderTokens.space2,
            children: [
              for (final todo
                  in _sortTodos(_todos).where((t) => !t.done).take(6))
                ActionChip(
                  avatar: const Icon(Icons.task_alt_outlined, size: 16),
                  label: Text(
                    todo.content,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed:
                      _todoBusy ? null : () => _openTodoEditor(todo: todo),
                ),
            ],
          )
        else
          Text(
            "Add TODO items with date/time, then reports will focus on guidance instead of activity流水账.",
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
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
                _todoPlannerSection(context),
                const SizedBox(height: RecorderTokens.space2),
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

  Widget _plannerPrimaryCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Planner", style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: RecorderTokens.space1),
            Text(
              "Manage your TODOs in day / week / month calendar views.",
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: RecorderTokens.space3),
            _todoPlannerSection(context),
          ],
        ),
      ),
    );
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
