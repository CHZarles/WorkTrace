import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../api/core_client.dart";
import "../theme/tokens.dart";

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.client,
    required this.serverUrl,
    required this.onServerUrlChanged,
  });

  final CoreClient client;
  final String serverUrl;
  final Future<void> Function(String url) onServerUrlChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _dateLocal;
  late final TextEditingController _blockMinutes;
  late final TextEditingController _idleCutoffMinutes;

  bool _healthLoading = false;
  bool? _healthOk;
  String? _healthError;

  bool _coreSettingsLoading = false;
  bool _coreSettingsSaving = false;
  String? _coreSettingsError;
  CoreSettings? _coreSettings;

  bool _rulesLoading = false;
  String? _rulesError;
  List<PrivacyRule> _rules = const [];

  bool _eventsLoading = false;
  String? _eventsError;
  List<EventRecord> _events = const [];

  bool _deleteDayLoading = false;

  @override
  void initState() {
    super.initState();
    _dateLocal = TextEditingController(text: _todayLocal());
    _blockMinutes = TextEditingController(text: "45");
    _idleCutoffMinutes = TextEditingController(text: "5");
    _refreshAll();
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverUrl != widget.serverUrl) {
      _refreshAll();
    }
  }

  @override
  void dispose() {
    _dateLocal.dispose();
    _blockMinutes.dispose();
    _idleCutoffMinutes.dispose();
    super.dispose();
  }

  String _todayLocal() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, "0");
    final m = now.month.toString().padLeft(2, "0");
    final d = now.day.toString().padLeft(2, "0");
    return "$y-$m-$d";
  }

  Future<void> _refreshAll() async {
    await Future.wait([_checkHealth(), _loadCoreSettings(), _loadRules(), _loadEvents()]);
  }

  Future<void> _checkHealth() async {
    setState(() {
      _healthLoading = true;
      _healthError = null;
    });
    try {
      final ok = await widget.client.health();
      if (!mounted) return;
      setState(() {
        _healthOk = ok;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _healthOk = false;
        _healthError = e.toString();
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
        _idleCutoffMinutes.text = _minsFromSeconds(s.idleCutoffSeconds).toString();
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Invalid block minutes")));
      return;
    }
    if (idleMin == null || idleMin < 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Invalid idle cutoff minutes")));
      return;
    }

    setState(() {
      _coreSettingsSaving = true;
      _coreSettingsError = null;
    });

    try {
      final s = await widget.client.updateSettings(
        blockSeconds: blockMin * 60,
        idleCutoffSeconds: idleMin * 60,
      );
      if (!mounted) return;
      setState(() => _coreSettings = s);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Settings saved")));
    } catch (e) {
      if (!mounted) return;
      setState(() => _coreSettingsError = e.toString());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Save failed: $e")));
    } finally {
      if (mounted) setState(() => _coreSettingsSaving = false);
    }
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

  Future<void> _editServerUrl() async {
    final controller = TextEditingController(text: widget.serverUrl);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Server URL"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: "http://127.0.0.1:17600",
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
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
                value: kind,
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
                value: action,
                decoration: const InputDecoration(labelText: "Action"),
                items: const [
                  DropdownMenuItem(value: "drop", child: Text("Drop (do not store)")),
                  DropdownMenuItem(value: "mask", child: Text("Mask (store as __hidden__)")),
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
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Rule saved")));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Save failed: $e")));
    }
  }

  Future<void> _deleteRule(PrivacyRule rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete rule?"),
        content: Text("${rule.kind}: ${rule.value}\nAction: ${rule.action}"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Rule deleted")));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Delete failed: $e")));
    }
  }

  Future<void> _deleteDayData() async {
    final date = _dateLocal.text.trim();
    if (date.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete this day?"),
        content: Text("This will delete all events and reviews for:\n$date\n\nThis cannot be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
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
        SnackBar(content: Text("Deleted ${res.eventsDeleted} events, ${res.reviewsDeleted} reviews")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Delete failed: $e")));
    } finally {
      if (mounted) setState(() => _deleteDayLoading = false);
    }
  }

  Future<void> _showTextExport({required String title, required Future<String> Function() load}) async {
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
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Copied to clipboard")));
              },
              child: const Text("Copy"),
            ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close")),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Export failed: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final healthText = _healthLoading
        ? "Checking…"
        : _healthOk == true
            ? "OK"
            : "Error";

    final healthColor = _healthOk == true
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;

    return ListView(
      padding: const EdgeInsets.all(RecorderTokens.space4),
      children: [
        Text("Server", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: RecorderTokens.space3),
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
                          "Health: $healthText",
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: healthColor),
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
                                FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close")),
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
              ],
            ),
          ),
        ),
        const SizedBox(height: RecorderTokens.space6),
        Text("Core settings", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: RecorderTokens.space3),
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
                      helperText: "Changing this affects how blocks are segmented (including history).",
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
                  if (_coreSettingsError != null) ...[
                    const SizedBox(height: RecorderTokens.space3),
                    Text("Load/save error: $_coreSettingsError"),
                  ],
                  const SizedBox(height: RecorderTokens.space4),
                  FilledButton.icon(
                    onPressed: _coreSettingsSaving ? null : _saveCoreSettings,
                    icon: const Icon(Icons.save_outlined),
                    label: _coreSettingsSaving ? const Text("Saving…") : const Text("Save"),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: RecorderTokens.space6),
        Row(
          children: [
            Expanded(child: Text("Privacy rules", style: Theme.of(context).textTheme.titleMedium)),
            FilledButton.icon(onPressed: _addRule, icon: const Icon(Icons.add), label: const Text("Add")),
          ],
        ),
        const SizedBox(height: RecorderTokens.space3),
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
                    child: Text("No rules yet. Add a domain/app to drop or mask."),
                  )
                else
                  ..._rules.map(
                    (r) => ListTile(
                      dense: true,
                      title: Text("${r.kind}: ${r.value}"),
                      subtitle: Text("Action: ${r.action}"),
                      trailing: IconButton(
                        onPressed: () => _deleteRule(r),
                        tooltip: "Delete",
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: RecorderTokens.space6),
        Row(
          children: [
            Expanded(child: Text("Recent events", style: Theme.of(context).textTheme.titleMedium)),
            OutlinedButton.icon(
              onPressed: _eventsLoading ? null : _loadEvents,
              icon: const Icon(Icons.refresh),
              label: const Text("Refresh"),
            ),
          ],
        ),
        const SizedBox(height: RecorderTokens.space3),
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
                    child: Text("No events yet. Install the extension / run collectors, then switch apps or tabs."),
                  )
                else
                  ..._events.take(20).map((e) {
                    final entity = e.entity ?? "(no entity)";
                    final meta = "${_hhmm(e.ts)} · ${e.source} · ${e.event}";
                    return ListTile(
                      dense: true,
                      title: Text(entity, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        onPressed: e.entity == null
                            ? null
                            : () async {
                                await Clipboard.setData(ClipboardData(text: e.entity!));
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text("Copied entity to clipboard")),
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
        const SizedBox(height: RecorderTokens.space6),
        Text("Export", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: RecorderTokens.space3),
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
                          tzOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
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
                          tzOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
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
                Text("Danger zone", style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: RecorderTokens.space2),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.errorContainer,
                    foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  onPressed: _deleteDayLoading ? null : _deleteDayData,
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: _deleteDayLoading ? const Text("Deleting…") : const Text("Delete this day"),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
