[CmdletBinding()]
param(
    [string]$CatalogPath = (Join-Path $PSScriptRoot '..\catalog.json'),
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

$repositoryRoot = Get-PatchletRepositoryRoot
$patchletsRoot = Join-Path $repositoryRoot 'patchlets'
$catalogFull = [IO.Path]::GetFullPath($CatalogPath)
$resolutionFull = [IO.Path]::GetFullPath($ResolutionPath)
if (-not (Test-Json -LiteralPath $catalogFull -SchemaFile (Join-Path $patchletsRoot 'schemas\catalog.schema.json') -ErrorAction Stop)) { throw 'Patchlet catalog failed schema validation.' }
if (-not (Test-Json -LiteralPath $resolutionFull -SchemaFile (Join-Path $patchletsRoot 'schemas\resolution.schema.json') -ErrorAction Stop)) { throw 'Patchlet resolution failed schema validation.' }

$catalog = Read-PatchletJson -Path $catalogFull
$resolution = Read-PatchletJson -Path $resolutionFull
if ([string]$catalog.policies.signedReview `
        -cne 'non-publishing-exact-signed-evidence-only') {
    throw 'Catalog SignedReview policy must remain non-publishing exact signed evidence only.'
}
$updateManifestPath = Join-Path $patchletsRoot 'features\085-in-app-update\patchlet.json'
$updateManifest = Read-PatchletJson -Path $updateManifestPath
if ([string]$updateManifest.id -ne '085-in-app-update' `
        -or [int]$updateManifest.revision -ne 2 `
        -or [string]$updateManifest.ai.taskTemplate `
            -ne '../../ai/tasks/RESOLVE-IN-APP-UPDATE.md') {
    throw 'In-app update patchlet identity, revision, or bounded AI task drifted.'
}
$expectedUpdateDexReviewRequired = if ([string]$resolution.status -ceq 'verified-current') {
    $false
} elseif ([string]$resolution.status -ceq 'review-required') {
    $true
} else {
    throw 'Updater resolution has an unsupported review status.'
}
if ($resolution.release.updateSignedDexReviewRequired -ne $expectedUpdateDexReviewRequired) {
    throw 'Updater raw primary-DEX blocker does not match the resolution review status.'
}
$expectedUpdateDescriptors = @(
    'Lthreadsmod/update/UpdateController;',
    'Lthreadsmod/update/UpdateEndpoints;',
    'Lthreadsmod/update/UpdateJson;',
    'Lthreadsmod/update/UpdateManifest;',
    'Lthreadsmod/update/UpdateSignature;',
    'Lthreadsmod/update/UpdateStore;'
)
$expectedUpdatePreferences = @(
    'update_verified_envelope',
    'update_revision',
    'update_mod_build',
    'update_check_not_before',
    'update_dismissed_revision'
)
$expectedUpdateGates = @(
    'update-host-fixtures',
    'update-endpoint-policy',
    'update-manifest-contract',
    'update-dialog-contract',
    'update-installer-contract',
    'update-signed-dex-contract',
    'update-manifest-rewrite-contract',
    'dex-method-budget'
)
if (@(Compare-Object @($updateManifest.ownership.classDescriptors) $expectedUpdateDescriptors).Count -ne 0 `
        -or @(Compare-Object @($updateManifest.ownership.preferenceKeys) $expectedUpdatePreferences).Count -ne 0 `
        -or @(Compare-Object @($updateManifest.releaseGates) $expectedUpdateGates -SyncWindow 0).Count -ne 0) {
    throw 'In-app update descriptors, preference ownership, or ordered release gates drifted.'
}
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
        -or [string]$resolution.update.requiredSignerCertificateSha256 `
            -ne '317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079') {
    throw 'Resolution in-app update version, metadata, FileProvider, permission, or signer binding drifted.'
}
$requiredProviderAuthorities = @()
$seenProviderAuthorities = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
foreach ($authorityRequirement in @($resolution.release.requiredProviderAuthorities)) {
    $propertyNames = @($authorityRequirement.PSObject.Properties.Name)
    $authority = [string]$authorityRequirement.authority
    $expectedCount = [int]$authorityRequirement.expectedCount
    if ($propertyNames.Count -ne 2 `
            -or -not ($propertyNames -ccontains 'authority') `
            -or -not ($propertyNames -ccontains 'expectedCount') `
            -or [string]::IsNullOrWhiteSpace($authority) `
            -or -not $authority.StartsWith(
                ([string]$resolution.target.applicationId + '.'),
                [StringComparison]::Ordinal) `
            -or $expectedCount -lt 1 `
            -or $expectedCount -gt 16 `
            -or -not $seenProviderAuthorities.Add($authority)) {
        throw 'Resolution provider authorities must be unique counted objects owned by the clone package.'
    }
    $requiredProviderAuthorities += [pscustomobject][ordered]@{
        authority = $authority
        expectedCount = $expectedCount
    }
}
if ($requiredProviderAuthorities.Count -lt 1 `
        -or @($requiredProviderAuthorities | Where-Object {
            [string]$_.authority -ceq [string]$resolution.update.fileProviderAuthority `
                -and [int]$_.expectedCount -eq 1
        }).Count -ne 1) {
    throw 'Resolution must count the updater FileProvider authority exactly once.'
}
$drawerRows = @($resolution.drawerSettings.rows)
$drawerPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
$drawerRuleIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
$drawerKeys = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
if ($drawerRows.Count -lt 1) {
    throw 'Resolution must declare at least one native drawer Settings row.'
}
foreach ($drawerRow in $drawerRows) {
    $path = [string]$drawerRow.path
    $method = [string]$drawerRow.method
    $ruleId = [string]$drawerRow.hookRuleId
    $key = [string]$drawerRow.key
    $label = [string]$drawerRow.label
    if ([string]::IsNullOrWhiteSpace($path) `
            -or [string]::IsNullOrWhiteSpace($method) `
            -or [string]::IsNullOrWhiteSpace($ruleId) `
            -or [string]::IsNullOrWhiteSpace($key) `
            -or [string]::IsNullOrWhiteSpace($label) `
            -or -not $drawerPaths.Add($path) `
            -or -not $drawerRuleIds.Add($ruleId) `
            -or -not $drawerKeys.Add($key)) {
        throw 'Resolution drawer Settings rows require nonempty values and unique paths, hook rule IDs, and keys.'
    }
}
if ([string]$resolution.source.versionName -ceq '444.0.0.45.85' `
        -and $drawerRows.Count -ne 2) {
    throw 'The exact 444.0.0.45.85 resolution must own both runtime-selectable drawer Settings rows.'
}
$targetedJadxRecoveryText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'tools\TargetedJadxRecovery.java')
if ((Get-PatchletLiteralCount -Text $targetedJadxRecoveryText `
            -Literal 'jadxArgs.setShowInconsistentCode(true);') -ne 1 `
        -or $targetedJadxRecoveryText.Contains(
            'jadxArgs.setShowInconsistentCode(false);', [StringComparison]::Ordinal)) {
    throw 'Targeted JADX recovery must enable the reviewed inconsistent-code recovery mode exactly once.'
}
$releaseToolBindings = @(
    @('splitUniversalizationToolSourceSha256', 'tools\Build-SplitSourceUniversalApk.ps1'),
    @('splitSourceContractTestSourceSha256', 'tools\Test-SplitSourceSetContract.ps1'),
    @('patchletPipelineSourceSha256', 'tools\Invoke-PatchletPipeline.ps1'),
    @('buildPatchedApkSourceSha256', 'tools\Build-PatchedApk.ps1'),
    @('targetedJadxRecoverySourceSha256', 'tools\TargetedJadxRecovery.java'),
    @('dexInspectorSourceSha256', 'tools\DexInspector.java'),
    @('dexLiteralCallInspectorSourceSha256', 'tools\DexLiteralCallInspector.java'),
    @('dexLiteralCallInspectorTestSourceSha256', 'tools\Test-DexLiteralCallInspector.ps1'),
    @('dexProxyBootstrapFlowInspectorSourceSha256', 'tools\DexProxyBootstrapFlowInspector.java'),
    @('dexProxyBootstrapFlowInspectorTestSourceSha256', 'tools\Test-DexProxyBootstrapFlowInspector.ps1'),
    @('dexBridgeFlowInspectorSourceSha256', 'tools\DexBridgeFlowInspector.java'),
    @('dexBridgeFlowFixtureAssemblerSourceSha256', 'tools\DexBridgeFlowFixtureAssembler.java'),
    @('dexBridgeFlowInspectorTestSourceSha256', 'tools\Test-DexBridgeFlowInspector.ps1'),
    @('dexReportPermalinkFlowInspectorSourceSha256', 'tools\DexReportPermalinkFlowInspector.java'),
    @('dexReportPermalinkFlowInspectorTestSourceSha256', 'tools\Test-DexReportPermalinkFlowInspector.ps1'),
    @('dexUpdateFlowInspectorSourceSha256', 'tools\DexUpdateFlowInspector.java'),
    @('dexUpdateFlowInspectorTestSourceSha256', 'tools\Test-DexUpdateFlowInspector.ps1'),
    @('releaseToolContractModuleSha256', 'tools\ThreadsMod.ReleaseToolContract.psm1'),
    @('patchletCoreModuleSha256', 'tools\ThreadsMod.Patchlets.psm1'),
    @('resolutionSchemaSha256', 'schemas\resolution.schema.json'),
    @('patchletSchemaSha256', 'schemas\patchlet.schema.json'),
    @('patchletCatalogTestSourceSha256', 'tools\Test-PatchletCatalog.ps1'),
    @('activityUiEmulatorTestSourceSha256', 'tools\Test-ActivityUiEmulator.ps1'),
    @('activityUiProbeManifestSha256', 'assets\release-gates\activity-ui-probe\AndroidManifest.xml'),
    @('patchedApkTestSourceSha256', 'tools\Test-PatchedApk.ps1'),
    @('releaseContractTestSourceSha256', 'tools\Test-ReleaseContract.ps1')
)
foreach ($binding in $releaseToolBindings) {
    $expectedHash = [string]$resolution.assets.($binding[0])
    $toolPath = Join-Path $patchletsRoot $binding[1]
    if ([string]::IsNullOrWhiteSpace($expectedHash) `
            -or (Get-PatchletSha256 -Path $toolPath) -ne $expectedHash) {
        throw "Release-contract tool hash is absent or stale: $($binding[1])"
    }
}
$releaseToolContractModulePath = Join-Path $patchletsRoot 'tools\ThreadsMod.ReleaseToolContract.psm1'
Import-Module $releaseToolContractModulePath -Force -DisableNameChecking
if ([int]$resolution.release.expectedDexBridgeFlowInspectorArgumentCount -ne 28) {
    throw 'Resolution must pin the reviewed DEX bridge inspector command to 28 arguments.'
}
if ([int]$resolution.release.expectedDexReportPermalinkFlowInspectorArgumentCount -ne 33 `
        -or [int]$resolution.release.expectedDexReportPermalinkFlowFixtureCount -ne 41) {
    throw 'Resolution must pin the report-permalink inspector to 33 arguments and 41 fixtures.'
}
if ([int]$resolution.release.expectedDexProxyBootstrapFlowInspectorArgumentCount -ne 11 `
        -or [int]$resolution.release.expectedDexProxyBootstrapFlowFixtureCount -ne 13) {
    throw 'Resolution must pin the proxy-bootstrap inspector to 11 arguments and 13 fixtures.'
}
if ([int]$resolution.release.expectedDexUpdateFlowInspectorArgumentCount -ne 12 `
        -or [int]$resolution.release.expectedDexUpdateFlowFixtureCount -ne 96) {
    throw 'Resolution must pin the updater inspector to 12 arguments and 96 fixtures.'
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
    throw 'Resolution updater raw DEX flow contract drifted.'
}
$releaseToolInvocationCompatibility = Test-ThreadsModReleaseToolInvocationContracts `
    -ToolsRoot (Join-Path $patchletsRoot 'tools')
$releaseToolWrapperAst = Get-ThreadsModReleaseToolAst `
    -Path (Join-Path $patchletsRoot 'tools\Test-PatchedApk.ps1') `
    -Label 'Patched-APK release wrapper'
$releaseToolHarnessAst = Get-ThreadsModReleaseToolAst `
    -Path (Join-Path $patchletsRoot 'tools\Test-DexBridgeFlowInspector.ps1') `
    -Label 'DEX bridge-flow positive fixture harness'
$releaseToolReportPermalinkHarnessAst = Get-ThreadsModReleaseToolAst `
    -Path (Join-Path $patchletsRoot 'tools\Test-DexReportPermalinkFlowInspector.ps1') `
    -Label 'DEX report-permalink-flow positive fixture harness'
$releaseToolProxyBootstrapHarnessAst = Get-ThreadsModReleaseToolAst `
    -Path (Join-Path $patchletsRoot 'tools\Test-DexProxyBootstrapFlowInspector.ps1') `
    -Label 'DEX proxy-bootstrap-flow positive fixture harness'
$releaseToolBridgeContract = @($resolution.release.requiredDexBridgeFlows)[0]
$releaseToolEvidenceCompatibility = Assert-ThreadsModReleaseEvidenceContract `
    -ReleaseWrapperAst $releaseToolWrapperAst `
    -FixtureHarnessAst $releaseToolHarnessAst `
    -ReviewedFixtureCount ([int]$resolution.release.expectedDexBridgeFlowFixtureCount) `
    -ReviewedTerminalRoutes ([int]$resolution.release.expectedReviewedTerminalRoutes) `
    -ReviewedCurrentTerminalRoutes `
        ([int]$resolution.release.expectedCurrentReviewedTerminalRoutes) `
    -ReviewedCurrentPacedNextPosts `
        ([int]$resolution.release.expectedCurrentAutomaticPacedNextPosts) `
    -ReviewedCurrentOwnerMode `
        ([string]$resolution.release.expectedCurrentAutomaticOwnerMode) `
    -ReviewedPrepareModelInvokeCount `
        ([int]$releaseToolBridgeContract.expectedPrepareModelInvokeCount) `
    -ReviewedPassivePreflightInvokeCount `
        ([int]$releaseToolBridgeContract.expectedPassivePreflightInvokeCount) `
    -ReviewedCacheLookupInvokeCount `
        ([int]$releaseToolBridgeContract.expectedCacheLookupInvokeCount) `
    -ReviewedCacheFactoryInvokeCount `
        ([int]$releaseToolBridgeContract.expectedCacheFactoryInvokeCount) `
    -ReviewedCachePlaceholderInvokeCount `
        ([int]$releaseToolBridgeContract.expectedCachePlaceholderInvokeCount)
$releaseToolInspectorArgumentCompatibility = Assert-ThreadsModDexBridgeInspectorArgumentContract `
    -InspectorSourcePath (Join-Path $patchletsRoot 'tools\DexBridgeFlowInspector.java') `
    -ReviewedArgumentCount ([int]$resolution.release.expectedDexBridgeFlowInspectorArgumentCount)
$releaseToolReportPermalinkEvidenceCompatibility = Assert-ThreadsModReportPermalinkEvidenceContract `
    -ReleaseWrapperAst $releaseToolWrapperAst `
    -FixtureHarnessAst $releaseToolReportPermalinkHarnessAst `
    -ReviewedFixtureCount ([int]$resolution.release.expectedDexReportPermalinkFlowFixtureCount) `
    -ReviewedInspectorArgumentCount `
        ([int]$resolution.release.expectedDexReportPermalinkFlowInspectorArgumentCount)
$releaseToolReportPermalinkInspectorArgumentCompatibility = `
    Assert-ThreadsModReportPermalinkInspectorArgumentContract `
        -InspectorSourcePath (Join-Path $patchletsRoot 'tools\DexReportPermalinkFlowInspector.java') `
        -ReviewedArgumentCount `
            ([int]$resolution.release.expectedDexReportPermalinkFlowInspectorArgumentCount)
$releaseToolReportPermalinkInspectorBindingCompatibility = `
    Assert-ThreadsModReportPermalinkInspectorBindingContract `
        -ReleaseWrapperAst $releaseToolWrapperAst `
        -FixtureHarnessAst $releaseToolReportPermalinkHarnessAst `
        -ReviewedArgumentCount `
            ([int]$resolution.release.expectedDexReportPermalinkFlowInspectorArgumentCount)
$releaseToolProxyBootstrapEvidenceCompatibility = `
    Assert-ThreadsModProxyBootstrapEvidenceContract `
        -ReleaseWrapperAst $releaseToolWrapperAst `
        -FixtureHarnessAst $releaseToolProxyBootstrapHarnessAst `
        -ReviewedFixtureCount `
            ([int]$resolution.release.expectedDexProxyBootstrapFlowFixtureCount) `
        -ReviewedInspectorArgumentCount `
            ([int]$resolution.release.expectedDexProxyBootstrapFlowInspectorArgumentCount)
$releaseToolProxyBootstrapInspectorArgumentCompatibility = `
    Assert-ThreadsModProxyBootstrapInspectorArgumentContract `
        -InspectorSourcePath (Join-Path $patchletsRoot 'tools\DexProxyBootstrapFlowInspector.java') `
        -ReviewedArgumentCount `
            ([int]$resolution.release.expectedDexProxyBootstrapFlowInspectorArgumentCount)
$releaseToolProxyBootstrapInspectorBindingCompatibility = `
    Assert-ThreadsModProxyBootstrapInspectorBindingContract `
        -ReleaseWrapperAst $releaseToolWrapperAst `
        -FixtureHarnessAst $releaseToolProxyBootstrapHarnessAst `
        -ReviewedArgumentCount `
            ([int]$resolution.release.expectedDexProxyBootstrapFlowInspectorArgumentCount)
$releaseToolContractNegativeFixtures = Test-ThreadsModReleaseToolContractNegativeFixtures `
    -ReviewedFixtureCount ([int]$resolution.release.expectedDexBridgeFlowFixtureCount) `
    -ReviewedTerminalRoutes ([int]$resolution.release.expectedReviewedTerminalRoutes) `
    -ReviewedCurrentTerminalRoutes `
        ([int]$resolution.release.expectedCurrentReviewedTerminalRoutes) `
    -ReviewedCurrentPacedNextPosts `
        ([int]$resolution.release.expectedCurrentAutomaticPacedNextPosts) `
    -ReviewedCurrentOwnerMode `
        ([string]$resolution.release.expectedCurrentAutomaticOwnerMode) `
    -ReviewedPrepareModelInvokeCount `
        ([int]$releaseToolBridgeContract.expectedPrepareModelInvokeCount) `
    -ReviewedPassivePreflightInvokeCount `
        ([int]$releaseToolBridgeContract.expectedPassivePreflightInvokeCount) `
    -ReviewedCacheLookupInvokeCount `
        ([int]$releaseToolBridgeContract.expectedCacheLookupInvokeCount) `
    -ReviewedCacheFactoryInvokeCount `
        ([int]$releaseToolBridgeContract.expectedCacheFactoryInvokeCount) `
    -ReviewedCachePlaceholderInvokeCount `
        ([int]$releaseToolBridgeContract.expectedCachePlaceholderInvokeCount) `
    -ReviewedInspectorArgumentCount ([int]$resolution.release.expectedDexBridgeFlowInspectorArgumentCount) `
    -ReviewedReportPermalinkFixtureCount `
        ([int]$resolution.release.expectedDexReportPermalinkFlowFixtureCount) `
    -ReviewedReportPermalinkInspectorArgumentCount `
        ([int]$resolution.release.expectedDexReportPermalinkFlowInspectorArgumentCount) `
    -ReviewedProxyBootstrapFixtureCount `
        ([int]$resolution.release.expectedDexProxyBootstrapFlowFixtureCount) `
    -ReviewedProxyBootstrapInspectorArgumentCount `
        ([int]$resolution.release.expectedDexProxyBootstrapFlowInspectorArgumentCount)
$expectedBridgeFlowFixtureTreeHash = [string]$resolution.assets.dexBridgeFlowFixtureTreeSha256
$bridgeFlowFixtureTreePath = Join-Path $patchletsRoot 'assets\release-gates\dex-bridge-flow'
if ([string]::IsNullOrWhiteSpace($expectedBridgeFlowFixtureTreeHash) `
        -or (Get-PatchletTreeSha256 -Root $bridgeFlowFixtureTreePath -Filter '*') `
            -ne $expectedBridgeFlowFixtureTreeHash) {
    throw 'Release-contract fixture tree hash is absent or stale: assets\release-gates\dex-bridge-flow'
}
$expectedReportPermalinkFlowFixtureTreeHash = `
    [string]$resolution.assets.dexReportPermalinkFlowFixtureTreeSha256
$reportPermalinkFlowFixtureTreePath = Join-Path $patchletsRoot `
    'assets\release-gates\dex-report-permalink-flow'
if ([string]::IsNullOrWhiteSpace($expectedReportPermalinkFlowFixtureTreeHash) `
        -or (Get-PatchletTreeSha256 -Root $reportPermalinkFlowFixtureTreePath -Filter '*') `
            -ne $expectedReportPermalinkFlowFixtureTreeHash) {
    throw 'Release-contract fixture tree hash is absent or stale: assets\release-gates\dex-report-permalink-flow'
}
$expectedUpdateFlowFixtureTreeHash = `
    [string]$resolution.assets.dexUpdateFlowFixtureTreeSha256
$updateFlowFixtureTreePath = Join-Path $patchletsRoot `
    'assets\release-gates\dex-update-flow'
$updateFlowFixtureManifest = Read-PatchletJson -Path (
    Join-Path $updateFlowFixtureTreePath 'negative\fixtures.json')
if ([string]::IsNullOrWhiteSpace($expectedUpdateFlowFixtureTreeHash) `
        -or (Get-PatchletTreeSha256 -Root $updateFlowFixtureTreePath -Filter '*') `
            -ne $expectedUpdateFlowFixtureTreeHash `
        -or [int]$updateFlowFixtureManifest.expectedFixtureCount -ne 96 `
        -or (1 + @($updateFlowFixtureManifest.fixtures).Count) -ne 96) {
    throw 'Release-contract updater DEX fixture tree hash or count is absent or stale.'
}
$aiTaskSchemaPath = Join-Path $patchletsRoot 'schemas\ai-task.schema.json'
$aiTaskSchema = Read-PatchletJson -Path $aiTaskSchemaPath
$aiTaskToolText = Get-NormalizedPatchletText -Path (
        Join-Path $patchletsRoot 'tools\New-AiResolutionTask.ps1')
foreach ($requiredTaskKind in @(
        'resolve-drawer-settings',
        'resolve-inline-report',
        'resolve-socks5-proxy')) {
    if (@($aiTaskSchema.properties.kind.enum | Where-Object {
            [string]$_ -eq $requiredTaskKind
        }).Count -ne 1 `
            -or -not $aiTaskToolText.Contains(
                "'$requiredTaskKind'", [StringComparison]::Ordinal)) {
        throw "AI task kind is not supported by both schema and generator: $requiredTaskKind"
    }
}
$expectedReadEndpoints = @(
    'https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/blocklist/v3/manifest.json',
    'https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/blocklist/v3/manifest.json',
    'https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/blocklist/v3/manifest.json'
)
$resolvedReadEndpoints = @($resolution.release.requiredReadEndpoints | ForEach-Object {
    [string]$_
})
if (($resolvedReadEndpoints -join "`n") -ne ($expectedReadEndpoints -join "`n")) {
    throw 'Resolution read endpoints must preserve the reviewed GitHub raw, jsDelivr, then AWS failover order.'
}
$expectedReportEndpoint = 'https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/reports'
if ([string]$resolution.reporting.writeEndpoint -ne $expectedReportEndpoint `
        -or [string]$resolution.release.requiredWriteEndpoint -ne $expectedReportEndpoint `
        -or [string]$resolution.reporting.writeEndpoint `
            -ne [string]$resolution.release.requiredWriteEndpoint) {
    throw 'Resolution reporting and release write endpoints must equal the one reviewed AWS report URL.'
}
$expectedModalActions = @('dynamic-positive', 'cancel')
$resolvedModalActions = @($resolution.inlineControls.presentation.modalActions | ForEach-Object {
    [string]$_
})
$resolvedReportTemplates = @($resolution.reporting.templateNames | ForEach-Object {
    [string]$_
})
if ([string]$resolution.inlineControls.presentation.mode `
        -ne 'single-block-entry-combined-modal' `
        -or [int]$resolution.inlineControls.presentation.visibleControlCount -ne 1 `
        -or [int]$resolution.inlineControls.presentation.separateReportControlCount -ne 0 `
        -or ($resolvedModalActions -join "`n") -ne ($expectedModalActions -join "`n")) {
    throw 'Resolution must expose one Block entry and exactly one dynamic-positive plus Cancel combined modal.'
}
if ([string]$resolution.reporting.launchMode -ne 'single-combined-modal-durable-queue' `
        -or ($resolvedReportTemplates -join "`n") `
            -ne 'InlineReportActionFactory.smali.tmpl') {
    throw 'Resolution reporting must use the single combined modal, durable queue, and request-factory-only template.'
}
if ([string]$resolution.reporting.canonicalPermalinkPrefix `
            -ne 'https://www.threads.com/@' `
        -or [string]$resolution.reporting.permalinkPathMarker -ne '/post/' `
        -or [string]$resolution.reporting.acceptedLegacyPermalinkHost `
            -ne 'www.threads.net') {
    throw 'Resolution reporting must pin the current canonical Threads post-link format and the sole accepted legacy input host.'
}
$combinedModalStringsText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'assets\autoblock\java\threadsmod\inlinecontrol\InlineBlockStrings.java')
foreach ($requiredCombinedModalLiteral in @(
        'title = "Block and report"',
        'postExcerpt = "Post excerpt"',
        'reportReason = "Report reason"',
        'alsoBlockLabel = "Also block this profile"',
        'block = "Block"',
        'report = "Report"')) {
    if (-not $combinedModalStringsText.Contains(
            $requiredCombinedModalLiteral, [StringComparison]::Ordinal)) {
        throw "Combined modal copy is missing required literal '$requiredCombinedModalLiteral'."
    }
}
$forbiddenDexStrings = @($resolution.release.forbiddenDexStrings | ForEach-Object {
    ([string]$_).ToLowerInvariant()
})
if ($forbiddenDexStrings -notcontains 'tree55.com') {
    throw 'Resolution must retain tree55.com as a case-insensitive final-DEX forbidden string.'
}
foreach ($removedInlineLiteral in @(
        'threadsmod_inline_report',
        'Safe processing',
        'Before exact review',
        'Block or report?',
        'Review report',
        'Review exact payload',
        'Consent and queue',
        'I consent to send exactly this report',
        'InlineReportClick',
        'ReportDialog',
        'ui_one_click_block',
        'ui_dismiss_after_block')) {
    if ($forbiddenDexStrings -notcontains $removedInlineLiteral) {
        throw "Resolution must forbid the removed inline/modal literal '$removedInlineLiteral' in final DEX."
    }
}
$ambiguousReportSubstring = 'send report'
$pristineReportCollisionFixture = 'Send reports blocking'
if ($pristineReportCollisionFixture.IndexOf(
        $ambiguousReportSubstring, [StringComparison]::OrdinalIgnoreCase) -lt 0 `
        -or $forbiddenDexStrings -contains $ambiguousReportSubstring) {
    throw 'Ambiguous Send report broad substring must stay excluded because it collides with pristine Send reports blocking.'
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
        -or $forbiddenDexStrings -contains $ambiguousSocksPortSubstring `
        -or $socksPortCollisionProof.Count -ne 1 `
        -or [string]$socksPortCollisionProof[0].path `
            -cne $expectedSocksPortCollisionPath `
        -or [string]$socksPortCollisionProof[0].contains `
            -ne '.method public final declared-synchronized getSocksProxyPort()I' `
        -or [int]$socksPortCollisionProof[0].minimumCount -ne 1) {
    throw 'Ambiguous socksProxyPort broad substring must stay excluded and bound to the exact pristine getSocksProxyPort method.'
}
foreach ($retiredProfileLookupLiteral in @(
        'lookup_failure',
        'lookup_busy',
        'UserFetchCallback',
        'signed_list_block_failed')) {
    if ($forbiddenDexStrings -notcontains $retiredProfileLookupLiteral) {
        throw "Resolution must forbid retired profile-info lookup artifact '$retiredProfileLookupLiteral' in final DEX."
    }
}
$assetExclusionPaths = @($resolution.release.assetPreservationExclusions | ForEach-Object {
    [string]$_.path
})
if (@($assetExclusionPaths | Sort-Object -Unique).Count -ne $assetExclusionPaths.Count) {
    throw 'Resolution asset-preservation exclusions must name unique exact files.'
}
foreach ($exclusion in @($resolution.release.assetPreservationExclusions)) {
    $path = [string]$exclusion.path
    if (-not $path.StartsWith('assets/', [StringComparison]::Ordinal) `
            -or $path.Contains('*', [StringComparison]::Ordinal) `
            -or $path.Contains('?', [StringComparison]::Ordinal) `
            -or -not $path.EndsWith('.dex', [StringComparison]::Ordinal) `
            -or [string]$exclusion.replacementGate -ne 'dex-header-integrity') {
        throw "Asset-preservation exclusion is not an exact generated DEX with a replacement gate: $path"
    }
}
$jadxTargetNames = @($resolution.release.targetedJadxClasses | ForEach-Object {
    [string]$_.className
})
if (@($jadxTargetNames | Sort-Object -Unique).Count -ne $jadxTargetNames.Count) {
    throw 'Resolution targeted JADX classes must be unique by className.'
}
$commonJadxTargetNames = @(
    'com.threadsmod.CloneBlockerActivity',
    'threadsmod.bootstrap.ModBootstrap',
    'threadsmod.autoblock.ThreadsBlockBridge',
    'threadsmod.autoblock.BlockDiagnostic',
    'threadsmod.inlinecontrol.InlineActionRowAdapter',
    'threadsmod.inlinecontrol.InlineActionClick',
    'threadsmod.inlinecontrol.InlineVisibilityCallback',
    'threadsmod.inlinecontrol.InlineBlockController',
    'threadsmod.autoblock.AutoBlockSync',
    'threadsmod.autoblock.BlocklistStore',
    'threadsmod.autoblock.ModStateStore',
    'threadsmod.autoblock.CloneBlockerEndpoints',
    'threadsmod.autoblock.ObjectFetcher',
    'threadsmod.autoblock.ChunkInstaller',
    'threadsmod.reporting.InlineReportActionFactory',
    'threadsmod.reporting.ReportController',
    'threadsmod.reporting.ReportPayload',
    'threadsmod.reporting.ReportStore',
    'threadsmod.reporting.ReportValues',
    'threadsmod.reporting.ReportClient',
    'com.instagram.barcelona.app.BarcelonaAppShell',
    'com.threadsmod.ProxySettingsActivity',
    'threadsmod.proxy.ProxyBootstrap',
    'threadsmod.proxy.ProxyConfig',
    'threadsmod.proxy.ProxyBypassPolicy',
    'threadsmod.proxy.ProxyConfigStore',
    'threadsmod.proxy.ProxyController',
    'threadsmod.proxy.ProxyRoutePlanner',
    'threadsmod.proxy.Socks5VpnService',
    'threadsmod.update.UpdateController',
    'threadsmod.update.UpdateEndpoints',
    'threadsmod.update.UpdateJson',
    'threadsmod.update.UpdateManifest',
    'threadsmod.update.UpdateSignature',
    'threadsmod.update.UpdateStore'
)
$sourceVersionName = [string]$resolution.source.versionName
if ($sourceVersionName -ceq '415.0.0.26.77') {
    $reviewedHostJadxTargetNames = @('X.0MO', 'X.0sC')
    $reviewedInlineHostClass = 'X.0sC'
    $reviewedInlineSnapshotHostClass = 'X.0sC'
    $reviewedPermalinkJadxCall = 'Bwc()'
    $reviewedPermalinkMethod = 'LX/7A4;->Bwc()Ljava/lang/String;'
    $reviewedCacheBridgeSymbols = [ordered]@{
        userCacheFactoryMethod = 'LX/2gx;->A00(Lcom/instagram/common/session/UserSession;)LX/2gy;'
        userCacheGetOrPutMethod = 'LX/2gy;->A02(LX/2fh;Ljava/lang/String;)LX/2fp;'
    }
    $reviewedCacheFactoryJadxChain = '.A00(userSession).A02(null,'
    $reviewedCacheGetOrPutJadxCall = '.A02(null,'
    $reviewedVisibilityAttachedJadxCall = 'Cku()'
    $reviewedVisibilityRectEmptyJadxCall = 'A0A()'
    $reviewedVisibilityJadxCallCounts = [ordered]@{
        'AutoBlockSync.registerVisibleControl(this,' = 2
        'AutoBlockSync.updateVisibleControl(this,' = 1
        'AutoBlockSync.unregisterVisibleControl(this)' = 1
    }
} elseif ($sourceVersionName -ceq '444.0.0.45.85') {
    $reviewedHostJadxTargetNames = @('X.02Gf', 'X.00sD', 'X.03gS', 'X.03ga')
    $reviewedInlineHostClass = 'X.03ga'
    $reviewedInlineSnapshotHostClass = 'X.03gS'
    $reviewedPermalinkJadxCall = 'A7o()'
    $reviewedPermalinkMethod = `
        'Lcom/instagram/feed/media/Media;->A7o()Ljava/lang/String;'
    $reviewedCacheBridgeSymbols = [ordered]@{
        userCacheFactoryMethod = 'Lcom/instagram/user/model/UserCache;->A00(Lcom/instagram/common/session/UserSession;)Lcom/instagram/user/model/UserCache;'
        userCacheGetOrPutMethod = 'Lcom/instagram/user/model/UserCache;->A05(LX/02ft;Ljava/lang/String;)Lcom/instagram/user/model/User;'
    }
    $reviewedCacheFactoryJadxChain = '.A00(userSession).A05(null,'
    $reviewedCacheGetOrPutJadxCall = '.A05(null,'
    $reviewedVisibilityAttachedJadxCall = 'D4A()'
    $reviewedVisibilityRectEmptyJadxCall = 'A07()'
    $reviewedVisibilityJadxCallCounts = [ordered]@{
        'AutoBlockSync.registerVisibleControl(this,' = 2
        'AutoBlockSync.updateVisibleControl(this,' = 1
        'AutoBlockSync.unregisterVisibleControl(this)' = 3
    }
} else {
    throw "No exact release-gate host layout is reviewed for '$sourceVersionName'."
}
$expectedJadxTargetNames = @(
    'com.instagram.barcelona.mainactivity.BarcelonaActivity'
) + $reviewedHostJadxTargetNames + $commonJadxTargetNames
if ($jadxTargetNames.Count -ne $expectedJadxTargetNames.Count `
        -or ($jadxTargetNames -join "`n") -ne ($expectedJadxTargetNames -join "`n")) {
    throw "Resolution targeted JADX classes must equal the exact ordered reviewed set for '$sourceVersionName'."
}
$updateJadxRequirements = [ordered]@{
    'threadsmod.update.UpdateController' = @(
        'CURRENT_MOD_BUILD',
        'app.tree55.threads',
        'app.tree55.threads.fileprovider',
        'downloadAuthorizedActivity = new WeakReference<>(activity)',
        'new Intent("android.intent.action.VIEW")',
        'application/vnd.android.package-archive')
    'threadsmod.update.UpdateEndpoints' = @(
        $expectedUpdateMetadataEndpoints[0],
        $expectedUpdateMetadataEndpoints[1],
        $expectedUpdateMetadataEndpoints[2],
        'release-assets.githubusercontent.com',
        '^[a-z0-9]{1,63}\\.cloudfront\\.net$')
    'threadsmod.update.UpdateJson' = @('CodingErrorAction.REPORT', 'isCompleteObject(')
    'threadsmod.update.UpdateManifest' = @(
        'threadsmod-app-update',
        'UpdateSignature.verifyProduction(',
        'sameSignedRelease(',
        'sameBinary(')
    'threadsmod.update.UpdateSignature' = @(
        'fYcRAV8CRof15IAinUoDOZuBbqqDtDXDPl3lwSLoMhk',
        'verifyWithKey(',
        'isCanonicalScalar(')
    'threadsmod.update.UpdateStore' = @(
        'update_verified_envelope',
        'update rollback floors are corrupt',
        'instanceof Long',
        '.commit()')
}
foreach ($updateClassName in $updateJadxRequirements.Keys) {
    $matches = @($resolution.release.targetedJadxClasses | Where-Object {
            [string]$_.className -ceq $updateClassName
        })
    if ($matches.Count -ne 1) {
        throw "Resolution must target updater class exactly once: $updateClassName"
    }
    $requiredStrings = @($matches[0].requiredStrings | ForEach-Object { [string]$_ })
    foreach ($requiredString in $updateJadxRequirements[$updateClassName]) {
        if ($requiredStrings -notcontains $requiredString) {
            throw "Updater JADX contract '$updateClassName' omits '$requiredString'."
        }
    }
}
foreach ($updateFinalDexMarker in @(
        'threadsmod-app-update',
        'Required update',
        'application/vnd.android.package-archive')) {
    if (@($resolution.release.requiredHookCalls | Where-Object {
                [string]$_ -ceq $updateFinalDexMarker
            }).Count -ne 1) {
        throw "Updater general final-DEX marker is not required exactly once: $updateFinalDexMarker"
    }
}
if (@($resolution.release.requiredHookCalls | Where-Object {
            [string]$_ -ceq [string]$resolution.update.requestInstallPermission
        }).Count -ne 0) {
    throw 'Manifest-only updater permission must not be required as a general final-DEX marker.'
}
foreach ($retiredTarget in @(
        'threadsmod.reporting.InlineReportClick',
        'threadsmod.reporting.ReportDialog')) {
    if ($jadxTargetNames -contains $retiredTarget) {
        throw "Resolution still targets retired report UI class: $retiredTarget"
    }
}
$inlineHostTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -ceq $reviewedInlineHostClass
    })
$inlineSnapshotHostTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -ceq $reviewedInlineSnapshotHostClass
    })
$reportFactoryTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.reporting.InlineReportActionFactory'
    })
$reportControllerTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.reporting.ReportController'
    })
$reportStoreTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.reporting.ReportStore'
    })
$reportPayloadTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.reporting.ReportPayload'
    })
$reportValuesTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.reporting.ReportValues'
    })
$reportFactoryPermalinkCount = if ($reportFactoryTarget.Count -eq 1) {
    $property = $reportFactoryTarget[0].exactStringCounts.PSObject.Properties[
        $reviewedPermalinkJadxCall]
    if ($null -eq $property) { -1 } else { [int]$property.Value }
} else { -1 }
if ($inlineHostTarget.Count -ne 1 `
        -or [int]$inlineHostTarget[0].exactStringCounts.'InlineActionRowAdapter.render(' -ne 1 `
        -or $reportFactoryTarget.Count -ne 1 `
        -or [int]$reportFactoryTarget[0].exactStringCounts.'new ReportRequest(' -ne 1 `
        -or $reportFactoryPermalinkCount -ne 1 `
        -or [int]$reportFactoryTarget[0].exactStringCounts.'getPermalink()' -ne 1 `
        -or $reportControllerTarget.Count -ne 1 `
        -or [int]$reportControllerTarget[0].exactStringCounts.'ReportClient.queueExplicit(' -ne 1 `
        -or [int]$reportControllerTarget[0].exactStringCounts.'isValidForNewQueue()' -ne 1 `
        -or $reportPayloadTarget.Count -ne 1 `
        -or $reportValuesTarget.Count -ne 1 `
        -or [int]$reportValuesTarget[0].exactStringCounts.'httpsThreadsPermalink(' -ne 1 `
        -or $reportStoreTarget.Count -ne 1) {
    throw 'Resolution does not bind the signed-Dex single-control, permalink request factory, payload, durable report queue, and store contracts.'
}
$reportClientTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.reporting.ReportClient'
})
$bridgeTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.autoblock.ThreadsBlockBridge'
    })
$diagnosticTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.autoblock.BlockDiagnostic'
    })
$inlineAdapterTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.inlinecontrol.InlineActionRowAdapter'
    })
$inlineActionClickTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.inlinecontrol.InlineActionClick'
    })
$inlineVisibilityTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.inlinecontrol.InlineVisibilityCallback'
    })
$inlineControllerTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.inlinecontrol.InlineBlockController'
    })
$autoBlockTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.autoblock.AutoBlockSync'
    })
$blocklistStoreTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.autoblock.BlocklistStore'
    })
$modStateTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.autoblock.ModStateStore'
    })
$readEndpointTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.autoblock.CloneBlockerEndpoints'
    })
$reportingSymbolNames = @($resolution.reporting.symbols.PSObject.Properties.Name)
foreach ($forbiddenReportResolutionSymbol in @(
        'ufiConfigDescriptor', 'sessionDescriptor', 'ufiMediaIdField',
        'mediaLookupMethod', 'mediaAuthorMethod', 'authorIdMethod',
        'authorUsernameMethod')) {
    if ($reportingSymbolNames -contains $forbiddenReportResolutionSymbol) {
        throw "Report resolution duplicates the host-owned private row seam: $forbiddenReportResolutionSymbol"
    }
}
if ([string]$resolution.reporting.symbols.mediaPermalinkMethod `
        -cne $reviewedPermalinkMethod) {
    throw 'Report resolution does not bind the exact captured-media permalink accessor.'
}
if ([string]$resolution.bridge.symbols.authorIdMethod -ne `
        [string]$resolution.inlineControls.symbols.authorIdMethod) {
    throw 'Native bridge model-ID validation is not bound to the exact inline author-ID seam.'
}
foreach ($cacheBridgeSymbol in $reviewedCacheBridgeSymbols.Keys) {
    if ([string]$resolution.bridge.symbols.$cacheBridgeSymbol -ne `
            $reviewedCacheBridgeSymbols[$cacheBridgeSymbol]) {
        throw "Resolution cache-placeholder bridge symbol is absent or inexact: $cacheBridgeSymbol"
    }
}
$bridgeSymbolNames = @($resolution.bridge.symbols.PSObject.Properties.Name)
foreach ($retiredBridgeSymbol in @(
        'fetchSingletonField',
        'fetchDedupeField',
        'fetchByIdMethod',
        'fetchCallbackInterface',
        'fetchFailureCallback',
        'fetchSuccessCallback')) {
    if ($bridgeSymbolNames -contains $retiredBridgeSymbol) {
        throw "Resolution still binds a retired native profile-info lookup symbol: $retiredBridgeSymbol"
    }
}
$nativeCandidateExampleText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'ai\examples\415-native-candidate-inventory.json')
$nativeProposalExampleText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'ai\examples\415-native-proposal.example.json')
$nativeExampleText = $nativeCandidateExampleText + "`n" + $nativeProposalExampleText
foreach ($retiredExampleRole in @(
        'user-fetch-route-owner',
        'users/%s/info/',
        'candidate-fetch')) {
    if ($nativeExampleText.Contains($retiredExampleRole, [StringComparison]::Ordinal)) {
        throw "Native bridge AI example retains retired profile-fetch authority: $retiredExampleRole"
    }
}
foreach ($requiredCurrentExampleRole in @(
        'user-cache-factory-owner',
        'user-cache-get-or-put-owner',
        'model-id-accessor-owner',
        'mutation-callback-interface-owner',
        'block-mutation-route-owner')) {
    if ((Get-PatchletLiteralCount -Text $nativeCandidateExampleText `
                -Literal ('"' + $requiredCurrentExampleRole + '"')) -lt 2 `
            -or (Get-PatchletLiteralCount -Text $nativeProposalExampleText `
                -Literal ('"' + $requiredCurrentExampleRole + '"')) -ne 1) {
        throw "Native bridge AI examples do not bind current reviewed role: $requiredCurrentExampleRole"
    }
}
$resolutionProofIds = @($resolution.proofs | ForEach-Object { [string]$_.id })
foreach ($requiredCacheProof in @(
        'cache-lookup-signature',
        'user-cache-factory-signature',
        'user-cache-get-or-put-signature',
        'user-cache-get-or-put-placeholder-factory',
        'user-cache-placeholder-model-construction',
        'user-cache-placeholder-session-initialization',
        'user-cache-null-seed-user-id-callsite',
        'bridge-model-id',
        'mutation-pre-start-guard-topology',
        'inline-host-author-username')) {
    if (@($resolutionProofIds | Where-Object { $_ -eq $requiredCacheProof }).Count -ne 1) {
        throw "Resolution does not contain exactly one reviewed cache/identity proof '$requiredCacheProof'."
    }
}
$nullSeedCallsiteProof = @($resolution.proofs | Where-Object {
        [string]$_.id -ceq 'user-cache-null-seed-user-id-callsite'
    })
if ($nullSeedCallsiteProof.Count -ne 1) {
    throw 'Resolution must contain exactly one null-seed user-ID callsite proof.'
}
$nullSeedCallsiteProof = $nullSeedCallsiteProof[0]
$nullSeedProofProperties = @($nullSeedCallsiteProof.PSObject.Properties.Name)
if ([string]$resolution.source.versionName -ceq '444.0.0.45.85') {
    $expectedCollisionProofProperties = @(
        'id',
        'candidatePaths',
        'targetClassDescriptor',
        'siblingClassDescriptor',
        'contains',
        'minimumCount'
    )
    $expectedCollisionCandidatePaths = @(
        'smali/X/02ja.smali',
        'smali/X/02ja.1.smali'
    )
    if ($nullSeedProofProperties.Count -ne $expectedCollisionProofProperties.Count `
            -or @($expectedCollisionProofProperties | Where-Object {
                    -not ($nullSeedProofProperties -ccontains $_)
                }).Count -ne 0 `
            -or (@($nullSeedCallsiteProof.candidatePaths | ForEach-Object {
                        [string]$_
                    }) -join "`n") -cne ($expectedCollisionCandidatePaths -join "`n") `
            -or [string]$nullSeedCallsiteProof.targetClassDescriptor -cne 'LX/02ja;' `
            -or [string]$nullSeedCallsiteProof.siblingClassDescriptor -cne 'LX/02jA;' `
            -or [string]$nullSeedCallsiteProof.contains -cne `
                'invoke-virtual {v2, v0, v3}, Lcom/instagram/user/model/UserCache;->A05(LX/02ft;Ljava/lang/String;)Lcom/instagram/user/model/User;' `
            -or [int]$nullSeedCallsiteProof.minimumCount -ne 1) {
        throw 'Threads 444 null-seed proof must use the exact descriptor-bound two-candidate collision mapping.'
    }
} elseif ([string]$resolution.source.versionName -ceq '415.0.0.26.77') {
    $expectedOrdinaryProofProperties = @('id', 'path', 'contains', 'minimumCount')
    if ($nullSeedProofProperties.Count -ne $expectedOrdinaryProofProperties.Count `
            -or @($expectedOrdinaryProofProperties | Where-Object {
                    -not ($nullSeedProofProperties -ccontains $_)
                }).Count -ne 0 `
            -or [string]$nullSeedCallsiteProof.path `
                -cne 'smali_classes4/X/3Oy.1.smali' `
            -or [int]$nullSeedCallsiteProof.minimumCount -ne 1) {
        throw 'Threads 415 null-seed proof must retain its exact ordinary-path semantics.'
    }
} else {
    throw 'No reviewed null-seed callsite proof layout exists for this source version.'
}
if ($bridgeTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX ThreadsBlockBridge contract.'
}
$bridgeRequiredStrings = @($bridgeTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredBridgeRecovery in @(
        'passivePreflight(',
        $reviewedCacheFactoryJadxChain,
        $reviewedCacheGetOrPutJadxCall,
        'new MutationCallback(',
        'model_id_mismatch',
        'placeholder_model_invalid',
        'session_model_exception',
        'cache_lookup_exception',
        'cache_factory_exception',
        'cache_placeholder_exception',
        'bridge_dispatch_exception',
        'model_id_exception',
        'already_blocked_exception',
        'mutation_exception',
        'already_blocked_success')) {
    if ($bridgeRequiredStrings -notcontains $requiredBridgeRecovery) {
        throw "ThreadsBlockBridge targeted recovery is missing cache-placeholder proof '$requiredBridgeRecovery'."
    }
}
$bridgeForbiddenStrings = @($bridgeTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
foreach ($retiredBridgeRecovery in @(
        'UserFetchCallback', 'lookup_failure', 'lookup_busy', 'users/%s/info/',
        'Not initialized variable reg:', 'strOnBridgeFailure')) {
    if ($bridgeForbiddenStrings -notcontains $retiredBridgeRecovery) {
        throw "ThreadsBlockBridge targeted recovery does not forbid '$retiredBridgeRecovery'."
    }
}
$bridgeFactoryChainCount = $bridgeTarget[0].exactStringCounts.PSObject.Properties[
    $reviewedCacheFactoryJadxChain]
$bridgeGetOrPutCount = $bridgeTarget[0].exactStringCounts.PSObject.Properties[
    $reviewedCacheGetOrPutJadxCall]
if ($null -eq $bridgeFactoryChainCount `
        -or [int]$bridgeFactoryChainCount.Value -ne 2 `
        -or $null -eq $bridgeGetOrPutCount `
        -or [int]$bridgeGetOrPutCount.Value -ne 2) {
    throw 'ThreadsBlockBridge targeted recovery does not pin the two readable preflight/mutation factory/getOrPut chains.'
}
foreach ($fixedBridgeStage in @(
        'session_model_exception', 'cache_lookup_exception', 'cache_factory_exception',
        'cache_placeholder_exception', 'bridge_dispatch_exception', 'model_id_exception',
        'already_blocked_exception', 'mutation_exception')) {
    $expectedBridgeStageCount = if ($fixedBridgeStage -eq 'session_model_exception') {
        3
    } elseif ($fixedBridgeStage -in @(
            'cache_lookup_exception', 'cache_factory_exception',
            'cache_placeholder_exception', 'bridge_dispatch_exception')) {
        2
    } else {
        1
    }
    if ([int]$bridgeTarget[0].exactStringCounts.$fixedBridgeStage -ne $expectedBridgeStageCount) {
        throw "ThreadsBlockBridge targeted recovery does not pin exactly $expectedBridgeStageCount '$fixedBridgeStage' handler(s)."
    }
}
if ([int]$bridgeTarget[0].exactStringCounts.already_blocked_success -ne 2) {
    throw 'ThreadsBlockBridge targeted recovery does not pin the two preparation/success sentinel uses.'
}
$bridgeOrderedStrings = @($bridgeTarget[0].orderedStrings | ForEach-Object { [string]$_ })
if (($bridgeOrderedStrings -join "`n") -ne (
        @($reviewedCacheFactoryJadxChain, '"placeholder_model_invalid"', 'blockModel(', 'new MutationCallback(') -join "`n")) {
    throw 'ThreadsBlockBridge targeted recovery does not preserve placeholder, dispatch, and mutation ordering.'
}
if ($diagnosticTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX BlockDiagnostic contract.'
}
$diagnosticRequiredStrings = @($diagnosticTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredDiagnosticRecovery in @(
        'CB-BRG-106', 'CB-BRG-107', 'CB-BRG-108', 'CB-BRG-109', 'CB-BRG-110', 'CB-BRG-111',
        'CB-BRG-112', 'CB-BRG-113',
        'placeholder_model_invalid', 'session_model_exception', 'cache_lookup_exception',
        'cache_factory_exception', 'cache_placeholder_exception', 'bridge_dispatch_exception',
        'model_id_exception', 'already_blocked_exception',
        'bridge=r6', 'mirror=n/a', 'route=', 'mutation=', 'retry=')) {
    if ($diagnosticRequiredStrings -notcontains $requiredDiagnosticRecovery) {
        throw "BlockDiagnostic targeted recovery is missing closed diagnostic proof '$requiredDiagnosticRecovery'."
    }
}
$diagnosticForbiddenStrings = @($diagnosticTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
foreach ($retiredDiagnosticLiteral in @(
        'lookup_failure', 'lookup_busy', 'UserFetchCallback', 'signed_list_block_failed')) {
    if ($diagnosticForbiddenStrings -notcontains $retiredDiagnosticLiteral) {
        throw "BlockDiagnostic targeted recovery does not forbid '$retiredDiagnosticLiteral'."
    }
}
if ($inlineHostTarget.Count -ne 1 -or $inlineSnapshotHostTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX inline action host and one exact-version snapshot host contract.'
}
$inlineSnapshotHostRequiredStrings = @(
    $inlineSnapshotHostTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredInlineSnapshotRecovery in @(
        'threadsmodResolveAuthorSnapshot(',
        'InlineBlockRequest.createHostBound(')) {
    if ($inlineSnapshotHostRequiredStrings -notcontains $requiredInlineSnapshotRecovery) {
        throw "Inline snapshot host targeted recovery is missing proof '$requiredInlineSnapshotRecovery'."
    }
}
$inlineHostRequiredStrings = @(
    $inlineHostTarget[0].requiredStrings | ForEach-Object { [string]$_ })
if ($inlineHostRequiredStrings -notcontains 'InlineActionRowAdapter.render(') {
    throw 'Inline action host targeted recovery is missing the sole render proof.'
}
if ([int]$inlineSnapshotHostTarget[0].exactStringCounts.'InlineBlockRequest.createHostBound(' -ne 1 `
        -or [int]$inlineHostTarget[0].exactStringCounts.'InlineActionRowAdapter.render(' -ne 1) {
    throw 'Inline targeted recovery does not pin one snapshot construction and one action-row render.'
}
$inlineHostForbiddenStrings = @($inlineHostTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
foreach ($forbiddenInlineHostRecovery in @(
        'InlineReportRowAdapter.render(')) {
    if ($inlineHostForbiddenStrings -notcontains $forbiddenInlineHostRecovery) {
        throw "Inline host targeted recovery does not forbid '$forbiddenInlineHostRecovery'."
    }
}
if ($inlineAdapterTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX InlineActionRowAdapter snapshot consumer contract.'
}
$inlineAdapterRequiredStrings = @($inlineAdapterTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredInlineAdapterRecovery in @(
        'getAuthorId()',
        'getLabel()',
        'getResolvedAuthorModel()',
        'InlineReportActionFactory.createRequest(')) {
    if ($inlineAdapterRequiredStrings -notcontains $requiredInlineAdapterRecovery `
            -or [int]$inlineAdapterTarget[0].exactStringCounts.$requiredInlineAdapterRecovery -ne 1) {
        throw "InlineActionRowAdapter targeted recovery does not pin exactly one snapshot consumer '$requiredInlineAdapterRecovery'."
    }
}
foreach ($requiredInlineDiagnosticRecovery in ([ordered]@{
        # The raw adapter has four invokes. JADX 1.5.6 duplicates the shared
        # report_request_unavailable block at its two recovered predecessors,
        # so the signed recovered source deterministically contains five calls.
        'AutoBlockSync.recordInlineRenderStage(' = 5
        'hook_seen' = 1
        'button_rendered' = 1
        'report_request_unavailable' = 2
        'adapter_exception' = 1
    }).GetEnumerator()) {
    if ($inlineAdapterRequiredStrings -notcontains $requiredInlineDiagnosticRecovery.Key `
            -or [int]$inlineAdapterTarget[0].exactStringCounts.PSObject.Properties[
                $requiredInlineDiagnosticRecovery.Key].Value -ne `
                [int]$requiredInlineDiagnosticRecovery.Value) {
        throw "InlineActionRowAdapter targeted recovery does not pin diagnostic '$($requiredInlineDiagnosticRecovery.Key)'."
    }
}
$inlineAdapterForbiddenStrings = @($inlineAdapterTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
foreach ($forbiddenInlineAdapterRecovery in @(
        '.getId()',
        'AnonymousClass023.A0e(',
        'AnonymousClass021.A0z(',
        'AnonymousClass021.A1B(',
        'AnonymousClass2GB.A0M(',
        'AutoBlockSync.getCurrentViewer(')) {
    if ($inlineAdapterForbiddenStrings -notcontains $forbiddenInlineAdapterRecovery) {
        throw "InlineActionRowAdapter targeted recovery does not forbid private row resolution '$forbiddenInlineAdapterRecovery'."
    }
}
if ($inlineVisibilityTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX memory-only viewport callback contract.'
}
$inlineVisibilityRequiredStrings = @(
    $inlineVisibilityTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredVisibilityRecovery in @(
        'AutoBlockSync.registerVisibleControl(this,',
        'AutoBlockSync.updateVisibleControl(this,',
        'AutoBlockSync.unregisterVisibleControl(this)',
        $reviewedVisibilityAttachedJadxCall,
        $reviewedVisibilityRectEmptyJadxCall)) {
    if ($inlineVisibilityRequiredStrings -notcontains $requiredVisibilityRecovery) {
        throw "InlineVisibilityCallback targeted recovery is missing viewport proof '$requiredVisibilityRecovery'."
    }
}
$inlineVisibilityForbiddenStrings = @(
    $inlineVisibilityTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
foreach ($forbiddenVisibilityRecovery in @(
        'BlocklistStore',
        'ThreadsBlockBridge',
        'SharedPreferences',
        'SQLite')) {
    if ($inlineVisibilityForbiddenStrings -notcontains $forbiddenVisibilityRecovery) {
        throw "InlineVisibilityCallback targeted recovery does not forbid non-memory authority '$forbiddenVisibilityRecovery'."
    }
}
if ($inlineAdapterRequiredStrings -notcontains 'new InlineVisibilityCallback(' `
        -or [int]$inlineAdapterTarget[0].exactStringCounts.'new InlineVisibilityCallback(' -ne 1) {
    throw 'InlineActionRowAdapter targeted recovery does not pin exactly one viewport observer.'
}
if ($reportFactoryTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX InlineReportActionFactory snapshot consumer contract.'
}
$reportFactoryRequiredStrings = @($reportFactoryTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredReportFactoryRecovery in @(
        'getAuthorId()',
        'getLabel()',
        'getResolvedMediaModel()',
        'new ReportRequest(')) {
    if ($reportFactoryRequiredStrings -notcontains $requiredReportFactoryRecovery `
            -or [int]$reportFactoryTarget[0].exactStringCounts.$requiredReportFactoryRecovery -ne 1) {
        throw "InlineReportActionFactory targeted recovery does not pin exactly one snapshot consumer '$requiredReportFactoryRecovery'."
    }
}
if ($sourceVersionName -ceq '444.0.0.45.85') {
    foreach ($requiredCurrentReportFactoryRecovery in ([ordered]@{
            'A75()' = 1
            'A7o()' = 1
            'ReportRequest.resolveHostPermalink(' = 2
            'ReportRequest.resolveHostExcerpt(' = 1
        }).GetEnumerator()) {
        if ($reportFactoryRequiredStrings -notcontains $requiredCurrentReportFactoryRecovery.Key `
                -or [int]$reportFactoryTarget[0].exactStringCounts.PSObject.Properties[
                    $requiredCurrentReportFactoryRecovery.Key].Value -ne `
                    [int]$requiredCurrentReportFactoryRecovery.Value) {
            throw "Current InlineReportActionFactory targeted recovery does not pin '$($requiredCurrentReportFactoryRecovery.Key)'."
        }
    }
}
$reportFactoryForbiddenStrings = @($reportFactoryTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
foreach ($forbiddenReportFactoryRecovery in @(
        'threadsmod_inline_report',
        'InlineReportRowAdapter.render(',
        '.getId()',
        'AnonymousClass023.A0e(',
        'AnonymousClass021.A0z(',
        'AnonymousClass021.A1B(',
        'AutoBlockSync.getCurrentViewer(')) {
    if ($reportFactoryForbiddenStrings -notcontains $forbiddenReportFactoryRecovery) {
        throw "InlineReportActionFactory targeted recovery does not forbid private row resolution '$forbiddenReportFactoryRecovery'."
    }
}
if ($inlineActionClickTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX InlineActionClick combined-controller handoff contract.'
}
$inlineActionClickRequiredStrings = @($inlineActionClickTarget[0].requiredStrings | ForEach-Object {
    [string]$_
})
foreach ($requiredInlineActionClickRecovery in @(
        'getResolvedAuthorModel()',
        'InlineBlockController.onClick(')) {
    if ($inlineActionClickRequiredStrings -notcontains $requiredInlineActionClickRecovery) {
        throw "InlineActionClick targeted recovery is missing '$requiredInlineActionClickRecovery'."
    }
}
if ($inlineControllerTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX InlineBlockController combined-submit contract.'
}
$inlineControllerRequiredStrings = @($inlineControllerTarget[0].requiredStrings | ForEach-Object {
    [string]$_
})
foreach ($requiredInlineControllerRecovery in @(
        'getResolvedAuthorModel()',
        'ReportController.queueFromForeground(',
        'AutoBlockSync.enqueueManual(',
        'AutoBlockSync.recordInlinePreEnqueueFailure(')) {
    if ($inlineControllerRequiredStrings -notcontains $requiredInlineControllerRecovery) {
        throw "InlineBlockController targeted recovery is missing '$requiredInlineControllerRecovery'."
    }
}
if ([int]$inlineControllerTarget[0].exactStringCounts.'ReportController.queueFromForeground(' -ne 1 `
        -or [int]$inlineControllerTarget[0].exactStringCounts.'AutoBlockSync.enqueueManual(' -ne 1 `
        -or $autoBlockTarget.Count -ne 1 `
        -or [int]$autoBlockTarget[0].exactStringCounts.'ThreadsBlockBridge.blockResolved(' -ne 1 `
        -or $readEndpointTarget.Count -ne 1) {
    throw 'Resolution targeted JADX contracts do not pin one durable Report handoff, optional scheduler Block handoff, and resolved-author bridge handoff.'
}
$passiveAutoBlockRequiredStrings = @(
    $autoBlockTarget[0].requiredStrings | ForEach-Object { [string]$_ })
$reviewedPassiveJadxWrapperAutoBlockStrings = @(
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
$resolvedPassiveJadxWrapperAutoBlockStrings = @(
    $resolution.release.requiredPassiveJadxWrapperAutoBlockStrings |
        ForEach-Object { [string]$_ })
if (($resolvedPassiveJadxWrapperAutoBlockStrings -join "`n") -cne `
        ($reviewedPassiveJadxWrapperAutoBlockStrings -join "`n") `
        -or @($reviewedPassiveJadxWrapperAutoBlockStrings | Where-Object {
                $passiveAutoBlockRequiredStrings -notcontains $_
            }).Count -ne 0) {
    throw 'Resolution passive JADX wrapper baseline must exactly bind the reviewed AutoBlockSync strings and targeted recovery metadata.'
}
$reviewedPassiveInvalidGenerationJadxCounts = [ordered]@{
    'latchPassiveStorePause(context, str, idMatchLookupId.generation)' = 1
    'threadsmod.autoblock.AutoBlockSync.latchPassiveStorePause(r8.context, r4, r2.generation)' = 1
    'latchPassiveStorePause(context, str, idMatchIsCurrentIdMatch.generation)' = 1
}
$reviewedPassiveJadxAliasCounts = [ordered]@{
    'if (j <= 0 || !snapshot.valid || snapshot.generation <= j)' = 1
    'if (passiveStorePaused && j > passiveStorePauseGeneration)' = 1
    'Map<String, ?> all = sharedPreferences.getAll()' = 2
    'readDeadline(prefs(context), KEY_LIST_REFRESH_NOT_BEFORE, j, MAX_LIST_REFRESH_DEADLINE_FUTURE_MS)' = 1
}
$obsoletePassiveJadxSourceLocals = @(
    'observedGeneration > 0L',
    'current.generation > observedGeneration',
    'Map<String, ?> values = preferences.getAll()',
    'prefs(context), KEY_LIST_REFRESH_NOT_BEFORE, now',
    'platform.length() == 0 || !platform.equals(platform.trim())',
    'if (!"threads".equals(platform))')
$resolvedPassiveInvalidGenerationRequiredStrings = @(
    $passiveAutoBlockRequiredStrings | Where-Object {
        $_.IndexOf('latchPassiveStorePause', [StringComparison]::Ordinal) -ge 0 `
            -and $_.IndexOf('.generation', [StringComparison]::Ordinal) -ge 0
    })
$resolvedPassiveInvalidGenerationCountProperties = @(
    $autoBlockTarget[0].exactStringCounts.PSObject.Properties | Where-Object {
        $_.Name.IndexOf('latchPassiveStorePause', [StringComparison]::Ordinal) -ge 0 `
            -and $_.Name.IndexOf('.generation', [StringComparison]::Ordinal) -ge 0
    })
if (($resolvedPassiveInvalidGenerationRequiredStrings -join "`n") -cne `
        (@($reviewedPassiveInvalidGenerationJadxCounts.Keys) -join "`n") `
        -or ($resolvedPassiveInvalidGenerationCountProperties.Name -join "`n") -cne `
            (@($reviewedPassiveInvalidGenerationJadxCounts.Keys) -join "`n")) {
    throw 'AutoBlockSync targeted recovery does not bind the exact three-path invalid-generation JADX tuple.'
}
foreach ($reviewedPassiveInvalidGenerationJadxLiteral in `
        $reviewedPassiveInvalidGenerationJadxCounts.Keys) {
    if ([int]$autoBlockTarget[0].exactStringCounts.PSObject.Properties[
                $reviewedPassiveInvalidGenerationJadxLiteral].Value -ne 1) {
        throw "AutoBlockSync targeted recovery invalid-generation count drifted: $reviewedPassiveInvalidGenerationJadxLiteral"
    }
}
foreach ($reviewedPassiveJadxAlias in $reviewedPassiveJadxAliasCounts.Keys) {
    if ($passiveAutoBlockRequiredStrings -notcontains $reviewedPassiveJadxAlias `
            -or [int]$autoBlockTarget[0].exactStringCounts.PSObject.Properties[
                $reviewedPassiveJadxAlias].Value -ne `
                [int]$reviewedPassiveJadxAliasCounts[$reviewedPassiveJadxAlias]) {
        throw "AutoBlockSync targeted recovery alias/count drifted: $reviewedPassiveJadxAlias"
    }
}
$passiveAutoBlockCountNames = @(
    $autoBlockTarget[0].exactStringCounts.PSObject.Properties.Name |
        ForEach-Object { [string]$_ })
foreach ($obsoletePassiveJadxSourceLocal in $obsoletePassiveJadxSourceLocals) {
    if ($passiveAutoBlockRequiredStrings -contains $obsoletePassiveJadxSourceLocal `
            -or $passiveAutoBlockCountNames -contains $obsoletePassiveJadxSourceLocal) {
        throw "AutoBlockSync targeted recovery retains impossible source-local spelling: $obsoletePassiveJadxSourceLocal"
    }
}
foreach ($requiredPassiveRuntimeRecovery in @(
        'BlocklistStore.replaceVerified(',
        'BlocklistStore.lookupId(',
        'BlocklistStore.isCurrentIdMatch(',
        'PASSIVE_ADMISSION_LOCK',
        'LIST_REFRESH_RUNNING.compareAndSet(false, true)',
        'postDelayed(LIST_REFRESH_WAKE',
        'new ListRefreshWorker(',
        'requestListForceRefresh(',
        'KEY_LIST_REFRESH_NOT_BEFORE',
        'LIST_REFRESH_DEADLINE_LOCK',
        'readListRefreshDeadline(',
        'advanceListRefreshDeadline(',
        'millisUntilNextListRefresh(',
        'isUsableBlocklistSnapshot(',
        'blocklist_refresh_worker_start_rejected',
        'public mirrors failed while a prior verified generation was retained',
        'Conditional fetch metadata will retry later.',
        'LIST_FORCE_REFRESH_VIEWERS',
        'doneIdsForScheduler(',
        'setDoneIds == null',
        'Completed-target state needs review; automatic work remains paused.',
        'new FetchWorker(',
        'loadTarget(',
        'finishAndResume(',
        'ThreadsBlockBridge.passivePreflight(',
        'handleAlreadyBlockedBeforeReservation(',
        'handlePreflightFailure(',
        'registerVisibleControl(',
        'updateVisibleControl(',
        'unregisterVisibleControl(',
        'PassiveAuthority',
        'currentPassiveAuthority(',
        'currentPassiveMatch(',
        'latchPassiveStorePause(',
        'clearPassiveStorePauseAfterVerifiedGeneration(',
        'visibleUsernameMatchesStored',
        'getListStatus(',
        'List fetch: ',
        'Records: ',
        'New this refresh: ',
        'Database index: ',
        'Inline control: ',
        'recordInlineRenderStage(',
        'hook_seen',
        'button_rendered',
        'report_request_unavailable',
        'adapter_exception')) {
    if ($passiveAutoBlockRequiredStrings -notcontains $requiredPassiveRuntimeRecovery) {
        throw "AutoBlockSync targeted recovery is missing passive runtime proof '$requiredPassiveRuntimeRecovery'."
    }
}
$passiveAutoBlockForbiddenStrings = @(
    $autoBlockTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
foreach ($forbiddenPassiveRuntimeRecovery in @(
        'encodeTargets(',
        'decodeTargets(',
        'verified.targetIds',
        'safeMessage(',
        'getMessage(',
        'getLocalizedMessage(',
        'printStackTrace(',
        'getStackTraceString(',
        'loadTargets(',
        'visibleIds',
        'private void next()',
        'hasForegroundRunCapacity(',
        'rateAllowed(',
        'millisUntilRateAllowed(',
        'automaticPerHour(',
        'targetBudget(',
        'totalPerHour(',
        'totalPerDay(',
        'maxPerRun(',
        'manualMinDelayMs(',
        'manualMaxDelayMs(',
        'admitForegroundPassiveTarget(',
        'removeForegroundPassiveTarget(',
        'targetBudgetAdded')) {
    if ($passiveAutoBlockForbiddenStrings -notcontains $forbiddenPassiveRuntimeRecovery) {
        throw "AutoBlockSync targeted recovery does not forbid alternate authority/error flow '$forbiddenPassiveRuntimeRecovery'."
    }
}
if ([int]$autoBlockTarget[0].exactStringCounts.'BlocklistStore.replaceVerified(' -ne 1 `
        -or [int]$autoBlockTarget[0].exactStringCounts.'BlocklistStore.isCurrentIdMatch(' -ne 1 `
        -or [int]$autoBlockTarget[0].exactStringCounts.'new BlockRun(' -ne 1 `
        -or [int]$autoBlockTarget[0].exactStringCounts.'ThreadsBlockBridge.passivePreflight(' -ne 1 `
        -or [int]$autoBlockTarget[0].exactStringCounts.'currentPassiveAuthority(' -ne 4 `
        -or [int]$autoBlockTarget[0].exactStringCounts.'currentPassiveMatch(' -ne 5) {
    throw 'AutoBlockSync targeted recovery does not pin one database replacement, tri-state generation guard, three final authority gates, passive preflight, and BlockRun construction.'
}
if ($blocklistStoreTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX indexed BlocklistStore contract.'
}
$chunkInstallerTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.autoblock.ChunkInstaller'
    })
$objectFetcherTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.autoblock.ObjectFetcher'
    })
if ($chunkInstallerTarget.Count -ne 1 -or $objectFetcherTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX ChunkInstaller and one ObjectFetcher contract.'
}
$chunkInstallerRequiredStrings = @(
    $chunkInstallerTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredChunkInstallerRecovery in @(
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
        'chunk exceeds the inflated byte cap',
        'group table is not the v3 threads group the root named',
        'threads:',
        'threads:@')) {
    if ($chunkInstallerRequiredStrings -notcontains $requiredChunkInstallerRecovery) {
        throw "ChunkInstaller targeted recovery is missing whole-chunk proof '$requiredChunkInstallerRecovery'."
    }
}
$chunkInstallerForbiddenStrings = @(
    $chunkInstallerTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
foreach ($forbiddenChunkInstallerRecovery in @(
        'safeMessage(', 'getMessage(', 'getLocalizedMessage(', 'printStackTrace(', 'getStackTraceString(',
        'HttpsURLConnection', 'setLenient', 'ThreadsBlockBridge', 'PASSIVE_ADMISSION_LOCK', 'replaceVerified(')) {
    if ($chunkInstallerForbiddenStrings -notcontains $forbiddenChunkInstallerRecovery) {
        throw "ChunkInstaller targeted recovery does not forbid '$forbiddenChunkInstallerRecovery'."
    }
}
$objectFetcherRequiredStrings = @(
    $objectFetcherTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredObjectFetcherRecovery in @(
        'CloneBlockerEndpoints.objectUrl(',
        'Accept-Encoding',
        'identity',
        'MessageDigest',
        'SHA-256',
        'signed root names an object whose bytes do not match',
        'object exceeds the local byte cap',
        'chunk byte count differs from the signed group entry')) {
    if ($objectFetcherRequiredStrings -notcontains $requiredObjectFetcherRecovery) {
        throw "ObjectFetcher targeted recovery is missing hash-before-return proof '$requiredObjectFetcherRecovery'."
    }
}
$objectFetcherForbiddenStrings = @(
    $objectFetcherTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
foreach ($forbiddenObjectFetcherRecovery in @(
        'safeMessage(', 'getMessage(', 'getLocalizedMessage(', 'printStackTrace(', 'getStackTraceString(',
        'JsonReader', 'GZIPInputStream', 'ThreadsBlockBridge', 'BlocklistStore')) {
    if ($objectFetcherForbiddenStrings -notcontains $forbiddenObjectFetcherRecovery) {
        throw "ObjectFetcher targeted recovery does not forbid '$forbiddenObjectFetcherRecovery'."
    }
}
$blocklistStoreRequiredStrings = @(
    $blocklistStoreTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredBlocklistStoreRecovery in @(
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
        'IdMatch',
        'normalizeUsername(',
        'Instant.parse(',
        'count(DISTINCT username_key)',
        'requireUniqueUsername(',
        'ALTER TABLE blocklist_metadata ADD COLUMN ',
        'blocklist database upgrade requires reviewed migration',
        'CREATE UNIQUE INDEX blocklist_targets_username_idx',
        'CREATE INDEX blocklist_targets_h32_idx',
        'CREATE TABLE blocklist_chunks (',
        'CREATE TABLE blocklist_groups (',
        'CREATE TABLE blocklist_staging (',
        'stageChunk(',
        'stagedShas(',
        'pruneStaging(',
        'readChunkTable(',
        'bucket_bits',
        'NOT EXISTS (SELECT 1 FROM blocklist_targets',
        'ALTER TABLE blocklist_targets RENAME TO blocklist_targets_v2',
        'ALTER TABLE blocklist_metadata RENAME TO blocklist_metadata_v2',
        'blocklist database v2 migration requires review')) {
    if ($blocklistStoreRequiredStrings -notcontains $requiredBlocklistStoreRecovery) {
        throw "BlocklistStore targeted recovery is missing indexed-store proof '$requiredBlocklistStoreRecovery'."
    }
}
$blocklistStoreForbiddenStrings = @(
    $blocklistStoreTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
foreach ($forbiddenBlocklistStoreRecovery in @(
        'encodeTargets(',
        'decodeTargets(',
        'ThreadsBlockBridge',
        'list_threads_targets',
        'DROP TABLE')) {
    if ($blocklistStoreForbiddenStrings -notcontains $forbiddenBlocklistStoreRecovery) {
        throw "BlocklistStore targeted recovery does not forbid alternate authority '$forbiddenBlocklistStoreRecovery'."
    }
}
if ([int]$blocklistStoreTarget[0].exactStringCounts.'CREATE INDEX blocklist_targets_username_idx' -ne 1 `
        -or [int]$blocklistStoreTarget[0].exactStringCounts.'CREATE UNIQUE INDEX blocklist_targets_username_idx' -ne 1 `
        -or [int]$blocklistStoreTarget[0].exactStringCounts.'stageChunk(' -ne 1 `
        -or [int]$blocklistStoreTarget[0].exactStringCounts.'replaceVerified(' -ne 1 `
        -or [int]$blocklistStoreTarget[0].exactStringCounts.'lookupId(' -ne 1 `
        -or [int]$blocklistStoreTarget[0].exactStringCounts.'isCurrentIdMatch(' -ne 1 `
        -or [int]$blocklistStoreTarget[0].exactStringCounts.'lookupUsernameMetadata(' -ne 1 `
        -or [int]$blocklistStoreTarget[0].exactStringCounts.'Instant.parse(' -ne 2 `
        -or [int]$blocklistStoreTarget[0].exactStringCounts.'requireUniqueUsername(' -ne 3) {
    throw 'BlocklistStore targeted recovery does not pin one indexed write, timestamp rebinding, username uniqueness, and each bounded lookup API.'
}
$reviewedBlocklistJadxEvidenceBoundary =
    'JADX local-variable recovery is non-authoritative for observed-generation catch paths; release authority is the raw primary-DEX bridge-flow proof.'
$nonAuthoritativeBlocklistJadxLocals = @(
    'invalid(String state, long observedGeneration)',
    'long observedGeneration = 0L;',
    'observedGeneration = metadata.generation;',
    'IdMatch.invalid(STATE_UNAVAILABLE, observedGeneration)',
    'IdMatch.invalid(invalidStore.state, observedGeneration)')
$blocklistStoreCountNames = @(
    $blocklistStoreTarget[0].exactStringCounts.PSObject.Properties.Name |
        ForEach-Object { [string]$_ })
if ([string]$blocklistStoreTarget[0].evidenceBoundary -cne `
        $reviewedBlocklistJadxEvidenceBoundary) {
    throw 'BlocklistStore targeted recovery does not declare raw primary-DEX authority over JADX local-variable rendering.'
}
foreach ($nonAuthoritativeBlocklistJadxLocal in $nonAuthoritativeBlocklistJadxLocals) {
    if ($blocklistStoreRequiredStrings -contains $nonAuthoritativeBlocklistJadxLocal `
            -or $blocklistStoreCountNames -contains $nonAuthoritativeBlocklistJadxLocal) {
        throw "BlocklistStore targeted recovery retains impossible source-local generation spelling: $nonAuthoritativeBlocklistJadxLocal"
    }
}
$autoBlockSourceText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'assets\autoblock\java\threadsmod\autoblock\AutoBlockSync.java')
$modStateSourceText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'assets\autoblock\java\threadsmod\autoblock\ModStateStore.java')
$blocklistStoreSourceText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'assets\autoblock\java\threadsmod\autoblock\BlocklistStore.java')
$catalogInlineTemplateRoot = Resolve-PatchletTemplateRoot `
    -PatchletsRoot $patchletsRoot `
    -Section $resolution.inlineControls `
    -DefaultRelativeRoot 'assets\inline-control\templates' `
    -Kind 'inline'
$visibilityTemplateText = Get-NormalizedPatchletText -Path (
    Join-Path $catalogInlineTemplateRoot 'InlineVisibilityCallback.smali.tmpl')
if ($inlineVisibilityTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX memory-only viewport callback contract.'
}
$visibilityTemplateCallsites = [ordered]@{
    'AutoBlockSync.registerVisibleControl(this,' =
        'Lthreadsmod/autoblock/AutoBlockSync;->registerVisibleControl(Ljava/lang/Object;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z'
    'AutoBlockSync.updateVisibleControl(this,' =
        'Lthreadsmod/autoblock/AutoBlockSync;->updateVisibleControl(Ljava/lang/Object;Z)V'
    'AutoBlockSync.unregisterVisibleControl(this)' =
        'Lthreadsmod/autoblock/AutoBlockSync;->unregisterVisibleControl(Ljava/lang/Object;)V'
}
$resolvedVisibilityCountProperties = @(
    $inlineVisibilityTarget[0].exactStringCounts.PSObject.Properties)
if ($resolvedVisibilityCountProperties.Count -ne $visibilityTemplateCallsites.Count) {
    throw 'InlineVisibilityCallback targeted JADX count keys must exactly match the reviewed visibility API set.'
}
foreach ($jadxVisibilityLiteral in $visibilityTemplateCallsites.Keys) {
    $resolvedVisibilityCountProperty =
        $inlineVisibilityTarget[0].exactStringCounts.PSObject.Properties[
            $jadxVisibilityLiteral]
    $templateVisibilityCallCount = Get-PatchletLiteralCount `
        -Text $visibilityTemplateText `
        -Literal ([string]$visibilityTemplateCallsites[$jadxVisibilityLiteral])
    $reviewedVisibilityCallCount =
        [int]$reviewedVisibilityJadxCallCounts[$jadxVisibilityLiteral]
    if ($null -eq $resolvedVisibilityCountProperty `
            -or $templateVisibilityCallCount -ne $reviewedVisibilityCallCount `
            -or [int]$resolvedVisibilityCountProperty.Value `
                -ne $templateVisibilityCallCount) {
        throw "InlineVisibilityCallback targeted JADX count '$jadxVisibilityLiteral' must equal the exact '$sourceVersionName' template callsite count $reviewedVisibilityCallCount."
    }
}
$refreshWorkerIndex = $autoBlockSourceText.IndexOf(
    'private static final class ListRefreshWorker implements Runnable',
    [StringComparison]::Ordinal)
$passiveLookupWorkerIndex = $autoBlockSourceText.IndexOf(
    'private static final class PassiveLookupWorker implements Runnable',
    [StringComparison]::Ordinal)
if ($refreshWorkerIndex -lt 0 -or $passiveLookupWorkerIndex -le $refreshWorkerIndex) {
    throw 'Canonical runtime does not separate list refresh from passive lookup workers.'
}
$refreshLaneText = $autoBlockSourceText.Substring(
    $refreshWorkerIndex, $passiveLookupWorkerIndex - $refreshWorkerIndex)
foreach ($requiredRefreshLaneText in @(
        'refreshBlocklist(',
        'BlocklistStore.markFetchedUnchanged(',
        'BlocklistStore.replaceVerified(')) {
    if (-not $refreshLaneText.Contains(
            $requiredRefreshLaneText, [StringComparison]::Ordinal)) {
        throw "Canonical list-refresh lane omits '$requiredRefreshLaneText'."
    }
}
foreach ($forbiddenRefreshLaneText in @(
        'new BlockRun(',
        'ThreadsBlockBridge.',
        'reserveAttempt(',
        'ModStateStore.markPassiveRunning(')) {
    if ($refreshLaneText.Contains(
            $forbiddenRefreshLaneText, [StringComparison]::Ordinal)) {
        throw "List refresh improperly creates or dispatches Block work: $forbiddenRefreshLaneText"
    }
}
foreach ($truthfulRefreshOutcomeText in @(
        'throw new IllegalStateException(',
        'public mirrors failed while a prior verified generation was retained',
        'boolean conditionalMetadataSaved = false;',
        'conditionalMetadataSaved = edit.commit();',
        'Conditional fetch metadata will retry later.')) {
    if (-not $refreshLaneText.Contains(
            $truthfulRefreshOutcomeText, [StringComparison]::Ordinal)) {
        throw "List refresh does not preserve truthful retained-generation/metadata outcomes: $truthfulRefreshOutcomeText"
    }
}
if ($refreshLaneText.Contains(
        'return "Public mirrors failed; retained the previous verified indexed list',
        [StringComparison]::Ordinal)) {
    throw 'A retained old generation may not turn an all-mirror failure into refresh success.'
}
$armRefreshIndex = $autoBlockSourceText.IndexOf(
    'private static void armListRefreshWake(', [StringComparison]::Ordinal)
$refreshWorkerIndexAfterArm = $autoBlockSourceText.IndexOf(
    'private static final class ListRefreshWorker implements Runnable',
    $armRefreshIndex + 1, [StringComparison]::Ordinal)
if ($armRefreshIndex -lt 0 -or $refreshWorkerIndexAfterArm -le $armRefreshIndex) {
    throw 'Canonical runtime has no bounded foreground list-refresh wake method.'
}
$armRefreshText = $autoBlockSourceText.Substring(
    $armRefreshIndex, $refreshWorkerIndexAfterArm - $armRefreshIndex)
foreach ($checkedRefreshWakeText in @(
        'private static final long FETCH_INTERVAL_MS = 10L * 60L * 1000L;',
        'boolean posted = MAIN.postDelayed(',
        'if (!posted)',
        'blocklist_refresh_wake_rejected')) {
    $wakeContractText = if ($checkedRefreshWakeText.StartsWith(
            'private static final long', [StringComparison]::Ordinal)) {
        $autoBlockSourceText
    } else {
        $armRefreshText
    }
    if (-not $wakeContractText.Contains(
            $checkedRefreshWakeText, [StringComparison]::Ordinal)) {
        throw "Foreground 10-minute refresh wake omits '$checkedRefreshWakeText'."
    }
}
foreach ($requiredRefreshCadenceText in @(
        'new ListRefreshWorker(activity, viewer, runForced)',
        'private static final String KEY_LIST_REFRESH_NOT_BEFORE = "list_refresh_not_before";',
        'private static final Object LIST_REFRESH_DEADLINE_LOCK = new Object();',
        'DeadlineState deadline = readListRefreshDeadline(activity, requestNow);',
        'if (!deadline.valid)',
        'if (deadline.value > requestNow)',
        'boolean deadlineSaved = advanceListRefreshDeadline(',
        'if (!(raw instanceof Long))',
        'millisUntilNextListRefresh(active)',
        'if (!isUsableBlocklistSnapshot(snapshot, now))',
        'return deadline.value <= now',
        '? 1000L : Math.max(1000L, deadline.value - now)')) {
    if (-not $autoBlockSourceText.Contains(
            $requiredRefreshCadenceText, [StringComparison]::Ordinal)) {
        throw "List refresh failure cadence or forced-refresh propagation omits '$requiredRefreshCadenceText'."
    }
}
$requestListRefreshDeadlineIndex = $autoBlockSourceText.IndexOf(
    'private static void requestListRefresh(', [StringComparison]::Ordinal)
$ordinaryDeadlineGateIndex = $autoBlockSourceText.IndexOf(
    'if (!forcedIntent)', $requestListRefreshDeadlineIndex, [StringComparison]::Ordinal)
$ordinaryDeadlineReadIndex = $autoBlockSourceText.IndexOf(
    'readListRefreshDeadline(activity, requestNow)', $ordinaryDeadlineGateIndex,
    [StringComparison]::Ordinal)
$refreshLaneAcquireIndex = $autoBlockSourceText.IndexOf(
    'LIST_REFRESH_RUNNING.compareAndSet(false, true)', $ordinaryDeadlineReadIndex,
    [StringComparison]::Ordinal)
$refreshStartDeadlineIndex = $autoBlockSourceText.IndexOf(
    'advanceListRefreshDeadline(activity, System.currentTimeMillis())',
    $refreshLaneAcquireIndex, [StringComparison]::Ordinal)
$refreshWorkerStartIndex = $autoBlockSourceText.IndexOf(
    'worker.start()', $refreshStartDeadlineIndex, [StringComparison]::Ordinal)
$refreshStartCatchIndex = $autoBlockSourceText.IndexOf(
    'catch (Throwable ignored)', $refreshWorkerStartIndex, [StringComparison]::Ordinal)
$refreshRejectDeadlineIndex = $autoBlockSourceText.IndexOf(
    'boolean deadlineSaved = advanceListRefreshDeadline(', $refreshStartCatchIndex,
    [StringComparison]::Ordinal)
$refreshRejectReleaseIndex = $autoBlockSourceText.IndexOf(
    'LIST_REFRESH_RUNNING.set(false)', $refreshRejectDeadlineIndex,
    [StringComparison]::Ordinal)
$refreshRejectWakeIndex = $autoBlockSourceText.IndexOf(
    'armListRefreshWake(', $refreshRejectReleaseIndex, [StringComparison]::Ordinal)
$refreshCompletionDeadlineIndex = $autoBlockSourceText.IndexOf(
    '|| !advanceListRefreshDeadline(', $refreshWorkerIndex,
    [StringComparison]::Ordinal)
$refreshCompletionReleaseIndex = $autoBlockSourceText.IndexOf(
    'LIST_REFRESH_RUNNING.set(false)', $refreshCompletionDeadlineIndex,
    [StringComparison]::Ordinal)
$refreshCompletionWakeIndex = $autoBlockSourceText.IndexOf(
    'millisUntilNextListRefresh(active)', $refreshCompletionReleaseIndex,
    [StringComparison]::Ordinal)
if ($ordinaryDeadlineGateIndex -lt 0 `
        -or $ordinaryDeadlineReadIndex -le $ordinaryDeadlineGateIndex `
        -or $refreshLaneAcquireIndex -le $ordinaryDeadlineReadIndex `
        -or $refreshStartDeadlineIndex -le $refreshLaneAcquireIndex `
        -or $refreshWorkerStartIndex -le $refreshStartDeadlineIndex `
        -or $refreshStartCatchIndex -le $refreshWorkerStartIndex `
        -or $refreshRejectDeadlineIndex -le $refreshStartCatchIndex `
        -or $refreshRejectReleaseIndex -le $refreshRejectDeadlineIndex `
        -or $refreshRejectWakeIndex -le $refreshRejectReleaseIndex `
        -or $refreshCompletionDeadlineIndex -le $refreshWorkerIndex `
        -or $refreshCompletionReleaseIndex -le $refreshCompletionDeadlineIndex `
        -or $refreshCompletionWakeIndex -le $refreshCompletionReleaseIndex `
        -or $autoBlockSourceText.Contains(
            '.remove(KEY_LIST_REFRESH_NOT_BEFORE)', [StringComparison]::Ordinal)) {
    throw 'Ordinary refresh must honor one typed durable/local deadline, and every start rejection or completion must advance it before lane release and wake.'
}
$readDeadlineIndex = $autoBlockSourceText.IndexOf(
    'private static DeadlineState readDeadline(', [StringComparison]::Ordinal)
$readListRefreshDeadlineIndex = $autoBlockSourceText.IndexOf(
    'private static DeadlineState readListRefreshDeadline(', $readDeadlineIndex,
    [StringComparison]::Ordinal)
$advanceListRefreshDeadlineIndex = $autoBlockSourceText.IndexOf(
    'private static boolean advanceListRefreshDeadline(', $readListRefreshDeadlineIndex,
    [StringComparison]::Ordinal)
if ($readDeadlineIndex -lt 0 `
        -or $readListRefreshDeadlineIndex -le $readDeadlineIndex `
        -or $advanceListRefreshDeadlineIndex -le $readListRefreshDeadlineIndex) {
    throw 'Canonical typed deadline reader boundaries are not recognizable.'
}
$readDeadlineText = $autoBlockSourceText.Substring(
    $readDeadlineIndex, $readListRefreshDeadlineIndex - $readDeadlineIndex)
$readListRefreshDeadlineText = $autoBlockSourceText.Substring(
    $readListRefreshDeadlineIndex,
    $advanceListRefreshDeadlineIndex - $readListRefreshDeadlineIndex)
$rawDeadlineTryIndex = $readDeadlineText.IndexOf('try {', [StringComparison]::Ordinal)
$rawDeadlineGetAllIndex = $readDeadlineText.IndexOf(
    'Map<String, ?> values = preferences.getAll();', $rawDeadlineTryIndex,
    [StringComparison]::Ordinal)
$rawDeadlineCatchIndex = $readDeadlineText.IndexOf(
    'catch (Throwable ignored)', $rawDeadlineGetAllIndex,
    [StringComparison]::Ordinal)
$rawDeadlineInvalidIndex = $readDeadlineText.IndexOf(
    'return new DeadlineState(false, 0L);', $rawDeadlineCatchIndex,
    [StringComparison]::Ordinal)
$listDeadlineTryIndex = $readListRefreshDeadlineText.IndexOf(
    'try {', [StringComparison]::Ordinal)
$listDeadlinePrefsIndex = $readListRefreshDeadlineText.IndexOf(
    'prefs(context)', $listDeadlineTryIndex, [StringComparison]::Ordinal)
$listDeadlineCatchIndex = $readListRefreshDeadlineText.IndexOf(
    'catch (Throwable ignored)', $listDeadlinePrefsIndex,
    [StringComparison]::Ordinal)
$listDeadlineInvalidIndex = $readListRefreshDeadlineText.IndexOf(
    'return new DeadlineState(false, 0L);', $listDeadlineCatchIndex,
    [StringComparison]::Ordinal)
if ($rawDeadlineTryIndex -lt 0 `
        -or $rawDeadlineGetAllIndex -le $rawDeadlineTryIndex `
        -or $rawDeadlineCatchIndex -le $rawDeadlineGetAllIndex `
        -or $rawDeadlineInvalidIndex -le $rawDeadlineCatchIndex `
        -or -not $readDeadlineText.Contains(
            'if (values == null)', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $readDeadlineText `
            -Literal 'preferences.getAll()') -ne 1 `
        -or $listDeadlineTryIndex -lt 0 `
        -or $listDeadlinePrefsIndex -le $listDeadlineTryIndex `
        -or $listDeadlineCatchIndex -le $listDeadlinePrefsIndex `
        -or $listDeadlineInvalidIndex -le $listDeadlineCatchIndex `
        -or (Get-PatchletLiteralCount -Text $readListRefreshDeadlineText `
            -Literal 'prefs(context)') -ne 1) {
    throw 'SharedPreferences deadline acquisition/read failures are not narrowly caught and converted to invalid fail-closed state.'
}
foreach ($requiredViewerScopedForceText in @(
        'forceRefresh && !requestListForceRefresh(viewer)',
        'boolean runForced = forceRefresh;',
        'if (!runForced && hasListForceRefresh(viewer))',
        'runForced = consumeListForceRefresh(viewer);',
        'LIST_REFRESH_RUNNING.set(false);',
        'boolean forceRetained = !runForced || requestListForceRefresh(viewer);',
        'blocklist_refresh_worker_start_rejected',
        'armListRefreshWake(activity, viewer, FETCH_INTERVAL_MS);',
        'LIST_FORCE_REFRESH_VIEWERS.add(viewer)',
        'activeViewer != null && isEnabled(active)',
        'hasListForceRefresh(activeViewer)',
        'consumeListForceRefresh(activeViewer)',
        'requestListRefresh(active, activeViewer, true)')) {
    if (-not $autoBlockSourceText.Contains(
            $requiredViewerScopedForceText, [StringComparison]::Ordinal)) {
        throw "Forced list refresh is not direct or viewer-scoped under contention: $requiredViewerScopedForceText"
    }
}
if ($autoBlockSourceText.Contains(
        'armListRefreshWake(active, viewer, 1000L)', [StringComparison]::Ordinal)) {
    throw 'List refresh failure retry or forced intent consumption bypasses the reviewed cadence/viewer scope.'
}
$blockRunIndex = $autoBlockSourceText.IndexOf(
    'private static final class BlockRun implements BridgeCallback',
    [StringComparison]::Ordinal)
$manualPriorityIndex = $autoBlockSourceText.IndexOf(
    'ModStateStore.nextQueued(activity, viewer)',
    $blockRunIndex, [StringComparison]::Ordinal)
$initialPassiveGuardIndex = $autoBlockSourceText.IndexOf(
    'PassiveMatchResult initialMatch =',
    $manualPriorityIndex, [StringComparison]::Ordinal)
$initialPassiveMatchCallIndex = $autoBlockSourceText.IndexOf(
    'currentPassiveMatch(activity, viewer, targetId)',
    $initialPassiveGuardIndex, [StringComparison]::Ordinal)
$passivePreflightIndex = $autoBlockSourceText.IndexOf(
    'ThreadsBlockBridge.passivePreflight(',
    $initialPassiveMatchCallIndex, [StringComparison]::Ordinal)
$postPreflightForegroundIndex = $autoBlockSourceText.IndexOf(
    'if (!isCurrentForeground())',
    $passivePreflightIndex, [StringComparison]::Ordinal)
$postPreflightManualIndex = $autoBlockSourceText.IndexOf(
    'if (ModStateStore.nextQueued(activity, viewer) != null)',
    $postPreflightForegroundIndex, [StringComparison]::Ordinal)
$postPreflightMembershipIndex = $autoBlockSourceText.IndexOf(
    'PassiveMatchResult postPreflightMatch =',
    $postPreflightManualIndex, [StringComparison]::Ordinal)
$postPreflightMatchCallIndex = $autoBlockSourceText.IndexOf(
    'currentPassiveMatch(activity, viewer, targetId)',
    $postPreflightMembershipIndex, [StringComparison]::Ordinal)
$alreadyBlockedBranchIndex = $autoBlockSourceText.IndexOf(
    'if ("already_blocked_success".equals(preflightStage))',
    $postPreflightMatchCallIndex, [StringComparison]::Ordinal)
$preflightFailureBranchIndex = $autoBlockSourceText.IndexOf(
    'if (preflightStage != null)',
    $alreadyBlockedBranchIndex, [StringComparison]::Ordinal)
$postPreflightLimitsIndex = $autoBlockSourceText.IndexOf(
    'if (!BlockLimitsStore.isValid(activity))',
    $preflightFailureBranchIndex, [StringComparison]::Ordinal)
$postPreflightDoneIndex = $autoBlockSourceText.IndexOf(
    'currentDone = doneIds(activity, viewer)',
    $postPreflightLimitsIndex, [StringComparison]::Ordinal)
$postPreflightReviewIndex = $autoBlockSourceText.IndexOf(
    'currentReview = ModStateStore.completionReviewState(activity, viewer)',
    $postPreflightDoneIndex, [StringComparison]::Ordinal)
$finalPostPreflightMembershipIndex = $autoBlockSourceText.IndexOf(
    'PassiveMatchResult finalMatch =',
    $postPreflightReviewIndex, [StringComparison]::Ordinal)
$finalPostPreflightMatchCallIndex = $autoBlockSourceText.IndexOf(
    'currentPassiveMatch(activity, viewer, targetId)',
    $finalPostPreflightMembershipIndex, [StringComparison]::Ordinal)
$postPreflightPaceIndex = $autoBlockSourceText.IndexOf(
    'long currentPaceWait = millisUntilPassivePaceAllowed(activity, viewer)',
    $finalPostPreflightMatchCallIndex, [StringComparison]::Ordinal)
$beforeRunningAuthorityIndex = $autoBlockSourceText.IndexOf(
    'currentPassiveAuthority(false, false)',
    $postPreflightPaceIndex, [StringComparison]::Ordinal)
$passiveRunningIndex = $autoBlockSourceText.IndexOf(
    'ModStateStore.markPassiveRunning(activity, viewer, targetId)',
    $beforeRunningAuthorityIndex, [StringComparison]::Ordinal)
$beforeReservationAuthorityIndex = $autoBlockSourceText.IndexOf(
    'currentPassiveAuthority(true, false)',
    $passiveRunningIndex, [StringComparison]::Ordinal)
$passiveReservationIndex = $autoBlockSourceText.IndexOf(
    'reserveAttempt(activity, viewer, true)',
    $beforeReservationAuthorityIndex, [StringComparison]::Ordinal)
$beforeDispatchAuthorityIndex = $autoBlockSourceText.IndexOf(
    'currentPassiveAuthority(true, true)',
    $passiveReservationIndex, [StringComparison]::Ordinal)
$passiveInFlightIndex = $autoBlockSourceText.IndexOf(
    'markSchedulerMutationInFlight(schedulerToken, true)',
    $beforeDispatchAuthorityIndex, [StringComparison]::Ordinal)
$passiveBridgeIndex = $autoBlockSourceText.IndexOf(
    'ThreadsBlockBridge.block(activity, userSession, targetId, this)',
    $passiveInFlightIndex, [StringComparison]::Ordinal)
$refreshAdmissionLockIndex = $autoBlockSourceText.IndexOf(
    'synchronized (PASSIVE_ADMISSION_LOCK)', $refreshWorkerIndex,
    [StringComparison]::Ordinal)
$databaseReplaceIndex = $autoBlockSourceText.IndexOf(
    'BlocklistStore.replaceVerified(', $refreshAdmissionLockIndex,
    [StringComparison]::Ordinal)
$dispatchAdmissionLockIndex = $autoBlockSourceText.IndexOf(
    'synchronized (PASSIVE_ADMISSION_LOCK)', $blockRunIndex,
    [StringComparison]::Ordinal)
$lockedFinalPassiveGuardIndex = $autoBlockSourceText.IndexOf(
    'currentPassiveMatch(activity, viewer, targetId)', $dispatchAdmissionLockIndex,
    [StringComparison]::Ordinal)
if ($blockRunIndex -lt 0 `
        -or $manualPriorityIndex -le $blockRunIndex `
        -or $initialPassiveGuardIndex -le $manualPriorityIndex `
        -or $initialPassiveMatchCallIndex -le $initialPassiveGuardIndex `
        -or $passivePreflightIndex -le $initialPassiveMatchCallIndex `
        -or $postPreflightForegroundIndex -le $passivePreflightIndex `
        -or $postPreflightManualIndex -le $postPreflightForegroundIndex `
        -or $postPreflightMembershipIndex -le $postPreflightManualIndex `
        -or $postPreflightMatchCallIndex -le $postPreflightMembershipIndex `
        -or $alreadyBlockedBranchIndex -le $postPreflightMatchCallIndex `
        -or $preflightFailureBranchIndex -le $alreadyBlockedBranchIndex `
        -or $postPreflightLimitsIndex -le $preflightFailureBranchIndex `
        -or $postPreflightDoneIndex -le $postPreflightLimitsIndex `
        -or $postPreflightReviewIndex -le $postPreflightDoneIndex `
        -or $finalPostPreflightMembershipIndex -le $postPreflightReviewIndex `
        -or $finalPostPreflightMatchCallIndex -le $finalPostPreflightMembershipIndex `
        -or $postPreflightPaceIndex -le $finalPostPreflightMatchCallIndex `
        -or $beforeRunningAuthorityIndex -le $postPreflightPaceIndex `
        -or $passiveRunningIndex -le $beforeRunningAuthorityIndex `
        -or $beforeReservationAuthorityIndex -le $passiveRunningIndex `
        -or $passiveReservationIndex -le $beforeReservationAuthorityIndex `
        -or $beforeDispatchAuthorityIndex -le $passiveReservationIndex `
        -or $passiveInFlightIndex -le $beforeDispatchAuthorityIndex `
        -or $passiveBridgeIndex -le $passiveInFlightIndex `
        -or (Get-PatchletLiteralCount -Text $autoBlockSourceText `
            -Literal 'synchronized (PASSIVE_ADMISSION_LOCK)') -ne 6 `
        -or $refreshAdmissionLockIndex -lt 0 `
        -or $databaseReplaceIndex -le $refreshAdmissionLockIndex `
        -or $dispatchAdmissionLockIndex -le $blockRunIndex `
        -or $lockedFinalPassiveGuardIndex -le $dispatchAdmissionLockIndex `
        -or $passiveRunningIndex -le $lockedFinalPassiveGuardIndex) {
    throw 'Passive BlockRun does not preserve callback-free native preflight, post-preflight checks, passive pacing, and complete current authority before running persistence, reservation, and bridge dispatch.'
}
$currentAuthorityIndex = $autoBlockSourceText.IndexOf(
    'private PassiveAuthority currentPassiveAuthority(', $passiveBridgeIndex,
    [StringComparison]::Ordinal)
$stopAuthorityIndex = $autoBlockSourceText.IndexOf(
    'private void stopForAuthorityFailure(', $currentAuthorityIndex,
    [StringComparison]::Ordinal)
if ($currentAuthorityIndex -le $passiveBridgeIndex -or $stopAuthorityIndex -le $currentAuthorityIndex) {
    throw 'Complete passive-authority helper boundary is not recognizable.'
}
$currentAuthorityText = $autoBlockSourceText.Substring(
    $currentAuthorityIndex, $stopAuthorityIndex - $currentAuthorityIndex)
foreach ($requiredCurrentAuthorityText in @(
        'isMainLooperThread()',
        'isCurrentForeground()',
        'isPassiveStorePaused()',
        'ModStateStore.nextQueued(activity, viewer)',
        'BlockLimitsStore.isValid(activity)',
        'doneIds(activity, viewer)',
        'ModStateStore.completionReviewState(activity, viewer)',
        'isLocalCompletionReviewPaused(viewer)',
        'ModStateStore.isPassiveRunningClear(activity, viewer)',
        'currentPassiveMatch(activity, viewer, targetId)',
        'millisUntilPassivePaceAllowed(activity, viewer)')) {
    if (-not $currentAuthorityText.Contains(
            $requiredCurrentAuthorityText, [StringComparison]::Ordinal)) {
        throw "Complete passive-authority helper omits '$requiredCurrentAuthorityText'."
    }
}
if ((Get-PatchletLiteralCount -Text $autoBlockSourceText `
            -Literal 'currentPassiveAuthority(') -ne 4 `
        -or (Get-PatchletLiteralCount -Text $autoBlockSourceText `
            -Literal 'currentPassiveAuthority(false, false)') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $autoBlockSourceText `
            -Literal 'currentPassiveAuthority(true, false)') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $autoBlockSourceText `
            -Literal 'currentPassiveAuthority(true, true)') -ne 1) {
    throw 'Passive authority must run exactly once before each of running persistence, attempt reservation, and native dispatch.'
}
$retiredPassiveCapLiterals = @(
    'automaticPerHour()',
    'targetBudgetAdded',
    'admitForegroundPassiveTarget(',
    'hasForegroundPassiveTarget(',
    'removeForegroundPassiveTarget(',
    'releaseNewlyAdmittedTargetBeforeReservation(',
    'resetForegroundRun(',
    'hasForegroundRunCapacity(',
    'rateAllowed(',
    'millisUntilRateAllowed(',
    'millisUntilPaceAllowed(',
    'foregroundPassiveTargets',
    'foregroundRunAttempts',
    '.targetBudget()',
    '.totalPerHour()',
    '.totalPerDay()',
    '.maxPerRun()')
foreach ($retiredPassiveCapLiteral in $retiredPassiveCapLiterals) {
    if ($autoBlockSourceText.Contains(
            $retiredPassiveCapLiteral, [StringComparison]::Ordinal)) {
        throw "Retired passive rate/cap authority remains in AutoBlockSync: $retiredPassiveCapLiteral"
    }
}

$reserveAttemptStartIndex = $autoBlockSourceText.IndexOf(
    'private static boolean reserveAttempt(', [StringComparison]::Ordinal)
$passivePaceHelperIndex = $autoBlockSourceText.IndexOf(
    'private static long millisUntilPassivePaceAllowed(',
    $reserveAttemptStartIndex, [StringComparison]::Ordinal)
if ($reserveAttemptStartIndex -lt 0 -or $passivePaceHelperIndex -le $reserveAttemptStartIndex) {
    throw 'Attempt-reservation boundary is not recognizable.'
}
$reserveAttemptText = $autoBlockSourceText.Substring(
    $reserveAttemptStartIndex, $passivePaceHelperIndex - $reserveAttemptStartIndex)
$reserveLimitsGuardIndex = $reserveAttemptText.IndexOf(
    'if (automatic && !BlockLimitsStore.isValid(context))', [StringComparison]::Ordinal)
$reservePaceGuardIndex = $reserveAttemptText.IndexOf(
    'if (automatic && millisUntilPassivePaceAllowed(context, viewer) > 0L)',
    $reserveLimitsGuardIndex, [StringComparison]::Ordinal)
$reserveEditorIndex = $reserveAttemptText.IndexOf(
    'SharedPreferences.Editor editor = p.edit()',
    $reservePaceGuardIndex, [StringComparison]::Ordinal)
$reserveAttemptHistoryIndex = $reserveAttemptText.IndexOf(
    '.putString(attemptsKey(viewer), encodeEvents(events))',
    $reserveEditorIndex, [StringComparison]::Ordinal)
$reserveAutomaticIndex = $reserveAttemptText.IndexOf(
    'if (automatic) {', $reserveAttemptHistoryIndex, [StringComparison]::Ordinal)
$reserveLimitsLoadIndex = $reserveAttemptText.IndexOf(
    'BlockLimits limits = BlockLimitsStore.load(context);',
    $reserveAutomaticIndex, [StringComparison]::Ordinal)
$reservePaceDeadlineIndex = $reserveAttemptText.IndexOf(
    'long paceUntil = now + randomDelay(',
    $reserveLimitsLoadIndex, [StringComparison]::Ordinal)
$reservePassiveBoundsIndex = $reserveAttemptText.IndexOf(
    'limits.passiveMinDelayMs(), limits.passiveMaxDelayMs());',
    $reservePaceDeadlineIndex, [StringComparison]::Ordinal)
$reservePaceWriteIndex = $reserveAttemptText.IndexOf(
    'editor.putLong(paceKey(viewer), paceUntil);',
    $reservePassiveBoundsIndex, [StringComparison]::Ordinal)
$reserveCommitIndex = $reserveAttemptText.IndexOf(
    'return editor.commit();', $reservePaceWriteIndex, [StringComparison]::Ordinal)
if ($reserveLimitsGuardIndex -lt 0 `
        -or $reservePaceGuardIndex -le $reserveLimitsGuardIndex `
        -or $reserveEditorIndex -le $reservePaceGuardIndex `
        -or $reserveAttemptHistoryIndex -le $reserveEditorIndex `
        -or $reserveAutomaticIndex -le $reserveAttemptHistoryIndex `
        -or $reserveLimitsLoadIndex -le $reserveAutomaticIndex `
        -or $reservePaceDeadlineIndex -le $reserveLimitsLoadIndex `
        -or $reservePassiveBoundsIndex -le $reservePaceDeadlineIndex `
        -or $reservePaceWriteIndex -le $reservePassiveBoundsIndex `
        -or $reserveCommitIndex -le $reservePaceWriteIndex `
        -or (Get-PatchletLiteralCount -Text $reserveAttemptText `
            -Literal 'BlockLimitsStore.load(context)') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reserveAttemptText `
            -Literal 'limits.passiveMinDelayMs()') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reserveAttemptText `
            -Literal 'limits.passiveMaxDelayMs()') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reserveAttemptText `
            -Literal 'editor.putLong(paceKey(viewer), paceUntil)') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reserveAttemptText `
            -Literal 'return editor.commit()') -ne 1) {
    throw 'Passive attempt reservation does not atomically commit attempt history and one delay bounded by passiveMin/passiveMax.'
}

$manualDrainStartIndex = $autoBlockSourceText.IndexOf(
    'private static void drainManualQueue()', [StringComparison]::Ordinal)
$manualCallbackKeyIndex = $autoBlockSourceText.IndexOf(
    'private static String manualCallbackKey(',
    $manualDrainStartIndex, [StringComparison]::Ordinal)
if ($manualDrainStartIndex -lt 0 -or $manualCallbackKeyIndex -le $manualDrainStartIndex) {
    throw 'Manual scheduler boundary is not recognizable.'
}
$manualDrainText = $autoBlockSourceText.Substring(
    $manualDrainStartIndex, $manualCallbackKeyIndex - $manualDrainStartIndex)
if ((Get-PatchletLiteralCount -Text $manualDrainText `
            -Literal 'reserveAttempt(activity, viewer, false)') -ne 1 `
        -or $manualDrainText.Contains(
            'reserveAttempt(activity, viewer, true)', [StringComparison]::Ordinal)) {
    throw 'Manual Block must reserve exactly once through the unpaced non-automatic attempt path.'
}
foreach ($forbiddenManualCapLiteral in @(
        'BlockLimits',
        'millisUntilPassivePaceAllowed(',
        'paceKey(',
        'randomDelay(') + $retiredPassiveCapLiterals) {
    if ($manualDrainText.Contains(
            $forbiddenManualCapLiteral, [StringComparison]::Ordinal)) {
        throw "Manual Block path unexpectedly depends on passive pacing or retired caps: $forbiddenManualCapLiteral"
    }
}
$registerVisibilityIndex = $autoBlockSourceText.IndexOf(
    'public static boolean registerVisibleControl(', [StringComparison]::Ordinal)
$updateVisibilityIndex = $autoBlockSourceText.IndexOf(
    'public static void updateVisibleControl(', $registerVisibilityIndex,
    [StringComparison]::Ordinal)
$unregisterVisibilityIndex = $autoBlockSourceText.IndexOf(
    'public static void unregisterVisibleControl(', $updateVisibilityIndex,
    [StringComparison]::Ordinal)
$inlineEnqueueIndex = $autoBlockSourceText.IndexOf(
    'public static boolean enqueueManual(', $unregisterVisibilityIndex,
    [StringComparison]::Ordinal)
$registerMainIndex = $autoBlockSourceText.IndexOf(
    'if (!isMainLooperThread()', $registerVisibilityIndex, [StringComparison]::Ordinal)
$registerGrantIndex = $autoBlockSourceText.IndexOf(
    'PASSIVE_REGISTRATIONS.put(', $registerMainIndex, [StringComparison]::Ordinal)
$updateOffMainIndex = $autoBlockSourceText.IndexOf(
    'if (!isMainLooperThread())', $updateVisibilityIndex, [StringComparison]::Ordinal)
$updateOffMainAdmissionIndex = $autoBlockSourceText.IndexOf(
    'synchronized (PASSIVE_ADMISSION_LOCK)', $updateOffMainIndex,
    [StringComparison]::Ordinal)
$updateOffMainReturnIndex = $autoBlockSourceText.IndexOf(
    'return;', $updateOffMainAdmissionIndex, [StringComparison]::Ordinal)
$unregisterOffMainIndex = $autoBlockSourceText.IndexOf(
    'if (!isMainLooperThread())', $unregisterVisibilityIndex,
    [StringComparison]::Ordinal)
$unregisterOffMainAdmissionIndex = $autoBlockSourceText.IndexOf(
    'synchronized (PASSIVE_ADMISSION_LOCK)', $unregisterOffMainIndex,
    [StringComparison]::Ordinal)
$unregisterOffMainReturnIndex = $autoBlockSourceText.IndexOf(
    'return;', $unregisterOffMainAdmissionIndex, [StringComparison]::Ordinal)
$inlineEnqueueMainIndex = $autoBlockSourceText.IndexOf(
    'if (!isMainLooperThread())', $inlineEnqueueIndex, [StringComparison]::Ordinal)
$inlineEnqueuePersistIndex = $autoBlockSourceText.IndexOf(
    'ModStateStore.enqueueManual(', $inlineEnqueueMainIndex, [StringComparison]::Ordinal)
if ($registerMainIndex -lt $registerVisibilityIndex `
        -or $registerGrantIndex -le $registerMainIndex `
        -or $registerGrantIndex -ge $updateVisibilityIndex `
        -or $updateOffMainAdmissionIndex -le $updateOffMainIndex `
        -or $updateOffMainReturnIndex -le $updateOffMainAdmissionIndex `
        -or $updateOffMainReturnIndex -ge $unregisterVisibilityIndex `
        -or $unregisterOffMainAdmissionIndex -le $unregisterOffMainIndex `
        -or $unregisterOffMainReturnIndex -le $unregisterOffMainAdmissionIndex `
        -or $unregisterOffMainReturnIndex -ge $inlineEnqueueIndex `
        -or $inlineEnqueuePersistIndex -le $inlineEnqueueMainIndex) {
    throw 'Visibility/manual authority grants are not main-thread-only or off-main revocation is not serialized through passive admission.'
}
$idMatchTypeIndex = $blocklistStoreSourceText.IndexOf(
    'public static final class IdMatch', [StringComparison]::Ordinal)
$usernameMetadataTypeIndex = $blocklistStoreSourceText.IndexOf(
    'public static final class UsernameMetadata', $idMatchTypeIndex,
    [StringComparison]::Ordinal)
$lookupIdMethodIndex = $blocklistStoreSourceText.IndexOf(
    'public static IdMatch lookupId(', $usernameMetadataTypeIndex,
    [StringComparison]::Ordinal)
$currentIdMethodIndex = $blocklistStoreSourceText.IndexOf(
    'public static IdMatch isCurrentIdMatch(', $lookupIdMethodIndex,
    [StringComparison]::Ordinal)
$usernameLookupMethodIndex = $blocklistStoreSourceText.IndexOf(
    'public static UsernameMetadata lookupUsernameMetadata(', $currentIdMethodIndex,
    [StringComparison]::Ordinal)
if ($idMatchTypeIndex -lt 0 `
        -or $usernameMetadataTypeIndex -le $idMatchTypeIndex `
        -or $lookupIdMethodIndex -le $usernameMetadataTypeIndex `
        -or $currentIdMethodIndex -le $lookupIdMethodIndex `
        -or $usernameLookupMethodIndex -le $currentIdMethodIndex) {
    throw 'Blocklist exact-ID result and lookup method boundaries are not recognizable.'
}
$idMatchTypeText = $blocklistStoreSourceText.Substring(
    $idMatchTypeIndex, $usernameMetadataTypeIndex - $idMatchTypeIndex)
$lookupIdMethodText = $blocklistStoreSourceText.Substring(
    $lookupIdMethodIndex, $currentIdMethodIndex - $lookupIdMethodIndex)
$currentIdMethodText = $blocklistStoreSourceText.Substring(
    $currentIdMethodIndex, $usernameLookupMethodIndex - $currentIdMethodIndex)
if (-not $idMatchTypeText.Contains(
        'private static IdMatch invalid(String state, long observedGeneration)',
        [StringComparison]::Ordinal) `
        -or -not $idMatchTypeText.Contains(
            'false, false, Math.max(0L, observedGeneration), "", state',
            [StringComparison]::Ordinal)) {
    throw 'Invalid exact-ID results do not retain a bounded observed database generation.'
}
foreach ($observedGenerationLookup in @(
        @($lookupIdMethodText, 'BlocklistStore.lookupId'),
        @($currentIdMethodText, 'BlocklistStore.isCurrentIdMatch'))) {
    $observedGenerationText = [string]$observedGenerationLookup[0]
    $observedGenerationLabel = [string]$observedGenerationLookup[1]
    $metadataReadIndex = $observedGenerationText.IndexOf(
        'StoredMetadata metadata = readMetadata(database, true);',
        [StringComparison]::Ordinal)
    $observedGenerationIndex = $observedGenerationText.IndexOf(
        'observedGeneration = metadata.generation;', $metadataReadIndex,
        [StringComparison]::Ordinal)
    $rowQueryIndex = $observedGenerationText.IndexOf(
        'Cursor cursor = database.query(', $observedGenerationIndex,
        [StringComparison]::Ordinal)
    if ((Get-PatchletLiteralCount -Text $observedGenerationText `
                -Literal 'IdMatch.invalid(') -ne 5 `
            -or (Get-PatchletLiteralCount -Text $observedGenerationText `
                -Literal ', observedGeneration)') -ne 3 `
            -or (Get-PatchletLiteralCount -Text $observedGenerationText `
                -Literal 'observedGeneration = metadata.generation;') -ne 1 `
            -or $metadataReadIndex -lt 0 `
            -or $observedGenerationIndex -le $metadataReadIndex `
            -or $rowQueryIndex -le $observedGenerationIndex `
            -or -not $observedGenerationText.Contains(
                'IdMatch.invalid(invalidStore.state, observedGeneration)',
                [StringComparison]::Ordinal) `
            -or -not $observedGenerationText.Contains(
                'IdMatch.invalid(STATE_UNAVAILABLE, observedGeneration)',
                [StringComparison]::Ordinal)) {
        throw "$observedGenerationLabel does not preserve the actual metadata generation across every post-metadata invalid result."
    }
}
$passiveLookupWorkerEndIndex = $autoBlockSourceText.IndexOf(
    'private static void startPassiveLookupWorker(', $passiveLookupWorkerIndex,
    [StringComparison]::Ordinal)
$passiveLookupWorkerText = if ($passiveLookupWorkerEndIndex -gt $passiveLookupWorkerIndex) {
    $autoBlockSourceText.Substring(
        $passiveLookupWorkerIndex,
        $passiveLookupWorkerEndIndex - $passiveLookupWorkerIndex)
} else { '' }
$workerInvalidLookupIndex = $passiveLookupWorkerText.IndexOf(
    'if (!match.storeValid)', [StringComparison]::Ordinal)
$workerObservedGenerationIndex = $passiveLookupWorkerText.IndexOf(
    'latchPassiveStorePause(context, viewer, match.generation);',
    $workerInvalidLookupIndex, [StringComparison]::Ordinal)
$workerInvalidBreakIndex = $passiveLookupWorkerText.IndexOf(
    'break;', $workerObservedGenerationIndex, [StringComparison]::Ordinal)
if ($workerInvalidLookupIndex -lt 0 `
        -or $workerObservedGenerationIndex -le $workerInvalidLookupIndex `
        -or $workerInvalidBreakIndex -le $workerObservedGenerationIndex `
        -or $passiveLookupWorkerText.Contains(
            'latchPassiveStorePause(context, viewer, 0L)',
            [StringComparison]::Ordinal)) {
    throw 'Passive lookup worker does not pass the invalid lookup actual observed generation into its fail-closed pause latch.'
}
$storeLatchIndex = $autoBlockSourceText.IndexOf(
    'private static void latchPassiveStorePause(', [StringComparison]::Ordinal)
