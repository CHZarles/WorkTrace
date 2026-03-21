param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [string]$OutDir = "",
  [switch]$NoBuild,
  [switch]$NoOverlayUI,
  [switch]$InstallProtocol,
  [switch]$Zip,
  [switch]$Installer
)

$ErrorActionPreference = "Stop"

Set-Location $RepoRoot

Write-Host "[package] repo: $RepoRoot"

function Stop-ProcessesAndWait {
  param(
    [Parameter(Mandatory = $true)][string[]]$Names,
    [int]$TimeoutSeconds = 10
  )

  foreach ($n in $Names) {
    try {
      Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {
      # best effort
    }
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $alive = @()
    foreach ($n in $Names) {
      try {
        $p = Get-Process $n -ErrorAction SilentlyContinue
        if ($p) { $alive += $n }
      } catch {
        # ignore
      }
    }
    if ($alive.Count -eq 0) { return }
    Start-Sleep -Milliseconds 200
  }

  $still = @()
  foreach ($n in $Names) {
    try {
      $p = Get-Process $n -ErrorAction SilentlyContinue
      if ($p) { $still += $n }
    } catch {
      # ignore
    }
  }
  if ($still.Count -gt 0) {
    throw "Failed to stop running processes: $($still -join ', '). Close WorkTrace (tray Exit) and retry."
  }
}

function Invoke-Robocopy {
  param(
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To,
    [string[]]$ExcludeFiles = @()
  )

  # Use small retry counts to avoid "hang forever" when something is locked.
  $common = @("/E", "/DCOPY:DA", "/COPY:DAT", "/R:3", "/W:1")
  if ($ExcludeFiles -and $ExcludeFiles.Count -gt 0) {
    robocopy $From $To @common /XF $ExcludeFiles | Out-Host
  } else {
    robocopy $From $To @common | Out-Host
  }
  $code = $LASTEXITCODE
  # robocopy exit codes: < 8 are success (0..7). >= 8 indicates failure.
  if ($code -ge 8) {
    throw "robocopy failed with exit code $code"
  }
}

function Invoke-RobocopyMirror {
  param(
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To
  )

  # Use small retry counts to avoid "hang forever" when something is locked.
  $common = @("/MIR", "/DCOPY:DA", "/COPY:DAT", "/R:3", "/W:1")
  robocopy $From $To @common | Out-Host
  $code = $LASTEXITCODE
  # robocopy exit codes: < 8 are success (0..7). >= 8 indicates failure.
  if ($code -ge 8) {
    throw "robocopy failed with exit code $code"
  }
}

function Copy-ItemWithRetry {
  param(
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To,
    [int]$Attempts = 6
  )
  for ($i = 0; $i -lt $Attempts; $i++) {
    try {
      Copy-Item -Force $From $To
      return
    } catch {
      if ($i -ge ($Attempts - 1)) { throw }
      Start-Sleep -Milliseconds 300
    }
  }
}

function Remove-DirectoryWithRetry {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Attempts = 6
  )
  if (-not (Test-Path $Path)) { return }
  for ($i = 0; $i -lt $Attempts; $i++) {
    try {
      Remove-Item -Recurse -Force $Path -ErrorAction Stop
      return
    } catch {
      if ($i -ge ($Attempts - 1)) { throw }
      Start-Sleep -Milliseconds 300
    }
  }
}

function Try-ExeVersion {
  param([Parameter(Mandatory = $true)][string]$ExePath)
  try {
    $out = & $ExePath "--version" 2>$null
    if ($out) {
      return ($out -join "`n").Trim()
    }
  } catch {
    # ignore
  }
  return ""
}

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    if (-not (Test-Path $Path)) { return "" }
    return ((Get-FileHash -Algorithm SHA256 $Path).Hash.ToString()).ToLowerInvariant()
  } catch {
    return ""
  }
}

function Resolve-IsccPath {
  $cmd = Get-Command "iscc.exe" -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }

  $candidates = @()
  if (${env:ProgramFiles(x86)}) {
    $candidates += (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\\ISCC.exe")
  }
  if ($env:ProgramFiles) {
    $candidates += (Join-Path $env:ProgramFiles "Inno Setup 6\\ISCC.exe")
  }

  foreach ($p in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path $p)) {
      return $p
    }
  }

  return ""
}

