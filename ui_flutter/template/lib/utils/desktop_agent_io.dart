import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";

import "desktop_agent.dart";

DesktopAgent getDesktopAgent() => _IoDesktopAgent();

class _HealthInfo {
  const _HealthInfo({required this.ok, this.service, this.version});

  final bool ok;
  final String? service;
  final String? version;
}

class _CoreSettingsLite {
  const _CoreSettingsLite({
    this.idleCutoffSeconds,
    this.reviewNotifyRepeatMinutes,
    this.reviewNotifyWhenPaused,
    this.reviewNotifyWhenIdle,
  });

  final int? idleCutoffSeconds;
  final int? reviewNotifyRepeatMinutes;
  final bool? reviewNotifyWhenPaused;
  final bool? reviewNotifyWhenIdle;
}

class _AgentBinaries {
  const _AgentBinaries({
    required this.mode,
    required this.coreExe,
    required this.collectorExe,
  });

  /// "packaged" | "repo"
  final String mode;
  final String coreExe;
  final String collectorExe;
}

class _IoDesktopAgent implements DesktopAgent {
  @override
  bool get isAvailable => !kIsWeb && Platform.isWindows;

  @override
  Future<String?> findRepoRoot() async {
    if (!isAvailable) return null;

    final roots = <Directory>[];

    final env = Platform.environment["WORKTRACE_REPO_ROOT"];
    if (env != null && env.trim().isNotEmpty) {
      roots.add(Directory(env.trim()));
    }

    roots.add(Directory.current);

    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      roots.add(exeDir);
    } catch (_) {
      // ignore
    }

    bool looksLikeRepoRoot(Directory dir) {
      final runAgent = File("${dir.path}${Platform.pathSeparator}dev${Platform.pathSeparator}run-agent.ps1");
      final cargoToml = File("${dir.path}${Platform.pathSeparator}Cargo.toml");
      return runAgent.existsSync() && cargoToml.existsSync();
    }

    for (final base in roots) {
      var d = base;
      for (var i = 0; i < 10; i++) {
        if (looksLikeRepoRoot(d)) return d.path;
        final parent = d.parent;
        if (parent.path == d.path) break;
        d = parent;
      }
    }