$storeLatchEndIndex = $autoBlockSourceText.IndexOf(
    'private static boolean isPassiveStorePaused()', $storeLatchIndex,
    [StringComparison]::Ordinal)
$storeLatchText = if ($storeLatchIndex -ge 0 -and $storeLatchEndIndex -gt $storeLatchIndex) {
    $autoBlockSourceText.Substring($storeLatchIndex, $storeLatchEndIndex - $storeLatchIndex)
} else { '' }
$storeClearIndex = $autoBlockSourceText.IndexOf(
    'private static boolean clearPassiveStorePauseAfterVerifiedGeneration(',
    $storeLatchEndIndex, [StringComparison]::Ordinal)
$storeClearEndIndex = $autoBlockSourceText.IndexOf(
    'private static void clearPassiveVisibility()', $storeClearIndex,
    [StringComparison]::Ordinal)
$storeClearText = if ($storeClearIndex -ge 0 -and $storeClearEndIndex -gt $storeClearIndex) {
    $autoBlockSourceText.Substring($storeClearIndex, $storeClearEndIndex - $storeClearIndex)
} else { '' }
foreach ($requiredStoreLatchText in @(
        'synchronized (PASSIVE_ADMISSION_LOCK)',
        'BlocklistStore.Snapshot current = BlocklistStore.snapshot(context)',
        'observedGeneration > 0L',
        'current.generation > observedGeneration',
        'passiveStorePaused = true',
        'PASSIVE_MATCH_GENERATIONS.clear()')) {
    if (-not $storeLatchText.Contains(
            $requiredStoreLatchText, [StringComparison]::Ordinal)) {
        throw "Invalid-store latch is not serialized or stale-generation-safe: $requiredStoreLatchText"
    }
}
$positiveObservedGenerationIndex = $storeLatchText.IndexOf(
    'observedGeneration > 0L', [StringComparison]::Ordinal)
