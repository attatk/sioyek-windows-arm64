# Builds a native Windows ARM64 sioyek (e.g. for Snapdragon X laptops) and packages it.
#
# Usage: .\build_windows_arm64.ps1 -QtDir C:\Qt\<version>\msvc2022_arm64 [-Portable]
#
# Requires Visual Studio with the ARM64 C++ build tools and an MSVC arm64 Qt kit
# that includes Qt Speech. Produces sioyek-release-windows-arm64[-portable].zip

param(
    [Parameter(Mandatory = $true)]
    [string]$QtDir,
    [switch]$Portable
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Invoke-Checked([scriptblock]$command) {
    & $command
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $command" }
}

$QtDir = (Resolve-Path $QtDir).Path
if (-not (Test-Path (Join-Path $QtDir 'bin\qmake.exe'))) { throw "qmake.exe not found in $QtDir\bin" }

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
Invoke-Checked { qmake -tp vc "DEFINES+=NON_PORTABLE" "CONFIG+=release" pdf_viewer_build_config.pro }
# msbuild would default to Win32, so pass the platform qmake generated (ARM64)
$sioyekPlatform = (Select-Xml -Path sioyek.vcxproj -Namespace @{ m = 'http://schemas.microsoft.com/developer/msbuild/2003' } `
    -XPath '//m:ProjectConfiguration/m:Platform' | Select-Object -First 1).Node.InnerText
Invoke-Checked { msbuild sioyek.vcxproj -m -nologo -verbosity:minimal -p:Configuration=Release "-p:Platform=$sioyekPlatform" }

# --- package ---------------------------------------------------------------
$releaseDir = 'sioyek-release-windows-arm64'
if (Test-Path $releaseDir) { Remove-Item -Recurse -Force $releaseDir }
New-Item -ItemType Directory $releaseDir | Out-Null

Copy-Item release\sioyek.exe $releaseDir
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
