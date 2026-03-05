import "dart:async";

import "package:flutter/material.dart";

import "../api/core_client.dart";
import "block_detail_page.dart";
import "../theme/tokens.dart";
import "../utils/format.dart";
import "../widgets/block_card.dart";
import "../widgets/quick_review_sheet.dart";

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

  _BlockStatusFilter _statusFilter = _BlockStatusFilter.all;

  bool _loading = false;
  bool _refreshing = false;
  Completer<void>? _loadCompleter;
  String? _error;
  DateTime? _lastRefreshedAt;
  DateTime _day = DateTime.now();
  List<BlockSummary> _blocks = const [];
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
      final blocks = await widget.client.blocksToday(
        date: _dateLocal(_day),
        tzOffsetMinutes: tzOffsetMinutes,
      );
      final previews = _buildPreviewsFromBlocks(blocks: blocks);
      if (!mounted) return;
      final blockById = <String, BlockSummary>{
        for (final b in blocks) b.id: b,
      };
      setState(() {
        _blocks = blocks;
        _previewFocusByBlockId
          ..clear()
          ..addAll(previews.focus);
        _previewAudioTopByBlockId
          ..clear()
          ..addAll(previews.audioTop);
        _selectedPendingBlockIds.removeWhere((id) {
          final b = blockById[id];
          if (b == null) return true;
          return _isReviewed(b);
        });
        if (_selectedPendingBlockIds.isEmpty) {
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
    if (d.inSeconds < 60) return "已更新 ${d.inSeconds}s 前";
    if (d.inMinutes < 60) return "已更新 ${d.inMinutes}m 前";
    if (d.inHours < 24) return "已更新 ${d.inHours}h 前";
    return "已更新 ${d.inDays}d 前";
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

    // Prefer the day inferred from block_id (block_id == start_ts RFC3339).
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

  List<BlockSummary> _filteredBlocks() {
    Iterable<BlockSummary> out = _blocks;
    switch (_statusFilter) {
      case _BlockStatusFilter.all:
        break;
      case _BlockStatusFilter.pending:
        out = out.where((b) => !_isReviewed(b));
        break;
      case _BlockStatusFilter.reviewed:
        out = out.where(_isReviewed);
        break;
      case _BlockStatusFilter.skipped:
        out = out.where((b) => b.review?.skipped == true);
        break;
    }

    final q = _queryController.text;
    if (q.trim().isEmpty) return out.toList();
    return out.where((b) => _matches(b, q)).toList();
  }

  List<BlockSummary> _selectedPendingBlocks() {
    final selectedIds = _selectedPendingBlockIds;
    if (selectedIds.isEmpty) return const [];
    return _blocks
        .where((b) => selectedIds.contains(b.id) && !_isReviewed(b))
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
    if (_isReviewed(b)) return;
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
      title: "Batch tag pending blocks",
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
              ? "Tagged $success pending blocks"
              : "Tagged $success blocks, failed $failed",
        ),
      ),
    );
  }

  Future<void> _batchSkip() async {
    final targets = _selectedPendingBlocks();
    if (targets.isEmpty || _batchBusy) return;

    final reason = await _askTextInput(
      title: "Batch skip pending blocks",
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
              ? "Skipped $success pending blocks"
              : "Skipped $success blocks, failed $failed",
        ),
      ),
    );
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

  Widget _searchHeader(
    BuildContext context,
    int results,
    int total,
    List<BlockSummary> filtered,
  ) {
    final date = _dateLocal(_day);
    final isWide = MediaQuery.of(context).size.width >= 720;

    final field = TextField(
      controller: _queryController,
      decoration: InputDecoration(
        hintText: "Search apps/domains/notes/tags…",
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _queryController.text.trim().isEmpty
            ? null
            : IconButton(
                tooltip: "Clear",
                onPressed: () => setState(() => _queryController.text = ""),
                icon: const Icon(Icons.clear),
              ),
      ),
      onChanged: (_) => setState(() {}),
    );

    final dateBtn = OutlinedButton.icon(
      onPressed: _pickDate,
      icon: const Icon(Icons.calendar_today_outlined, size: 18),
      label: Text(date),
    );

    final metaText = _lastRefreshedAt == null
        ? "$results / $total blocks"
        : "$results / $total blocks · ${_updatedAgoText(_lastRefreshedAt)}";
    final meta = Text(metaText, style: Theme.of(context).textTheme.labelMedium);

    final filter = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<_BlockStatusFilter>(
        segments: const [
          ButtonSegment(value: _BlockStatusFilter.all, label: Text("All")),
          ButtonSegment(
              value: _BlockStatusFilter.pending, label: Text("Pending")),
          ButtonSegment(
              value: _BlockStatusFilter.reviewed, label: Text("Reviewed")),
          ButtonSegment(
              value: _BlockStatusFilter.skipped, label: Text("Skipped")),
        ],
        selected: {_statusFilter},
        showSelectedIcon: false,
        onSelectionChanged: (v) => setState(() {
          _statusFilter = v.first;
          if (_statusFilter != _BlockStatusFilter.pending) {
            _batchMode = false;
            _selectedPendingBlockIds.clear();
          }
        }),
      ),
    );

    final pendingVisible = filtered.where((b) => !_isReviewed(b)).toList();
    final pendingVisibleIds = pendingVisible.map((b) => b.id).toSet();
    final selectedVisibleCount = _selectedPendingBlockIds
        .where((id) => pendingVisibleIds.contains(id))
        .length;
    final selectedTotalCount = _selectedPendingBlockIds.length;

    final Widget batchBar = (_statusFilter == _BlockStatusFilter.pending)
        ? Wrap(
            spacing: RecorderTokens.space2,
            runSpacing: RecorderTokens.space2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: !_batchMode
                ? [
                    OutlinedButton.icon(
                      onPressed: pendingVisible.isEmpty
                          ? null
                          : () => _setBatchMode(true),
                      icon: const Icon(Icons.checklist_rtl, size: 18),
                      label: const Text("Batch actions"),
                    ),
                  ]
                : [
                    Chip(
                      avatar: _batchBusy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.checklist, size: 16),
                      label: Text("$selectedTotalCount selected"),
                    ),
                    OutlinedButton(
                      onPressed: _batchBusy || pendingVisible.isEmpty
                          ? null
                          : () => setState(() {
                                if (selectedVisibleCount ==
                                    pendingVisible.length) {
                                  _selectedPendingBlockIds
                                      .removeWhere(pendingVisibleIds.contains);
                                } else {
                                  _selectedPendingBlockIds
                                      .addAll(pendingVisibleIds);
                                }
                              }),
                      child: Text(
                        selectedVisibleCount == pendingVisible.length &&
                                pendingVisible.isNotEmpty
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
                      icon: const Icon(Icons.skip_next, size: 18),
                      label: const Text("Batch skip"),
                    ),
                    TextButton(
                      onPressed: _batchBusy ? null : () => _setBatchMode(false),
                      child: const Text("Cancel"),
                    ),
                  ],
          )
        : const SizedBox.shrink();

    final Widget content = isWide
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Quick Review",
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: RecorderTokens.space1),
              Text(
                "Filter pending blocks, then review or batch tag/skip.",
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: RecorderTokens.space3),
              Row(
                children: [
                  Expanded(child: field),
                  const SizedBox(width: RecorderTokens.space3),
                  dateBtn,
                ],
              ),
              const SizedBox(height: RecorderTokens.space2),
              Row(
                children: [
                  Expanded(child: meta),
                  const SizedBox(width: RecorderTokens.space3),
                  filter,
                ],
              ),
              if (_statusFilter == _BlockStatusFilter.pending) ...[
                const SizedBox(height: RecorderTokens.space2),
                batchBar,
              ],
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Quick Review",
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: RecorderTokens.space1),
              Text(
                "Filter pending blocks, then review or batch tag/skip.",
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: RecorderTokens.space3),
              field,
              const SizedBox(height: RecorderTokens.space2),
              Row(
                children: [
                  dateBtn,
                  const SizedBox(width: RecorderTokens.space3),
                  meta,
                ],
              ),
              const SizedBox(height: RecorderTokens.space2),
              filter,
              if (_statusFilter == _BlockStatusFilter.pending) ...[
                const SizedBox(height: RecorderTokens.space2),
                batchBar,
              ],
            ],
          );

    return Container(
      key: widget.tutorialHeaderKey,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(RecorderTokens.space3),
          child: content,
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
      return Padding(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Review unavailable",
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: RecorderTokens.space2),
            Text("Server URL: ${widget.serverUrl}",
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: RecorderTokens.space2),
            Text("Error: $msg", style: Theme.of(context).textTheme.labelMedium),
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

    final filtered = _filteredBlocks().reversed.toList();

    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView.separated(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        itemCount: filtered.length + 1,
        separatorBuilder: (_, __) =>
            const SizedBox(height: RecorderTokens.space3),
        itemBuilder: (context, i) {
          if (i == 0) {
            return _searchHeader(
              context,
              filtered.length,
              _blocks.length,
              filtered,
            );
          }
          final block = filtered[i - 1];
          final pending = !_isReviewed(block);
          final selectionMode =
              _batchMode && _statusFilter == _BlockStatusFilter.pending;
          return BlockCard(
            block: block,
            onTap: () => _openBlock(block),
            previewFocus: _previewFocusByBlockId[block.id],
            previewAudioTop: _previewAudioTopByBlockId[block.id],
            selectionMode: selectionMode && pending,
            selected: _selectedPendingBlockIds.contains(block.id),
            onSelectedChanged: selectionMode && pending
                ? (v) => _togglePendingSelection(block, v)
                : null,
          );
        },
      ),
    );
  }
}

enum _BlockStatusFilter { all, pending, reviewed, skipped }
