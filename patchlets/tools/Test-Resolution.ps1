[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceApk,
    [Parameter(Mandatory)][string]$DecodedRoot,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

$repositoryRoot = Get-PatchletRepositoryRoot
$resolutionPathFull = [IO.Path]::GetFullPath($ResolutionPath)
$resolutionDirectory = Split-Path -Parent $resolutionPathFull
$decodedRootFull = [IO.Path]::GetFullPath($DecodedRoot)
$resolutionSchema = Join-Path $repositoryRoot 'patchlets\schemas\resolution.schema.json'
if (-not (Test-Json -LiteralPath $resolutionPathFull -SchemaFile $resolutionSchema -ErrorAction Stop)) { throw 'Resolution failed schema validation.' }
$resolution = Read-PatchletJson -Path $resolutionPathFull
$expectedUpdateMetadataEndpoints = @(
    'https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/threadsmod-update.json',
    'https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/threadsmod-update.json',
    'https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/threadsmod-update.json'
)
$sourceVersionCode = [int64]$resolution.source.versionCode
$targetModBuild = [int64]$resolution.target.modBuild
if ($sourceVersionCode -eq [int64]::MaxValue) {
    throw 'Resolution source versionCode cannot be incremented for the clone target.'
}
$expectedTargetVersionCode = $sourceVersionCode + 1L
$expectedTargetVersionName = '{0}-threadsmod.{1}' -f `
    [string]$resolution.source.versionName, $targetModBuild
$expectedUpdateDexReviewRequired = if ([string]$resolution.status -ceq 'verified-current') {
    $false
} elseif ([string]$resolution.status -ceq 'review-required') {
    $true
} else {
    throw 'Resolution updater proof has an unsupported review status.'
}
if ([int64]$resolution.update.currentModBuild -ne 1L `
        -or $targetModBuild -ne 1L `
        -or [int64]$resolution.target.versionCode -ne $expectedTargetVersionCode `
        -or [string]$resolution.target.versionName -cne $expectedTargetVersionName `
        -or [string]$resolution.update.metadataPurpose -ne 'threadsmod-app-update' `
        -or @(Compare-Object @($resolution.update.metadataEndpoints) `
            $expectedUpdateMetadataEndpoints -SyncWindow 0).Count -ne 0 `
        -or [string]$resolution.update.requestInstallPermission `
            -ne 'android.permission.REQUEST_INSTALL_PACKAGES' `
        -or [string]$resolution.update.fileProviderAuthority `
            -ne 'app.tree55.threads.fileprovider' `
        -or [string]$resolution.update.fileProviderCachePath -ne 'shared/updates' `
        -or $resolution.release.updateSignedDexReviewRequired `
            -ne $expectedUpdateDexReviewRequired `
        -or [int]$resolution.release.expectedDexUpdateFlowFixtureCount -ne 96 `
        -or [int]$resolution.release.expectedDexUpdateFlowInspectorArgumentCount -ne 12) {
    throw 'Resolution in-app update contract drifted.'
}
if (@($resolution.release.requiredHookCalls | Where-Object {
            [string]$_ -ceq [string]$resolution.update.requestInstallPermission
        }).Count -ne 0) {
    throw 'Manifest-only updater permission must not be required as a final-DEX marker.'
}
$expectedUpdateFlowRoots = @(
    'Lthreadsmod/update/UpdateController;',
    'Lthreadsmod/update/UpdateEndpoints;',
    'Lthreadsmod/update/UpdateJson;',
    'Lthreadsmod/update/UpdateManifest;',
    'Lthreadsmod/update/UpdateSignature;',
    'Lthreadsmod/update/UpdateStore;',
    'Lthreadsmod/bootstrap/ModBootstrap;'
)
$requiredDexUpdateFlow = $resolution.release.requiredDexUpdateFlow
if ([string]$requiredDexUpdateFlow.id -ne 'threadsmod-update-flow-v1' `
        -or [string]$requiredDexUpdateFlow.expectedDexName -ne 'classes.dex' `
        -or [string]$requiredDexUpdateFlow.classPrefix -ne 'Lthreadsmod/update/' `
        -or [string]$requiredDexUpdateFlow.expectedSemanticSha256 `
            -notmatch '^[0-9a-f]{64}$' `
        -or [int]$requiredDexUpdateFlow.expectedSemanticClassCount -ne 24 `
        -or (@($requiredDexUpdateFlow.orderedRootDescriptors) -join "`n") `
            -cne ($expectedUpdateFlowRoots -join "`n")) {
    throw 'Resolution raw updater DEX flow contract drifted.'
}

$sourceBinding = Test-PatchletSourceBinding -Resolution $resolution -SourceApk $SourceApk
$assets = @(Test-PatchletAssets -Resolution $resolution -RepositoryRoot $repositoryRoot)
$toolchain = @()
foreach ($toolCheck in @(
    @((Join-Path $repositoryRoot '.tools\apktool\apktool_3.0.3.jar'), [string]$resolution.toolchain.apktoolJarSha256, 'apktool'),
    @((Join-Path $repositoryRoot 'decompiled\apktool-framework\1.apk'), [string]$resolution.toolchain.frameworkApkSha256, 'framework'),
    @((Join-Path $repositoryRoot '.tools\jadx-1.5.6\lib\jadx-1.5.6-all.jar'), [string]$resolution.toolchain.jadxJarSha256, 'jadx')
)) {
    $actualHash = Get-PatchletSha256 -Path $toolCheck[0]
    if ($actualHash -ne $toolCheck[1]) { throw "Pinned tool '$($toolCheck[2])' hash mismatch." }
    $toolchain += [pscustomobject]@{ id = $toolCheck[2]; path = $toolCheck[0]; sha256 = $actualHash }
}
$proofs = @(Test-PatchletProofs -Resolution $resolution -DecodedRoot $decodedRootFull)
$rewriteSets = @()
foreach ($rewriteSetName in @($resolution.rewriteSets)) {
    $rewriteSetPath = Resolve-PatchletChildPath -Root $resolutionDirectory -Child ([string]$rewriteSetName)
    $states = @(Test-PatchletRewriteSet -RewriteSetPath $rewriteSetPath -DecodedRoot $decodedRootFull)
    $rewriteSets += [pscustomobject]@{
        name = [string]$rewriteSetName
        pristine = @($states | Where-Object state -eq 'pristine').Count
        applied = @($states | Where-Object state -eq 'applied').Count
        total = $states.Count
    }
}

$manifestPath = Join-Path $decodedRootFull 'AndroidManifest.xml'
$manifest = Get-NormalizedPatchletText -Path $manifestPath
$sourceId = [string]$resolution.source.applicationId
$targetId = [string]$resolution.target.applicationId
$sourcePackage = 'package="{0}"' -f $sourceId
$targetPackage = 'package="{0}"' -f $targetId
if (($manifest.IndexOf($sourcePackage, [StringComparison]::Ordinal) -lt 0) -and
    ($manifest.IndexOf($targetPackage, [StringComparison]::Ordinal) -lt 0)) {
    throw "Decoded manifest is neither the expected source nor the resolved target application ID."
}
$isTargetManifest = $manifest.Contains($targetPackage, [StringComparison]::Ordinal)
if ($isTargetManifest) {
    $null = Assert-PatchletManifestPermission -ManifestText $manifest `
        -Permission ([string]$resolution.update.requestInstallPermission) `
        -Format 'decoded-xml' `
        -FailureMessage 'Patched manifest lacks one exact updater install permission.'
    foreach ($requiredManifestLiteral in @(
        'android:authorities="app.tree55.threads.fileprovider"')) {
        if ((Get-PatchletLiteralCount -Text $manifest -Literal $requiredManifestLiteral) -ne 1) {
            throw "Patched manifest lacks one exact updater binding: $requiredManifestLiteral"
        }
    }
    $apktoolYaml = Get-NormalizedPatchletText -Path (Join-Path $decodedRootFull 'apktool.yml')
    $expectedApktoolVersionCode = 'versionCode: {0}' -f $expectedTargetVersionCode
    $expectedApktoolVersionName = 'versionName: {0}' -f $expectedTargetVersionName
    if ((Get-PatchletLiteralCount -Text $apktoolYaml -Literal $expectedApktoolVersionCode) -ne 1 `
            -or (Get-PatchletLiteralCount -Text $apktoolYaml `
                -Literal $expectedApktoolVersionName) -ne 1) {
        throw 'Patched apktool version does not match the exact updater target.'
    }
} elseif ($manifest.Contains(
        'android.permission.REQUEST_INSTALL_PACKAGES', [StringComparison]::Ordinal)) {
    throw 'Pristine decoded manifest unexpectedly contains updater install permission.'
}

$report = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToString('o')
    status = 'passed'
    resolutionId = [string]$resolution.resolutionId
    resolutionPath = $resolutionPathFull
    decodedRoot = $decodedRootFull
    sourceBinding = $sourceBinding
    manifestIdentity = if ($isTargetManifest) { 'target' } else { 'source' }
    inAppUpdate = [ordered]@{
        currentModBuild = [long]$resolution.update.currentModBuild
        targetModBuild = $targetModBuild
        targetVersionCode = [long]$resolution.target.versionCode
        targetVersionName = [string]$resolution.target.versionName
        metadataPurpose = 'threadsmod-app-update'
        metadataEndpoints = $expectedUpdateMetadataEndpoints
        patchedManifestVerified = $isTargetManifest
        requestInstallPermissionAuthority = 'manifest-only'
        requiredAsDexMarker = $false
        signedDexReviewRequired = $expectedUpdateDexReviewRequired
        generatedFixtureCount = 96
        inspectorArgumentCount = 12
        semanticSha256 = [string]$requiredDexUpdateFlow.expectedSemanticSha256
        semanticClassCount = [int]$requiredDexUpdateFlow.expectedSemanticClassCount
    }
    assets = $assets
    toolchain = $toolchain
    semanticProofs = $proofs
    rewriteSets = $rewriteSets
}

if ($ReportPath) {
    Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath))
}

[pscustomobject]$report
