[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Apk,
    [Parameter(Mandatory)][string]$ScratchRoot,
    [Parameter(Mandatory)][string]$SourceApk,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [ValidateSet('Release', 'SignedReview')][string]$ValidationMode = 'Release',
    [string]$ReportPath,
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$BuildToolsVersion = '36.0.0',
    [string]$Java = 'java',
    [string]$Javac = 'javac',
    [string]$SevenZip = 'C:\Program Files\7-Zip\7z.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

function Invoke-Captured {
    param([string]$Command, [string[]]$Arguments)
    $lines = @(& $Command @Arguments)
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $lines | ForEach-Object { Write-Host $_ }
        throw "Native validation command failed with exit code ${code}: $Command"
    }
    return $lines
}

function Get-ZipEntryHashes {
    param([string]$Path, [string]$Prefix, [string[]]$ExcludedNames = @())
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $excluded = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @($ExcludedNames)) { $null = $excluded.Add([string]$name) }
    $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
    try {
        $result = [ordered]@{}
        $seenNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in @($archive.Entries | Where-Object {
                    -not [string]::IsNullOrEmpty($_.Name) `
                        -and $_.FullName.StartsWith($Prefix, [StringComparison]::Ordinal)
                } | Sort-Object FullName)) {
            if (-not $seenNames.Add($entry.FullName)) {
                throw "ZIP inventory contains duplicate entry FullName '$($entry.FullName)' in '$Path'."
            }
            if ($excluded.Contains($entry.FullName)) { continue }
            $stream = $entry.Open()
            try {
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $hash = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
            } finally { $stream.Dispose() }
            $result[$entry.FullName] = ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
        }
        return $result
    } finally { $archive.Dispose() }
}

function Get-ZipEntryBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EntryName
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
    try {
        $matches = @($archive.Entries | Where-Object {
                $_.FullName.Equals($EntryName, [StringComparison]::Ordinal)
            })
        if ($matches.Count -ne 1) {
            throw "ZIP entry '$EntryName' must occur exactly once in '$Path'; observed $($matches.Count)."
        }
        if ($matches[0].Length -gt [int]::MaxValue) {
            throw "ZIP entry '$EntryName' is too large for bounded ELF inspection."
        }
        $input = $matches[0].Open()
        $memory = [IO.MemoryStream]::new([int]$matches[0].Length)
        try {
            $input.CopyTo($memory)
            return ,$memory.ToArray()
        } finally {
            $memory.Dispose()
            $input.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

function Assert-ElfReadRange {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][long]$Offset,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][string]$Label
    )
    if ($Offset -lt 0 -or $Count -lt 0 `
            -or $Offset -gt $Bytes.LongLength - $Count) {
        throw "ELF field '$Label' is outside the native library."
    }
}

function Read-ElfUInt16Le {
    param([byte[]]$Bytes, [long]$Offset, [string]$Label)
    Assert-ElfReadRange -Bytes $Bytes -Offset $Offset -Count 2 -Label $Label
    return [uint16]([uint16]$Bytes[$Offset] -bor ([uint16]$Bytes[$Offset + 1] -shl 8))
}

function Read-ElfUInt32Le {
    param([byte[]]$Bytes, [long]$Offset, [string]$Label)
    Assert-ElfReadRange -Bytes $Bytes -Offset $Offset -Count 4 -Label $Label
    [uint32]$value = 0
    for ($index = 3; $index -ge 0; $index--) {
        $value = [uint32](([uint64]$value * 256) + [uint64]$Bytes[$Offset + $index])
    }
    return $value
}

function Read-ElfUInt64Le {
    param([byte[]]$Bytes, [long]$Offset, [string]$Label)
    Assert-ElfReadRange -Bytes $Bytes -Offset $Offset -Count 8 -Label $Label
    [uint64]$value = 0
    for ($index = 7; $index -ge 0; $index--) {
        $value = ([uint64]$value * 256) + [uint64]$Bytes[$Offset + $index]
    }
    return $value
}

function Test-ReviewedAarch64Elf {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$ExpectedMachine,
        [Parameter(Mandatory)][uint64]$MinimumLoadAlignment
    )

    if ($Bytes.LongLength -lt 64 `
            -or $Bytes[0] -ne 0x7f `
            -or $Bytes[1] -ne [byte][char]'E' `
            -or $Bytes[2] -ne [byte][char]'L' `
            -or $Bytes[3] -ne [byte][char]'F') {
        throw 'Reviewed proxy native addition is not an ELF file.'
    }
    if ($Bytes[4] -ne 2) { throw 'Reviewed proxy native addition is not ELF64.' }
    if ($Bytes[5] -ne 1) { throw 'Reviewed proxy native addition is not little-endian ELF.' }
    if ($Bytes[6] -ne 1) { throw 'Reviewed proxy native addition has an unsupported ELF identity version.' }
    if ($ExpectedMachine -ne 183) { throw 'Resolution proxy elfMachine must be AArch64 (183).' }
    if ($MinimumLoadAlignment -lt 16384) {
        throw 'Resolution proxy minimumLoadAlignment must be at least 16384.'
    }

    $machine = [int](Read-ElfUInt16Le -Bytes $Bytes -Offset 18 -Label 'e_machine')
    $version = Read-ElfUInt32Le -Bytes $Bytes -Offset 20 -Label 'e_version'
    $programHeaderOffset = Read-ElfUInt64Le -Bytes $Bytes -Offset 32 -Label 'e_phoff'
    $elfHeaderSize = [int](Read-ElfUInt16Le -Bytes $Bytes -Offset 52 -Label 'e_ehsize')
    $programHeaderSize = [int](Read-ElfUInt16Le -Bytes $Bytes -Offset 54 -Label 'e_phentsize')
    $programHeaderCount = [int](Read-ElfUInt16Le -Bytes $Bytes -Offset 56 -Label 'e_phnum')
    if ($machine -ne $ExpectedMachine) {
        throw "Proxy native ELF machine mismatch. Expected '$ExpectedMachine', observed '$machine'."
    }
    if ($version -ne 1 -or $elfHeaderSize -lt 64) {
        throw 'Proxy native ELF header version or size is invalid.'
    }
    if ($programHeaderSize -lt 56 -or $programHeaderCount -lt 1) {
        throw 'Proxy native ELF has no bounded ELF64 program-header table.'
    }
    if ($programHeaderOffset -gt [uint64][long]::MaxValue) {
        throw 'Proxy native ELF program-header offset is too large.'
    }
    $tableSize = [uint64]$programHeaderSize * [uint64]$programHeaderCount
    if ($programHeaderOffset -gt [uint64]$Bytes.LongLength `
            -or $tableSize -gt [uint64]$Bytes.LongLength - $programHeaderOffset) {
        throw 'Proxy native ELF program-header table is truncated.'
    }

    $loadAlignments = @()
    for ($index = 0; $index -lt $programHeaderCount; $index++) {
        $headerOffset = [long]($programHeaderOffset + ([uint64]$index * [uint64]$programHeaderSize))
        $type = Read-ElfUInt32Le -Bytes $Bytes -Offset $headerOffset -Label "p_type[$index]"
        if ($type -ne 1) { continue }
        $alignment = Read-ElfUInt64Le `
            -Bytes $Bytes -Offset ($headerOffset + 48) -Label "p_align[$index]"
        if ($alignment -lt $MinimumLoadAlignment `
                -or ($alignment -band ($alignment - 1)) -ne 0) {
            throw "Proxy native PT_LOAD[$index] alignment '$alignment' is below or incompatible with '$MinimumLoadAlignment'."
        }
        $loadAlignments += [uint64]$alignment
    }
    if ($loadAlignments.Count -lt 1) {
        throw 'Proxy native ELF contains no PT_LOAD program header.'
    }

    return [pscustomobject]@{
        class = 'ELF64'
        endianness = 'little'
        machine = $machine
        machineName = 'AArch64'
        programHeaders = $programHeaderCount
        loadSegments = $loadAlignments.Count
        loadAlignments = @($loadAlignments)
        minimumRequiredLoadAlignment = $MinimumLoadAlignment
    }
}

function Get-AaptXmlElementBlock {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][string]$ElementName,
        [Parameter(Mandatory)][string]$AndroidName
    )

    $nameNeedle = '="{0}"' -f $AndroidName
    $nameIndexes = @()
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ([string]$Lines[$index] -like '*android:name*' `
                -and [string]$Lines[$index] -like "*$nameNeedle*") {
            $nameIndexes += $index
        }
    }
    if ($nameIndexes.Count -ne 1) {
        throw "Manifest element '$ElementName/$AndroidName' must occur exactly once; observed $($nameIndexes.Count)."
    }

    $elementPattern = '^(?<indent>\s*)E:\s+' `
        + [regex]::Escape($ElementName) + '(?:\s|\(|$)'
    $start = -1
    $indent = -1
    for ($index = $nameIndexes[0]; $index -ge 0; $index--) {
        $match = [regex]::Match([string]$Lines[$index], $elementPattern)
        if ($match.Success) {
            $start = $index
            $indent = $match.Groups['indent'].Value.Length
            break
        }
    }
    if ($start -lt 0) {
        throw "Manifest element boundary is missing for '$ElementName/$AndroidName'."
    }

    $end = $Lines.Count
    for ($index = $start + 1; $index -lt $Lines.Count; $index++) {
        $line = [string]$Lines[$index]
        $elementMatch = [regex]::Match($line, '^(?<indent>\s*)E:\s+')
        if ($elementMatch.Success `
                -and $elementMatch.Groups['indent'].Value.Length -le $indent) {
            $end = $index
            break
        }
    }
    $blockLines = @($Lines[$start..($end - 1)])
    return [pscustomobject]@{
        element = $ElementName
        androidName = $AndroidName
        startLine = $start
        lines = $blockLines
        text = $blockLines -join "`n"
    }
}

function Test-NativeAsciiLiterals {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string[]]$Required,
        [string[]]$Forbidden = @()
    )

    $ascii = [Text.Encoding]::ASCII.GetString($Bytes)
    foreach ($literal in $Required) {
        if (-not $ascii.Contains($literal, [StringComparison]::Ordinal)) {
            throw "Proxy native JNI contract is missing '$literal'."
        }
    }
    foreach ($literal in $Forbidden) {
        if ($ascii.Contains($literal, [StringComparison]::Ordinal)) {
            throw "Proxy native JNI contract contains retired owner '$literal'."
        }
    }
    return [pscustomobject]@{
        required = $Required
        forbidden = $Forbidden
        status = 'passed'
    }
}

$apkFull = [IO.Path]::GetFullPath($Apk)
$candidateArtifactLock = [IO.File]::Open(
    $apkFull, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
$scratchFull = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $scratchFull) { throw "ScratchRoot must be fresh: $scratchFull" }
[IO.Directory]::CreateDirectory($scratchFull) | Out-Null