function Get-InstallerVersion {
  $tag = ""

  if ($env:GITHUB_REF_NAME) {
    $tag = $env:GITHUB_REF_NAME.ToString().Trim()
  }

  if ([string]::IsNullOrWhiteSpace($tag)) {
    try {
      $out = & git -C $RepoRoot describe --tags --always 2>$null
      if ($out) { $tag = ($out -join "`n").Trim() }
    } catch {
      $tag = ""
    }
  }

  if ($tag -match "^[vV](.+)$") {
    $tag = $Matches[1]
  }

  if ($null -eq $tag) { $tag = "" }
  $tag = $tag.ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($tag)) {
    return "0.0.0-local"
  }
  return $tag
}

function Build-Installer {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$OutputDir
  )

  $issPath = Join-Path $RepoRoot "dev\\installer\\WorkTrace.iss"
  if (-not (Test-Path $issPath)) {
    throw "Installer script not found: $issPath"
  }

  $iscc = Resolve-IsccPath
  if ([string]::IsNullOrWhiteSpace($iscc)) {
    throw "ISCC.exe (Inno Setup 6) not found. Install Inno Setup and retry (e.g. choco install innosetup -y)."
  }

  $version = Get-InstallerVersion
  $outputBase = "WorkTrace-Setup"
  Write-Host "[package] build installer ($version) -> $(Join-Path $OutputDir "$outputBase.exe")"
  $null = (& $iscc `
      "/DAppVersion=$version" `
      "/DAppSourceDir=$SourceDir" `
      "/DOutputDir=$OutputDir" `
      "/DOutputBaseFilename=$outputBase" `
      $issPath) | Out-Host
  $isccExitCode = $LASTEXITCODE

  if ($isccExitCode -ne 0) {
    throw "Installer build failed (iscc exit code $isccExitCode)."
  }

  $setupPath = Join-Path $OutputDir "$outputBase.exe"
  if (-not (Test-Path $setupPath)) {
    throw "Installer output not found: $setupPath"
  }

  return $setupPath
}

function Assert-SameHash {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To
  )
  $h1 = Get-Sha256 -Path $From
  $h2 = Get-Sha256 -Path $To
  if ([string]::IsNullOrWhiteSpace($h1) -or [string]::IsNullOrWhiteSpace($h2)) {
    Write-Host "[package] warn: skip hash verify for $Name (Get-FileHash unavailable?)"
    return
  }
  if ($h1 -ne $h2) {
    throw "Hash mismatch for $Name. From=$From To=$To (build and package are inconsistent)."
  }
  $short = if ($h2.Length -ge 12) { $h2.Substring(0, 12) } else { $h2 }
  Write-Host "[package] verified $Name sha256=$short..."
}

function Write-BuildInfo {
  param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [Parameter(Mandatory = $true)][string]$CoreExe,
    [Parameter(Mandatory = $true)][string]$CollectorExe
  )

  function Try-Git {
    param([Parameter(Mandatory = $true)][string[]]$Args)
    try {
      $out = & git -C $RepoRoot @Args 2>$null
      if ($out) { return ($out -join "`n").Trim() }
    } catch {
      # ignore
    }
    return ""
  }

  function Try-DetectGitHubRepo {
    # 1) CI/env override
    $envRepo = ""
    if ($env:RECORDERPHONE_UPDATE_REPO) {
      $envRepo = $env:RECORDERPHONE_UPDATE_REPO
    } elseif ($env:GITHUB_REPOSITORY) {
      $envRepo = $env:GITHUB_REPOSITORY
    }
    $envRepo = $envRepo.ToString().Trim()
    if ($envRepo -match "^[^/]+/[^/]+$") { return $envRepo }

    # 2) Parse from git remote url
    $u = Try-Git -Args @("remote", "get-url", "origin")
    if ([string]::IsNullOrWhiteSpace($u)) { return "" }
    $u = $u.Trim()

    # Examples:
    # - https://github.com/owner/repo.git
    # - git@github.com:owner/repo.git
    # - ssh://git@github.com/owner/repo.git
    $m = [regex]::Match($u, "github\.com[:/](?<owner>[^/]+)/(?<repo>[^/\.]+)(?:\.git)?$", "IgnoreCase")
    if ($m.Success) {
      $owner = $m.Groups["owner"].Value
      $repo = $m.Groups["repo"].Value
      if ($owner -and $repo) { return "$owner/$repo" }
    }

    return ""
  }

  $git = ""
  $git = Try-Git -Args @("rev-parse", "HEAD")
  $gitTag = Try-Git -Args @("describe", "--tags", "--exact-match")
  $gitDescribe = Try-Git -Args @("describe", "--tags", "--always")
  $githubRepo = Try-DetectGitHubRepo

  $info = @{
    builtAt = (Get-Date).ToString("o")
    repoRoot = $RepoRoot
    git = if ([string]::IsNullOrWhiteSpace($git)) { $null } else { $git }
    gitTag = if ([string]::IsNullOrWhiteSpace($gitTag)) { $null } else { $gitTag }
    gitDescribe = if ([string]::IsNullOrWhiteSpace($gitDescribe)) { $null } else { $gitDescribe }
    core = @{
      exe = "recorder_core.exe"
      version = (Try-ExeVersion -ExePath $CoreExe)
      sha256 = (Get-Sha256 -Path $CoreExe)
    }
    collector = @{
      exe = "windows_collector.exe"
      version = (Try-ExeVersion -ExePath $CollectorExe)
      sha256 = (Get-Sha256 -Path $CollectorExe)
    }
    update = @{
      githubRepo = if ([string]::IsNullOrWhiteSpace($githubRepo)) { $null } else { $githubRepo }
      assetSuffix = "-windows-setup.exe"
    }
  }

  $p = Join-Path $Dir "build-info.json"
  $info | ConvertTo-Json -Depth 6 | Out-File -Encoding utf8 $p
}

