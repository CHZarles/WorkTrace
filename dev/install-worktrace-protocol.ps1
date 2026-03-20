param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [string]$ExePath = ""
)

$ErrorActionPreference = "Stop"

Set-Location $RepoRoot

$protocol = "worktrace"
$keyPath = "HKCU:\\Software\\Classes\\$protocol"
$legacyKeyPath = "HKCU:\\Software\\Classes\\recorderphone"

function Resolve-DefaultExePath {
  $candidates = @(
    (Join-Path $RepoRoot "dist\\windows\\WorkTrace\\WorkTrace.exe"),
    (Join-Path $RepoRoot "dist\\windows\\RecorderPhone\\RecorderPhone.exe"),
    (Join-Path $RepoRoot "dist\\windows\\WorkTrace\\recorderphone_ui.exe"),
    (Join-Path $RepoRoot "dist\\windows\\RecorderPhone\\recorderphone_ui.exe"),
    (Join-Path $RepoRoot "recorderphone_ui\\build\\windows\\x64\\runner\\Debug\\recorderphone_ui.exe"),
    (Join-Path $RepoRoot "recorderphone_ui\\build\\windows\\x64\\runner\\Release\\recorderphone_ui.exe")
  )
  foreach ($p in $candidates) {
    if (Test-Path $p) { return (Resolve-Path $p).Path }
  }
  return ""
}

if ([string]::IsNullOrWhiteSpace($ExePath)) {
  $ExePath = Resolve-DefaultExePath
} else {
  $p = $ExePath
  # Accept relative paths: resolve against repo root.
  if (-not (Test-Path $p)) {
    $p = Join-Path $RepoRoot $ExePath
  }
  if (Test-Path $p) {
    $ExePath = (Resolve-Path $p).Path
  } else {
    Write-Host "[protocol] Exe not found: $ExePath"
    $ExePath = Resolve-DefaultExePath
  }
}

if ([string]::IsNullOrWhiteSpace($ExePath) -or -not (Test-Path $ExePath)) {
  Write-Host "[protocol] WorkTrace.exe / recorderphone_ui.exe not found."
  Write-Host "  Expected one of:"
  Write-Host "    $RepoRoot\\dist\\windows\\WorkTrace\\WorkTrace.exe"
  Write-Host "    $RepoRoot\\dist\\windows\\RecorderPhone\\RecorderPhone.exe"
  Write-Host "    $RepoRoot\\recorderphone_ui\\build\\windows\\x64\\runner\\Debug\\recorderphone_ui.exe"
  Write-Host "    $RepoRoot\\recorderphone_ui\\build\\windows\\x64\\runner\\Release\\recorderphone_ui.exe"
  Write-Host ""
  Write-Host "Fix:"
  Write-Host "  1) Build/run the Flutter Windows app once:"
  Write-Host "       cd $RepoRoot\\recorderphone_ui"
  Write-Host "       flutter run -d windows"
  Write-Host "  2) Or build a packaged folder:"
  Write-Host "       cd $RepoRoot"
  Write-Host "       powershell -ExecutionPolicy Bypass -File .\\dev\\package-windows.ps1 -InstallProtocol"
  Write-Host "  3) Re-run this script, or pass -ExePath explicitly."
  exit 2
}

Write-Host "[protocol] Installing ${protocol}:// handler -> $ExePath"

if (Test-Path $legacyKeyPath) {
  try {
    Remove-Item -Path $legacyKeyPath -Recurse -Force
    Write-Host "[protocol] Removed legacy recorderphone:// handler."
  } catch {
    Write-Host "[protocol] Could not remove legacy recorderphone:// handler; continuing."
  }
}

New-Item -Path $keyPath -Force | Out-Null
New-ItemProperty -Path $keyPath -Name "(default)" -Value "URL:WorkTrace Protocol" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $keyPath -Name "URL Protocol" -Value "" -PropertyType String -Force | Out-Null

$cmdKey = Join-Path $keyPath "shell\\open\\command"
New-Item -Path $cmdKey -Force | Out-Null

# Command must be: "<exePath>" "%1"
$command = "`"$ExePath`" `"%1`""
New-ItemProperty -Path $cmdKey -Name "(default)" -Value $command -PropertyType String -Force | Out-Null

Write-Host "[protocol] Done."
Write-Host "Test:"
Write-Host "  Win+R -> ${protocol}://review"
