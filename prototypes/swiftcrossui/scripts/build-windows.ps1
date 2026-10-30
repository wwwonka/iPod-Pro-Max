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
    # Skip what's there: a re-run (e.g. to add a missing tool) must not reinstall Visual Studio.
    winget list --id $id --exact --accept-source-agreements | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Output "$id already installed"; return }
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
    # SwiftPM clones the dependencies with git.
    Winget-Install "Git.Git"
    # WinUIBackend: SDK at build time, Windows App Runtime at run time (SwiftCrossUI docs).
    # Its installer fails on ARM64 VMs (exit 2008); Visual Studio's 22621 SDK may be enough.
    try { Winget-Install "Microsoft.WindowsSDK.10.0.17763" } catch { Write-Warning $_ }
    $installer = Join-Path $env:TEMP "windowsappruntimeinstall-$arch.exe"
    Invoke-WebRequest "https://aka.ms/windowsappsdk/1.5/1.5.240205001-preview1/windowsappruntimeinstall-$arch.exe" -OutFile $installer
    & $installer --quiet
    Refresh-Path
}

foreach ($tool in "swift", "git") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Refresh-Path
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not installed: run again with -Setup (./build.sh --setup windows)." }
    }
}
swift --version

# Large clones (swift-cross-ui, swift-syntax) drop mid-transfer in the VM with "unexpected
# disconnect while reading sideband packet"; HTTP/1.1 and a bigger buffer avoid it.
# Some packages contain symlinks: Windows only lets a normal user create them in Developer Mode
# (which the Swift on Windows setup asks for), and git must be told to make real links.
$devMode = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
if ((Get-ItemProperty $devMode -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense -ne 1) {
    Write-Output "Turning on Developer Mode (approve the admin prompt in the VM)..."
    Start-Process reg.exe -Verb RunAs -Wait -ArgumentList 'add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1'
}
git config --global core.symlinks true
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000

# A running copy locks the exe and the link step fails.
Get-Process iPodProMaxProto -ErrorAction SilentlyContinue | Stop-Process -Force

# SF Symbols font for the icons, if put in local/ (never committed: see Symbols.swift). Installed
# for the current user only, which needs no admin approval.
$font = Join-Path $Source "local\SF-SYMBOLS4.TTF"
if (Test-Path $font) {
    $fonts = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
    $installed = Join-Path $fonts "SF-SYMBOLS4.TTF"
    if (-not (Test-Path $installed) -or (Get-FileHash $font).Hash -ne (Get-FileHash $installed).Hash) {
        New-Item -ItemType Directory $fonts -Force | Out-Null
        Copy-Item $font $installed -Force
        New-ItemProperty "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts" -Name "SF-Symbols (TrueType)" `
            -Value $installed -PropertyType String -Force | Out-Null
        Write-Output "SF Symbols font installed"
    }
}

# Local copy: building on the network share is slow, and some tools dislike UNC paths.
robocopy $Source $Work /MIR /XD .build .build-gtk dist .swiftpm /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }

# Only WinUI: left to its platform conditions, SwiftPM also builds the GTK backend here.
$env:SCUI_DEFAULT_BACKEND = "WinUIBackend"
Push-Location $Work
# Swift writes warnings to stderr, which "Stop" would turn into a failure: judge by exit code.
$ErrorActionPreference = "Continue"
try {
    swift package resolve
    if ($LASTEXITCODE -ne 0) { throw "swift package resolve failed" }
    & (Join-Path $env:ProgramFiles "Git\bin\bash.exe") scripts/patch-dependencies.sh .build
    if ($LASTEXITCODE -ne 0) { throw "patch-dependencies failed" }
    # The app icon in the executable's resources (Explorer, taskbar), from build.sh's dist/icons.
    $icon = Join-Path $Source "dist\icons\AppIcon.ico"
    $linkFlags = @()
    $rc = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter rc.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\(arm64|x64)\\" } | Sort-Object FullName -Descending | Select-Object -First 1
    if ((Test-Path $icon) -and $rc) {
        Copy-Item $icon "AppIcon.ico" -Force
        Set-Content "AppIcon.rc" '1 ICON "AppIcon.ico"'
        & $rc.FullName /nologo /fo AppIcon.res AppIcon.rc
        if ($LASTEXITCODE -eq 0) { $linkFlags = @("-Xlinker", (Join-Path $Work "AppIcon.res")) }
    } else { Write-Warning "No icon resource: dist\icons\AppIcon.ico or rc.exe missing." }
    swift build -c release --build-system native @linkFlags
    if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
    $bin = (swift build -c release --build-system native --show-bin-path).Trim()
    # Also next to the executable, for the window's icon (AppWindow.SetIcon takes a file).
    if (Test-Path "AppIcon.ico") { Copy-Item "AppIcon.ico" $bin -Force }
} finally { Pop-Location; $ErrorActionPreference = "Stop" }

# Self-contained folder: the exe, the DLLs built next to it, and the Swift runtime DLLs.
# Assembled locally, then mirrored to the share: deleting a folder on the Parallels share fails
# now and then (Linux uses rsync for the same reason).
$stage = Join-Path $Work "dist-windows"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory $stage | Out-Null
Copy-Item "$bin\iPodProMaxProto.exe" $stage
Copy-Item "$bin\AppIcon.ico" $stage -ErrorAction SilentlyContinue
foreach ($pattern in "*.dll", "*.pri", "*.winmd") { Copy-Item "$bin\$pattern" $stage -ErrorAction SilentlyContinue }
Get-ChildItem $bin -Directory -Filter *.resources | Copy-Item -Destination $stage -Recurse
# The app's own ffmpeg (Tools/ffmpeg/build.sh windows), next to the executable where MediaKit looks.
$ffArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$ffmpeg = Join-Path $Source "..\..\Tools\ffmpeg\dist\windows-$ffArch\ffmpeg.exe"
if (Test-Path $ffmpeg) { Copy-Item $ffmpeg $stage } else { Write-Warning "ffmpeg not built (Tools/ffmpeg/build.sh windows)" }
$swiftCore = where.exe swiftCore.dll 2>$null | Select-Object -First 1
if ($swiftCore) { Copy-Item (Join-Path (Split-Path $swiftCore) "*.dll") $stage }
else { Write-Warning "swiftCore.dll not found on PATH: the exe will only run where Swift is installed." }
$dist = Join-Path $Source "dist\windows"
robocopy $stage $dist /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy to $dist failed ($LASTEXITCODE)" }
Write-Output "OK: $dist\iPodProMaxProto.exe"

if ($Run) {
    # Started from the local build folder: running WinUI from the \\Mac share is slow and fragile.
    Get-Process iPodProMaxProto -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($swiftCore) { $env:Path = (Split-Path $swiftCore) + ";" + $env:Path }
    Start-Process (Join-Path $bin "iPodProMaxProto.exe") -WorkingDirectory $Work
    Write-Output "Launched"
}
