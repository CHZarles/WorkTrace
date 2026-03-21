import "dart:async";

import "package:flutter/material.dart";

import "../api/core_client.dart";
import "../theme/tokens.dart";
import "../utils/format.dart";
import "../widgets/block_card.dart";
import "../widgets/quick_review_sheet.dart";
import "block_detail_page.dart";

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.client,
    required this.serverUrl,
    this.isActive = false,
    this.tutorialHeaderKey,
  });

  final CoreClient client;
  final String serverUrl;
  final bool isActive;
  final GlobalKey? tutorialHeaderKey;

  @override
  State<SearchScreen> createState() => SearchScreenState();
}

class SearchScreenState extends State<SearchScreen> {
  final _queryController = TextEditingController();

  _ReviewLens _reviewLens = _ReviewLens.queue;

  bool _loading = false;
  bool _refreshing = false;
  Completer<void>? _loadCompleter;
  String? _error;
  DateTime? _lastRefreshedAt;
  DateTime _day = DateTime.now();
  List<BlockSummary> _blocks = const [];
  CoreSettings? _settings;
  String? _dueBlockId;
  final Map<String, List<BlockCardItem>> _previewFocusByBlockId = {};
  final Map<String, BlockCardItem> _previewAudioTopByBlockId = {};
  bool _batchMode = false;
  bool _batchBusy = false;
  final Set<String> _selectedPendingBlockIds = {};