$validCurrentGenerationIndex = $storeLatchText.IndexOf(
    'current.valid', $positiveObservedGenerationIndex, [StringComparison]::Ordinal)
$strictlyNewerGenerationIndex = $storeLatchText.IndexOf(
    'current.generation > observedGeneration', $validCurrentGenerationIndex,
    [StringComparison]::Ordinal)
$staleLatchReturnIndex = $storeLatchText.IndexOf(
    'return;', $strictlyNewerGenerationIndex, [StringComparison]::Ordinal)
$pauseLatchIndex = $storeLatchText.IndexOf(
    'passiveStorePaused = true', $staleLatchReturnIndex,
    [StringComparison]::Ordinal)
if ($positiveObservedGenerationIndex -lt 0 `
        -or $validCurrentGenerationIndex -le $positiveObservedGenerationIndex `
        -or $strictlyNewerGenerationIndex -le $validCurrentGenerationIndex `
        -or $staleLatchReturnIndex -le $strictlyNewerGenerationIndex `
        -or $pauseLatchIndex -le $staleLatchReturnIndex `
        -or $storeLatchText.Contains(
            'current.generation > Math.max(0L, observedGeneration)',
            [StringComparison]::Ordinal)) {
    throw 'Invalid-store stale suppression must require a positive observed generation and a strictly newer valid current generation before returning.'
}
foreach ($requiredStoreClearText in @(
        'generation <= passiveStorePauseGeneration',
        'passiveStorePaused = false',
        'passiveStorePauseGeneration = 0L')) {
    if (-not $storeClearText.Contains(
            $requiredStoreClearText, [StringComparison]::Ordinal)) {
        throw "Invalid-store pause can clear without a strictly newer verified generation: $requiredStoreClearText"
    }
}
$alreadyBlockedHelperIndex = $autoBlockSourceText.IndexOf(
    'private void handleAlreadyBlockedBeforeReservation()',
    $passiveBridgeIndex, [StringComparison]::Ordinal)
$preflightFailureHelperIndex = $autoBlockSourceText.IndexOf(
    'private void handlePreflightFailure(String stage)',
    $alreadyBlockedHelperIndex, [StringComparison]::Ordinal)
$bridgeStartedCallbackIndex = $autoBlockSourceText.IndexOf(
    'public void onBridgeStarted(final String targetId)',
    $preflightFailureHelperIndex, [StringComparison]::Ordinal)
if ($alreadyBlockedHelperIndex -le $passiveBridgeIndex `
        -or $preflightFailureHelperIndex -le $alreadyBlockedHelperIndex `
        -or $bridgeStartedCallbackIndex -le $preflightFailureHelperIndex) {
    throw 'Passive pre-reservation completion/failure helper boundaries are not recognizable.'
}
$alreadyBlockedHelperText = $autoBlockSourceText.Substring(
    $alreadyBlockedHelperIndex,
    $preflightFailureHelperIndex - $alreadyBlockedHelperIndex)
$preflightFailureHelperText = $autoBlockSourceText.Substring(
    $preflightFailureHelperIndex,
    $bridgeStartedCallbackIndex - $preflightFailureHelperIndex)
foreach ($requiredAlreadyBlockedText in @(
        'completionSaved = markDone(activity, viewer, targetId)',
        'reviewSaved = quarantineCompletionReview(',
        '"completion_persistence", true, false, false, reviewSaved',
        'clearRetryDeadline(activity, viewer)',
        'finishAndResume(')) {
    if (-not $alreadyBlockedHelperText.Contains(
            $requiredAlreadyBlockedText, [StringComparison]::Ordinal)) {
        throw "Native-already-blocked helper omits durable completion/quarantine proof: $requiredAlreadyBlockedText"
    }
}
foreach ($requiredPreflightFailureText in @(
        'backoffPersisted = persistRetryDeadline(activity, viewer)',
        'BlockDiagnostic.forFailure(',
        'stage, true, false, false, backoffPersisted',
        'ModStateStore.recordAutomaticFailure(',
        'ModStateStore.recordFailureDiagnostic(activity, viewer, diagnostic)',
        'scheduleManualDrain(FAILURE_BACKOFF_MS + 1000L)')) {
    if (-not $preflightFailureHelperText.Contains(
            $requiredPreflightFailureText, [StringComparison]::Ordinal)) {
        throw "Passive-preflight failure helper omits durable backoff/closed-diagnostic proof: $requiredPreflightFailureText"
    }
}
foreach ($preReservationHelper in @(
        @('already-blocked', $alreadyBlockedHelperText),
        @('preflight-failure', $preflightFailureHelperText))) {
    foreach ($forbiddenPreReservationText in @(
            'markPassiveRunning(',
            'reserveAttempt(',
            'ThreadsBlockBridge.block(')) {
        if (([string]$preReservationHelper[1]).Contains(
                $forbiddenPreReservationText, [StringComparison]::Ordinal)) {
            throw "Passive $($preReservationHelper[0]) helper consumes admission, running, reservation, or mutation authority: $forbiddenPreReservationText"
        }
    }
}
$blockRunEndIndex = $autoBlockSourceText.IndexOf(
    'private static long tryAcquireScheduler(', $blockRunIndex,
    [StringComparison]::Ordinal)
if ($blockRunEndIndex -le $blockRunIndex) {
    throw 'Passive BlockRun boundary is not recognizable.'
}
$singleTargetBlockRunText = $autoBlockSourceText.Substring(
    $blockRunIndex, $blockRunEndIndex - $blockRunIndex)
foreach ($forbiddenSameDrainBatchText in @(
        'List<String> targets',
        'private int index',
        'while (index <',
        'targets.get(',
        'private void next()',
        'next();')) {
    if ($singleTargetBlockRunText.Contains(
            $forbiddenSameDrainBatchText, [StringComparison]::Ordinal)) {
        throw "Passive BlockRun still owns same-drain batch iteration: $forbiddenSameDrainBatchText"
    }
}
$loadTargetIndex = $autoBlockSourceText.IndexOf(
    'private static PassiveTargetSelection loadTarget(', [StringComparison]::Ordinal)
$requestListRefreshIndex = $autoBlockSourceText.IndexOf(
    'private static void requestListRefresh(', $loadTargetIndex,
    [StringComparison]::Ordinal)
if ($loadTargetIndex -lt 0 -or $requestListRefreshIndex -le $loadTargetIndex) {
    throw 'Single-target passive loader boundary is not recognizable.'
}
$singleTargetLoadText = $autoBlockSourceText.Substring(
    $loadTargetIndex, $requestListRefreshIndex - $loadTargetIndex)
if ($singleTargetLoadText.Contains('visibleIds', [StringComparison]::Ordinal) `
        -or $singleTargetLoadText.Contains('ArrayList<String>', [StringComparison]::Ordinal) `
        -or -not $singleTargetLoadText.Contains(
            'String targetId = null;', [StringComparison]::Ordinal) `
        -or -not $singleTargetLoadText.Contains(
            'BlocklistStore.lookupId(context, targetId)', [StringComparison]::Ordinal)) {
    throw 'Each passive drain must copy and index-check only one visible String target.'
}
$automaticSuccessIndex = $singleTargetBlockRunText.IndexOf(
    'public void onBridgeSuccess(final String targetId)', [StringComparison]::Ordinal)