if (-not $NoOverlayUI) {
  Write-Host "[package] overlay UI template -> recorderphone_ui"
  & (Join-Path $RepoRoot "dev\\overlay-ui.ps1") -RepoRoot $RepoRoot
}

if (-not $NoBuild) {
  # Ensure builds don't fail due to locked target/release exes (dev agent / packaged agent still running).
  Write-Host "[package] stopping processes (pre-build)..."
  Stop-ProcessesAndWait -Names @("WorkTrace", "recorderphone_ui", "recorder_core", "windows_collector") -TimeoutSeconds 6

  Write-Host "[package] cargo build -p recorder_core --release"
  cargo build -p recorder_core --release
  Write-Host "[package] cargo build -p windows_collector --release"
  cargo build -p windows_collector --release
} else {
  Write-Host "[package] -NoBuild: skip cargo build"
}

$coreExe = Join-Path $RepoRoot "target\\release\\recorder_core.exe"
$collectorExe = Join-Path $RepoRoot "target\\release\\windows_collector.exe"

if (-not (Test-Path $coreExe)) {
  throw "recorder_core.exe not found at: $coreExe"
}
if (-not (Test-Path $collectorExe)) {
  throw "windows_collector.exe not found at: $collectorExe"
}

if (-not (Test-Path (Join-Path $RepoRoot "recorderphone_ui\\pubspec.yaml"))) {
  throw "Missing recorderphone_ui (Flutter project). Run: flutter create --platforms=windows recorderphone_ui"
}

if (-not $NoBuild) {
  Push-Location (Join-Path $RepoRoot "recorderphone_ui")
  Write-Host "[package] flutter build windows --release"
  flutter build windows --release
  Pop-Location
} else {
  Write-Host "[package] -NoBuild: skip flutter build"
}

$flutterReleaseDir = Join-Path $RepoRoot "recorderphone_ui\\build\\windows\\x64\\runner\\Release"
if (-not (Test-Path $flutterReleaseDir)) {
  throw "Flutter release output not found at: $flutterReleaseDir"
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $RepoRoot "dist\\windows\\WorkTrace"
}

function Stop-ProcessByExecutablePath {
  param([Parameter(Mandatory = $true)][string]$ExePath)
  if (-not (Test-Path $ExePath)) { return }
  $full = ""
  try {
    $full = (Resolve-Path $ExePath).Path
  } catch {
    return
  }
  $name = Split-Path $full -Leaf
  try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
      $ep = $p.ExecutablePath
      # ExecutablePath may be null without elevation; in that case stop by name (best effort).
      $shouldStop = ($null -eq $ep) -or ($ep -and ($ep -ieq $full))
      if (-not $shouldStop) { continue }
      Write-Host "[package] stopping $name pid=$($p.ProcessId)"
      Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
  } catch {
    # best effort
  }
}

