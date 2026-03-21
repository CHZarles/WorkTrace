import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../api/core_client.dart";
import "../theme/tokens.dart";
import "../utils/format.dart";

class QuickReviewSheet extends StatefulWidget {
  const QuickReviewSheet(
      {super.key, required this.client, required this.block});

  final CoreClient client;
  final BlockSummary block;

  @override
  State<QuickReviewSheet> createState() => _QuickReviewSheetState();
}

class _QuickReviewSheetState extends State<QuickReviewSheet> {
  late final TextEditingController _doing;
  late final TextEditingController _output;
  late final TextEditingController _next;
  bool _saving = false;
  bool _skipSaving = false;
  final Set<String> _tags = {};

  static const _presetTags = [
    "Work",
    "Meeting",
    "Learning",
    "Admin",
    "Life",
    "Entertainment",
  ];

  @override
  void initState() {
    super.initState();
    _doing = TextEditingController(text: widget.block.review?.doing ?? "");
    _output = TextEditingController(text: widget.block.review?.output ?? "");
    _next = TextEditingController(text: widget.block.review?.next ?? "");
    _tags.addAll(widget.block.review?.tags ?? const []);
  }

  @override
  void dispose() {
    _doing.dispose();
    _output.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final doing = _doing.text.trim();
    final output = _output.text.trim();
    final next = _next.text.trim();

    if (doing.isEmpty && output.isEmpty && next.isEmpty && _tags.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Write a quick note, add a tag, or choose Skip.")),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await widget.client.upsertReview(
        ReviewUpsert(
          blockId: widget.block.id,
          skipped: false,
          skipReason: null,
          doing: doing.isEmpty ? null : doing,
          output: output.isEmpty ? null : output,
          next: next.isEmpty ? null : next,
          tags: _tags.toList(),
        ),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Save failed: $e")),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleSkip({required bool skipped}) async {
    setState(() => _skipSaving = true);
    try {
      final r = widget.block.review;
      await widget.client.upsertReview(
        ReviewUpsert(
          blockId: widget.block.id,
          skipped: skipped,
          skipReason: null,
          doing: r?.doing,
          output: r?.output,
          next: r?.next,
          tags: r?.tags ?? const [],
        ),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Action failed: $e")),
      );
    } finally {
      if (mounted) setState(() => _skipSaving = false);
    }
  }

  Widget _summaryPill(
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

  Widget _sectionCard(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
      ),
      padding: const EdgeInsets.all(RecorderTokens.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: RecorderTokens.space3),
          child,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final title =
        "${formatHHMM(widget.block.startTs)}–${formatHHMM(widget.block.endTs)}";
    final top = widget.block.topItems
        .take(3)
        .map((it) => "${displayTopItemName(it)} ${formatDuration(it.seconds)}")
        .join(" · ");
    final skipped = widget.block.review?.skipped == true;

    final allTags = {..._presetTags, ..._tags}.toList();
    allTags.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (_saving || _skipSaving) return;
          _save();
        },
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          if (_saving || _skipSaving) return;
          _save();
        },
      },
      child: Focus(
        autofocus: true,
        child: Padding(
          padding: EdgeInsets.only(
            left: RecorderTokens.space4,
            right: RecorderTokens.space4,
            bottom: bottom + RecorderTokens.space4,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(
                "Quick review",
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: RecorderTokens.space3),
              _sectionCard(
                context,
                title: "Block",
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: RecorderTokens.space2,
                      runSpacing: RecorderTokens.space2,
                      children: [
                        _summaryPill(
                          context,
                          icon: Icons.schedule_outlined,
                          label:
                              "${formatDuration(widget.block.totalSeconds)} · $title",
                        ),
                        _summaryPill(
                          context,
                          icon: skipped
                              ? Icons.skip_next_outlined
                              : Icons.pending_actions_outlined,
                          label: skipped ? "Skipped" : "Open",
                          bgColor: skipped
                              ? scheme.surfaceContainerHigh
                              : scheme.primary.withValues(alpha: 0.10),
                          fgColor: skipped
                              ? scheme.onSurfaceVariant
                              : scheme.primary,
                          borderColor: skipped
                              ? scheme.outline.withValues(alpha: 0.14)
                              : scheme.primary.withValues(alpha: 0.16),
                        ),
                      ],
                    ),
                    if (top.isNotEmpty) ...[
                      const SizedBox(height: RecorderTokens.space3),
                      Text(
                        top,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: RecorderTokens.space3),
              _sectionCard(
                context,
                title: "Review",
                child: Column(
                  children: [
                    TextField(
                      controller: _doing,
                      decoration: const InputDecoration(
                        labelText: "Doing",
                        hintText: "What were you mainly doing?",
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: RecorderTokens.space3),
                    TextField(
                      controller: _output,
                      decoration: const InputDecoration(
                        labelText: "Output / Result",
                        hintText: "What actually got produced or decided?",
                      ),
                      minLines: 2,
                      maxLines: 5,
                    ),
                    const SizedBox(height: RecorderTokens.space3),
                    TextField(
                      controller: _next,
                      decoration: const InputDecoration(
                        labelText: "Next",
                        hintText: "What should happen after this block?",
                      ),
                      minLines: 1,
                      maxLines: 3,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: RecorderTokens.space3),
              _sectionCard(
                context,
                title: "Tags",
                child: Wrap(
                  spacing: RecorderTokens.space2,
                  runSpacing: RecorderTokens.space2,
                  children: [
                    for (final t in allTags)
                      FilterChip(
                        label: Text(t),
                        selected: _tags.contains(t),
                        onSelected: (v) => setState(() {
                          if (v) {
                            _tags.add(t);
                          } else {
                            _tags.remove(t);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: RecorderTokens.space4),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving || _skipSaving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined, size: 18),
                      label: const Text("Save review"),
                    ),
                  ),
                  const SizedBox(width: RecorderTokens.space3),
                  OutlinedButton.icon(
                    onPressed: _saving || _skipSaving
                        ? null
                        : () => _toggleSkip(skipped: !skipped),
                    icon: _skipSaving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            skipped
                                ? Icons.undo_outlined
                                : Icons.skip_next_outlined,
                            size: 18,
                          ),
                    label: Text(skipped ? "Unskip" : "Skip"),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
