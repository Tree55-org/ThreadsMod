[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceApkSet,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ResolutionPath,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$AndroidSdk,
    [Parameter(Mandatory)][string]$BuildToolsVersion,
    [Parameter(Mandatory)][string]$Java,
    [Parameter(Mandatory)][string]$ApkEditorJar
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

function Invoke-CapturedNative {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $lines = @(& $Command @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        exitCode = [int]$exitCode
        text = [string]::Join("`n", $lines)
    }
}

function Invoke-RequiredNative {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Label
    )

    $result = Invoke-CapturedNative -Command $Command -Arguments $Arguments
    if ($result.exitCode -ne 0) {
        throw "$Label failed with exit code $($result.exitCode)."
    }
    return $result
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n", "`n").Replace("`r", "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ZipEntryDigestMap {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('root-dex', 'native-library', 'density-resource', 'signature')][string]$Kind
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
    try {
        $map = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($entry in @($archive.Entries)) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrEmpty([string]$entry.Name)) { continue }
            $selected = switch ($Kind) {
                'root-dex' { $name -cmatch '^classes(?:[2-9]|1[0-9]|2[0-9])?\.dex$' }
                'native-library' { $name -cmatch '^lib/arm64-v8a/[^/]+\.so$' }
                'density-resource' { $name.StartsWith('res/', [StringComparison]::Ordinal) }
                'signature' { $name -cmatch '^META-INF/[^/]+\.(?:RSA|DSA|EC|SF)$' }
            }
            if (-not $selected) { continue }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $digest = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
            } finally {
                $sha.Dispose()
                $stream.Dispose()
            }
            if (-not $map.TryAdd($name, $digest)) {
                throw "Archive contains duplicate selected entry '$name'."
            }
        }
        return $map
    } finally {
        $archive.Dispose()
    }
}

function Assert-ExactDigestMap {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw "$Label count mismatch. Expected '$($Expected.Count)', observed '$($Actual.Count)'."
    }
    foreach ($name in @($Expected.Keys)) {
        if (-not $Actual.ContainsKey($name) -or $Actual[$name] -ne $Expected[$name]) {
            throw "$Label payload mismatch at '$name'."
        }
    }
}

function Assert-SubsetDigestMap {
    param(
        [Parameter(Mandatory)]$ExpectedSubset,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Label
    )

    foreach ($name in @($ExpectedSubset.Keys)) {
        if (-not $Actual.ContainsKey($name) -or $Actual[$name] -ne $ExpectedSubset[$name]) {
            throw "$Label payload mismatch at '$name'."
        }
    }
}

function Get-MemberByRole {
    param(
        [Parameter(Mandatory)]$Resolution,
        [Parameter(Mandatory)][string]$Role
    )

    $matches = @($Resolution.source.splitMembers | Where-Object { [string]$_.role -eq $Role })
    if ($matches.Count -ne 1) { throw "Resolution must declare exactly one '$Role' split member." }
    return $matches[0]
}

