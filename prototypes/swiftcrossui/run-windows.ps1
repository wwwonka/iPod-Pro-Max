# Builds and runs with WinUI 3 (DefaultBackend on Windows). Pass --library <path> to pick a library.json.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
swift run iPodProMaxProto @args