  Timer? _autoRetryTimer;
  int _autoRetryAttempts = 0;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) {
      _load(silent: true);
    }
  }

  @override
  void didUpdateWidget(covariant SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverUrl != widget.serverUrl) {
      _autoRetryTimer?.cancel();
      _autoRetryTimer = null;
      _autoRetryAttempts = 0;
      if (widget.isActive) {
        _load();
      } else if (mounted) {
        setState(() {
          _loading = false;
          _error = null;
          _blocks = const [];
          _settings = null;
          _dueBlockId = null;
          _previewFocusByBlockId.clear();
          _previewAudioTopByBlockId.clear();
          _batchMode = false;
          _batchBusy = false;
          _selectedPendingBlockIds.clear();
        });
      }
      return;
    }
    if (!oldWidget.isActive && widget.isActive) {
      _load(silent: true);
    }
  }

  @override
  void dispose() {
    _autoRetryTimer?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> setDay(DateTime day, {bool refresh = true}) async {
    final next = DateTime(day.year, day.month, day.day);
    if (_day.year == next.year &&
        _day.month == next.month &&
        _day.day == next.day) {
      if (refresh) await _load(silent: true);
      return;
    }
    setState(() => _day = next);
    if (refresh) await _load(silent: true);
  }

  Future<void> applyQuery(String query, {bool refresh = true}) async {
    final q = query.trim();
    if (_queryController.text != q) {
      _queryController.text = q;
    }
    if (mounted) setState(() {});
    if (refresh) {
      await _load(silent: true);
    }
  }

  CoreSettings _fallbackSettings() {
    return CoreSettings(
      blockSeconds: 45 * 60,
      idleCutoffSeconds: 5 * 60,
      storeTitles: false,
      storeExePath: false,
      reviewMinSeconds: 5 * 60,
      reviewNotifyRepeatMinutes: 10,
      reviewNotifyWhenPaused: false,
      reviewNotifyWhenIdle: false,
    );
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

  bool _isSkipped(BlockSummary b) => b.review?.skipped == true;

  bool _isSameCalendarDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isTodaySelectedDay() => _isSameCalendarDay(_day, DateTime.now());

  int _reviewMinSecondsSafe() {
    final s =
        _settings?.reviewMinSeconds ?? _fallbackSettings().reviewMinSeconds;
    return s.clamp(60, 4 * 60 * 60);
  }

  bool _isOptionalBlock(BlockSummary b) {
    if (_isReviewed(b)) return false;
    return b.totalSeconds < _reviewMinSecondsSafe();
  }

  bool _isQueueBlock(BlockSummary b) {
    if (_isReviewed(b)) return false;
    return !_isOptionalBlock(b);
  }

  bool _isDueBlock(BlockSummary b) =>
      _dueBlockId != null && _dueBlockId == b.id;

  String _dateLocal(DateTime d) {
    final y = d.year.toString().padLeft(4, "0");
    final m = d.month.toString().padLeft(2, "0");
    final dd = d.day.toString().padLeft(2, "0");
    return "$y-$m-$dd";
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

  Future<void> refresh({bool silent = false}) async {
    if (_refreshing) {
      await (_loadCompleter?.future ?? Future.value());
    }
    await _load(silent: silent);
  }

  Future<void> _load({bool silent = false}) async {
    if (!widget.isActive && !silent) return;
    if (_refreshing) return;
    _refreshing = true;
    _loadCompleter = Completer<void>();
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

      final tzOffsetMinutes = DateTime.now().timeZoneOffset.inMinutes;
      final blocksFuture = widget.client.blocksToday(
        date: _dateLocal(_day),
        tzOffsetMinutes: tzOffsetMinutes,
      );
      final settingsFuture =
          widget.client.settings().catchError((_) => _fallbackSettings());
      final dueFuture = _isTodaySelectedDay()
          ? widget.client
              .blocksDue(
                date: _dateLocal(_day),
                tzOffsetMinutes: tzOffsetMinutes,
              )
              .catchError((_) => null)
          : Future<BlockSummary?>.value(null);

      final blocks = await blocksFuture;
      final settings = await settingsFuture;
      final due = await dueFuture;
      final previews = _buildPreviewsFromBlocks(blocks: blocks);
      final blockById = <String, BlockSummary>{for (final b in blocks) b.id: b};
      final reviewMinSeconds = settings.reviewMinSeconds.clamp(60, 4 * 60 * 60);

      bool queueByThreshold(BlockSummary b) {
        if (_isReviewed(b)) return false;
        return b.totalSeconds >= reviewMinSeconds;
      }

      if (!mounted) return;
      setState(() {
        _blocks = blocks;
        _settings = settings;
        _dueBlockId = due?.id;
        _previewFocusByBlockId
          ..clear()
          ..addAll(previews.focus);
        _previewAudioTopByBlockId
          ..clear()
          ..addAll(previews.audioTop);
        _selectedPendingBlockIds.removeWhere((id) {
          final b = blockById[id];
          if (b == null) return true;
          return !queueByThreshold(b);
        });
        if (_selectedPendingBlockIds.isEmpty ||
            _reviewLens != _ReviewLens.queue) {
          _batchMode = false;
        }
        _error = null;
        _lastRefreshedAt = DateTime.now();
      });
      _autoRetryAttempts = 0;
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      if (showLoadingUi) setState(() => _error = msg);
      _scheduleAutoRetryIfNeeded(msg);
    } finally {
      if (showLoadingUi && mounted) {
        setState(() => _loading = false);
      }
      _refreshing = false;
      _loadCompleter?.complete();
      _loadCompleter = null;
    }
  }

  String _updatedAgoText(DateTime? t) {
    if (t == null) return "";
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return "Updated ${d.inSeconds}s ago";
    if (d.inMinutes < 60) return "Updated ${d.inMinutes}m ago";
    if (d.inHours < 24) return "Updated ${d.inHours}h ago";
    return "Updated ${d.inDays}d ago";
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
      _load(silent: true);
    });
  }

  ({
    Map<String, List<BlockCardItem>> focus,
    Map<String, BlockCardItem> audioTop
  }) _buildPreviewsFromBlocks({
    required List<BlockSummary> blocks,
  }) {
    String guessKind(String entity) {
      final v = entity.trim();
      if (v.isEmpty) return "app";
      if (v.contains("\\") || v.contains("/") || v.contains(":")) return "app";
      if (!v.contains(".")) return "app";
      if (v.contains(" ")) return "app";
      return "domain";
    }

    String kindForTopItem(TopItem it) {
      return (it.kind == "domain" || it.kind == "app")
          ? it.kind
          : guessKind(it.entity);
    }

    BlockCardItem itemFromTopItem(TopItem it, {required bool audio}) {
      final kind = kindForTopItem(it);
      if (kind == "domain") {
        final domain = it.entity.trim().toLowerCase();
        final rawTitle = (it.title ?? "").trim();
        final title =
            rawTitle.isEmpty ? "" : normalizeWebTitle(domain, rawTitle);
        final label = title.isEmpty ? displayEntity(domain) : title;
        final subtitle = title.isEmpty ? null : displayEntity(domain);
        return BlockCardItem(
          kind: kind,
          entity: domain,
          label: label,
          subtitle: subtitle,
          seconds: it.seconds,
          audio: audio,
        );
      }

      final appEntity = it.entity.trim();
      final appLabel = displayEntity(appEntity);
      String? subtitle;

      final title = (it.title ?? "").trim();
      if (title.isNotEmpty) {
        final labelLc = appLabel.toLowerCase();
        final isVscode = labelLc == "code" ||
            labelLc == "vscode" ||
            title.contains("Visual Studio Code");
        if (isVscode) {
          final ws = extractVscodeWorkspace(title);
          if (ws != null && ws.trim().isNotEmpty) {
            subtitle = "Workspace: ${ws.trim()}";
          }
        }
      }

      return BlockCardItem(
        kind: kind,
        entity: appEntity,
        label: appLabel,
        subtitle: subtitle,
        seconds: it.seconds,
        audio: audio,
      );
    }

    final focus = <String, List<BlockCardItem>>{};
    final audioTop = <String, BlockCardItem>{};

    for (final b in blocks) {
      focus[b.id] = b.topItems
          .take(4)
          .map((it) => itemFromTopItem(it, audio: false))
          .toList();
      if (b.backgroundTopItems.isNotEmpty) {
        audioTop[b.id] =
            itemFromTopItem(b.backgroundTopItems.first, audio: true);
      }
    }

    return (focus: focus, audioTop: audioTop);
  }

  Future<void> openBlockById(String blockId, {bool quick = false}) async {
    final id = blockId.trim();
    if (id.isEmpty) return;

    try {
      final local = DateTime.parse(id).toLocal();
      final nextDay = DateTime(local.year, local.month, local.day);
      if (_day.year != nextDay.year ||
          _day.month != nextDay.month ||
          _day.day != nextDay.day) {
        setState(() => _day = nextDay);
      }
    } catch (_) {
      // ignore
    }

    if (_refreshing) {
      await (_loadCompleter?.future ?? Future.value());
    }
    await _load();

    BlockSummary? found;
    for (final b in _blocks) {
      if (b.id == id) {
        found = b;
        break;
      }
    }

    if (found == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Block not found: $id")),
      );
      return;
    }

    await _openBlock(found, quick: quick);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() => _day = picked);
    await _load();
  }

  bool _matches(BlockSummary b, String q) {
    final target = q.trim().toLowerCase();
    if (target.isEmpty) return true;

    final timeRange =
        "${formatHHMM(b.startTs)}–${formatHHMM(b.endTs)}".toLowerCase();
    if (timeRange.contains(target)) return true;

    for (final it in b.topItems) {
      final name = displayTopItemName(it).toLowerCase();
      if (name.contains(target)) return true;
      if (it.entity.toLowerCase().contains(target)) return true;
      if ((it.title ?? "").toLowerCase().contains(target)) return true;
    }

    final preview = _previewFocusByBlockId[b.id];
    if (preview != null) {
      for (final it in preview) {
        if (it.label.toLowerCase().contains(target)) return true;
        if ((it.subtitle ?? "").toLowerCase().contains(target)) return true;
        if (it.entity.toLowerCase().contains(target)) return true;
      }
    }
    final audio = _previewAudioTopByBlockId[b.id];
    if (audio != null) {
      if (audio.label.toLowerCase().contains(target)) return true;
      if ((audio.subtitle ?? "").toLowerCase().contains(target)) return true;
    }

    final r = b.review;
    if (r != null) {
      final doing = (r.doing ?? "").toLowerCase();
      final output = (r.output ?? "").toLowerCase();
      final next = (r.next ?? "").toLowerCase();
      final reason = (r.skipReason ?? "").toLowerCase();
      if (doing.contains(target) ||
          output.contains(target) ||
          next.contains(target) ||
          reason.contains(target)) {
        return true;
      }
      for (final t in r.tags) {
        if (t.toLowerCase().contains(target)) return true;
      }
    }

    return false;
  }

  List<BlockSummary> _matchedBlocks() {
    final ordered = _blocks.reversed.toList();
    final q = _queryController.text.trim();
    if (q.isEmpty) return ordered;
    return ordered.where((b) => _matches(b, q)).toList();
  }

  _ReviewBuckets _bucketBlocks(Iterable<BlockSummary> blocks) {
    final queue = <BlockSummary>[];
    final optional = <BlockSummary>[];
    final reviewed = <BlockSummary>[];
    final skipped = <BlockSummary>[];

    for (final b in blocks) {
      if (_isSkipped(b)) {
        skipped.add(b);
      } else if (_isReviewed(b)) {
        reviewed.add(b);
      } else if (_isOptionalBlock(b)) {
        optional.add(b);
      } else {
        queue.add(b);
      }
    }

    return _ReviewBuckets(
      queue: queue,
      optional: optional,
      reviewed: reviewed,
      skipped: skipped,
    );
  }

  int _visibleCountForLens(_ReviewBuckets buckets) {
    switch (_reviewLens) {
      case _ReviewLens.queue:
        return buckets.queue.length;
      case _ReviewLens.reviewed:
        return buckets.reviewed.length;
      case _ReviewLens.skipped:
        return buckets.skipped.length;
      case _ReviewLens.all:
        return buckets.total;
    }
  }

  List<BlockSummary> _selectedPendingBlocks() {
    final selectedIds = _selectedPendingBlockIds;
    if (selectedIds.isEmpty) return const [];
    return _blocks
        .where((b) => selectedIds.contains(b.id) && _isQueueBlock(b))
        .toList();
  }

  void _setBatchMode(bool enabled) {
    setState(() {
      _batchMode = enabled;
      if (!enabled) {
        _selectedPendingBlockIds.clear();
      }
    });
  }

  void _togglePendingSelection(BlockSummary b, bool selected) {
    if (!_isQueueBlock(b)) return;
    setState(() {
      if (selected) {
        _selectedPendingBlockIds.add(b.id);
      } else {
        _selectedPendingBlockIds.remove(b.id);
      }
    });
  }

  Future<String?> _askTextInput({
    required String title,
    required String hintText,
    String initialValue = "",
    String confirmText = "Confirm",
    bool allowEmpty = false,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hintText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    controller.dispose();
    final out = value?.trim();
    if (out == null) return null;
    if (!allowEmpty && out.isEmpty) return null;
    return out;
  }

  Future<void> _batchAddTag() async {
    final targets = _selectedPendingBlocks();
    if (targets.isEmpty || _batchBusy) return;
    final tag = await _askTextInput(
      title: "Batch tag review queue",
      hintText: "Tag name (e.g. Work, Meeting)",
      confirmText: "Apply",
    );
    if (tag == null || tag.isEmpty) return;

    setState(() => _batchBusy = true);
    var success = 0;
    var failed = 0;
    for (final b in targets) {
      try {
        final review = b.review;
        final tags = {...(review?.tags ?? const <String>[]), tag}.toList();
        await widget.client.upsertReview(
          ReviewUpsert(
            blockId: b.id,
            skipped: review?.skipped ?? false,
            skipReason: review?.skipReason,
            doing: review?.doing,
            output: review?.output,
            next: review?.next,
            tags: tags,
          ),
        );
        success += 1;
      } catch (_) {
        failed += 1;
      }
    }

    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _batchMode = false;
      _selectedPendingBlockIds.clear();
    });
    await _load(silent: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? "Tagged $success queue blocks"
              : "Tagged $success blocks, failed $failed",
        ),
      ),
    );
  }

  Future<void> _batchSkip() async {
    final targets = _selectedPendingBlocks();
    if (targets.isEmpty || _batchBusy) return;

    final reason = await _askTextInput(
      title: "Skip selected queue blocks",
      hintText: "Optional reason (leave empty to skip without reason)",
      confirmText: "Skip selected",
      allowEmpty: true,
    );
    if (reason == null) return;

    setState(() => _batchBusy = true);
    var success = 0;
    var failed = 0;
    for (final b in targets) {
      try {
        final review = b.review;
        await widget.client.upsertReview(
          ReviewUpsert(
            blockId: b.id,
            skipped: true,
            skipReason: reason.isEmpty ? null : reason,
            doing: review?.doing,
            output: review?.output,
            next: review?.next,
            tags: review?.tags ?? const [],
          ),
        );
        success += 1;
      } catch (_) {
        failed += 1;
      }
    }

    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _batchMode = false;
      _selectedPendingBlockIds.clear();
    });
    await _load(silent: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? "Skipped $success queue blocks"
              : "Skipped $success blocks, failed $failed",
        ),
      ),
    );
  }

  Future<void> _skipBlock(BlockSummary b) async {
    final review = b.review;
    final reason = await _askTextInput(
      title: "Skip this block",
      hintText: "Optional reason",
      initialValue: review?.skipReason ?? "",
      confirmText: "Skip",
      allowEmpty: true,
    );
    if (reason == null) return;

    try {
      await widget.client.upsertReview(
        ReviewUpsert(
          blockId: b.id,
          skipped: true,
          skipReason: reason.isEmpty ? null : reason,
          doing: review?.doing,
          output: review?.output,
          next: review?.next,
          tags: review?.tags ?? const [],
        ),
      );
      if (!mounted) return;
      await _load(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Skipped block")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Skip failed: $e")),
      );
    }
  }

  Future<void> _unskipBlock(BlockSummary b) async {
    final review = b.review;
    try {
      await widget.client.upsertReview(
        ReviewUpsert(
          blockId: b.id,
          skipped: false,
          skipReason: null,
          doing: review?.doing,
          output: review?.output,
          next: review?.next,
          tags: review?.tags ?? const [],
        ),
      );
      if (!mounted) return;
      await _load(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Moved block back to review flow")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Unskip failed: $e")),
      );
    }
  }

  Future<void> _openBlock(BlockSummary b, {bool quick = false}) async {
    final bool? ok;
    if (quick) {
      ok = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => QuickReviewSheet(client: widget.client, block: b),
      );
    } else {
      ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => BlockDetailPage(client: widget.client, block: b),
        ),
      );
    }
    if (ok == true) {
      await _load(silent: true);
    }
  }

  Widget _reviewInfoPill(
    BuildContext context, {
    required IconData icon,
    required String label,
    Color? bgColor,
    Color? fgColor,
    Color? borderColor,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final resolvedBg = bgColor ?? scheme.surface;
    final resolvedFg = fgColor ?? scheme.onSurfaceVariant;
    final resolvedBorder =
        borderColor ?? scheme.outline.withValues(alpha: 0.14);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RecorderTokens.space2,
        vertical: RecorderTokens.space1,
      ),
      decoration: BoxDecoration(
        color: resolvedBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: resolvedBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: resolvedFg),
          const SizedBox(width: 6),
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

  Widget _reviewControlsCard(
    BuildContext context, {
    required _ReviewBuckets matchedBuckets,
    required int visibleCount,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isWide = MediaQuery.of(context).size.width >= 860;
    final queueVisible = matchedBuckets.queue;
    final queueVisibleIds = queueVisible.map((b) => b.id).toSet();
    final selectedVisibleCount = _selectedPendingBlockIds
        .where((id) => queueVisibleIds.contains(id))
        .length;
    final selectedTotalCount = _selectedPendingBlockIds.length;
    final query = _queryController.text.trim();

    final searchField = TextField(
      controller: _queryController,
      decoration: InputDecoration(
        hintText: "Search apps, domains, notes, tags…",
        prefixIcon: const Icon(Icons.search),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                tooltip: "Clear",
                onPressed: () => setState(() => _queryController.text = ""),
                icon: const Icon(Icons.clear),
              ),
      ),
      onChanged: (_) => setState(() {}),
    );

    final dateButton = OutlinedButton.icon(
      onPressed: _pickDate,
      icon: const Icon(Icons.calendar_today_outlined, size: 18),
      label: Text(_dateLocal(_day)),
    );

    final refreshButton = OutlinedButton.icon(
      onPressed: _refreshing ? null : () => _load(silent: true),
      icon: const Icon(Icons.refresh, size: 18),
      label: const Text("Refresh"),
    );

    final filters = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<_ReviewLens>(
        segments: const [
          ButtonSegment(value: _ReviewLens.queue, label: Text("Queue")),
          ButtonSegment(value: _ReviewLens.reviewed, label: Text("Reviewed")),
          ButtonSegment(value: _ReviewLens.skipped, label: Text("Skipped")),
          ButtonSegment(value: _ReviewLens.all, label: Text("All")),
        ],
        selected: {_reviewLens},
        showSelectedIcon: false,
        onSelectionChanged: (v) => setState(() {
          _reviewLens = v.first;
          if (_reviewLens != _ReviewLens.queue) {
            _batchMode = false;
            _selectedPendingBlockIds.clear();
          }
        }),
      ),
    );

    final metaParts = <String>["$visibleCount shown"];
    if (query.isNotEmpty || matchedBuckets.total != _blocks.length) {
      metaParts.add("${matchedBuckets.total}/${_blocks.length} matched");
    }
    if (_lastRefreshedAt != null) {
      metaParts.add(_updatedAgoText(_lastRefreshedAt));
    }

    final meta = Text(
      metaParts.join(" · "),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
    );

    final batchBar = _reviewLens == _ReviewLens.queue
        ? Wrap(
            spacing: RecorderTokens.space2,
            runSpacing: RecorderTokens.space2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: !_batchMode
                ? [
                    OutlinedButton.icon(
                      onPressed: queueVisible.isEmpty
                          ? null
                          : () => _setBatchMode(true),
                      icon: const Icon(Icons.checklist_rtl, size: 18),
                      label: const Text("Batch actions"),
                    ),
                  ]
                : [
                    _reviewInfoPill(
                      context,
                      icon: _batchBusy ? Icons.sync : Icons.checklist,
                      label: "$selectedTotalCount selected",
                    ),
                    OutlinedButton(
                      onPressed: _batchBusy || queueVisible.isEmpty
                          ? null
                          : () => setState(() {
                                if (selectedVisibleCount ==
                                        queueVisible.length &&
                                    queueVisible.isNotEmpty) {
                                  _selectedPendingBlockIds
                                      .removeWhere(queueVisibleIds.contains);
                                } else {
                                  _selectedPendingBlockIds
                                      .addAll(queueVisibleIds);
                                }
                              }),
                      child: Text(
                        selectedVisibleCount == queueVisible.length &&
                                queueVisible.isNotEmpty
                            ? "Clear visible"
                            : "Select visible",
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _batchBusy || selectedTotalCount == 0
                          ? null
                          : _batchAddTag,
                      icon: const Icon(Icons.sell_outlined, size: 18),
                      label: const Text("Batch tag"),
                    ),
                    OutlinedButton.icon(
                      onPressed: _batchBusy || selectedTotalCount == 0
                          ? null
                          : _batchSkip,
                      icon: const Icon(Icons.skip_next_outlined, size: 18),
                      label: const Text("Batch skip"),
                    ),
                    TextButton(
                      onPressed: _batchBusy ? null : () => _setBatchMode(false),
                      child: const Text("Cancel"),
                    ),
                  ],
          )
        : const SizedBox.shrink();

    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Review",
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          _dateLocal(_day),
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
      ],
    );

    final content = isWide
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: titleBlock),
                  const SizedBox(width: RecorderTokens.space2),
                  dateButton,
                  const SizedBox(width: RecorderTokens.space2),
                  refreshButton,
                ],
              ),
              const SizedBox(height: RecorderTokens.space3),
              Row(
                children: [
                  Expanded(child: searchField),
                  const SizedBox(width: RecorderTokens.space3),
                  Flexible(child: filters),
                ],
              ),
              const SizedBox(height: RecorderTokens.space2),
              meta,
              if (_reviewLens == _ReviewLens.queue) ...[
                const SizedBox(height: RecorderTokens.space2),
                batchBar,
              ],
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleBlock,
              const SizedBox(height: RecorderTokens.space2),
              Wrap(
                spacing: RecorderTokens.space2,
                runSpacing: RecorderTokens.space2,
                children: [
                  dateButton,
                  refreshButton,
                ],
              ),
              const SizedBox(height: RecorderTokens.space2),
              searchField,
              const SizedBox(height: RecorderTokens.space2),
              filters,
              const SizedBox(height: RecorderTokens.space2),
              meta,
              if (_reviewLens == _ReviewLens.queue) ...[
                const SizedBox(height: RecorderTokens.space2),
                batchBar,
              ],
            ],
          );

    return Container(
      key: widget.tutorialHeaderKey,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
      ),
      padding: const EdgeInsets.all(RecorderTokens.space3),
      child: content,
    );
  }

  Widget _emptyStateCard(
    BuildContext context, {
    required String title,
    required String body,
    Widget? action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
      ),
      padding: const EdgeInsets.all(RecorderTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: RecorderTokens.space1),
          Text(
            body,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          if (action != null) ...[
            const SizedBox(height: RecorderTokens.space3),
            action,
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(
    BuildContext context, {
    required String title,
    required int count,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        const SizedBox(width: RecorderTokens.space2),
        _reviewInfoPill(
          context,
          icon: Icons.layers_outlined,
          label: "$count",
        ),
      ],
    );
  }

  Widget _buildBlockCard(
    BuildContext context,
    BlockSummary block, {
    required bool selectionEnabled,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final due = _isDueBlock(block);
    final optional = _isOptionalBlock(block);
    final skipped = _isSkipped(block);
    final reviewed = _isReviewed(block) && !skipped;

    String? emphasisLabel;
    IconData? emphasisIcon;
    Color? emphasisColor;

    if (due) {
      emphasisLabel = "Due now";
      emphasisIcon = Icons.bolt_outlined;
      emphasisColor = scheme.primary;
    } else if (optional) {
      emphasisLabel = "Short block";
      emphasisIcon = Icons.timer_outlined;
      emphasisColor = scheme.tertiary;
    } else if (skipped) {
      emphasisLabel = "Skipped";
      emphasisIcon = Icons.skip_next_outlined;
      emphasisColor = scheme.onSurfaceVariant;
    } else if (reviewed) {
      emphasisLabel = "Reviewed";
      emphasisIcon = Icons.check_circle_outline;
      emphasisColor = scheme.primary;
    } else {
      emphasisLabel = "In queue";
      emphasisIcon = Icons.pending_actions_outlined;
      emphasisColor = scheme.primary;
    }

    Widget? footer;
    if (!selectionEnabled) {
      if (skipped) {
        footer = Wrap(
          spacing: RecorderTokens.space2,
          runSpacing: RecorderTokens.space2,
          children: [
            OutlinedButton.icon(
              onPressed: () => _openBlock(block),
              icon: const Icon(Icons.open_in_new_outlined, size: 18),
              label: const Text("Open details"),
            ),
            TextButton.icon(
              onPressed: () => _unskipBlock(block),
              icon: const Icon(Icons.undo_outlined, size: 18),
              label: const Text("Unskip"),
            ),
          ],
        );
      } else if (reviewed) {
        footer = Wrap(
          spacing: RecorderTokens.space2,
          runSpacing: RecorderTokens.space2,
          children: [
            OutlinedButton.icon(
              onPressed: () => _openBlock(block, quick: true),
              icon: const Icon(Icons.edit_note_outlined, size: 18),
              label: const Text("Edit review"),
            ),
            TextButton.icon(
              onPressed: () => _openBlock(block),
              icon: const Icon(Icons.open_in_new_outlined, size: 18),
              label: const Text("Open details"),
            ),
          ],
        );
      } else {
        footer = Wrap(
          spacing: RecorderTokens.space2,
          runSpacing: RecorderTokens.space2,
          children: [
            FilledButton.icon(
              onPressed: () => _openBlock(block, quick: true),
              icon: const Icon(Icons.rate_review_outlined, size: 18),
              label: Text(due ? "Review now" : "Quick review"),
            ),
            OutlinedButton.icon(
              onPressed: () => _openBlock(block),
              icon: const Icon(Icons.open_in_new_outlined, size: 18),
              label: const Text("Open details"),
            ),
            TextButton.icon(
              onPressed: () => _skipBlock(block),
              icon: const Icon(Icons.skip_next_outlined, size: 18),
              label: const Text("Skip"),
            ),
          ],
        );
      }
    }

    return BlockCard(
      block: block,
      onTap: selectionEnabled ? () {} : () => _openBlock(block),
      previewFocus: _previewFocusByBlockId[block.id],
      previewAudioTop: _previewAudioTopByBlockId[block.id],
      selectionMode: selectionEnabled,
      selected: _selectedPendingBlockIds.contains(block.id),
      onSelectedChanged:
          selectionEnabled ? (v) => _togglePendingSelection(block, v) : null,
      emphasisLabel: emphasisLabel,
      emphasisIcon: emphasisIcon,
      emphasisColor: emphasisColor,
      footer: footer,
      highlight: due,
    );
  }

  List<Widget> _buildSectionChildren(
    BuildContext context, {
    required String title,
    required List<BlockSummary> blocks,
    required bool selectionEnabled,
  }) {
    if (blocks.isEmpty) return const [];
    return [
      _sectionHeader(
        context,
        title: title,
        count: blocks.length,
      ),
      const SizedBox(height: RecorderTokens.space2),
      for (var i = 0; i < blocks.length; i++) ...[
        _buildBlockCard(
          context,
          blocks[i],
          selectionEnabled: selectionEnabled,
        ),
        if (i != blocks.length - 1)
          const SizedBox(height: RecorderTokens.space2),
      ],
    ];
  }

  List<Widget> _buildBodySections(
    BuildContext context, {
    required _ReviewBuckets matchedBuckets,
  }) {
    final queryActive = _queryController.text.trim().isNotEmpty;
    final children = <Widget>[];

    void addBlockSection(
      String title,
      List<BlockSummary> blocks, {
      bool selectionEnabled = false,
    }) {
      final section = _buildSectionChildren(
        context,
        title: title,
        blocks: blocks,
        selectionEnabled: selectionEnabled,
      );
      if (section.isEmpty) return;
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: RecorderTokens.space4));
      }
      children.addAll(section);
    }

    switch (_reviewLens) {
      case _ReviewLens.queue:
        addBlockSection(
          "Queue",
          matchedBuckets.queue,
          selectionEnabled: _batchMode,
        );
        if (children.isEmpty) {
          children.add(
            _emptyStateCard(
              context,
              title: "Queue is clear",
              body: queryActive
                  ? "No queue blocks match the current search."
                  : matchedBuckets.optional.isNotEmpty
                      ? "Queue is clear. Short blocks are still available under All."
                      : "No queue blocks for this day.",
            ),
          );
        }
        break;
      case _ReviewLens.reviewed:
        addBlockSection(
          "Reviewed",
          matchedBuckets.reviewed,
        );
        if (children.isEmpty) {
          children.add(
            _emptyStateCard(
              context,
              title: "No reviewed blocks",
              body: queryActive
                  ? "No reviewed blocks match the current search."
                  : "Nothing reviewed for this day.",
            ),
          );
        }
        break;
      case _ReviewLens.skipped:
        addBlockSection(
          "Skipped",
          matchedBuckets.skipped,
        );
        if (children.isEmpty) {
          children.add(
            _emptyStateCard(
              context,
              title: "No skipped blocks",
              body: queryActive
                  ? "No skipped blocks match the current search."
                  : "Nothing skipped for this day.",
            ),
          );
        }
        break;
      case _ReviewLens.all:
        addBlockSection(
          "Queue",
          matchedBuckets.queue,
          selectionEnabled: false,
        );
        addBlockSection(
          "Short blocks",
          matchedBuckets.optional,
        );
        addBlockSection(
          "Reviewed",
          matchedBuckets.reviewed,
        );
        addBlockSection(
          "Skipped",
          matchedBuckets.skipped,
        );
        if (children.isEmpty) {
          children.add(
            _emptyStateCard(
              context,
              title: "Nothing to show",
              body: queryActive
                  ? "No blocks match the current query."
                  : "No blocks were recorded for this day.",
            ),
          );
        }
        break;
    }

    return children;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      final msg = _error ?? "";
      final auto = _serverLooksLikeLocalhost() && _isTransientError(msg);
      return Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Review unavailable",
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: RecorderTokens.space2),
            Text(
              "Server URL: ${widget.serverUrl}",
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: RecorderTokens.space2),
            Text(
              "Error: $msg",
              style: Theme.of(context).textTheme.labelMedium,
            ),
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
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text("Retry"),
            ),
          ],
        ),
      );
    }

    final matched = _matchedBlocks();
    final matchedBuckets = _bucketBlocks(matched);
    final visibleCount = _visibleCountForLens(matchedBuckets);
    final bodySections = _buildBodySections(
      context,
      matchedBuckets: matchedBuckets,
    );

    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        children: [
          _reviewControlsCard(
            context,
            matchedBuckets: matchedBuckets,
            visibleCount: visibleCount,
          ),
          const SizedBox(height: RecorderTokens.space4),
          ...bodySections,
        ],
      ),
    );
  }
}

class _ReviewBuckets {
  const _ReviewBuckets({
    required this.queue,
    required this.optional,
    required this.reviewed,
    required this.skipped,
  });

  final List<BlockSummary> queue;
  final List<BlockSummary> optional;
  final List<BlockSummary> reviewed;
  final List<BlockSummary> skipped;

  int get total =>
      queue.length + optional.length + reviewed.length + skipped.length;
}

enum _ReviewLens { queue, reviewed, skipped, all }
