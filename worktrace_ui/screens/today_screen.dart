import "package:flutter/material.dart";

import "../api/core_client.dart";
import "../theme/tokens.dart";

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key, required this.client, required this.serverUrl});

  final CoreClient client;
  final String serverUrl;

  @override
  State<TodayScreen> createState() => TodayScreenState();
}

class TodayScreenState extends State<TodayScreen> {
  bool _loading = true;
  String? _error;
  List<BlockSummary> _blocks = const [];

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void didUpdateWidget(covariant TodayScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverUrl != widget.serverUrl) {
      refresh();
    }
  }

  String _todayLocal() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, "0");
    final m = now.month.toString().padLeft(2, "0");
    final d = now.day.toString().padLeft(2, "0");
    return "$y-$m-$d";
  }

  Future<void> refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ok = await widget.client.health();
      if (!ok) throw Exception("health_failed");
      final blocks = await widget.client.blocksToday(
        date: _todayLocal(),
        tzOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
      );
      setState(() {
        _blocks = blocks;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _ErrorState(serverUrl: widget.serverUrl, error: _error!, onRetry: refresh);
    }
    if (_blocks.isEmpty) return _EmptyState(serverUrl: widget.serverUrl, onRefresh: refresh);

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.separated(
        padding: const EdgeInsets.all(RecorderTokens.space4),
        itemCount: _blocks.length,
        separatorBuilder: (_, __) => const SizedBox(height: RecorderTokens.space3),
        itemBuilder: (context, i) => _BlockCard(
          block: _blocks[i],
          onReview: () async {
            final ok = await showModalBottomSheet<bool>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => _BlockDetailSheet(client: widget.client, block: _blocks[i]),
            );
            if (ok == true) {
              await refresh();
            }
          },
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.serverUrl, required this.error, required this.onRetry});

  final String serverUrl;
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RecorderTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Cannot reach Core", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: RecorderTokens.space2),
          Text("Server URL: $serverUrl", style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: RecorderTokens.space2),
          Text("Error: $error", style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: RecorderTokens.space4),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text("Retry"),
          ),
          const SizedBox(height: RecorderTokens.space4),
          const Text("Tip: run Core locally:\n  cargo run -p recorder_core -- --listen 127.0.0.1:17600"),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.serverUrl, required this.onRefresh});

  final String serverUrl;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RecorderTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("No blocks yet", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: RecorderTokens.space2),
          Text("Server URL: $serverUrl", style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: RecorderTokens.space4),
          FilledButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text("Refresh"),
          ),
          const SizedBox(height: RecorderTokens.space4),
          const Text("Generate some activity:\n- Run Core\n- Install browser extension\n- Switch tabs a few times"),
        ],
      ),
    );
  }
}

class _BlockCard extends StatelessWidget {
  const _BlockCard({required this.block, required this.onReview});

  final BlockSummary block;
  final VoidCallback onReview;

  String _hhmm(String rfc3339) {
    try {
      final t = DateTime.parse(rfc3339).toLocal();
      final hh = t.hour.toString().padLeft(2, "0");
      final mm = t.minute.toString().padLeft(2, "0");
      return "$hh:$mm";
    } catch (_) {
      final parts = rfc3339.split("T");
      if (parts.length < 2) return "??:??";
      final hhmm = parts[1];
      return hhmm.length >= 5 ? hhmm.substring(0, 5) : "??:??";
    }
  }

  String _dur(int seconds) {
    final m = ((seconds + 30) / 60).floor();
    if (m < 60) return "${m}m";
    final h = (m / 60).floor();
    final rm = m % 60;
    return rm == 0 ? "${h}h" : "${h}h ${rm}m";
  }

