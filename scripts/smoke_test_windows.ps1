# Checks that a packaged Windows sioyek actually starts.
#
# Usage: .\scripts\smoke_test_windows.ps1 -PackageDir sioyek-release-windows-arm64 [-LaunchGui]
#
# Always checks that the files sioyek needs at runtime were packaged and that `sioyek.exe --version`
# runs (a missing DLL makes the process fail before main). With -LaunchGui it also opens tutorial.pdf
# and fails if sioyek exits with an error within a few seconds; this needs a working OpenGL driver.

param(
    [Parameter(Mandatory = $true)]
    [string]$PackageDir,
    [switch]$LaunchGui,
    [int]$GuiSeconds = 15
)

$ErrorActionPreference = 'Stop'
$PackageDir = (Resolve-Path $PackageDir).Path
$exe = Join-Path $PackageDir 'sioyek.exe'

$required = @(
    'sioyek.exe', 'prefs.config', 'keys.config', 'tutorial.pdf', 'shaders',
    'Qt6Core.dll', 'Qt6Gui.dll', 'Qt6Widgets.dll', 'Qt6Network.dll', 'Qt6OpenGL.dll',
    'platforms/qwindows.dll',
    # Qt 6 uses Windows' own TLS (schannel) for HTTPS, e.g. for downloading papers and the AI endpoints
    'tls/qschannelbackend.dll',
    'vcruntime140.dll', 'msvcp140.dll'
)
$missing = $required | Where-Object { -not (Test-Path (Join-Path $PackageDir $_)) }
if ($missing) { throw "Missing from ${PackageDir}: $($missing -join ', ')" }
Write-Host 'All required files are packaged'

$out = New-TemporaryFile
$err = New-TemporaryFile
$process = Start-Process -FilePath $exe -ArgumentList '--version' -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $out.FullName -RedirectStandardError $err.FullName
$version = (Get-Content $out.FullName -Raw)
if ($process.ExitCode -ne 0) {
    throw ("sioyek.exe --version failed with exit code 0x{0:X8}`n{1}" -f $process.ExitCode, (Get-Content $err.FullName -Raw))
}
if ($version -notmatch 'sioyek') { throw "Unexpected --version output: '$version'" }
Write-Host "sioyek.exe --version: $($version.Trim())"

if ($LaunchGui) {
    $gui = Start-Process -FilePath $exe -ArgumentList "`"$(Join-Path $PackageDir 'tutorial.pdf')`"" -PassThru
    $exited = $gui.WaitForExit($GuiSeconds * 1000)
    if ($exited) {
        if ($gui.ExitCode -ne 0) { throw ("sioyek exited with code 0x{0:X8} while opening tutorial.pdf" -f $gui.ExitCode) }
        Write-Warning 'sioyek exited by itself (with exit code 0) while opening tutorial.pdf'
    }
    else {
        Stop-Process -Id $gui.Id -Force
        Write-Host "sioyek was still running after $GuiSeconds seconds"
    }
}
