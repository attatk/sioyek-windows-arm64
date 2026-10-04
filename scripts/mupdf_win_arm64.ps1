# Adds an ARM64 platform to mupdf's Visual Studio projects and builds libmupdf for it.
#
# mupdf only ships Win32/x64 configurations, so this clones the x64 configurations
# (Win32 for bin2coff, which has no x64 one) into ARM64 ones, drops x86-only SIMD
# settings from the clones, and applies mupdf_arm64.patch (bin2coff ARM64 COFF output,
# _M_ARM64 endianness detection).
# Safe to run more than once: already patched projects are left alone.
#
# Must be run from a VS developer shell targeting arm64 (msbuild on PATH).
# Output: mupdf\platform\win32\ARM64\Release\libmupdf.lib

param(
    [string]$MupdfDir = (Join-Path $PSScriptRoot '..\mupdf'),
    [string]$Configuration = 'Release',
    [switch]$PatchOnly
)

$ErrorActionPreference = 'Stop'

$MupdfDir = (Resolve-Path $MupdfDir).Path
$win32Dir = Join-Path $MupdfDir 'platform\win32'
$newPlatform = 'ARM64'

# project name -> platform whose configurations are cloned
$projects = [ordered]@{
    'bin2coff'      = 'Win32'
    'libresources'  = 'x64'
    'libpkcs7'      = 'x64'
    'libthirdparty' = 'x64'
    'libleptonica'  = 'x64'
    'libtesseract'  = 'x64'
    'libextract'    = 'x64'
    'libharfbuzz'   = 'x64'
    'libzxing'      = 'x64'
    'libmubarcode'  = 'x64'
    'libmupdf'      = 'x64'
}

# x86-only defines/settings that must not leak into ARM64 builds
$x86Defines = @('HAVE_AVX', 'HAVE_AVX2', 'HAVE_SSE4_1', 'HAVE_FMA', '__AVX__', '__AVX2__', '__FMA__', '__SSE4_1__')
$x86Elements = @('TargetMachine', 'TargetEnvironment', 'EnableEnhancedInstructionSet')

function Add-Arm64Platform([string]$projectPath, [string]$fromPlatform) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($projectPath)

    $all = @($doc.GetElementsByTagName('*'))

    $alreadyPatched = $all | Where-Object {
        $_.LocalName -eq 'ProjectConfiguration' -and $_.GetAttribute('Include').EndsWith("|$newPlatform")
    }
    if ($alreadyPatched) {
        Write-Host "  $(Split-Path -Leaf $projectPath): already has $newPlatform"
        return
    }

    $fromCondition = "|$fromPlatform'"
    $toCondition = "|$newPlatform'"

    $sources = $all | Where-Object {
        ($_.LocalName -eq 'ProjectConfiguration' -and $_.GetAttribute('Include').EndsWith("|$fromPlatform")) -or
        ($_.HasAttribute('Condition') -and $_.GetAttribute('Condition').Contains($fromCondition))
    }
    # elements nested in another matched element are cloned along with their ancestor
    $sources = $sources | Where-Object {
        $ancestor = $_.ParentNode
        while ($ancestor -is [System.Xml.XmlElement] -and $sources -notcontains $ancestor) { $ancestor = $ancestor.ParentNode }
        -not ($ancestor -is [System.Xml.XmlElement])
    }

    $cloned = 0
    foreach ($source in $sources) {
        $clone = $source.CloneNode($true)

        if ($clone.LocalName -eq 'ProjectConfiguration') {
            $include = $clone.GetAttribute('Include') -replace "\|$fromPlatform`$", "|$newPlatform"
            $clone.SetAttribute('Include', $include)
            foreach ($platform in @($clone.GetElementsByTagName('Platform'))) {
                $platform.InnerText = $newPlatform
            }
        }
        else {
            $clone.SetAttribute('Condition', $clone.GetAttribute('Condition').Replace($fromCondition, $toCondition))
        }

        foreach ($element in @($clone.GetElementsByTagName('*'))) {
            if ($element.HasAttribute('Condition')) {
                $element.SetAttribute('Condition', $element.GetAttribute('Condition').Replace($fromCondition, $toCondition))
            }
            if ($x86Elements -contains $element.LocalName) {
                [void]$element.ParentNode.RemoveChild($element)
            }
            elseif ($element.LocalName -eq 'PreprocessorDefinitions') {
                $defines = $element.InnerText -split ';' | Where-Object { $x86Defines -notcontains $_ }
                $element.InnerText = $defines -join ';'
            }
        }

        # keep the source's indentation: source, newline+indent, clone
        [void]$source.ParentNode.InsertAfter($clone, $source)
        if ($source.PreviousSibling -is [System.Xml.XmlWhitespace]) {
            [void]$source.ParentNode.InsertAfter($source.PreviousSibling.CloneNode($false), $source)
        }
        $cloned++
    }

    # write back without changing the file's BOM / encoding
    $bytes = [System.IO.File]::ReadAllBytes($projectPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $writer = New-Object System.IO.StreamWriter($projectPath, $false, (New-Object System.Text.UTF8Encoding($hasBom)))
    try { $doc.Save($writer) } finally { $writer.Dispose() }
    Write-Host "  $(Split-Path -Leaf $projectPath): added $cloned $newPlatform entries (from $fromPlatform)"
}

Write-Host "Adding $newPlatform platform to mupdf projects"
foreach ($name in $projects.Keys) {
    Add-Arm64Platform (Join-Path $win32Dir "$name.vcxproj") $projects[$name]
}

Write-Host 'Applying mupdf ARM64 source fixes (bin2coff, endianness)'
$sourcePatch = Join-Path $PSScriptRoot 'mupdf_arm64.patch'
git -C $MupdfDir apply --reverse --check $sourcePatch 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host '  already applied'
}
else {
    git -C $MupdfDir apply $sourcePatch
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply mupdf_arm64.patch' }
}

if ($PatchOnly) { return }

# mupdf's projects pin the VS 2019 toolset (v142); use the one that ships with the active VS instead
$toolsets = @{ '16.0' = 'v142'; '17.0' = 'v143'; '18.0' = 'v145' }
$toolset = $toolsets[$env:VisualStudioVersion]
if (-not $toolset) { throw "Unknown VisualStudioVersion '$env:VisualStudioVersion'; run from a VS developer shell" }

Write-Host "Building libmupdf ($Configuration|$newPlatform, $toolset)"
msbuild (Join-Path $win32Dir 'libmupdf.vcxproj') -m -nologo -verbosity:minimal `
    "-p:Configuration=$Configuration" "-p:Platform=$newPlatform" "-p:PlatformToolset=$toolset" `
    '-p:MultiProcessorCompilation=true'
if ($LASTEXITCODE -ne 0) { throw "libmupdf build failed with exit code $LASTEXITCODE" }
