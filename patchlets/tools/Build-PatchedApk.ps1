[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DecodedRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ArtifactBaseName,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [ValidateSet('Release', 'SignedReview')][string]$ValidationMode = 'Release',
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$BuildToolsVersion = '36.0.0',
    [string]$Java = 'java',
    [string]$ApktoolJar,
    [string]$FrameworkDirectory,
    [string]$KeyStore,
    [string]$KeyAlias,
    [string]$KeyStorePasswordEnvironment = 'THREADSMOD_KS_PASS',
    [string]$KeyPasswordEnvironment = 'THREADSMOD_KEY_PASS',
    [string]$ExpectedDecodedTreeSha256,
    [Nullable[int]]$ExpectedDecodedFiles,
    [Nullable[int]]$ExpectedDecodedDirectories,
    [Nullable[int]]$ExpectedDecodedEntries
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Native command failed with exit code ${code}: $Command" }
}

$repositoryRoot = Get-PatchletRepositoryRoot
if (-not $ApktoolJar) { $ApktoolJar = Join-Path $repositoryRoot '.tools\apktool\apktool_3.0.3.jar' }
if (-not $FrameworkDirectory) { $FrameworkDirectory = Join-Path $repositoryRoot 'decompiled\apktool-framework' }
$resolution = Read-PatchletJson -Path ([IO.Path]::GetFullPath($ResolutionPath))
if ($BuildToolsVersion -ne [string]$resolution.toolchain.buildToolsVersion) {
    throw "Build Tools version '$BuildToolsVersion' differs from the resolution's pinned '$($resolution.toolchain.buildToolsVersion)'."
}
$apksignerJar = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion\lib\apksigner.jar"
$zipalign = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion\zipalign.exe"

foreach ($path in @($DecodedRoot, $ApktoolJar, $FrameworkDirectory, $zipalign)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required build path does not exist: $path" }
}
foreach ($toolCheck in @(
    @($ApktoolJar, [string]$resolution.toolchain.apktoolJarSha256, 'Apktool'),
    @((Join-Path $FrameworkDirectory '1.apk'), [string]$resolution.toolchain.frameworkApkSha256, 'Apktool framework')
)) {
    $actualHash = Get-PatchletSha256 -Path $toolCheck[0]
    if ($actualHash -ne $toolCheck[1]) { throw "$($toolCheck[2]) hash mismatch. Expected '$($toolCheck[1])', observed '$actualHash'." }
}

$expectedDecodedValues = @(
    -not [string]::IsNullOrWhiteSpace($ExpectedDecodedTreeSha256),
    $null -ne $ExpectedDecodedFiles,
    $null -ne $ExpectedDecodedDirectories,
    $null -ne $ExpectedDecodedEntries
)
$expectedDecodedCount = @($expectedDecodedValues | Where-Object { $_ }).Count
if ($expectedDecodedCount -ne 0 -and $expectedDecodedCount -ne $expectedDecodedValues.Count) {
    throw 'Expected decoded-tree SHA-256 and inventory counts must be supplied together.'
}
$decodedInputState = Get-PatchletCompleteTreeState -Root ([IO.Path]::GetFullPath($DecodedRoot))
if ($expectedDecodedCount -ne 0 `
        -and ([string]$decodedInputState.sha256 -ne $ExpectedDecodedTreeSha256.ToLowerInvariant() `
            -or [int]$decodedInputState.files -ne [int]$ExpectedDecodedFiles `
            -or [int]$decodedInputState.directories -ne [int]$ExpectedDecodedDirectories `
            -or [int]$decodedInputState.entries -ne [int]$ExpectedDecodedEntries)) {
    throw 'Build decoded-tree input does not match the bound complete idempotency inventory.'
}

$ArtifactBaseName = Assert-PatchletArtifactBaseName -Name $ArtifactBaseName
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if ($ValidationMode -ceq 'SignedReview' -and -not $KeyStore) {
    throw 'SignedReview mode requires a keystore and may not produce an unsigned review candidate.'
}
if ($KeyStore) {
    $expectedResolutionStatus = if ($ValidationMode -ceq 'SignedReview') {
        'review-required'
    } else {
        'verified-current'
    }
    $expectedUpdateSignedDexReviewRequired = $ValidationMode -ceq 'SignedReview'
    if ([string]$resolution.status -cne $expectedResolutionStatus `
            -or $resolution.release.updateSignedDexReviewRequired `
                -ne $expectedUpdateSignedDexReviewRequired) {
        throw "Signing resolution state does not match ValidationMode '$ValidationMode'."
    }
}
if ($ValidationMode -ceq 'SignedReview') {
    $workRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'work'))
    $reviewOutput = Assert-PatchletPathUnderRoot -Path $outputFull -Root $workRoot
    if ($reviewOutput.Equals($workRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SignedReview output must be a strict child of the workspace work directory.'
    }
}
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
$unsigned = Assert-PatchletPathUnderRoot `
    -Path (Join-Path $outputFull "$ArtifactBaseName-unsigned.apk") -Root $outputFull
$aligned = Assert-PatchletPathUnderRoot `
    -Path (Join-Path $outputFull "$ArtifactBaseName-aligned.apk") -Root $outputFull