$automaticFailureIndex = $singleTargetBlockRunText.IndexOf(
    'public void onBridgeFailure(', $automaticSuccessIndex, [StringComparison]::Ordinal)
if ($automaticSuccessIndex -lt 0 -or $automaticFailureIndex -le $automaticSuccessIndex) {
    throw 'Automatic success boundary is not recognizable.'
}
$automaticSuccessText = $singleTargetBlockRunText.Substring(
    $automaticSuccessIndex, $automaticFailureIndex - $automaticSuccessIndex)
if (-not $automaticSuccessText.Contains('finishAndResume(', [StringComparison]::Ordinal) `
        -or $automaticSuccessText.Contains('MAIN.postDelayed(', [StringComparison]::Ordinal) `
        -or $automaticSuccessText.Contains('next();', [StringComparison]::Ordinal)) {
    throw 'Automatic success must release into a fresh manual-first drain, not continue under the same scheduler owner.'
}
if ((Get-PatchletLiteralCount -Text $autoBlockSourceText `
            -Literal 'private static final String LEGACY_KEY_TARGET_CACHE = "list_threads_targets";') -ne 1 `
        -or $autoBlockSourceText.Contains('getString(LEGACY_KEY_TARGET_CACHE', [StringComparison]::Ordinal) `
        -or $autoBlockSourceText.Contains('putString(LEGACY_KEY_TARGET_CACHE', [StringComparison]::Ordinal) `
        -or $autoBlockSourceText.Contains('encodeTargets(', [StringComparison]::Ordinal) `
        -or $autoBlockSourceText.Contains('decodeTargets(', [StringComparison]::Ordinal)) {
    throw 'Retired SharedPreferences batch list is not deletion-only.'
}
foreach ($requiredDoneStateText in @(
        'static synchronized Set<String> doneIdsForScheduler(',
        'Map<String, ?> values = preferences.getAll();',
        'if (!(raw instanceof Set<?>))',
        'if (stored.size() > MAX_DONE_IDS)',
        'return done.size() == stored.size() ? done : null;',
        'static synchronized boolean markAutomaticDone(',
        'done == null',
        '!done.contains(targetId) && done.size() >= MAX_DONE_IDS')) {
    if (-not $modStateSourceText.Contains(
            $requiredDoneStateText, [StringComparison]::Ordinal)) {
        throw "Completed-target state does not fail closed on corrupt or oversized data: $requiredDoneStateText"
    }
}
if ($modStateSourceText.Contains('getStringSet(', [StringComparison]::Ordinal)) {
    throw 'Completed-target persistence may not use crash-prone getStringSet reads.'
}
foreach ($throwableSafeSource in @($autoBlockSourceText, $modStateSourceText)) {
    if ([regex]::IsMatch(
            $throwableSafeSource,
            '(?i)(safeMessage\s*\(|\.\s*get(?:Localized)?Message\s*\(|printStackTrace\s*\(|getStackTraceString\s*\()')) {
        throw 'Passive scheduler/state source may not copy raw Throwable messages.'
    }
}
foreach ($requiredStoreSourceText in @(
        'target_id TEXT PRIMARY KEY NOT NULL',
        'CREATE INDEX blocklist_targets_username_idx',
        'CREATE UNIQUE INDEX blocklist_targets_username_idx ON blocklist_targets',
        'h32 INTEGER NOT NULL CHECK(h32 BETWEEN 0 AND 4294967295)',
        'INSERT INTO blocklist_targets (target_id,username,username_key,h32) ',
        'DELETE FROM blocklist_targets WHERE h32 BETWEEN ? AND ?',
        'database.beginTransaction();',
        'database.setTransactionSuccessful();',
        'Set<String> usernames = new HashSet<String>(source.size());',
        '!usernames.add(usernameKey)',
        'Instant.parse(cleanUpdatedAt).toEpochMilli() != verifiedUpdatedAtMs',
        'parsedUpdatedAtMs = Instant.parse(updatedAt).toEpochMilli();',
        'parsedUpdatedAtMs != updatedAtMs',
        'SELECT count(DISTINCT username_key) FROM blocklist_targets',
        'requireUniqueUsername(database, usernameKey)',
        'BlocklistStore.isCurrentIdMatch')) {
    $storeContractText = if ($requiredStoreSourceText.StartsWith(
            'BlocklistStore.', [StringComparison]::Ordinal)) {
        $autoBlockSourceText
    } else {
        $blocklistStoreSourceText
    }
    if (-not $storeContractText.Contains(
            $requiredStoreSourceText, [StringComparison]::Ordinal)) {
        throw "Indexed database authority omits '$requiredStoreSourceText'."
    }
}
$signedParserIndex = $autoBlockSourceText.IndexOf(
    'private static VerifiedList parseAndVerify(', [StringComparison]::Ordinal)
$signatureVerifierIndex = $autoBlockSourceText.IndexOf(
    'private static boolean verifySignature(', $signedParserIndex,
    [StringComparison]::Ordinal)
if ($signedParserIndex -lt 0 -or $signatureVerifierIndex -le $signedParserIndex) {
    throw 'Signed passive-list parser boundaries are not recognizable.'
}
$signedParserText = $autoBlockSourceText.Substring(
    $signedParserIndex, $signatureVerifierIndex - $signedParserIndex)
$signedRootSteps = @(
    'if (body.length() > MAX_ROOT_BYTES)',
    'JSONObject envelope = new JSONObject(body);',
    'signatureValid = verifySignature(payloadJson, signature);',
    'long publishedAt = parseInstant(updatedAt);',
    'if (previousPublishedAt > 0L && publishedAt < previousPublishedAt)',
    'Object versionValue = payload.opt("v");',
    'if (!(versionValue instanceof Integer) || ((Integer) versionValue).intValue() != 3)',
    'signed root is not v3',
    'if (!(hashValue instanceof String) || !"sha256-hi32".equals((String) hashValue))',
    'signed root bucket function is not sha256-hi32',
    'if (maxChunkRows > MAX_CHUNK_ROWS || maxChunkBytes > MAX_CHUNK_GZ_BYTES)',
    'signed root chunk caps exceed the local caps',
    'if (!(threadsValue instanceof JSONObject))',
    'signed root has no threads partition',
    'if (bucketBits > MAX_BUCKET_BITS || groupBits > MAX_GROUP_BITS)',
    'signed root exceeds the local bucket cap',
    'if (total > MAX_INDEX_ROWS)',
    'signed root exceeds the local row cap',
    'if (groupTable.length() != groupCount)',
    'return new VerifiedList(')
$previousRootStepIndex = -1
foreach ($signedRootStep in $signedRootSteps) {
    $rootStepIndex = $signedParserText.IndexOf($signedRootStep, [StringComparison]::Ordinal)
    if ($rootStepIndex -le $previousRootStepIndex) {
        throw "Signed root parser must verify the envelope, timestamps, version, bucket function, caps and threads partition in order: $signedRootStep"
    }
    $previousRootStepIndex = $rootStepIndex
}
if ($signedParserText.Contains('optJSONArray("targets")', [StringComparison]::Ordinal) `
        -or $signedParserText.Contains('targets.optJSONObject(i)', [StringComparison]::Ordinal) `
        -or $signedParserText.Contains('MAX_TARGETS', [StringComparison]::Ordinal) `
        -or $signedParserText.Contains('optInt(', [StringComparison]::Ordinal) `
        -or $signedParserText.Contains('continue;', [StringComparison]::Ordinal)) {
    throw 'Signed root parser must not read a whole-file target array or coerce root fields.'
}
$chunkInstallerSourceText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'assets\autoblock\java\threadsmod\autoblock\ChunkInstaller.java')
$objectFetcherSourceText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'assets\autoblock\java\threadsmod\autoblock\ObjectFetcher.java')
$chunkRowIndex = $chunkInstallerSourceText.IndexOf(
    'private static void parseRow(', [StringComparison]::Ordinal)
$chunkBucketOfIndex = $chunkInstallerSourceText.IndexOf(
    'private static int bucketOf(long h32, int bits)', $chunkRowIndex, [StringComparison]::Ordinal)
if ($chunkRowIndex -lt 0 -or $chunkBucketOfIndex -le $chunkRowIndex) {
    throw 'Chunk row parser boundaries are not recognizable.'
}
$chunkRowText = $chunkInstallerSourceText.Substring($chunkRowIndex, $chunkBucketOfIndex - $chunkRowIndex)
$chunkRowSteps = @(
    'if (reader.peek() != JsonToken.BEGIN_OBJECT)',
    'chunk row is not a JSON object',
    'reader.beginObject();',
    'if ("i".equals(key))',
    'if ("u".equals(key))',
    'reader.skipValue();',
    'reader.endObject();',
    'if (reader.peek() != JsonToken.END_DOCUMENT)',
    'if (!AutoBlockSync.isDecimalId(id) || id.length() > MAX_ID_CHARS)',
    'AutoBlockSync.cleanSignedUsername(username)',
    'chunk threads id row has malformed username metadata',
    'BlocklistStore.bucketHash(ID_KEY_PREFIX + id)',
    'if (bucketOf(h32, bucketBits) != bucket)',
    'chunk row belongs to a different bucket',
    'if (!ids.add(id))',
    'chunk rows contain a duplicate numeric id',
    'if (!usernameKeys.add(clean.toLowerCase(Locale.US)))',
    'chunk rows have conflicting normalized usernames',
    'entries.add(new BlocklistStore.Entry(id, clean, h32));',
    'BlocklistStore.bucketHash(HANDLE_KEY_PREFIX + username)',
    'if (bucketOf(handleHash, bucketBits) != bucket)')
$previousRowStepIndex = -1
foreach ($chunkRowStep in $chunkRowSteps) {
    $rowStepIndex = $chunkRowText.IndexOf($chunkRowStep, [StringComparison]::Ordinal)
    if ($rowStepIndex -le $previousRowStepIndex) {
        throw "Chunk row parser must validate shape, id grammar, username, bucket membership and uniqueness in order: $chunkRowStep"
    }
    $previousRowStepIndex = $rowStepIndex
}
foreach ($chunkRejectionLiteral in @(
        'chunk row is not a JSON object',
        'chunk threads id row has malformed username metadata',
        'chunk rows contain a duplicate numeric id',
        'chunk rows have conflicting normalized usernames',
        'chunk is not valid gzip NDJSON',
        'group table is not the v3 threads group the root named',
        'private static final String ID_KEY_PREFIX = "threads:";',
        'private static final String HANDLE_KEY_PREFIX = "threads:@";')) {
    if ((Get-PatchletLiteralCount -Text $chunkInstallerSourceText -Literal $chunkRejectionLiteral) -ne 1) {
        throw "Chunk installer must carry exactly one fixed rejection literal: $chunkRejectionLiteral"
    }
}
if ($chunkInstallerSourceText.Contains('setLenient(true)', [StringComparison]::Ordinal) `
        -or $chunkInstallerSourceText.Contains('HttpsURLConnection', [StringComparison]::Ordinal) `
        -or $chunkInstallerSourceText.Contains('PASSIVE_ADMISSION_LOCK', [StringComparison]::Ordinal) `
        -or $chunkInstallerSourceText.Contains('replaceVerified(', [StringComparison]::Ordinal) `
        -or $objectFetcherSourceText.Contains('JsonReader', [StringComparison]::Ordinal) `
        -or $objectFetcherSourceText.Contains('GZIPInputStream', [StringComparison]::Ordinal) `
        -or $objectFetcherSourceText.Contains('BlocklistStore', [StringComparison]::Ordinal) `
        -or -not $objectFetcherSourceText.Contains('setRequestProperty("Accept-Encoding", "identity")', [StringComparison]::Ordinal) `
        -or -not $objectFetcherSourceText.Contains('signed root names an object whose bytes do not match', [StringComparison]::Ordinal)) {
    throw 'Object fetching and chunk parsing must stay separated: the fetcher proves bytes against the signed name with identity encoding, the installer parses strictly and never opens a connection or commits.'
}
foreach ($throwableSafeSource in @($chunkInstallerSourceText, $objectFetcherSourceText)) {
    if ([regex]::IsMatch(
            $throwableSafeSource,
            '(?i)(safeMessage\s*\(|\.\s*get(?:Localized)?Message\s*\(|printStackTrace\s*\(|getStackTraceString\s*\()')) {
        throw 'Object fetcher and chunk installer source may not copy raw Throwable messages.'
    }
}
foreach ($requiredVisibleIdentityText in @(
        'visibleUsernameMatchesStoredLocked(',
        'stored.equals(visible)')) {
    if (-not $autoBlockSourceText.Contains(
            $requiredVisibleIdentityText, [StringComparison]::Ordinal)) {
        throw "Signed import or stored-visible username binding omits '$requiredVisibleIdentityText'."
    }
}
if ((Get-PatchletLiteralCount -Text $blocklistStoreSourceText `
            -Literal 'Instant.parse(') -ne 2 `
        -or (Get-PatchletLiteralCount -Text $blocklistStoreSourceText `
            -Literal 'requireUniqueUsername(') -ne 3) {
    throw 'Timestamp text/millisecond rebinding and per-result username uniqueness are not exact.'
}
$usernameLookupIndex = $blocklistStoreSourceText.IndexOf(
    'public static UsernameMetadata lookupUsernameMetadata(',
    [StringComparison]::Ordinal)
