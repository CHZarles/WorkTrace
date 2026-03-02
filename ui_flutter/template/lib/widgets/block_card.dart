import "package:flutter/material.dart";

import "../api/core_client.dart";
import "../theme/tokens.dart";
import "../utils/format.dart";
import "recorder_tooltip.dart";

class BlockCardItem {
  const BlockCardItem({
    required this.kind,
    required this.entity,
    required this.label,
    required this.subtitle,
    required this.seconds,
    required this.audio,
  });

  final String kind; // "app" | "domain"
  final String entity;
  final String label;
  final String? subtitle;
  final int seconds;
  final bool audio;
}

class BlockCard extends StatelessWidget {
  const BlockCard({
    super.key,
    required this.block,
    required this.onTap,
    this.previewFocus,
    this.previewAudioTop,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectedChanged,
  });

  final BlockSummary block;
  final VoidCallback onTap;
  final List<BlockCardItem>? previewFocus;
  final BlockCardItem? previewAudioTop;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool>? onSelectedChanged;

  bool _hasReview(BlockReview? r) {
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

  String _preview(BlockReview r) {
    if (r.skipped) {
      final reason = (r.skipReason ?? "").trim();
      return reason.isEmpty ? "Skipped" : "Skipped: $reason";
    }
    final output = (r.output ?? "").trim();
    if (output.isNotEmpty) return output;
    final doing = (r.doing ?? "").trim();
    if (doing.isNotEmpty) return doing;
    final next = (r.next ?? "").trim();
    if (next.isNotEmpty) return next;
    if (r.tags.isNotEmpty) return "Tags: ${r.tags.join(", ")}";
    return "";
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = "${formatHHMM(block.startTs)}–${formatHHMM(block.endTs)}";
    final bg = block.backgroundTopItems;
    final bgTop = bg.isEmpty ? null : bg.first;
    final hasReview = _hasReview(block.review);
    final skipped = block.review?.skipped == true;
    final preview = block.review == null ? "" : _preview(block.review!);

    final (IconData statusIcon, Color statusColor, String statusTip) = skipped
        ? (Icons.skip_next, scheme.onSurfaceVariant, "Skipped")
        : hasReview
            ? (Icons.check_circle, scheme.primary, "Reviewed")
            : (Icons.pending, scheme.onSurfaceVariant, "Needs review");

    IconData iconForItem(BlockCardItem it) {
      if (it.audio) return Icons.headphones;
      if (it.kind == "domain") return Icons.public;
      return Icons.apps_outlined;
    }

    Widget pill(BlockCardItem it) {
      final label = it.label.trim().isEmpty ? "(unknown)" : it.label.trim();
      final duration = formatDuration(it.seconds);
      return RecorderTooltip(
        message: it.subtitle == null
            ? "$label · $duration"
            : "$label\n${it.subtitle}\n$duration",
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: RecorderTokens.space2,
              vertical: RecorderTokens.space1),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: scheme.outline.withValues(alpha: 0.10)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconForItem(it), size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: RecorderTokens.space1),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              const SizedBox(width: RecorderTokens.space1),
              Text(duration, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        ),
      );
    }

    final focusItems =
        (previewFocus ?? const []).where((it) => !it.audio).toList();
    final showFocusItems = focusItems.isNotEmpty;
    final topTextFallback = block.topItems
        .take(3)
        .map((e) => "${displayTopItemName(e)} ${formatDuration(e.seconds)}")
        .join(" · ");

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
        onTap: selectionMode ? () => onSelectedChanged?.call(!selected) : onTap,
        onLongPress: selectionMode ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(RecorderTokens.space4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  RecorderTooltip(
                    message: statusTip,
                    child: Icon(
                      statusIcon,
                      size: 20,
                      color: statusColor,
                    ),
                  ),
                  if (selectionMode) ...[
                    const SizedBox(width: RecorderTokens.space1),
                    Checkbox(
                      value: selected,
                      onChanged: (v) => onSelectedChanged?.call(v ?? false),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: RecorderTokens.space2),
              if (showFocusItems)
                Wrap(
                  spacing: RecorderTokens.space2,
                  runSpacing: RecorderTokens.space2,
                  children: [
                    for (final it in focusItems.take(4)) pill(it),
                  ],
                )
              else
                Text(topTextFallback,
                    style: Theme.of(context).textTheme.bodyMedium),
              if (previewAudioTop == null && bgTop != null) ...[
                const SizedBox(height: RecorderTokens.space2),
                Row(
                  children: [
                    Icon(Icons.headphones,
                        size: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: RecorderTokens.space1),
                    Expanded(
                      child: Text(
                        "${displayTopItemName(bgTop)} ${formatDuration(bgTop.seconds)}",
                        style: Theme.of(context).textTheme.labelMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              if (previewAudioTop != null) ...[
                const SizedBox(height: RecorderTokens.space2),
                Wrap(
                  spacing: RecorderTokens.space2,
                  runSpacing: RecorderTokens.space2,
                  children: [pill(previewAudioTop!)],
                ),
              ],
              if (hasReview) ...[
                const SizedBox(height: RecorderTokens.space2),
                Text(
                  preview,
                  style: Theme.of(context).textTheme.bodyLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
