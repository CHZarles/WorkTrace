import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:http/http.dart" as http;

import "update_manager.dart";

UpdateManager getUpdateManager() => _IoUpdateManager();

class _IoUpdateManager implements UpdateManager {
  static const _userAgent = "RecorderPhone";
  static const _defaultAssetSuffix = "-windows-setup.exe";

  @override
  bool get isAvailable => !kIsWeb && Platform.isWindows;

  @override
  void exitApp() => exit(0);

  String _join(String a, String b) {
    final sep = Platform.pathSeparator;
    if (a.endsWith(sep)) return "$a$b";
    return "$a$sep$b";
  }

  Directory? _appDir() {
    try {
      return File(Platform.resolvedExecutable).parent;
    } catch (_) {
      return null;
    }
  }

  File? _buildInfoFile() {
    final dir = _appDir();
    if (dir == null) return null;
    return File(_join(dir.path, "build-info.json"));
  }

  bool _looksLikePackagedInstall(Directory dir) {
    // Minimal heuristics: the packaged folder contains these siblings.
    final sep = Platform.pathSeparator;
    final base = dir.path;
    final core = File("$base${sep}recorder_core.exe");
    final collector = File("$base${sep}windows_collector.exe");
    final info = File("$base${sep}build-info.json");
    return core.existsSync() && collector.existsSync() && info.existsSync();
  }

