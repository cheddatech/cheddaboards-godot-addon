# Run the SDK smoke test on Windows.  Usage:  .\smoke\run.ps1
# Requires Godot 4 on PATH as godot4/godot, or $env:GODOT = "C:\path\Godot.exe"
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$godot = $env:GODOT
if (-not $godot) { $godot = (Get-Command godot4 -ErrorAction SilentlyContinue).Source }
if (-not $godot) { $godot = (Get-Command godot  -ErrorAction SilentlyContinue).Source }
if (-not $godot) { Write-Error "Godot 4 binary not found; set `$env:GODOT"; exit 2 }

if (Test-Path addons) { Remove-Item -Recurse -Force addons }
New-Item -ItemType Directory -Path addons\cheddaboards | Out-Null
Copy-Item -Recurse -Force ..\addons\cheddaboards\* addons\cheddaboards\

& $godot --headless --path . --import 2>$null | Out-Null
& $godot --headless --path . smoke.tscn
exit $LASTEXITCODE
