param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

Set-Location $RepoRoot

Write-Host "[overlay-ui] repo: $RepoRoot"

if (-not (Test-Path ".\\ui_flutter\\template\\lib")) {
  throw "Missing ui_flutter\\template\\lib. Run from the WorkTrace repo."
}

if (-not (Test-Path ".\\ui_flutter\\template\\assets")) {
  throw "Missing ui_flutter\\template\\assets. Run from the WorkTrace repo."
}

if (-not (Test-Path ".\\worktrace_ui")) {
  throw "Missing worktrace_ui. Create the Flutter project on Windows first."
}

function Invoke-RobocopyMirror {
  param(
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To
  )

  # Avoid the default "retry forever" behaviour.
  robocopy $From $To /MIR /R:3 /W:1 | Out-Host
  $code = $LASTEXITCODE
  if ($code -ge 8) {
    throw "robocopy failed with exit code $code"
  }
}

Write-Host "[overlay-ui] robocopy template\\lib -> worktrace_ui\\lib"
Invoke-RobocopyMirror -From ".\\ui_flutter\\template\\lib" -To ".\\worktrace_ui\\lib"

Write-Host "[overlay-ui] robocopy template\\assets -> worktrace_ui\\assets"
Invoke-RobocopyMirror -From ".\\ui_flutter\\template\\assets" -To ".\\worktrace_ui\\assets"

Write-Host "[overlay-ui] copy template\\pubspec.yaml -> worktrace_ui\\pubspec.yaml"
Copy-Item -Force ".\\ui_flutter\\template\\pubspec.yaml" ".\\worktrace_ui\\pubspec.yaml"

Push-Location ".\\worktrace_ui"
Write-Host "[overlay-ui] flutter pub get"
flutter pub get
Pop-Location

Write-Host "[overlay-ui] done. Next:"
Write-Host "  cd .\\worktrace_ui"
Write-Host "  flutter run -d windows"