  Future<bool> _canWriteToDir(Directory dir) async {
    try {
      final f = File(_join(dir.path, ".__write_test__"));
      await f.writeAsString("ok");
      await f.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  String? _str(Map obj, String key) {
    final v = obj[key];
    if (v is String) return v;
    return v?.toString();
  }

  int? _int(Map obj, String key) {
    final v = obj[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  @override
  Future<BuildInfo?> readBuildInfo() async {
    if (!isAvailable) return null;
    final f = _buildInfoFile();
    if (f == null) return null;
    try {
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      final obj = jsonDecode(raw);
      if (obj is! Map) return null;
      final map = obj;

      Map? core;
      if (map["core"] is Map) core = map["core"] as Map;
      Map? collector;
      if (map["collector"] is Map) collector = map["collector"] as Map;
      Map? update;
      if (map["update"] is Map) update = map["update"] as Map;

      return BuildInfo(
        builtAt: _str(map, "builtAt"),
        git: _str(map, "git"),
        gitTag: _str(map, "gitTag"),
        gitDescribe: _str(map, "gitDescribe"),
        coreVersion: core == null ? null : _str(core, "version"),
        collectorVersion: collector == null ? null : _str(collector, "version"),
        updateGitHubRepo: update == null ? null : _str(update, "githubRepo"),
        updateAssetSuffix: update == null ? null : _str(update, "assetSuffix"),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> defaultGitHubRepo() async {
    final info = await readBuildInfo();
    final r = (info?.updateGitHubRepo ?? "").trim();
    if (r.isEmpty) return null;
    return r;
  }

  Uri _latestReleaseApi(String repo) {
    final clean = repo.trim();
    return Uri.parse("https://api.github.com/repos/$clean/releases/latest");
  }

  int _compareSemverTags(String a, String b) {
    // Returns: <0 if a<b, 0 if equal, >0 if a>b
    String norm(String s) {
      var v = s.trim();
      if (v.startsWith("v") || v.startsWith("V")) v = v.substring(1);
      final plus = v.indexOf("+");
      if (plus >= 0) v = v.substring(0, plus);
      return v;
    }

    List<String> splitPre(String s) {
      final v = norm(s);
      final dash = v.indexOf("-");
      if (dash < 0) return [v, ""];
      return [v.substring(0, dash), v.substring(dash + 1)];
    }

    List<int> nums(String core) {
      final parts = core.split(".");
      int p(String x) {
        final m = RegExp(r"^(\d+)").firstMatch(x.trim());
        if (m == null) return 0;
        return int.tryParse(m.group(1)!) ?? 0;
      }

      final n = <int>[0, 0, 0];
      for (var i = 0; i < 3; i++) {
        if (i < parts.length) n[i] = p(parts[i]);
      }
      return n;
    }

    int cmpInt(int x, int y) => x == y ? 0 : (x < y ? -1 : 1);

    final ap = splitPre(a);
    final bp = splitPre(b);
    final an = nums(ap[0]);
    final bn = nums(bp[0]);
    for (var i = 0; i < 3; i++) {
      final c = cmpInt(an[i], bn[i]);
      if (c != 0) return c;
    }

    final apre = ap[1].trim();
    final bpre = bp[1].trim();
    if (apre.isEmpty && bpre.isEmpty) return 0;
    if (apre.isEmpty) return 1; // stable > prerelease
    if (bpre.isEmpty) return -1;

    // Compare prerelease identifiers
    final aIds = apre.split(".");
    final bIds = bpre.split(".");
    final len = aIds.length > bIds.length ? aIds.length : bIds.length;
    for (var i = 0; i < len; i++) {
      if (i >= aIds.length) return -1;
      if (i >= bIds.length) return 1;
      final ax = aIds[i];
      final bx = bIds[i];
      final ai = int.tryParse(ax);
      final bi = int.tryParse(bx);
      if (ai != null && bi != null) {
        final c = cmpInt(ai, bi);
        if (c != 0) return c;
      } else if (ai != null && bi == null) {
        return -1;
      } else if (ai == null && bi != null) {
        return 1;
      } else {
        final c = ax.compareTo(bx);
        if (c != 0) return c;
      }
    }
    return 0;
  }

  Future<UpdateRelease?> _fetchLatestRelease(String repo,
      {required String assetSuffix}) async {
    final uri = _latestReleaseApi(repo);
    final res = await http.get(uri, headers: {
      "Accept": "application/vnd.github+json",
      "User-Agent": _userAgent,
    }).timeout(const Duration(seconds: 8));

    if (res.statusCode != 200) {
      throw Exception("http_${res.statusCode}");
    }
    final obj = jsonDecode(res.body);
    if (obj is! Map) throw Exception("invalid_response");

    final tag = (obj["tag_name"] ?? "").toString().trim();
    if (tag.isEmpty) throw Exception("missing_tag");

    final assets = (obj["assets"] is List) ? (obj["assets"] as List) : const [];
    Map? best;
    final suffix =
        assetSuffix.trim().isEmpty ? _defaultAssetSuffix : assetSuffix.trim();
    final suffixLower = suffix.toLowerCase();
    for (final a in assets) {
      if (a is! Map) continue;
      final name = (a["name"] ?? "").toString();
      if (!name.toLowerCase().endsWith(suffixLower)) continue;
      best = a;
      break;
    }

    final assetName = best == null ? null : (best["name"] ?? "").toString();
    final assetUrl =
        best == null ? null : (best["browser_download_url"] ?? "").toString();
    final size = best == null ? null : _int(best, "size");

    return UpdateRelease(
      tag: tag,
      name: (obj["name"] ?? "").toString().trim().isEmpty
          ? null
          : (obj["name"] ?? "").toString().trim(),
      publishedAt: (obj["published_at"] ?? "").toString().trim().isEmpty
          ? null
          : (obj["published_at"] ?? "").toString().trim(),
      body: (obj["body"] ?? "").toString(),
      assetName: assetName?.trim().isEmpty == true ? null : assetName,
      assetUrl: assetUrl?.trim().isEmpty == true ? null : assetUrl,
      assetSizeBytes: size,
      htmlUrl: (obj["html_url"] ?? "").toString().trim().isEmpty
          ? null
          : (obj["html_url"] ?? "").toString().trim(),
    );
  }

  @override
  Future<UpdateCheckResult> checkLatest({required String gitHubRepo}) async {
    if (!isAvailable) {
      return const UpdateCheckResult(
          ok: false, error: "not_supported", updateAvailable: false);
    }

    final repo = gitHubRepo.trim();
    if (repo.isEmpty) {
      return const UpdateCheckResult(
          ok: false, error: "missing_repo", updateAvailable: false);
    }

    try {
      final current = await readBuildInfo();
      final configuredSuffix = (current?.updateAssetSuffix ?? "").trim();
      final suffix =
          configuredSuffix.isEmpty ? _defaultAssetSuffix : configuredSuffix;
      var latest = await _fetchLatestRelease(repo, assetSuffix: suffix);

      final hasAsset = (latest?.assetUrl ?? "").trim().isNotEmpty;
      final suffixIsSetup =
          suffix.toLowerCase() == _defaultAssetSuffix.toLowerCase();
      if (!hasAsset && !suffixIsSetup) {
        latest =
            await _fetchLatestRelease(repo, assetSuffix: _defaultAssetSuffix);
      }

      final curTag = (current?.gitTag ?? "").trim();
      final canCompare = curTag.isNotEmpty;
      final updateAvailable = latest != null &&
          (latest.assetUrl ?? "").trim().isNotEmpty &&
          (canCompare ? (_compareSemverTags(latest.tag, curTag) > 0) : true);

      return UpdateCheckResult(
        ok: true,
        current: current,
        latest: latest,
        updateAvailable: updateAvailable,
      );
    } catch (e) {
      return UpdateCheckResult(
          ok: false, error: e.toString(), updateAvailable: false);
    }
  }

  Future<File> _downloadToTempFile(Uri url) async {
    final tmp = Directory.systemTemp;
    final lowerPath = url.path.toLowerCase();
    final ext = lowerPath.endsWith(".exe")
        ? ".exe"
        : (lowerPath.endsWith(".zip") ? ".zip" : ".bin");
    final name = "RecorderPhone-${DateTime.now().millisecondsSinceEpoch}$ext";
    final f = File(_join(tmp.path, name));
    final req = http.Request("GET", url);
    req.headers["User-Agent"] = _userAgent;
    req.headers["Accept"] = "application/octet-stream";

    final client = http.Client();
    try {
      final res = await client.send(req).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw Exception("http_${res.statusCode}");
      final sink = f.openWrite();
      await res.stream.pipe(sink);
      await sink.flush();
      await sink.close();
      return f;
    } finally {
      client.close();
    }
  }

  String _updaterScript() {
    // Keep the script self-contained to avoid shipping extra files in the app.
    return r'''
param(
  [Parameter(Mandatory=$true)][string]$SetupPath,
  [Parameter(Mandatory=$true)][string]$InstallDir,
  [string]$ExeName = "RecorderPhone.exe",
  [int]$UiPid = 0,
  [string]$StartArgs = ""
)

$ErrorActionPreference = "Stop"

function Stop-ByName {
  param([Parameter(Mandatory=$true)][string[]]$Names)
  foreach ($n in $Names) {
    try { Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Wait-NotRunning {
  param([Parameter(Mandatory=$true)][string[]]$Names, [int]$TimeoutSeconds = 12)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $alive = @()
    foreach ($n in $Names) {
      try { if (Get-Process $n -ErrorAction SilentlyContinue) { $alive += $n } } catch {}
    }
    if ($alive.Count -eq 0) { return }
    Start-Sleep -Milliseconds 200
  }
}

if (!(Test-Path $SetupPath)) { throw "setup_not_found" }
if ([string]::IsNullOrWhiteSpace($InstallDir)) { throw "install_dir_missing" }

$names = @("RecorderPhone", "recorderphone_ui", "recorder_core", "windows_collector")
Stop-ByName -Names $names
try { if ($UiPid -gt 0) { Wait-Process -Id $UiPid -Timeout 15 } } catch {}
Wait-NotRunning -Names $names -TimeoutSeconds 10

$setupArgs = @(
  "/VERYSILENT",
  "/SUPPRESSMSGBOXES",
  "/NORESTART",
  "/SP-",
  "/CLOSEAPPLICATIONS",
  "/FORCECLOSEAPPLICATIONS",
  "/DIR=""$InstallDir"""
)

$setupProc = Start-Process -FilePath $SetupPath -ArgumentList $setupArgs -PassThru -Wait
if ($null -eq $setupProc) { throw "setup_start_failed" }
if ($setupProc.ExitCode -ne 0) { throw "setup_failed_exit_$($setupProc.ExitCode)" }

$exe = Join-Path $InstallDir $ExeName
if (!(Test-Path $exe)) {
  $c = Get-ChildItem -Path $InstallDir -Filter "*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { $exe = $c.FullName } else { throw "installed_exe_not_found" }
}

try {
  if ([string]::IsNullOrWhiteSpace($StartArgs)) {
    Start-Process -FilePath $exe | Out-Null
  } else {
    Start-Process -FilePath $exe -ArgumentList $StartArgs | Out-Null
  }
} catch {
  throw "restart_failed: $($_.Exception.Message)"
}
''';
  }

  @override
  Future<UpdateInstallResult> installUpdate({
    required UpdateRelease latest,
    required String installAssetUrl,
    bool startMinimized = false,
  }) async {
    if (!isAvailable)
      return const UpdateInstallResult(ok: false, error: "not_supported");

    final dir = _appDir();
    if (dir == null)
      return const UpdateInstallResult(ok: false, error: "no_app_dir");

    if (!_looksLikePackagedInstall(dir)) {
      return const UpdateInstallResult(ok: false, error: "packaged_only");
    }

    final canWrite = await _canWriteToDir(dir);
    if (!canWrite) {
      return const UpdateInstallResult(
          ok: false, error: "install_dir_not_writable");
    }

    Uri url;
    try {
      url = Uri.parse(installAssetUrl.trim());
    } catch (_) {
      return const UpdateInstallResult(ok: false, error: "invalid_url");
    }

    try {
      final setupAsset = await _downloadToTempFile(url);
      final scriptFile =
          File(_join(Directory.systemTemp.path, "RecorderPhone-update.ps1"));
      await scriptFile.writeAsString(_updaterScript(), flush: true);

      final exePath = Platform.resolvedExecutable;
      final exeName = exePath.split(Platform.pathSeparator).last;
      final startArgs = startMinimized ? "--minimized" : "";

      final args = <String>[
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        scriptFile.path,
        "-SetupPath",
        setupAsset.path,
        "-InstallDir",
        dir.path,
        "-ExeName",
        exeName,
        "-UiPid",
        pid.toString(),
        "-StartArgs",
        startArgs,
      ];

      await Process.start(
        "powershell.exe",
        args,
        runInShell: false,
        mode: ProcessStartMode.detached,
      );

      return const UpdateInstallResult(ok: true);
    } catch (e) {
      return UpdateInstallResult(ok: false, error: e.toString());
    }
  }
}