$snapshotIndex = $blocklistStoreSourceText.IndexOf(
    'public static Snapshot snapshot(', $usernameLookupIndex,
    [StringComparison]::Ordinal)
if ($usernameLookupIndex -lt 0 -or $snapshotIndex -le $usernameLookupIndex) {
    throw 'BlocklistStore does not expose a bounded username metadata lookup.'
}
$usernameLookupText = $blocklistStoreSourceText.Substring(
    $usernameLookupIndex, $snapshotIndex - $usernameLookupIndex)
if ($usernameLookupText.Contains('target_id', [StringComparison]::Ordinal) `
        -or $usernameLookupText.Contains('targetId', [StringComparison]::Ordinal)) {
    throw 'Username metadata lookup improperly exposes mutation-authoritative target IDs.'
}
foreach ($memoryOnlyVisibilityForbidden in @(
        'BlocklistStore', 'ThreadsBlockBridge', 'SharedPreferences', 'SQLite')) {
    if ($visibilityTemplateText.Contains(
            $memoryOnlyVisibilityForbidden, [StringComparison]::Ordinal)) {
        throw "Viewport callback contains forbidden storage or mutation authority '$memoryOnlyVisibilityForbidden'."
    }
}
$resolvedEndpointOrder = @($readEndpointTarget[0].orderedStrings | ForEach-Object {
    [string]$_
})
if (($resolvedEndpointOrder -join "`n") -ne ($expectedReadEndpoints -join "`n")) {
    throw 'CloneBlockerEndpoints targeted JADX contract does not preserve exact read failover order.'
}
if ($reportClientTarget.Count -ne 1 `
        -or [int]$reportClientTarget[0].exactStringCounts.'isValidForNewQueue()' -ne 1) {
    throw 'Resolution must have one targeted JADX ReportClient contract.'
}
$reportControllerRequiredStrings = @($reportControllerTarget[0].requiredStrings | ForEach-Object {
    [string]$_
})
foreach ($requiredReportControllerText in @(
        'ReportClient.queueExplicit(',
        'isValidForNewQueue()',
        'AutoBlockSync.getForegroundActivity()',
        'AutoBlockSync.getCurrentViewer()',
        'The report target, reason, or foreground activity is invalid.')) {
    if ($reportControllerRequiredStrings -notcontains $requiredReportControllerText) {
        throw "ReportController targeted JADX contract is missing '$requiredReportControllerText'."
    }
}
$reportControllerForbiddenStrings = @($reportControllerTarget[0].forbiddenStrings | ForEach-Object {
    [string]$_
})
foreach ($forbiddenReportControllerText in @(
        'ReportDialog',
        'showFromForeground(',
        'prepareExplicit(',
        'submitPrepared(')) {
    if ($reportControllerForbiddenStrings -notcontains $forbiddenReportControllerText) {
        throw "ReportController targeted JADX contract does not forbid retired UI flow '$forbiddenReportControllerText'."
    }
}
$reportStoreRequiredStrings = @($reportStoreTarget[0].requiredStrings | ForEach-Object {
    [string]$_
})
foreach ($requiredReportStoreText in @(
        'report_outbox_v1',
        'report database migration row count mismatch',
        'report database upgrade requires reviewed migration')) {
    if ($reportStoreRequiredStrings -notcontains $requiredReportStoreText) {
        throw "ReportStore targeted JADX contract is missing '$requiredReportStoreText'."
    }
}
$reportStoreForbiddenStrings = @($reportStoreTarget[0].forbiddenStrings | ForEach-Object {
    [string]$_
})
if ($reportStoreForbiddenStrings -notcontains 'A report for this profile is already queued') {
    throw 'ReportStore targeted JADX contract does not forbid retired target-level report dedupe.'
}
$reportClientJadxStrings = @($reportClientTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredReportClientText in @(
        'isValidForNewQueue()',
        'ReportStore.reserveNextDue(',
        'ReportEndpoint.writeUrl()',
        'setRequestMethod(',
        'setInstanceFollowRedirects(false)',
        'getOutputStream()')) {
    if ($reportClientJadxStrings -notcontains $requiredReportClientText) {
        throw "ReportClient targeted JADX contract is missing '$requiredReportClientText'."
    }
}
$reportValuesRequiredStrings = @($reportValuesTarget[0].requiredStrings | ForEach-Object {
    [string]$_
})
foreach ($requiredReportValuesText in @(
        'httpsThreadsPermalink(', 'normalizeUsername(', 'new URI(',
        'getScheme()', 'getHost()', 'isOpaque()', 'getUserInfo()', 'getPort()',
        'getRawQuery()', 'getRawFragment()', 'getRawPath()', 'www.threads.com',
        'www.threads.net', 'getRawAuthority()', '/@', '/post/',
        'https://www.threads.com/@')) {
    if ($reportValuesRequiredStrings -notcontains $requiredReportValuesText) {
        throw "ReportValues targeted JADX contract is missing '$requiredReportValuesText'."
    }
}
$activityTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'com.threadsmod.CloneBlockerActivity'
    })
