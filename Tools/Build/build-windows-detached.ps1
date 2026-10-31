# Started detached by ../build.sh: runs build-windows.ps1 with its arguments, writes everything it
# prints to .build-work\windows-vm.log and its exit code to .build-work\windows-vm.exit, even when it throws.
param([string]$Source, [switch]$Setup, [switch]$Run)
$dist = Join-Path $Source ".build-work"
$log = Join-Path $dist "windows-vm.log"
$code = 1
try {
    & (Join-Path $PSScriptRoot "build-windows.ps1") -Source $Source -Setup:$Setup -Run:$Run *> $log
    $code = if ($?) { 0 } else { 1 }
} catch {
    $_ | Out-String | Add-Content $log
}
# Written under a temporary name, then renamed: the Mac waits for this file and must never see
# it empty.
$exit = Join-Path $dist "windows-vm.exit"
Set-Content "$exit.tmp" $code
Move-Item "$exit.tmp" $exit -Force