$signed = Assert-PatchletPathUnderRoot `
    -Path (Join-Path $outputFull "$ArtifactBaseName.apk") -Root $outputFull
foreach ($path in @($unsigned, $aligned, $signed)) {
    if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite existing build artifact: $path" }
}

$unsignedLock = $null
$alignedLock = $null
$signedLock = $null
try {
Invoke-Checked -Command $Java -Arguments @(
    '-jar', $ApktoolJar, 'b',
    '--force', '--jobs', '8',
    '--frame-path', ([IO.Path]::GetFullPath($FrameworkDirectory)),
    '--output', $unsigned,
    ([IO.Path]::GetFullPath($DecodedRoot))
)
$unsignedLock = [IO.File]::Open(
    $unsigned, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
Invoke-Checked -Command $zipalign -Arguments @('-P', '16', '-f', '4', $unsigned, $aligned)
$alignedLock = [IO.File]::Open(
    $aligned, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
$unsignedLock.Dispose()
$unsignedLock = $null
Invoke-Checked -Command $zipalign -Arguments @('-c', '-P', '16', '4', $aligned)

$artifact = $aligned
$signedResult = $false
if ($KeyStore) {
    foreach ($path in @($KeyStore, $apksignerJar)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Signing input does not exist: $path" }
    }
    if (-not $KeyAlias) { throw 'KeyAlias is required when KeyStore is supplied.' }
    $apksignerHash = Get-PatchletSha256 -Path $apksignerJar
    if ($apksignerHash -ne [string]$resolution.toolchain.apksignerJarSha256) {
        throw "Apksigner hash mismatch. Expected '$($resolution.toolchain.apksignerJarSha256)', observed '$apksignerHash'."
    }
    if (-not [Environment]::GetEnvironmentVariable($KeyStorePasswordEnvironment)) {
        throw "Signing password environment variable is not set: $KeyStorePasswordEnvironment"
    }
    if (-not [Environment]::GetEnvironmentVariable($KeyPasswordEnvironment)) {
        throw "Signing password environment variable is not set: $KeyPasswordEnvironment"
    }
    Invoke-Checked -Command $Java -Arguments @(
        '-jar', $apksignerJar, 'sign',
        '--ks', ([IO.Path]::GetFullPath($KeyStore)),
        '--ks-key-alias', $KeyAlias,
        '--ks-pass', "env:$KeyStorePasswordEnvironment",
        '--key-pass', "env:$KeyPasswordEnvironment",
        '--v1-signing-enabled', 'false',
        '--v2-signing-enabled', 'true',
        '--v3-signing-enabled', 'false',
        '--v4-signing-enabled', 'false',
        '--out', $signed,
        $aligned
    )
    $signedLock = [IO.File]::Open(
        $signed, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    Invoke-Checked -Command $Java -Arguments @('-jar', $apksignerJar, 'verify', '-Werr', '--verbose', '--print-certs', $signed)
    Invoke-Checked -Command $zipalign -Arguments @('-c', '-P', '16', '4', $signed)
    $artifact = $signed
    $signedResult = $true
}

[pscustomobject]@{
    schemaVersion = 1
    status = 'passed'
    artifact = $artifact
    sha256 = Get-PatchletSha256 -Path $artifact
    size = (Get-Item -LiteralPath $artifact).Length
    signed = $signedResult
    validationMode = $ValidationMode
    releaseEligible = $signedResult -and $ValidationMode -ceq 'Release'
    unsigned = $unsigned
    aligned = $aligned
    decodedInput = [pscustomobject]@{
        path = [IO.Path]::GetFullPath($DecodedRoot)
        sha256 = [string]$decodedInputState.sha256
        files = [int]$decodedInputState.files
        directories = [int]$decodedInputState.directories
        entries = [int]$decodedInputState.entries
    }
}
}
finally {
    if ($null -ne $signedLock) { $signedLock.Dispose() }
    if ($null -ne $alignedLock) { $alignedLock.Dispose() }
    if ($null -ne $unsignedLock) { $unsignedLock.Dispose() }
}