function Stop-ProcessByNameBestEffort {
  param([Parameter(Mandatory = $true)][string]$Name)
  try {
    Get-Process $Name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  } catch {
    # best effort
  }
}

Write-Host "[package] output dir:  $OutDir"
$stagingDir = "$OutDir.__staging__"
$oldDir = "$OutDir.__old__"
Write-Host "[package] staging dir: $stagingDir"

# 1) Build a complete staged folder first (so we can swap quickly after stopping processes).
Remove-DirectoryWithRetry -Path $stagingDir -Attempts 6
New-Item -ItemType Directory -Force $stagingDir | Out-Null

Write-Host "[package] stage flutter release -> $stagingDir"
Invoke-RobocopyMirror -From $flutterReleaseDir -To $stagingDir

Write-Host "[package] stage agent binaries"
Copy-ItemWithRetry -From $coreExe -To (Join-Path $stagingDir "recorder_core.exe")
Copy-ItemWithRetry -From $collectorExe -To (Join-Path $stagingDir "windows_collector.exe")

# Rename UI entrypoint exe inside staging.
$stagedUiExe = Join-Path $stagingDir "recorderphone_ui.exe"
$stagedDistExe = Join-Path $stagingDir "WorkTrace.exe"
if (Test-Path $stagedUiExe) {
  Move-Item -Force $stagedUiExe $stagedDistExe
}
if (-not (Test-Path $stagedDistExe)) {
  $other = Get-ChildItem -Path $stagingDir -Filter "*.exe" -File -ErrorAction SilentlyContinue `
    | Where-Object { $_.Name -ne "recorder_core.exe" -and $_.Name -ne "windows_collector.exe" } `
    | Select-Object -First 1
  if ($other) {
    Move-Item -Force $other.FullName $stagedDistExe
  } else {
    throw "UI exe not found in staging: $stagingDir (check Flutter build output at: $flutterReleaseDir)"
  }
}

Write-Host "[package] write build-info.json"
Write-BuildInfo -Dir $stagingDir -CoreExe $coreExe -CollectorExe $collectorExe

# 2) Stop running packaged processes (so we can swap/overwrite).
Write-Host "[package] stopping running processes..."
Stop-ProcessByExecutablePath (Join-Path $OutDir "WorkTrace.exe")
Stop-ProcessByExecutablePath (Join-Path $OutDir "recorderphone_ui.exe")
Stop-ProcessByExecutablePath (Join-Path $OutDir "recorder_core.exe")
Stop-ProcessByExecutablePath (Join-Path $OutDir "windows_collector.exe")
# Also stop any remaining processes by image name (handles cases where ExecutablePath is not accessible).
Stop-ProcessByNameBestEffort "WorkTrace"
Stop-ProcessByNameBestEffort "recorderphone_ui"
Stop-ProcessByNameBestEffort "recorder_core"
Stop-ProcessByNameBestEffort "windows_collector"
Stop-ProcessesAndWait -Names @("WorkTrace", "recorderphone_ui", "recorder_core", "windows_collector") -TimeoutSeconds 8

# 3) Swap staged folder into place (atomic move if possible; otherwise in-place update).
try {
  Remove-DirectoryWithRetry -Path $oldDir -Attempts 3
} catch {
  # best effort
}

$renamedOld = $false
if (Test-Path $OutDir) {
  try {
    Move-Item -Force $OutDir $oldDir
    $renamedOld = $true
  } catch {
    try {
      Remove-DirectoryWithRetry -Path $OutDir -Attempts 6
    } catch {
      Write-Host "[package] warn: failed to rename/clean $OutDir; will update in-place. Close WorkTrace if files are locked."
    }
  }
}

$swapped = $false
try {
  if (-not (Test-Path $OutDir)) {
    Move-Item -Force $stagingDir $OutDir
    $swapped = $true
  }
} catch {
  $swapped = $false
}