  @override
  Widget build(BuildContext context) {
    final title = "${_hhmm(block.startTs)}–${_hhmm(block.endTs)}";
    final top = block.topItems.take(3).map((e) => "${e.name} ${_dur(e.seconds)}").join(" · ");
    final hasReview = block.review != null && ((block.review!.output ?? "").trim().isNotEmpty);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
        onTap: onReview,
        child: Padding(
          padding: const EdgeInsets.all(RecorderTokens.space4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                  ),
                  Text(hasReview ? "✅" : "⏳", style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: RecorderTokens.space2),
              Text(top, style: Theme.of(context).textTheme.bodyMedium),
              if (hasReview) ...[
                const SizedBox(height: RecorderTokens.space2),
                Text(
                  block.review!.output ?? "",
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

class _BlockDetailSheet extends StatefulWidget {
  const _BlockDetailSheet({required this.client, required this.block});

  final CoreClient client;
  final BlockSummary block;

  @override
  State<_BlockDetailSheet> createState() => _BlockDetailSheetState();
}

class _BlockDetailSheetState extends State<_BlockDetailSheet> {
  late final TextEditingController _doing;
  late final TextEditingController _output;
  late final TextEditingController _next;
  bool _saving = false;
  bool _rulesLoading = true;
  final Map<String, int> _ruleIdByKey = {};
  final Set<String> _blockedKeys = {};
  final Set<String> _tags = {};

  static const _presetTags = ["Work", "Meeting", "Learning", "Admin", "Life", "Entertainment"];

  @override
  void initState() {
    super.initState();
    _doing = TextEditingController(text: widget.block.review?.doing ?? "");
    _output = TextEditingController(text: widget.block.review?.output ?? "");
    _next = TextEditingController(text: widget.block.review?.next ?? "");
    _tags.addAll(widget.block.review?.tags ?? const []);
    _loadRules();
  }

  @override
  void dispose() {
    _doing.dispose();
    _output.dispose();
    _next.dispose();
    super.dispose();
  }

  String _dur(int seconds) {
    final m = ((seconds + 30) / 60).floor();
    if (m < 60) return "${m}m";
    final h = (m / 60).floor();
    final rm = m % 60;
    return rm == 0 ? "${h}h" : "${h}h ${rm}m";
  }

  String _ruleKey(String kind, String value) => "$kind|$value";

  bool _isBlocked(TopItem it) {
    final kind = (it.kind == "domain" || it.kind == "app") ? it.kind : _guessKind(it.name);
    final value = kind == "domain" ? it.name.toLowerCase() : it.name;
    return _blockedKeys.contains(_ruleKey(kind, value));
  }

  String _guessKind(String value) {
    final v = value.trim();
    if (v.isEmpty) return "app";
    if (v.contains("\\") || v.contains("/") || v.contains(":")) return "app";
    if (!v.contains(".")) return "app";
    if (v.contains(" ")) return "app";
    return "domain";
  }

  Future<void> _loadRules() async {
    setState(() => _rulesLoading = true);
    try {
      final rules = await widget.client.privacyRules();
      if (!mounted) return;
      setState(() {
        _ruleIdByKey.clear();
        _blockedKeys.clear();
        for (final r in rules) {
          final value = r.kind == "domain" ? r.value.toLowerCase() : r.value;
          final key = _ruleKey(r.kind, value);
          _ruleIdByKey[key] = r.id;
          _blockedKeys.add(key);
        }
      });
    } catch (_) {
      // best effort
    } finally {
      if (mounted) setState(() => _rulesLoading = false);
    }
  }

  Future<void> _blacklist(TopItem it) async {
    final kind = (it.kind == "domain" || it.kind == "app") ? it.kind : _guessKind(it.name);
    final value = kind == "domain" ? it.name.toLowerCase() : it.name;
    final key = _ruleKey(kind, value);

    if (_blockedKeys.contains(key)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Already blacklisted: ${it.name}")),
      );
      return;
    }

    try {
      final rule = await widget.client.upsertPrivacyRule(
        PrivacyRuleUpsert(kind: kind, value: value, action: "drop"),
      );
      if (!mounted) return;
      setState(() {
        _blockedKeys.add(key);
        _ruleIdByKey[key] = rule.id;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Blacklisted: ${it.name}"),
          action: SnackBarAction(
            label: "Undo",
            onPressed: () async {
              final id = _ruleIdByKey[key];
              if (id == null) return;
              try {
                await widget.client.deletePrivacyRule(id);
                if (!mounted) return;
                setState(() {
                  _blockedKeys.remove(key);
                  _ruleIdByKey.remove(key);
                });
              } catch (_) {}
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Blacklist failed: $e")),
      );
    }
  }

  Future<void> _addTag() async {
    final controller = TextEditingController();
    final tag = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Add tag"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: "e.g. Work"),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text("Add"),
          ),
        ],
      ),
    );
    controller.dispose();
    final t = tag?.trim();
    if (t == null || t.isEmpty) return;
    setState(() => _tags.add(t));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.client.upsertReview(
        ReviewUpsert(
          blockId: widget.block.id,
          doing: _doing.text.trim().isEmpty ? null : _doing.text.trim(),
          output: _output.text.trim().isEmpty ? null : _output.text.trim(),
          next: _next.text.trim().isEmpty ? null : _next.text.trim(),
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

  @override
  Widget build(BuildContext context) {
    final top = widget.block.topItems.take(3).map((e) => e.name).join(" · ");
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final maxSeconds = widget.block.topItems.fold<int>(0, (m, it) => it.seconds > m ? it.seconds : m);
    final allTags = {..._presetTags, ..._tags}.toList();
    allTags.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return Padding(
      padding: EdgeInsets.only(
        left: RecorderTokens.space4,
        right: RecorderTokens.space4,
        bottom: bottom + RecorderTokens.space4,
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text("Block details", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: RecorderTokens.space2),
          Text("Top: $top", style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: RecorderTokens.space4),
          Text("Top items", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: RecorderTokens.space2),
          if (widget.block.topItems.isEmpty)
            const Text("No items.")
          else
            ...widget.block.topItems.map((it) {
              final ratio = maxSeconds <= 0 ? 0.0 : (it.seconds / maxSeconds).clamp(0.0, 1.0);
              final blocked = _isBlocked(it);
              return Padding(
                padding: const EdgeInsets.only(bottom: RecorderTokens.space3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            it.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                        const SizedBox(width: RecorderTokens.space2),
                        Text(_dur(it.seconds), style: Theme.of(context).textTheme.labelMedium),
                        const SizedBox(width: RecorderTokens.space1),
                        IconButton(
                          onPressed: blocked || _rulesLoading ? null : () => _blacklist(it),
                          tooltip: blocked ? "Blacklisted" : "Add to blacklist",
                          icon: Icon(blocked ? Icons.block : Icons.block_outlined),
                        ),
                      ],
                    ),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: ratio,
                        minHeight: 10,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
              );
            }),
          const SizedBox(height: RecorderTokens.space4),
          Text("Review", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: RecorderTokens.space3),
          TextField(controller: _doing, decoration: const InputDecoration(labelText: "Doing (optional)")),
          const SizedBox(height: RecorderTokens.space3),
          TextField(controller: _output, decoration: const InputDecoration(labelText: "Output / Result")),
          const SizedBox(height: RecorderTokens.space3),
          TextField(controller: _next, decoration: const InputDecoration(labelText: "Next (optional)")),
          const SizedBox(height: RecorderTokens.space4),
          Row(
            children: [
              Expanded(child: Text("Tags", style: Theme.of(context).textTheme.titleMedium)),
              OutlinedButton.icon(onPressed: _addTag, icon: const Icon(Icons.add), label: const Text("Add")),
            ],
          ),
          const SizedBox(height: RecorderTokens.space2),
          Wrap(
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
          const SizedBox(height: RecorderTokens.space4),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text("Save"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