$resolutionPathFull = [IO.Path]::GetFullPath($ResolutionPath)
$resolution = Read-PatchletJson -Path $resolutionPathFull
$proxyProperty = $resolution.PSObject.Properties['proxy']
if ($null -ne $proxyProperty `
        -and @($resolution.patchlets | Where-Object {
                [string]$_ -eq '080-socks5-proxy'
            }).Count -ne 1) {
    throw 'A reviewed proxy release requires exactly one 080-socks5-proxy resolution entry.'
}
$expectedResolutionStatus = if ($ValidationMode -ceq 'SignedReview') {
    'review-required'
} else {
    'verified-current'
}
$expectedUpdateSignedDexReviewRequired = $ValidationMode -ceq 'SignedReview'
if ([string]$resolution.status -cne $expectedResolutionStatus `
        -or $resolution.release.updateSignedDexReviewRequired `
            -ne $expectedUpdateSignedDexReviewRequired) {
    throw "Signed-APK validation state does not match ValidationMode '$ValidationMode'."
}
if ($BuildToolsVersion -ne [string]$resolution.toolchain.buildToolsVersion) {
    throw "Build Tools version '$BuildToolsVersion' differs from the resolution's pinned '$($resolution.toolchain.buildToolsVersion)'."
}
$buildTools = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion"
$aapt2 = Join-Path $buildTools 'aapt2.exe'
$zipalign = Join-Path $buildTools 'zipalign.exe'
$apksignerJar = Join-Path $buildTools 'lib\apksigner.jar'
$jadxJar = Join-Path (Get-PatchletRepositoryRoot) '.tools\jadx-1.5.6\lib\jadx-1.5.6-all.jar'
$apktoolJar = Join-Path (Get-PatchletRepositoryRoot) '.tools\apktool\apktool_3.0.3.jar'
$jadxRecoverySource = Join-Path $PSScriptRoot 'TargetedJadxRecovery.java'
$dexLiteralCallSource = Join-Path $PSScriptRoot 'DexLiteralCallInspector.java'
$dexProxyBootstrapFlowSource = Join-Path $PSScriptRoot 'DexProxyBootstrapFlowInspector.java'
$dexProxyBootstrapFlowFixtureTest = Join-Path $PSScriptRoot 'Test-DexProxyBootstrapFlowInspector.ps1'
$dexUpdateFlowSource = Join-Path $PSScriptRoot 'DexUpdateFlowInspector.java'
$dexUpdateFlowFixtureTest = Join-Path $PSScriptRoot 'Test-DexUpdateFlowInspector.ps1'
$dexBridgeFlowSource = Join-Path $PSScriptRoot 'DexBridgeFlowInspector.java'
$dexBridgeFlowFixtureAssemblerSource = Join-Path $PSScriptRoot 'DexBridgeFlowFixtureAssembler.java'
$dexBridgeFlowFixtureTest = Join-Path $PSScriptRoot 'Test-DexBridgeFlowInspector.ps1'
$dexReportPermalinkFlowSource = Join-Path $PSScriptRoot 'DexReportPermalinkFlowInspector.java'
$dexReportPermalinkFlowFixtureTest = Join-Path $PSScriptRoot 'Test-DexReportPermalinkFlowInspector.ps1'
$releaseToolContractModule = Join-Path $PSScriptRoot 'ThreadsMod.ReleaseToolContract.psm1'
$dexBridgeFlowFixtureRoot = Join-Path (Get-PatchletRepositoryRoot) 'patchlets\assets\release-gates\dex-bridge-flow'
$dexProxyBootstrapFlowFixtureRoot = Join-Path (Get-PatchletRepositoryRoot) 'patchlets\assets\release-gates\dex-proxy-bootstrap-flow'
$dexUpdateFlowFixtureRoot = Join-Path (Get-PatchletRepositoryRoot) 'patchlets\assets\release-gates\dex-update-flow'
$dexReportPermalinkFlowFixtureRoot = Join-Path (Get-PatchletRepositoryRoot) 'patchlets\assets\release-gates\dex-report-permalink-flow'
$patchedApkTestSource = [IO.Path]::GetFullPath($PSCommandPath)
$sourceApkFull = if ($SourceApk) { [IO.Path]::GetFullPath($SourceApk) } else { $null }
$requiredPaths = @(
    $apkFull, $aapt2, $zipalign, $apksignerJar, $SevenZip, $jadxJar, $apktoolJar,
    $jadxRecoverySource, $dexLiteralCallSource, $dexProxyBootstrapFlowSource,
    $dexProxyBootstrapFlowFixtureTest, $dexUpdateFlowSource,
    $dexUpdateFlowFixtureTest, $dexBridgeFlowSource,
    $dexBridgeFlowFixtureAssemblerSource, $dexBridgeFlowFixtureTest,
    $dexReportPermalinkFlowSource, $dexReportPermalinkFlowFixtureTest,
    $releaseToolContractModule, $dexProxyBootstrapFlowFixtureRoot,
    $dexUpdateFlowFixtureRoot, $dexBridgeFlowFixtureRoot,
    $dexReportPermalinkFlowFixtureRoot, $patchedApkTestSource)
if ($sourceApkFull) { $requiredPaths += $sourceApkFull }
foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required validation input does not exist: $path" }
}
$candidateArchiveInventory = Test-PatchletZipInventory -Path $apkFull
$sourceArchiveInventory = Test-PatchletZipInventory -Path $sourceApkFull
$boundSourceSha256 = Get-PatchletSha256 -Path $sourceApkFull
if ($boundSourceSha256 -ne [string]$resolution.source.sha256) {
    throw 'Release validation source APK hash does not match the exact resolution.'
}
if ((Get-PatchletSha256 -Path $jadxJar) -ne [string]$resolution.toolchain.jadxJarSha256) {
    throw 'JADX executable JAR hash does not match the resolution.'
}
if ((Get-PatchletSha256 -Path $jadxRecoverySource) -ne [string]$resolution.assets.targetedJadxRecoverySourceSha256) {
    throw 'Targeted JADX recovery source hash does not match the resolution.'
}
if ((Get-PatchletSha256 -Path $apktoolJar) -ne [string]$resolution.toolchain.apktoolJarSha256 `
        -or (Get-PatchletSha256 -Path $dexLiteralCallSource) `
            -ne [string]$resolution.assets.dexLiteralCallInspectorSourceSha256 `
        -or (Get-PatchletSha256 -Path $dexProxyBootstrapFlowSource) `
            -ne [string]$resolution.assets.dexProxyBootstrapFlowInspectorSourceSha256 `
        -or (Get-PatchletSha256 -Path $dexProxyBootstrapFlowFixtureTest) `
            -ne [string]$resolution.assets.dexProxyBootstrapFlowInspectorTestSourceSha256 `
        -or (Get-PatchletTreeSha256 -Root $dexProxyBootstrapFlowFixtureRoot -Filter '*') `
            -ne [string]$resolution.assets.dexProxyBootstrapFlowFixtureTreeSha256 `
        -or (Get-PatchletSha256 -Path $dexUpdateFlowSource) `
            -ne [string]$resolution.assets.dexUpdateFlowInspectorSourceSha256 `
        -or (Get-PatchletSha256 -Path $dexUpdateFlowFixtureTest) `
            -ne [string]$resolution.assets.dexUpdateFlowInspectorTestSourceSha256 `
        -or (Get-PatchletTreeSha256 -Root $dexUpdateFlowFixtureRoot -Filter '*') `
            -ne [string]$resolution.assets.dexUpdateFlowFixtureTreeSha256 `
        -or (Get-PatchletSha256 -Path $dexBridgeFlowSource) `
            -ne [string]$resolution.assets.dexBridgeFlowInspectorSourceSha256 `
        -or (Get-PatchletSha256 -Path $dexBridgeFlowFixtureAssemblerSource) `
            -ne [string]$resolution.assets.dexBridgeFlowFixtureAssemblerSourceSha256 `
        -or (Get-PatchletSha256 -Path $dexBridgeFlowFixtureTest) `
            -ne [string]$resolution.assets.dexBridgeFlowInspectorTestSourceSha256 `
        -or (Get-PatchletSha256 -Path $releaseToolContractModule) `
            -ne [string]$resolution.assets.releaseToolContractModuleSha256 `
        -or (Get-PatchletTreeSha256 -Root $dexBridgeFlowFixtureRoot -Filter '*') `
            -ne [string]$resolution.assets.dexBridgeFlowFixtureTreeSha256 `
        -or (Get-PatchletSha256 -Path $dexReportPermalinkFlowSource) `
            -ne [string]$resolution.assets.dexReportPermalinkFlowInspectorSourceSha256 `
        -or (Get-PatchletSha256 -Path $dexReportPermalinkFlowFixtureTest) `
            -ne [string]$resolution.assets.dexReportPermalinkFlowInspectorTestSourceSha256 `
        -or (Get-PatchletTreeSha256 -Root $dexReportPermalinkFlowFixtureRoot -Filter '*') `
            -ne [string]$resolution.assets.dexReportPermalinkFlowFixtureTreeSha256 `
        -or (Get-PatchletSha256 -Path $patchedApkTestSource) `
            -ne [string]$resolution.assets.patchedApkTestSourceSha256) {
    throw 'DEX flow verifiers, release-gate script, or pinned Apktool hash does not match the resolution.'
}
Import-Module $releaseToolContractModule -Force -DisableNameChecking
$patchedApkAst = Get-ThreadsModReleaseToolAst `
    -Path $patchedApkTestSource -Label 'Patched-APK release wrapper'
$dexBridgeFlowFixtureTestAst = Get-ThreadsModReleaseToolAst `
    -Path $dexBridgeFlowFixtureTest -Label 'DEX bridge-flow positive fixture harness'
$dexProxyBootstrapFlowFixtureTestAst = Get-ThreadsModReleaseToolAst `
    -Path $dexProxyBootstrapFlowFixtureTest `
    -Label 'DEX proxy-bootstrap-flow positive fixture harness'
$dexReportPermalinkFlowFixtureTestAst = Get-ThreadsModReleaseToolAst `
    -Path $dexReportPermalinkFlowFixtureTest `
    -Label 'DEX report-permalink-flow positive fixture harness'
$releaseToolInvocationCompatibility = Test-ThreadsModReleaseToolInvocationContracts `
    -ToolsRoot $PSScriptRoot
$releaseBridgeEvidenceContract = @($resolution.release.requiredDexBridgeFlows)[0]
$releaseToolEvidenceCompatibility = Assert-ThreadsModReleaseEvidenceContract `
    -ReleaseWrapperAst $patchedApkAst `
    -FixtureHarnessAst $dexBridgeFlowFixtureTestAst `
    -ReviewedFixtureCount ([int]$resolution.release.expectedDexBridgeFlowFixtureCount) `
    -ReviewedTerminalRoutes ([int]$resolution.release.expectedReviewedTerminalRoutes) `
    -ReviewedCurrentTerminalRoutes `
        ([int]$resolution.release.expectedCurrentReviewedTerminalRoutes) `
    -ReviewedCurrentPacedNextPosts `
        ([int]$resolution.release.expectedCurrentAutomaticPacedNextPosts) `
    -ReviewedCurrentOwnerMode `
        ([string]$resolution.release.expectedCurrentAutomaticOwnerMode) `
    -ReviewedPrepareModelInvokeCount `
        ([int]$releaseBridgeEvidenceContract.expectedPrepareModelInvokeCount) `
    -ReviewedPassivePreflightInvokeCount `
        ([int]$releaseBridgeEvidenceContract.expectedPassivePreflightInvokeCount) `
    -ReviewedCacheLookupInvokeCount `
        ([int]$releaseBridgeEvidenceContract.expectedCacheLookupInvokeCount) `
    -ReviewedCacheFactoryInvokeCount `
        ([int]$releaseBridgeEvidenceContract.expectedCacheFactoryInvokeCount) `
    -ReviewedCachePlaceholderInvokeCount `
        ([int]$releaseBridgeEvidenceContract.expectedCachePlaceholderInvokeCount)
$releaseToolInspectorArgumentCompatibility = Assert-ThreadsModDexBridgeInspectorArgumentContract `
    -InspectorSourcePath $dexBridgeFlowSource `
    -ReviewedArgumentCount ([int]$resolution.release.expectedDexBridgeFlowInspectorArgumentCount)
$releaseToolReportPermalinkEvidenceCompatibility = Assert-ThreadsModReportPermalinkEvidenceContract `
    -ReleaseWrapperAst $patchedApkAst `
    -FixtureHarnessAst $dexReportPermalinkFlowFixtureTestAst `
    -ReviewedFixtureCount ([int]$resolution.release.expectedDexReportPermalinkFlowFixtureCount) `
    -ReviewedInspectorArgumentCount `
        ([int]$resolution.release.expectedDexReportPermalinkFlowInspectorArgumentCount)
$releaseToolReportPermalinkInspectorArgumentCompatibility = `
    Assert-ThreadsModReportPermalinkInspectorArgumentContract `
        -InspectorSourcePath $dexReportPermalinkFlowSource `
        -ReviewedArgumentCount `
            ([int]$resolution.release.expectedDexReportPermalinkFlowInspectorArgumentCount)
$releaseToolReportPermalinkInspectorBindingCompatibility = `
    Assert-ThreadsModReportPermalinkInspectorBindingContract `
        -ReleaseWrapperAst $patchedApkAst `
        -FixtureHarnessAst $dexReportPermalinkFlowFixtureTestAst `
        -ReviewedArgumentCount `
            ([int]$resolution.release.expectedDexReportPermalinkFlowInspectorArgumentCount)
$releaseToolProxyBootstrapEvidenceCompatibility = `
    Assert-ThreadsModProxyBootstrapEvidenceContract `
        -ReleaseWrapperAst $patchedApkAst `
        -FixtureHarnessAst $dexProxyBootstrapFlowFixtureTestAst `
        -ReviewedFixtureCount `
            ([int]$resolution.release.expectedDexProxyBootstrapFlowFixtureCount) `
        -ReviewedInspectorArgumentCount `
            ([int]$resolution.release.expectedDexProxyBootstrapFlowInspectorArgumentCount)
$releaseToolProxyBootstrapInspectorArgumentCompatibility = `
    Assert-ThreadsModProxyBootstrapInspectorArgumentContract `
        -InspectorSourcePath $dexProxyBootstrapFlowSource `
        -ReviewedArgumentCount `
            ([int]$resolution.release.expectedDexProxyBootstrapFlowInspectorArgumentCount)
$releaseToolProxyBootstrapInspectorBindingCompatibility = `
    Assert-ThreadsModProxyBootstrapInspectorBindingContract `
        -ReleaseWrapperAst $patchedApkAst `
        -FixtureHarnessAst $dexProxyBootstrapFlowFixtureTestAst `
        -ReviewedArgumentCount `
            ([int]$resolution.release.expectedDexProxyBootstrapFlowInspectorArgumentCount)
$jadxVersionLines = @(Invoke-Captured -Command $Java -Arguments @(
        '-cp', $jadxJar, 'jadx.cli.JadxCLI', '--version'))
$jadxVersion = [string]$jadxVersionLines[-1]
if ($jadxVersion.Trim() -ne [string]$resolution.toolchain.jadxVersion) {
    throw "JADX version mismatch. Expected '$($resolution.toolchain.jadxVersion)', observed '$jadxVersion'."
}

$dexBridgeFlowFixtureReportPath = Join-Path $scratchFull 'dex-bridge-flow-fixtures.json'
$dexBridgeFlowFixtureResult = & $dexBridgeFlowFixtureTest `
    -ScratchRoot (Join-Path $scratchFull 'dex-bridge-flow-fixtures') `
    -ResolutionPath $resolutionPathFull `
    -Java $Java `
    -Javac $Javac `
    -AndroidSdk $AndroidSdk `
    -BuildToolsVersion $BuildToolsVersion `
    -SevenZip $SevenZip `
    -ReportPath $dexBridgeFlowFixtureReportPath
if ([string]$dexBridgeFlowFixtureResult.status -ne 'passed' `
        -or [int]$dexBridgeFlowFixtureResult.expectedFixtureCount -ne 328 `
        -or @($dexBridgeFlowFixtureResult.fixtures).Count -ne 328) {
    throw 'Signed-DEX bridge-flow fixture prerequisite did not pass all 328 exact cases.'
}
$dexBridgeFlowFixtureEvidence = [pscustomobject]@{
    status = [string]$dexBridgeFlowFixtureResult.status
    expectedFixtureCount = [int]$dexBridgeFlowFixtureResult.expectedFixtureCount
    inspectorSha256 = [string]$resolution.assets.dexBridgeFlowInspectorSourceSha256
    assemblerSha256 = [string]$resolution.assets.dexBridgeFlowFixtureAssemblerSourceSha256
    testSha256 = [string]$resolution.assets.dexBridgeFlowInspectorTestSourceSha256
    fixtureTreeSha256 = [string]$resolution.assets.dexBridgeFlowFixtureTreeSha256
    fixtures = @($dexBridgeFlowFixtureResult.fixtures)
}

$dexReportPermalinkFlowFixtureReportPath = Join-Path $scratchFull 'dex-report-permalink-flow-fixtures.json'
$dexReportPermalinkFlowFixtureResult = & $dexReportPermalinkFlowFixtureTest `
    -ScratchRoot (Join-Path $scratchFull 'dex-report-permalink-flow-fixtures') `
    -ResolutionPath $resolutionPathFull `
    -Java $Java `
    -Javac $Javac `
    -ReportPath $dexReportPermalinkFlowFixtureReportPath
if ([string]$dexReportPermalinkFlowFixtureResult.status -ne 'passed' `
        -or [int]$dexReportPermalinkFlowFixtureResult.expectedFixtureCount -ne 41 `
        -or @($dexReportPermalinkFlowFixtureResult.fixtures).Count -ne 41 `
        -or [int]$dexReportPermalinkFlowFixtureResult.inspectorArgumentCount -ne 33) {
    throw 'Signed-DEX report-permalink-flow fixture prerequisite did not pass all 41 exact cases with the 33-argument inspector.'
}
$dexReportPermalinkFlowFixtureEvidence = [pscustomobject]@{
    status = [string]$dexReportPermalinkFlowFixtureResult.status
    expectedFixtureCount = [int]$dexReportPermalinkFlowFixtureResult.expectedFixtureCount
    inspectorArgumentCount = [int]$dexReportPermalinkFlowFixtureResult.inspectorArgumentCount
    inspectorSha256 = [string]$resolution.assets.dexReportPermalinkFlowInspectorSourceSha256
    testSha256 = [string]$resolution.assets.dexReportPermalinkFlowInspectorTestSourceSha256
    fixtureTreeSha256 = [string]$resolution.assets.dexReportPermalinkFlowFixtureTreeSha256
    fixtures = @($dexReportPermalinkFlowFixtureResult.fixtures)
}

$dexProxyBootstrapFlowFixtureReportPath = Join-Path $scratchFull `
    'dex-proxy-bootstrap-flow-fixtures.json'
$dexProxyBootstrapFlowFixtureResult = & $dexProxyBootstrapFlowFixtureTest `
    -ScratchRoot (Join-Path $scratchFull 'dex-proxy-bootstrap-flow-fixtures') `
    -ResolutionPath $resolutionPathFull `
    -Java $Java `
    -Javac $Javac `
    -ReportPath $dexProxyBootstrapFlowFixtureReportPath
if ([string]$dexProxyBootstrapFlowFixtureResult.status -ne 'passed' `
        -or [int]$dexProxyBootstrapFlowFixtureResult.expectedFixtureCount -ne 13 `
        -or @($dexProxyBootstrapFlowFixtureResult.fixtures).Count -ne 13 `
        -or [int]$dexProxyBootstrapFlowFixtureResult.inspectorArgumentCount -ne 11) {
    throw 'Signed-DEX proxy-bootstrap-flow fixture prerequisite did not pass all 13 exact cases with the 11-argument inspector.'
}
$dexProxyBootstrapFlowFixtureEvidence = [pscustomobject]@{
    status = [string]$dexProxyBootstrapFlowFixtureResult.status
    expectedFixtureCount = [int]$dexProxyBootstrapFlowFixtureResult.expectedFixtureCount
    inspectorArgumentCount = `
        [int]$dexProxyBootstrapFlowFixtureResult.inspectorArgumentCount
    inspectorSha256 = `
        [string]$resolution.assets.dexProxyBootstrapFlowInspectorSourceSha256
    testSha256 = `
        [string]$resolution.assets.dexProxyBootstrapFlowInspectorTestSourceSha256
    fixtureTreeSha256 = `
        [string]$resolution.assets.dexProxyBootstrapFlowFixtureTreeSha256
    fixtures = @($dexProxyBootstrapFlowFixtureResult.fixtures)
}

$expectedDexUpdateFlowFixtureCount = 96
$expectedDexUpdateFlowInspectorArgumentCount = 12
if ([int]$resolution.release.expectedDexUpdateFlowFixtureCount `
        -ne $expectedDexUpdateFlowFixtureCount `
        -or [int]$resolution.release.expectedDexUpdateFlowInspectorArgumentCount `
            -ne $expectedDexUpdateFlowInspectorArgumentCount) {
    throw 'Resolution updater flow fixture or inspector argument count drifted.'
}
$dexUpdateFlowFixtureReportPath = Join-Path $scratchFull `
    'dex-update-flow-fixtures.json'
$dexUpdateFlowFixtureResult = & $dexUpdateFlowFixtureTest `
    -ScratchRoot (Join-Path $scratchFull 'dex-update-flow-fixtures') `
    -ResolutionPath $resolutionPathFull `
    -AndroidSdk $AndroidSdk `
    -BuildToolsVersion $BuildToolsVersion `
    -Java $Java `
    -Javac $Javac `
    -ReportPath $dexUpdateFlowFixtureReportPath