if (-not $swapped) {
  if ($renamedOld -and -not (Test-Path $OutDir) -and (Test-Path $oldDir)) {
    try {
      Move-Item -Force $oldDir $OutDir
    } catch {
      # ignore
    }
  }

  # In-place update (avoid copying agent exes via robocopy; overwrite them separately with retry).
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  Write-Host "[package] in-place update -> $OutDir"
  Invoke-Robocopy -From $stagingDir -To $OutDir -ExcludeFiles @("recorder_core.exe", "windows_collector.exe")
  try {
    Copy-ItemWithRetry -From (Join-Path $stagingDir "recorder_core.exe") -To (Join-Path $OutDir "recorder_core.exe")
    Copy-ItemWithRetry -From (Join-Path $stagingDir "windows_collector.exe") -To (Join-Path $OutDir "windows_collector.exe")
  } catch {
    throw "Failed to overwrite agent binaries in $OutDir. Close WorkTrace / stop agent and retry."
  }

  # Ensure UI entrypoint exists (fallback if rename didn't propagate).
  $uiExe = Join-Path $OutDir "recorderphone_ui.exe"
  $distExe = Join-Path $OutDir "WorkTrace.exe"
  if ((Test-Path $uiExe) -and (-not (Test-Path $distExe))) {
    Move-Item -Force $uiExe $distExe
  } elseif (Test-Path $uiExe) {
    Move-Item -Force $uiExe $distExe
  }

  try {
    Remove-DirectoryWithRetry -Path $stagingDir -Attempts 6
  } catch {
    Write-Host "[package] warn: failed to remove staging dir $stagingDir (safe to delete manually)."
  }
} else {
  # Clean old folder if it exists (best-effort).
  try {
    Remove-DirectoryWithRetry -Path $oldDir -Attempts 3
  } catch {
    Write-Host "[package] note: kept previous version at $oldDir"
  }
}

# Resolve UI entrypoint exe in final output folder.
$distExe = Join-Path $OutDir "WorkTrace.exe"
if (-not (Test-Path $distExe)) {
  $other = Get-ChildItem -Path $OutDir -Filter "*.exe" -File -ErrorAction SilentlyContinue `
    | Where-Object { $_.Name -ne "recorder_core.exe" -and $_.Name -ne "windows_collector.exe" } `
    | Select-Object -First 1
  if ($other) {
    $distExe = $other.FullName
  } else {
    throw "UI exe not found in: $OutDir"
  }
}

# 4) Version self-check: verify packaged agent binaries match what we just built.
Assert-SameHash -Name "recorder_core.exe" -From $coreExe -To (Join-Path $OutDir "recorder_core.exe")
Assert-SameHash -Name "windows_collector.exe" -From $collectorExe -To (Join-Path $OutDir "windows_collector.exe")

if ($InstallProtocol) {
  if (-not (Test-Path $distExe)) {
    # Fallback if exe wasn't renamed.
    $distExe = Join-Path $OutDir "WorkTrace.exe"
  }
  Write-Host "[package] installing worktrace:// protocol -> $distExe"
  & (Join-Path $RepoRoot "dev\\install-worktrace-protocol.ps1") -RepoRoot $RepoRoot -ExePath $distExe
}

if ($Zip) {
  $zipPath = Join-Path (Split-Path $OutDir -Parent) "WorkTrace-windows.zip"
  if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
  Write-Host "[package] zip -> $zipPath"
  Compress-Archive -Path (Join-Path $OutDir "*") -DestinationPath $zipPath -Force
}

$setupPath = ""
if ($Installer) {
  $setupPath = Build-Installer `
    -RepoRoot $RepoRoot `
    -SourceDir $OutDir `
    -OutputDir (Split-Path $OutDir -Parent)
  if ($setupPath -is [array]) {
    $setupPath = ($setupPath `
      | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } `
      | Select-Object -Last 1)
  }
  if ($null -eq $setupPath) { $setupPath = "" }
  $setupPath = $setupPath.ToString().Trim()
}

Write-Host "[package] done."
Write-Host "Next:"
if (Test-Path $distExe) {
  Write-Host "  Start: $distExe"
} else {
  Write-Host "  Start: $uiExe"
}
if ($Zip) {
  Write-Host "  Zip:   $zipPath"
}
if ($Installer -and -not [string]::IsNullOrWhiteSpace($setupPath) -and (Test-Path $setupPath)) {
  Write-Host "  Setup: $setupPath"
}
