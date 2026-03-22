import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:http/http.dart" as http;

import "update_manager.dart";

UpdateManager getUpdateManager() => _IoUpdateManager();

class _IoUpdateManager implements UpdateManager {
  static const _userAgent = "WorkTrace";
  static const _defaultGitHubRepo = "CHZarles/WorkTrace";
  static const _defaultAssetSuffix = "-windows-setup.exe";
  static const _innoAppId = "{D3A8F3B5-3A57-4A17-9A2B-D8C1A8E1D95D}";

  @override
  bool get isAvailable => !kIsWeb && Platform.isWindows;

  @override
  void exitApp() => exit(0);

  String _join(String a, String b) {
    final sep = Platform.pathSeparator;
    if (a.endsWith(sep)) return "$a$b";
    return "$a$sep$b";
  }

  String _normalizePath(String raw) {
    var v = raw.trim();
    if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) {
      v = v.substring(1, v.length - 1);
    }
    return v.replaceAll("/", Platform.pathSeparator).trim();
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
    final workTraceUi = File("$base${sep}WorkTrace.exe");
    final legacyUi = File("$base${sep}worktrace_ui.exe");
    final info = File("$base${sep}build-info.json");
    return core.existsSync() &&
        collector.existsSync() &&
        (workTraceUi.existsSync() ||
            legacyUi.existsSync() ||
            info.existsSync());
  }

  Future<String?> _queryRegistryValue(String key, String valueName) async {
    try {
      final res = await Process.run(
        "reg.exe",
        ["query", key, "/v", valueName],
        runInShell: false,
      );
      if (res.exitCode != 0) return null;
      final out = "${res.stdout}\n${res.stderr}";
      final pattern =
          RegExp("^\\s*${RegExp.escape(valueName)}\\s+REG_\\w+\\s+(.*)\$");
      for (final line in out.split(RegExp(r"\r?\n"))) {
        final m = pattern.firstMatch(line);
        if (m == null) continue;
        final v = _normalizePath(m.group(1) ?? "");
        if (v.isNotEmpty) return v;
      }
    } catch (_) {
      // ignore
    }
    return null;
  }

  Future<String?> _installedInstallDirFromRegistry() async {
    final key =
        r"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{D3A8F3B5-3A57-4A17-9A2B-D8C1A8E1D95D}_is1";

    final loc = await _queryRegistryValue(key, "InstallLocation");
    if (loc != null && loc.trim().isNotEmpty) return loc.trim();

    final displayIcon = await _queryRegistryValue(key, "DisplayIcon");
    final icon = (displayIcon ?? "").trim();
    if (icon.isEmpty) return null;

    var exe = icon;
    final comma = exe.indexOf(",");
    if (comma > 0) exe = exe.substring(0, comma);
    exe = _normalizePath(exe).trim();
    if (exe.isEmpty) return null;
    try {
      return File(exe).parent.path;
    } catch (_) {
      return null;
    }
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
    return r.isEmpty ? _defaultGitHubRepo : r;
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
    });

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

    var repo = gitHubRepo.trim();
    if (repo.isEmpty) {
      repo = ((await defaultGitHubRepo()) ?? "").trim();
    }
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

  Future<File> _downloadToTempFile(
    Uri url, {
    int? expectedBytes,
    void Function(UpdateInstallProgress progress)? onProgress,
  }) async {
    final tmp = Directory.systemTemp;
    final lowerPath = url.path.toLowerCase();
    final ext = lowerPath.endsWith(".exe")
        ? ".exe"
        : (lowerPath.endsWith(".zip") ? ".zip" : ".bin");
    final name = "WorkTrace-${DateTime.now().millisecondsSinceEpoch}$ext";
    final f = File(_join(tmp.path, name));
    final req = http.Request("GET", url);
    req.headers["User-Agent"] = _userAgent;
    req.headers["Accept"] = "application/octet-stream";

    final client = http.Client();
    try {
      final res = await client.send(req);
      if (res.statusCode != 200) throw Exception("http_${res.statusCode}");
      final reportedLength = res.contentLength;
      final contentLength = (reportedLength != null && reportedLength > 0)
          ? reportedLength
          : (expectedBytes ?? 0);
      final totalBytes = contentLength > 0 ? contentLength : null;
      final sink = f.openWrite();
      var downloadedBytes = 0;
      onProgress?.call(
        UpdateInstallProgress(
          phase: UpdateInstallPhase.downloading,
          downloadedBytes: downloadedBytes,
          totalBytes: totalBytes,
        ),
      );
      try {
        await for (final chunk in res.stream) {
          downloadedBytes += chunk.length;
          sink.add(chunk);
          onProgress?.call(
            UpdateInstallProgress(
              phase: UpdateInstallPhase.downloading,
              downloadedBytes: downloadedBytes,
              totalBytes: totalBytes,
            ),
          );
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return f;
    } catch (_) {
      if (await f.exists()) {
        await f.delete();
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<bool> _waitForFile(
    File file, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      try {
        if (await file.exists()) return true;
      } catch (_) {
        // ignore
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    try {
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  String _updaterScript() {
    // Keep the script self-contained to avoid shipping extra files in the app.
    return r'''
param(
  [Parameter(Mandatory=$true)][string]$SetupPath,
  [string]$InstallDir = "",
  [string]$PreferredExeName = "WorkTrace.exe",
  [string]$AppId = "",
  [int]$UiPid = 0,
  [string]$StartArgs = "",
  [string]$AckPath = ""
)

$ErrorActionPreference = "Stop"
$LogPath = Join-Path $env:TEMP "WorkTrace-updater.log"

function Write-Log {
  param([Parameter(Mandatory=$true)][string]$Line)
  try {
    Add-Content -Path $LogPath -Value ("[{0}] {1}" -f (Get-Date).ToString("s"), $Line)
  } catch {}
}

function Write-Ack {
  if ([string]::IsNullOrWhiteSpace($AckPath)) { return }
  try {
    Set-Content -Path $AckPath -Value "started" -Encoding utf8 -Force
  } catch {}
}

function Stop-ByName {
  param([Parameter(Mandatory=$true)][string[]]$Names)
  foreach ($n in $Names) {
    try { Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Stop-ByImage {
  param([Parameter(Mandatory=$true)][string[]]$Images)
  foreach ($img in $Images) {
    try { & taskkill /IM $img /F /T | Out-Null } catch {}
  }
}

function Stop-ByPathPrefix {
  param([string]$Dir)
  if ([string]::IsNullOrWhiteSpace($Dir)) { return }
  $prefix = ""
  try {
    $prefix = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\') + "\"
  } catch {
    $prefix = $Dir.TrimEnd('\') + "\"
  }
  try {
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
      $ep = "$($p.ExecutablePath)"
      if ([string]::IsNullOrWhiteSpace($ep)) { continue }
      $full = $ep
      try { $full = [System.IO.Path]::GetFullPath($ep) } catch {}
      if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
      }
    }
  } catch {}
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

function Wait-NotRunningFromDir {
  param([string]$Dir, [int]$TimeoutSeconds = 12)
  if ([string]::IsNullOrWhiteSpace($Dir)) { return }
  $prefix = ""
  try {
    $prefix = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\') + "\"
  } catch {
    $prefix = $Dir.TrimEnd('\') + "\"
  }
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $alive = $false
    try {
      $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
      foreach ($p in $procs) {
        $ep = "$($p.ExecutablePath)"
        if ([string]::IsNullOrWhiteSpace($ep)) { continue }
        $full = $ep
        try { $full = [System.IO.Path]::GetFullPath($ep) } catch {}
        if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
          $alive = $true
          break
        }
      }
    } catch {
      return
    }
    if (-not $alive) { return }
    Start-Sleep -Milliseconds 200
  }
}

function Read-UninstallValue {
  param([Parameter(Mandatory=$true)][string]$Name)
  if ([string]::IsNullOrWhiteSpace($AppId)) { return "" }
  $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$($AppId)_is1"
  try {
    $v = (Get-ItemProperty -Path $key -Name $Name -ErrorAction Stop).$Name
    if ($null -eq $v) { return "" }
    return "$v".Trim()
  } catch {
    return ""
  }
}

function Resolve-InstallDir {
  param([string]$Fallback)
  $loc = Read-UninstallValue -Name "InstallLocation"
  if (-not [string]::IsNullOrWhiteSpace($loc)) { return $loc.Trim('"') }

  $icon = Read-UninstallValue -Name "DisplayIcon"
  if (-not [string]::IsNullOrWhiteSpace($icon)) {
    $path = $icon.Trim('"')
    $comma = $path.IndexOf(",")
    if ($comma -gt 0) { $path = $path.Substring(0, $comma) }
    try {
      $dir = Split-Path -Parent $path
      if (-not [string]::IsNullOrWhiteSpace($dir)) { return $dir }
    } catch {}
  }
  return $Fallback
}

function Resolve-UiExe {
  param(
    [Parameter(Mandatory=$true)][string]$Dir,
    [string]$Preferred = "WorkTrace.exe"
  )
  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
    $candidates += (Join-Path $Dir $Preferred)
  }
  $candidates += (Join-Path $Dir "WorkTrace.exe")

  foreach ($c in $candidates) {
    if (Test-Path $c) { return $c }
  }

  $alts = Get-ChildItem -Path $Dir -Filter "*.exe" -File -ErrorAction SilentlyContinue `
    | Where-Object { $_.Name -ne "recorder_core.exe" -and $_.Name -ne "windows_collector.exe" } `
    | Sort-Object `
        @{ Expression = { if ($_.Name -ieq "WorkTrace.exe") { 0 } elseif ($_.Name -ieq "worktrace_ui.exe") { 1 } else { 2 } } }, `
        @{ Expression = { $_.Name } }
  if ($alts -and $alts.Count -gt 0) { return $alts[0].FullName }
  return ""
}

function Start-App {
  param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [string]$Args = "",
    [string]$Dir = ""
  )
  if ([string]::IsNullOrWhiteSpace($Exe) -or !(Test-Path $Exe)) { return $false }
  try {
    if ([string]::IsNullOrWhiteSpace($Dir)) {
      $Dir = Split-Path -Parent $Exe
    }
    if ([string]::IsNullOrWhiteSpace($Args)) {
      Start-Process -FilePath $Exe -WorkingDirectory $Dir | Out-Null
    } else {
      Start-Process -FilePath $Exe -ArgumentList $Args -WorkingDirectory $Dir | Out-Null
    }
    return $true
  } catch {
    Write-Log "start app failed ($Exe): $($_.Exception.Message)"
    return $false
  }
}

Write-Log "updater started setup=$SetupPath installDir=$InstallDir appId=$AppId uiPid=$UiPid"
Write-Ack

$targetInstallDir = ""
$fallbackExe = ""

try {
  if (!(Test-Path $SetupPath)) { throw "setup_not_found" }
  $targetInstallDir = Resolve-InstallDir -Fallback $InstallDir
  if ([string]::IsNullOrWhiteSpace($targetInstallDir)) { throw "install_dir_missing" }
  Write-Log "resolved install dir: $targetInstallDir"

  $fallbackExe = Resolve-UiExe -Dir $targetInstallDir -Preferred $PreferredExeName
  if (-not [string]::IsNullOrWhiteSpace($fallbackExe)) {
    Write-Log "fallback exe: $fallbackExe"
  }

  $names = @("WorkTrace", "worktrace_ui", "recorder_core", "windows_collector")
  $images = @("WorkTrace.exe", "worktrace_ui.exe", "recorder_core.exe", "windows_collector.exe")
  for ($i = 0; $i -lt 3; $i++) {
    Stop-ByName -Names $names
    Stop-ByImage -Images $images
    Stop-ByPathPrefix -Dir $targetInstallDir
    try { if ($UiPid -gt 0) { Wait-Process -Id $UiPid -Timeout 6 } } catch {}
    Wait-NotRunning -Names $names -TimeoutSeconds 4
    Wait-NotRunningFromDir -Dir $targetInstallDir -TimeoutSeconds 4
    Start-Sleep -Milliseconds 200
  }

  $setupLog = Join-Path $env:TEMP "WorkTrace-updater-setup.log"
  $setupArgs = @(
    "/VERYSILENT",
    "/SUPPRESSMSGBOXES",
    "/NORESTART",
    "/SP-",
    "/CLOSEAPPLICATIONS",
    "/FORCECLOSEAPPLICATIONS",
    "/NORESTARTAPPLICATIONS",
    "/LOG=""$setupLog"""
  )
  if (-not [string]::IsNullOrWhiteSpace($targetInstallDir)) {
    $setupArgs += "/DIR=""$targetInstallDir"""
  }

  Write-Log "running installer: $SetupPath"
  $setupProc = Start-Process -FilePath $SetupPath -ArgumentList $setupArgs -PassThru -Wait
  if ($null -eq $setupProc) { throw "setup_start_failed" }
  if ($setupProc.ExitCode -ne 0) { throw "setup_failed_exit_$($setupProc.ExitCode)" }
  Write-Log "installer finished exit=$($setupProc.ExitCode)"

  $finalInstallDir = Resolve-InstallDir -Fallback $targetInstallDir
  if ([string]::IsNullOrWhiteSpace($finalInstallDir)) { $finalInstallDir = $targetInstallDir }
  Write-Log "final install dir: $finalInstallDir"

  $exe = Resolve-UiExe -Dir $finalInstallDir -Preferred $PreferredExeName
  if ([string]::IsNullOrWhiteSpace($exe) -or !(Test-Path $exe)) {
    throw "installed_exe_not_found"
  }
  Write-Log "restart exe: $exe"

  $started = Start-App -Exe $exe -Args $StartArgs -Dir $finalInstallDir
  if (-not $started) { throw "restart_failed" }
  Write-Log "update completed"
} catch {
  Write-Log "update failed: $($_.Exception.Message)"
  if (-not [string]::IsNullOrWhiteSpace($fallbackExe) -and (Test-Path $fallbackExe)) {
    $fallbackDir = ""
    try { $fallbackDir = Split-Path -Parent $fallbackExe } catch {}
    if (Start-App -Exe $fallbackExe -Args $StartArgs -Dir $fallbackDir) {
      Write-Log "fallback restart launched: $fallbackExe"
    }
  }
  throw
}
''';
  }

  @override
  Future<UpdateInstallResult> installUpdate({
    required UpdateRelease latest,
    required String installAssetUrl,
    bool startMinimized = false,
    void Function(UpdateInstallProgress progress)? onProgress,
  }) async {
    if (!isAvailable)
      return const UpdateInstallResult(ok: false, error: "not_supported");

    final currentDir = _appDir();
    if (currentDir == null)
      return const UpdateInstallResult(ok: false, error: "no_app_dir");

    final registryInstallDir = await _installedInstallDirFromRegistry();
    final targetDir =
        (registryInstallDir != null && registryInstallDir.trim().isNotEmpty)
            ? Directory(registryInstallDir.trim())
            : currentDir;

    final currentLooksPackaged = _looksLikePackagedInstall(currentDir);
    final targetLooksPackaged = _looksLikePackagedInstall(targetDir);
    if (!currentLooksPackaged && !targetLooksPackaged) {
      return const UpdateInstallResult(ok: false, error: "packaged_only");
    }

    final canWrite = await _canWriteToDir(targetDir);
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
      onProgress?.call(
        const UpdateInstallProgress(phase: UpdateInstallPhase.preparing),
      );
      final setupAsset = await _downloadToTempFile(
        url,
        expectedBytes: latest.assetSizeBytes,
        onProgress: onProgress,
      );
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final scriptFile =
          File(_join(Directory.systemTemp.path, "WorkTrace-update-$stamp.ps1"));
      await scriptFile.writeAsString(_updaterScript(), flush: true);
      final ackFile =
          File(_join(Directory.systemTemp.path, "WorkTrace-update-$stamp.ack"));
      if (await ackFile.exists()) {
        await ackFile.delete();
      }

      final preferredExeName = "WorkTrace.exe";
      final startArgs = startMinimized ? "--minimized" : "";

      final args = <String>[
        "-NoProfile",
        "-WindowStyle",
        "Hidden",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        scriptFile.path,
        "-SetupPath",
        setupAsset.path,
        "-InstallDir",
        targetDir.path,
        "-PreferredExeName",
        preferredExeName,
        "-AppId",
        _innoAppId,
        "-UiPid",
        pid.toString(),
        "-StartArgs",
        startArgs,
        "-AckPath",
        ackFile.path,
      ];

      onProgress?.call(
        UpdateInstallProgress(
          phase: UpdateInstallPhase.launchingInstaller,
          downloadedBytes: latest.assetSizeBytes ?? 0,
          totalBytes: latest.assetSizeBytes,
        ),
      );

      await Process.start(
        "powershell.exe",
        args,
        runInShell: false,
        workingDirectory: Directory.systemTemp.path,
        mode: ProcessStartMode.detached,
      );

      final confirmed = await _waitForFile(ackFile);
      if (!confirmed) {
        return const UpdateInstallResult(
          ok: false,
          error: "updater_not_confirmed",
        );
      }

      return const UpdateInstallResult(ok: true);
    } catch (e) {
      return UpdateInstallResult(ok: false, error: e.toString());
    }
  }
}
