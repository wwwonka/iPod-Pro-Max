# Builds and runs in the Windows VM by hand (build.sh does this for you). Pass --library <path>
# to pick a library.json.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
# Only WinUI: otherwise SwiftPM also builds the GTK backend and fails.
$env:SCUI_DEFAULT_BACKEND = "WinUIBackend"
swift run --build-system native iPodProMaxProto @args