if ($activityTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX CloneBlockerActivity contract.'
}
$activityRequiredStrings = @($activityTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredActivityText in @(
        '"Activity data needs review"',
        '"Current status"',
        '"Overview"',
        '"Passive block list"',
        '"Refreshes every 10 minutes while Threads is foreground. Only listed profiles whose post or reply action row is actually visible are admitted to blocking."',
        'AutoBlockSync.isRefreshingList()',
        'AutoBlockSync.getListStatus(',
        'postDelayed(',
        'removeCallbacks(',
        'live block-list status refresh stopped',
        '"Report outbox"',
        '"Manual queue"',
        '"History"')) {
    if ($activityRequiredStrings -notcontains $requiredActivityText) {
        throw "CloneBlockerActivity targeted JADX contract is missing '$requiredActivityText'."
    }
}
$activityOrderedStrings = @($activityTarget[0].orderedStrings | ForEach-Object { [string]$_ })
if (($activityOrderedStrings -join "`n") -ne (
        @('setContentView(this.scroll);', 'ModStateStore.snapshot(this);') -join "`n")) {
    throw 'CloneBlockerActivity targeted JADX contract does not prove shell attachment before state reads.'
}
$activityForbiddenStrings = @($activityTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
if (($activityForbiddenStrings -join "`n") -ne 'setLayoutParams(null)') {
    throw 'CloneBlockerActivity targeted JADX contract does not reject null layout parameters.'
}
if ($modStateTarget.Count -ne 1) {
    throw 'Resolution must have one targeted JADX ModStateStore passive snapshot contract.'
}
$modStateRequiredStrings = @(
    $modStateTarget[0].requiredStrings | ForEach-Object { [string]$_ })
foreach ($requiredPassiveSnapshotText in @(
        'BlocklistStore.snapshot(',
        '.targetCount',
        '.fetchedAtMs',
        '.verifiedUpdatedAt',
        'done_threads_',
        'doneIdsForScheduler(',
        'readDoneIds(',
        '.getAll()',
        'instanceof Set',
        'MAX_DONE_IDS',
        'markAutomaticDone(')) {
    if ($modStateRequiredStrings -notcontains $requiredPassiveSnapshotText) {
        throw "ModStateStore targeted JADX contract is missing passive snapshot field '$requiredPassiveSnapshotText'."
    }
}
$modStateForbiddenStrings = @(
    $modStateTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
foreach ($forbiddenPassiveStateRecovery in @(
        'getStringSet(',
        'safeMessage(',
        'getMessage(',
        'getLocalizedMessage(',
        'printStackTrace(',
        'getStackTraceString(')) {
    if ($modStateForbiddenStrings -notcontains $forbiddenPassiveStateRecovery) {
        throw "ModStateStore targeted recovery does not forbid unsafe state/error flow '$forbiddenPassiveStateRecovery'."
    }
}
$settingsPassiveDisclosure =
        'Always on. Refreshes the signed index every 10 minutes in the foreground, then blocks only listed profiles whose post or reply action row becomes visible.'
if (@($resolution.release.requiredHookCalls | Where-Object {
            [string]$_ -ceq $settingsPassiveDisclosure
        }).Count -ne 1) {
    throw 'Resolution final-DEX requirements omit the exact foreground-only Settings passive disclosure.'
}
foreach ($currentPassiveFinalDexMarker in @(
        'limit_passive_min_delay_ms',
        'limit_passive_max_delay_ms',
        'List fetch:',
        'Records:',
        'New this refresh:',
        'Database index:',
        'Inline control:',
        'hook_seen',
        'button_rendered',
        'report_request_unavailable',
        'adapter_exception',
        '(no text in this post)')) {
    if (@($resolution.release.requiredHookCalls | Where-Object {
                [string]$_ -ceq $currentPassiveFinalDexMarker
            }).Count -ne 1) {
        throw "Resolution final-DEX requirements omit current passive/UI marker '$currentPassiveFinalDexMarker'."
    }
}
if (@($resolution.release.requiredHookCalls | Where-Object {
            [string]$_ -ceq 'limit_automatic_per_hour'
        }).Count -ne 0) {
    throw 'A retired automatic capacity key remains a positive final-DEX hook requirement.'
}
$activitySourceText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'assets\autoblock\java\com\threadsmod\CloneBlockerActivity.java')
$settingsSourceText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'assets\autoblock\java\com\threadsmod\CloneBlockerSettingsActivity.java')
$modStateSourceText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'assets\autoblock\java\threadsmod\autoblock\ModStateStore.java')
foreach ($passiveActivitySourceProof in @(
        'Refreshes every 10 minutes while Threads is foreground. Only listed profiles whose post or reply action row is actually visible are admitted to blocking.',
        'CloneBlockerUi.sectionTitle(this, "Current status")',
        'AutoBlockSync.getListStatus(this)',
        'STATUS_POLL_INTERVAL_MS',
        'statusHandler.postDelayed(',
        'statusHandler.removeCallbacks(')) {
    if (-not $activitySourceText.Contains(
            $passiveActivitySourceProof, [StringComparison]::Ordinal)) {
        throw "CloneBlockerActivity canonical passive status omits '$passiveActivitySourceProof'."
    }
}
if (-not $settingsSourceText.Contains(
        $settingsPassiveDisclosure, [StringComparison]::Ordinal) `
        -or -not $activitySourceText.Contains(
            'AutoBlockSync.isRefreshingList()', [StringComparison]::Ordinal) `
        -or -not $settingsSourceText.Contains(
            'AutoBlockSync.isRefreshingList()', [StringComparison]::Ordinal) `
        -or -not $settingsSourceText.Contains(
            'AutoBlockSync.getListStatus(this)', [StringComparison]::Ordinal) `
        -or -not $settingsSourceText.Contains(
            'statusHandler.postDelayed(', [StringComparison]::Ordinal) `
        -or -not $settingsSourceText.Contains(
            'statusHandler.removeCallbacks(', [StringComparison]::Ordinal) `
        -or -not $modStateSourceText.Contains(
            'BlocklistStore.Snapshot blocklist = BlocklistStore.snapshot(context);',
            [StringComparison]::Ordinal) `
        -or -not $modStateSourceText.Contains(
            'blocklist.valid ? blocklist.targetCount : 0',
            [StringComparison]::Ordinal) `
        -or $settingsSourceText.Contains(
            'background refresh', [StringComparison]::OrdinalIgnoreCase) `
        -or $settingsSourceText.Contains(
            'profile header becomes visible', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Activity/Settings passive status is not indexed, foreground-only, post/reply-visible-only, and snapshot-backed.'
}
$postContracts = @($resolution.release.requiredDexDirectStringCalls)
if ($postContracts.Count -ne 1) {
    throw 'Resolution must have exactly one DEX direct-string call contract.'
}
$postContract = $postContracts[0]
if ([string]$postContract.id -ne 'report-client-post' `
        -or [string]$postContract.ownerClassDescriptor -ne 'Lthreadsmod/reporting/ReportClient;' `
        -or [string]$postContract.ownerMethodName -ne 'post' `
        -or [string]$postContract.ownerMethodDescriptor `
            -ne '(Lthreadsmod/reporting/ReportPayload;Ljava/lang/String;I)Lthreadsmod/reporting/ReportClient$TransportResult;' `
        -or [string]$postContract.calleeClassDescriptor -ne 'Ljavax/net/ssl/HttpsURLConnection;' `
        -or [string]$postContract.calleeMethodName -ne 'setRequestMethod' `
        -or [string]$postContract.calleeMethodDescriptor -ne '(Ljava/lang/String;)V' `
        -or [string]$postContract.invokeOpcode -ne 'INVOKE_VIRTUAL' `
        -or [int]$postContract.stringParameterIndex -ne 0 `
        -or [string]$postContract.literal -ne 'POST' `
        -or [int]$postContract.expectedOccurrences -ne 1 `
        -or -not [bool]$postContract.requireImmediateConstString `
        -or -not [bool]$postContract.requireOnlyCalleeOccurrence) {
    throw 'Resolution DEX direct-string call contract differs from the reviewed ReportClient POST flow.'
}
$bridgeFlowContracts = @($resolution.release.requiredDexBridgeFlows)
if ($bridgeFlowContracts.Count -ne 1) {
    throw 'Resolution must have exactly one signed-DEX direct-ID bridge-flow contract.'
}
$bridgeFlowContract = $bridgeFlowContracts[0]
if ([string]$bridgeFlowContract.id -ne 'threads-block-bridge-flow-v1' `
        -or [string]$bridgeFlowContract.ownerClassDescriptor `
            -ne 'Lthreadsmod/autoblock/ThreadsBlockBridge;' `
        -or [string]$bridgeFlowContract.blockMethodName -ne 'block' `
        -or [string]$bridgeFlowContract.blockResolvedMethodName -ne 'blockResolved' `
        -or [string]$bridgeFlowContract.blockModelMethodName -ne 'blockModel' `
        -or [string]$bridgeFlowContract.prepareModelMethodName -ne 'prepareModel' `
        -or [string]$bridgeFlowContract.passivePreflightMethodName -ne 'passivePreflight' `
        -or [string]$bridgeFlowContract.automaticCallerClassDescriptor `
            -ne 'Lthreadsmod/autoblock/AutoBlockSync$BlockRun;' `
        -or [string]$bridgeFlowContract.manualCallerClassDescriptor `
            -ne 'Lthreadsmod/autoblock/AutoBlockSync$ManualBlockRun;' `
        -or [string]$bridgeFlowContract.fetchWorkerRunMethodReference `
            -ne 'Lthreadsmod/autoblock/AutoBlockSync$FetchWorker;->run()V' `
        -or [string]$bridgeFlowContract.scheduleManualDrainMethodReference `
            -ne 'Lthreadsmod/autoblock/AutoBlockSync;->scheduleManualDrain(J)V' `
        -or [string]$bridgeFlowContract.symbolsPointer -ne '/bridge/symbols' `
        -or [string]$bridgeFlowContract.inlineSymbolsPointer -ne '/inlineControls/symbols' `
        -or [string]$bridgeFlowContract.expectedDexName -ne 'classes.dex' `
        -or [int]$bridgeFlowContract.expectedBlockInvokeCount -ne 3 `
        -or [int]$bridgeFlowContract.expectedBlockResolvedInvokeCount -ne 1 `
        -or [int]$bridgeFlowContract.expectedBlockModelInvokeCount -ne 2 `
        -or [int]$bridgeFlowContract.expectedPrepareModelInvokeCount -ne 2 `
        -or [int]$bridgeFlowContract.expectedPassivePreflightInvokeCount -ne 1 `
        -or [int]$bridgeFlowContract.expectedCacheLookupInvokeCount -ne 2 `
        -or [int]$bridgeFlowContract.expectedCacheFactoryInvokeCount -ne 2 `
        -or [int]$bridgeFlowContract.expectedCachePlaceholderInvokeCount -ne 2 `
        -or -not [bool]$bridgeFlowContract.requirePassivePreflightBeforeReservation `
        -or -not [bool]$bridgeFlowContract.requireNarrowSeamHandlers `
        -or -not [bool]$bridgeFlowContract.requirePreparationResultFlow `
        -or -not [bool]$bridgeFlowContract.requireCallerProvenance `
        -or -not [bool]$bridgeFlowContract.requireCallerCatchTopology `
        -or -not [bool]$bridgeFlowContract.requireDirectCallerCallbackExecution `
        -or -not [bool]$bridgeFlowContract.requireCallerCallbackEffectTopology `
        -or -not [bool]$bridgeFlowContract.requireCallbackExceptionalControlFlow `
        -or -not [bool]$bridgeFlowContract.requireBridgeEntryReachability `
        -or -not [bool]$bridgeFlowContract.requireSchedulerEnqueueAcceptance `
        -or -not [bool]$bridgeFlowContract.requireUncertainMutationQuarantine `
        -or -not [bool]$bridgeFlowContract.requirePrivateSeamCallProvenance `
        -or -not [bool]$bridgeFlowContract.requireStableInlinePrivateSeamAbsence `
        -or -not [bool]$bridgeFlowContract.requireDispatcherCallProvenance `
        -or -not [bool]$bridgeFlowContract.requireAsyncCallbackFirewall `
        -or -not [bool]$bridgeFlowContract.requireTerminalCallbackMap `
        -or -not [bool]$bridgeFlowContract.requireImmutableTargetFlow `
        -or -not [bool]$bridgeFlowContract.requireModelIdGuard `
        -or -not [bool]$bridgeFlowContract.requireNativeMutationIdentity) {
    throw 'Resolution signed-DEX bridge-flow contract differs from the reviewed direct-ID safety flow.'
}
$manifests = @{}
foreach ($entry in @($catalog.patchlets)) {
    $manifestPath = Resolve-PatchletChildPath -Root $patchletsRoot -Child ([string]$entry.path)
    if (-not (Test-Json -LiteralPath $manifestPath -SchemaFile (Join-Path $patchletsRoot 'schemas\patchlet.schema.json') -ErrorAction Stop)) { throw "Patchlet manifest failed schema validation: $manifestPath" }
    $manifest = Read-PatchletJson -Path $manifestPath
    if ([string]$manifest.id -ne [string]$entry.id) { throw "Catalog ID '$($entry.id)' does not match manifest ID '$($manifest.id)'." }
    $manifests[[string]$entry.id] = $manifest
}
$sourcePreparationManifest = $manifests['005-split-source-universalization']
$expectedSourcePreparationGates = @(
    'exact-split-source-set',
    'split-role-manifest-contract',
    'pinned-apkeditor-contract',
    'deterministic-universalization',
    'universal-payload-preservation',
    'universal-standalone-manifest',
    'universal-unsigned-boundary'
)
$expectedArchiveTransforms = @(
    'split-set-to-standalone-apk',
    'split-delivery-metadata-removal'
)
$sourcePreparationOperations = @($sourcePreparationManifest.operations | Where-Object {
        [string]$_.id -eq 'derive-standalone-apk'
    })
if ([int]$sourcePreparationManifest.revision -ne 1 `
        -or [string]$sourcePreparationManifest.stage -ne 'prepare' `
        -or [string]$sourcePreparationManifest.resolution.binding `
            -ne 'exact-split-set-and-derived-apk-sha256' `
        -or [string]$sourcePreparationManifest.ai.taskTemplate `
            -ne '../../ai/tasks/RESOLVE-SPLIT-SOURCE-UNIVERSALIZATION.md' `
        -or @(Compare-Object @($sourcePreparationManifest.ownership.archiveTransforms) `
            $expectedArchiveTransforms -SyncWindow 0).Count -ne 0 `
        -or @(Compare-Object @($sourcePreparationManifest.releaseGates) `
            $expectedSourcePreparationGates -SyncWindow 0).Count -ne 0 `
        -or $sourcePreparationOperations.Count -ne 1 `
        -or [string]$sourcePreparationOperations[0].type -ne 'deterministic-split-merge' `
        -or [string]$sourcePreparationOperations[0].idempotency -ne 'deterministic-output-hash') {
    throw 'Patchlet 005 identity, ownership, operation, AI task, or ordered gates drifted.'
}
$expectedApkEditorArguments = @(
    'm', '-i', '{sourceSet}', '-o', '{outputApk}',
    '-clean-meta', '-validate-modules', '-extractNativeLibs', 'false'
)
if ([string]$resolution.source.delivery -ne 'split-apk-set' `
        -or @($resolution.source.splitMembers).Count -ne 3 `
        -or [string]$resolution.source.splitMembers[0].role -ne 'base' `
        -or [string]$resolution.source.splitMembers[1].role -ne 'abi' `
        -or [string]$resolution.source.splitMembers[2].role -ne 'density' `
        -or [string]$resolution.toolchain.apkEditorVersion -ne '1.4.9' `
        -or [string]$resolution.toolchain.apkEditorArscLibVersion -ne '1.3.9' `
        -or @(Compare-Object @($resolution.toolchain.apkEditorMergeArguments) `
            $expectedApkEditorArguments -SyncWindow 0).Count -ne 0 `
        -or (Get-PatchletSha256 -Path (Join-Path $repositoryRoot '.tools\apkeditor\APKEditor-1.4.9.jar')) `
            -ne [string]$resolution.toolchain.apkEditorJarSha256) {
    throw 'Resolution split-source topology or pinned APKEditor contract drifted.'
}
$requiredHandoffPostconditions = [ordered]@{
    '005-split-source-universalization' = @(
        'merge-is-byte-reproducible',
        'payloads-are-preserved',
        'derived-apk-is-standalone',
        'derived-apk-is-unsigned'
    )
    '020-autoblock-runtime' = @(
        'manual-model-hint-reservation-order',
        'closed-block-diagnostic-contract',
        'bridge-callback-firewall-contract',
        'bridge-caller-catch-contract',
        'bridge-caller-callback-effect-contract',
        'scheduler-wake-enqueue-contract',
        'uncertain-mutation-review-contract',
        'confirmed-success-quarantine-contract',
        'passive-index-contract',
        'passive-refresh-contract',
        'passive-visible-scheduler-contract'
    )
    '030-native-block-bridge' = @(
        'resolved-model-id-match',
        'null-model-native-cache-placeholder-fallback',
        'legacy-profile-lookup-removed',
        'bridge-failure-stage-vocabulary-closed',
        'bridge-private-seam-handlers-narrow',
        'bridge-entry-reachability-exact',
        'native-callbacks-cross-asynchronous-firewall'
    )
    '050-mod-settings-ui' = @(
        'passive-status-is-truthful'
    )
    '060-inline-block-controls' = @(
        'combined-action-routing',
        'compact-combined-dialog-present',
        'combined-dialog-is-single-step',
        'shared-inline-hook-has-one-control',
        'inline-host-bound-snapshot',
        'inline-author-model-handoff',
        'inline-profile-username-label',
        'inline-pre-enqueue-diagnostics',
        'passive-viewport-observer',
        'inline-stable-media-key-and-report-request-guard'
    )
    '070-consented-reporting' = @(
        'report-shared-row-snapshot',
        'report-post-permalink',
        'explicit-combined-submit-only',
        'report-submit-owner-bound',
        'outbox-before-network',
        'report-database-v1-to-v2-migration',
        'report-block-independent'
    )
    '080-socks5-proxy' = @(
        'proxy-components-private',
        'proxy-bootstrap-exact',
        'proxy-state-fails-closed',
        'proxy-bypass-exact-and-bounded',
        'proxy-native-pinned',
        'proxy-license-notice-pinned',
        'proxy-runtime-boundary-truthful'
    )
    '090-release-gates' = @(
        'split-source-and-derived-bindings-are-complete',
        'split-universalization-precedes-normal-replay',
        'signed-review-evidence-cannot-publish',
        'combined-modal-report-contract-is-proven',
        'report-post-permalink-is-signed-dex-bound',
        'release-tool-parameters-remain-compatible',
        'release-tool-evidence-remains-compatible',
        'bridge-inspector-argument-count-remains-compatible',
        'ambiguous-report-label-collision-stays-excluded',
        'ambiguous-pristine-socks-port-collision-stays-excluded',
        'inline-model-handoff-remains-fail-closed',
        'closed-block-diagnostics-remain-safe',
        'direct-id-bridge-signed-dex-flow-is-exact',
        'confirmed-success-never-retries-automatically',
        'scheduler-enqueue-rejection-fails-closed',
        'uncertain-mutation-never-retries-automatically',
        'inline-pre-enqueue-failures-remain-diagnosable',
        'inline-username-remains-display-only',
        'network-order-and-write-authority-remain-exact',
        'passive-index-is-sole-list-authority',
        'passive-refresh-never-creates-block-work',
        'passive-activity-status-is-truthful',
        'passive-viewport-observer-is-version-bound',
        'passive-visible-admission-is-finally-rechecked'
    )
}
foreach ($patchletId in $requiredHandoffPostconditions.Keys) {
    $postconditionIds = @($manifests[$patchletId].postconditions | ForEach-Object {
        [string]$_.id
    })
    foreach ($postconditionId in $requiredHandoffPostconditions[$patchletId]) {
        if (@($postconditionIds | Where-Object { $_ -eq $postconditionId }).Count -ne 1) {
            throw "Patchlet '$patchletId' does not own exact postcondition '$postconditionId'."
        }
    }
}
$requiredFeatureReleaseGates = [ordered]@{
    '005-split-source-universalization' = @(
        'exact-split-source-set',
        'split-role-manifest-contract',
        'pinned-apkeditor-contract',
        'deterministic-universalization',
        'universal-payload-preservation',
        'universal-standalone-manifest',
        'universal-unsigned-boundary'
    )
    '020-autoblock-runtime' = @(
        'bridge-callback-firewall-contract',
        'bridge-caller-catch-contract',
        'bridge-caller-callback-effect-contract',
        'scheduler-wake-enqueue-contract',
        'uncertain-mutation-review-contract',
        'confirmed-success-quarantine-contract',
        'passive-index-contract',
        'passive-refresh-contract',
        'passive-visible-scheduler-contract'
    )
    '030-native-block-bridge' = @(
        'bridge-private-seam-handler-contract',
        'bridge-entry-reachability-contract',
        'bridge-signed-dex-flow-contract',
        'bridge-callback-firewall-contract'
    )
    '050-mod-settings-ui' = @(
        'passive-activity-status-contract'
    )
    '060-inline-block-controls' = @(
        'compact-combined-dialog-contract',
        'inline-host-bound-snapshot-contract',
        'inline-pre-enqueue-diagnostic-contract',
        'passive-viewport-observer-contract',
        'inline-stable-media-key-and-report-request-guard-contract'
    )
    '070-consented-reporting' = @(
        'report-shared-row-snapshot-contract',
        'report-post-permalink-contract',
        'report-explicit-combined-submit',
        'report-submit-owner-binding',
        'report-retired-ui-absence',
        'report-outbox-retry-contract',
        'report-database-contract',
        'report-database-v1-to-v2-migration-contract',
        'report-block-independence'
    )
    '080-socks5-proxy' = @(
        'socks5-config-contract',
        'socks5-vpn-manifest-contract',
        'socks5-bootstrap-contract',
        'socks5-route-contract',
        'socks5-credential-contract',
        'socks5-native-contract',
        'socks5-license-contract',
        'socks5-static-dex-contract',
        'proxy-settings-activity-contract'
    )
}
foreach ($patchletId in $requiredFeatureReleaseGates.Keys) {
    $featureGates = @($manifests[$patchletId].releaseGates | ForEach-Object {
        [string]$_
    })
    foreach ($requiredGate in @($requiredFeatureReleaseGates[$patchletId])) {
        if (@($featureGates | Where-Object { $_ -eq $requiredGate }).Count -ne 1) {
            throw "Patchlet '$patchletId' does not require exact feature gate '$requiredGate'."
        }
    }
}

# Every canonical ownership declaration must be unique across the complete series. This turns
# ownership from documentation into a release gate and prevents two patchlets from rewriting or
# regenerating the same durable seam.
$ownershipFields = @(
    'classPrefixes',
    'classDescriptors',
    'rewriteRuleIds',
    'manifestComponents',
    'hostHooks',
    'preferenceKeys',
    'databaseSchemas',
    'archiveTransforms',
    'semanticProofIds'
)
$ownership = @{}
foreach ($field in $ownershipFields) { $ownership[$field] = @{} }
foreach ($entry in @($catalog.patchlets)) {
    $id = [string]$entry.id
    $owner = $manifests[$id].ownership
    foreach ($field in $ownershipFields) {
        $ownershipProperty = $owner.PSObject.Properties[$field]
        $ownedValues = if ($null -eq $ownershipProperty) { @() } else { @($ownershipProperty.Value) }
        foreach ($valueObject in $ownedValues) {
            $value = [string]$valueObject
            if ($ownership[$field].ContainsKey($value)) {
                throw "Ownership conflict for $field '$value': '$($ownership[$field][$value])' and '$id'."
            }
            $ownership[$field][$value] = $id
        }
    }
}
foreach ($prefixEntry in $ownership['classPrefixes'].GetEnumerator()) {
    foreach ($descriptorEntry in $ownership['classDescriptors'].GetEnumerator()) {
        if ($descriptorEntry.Key.StartsWith($prefixEntry.Key, [StringComparison]::Ordinal) `
                -and $descriptorEntry.Value -ne $prefixEntry.Value) {
            throw "Class descriptor '$($descriptorEntry.Key)' is covered by another patchlet's prefix '$($prefixEntry.Key)'."
        }
    }
}
if (-not $ownership['preferenceKeys'].ContainsKey(
        'completion_review_threads_<viewerId>') `
        -or [string]$ownership['preferenceKeys']['completion_review_threads_<viewerId>'] `
            -ne '020-autoblock-runtime') {
    throw 'Patchlet 020 must uniquely own the viewer-scoped completion-review preference key.'
}
if (-not $ownership['semanticProofIds'].ContainsKey(
        'user-cache-null-seed-user-id-callsite') `
        -or [string]$ownership['semanticProofIds']['user-cache-null-seed-user-id-callsite'] `
            -cne '090-release-gates' `
        -or @($manifests['090-release-gates'].ownership.semanticProofIds | Where-Object {
                [string]$_ -ceq 'user-cache-null-seed-user-id-callsite'
            }).Count -ne 1) {
    throw 'Patchlet 090 must uniquely own the descriptor-bound null-seed collision proof.'
}
if (-not $ownership['preferenceKeys'].ContainsKey('list_refresh_not_before') `
        -or [string]$ownership['preferenceKeys']['list_refresh_not_before'] `
            -ne '020-autoblock-runtime' `
        -or @($manifests['020-autoblock-runtime'].ownership.preferenceKeys | Where-Object {
                [string]$_ -ceq 'list_refresh_not_before'
            }).Count -ne 1) {
    throw 'Patchlet 020 must solely and exactly once own the durable list-refresh not-before preference.'
}
$expectedPassiveDatabaseSchemas = @(
    'database:threadsmod_blocklist.db:v3',
    'migration:threadsmod_blocklist.db:v1-to-v2',
    'migration:threadsmod_blocklist.db:v2-to-v3',
    'table:blocklist_targets:v3',
    'index:blocklist_targets_username_idx:v3',
    'index:blocklist_targets_h32_idx:v3',
    'table:blocklist_metadata:v3',
    'schema:blocklist_metadata.new_target_count:v2',
    'schema:blocklist_metadata.bucket_bits:v3',
    'table:blocklist_chunks:v3',
    'table:blocklist_groups:v3',
    'table:blocklist_staging:v3',
    'table:blocklist_targets_v2:retired-empty',
    'table:blocklist_metadata_v2:retired-empty'
)
$ownedPassiveDatabaseSchemas = @(
    $manifests['020-autoblock-runtime'].ownership.databaseSchemas | ForEach-Object {
        [string]$_
    })
