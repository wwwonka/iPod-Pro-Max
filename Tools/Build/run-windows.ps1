# Builds and runs in the Windows VM by hand (build.sh does this for you). Pass --library <path>
# to pick a library.json.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "../..")
# Only WinUI: otherwise SwiftPM also builds the GTK backend and fails.
$env:SCUI_DEFAULT_BACKEND = "WinUIBackend"
swift package resolve
if ($LASTEXITCODE -ne 0) { throw "swift package resolve failed" }
& (Join-Path $env:ProgramFiles "Git/bin/bash.exe") Tools/Build/patch-dependencies.sh .build
if ($LASTEXITCODE -ne 0) { throw "patch-dependencies failed" }
swift run --build-system native iPodProMaxApp @args
