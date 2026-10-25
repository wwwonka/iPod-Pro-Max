# Started detached by ../build.sh: runs build-windows.ps1 with its arguments, writes everything it
# prints to dist\windows-vm.log and its exit code to dist\windows-vm.exit, even when it throws.
param([string]$Source, [switch]$Setup, [switch]$Run)
$dist = Join-Path $Source "dist"
$log = Join-Path $dist "windows-vm.log"
$code = 1
try {
    & (Join-Path $PSScriptRoot "build-windows.ps1") -Source $Source -Setup:$Setup -Run:$Run *> $log
    $code = if ($?) { 0 } else { 1 }
} catch {
    $_ | Out-String | Add-Content $log
}
Set-Content (Join-Path $dist "windows-vm.exit") $code
