# Runs inside the Windows VM, called by ../build.sh through prlctl exec (or by hand in PowerShell).
#   build-windows.ps1 -Source \\Mac\Home\...\swiftcrossui [-Setup]
# -Setup installs Visual Studio Build Tools, Swift, the Windows SDK and the Windows App Runtime
# (one time; Windows will ask for admin approval in the VM).
param(
    [string]$Source = (Split-Path $PSScriptRoot -Parent),
    [string]$Work = "C:\dev\swiftcrossui",
    [switch]$Setup,
    [switch]$Run
)
$ErrorActionPreference = "Stop"

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
}

function Winget-Install([string]$id, [string[]]$extra = @()) {
    winget install --id $id --exact --accept-package-agreements --accept-source-agreements @extra
    # -1978335189: already installed, nothing to upgrade.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) { throw "winget $id failed ($LASTEXITCODE)" }
}

if ($Setup) {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $vcTools = if ($arch -eq "arm64") { "Microsoft.VisualStudio.Component.VC.Tools.ARM64" } else { "Microsoft.VisualStudio.Component.VC.Tools.x86.x64" }
    # Toolchain prerequisites as listed on swift.org/install/windows.
    Winget-Install "Microsoft.VisualStudio.2022.Community" @("--force", "--custom",
        "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add $vcTools")
    Winget-Install "Swift.Toolchain"
    # WinUIBackend: SDK at build time, Windows App Runtime at run time (SwiftCrossUI docs).
    Winget-Install "Microsoft.WindowsSDK.10.0.17763"
    $installer = Join-Path $env:TEMP "windowsappruntimeinstall-$arch.exe"
    Invoke-WebRequest "https://aka.ms/windowsappsdk/1.5/1.5.240205001-preview1/windowsappruntimeinstall-$arch.exe" -OutFile $installer
    & $installer --quiet
    Refresh-Path
}

if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    Refresh-Path
    if (-not (Get-Command swift -ErrorAction SilentlyContinue)) { throw "Swift is not installed: run again with -Setup (./build.sh --setup windows)." }
}
swift --version

# Local copy: building on the network share is slow, and some tools dislike UNC paths.
robocopy $Source $Work /MIR /XD .build .build-gtk dist .swiftpm /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }

Push-Location $Work
try {
    swift build -c release
    if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
    $bin = (swift build -c release --show-bin-path).Trim()
} finally { Pop-Location }

# Self-contained folder: the exe, the DLLs built next to it, and the Swift runtime DLLs.
$dist = Join-Path $Source "dist\windows"
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory $dist | Out-Null
Copy-Item "$bin\iPodProMaxProto.exe" $dist
foreach ($pattern in "*.dll", "*.pri", "*.winmd") { Copy-Item "$bin\$pattern" $dist -ErrorAction SilentlyContinue }
Get-ChildItem $bin -Directory -Filter *.resources | Copy-Item -Destination $dist -Recurse
$swiftCore = where.exe swiftCore.dll 2>$null | Select-Object -First 1
if ($swiftCore) { Copy-Item (Join-Path (Split-Path $swiftCore) "*.dll") $dist }
else { Write-Warning "swiftCore.dll not found on PATH: the exe will only run where Swift is installed." }
Write-Output "OK: $dist\iPodProMaxProto.exe"

if ($Run) {
    # Started from the local build folder: running WinUI from the \\Mac share is slow and fragile.
    Get-Process iPodProMaxProto -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($swiftCore) { $env:Path = (Split-Path $swiftCore) + ";" + $env:Path }
    Start-Process (Join-Path $bin "iPodProMaxProto.exe") -WorkingDirectory $Work
    Write-Output "Launched"
}