function Assert-MemberManifest {
    param(
        [Parameter(Mandatory)][string]$Aapt2,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Member,
        [Parameter(Mandatory)]$Resolution
    )

    $badgingResult = Invoke-RequiredNative -Command $Aapt2 -Arguments @('dump', 'badging', $Path) -Label "aapt2 badging for $($Member.fileName)"
    $manifestResult = Invoke-RequiredNative -Command $Aapt2 -Arguments @('dump', 'xmltree', '--file', 'AndroidManifest.xml', $Path) -Label "aapt2 manifest for $($Member.fileName)"
    $badging = $badgingResult.text
    $manifest = $manifestResult.text
    $packageNeedle = "package: name='$($Resolution.source.applicationId)' versionCode='$($Resolution.source.versionCode)'"
    if (-not $badging.Contains($packageNeedle, [StringComparison]::Ordinal)) {
        throw "Split member package/version mismatch for '$($Member.fileName)'."
    }

    $role = [string]$Member.role
    if ($role -eq 'base') {
        if ($badging.Contains(" split='", [StringComparison]::Ordinal) `
                -or -not $badging.Contains("versionName='$($Resolution.source.versionName)'", [StringComparison]::Ordinal) `
                -or -not $manifest.Contains('requiredSplitTypes', [StringComparison]::Ordinal) `
                -or -not $manifest.Contains('base__abi,base__density', [StringComparison]::Ordinal)) {
            throw 'Base APK does not carry the exact reviewed split-delivery manifest contract.'
        }
    } else {
        $expectedSplit = [string]$Member.splitName
        $expectedType = [string]$Member.splitType
        if (-not $badging.Contains(" split='$expectedSplit'", [StringComparison]::Ordinal) `
                -or -not $manifest.Contains("split=`"$expectedSplit`"", [StringComparison]::Ordinal) `
                -or -not $manifest.Contains("splitTypes", [StringComparison]::Ordinal) `
                -or -not $manifest.Contains("`"$expectedType`"", [StringComparison]::Ordinal) `
                -or -not $manifest.Contains('hasCode', [StringComparison]::Ordinal) `
                -or -not $manifest.Contains('=false', [StringComparison]::Ordinal)) {
            throw "Configuration APK '$($Member.fileName)' does not carry its exact reviewed split role."
        }
    }
    return [pscustomobject]@{
        role = $role
        fileName = [string]$Member.fileName
        badgingSha256 = Get-TextSha256 -Text $badging
        manifestSha256 = Get-TextSha256 -Text $manifest
    }
}

function Invoke-ExactApkEditorMerge {
    param(
        [Parameter(Mandatory)][string]$Java,
        [Parameter(Mandatory)][string]$ApkEditorJar,
        [Parameter(Mandatory)][string]$InputDirectory,
        [Parameter(Mandatory)][string]$OutputApk
    )

    # The literal order is part of patchlet 005 and the patchlet 090 tool contract.
    return Invoke-RequiredNative -Command $Java -Arguments @(
        '-jar', $ApkEditorJar,
        'm', '-i', $InputDirectory, '-o', $OutputApk,
        '-clean-meta', '-validate-modules', '-extractNativeLibs', 'false'
    ) -Label 'APKEditor split merge'
}

function Get-NormalizedUniversalizationPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Universalization path contract rejected an empty $Label path."
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $full }
    return $full.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Test-UniversalizationSameOrDescendantPath {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Root
    )

    if ($Candidate.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $rootPrefix = $Root
    if (-not $rootPrefix.EndsWith(
            [IO.Path]::DirectorySeparatorChar.ToString(),
            [StringComparison]::Ordinal)) {
        $rootPrefix += [IO.Path]::DirectorySeparatorChar
    }
    return $Candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoUniversalizationReparseAncestor {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $cursor = $Path
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Universalization path contract rejects reparse-point aliasing at $Label."
            }
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrEmpty($parent) `
                -or $parent.Equals($cursor, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $cursor = $parent
    }
}

function Assert-UniversalizationPathContract {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$ResolutionFile,
        [Parameter(Mandatory)][string]$ReportFile,
        [Parameter(Mandatory)][string]$ApkEditorFile,
        [Parameter(Mandatory)][string]$WorkspaceWorkRoot
    )

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw 'Universalization path contract requires an existing source-set directory.'
    }
    if (-not (Test-Path -LiteralPath $ResolutionFile -PathType Leaf)) {
        throw 'Universalization path contract requires an existing resolution file.'
    }
    if (-not (Test-Path -LiteralPath $ApkEditorFile -PathType Leaf)) {
        throw 'Universalization path contract requires an existing APKEditor file.'
    }
    if (-not (Test-Path -LiteralPath $WorkspaceWorkRoot -PathType Container)) {
        throw 'Universalization path contract requires the workspace work directory.'
    }

    $pathChecks = @(
        [pscustomobject]@{ path=$SourceRoot; label='source set' }
        [pscustomobject]@{ path=$OutputRoot; label='output directory' }
        [pscustomobject]@{ path=$ResolutionFile; label='resolution' }
        [pscustomobject]@{ path=$ReportFile; label='report' }
        [pscustomobject]@{ path=$ApkEditorFile; label='APKEditor' }
        [pscustomobject]@{ path=$WorkspaceWorkRoot; label='workspace work directory' }
    )
    foreach ($entry in $pathChecks) {
        Assert-NoUniversalizationReparseAncestor -Path $entry.path -Label $entry.label
    }

    $namedPaths = [ordered]@{
        'source set' = $SourceRoot
        'output directory' = $OutputRoot
        'resolution' = $ResolutionFile
        'report' = $ReportFile
        'APKEditor' = $ApkEditorFile
    }
    $names = @($namedPaths.Keys)
    for ($left = 0; $left -lt $names.Count; $left++) {
        for ($right = $left + 1; $right -lt $names.Count; $right++) {
            if ($namedPaths[$names[$left]].Equals(
                    $namedPaths[$names[$right]],
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "Universalization path contract rejects aliasing between $($names[$left]) and $($names[$right])."
            }
        }
    }

    if (-not (Test-UniversalizationSameOrDescendantPath `
            -Candidate $OutputRoot -Root $WorkspaceWorkRoot) `
            -or $OutputRoot.Equals($WorkspaceWorkRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Universalization output must be a strict child of the workspace work directory.'
    }
    if (-not (Test-UniversalizationSameOrDescendantPath `
            -Candidate $ReportFile -Root $WorkspaceWorkRoot) `
            -or $ReportFile.Equals($WorkspaceWorkRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Universalization report must be a strict child of the workspace work directory.'
    }

    if ((Test-UniversalizationSameOrDescendantPath -Candidate $OutputRoot -Root $SourceRoot) `
            -or (Test-UniversalizationSameOrDescendantPath -Candidate $SourceRoot -Root $OutputRoot)) {
        throw 'Universalization source set and output directory must be disjoint.'
    }
    foreach ($fixedFile in @($ResolutionFile, $ApkEditorFile)) {
        if ((Test-UniversalizationSameOrDescendantPath -Candidate $fixedFile -Root $SourceRoot) `
                -or (Test-UniversalizationSameOrDescendantPath -Candidate $fixedFile -Root $OutputRoot)) {
            throw 'Universalization source/output directories must not contain the resolution or APKEditor file.'
        }
    }
    if ((Test-UniversalizationSameOrDescendantPath -Candidate $ReportFile -Root $SourceRoot) `
            -or (Test-UniversalizationSameOrDescendantPath -Candidate $ReportFile -Root $OutputRoot)) {
        throw 'Universalization report must be outside the source set and output directory.'
    }
    if (Test-Path -LiteralPath $OutputRoot) {
        throw "Universalization output directory must be fresh: $OutputRoot"
    }
    if (Test-Path -LiteralPath $ReportFile) {
        throw "Universalization report path must be fresh: $ReportFile"
    }
}

$repositoryRoot = Get-PatchletRepositoryRoot
$sourceRoot = Get-NormalizedUniversalizationPath -Path $SourceApkSet -Label 'source set'
$outputRoot = Get-NormalizedUniversalizationPath -Path $OutputDirectory -Label 'output directory'
$resolutionPathFull = Get-NormalizedUniversalizationPath -Path $ResolutionPath -Label 'resolution'
$reportPathFull = Get-NormalizedUniversalizationPath -Path $ReportPath -Label 'report'
$apkEditorJarFull = Get-NormalizedUniversalizationPath -Path $ApkEditorJar -Label 'APKEditor'
$workspaceWorkRoot = Get-NormalizedUniversalizationPath `
    -Path (Join-Path $repositoryRoot 'work') -Label 'workspace work directory'
Assert-UniversalizationPathContract `
    -SourceRoot $sourceRoot `
    -OutputRoot $outputRoot `
    -ResolutionFile $resolutionPathFull `
    -ReportFile $reportPathFull `
    -ApkEditorFile $apkEditorJarFull `
    -WorkspaceWorkRoot $workspaceWorkRoot
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null

$resolution = Read-PatchletJson -Path $resolutionPathFull
if ([string]$resolution.source.delivery -ne 'split-apk-set' `
        -or @($resolution.patchlets | Where-Object { [string]$_ -eq '005-split-source-universalization' }).Count -ne 1) {
    throw 'Split universalization requires one resolution-bound 005-split-source-universalization patchlet.'
}
if ($BuildToolsVersion -ne [string]$resolution.toolchain.buildToolsVersion) {
    throw 'Build Tools version differs from the split universalization resolution.'
}
$toolContract = Test-PatchletApkEditorContract -Resolution $resolution -ApkEditorJar $apkEditorJarFull
$expectedMergeArguments = @($toolContract.orderedArguments)
$toolVersionResult = Invoke-CapturedNative -Command $Java -Arguments @('-jar', $apkEditorJarFull, '-version')
if ($toolVersionResult.exitCode -ne 2 `
        -or $toolVersionResult.text.Trim() -ne 'APKEditor version 1.4.9, ARSCLib version 1.3.9') {
    throw 'APKEditor reported an unexpected version or ARSCLib pairing.'
}

$aapt2 = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion\aapt2.exe"
$apksignerJar = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion\lib\apksigner.jar"
foreach ($tool in @($aapt2, $apksignerJar)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Required Android tool is missing: $tool" }
}

$setEvidence = Test-PatchletSplitSourceSet -Resolution $resolution -SourceApkSet $sourceRoot
$memberManifestEvidence = @()
foreach ($member in @($resolution.source.splitMembers)) {
    $memberPath = Join-Path $sourceRoot ([string]$member.fileName)
    $null = Test-PatchletZipInventory -Path $memberPath
    $memberManifestEvidence += Assert-MemberManifest -Aapt2 $aapt2 -Path $memberPath -Member $member -Resolution $resolution
}

$baseMember = Get-MemberByRole -Resolution $resolution -Role 'base'
$abiMember = Get-MemberByRole -Resolution $resolution -Role 'abi'
$densityMember = Get-MemberByRole -Resolution $resolution -Role 'density'
$basePath = Join-Path $sourceRoot ([string]$baseMember.fileName)
$abiPath = Join-Path $sourceRoot ([string]$abiMember.fileName)
$densityPath = Join-Path $sourceRoot ([string]$densityMember.fileName)
$baseDex = Get-ZipEntryDigestMap -Path $basePath -Kind 'root-dex'
$abiLibraries = Get-ZipEntryDigestMap -Path $abiPath -Kind 'native-library'
$densityResources = Get-ZipEntryDigestMap -Path $densityPath -Kind 'density-resource'
if ($baseDex.Count -ne [int]$resolution.source.rootDexCount) { throw 'Base root DEX count differs from the resolution.' }
if ($abiLibraries.Count -ne [int]$resolution.source.nativeLibraryCount) { throw 'ABI split native-library count differs from the resolution.' }
if ($densityResources.Count -ne [int]$resolution.source.densityResourceCount) { throw 'Density split resource-payload count differs from the resolution.' }

$outputA = Join-Path $outputRoot 'source-universal-a.apk'
$outputB = Join-Path $outputRoot 'source-universal-b.apk'
$mergeA = Invoke-ExactApkEditorMerge -Java $Java -ApkEditorJar $apkEditorJarFull -InputDirectory $sourceRoot -OutputApk $outputA
$mergeB = Invoke-ExactApkEditorMerge -Java $Java -ApkEditorJar $apkEditorJarFull -InputDirectory $sourceRoot -OutputApk $outputB
foreach ($output in @($outputA, $outputB)) {
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "APKEditor did not produce '$output'." }
    $null = Test-PatchletZipInventory -Path $output
}
$derivedSha256A = Get-PatchletSha256 -Path $outputA
$derivedSha256B = Get-PatchletSha256 -Path $outputB
if ($derivedSha256A -ne $derivedSha256B) { throw 'Independent APKEditor merges were not byte-identical.' }
if ($derivedSha256A -ne [string]$resolution.source.sha256) {
    throw 'Derived standalone APK hash differs from the exact resolution.'
}

$mergedBadgingResult = Invoke-RequiredNative -Command $aapt2 -Arguments @('dump', 'badging', $outputA) -Label 'merged aapt2 badging'
$mergedManifestResult = Invoke-RequiredNative -Command $aapt2 -Arguments @('dump', 'xmltree', '--file', 'AndroidManifest.xml', $outputA) -Label 'merged aapt2 manifest'
$mergedConfigurationsResult = Invoke-RequiredNative -Command $aapt2 -Arguments @('dump', 'configurations', $outputA) -Label 'merged aapt2 configurations'
$densityConfigurationsResult = Invoke-RequiredNative -Command $aapt2 -Arguments @('dump', 'configurations', $densityPath) -Label 'density aapt2 configurations'
$mergedBadging = $mergedBadgingResult.text
$mergedManifest = $mergedManifestResult.text
$mergedPackageNeedle = "package: name='$($resolution.source.applicationId)' versionCode='$($resolution.source.versionCode)' versionName='$($resolution.source.versionName)'"
if (-not $mergedBadging.Contains($mergedPackageNeedle, [StringComparison]::Ordinal) `
        -or -not $mergedBadging.Contains("minSdkVersion:'$($resolution.source.minSdk)'", [StringComparison]::Ordinal) `
        -or -not $mergedBadging.Contains("targetSdkVersion:'$($resolution.source.targetSdk)'", [StringComparison]::Ordinal) `
        -or $mergedBadging.Contains(" split='", [StringComparison]::Ordinal)) {
    throw 'Derived APK package, version, SDK, or standalone badging contract failed.'
}
foreach ($forbiddenManifestMarker in @('requiredSplitTypes', 'splitTypes', 'A: split=', 'com.android.vending.splits')) {
    if ($mergedManifest.Contains($forbiddenManifestMarker, [StringComparison]::Ordinal)) {
        throw "Derived APK retains forbidden split-delivery metadata '$forbiddenManifestMarker'."
    }
}
if (-not $mergedManifest.Contains('extractNativeLibs', [StringComparison]::Ordinal) `
        -or -not $mergedManifest.Contains('=false', [StringComparison]::Ordinal)) {
    throw 'Derived APK did not preserve extractNativeLibs=false.'
}

$densityConfigurations = @($densityConfigurationsResult.text.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$mergedConfigurations = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($configuration in @($mergedConfigurationsResult.text.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $null = $mergedConfigurations.Add($configuration)
}
foreach ($configuration in $densityConfigurations) {
    if (-not $mergedConfigurations.Contains($configuration)) {
        throw "Derived resource table is missing density configuration '$configuration'."
    }
}

$mergedDex = Get-ZipEntryDigestMap -Path $outputA -Kind 'root-dex'
$mergedLibraries = Get-ZipEntryDigestMap -Path $outputA -Kind 'native-library'
$mergedDensityResources = Get-ZipEntryDigestMap -Path $outputA -Kind 'density-resource'
Assert-ExactDigestMap -Expected $baseDex -Actual $mergedDex -Label 'Root DEX'
Assert-ExactDigestMap -Expected $abiLibraries -Actual $mergedLibraries -Label 'Native library'
Assert-SubsetDigestMap -ExpectedSubset $densityResources -Actual $mergedDensityResources -Label 'Density resource'

$signatureEntries = Get-ZipEntryDigestMap -Path $outputA -Kind 'signature'
if ($signatureEntries.Count -ne 0) { throw 'Derived APK unexpectedly retains JAR signature entries.' }
$signatureVerification = Invoke-CapturedNative -Command $Java -Arguments @('-jar', $apksignerJar, 'verify', '--verbose', $outputA)
if ($signatureVerification.exitCode -eq 0) { throw 'Derived APK unexpectedly verifies as signed.' }

$report = [ordered]@{
    schemaVersion = 1
    patchlet = '005-split-source-universalization'
    status = 'passed'
    sourceSet = $setEvidence
    memberManifests = @($memberManifestEvidence)
    tool = [ordered]@{
        name = 'APKEditor'
        version = '1.4.9'
        arscLibVersion = '1.3.9'
        jarSha256 = Get-PatchletSha256 -Path $apkEditorJarFull
        orderedArguments = $expectedMergeArguments
        firstMergeLogSha256 = Get-TextSha256 -Text $mergeA.text
        secondMergeLogSha256 = Get-TextSha256 -Text $mergeB.text
    }
    derived = [ordered]@{
        path = $outputA
        repeatPath = $outputB
        sha256 = $derivedSha256A
        repeatSha256 = $derivedSha256B
        deterministic = $true
        unsigned = $true
        splitMetadataAbsent = $true
        packageName = [string]$resolution.source.applicationId
        versionCode = [long]$resolution.source.versionCode
        versionName = [string]$resolution.source.versionName
        rootDexCount = $mergedDex.Count
        nativeLibraryCount = $mergedLibraries.Count
        densitySourcePayloadCount = $densityResources.Count
        densityConfigurations = @($densityConfigurations)
        badgingSha256 = Get-TextSha256 -Text $mergedBadging
        manifestSha256 = Get-TextSha256 -Text $mergedManifest
        configurationsSha256 = Get-TextSha256 -Text $mergedConfigurationsResult.text
    }
    finalArchiveAlignment = 'deferred-to-build-and-patchlet-090'
}
Write-PatchletJson -Value $report -Path $reportPathFull
[pscustomobject]$report