if (($ownedPassiveDatabaseSchemas -join "`n") -ne (
            $expectedPassiveDatabaseSchemas -join "`n")) {
    throw 'Patchlet 020 must exactly own the indexed blocklist v3 database, its v1-to-v2 and v2-to-v3 migrations, tables, indexes, chunk/group/staging tables, bucket-bits metadata and the retired empty v2 tables.'
}
foreach ($databaseSchema in $expectedPassiveDatabaseSchemas) {
    if (-not $ownership['databaseSchemas'].ContainsKey($databaseSchema) `
            -or [string]$ownership['databaseSchemas'][$databaseSchema] `
                -ne '020-autoblock-runtime') {
        throw "Indexed passive database schema has no sole patchlet-020 owner: $databaseSchema"
    }
}
$settingsPreferenceKeys = @($manifests['050-mod-settings-ui'].ownership.preferenceKeys | ForEach-Object {
    [string]$_
})
if (-not $ownership['preferenceKeys'].ContainsKey('ui_also_block_profile') `
        -or [string]$ownership['preferenceKeys']['ui_also_block_profile'] `
            -ne '050-mod-settings-ui' `
        -or ($settingsPreferenceKeys -join "`n") -ne 'ui_also_block_profile') {
    throw 'Patchlet 050 must solely and uniquely own the persisted ui_also_block_profile preference.'
}
$proxyPreferenceKeys = @(
    'threadsmod_proxy_schema_version',
    'threadsmod_proxy_generation',
    'threadsmod_proxy_enabled',
    'threadsmod_proxy_host',
    'threadsmod_proxy_port',
    'threadsmod_proxy_auth_enabled',
    'threadsmod_proxy_credentials_ciphertext',
    'threadsmod_proxy_credentials_iv',
    'threadsmod_proxy_bypass_rules_v1',
    'threadsmod_proxy_fail_closed'
)
$ownedProxyPreferenceKeys = @(
    $manifests['080-socks5-proxy'].ownership.preferenceKeys |
        ForEach-Object { [string]$_ }
)
if (($ownedProxyPreferenceKeys -join "`n") -ne ($proxyPreferenceKeys -join "`n")) {
    throw 'Patchlet 080 must own the exact ordered SOCKS5 preference-key contract.'
}
foreach ($proxyPreferenceKey in $proxyPreferenceKeys) {
    if (-not $ownership['preferenceKeys'].ContainsKey($proxyPreferenceKey) `
            -or [string]$ownership['preferenceKeys'][$proxyPreferenceKey] `
                -ne '080-socks5-proxy') {
        throw "SOCKS5 preference key has the wrong owner: $proxyPreferenceKey"
    }
}
$proxyManifestComponents = @(
    $manifests['080-socks5-proxy'].ownership.manifestComponents |
        ForEach-Object { [string]$_ }
)
if (($proxyManifestComponents -join "`n") -ne (
        @('com.threadsmod.ProxySettingsActivity', 'threadsmod.proxy.Socks5VpnService') -join "`n")) {
    throw 'Patchlet 080 must own exactly the private proxy Settings Activity and VPN service.'
}
$proxyClassPrefixes = @(
    $manifests['080-socks5-proxy'].ownership.classPrefixes |
        ForEach-Object { [string]$_ }
)
if (($proxyClassPrefixes -join "`n") -ne (
        @('Lcom/threadsmod/ProxySettingsActivity', 'Lthreadsmod/proxy/') -join "`n")) {
    throw 'Patchlet 080 class-prefix ownership differs from the reviewed proxy families.'
}
$proxyRequiredDescriptors = @(
    'Lcom/threadsmod/ProxySettingsActivity;',
    'Lthreadsmod/proxy/ProxyBootstrap;',
    'Lthreadsmod/proxy/ProxyBypassPolicy;',
    'Lthreadsmod/proxy/ProxyConfig;',
    'Lthreadsmod/proxy/ProxyConfigStore;',
    'Lthreadsmod/proxy/ProxyController;',
    'Lthreadsmod/proxy/ProxyRoutePlanner;',
    'Lthreadsmod/proxy/Socks5VpnService;'
)
$ownedProxyDescriptors = @(
    $manifests['080-socks5-proxy'].ownership.classDescriptors |
        ForEach-Object { [string]$_ }
)
if (($ownedProxyDescriptors -join "`n") -ne ($proxyRequiredDescriptors -join "`n")) {
    throw 'Patchlet 080 must exactly own every stable top-level proxy descriptor.'
}
$proxyNative = $resolution.proxy.nativeLibrary
$proxyLicense = $resolution.proxy.licenseAsset
if ([string]$resolution.proxy.rewriteSet -ne 'proxy-manifest-rewrites.json' `
        -or [string]$resolution.proxy.settingsActivity.name `
            -ne 'com.threadsmod.ProxySettingsActivity' `
        -or [string]$resolution.proxy.vpnService.name `
            -ne 'threadsmod.proxy.Socks5VpnService' `
        -or [string]$resolution.proxy.vpnService.permission `
            -ne 'android.permission.BIND_VPN_SERVICE' `
        -or [string]$resolution.proxy.vpnService.action -ne 'android.net.VpnService' `
        -or [string]$resolution.proxy.vpnService.foregroundServiceType -ne 'specialUse' `
        -or [string]$resolution.proxy.vpnService.foregroundServicePermission `
            -ne 'android.permission.FOREGROUND_SERVICE_SPECIAL_USE' `
        -or [string]$proxyNative.assetPath `
            -ne 'assets/socks5-proxy/native/arm64-v8a/libhev-socks5-tunnel.so' `
        -or [string]$proxyNative.apkPath `
            -ne 'lib/arm64-v8a/libhev-socks5-tunnel.so' `
        -or [string]$proxyNative.abi -ne 'arm64-v8a' `
        -or [string]$proxyNative.sha256 `
            -ne '3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099' `
        -or [int]$proxyNative.elfMachine -ne 183 `
        -or [int64]$proxyNative.minimumLoadAlignment -ne 16384 `
        -or [string]$proxyLicense.assetPath `
            -ne 'assets/socks5-proxy/native/NOTICE.hev-socks5-tunnel-and-lwip.txt' `
        -or [string]$proxyLicense.decodedPath `
            -ne 'assets/threadsmod/licenses/hev-socks5-tunnel-and-lwip.txt' `
        -or [string]$proxyLicense.apkPath `
            -ne 'assets/threadsmod/licenses/hev-socks5-tunnel-and-lwip.txt' `
        -or [string]$proxyLicense.sha256 `
            -ne 'c6f7f6dbe54e21b0844f0b85887d6ce741b524d0f506179db1e83221c802e521') {
    throw 'Resolution SOCKS5 manifest/native contract differs from the reviewed exact values.'
}
$requiredProxyReleaseDescriptors = @(
    $resolution.release.requiredClassDescriptors | Where-Object {
        $proxyRequiredDescriptors -contains [string]$_
    } | ForEach-Object { [string]$_ }
)
$requiredProxyForbiddenDexStrings = @(
    'allowBypass',
    'socksProxyHost',
    'java.net.useSystemProxies',
    'threadsmod_proxy_username',
    'threadsmod_proxy_password',
    'tree55.com'
)
if (($requiredProxyReleaseDescriptors -join "`n") -ne ($proxyRequiredDescriptors -join "`n") `
        -or @($resolution.release.requiredInjectedActivities | Where-Object {
                [string]$_ -eq 'com.threadsmod.ProxySettingsActivity'
            }).Count -ne 1) {
    throw 'Signed release metadata omits a proxy descriptor or the private Proxy Settings Activity.'
}
foreach ($forbiddenProxyLiteral in $requiredProxyForbiddenDexStrings) {
    if (@($resolution.release.forbiddenDexStrings | Where-Object {
                [string]$_ -eq $forbiddenProxyLiteral
            }).Count -ne 1) {
        throw "Signed release metadata does not forbid proxy fallback/plaintext literal '$forbiddenProxyLiteral'."
    }
}
$requiredProxyJadxClasses = @(
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
$targetedProxyFallbackLiterals = @(
    'allowBypass(',
    'System.setProperty(',
    'ProxySelector.setDefault(',
    'socksProxyHost',
    'socksProxyPort',
    'java.net.useSystemProxies'
)
foreach ($proxyJadxClass in $requiredProxyJadxClasses) {
    $proxyJadxTargets = @($resolution.release.targetedJadxClasses | Where-Object {
                [string]$_.className -eq $proxyJadxClass
            })
    if ($proxyJadxTargets.Count -ne 1) {
        throw "Signed release metadata omits proxy JADX contract '$proxyJadxClass'."
    }
    foreach ($targetedProxyFallbackLiteral in $targetedProxyFallbackLiterals) {
        if (@($proxyJadxTargets[0].forbiddenStrings | Where-Object {
                    [string]$_ -ceq $targetedProxyFallbackLiteral
                }).Count -ne 1) {
            throw "Proxy JADX contract '$proxyJadxClass' does not forbid exact fallback literal '$targetedProxyFallbackLiteral'."
        }
    }
}
$proxyApplicationJadxTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'com.instagram.barcelona.app.BarcelonaAppShell'
    })[0]
$proxyApplicationOrderedStrings = @(
    $proxyApplicationJadxTarget.orderedStrings | ForEach-Object { [string]$_ })
