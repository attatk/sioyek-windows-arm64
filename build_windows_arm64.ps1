# Builds a native Windows ARM64 sioyek (e.g. for Snapdragon X laptops) and packages it.
#
# Usage: .\build_windows_arm64.ps1 -QtDir C:\Qt\<version>\msvc2022_arm64 [-Portable] [-Installer]
#                                  [-CertificatePath cert.pfx -CertificatePassword <password>]
#
# Requires Visual Studio with the ARM64 C++ build tools and an MSVC arm64 Qt kit
# that includes Qt Speech. Produces sioyek-release-windows-arm64[-portable].zip.
#
#   -Portable     builds a portable sioyek that keeps its config and database next to sioyek.exe
#   -Installer    also builds sioyek-setup-windows-arm64.exe (requires Inno Setup 6)
#   -CertificatePath / -CertificatePassword
#                 signs sioyek.exe (and the installer) with signtool; the password can also be
#                 passed in the SIOYEK_SIGN_CERT_PASSWORD environment variable

param(
    [Parameter(Mandatory = $true)]
    [string]$QtDir,
    [switch]$Portable,
    [switch]$Installer,
    [string]$CertificatePath,
    [string]$CertificatePassword = $env:SIOYEK_SIGN_CERT_PASSWORD
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Invoke-Checked([scriptblock]$command) {
    & $command
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $command" }
}

function Invoke-Sign([string]$file) {
    if (-not $CertificatePath) { return }
    Write-Host "Signing $file"
    Invoke-Checked { signtool sign /f $CertificatePath /p $CertificatePassword /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $file }
}

if ($Portable -and $Installer) { throw 'The installer is built from the regular (non-portable) package; build it without -Portable' }

$QtDir = (Resolve-Path $QtDir).Path
if (-not (Test-Path (Join-Path $QtDir 'bin\qmake.exe'))) { throw "qmake.exe not found in $QtDir\bin" }
if ($CertificatePath) { $CertificatePath = (Resolve-Path $CertificatePath).Path }

# --- toolchain -------------------------------------------------------------
if ($env:VSCMD_ARG_TGT_ARCH -ne 'arm64') {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
    if (-not $vsPath) { throw 'No Visual Studio installation with the ARM64 C++ build tools was found' }
    $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $env:PATH = "$(Split-Path $vswhere);$env:PATH"  # VsDevCmd looks for vswhere on PATH
    & (Join-Path $vsPath 'Common7\Tools\Launch-VsDevShell.ps1') -Arch arm64 -HostArch $hostArch -SkipAutomaticLocation | Out-Null
    Set-Location $PSScriptRoot
}
$env:PATH = "$QtDir\bin;$env:PATH"

$iscc = $null
if ($Installer) {
    $iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
    if (-not $iscc) {
        $iscc = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) was not found; install it from https://jrsoftware.org/isdl.php' }
}

# --- dependencies ----------------------------------------------------------
Invoke-Checked { git submodule update --init --recursive }

& .\scripts\mupdf_win_arm64.ps1

Push-Location zlib
try {
    # clean first so a leftover x64 zlib.lib is never linked
    Invoke-Checked { nmake -nologo -f win32/Makefile.msc clean }
    Invoke-Checked { nmake -nologo -f win32/Makefile.msc zlib.lib }
}
finally { Pop-Location }

# --- sioyek ----------------------------------------------------------------
# a portable build looks for its config files and database next to sioyek.exe instead of in AppData
$qmakeArgs = @('-tp', 'vc', 'CONFIG+=release', 'pdf_viewer_build_config.pro')
if (-not $Portable) { $qmakeArgs = @('DEFINES+=NON_PORTABLE') + $qmakeArgs }
Invoke-Checked { qmake @qmakeArgs }
# msbuild would default to Win32, so pass the platform qmake generated (ARM64)
$sioyekPlatform = (Select-Xml -Path sioyek.vcxproj -Namespace @{ m = 'http://schemas.microsoft.com/developer/msbuild/2003' } `
    -XPath '//m:ProjectConfiguration/m:Platform' | Select-Object -First 1).Node.InnerText
Invoke-Checked { msbuild sioyek.vcxproj -m -nologo -verbosity:minimal -p:Configuration=Release "-p:Platform=$sioyekPlatform" }

# --- package ---------------------------------------------------------------
$releaseDir = 'sioyek-release-windows-arm64'
if (Test-Path $releaseDir) { Remove-Item -Recurse -Force $releaseDir }
New-Item -ItemType Directory $releaseDir | Out-Null

Copy-Item release\sioyek.exe $releaseDir
Invoke-Sign (Join-Path $releaseDir 'sioyek.exe')
Copy-Item pdf_viewer\keys.config, pdf_viewer\prefs.config, tutorial.pdf $releaseDir
Copy-Item -Recurse pdf_viewer\shaders (Join-Path $releaseDir 'shaders')

Invoke-Checked { windeployqt --qmldir .\pdf_viewer\touchui --release --no-compiler-runtime (Join-Path $releaseDir 'sioyek.exe') }

# the DLLs in windows_runtime\ are x64 only; ship the ARM64 MSVC runtime app-locally instead
$crtDir = Get-ChildItem (Join-Path $env:VCToolsRedistDir 'arm64') -Directory -Filter 'Microsoft.VC*.CRT' | Select-Object -First 1
if (-not $crtDir) { throw "ARM64 MSVC runtime not found under $env:VCToolsRedistDir" }
Copy-Item (Join-Path $crtDir.FullName '*.dll') $releaseDir

$zipName = 'sioyek-release-windows-arm64.zip'
if ($Portable) {
    Copy-Item pdf_viewer\keys_user.config, pdf_viewer\prefs_user.config $releaseDir
    $zipName = 'sioyek-release-windows-arm64-portable.zip'
}

if (Test-Path $zipName) { Remove-Item $zipName }
if (Get-Command 7z -ErrorAction SilentlyContinue) {
    Invoke-Checked { 7z a $zipName $releaseDir }
}
else {
    Compress-Archive -Path $releaseDir -DestinationPath $zipName
}
Write-Host "Done: $zipName"

if ($Installer) {
    $version = (Select-String -Path pdf_viewer_build_config.pro -Pattern '^VERSION\s*=\s*(\S+)').Matches[0].Groups[1].Value
    $installerName = 'sioyek-setup-windows-arm64'
    Invoke-Checked {
        & $iscc /Q "/DSourceDir=$(Resolve-Path $releaseDir)" "/DOutputDir=$PSScriptRoot" "/DOutputBaseFilename=$installerName" `
            '/DArch=arm64' "/DAppVersion=$version" scripts\sioyek_installer.iss
    }
    Invoke-Sign "$installerName.exe"
    Write-Host "Done: $installerName.exe"
}