if ([string]$dexUpdateFlowFixtureResult.status -ne 'passed' `
        -or [int]$dexUpdateFlowFixtureResult.expectedFixtureCount `
            -ne $expectedDexUpdateFlowFixtureCount `
        -or @($dexUpdateFlowFixtureResult.fixtures).Count `
            -ne $expectedDexUpdateFlowFixtureCount `
        -or [int]$dexUpdateFlowFixtureResult.inspectorArgumentCount `
            -ne $expectedDexUpdateFlowInspectorArgumentCount `
        -or $dexUpdateFlowFixtureResult.semanticChecksBeforeDigest -ne $true `
        -or [string]$dexUpdateFlowFixtureResult.representationStableEncoding.status `
            -ne 'passed' `
        -or [string]$dexUpdateFlowFixtureResult.representationStableEncoding.semanticSha256 `
            -notmatch '^[0-9a-f]{64}$' `
        -or [int]$dexUpdateFlowFixtureResult.representationStableEncoding.scopedClassCount `
            -ne 25 `
        -or [int]$dexUpdateFlowFixtureResult.representationStableEncoding.constStringJumboReplacements `
            -lt 1 `
        -or [int]$dexUpdateFlowFixtureResult.representationStableEncoding.tryCount `
            -lt 1 `
        -or [int]$dexUpdateFlowFixtureResult.representationStableEncoding.switchCount `
            -lt 1 `
        -or [int]$dexUpdateFlowFixtureResult.representationStableEncoding.branchCount `
            -lt 1) {
    throw 'Signed-DEX updater flow fixture prerequisite did not pass all 96 exact cases with the 12-argument inspector.'
}
$dexUpdateFlowFixtureEvidence = [pscustomobject]@{
    status = [string]$dexUpdateFlowFixtureResult.status
    expectedFixtureCount = [int]$dexUpdateFlowFixtureResult.expectedFixtureCount
    inspectorArgumentCount = [int]$dexUpdateFlowFixtureResult.inspectorArgumentCount
    semanticSha256 = [string]$dexUpdateFlowFixtureResult.positiveSemanticSha256
    inspectorSha256 = [string]$resolution.assets.dexUpdateFlowInspectorSourceSha256
    testSha256 = [string]$resolution.assets.dexUpdateFlowInspectorTestSourceSha256
    fixtureTreeSha256 = [string]$resolution.assets.dexUpdateFlowFixtureTreeSha256
    representationStableEncoding = `
        $dexUpdateFlowFixtureResult.representationStableEncoding
    fixtures = @($dexUpdateFlowFixtureResult.fixtures)
}

$classes = Join-Path $scratchFull 'classes'
[IO.Directory]::CreateDirectory($classes) | Out-Null
$dexInspectorSource = Join-Path $PSScriptRoot 'DexInspector.java'
$dexInspectorHash = Get-PatchletSha256 -Path $dexInspectorSource
if ($dexInspectorHash -ne [string]$resolution.assets.dexInspectorSourceSha256) {
    throw 'DEX inspector source hash does not match the resolution.'
}
$null = Invoke-Captured -Command $Javac -Arguments @('-encoding', 'UTF-8', '-d', $classes, $dexInspectorSource)
$null = Invoke-Captured -Command $Javac -Arguments @(
    '-encoding', 'UTF-8', '-cp', $apktoolJar, '-d', $classes, $dexLiteralCallSource)
$null = Invoke-Captured -Command $Javac -Arguments @(
    '-encoding', 'UTF-8', '-cp', $apktoolJar, '-d', $classes,
    $dexProxyBootstrapFlowSource)
$null = Invoke-Captured -Command $Javac -Arguments @(
    '-encoding', 'UTF-8', '-cp', $apktoolJar, '-d', $classes,
    $dexUpdateFlowSource)
$null = Invoke-Captured -Command $Javac -Arguments @(
    '-encoding', 'UTF-8', '-cp', $apktoolJar, '-d', $classes, $dexBridgeFlowSource)
$null = Invoke-Captured -Command $Javac -Arguments @(
    '-encoding', 'UTF-8', '-cp', $apktoolJar, '-d', $classes,
    $dexReportPermalinkFlowSource)
$dexArguments = @('-cp', $classes, 'DexInspector', $apkFull,
    "--expected-root-dex=$($resolution.source.rootDexCount)",
    "--max-primary-methods=$($resolution.release.maximumPrimaryMethodReferences)")
foreach ($required in @($resolution.release.requiredReadEndpoints)) { $dexArguments += "--require=$required" }
foreach ($required in @($resolution.update.metadataEndpoints)) { $dexArguments += "--require=$required" }
$dexArguments += "--require=$($resolution.release.requiredWriteEndpoint)"
foreach ($required in @($resolution.release.requiredClassDescriptors)) { $dexArguments += "--require=$required" }
foreach ($required in @($resolution.release.requiredHookCalls)) { $dexArguments += "--require=$required" }
foreach ($forbidden in @($resolution.release.forbiddenDexStrings)) { $dexArguments += "--forbid=$forbidden" }
$dexLines = @(Invoke-Captured -Command $Java -Arguments $dexArguments)
$dex = $dexLines[-1] | ConvertFrom-Json

$dexDirectStringCalls = @()
$dexLiteralClasspath = $classes + [IO.Path]::PathSeparator + $apktoolJar
foreach ($contract in @($resolution.release.requiredDexDirectStringCalls)) {
    if (-not [bool]$contract.requireImmediateConstString `
            -or -not [bool]$contract.requireOnlyCalleeOccurrence) {
        throw "DEX direct-string contract '$($contract.id)' does not retain both fail-closed requirements."
    }
    $literalLines = @(Invoke-Captured -Command $Java -Arguments @(
        '-cp', $dexLiteralClasspath, 'DexLiteralCallInspector', $apkFull,
        [string]$contract.ownerClassDescriptor,
        [string]$contract.ownerMethodName,
        [string]$contract.ownerMethodDescriptor,
        [string]$contract.calleeClassDescriptor,
        [string]$contract.calleeMethodName,
        [string]$contract.calleeMethodDescriptor,
        [string]$contract.invokeOpcode,
        [string]$contract.stringParameterIndex,
        [string]$contract.literal,
        [string]$contract.expectedOccurrences))
    $literalResult = $literalLines[-1] | ConvertFrom-Json
    if ([string]$literalResult.status -ne 'passed' `
            -or [int]$literalResult.matchedCount -ne [int]$contract.expectedOccurrences `
            -or [string]$literalResult.literal -ne [string]$contract.literal `
            -or [string]$literalResult.invokeOpcode -ne [string]$contract.invokeOpcode `
            -or [int]$literalResult.literalCodeOffset -lt 0 `
            -or [int]$literalResult.callCodeOffset -le [int]$literalResult.literalCodeOffset `
            -or [int]$literalResult.argumentRegister -lt 0 `
            -or [int]$literalResult.alternateEntryCount -ne 0) {
        throw "DEX direct-string contract '$($contract.id)' returned incomplete evidence."
    }
    $dexDirectStringCalls += [pscustomobject]@{
        id = [string]$contract.id
        result = $literalResult
    }
}

$proxyBootstrapContract = $resolution.release.requiredDexProxyBootstrapFlow
$expectedProxyFallbackMethods = @(
    'Landroid/net/VpnService$Builder;->allowBypass()Landroid/net/VpnService$Builder;',
    'Ljava/lang/System;->setProperty(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;',
    'Ljava/net/ProxySelector;->setDefault(Ljava/net/ProxySelector;)V'
)
$expectedProxyFallbackStrings = @(
    'socksProxyHost',
    'socksProxyPort',
    'java.net.useSystemProxies'
)
$reviewedProxyBootstrapLayout = (
    ([string]$proxyBootstrapContract.expectedDexName -ceq 'classes10.dex' -and
        [string]$proxyBootstrapContract.originalNextFieldReference -ceq
            'LX/319;->A05:LX/319;') -or
    ([string]$proxyBootstrapContract.expectedDexName -ceq 'classes6.dex' -and
        [string]$proxyBootstrapContract.originalNextFieldReference -ceq
            'LX/0143;->A06:LX/0143;')
)
if ([string]$proxyBootstrapContract.id `
        -ne 'socks5-bootstrap-signed-dex-flow-contract' `
        -or -not $reviewedProxyBootstrapLayout `
        -or (@($proxyBootstrapContract.forbiddenMethodReferences) -join "`n") `
            -ne ($expectedProxyFallbackMethods -join "`n") `
        -or (@($proxyBootstrapContract.forbiddenStringLiterals) -join "`n") `
            -ne ($expectedProxyFallbackStrings -join "`n") `
        -or -not [bool]$proxyBootstrapContract.requireExactEntryPrefix `
        -or -not [bool]$proxyBootstrapContract.requireSoleBootstrapCaller `
        -or -not [bool]$proxyBootstrapContract.requireParameterRegisterFlow `
        -or -not [bool]$proxyBootstrapContract.requireImmediateAdjacency `
        -or -not [bool]$proxyBootstrapContract.requireNoAlternateEntry `
        -or -not [bool]$proxyBootstrapContract.requireNoBootstrapTryCoverage `
        -or -not [bool]$proxyBootstrapContract.requireOriginalNextField `
        -or -not [bool]$proxyBootstrapContract.requireExactFallbackAbsence) {
    throw 'Signed-DEX proxy-bootstrap-flow contract metadata is incomplete.'
}
$proxyBootstrapLines = @(Invoke-Captured -Command $Java -Arguments @(
    '-cp', $dexLiteralClasspath, 'DexProxyBootstrapFlowInspector', $apkFull,
    [string]$proxyBootstrapContract.expectedDexName,
    [string]$proxyBootstrapContract.ownerClassDescriptor,
    [string]$proxyBootstrapContract.ownerMethodName,
    [string]$proxyBootstrapContract.ownerMethodDescriptor,
    [string]$proxyBootstrapContract.superClassDescriptor,
    [string]$proxyBootstrapContract.superMethodName,
    [string]$proxyBootstrapContract.superMethodDescriptor,
    [string]$proxyBootstrapContract.bootstrapClassDescriptor,
    [string]$proxyBootstrapContract.bootstrapMethodName,
    [string]$proxyBootstrapContract.bootstrapMethodDescriptor))