    return null;
  }

  Directory? _appDir() {
    try {
      return File(Platform.resolvedExecutable).parent;
    } catch (_) {
      return null;
    }
  }

  String _join(String a, String b) {
    final sep = Platform.pathSeparator;
    if (a.endsWith(sep)) return "$a$b";
    return "$a$sep$b";
  }

  bool _fileExists(String path) => File(path).existsSync();

  _AgentBinaries? _findPackagedBinaries() {
    final dir = _appDir();
    if (dir == null) return null;

    final sep = Platform.pathSeparator;
    final base = dir.path;

    final core = [
      "$base${sep}recorder_core.exe",
      "$base${sep}bin${sep}recorder_core.exe",
    ].firstWhere((p) => _fileExists(p), orElse: () => "");
    final collector = [
      "$base${sep}windows_collector.exe",
      "$base${sep}bin${sep}windows_collector.exe",
    ].firstWhere((p) => _fileExists(p), orElse: () => "");

    if (core.isEmpty || collector.isEmpty) return null;
    return _AgentBinaries(mode: "packaged", coreExe: core, collectorExe: collector);
  }

  _AgentBinaries? _findRepoBinaries(String repoRoot) {
    final sep = Platform.pathSeparator;
    final base = repoRoot;
    final core = "$base${sep}target${sep}release${sep}recorder_core.exe";
    final collector = "$base${sep}target${sep}release${sep}windows_collector.exe";
    if (!_fileExists(core) || !_fileExists(collector)) return null;
    return _AgentBinaries(mode: "repo", coreExe: core, collectorExe: collector);
  }

  Directory _userDataRoot(String name) {
    final sep = Platform.pathSeparator;
    final base = (Platform.environment["LOCALAPPDATA"] ?? "").trim();
    final fallback = (Platform.environment["APPDATA"] ?? "").trim();
    final root = base.isNotEmpty ? base : (fallback.isNotEmpty ? fallback : Directory.systemTemp.path);
    return Directory("$root${sep}$name");
  }

  Directory _defaultDataRoot() {
    return _userDataRoot("WorkTrace");
  }

  Directory _dataRootForMode({required _AgentBinaries bins, String? repoRoot}) {
    if (bins.mode == "repo" && repoRoot != null) {
      return Directory(_join(repoRoot, "data"));
    }
    return _defaultDataRoot();
  }

  File _pidFileForDataRoot(Directory dataRoot) {
    return File(_join(dataRoot.path, "agent-pids.json"));
  }

  Future<_HealthInfo?> _healthInfo(String coreUrl) async {
    Uri base;
    try {
      base = Uri.parse(coreUrl.trim());
    } catch (_) {
      return null;
    }

    final u = base.replace(path: "/health", queryParameters: null, fragment: "");
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(u).timeout(const Duration(seconds: 3));
      final res = await req.close().timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return _HealthInfo(ok: false);
      final text = await res.transform(utf8.decoder).join();
      final obj = jsonDecode(text);
      if (obj is! Map) return _HealthInfo(ok: true);

      Map? data;
      if (obj["data"] is Map) data = obj["data"] as Map;

      final ok = (obj["ok"] == true) || (data != null);
      final svc = (data?["service"] ?? obj["service"])?.toString();
      final ver = (data?["version"] ?? obj["version"])?.toString();
      return _HealthInfo(ok: ok, service: svc, version: ver);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<_CoreSettingsLite?> _coreSettingsLite(String coreUrl) async {
    Uri base;
    try {
      base = Uri.parse(coreUrl.trim());
    } catch (_) {
      return null;
    }

    final u = base.replace(path: "/settings", queryParameters: null, fragment: "");
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(u).timeout(const Duration(seconds: 3));
      final res = await req.close().timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      final text = await res.transform(utf8.decoder).join();
      final obj = jsonDecode(text);
      if (obj is! Map) return null;

      Map? data;
      if (obj["data"] is Map) {
        data = obj["data"] as Map;
      } else {
        data = obj;
      }

      int? i(String key) {
        final v = data?[key];
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v.trim());
        return null;
      }

      bool? b(String key) {
        final v = data?[key];
        if (v is bool) return v;
        if (v is int) return v != 0;
        if (v is String) {
          final s = v.trim().toLowerCase();
          if (s == "true" || s == "1" || s == "yes" || s == "on") return true;
          if (s == "false" || s == "0" || s == "no" || s == "off") return false;
        }
        return null;
      }

      return _CoreSettingsLite(
        idleCutoffSeconds: i("idle_cutoff_seconds"),
        reviewNotifyRepeatMinutes: i("review_notify_repeat_minutes"),
        reviewNotifyWhenPaused: b("review_notify_when_paused"),
        reviewNotifyWhenIdle: b("review_notify_when_idle"),
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _waitCoreHealthy(String coreUrl, {Duration timeout = const Duration(seconds: 15)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final info = await _healthInfo(coreUrl);
      if (info != null && info.ok == true && info.service == "recorder_core") return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<Map<String, dynamic>?> _readPidFile(File f) async {
    try {
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      final obj = jsonDecode(raw);
      if (obj is Map<String, dynamic>) return obj;
      if (obj is Map) return obj.map((k, v) => MapEntry(k.toString(), v));
      return null;
    } catch (_) {
      return null;
    }
  }

  int? _intFromJson(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  Future<void> _killPid(int pid) async {
    try {
      Process.killPid(pid);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _taskkillImage(String imageName) async {
    try {
      await Process.run("taskkill", ["\/IM", imageName, "\/F"], runInShell: false);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _stopFromPidFile(File pidFile) async {
    final info = await _readPidFile(pidFile);
    if (info == null) return;
    final corePid = _intFromJson(info["corePid"]);
    final collectorPid = _intFromJson(info["collectorPid"]);
    if (collectorPid != null) await _killPid(collectorPid);
    if (corePid != null) await _killPid(corePid);
    try {
      await pidFile.delete();
    } catch (_) {
      // ignore
    }
  }

  bool _exeExists(String repoRoot, String relPath) {
    return File("$repoRoot${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}").existsSync();
  }

  Future<DesktopAgentResult> _startViaBinaries({
    required _AgentBinaries bins,
    required String coreUrl,
    required bool restart,
    required bool sendTitle,
    required bool trackAudio,
    required bool reviewNotify,
    required Directory dataRoot,
    String? repoRoot,
  }) async {
    try {
      await dataRoot.create(recursive: true);
    } catch (_) {
      // ignore
    }

    final pidFile = _pidFileForDataRoot(dataRoot);

    final uri = Uri.tryParse(coreUrl.trim());
    if (uri == null || uri.host.trim().isEmpty) {
      return DesktopAgentResult(ok: false, message: "invalid_core_url");
    }

    // If something else is already bound to this port, fail early with a useful message.
    final h = await _healthInfo(coreUrl);
    if (h != null && h.ok == true && h.service != null && h.service != "recorder_core") {
      return DesktopAgentResult(ok: false, message: "port_in_use_by_${h.service}");
    }

    if (restart) {
      await _stopFromPidFile(pidFile);
      // Ensure single-instance collector (avoid double events).
      await _taskkillImage("windows_collector.exe");
      await _taskkillImage("recorder_core.exe");
    } else {
      // Even on Start (non-restart), ensure we don't end up with duplicate collectors.
      await _taskkillImage("windows_collector.exe");
    }

    final port = uri.hasPort ? uri.port : 17600;
    final host = uri.host.trim();
    final listen = "$host:$port";

    final dbPath = _join(dataRoot.path, "recorder-core.db");

    final coreAlreadyHealthy = h != null && h.ok == true && h.service == "recorder_core";
    int? corePid;
    if (!coreAlreadyHealthy || restart) {
      int startedPid;
      try {
        final p = await Process.start(
          bins.coreExe,
          ["--listen", listen, "--db", dbPath],
          workingDirectory: dataRoot.path,
          runInShell: false,
          mode: ProcessStartMode.detached,
        );
        startedPid = p.pid;
        corePid = startedPid;
      } catch (e) {
        return DesktopAgentResult(ok: false, message: "start_core_failed: $e");
      }

      final ok = await _waitCoreHealthy(coreUrl);
      if (!ok) {
        await _killPid(startedPid);
        return DesktopAgentResult(ok: false, message: "core_not_healthy");
      }
    }

    int? collectorPid;
    try {
      final cfg = await _coreSettingsLite(coreUrl);
      final idleCutoffSeconds = cfg?.idleCutoffSeconds;
      final repeatMinutes = cfg?.reviewNotifyRepeatMinutes;
      final notifyWhenPaused = cfg?.reviewNotifyWhenPaused ?? false;
      final notifyWhenIdle = cfg?.reviewNotifyWhenIdle ?? false;

      final args = <String>[
        "--core-url",
        coreUrl,
        if (idleCutoffSeconds != null && idleCutoffSeconds > 0) "--idle-cutoff-seconds=$idleCutoffSeconds",
        "--track-audio=${trackAudio ? 'true' : 'false'}",
        "--review-notify=${reviewNotify ? 'true' : 'false'}",
        if (repeatMinutes != null && repeatMinutes > 0) "--review-notify-repeat-minutes=$repeatMinutes",
        "--review-notify-when-paused=${notifyWhenPaused ? 'true' : 'false'}",
        "--review-notify-when-idle=${notifyWhenIdle ? 'true' : 'false'}",
      ];
      if (sendTitle) args.add("--send-title");

      final p = await Process.start(
        bins.collectorExe,
        args,
        workingDirectory: dataRoot.path,
        runInShell: false,
        mode: ProcessStartMode.detached,
      );
      collectorPid = p.pid;
    } catch (e) {
      return DesktopAgentResult(ok: false, message: "start_collector_failed: $e");
    }

    final info = <String, dynamic>{
      "mode": bins.mode,
      "coreUrl": coreUrl,
      "listen": listen,
      "dbPath": dbPath,
      "startedAt": DateTime.now().toIso8601String(),
      "corePid": corePid,
      "collectorPid": collectorPid,
      "coreExe": bins.coreExe,
      "collectorExe": bins.collectorExe,
      "dataDir": dataRoot.path,
      if (repoRoot != null) "repoRoot": repoRoot,
    };
    try {
      await pidFile.writeAsString(jsonEncode(info));
    } catch (_) {
      // ignore
    }

    final msg = bins.mode == "packaged"
        ? "ok (packaged)"
        : bins.mode == "repo"
            ? "ok (repo)"
            : "ok";
    return DesktopAgentResult(ok: true, message: msg);
  }

  @override
  Future<DesktopAgentResult> start({
    required String coreUrl,
    bool restart = false,
    bool sendTitle = false,
    bool trackAudio = true,
    bool reviewNotify = true,
  }) async {
    if (!isAvailable) return DesktopAgentResult(ok: false, message: "not_supported");

    // 1) Prefer packaged mode: bundled binaries next to the UI.
    final packaged = _findPackagedBinaries();
    if (packaged != null) {
      final dataRoot = _dataRootForMode(bins: packaged);
      return _startViaBinaries(
        bins: packaged,
        coreUrl: coreUrl,
        restart: restart,
        sendTitle: sendTitle,
        trackAudio: trackAudio,
        reviewNotify: reviewNotify,
        dataRoot: dataRoot,
      );
    }

    // 2) Dev/repo mode: prefer direct start if release exes already exist; otherwise fall back to PowerShell scripts.
    final repoRoot = await findRepoRoot();
    if (repoRoot != null) {
      final repoBins = _findRepoBinaries(repoRoot);
      if (repoBins != null) {
        final dataRoot = _dataRootForMode(bins: repoBins, repoRoot: repoRoot);
        return _startViaBinaries(
          bins: repoBins,
          coreUrl: coreUrl,
          restart: restart,
          sendTitle: sendTitle,
          trackAudio: trackAudio,
          reviewNotify: reviewNotify,
          dataRoot: dataRoot,
          repoRoot: repoRoot,
        );
      }
    }

    if (repoRoot == null) {
      return DesktopAgentResult(ok: false, message: "no_bundled_binaries");
    }

    final runAgent = "$repoRoot${Platform.pathSeparator}dev${Platform.pathSeparator}run-agent.ps1";
    if (!File(runAgent).existsSync()) {
      return DesktopAgentResult(ok: false, message: "run_agent_missing");
    }

    final coreExeOk = _exeExists(repoRoot, "target/release/recorder_core.exe");
    final collectorExeOk = _exeExists(repoRoot, "target/release/windows_collector.exe");
    final noBuild = coreExeOk && collectorExeOk;

    final boolArg = (bool v) => v ? "\$true" : "\$false";

    final args = <String>[
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-WindowStyle",
      "Hidden",
      "-File",
      runAgent,
      "-RepoRoot",
      repoRoot,
      "-CoreUrl",
      coreUrl,
      "-TrackAudio",
      boolArg(trackAudio),
      "-ReviewNotify",
      boolArg(reviewNotify),
    ];

    if (sendTitle) args.add("-SendTitle");
    if (restart) args.add("-Restart");
    if (noBuild) args.add("-NoBuild");

    try {
      final res = await Process.run("powershell", args, runInShell: false);
      final out = "${(res.stdout ?? "").toString().trim()}\n${(res.stderr ?? "").toString().trim()}".trim();
      if (res.exitCode == 0) {
        return DesktopAgentResult(ok: true, message: out.isEmpty ? "ok" : out);
      }
      return DesktopAgentResult(ok: false, message: out.isEmpty ? "exit_${res.exitCode}" : out);
    } catch (e) {
      return DesktopAgentResult(ok: false, message: e.toString());
    }
  }

  @override
  Future<DesktopAgentResult> stop({bool killAllByName = true}) async {
    if (!isAvailable) return DesktopAgentResult(ok: false, message: "not_supported");

    // Prefer stopping via pid files directly (works for both packaged and repo runs).
    final killed = <String>[];

    final packagedPid = _pidFileForDataRoot(_defaultDataRoot());
    if (await packagedPid.exists()) {
      await _stopFromPidFile(packagedPid);
      killed.add("pidfile(packaged)");
    }

    final repoRoot = await findRepoRoot();
    if (repoRoot != null) {
      final repoPid = _pidFileForDataRoot(Directory(_join(repoRoot, "data")));
      if (await repoPid.exists()) {
        await _stopFromPidFile(repoPid);
        killed.add("pidfile(repo)");
      }
    }

    if (killAllByName) {
      await _taskkillImage("windows_collector.exe");
      await _taskkillImage("recorder_core.exe");
      killed.add("taskkill");
    }

    return DesktopAgentResult(ok: true, message: killed.isEmpty ? "ok" : "ok (${killed.join(', ')})");
  }
}
