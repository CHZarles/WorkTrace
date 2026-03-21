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
    this.emphasisLabel,
    this.emphasisIcon,
    this.emphasisColor,
    this.helperText,
    this.footer,
    this.highlight = false,
  });

  final BlockSummary block;
  final VoidCallback onTap;
  final List<BlockCardItem>? previewFocus;
  final BlockCardItem? previewAudioTop;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool>? onSelectedChanged;
  final String? emphasisLabel;
  final IconData? emphasisIcon;
  final Color? emphasisColor;
  final String? helperText;
  final Widget? footer;
  final bool highlight;

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

  Widget _metaPill(
    BuildContext context, {
    required IconData icon,
    required String label,
    Color? bgColor,
    Color? fgColor,
    Color? borderColor,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final resolvedBg = bgColor ?? scheme.surfaceContainerHighest;
    final resolvedFg = fgColor ?? scheme.onSurfaceVariant;
    final resolvedBorder =
        borderColor ?? scheme.outline.withValues(alpha: 0.12);
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = "${formatHHMM(block.startTs)}–${formatHHMM(block.endTs)}";
    final hasReview = _hasReview(block.review);
    final skipped = block.review?.skipped == true;
    final preview = block.review == null ? "" : _preview(block.review!);
    final accent = emphasisColor ??
        (highlight
            ? scheme.primary
            : selected
                ? scheme.primary
                : scheme.outline);
    final cardColor = selected
        ? scheme.primaryContainer.withValues(alpha: 0.22)
        : highlight
            ? scheme.primaryContainer.withValues(alpha: 0.12)
            : scheme.surfaceContainerLowest;
    final borderColor = selected || highlight
        ? accent.withValues(alpha: 0.22)
        : scheme.outline.withValues(alpha: 0.14);

    final (
      IconData statusIcon,
      Color statusColor,
      String statusTip,
      String statusLabel,
    ) = skipped
        ? (
            Icons.skip_next,
            scheme.onSurfaceVariant,
            "Skipped",
            "Skipped",
          )
        : hasReview
            ? (
                Icons.check_circle,
                scheme.primary,
                "Reviewed",
                "Reviewed",
              )
            : (
                Icons.pending_actions_outlined,
                scheme.onSurfaceVariant,
                "Needs review",
                "Needs review",
              );

    IconData iconForItem(BlockCardItem it) {
      if (it.audio) return Icons.headphones;
      if (it.kind == "domain") return Icons.public;
      return Icons.apps_outlined;
    }

    Widget focusPill(BlockCardItem it) {
      final label = it.label.trim().isEmpty ? "(unknown)" : it.label.trim();
      final duration = formatDuration(it.seconds);
      return RecorderTooltip(
        message: it.subtitle == null
            ? "$label · $duration"
            : "$label\n${it.subtitle}\n$duration",
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: RecorderTokens.space2,
            vertical: RecorderTokens.space1,
          ),
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
    final topTextFallback = block.topItems
        .take(3)
        .map((e) => "${displayTopItemName(e)} ${formatDuration(e.seconds)}")
        .join(" · ");

    return Card(
      margin: EdgeInsets.zero,
      color: cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RecorderTokens.radiusL),
        side: BorderSide(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(RecorderTokens.radiusL),
        onTap: selectionMode ? () => onSelectedChanged?.call(!selected) : onTap,
        onLongPress: selectionMode ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(RecorderTokens.space4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: RecorderTokens.space2,
                          runSpacing: RecorderTokens.space2,
                          children: [
                            _metaPill(
                              context,
                              icon: Icons.schedule_outlined,
                              label: formatDuration(block.totalSeconds),
                            ),
                            _metaPill(
                              context,
                              icon: statusIcon,
                              label: statusLabel,
                              bgColor: hasReview
                                  ? scheme.primaryContainer
                                      .withValues(alpha: 0.24)
                                  : scheme.surfaceContainerHighest,
                              fgColor: hasReview ? scheme.primary : statusColor,
                              borderColor: hasReview
                                  ? scheme.primary.withValues(alpha: 0.14)
                                  : scheme.outline.withValues(alpha: 0.12),
                            ),
                            if ((emphasisLabel ?? "").trim().isNotEmpty)
                              _metaPill(
                                context,
                                icon:
                                    emphasisIcon ?? Icons.auto_awesome_outlined,
                                label: emphasisLabel!.trim(),
                                bgColor: accent.withValues(alpha: 0.10),
                                fgColor: accent,
                                borderColor: accent.withValues(alpha: 0.16),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: RecorderTokens.space2),
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
              const SizedBox(height: RecorderTokens.space3),
              if (focusItems.isNotEmpty)
                Wrap(
                  spacing: RecorderTokens.space2,
                  runSpacing: RecorderTokens.space2,
                  children: [
                    for (final it in focusItems.take(4)) focusPill(it),
                  ],
                )
              else
                Text(
                  topTextFallback,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              if (previewAudioTop != null) ...[
                const SizedBox(height: RecorderTokens.space2),
                Wrap(
                  spacing: RecorderTokens.space2,
                  runSpacing: RecorderTokens.space2,
                  children: [focusPill(previewAudioTop!)],
                ),
              ],
              if (preview.isNotEmpty) ...[
                const SizedBox(height: RecorderTokens.space3),
                Text(
                  preview,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if ((helperText ?? "").trim().isNotEmpty) ...[
                const SizedBox(height: RecorderTokens.space2),
                Text(
                  helperText!.trim(),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
              if (footer != null) ...[
                const SizedBox(height: RecorderTokens.space3),
                Divider(
                  height: 1,
                  color: scheme.outline.withValues(alpha: 0.12),
                ),
                const SizedBox(height: RecorderTokens.space3),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
