param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [string]$Device = "windows"
)

$ErrorActionPreference = "Stop"

Set-Location $RepoRoot

Write-Host "[run-ui] repo: $RepoRoot"

powershell -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "dev\\overlay-ui.ps1") -RepoRoot $RepoRoot

Push-Location (Join-Path $RepoRoot "worktrace_ui")
Write-Host "[run-ui] flutter run -d $Device"
flutter run -d $Device
Pop-Location

