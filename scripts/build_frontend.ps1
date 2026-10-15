# Build the AngularDart frontend (ts2dart -> ngdart -> dart2js).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$frontend = Join-Path $root 'frontend'
$appDart = Join-Path $frontend 'app_dart'

$dart = 'D:\flutter\bin\cache\dart-sdk\bin\dart.exe'
if (-not (Test-Path $dart)) { $dart = 'dart' }

Push-Location $frontend
if (-not (Test-Path (Join-Path $frontend 'node_modules'))) { npm install --no-audit --no-fund }
node pipeline.js
Pop-Location

Push-Location $appDart
& $dart pub get
& $dart run build_runner build --release -o build
Pop-Location

Write-Host 'frontend built: frontend/app_dart/build/web'