$dexProxyBootstrapFlow = $proxyBootstrapLines[-1] | ConvertFrom-Json
if ([string]$dexProxyBootstrapFlow.status -ne 'passed' `
        -or [string]$dexProxyBootstrapFlow.contract `
            -ne [string]$proxyBootstrapContract.id `
        -or [string]$dexProxyBootstrapFlow.dex `
            -ne [string]$proxyBootstrapContract.expectedDexName `
        -or [string]$dexProxyBootstrapFlow.owner `
            -ne [string]$proxyBootstrapContract.ownerClassDescriptor `
        -or [string]$dexProxyBootstrapFlow.method `
            -ne ([string]$proxyBootstrapContract.ownerMethodName `
                + [string]$proxyBootstrapContract.ownerMethodDescriptor) `
        -or [string]$dexProxyBootstrapFlow.originalAnchorField `
            -ne [string]$proxyBootstrapContract.originalNextFieldReference `
        -or (@($dexProxyBootstrapFlow.forbiddenFallbackMethods) -join "`n") `
            -ne ($expectedProxyFallbackMethods -join "`n") `
        -or (@($dexProxyBootstrapFlow.forbiddenFallbackStrings) -join "`n") `
            -ne ($expectedProxyFallbackStrings -join "`n") `
        -or [int]$dexProxyBootstrapFlow.bootstrapCallCount -ne 1 `
        -or [int]$dexProxyBootstrapFlow.superOffset -lt 0 `
        -or [int]$dexProxyBootstrapFlow.bootstrapOffset `
            -le [int]$dexProxyBootstrapFlow.superOffset `
        -or [int]$dexProxyBootstrapFlow.originalAnchorOffset `
            -le [int]$dexProxyBootstrapFlow.bootstrapOffset `
        -or $dexProxyBootstrapFlow.checks.exactEntryPrefix -ne $true `
        -or $dexProxyBootstrapFlow.checks.soleBootstrapCaller -ne $true `
        -or $dexProxyBootstrapFlow.checks.sameContextRegister -ne $true `
        -or $dexProxyBootstrapFlow.checks.adjacentAfterSuper -ne $true `
        -or $dexProxyBootstrapFlow.checks.noAlternateEntry -ne $true `
        -or $dexProxyBootstrapFlow.checks.outsideTryRanges -ne $true `
        -or $dexProxyBootstrapFlow.checks.originalAnchorAdjacent -ne $true `
        -or $dexProxyBootstrapFlow.checks.fallbackReferencesAbsent -ne $true) {
    throw 'Signed-DEX proxy-bootstrap-flow evidence is incomplete.'
}

$updateFlowContract = $resolution.release.requiredDexUpdateFlow
$expectedUpdateFlowRoots = @(
    'Lthreadsmod/update/UpdateController;',
    'Lthreadsmod/update/UpdateEndpoints;',
    'Lthreadsmod/update/UpdateJson;',
    'Lthreadsmod/update/UpdateManifest;',
    'Lthreadsmod/update/UpdateSignature;',
    'Lthreadsmod/update/UpdateStore;',
    'Lthreadsmod/bootstrap/ModBootstrap;'
)
if ([string]$updateFlowContract.id -ne 'threadsmod-update-flow-v1' `
        -or [string]$updateFlowContract.expectedDexName -ne 'classes.dex' `
        -or [string]$updateFlowContract.classPrefix -ne 'Lthreadsmod/update/' `
        -or [string]$updateFlowContract.expectedSemanticSha256 `
            -notmatch '^[0-9a-f]{64}$' `
        -or [int]$updateFlowContract.expectedSemanticClassCount -ne 24 `
        -or (@($updateFlowContract.orderedRootDescriptors) -join "`n") `
            -cne ($expectedUpdateFlowRoots -join "`n")) {
    throw 'Signed-DEX updater flow contract metadata is incomplete.'
}
$updateFlowLines = @(Invoke-Captured -Command $Java -Arguments @(
    '-cp', $dexLiteralClasspath, 'DexUpdateFlowInspector', $apkFull,
    [string]$updateFlowContract.expectedDexName,
    [string]$updateFlowContract.classPrefix,
    [string]$updateFlowContract.expectedSemanticSha256,
    [string]$updateFlowContract.expectedSemanticClassCount,
    [string]$updateFlowContract.orderedRootDescriptors[0],
    [string]$updateFlowContract.orderedRootDescriptors[1],
    [string]$updateFlowContract.orderedRootDescriptors[2],
    [string]$updateFlowContract.orderedRootDescriptors[3],
    [string]$updateFlowContract.orderedRootDescriptors[4],
    [string]$updateFlowContract.orderedRootDescriptors[5],
    [string]$updateFlowContract.orderedRootDescriptors[6]))
$dexUpdateFlow = $updateFlowLines[-1] | ConvertFrom-Json
$requiredUpdateFlowChecks = @(
    'completeUpdaterGraph',
    'normalControlFlow',
    'exceptionalControlFlow',
    'registerValueFlow',
    'bootstrapArbitration',
    'signatureAndMetadata',
    'eligibilityAndPolicy',
    'requiredOptionalDialog',
    'explicitUpdateTap',
    'retainedUnavailableOnly',
    'verifiedFileProvenance',
    'currentBinarySerialization',
    'lifecycleOwnership',
    'storeAntiRollback'
)
if ([string]$dexUpdateFlow.status -ne 'passed' `
        -or [string]$dexUpdateFlow.contract -ne [string]$updateFlowContract.id `
        -or [string]$dexUpdateFlow.dex `
            -ne [string]$updateFlowContract.expectedDexName `
        -or [int]$dexUpdateFlow.updaterClassCount `
            -ne [int]$updateFlowContract.expectedSemanticClassCount `
        -or [string]$dexUpdateFlow.semanticSha256 `
            -cne [string]$updateFlowContract.expectedSemanticSha256) {
    throw 'Signed-DEX updater flow evidence is incomplete.'
}
$observedUpdateFlowChecks = @($dexUpdateFlow.checks.PSObject.Properties.Name)
if ($observedUpdateFlowChecks.Count -ne $requiredUpdateFlowChecks.Count `
        -or @($requiredUpdateFlowChecks | Where-Object {
                $name = [string]$_
                @($observedUpdateFlowChecks | Where-Object {
                        [string]$_ -ceq $name
                    }).Count -ne 1 `
                    -or $dexUpdateFlow.checks.$name -ne $true
            }).Count -ne 0) {
    throw 'Signed-DEX updater flow did not return every exact reviewed semantic check.'
}

$dexBridgeFlows = @()
foreach ($contract in @($resolution.release.requiredDexBridgeFlows)) {
    if ([string]$contract.symbolsPointer -ne '/bridge/symbols' `
            -or [string]$contract.inlineSymbolsPointer -ne '/inlineControls/symbols' `
            -or [string]$contract.passivePreflightMethodName -ne 'passivePreflight' `
            -or [int]$contract.expectedPrepareModelInvokeCount -ne 2 `
            -or [int]$contract.expectedPassivePreflightInvokeCount -ne 1 `
            -or [int]$contract.expectedCacheLookupInvokeCount -ne 2 `
            -or [int]$contract.expectedCacheFactoryInvokeCount -ne 2 `
            -or [int]$contract.expectedCachePlaceholderInvokeCount -ne 2 `
            -or [string]$contract.fetchWorkerRunMethodReference `
                -ne 'Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->run()V' `
            -or [string]$contract.scheduleManualDrainMethodReference `
                -ne 'Lthreadsmod/autoblock/AutoBlockSync;->scheduleManualDrain(J)V' `
            -or -not [bool]$contract.requireNarrowSeamHandlers `
            -or -not [bool]$contract.requirePassivePreflightBeforeReservation `
            -or -not [bool]$contract.requirePreparationResultFlow `
            -or -not [bool]$contract.requireCallerProvenance `
            -or -not [bool]$contract.requireCallerCatchTopology `
            -or -not [bool]$contract.requireDirectCallerCallbackExecution `
            -or -not [bool]$contract.requireCallerCallbackEffectTopology `
            -or -not [bool]$contract.requireCallbackExceptionalControlFlow `
            -or -not [bool]$contract.requireBridgeEntryReachability `
            -or -not [bool]$contract.requireSchedulerEnqueueAcceptance `
            -or -not [bool]$contract.requireUncertainMutationQuarantine `
            -or -not [bool]$contract.requirePrivateSeamCallProvenance `
            -or -not [bool]$contract.requireStableInlinePrivateSeamAbsence `
            -or -not [bool]$contract.requireDispatcherCallProvenance `
            -or -not [bool]$contract.requireAsyncCallbackFirewall `
            -or -not [bool]$contract.requireTerminalCallbackMap `
            -or -not [bool]$contract.requireImmutableTargetFlow `
            -or -not [bool]$contract.requireModelIdGuard `
            -or -not [bool]$contract.requireNativeMutationIdentity) {
        throw "DEX bridge-flow contract '$($contract.id)' does not retain every fail-closed requirement."
    }
    $symbols = $resolution.bridge.symbols
    $inlineSymbols = $resolution.inlineControls.symbols
    $bridgeLines = @(Invoke-Captured -Command $Java -Arguments @(
        '-cp', $dexLiteralClasspath, 'DexBridgeFlowInspector', $apkFull,
        [string]$contract.ownerClassDescriptor,
        [string]$contract.blockMethodName,
        [string]$contract.blockResolvedMethodName,
        [string]$contract.blockModelMethodName,
        [string]$contract.prepareModelMethodName,
        [string]$symbols.sessionDescriptor,
        [string]$symbols.modelDescriptor,
        [string]$symbols.cacheLookupMethod,
        [string]$symbols.userCacheFactoryMethod,
        [string]$symbols.userCacheGetOrPutMethod,
        [string]$symbols.authorIdMethod,
        [string]$symbols.alreadyBlockedMethod,
        [string]$symbols.blockMutationMethod,
        [string]$symbols.surface,
        [string]$symbols.mutationStartedCallback,
        [string]$symbols.mutationFailureCallback,
        [string]$symbols.mutationEndedCallback,
        [string]$symbols.mutationCancelCallback,
        [string]$symbols.mutationSuccessCallback,
        [string]$symbols.mutationCallbackInterface,
        [string]$contract.automaticCallerClassDescriptor,
        [string]$contract.manualCallerClassDescriptor,
        [string]$contract.fetchWorkerRunMethodReference,
        [string]$contract.scheduleManualDrainMethodReference,
        [string]$inlineSymbols.mediaLookupMethod,
        [string]$inlineSymbols.mediaAuthorMethod,
        [string]$inlineSymbols.authorUsernameMethod))
    $bridgeResult = $bridgeLines[-1] | ConvertFrom-Json
    if ([string]$resolution.source.versionName -ceq '444.0.0.45.85') {
        if ([string]$bridgeResult.callerProvenance.automatic.ownerMode -ne 'single-target' `
                -or [int]$bridgeResult.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne 3 `
                -or [int]$bridgeResult.callerCallbackEffectTopology.automatic.pacedNextPosts -ne 0) {
            throw "Current DEX bridge-flow contract '$($contract.id)' did not prove one immutable target and fresh-drain continuation."
        }
    } elseif ([string]$resolution.source.versionName -ceq '415.0.0.26.77') {
        $legacyBridgeResult = $bridgeResult
        if ([string]$legacyBridgeResult.callerProvenance.automatic.ownerMode -ne 'legacy-batch' `
                -or [int]$legacyBridgeResult.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne 5 `
                -or [int]$legacyBridgeResult.callerCallbackEffectTopology.automatic.pacedNextPosts -ne 1) {
            throw "Historical DEX bridge-flow contract '$($contract.id)' did not retain its exact reviewed batch evidence."
        }
    } else {
        throw 'DEX bridge-flow owner mode has no exact reviewed version binding.'
    }
    if ([string]$bridgeResult.status -ne 'passed' `
            -or [string]$bridgeResult.contract -ne [string]$contract.id `
            -or [string]$bridgeResult.dex -ne [string]$contract.expectedDexName `
            -or [string]$bridgeResult.classDescriptor -ne [string]$contract.ownerClassDescriptor `
            -or [string]$bridgeResult.mutationCallbackInterface `
                -ne [string]$symbols.mutationCallbackInterface `
            -or [int]$bridgeResult.rawCalls.block -ne [int]$contract.expectedBlockInvokeCount `
            -or [int]$bridgeResult.rawCalls.blockResolved -ne [int]$contract.expectedBlockResolvedInvokeCount `
            -or [int]$bridgeResult.rawCalls.blockModel -ne [int]$contract.expectedBlockModelInvokeCount `
            -or [int]$bridgeResult.rawCalls.prepareModel -ne 2 `
            -or [int]$bridgeResult.rawCalls.passivePreflight -ne 1 `
            -or [int]$bridgeResult.definitions.block -ne 1 `
            -or [int]$bridgeResult.definitions.blockResolved -ne 1 `
            -or [int]$bridgeResult.definitions.blockModel -ne 1 `
            -or [int]$bridgeResult.definitions.prepareModel -ne 1 `
            -or [int]$bridgeResult.definitions.passivePreflight -ne 1 `
            -or [int]$bridgeResult.definitions.mutationCallback -ne 1 `
            -or [int]$bridgeResult.definitions.dispatcher -ne 1 `
            -or [int]$bridgeResult.definitions.delivery -ne 1 `
            -or [string]$bridgeResult.callerProvenance.automatic.descriptor `
                -ne [string]$contract.automaticCallerClassDescriptor `
            -or [int]$bridgeResult.callerProvenance.automatic.block -ne 1 `
            -or [int]$bridgeResult.callerProvenance.automatic.blockResolved -ne 0 `
            -or [int]$bridgeResult.callerProvenance.automatic.blockModel -ne 0 `
            -or [int]$bridgeResult.callerProvenance.automatic.prepareModel -ne 0 `
            -or [int]$bridgeResult.callerProvenance.automatic.passivePreflight -ne 1 `
            -or [string]$bridgeResult.callerProvenance.manual.descriptor `
                -ne [string]$contract.manualCallerClassDescriptor `
            -or [int]$bridgeResult.callerProvenance.manual.block -ne 1 `
            -or [int]$bridgeResult.callerProvenance.manual.blockResolved -ne 1 `
            -or [int]$bridgeResult.callerProvenance.manual.blockModel -ne 0 `
            -or [int]$bridgeResult.callerProvenance.manual.prepareModel -ne 0 `
            -or [int]$bridgeResult.callerProvenance.manual.passivePreflight -ne 0 `
            -or [int]$bridgeResult.callerProvenance.bridge.block -ne 1 `
            -or [int]$bridgeResult.callerProvenance.bridge.blockResolved -ne 0 `
            -or [int]$bridgeResult.callerProvenance.bridge.blockModel -ne 2 `
            -or [int]$bridgeResult.callerProvenance.bridge.prepareModel -ne 2 `
            -or [int]$bridgeResult.callerProvenance.bridge.passivePreflight -ne 0 `
            -or [int]$bridgeResult.callerProvenance.other.block -ne 0 `
            -or [int]$bridgeResult.callerProvenance.other.blockResolved -ne 0 `
            -or [int]$bridgeResult.callerProvenance.other.blockModel -ne 0 `
            -or [int]$bridgeResult.callerProvenance.other.prepareModel -ne 0 `
            -or [int]$bridgeResult.callerProvenance.other.passivePreflight -ne 0 `
            -or [int]$bridgeResult.callerCatchTopology.automatic.bridgeMethodCount -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.automatic.tryCount -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.automatic.block -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.automatic.blockResolved -ne 0 `
            -or [int]$bridgeResult.callerCatchTopology.automatic.handoffCalls -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.automatic.falseReturns -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.automatic.handlerLiteralRoutes -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.automatic.unreviewedInvokes -ne 0 `
            -or [int]$bridgeResult.callerCatchTopology.automatic.unreviewedOpcodes -ne 0 `
            -or [int]$bridgeResult.callerCatchTopology.manual.bridgeMethodCount -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.manual.tryCount -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.manual.block -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.manual.blockResolved -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.manual.handoffCalls -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.manual.falseReturns -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.manual.handlerLiteralRoutes -ne 1 `
            -or [int]$bridgeResult.callerCatchTopology.manual.unreviewedInvokes -ne 0 `
            -or [int]$bridgeResult.callerCatchTopology.manual.unreviewedOpcodes -ne 0 `
            -or -not [bool]$bridgeResult.callerCallbackExecution.automatic.interface `
            -or [int]$bridgeResult.callerCallbackExecution.automatic.started -ne 1 `
            -or [int]$bridgeResult.callerCallbackExecution.automatic.failure -ne 1 `
            -or [int]$bridgeResult.callerCallbackExecution.automatic.success -ne 1 `
            -or [int]$bridgeResult.callerCallbackExecution.automatic.immediateRunnableDispatches -ne 0 `
            -or -not [bool]$bridgeResult.callerCallbackExecution.manual.interface `
            -or [int]$bridgeResult.callerCallbackExecution.manual.started -ne 1 `
            -or [int]$bridgeResult.callerCallbackExecution.manual.failure -ne 1 `
            -or [int]$bridgeResult.callerCallbackExecution.manual.success -ne 1 `
            -or [int]$bridgeResult.callerCallbackExecution.manual.immediateRunnableDispatches -ne 0 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.automatic.startedLatchWrites -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.automatic.statusCalls -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.automatic.failureRoutes -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.automatic.completionSaveCalls -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.automatic.completionQuarantineBranches -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.automatic.ownershipReleaseCalls -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.automatic.successRecordCalls -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.automatic.waitingClearWrites -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.automatic.terminalCatchRoutes -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.manual.startedLatchWrites -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.manual.startedDispatchCalls -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.manual.statusCalls -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.manual.runtimeStateCalls -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.manual.failureRoutes -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.manual.completionSaveCalls -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.manual.completionQuarantineBranches -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.manual.ownershipReleaseCalls -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.manual.successDispatchCalls -ne 1 `
            -or [int]$bridgeResult.callerCallbackEffectTopology.manual.schedulerReleaseCalls -ne 2 `
            -or [int]$bridgeResult.privateSeamProvenance.cacheLookup -ne 2 `
            -or [int]$bridgeResult.privateSeamProvenance.cacheFactory -ne 2 `
            -or [int]$bridgeResult.privateSeamProvenance.cachePlaceholder -ne 2 `
            -or [int]$bridgeResult.privateSeamProvenance.authorId -ne 1 `
            -or [int]$bridgeResult.privateSeamProvenance.alreadyBlocked -ne 1 `
            -or [int]$bridgeResult.privateSeamProvenance.nativeMutation -ne 1 `
            -or [int]$bridgeResult.stablePrivateSeamProvenance.mediaLookup -ne 0 `
            -or [int]$bridgeResult.stablePrivateSeamProvenance.authorLookup -ne 0 `
            -or [int]$bridgeResult.stablePrivateSeamProvenance.username -ne 0 `
            -or [int]$bridgeResult.dispatcherCallProvenance.bridge.started -ne 0 `
            -or [int]$bridgeResult.dispatcherCallProvenance.bridge.failure -ne 10 `
            -or [int]$bridgeResult.dispatcherCallProvenance.bridge.success -ne 1 `
            -or [int]$bridgeResult.dispatcherCallProvenance.mutationCallback.started -ne 1 `
            -or [int]$bridgeResult.dispatcherCallProvenance.mutationCallback.failure -ne 1 `
            -or [int]$bridgeResult.dispatcherCallProvenance.mutationCallback.success -ne 1 `
            -or [int]$bridgeResult.dispatcherCallProvenance.other.started -ne 0 `
            -or [int]$bridgeResult.dispatcherCallProvenance.other.failure -ne 0 `
            -or [int]$bridgeResult.dispatcherCallProvenance.other.success -ne 0 `
            -or [int]$bridgeResult.dispatcherCallProvenance.aggregate.started -ne 1 `
            -or [int]$bridgeResult.dispatcherCallProvenance.aggregate.failure -ne 11 `
            -or [int]$bridgeResult.dispatcherCallProvenance.aggregate.success -ne 2 `
            -or [int]$bridgeResult.dispatcherCallProvenance.enqueue -ne 3 `
            -or [int]$bridgeResult.dispatcherCallProvenance.deliveryConstructor -ne 1 `
            -or [int]$bridgeResult.dispatcherCallProvenance.directDeliveryRun -ne 0 `
            -or [int]$bridgeResult.bridgeCallbackRouting.failure -ne 10 `
            -or [int]$bridgeResult.bridgeCallbackRouting.success -ne 1 `
            -or [int]$bridgeResult.bridgeCallbackRouting.directOutsideDelivery -ne 0 `
            -or [int]$bridgeResult.mutationCallback.dispatcherStarted -ne 1 `
            -or [int]$bridgeResult.mutationCallback.dispatcherFailure -ne 1 `
            -or [int]$bridgeResult.mutationCallback.dispatcherSuccess -ne 1 `
            -or [int]$bridgeResult.mutationCallback.handlerPost -ne 1 `
            -or [int]$bridgeResult.mutationCallback.deliveryStarted -ne 1 `
            -or [int]$bridgeResult.mutationCallback.deliveryFailure -ne 1 `
            -or [int]$bridgeResult.mutationCallback.deliverySuccess -ne 1 `
            -or -not [bool]$bridgeResult.checks.directIdCacheFallback `
            -or -not [bool]$bridgeResult.checks.nullPlaceholderSeed `
            -or -not [bool]$bridgeResult.checks.passiveNativePreflight `
            -or -not [bool]$bridgeResult.checks.passiveMatchFailClosed `
            -or -not [bool]$bridgeResult.checks.exactRawBridgeCalls `
            -or -not [bool]$bridgeResult.checks.immutableTargetFlow `
            -or -not [bool]$bridgeResult.checks.narrowSeamHandlers `
            -or -not [bool]$bridgeResult.checks.callbacksOutsidePrivateSeams `
            -or -not [bool]$bridgeResult.checks.modelIdGuard `
            -or -not [bool]$bridgeResult.checks.preparationResultFlow `
            -or -not [bool]$bridgeResult.checks.mutationAfterIdEquality `
            -or -not [bool]$bridgeResult.checks.nativeMutationIdentity `
            -or -not [bool]$bridgeResult.checks.asyncCallbackFirewall `
            -or -not [bool]$bridgeResult.checks.terminalCallbackMap `
            -or -not [bool]$bridgeResult.checks.callerProvenance `
            -or -not [bool]$bridgeResult.checks.callerCatchTopology `
            -or -not [bool]$bridgeResult.checks.directCallerCallbackExecution `
            -or -not [bool]$bridgeResult.checks.callerCallbackEffectTopology `
            -or -not [bool]$bridgeResult.checks.callbackExceptionalControlFlow `
            -or -not [bool]$bridgeResult.checks.bridgeEntryReachability `
            -or -not [bool]$bridgeResult.checks.schedulerEnqueueAcceptance `
            -or -not [bool]$bridgeResult.checks.uncertainMutationQuarantine `
            -or -not [bool]$bridgeResult.checks.privateSeamCallProvenance `
            -or -not [bool]$bridgeResult.checks.stableInlinePrivateSeamAbsence `
            -or -not [bool]$bridgeResult.checks.dispatcherCallProvenance) {
        throw "DEX bridge-flow contract '$($contract.id)' returned incomplete evidence."
    }
    $dexBridgeFlows += [pscustomobject]@{
        id = [string]$contract.id
        result = $bridgeResult
    }
}

$reportPermalinkContract = $resolution.release.requiredDexReportPermalinkFlow
if ([string]$reportPermalinkContract.id -ne 'report-post-permalink-contract' `
        -or [string]$reportPermalinkContract.expectedDexName -ne 'classes.dex' `
        -or [string]$reportPermalinkContract.mediaPermalinkMethodPointer `
            -ne '/reporting/symbols/mediaPermalinkMethod' `
        -or [string]$reportPermalinkContract.mediaCodeMethodPointer `
            -ne '/reporting/symbols/mediaCodeMethod' `
        -or [string]$reportPermalinkContract.mediaBackingFieldPointer `
            -ne '/reporting/symbols/mediaBackingField' `
        -or [string]$reportPermalinkContract.mediaCaptionMethodPointer `
            -ne '/reporting/symbols/mediaCaptionMethod' `
        -or [string]$reportPermalinkContract.captionTextMethodPointer `
            -ne '/reporting/symbols/captionTextMethod' `
        -or [string]$reportPermalinkContract.ufiButtonMethodPointer `
            -ne '/inlineControls/symbols/ufiButtonMethod' `
        -or [string]$reportPermalinkContract.visibilityModifierMethodPointer `
            -ne '/inlineControls/symbols/visibilityModifierMethod' `
        -or [string]$reportPermalinkContract.testTagMethodPointer `
            -ne '/inlineControls/symbols/testTagMethod' `
        -or [string]$reportPermalinkContract.modifierComposedMethodPointer `
            -ne '/inlineControls/symbols/modifierComposedMethod' `
        -or [int]$reportPermalinkContract.ufiButtonDefaultMask -ne 63232 `
        -or [string]$reportPermalinkContract.permalinkResolverMethodReference `
            -ne 'Lthreadsmod/reporting/ReportRequest;->resolveHostPermalink(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;' `
        -or [string]$reportPermalinkContract.excerptResolverMethodReference `
            -ne 'Lthreadsmod/reporting/ReportRequest;->resolveHostExcerpt(Ljava/lang/String;)Ljava/lang/String;' `
        -or [string]$reportPermalinkContract.rowLabelGetterReference `
            -ne 'Lthreadsmod/inlinecontrol/InlineBlockRequest;->getLabel()Ljava/lang/String;' `
        -or [string]$reportPermalinkContract.inlineRowRenderMethodReference `
            -ne 'Lthreadsmod/inlinecontrol/InlineActionRowAdapter;->render(LX/09jq;LX/09dm;LX/03gT;Lthreadsmod/inlinecontrol/InlineBlockRequest;JJ)V' `
        -or [string]$reportPermalinkContract.currentViewerMethodReference `
            -ne 'Lthreadsmod/autoblock/AutoBlockSync;->getCurrentViewer()Ljava/lang/String;') {
    throw 'Signed-DEX report-permalink-flow contract metadata is incomplete.'
}
$reportPermalinkLines = @(Invoke-Captured -Command $Java -Arguments @(
    '-cp', $dexLiteralClasspath, 'DexReportPermalinkFlowInspector', $apkFull,
    [string]$reportPermalinkContract.factoryMethodReference,
    [string]$reportPermalinkContract.resolvedMediaGetterReference,
    [string]$resolution.reporting.symbols.mediaBackingField,
    [string]$resolution.reporting.symbols.mediaPermalinkMethod,
    [string]$resolution.reporting.symbols.mediaCaptionMethod,
    [string]$reportPermalinkContract.requestConstructorReference,
    [string]$reportPermalinkContract.permalinkSanitizerMethodReference,
    [string]$reportPermalinkContract.requestPermalinkFieldReference,
    [string]$reportPermalinkContract.requestNewQueueValidityMethodReference,
    [string]$reportPermalinkContract.requestBaseValidityMethodReference,
    [string]$reportPermalinkContract.requestPermalinkGetterReference,
    [string]$reportPermalinkContract.payloadToJsonMethodReference,
    [string]$reportPermalinkContract.payloadRequestFieldReference,
    [string]$reportPermalinkContract.jsonPutMethodReference,
    [string]$reportPermalinkContract.jsonArrayPutMethodReference,
    [string]$reportPermalinkContract.stringLengthMethodReference,
    [string]$reportPermalinkContract.controllerQueueMethodReference,
    [string]$reportPermalinkContract.clientQueueMethodReference,
    [string]$reportPermalinkContract.threadStartMethodReference,
    [string]$reportPermalinkContract.jsonArrayConstructorMethodReference,
    [string]$resolution.reporting.symbols.mediaCodeMethod,
    [string]$resolution.reporting.symbols.captionTextMethod,
    [string]$reportPermalinkContract.permalinkResolverMethodReference,
    [string]$reportPermalinkContract.excerptResolverMethodReference,
    [string]$reportPermalinkContract.rowLabelGetterReference,
    [string]$reportPermalinkContract.inlineRowRenderMethodReference,
    [string]$reportPermalinkContract.currentViewerMethodReference,
    [string]$resolution.inlineControls.symbols.ufiButtonMethod,
    [string]$resolution.inlineControls.symbols.visibilityModifierMethod,
    [string]$resolution.inlineControls.symbols.testTagMethod,
    [string]$resolution.inlineControls.symbols.modifierComposedMethod,
    [string]$reportPermalinkContract.ufiButtonDefaultMask))
$dexReportPermalinkFlow = $reportPermalinkLines[-1] | ConvertFrom-Json
if ([string]$dexReportPermalinkFlow.status -ne 'passed' `
        -or [string]$dexReportPermalinkFlow.contract `
            -ne [string]$reportPermalinkContract.id `
        -or [string]$dexReportPermalinkFlow.dex `
            -ne [string]$reportPermalinkContract.expectedDexName `
        -or [int]$dexReportPermalinkFlow.factory.codeCallOffset -lt 0 `
        -or [int]$dexReportPermalinkFlow.factory.permalinkResolverOffset `
            -le [int]$dexReportPermalinkFlow.factory.codeCallOffset `
        -or [int]$dexReportPermalinkFlow.factory.permalinkFallbackGuardOffset `
            -le [int]$dexReportPermalinkFlow.factory.permalinkResolverOffset `
        -or [int]$dexReportPermalinkFlow.factory.permalinkCallOffset `
            -le [int]$dexReportPermalinkFlow.factory.permalinkFallbackGuardOffset `
        -or [int]$dexReportPermalinkFlow.factory.fallbackPermalinkResolverOffset `
            -le [int]$dexReportPermalinkFlow.factory.permalinkCallOffset `
        -or [int]$dexReportPermalinkFlow.factory.captionTextCallOffset `
            -le [int]$dexReportPermalinkFlow.factory.fallbackPermalinkResolverOffset `
        -or [int]$dexReportPermalinkFlow.factory.excerptResolverOffset `
            -le [int]$dexReportPermalinkFlow.factory.captionTextCallOffset `
        -or [int]$dexReportPermalinkFlow.factory.constructorOffset `
            -le [int]$dexReportPermalinkFlow.factory.excerptResolverOffset `
        -or [int]$dexReportPermalinkFlow.request.sanitizerOffset -lt 0 `
        -or [int]$dexReportPermalinkFlow.request.storeOffset `
            -le [int]$dexReportPermalinkFlow.request.sanitizerOffset `
        -or [int]$dexReportPermalinkFlow.request.baseValidityGuardOffset -lt 0 `
        -or [int]$dexReportPermalinkFlow.request.permalinkGuardOffset `
            -le [int]$dexReportPermalinkFlow.request.baseValidityGuardOffset `
        -or [int]$dexReportPermalinkFlow.payload.targetUrlOffset -lt 0 `
        -or [int]$dexReportPermalinkFlow.payload.evidenceValueOffset `
            -le [int]$dexReportPermalinkFlow.payload.targetUrlOffset `
        -or [int]$dexReportPermalinkFlow.payload.evidenceContainerOffset `
            -le [int]$dexReportPermalinkFlow.payload.evidenceValueOffset `
        -or [int]$dexReportPermalinkFlow.queueBoundaries.controllerValidityGuardOffset -lt 0 `
        -or [int]$dexReportPermalinkFlow.queueBoundaries.clientValidityGuardOffset -lt 0 `
        -or $dexReportPermalinkFlow.checks.permalinkFieldFinal -ne $true `
        -or $dexReportPermalinkFlow.checks.singlePermalinkWrite -ne $true `
        -or $dexReportPermalinkFlow.checks.soleInitializedEvidenceEntry -ne $true `
        -or $dexReportPermalinkFlow.checks.controllerBoundary -ne $true `
        -or $dexReportPermalinkFlow.checks.clientBoundary -ne $true `
        -or $dexReportPermalinkFlow.checks.hostPermalinkResolverFlow -ne $true `
        -or $dexReportPermalinkFlow.checks.shortcodeFirstFallbackFlow -ne $true `
        -or $dexReportPermalinkFlow.checks.hostExcerptResolverFlow -ne $true `
        -or $dexReportPermalinkFlow.checks.factoryViewerGuardAbsent -ne $true `
        -or $dexReportPermalinkFlow.checks.rowViewerGuardAbsent -ne $true `
        -or [int]$dexReportPermalinkFlow.rowControl.ufiButtonDefaultMask -ne 63232 `
        -or -not [bool]$dexReportPermalinkFlow.checks.rowDecoratedModifierFlow `
        -or -not [bool]$dexReportPermalinkFlow.checks.rowUfiDefaultMaskExact) {
    throw 'Signed primary-DEX report-permalink value-flow evidence is incomplete.'
}

$jadxClasses = Join-Path $scratchFull 'jadx-gate-classes'
$jadxOutput = Join-Path $scratchFull 'jadx-targets'
[IO.Directory]::CreateDirectory($jadxClasses) | Out-Null
[IO.Directory]::CreateDirectory($jadxOutput) | Out-Null
$null = Invoke-Captured -Command $Javac -Arguments @(
    '-encoding', 'UTF-8', '-cp', $jadxJar, '-d', $jadxClasses, $jadxRecoverySource)
$jadxTargets = @($resolution.release.targetedJadxClasses)
$jadxArguments = @(
    '-cp', ($jadxClasses + [IO.Path]::PathSeparator + $jadxJar),
    'TargetedJadxRecovery', $apkFull, $jadxOutput)
foreach ($target in $jadxTargets) { $jadxArguments += [string]$target.className }
$jadxLines = @(Invoke-Captured -Command $Java -Arguments $jadxArguments)
$jadxSummary = $jadxLines[-1] | ConvertFrom-Json
if ([string]$jadxSummary.status -ne 'passed' `
        -or @($jadxSummary.recoveredClasses).Count -ne $jadxTargets.Count) {
    throw 'Targeted JADX recovery did not return the complete reviewed target set.'
}
$jadxRecovery = @()
for ($index = 0; $index -lt $jadxTargets.Count; $index++) {
    $target = $jadxTargets[$index]
    if ([string]$jadxSummary.recoveredClasses[$index] -ne [string]$target.className) {
        throw "Targeted JADX recovery order drifted at index $index."
    }
    $recoveredPath = Join-Path $jadxOutput ('target-{0:d2}.java' -f ($index + 1))
    if (-not (Test-Path -LiteralPath $recoveredPath -PathType Leaf)) {
        throw "Targeted JADX output is missing for '$($target.className)'."
    }
    $recoveredText = Get-NormalizedPatchletText -Path $recoveredPath
    foreach ($requiredText in @($target.requiredStrings)) {
        if (-not $recoveredText.Contains([string]$requiredText, [StringComparison]::Ordinal)) {
            throw "Targeted JADX recovery for '$($target.className)' is missing '$requiredText'."
        }
    }
    $exactCountProperty = $target.PSObject.Properties['exactStringCounts']
    $exactStringCounts = [ordered]@{}
    if ($null -ne $exactCountProperty) {
        foreach ($countProperty in @($exactCountProperty.Value.PSObject.Properties)) {
            $literal = [string]$countProperty.Name
            $expectedCount = [int]$countProperty.Value
            $actualCount = Get-PatchletLiteralCount -Text $recoveredText -Literal $literal
            if ($actualCount -ne $expectedCount) {
                throw "Targeted JADX recovery for '$($target.className)' has $actualCount occurrences of '$literal'; expected $expectedCount."
            }
            $exactStringCounts[$literal] = $actualCount
        }
    }
    $orderedProperty = $target.PSObject.Properties['orderedStrings']
    $orderedStrings = if ($null -eq $orderedProperty) {
        @()
    } else {
        @($orderedProperty.Value | ForEach-Object { [string]$_ })
    }
    $previousOrderedIndex = -1
    foreach ($orderedText in $orderedStrings) {
        $orderedIndex = $recoveredText.IndexOf(
            $orderedText, $previousOrderedIndex + 1, [StringComparison]::Ordinal)
        if ($orderedIndex -lt 0) {
            throw "Targeted JADX recovery for '$($target.className)' is missing ordered text '$orderedText'."
        }
        $previousOrderedIndex = $orderedIndex
    }
    $forbiddenProperty = $target.PSObject.Properties['forbiddenStrings']
    $forbiddenStrings = if ($null -eq $forbiddenProperty) {
        @()
    } else {
        @($forbiddenProperty.Value | ForEach-Object { [string]$_ })
    }
    foreach ($forbiddenText in $forbiddenStrings) {
        if ($recoveredText.Contains($forbiddenText, [StringComparison]::Ordinal)) {
            throw "Targeted JADX recovery for '$($target.className)' contains forbidden text '$forbiddenText'."
        }
    }
    $jadxRecovery += [pscustomobject]@{
        className = [string]$target.className
        sha256 = Get-PatchletSha256 -Path $recoveredPath
        requiredStrings = @($target.requiredStrings)
        exactStringCounts = $exactStringCounts
        orderedStrings = $orderedStrings
        forbiddenStrings = $forbiddenStrings
    }
}

$proxyJadxContract = $null
if ($null -ne $proxyProperty) {
    $expectedProxyJadxClasses = @(
        'com.instagram.barcelona.app.BarcelonaAppShell',
        'com.threadsmod.ProxySettingsActivity',
        'threadsmod.proxy.ProxyBootstrap',
        'threadsmod.proxy.ProxyConfig',
        'threadsmod.proxy.ProxyBypassPolicy',
        'threadsmod.proxy.ProxyConfigStore',
        'threadsmod.proxy.ProxyController',
        'threadsmod.proxy.ProxyRoutePlanner',
        'threadsmod.proxy.Socks5VpnService'
    )
    $proxyRecovered = @()
    foreach ($className in $expectedProxyJadxClasses) {
        $matches = @($jadxRecovery | Where-Object {
                [string]$_.className -eq $className
            })
        if ($matches.Count -ne 1) {
            throw "Signed proxy JADX contract '$className' must execute exactly once."
        }
        $proxyRecovered += $matches[0]
    }
    $proxyJadxContract = [pscustomobject]@{
        status = 'passed'
        recovered = $proxyRecovered
    }
}

function Get-ResolutionNoArgBooleanJadxToken {
    param(
        [Parameter(Mandatory)][object]$Reference,
        [Parameter(Mandatory)][string]$Label
    )

    $referenceText = [string]$Reference
    $match = [regex]::Match(
        $referenceText,
        '^L[A-Za-z0-9_/$]+;->(?<name>[A-Za-z0-9_$<>]+)\(\)Z$',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        throw "Resolution $Label must be an exact no-argument boolean DEX method reference."
    }
    return $match.Groups['name'].Value + '()'
}

$layoutAttachedJadxToken = Get-ResolutionNoArgBooleanJadxToken `
    -Reference $resolution.inlineControls.symbols.layoutAttachedMethod `
    -Label 'inlineControls.symbols.layoutAttachedMethod'
$rectEmptyJadxToken = Get-ResolutionNoArgBooleanJadxToken `
    -Reference $resolution.inlineControls.symbols.rectEmptyMethod `
    -Label 'inlineControls.symbols.rectEmptyMethod'
$passiveTargetRequirements = [ordered]@{
    'com.threadsmod.CloneBlockerActivity' = @(
        '"Passive block list"',
        '"Refreshes every 10 minutes while Threads is foreground. Only listed profiles whose post or reply action row is actually visible are admitted to blocking."',
        'AutoBlockSync.isRefreshingList()',
        'AutoBlockSync.getListStatus(',
        'postDelayed(',
        'removeCallbacks(',
        'live block-list status refresh stopped')
    'threadsmod.autoblock.BlocklistStore' = @(
        'CREATE TABLE blocklist_targets (',
        'target_id TEXT PRIMARY KEY NOT NULL',
        'CREATE INDEX blocklist_targets_username_idx',
        'CREATE TABLE blocklist_metadata (',
        'new_target_count INTEGER NOT NULL DEFAULT -1',
        'replaceVerified(',
        'countNewTargets(',
        'beginTransaction()',
        'setTransactionSuccessful()',
        'lookupId(',
        'isCurrentIdMatch(',
        'lookupUsernameMetadata(',
        'ALTER TABLE blocklist_metadata ADD COLUMN ',
        'blocklist database upgrade requires reviewed migration',
        'CREATE UNIQUE INDEX blocklist_targets_username_idx',
        'CREATE INDEX blocklist_targets_h32_idx',
        'CREATE TABLE blocklist_chunks (',
        'CREATE TABLE blocklist_groups (',
        'CREATE TABLE blocklist_staging (',
        'stageChunk(',
        'bucket_bits',
        'NOT EXISTS (SELECT 1 FROM blocklist_targets',
        'ALTER TABLE blocklist_targets RENAME TO blocklist_targets_v2',
        'ALTER TABLE blocklist_metadata RENAME TO blocklist_metadata_v2',
        'blocklist database v2 migration requires review')
    'threadsmod.autoblock.ObjectFetcher' = @(
        'CloneBlockerEndpoints.objectUrl(',
        'Accept-Encoding',
        'identity',
        'MessageDigest',
        'SHA-256',
        'signed root names an object whose bytes do not match',
        'object exceeds the local byte cap',
        'chunk byte count differs from the signed group entry')
    'threadsmod.autoblock.ChunkInstaller' = @(
        'BlocklistStore.stageChunk(',
        'BlocklistStore.pruneStaging(',
        'BlocklistStore.stagedShas(',
        'BlocklistStore.readChunkTable(',
        'ObjectFetcher.fetchObject(',
        'GZIPInputStream',
        'JsonReader',
        'chunk row is not a JSON object',
        'chunk row has malformed numeric id',
        'chunk threads id row has malformed username metadata',
        'chunk rows contain a duplicate numeric id',
        'chunk rows have conflicting normalized usernames',
        'chunk row belongs to a different bucket',
        'chunk row count differs from the signed group entry',
        'chunk is not valid gzip NDJSON',
        'group table is not the v3 threads group the root named')
    'threadsmod.autoblock.AutoBlockSync' = @(
        'BlocklistStore.replaceVerified(',
        'BlocklistStore.lookupId(',
        'BlocklistStore.isCurrentIdMatch(',
        'LIST_REFRESH_RUNNING.compareAndSet(false, true)',
        'postDelayed(LIST_REFRESH_WAKE',
        'new ListRefreshWorker(',
        'new FetchWorker(',
        'registerVisibleControl(',
        'updateVisibleControl(',
        'unregisterVisibleControl(',
        'currentPassiveMatch(')
    'threadsmod.autoblock.ModStateStore' = @(
        'BlocklistStore.snapshot(',
        '.targetCount',
        '.fetchedAtMs',
        '.verifiedUpdatedAt')
    'threadsmod.inlinecontrol.InlineActionRowAdapter' = @(
        'new InlineVisibilityCallback(',
        'AutoBlockSync.recordInlineRenderStage(',
        'hook_seen',
        'button_rendered',
        'report_request_unavailable',
        'adapter_exception')
    'threadsmod.inlinecontrol.InlineVisibilityCallback' = @(
        'AutoBlockSync.registerVisibleControl(this,',
        'AutoBlockSync.updateVisibleControl(this,',
        'AutoBlockSync.unregisterVisibleControl(this)',
        $layoutAttachedJadxToken,
        $rectEmptyJadxToken)
}
$passiveTargetForbidden = [ordered]@{
    'threadsmod.autoblock.BlocklistStore' = @(
        'encodeTargets(', 'decodeTargets(', 'ThreadsBlockBridge', 'list_threads_targets',
        'DROP TABLE')
    'threadsmod.autoblock.AutoBlockSync' = @(
        'encodeTargets(', 'decodeTargets(', 'verified.targetIds',
        'hasForegroundRunCapacity(', 'rateAllowed(', 'millisUntilRateAllowed(',
        'automaticPerHour(', 'targetBudget(', 'totalPerHour(', 'totalPerDay(',
        'maxPerRun(', 'manualMinDelayMs(', 'manualMaxDelayMs(',
        'admitForegroundPassiveTarget(', 'removeForegroundPassiveTarget(',
        'targetBudgetAdded')
    'threadsmod.inlinecontrol.InlineActionRowAdapter' = @(
        'AutoBlockSync.getCurrentViewer(')
    'threadsmod.autoblock.ObjectFetcher' = @(
        'safeMessage(', 'getMessage(', 'getLocalizedMessage(',
        'printStackTrace(', 'getStackTraceString(',
        'JsonReader', 'GZIPInputStream', 'ThreadsBlockBridge', 'BlocklistStore')
    'threadsmod.autoblock.ChunkInstaller' = @(
        'safeMessage(', 'getMessage(', 'getLocalizedMessage(',
        'printStackTrace(', 'getStackTraceString(',
        'HttpsURLConnection', 'setLenient', 'ThreadsBlockBridge',
        'PASSIVE_ADMISSION_LOCK', 'replaceVerified(')
    'threadsmod.inlinecontrol.InlineVisibilityCallback' = @(
        'BlocklistStore', 'ThreadsBlockBridge', 'SharedPreferences', 'SQLite')
}
$passiveRecovered = [ordered]@{}
foreach ($passiveClassName in $passiveTargetRequirements.Keys) {
    $matches = @($jadxRecovery | Where-Object {
            [string]$_.className -ceq $passiveClassName
        })
    if ($matches.Count -ne 1) {
        throw "Signed passive JADX contract '$passiveClassName' must execute exactly once."
    }
    $requiredStrings = @($matches[0].requiredStrings | ForEach-Object { [string]$_ })
    foreach ($requiredString in $passiveTargetRequirements[$passiveClassName]) {
        if ($requiredStrings -notcontains $requiredString) {
            throw "Signed passive JADX contract '$passiveClassName' omits '$requiredString'."
        }
    }
    if ($passiveTargetForbidden.Contains($passiveClassName)) {
        $forbiddenStrings = @(
            $matches[0].forbiddenStrings | ForEach-Object { [string]$_ })
        foreach ($forbiddenString in $passiveTargetForbidden[$passiveClassName]) {
            if ($forbiddenStrings -notcontains $forbiddenString) {
                throw "Signed passive JADX contract '$passiveClassName' does not forbid '$forbiddenString'."
            }
        }
    }
    $passiveRecovered[$passiveClassName] = $matches[0]
}
$requiredPassiveDescriptors = [ordered]@{
    'Lthreadsmod/autoblock/BlocklistStore;' = '020-autoblock-runtime'
    'Lthreadsmod/inlinecontrol/InlineVisibilityCallback;' = '060-inline-block-controls'
}
foreach ($passiveDescriptor in $requiredPassiveDescriptors.Keys) {
    if (@($resolution.release.requiredClassDescriptors | Where-Object {
                [string]$_ -ceq $passiveDescriptor
            }).Count -ne 1) {
        throw "Signed passive descriptor is not required exactly once: $passiveDescriptor"
    }
}
$blocklistStoreEvidence = $passiveRecovered['threadsmod.autoblock.BlocklistStore']
$autoBlockEvidence = $passiveRecovered['threadsmod.autoblock.AutoBlockSync']
$inlineAdapterEvidence = $passiveRecovered['threadsmod.inlinecontrol.InlineActionRowAdapter']
if ([int]$blocklistStoreEvidence.exactStringCounts.'CREATE INDEX blocklist_targets_username_idx' -ne 1 `
        -or [int]$blocklistStoreEvidence.exactStringCounts.'CREATE UNIQUE INDEX blocklist_targets_username_idx' -ne 1 `
        -or [int]$blocklistStoreEvidence.exactStringCounts.'stageChunk(' -ne 1 `
        -or [int]$passiveRecovered['threadsmod.autoblock.ChunkInstaller'].exactStringCounts.'BlocklistStore.stageChunk(' -ne 1 `
        -or [int]$passiveRecovered['threadsmod.autoblock.ObjectFetcher'].exactStringCounts.'signed root names an object whose bytes do not match' -ne 1 `
        -or [int]$blocklistStoreEvidence.exactStringCounts.'replaceVerified(' -ne 1 `
        -or [int]$blocklistStoreEvidence.exactStringCounts.'lookupId(' -ne 1 `
        -or [int]$blocklistStoreEvidence.exactStringCounts.'isCurrentIdMatch(' -ne 1 `
        -or [int]$blocklistStoreEvidence.exactStringCounts.'lookupUsernameMetadata(' -ne 1 `
        -or [int]$autoBlockEvidence.exactStringCounts.'BlocklistStore.replaceVerified(' -ne 1 `
        -or [int]$autoBlockEvidence.exactStringCounts.'BlocklistStore.isCurrentIdMatch(' -ne 1 `
        -or [int]$autoBlockEvidence.exactStringCounts.'new BlockRun(' -ne 1 `
        -or [int]$inlineAdapterEvidence.exactStringCounts.'new InlineVisibilityCallback(' -ne 1) {
    throw 'Signed passive JADX evidence does not pin the one-store, one-BlockRun, one-viewport topology.'
}
$settingsPassiveDisclosure =
    'Always on. Refreshes the signed index every 10 minutes in the foreground, then blocks only listed profiles whose post or reply action row becomes visible.'
if (@($resolution.release.requiredHookCalls | Where-Object {
            [string]$_ -ceq $settingsPassiveDisclosure
        }).Count -ne 1) {
    throw 'Signed final-DEX contract omits the exact foreground-only Settings passive disclosure.'
}
$passiveBlockingReleaseGates = [ordered]@{
    'passive-index-contract' = [pscustomobject]@{
        status = 'passed'
        ownerPatchlet = '020-autoblock-runtime'
        descriptors = @('Lthreadsmod/autoblock/BlocklistStore;')
        signedJadx = $blocklistStoreEvidence
        mutationAuthority = 'exact-target-id-primary-key-only'
    }
    'passive-refresh-contract' = [pscustomobject]@{
        status = 'passed'
        ownerPatchlet = '020-autoblock-runtime'
        signedJadx = $autoBlockEvidence
        cadenceMs = 600000
        lifecycle = 'foreground-checked-handler-wake'
        independentWorker = 'ListRefreshWorker'
    }
    'passive-activity-status-contract' = [pscustomobject]@{
        status = 'passed'
        ownerPatchlet = '050-mod-settings-ui'
        activity = $passiveRecovered['com.threadsmod.CloneBlockerActivity']
        snapshot = $passiveRecovered['threadsmod.autoblock.ModStateStore']
        settingsDisclosure = $settingsPassiveDisclosure
    }
    'passive-viewport-observer-contract' = [pscustomobject]@{
        status = 'passed'
        ownerPatchlet = '060-inline-block-controls'
        descriptor = 'Lthreadsmod/inlinecontrol/InlineVisibilityCallback;'
        adapter = $inlineAdapterEvidence
        callback = $passiveRecovered['threadsmod.inlinecontrol.InlineVisibilityCallback']
        authority = 'memory-only-visibility-transitions'
    }
    'passive-visible-scheduler-contract' = [pscustomobject]@{
        status = 'passed'
        ownerPatchlet = '020-autoblock-runtime'
        signedJadx = $autoBlockEvidence
        finalGuard = 'generation-membership-and-current-visibility-before-reservation'
        scheduler = 'shared-single-flight-BlockRun'
    }
}

$expectedUpdateJadxClasses = @(
    'threadsmod.update.UpdateController',
    'threadsmod.update.UpdateEndpoints',
    'threadsmod.update.UpdateJson',
    'threadsmod.update.UpdateManifest',
    'threadsmod.update.UpdateSignature',
    'threadsmod.update.UpdateStore'
)
$updateRecovered = @()
foreach ($updateClassName in $expectedUpdateJadxClasses) {
    $matches = @($jadxRecovery | Where-Object {
            [string]$_.className -ceq $updateClassName
        })
    if ($matches.Count -ne 1) {
        throw "Signed updater JADX contract '$updateClassName' must execute exactly once."
    }
    $updateRecovered += $matches[0]
}
$requiredUpdateDescriptors = @(
    'Lthreadsmod/update/UpdateController;',
    'Lthreadsmod/update/UpdateEndpoints;',
    'Lthreadsmod/update/UpdateJson;',
    'Lthreadsmod/update/UpdateManifest;',
    'Lthreadsmod/update/UpdateSignature;',
    'Lthreadsmod/update/UpdateStore;'
)
foreach ($updateDescriptor in $requiredUpdateDescriptors) {
    if (@($resolution.release.requiredClassDescriptors | Where-Object {
                [string]$_ -ceq $updateDescriptor
            }).Count -ne 1) {
        throw "Signed updater descriptor is not required exactly once: $updateDescriptor"
    }
}
foreach ($updateFinalDexMarker in @(
        'threadsmod-app-update',
        'Required update',
        'application/vnd.android.package-archive')) {
    if (@($resolution.release.requiredHookCalls | Where-Object {
                [string]$_ -ceq $updateFinalDexMarker
            }).Count -ne 1) {
        throw "Updater final-DEX marker is not required exactly once: $updateFinalDexMarker"
    }
}
if (@($resolution.release.requiredHookCalls | Where-Object {
            [string]$_ -ceq [string]$resolution.update.requestInstallPermission
        }).Count -ne 0) {
    throw 'Manifest-only updater permission must not be required as a final-DEX marker.'
}
$updateJadxContract = [pscustomobject]@{
    status = 'passed'
    recovered = $updateRecovered
}

$badging = @(Invoke-Captured -Command $aapt2 -Arguments @('dump', 'badging', $apkFull))
$packageLine = [string]($badging | Where-Object { $_ -like 'package:*' } | Select-Object -First 1)
$minLine = [string]($badging | Where-Object { $_ -like 'minSdkVersion:*' } | Select-Object -First 1)
$targetLine = [string]($badging | Where-Object { $_ -like 'targetSdkVersion:*' } | Select-Object -First 1)
if ($packageLine -notmatch "name='$([regex]::Escape([string]$resolution.target.applicationId))'") { throw 'Final application ID is incorrect.' }
if ($packageLine -notmatch "versionCode='$($resolution.target.versionCode)'") { throw 'Final versionCode is incorrect.' }
if ($packageLine -notmatch "versionName='$([regex]::Escape([string]$resolution.target.versionName))'") { throw 'Final versionName is incorrect.' }
if ($minLine -ne "minSdkVersion:'$($resolution.source.minSdk)'") { throw 'Final minSdk is incorrect.' }
if ($targetLine -ne "targetSdkVersion:'$($resolution.source.targetSdk)'") { throw 'Final targetSdk is incorrect.' }
$launcherLine = [string]($badging | Where-Object { $_ -like 'launchable-activity:*' } | Select-Object -First 1)
if ($launcherLine -notmatch "name='$([regex]::Escape([string]$resolution.release.requiredLauncherActivity))'") { throw 'Resolved launcher activity is incorrect.' }

$manifestTree = @(Invoke-Captured -Command $aapt2 -Arguments @('dump', 'xmltree', $apkFull, '--file', 'AndroidManifest.xml'))
$manifestText = $manifestTree -join "`n"
$null = Assert-PatchletManifestPermission -ManifestText $manifestText `
    -Permission ([string]$resolution.update.requestInstallPermission) `
    -Format 'aapt2-xmltree' `
    -FailureMessage 'Final manifest must request REQUEST_INSTALL_PACKAGES exactly once.'
$updateProviderAuthorityNeedle = '="{0}"' -f [string]$resolution.update.fileProviderAuthority
if ((Get-PatchletLiteralCount -Text $manifestText `
            -Literal $updateProviderAuthorityNeedle) -ne 1) {
    throw 'Final manifest must retain exactly one resolution-owned clone FileProvider authority.'
}
$updateProviderBlock = Get-AaptXmlElementBlock `
    -Lines $manifestTree -ElementName 'provider' `
    -AndroidName 'androidx.core.content.FileProvider'
if ($updateProviderBlock.text -notmatch 'android:exported[^\n]*=false' `
        -or $updateProviderBlock.text -notmatch 'android:grantUriPermissions[^\n]*=true' `
        -or (Get-PatchletLiteralCount -Text $updateProviderBlock.text `
            -Literal $updateProviderAuthorityNeedle) -ne 1) {
    throw 'Final clone FileProvider must be non-exported, grant URI permissions, and own the exact updater authority.'
}
$updatePathsTree = @(Invoke-Captured -Command $aapt2 -Arguments @(
        'dump', 'xmltree', $apkFull, '--file', 'res/xml/barcelona_file_provider_paths.xml'))
$updatePathsText = $updatePathsTree -join "`n"
if ([regex]::Matches(
        $updatePathsText, '(?m)^\s*E:\s+cache-path(?:\s|\(|$)').Count -ne 1 `
        -or (Get-PatchletLiteralCount -Text $updatePathsText -Literal '="shared"') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $updatePathsText -Literal '="shared/"') -ne 1) {
    throw 'Final FileProvider paths resource must expose exactly cache/shared through the reviewed shared path.'
}
$updateManifestContract = [pscustomobject]@{
    status = 'passed'
    requestInstallPermission = [string]$resolution.update.requestInstallPermission
    requestInstallPermissionAuthority = 'manifest-only'
    requiredAsDexMarker = $false
    fileProviderAuthority = [string]$resolution.update.fileProviderAuthority
    fileProviderExported = $false
    grantUriPermissions = $true
    fileProviderCacheRoot = 'shared/'
    updaterCachePath = [string]$resolution.update.fileProviderCachePath
}
$injectedActivities = @()
foreach ($component in @($resolution.release.requiredInjectedActivities)) {
    $needle = '="{0}"' -f [string]$component
    $matchingIndexes = @()
    for ($index = 0; $index -lt $manifestTree.Count; $index++) {
        if ([string]$manifestTree[$index] -like '*android:name*' -and [string]$manifestTree[$index] -like "*$needle*") {
            $matchingIndexes += $index
        }
    }
    if ($matchingIndexes.Count -ne 1) {
        throw "Injected Activity '$component' must occur exactly once; observed $($matchingIndexes.Count)."
    }
    $activityIndex = $matchingIndexes[0]
    $windowStart = [Math]::Max(0, $activityIndex - 5)
    $windowEnd = [Math]::Min($manifestTree.Count - 1, $activityIndex + 8)
    $window = @($manifestTree[$windowStart..$windowEnd]) -join "`n"
    if ($window -notmatch 'android:exported[^\n]*=false') {
        throw "Injected Activity '$component' is not explicitly exported=false."
    }
    $injectedActivities += [string]$component
}
$proxyManifestContract = $null
if ($null -ne $proxyProperty) {
    $proxy = $proxyProperty.Value
    $settingsBlock = Get-AaptXmlElementBlock `
        -Lines $manifestTree -ElementName 'activity' `
        -AndroidName ([string]$proxy.settingsActivity.name)
    if ($settingsBlock.text -notmatch 'android:exported[^\n]*=false' `
            -or $settingsBlock.text -match '(?m)^\s*E:\s+intent-filter(?:\s|\(|$)') {
        throw 'Proxy Settings Activity must be private and have no intent filter.'
    }

    $serviceBlock = Get-AaptXmlElementBlock `
        -Lines $manifestTree -ElementName 'service' `
        -AndroidName ([string]$proxy.vpnService.name)
    $intentFilterCount = [regex]::Matches(
        $serviceBlock.text, '(?m)^\s*E:\s+intent-filter(?:\s|\(|$)').Count
    $actionElementCount = [regex]::Matches(
        $serviceBlock.text, '(?m)^\s*E:\s+action(?:\s|\(|$)').Count
    if ($serviceBlock.text -notmatch 'android:exported[^\n]*=false' `
            -or $serviceBlock.text -notmatch (
                'android:permission[^\n]*="' `
                + [regex]::Escape([string]$proxy.vpnService.permission) + '"') `
            -or $serviceBlock.text -notmatch 'android:foregroundServiceType[^\n]*=0x40000000' `
            -or $intentFilterCount -ne 1 `
            -or $actionElementCount -ne 1 `
            -or (Get-PatchletLiteralCount -Text $serviceBlock.text `
                -Literal ('="{0}"' -f [string]$proxy.vpnService.action)) -ne 1 `
            -or $serviceBlock.text -match '(?m)^\s*E:\s+(?:category|data)(?:\s|\(|$)' `
            -or $serviceBlock.text -match 'android:process') {
        throw 'VPN service privacy, BIND_VPN_SERVICE, default-process, action, or specialUse contract differs from the resolution.'
    }
    if ((Get-PatchletLiteralCount -Text $manifestText `
                -Literal ('="{0}"' -f [string]$proxy.vpnService.foregroundServicePermission)) -ne 1 `
            -or (Get-PatchletLiteralCount -Text $serviceBlock.text `
                -Literal '="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"') -ne 1 `
            -or (Get-PatchletLiteralCount -Text $serviceBlock.text `
                -Literal ('="{0}"' -f [string]$proxy.vpnService.specialUseSubtype)) -ne 1 `
            -or (Get-PatchletLiteralCount -Text $manifestText `
                -Literal '="com.instagram.barcelona.app.BarcelonaAppShell"') -ne 1) {
        throw 'VPN special-use permission/property or exact Application declaration is missing.'
    }
    $proxyManifestContract = [pscustomobject]@{
        status = 'passed'
        settingsActivity = [pscustomobject]@{
            name = [string]$proxy.settingsActivity.name
            exported = $false
            intentFilters = 0
        }
        vpnService = [pscustomobject]@{
            name = [string]$proxy.vpnService.name
            exported = $false
            permission = [string]$proxy.vpnService.permission
            action = [string]$proxy.vpnService.action
            foregroundServiceType = [string]$proxy.vpnService.foregroundServiceType
            foregroundServicePermission = [string]$proxy.vpnService.foregroundServicePermission
            specialUseSubtype = [string]$proxy.vpnService.specialUseSubtype
            process = 'default'
        }
        application = 'com.instagram.barcelona.app.BarcelonaAppShell'
    }
}
$authorityText = @($manifestTree | Where-Object { $_ -like '*android:authorities*' }) -join "`n"
foreach ($authorityRequirement in @($resolution.release.requiredProviderAuthorities)) {
    $authority = [string]$authorityRequirement.authority
    $expectedAuthorityCount = [int]$authorityRequirement.expectedCount
    $needle = '="{0}"' -f $authority
    $matches = [regex]::Matches($authorityText, [regex]::Escape($needle)).Count
    if ($matches -ne $expectedAuthorityCount) {
        throw "Provider authority '$authority' must occur exactly $expectedAuthorityCount time(s); observed $matches."
    }
    $officialAuthority = $authority.Replace([string]$resolution.target.applicationId, [string]$resolution.source.applicationId)
    if ($authorityText.Contains(('="{0}"' -f $officialAuthority))) { throw "Official app-owned provider authority remains: $officialAuthority" }
}
foreach ($affinity in @($resolution.release.requiredTaskAffinities)) {
    if (-not $manifestText.Contains(('="{0}"' -f [string]$affinity))) { throw "Required clone task affinity is missing: $affinity" }
}
foreach ($permission in @($resolution.release.requiredCustomPermissions)) {
    if (-not $manifestText.Contains(('="{0}"' -f [string]$permission))) { throw "Required clone permission is missing: $permission" }
}
$authenticatorTree = @(Invoke-Captured -Command $aapt2 -Arguments @('dump', 'xmltree', $apkFull, '--file', 'res/xml/authenticator.xml'))
$authenticatorText = $authenticatorTree -join "`n"
if (-not $authenticatorText.Contains(('="{0}"' -f [string]$resolution.release.requiredAuthenticatorAccountType))) {
    throw 'Authenticator account type is not clone-owned.'
}

$null = Invoke-Captured -Command $zipalign -Arguments @('-c', '-P', '16', '4', $apkFull)
$archiveLines = @(Invoke-Captured -Command $SevenZip -Arguments @('t', $apkFull))
if (-not ($archiveLines -contains 'Everything is Ok')) { throw '7-Zip archive test did not report success.' }

$signature = @(Invoke-Captured -Command $Java -Arguments @('-jar', $apksignerJar, 'verify', '-Werr', '--verbose', '--print-certs', $apkFull))
$apksignerHash = Get-PatchletSha256 -Path $apksignerJar
if ($apksignerHash -ne [string]$resolution.toolchain.apksignerJarSha256) { throw 'Apksigner tool hash does not match the resolution.' }
if (-not ($signature -contains 'Verified using v2 scheme (APK Signature Scheme v2): true')) { throw 'APK is not v2 signed.' }
foreach ($unexpected in @('Verified using v1 scheme (JAR signing): true', 'Verified using v3 scheme (APK Signature Scheme v3): true', 'Verified using v3.1 scheme (APK Signature Scheme v3.1): true', 'Verified using v4 scheme (APK Signature Scheme v4): true')) {
    if ($signature -contains $unexpected) { throw "Unexpected signing scheme: $unexpected" }
}
if (-not ($signature -contains 'Number of signers: 1')) { throw 'APK must have exactly one signer.' }
$certificateLine = [string]($signature | Where-Object { $_ -like 'Signer #1 certificate SHA-256 digest:*' } | Select-Object -First 1)
$certificate = ($certificateLine -split ': ', 2)[1].ToLowerInvariant()
$expectedCertificate = ([string]$resolution.release.requiredSignerCertificateSha256).ToLowerInvariant()
if ($certificate -ne $expectedCertificate) { throw "Signer continuity failed. Expected '$expectedCertificate', observed '$certificate'." }
$expectedUpdateCertificate = ([string]$resolution.update.requiredSignerCertificateSha256).ToLowerInvariant()
if ($certificate -ne $expectedUpdateCertificate) {
    throw "Updater signer pin differs from the signed candidate certificate. Expected '$expectedUpdateCertificate', observed '$certificate'."
}
if ($resolution.release.updateSignedDexReviewRequired `
        -ne $expectedUpdateSignedDexReviewRequired) {
    throw 'Updater raw primary-DEX blocker changed after signed-APK validation state binding.'
}
if ($null -eq $dexUpdateFlow -or $null -eq $dexUpdateFlowFixtureEvidence) {
    throw 'Executable signed-APK updater release evidence is incomplete.'
}
$updateReleaseGates = [ordered]@{
    'update-host-fixtures' = [pscustomobject]@{
        status = 'required-prerequisite'
        proofOwner = 'Test-HostPatchletAssets.ps1'
    }
    'update-endpoint-policy' = [pscustomobject]@{
        status = 'passed'
        authoritative = $true
        signedDex = $dexUpdateFlow
        metadataEndpoints = @($resolution.update.metadataEndpoints)
        signedJadx = @($updateRecovered | Where-Object {
                [string]$_.className -ceq 'threadsmod.update.UpdateEndpoints'
            })[0]
    }
    'update-manifest-contract' = [pscustomobject]@{
        status = 'passed'
        authoritative = $true
        signedDex = $dexUpdateFlow
        signedJadx = @($updateRecovered | Where-Object {
                [string]$_.className -ceq 'threadsmod.update.UpdateManifest'
            })[0]
    }
    'update-dialog-contract' = [pscustomobject]@{
        status = 'passed'
        authoritative = $true
        signedDex = $dexUpdateFlow
        signedJadx = @($updateRecovered | Where-Object {
                [string]$_.className -ceq 'threadsmod.update.UpdateController'
            })[0]
    }
    'update-installer-contract' = [pscustomobject]@{
        status = 'passed'
        authoritative = $true
        signedDex = $dexUpdateFlow
        manifest = $updateManifestContract
        signerCertificateSha256 = $certificate
        runtimeInstallTested = $false
    }
    'update-signed-dex-contract' = [pscustomobject]@{
        status = 'passed'
        authoritative = $true
        generatedD8Fixtures = $dexUpdateFlowFixtureEvidence
        signedApk = $dexUpdateFlow
    }
    'update-manifest-rewrite-contract' = [pscustomobject]@{
        status = 'passed'
        authoritative = $true
        signedDex = $dexUpdateFlow
        targetModBuild = [long]$resolution.target.modBuild
        targetVersionCode = [long]$resolution.target.versionCode
        targetVersionName = [string]$resolution.target.versionName
        manifest = $updateManifestContract
    }
}

$nativeLibraries = $null
$assetPreservation = $null
$proxyNativeJniContract = $null
$proxyLicenseContract = $null
if ($sourceApkFull) {
    $sourceHashes = Get-ZipEntryHashes -Path $sourceApkFull -Prefix 'lib/'
    $outputHashes = Get-ZipEntryHashes -Path $apkFull -Prefix 'lib/'
    if ($null -eq $proxyProperty) {
        if (($sourceHashes | ConvertTo-Json -Compress) -ne ($outputHashes | ConvertTo-Json -Compress)) {
            throw 'Native-library inventory or content changed during patching.'
        }
        $nativeLibraries = [pscustomobject]@{ status = 'preserved'; count = $sourceHashes.Count }
    } else {
        $native = $proxyProperty.Value.nativeLibrary
        $reviewedApkPath = ([string]$native.apkPath).Replace('\', '/')
        $reviewedDecodedPath = ([string]$native.decodedPath).Replace('\', '/')
        $reviewedAbi = [string]$native.abi
        $reviewedSha256 = ([string]$native.sha256).ToLowerInvariant()
        $reviewedPrefix = "lib/$reviewedAbi/"
        if ($reviewedDecodedPath -ne $reviewedApkPath `
                -or -not $reviewedApkPath.StartsWith($reviewedPrefix, [StringComparison]::Ordinal) `
                -or -not $reviewedApkPath.EndsWith('.so', [StringComparison]::Ordinal) `
                -or @($resolution.source.abis | Where-Object {
                        [string]$_ -eq $reviewedAbi
                    }).Count -ne 1) {
            throw 'Resolution proxy native paths or ABI do not match the exact source ABI contract.'
        }
        if ($sourceHashes.Contains($reviewedApkPath)) {
            throw 'Resolution proxy native library is not an addition; its APK path already exists in the source.'
        }
        foreach ($sourceName in @($sourceHashes.Keys)) {
            if (-not $outputHashes.Contains($sourceName) `
                    -or [string]$outputHashes[$sourceName] -ne [string]$sourceHashes[$sourceName]) {
                throw "Source native library was removed or changed during proxy patching: $sourceName"
            }
        }
        $addedNames = @($outputHashes.Keys | Where-Object {
                -not $sourceHashes.Contains([string]$_)
            })
        if ($addedNames.Count -ne 1 -or [string]$addedNames[0] -ne $reviewedApkPath) {
            throw "Candidate native additions differ from the sole reviewed proxy library '$reviewedApkPath'."
        }
        if ([string]$outputHashes[$reviewedApkPath] -ne $reviewedSha256) {
            throw 'Candidate proxy native library hash differs from the exact resolution.'
        }
        $proxyAssetPath = Resolve-PatchletChildPath `
            -Root (Join-Path (Get-PatchletRepositoryRoot) 'patchlets') `
            -Child ([string]$native.assetPath)
        if (-not (Test-Path -LiteralPath $proxyAssetPath -PathType Leaf) `
                -or (Get-PatchletSha256 -Path $proxyAssetPath) -ne $reviewedSha256) {
            throw 'Canonical proxy native asset is missing or differs from the exact resolution.'
        }
        $proxyNativeBytes = Get-ZipEntryBytes -Path $apkFull -EntryName $reviewedApkPath
        $proxyElf = Test-ReviewedAarch64Elf `
            -Bytes $proxyNativeBytes `
            -ExpectedMachine ([int]$native.elfMachine) `
            -MinimumLoadAlignment ([uint64]$native.minimumLoadAlignment)
        $proxyNativeJniContract = Test-NativeAsciiLiterals `
            -Bytes $proxyNativeBytes `
            -Required @(
                'threadsmod/proxy/Socks5VpnService',
                'TProxyStartService',
                '(Ljava/lang/String;I)Z',
                'TProxyStopService',
                'TProxyIsRunning',
                'TProxyGetStats',
                '()[J',
                'hev_socks5_tunnel_main_from_str') `
            -Forbidden @('hev/htproxy', 'TProxyService')
        $nativeLibraries = [pscustomobject]@{
            status = 'preserved-with-reviewed-addition'
            sourceCount = $sourceHashes.Count
            outputCount = $outputHashes.Count
            addedCount = 1
            addition = [pscustomobject]@{
                path = $reviewedApkPath
                abi = $reviewedAbi
                sha256 = $reviewedSha256
                ownerPatchlet = '080-socks5-proxy'
                elf = $proxyElf
                jni = $proxyNativeJniContract
            }
        }
    }

    $assetExclusions = @($resolution.release.assetPreservationExclusions | ForEach-Object {
            [string]$_.path
        })
    $outputAssetExclusions = @($assetExclusions)
    $sourceAllAssets = Get-ZipEntryHashes -Path $sourceApkFull -Prefix 'assets/'
    $outputAllAssets = Get-ZipEntryHashes -Path $apkFull -Prefix 'assets/'
    foreach ($exclusion in @($resolution.release.assetPreservationExclusions)) {
        $excludedPath = [string]$exclusion.path
        if (-not $sourceAllAssets.Contains($excludedPath) `
                -or -not $outputAllAssets.Contains($excludedPath)) {
            throw "Reviewed asset exclusion is absent from source or output: $excludedPath"
        }
        if (@($dex.allDexNames) -notcontains $excludedPath) {
            throw "Reviewed asset exclusion did not pass its replacement DEX gate: $excludedPath"
        }
    }
    if ($null -ne $proxyProperty) {
        $license = $proxyProperty.Value.licenseAsset
        $licenseApkPath = ([string]$license.apkPath).Replace('\', '/')
        $licenseDecodedPath = ([string]$license.decodedPath).Replace('\', '/')
        $licenseSha256 = ([string]$license.sha256).ToLowerInvariant()
        if ($licenseApkPath -ne 'assets/threadsmod/licenses/hev-socks5-tunnel-and-lwip.txt' `
                -or $licenseApkPath -ne $licenseDecodedPath `
                -or -not $licenseApkPath.StartsWith(
                    'assets/threadsmod/licenses/', [StringComparison]::Ordinal) `
                -or $sourceAllAssets.Contains($licenseApkPath) `
                -or -not $outputAllAssets.Contains($licenseApkPath) `
                -or [string]$outputAllAssets[$licenseApkPath] -ne $licenseSha256) {
            throw 'Signed APK proxy license addition differs from the exact resolution.'
        }
        $licenseAssetPath = Resolve-PatchletChildPath `
            -Root (Join-Path (Get-PatchletRepositoryRoot) 'patchlets') `
            -Child ([string]$license.assetPath)
        if (-not (Test-Path -LiteralPath $licenseAssetPath -PathType Leaf) `
                -or (Get-PatchletSha256 -Path $licenseAssetPath) -ne $licenseSha256) {
            throw 'Canonical combined HEV/lwIP license notice is missing or unpinned.'
        }
        $licenseText = Get-NormalizedPatchletText -Path $licenseAssetPath
        if (-not $licenseText.Contains('Copyright (c) 2022 hev', [StringComparison]::Ordinal) `
                -or -not $licenseText.Contains(
                    'Copyright (c) 2001, 2002 Swedish Institute of Computer Science.',
                    [StringComparison]::Ordinal)) {
            throw 'Canonical proxy license notice does not contain both reviewed notices.'
        }
        $outputAssetExclusions += $licenseApkPath
        $proxyLicenseContract = [pscustomobject]@{
            status = 'passed'
            path = $licenseApkPath
            sha256 = $licenseSha256
            ownerPatchlet = '080-socks5-proxy'
            notices = @('hev-mit', 'lwip-sics-bsd-3-clause')
        }
    }
    $sourcePreservedAssets = Get-ZipEntryHashes `
        -Path $sourceApkFull -Prefix 'assets/' -ExcludedNames $assetExclusions
    $outputPreservedAssets = Get-ZipEntryHashes `
        -Path $apkFull -Prefix 'assets/' -ExcludedNames $outputAssetExclusions
    if (($sourcePreservedAssets | ConvertTo-Json -Compress) `
            -ne ($outputPreservedAssets | ConvertTo-Json -Compress)) {
        throw 'Reviewed assets inventory or content changed outside the exact exclusion set.'
    }
    $assetPreservation = [pscustomobject]@{
        status = 'preserved-with-reviewed-exclusions'
        comparedCount = $sourcePreservedAssets.Count
        excluded = @($resolution.release.assetPreservationExclusions)
        reviewedAddition = $proxyLicenseContract
    }
}

$proxyReleaseGates = $null
if ($null -ne $proxyProperty) {
    if ($null -eq $proxyManifestContract `
            -or $null -eq $proxyJadxContract `
            -or $null -eq $dexProxyBootstrapFlow `
            -or $null -eq $dexProxyBootstrapFlowFixtureEvidence `
            -or $null -eq $proxyNativeJniContract `
            -or $null -eq $proxyLicenseContract) {
        throw 'Executable signed-APK proxy release evidence is incomplete.'
    }
    $requiredProxyDescriptors = @(
        'Lcom/threadsmod/ProxySettingsActivity;',
        'Lthreadsmod/proxy/ProxyBootstrap;',
        'Lthreadsmod/proxy/ProxyBypassPolicy;',
        'Lthreadsmod/proxy/ProxyConfig;',
        'Lthreadsmod/proxy/ProxyConfigStore;',
        'Lthreadsmod/proxy/ProxyController;',
        'Lthreadsmod/proxy/ProxyRoutePlanner;',
        'Lthreadsmod/proxy/Socks5VpnService;'
    )
    foreach ($descriptor in $requiredProxyDescriptors) {
        if (@($resolution.release.requiredClassDescriptors | Where-Object {
                    [string]$_ -eq $descriptor
                }).Count -ne 1) {
            throw "Signed-DEX proxy descriptor is not required exactly once: $descriptor"
        }
    }
    $requiredProxyForbiddenDexStrings = @(
        'allowBypass',
        'socksProxyHost',
        'java.net.useSystemProxies',
        'threadsmod_proxy_username',
        'threadsmod_proxy_password',
        'tree55.com'
    )
    foreach ($literal in $requiredProxyForbiddenDexStrings) {
        if (@($resolution.release.forbiddenDexStrings | Where-Object {
                    [string]$_ -eq $literal
                }).Count -ne 1) {
            throw "Proxy direct-fallback or plaintext-key literal is not forbidden exactly once: $literal"
        }
    }
    $targetedProxyFallbackLiterals = @(
        'allowBypass(',
        'System.setProperty(',
        'ProxySelector.setDefault(',
        'socksProxyHost',
        'socksProxyPort',
        'java.net.useSystemProxies'
    )
    foreach ($proxyRecovery in @($proxyJadxContract.recovered)) {
        foreach ($targetedProxyFallbackLiteral in $targetedProxyFallbackLiterals) {
            if (@($proxyRecovery.forbiddenStrings | Where-Object {
                        [string]$_ -ceq $targetedProxyFallbackLiteral
                    }).Count -ne 1) {
                throw "Signed proxy JADX class '$($proxyRecovery.className)' did not execute the exact fallback-string absence gate for '$targetedProxyFallbackLiteral'."
            }
        }
    }
    $ambiguousSocksPortSubstring = 'socksProxyPort'
    $pristineSocksPortCollisionFixture = 'getSocksProxyPort'
    $socksPortCollisionProof = @($resolution.proofs | Where-Object {
            [string]$_.id -eq 'proxy-pristine-socks-port-substring-collision'
        })
    $expectedSocksPortCollisionPath = if (
            [string]$resolution.source.versionName -ceq '415.0.0.26.77') {
        'smali_classes11/com/facebook/proxyservice/observer/ProxyServiceBroadcaster.smali'
    } elseif ([string]$resolution.source.versionName -ceq '444.0.0.45.85') {
        'smali_classes12/com/facebook/proxyservice/observer/ProxyServiceBroadcaster.smali'
    } else {
        throw 'No exact pristine SOCKS port collision path is reviewed for this source version.'
    }
    if ($pristineSocksPortCollisionFixture.IndexOf(
            $ambiguousSocksPortSubstring, [StringComparison]::OrdinalIgnoreCase) -lt 0 `
            -or @($resolution.release.forbiddenDexStrings | Where-Object {
                    [string]$_ -ieq $ambiguousSocksPortSubstring
                }).Count -ne 0 `
            -or $socksPortCollisionProof.Count -ne 1 `
            -or [string]$socksPortCollisionProof[0].path `
                -cne $expectedSocksPortCollisionPath `
            -or [string]$socksPortCollisionProof[0].contains `
                -ne '.method public final declared-synchronized getSocksProxyPort()I' `
            -or [int]$socksPortCollisionProof[0].minimumCount -ne 1) {
        throw 'The pristine getSocksProxyPort collision exception is absent, broad, or not exact-SHA resolution-bound.'
    }

    $proxyReleaseGates = [ordered]@{
        'socks5-config-contract' = [pscustomobject]@{
            status = 'passed'
            signedJadxClasses = @(
                'threadsmod.proxy.ProxyConfig',
                'threadsmod.proxy.ProxyBypassPolicy',
                'com.threadsmod.ProxySettingsActivity')
        }
        'socks5-vpn-manifest-contract' = $proxyManifestContract
        'socks5-bootstrap-contract' = [pscustomobject]@{
            status = 'passed'
            application = 'com.instagram.barcelona.app.BarcelonaAppShell'
            signedJadxClass = 'com.instagram.barcelona.app.BarcelonaAppShell'
            exactCall = 'ProxyBootstrap.install('
            evidenceRole = 'secondary-readable'
        }
        'socks5-bootstrap-signed-dex-flow-contract' = [pscustomobject]@{
            status = 'passed'
            authoritative = $true
            result = $dexProxyBootstrapFlow
            fixtures = $dexProxyBootstrapFlowFixtureEvidence
        }
        'socks5-route-contract' = [pscustomobject]@{
            status = 'passed'
            signedJadxClasses = @(
                'threadsmod.proxy.ProxyRoutePlanner',
                'threadsmod.proxy.Socks5VpnService')
            directFallbackForbidden = @(
                'allowBypass', 'socksProxyHost', 'socksProxyPort',
                'java.net.useSystemProxies')
        }
        'socks5-credential-contract' = [pscustomobject]@{
            status = 'passed'
            signedJadxClass = 'threadsmod.proxy.ProxyConfigStore'
            storage = @('AndroidKeyStore', 'AES/GCM/NoPadding')
            plaintextPreferenceKeysForbidden = @(
                'threadsmod_proxy_username', 'threadsmod_proxy_password')
        }
        'socks5-native-contract' = [pscustomobject]@{
            status = 'passed'
            library = $nativeLibraries.addition
        }
        'socks5-license-contract' = $proxyLicenseContract
        'socks5-static-dex-contract' = [pscustomobject]@{
            status = 'passed'
            requiredClassDescriptors = $requiredProxyDescriptors
            forbiddenStrings = $requiredProxyForbiddenDexStrings
            targetedJadx = $proxyJadxContract
        }
        'socks5-pristine-port-substring-collision' = [pscustomobject]@{
            status = 'passed'
            scannerSemantics = 'case-insensitive-substring'
            ambiguousSubstring = $ambiguousSocksPortSubstring
            pristineSourceMethod = $pristineSocksPortCollisionFixture
            proof = $socksPortCollisionProof[0]
            broadForbiddenStringExcluded = $true
            targetedExactFallbackStrings = $targetedProxyFallbackLiterals
            targetedJadxClasses = @($proxyJadxContract.recovered | ForEach-Object {
                    [string]$_.className
                })
        }
        'proxy-settings-activity-contract' = [pscustomobject]@{
            status = 'passed'
            manifest = $proxyManifestContract.settingsActivity
            signedJadxClass = 'com.threadsmod.ProxySettingsActivity'
            credentialViewHardening = @(
                'usernameInput.setSaveEnabled(false)',
                'usernameInput.setImportantForAutofill(',
                'passwordInput.setSaveEnabled(false)',
                'passwordInput.setImportantForAutofill(',
                'protected void onPause()',
                'sensitiveFieldsCleared = true',
                'restoreSensitiveFieldsIfNeeded()')
            emulatorProbe = 'required-separately-exact-primary-dex-no-permission'
        }
    }
}

$outputSha256 = Get-PatchletSha256 -Path $apkFull
$sourceSha256 = $boundSourceSha256
$resolutionSha256 = Get-PatchletSha256 -Path $resolutionPathFull
$report = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToString('o')
    status = 'passed'
    artifactProduced = $true
    validationMode = $ValidationMode
    reviewOnly = $ValidationMode -ceq 'SignedReview'
    releaseEligible = $ValidationMode -ceq 'Release'
    apk = $apkFull
    sha256 = $outputSha256
    size = (Get-Item -LiteralPath $apkFull).Length
    bindings = [pscustomobject]@{
        sourceApkSha256 = $sourceSha256
        resolutionFileSha256 = $resolutionSha256
        outputApkSha256 = $outputSha256
    }
    source = if ($sourceApkFull) {
        [pscustomobject]@{ path = $sourceApkFull; sha256 = $sourceSha256 }
    } else { $null }
    resolution = [pscustomobject]@{
        id = [string]$resolution.resolutionId
        path = $resolutionPathFull
        sha256 = $resolutionSha256
    }
    applicationId = [string]$resolution.target.applicationId
    versionName = [string]$resolution.target.versionName
    versionCode = [long]$resolution.target.versionCode
    inAppUpdate = [pscustomobject]@{
        currentModBuild = [long]$resolution.update.currentModBuild
        targetModBuild = [long]$resolution.target.modBuild
        metadataPurpose = [string]$resolution.update.metadataPurpose
        metadataEndpoints = @($resolution.update.metadataEndpoints)
        requestInstallPermission = [string]$resolution.update.requestInstallPermission
        fileProviderAuthority = [string]$resolution.update.fileProviderAuthority
        fileProviderCachePath = [string]$resolution.update.fileProviderCachePath
        signerCertificateSha256 = [string]$resolution.update.requiredSignerCertificateSha256
        metadataDeployed = $false
        runtimeInstallTested = $false
    }
    minSdk = [int]$resolution.source.minSdk
    targetSdk = [int]$resolution.source.targetSdk
    injectedActivities = $injectedActivities
    dex = $dex
    dexDirectStringCalls = $dexDirectStringCalls
    dexProxyBootstrapFlowFixtures = $dexProxyBootstrapFlowFixtureEvidence
    dexProxyBootstrapFlow = $dexProxyBootstrapFlow
    dexUpdateFlowFixtures = $dexUpdateFlowFixtureEvidence
    dexUpdateFlow = $dexUpdateFlow
    dexBridgeFlowFixtures = $dexBridgeFlowFixtureEvidence
    dexBridgeFlows = $dexBridgeFlows
    dexReportPermalinkFlowFixtures = $dexReportPermalinkFlowFixtureEvidence
    dexReportPermalinkFlow = $dexReportPermalinkFlow
    releaseToolContracts = [pscustomobject]@{
        invocations = $releaseToolInvocationCompatibility
        evidence = $releaseToolEvidenceCompatibility
        inspectorArguments = $releaseToolInspectorArgumentCompatibility
        reportPermalinkEvidence = $releaseToolReportPermalinkEvidenceCompatibility
        reportPermalinkInspectorArguments = `
            $releaseToolReportPermalinkInspectorArgumentCompatibility
        reportPermalinkInspectorBindings = `
            $releaseToolReportPermalinkInspectorBindingCompatibility
        proxyBootstrapEvidence = $releaseToolProxyBootstrapEvidenceCompatibility
        proxyBootstrapInspectorArguments = `
            $releaseToolProxyBootstrapInspectorArgumentCompatibility
        proxyBootstrapInspectorBindings = `
            $releaseToolProxyBootstrapInspectorBindingCompatibility
    }
    alignment = '16KiB-passed'
    archive = 'passed'
    archiveInventory = [pscustomobject]@{
        candidate = $candidateArchiveInventory
        source = $sourceArchiveInventory
    }
    signing = [pscustomobject]@{ schemes = @('v2'); signerCount = 1; certificateSha256 = $certificate }
    nativeLibraries = $nativeLibraries
    assets = $assetPreservation
    passiveBlockingReleaseGates = $passiveBlockingReleaseGates
    updateReleaseGates = $updateReleaseGates
    proxyReleaseGates = $proxyReleaseGates
    targetedJadx = [pscustomobject]@{
        version = [string]$resolution.toolchain.jadxVersion
        jarSha256 = [string]$resolution.toolchain.jadxJarSha256
        recovered = $jadxRecovery
    }
    runtimeValidation = 'not-run'
}
if ($ReportPath) { Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath)) }
[pscustomobject]$report
}
finally {
    $candidateArtifactLock.Dispose()
}