if (($proxyApplicationOrderedStrings -join "`n") -ne (
        @('super.attachBaseContext(', 'ProxyBootstrap.install(') -join "`n") `
        -or [int]$proxyApplicationJadxTarget.exactStringCounts.'super.attachBaseContext(' -ne 1 `
        -or [int]$proxyApplicationJadxTarget.exactStringCounts.'ProxyBootstrap.install(' -ne 1 `
        -or @($proxyApplicationJadxTarget.forbiddenStrings | Where-Object {
                [string]$_ -ceq 'Method dump skipped'
            }).Count -ne 1 `
        -or @($proxyApplicationJadxTarget.forbiddenStrings | Where-Object {
                [string]$_ -ceq 'Method not decompiled: com.instagram.barcelona.app.BarcelonaAppShell.attachBaseContext(android.content.Context):void'
            }).Count -ne 1) {
    throw 'Application targeted-JADX metadata must prove one readable super/bootstrap pair and reject skipped attachBaseContext output.'
}
$proxyBootstrapFlowContract = $resolution.release.requiredDexProxyBootstrapFlow
$proxyBootstrapInspectorText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'tools\DexProxyBootstrapFlowInspector.java')
$proxyBootstrapFixtureText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'tools\Test-DexProxyBootstrapFlowInspector.ps1')
if ((Get-PatchletLiteralCount -Text $proxyBootstrapInspectorText `
            -Literal ("args.length != {0}" -f (
                    [int]$resolution.release.expectedDexProxyBootstrapFlowInspectorArgumentCount))) -ne 1 `
        -or -not $proxyBootstrapInspectorText.Contains(
            [string]$proxyBootstrapFlowContract.id, [StringComparison]::Ordinal) `
        -or -not $proxyBootstrapFixtureText.Contains(
            'expectedDexProxyBootstrapFlowFixtureCount', [StringComparison]::Ordinal) `
        -or -not [bool]$proxyBootstrapFlowContract.requireExactEntryPrefix `
        -or -not [bool]$proxyBootstrapFlowContract.requireSoleBootstrapCaller `
        -or -not [bool]$proxyBootstrapFlowContract.requireParameterRegisterFlow `
        -or -not [bool]$proxyBootstrapFlowContract.requireImmediateAdjacency `
        -or -not [bool]$proxyBootstrapFlowContract.requireNoAlternateEntry `
        -or -not [bool]$proxyBootstrapFlowContract.requireNoBootstrapTryCoverage `
        -or -not [bool]$proxyBootstrapFlowContract.requireOriginalNextField `
        -or -not [bool]$proxyBootstrapFlowContract.requireExactFallbackAbsence) {
    throw 'Resolution and tools do not retain the complete raw signed-DEX proxy-bootstrap flow contract.'
}
$reviewedNextFieldReference = [string]$proxyBootstrapFlowContract.originalNextFieldReference
$reviewedNextFieldMatch = [Text.RegularExpressions.Regex]::Match(
    $reviewedNextFieldReference,
    '^(L[^;]+;)->([^:]+):(.+)$',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant)
if (-not $reviewedNextFieldMatch.Success) {
    throw 'Proxy-bootstrap original next-field reference is not a canonical DEX field reference.'
}
$reviewedNextFieldSourceTuple = '"{0}", "{1}", "{2}",' -f `
    $reviewedNextFieldMatch.Groups[1].Value,
    $reviewedNextFieldMatch.Groups[2].Value,
    $reviewedNextFieldMatch.Groups[3].Value
if ((Get-PatchletLiteralCount -Text $proxyBootstrapInspectorText `
            -Literal $reviewedNextFieldSourceTuple) -ne 1) {
    throw "Proxy-bootstrap inspector source does not bind the exact reviewed next-field tuple '$reviewedNextFieldReference'."
}
foreach ($proxyBootstrapMetadataLiteral in @(
        $proxyBootstrapFlowContract.forbiddenMethodReferences) `
        + @($proxyBootstrapFlowContract.forbiddenStringLiterals)) {
    if (-not $proxyBootstrapInspectorText.Contains(
            [string]$proxyBootstrapMetadataLiteral, [StringComparison]::Ordinal)) {
        throw "Proxy-bootstrap inspector source diverges from resolution literal '$proxyBootstrapMetadataLiteral'."
    }
}
$proxyJavaRoot = Join-Path $patchletsRoot 'assets\autoblock\java'
foreach ($proxyJavaFile in @(Get-ChildItem -LiteralPath $proxyJavaRoot -Recurse -File -Filter '*.java')) {
    $proxyJavaText = Get-NormalizedPatchletText -Path $proxyJavaFile.FullName
    foreach ($targetedProxyFallbackLiteral in $targetedProxyFallbackLiterals) {
        if ($proxyJavaText.Contains($targetedProxyFallbackLiteral, [StringComparison]::Ordinal)) {
            throw "Canonical proxy Java contains exact fallback literal '$targetedProxyFallbackLiteral' in '$($proxyJavaFile.FullName)'."
        }
    }
}
$proxySettingsSourcePath = Join-Path $patchletsRoot `
    'assets\autoblock\java\com\threadsmod\ProxySettingsActivity.java'
$proxySettingsSourceText = Get-NormalizedPatchletText -Path $proxySettingsSourcePath
$proxySettingsJadxTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'com.threadsmod.ProxySettingsActivity'
    })
if ($proxySettingsJadxTarget.Count -ne 1) {
    throw 'Proxy Settings signed-JADX contract must be unique.'
}
foreach ($credentialViewLiteral in @(
        'usernameInput.setSaveEnabled(false)',
        'usernameInput.setImportantForAutofill(',
        'passwordInput.setSaveEnabled(false)',
        'passwordInput.setImportantForAutofill(',
        'protected void onPause()',
        'sensitiveFieldsCleared = true',
        'restoreSensitiveFieldsIfNeeded()')) {
    if (-not $proxySettingsSourceText.Contains(
            $credentialViewLiteral, [StringComparison]::Ordinal) `
            -or @($proxySettingsJadxTarget[0].requiredStrings | Where-Object {
                    [string]$_ -eq $credentialViewLiteral
                }).Count -ne 1) {
        throw "Proxy Settings credential-view hardening is not source- and signed-JADX-bound: $credentialViewLiteral"
    }
}
$proxyTruthContracts = @(
    [pscustomobject]@{
        ClassName = 'com.threadsmod.ProxySettingsActivity'
        SourcePath = $proxySettingsSourcePath
        Required = @(
            'protected void onResume()',
            'Socks5VpnService.runtimeState()',
            'observedRuntimeState = Socks5VpnService.runtimeState()',
            'ProxyController.status(this)',
            'statusHandler.postDelayed(',
            'statusHandler.removeCallbacks(',
            'startStatusPolling()',
            'stopStatusPolling()',
            'showStatusRefreshUnavailable()',
            'statusPolling = true',
            'Unavailable: live proxy status refresh stopped. Reopen this page before relying on proxy status.'
        )
    },
    [pscustomobject]@{
        ClassName = 'threadsmod.proxy.ProxyController'
        SourcePath = Join-Path $patchletsRoot `
            'assets\autoblock\java\threadsmod\proxy\ProxyController.java'
        Required = @(
            'Paused: a full-route guard is active; app traffic remains blocked.',
            'Paused: the prior full-route guard is retained; app traffic remains blocked.',
            'Unprotected: Android refused the fresh full-route guard; prior VPN routing is retained and earlier numeric DIRECT exclusions may remain.',
            'Unprotected: Android could not establish the VPN; direct traffic may continue.',
            'Unprotected: proxy service is inactive; direct traffic may continue.'
        )
    },
    [pscustomobject]@{
        ClassName = 'threadsmod.proxy.Socks5VpnService'
        SourcePath = Join-Path $patchletsRoot `
            'assets\autoblock\java\threadsmod\proxy\Socks5VpnService.java'
        Required = @(
            'STATE_PAUSED_GUARD_ACTIVE',
            'paused_guard_active',
            'STATE_PAUSED_GUARD_RETAINED',
            'paused_guard_retained',
            'STATE_UNPROTECTED_PRIOR_ROUTING',
            'unprotected_prior_routing',
            'Traffic remains paused; prior full-route guard retained',
            'Prior VPN routing retained; earlier numeric DIRECT exclusions may remain',
            'VPN guard unavailable; direct traffic may continue',
            'Traffic paused; full-route guard active'
        )
    }
)
foreach ($proxyTruthContract in $proxyTruthContracts) {
    $proxyTruthSource = Get-NormalizedPatchletText -Path $proxyTruthContract.SourcePath
    $proxyTruthTarget = @($resolution.release.targetedJadxClasses | Where-Object {
            [string]$_.className -eq [string]$proxyTruthContract.ClassName
        })
    if ($proxyTruthTarget.Count -ne 1) {
        throw "Proxy truthful-state signed-JADX target must be unique: $($proxyTruthContract.ClassName)"
    }
    foreach ($proxyTruthLiteral in @($proxyTruthContract.Required)) {
        if (-not $proxyTruthSource.Contains(
                [string]$proxyTruthLiteral, [StringComparison]::Ordinal) `
                -or @($proxyTruthTarget[0].requiredStrings | Where-Object {
                        [string]$_ -eq [string]$proxyTruthLiteral
                    }).Count -ne 1) {
            throw "Proxy truthful-state behavior is not source- and signed-JADX-bound: $($proxyTruthContract.ClassName) :: $proxyTruthLiteral"
        }
    }
}
$proxySettingsPollingOrder = @(
    'protected void onResume()',
    'refreshStatus()',
    'startStatusPolling()',
    'protected void onPause()',
    'stopStatusPolling()'
)
$resolvedProxySettingsOrder = @($proxySettingsJadxTarget[0].orderedStrings |
    ForEach-Object { [string]$_ })
if ($resolvedProxySettingsOrder.Count -lt $proxySettingsPollingOrder.Count `
        -or ($resolvedProxySettingsOrder[0..($proxySettingsPollingOrder.Count - 1)] -join "`n") `
            -ne ($proxySettingsPollingOrder -join "`n")) {
    throw 'Proxy Settings signed-JADX order must begin with resumed refresh/poll wiring followed by pause/stop wiring.'
}
$proxySettingsPollingTail = @(
    'observedRuntimeState = Socks5VpnService.runtimeState()',
    'ProxyController.status(this)',
    'private void startStatusPolling()',
    'statusHandler.removeCallbacks(',
    'statusPolling = true',
    'statusHandler.postDelayed('
)
if ($resolvedProxySettingsOrder.Count -lt $proxySettingsPollingTail.Count `
        -or ($resolvedProxySettingsOrder[
                ($resolvedProxySettingsOrder.Count - $proxySettingsPollingTail.Count)..
                ($resolvedProxySettingsOrder.Count - 1)] -join "`n") `
            -ne ($proxySettingsPollingTail -join "`n")) {
    throw 'Proxy Settings signed-JADX order must end with observe-before-render and checked polling setup.'
}
$proxySettingsExactCounts = [ordered]@{
    'Socks5VpnService.runtimeState()' = 2
    'observedRuntimeState = Socks5VpnService.runtimeState()' = 1
    'ProxyController.status(this)' = 1
    'statusHandler.postDelayed(' = 2
    'statusHandler.removeCallbacks(' = 2
    'startStatusPolling()' = 2
    'stopStatusPolling()' = 2
    'showStatusRefreshUnavailable()' = 3
    'statusPolling = true' = 1
    'Unavailable: live proxy status refresh stopped. Reopen this page before relying on proxy status.' = 1
}
foreach ($proxySettingsCountEntry in $proxySettingsExactCounts.GetEnumerator()) {
    $resolvedCountProperties = @($proxySettingsJadxTarget[0].exactStringCounts.PSObject.Properties |
        Where-Object { [string]$_.Name -ceq [string]$proxySettingsCountEntry.Key })
    if ($resolvedCountProperties.Count -ne 1 `
            -or [int]$resolvedCountProperties[0].Value -ne [int]$proxySettingsCountEntry.Value) {
        throw "Proxy Settings signed-JADX exact count is missing or stale: $($proxySettingsCountEntry.Key)"
    }
}
$proxyControllerTruthTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.proxy.ProxyController'
    })
$proxyControllerTruthOrder = @(
    'Paused: the SOCKS5 tunnel engine is unavailable.',
    'Paused: a full-route guard is active; app traffic remains blocked.',
    'Paused: the prior full-route guard is retained; app traffic remains blocked.',
    'Unprotected: Android refused the fresh full-route guard; prior VPN routing is retained and earlier numeric DIRECT exclusions may remain.',
    'Unprotected: Android could not establish the VPN; direct traffic may continue.',
    'Unprotected: proxy service is inactive; direct traffic may continue.'
)
if ($proxyControllerTruthTarget.Count -ne 1 `
        -or (@($proxyControllerTruthTarget[0].orderedStrings |
                ForEach-Object { [string]$_ }) -join "`n") `
            -ne ($proxyControllerTruthOrder -join "`n")) {
    throw 'ProxyController signed-JADX truthful-state order is missing, duplicated, or reordered.'
}
foreach ($proxyControllerStatus in @($proxyControllerTruthOrder | Select-Object -Skip 1)) {
    $resolvedCountProperties = @($proxyControllerTruthTarget[0].exactStringCounts.PSObject.Properties |
        Where-Object { [string]$_.Name -ceq [string]$proxyControllerStatus })
    if ($resolvedCountProperties.Count -ne 1 -or [int]$resolvedCountProperties[0].Value -ne 1) {
        throw "ProxyController signed-JADX truthful status must occur exactly once: $proxyControllerStatus"
    }
}
$proxyServiceTruthTarget = @($resolution.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'threadsmod.proxy.Socks5VpnService'
    })
$proxyServiceTruthOrder = @(
    'STATE_PAUSED_GUARD_ACTIVE',
    'paused_guard_active',
    'STATE_PAUSED_GUARD_RETAINED',
    'paused_guard_retained',
    'STATE_UNPROTECTED_PRIOR_ROUTING',
    'unprotected_prior_routing',
    'Traffic remains paused; prior full-route guard retained',
    'Prior VPN routing retained; earlier numeric DIRECT exclusions may remain',
    'VPN guard unavailable; direct traffic may continue',
    'Traffic paused; full-route guard active'
)
if ($proxyServiceTruthTarget.Count -ne 1 `
        -or (@($proxyServiceTruthTarget[0].orderedStrings |
                ForEach-Object { [string]$_ }) -join "`n") `
            -ne ($proxyServiceTruthOrder -join "`n")) {
    throw 'Socks5VpnService signed-JADX guard/no-TUN order is missing, duplicated, or reordered.'
}
foreach ($proxyServiceExactCount in ([ordered]@{
        'paused_guard_active' = 1
        'paused_guard_retained' = 1
        'unprotected_prior_routing' = 1
        'Traffic paused; full-route guard active' = 1
    }).GetEnumerator()) {
    $resolvedCountProperties = @($proxyServiceTruthTarget[0].exactStringCounts.PSObject.Properties |
        Where-Object { [string]$_.Name -ceq [string]$proxyServiceExactCount.Key })
    if ($resolvedCountProperties.Count -ne 1 `
            -or [int]$resolvedCountProperties[0].Value -ne [int]$proxyServiceExactCount.Value) {
        throw "Socks5VpnService signed-JADX exact count is missing or stale: $($proxyServiceExactCount.Key)"
    }
}
$retiredAmbiguousProxyStatus = 'VPN replacement unavailable; prior routing retained'
if ($proxyServiceTruthTarget.Count -ne 1 `
        -or (Get-NormalizedPatchletText -Path $proxyTruthContracts[2].SourcePath).Contains(
            $retiredAmbiguousProxyStatus, [StringComparison]::Ordinal) `
        -or @($proxyServiceTruthTarget[0].forbiddenStrings | Where-Object {
                [string]$_ -eq $retiredAmbiguousProxyStatus
            }).Count -ne 1) {
    throw 'Retired ambiguous proxy replacement status is not absent from source and forbidden in signed JADX.'
}
$patchedApkGateText = Get-NormalizedPatchletText -Path (
    Join-Path $patchletsRoot 'tools\Test-PatchedApk.ps1')
foreach ($proxyExecutableGate in @(
        'socks5-config-contract',
        'socks5-vpn-manifest-contract',
        'socks5-bootstrap-contract',
        'socks5-bootstrap-signed-dex-flow-contract',
        'socks5-route-contract',
        'socks5-credential-contract',
        'socks5-native-contract',
        'socks5-license-contract',
        'socks5-static-dex-contract',
        'socks5-pristine-port-substring-collision',
        'proxy-settings-activity-contract')) {
    if ((Get-PatchletLiteralCount -Text $patchedApkGateText `
                -Literal ("'{0}' =" -f $proxyExecutableGate)) -ne 1) {
        throw "SOCKS5 release gate has no executed signed-APK evidence entry: $proxyExecutableGate"
    }
}
if (-not ((Get-NormalizedPatchletText -Path (
                Join-Path $patchletsRoot 'ai\tasks\RESOLVE-SOCKS5-PROXY.md')).Contains(
            'ProxyBootstrap.install(Context)', [StringComparison]::Ordinal))) {
    throw 'SOCKS5 AI updater task is missing its bounded bootstrap objective.'
}
foreach ($retiredCombinedActionPreference in @(
        'ui_one_click_block',
        'ui_dismiss_after_block')) {
    if ($ownership['preferenceKeys'].ContainsKey($retiredCombinedActionPreference)) {
        throw "Retired combined-action preference still has an owner: $retiredCombinedActionPreference"
    }
}

$defaultSeriesId = [string]$catalog.defaultSeries
$series = @($catalog.series | Where-Object { [string]$_.id -eq $defaultSeriesId })
if ($series.Count -ne 1) { throw 'Catalog default series did not resolve exactly once.' }
$seriesIds = @($series[0].patchlets | ForEach-Object { [string]$_ })
$resolutionIds = @($resolution.patchlets | ForEach-Object { [string]$_ })
if (($seriesIds -join "`n") -ne ($resolutionIds -join "`n")) { throw 'Resolution patchlet order differs from the catalog series.' }
for ($index = 0; $index -lt $seriesIds.Count; $index++) {
    $id = $seriesIds[$index]
    if (-not $manifests.ContainsKey($id)) { throw "Series references unknown patchlet '$id'." }
    foreach ($dependency in @($manifests[$id].dependsOn)) {
        $dependencyIndex = [Array]::IndexOf($seriesIds, [string]$dependency)
        if ($dependencyIndex -lt 0 -or $dependencyIndex -ge $index) { throw "Patchlet '$id' has unsatisfied or misordered dependency '$dependency'." }
    }
}
$releaseGates = @($manifests['090-release-gates'].operations | Where-Object {
        [string]$_.id -eq 'run-static-release-gates'
    } | ForEach-Object { @($_.orderedGates) })
$requiredCurrentRevisions = [ordered]@{
    '005-split-source-universalization' = 1
    '010-clone-identity' = 5
    '020-autoblock-runtime' = 24
    '030-native-block-bridge' = 7
    '050-mod-settings-ui' = 17
    '060-inline-block-controls' = 14
    '070-consented-reporting' = 10
    '080-socks5-proxy' = 3
    '085-in-app-update' = 2
    '090-release-gates' = 62
}
foreach ($patchletId in $requiredCurrentRevisions.Keys) {
    if ([int]$manifests[$patchletId].revision -ne [int]$requiredCurrentRevisions[$patchletId]) {
        throw "Patchlet '$patchletId' revision must equal current reviewed revision $($requiredCurrentRevisions[$patchletId])."
    }
}
foreach ($requiredGate in @(
        'exact-split-source-set',
        'split-role-manifest-contract',
        'pinned-apkeditor-contract',
        'deterministic-universalization',
        'universal-payload-preservation',
        'universal-standalone-manifest',
        'universal-unsigned-boundary',
        'bootstrap-entry-attestation',
        'resolution-file-sha-binding',
        'release-input-snapshot',
        'decoded-build-input-freeze',
        'canonical-decoded-zero-mutation-lock',
        'isolated-apktool-build-working-copy',
        'exact-apktool-work-mutation-contract',
        'intermediate-and-candidate-artifact-lock',
        'build-working-restoration-and-seal',
        'artifact-path-confinement',
        'reviewed-asset-preservation-scope',
        'full-archive-unique-canonical-names',
        'exact-root-dex-inventory',
        'socks5-config-contract',
        'socks5-vpn-manifest-contract',
        'socks5-bootstrap-contract',
        'socks5-bootstrap-signed-dex-flow-contract',
        'socks5-route-contract',
        'socks5-credential-contract',
        'socks5-native-contract',
        'socks5-license-contract',
        'socks5-static-dex-contract',
        'socks5-pristine-port-substring-collision',
        'proxy-settings-activity-contract',
        'mod-activity-static-construction-contract',
        'exact-network-allowlist-contract',
        'passive-index-contract',
        'passive-refresh-contract',
        'passive-activity-status-contract',
        'passive-visible-scheduler-contract',
        'update-host-fixtures',
        'update-endpoint-policy',
        'update-manifest-contract',
        'update-dialog-contract',
        'update-installer-contract',
        'update-signed-dex-contract',
        'update-manifest-rewrite-contract',
        'inline-post-share-single-control-topology',
        'passive-viewport-observer-contract',
        'inline-stable-media-key-and-report-request-guard-contract',
        'compact-combined-dialog-contract',
        'single-inline-action-static-contract',
        'ambiguous-report-label-substring-collision',
        'inline-author-model-handoff-contract',
        'manual-model-hint-scheduler-contract',
        'resolved-model-id-match-contract',
        'cache-placeholder-id-match-contract',
        'bridge-failure-stage-vocabulary-contract',
        'bridge-private-seam-handler-contract',
        'bridge-entry-reachability-contract',
        'release-tool-parameter-compatibility',
        'signed-review-no-publish-contract',
        'release-tool-evidence-compatibility',
        'bridge-inspector-argument-count-compatibility',
        'bridge-signed-dex-flow-contract',
        'bridge-callback-firewall-contract',
        'bridge-caller-catch-contract',
        'bridge-caller-callback-effect-contract',
        'scheduler-wake-enqueue-contract',
        'uncertain-mutation-review-contract',
        'closed-block-diagnostic-contract',
        'inline-profile-username-label-contract',
        'report-explicit-combined-submit',
        'report-submit-owner-binding',
        'report-retired-ui-absence',
        'report-post-permalink-contract',
        'report-payload-contract',
        'report-pseudonym-contract',
        'report-outbox-retry-contract',
        'report-outbox-review-contract',
        'report-database-contract',
        'report-database-v1-to-v2-migration-contract',
        'report-success-response-contract',
        'report-disclosure-contract',
        'report-cancel-race-contract',
        'report-endpoint-policy',
        'report-post-dex-call-semantics',
        'report-block-independence',
        'targeted-jadx-recovery',
        'pre-publish-input-freeze',
        'post-publish-input-drift-rollback',
        'published-artifact-sha-binding',
        'rollback-residue-truthful-failure',
        'post-commit-outer-rollback',
        'failure-report-no-publish')) {
    if ($releaseGates -notcontains $requiredGate) {
        throw "Patchlet 090 is missing a required release-contract gate: $requiredGate"
    }
}
$proxyBootstrapRawGate = 'socks5-bootstrap-signed-dex-flow-contract'
$targetedJadxGate = 'targeted-jadx-recovery'
$proxyBootstrapRawGateIndex = [Array]::IndexOf($releaseGates, $proxyBootstrapRawGate)
$targetedJadxGateIndex = [Array]::IndexOf($releaseGates, $targetedJadxGate)
if (@($releaseGates | Where-Object {
            [string]$_ -ceq $proxyBootstrapRawGate
        }).Count -ne 1 `
        -or @($releaseGates | Where-Object {
            [string]$_ -ceq $targetedJadxGate
        }).Count -ne 1 `
        -or $proxyBootstrapRawGateIndex -ge $targetedJadxGateIndex) {
    throw 'Patchlet 090 must run one raw proxy-bootstrap signed-DEX gate before one targeted-JADX recovery gate.'
}
$passiveReleaseGateOrder = @(
    'passive-index-contract',
    'passive-refresh-contract',
    'passive-activity-status-contract',
    'passive-viewport-observer-contract',
    'passive-visible-scheduler-contract'
)
$previousPassiveGateIndex = -1
foreach ($passiveReleaseGate in $passiveReleaseGateOrder) {
    $passiveGateIndex = [Array]::IndexOf($releaseGates, $passiveReleaseGate)
    if (@($releaseGates | Where-Object {
                [string]$_ -ceq $passiveReleaseGate
            }).Count -ne 1 `
            -or $passiveGateIndex -le $previousPassiveGateIndex `
            -or $passiveGateIndex -ge $targetedJadxGateIndex) {
        throw "Patchlet 090 must run one ordered passive gate before targeted JADX recovery: $passiveReleaseGate"
    }
    $previousPassiveGateIndex = $passiveGateIndex
}
$updateReleaseGateOrder = @(
    'update-host-fixtures',
    'update-endpoint-policy',
    'update-manifest-contract',
    'update-dialog-contract',
    'update-installer-contract',
    'update-signed-dex-contract',
    'update-manifest-rewrite-contract'
)
$previousUpdateGateIndex = -1
foreach ($updateReleaseGate in $updateReleaseGateOrder) {
    $updateGateIndex = [Array]::IndexOf($releaseGates, $updateReleaseGate)
    if (@($releaseGates | Where-Object {
                [string]$_ -ceq $updateReleaseGate
            }).Count -ne 1 `
            -or $updateGateIndex -le $previousUpdateGateIndex `
            -or $updateGateIndex -ge $targetedJadxGateIndex) {
        throw "Patchlet 090 must run one ordered updater gate before targeted JADX recovery: $updateReleaseGate"
    }
    $previousUpdateGateIndex = $updateGateIndex
}
$releaseGateManifest = $manifests['090-release-gates']
$descriptorCollisionPostcondition = @(
    $releaseGateManifest.postconditions | Where-Object {
        [string]$_.id -ceq 'descriptor-bound-smali-case-collision-proof-is-exact'
    })
if ($descriptorCollisionPostcondition.Count -ne 1 `
        -or [string]$descriptorCollisionPostcondition[0].check -cne `
            'resolution-schema-core-evaluator-catalog-and-release-contract-require-exactly-two-reviewed-candidate-paths-select-exactly-one-lx-02ja-target-by-its-class-declaration-require-exactly-one-lx-02jA-sibling-count-the-null-seed-callsite-only-in-the-selected-target-and-reject-a-proven-absent-candidate-by-the-exact-missing-file-condition-plus-duplicate-extra-mixed-or-malformed-mappings-under-both-apktool-suffix-orders' `
        -or [string]$descriptorCollisionPostcondition[0].severity -cne 'error') {
    throw 'Patchlet 090 must own one blocking descriptor-bound Smali collision postcondition.'
}
$visibilityCountPostcondition = @(
    $releaseGateManifest.postconditions | Where-Object {
        [string]$_.id -ceq 'targeted-jadx-visibility-callsite-counts-are-version-bound'
    })
if ($visibilityCountPostcondition.Count -ne 1 `
        -or [string]$visibilityCountPostcondition[0].check -cne `
            'resolution-selected-inline-visibility-template-and-targeted-jadx-metadata-have-identical-exact-register-update-unregister-callsites-with-444-two-one-three-and-415-two-one-one-and-release-contract-rejects-a-count-drift-fixture' `
        -or [string]$visibilityCountPostcondition[0].severity -cne 'error') {
    throw 'Patchlet 090 must own one blocking version-bound visibility-callsite count postcondition.'
}
$passiveWrapperParityPostcondition = @(
    $releaseGateManifest.postconditions | Where-Object {
        [string]$_.id -ceq 'passive-jadx-wrapper-requirements-are-resolution-bound'
    })
if ($passiveWrapperParityPostcondition.Count -ne 1 `
        -or [string]$passiveWrapperParityPostcondition[0].check -cne `
            'resolution-schema-pins-the-exact-eleven-autoblocksync-wrapper-requirement-strings-with-currentpassivematch-and-the-release-contract-ast-proves-the-patched-apk-wrapper-identical-while-stale-missing-duplicate-and-nonliteral-negative-fixtures-fail-closed' `
        -or [string]$passiveWrapperParityPostcondition[0].severity -cne 'error') {
    throw 'Patchlet 090 must own one blocking resolution-bound passive JADX wrapper parity postcondition.'
}
$expectedUpdateFlowInputs = [ordered]@{
    'patchlet-pipeline-tool' = @(
        'asset-file', 'tools/Invoke-PatchletPipeline.ps1',
        '/assets/patchletPipelineSourceSha256')
    'patched-apk-build-tool' = @(
        'asset-file', 'tools/Build-PatchedApk.ps1',
        '/assets/buildPatchedApkSourceSha256')
    'dex-update-flow-inspector-tool' = @(
        'asset-file', 'tools/DexUpdateFlowInspector.java',
        '/assets/dexUpdateFlowInspectorSourceSha256')
    'dex-update-flow-inspector-test-tool' = @(
        'asset-file', 'tools/Test-DexUpdateFlowInspector.ps1',
        '/assets/dexUpdateFlowInspectorTestSourceSha256')
    'dex-update-flow-fixtures' = @(
        'asset-tree', 'assets/release-gates/dex-update-flow',
        '/assets/dexUpdateFlowFixtureTreeSha256')
}
foreach ($inputId in $expectedUpdateFlowInputs.Keys) {
    $matches = @($releaseGateManifest.inputs | Where-Object {
            [string]$_.id -ceq $inputId
        })
    $expectedInput = $expectedUpdateFlowInputs[$inputId]
    if ($matches.Count -ne 1 `
            -or [string]$matches[0].kind -cne $expectedInput[0] `
            -or [string]$matches[0].path -cne $expectedInput[1] `
            -or [string]$matches[0].sha256FromResolution -cne $expectedInput[2] `
            -or $matches[0].required -ne $true) {
        throw "Patchlet 090 release proof input is missing, duplicated, or drifted: $inputId"
    }
}
if (@($releaseGateManifest.resolution.requiredSections | Where-Object {
            [string]$_ -ceq 'update'
        }).Count -ne 1 `
        -or @($releaseGateManifest.resolution.rewriteSets | Where-Object {
            [string]$_ -ceq 'update-manifest-rewrites.json'
        }).Count -ne 1) {
    throw 'Patchlet 090 must require the updater resolution section and exact manifest rewrite set.'
}
$parameterCompatibilityGate = 'release-tool-parameter-compatibility'
$signedReviewCompatibilityGate = 'signed-review-no-publish-contract'
$evidenceCompatibilityGate = 'release-tool-evidence-compatibility'
$inspectorArgumentCompatibilityGate = 'bridge-inspector-argument-count-compatibility'
$parameterCompatibilityGateIndex = [Array]::IndexOf(
    $releaseGates, $parameterCompatibilityGate)
$signedReviewCompatibilityGateIndex = [Array]::IndexOf(
    $releaseGates, $signedReviewCompatibilityGate)
$evidenceCompatibilityGateIndex = [Array]::IndexOf(
    $releaseGates, $evidenceCompatibilityGate)
$inspectorArgumentCompatibilityGateIndex = [Array]::IndexOf(
    $releaseGates, $inspectorArgumentCompatibilityGate)
if (@($releaseGates | Where-Object { [string]$_ -eq $parameterCompatibilityGate }).Count -ne 1 `
        -or @($releaseGates | Where-Object { [string]$_ -eq $signedReviewCompatibilityGate }).Count -ne 1 `
        -or @($releaseGates | Where-Object { [string]$_ -eq $evidenceCompatibilityGate }).Count -ne 1 `
        -or @($releaseGates | Where-Object { [string]$_ -eq $inspectorArgumentCompatibilityGate }).Count -ne 1 `
        -or $signedReviewCompatibilityGateIndex -ne $parameterCompatibilityGateIndex + 1 `
        -or $evidenceCompatibilityGateIndex -ne $signedReviewCompatibilityGateIndex + 1 `
        -or $inspectorArgumentCompatibilityGateIndex -ne $evidenceCompatibilityGateIndex + 1) {
    throw 'Patchlet 090 must order one SignedReview no-publish gate and evidence gate after the parameter gate, then one inspector-argument gate.'
}

$resolutionDirectory = Split-Path -Parent $resolutionFull
$reviewedRewriteRuleIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
foreach ($reviewedResolutionVersion in @('415.0.0.26.77', '444.0.0.45.85')) {
    $reviewedResolutionDirectory = Join-Path $patchletsRoot (
        'resolutions\' + $reviewedResolutionVersion)
    $reviewedResolutionPath = Join-Path $reviewedResolutionDirectory 'resolution.json'
    $reviewedResolution = Read-PatchletJson -Path $reviewedResolutionPath
    if ([string]$reviewedResolution.source.versionName -cne $reviewedResolutionVersion) {
        throw "Reviewed rewrite-ownership resolution folder does not match its exact source version: $reviewedResolutionVersion"
    }
    foreach ($reviewedRewriteSetName in @($reviewedResolution.rewriteSets)) {
        $reviewedRewriteSetPath = Resolve-PatchletChildPath `
            -Root $reviewedResolutionDirectory -Child ([string]$reviewedRewriteSetName)
        if (-not (Test-Json -LiteralPath $reviewedRewriteSetPath `
                    -SchemaFile (Join-Path $patchletsRoot 'schemas\rewrite-set.schema.json') `
                    -ErrorAction Stop)) {
            throw "Reviewed ownership rewrite set failed schema validation: $reviewedResolutionVersion/$reviewedRewriteSetName"
        }
        $reviewedRewriteSet = Read-PatchletJson -Path $reviewedRewriteSetPath
        foreach ($reviewedRule in @($reviewedRewriteSet.rules)) {
            [void]$reviewedRewriteRuleIds.Add([string]$reviewedRule.id)
        }
    }
}
foreach ($rewriteSetName in @($resolution.rewriteSets)) {
    $rewriteSetPath = Resolve-PatchletChildPath -Root $resolutionDirectory -Child ([string]$rewriteSetName)
    if (-not (Test-Json -LiteralPath $rewriteSetPath -SchemaFile (Join-Path $patchletsRoot 'schemas\rewrite-set.schema.json') -ErrorAction Stop)) { throw "Rewrite set failed schema validation: $rewriteSetName" }
    $rewriteSet = Read-PatchletJson -Path $rewriteSetPath
    foreach ($rule in @($rewriteSet.rules)) {
        $ruleId = [string]$rule.id
        if (-not $ownership['rewriteRuleIds'].ContainsKey($ruleId)) {
            throw "Rewrite rule '$ruleId' has no owning patchlet."
        }
    }
}
foreach ($ownedRule in $ownership['rewriteRuleIds'].Keys) {
    if (-not $reviewedRewriteRuleIds.Contains([string]$ownedRule)) {
        throw "Owned rewrite rule '$ownedRule' is absent from the exact 415 and 444 reviewed rewrite sets."
    }
}
$requiredClassDescriptors = @($resolution.release.requiredClassDescriptors | ForEach-Object {
        [string]$_
    })
if ($requiredClassDescriptors.Count -ne 54 `
        -or @($requiredClassDescriptors | Where-Object {
            $_ -eq 'Lthreadsmod/autoblock/BlockDiagnostic;'
        }).Count -ne 1 `
        -or @($requiredClassDescriptors | Where-Object {
            $_.Contains('UserFetchCallback', [StringComparison]::Ordinal)
        }).Count -ne 0) {
    throw 'Required class descriptors must equal the 54-class passive-plus-update release set, own BlockDiagnostic once, and exclude retired UserFetchCallback.'
}
$requiredPassiveDescriptors = [ordered]@{
    'Lthreadsmod/autoblock/BlocklistStore;' = '020-autoblock-runtime'
    'Lthreadsmod/autoblock/ChunkInstaller;' = '020-autoblock-runtime'
    'Lthreadsmod/autoblock/ObjectFetcher;' = '020-autoblock-runtime'
    'Lthreadsmod/inlinecontrol/InlineVisibilityCallback;' = '060-inline-block-controls'
}
foreach ($passiveDescriptor in $requiredPassiveDescriptors.Keys) {
    if (@($requiredClassDescriptors | Where-Object {
                [string]$_ -ceq $passiveDescriptor
            }).Count -ne 1 `
            -or -not $ownership['classDescriptors'].ContainsKey($passiveDescriptor) `
            -or [string]$ownership['classDescriptors'][$passiveDescriptor] `
                -ne $requiredPassiveDescriptors[$passiveDescriptor]) {
        throw "Passive release descriptor is not required once by its sole owner: $passiveDescriptor"
    }
}
$requiredUpdateDescriptors = [ordered]@{
    'Lthreadsmod/update/UpdateController;' = '085-in-app-update'
    'Lthreadsmod/update/UpdateEndpoints;' = '085-in-app-update'
    'Lthreadsmod/update/UpdateJson;' = '085-in-app-update'
    'Lthreadsmod/update/UpdateManifest;' = '085-in-app-update'
    'Lthreadsmod/update/UpdateSignature;' = '085-in-app-update'
    'Lthreadsmod/update/UpdateStore;' = '085-in-app-update'
}
foreach ($updateDescriptor in $requiredUpdateDescriptors.Keys) {
    if (@($requiredClassDescriptors | Where-Object {
                [string]$_ -ceq $updateDescriptor
            }).Count -ne 1 `
            -or -not $ownership['classDescriptors'].ContainsKey($updateDescriptor) `
            -or [string]$ownership['classDescriptors'][$updateDescriptor] `
                -ne $requiredUpdateDescriptors[$updateDescriptor]) {
        throw "Updater release descriptor is not required once by its sole owner: $updateDescriptor"
    }
}
foreach ($descriptor in $requiredClassDescriptors) {
    if (-not $ownership['classDescriptors'].ContainsKey([string]$descriptor)) {
        throw "Required injected class descriptor '$descriptor' has no exact owning patchlet."
    }
}
foreach ($component in @($resolution.release.requiredInjectedActivities)) {
    if (-not $ownership['manifestComponents'].ContainsKey([string]$component)) {
        throw "Required injected manifest component '$component' has no exact owning patchlet."
    }
}

$report = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToString('o')
    status = 'passed'
    catalogId = [string]$catalog.catalogId
    seriesId = [string]$series[0].id
    patchletOrder = $seriesIds
    manifests = $manifests.Count
    resolutionId = [string]$resolution.resolutionId
    sourceApkSha256 = [string]$resolution.source.sha256
    splitSourceUniversalization = [ordered]@{
        patchlet = '005-split-source-universalization'
        revision = 1
        sourceSetSha256 = [string]$resolution.source.splitSetSha256
        sourceMembers = @($resolution.source.splitMembers)
        derivedApkSha256 = [string]$resolution.source.sha256
        apkEditorVersion = [string]$resolution.toolchain.apkEditorVersion
        apkEditorJarSha256 = [string]$resolution.toolchain.apkEditorJarSha256
        mergeArguments = @($resolution.toolchain.apkEditorMergeArguments)
        releaseGates = $expectedSourcePreparationGates
    }
    providerAuthorities = @($requiredProviderAuthorities)
    drawerSettingsRows = @($drawerRows)
    inAppUpdate = [ordered]@{
        patchlet = '085-in-app-update'
        revision = 1
        currentModBuild = [long]$resolution.update.currentModBuild
        targetModBuild = $targetModBuild
        targetVersionCode = [long]$resolution.target.versionCode
        targetVersionName = [string]$resolution.target.versionName
        metadataPurpose = 'threadsmod-app-update'
        metadataEndpoints = $expectedUpdateMetadataEndpoints
        requestInstallPermission = 'android.permission.REQUEST_INSTALL_PACKAGES'
        requestInstallPermissionAuthority = 'manifest-only'
        requiredAsDexMarker = $false
        fileProviderAuthority = 'app.tree55.threads.fileprovider'
        fileProviderCachePath = 'shared/updates'
        ownedDescriptors = $expectedUpdateDescriptors
        ownedPreferences = $expectedUpdatePreferences
        releaseGates = $expectedUpdateGates
        rawDexFlow = [ordered]@{
            contract = [string]$requiredDexUpdateFlow.id
            fixtureCount = 96
            inspectorArgumentCount = 12
            semanticSha256 = [string]$requiredDexUpdateFlow.expectedSemanticSha256
            semanticClassCount = 24
            orderedRootDescriptors = $expectedUpdateFlowRoots
            finalSignedCandidateExecutionRequired = $true
        }
        deploymentProved = $false
    }
    rewriteSets = @($resolution.rewriteSets).Count
    assetPreservationExclusions = $assetExclusionPaths
    targetedJadxClasses = $jadxTargetNames
    targetedJadxClassCount = $jadxTargetNames.Count
    passiveBlocking = [ordered]@{
        databaseSchemas = $expectedPassiveDatabaseSchemas
        requiredDescriptors = @($requiredPassiveDescriptors.Keys)
        releaseGateOrder = $passiveReleaseGateOrder
        refreshCadenceMs = 600000
        durableRefreshDeadline = 'typed-later-of-local-and-persisted'
        storeOutcome = 'match-nonmatch-invalid-pause'
        usernameBinding = 'unique-normalized-and-visible-bound'
        timestampBinding = 'iso-text-equals-epoch-ms'
        viewportAuthority = 'memory-only'
        offMainVisibility = 'admission-serialized-revocation-only'
        scheduler = 'shared-single-flight'
        finalAuthorityGates = 4
        provisionalBudget = 'refund-before-reservation-only'
        jadxWrapperRequirements = $resolvedPassiveJadxWrapperAutoBlockStrings
    }
    proxyBootstrapRawBeforeTargetedJadx = `
        $proxyBootstrapRawGateIndex -lt $targetedJadxGateIndex
    dexDirectStringCallContracts = @($postContracts | ForEach-Object { [string]$_.id })
    dexBridgeFlowContracts = @($bridgeFlowContracts | ForEach-Object { [string]$_.id })
    dexReportPermalinkFlowContract = `
        [string]$resolution.release.requiredDexReportPermalinkFlow.id
    ambiguousReportSubstringCollision = [ordered]@{
        ambiguousSubstring = 'Send report'
        pristineSourceLiteral = $pristineReportCollisionFixture
        broadForbiddenStringExcluded = $true
        authoritativeProofs = @(
            'visibleControlCount=1',
            'separateReportControlCount=0',
            'threadsmod_inline_report-forbidden',
            'InlineReportClick-class-absent',
            'ReportDialog-class-absent',
            'InlineReportRowAdapter.render-forbidden')
    }
    ambiguousSocksPortSubstringCollision = [ordered]@{
        ambiguousSubstring = $ambiguousSocksPortSubstring
        pristineSourceMethod = $pristineSocksPortCollisionFixture
        proofId = [string]$socksPortCollisionProof[0].id
        broadForbiddenStringExcluded = $true
        targetedExactFallbackStrings = $targetedProxyFallbackLiterals
        targetedJadxClasses = $requiredProxyJadxClasses
    }
    releaseToolContracts = [ordered]@{
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
        negativeFixtures = $releaseToolContractNegativeFixtures
    }
    ownership = [ordered]@{
        classPrefixes = $ownership['classPrefixes'].Count
        classDescriptors = $ownership['classDescriptors'].Count
        rewriteRuleIds = $ownership['rewriteRuleIds'].Count
        manifestComponents = $ownership['manifestComponents'].Count
        hostHooks = $ownership['hostHooks'].Count
        preferenceKeys = $ownership['preferenceKeys'].Count
        databaseSchemas = $ownership['databaseSchemas'].Count
        archiveTransforms = $ownership['archiveTransforms'].Count
        semanticProofIds = $ownership['semanticProofIds'].Count
    }
}
if ($ReportPath) { Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath)) }
[pscustomobject]$report
