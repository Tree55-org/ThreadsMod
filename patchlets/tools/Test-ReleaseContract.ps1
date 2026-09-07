[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScratchRoot,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$SourceApkSet,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

$repositoryRoot = Get-PatchletRepositoryRoot
$scratchFull = Assert-PatchletPathUnderRoot `
    -Path ([IO.Path]::GetFullPath($ScratchRoot)) `
    -Root (Join-Path $repositoryRoot 'work')
if (Test-Path -LiteralPath $scratchFull) {
    throw "ScratchRoot must be fresh: $scratchFull"
}
[IO.Directory]::CreateDirectory($scratchFull) | Out-Null
$resolutionForContract = Read-PatchletJson -Path ([IO.Path]::GetFullPath($ResolutionPath))
$releaseGateManifestPath = Join-Path $repositoryRoot `
    'patchlets\features\090-release-gates\patchlet.json'
$releaseGateManifest = Read-PatchletJson -Path $releaseGateManifestPath
if ([int]$releaseGateManifest.revision -ne 62 `
        -or @($releaseGateManifest.dependsOn | Where-Object {
            [string]$_ -ceq '085-in-app-update'
        }).Count -ne 1) {
    throw 'Patchlet 090 must be revision 62 and depend exactly once on patchlet 085.'
}

$semanticCollisionNeedle = 'invoke-virtual {v2, v0, v3}, Lcom/instagram/user/model/UserCache;->A05(LX/02ft;Ljava/lang/String;)Lcom/instagram/user/model/User;'
$semanticCollisionCandidatePaths = @(
    'smali/X/02ja.smali',
    'smali/X/02ja.1.smali'
)
$semanticCollisionTargetDescriptor = 'LX/02ja;'
$semanticCollisionSiblingDescriptor = 'LX/02jA;'
$canonicalNullSeedProofs = @($resolutionForContract.proofs | Where-Object {
        [string]$_.id -ceq 'user-cache-null-seed-user-id-callsite'
    })
if ($canonicalNullSeedProofs.Count -ne 1) {
    throw 'Resolution must own exactly one null-seed user-ID callsite proof.'
}
$canonicalNullSeedProof = $canonicalNullSeedProofs[0]
$canonicalNullSeedProperties = @($canonicalNullSeedProof.PSObject.Properties.Name)
if ([string]$resolutionForContract.source.versionName -ceq '444.0.0.45.85') {
    $expectedCollisionProperties = @(
        'id',
        'candidatePaths',
        'targetClassDescriptor',
        'siblingClassDescriptor',
        'contains',
        'minimumCount'
    )
    if ($canonicalNullSeedProperties.Count -ne $expectedCollisionProperties.Count `
            -or @($expectedCollisionProperties | Where-Object {
                    -not ($canonicalNullSeedProperties -ccontains $_)
                }).Count -ne 0 `
            -or (@($canonicalNullSeedProof.candidatePaths | ForEach-Object {
                        [string]$_
                    }) -join "`n") -cne ($semanticCollisionCandidatePaths -join "`n") `
            -or [string]$canonicalNullSeedProof.targetClassDescriptor `
                -cne $semanticCollisionTargetDescriptor `
            -or [string]$canonicalNullSeedProof.siblingClassDescriptor `
                -cne $semanticCollisionSiblingDescriptor `
            -or [string]$canonicalNullSeedProof.contains -cne $semanticCollisionNeedle `
            -or [int]$canonicalNullSeedProof.minimumCount -ne 1) {
        throw 'Threads 444 resolution must bind the exact descriptor-selected collision proof used by the release fixtures.'
    }
} elseif ([string]$resolutionForContract.source.versionName -ceq '415.0.0.26.77') {
    $expectedOrdinaryProperties = @('id', 'path', 'contains', 'minimumCount')
    if ($canonicalNullSeedProperties.Count -ne $expectedOrdinaryProperties.Count `
            -or @($expectedOrdinaryProperties | Where-Object {
                    -not ($canonicalNullSeedProperties -ccontains $_)
                }).Count -ne 0 `
            -or [string]$canonicalNullSeedProof.path `
                -cne 'smali_classes4/X/3Oy.1.smali' `
            -or [string]::IsNullOrWhiteSpace([string]$canonicalNullSeedProof.contains) `
            -or [int]$canonicalNullSeedProof.minimumCount -ne 1) {
        throw 'Threads 415 resolution must retain its exact ordinary-path null-seed proof layout.'
    }
} else {
    throw 'No reviewed null-seed callsite proof layout exists for this source version.'
}
$semanticCollisionTargetText = @"
.class public final LX/02ja;
.super Ljava/lang/Object;

$semanticCollisionNeedle
"@
$semanticCollisionSiblingText = @"
.class public interface abstract LX/02jA;
.super Ljava/lang/Object;
"@
$semanticCollisionUtf8 = [Text.UTF8Encoding]::new($false)

function New-SemanticCollisionProofContract {
    [pscustomobject][ordered]@{
        id = 'user-cache-null-seed-user-id-callsite'
        candidatePaths = @($semanticCollisionCandidatePaths)
        targetClassDescriptor = $semanticCollisionTargetDescriptor
        siblingClassDescriptor = $semanticCollisionSiblingDescriptor
        contains = $semanticCollisionNeedle
        minimumCount = 1
    }
}

function New-SemanticCollisionFixtureRoot {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$BaseText,
        [AllowNull()][object]$SuffixText,
        [AllowNull()][object]$ExtraText
    )

    $root = Join-Path $scratchFull ('semantic-collision-' + $Name)
    $classRoot = Join-Path $root 'smali\X'
    [IO.Directory]::CreateDirectory($classRoot) | Out-Null
    if ($null -ne $BaseText) {
        [IO.File]::WriteAllText(
            (Join-Path $classRoot '02ja.smali'), [string]$BaseText, $semanticCollisionUtf8)
    }
    if ($null -ne $SuffixText) {
        [IO.File]::WriteAllText(
            (Join-Path $classRoot '02ja.1.smali'), [string]$SuffixText, $semanticCollisionUtf8)
    }
    if ($null -ne $ExtraText) {
        [IO.File]::WriteAllText(
            (Join-Path $classRoot '02ja.2.smali'), [string]$ExtraText, $semanticCollisionUtf8)
    }
    return $root
}

function Assert-SemanticCollisionPositive {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BaseText,
        [Parameter(Mandatory)][string]$SuffixText,
        [Parameter(Mandatory)][string]$ExpectedSelectedPath
    )

    $root = New-SemanticCollisionFixtureRoot `
        -Name $Name -BaseText $BaseText -SuffixText $SuffixText -ExtraText $null
    $resolution = [pscustomobject]@{
        proofs = @((New-SemanticCollisionProofContract))
    }
    $result = @(Test-PatchletProofs -Resolution $resolution -DecodedRoot $root)
    if ($result.Count -ne 1 `
            -or [string]$result[0].id -cne 'user-cache-null-seed-user-id-callsite' `
            -or [string]$result[0].path -cne $ExpectedSelectedPath `
            -or (@($result[0].candidatePaths | ForEach-Object { [string]$_ }) -join "`n") `
                -cne ($semanticCollisionCandidatePaths -join "`n") `
            -or [string]$result[0].targetClassDescriptor `
                -cne $semanticCollisionTargetDescriptor `
            -or [string]$result[0].siblingClassDescriptor `
                -cne $semanticCollisionSiblingDescriptor `
            -or [int]$result[0].count -ne 1 `
            -or [int]$result[0].minimumCount -ne 1) {
        throw "Descriptor-bound semantic collision positive failed: $Name"
    }
    return [pscustomobject]@{
        id = $Name
        selectedPath = [string]$result[0].path
    }
}

function Assert-SemanticCollisionNegative {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Proof,
        [AllowNull()][object]$BaseText,
        [AllowNull()][object]$SuffixText,
        [AllowNull()][object]$ExtraText,
        [string]$ExpectedAbsentRelativePath,
        [string]$ExpectedFailureMessage
    )

    $root = New-SemanticCollisionFixtureRoot `
        -Name ('negative-' + $Name) `
        -BaseText $BaseText -SuffixText $SuffixText -ExtraText $ExtraText
    $absenceVerified = $false
    if (-not [string]::IsNullOrWhiteSpace($ExpectedAbsentRelativePath)) {
        $expectedAbsentPath = Resolve-PatchletChildPath `
            -Root $root -Child $ExpectedAbsentRelativePath
        if (Test-Path -LiteralPath $expectedAbsentPath) {
            throw "Descriptor-bound semantic collision fixture unexpectedly created absent path: $Name"
        }
        $absenceVerified = $true
    }
    $caught = $null
    try {
        Test-PatchletProofs `
            -Resolution ([pscustomobject]@{ proofs = @($Proof) }) `
            -DecodedRoot $root | Out-Null
    } catch {
        $caught = $_
    }
    if ($null -eq $caught) {
        throw "Descriptor-bound semantic collision negative was accepted: $Name"
    }
    $failureMessageVerified = $false
    if (-not [string]::IsNullOrWhiteSpace($ExpectedFailureMessage)) {
        if ([string]$caught.Exception.Message -cne $ExpectedFailureMessage) {
            throw "Descriptor-bound semantic collision negative failed for the wrong condition: $Name"
        }
        $failureMessageVerified = $true
    }
    return [pscustomobject]@{
        id = $Name
        absentPathVerified = $absenceVerified
        failureMessageVerified = $failureMessageVerified
    }
}

$semanticCollisionPositiveResults = @(
    Assert-SemanticCollisionPositive `
        -Name 'target-unsuffixed' `
        -BaseText $semanticCollisionTargetText `
        -SuffixText $semanticCollisionSiblingText `
        -ExpectedSelectedPath 'smali/X/02ja.smali'
    Assert-SemanticCollisionPositive `
        -Name 'target-suffixed' `
        -BaseText $semanticCollisionSiblingText `
        -SuffixText $semanticCollisionTargetText `
        -ExpectedSelectedPath 'smali/X/02ja.1.smali'
)

$semanticCollisionNegativeResults = @()
$semanticCollisionNegativeResults += Assert-SemanticCollisionNegative `
    -Name 'missing-candidate' `
    -Proof (New-SemanticCollisionProofContract) `
    -BaseText $semanticCollisionTargetText -SuffixText $null -ExtraText $null `
    -ExpectedAbsentRelativePath 'smali/X/02ja.1.smali' `
    -ExpectedFailureMessage (
        "Semantic proof 'user-cache-null-seed-user-id-callsite' candidate " +
        "'smali/X/02ja.1.smali' is absent.")
$semanticCollisionNegativeResults += Assert-SemanticCollisionNegative `
    -Name 'duplicate-target-descriptor' `
    -Proof (New-SemanticCollisionProofContract) `
    -BaseText $semanticCollisionTargetText -SuffixText $semanticCollisionTargetText `
    -ExtraText $null
$semanticCollisionNegativeResults += Assert-SemanticCollisionNegative `
    -Name 'duplicate-sibling-descriptor' `
    -Proof (New-SemanticCollisionProofContract) `
    -BaseText $semanticCollisionSiblingText -SuffixText $semanticCollisionSiblingText `
    -ExtraText $null
$singleCandidateProof = New-SemanticCollisionProofContract
$singleCandidateProof.candidatePaths = @($semanticCollisionCandidatePaths[0])
$semanticCollisionNegativeResults += Assert-SemanticCollisionNegative `
    -Name 'single-candidate' -Proof $singleCandidateProof `
    -BaseText $semanticCollisionTargetText `
    -SuffixText $semanticCollisionSiblingText -ExtraText $null
$extraCandidateProof = New-SemanticCollisionProofContract
$extraCandidateProof.candidatePaths = @(
    $semanticCollisionCandidatePaths[0],
    $semanticCollisionCandidatePaths[1],
    'smali/X/02ja.2.smali'
)
$semanticCollisionNegativeResults += Assert-SemanticCollisionNegative `
    -Name 'extra-candidate' -Proof $extraCandidateProof `
    -BaseText $semanticCollisionTargetText `
    -SuffixText $semanticCollisionSiblingText `
    -ExtraText $semanticCollisionSiblingText
$duplicateCandidateProof = New-SemanticCollisionProofContract
$duplicateCandidateProof.candidatePaths = @(
    $semanticCollisionCandidatePaths[0],
    $semanticCollisionCandidatePaths[0]
)
$semanticCollisionNegativeResults += Assert-SemanticCollisionNegative `
    -Name 'duplicate-candidate-path' -Proof $duplicateCandidateProof `
    -BaseText $semanticCollisionTargetText `
    -SuffixText $semanticCollisionSiblingText -ExtraText $null
$semanticCollisionNegativeResults += Assert-SemanticCollisionNegative `
    -Name 'malformed-class-declaration' `
    -Proof (New-SemanticCollisionProofContract) `
    -BaseText ".class public final LX/02ja`n$semanticCollisionNeedle" `
    -SuffixText $semanticCollisionSiblingText -ExtraText $null
$semanticCollisionNegativeResults += Assert-SemanticCollisionNegative `
    -Name 'duplicate-class-declaration' `
    -Proof (New-SemanticCollisionProofContract) `
    -BaseText ($semanticCollisionTargetText + "`n.class public final LX/02ja;`n") `
    -SuffixText $semanticCollisionSiblingText -ExtraText $null
$semanticCollisionNegativeResults += Assert-SemanticCollisionNegative `
    -Name 'unexpected-class-descriptor' `
    -Proof (New-SemanticCollisionProofContract) `
    -BaseText ".class public final LX/02jB;`n$semanticCollisionNeedle" `
    -SuffixText $semanticCollisionSiblingText -ExtraText $null
$semanticCollisionNegativeResults += Assert-SemanticCollisionNegative `
    -Name 'callsite-only-in-sibling' `
    -Proof (New-SemanticCollisionProofContract) `
    -BaseText ".class public final LX/02ja;`n.super Ljava/lang/Object;`n" `
    -SuffixText ($semanticCollisionSiblingText + "`n$semanticCollisionNeedle`n") `
    -ExtraText $null
$mixedPathModeProof = New-SemanticCollisionProofContract
$mixedPathModeProof | Add-Member -NotePropertyName path -NotePropertyValue 'smali/X/02ja.smali'
$semanticCollisionNegativeResults += Assert-SemanticCollisionNegative `
    -Name 'mixed-path-modes' -Proof $mixedPathModeProof `
    -BaseText $semanticCollisionTargetText `
    -SuffixText $semanticCollisionSiblingText -ExtraText $null
if ($semanticCollisionPositiveResults.Count -ne 2 `
        -or $semanticCollisionNegativeResults.Count -ne 11 `
        -or @($semanticCollisionNegativeResults | Where-Object {
                [string]$_.id -ceq 'missing-candidate' `
                    -and [bool]$_.absentPathVerified `
                    -and [bool]$_.failureMessageVerified
            }).Count -ne 1) {
    throw 'Descriptor-bound semantic collision fixture accounting drifted.'
}
$ordinaryProofRoot = Join-Path $scratchFull 'semantic-proof-ordinary-path'
$ordinaryProofPath = Join-Path $ordinaryProofRoot 'smali\X\ordinary.smali'
[IO.Directory]::CreateDirectory((Split-Path -Parent $ordinaryProofPath)) | Out-Null
[IO.File]::WriteAllText($ordinaryProofPath, 'ordinary-proof-literal', $semanticCollisionUtf8)
$ordinaryProofResult = @(Test-PatchletProofs `
    -Resolution ([pscustomobject]@{
        proofs = @([pscustomobject][ordered]@{
                id = 'ordinary-path-compatibility'
                path = 'smali/X/ordinary.smali'
                contains = 'ordinary-proof-literal'
                minimumCount = 1
            })
    }) `
    -DecodedRoot $ordinaryProofRoot)
if ($ordinaryProofResult.Count -ne 1 `
        -or [string]$ordinaryProofResult[0].path -cne 'smali/X/ordinary.smali' `
        -or [int]$ordinaryProofResult[0].count -ne 1) {
    throw 'Ordinary-path semantic proof backward compatibility failed.'
}
$staticReleaseGateSuites = @($releaseGateManifest.operations | Where-Object {
        [string]$_.id -eq 'run-static-release-gates'
    })
if ($staticReleaseGateSuites.Count -ne 1) {
    throw 'Patchlet 090 must define exactly one static release-gate suite.'
}
$releaseGateOrder = @($staticReleaseGateSuites[0].orderedGates | ForEach-Object {
        [string]$_
    })
$proxyBootstrapRawGate = 'socks5-bootstrap-signed-dex-flow-contract'
$targetedJadxGate = 'targeted-jadx-recovery'
$proxyBootstrapRawGateIndex = [Array]::IndexOf($releaseGateOrder, $proxyBootstrapRawGate)
$targetedJadxGateIndex = [Array]::IndexOf($releaseGateOrder, $targetedJadxGate)
$signedReviewGate = 'signed-review-no-publish-contract'
$signedReviewGateIndex = [Array]::IndexOf($releaseGateOrder, $signedReviewGate)
$releaseToolParameterGateIndex = [Array]::IndexOf(
    $releaseGateOrder, 'release-tool-parameter-compatibility')
$releaseToolEvidenceGateIndex = [Array]::IndexOf(
    $releaseGateOrder, 'release-tool-evidence-compatibility')
if (@($releaseGateOrder | Where-Object {
            [string]$_ -ceq $proxyBootstrapRawGate
        }).Count -ne 1 `
        -or @($releaseGateOrder | Where-Object {
            [string]$_ -ceq $targetedJadxGate
        }).Count -ne 1 `
        -or $proxyBootstrapRawGateIndex -ge $targetedJadxGateIndex) {
    throw 'Patchlet 090 must run one raw proxy-bootstrap signed-DEX gate before one targeted-JADX recovery gate.'
}
if (@($releaseGateOrder | Where-Object {
            [string]$_ -ceq $signedReviewGate
        }).Count -ne 1 `
        -or $signedReviewGateIndex -le $releaseToolParameterGateIndex `
        -or $signedReviewGateIndex -ge $releaseToolEvidenceGateIndex) {
    throw 'Patchlet 090 must run one SignedReview no-publish gate between parameter and evidence compatibility.'
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
    $passiveGateIndex = [Array]::IndexOf($releaseGateOrder, $passiveReleaseGate)
    if (@($releaseGateOrder | Where-Object {
                [string]$_ -ceq $passiveReleaseGate
            }).Count -ne 1 `
            -or $passiveGateIndex -le $previousPassiveGateIndex `
            -or $passiveGateIndex -ge $targetedJadxGateIndex) {
        throw "Patchlet 090 passive release gate is missing, duplicated, or misordered: $passiveReleaseGate"
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
    $updateGateIndex = [Array]::IndexOf($releaseGateOrder, $updateReleaseGate)
    if (@($releaseGateOrder | Where-Object {
                [string]$_ -ceq $updateReleaseGate
            }).Count -ne 1 `
            -or $updateGateIndex -le $previousUpdateGateIndex `
            -or $updateGateIndex -ge $targetedJadxGateIndex) {
        throw "Patchlet 090 update gate is missing, duplicated, or misordered: $updateReleaseGate"
    }
    $previousUpdateGateIndex = $updateGateIndex
}
$expectedUpdateMetadataEndpoints = @(
    'https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/threadsmod-update.json',
    'https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/threadsmod-update.json',
    'https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/threadsmod-update.json'
)
$sourceVersionCode = [int64]$resolutionForContract.source.versionCode
$targetModBuild = [int64]$resolutionForContract.target.modBuild
if ($sourceVersionCode -eq [int64]::MaxValue) {
    throw 'Resolution source versionCode cannot be incremented for the clone target.'
}
$expectedTargetVersionCode = $sourceVersionCode + 1L
$expectedTargetVersionName = '{0}-threadsmod.{1}' -f `
    [string]$resolutionForContract.source.versionName, $targetModBuild
$expectedUpdateDexReviewRequired = if (
        [string]$resolutionForContract.status -ceq 'verified-current') {
    $false
} elseif ([string]$resolutionForContract.status -ceq 'review-required') {
    $true
} else {
    throw 'Updater release contract has an unsupported resolution review status.'
}
if ([int64]$resolutionForContract.update.currentModBuild -ne 1L `
        -or $targetModBuild -ne 1L `
        -or [int64]$resolutionForContract.target.versionCode `
            -ne $expectedTargetVersionCode `
        -or [string]$resolutionForContract.target.versionName `
            -cne $expectedTargetVersionName `
        -or [string]$resolutionForContract.update.metadataPurpose `
            -ne 'threadsmod-app-update' `
        -or @(Compare-Object @($resolutionForContract.update.metadataEndpoints) `
            $expectedUpdateMetadataEndpoints -SyncWindow 0).Count -ne 0 `
        -or [string]$resolutionForContract.update.requestInstallPermission `
            -ne 'android.permission.REQUEST_INSTALL_PACKAGES' `
        -or [string]$resolutionForContract.update.fileProviderAuthority `
            -ne 'app.tree55.threads.fileprovider' `
        -or [string]$resolutionForContract.update.fileProviderCachePath `
            -ne 'shared/updates' `
        -or [string]$resolutionForContract.update.requiredSignerCertificateSha256 `
            -ne '317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079' `
        -or $resolutionForContract.release.updateSignedDexReviewRequired `
            -ne $expectedUpdateDexReviewRequired `
        -or [int]$resolutionForContract.release.expectedDexUpdateFlowFixtureCount -ne 96 `
        -or [int]$resolutionForContract.release.expectedDexUpdateFlowInspectorArgumentCount -ne 12) {
    throw 'Resolution updater release contract drifted.'
}
$requiredProviderAuthorities = @()
$seenProviderAuthorities = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
foreach ($authorityRequirement in @($resolutionForContract.release.requiredProviderAuthorities)) {
    $propertyNames = @($authorityRequirement.PSObject.Properties.Name)
    $authority = [string]$authorityRequirement.authority
    $expectedCount = [int]$authorityRequirement.expectedCount
    if ($propertyNames.Count -ne 2 `
            -or -not ($propertyNames -ccontains 'authority') `
            -or -not ($propertyNames -ccontains 'expectedCount') `
            -or [string]::IsNullOrWhiteSpace($authority) `
            -or -not $authority.StartsWith(
                ([string]$resolutionForContract.target.applicationId + '.'),
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
            [string]$_.authority -ceq [string]$resolutionForContract.update.fileProviderAuthority `
                -and [int]$_.expectedCount -eq 1
        }).Count -ne 1) {
    throw 'Resolution must count the updater FileProvider authority exactly once.'
}
$drawerRows = @($resolutionForContract.drawerSettings.rows)
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
if ([string]$resolutionForContract.source.versionName -ceq '444.0.0.45.85' `
        -and $drawerRows.Count -ne 2) {
    throw 'The exact 444.0.0.45.85 resolution must own both runtime-selectable drawer Settings rows.'
}
$dexUpdateFlowInspectorPath = Join-Path $PSScriptRoot 'DexUpdateFlowInspector.java'
$dexUpdateFlowFixtureTestPath = Join-Path $PSScriptRoot `
    'Test-DexUpdateFlowInspector.ps1'
$dexUpdateFlowFixtureRoot = Join-Path $repositoryRoot `
    'patchlets\assets\release-gates\dex-update-flow'
$dexUpdateFlowNegativeManifestPath = Join-Path $dexUpdateFlowFixtureRoot `
    'negative\fixtures.json'
foreach ($requiredUpdateFlowPath in @(
        $dexUpdateFlowInspectorPath,
        $dexUpdateFlowFixtureTestPath,
        $dexUpdateFlowNegativeManifestPath
    )) {
    if (-not (Test-Path -LiteralPath $requiredUpdateFlowPath -PathType Leaf)) {
        throw "Reviewed updater DEX proof asset is missing: $requiredUpdateFlowPath"
    }
}
if ((Get-PatchletSha256 -Path $dexUpdateFlowInspectorPath) `
        -ne [string]$resolutionForContract.assets.dexUpdateFlowInspectorSourceSha256 `
        -or (Get-PatchletSha256 -Path $dexUpdateFlowFixtureTestPath) `
            -ne [string]$resolutionForContract.assets.dexUpdateFlowInspectorTestSourceSha256 `
        -or (Get-PatchletTreeSha256 -Root $dexUpdateFlowFixtureRoot -Filter '*') `
            -ne [string]$resolutionForContract.assets.dexUpdateFlowFixtureTreeSha256) {
    throw 'Reviewed updater DEX proof asset hash differs from the exact resolution.'
}
$dexUpdateFlowNegativeManifest = Read-PatchletJson `
    -Path $dexUpdateFlowNegativeManifestPath
if ([int]$dexUpdateFlowNegativeManifest.schemaVersion -ne 1 `
        -or [int]$dexUpdateFlowNegativeManifest.expectedFixtureCount -ne 96 `
        -or (1 + @($dexUpdateFlowNegativeManifest.fixtures).Count) -ne 96) {
    throw 'Reviewed updater DEX proof fixture count or schema drifted.'
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
$requiredDexUpdateFlow = $resolutionForContract.release.requiredDexUpdateFlow
if ([string]$requiredDexUpdateFlow.id -ne 'threadsmod-update-flow-v1' `
        -or [string]$requiredDexUpdateFlow.expectedDexName -ne 'classes.dex' `
        -or [string]$requiredDexUpdateFlow.classPrefix -ne 'Lthreadsmod/update/' `
        -or [string]$requiredDexUpdateFlow.expectedSemanticSha256 `
            -notmatch '^[0-9a-f]{64}$' `
        -or [int]$requiredDexUpdateFlow.expectedSemanticClassCount -ne 24 `
        -or (@($requiredDexUpdateFlow.orderedRootDescriptors) -join "`n") `
            -cne ($expectedUpdateFlowRoots -join "`n")) {
    throw 'Reviewed updater DEX proof contract metadata drifted.'
}
$commonTargetedJadxClassNames = @(
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
$sourceVersionName = [string]$resolutionForContract.source.versionName
if ($sourceVersionName -ceq '415.0.0.26.77') {
    $reviewedHostTargetedJadxClassNames = @('X.0MO', 'X.0sC')
    $reviewedVisibilityJadxCallCounts = [ordered]@{
        'AutoBlockSync.registerVisibleControl(this,' = 2
        'AutoBlockSync.updateVisibleControl(this,' = 1
        'AutoBlockSync.unregisterVisibleControl(this)' = 1
    }
} elseif ($sourceVersionName -ceq '444.0.0.45.85') {
    $reviewedHostTargetedJadxClassNames = @('X.02Gf', 'X.00sD', 'X.03gS', 'X.03ga')
    $reviewedVisibilityJadxCallCounts = [ordered]@{
        'AutoBlockSync.registerVisibleControl(this,' = 2
        'AutoBlockSync.updateVisibleControl(this,' = 1
        'AutoBlockSync.unregisterVisibleControl(this)' = 3
    }
} else {
    throw "No exact targeted-JADX host layout is reviewed for '$sourceVersionName'."
}
$expectedTargetedJadxClassNames = @(
    'com.instagram.barcelona.mainactivity.BarcelonaActivity'
) + $reviewedHostTargetedJadxClassNames + $commonTargetedJadxClassNames
$resolvedTargetedJadxClassNames = @(
    $resolutionForContract.release.targetedJadxClasses | ForEach-Object {
        [string]$_.className
    })
if ($resolvedTargetedJadxClassNames.Count -ne $expectedTargetedJadxClassNames.Count `
        -or ($resolvedTargetedJadxClassNames -join "`n") -ne (
            $expectedTargetedJadxClassNames -join "`n")) {
    throw "Resolution targeted JADX classes must equal the exact ordered reviewed set for '$sourceVersionName'."
}
function Test-VisibilityJadxCountTuple {
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedCounts
    )

    $countsProperty = $Target.PSObject.Properties['exactStringCounts']
    if ($null -eq $countsProperty) {
        return $false
    }
    $resolvedCountProperties = @($countsProperty.Value.PSObject.Properties)
    if ($resolvedCountProperties.Count -ne $ExpectedCounts.Count) {
        return $false
    }
    foreach ($literal in $ExpectedCounts.Keys) {
        $resolvedCountProperty = $countsProperty.Value.PSObject.Properties[$literal]
        if ($null -eq $resolvedCountProperty `
                -or [int]$resolvedCountProperty.Value -ne [int]$ExpectedCounts[$literal]) {
            return $false
        }
    }
    return $true
}
$visibilityJadxTargets = @(
    $resolutionForContract.release.targetedJadxClasses | Where-Object {
        [string]$_.className -ceq 'threadsmod.inlinecontrol.InlineVisibilityCallback'
    })
if ($visibilityJadxTargets.Count -ne 1 `
        -or -not (Test-VisibilityJadxCountTuple `
            -Target $visibilityJadxTargets[0] `
            -ExpectedCounts $reviewedVisibilityJadxCallCounts)) {
    throw "Resolution InlineVisibilityCallback targeted JADX counts do not match the exact reviewed '$sourceVersionName' tuple."
}
$visibilityCountDriftValues = [ordered]@{}
foreach ($visibilityCountKey in $reviewedVisibilityJadxCallCounts.Keys) {
    $visibilityCountDriftValues[$visibilityCountKey] =
        [int]$reviewedVisibilityJadxCallCounts[$visibilityCountKey]
}
$visibilityCountDriftValues['AutoBlockSync.unregisterVisibleControl(this)'] =
    [int]$reviewedVisibilityJadxCallCounts[
        'AutoBlockSync.unregisterVisibleControl(this)'] + 1
$visibilityCountDriftFixture = [pscustomobject]@{
    exactStringCounts = [pscustomobject]$visibilityCountDriftValues
}
$visibilityJadxCountDriftRejected = -not (Test-VisibilityJadxCountTuple `
    -Target $visibilityCountDriftFixture `
    -ExpectedCounts $reviewedVisibilityJadxCallCounts)
if (-not $visibilityJadxCountDriftRejected) {
    throw 'InlineVisibilityCallback targeted JADX count-drift fixture did not fail closed.'
}
$reviewedPassiveInvalidGenerationJadxCounts = [ordered]@{
    'latchPassiveStorePause(context, str, idMatchLookupId.generation)' = 1
    'threadsmod.autoblock.AutoBlockSync.latchPassiveStorePause(r8.context, r4, r2.generation)' = 1
    'latchPassiveStorePause(context, str, idMatchIsCurrentIdMatch.generation)' = 1
}
$reviewedBlocklistJadxEvidenceBoundary =
    'JADX local-variable recovery is non-authoritative for observed-generation catch paths; release authority is the raw primary-DEX bridge-flow proof.'
$nonAuthoritativeBlocklistJadxLocals = @(
    'invalid(String state, long observedGeneration)',
    'long observedGeneration = 0L;',
    'observedGeneration = metadata.generation;',
    'IdMatch.invalid(STATE_UNAVAILABLE, observedGeneration)',
    'IdMatch.invalid(invalidStore.state, observedGeneration)')
function Test-PassiveInvalidGenerationJadxTuple {
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedCounts
    )

    $requiredProperty = $Target.PSObject.Properties['requiredStrings']
    $countsProperty = $Target.PSObject.Properties['exactStringCounts']
    if ($null -eq $requiredProperty -or $null -eq $countsProperty) {
        return $false
    }
    $required = @($requiredProperty.Value | ForEach-Object { [string]$_ })
    $resolvedRequired = @($required | Where-Object {
            $_.IndexOf('latchPassiveStorePause', [StringComparison]::Ordinal) -ge 0 `
                -and $_.IndexOf('.generation', [StringComparison]::Ordinal) -ge 0
        })
    $resolvedCountProperties = @(
        $countsProperty.Value.PSObject.Properties | Where-Object {
            $_.Name.IndexOf('latchPassiveStorePause', [StringComparison]::Ordinal) -ge 0 `
                -and $_.Name.IndexOf('.generation', [StringComparison]::Ordinal) -ge 0
        })
    $expectedKeys = @($ExpectedCounts.Keys | ForEach-Object { [string]$_ })
    if (($resolvedRequired -join "`n") -cne ($expectedKeys -join "`n") `
            -or ($resolvedCountProperties.Name -join "`n") -cne `
                ($expectedKeys -join "`n")) {
        return $false
    }
    foreach ($literal in $expectedKeys) {
        $property = $countsProperty.Value.PSObject.Properties[$literal]
        if ($null -eq $property `
                -or [int]$property.Value -ne [int]$ExpectedCounts[$literal]) {
            return $false
        }
    }
    return $true
}
$resolvedRequiredDescriptors = @(
    $resolutionForContract.release.requiredClassDescriptors | ForEach-Object {
        [string]$_
    })
if ($resolvedRequiredDescriptors.Count -ne 54) {
    throw 'Resolution required descriptors must equal the exact 54-class passive-plus-update release set.'
}
foreach ($passiveDescriptor in @(
        'Lthreadsmod/autoblock/BlocklistStore;',
        'Lthreadsmod/inlinecontrol/InlineVisibilityCallback;')) {
    if (@($resolvedRequiredDescriptors | Where-Object {
                [string]$_ -ceq $passiveDescriptor
            }).Count -ne 1) {
        throw "Resolution must require passive signed-DEX descriptor exactly once: $passiveDescriptor"
    }
}
foreach ($updateDescriptor in @(
        'Lthreadsmod/update/UpdateController;',
        'Lthreadsmod/update/UpdateEndpoints;',
        'Lthreadsmod/update/UpdateJson;',
        'Lthreadsmod/update/UpdateManifest;',
        'Lthreadsmod/update/UpdateSignature;',
        'Lthreadsmod/update/UpdateStore;')) {
    if (@($resolvedRequiredDescriptors | Where-Object {
                [string]$_ -ceq $updateDescriptor
            }).Count -ne 1) {
        throw "Resolution must require updater signed-DEX descriptor exactly once: $updateDescriptor"
    }
}
foreach ($updateFinalDexMarker in @(
        'threadsmod-app-update',
        'Required update',
        'application/vnd.android.package-archive')) {
    if (@($resolutionForContract.release.requiredHookCalls | Where-Object {
                [string]$_ -ceq $updateFinalDexMarker
            }).Count -ne 1) {
        throw "Resolution must require updater general final-DEX marker exactly once: $updateFinalDexMarker"
    }
}
if (@($resolutionForContract.release.requiredHookCalls | Where-Object {
            [string]$_ -ceq [string]$resolutionForContract.update.requestInstallPermission
        }).Count -ne 0) {
    throw 'Manifest-only updater permission must not be required as a general final-DEX marker.'
}
$updateInstallPermission = [string]$resolutionForContract.update.requestInstallPermission
$updateInstallPermissionFailure = 'Final manifest must request REQUEST_INSTALL_PACKAGES exactly once.'
$decodedPermissionPositive = '<manifest xmlns:android="http://schemas.android.com/apk/res/android"><uses-permission android:name="' + `
    $updateInstallPermission + '"/></manifest>'
$aaptPermissionPositive = @(
    '    E: manifest (line=1)'
    '        E: uses-permission (line=2)'
    '          A: http://schemas.android.com/apk/res/android:name(0x01010003)="' + $updateInstallPermission + `
        '" (Raw: "' + $updateInstallPermission + '")'
) -join "`n"
$null = Assert-PatchletManifestPermission -ManifestText $decodedPermissionPositive `
    -Permission $updateInstallPermission -Format 'decoded-xml' `
    -FailureMessage $updateInstallPermissionFailure
$null = Assert-PatchletManifestPermission -ManifestText $aaptPermissionPositive `
    -Permission $updateInstallPermission -Format 'aapt2-xmltree' `
    -FailureMessage $updateInstallPermissionFailure
$updateInstallPermissionNegativeFixtures = @(
    [pscustomobject]@{
        id = 'decoded-missing-permission'
        format = 'decoded-xml'
        text = '<manifest xmlns:android="http://schemas.android.com/apk/res/android"><uses-permission android:name="android.permission.INTERNET"/></manifest>'
    },
    [pscustomobject]@{
        id = 'decoded-wrong-element-decoy'
        format = 'decoded-xml'
        text = '<manifest xmlns:android="http://schemas.android.com/apk/res/android"><application><meta-data android:value="' + `
            $updateInstallPermission + '"/></application></manifest>'
    },
    [pscustomobject]@{
        id = 'aapt-wrong-element-decoy'
        format = 'aapt2-xmltree'
        text = @(
            '    E: manifest (line=1)'
            '        E: application (line=2)'
            '            E: meta-data (line=3)'
            '              A: http://schemas.android.com/apk/res/android:value(0x01010024)="' + $updateInstallPermission + '"'
        ) -join "`n"
    },
    [pscustomobject]@{
        id = 'aapt-duplicate-uses-permission'
        format = 'aapt2-xmltree'
        text = $aaptPermissionPositive + "`n        E: uses-permission (line=3)`n" +
            '          A: http://schemas.android.com/apk/res/android:name(0x01010003)="' + $updateInstallPermission + '"'
    },
    [pscustomobject]@{
        id = 'aapt-unnamespaced-name-decoy'
        format = 'aapt2-xmltree'
        text = "    E: manifest (line=1)`n        E: uses-permission (line=2)`n" +
            '          A: name="' + $updateInstallPermission + '"'
    },
    [pscustomobject]@{
        id = 'aapt-nested-child-name-decoy'
        format = 'aapt2-xmltree'
        text = "    E: manifest (line=1)`n        E: uses-permission (line=2)`n" +
            "            E: meta-data (line=3)`n" +
            '              A: http://schemas.android.com/apk/res/android:name(0x01010003)="' + $updateInstallPermission + '"'
    },
    [pscustomobject]@{
        id = 'aapt-wrong-parent-uses-permission'
        format = 'aapt2-xmltree'
        text = "    E: manifest (line=1)`n        E: application (line=2)`n" +
            "            E: uses-permission (line=3)`n" +
            '              A: http://schemas.android.com/apk/res/android:name(0x01010003)="' + $updateInstallPermission + '"'
    }
)
$updateInstallPermissionNegativeResults = @()
foreach ($fixture in $updateInstallPermissionNegativeFixtures) {
    $caught = $null
    try {
        $null = Assert-PatchletManifestPermission -ManifestText ([string]$fixture.text) `
            -Permission $updateInstallPermission -Format ([string]$fixture.format) `
            -FailureMessage $updateInstallPermissionFailure
    } catch {
        $caught = $_
    }
    if ($null -eq $caught `
            -or $caught.Exception.Message -cne $updateInstallPermissionFailure) {
        throw "Updater manifest permission negative '$($fixture.id)' did not fail closed."
    }
    $updateInstallPermissionNegativeResults += [pscustomobject]@{
        id = [string]$fixture.id
        rejected = $true
    }
}
$missingUpdateInstallPermissionRejected = `
    @($updateInstallPermissionNegativeResults | Where-Object id -ceq 'decoded-missing-permission').Count -eq 1

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
    -Reference $resolutionForContract.inlineControls.symbols.layoutAttachedMethod `
    -Label 'inlineControls.symbols.layoutAttachedMethod'
$rectEmptyJadxToken = Get-ResolutionNoArgBooleanJadxToken `
    -Reference $resolutionForContract.inlineControls.symbols.rectEmptyMethod `
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
        'IdMatch',
        'storeValid',
        'matched',
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
        'adapter_exception',
        'latchPassiveStorePause(context, str, idMatchLookupId.generation)',
        'threadsmod.autoblock.AutoBlockSync.latchPassiveStorePause(r8.context, r4, r2.generation)',
        'latchPassiveStorePause(context, str, idMatchIsCurrentIdMatch.generation)',
        'if (j <= 0 || !snapshot.valid || snapshot.generation <= j)',
        'if (passiveStorePaused && j > passiveStorePauseGeneration)',
        'Map<String, ?> all = sharedPreferences.getAll()',
        'readDeadline(prefs(context), KEY_LIST_REFRESH_NOT_BEFORE, j, MAX_LIST_REFRESH_DEADLINE_FUTURE_MS)',
        'signed root exceeds the local byte cap',
        'signed root is not v3',
        'signed root bucket function is not sha256-hi32',
        'signed root chunk caps exceed the local caps',
        'signed root has no threads partition',
        'signed root threads partition is malformed',
        'signed root exceeds the local bucket cap',
        'signed root exceeds the local row cap',
        'ChunkInstaller.stage(',
        'signed objects could not be staged')
    'threadsmod.autoblock.ModStateStore' = @(
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
        'markAutomaticDone(')
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
        'safeMessage(', 'getMessage(', 'getLocalizedMessage(',
        'printStackTrace(', 'getStackTraceString(',
        'hasForegroundRunCapacity(', 'rateAllowed(', 'millisUntilRateAllowed(',
        'automaticPerHour(', 'targetBudget(', 'totalPerHour(', 'totalPerDay(',
        'maxPerRun(', 'manualMinDelayMs(', 'manualMaxDelayMs(',
        'admitForegroundPassiveTarget(', 'removeForegroundPassiveTarget(',
        'targetBudgetAdded')
    'threadsmod.autoblock.ModStateStore' = @(
        'getStringSet(', 'safeMessage(', 'getMessage(', 'getLocalizedMessage(',
        'printStackTrace(', 'getStackTraceString(')
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
    'threadsmod.inlinecontrol.InlineActionRowAdapter' = @(
        'AutoBlockSync.getCurrentViewer(')
}
foreach ($passiveClassName in $passiveTargetRequirements.Keys) {
    $passiveTarget = @($resolutionForContract.release.targetedJadxClasses | Where-Object {
            [string]$_.className -ceq $passiveClassName
        })
    if ($passiveTarget.Count -ne 1) {
        throw "Resolution must target passive evidence class exactly once: $passiveClassName"
    }
    $requiredPassiveStrings = @(
        $passiveTarget[0].requiredStrings | ForEach-Object { [string]$_ })
    foreach ($requiredPassiveString in $passiveTargetRequirements[$passiveClassName]) {
        if ($requiredPassiveStrings -notcontains $requiredPassiveString) {
            throw "Passive targeted contract '$passiveClassName' omits '$requiredPassiveString'."
        }
    }
    if ($passiveTargetForbidden.Contains($passiveClassName)) {
        $forbiddenPassiveStrings = @(
            $passiveTarget[0].forbiddenStrings | ForEach-Object { [string]$_ })
        foreach ($forbiddenPassiveString in $passiveTargetForbidden[$passiveClassName]) {
            if ($forbiddenPassiveStrings -notcontains $forbiddenPassiveString) {
                throw "Passive targeted contract '$passiveClassName' does not forbid '$forbiddenPassiveString'."
            }
        }
    }
}
$autoBlockPassiveTarget = @($resolutionForContract.release.targetedJadxClasses | Where-Object {
        [string]$_.className -ceq 'threadsmod.autoblock.AutoBlockSync'
    })[0]
$blocklistStorePassiveTarget = @($resolutionForContract.release.targetedJadxClasses | Where-Object {
        [string]$_.className -ceq 'threadsmod.autoblock.BlocklistStore'
    })[0]
$blocklistJadxRequiredStrings = @(
    $blocklistStorePassiveTarget.requiredStrings | ForEach-Object { [string]$_ })
$blocklistJadxCountNames = @(
    $blocklistStorePassiveTarget.exactStringCounts.PSObject.Properties.Name |
        ForEach-Object { [string]$_ })
$blocklistJadxLocalsExcluded = $true
foreach ($nonAuthoritativeBlocklistJadxLocal in $nonAuthoritativeBlocklistJadxLocals) {
    if ($blocklistJadxRequiredStrings -contains $nonAuthoritativeBlocklistJadxLocal `
            -or $blocklistJadxCountNames -contains $nonAuthoritativeBlocklistJadxLocal) {
        $blocklistJadxLocalsExcluded = $false
    }
}
$blocklistJadxEvidenceBoundaryBound =
    [string]$blocklistStorePassiveTarget.evidenceBoundary -ceq `
        $reviewedBlocklistJadxEvidenceBoundary
if (-not $blocklistJadxEvidenceBoundaryBound `
        -or -not $blocklistJadxLocalsExcluded) {
    throw 'BlocklistStore targeted JADX must declare its local-variable nonauthority and omit impossible source-local generation spellings.'
}
$passiveInvalidGenerationJadxTupleBound = Test-PassiveInvalidGenerationJadxTuple `
    -Target $autoBlockPassiveTarget `
    -ExpectedCounts $reviewedPassiveInvalidGenerationJadxCounts
$passiveInvalidGenerationDriftCounts = [ordered]@{}
foreach ($literal in $reviewedPassiveInvalidGenerationJadxCounts.Keys) {
    $passiveInvalidGenerationDriftCounts[$literal] =
        [int]$reviewedPassiveInvalidGenerationJadxCounts[$literal]
}
$passiveInvalidGenerationDriftCounts[
    'latchPassiveStorePause(context, str, idMatchLookupId.generation)'] = 2
$passiveInvalidGenerationJadxCountDriftRejected = -not (
    Test-PassiveInvalidGenerationJadxTuple `
        -Target ([pscustomobject]@{
            requiredStrings = @($reviewedPassiveInvalidGenerationJadxCounts.Keys)
            exactStringCounts = [pscustomobject]$passiveInvalidGenerationDriftCounts
        }) `
        -ExpectedCounts $reviewedPassiveInvalidGenerationJadxCounts)
if (-not $passiveInvalidGenerationJadxTupleBound `
        -or -not $passiveInvalidGenerationJadxCountDriftRejected) {
    throw 'Passive invalid-generation targeted-JADX tuple is missing or its count-drift negative was accepted.'
}
if ([int]$autoBlockPassiveTarget.exactStringCounts.'BlocklistStore.replaceVerified(' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'BlocklistStore.isCurrentIdMatch(' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'new BlockRun(' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'ThreadsBlockBridge.passivePreflight(' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'KEY_LIST_REFRESH_NOT_BEFORE' -ne 3 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'LIST_REFRESH_DEADLINE_LOCK' -ne 3 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'readListRefreshDeadline(' -ne 3 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'advanceListRefreshDeadline(' -ne 6 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'currentPassiveAuthority(' -ne 4 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'currentPassiveMatch(' -ne 5 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'latchPassiveStorePause(' -ne 5 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'clearPassiveStorePauseAfterVerifiedGeneration(' -ne 2 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'latchPassiveStorePause(context, str, idMatchLookupId.generation)' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'threadsmod.autoblock.AutoBlockSync.latchPassiveStorePause(r8.context, r4, r2.generation)' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'latchPassiveStorePause(context, str, idMatchIsCurrentIdMatch.generation)' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'if (j <= 0 || !snapshot.valid || snapshot.generation <= j)' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'if (passiveStorePaused && j > passiveStorePauseGeneration)' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'Map<String, ?> all = sharedPreferences.getAll()' -ne 2 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'readDeadline(prefs(context), KEY_LIST_REFRESH_NOT_BEFORE, j, MAX_LIST_REFRESH_DEADLINE_FUTURE_MS)' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'signed root is not v3' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'signed root bucket function is not sha256-hi32' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'signed root has no threads partition' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'signed root exceeds the local row cap' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'ChunkInstaller.stage(' -ne 1 `
        -or [int]$autoBlockPassiveTarget.exactStringCounts.'signed objects could not be staged' -ne 1) {
    throw 'Passive AutoBlockSync recovery must pin the durable deadline, fail-closed deadline reads, tri-state generation latch, strict signed-root parsing with one staged install path, and three final authority gates without retired capacity admission.'
}
$chunkInstallerPassiveTarget = @($resolutionForContract.release.targetedJadxClasses | Where-Object {
        [string]$_.className -ceq 'threadsmod.autoblock.ChunkInstaller'
    })[0]
$objectFetcherPassiveTarget = @($resolutionForContract.release.targetedJadxClasses | Where-Object {
        [string]$_.className -ceq 'threadsmod.autoblock.ObjectFetcher'
    })[0]
if ([int]$chunkInstallerPassiveTarget.exactStringCounts.'BlocklistStore.stageChunk(' -ne 1 `
        -or [int]$chunkInstallerPassiveTarget.exactStringCounts.'chunk row is not a JSON object' -ne 1 `
        -or [int]$chunkInstallerPassiveTarget.exactStringCounts.'chunk rows contain a duplicate numeric id' -ne 1 `
        -or [int]$chunkInstallerPassiveTarget.exactStringCounts.'chunk rows have conflicting normalized usernames' -ne 1 `
        -or [int]$objectFetcherPassiveTarget.exactStringCounts.'CloneBlockerEndpoints.objectUrl(' -ne 1 `
        -or [int]$objectFetcherPassiveTarget.exactStringCounts.'signed root names an object whose bytes do not match' -ne 1) {
    throw 'Chunk installer and object fetcher recovery must pin one staging path, fixed whole-chunk rejections, one allowlisted object URL builder, and one hash-before-return proof.'
}
if ([int]$blocklistStorePassiveTarget.exactStringCounts.'CREATE INDEX blocklist_targets_username_idx' -ne 1 `
        -or [int]$blocklistStorePassiveTarget.exactStringCounts.'CREATE UNIQUE INDEX blocklist_targets_username_idx' -ne 1 `
        -or [int]$blocklistStorePassiveTarget.exactStringCounts.'stageChunk(' -ne 1 `
        -or [int]$blocklistStorePassiveTarget.exactStringCounts.'replaceVerified(' -ne 1 `
        -or [int]$blocklistStorePassiveTarget.exactStringCounts.'lookupId(' -ne 1 `
        -or [int]$blocklistStorePassiveTarget.exactStringCounts.'isCurrentIdMatch(' -ne 1 `
        -or [int]$blocklistStorePassiveTarget.exactStringCounts.'lookupUsernameMetadata(' -ne 1 `
        -or [int]$blocklistStorePassiveTarget.exactStringCounts.'normalizeUsername(' -ne 5 `
        -or [int]$blocklistStorePassiveTarget.exactStringCounts.'Instant.parse(' -ne 2 `
        -or [int]$blocklistStorePassiveTarget.exactStringCounts.'count(DISTINCT username_key)' -ne 1 `
        -or [int]$blocklistStorePassiveTarget.exactStringCounts.'requireUniqueUsername(' -ne 3) {
    throw 'Passive BlocklistStore recovery must pin indexed lookup, tri-state results, normalized-username uniqueness, and timestamp rebinding without treating recovered locals as release authority.'
}
$expectedPassiveAutoBlockOrder = @(
    'new PassiveRegistration(',
    'updateVisibleControl(',
    'isMainLooperThread()',
    'PASSIVE_REGISTRATIONS.remove(',
    'latchPassiveStorePause(',
    'visibleUsernameMatchesStored(',
    'readListRefreshDeadline(',
    'LIST_REFRESH_RUNNING.compareAndSet(false, true)',
    'advanceListRefreshDeadline(',
    'new ListRefreshWorker(',
    'synchronized (PASSIVE_ADMISSION_LOCK)',
    'BlocklistStore.replaceVerified(',
    'clearPassiveStorePauseAfterVerifiedGeneration(',
    'synchronized (AutoBlockSync.PASSIVE_ADMISSION_LOCK)',
    'AutoBlockSync.currentPassiveMatch(',
    'ThreadsBlockBridge.passivePreflight(',
    'currentPassiveAuthority(false, false)',
    'ModStateStore.markPassiveRunning(',
    'currentPassiveAuthority(true, false)',
    'AutoBlockSync.reserveAttempt(',
    'currentPassiveAuthority(true, true)',
    'ThreadsBlockBridge.block('
)
$resolvedPassiveAutoBlockOrder = @(
    $autoBlockPassiveTarget.orderedStrings | ForEach-Object { [string]$_ })
if (($resolvedPassiveAutoBlockOrder -join "`n") -cne ($expectedPassiveAutoBlockOrder -join "`n")) {
    throw 'Passive AutoBlockSync recovery order must bind main-thread grants, admission-locked revocation/replacement, preflight, three authority gates, atomic passive reservation, and dispatch.'
}
$expectedPassiveBlocklistOrder = @(
    'username_key = lower(username)',
    'requireUniqueUsername(',
    'Instant.parse(',
    'count(DISTINCT username_key)'
)
$resolvedPassiveBlocklistOrder = @(
    $blocklistStorePassiveTarget.orderedStrings | ForEach-Object { [string]$_ })
if (($resolvedPassiveBlocklistOrder -join "`n") -cne ($expectedPassiveBlocklistOrder -join "`n")) {
    throw 'Passive BlocklistStore recovery order must bind normalized-username uniqueness and exact timestamp/schema validation.'
}
$settingsPassiveDisclosure =
    'Always on. Refreshes the signed index every 10 minutes in the foreground, then blocks only listed profiles whose post or reply action row becomes visible.'
if (@($resolutionForContract.release.requiredHookCalls | Where-Object {
            [string]$_ -ceq $settingsPassiveDisclosure
        }).Count -ne 1) {
    throw 'Resolution final-DEX contract omits the exact foreground-only Settings passive disclosure.'
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
    if (@($resolutionForContract.release.requiredHookCalls | Where-Object {
                [string]$_ -ceq $currentPassiveFinalDexMarker
            }).Count -ne 1) {
        throw "Resolution final-DEX contract omits '$currentPassiveFinalDexMarker'."
    }
}
if (@($resolutionForContract.release.requiredHookCalls | Where-Object {
            [string]$_ -ceq 'limit_automatic_per_hour'
        }).Count -ne 0) {
    throw 'Resolution incorrectly treats a retired capacity key as a positive final-DEX marker.'
}

$dexLiteralFixtureReportPath = Join-Path $scratchFull 'dex-literal-call-fixtures.json'
$dexLiteralFixtureResult = & (Join-Path $PSScriptRoot 'Test-DexLiteralCallInspector.ps1') `
    -ScratchRoot (Join-Path $scratchFull 'dex-literal-call-fixtures') `
    -ResolutionPath ([IO.Path]::GetFullPath($ResolutionPath)) `
    -ReportPath $dexLiteralFixtureReportPath
if ([string]$dexLiteralFixtureResult.status -ne 'passed' `
        -or @($dexLiteralFixtureResult.fixtures).Count -ne 5) {
    throw 'DEX direct-string literal/call contract fixtures did not all complete.'
}

$dexProxyBootstrapFlowFixtureReportPath = Join-Path $scratchFull `
    'dex-proxy-bootstrap-flow-fixtures.json'
$dexProxyBootstrapFlowFixtureResult = & (
    Join-Path $PSScriptRoot 'Test-DexProxyBootstrapFlowInspector.ps1') `
    -ScratchRoot (Join-Path $scratchFull 'dex-proxy-bootstrap-flow-fixtures') `
    -ResolutionPath ([IO.Path]::GetFullPath($ResolutionPath)) `
    -ReportPath $dexProxyBootstrapFlowFixtureReportPath
if ([string]$dexProxyBootstrapFlowFixtureResult.status -ne 'passed' `
        -or [int]$dexProxyBootstrapFlowFixtureResult.expectedFixtureCount -ne 13 `
        -or @($dexProxyBootstrapFlowFixtureResult.fixtures).Count -ne 13 `
        -or [int]$dexProxyBootstrapFlowFixtureResult.inspectorArgumentCount -ne 11) {
    throw 'Signed-DEX proxy-bootstrap-flow contract fixtures did not complete all 13 cases with the 11-argument inspector.'
}

$dexBridgeFlowFixtureReportPath = Join-Path $scratchFull 'dex-bridge-flow-fixtures.json'
$dexBridgeFlowFixtureResult = & (Join-Path $PSScriptRoot 'Test-DexBridgeFlowInspector.ps1') `
    -ScratchRoot (Join-Path $scratchFull 'dex-bridge-flow-fixtures') `
    -ResolutionPath ([IO.Path]::GetFullPath($ResolutionPath)) `
    -ReportPath $dexBridgeFlowFixtureReportPath
if ([string]$dexBridgeFlowFixtureResult.status -ne 'passed' `
        -or [int]$dexBridgeFlowFixtureResult.expectedFixtureCount `
            -ne @($dexBridgeFlowFixtureResult.fixtures).Count) {
    throw 'Signed-DEX bridge-flow contract fixtures did not all complete.'
}

$dexReportPermalinkFlowFixtureReportPath = Join-Path $scratchFull 'dex-report-permalink-flow-fixtures.json'
$dexReportPermalinkFlowFixtureResult = & (Join-Path $PSScriptRoot 'Test-DexReportPermalinkFlowInspector.ps1') `
    -ScratchRoot (Join-Path $scratchFull 'dex-report-permalink-flow-fixtures') `
    -ResolutionPath ([IO.Path]::GetFullPath($ResolutionPath)) `
    -ReportPath $dexReportPermalinkFlowFixtureReportPath
if ([string]$dexReportPermalinkFlowFixtureResult.status -ne 'passed' `
        -or [int]$dexReportPermalinkFlowFixtureResult.expectedFixtureCount -ne 41 `
        -or @($dexReportPermalinkFlowFixtureResult.fixtures).Count -ne 41 `
        -or [int]$dexReportPermalinkFlowFixtureResult.inspectorArgumentCount -ne 33) {
    throw 'Signed-DEX report-permalink-flow contract fixtures did not all complete.'
}

$freezeFixture = Join-Path $scratchFull 'freeze-fixture.txt'
$driftPublishProbe = Join-Path $repositoryRoot ("dist\.release-freeze-drift-probe-{0}.apk" -f [guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($freezeFixture, "before`n", [Text.UTF8Encoding]::new($false))
$freezeSnapshot = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{ id = 'deterministic-drift-fixture'; kind = 'file'; path = $freezeFixture; filter = $null }
    ))
[IO.File]::WriteAllText($freezeFixture, "after`n", [Text.UTF8Encoding]::new($false))
$driftCaught = $null
try {
    $null = Assert-PatchletInputFreeze -Snapshot $freezeSnapshot -Stage 'contract-test-pre-publish'
    Copy-Item -LiteralPath $freezeFixture -Destination $driftPublishProbe
} catch {
    $driftCaught = $_
}
if ($null -eq $driftCaught `
        -or -not $driftCaught.Exception.Message.Contains('Release input drift', [StringComparison]::Ordinal)) {
    throw 'Deterministic release-input drift probe did not fail closed.'
}
if (Test-Path -LiteralPath $driftPublishProbe) {
    throw "Release-input drift probe unexpectedly published an APK: $driftPublishProbe"
}

$lockFixture = Join-Path $scratchFull 'lock-fixture.txt'
[IO.File]::WriteAllText($lockFixture, "locked`n", [Text.UTF8Encoding]::new($false))
$lockSnapshot = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{ id = 'deterministic-lock-fixture'; kind = 'file'; path = $lockFixture; filter = $null }
    ))
$freezeLock = Enter-PatchletInputFreezeLock -Snapshot $lockSnapshot -Stage 'contract-test-lock'
$lockBlockedWrite = $false
try {
    try {
        [IO.File]::WriteAllText($lockFixture, "unexpected-write`n", [Text.UTF8Encoding]::new($false))
    } catch [IO.IOException] {
        $lockBlockedWrite = $true
    }
} finally {
    Exit-PatchletInputFreezeLock -Lock $freezeLock
}
if (-not $lockBlockedWrite `
        -or (Get-PatchletSha256 -Path $lockFixture) -ne [string]$lockSnapshot[0].sha256) {
    throw 'Release-input lock did not prevent transient mutation of a frozen file.'
}

$treeLockRoot = Join-Path $scratchFull 'lock-tree'
[IO.Directory]::CreateDirectory($treeLockRoot) | Out-Null
$treeLockExisting = Join-Path $treeLockRoot 'existing.txt'
$treeLockAddition = Join-Path $treeLockRoot 'transient.txt'
[IO.File]::WriteAllText($treeLockExisting, "existing`n", [Text.UTF8Encoding]::new($false))
$treeLockSnapshot = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{ id = 'deterministic-tree-lock-fixture'; kind = 'tree'; path = $treeLockRoot; filter = '*' }
    ))
$treeFreezeLock = Enter-PatchletInputFreezeLock -Snapshot $treeLockSnapshot -Stage 'contract-test-tree-lock'
$treeLockDetectedTransient = $false
$transactionDriftCaught = $null
try {
    [IO.File]::WriteAllText($treeLockAddition, "transient-addition`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::Delete($treeLockAddition)
    $null = [Threading.SpinWait]::SpinUntil({ $treeFreezeLock.monitors[0].EventCount -gt 0 }, 2000)
    try { $null = Assert-PatchletInputFreezeLock -Lock $treeFreezeLock -Stage 'contract-test-tree-drift' } catch {
        $treeLockDetectedTransient = $_.Exception.Message.Contains('Release input tree drift', [StringComparison]::Ordinal)
    }
    try {
        $null = Invoke-PatchletPublicationTransaction `
            -SourceArtifact $treeLockExisting `
            -PublishPath $driftPublishProbe `
            -ExpectedSha256 (Get-PatchletSha256 -Path $treeLockExisting) `
            -InputSnapshot $treeLockSnapshot `
            -InputLock $treeFreezeLock
    } catch {
        $transactionDriftCaught = $_
    }
} finally {
    Exit-PatchletInputFreezeLock -Lock $treeFreezeLock
}
if (-not $treeLockDetectedTransient `
        -or $null -eq $transactionDriftCaught `
        -or (Test-Path -LiteralPath $treeLockAddition) `
        -or (Test-Path -LiteralPath $driftPublishProbe) `
        -or (Get-PatchletTreeSha256 -Root $treeLockRoot -Filter '*') -ne [string]$treeLockSnapshot[0].sha256) {
    throw 'Release-input tree drift did not fail the publication transaction with no target.'
}

$decodedRoot = [IO.Path]::GetFullPath((Join-Path $scratchFull 'pipeline-decoded-root'))
[IO.Directory]::CreateDirectory((Join-Path $decodedRoot 'res')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $decodedRoot 'empty')) | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $decodedRoot 'AndroidManifest.xml'), "manifest-before`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText(
    (Join-Path $decodedRoot 'res\stable.smali'), "stable`n", [Text.UTF8Encoding]::new($false))
$decodedBuildCache = Assert-PatchletPathUnderRoot `
    -Path (Join-Path $decodedRoot 'build') -Root $decodedRoot
if (Test-Path -LiteralPath $decodedBuildCache) {
    throw 'Pipeline-shaped decoded build-cache fixture must begin absent.'
}
$decodedInputFreeze = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{
            id = 'decoded-build-input'
            kind = 'complete-tree'
            path = $decodedRoot
            filter = $null
        }
    ))
$decodedInputLock = Enter-PatchletInputFreezeLock `
    -Snapshot $decodedInputFreeze `
    -Stage 'decoded-input-before-idempotency'
$decodedIdempotencyFreeze = $null
$decodedIdempotencyLock = $null
$decodedCanonicalWriteBlocked = $false
$buildWorkingCopyFixture = $null
$buildWorkingMutationEvents = $null
$buildWorkingOmittedTreeAllowlistCaught = $null
$buildWorkingOmittedFileAllowlistCaught = $null
$buildWorkingSealOverlapCheck = $null
$buildWorkingSealedCheck = $null
$buildWorkingSealedWriteBlocked = $false
$buildWorkingStableWriteBlocked = $false
$buildWorkingHandleCountPassed = $false
try {
    try {
        [IO.File]::WriteAllText(
            (Join-Path $decodedRoot 'res\stable.smali'), "mutated`n", [Text.UTF8Encoding]::new($false))
    } catch [IO.IOException] { $decodedCanonicalWriteBlocked = $true }
    $decodedIdempotencyFreeze = Assert-PatchletInputFreeze `
        -Snapshot $decodedInputFreeze -Stage 'decoded-input-after-idempotency'
    $decodedIdempotencyLock = Assert-PatchletInputFreezeLock `
        -Lock $decodedInputLock -Stage 'decoded-input-after-idempotency'

    $buildWorkingRoot = Assert-PatchletPathUnderRoot `
        -Path (Join-Path $scratchFull 'pipeline-build-working-decoded') -Root $scratchFull
    $buildWorkingCopyFixture = Copy-PatchletCompleteTree `
        -SourceRoot $decodedRoot -DestinationRoot $buildWorkingRoot
    $buildWorkingBuildCache = Assert-PatchletPathUnderRoot `
        -Path (Join-Path $buildWorkingRoot 'build') -Root $buildWorkingRoot
    $buildWorkingManifest = Assert-PatchletPathUnderRoot `
        -Path (Join-Path $buildWorkingRoot 'AndroidManifest.xml') -Root $buildWorkingRoot
    $buildWorkingManifestOriginal = Assert-PatchletPathUnderRoot `
        -Path (Join-Path $buildWorkingRoot 'AndroidManifest.xml.orig') -Root $buildWorkingRoot
    $buildWorkingInputFreeze = @(New-PatchletInputFreeze -Inputs @(
            [pscustomobject]@{
                id = 'build-working-decoded-input'
                kind = 'complete-tree'
                path = $buildWorkingRoot
                filter = $null
            }
        ))
    $buildWorkingMutationLock = Enter-PatchletInputFreezeLock `
        -Snapshot $buildWorkingInputFreeze `
        -Stage 'build-working-before-apktool' `
        -AllowedTreeMutationRoots @($buildWorkingBuildCache) `
        -AllowedFileMutationPaths @($buildWorkingManifest, $buildWorkingManifestOriginal)
    $buildWorkingHandleCountPassed = [int]$buildWorkingMutationLock.fileCount `
        -eq ([int]$buildWorkingInputFreeze[0].files - 1)
    try {
        try {
            [IO.File]::WriteAllText(
                (Join-Path $buildWorkingRoot 'res\stable.smali'),
                "unexpected-work-write`n", [Text.UTF8Encoding]::new($false))
        } catch [IO.IOException] { $buildWorkingStableWriteBlocked = $true }
        try {
            $null = Assert-PatchletInputFreezeLock `
                -Lock $buildWorkingMutationLock `
                -Stage 'contract-test-build-working-omitted-tree' `
                -AllowedFileMutationPaths @($buildWorkingManifest, $buildWorkingManifestOriginal)
        } catch { $buildWorkingOmittedTreeAllowlistCaught = $_ }
        try {
            $null = Assert-PatchletInputFreezeLock `
                -Lock $buildWorkingMutationLock `
                -Stage 'contract-test-build-working-omitted-files' `
                -AllowedTreeMutationRoots @($buildWorkingBuildCache)
        } catch { $buildWorkingOmittedFileAllowlistCaught = $_ }

        [IO.File]::Copy($buildWorkingManifest, $buildWorkingManifestOriginal, $false)
        [IO.File]::WriteAllText(
            $buildWorkingManifest, "manifest-during-build`n", [Text.UTF8Encoding]::new($false))
        [IO.Directory]::SetLastWriteTimeUtc(
            (Join-Path $buildWorkingRoot 'res'), [DateTime]::UtcNow)
        [IO.Directory]::CreateDirectory($buildWorkingBuildCache) | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $buildWorkingBuildCache 'derived.bin'), "derived`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Delete($buildWorkingManifest)
        [IO.File]::Move($buildWorkingManifestOriginal, $buildWorkingManifest)
        Remove-Item -LiteralPath $buildWorkingBuildCache -Recurse -Force
        $null = [Threading.SpinWait]::SpinUntil({
                @($buildWorkingMutationLock.monitors | ForEach-Object { $_.EventCount } |
                    Measure-Object -Sum).Sum -gt 0
            }, 2000)
        $buildWorkingMutationEvents = Assert-PatchletInputFreezeLock `
            -Lock $buildWorkingMutationLock `
            -Stage 'build-working-after-cleanup' `
            -AllowedTreeMutationRoots @($buildWorkingBuildCache) `
            -AllowedFileMutationPaths @($buildWorkingManifest, $buildWorkingManifestOriginal)
        $null = Assert-PatchletInputFreeze `
            -Snapshot $buildWorkingInputFreeze -Stage 'build-working-after-cleanup'
        $buildWorkingSealedLockFixture = Enter-PatchletInputFreezeLock `
            -Snapshot $buildWorkingInputFreeze -Stage 'build-working-sealed-after-cleanup'
        $buildWorkingSealOverlapCheck = Assert-PatchletInputFreezeLock `
            -Lock $buildWorkingMutationLock `
            -Stage 'build-working-mutation-lock-during-seal' `
            -AllowedTreeMutationRoots @($buildWorkingBuildCache) `
            -AllowedFileMutationPaths @($buildWorkingManifest, $buildWorkingManifestOriginal)
    } finally {
        Exit-PatchletInputFreezeLock -Lock $buildWorkingMutationLock
    }
    try {
        $buildWorkingSealedCheck = Assert-PatchletInputFreezeLock `
            -Lock $buildWorkingSealedLockFixture -Stage 'build-working-sealed-after-cleanup'
        try {
            [IO.File]::WriteAllText(
                $buildWorkingManifest, "unexpected-sealed-write`n", [Text.UTF8Encoding]::new($false))
        } catch [IO.IOException] { $buildWorkingSealedWriteBlocked = $true }
    } finally {
        Exit-PatchletInputFreezeLock -Lock $buildWorkingSealedLockFixture
    }
} finally {
    Exit-PatchletInputFreezeLock -Lock $decodedInputLock
}
if ($null -eq $decodedIdempotencyFreeze `
        -or [string]$decodedIdempotencyFreeze.status -ne 'matched' `
        -or $null -eq $decodedIdempotencyLock `
        -or [string]$decodedIdempotencyLock.status -ne 'held' `
        -or -not $decodedCanonicalWriteBlocked `
        -or $null -eq $buildWorkingCopyFixture `
        -or [string]$buildWorkingCopyFixture.sha256 -ne [string]$decodedInputFreeze[0].sha256 `
        -or $null -eq $buildWorkingMutationEvents `
        -or [int]$buildWorkingMutationEvents.unexpectedTreeMonitorEvents -ne 0 `
        -or $null -eq $buildWorkingSealOverlapCheck `
        -or $null -eq $buildWorkingSealedCheck `
        -or -not $buildWorkingSealedWriteBlocked `
        -or -not $buildWorkingStableWriteBlocked `
        -or -not $buildWorkingHandleCountPassed `
        -or $null -eq $buildWorkingOmittedTreeAllowlistCaught `
        -or -not $buildWorkingOmittedTreeAllowlistCaught.Exception.Message.Contains(
            'Allowed tree mutation roots differ from the lock-time configuration', [StringComparison]::Ordinal) `
        -or $null -eq $buildWorkingOmittedFileAllowlistCaught `
        -or -not $buildWorkingOmittedFileAllowlistCaught.Exception.Message.Contains(
            'Allowed file mutation paths differ from the lock-time configuration', [StringComparison]::Ordinal) `
        -or (Test-Path -LiteralPath $buildWorkingBuildCache) `
        -or (Test-Path -LiteralPath $buildWorkingManifestOriginal) `
        -or (Get-PatchletCompleteTreeState -Root $buildWorkingRoot).sha256 -ne [string]$decodedInputFreeze[0].sha256) {
    throw 'Locked canonical decoded input and exact monitored Apktool build-working sequence did not restore identically.'
}

$buildWorkingDriftRoot = Join-Path $scratchFull 'build-working-unexpected-rename'
[IO.Directory]::CreateDirectory($buildWorkingDriftRoot) | Out-Null
$buildWorkingDriftManifest = Join-Path $buildWorkingDriftRoot 'AndroidManifest.xml'
$buildWorkingDriftOriginal = Join-Path $buildWorkingDriftRoot 'AndroidManifest.xml.orig'
$buildWorkingDriftBuild = Join-Path $buildWorkingDriftRoot 'build'
$buildWorkingDriftOutside = Join-Path $buildWorkingDriftRoot 'unexpected.xml'
[IO.File]::WriteAllText(
    $buildWorkingDriftManifest, "manifest`n", [Text.UTF8Encoding]::new($false))
$buildWorkingDriftFreeze = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{
            id = 'build-working-unexpected-rename'
            kind = 'complete-tree'
            path = $buildWorkingDriftRoot
            filter = $null
        }
    ))
$buildWorkingDriftLock = Enter-PatchletInputFreezeLock `
    -Snapshot $buildWorkingDriftFreeze `
    -Stage 'contract-test-build-working-unexpected-rename' `
    -AllowedTreeMutationRoots @($buildWorkingDriftBuild) `
    -AllowedFileMutationPaths @($buildWorkingDriftManifest, $buildWorkingDriftOriginal)
$buildWorkingUnexpectedRenameCaught = $null
try {
    [IO.File]::Move($buildWorkingDriftManifest, $buildWorkingDriftOutside)
    [IO.File]::Move($buildWorkingDriftOutside, $buildWorkingDriftManifest)
    $null = [Threading.SpinWait]::SpinUntil({
            @($buildWorkingDriftLock.monitors | ForEach-Object { $_.EventCount } |
                Measure-Object -Sum).Sum -gt 0
        }, 2000)
    try {
        $null = Assert-PatchletInputFreezeLock `
            -Lock $buildWorkingDriftLock `
            -Stage 'contract-test-build-working-unexpected-rename-reject' `
            -AllowedTreeMutationRoots @($buildWorkingDriftBuild) `
            -AllowedFileMutationPaths @($buildWorkingDriftManifest, $buildWorkingDriftOriginal)
    } catch { $buildWorkingUnexpectedRenameCaught = $_ }
} finally {
    Exit-PatchletInputFreezeLock -Lock $buildWorkingDriftLock
}
if ($null -eq $buildWorkingUnexpectedRenameCaught `
        -or -not $buildWorkingUnexpectedRenameCaught.Exception.Message.Contains(
            'Release input tree drift', [StringComparison]::Ordinal)) {
    throw 'Build-working rename with one endpoint outside the exact mutation files was not rejected.'
}

$monitorErrorRoot = Join-Path $scratchFull 'monitor-error-fixture'
[IO.Directory]::CreateDirectory($monitorErrorRoot) | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $monitorErrorRoot 'stable.txt'), "stable`n", [Text.UTF8Encoding]::new($false))
$monitorErrorFreeze = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{ id = 'monitor-error'; kind = 'complete-tree'; path = $monitorErrorRoot; filter = $null }
    ))
$monitorErrorLock = Enter-PatchletInputFreezeLock `
    -Snapshot $monitorErrorFreeze -Stage 'contract-test-monitor-error'
$monitorErrorCaught = $null
try {
    $monitorErrorLock.monitors[0].InjectErrorForContractTest('deterministic-overflow')
    try {
        $null = Assert-PatchletInputFreezeLock `
            -Lock $monitorErrorLock -Stage 'contract-test-monitor-error-reject'
    } catch { $monitorErrorCaught = $_ }
} finally {
    Exit-PatchletInputFreezeLock -Lock $monitorErrorLock
}
if ($null -eq $monitorErrorCaught `
        -or -not $monitorErrorCaught.Exception.Message.Contains(
            'monitor-error:deterministic-overflow', [StringComparison]::Ordinal)) {
    throw 'Tree-monitor error or overflow evidence did not fail closed.'
}

$generatedTreeRoot = Join-Path $scratchFull 'generated-tree-allowlist'
[IO.Directory]::CreateDirectory($generatedTreeRoot) | Out-Null
$generatedTreeStable = Join-Path $generatedTreeRoot 'stable.txt'
$generatedTreeBuild = Join-Path $generatedTreeRoot 'build'
[IO.File]::WriteAllText($generatedTreeStable, "stable`n", [Text.UTF8Encoding]::new($false))
$generatedTreeSnapshot = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{ id = 'generated-complete-tree'; kind = 'complete-tree'; path = $generatedTreeRoot; filter = $null }
    ))
$generatedTreeLock = Enter-PatchletInputFreezeLock `
    -Snapshot $generatedTreeSnapshot `
    -Stage 'contract-test-generated-tree' `
    -AllowedTreeMutationRoots @($generatedTreeBuild)
$generatedTreeAllowed = $null
try {
    [IO.Directory]::CreateDirectory($generatedTreeBuild) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $generatedTreeBuild 'derived.bin'), "derived`n", [Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $generatedTreeBuild -Recurse -Force
    $null = [Threading.SpinWait]::SpinUntil({ $generatedTreeLock.monitors[0].EventCount -gt 0 }, 2000)
    $generatedTreeAllowed = Assert-PatchletInputFreezeLock `
        -Lock $generatedTreeLock `
        -Stage 'contract-test-generated-tree-allowed' `
        -AllowedTreeMutationRoots @($generatedTreeBuild)
    $null = Assert-PatchletInputFreeze `
        -Snapshot $generatedTreeSnapshot -Stage 'contract-test-generated-tree-restored'
} finally {
    Exit-PatchletInputFreezeLock -Lock $generatedTreeLock
}
if ($null -eq $generatedTreeAllowed `
        -or [int]$generatedTreeAllowed.allowedTreeMonitorEvents -le 0 `
        -or [int]$generatedTreeAllowed.unexpectedTreeMonitorEvents -ne 0) {
    throw 'Exact generated build-cache churn was not accepted and recorded by the tree lock.'
}

$generatedDriftRoot = Join-Path $scratchFull 'generated-tree-sibling-drift'
[IO.Directory]::CreateDirectory($generatedDriftRoot) | Out-Null
$generatedDriftStable = Join-Path $generatedDriftRoot 'stable.txt'
$generatedDriftBuild = Join-Path $generatedDriftRoot 'build'
$generatedDriftSibling = Join-Path $generatedDriftRoot 'unexpected.txt'
[IO.File]::WriteAllText($generatedDriftStable, "stable`n", [Text.UTF8Encoding]::new($false))
$generatedDriftSnapshot = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{ id = 'generated-sibling-tree'; kind = 'complete-tree'; path = $generatedDriftRoot; filter = $null }
    ))
$generatedDriftLock = Enter-PatchletInputFreezeLock `
    -Snapshot $generatedDriftSnapshot `
    -Stage 'contract-test-generated-sibling' `
    -AllowedTreeMutationRoots @($generatedDriftBuild)
$generatedSiblingCaught = $null
try {
    [IO.File]::WriteAllText($generatedDriftSibling, "unexpected`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::Delete($generatedDriftSibling)
    $null = [Threading.SpinWait]::SpinUntil({ $generatedDriftLock.monitors[0].EventCount -gt 0 }, 2000)
    try {
        $null = Assert-PatchletInputFreezeLock `
            -Lock $generatedDriftLock `
            -Stage 'contract-test-generated-sibling-reject' `
            -AllowedTreeMutationRoots @($generatedDriftBuild)
    } catch { $generatedSiblingCaught = $_ }
} finally {
    Exit-PatchletInputFreezeLock -Lock $generatedDriftLock
}
if ($null -eq $generatedSiblingCaught `
        -or -not $generatedSiblingCaught.Exception.Message.Contains('Release input tree drift', [StringComparison]::Ordinal)) {
    throw 'Transient mutation outside the exact generated build-cache subtree was not rejected.'
}

$releaseToolContractModulePath = Join-Path $PSScriptRoot 'ThreadsMod.ReleaseToolContract.psm1'
if ((Get-PatchletSha256 -Path $releaseToolContractModulePath) `
        -ne [string]$resolutionForContract.assets.releaseToolContractModuleSha256) {
    throw 'Release-tool AST contract module hash differs from the exact resolution.'
}
Import-Module $releaseToolContractModulePath -Force -DisableNameChecking
$safeArtifactBaseName = Assert-PatchletArtifactBaseName -Name ([string]$resolutionForContract.target.artifactBaseName)
$contractForbiddenDexStrings = @($resolutionForContract.release.forbiddenDexStrings | ForEach-Object { [string]$_ })
$contractModalActions = @($resolutionForContract.inlineControls.presentation.modalActions | ForEach-Object { [string]$_ })
$ambiguousReportSubstring = 'Send report'
$pristineReportCollisionFixture = 'Send reports blocking'
if ($pristineReportCollisionFixture.IndexOf(
        $ambiguousReportSubstring, [StringComparison]::OrdinalIgnoreCase) -lt 0 `
        -or $contractForbiddenDexStrings -contains $ambiguousReportSubstring) {
    throw 'Release contract must exclude the ambiguous Send report broad substring collision.'
}
$ambiguousSocksPortSubstring = 'socksProxyPort'
$pristineSocksPortCollisionFixture = 'getSocksProxyPort'
$socksPortCollisionProof = @($resolutionForContract.proofs | Where-Object {
        [string]$_.id -eq 'proxy-pristine-socks-port-substring-collision'
    })
$expectedSocksPortCollisionPath = if (
        [string]$resolutionForContract.source.versionName -ceq '415.0.0.26.77') {
    'smali_classes11/com/facebook/proxyservice/observer/ProxyServiceBroadcaster.smali'
} elseif ([string]$resolutionForContract.source.versionName -ceq '444.0.0.45.85') {
    'smali_classes12/com/facebook/proxyservice/observer/ProxyServiceBroadcaster.smali'
} else {
    throw 'No exact pristine SOCKS port collision path is reviewed for this source version.'
}
if ($pristineSocksPortCollisionFixture.IndexOf(
        $ambiguousSocksPortSubstring, [StringComparison]::OrdinalIgnoreCase) -lt 0 `
        -or $contractForbiddenDexStrings -contains $ambiguousSocksPortSubstring `
        -or $socksPortCollisionProof.Count -ne 1 `
        -or [string]$socksPortCollisionProof[0].path `
            -cne $expectedSocksPortCollisionPath `
        -or [string]$socksPortCollisionProof[0].contains `
            -ne '.method public final declared-synchronized getSocksProxyPort()I' `
        -or [int]$socksPortCollisionProof[0].minimumCount -ne 1) {
    throw 'Release contract must bind and exclude the ambiguous pristine getSocksProxyPort broad substring collision.'
}
$proxyTargetedJadxClasses = @(
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
foreach ($proxyTargetedJadxClass in $proxyTargetedJadxClasses) {
    $proxyTarget = @($resolutionForContract.release.targetedJadxClasses | Where-Object {
            [string]$_.className -eq $proxyTargetedJadxClass
        })
    if ($proxyTarget.Count -ne 1) {
        throw "Release contract is missing exact proxy JADX target '$proxyTargetedJadxClass'."
    }
    foreach ($targetedProxyFallbackLiteral in $targetedProxyFallbackLiterals) {
        if (@($proxyTarget[0].forbiddenStrings | Where-Object {
                    [string]$_ -ceq $targetedProxyFallbackLiteral
                }).Count -ne 1) {
            throw "Release proxy JADX target '$proxyTargetedJadxClass' does not forbid exact fallback literal '$targetedProxyFallbackLiteral'."
        }
    }
}
$proxyApplicationJadxTarget = @(
    $resolutionForContract.release.targetedJadxClasses | Where-Object {
        [string]$_.className -eq 'com.instagram.barcelona.app.BarcelonaAppShell'
    })[0]
$proxyApplicationOrderedStrings = @(
    $proxyApplicationJadxTarget.orderedStrings | ForEach-Object { [string]$_ })
if (($proxyApplicationOrderedStrings -join "`n") -ne (
        @('super.attachBaseContext(', 'ProxyBootstrap.install(') -join "`n")) {
    throw 'Application targeted-JADX metadata must order the super call before the proxy bootstrap call.'
}
if ([string]$resolutionForContract.inlineControls.presentation.mode -ne 'single-block-entry-combined-modal' `
        -or [int]$resolutionForContract.inlineControls.presentation.visibleControlCount -ne 1 `
        -or [int]$resolutionForContract.inlineControls.presentation.separateReportControlCount -ne 0 `
        -or ($contractModalActions -join "`n") -ne (@('dynamic-positive', 'cancel') -join "`n") `
        -or [string]$resolutionForContract.reporting.launchMode -ne 'single-combined-modal-durable-queue' `
        -or $contractForbiddenDexStrings -notcontains 'threadsmod_inline_report' `
        -or $contractForbiddenDexStrings -notcontains 'Safe processing' `
        -or $contractForbiddenDexStrings -notcontains 'Before exact review' `
        -or $contractForbiddenDexStrings -notcontains 'Block or report?' `
        -or $contractForbiddenDexStrings -notcontains 'Review report' `
        -or $contractForbiddenDexStrings -notcontains 'InlineReportClick' `
        -or $contractForbiddenDexStrings -notcontains 'ReportDialog' `
        -or $contractForbiddenDexStrings -notcontains 'ui_one_click_block') {
    throw 'Resolution does not fail closed on the single dynamic-action presentation and retired report/review/one-click flow.'
}
foreach ($unsafeArtifactBaseName in @(
        '..\outside', '../outside', 'C:\outside', 'name:stream', 'nested/name', 'nested\name', '.', 'name.')) {
    $unsafeCaught = $null
    try { $null = Assert-PatchletArtifactBaseName -Name $unsafeArtifactBaseName } catch { $unsafeCaught = $_ }
    if ($null -eq $unsafeCaught) {
        throw "Unsafe artifact basename was accepted: $unsafeArtifactBaseName"
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$duplicateZip = Join-Path $scratchFull 'duplicate-entry.zip'
$duplicateStream = [IO.File]::Open($duplicateZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$duplicateArchive = [IO.Compression.ZipArchive]::new($duplicateStream, [IO.Compression.ZipArchiveMode]::Create, $false)
try {
    foreach ($index in 1..2) {
        $entry = $duplicateArchive.CreateEntry('AndroidManifest.xml')
        $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write("manifest-$index") } finally { $writer.Dispose() }
    }
} finally {
    $duplicateArchive.Dispose()
    $duplicateStream.Dispose()
}
$duplicateZipCaught = $null
try { $null = Test-PatchletZipInventory -Path $duplicateZip } catch { $duplicateZipCaught = $_ }
if ($null -eq $duplicateZipCaught `
        -or -not $duplicateZipCaught.Exception.Message.Contains('duplicate', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Whole-archive duplicate FullName inventory did not fail closed.'
}

$traversalZip = Join-Path $scratchFull 'traversal-entry.zip'
$traversalStream = [IO.File]::Open($traversalZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$traversalArchive = [IO.Compression.ZipArchive]::new($traversalStream, [IO.Compression.ZipArchiveMode]::Create, $false)
try {
    $entry = $traversalArchive.CreateEntry('../outside.bin')
    $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
    try { $writer.Write('outside') } finally { $writer.Dispose() }
} finally {
    $traversalArchive.Dispose()
    $traversalStream.Dispose()
}
$traversalZipCaught = $null
try { $null = Test-PatchletZipInventory -Path $traversalZip } catch { $traversalZipCaught = $_ }
if ($null -eq $traversalZipCaught `
        -or -not $traversalZipCaught.Exception.Message.Contains('canonical', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Whole-archive non-canonical traversal inventory did not fail closed.'
}

$smaliCarrierApk = Join-Path $repositoryRoot `
    'patchlets\assets\autoblock\stub\smali-carrier.apk'
if (-not (Test-Path -LiteralPath $smaliCarrierApk -PathType Leaf)) {
    throw "Resolution-pinned Smali carrier is unavailable for the duplicate-DEX contract fixture: $smaliCarrierApk"
}
$expectedSmaliCarrierSha256 = ([string]$resolutionForContract.assets.smaliCarrierSha256).ToLowerInvariant()
if ($expectedSmaliCarrierSha256 -notmatch '^[0-9a-f]{64}$' `
        -or (Get-PatchletSha256 -Path $smaliCarrierApk) -cne $expectedSmaliCarrierSha256) {
    throw 'Resolution-pinned Smali carrier hash does not authorize the duplicate-DEX contract fixture.'
}
$sourceArchive = [IO.Compression.ZipFile]::OpenRead($smaliCarrierApk)
try {
    $sourceDexEntry = @($sourceArchive.Entries | Where-Object FullName -eq 'classes.dex')
    if ($sourceDexEntry.Count -ne 1) { throw 'Pristine APK does not contain exactly one classes.dex.' }
    $sourceDexStream = $sourceDexEntry[0].Open()
    $sourceDexBuffer = [IO.MemoryStream]::new()
    try { $sourceDexStream.CopyTo($sourceDexBuffer); $sourceDexBytes = $sourceDexBuffer.ToArray() }
    finally { $sourceDexBuffer.Dispose(); $sourceDexStream.Dispose() }
} finally { $sourceArchive.Dispose() }
$duplicateDexZip = Join-Path $scratchFull 'duplicate-root-dex.apk'
$duplicateDexStream = [IO.File]::Open($duplicateDexZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$duplicateDexArchive = [IO.Compression.ZipArchive]::new($duplicateDexStream, [IO.Compression.ZipArchiveMode]::Create, $false)
try {
    foreach ($dexName in @('classes.dex', 'classes2.dex', 'classes2.dex')) {
        $entry = $duplicateDexArchive.CreateEntry($dexName, [IO.Compression.CompressionLevel]::NoCompression)
        $stream = $entry.Open()
        try { $stream.Write($sourceDexBytes, 0, $sourceDexBytes.Length) } finally { $stream.Dispose() }
    }
} finally {
    $duplicateDexArchive.Dispose()
    $duplicateDexStream.Dispose()
}
$dexInspectorClasses = Join-Path $scratchFull 'dex-inspector-classes'
[IO.Directory]::CreateDirectory($dexInspectorClasses) | Out-Null
$dexInspectorSource = Join-Path $PSScriptRoot 'DexInspector.java'
& javac -encoding UTF-8 -d $dexInspectorClasses $dexInspectorSource
if ($LASTEXITCODE -ne 0) { throw 'Unable to compile DexInspector duplicate-name contract fixture.' }
$dexProcessInfo = [Diagnostics.ProcessStartInfo]::new()
$dexProcessInfo.FileName = (Get-Command java -CommandType Application | Select-Object -First 1).Source
$dexProcessInfo.UseShellExecute = $false
$dexProcessInfo.RedirectStandardOutput = $true
$dexProcessInfo.RedirectStandardError = $true
foreach ($argument in @(
        '-cp', $dexInspectorClasses, 'DexInspector', $duplicateDexZip,
        '--expected-root-dex=3', '--max-primary-methods=65535')) {
    $null = $dexProcessInfo.ArgumentList.Add($argument)
}
$dexProcess = [Diagnostics.Process]::Start($dexProcessInfo)
$dexStandardOutput = $dexProcess.StandardOutput.ReadToEnd()
$dexStandardError = $dexProcess.StandardError.ReadToEnd()
$dexProcess.WaitForExit()
if ($dexProcess.ExitCode -eq 0 `
        -or -not ($dexStandardOutput + $dexStandardError).Contains('duplicate DEX ZIP entry name', [StringComparison]::Ordinal)) {
    throw 'DexInspector did not reject an ambiguous duplicate root-DEX inventory.'
}

$rollbackGuard = Join-Path $scratchFull 'rollback-guard.txt'
$rollbackPublishProbe = Join-Path $repositoryRoot ("dist\.release-rollback-probe-{0}.apk" -f [guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($rollbackGuard, "rollback`n", [Text.UTF8Encoding]::new($false))
$rollbackSnapshot = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{ id = 'deterministic-rollback-fixture'; kind = 'file'; path = $rollbackGuard; filter = $null }
    ))
$rollbackLock = Enter-PatchletInputFreezeLock -Snapshot $rollbackSnapshot -Stage 'contract-test-rollback'
$rollbackCaught = $null
$callbackState = [ordered]@{}
function Get-ReleaseContractCallbackProbe { return 'callback-scope-passed' }
try {
    try {
        $null = Invoke-PatchletPublicationTransaction `
            -SourceArtifact $rollbackGuard `
            -PublishPath $rollbackPublishProbe `
            -ExpectedSha256 (Get-PatchletSha256 -Path $rollbackGuard) `
            -InputSnapshot $rollbackSnapshot `
            -InputLock $rollbackLock `
            -PostMoveValidation {
                $callbackState['result'] = Get-ReleaseContractCallbackProbe
                throw 'deterministic post-move rollback probe'
            }
    } catch {
        $rollbackCaught = $_
    }
} finally {
    Exit-PatchletInputFreezeLock -Lock $rollbackLock
}
$rollbackTemporaryResidue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $rollbackPublishProbe) -File | Where-Object {
        $_.Name.StartsWith(([IO.Path]::GetFileName($rollbackPublishProbe) + '.publishing-'), [StringComparison]::Ordinal)
    })
if ($null -eq $rollbackCaught `
        -or [string]$callbackState['result'] -ne 'callback-scope-passed' `
        -or -not $rollbackCaught.Exception.Message.Contains('deterministic post-move rollback probe', [StringComparison]::Ordinal) `
        -or (Test-Path -LiteralPath $rollbackPublishProbe) `
        -or $rollbackTemporaryResidue.Count -ne 0) {
    throw 'Post-move publication failure did not roll back both the exact target and temporary file.'
}

$residueGuard = Join-Path $scratchFull 'residue-guard.txt'
$residuePublishProbe = Join-Path $repositoryRoot ("dist\.release-residue-probe-{0}.apk" -f [guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($residueGuard, "residue`n", [Text.UTF8Encoding]::new($false))
$residueSnapshot = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{ id = 'deterministic-residue-fixture'; kind = 'file'; path = $residueGuard; filter = $null }
    ))
$residueLock = Enter-PatchletInputFreezeLock -Snapshot $residueSnapshot -Stage 'contract-test-residue'
$residueState = [ordered]@{ handle = $null }
$residueCaught = $null
try {
    try {
        $null = Invoke-PatchletPublicationTransaction `
            -SourceArtifact $residueGuard `
            -PublishPath $residuePublishProbe `
            -ExpectedSha256 (Get-PatchletSha256 -Path $residueGuard) `
            -InputSnapshot $residueSnapshot `
            -InputLock $residueLock `
            -PostMoveValidation {
                $residueState['handle'] = [IO.File]::Open(
                    $residuePublishProbe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                throw 'deterministic rollback-residue probe'
            }
    } catch {
        $residueCaught = $_
    }
} finally {
    Exit-PatchletInputFreezeLock -Lock $residueLock
}
$residueEvidencePassed = $null -ne $residueCaught `
    -and $residueCaught.Exception.Data.Contains('PatchletPublicationResiduePaths') `
    -and ([string]$residueCaught.Exception.Data['PatchletPublicationResiduePaths']).Contains($residuePublishProbe, [StringComparison]::Ordinal) `
    -and (Test-Path -LiteralPath $residuePublishProbe -PathType Leaf)
if ($null -ne $residueState['handle']) {
    $residueState['handle'].Dispose()
    $residueState['handle'] = $null
}
if (Test-Path -LiteralPath $residuePublishProbe -PathType Leaf) {
    Remove-Item -LiteralPath $residuePublishProbe -Force
}
if (-not $residueEvidencePassed -or (Test-Path -LiteralPath $residuePublishProbe)) {
    throw 'Rollback residue did not produce truthful hard-failure evidence or exact-path cleanup.'
}

$postCommitPublishProbe = Join-Path $repositoryRoot ("dist\.release-post-commit-probe-{0}.apk" -f [guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($postCommitPublishProbe, "post-commit`n", [Text.UTF8Encoding]::new($false))
$postCommitCleanup = Remove-PatchletOwnedPublication `
    -Path $postCommitPublishProbe -AllowedRoot (Join-Path $repositoryRoot 'dist')
if (-not [bool]$postCommitCleanup.removed `
        -or [bool]$postCommitCleanup.residue `
        -or (Test-Path -LiteralPath $postCommitPublishProbe)) {
    throw 'Outer post-commit cleanup did not remove and verify the exact run-owned target.'
}

$postCommitResidueProbe = Join-Path $repositoryRoot ("dist\.release-post-commit-residue-{0}.apk" -f [guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($postCommitResidueProbe, "locked-post-commit`n", [Text.UTF8Encoding]::new($false))
$postCommitResidueHash = Get-PatchletSha256 -Path $postCommitResidueProbe
$postCommitResidueHandle = [IO.File]::Open(
    $postCommitResidueProbe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $postCommitResidue = Remove-PatchletOwnedPublication `
        -Path $postCommitResidueProbe -AllowedRoot (Join-Path $repositoryRoot 'dist')
} finally {
    $postCommitResidueHandle.Dispose()
}
if (-not [bool]$postCommitResidue.residue `
        -or [bool]$postCommitResidue.removed `
        -or [string]$postCommitResidue.sha256 -ne $postCommitResidueHash `
        -or -not (Test-Path -LiteralPath $postCommitResidueProbe -PathType Leaf)) {
    throw 'Outer post-commit cleanup refusal did not retain truthful residue/hash evidence.'
}
$postCommitResidueFinalCleanup = Remove-PatchletOwnedPublication `
    -Path $postCommitResidueProbe -AllowedRoot (Join-Path $repositoryRoot 'dist')
if (-not [bool]$postCommitResidueFinalCleanup.removed `
        -or (Test-Path -LiteralPath $postCommitResidueProbe)) {
    throw 'Unable to clean the exact post-commit residue fixture after releasing its deterministic lock.'
}

$pipelinePath = Join-Path $PSScriptRoot 'Invoke-PatchletPipeline.ps1'
$pipelineText = Get-NormalizedPatchletText -Path $pipelinePath
$splitUniversalizationText = Get-NormalizedPatchletText -Path (
    Join-Path $PSScriptRoot 'Build-SplitSourceUniversalApk.ps1')
$splitSourceContractText = Get-NormalizedPatchletText -Path (
    Join-Path $PSScriptRoot 'Test-SplitSourceSetContract.ps1')
$pipelineTokens = $null
$pipelineParseErrors = $null
$pipelineAst = [Management.Automation.Language.Parser]::ParseFile(
    $pipelinePath, [ref]$pipelineTokens, [ref]$pipelineParseErrors)
if (@($pipelineParseErrors).Count -ne 0) {
    throw 'Release pipeline source has PowerShell parse errors.'
}
function Get-ReleaseContractCommandArgumentAst {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory)][string]$ParameterName
    )

    for ($index = 1; $index -lt $Command.CommandElements.Count; $index++) {
        $element = $Command.CommandElements[$index]
        if ($element -is [Management.Automation.Language.CommandParameterAst] `
                -and $element.ParameterName.Equals($ParameterName, [StringComparison]::OrdinalIgnoreCase)) {
            if ($index + 1 -ge $Command.CommandElements.Count `
                    -or $Command.CommandElements[$index + 1] -is [Management.Automation.Language.CommandParameterAst]) {
                return $null
            }
            return $Command.CommandElements[$index + 1]
        }
    }
    return $null
}
function Test-ReleaseContractVariableArrayArgument {
    param(
        [Parameter(Mandatory)]$Argument,
        [Parameter(Mandatory)][string[]]$VariableNames
    )

    if ($Argument -isnot [Management.Automation.Language.ArrayExpressionAst]) { return $false }
    $statements = @($Argument.SubExpression.Statements)
    if ($statements.Count -ne 1) { return $false }
    $pipelineElements = @($statements[0].PipelineElements)
    if ($pipelineElements.Count -ne 1 `
            -or $pipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst]) {
        return $false
    }
    $expression = $pipelineElements[0].Expression
    $expressions = @(if ($expression -is [Management.Automation.Language.VariableExpressionAst]) {
        $expression
    } elseif ($expression -is [Management.Automation.Language.ArrayLiteralAst]) {
        @($expression.Elements)
    })
    $expectedVariables = @($VariableNames)
    if ($expressions.Count -ne $expectedVariables.Count) { return $false }
    foreach ($index in 0..($expectedVariables.Count - 1)) {
        if ($expressions[$index] -isnot [Management.Automation.Language.VariableExpressionAst] `
                -or -not $expressions[$index].VariablePath.UserPath.Equals(
                    $expectedVariables[$index], [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}
function Get-ReleaseContractScriptAst {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) {
        throw "$Label source has PowerShell parse errors."
    }
    return $ast
}
function Test-ReleaseContractToolParameterCompatibility {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$CallerAst,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$CalleeAst
    )

    $targetCommands = @($CallerAst.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.CommandAst] `
                        -or $node.CommandElements.Count -eq 0) {
                    return $false
                }
                $target = $node.CommandElements[0]
                return $target -is [Management.Automation.Language.VariableExpressionAst] `
                    -and $target.VariablePath.UserPath.Equals(
                        'dexBridgeFlowFixtureTest', [StringComparison]::OrdinalIgnoreCase)
            }, $true))
    if ($targetCommands.Count -ne 1 `
            -or $targetCommands[0].InvocationOperator `
                -ne [Management.Automation.Language.TokenKind]::Ampersand) {
        throw 'Patched-APK validation must contain one ampersand invocation through $dexBridgeFlowFixtureTest.'
    }

    $command = $targetCommands[0]
    $elements = @($command.CommandElements)
    $splattedVariables = @($elements | Where-Object {
            $_ -is [Management.Automation.Language.VariableExpressionAst] -and $_.Splatted
        })
    if ($splattedVariables.Count -ne 0) {
        throw 'DEX bridge-flow fixture invocation must not use splatting.'
    }

    $observedNames = [Collections.Generic.List[string]]::new()
    $seenNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $index = 1
    while ($index -lt $elements.Count) {
        $parameter = $elements[$index]
        if ($parameter -isnot [Management.Automation.Language.CommandParameterAst]) {
            throw 'DEX bridge-flow fixture invocation contains an unsupported positional argument.'
        }
        if (-not $seenNames.Add($parameter.ParameterName)) {
            throw "DEX bridge-flow fixture invocation duplicates parameter '$($parameter.ParameterName)'."
        }
        $observedNames.Add($parameter.ParameterName)
        $index++

        if ($null -ne $parameter.Argument) { continue }
        if ($index -ge $elements.Count `
                -or $elements[$index] -is [Management.Automation.Language.CommandParameterAst]) {
            throw "DEX bridge-flow fixture parameter '$($parameter.ParameterName)' has no argument."
        }
        if ($elements[$index] -is [Management.Automation.Language.VariableExpressionAst] `
                -and $elements[$index].Splatted) {
            throw 'DEX bridge-flow fixture invocation must not use splatting.'
        }
        $index++
    }

    $expectedNames = @('ScratchRoot', 'ResolutionPath', 'Java', 'Javac', 'ReportPath')
    if ($observedNames.Count -ne $expectedNames.Count) {
        throw 'DEX bridge-flow fixture invocation parameter count differs from the release contract.'
    }
    for ($nameIndex = 0; $nameIndex -lt $expectedNames.Count; $nameIndex++) {
        if (-not $observedNames[$nameIndex].Equals(
                $expectedNames[$nameIndex], [StringComparison]::Ordinal)) {
            throw 'DEX bridge-flow fixture invocation parameter order differs from the release contract.'
        }
    }

    if ($null -eq $CalleeAst.ParamBlock) {
        throw 'DEX bridge-flow fixture test has no top-level ParamBlock.'
    }
    $calleeNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($calleeParameter in @($CalleeAst.ParamBlock.Parameters)) {
        $calleeName = $calleeParameter.Name.VariablePath.UserPath
        if (-not $calleeNames.Add($calleeName)) {
            throw "DEX bridge-flow fixture test duplicates parameter '$calleeName'."
        }
    }
    foreach ($callerName in $observedNames) {
        if (-not $calleeNames.Contains($callerName)) {
            throw "DEX bridge-flow fixture invocation passes undeclared callee parameter '$callerName'."
        }
    }
    return $true
}
function Test-ReleaseContractExactMemberPath {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Expression,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string[]]$MemberPath
    )

    $current = $Expression
    if ($current -is [Management.Automation.Language.ConvertExpressionAst]) {
        $current = $current.Child
    }
    $observedMembers = [Collections.Generic.List[string]]::new()
    while ($current -is [Management.Automation.Language.MemberExpressionAst]) {
        if ($current.Static `
                -or $current.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
            return $false
        }
        $observedMembers.Insert(0, [string]$current.Member.Value)
        $current = $current.Expression
    }
    if ($current -isnot [Management.Automation.Language.VariableExpressionAst] `
            -or $current.Splatted `
            -or -not $current.VariablePath.UserPath.Equals(
                $VariableName, [StringComparison]::Ordinal) `
            -or $observedMembers.Count -ne $MemberPath.Count) {
        return $false
    }
    for ($index = 0; $index -lt $MemberPath.Count; $index++) {
        if (-not $observedMembers[$index].Equals(
                $MemberPath[$index], [StringComparison]::Ordinal)) {
            return $false
        }
    }
    return $true
}
function Get-ReleaseContractNumericEvidenceComparison {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$ScriptAst,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string[]]$MemberPath,
        [Parameter(Mandatory)][string]$Label
    )

    $comparisons = @($ScriptAst.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.BinaryExpressionAst]) {
                    return $false
                }
                return (Test-ReleaseContractExactMemberPath `
                        -Expression $node.Left -VariableName $VariableName -MemberPath $MemberPath) `
                    -or (Test-ReleaseContractExactMemberPath `
                        -Expression $node.Right -VariableName $VariableName -MemberPath $MemberPath)
            }, $true))
    if ($comparisons.Count -ne 1) {
        throw "$Label must contain exactly one reviewed-terminal-route numeric comparison."
    }

    $comparison = $comparisons[0]
    if ($comparison.Operator -ne [Management.Automation.Language.TokenKind]::Ine `
            -or $comparison.Left -isnot [Management.Automation.Language.ConvertExpressionAst] `
            -or [string]$comparison.Left.Type.TypeName -cne 'int' `
            -or -not (Test-ReleaseContractExactMemberPath `
                -Expression $comparison.Left -VariableName $VariableName -MemberPath $MemberPath)) {
        throw "$Label reviewed-terminal-route comparison must be the exact [int] property -ne literal shape."
    }
    if ($comparison.Right -isnot [Management.Automation.Language.ConstantExpressionAst]) {
        throw "$Label reviewed-terminal-route comparison must use a numeric literal."
    }
    $numericTypes = @(
        [sbyte], [byte], [int16], [uint16], [int32], [uint32],
        [int64], [uint64], [single], [double], [decimal])
    if ($numericTypes -notcontains $comparison.Right.StaticType) {
        throw "$Label reviewed-terminal-route comparison must use a numeric literal."
    }
    return [decimal]$comparison.Right.Value
}
function Test-ReleaseContractToolEvidenceCompatibility {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$CallerAst,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$CalleeAst
    )

    $memberPath = @(
        'callerCallbackEffectTopology', 'automatic', 'reviewedTerminalRoutes')
    $callerValue = Get-ReleaseContractNumericEvidenceComparison `
        -ScriptAst $CallerAst -VariableName 'bridgeResult' -MemberPath $memberPath `
        -Label 'Patched-APK validation'
    $calleeValue = Get-ReleaseContractNumericEvidenceComparison `
        -ScriptAst $CalleeAst -VariableName 'Result' -MemberPath $memberPath `
        -Label 'DEX bridge-flow fixture test'
    if ($callerValue -ne $calleeValue) {
        throw 'Release tools disagree on the reviewed-terminal-route evidence count.'
    }
    if ($callerValue -ne 5) {
        throw 'Release tools must require exactly five reviewed terminal routes.'
    }
    return $true
}
function Get-UpdateFlowExactAssignment {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string]$Label
    )

    $assignments = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] `
                    -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] `
                    -and -not $node.Left.Splatted `
                    -and $node.Left.VariablePath.UserPath.Equals(
                        $VariableName, [StringComparison]::Ordinal)
            }, $true))
    if ($assignments.Count -ne 1) {
        throw "$Label must declare `$${VariableName} exactly once."
    }
    return $assignments[0]
}
function Assert-UpdateFlowNumericExpectation {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][int]$ExpectedValue,
        [Parameter(Mandatory)][string]$ResolutionProperty,
        [Parameter(Mandatory)][string]$Label
    )

    $assignment = Get-UpdateFlowExactAssignment -Ast $Ast `
        -VariableName $VariableName -Label $Label
    if ($assignment.Right -isnot [Management.Automation.Language.CommandExpressionAst] `
            -or $assignment.Right.Expression `
                -isnot [Management.Automation.Language.ConstantExpressionAst] `
            -or $assignment.Right.Expression.StaticType -ne [int] `
            -or [int]$assignment.Right.Expression.Value -ne $ExpectedValue) {
        throw "$Label must bind `$${VariableName} to the reviewed integer literal $ExpectedValue."
    }
    $comparisons = @($Ast.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.BinaryExpressionAst] `
                        -or $node.Operator -ne [Management.Automation.Language.TokenKind]::Ine) {
                    return $false
                }
                $normalized = [regex]::Replace($node.Extent.Text, '[\s`]+', '')
                return $normalized -ceq (
                    '[int]$resolution.release.' + $ResolutionProperty +
                    '-ne$' + $VariableName)
            }, $true))
    if ($comparisons.Count -ne 1) {
        throw "$Label must compare the resolution $ResolutionProperty to `$${VariableName} exactly once."
    }
}
function Get-UpdateFlowExactStringArray {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string]$Label
    )

    $assignment = Get-UpdateFlowExactAssignment -Ast $Ast `
        -VariableName $VariableName -Label $Label
    if ($assignment.Right -isnot [Management.Automation.Language.CommandExpressionAst] `
            -or $assignment.Right.Expression `
                -isnot [Management.Automation.Language.ArrayExpressionAst]) {
        throw "$Label must bind `$${VariableName} to one literal array."
    }
    $elements = @($assignment.Right.Expression.SubExpression.FindAll({
                param($node)
                $node -is [Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | Sort-Object { $_.Extent.StartOffset })
    $nonStringExpressions = @($assignment.Right.Expression.SubExpression.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ExpressionAst] `
                    -and $node -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                    -and $node -isnot [Management.Automation.Language.ArrayExpressionAst] `
                    -and $node -isnot [Management.Automation.Language.ArrayLiteralAst]
            }, $true))
    if ($nonStringExpressions.Count -ne 0) {
        throw "$Label `$${VariableName} must contain only literal strings."
    }
    return @($elements | ForEach-Object { [string]$_.Value })
}
function Assert-UpdateFlowCheckExpectations {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string[]]$ExpectedNames,
        [Parameter(Mandatory)][string]$Label
    )

    $observed = @(Get-UpdateFlowExactStringArray -Ast $Ast `
        -VariableName $VariableName -Label $Label)
    if ($observed.Count -ne $ExpectedNames.Count `
            -or ($observed -join "`n") -cne ($ExpectedNames -join "`n")) {
        throw "$Label semantic-check expectation differs from the reviewed ordered list."
    }
}
function Assert-UpdateFlowInspectorInvocationBindings {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$PatchedApkAst,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$FixtureAst
    )

    $mainAssignment = Get-UpdateFlowExactAssignment -Ast $PatchedApkAst `
        -VariableName 'updateFlowLines' -Label 'Patched-APK updater inspector invocation'
    $mainCommands = @($mainAssignment.Right.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] `
                    -and $node.GetCommandName() -ceq 'Invoke-Captured'
            }, $true))
    if ($mainCommands.Count -ne 1 `
            -or $mainCommands[0].CommandElements.Count -ne 5 `
            -or $mainCommands[0].CommandElements[1].Extent.Text -cne '-Command' `
            -or $mainCommands[0].CommandElements[2].Extent.Text -cne '$Java' `
            -or $mainCommands[0].CommandElements[3].Extent.Text -cne '-Arguments' `
            -or $mainCommands[0].CommandElements[4] `
                -isnot [Management.Automation.Language.ArrayExpressionAst]) {
        throw 'Patched-APK updater inspector invocation shape drifted.'
    }
    $mainArray = $mainCommands[0].CommandElements[4].SubExpression.Statements[0].PipelineElements[0].Expression
    if ($mainArray -isnot [Management.Automation.Language.ArrayLiteralAst]) {
        throw 'Patched-APK updater inspector arguments must be one literal AST array.'
    }
    $mainExpected = @(
        "'-cp'", '$dexLiteralClasspath', "'DexUpdateFlowInspector'", '$apkFull',
        '[string]$updateFlowContract.expectedDexName',
        '[string]$updateFlowContract.classPrefix',
        '[string]$updateFlowContract.expectedSemanticSha256',
        '[string]$updateFlowContract.expectedSemanticClassCount',
        '[string]$updateFlowContract.orderedRootDescriptors[0]',
        '[string]$updateFlowContract.orderedRootDescriptors[1]',
        '[string]$updateFlowContract.orderedRootDescriptors[2]',
        '[string]$updateFlowContract.orderedRootDescriptors[3]',
        '[string]$updateFlowContract.orderedRootDescriptors[4]',
        '[string]$updateFlowContract.orderedRootDescriptors[5]',
        '[string]$updateFlowContract.orderedRootDescriptors[6]'
    )
    $mainObserved = @($mainArray.Elements | ForEach-Object { $_.Extent.Text })
    if (($mainObserved -join "`n") -cne ($mainExpected -join "`n")) {
        throw 'Patched-APK updater inspector binding order differs from resolution.'
    }

    $fixtureAssignment = Get-UpdateFlowExactAssignment -Ast $FixtureAst `
        -VariableName 'arguments' -Label 'Updater fixture inspector invocation'
    if ($fixtureAssignment.Right -isnot [Management.Automation.Language.CommandExpressionAst] `
            -or $fixtureAssignment.Right.Expression `
                -isnot [Management.Automation.Language.BinaryExpressionAst] `
            -or $fixtureAssignment.Right.Expression.Operator `
                -ne [Management.Automation.Language.TokenKind]::Plus) {
        throw 'Updater fixture inspector arguments must be one exact concatenation.'
    }
    $fixturePrefix = $fixtureAssignment.Right.Expression.Left
    $fixtureRoots = $fixtureAssignment.Right.Expression.Right
    if ($fixturePrefix -isnot [Management.Automation.Language.ArrayExpressionAst] `
            -or $fixtureRoots -isnot [Management.Automation.Language.ArrayExpressionAst]) {
        throw 'Updater fixture inspector argument segments must be AST arrays.'
    }
    $fixturePrefixArray = $fixturePrefix.SubExpression.Statements[0].PipelineElements[0].Expression
    $fixtureExpected = @(
        "'-cp'", '$helperClasspath', "'DexUpdateFlowInspector'", '$FixtureApk',
        '[string]$contract.expectedDexName',
        '[string]$contract.classPrefix',
        '$ExpectedHash',
        '([string]$ExpectedClassCount)'
    )
    $fixtureObserved = @($fixturePrefixArray.Elements | ForEach-Object { $_.Extent.Text })
    if (($fixtureObserved -join "`n") -cne ($fixtureExpected -join "`n") `
            -or [regex]::Replace($fixtureRoots.Extent.Text, '\s+', '') -cne `
                '@($contract.orderedRootDescriptors|ForEach-Object{[string]$_})') {
        throw 'Updater fixture inspector binding order differs from resolution.'
    }
}
function Assert-UpdateReleaseGateAuthorityTopology {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$PatchedApkAst
    )

    $assignment = Get-UpdateFlowExactAssignment -Ast $PatchedApkAst `
        -VariableName 'updateReleaseGates' -Label 'Patched-APK updater release gates'
    if ($assignment.Right -isnot [Management.Automation.Language.CommandExpressionAst] `
            -or $assignment.Right.Expression `
                -isnot [Management.Automation.Language.ConvertExpressionAst] `
            -or [string]$assignment.Right.Expression.Type.TypeName -cne 'ordered' `
            -or $assignment.Right.Expression.Child `
                -isnot [Management.Automation.Language.HashtableAst]) {
        throw 'Patched-APK updater release gates must be one ordered literal map.'
    }
    $gateTable = $assignment.Right.Expression.Child
    $expected = [ordered]@{
        'update-host-fixtures' = [ordered]@{
            status = "'required-prerequisite'"
            proofOwner = "'Test-HostPatchletAssets.ps1'"
        }
        'update-endpoint-policy' = [ordered]@{
            status = "'passed'"
            authoritative = '$true'
            signedDex = '$dexUpdateFlow'
            metadataEndpoints = '@($resolution.update.metadataEndpoints)'
            signedJadx = "@(`$updateRecovered | Where-Object { [string]`$_.className -ceq 'threadsmod.update.UpdateEndpoints' })[0]"
        }
        'update-manifest-contract' = [ordered]@{
            status = "'passed'"
            authoritative = '$true'
            signedDex = '$dexUpdateFlow'
            signedJadx = "@(`$updateRecovered | Where-Object { [string]`$_.className -ceq 'threadsmod.update.UpdateManifest' })[0]"
        }
        'update-dialog-contract' = [ordered]@{
            status = "'passed'"
            authoritative = '$true'
            signedDex = '$dexUpdateFlow'
            signedJadx = "@(`$updateRecovered | Where-Object { [string]`$_.className -ceq 'threadsmod.update.UpdateController' })[0]"
        }
        'update-installer-contract' = [ordered]@{
            status = "'passed'"
            authoritative = '$true'
            signedDex = '$dexUpdateFlow'
            manifest = '$updateManifestContract'
            signerCertificateSha256 = '$certificate'
            runtimeInstallTested = '$false'
        }
        'update-signed-dex-contract' = [ordered]@{
            status = "'passed'"
            authoritative = '$true'
            generatedD8Fixtures = '$dexUpdateFlowFixtureEvidence'
            signedApk = '$dexUpdateFlow'
        }
        'update-manifest-rewrite-contract' = [ordered]@{
            status = "'passed'"
            authoritative = '$true'
            signedDex = '$dexUpdateFlow'
            targetModBuild = '[long]$resolution.target.modBuild'
            targetVersionCode = '[long]$resolution.target.versionCode'
            targetVersionName = '[string]$resolution.target.versionName'
            manifest = '$updateManifestContract'
        }
    }
    $pairs = @($gateTable.KeyValuePairs)
    if ($pairs.Count -ne $expected.Count) {
        throw 'Patched-APK updater release-gate count differs from the reviewed topology.'
    }
    $index = 0
    foreach ($expectedGate in $expected.GetEnumerator()) {
        $pair = $pairs[$index]
        if ($pair.Item1 -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                -or [string]$pair.Item1.Value -cne [string]$expectedGate.Key) {
            throw 'Patched-APK updater release-gate order or key drifted.'
        }
        $nested = @($pair.Item2.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.HashtableAst]
                }, $true))
        if ($nested.Count -ne 1) {
            throw "Updater release gate '$($expectedGate.Key)' must contain one literal property map."
        }
        $properties = @($nested[0].KeyValuePairs)
        if ($properties.Count -ne $expectedGate.Value.Count) {
            throw "Updater release gate '$($expectedGate.Key)' property count drifted."
        }
        $propertyIndex = 0
        foreach ($expectedProperty in $expectedGate.Value.GetEnumerator()) {
            $property = $properties[$propertyIndex]
            $propertyName = if ($property.Item1 -is [Management.Automation.Language.StringConstantExpressionAst]) {
                [string]$property.Item1.Value
            } else {
                [string]$property.Item1.Extent.Text
            }
            $actualExpression = [regex]::Replace(
                [string]$property.Item2.Extent.Text, '\s+', ' ').Trim()
            $expectedExpression = [regex]::Replace(
                [string]$expectedProperty.Value, '\s+', ' ').Trim()
            if ($propertyName -cne [string]$expectedProperty.Key `
                    -or $actualExpression -cne $expectedExpression) {
                throw "Updater release gate '$($expectedGate.Key)' property '$($expectedProperty.Key)' drifted."
            }
            $propertyIndex++
        }
        $index++
    }
}
function Assert-UpdateFlowReleaseToolContract {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$PatchedApkAst,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$FixtureAst,
        [Parameter(Mandatory)][string]$InspectorText,
        [Parameter(Mandatory)][int]$ReviewedFixtureCount,
        [Parameter(Mandatory)][int]$ReviewedArgumentCount
    )

    foreach ($entry in @(
            @($PatchedApkAst, 'Patched-APK validation'),
            @($FixtureAst, 'Updater fixture harness')
        )) {
        Assert-UpdateFlowNumericExpectation -Ast $entry[0] `
            -VariableName 'expectedDexUpdateFlowFixtureCount' `
            -ExpectedValue $ReviewedFixtureCount `
            -ResolutionProperty 'expectedDexUpdateFlowFixtureCount' -Label $entry[1]
        Assert-UpdateFlowNumericExpectation -Ast $entry[0] `
            -VariableName 'expectedDexUpdateFlowInspectorArgumentCount' `
            -ExpectedValue $ReviewedArgumentCount `
            -ResolutionProperty 'expectedDexUpdateFlowInspectorArgumentCount' -Label $entry[1]
    }
    $expectedChecks = @(
        'completeUpdaterGraph', 'normalControlFlow', 'exceptionalControlFlow',
        'registerValueFlow', 'bootstrapArbitration', 'signatureAndMetadata',
        'eligibilityAndPolicy', 'requiredOptionalDialog', 'explicitUpdateTap',
        'retainedUnavailableOnly', 'verifiedFileProvenance',
        'currentBinarySerialization', 'lifecycleOwnership', 'storeAntiRollback'
    )
    Assert-UpdateFlowCheckExpectations -Ast $PatchedApkAst `
        -VariableName 'requiredUpdateFlowChecks' -ExpectedNames $expectedChecks `
        -Label 'Patched-APK validation'
    Assert-UpdateFlowCheckExpectations -Ast $FixtureAst `
        -VariableName 'expectedCheckNames' -ExpectedNames $expectedChecks `
        -Label 'Updater fixture harness'
    Assert-UpdateFlowInspectorInvocationBindings -PatchedApkAst $PatchedApkAst `
        -FixtureAst $FixtureAst
    Assert-UpdateReleaseGateAuthorityTopology -PatchedApkAst $PatchedApkAst
    $mainText = [string]$PatchedApkAst.Extent.Text
    $fixtureText = [string]$FixtureAst.Extent.Text
    foreach ($literal in @(
            '[string]$dexUpdateFlowFixtureResult.representationStableEncoding.status',
            '[int]$dexUpdateFlowFixtureResult.representationStableEncoding.constStringJumboReplacements',
            'representationStableEncoding =')) {
        if ((Get-PatchletLiteralCount -Text $mainText -Literal $literal) -ne 1) {
            throw "Patched-APK updater representation prerequisite '$literal' is missing or duplicated."
        }
    }
    foreach ($literal in @(
            'function New-StringEncodingVariantApk {',
            'representation\EncodingNormalizationFixture.java',
            '-or [string]$representationProbe.result.semanticSha256 -cne $representationHash',
            "throw 'Update representation-stability jumbo/offset/try/switch fixture failed.'")) {
        if ((Get-PatchletLiteralCount -Text $fixtureText -Literal $literal) -ne 1) {
            throw "Updater representation fixture proof '$literal' is missing or duplicated."
        }
    }
    if (([regex]::Matches($InspectorText,
                'require\(args\.length == 12, "argument_count"\);')).Count -ne 1 `
            -or $ReviewedArgumentCount -ne 12) {
        throw 'Updater inspector argument-count guard differs from the reviewed literal.'
    }
    return [pscustomobject]@{
        status = 'passed'
        fixtureCount = $ReviewedFixtureCount
        inspectorArgumentCount = $ReviewedArgumentCount
        semanticCheckCount = $expectedChecks.Count
    }
}
function Get-UpdateFlowAstFromText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Label
    )

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $Text, $Label, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        throw "$Label mutation produced a PowerShell parse error."
    }
    return $ast
}
function Set-UpdateFlowContractMutation {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Before,
        [Parameter(Mandatory)][AllowEmptyString()][string]$After,
        [Parameter(Mandatory)][string]$Label
    )

    $count = [regex]::Matches($Text, [regex]::Escape($Before)).Count
    if ($count -ne 1 -or $Before.Equals($After, [StringComparison]::Ordinal)) {
        throw "$Label source mutation is not exact."
    }
    return $Text.Replace($Before, $After)
}
function Test-UpdateFlowReleaseToolContractNegativeFixtures {
    param(
        [Parameter(Mandatory)][string]$PatchedApkText,
        [Parameter(Mandatory)][string]$FixtureText,
        [Parameter(Mandatory)][string]$InspectorText,
        [Parameter(Mandatory)][int]$ReviewedFixtureCount,
        [Parameter(Mandatory)][int]$ReviewedArgumentCount
    )

    $cases = @(
        [pscustomobject]@{
            id = 'fixture-count-missing'
            target = 'fixture'
            before = "`$expectedDexUpdateFlowFixtureCount = $ReviewedFixtureCount"
            after = ''
        },
        [pscustomobject]@{
            id = 'fixture-count-duplicate'
            target = 'fixture'
            before = "`$expectedDexUpdateFlowFixtureCount = $ReviewedFixtureCount"
            after = "`$expectedDexUpdateFlowFixtureCount = $ReviewedFixtureCount`n`$expectedDexUpdateFlowFixtureCount = $ReviewedFixtureCount"
        },
        [pscustomobject]@{
            id = 'fixture-count-nonliteral'
            target = 'fixture'
            before = "`$expectedDexUpdateFlowFixtureCount = $ReviewedFixtureCount"
            after = '`$expectedDexUpdateFlowFixtureCount = [int]$resolution.release.expectedDexUpdateFlowFixtureCount'.Replace('`$', '$')
        },
        [pscustomobject]@{
            id = 'main-fixture-count-divergent'
            target = 'main'
            before = "`$expectedDexUpdateFlowFixtureCount = $ReviewedFixtureCount"
            after = "`$expectedDexUpdateFlowFixtureCount = $($ReviewedFixtureCount + 1)"
        },
        [pscustomobject]@{
            id = 'main-argument-count-divergent'
            target = 'main'
            before = "`$expectedDexUpdateFlowInspectorArgumentCount = $ReviewedArgumentCount"
            after = "`$expectedDexUpdateFlowInspectorArgumentCount = $($ReviewedArgumentCount + 1)"
        },
        [pscustomobject]@{
            id = 'semantic-check-divergent'
            target = 'fixture'
            before = "'storeAntiRollback'"
            after = "'storeAntiRollbackDrifted'"
        },
        [pscustomobject]@{
            id = 'main-binding-reordered'
            target = 'main'
            before = "[string]`$updateFlowContract.expectedDexName,`n    [string]`$updateFlowContract.classPrefix,"
            after = "[string]`$updateFlowContract.classPrefix,`n    [string]`$updateFlowContract.expectedDexName,"
        },
        [pscustomobject]@{
            id = 'inspector-argument-guard-divergent'
            target = 'inspector'
            before = 'require(args.length == 12, "argument_count");'
            after = 'require(args.length == 13, "argument_count");'
        },
        [pscustomobject]@{
            id = 'jadx-cannot-supply-update-authority'
            target = 'main'
            before = "signedDex = `$dexUpdateFlow`n        metadataEndpoints ="
            after = "signedDex = `$null`n        metadataEndpoints ="
        },
        [pscustomobject]@{
            id = 'main-representation-prerequisite-removed'
            target = 'main'
            before = '[string]$dexUpdateFlowFixtureResult.representationStableEncoding.status'
            after = '[string]$false'
        },
        [pscustomobject]@{
            id = 'fixture-representation-equality-removed'
            target = 'fixture'
            before = '-or [string]$representationProbe.result.semanticSha256 -cne $representationHash'
            after = '-or $false'
        }
    )
    $results = @()
    foreach ($case in $cases) {
        $mainText = $PatchedApkText
        $harnessText = $FixtureText
        $javaText = $InspectorText
        if ($case.target -eq 'main') {
            $mainText = Set-UpdateFlowContractMutation -Text $mainText `
                -Before $case.before -After $case.after -Label $case.id
        } elseif ($case.target -eq 'fixture') {
            $harnessText = Set-UpdateFlowContractMutation -Text $harnessText `
                -Before $case.before -After $case.after -Label $case.id
        } else {
            $javaText = Set-UpdateFlowContractMutation -Text $javaText `
                -Before $case.before -After $case.after -Label $case.id
        }
        $rejected = $false
        try {
            $mainAst = Get-UpdateFlowAstFromText -Text $mainText `
                -Label ($case.id + '-main')
            $harnessAst = Get-UpdateFlowAstFromText -Text $harnessText `
                -Label ($case.id + '-fixture')
            $null = Assert-UpdateFlowReleaseToolContract `
                -PatchedApkAst $mainAst -FixtureAst $harnessAst `
                -InspectorText $javaText -ReviewedFixtureCount $ReviewedFixtureCount `
                -ReviewedArgumentCount $ReviewedArgumentCount
        } catch {
            $rejected = $true
        }
        if (-not $rejected) {
            throw "Updater release-tool contract negative '$($case.id)' was accepted."
        }
        $results += [pscustomobject]@{ id = $case.id; rejected = $true }
    }
    return @($results)
}

function Assert-PatchedApkPassiveJadxWrapperParity {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string[]]$ExpectedStrings
    )

    if ($ExpectedStrings.Count -eq 0 `
            -or @($ExpectedStrings | Where-Object {
                    [string]::IsNullOrWhiteSpace([string]$_)
                }).Count -ne 0 `
            -or @($ExpectedStrings | Sort-Object -Unique).Count -ne $ExpectedStrings.Count) {
        throw 'Resolution passive JADX wrapper baseline must be nonempty, literal, and unique.'
    }
    $assignments = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] `
                    -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] `
                    -and $node.Left.VariablePath.UserPath -ceq 'passiveTargetRequirements'
            }, $true))
    if ($assignments.Count -ne 1) {
        throw 'Patched-APK wrapper must declare passiveTargetRequirements exactly once.'
    }
    $hashtables = @($assignments[0].Right.FindAll({
                param($node)
                $node -is [Management.Automation.Language.HashtableAst]
            }, $true))
    if ($hashtables.Count -ne 1) {
        throw 'Patched-APK passiveTargetRequirements must be one literal hashtable.'
    }
    $entries = @($hashtables[0].KeyValuePairs | Where-Object {
            $_.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] `
                -and [string]$_.Item1.Value -ceq 'threadsmod.autoblock.AutoBlockSync'
        })
    if ($entries.Count -ne 1) {
        throw 'Patched-APK passive JADX wrapper must own one AutoBlockSync requirement array.'
    }
    $nonliteralVariables = @($entries[0].Item2.FindAll({
                param($node)
                $node -is [Management.Automation.Language.VariableExpressionAst]
            }, $true))
    $actualStrings = @($entries[0].Item2.FindAll({
                param($node)
                $node -is [Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | ForEach-Object { [string]$_.Value })
    if ($nonliteralVariables.Count -ne 0 `
            -or ($actualStrings -join "`n") -cne ($ExpectedStrings -join "`n")) {
        throw 'Patched-APK passive JADX wrapper differs from the exact resolution-owned AutoBlockSync baseline.'
    }
    return [pscustomobject]@{
        strings = $actualStrings
        assignmentText = [string]$assignments[0].Extent.Text
    }
}

$patchedApkPath = Join-Path $PSScriptRoot 'Test-PatchedApk.ps1'
$dexBridgeFlowFixtureTestPath = Join-Path $PSScriptRoot 'Test-DexBridgeFlowInspector.ps1'
$dexReportPermalinkFlowFixtureTestPath = Join-Path $PSScriptRoot 'Test-DexReportPermalinkFlowInspector.ps1'
$dexProxyBootstrapFlowFixtureTestPath = Join-Path $PSScriptRoot `
    'Test-DexProxyBootstrapFlowInspector.ps1'
$patchedApkAst = Get-ThreadsModReleaseToolAst `
    -Path $patchedApkPath -Label 'Patched-APK validation'
$passiveJadxWrapperExpectedStrings = @(
    $resolutionForContract.release.requiredPassiveJadxWrapperAutoBlockStrings |
        ForEach-Object { [string]$_ })
if ($passiveJadxWrapperExpectedStrings.Count -ne 11 `
        -or @($passiveJadxWrapperExpectedStrings | Where-Object {
                $_ -ceq 'currentPassiveMatch('
            }).Count -ne 1 `
        -or @($passiveJadxWrapperExpectedStrings | Where-Object {
                $_ -ceq 'isCurrentPassiveMatch('
            }).Count -ne 0) {
    throw 'Resolution passive JADX wrapper baseline must bind currentPassiveMatch and reject the stale isCurrentPassiveMatch spelling.'
}
$passiveJadxWrapperParity = Assert-PatchedApkPassiveJadxWrapperParity `
    -Ast $patchedApkAst -ExpectedStrings $passiveJadxWrapperExpectedStrings
$passiveJadxWrapperNegativeCases = @(
    [pscustomobject]@{
        id = 'stale-is-current-spelling'
        replacement = "'isCurrentPassiveMatch('"
    },
    [pscustomobject]@{
        id = 'missing-current-spelling'
        replacement = "'retiredPassiveMatch('"
    },
    [pscustomobject]@{
        id = 'duplicate-current-spelling'
        replacement = "'currentPassiveMatch(',`n        'currentPassiveMatch('"
    },
    [pscustomobject]@{
        id = 'nonliteral-current-spelling'
        replacement = '$passiveCurrentMatchToken'
    }
)
$passiveJadxWrapperNegativeResults = @()
foreach ($passiveJadxWrapperNegativeCase in $passiveJadxWrapperNegativeCases) {
    $fixtureAnchor = "'currentPassiveMatch('"
    if ((Get-PatchletLiteralCount `
                -Text ([string]$passiveJadxWrapperParity.assignmentText) `
                -Literal $fixtureAnchor) -ne 1) {
        throw 'Patched-APK passive JADX wrapper currentPassiveMatch fixture anchor must occur exactly once.'
    }
    $fixtureText = ([string]$passiveJadxWrapperParity.assignmentText).Replace(
        $fixtureAnchor, [string]$passiveJadxWrapperNegativeCase.replacement)
    $fixtureTokens = $null
    $fixtureErrors = $null
    $fixtureAst = [Management.Automation.Language.Parser]::ParseInput(
        $fixtureText, [ref]$fixtureTokens, [ref]$fixtureErrors)
    if (@($fixtureErrors).Count -ne 0) {
        throw "Passive JADX wrapper negative '$($passiveJadxWrapperNegativeCase.id)' has PowerShell parse errors."
    }
    $caught = $null
    try {
        $null = Assert-PatchedApkPassiveJadxWrapperParity `
            -Ast $fixtureAst -ExpectedStrings $passiveJadxWrapperExpectedStrings
    } catch {
        $caught = $_
    }
    if ($null -eq $caught) {
        throw "Passive JADX wrapper negative '$($passiveJadxWrapperNegativeCase.id)' was accepted."
    }
    $passiveJadxWrapperNegativeResults += [pscustomobject]@{
        id = [string]$passiveJadxWrapperNegativeCase.id
        rejected = $true
    }
}
$dexUpdateFlowFixtureTestAst = Get-ThreadsModReleaseToolAst `
    -Path $dexUpdateFlowFixtureTestPath -Label 'DEX updater-flow fixture test'
$dexUpdateFlowInspectorText = Get-NormalizedPatchletText `
    -Path $dexUpdateFlowInspectorPath
$releaseToolUpdateFlowCompatibility = Assert-UpdateFlowReleaseToolContract `
    -PatchedApkAst $patchedApkAst -FixtureAst $dexUpdateFlowFixtureTestAst `
    -InspectorText $dexUpdateFlowInspectorText `
    -ReviewedFixtureCount `
        ([int]$resolutionForContract.release.expectedDexUpdateFlowFixtureCount) `
    -ReviewedArgumentCount `
        ([int]$resolutionForContract.release.expectedDexUpdateFlowInspectorArgumentCount)
$releaseToolUpdateFlowContractNegativeFixtures = `
    Test-UpdateFlowReleaseToolContractNegativeFixtures `
        -PatchedApkText (Get-NormalizedPatchletText -Path $patchedApkPath) `
        -FixtureText (Get-NormalizedPatchletText -Path $dexUpdateFlowFixtureTestPath) `
        -InspectorText $dexUpdateFlowInspectorText `
        -ReviewedFixtureCount `
            ([int]$resolutionForContract.release.expectedDexUpdateFlowFixtureCount) `
        -ReviewedArgumentCount `
            ([int]$resolutionForContract.release.expectedDexUpdateFlowInspectorArgumentCount)
$dexBridgeFlowFixtureTestAst = Get-ThreadsModReleaseToolAst `
    -Path $dexBridgeFlowFixtureTestPath -Label 'DEX bridge-flow fixture test'
$dexReportPermalinkFlowFixtureTestAst = Get-ThreadsModReleaseToolAst `
    -Path $dexReportPermalinkFlowFixtureTestPath `
    -Label 'DEX report-permalink-flow fixture test'
$dexProxyBootstrapFlowFixtureTestAst = Get-ThreadsModReleaseToolAst `
    -Path $dexProxyBootstrapFlowFixtureTestPath `
    -Label 'DEX proxy-bootstrap-flow fixture test'
$releaseToolParameterCompatibility = Test-ThreadsModReleaseToolInvocationContracts `
    -ToolsRoot $PSScriptRoot
$releaseBridgeEvidenceContract = `
    @($resolutionForContract.release.requiredDexBridgeFlows)[0]
$releaseToolEvidenceCompatibility = Assert-ThreadsModReleaseEvidenceContract `
    -ReleaseWrapperAst $patchedApkAst `
    -FixtureHarnessAst $dexBridgeFlowFixtureTestAst `
    -ReviewedFixtureCount ([int]$resolutionForContract.release.expectedDexBridgeFlowFixtureCount) `
    -ReviewedTerminalRoutes ([int]$resolutionForContract.release.expectedReviewedTerminalRoutes) `
    -ReviewedCurrentTerminalRoutes `
        ([int]$resolutionForContract.release.expectedCurrentReviewedTerminalRoutes) `
    -ReviewedCurrentPacedNextPosts `
        ([int]$resolutionForContract.release.expectedCurrentAutomaticPacedNextPosts) `
    -ReviewedCurrentOwnerMode `
        ([string]$resolutionForContract.release.expectedCurrentAutomaticOwnerMode) `
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
    -InspectorSourcePath (Join-Path $PSScriptRoot 'DexBridgeFlowInspector.java') `
    -ReviewedArgumentCount ([int]$resolutionForContract.release.expectedDexBridgeFlowInspectorArgumentCount)
$releaseToolInspectorBindingCompatibility = Assert-ThreadsModDexBridgeInspectorBindingContract `
    -ReleaseWrapperAst $patchedApkAst `
    -FixtureHarnessAst $dexBridgeFlowFixtureTestAst `
    -ReviewedArgumentCount `
        ([int]$resolutionForContract.release.expectedDexBridgeFlowInspectorArgumentCount)
$releaseToolReportPermalinkEvidenceCompatibility = Assert-ThreadsModReportPermalinkEvidenceContract `
    -ReleaseWrapperAst $patchedApkAst `
    -FixtureHarnessAst $dexReportPermalinkFlowFixtureTestAst `
    -ReviewedFixtureCount `
        ([int]$resolutionForContract.release.expectedDexReportPermalinkFlowFixtureCount) `
    -ReviewedInspectorArgumentCount `
        ([int]$resolutionForContract.release.expectedDexReportPermalinkFlowInspectorArgumentCount)
$releaseToolReportPermalinkInspectorArgumentCompatibility = `
    Assert-ThreadsModReportPermalinkInspectorArgumentContract `
        -InspectorSourcePath (Join-Path $PSScriptRoot 'DexReportPermalinkFlowInspector.java') `
        -ReviewedArgumentCount `
            ([int]$resolutionForContract.release.expectedDexReportPermalinkFlowInspectorArgumentCount)
$releaseToolReportPermalinkInspectorBindingCompatibility = `
    Assert-ThreadsModReportPermalinkInspectorBindingContract `
        -ReleaseWrapperAst $patchedApkAst `
        -FixtureHarnessAst $dexReportPermalinkFlowFixtureTestAst `
        -ReviewedArgumentCount `
            ([int]$resolutionForContract.release.expectedDexReportPermalinkFlowInspectorArgumentCount)
$releaseToolProxyBootstrapEvidenceCompatibility = `
    Assert-ThreadsModProxyBootstrapEvidenceContract `
        -ReleaseWrapperAst $patchedApkAst `
        -FixtureHarnessAst $dexProxyBootstrapFlowFixtureTestAst `
        -ReviewedFixtureCount `
            ([int]$resolutionForContract.release.expectedDexProxyBootstrapFlowFixtureCount) `
        -ReviewedInspectorArgumentCount `
            ([int]$resolutionForContract.release.expectedDexProxyBootstrapFlowInspectorArgumentCount)
$releaseToolProxyBootstrapInspectorArgumentCompatibility = `
    Assert-ThreadsModProxyBootstrapInspectorArgumentContract `
        -InspectorSourcePath (Join-Path $PSScriptRoot 'DexProxyBootstrapFlowInspector.java') `
        -ReviewedArgumentCount `
            ([int]$resolutionForContract.release.expectedDexProxyBootstrapFlowInspectorArgumentCount)
$releaseToolProxyBootstrapInspectorBindingCompatibility = `
    Assert-ThreadsModProxyBootstrapInspectorBindingContract `
        -ReleaseWrapperAst $patchedApkAst `
        -FixtureHarnessAst $dexProxyBootstrapFlowFixtureTestAst `
        -ReviewedArgumentCount `
            ([int]$resolutionForContract.release.expectedDexProxyBootstrapFlowInspectorArgumentCount)
$releaseToolContractNegativeFixtures = Test-ThreadsModReleaseToolContractNegativeFixtures `
    -ReviewedFixtureCount ([int]$resolutionForContract.release.expectedDexBridgeFlowFixtureCount) `
    -ReviewedTerminalRoutes ([int]$resolutionForContract.release.expectedReviewedTerminalRoutes) `
    -ReviewedCurrentTerminalRoutes `
        ([int]$resolutionForContract.release.expectedCurrentReviewedTerminalRoutes) `
    -ReviewedCurrentPacedNextPosts `
        ([int]$resolutionForContract.release.expectedCurrentAutomaticPacedNextPosts) `
    -ReviewedCurrentOwnerMode `
        ([string]$resolutionForContract.release.expectedCurrentAutomaticOwnerMode) `
    -ReviewedPrepareModelInvokeCount `
        ([int]$releaseBridgeEvidenceContract.expectedPrepareModelInvokeCount) `
    -ReviewedPassivePreflightInvokeCount `
        ([int]$releaseBridgeEvidenceContract.expectedPassivePreflightInvokeCount) `
    -ReviewedCacheLookupInvokeCount `
        ([int]$releaseBridgeEvidenceContract.expectedCacheLookupInvokeCount) `
    -ReviewedCacheFactoryInvokeCount `
        ([int]$releaseBridgeEvidenceContract.expectedCacheFactoryInvokeCount) `
    -ReviewedCachePlaceholderInvokeCount `
        ([int]$releaseBridgeEvidenceContract.expectedCachePlaceholderInvokeCount) `
    -ReviewedInspectorArgumentCount ([int]$resolutionForContract.release.expectedDexBridgeFlowInspectorArgumentCount) `
    -ReviewedReportPermalinkFixtureCount `
        ([int]$resolutionForContract.release.expectedDexReportPermalinkFlowFixtureCount) `
    -ReviewedReportPermalinkInspectorArgumentCount `
        ([int]$resolutionForContract.release.expectedDexReportPermalinkFlowInspectorArgumentCount) `
    -ReviewedProxyBootstrapFixtureCount `
        ([int]$resolutionForContract.release.expectedDexProxyBootstrapFlowFixtureCount) `
    -ReviewedProxyBootstrapInspectorArgumentCount `
        ([int]$resolutionForContract.release.expectedDexProxyBootstrapFlowInspectorArgumentCount)
$pipelineCommands = @($pipelineAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst]
        }, $true))
$decodedLockAssertions = @($pipelineCommands | Where-Object {
        if ($_.GetCommandName() -ne 'Assert-PatchletInputFreezeLock') { return $false }
        $stageArgument = Get-ReleaseContractCommandArgumentAst -Command $_ -ParameterName 'Stage'
        return $null -ne $stageArgument `
            -and $stageArgument.Extent.Text.IndexOf('decoded', [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
if ($decodedLockAssertions.Count -lt 4) {
    throw 'Release pipeline is missing a required decoded-input lock assertion.'
}
foreach ($decodedLockAssertion in $decodedLockAssertions) {
    $lockArgument = Get-ReleaseContractCommandArgumentAst `
        -Command $decodedLockAssertion -ParameterName 'Lock'
    $allowedTreeArgument = Get-ReleaseContractCommandArgumentAst `
        -Command $decodedLockAssertion -ParameterName 'AllowedTreeMutationRoots'
    $allowedFileArgument = Get-ReleaseContractCommandArgumentAst `
        -Command $decodedLockAssertion -ParameterName 'AllowedFileMutationPaths'
    if ($lockArgument -isnot [Management.Automation.Language.VariableExpressionAst] `
            -or @('decodedInputLock', 'DecodedLock') -notcontains $lockArgument.VariablePath.UserPath `
            -or $null -ne $allowedTreeArgument `
            -or $null -ne $allowedFileArgument) {
        throw 'Canonical decoded-input lock assertions must retain a zero-exception mutation contract.'
    }
}
$decodedAfterIdempotencyAssertions = @($decodedLockAssertions | Where-Object {
        $stageArgument = Get-ReleaseContractCommandArgumentAst -Command $_ -ParameterName 'Stage'
        $stageArgument -is [Management.Automation.Language.StringConstantExpressionAst] `
            -and $stageArgument.Value -eq 'decoded-input-after-idempotency'
    })
if ($decodedAfterIdempotencyAssertions.Count -ne 1) {
    throw 'Release pipeline must have exactly one decoded lock assertion immediately after idempotency.'
}
$decodedLockAcquisitions = @($pipelineCommands | Where-Object {
        if ($_.GetCommandName() -ne 'Enter-PatchletInputFreezeLock') { return $false }
        $stageArgument = Get-ReleaseContractCommandArgumentAst -Command $_ -ParameterName 'Stage'
        $stageArgument -is [Management.Automation.Language.StringConstantExpressionAst] `
            -and $stageArgument.Value -eq 'decoded-input-before-idempotency'
    })
if ($decodedLockAcquisitions.Count -ne 1) {
    throw 'Decoded-input lock acquisition must occur exactly once before idempotency.'
}
$decodedAcquisitionAllowedTreeArgument = Get-ReleaseContractCommandArgumentAst `
    -Command $decodedLockAcquisitions[0] -ParameterName 'AllowedTreeMutationRoots'
$decodedAcquisitionAllowedFileArgument = Get-ReleaseContractCommandArgumentAst `
    -Command $decodedLockAcquisitions[0] -ParameterName 'AllowedFileMutationPaths'
if ($null -ne $decodedAcquisitionAllowedTreeArgument -or $null -ne $decodedAcquisitionAllowedFileArgument) {
    throw 'Canonical decoded-input lock acquisition must not permit any mutation path.'
}
$buildWorkingMutationLockAssertions = @($pipelineCommands | Where-Object {
        if ($_.GetCommandName() -ne 'Assert-PatchletInputFreezeLock') { return $false }
        $lockArgument = Get-ReleaseContractCommandArgumentAst -Command $_ -ParameterName 'Lock'
        return $lockArgument -is [Management.Automation.Language.VariableExpressionAst] `
            -and $lockArgument.VariablePath.UserPath.Equals(
                'buildWorkingMutationLock', [StringComparison]::OrdinalIgnoreCase)
    })
if ($buildWorkingMutationLockAssertions.Count -lt 4) {
    throw 'Release pipeline is missing a required mutable build-working lock assertion.'
}
foreach ($buildWorkingLockAssertion in $buildWorkingMutationLockAssertions) {
    $lockArgument = Get-ReleaseContractCommandArgumentAst `
        -Command $buildWorkingLockAssertion -ParameterName 'Lock'
    $allowedTreeArgument = Get-ReleaseContractCommandArgumentAst `
        -Command $buildWorkingLockAssertion -ParameterName 'AllowedTreeMutationRoots'
    $allowedFileArgument = Get-ReleaseContractCommandArgumentAst `
        -Command $buildWorkingLockAssertion -ParameterName 'AllowedFileMutationPaths'
    if ($null -eq $allowedTreeArgument `
            -or -not (Test-ReleaseContractVariableArrayArgument `
                -Argument $allowedTreeArgument -VariableNames @('buildWorkingBuildCache')) `
            -or $null -eq $allowedFileArgument `
            -or -not (Test-ReleaseContractVariableArrayArgument `
                -Argument $allowedFileArgument `
                -VariableNames @('buildWorkingManifest', 'buildWorkingManifestOriginal'))) {
        throw 'Every build-working lock assertion must repeat the exact Apktool tree/file mutation contract.'
    }
}
$buildWorkingSealedLockAssertions = @($pipelineCommands | Where-Object {
        if ($_.GetCommandName() -ne 'Assert-PatchletInputFreezeLock') { return $false }
        $lockArgument = Get-ReleaseContractCommandArgumentAst -Command $_ -ParameterName 'Lock'
        return $lockArgument -is [Management.Automation.Language.VariableExpressionAst] `
            -and @('buildWorkingInputLock', 'BuildWorkingLock') -contains $lockArgument.VariablePath.UserPath
    })
if ($buildWorkingSealedLockAssertions.Count -lt 2) {
    throw 'Release pipeline is missing a required sealed build-working lock assertion.'
}
foreach ($buildWorkingSealedLockAssertion in $buildWorkingSealedLockAssertions) {
    if ($null -ne (Get-ReleaseContractCommandArgumentAst `
                -Command $buildWorkingSealedLockAssertion -ParameterName 'AllowedTreeMutationRoots') `
            -or $null -ne (Get-ReleaseContractCommandArgumentAst `
                -Command $buildWorkingSealedLockAssertion -ParameterName 'AllowedFileMutationPaths')) {
        throw 'Sealed build-working lock assertions must retain a zero-exception mutation contract.'
    }
}
$buildWorkingLockAcquisitions = @($pipelineCommands | Where-Object {
        if ($_.GetCommandName() -ne 'Enter-PatchletInputFreezeLock') { return $false }
        $stageArgument = Get-ReleaseContractCommandArgumentAst -Command $_ -ParameterName 'Stage'
        $stageArgument -is [Management.Automation.Language.StringConstantExpressionAst] `
            -and $stageArgument.Value -eq 'build-working-before-apktool'
    })
if ($buildWorkingLockAcquisitions.Count -ne 1) {
    throw 'Build-working lock acquisition must occur exactly once before Apktool.'
}
$workingAcquisitionTreeArgument = Get-ReleaseContractCommandArgumentAst `
    -Command $buildWorkingLockAcquisitions[0] -ParameterName 'AllowedTreeMutationRoots'
$workingAcquisitionFileArgument = Get-ReleaseContractCommandArgumentAst `
    -Command $buildWorkingLockAcquisitions[0] -ParameterName 'AllowedFileMutationPaths'
if ($null -eq $workingAcquisitionTreeArgument `
        -or -not (Test-ReleaseContractVariableArrayArgument `
            -Argument $workingAcquisitionTreeArgument -VariableNames @('buildWorkingBuildCache')) `
        -or $null -eq $workingAcquisitionFileArgument `
        -or -not (Test-ReleaseContractVariableArrayArgument `
            -Argument $workingAcquisitionFileArgument `
            -VariableNames @('buildWorkingManifest', 'buildWorkingManifestOriginal'))) {
    throw 'Build-working lock acquisition does not bind the exact Apktool mutation paths.'
}
$buildWorkingSealAcquisitions = @($pipelineCommands | Where-Object {
        if ($_.GetCommandName() -ne 'Enter-PatchletInputFreezeLock') { return $false }
        $stageArgument = Get-ReleaseContractCommandArgumentAst -Command $_ -ParameterName 'Stage'
        $stageArgument -is [Management.Automation.Language.StringConstantExpressionAst] `
            -and $stageArgument.Value -eq 'build-working-sealed-after-cleanup'
    })
if ($buildWorkingSealAcquisitions.Count -ne 1 `
        -or $null -ne (Get-ReleaseContractCommandArgumentAst `
            -Command $buildWorkingSealAcquisitions[0] -ParameterName 'AllowedTreeMutationRoots') `
        -or $null -ne (Get-ReleaseContractCommandArgumentAst `
            -Command $buildWorkingSealAcquisitions[0] -ParameterName 'AllowedFileMutationPaths')) {
    throw 'Build-working tree must be immutably re-locked before candidate acceptance.'
}
$moduleText = Get-NormalizedPatchletText -Path (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1')
$buildText = Get-NormalizedPatchletText -Path (Join-Path $PSScriptRoot 'Build-PatchedApk.ps1')
$patchedApkText = Get-NormalizedPatchletText -Path $patchedApkPath
if ((Get-PatchletSha256 -Path $pipelinePath) `
        -ne [string]$resolutionForContract.assets.patchletPipelineSourceSha256 `
        -or (Get-PatchletSha256 -Path (Join-Path $PSScriptRoot 'Build-PatchedApk.ps1')) `
        -ne [string]$resolutionForContract.assets.buildPatchedApkSourceSha256) {
    throw 'SignedReview pipeline or build-tool hash differs from the exact resolution.'
}
$hostPatchletAssetsText = Get-NormalizedPatchletText -Path (
    Join-Path $PSScriptRoot 'Test-HostPatchletAssets.ps1')
$passiveSignedGateIds = @(
    'passive-index-contract',
    'passive-refresh-contract',
    'passive-activity-status-contract',
    'passive-viewport-observer-contract',
    'passive-visible-scheduler-contract'
)
foreach ($passiveSignedGateId in $passiveSignedGateIds) {
    if ((Get-PatchletLiteralCount -Text $patchedApkText `
                -Literal ("'{0}' =" -f $passiveSignedGateId)) -ne 1) {
        throw "Signed-APK passive gate is not executable exactly once: $passiveSignedGateId"
    }
}
foreach ($passiveSignedGateLiteral in @(
        'passiveBlockingReleaseGates = $passiveBlockingReleaseGates',
        'mutationAuthority = ''exact-target-id-primary-key-only''',
        'cadenceMs = 600000',
        'lifecycle = ''foreground-checked-handler-wake''',
        'settingsDisclosure = $settingsPassiveDisclosure',
        'authority = ''memory-only-visibility-transitions''',
        'finalGuard = ''generation-membership-and-current-visibility-before-reservation''',
        'scheduler = ''shared-single-flight-BlockRun''')) {
    if (-not $patchedApkText.Contains(
            $passiveSignedGateLiteral, [StringComparison]::Ordinal)) {
        throw "Signed-APK passive release evidence is missing '$passiveSignedGateLiteral'."
    }
}
foreach ($updateHostLiteral in @(
        "(Join-Path `$assetsRoot 'tests\UpdatePolicyHarness.java')",
        "(Join-Path `$assetsRoot 'tests\UpdateSignatureHarness.java')",
        "(Join-Path `$assetsRoot 'tests\UpdateStoreFloorHarness.java')",
        "'PASS update-policy metadata=3 providers=github,aws redirects=same-provider json=strict utf8=strict'",
        "'PASS update-signature rfc8032=true tamper=false noncanonical=false'",
        "'PASS update-store-floor false-commit=true thrown-edit=true uncertain-load-rejected=true stale-rejected=true same-repair=true higher-repair=true envelope-below-typed=true envelope-above-typed=true mismatch-equal-rejected=true mismatch-newer-repair=true retained-required=true first-run-no-lock=true optional-no-lock=true'",
        'static final String PURPOSE = "threadsmod-app-update";',
        "'UpdateSignature.verifyProduction(payloadJson, signature)'",
        "'MAX_INITIAL_URL_CHARS = 1024'",
        "'MAX_REDIRECT_LOCATION_CHARS = 4096'",
        "'MAX_REDIRECT_PATH_CHARS = 2048'",
        "'MAX_REDIRECT_QUERY_CHARS = 2048'",
        "'public static final long CURRENT_MOD_BUILD = 1L'",
        "'METADATA_ATTEMPT_TIMEOUT_MS = 8000L'",
        "'METADATA_OPERATION_TIMEOUT_MS = 24000L'",
        "'DOWNLOAD_OPERATION_TIMEOUT_MS = 20L * 60L * 1000L'",
        "'disconnectAtDeadline(connection, attemptDeadline)'",
        "'shown.setCancelable(!required)'",
        "'dialog != shown || !shown.isShowing()'",
        "'hasPolicyState && (!(rawRevision instanceof Long)'",
        "'(Long) rawRevision <= 0L'",
        "'(Long) rawModBuild <= 0L'",
        "'boolean exactEnvelopeBinding = envelopeFloor != null'",
        "'long strongestRevisionFloor = envelopeFloor == null'",
        "'hasPolicyState && !exactEnvelopeBinding'",
        'throw new SecurityException("update manifest repair requires newer revision")',
        "'private static boolean policyPersistenceUncertain'",
        "'private static UpdateManifest policyPersistenceFloor'",
        "'private static UpdateManifest lastVerifiedManifestForEnforcement'",
        "'static synchronized boolean hasRetainedRequiredForEnforcement(long currentModBuild)'",
        "`$retainedAccessorCount = Get-PatchletLiteralCount",
        "`$retainedUnavailableCallCount = Get-PatchletLiteralCount",
        "'Updater retained-required enforcement must have exactly three boolean Store checks and three unavailable-only UI routes, with no retained-manifest accessor.'",
        'CACHE_APK_NAME = "threadsmod-update.apk"',
        'CACHE_PART_NAME = "threadsmod-update.apk.part"',
        "'apk.length() != manifest.apkSize'",
        "'archive.getLongVersionCode() <= current.getLongVersionCode()'",
        "'!manifest.versionName.equals(archive.versionName)'",
        "'UpdateManifest.APPLICATION_ID.equals(activity.getPackageName())'",
        'FILE_PROVIDER_AUTHORITY = "app.tree55.threads.fileprovider"',
        "'signers.length != 1'")) {
    if ((Get-PatchletLiteralCount -Text $hostPatchletAssetsText `
                -Literal $updateHostLiteral) -ne 1) {
        throw "Updater host/static proof literal is missing or duplicated: $updateHostLiteral"
    }
}
foreach ($updateSignedApkLiteral in @(
        'foreach ($required in @($resolution.update.metadataEndpoints))',
        "'Final versionCode is incorrect.'",
        "'Final versionName is incorrect.'",
        'foreach ($authorityRequirement in @($resolution.release.requiredProviderAuthorities))',
        '$authority = [string]$authorityRequirement.authority',
        '$expectedAuthorityCount = [int]$authorityRequirement.expectedCount',
        'if ($matches -ne $expectedAuthorityCount)',
        '$null = Assert-PatchletManifestPermission -ManifestText $manifestText',
        "'Manifest-only updater permission must not be required as a final-DEX marker.'",
        "'Final manifest must request REQUEST_INSTALL_PACKAGES exactly once.'",
        "'Final manifest must retain exactly one resolution-owned clone FileProvider authority.'",
        "'Final clone FileProvider must be non-exported, grant URI permissions, and own the exact updater authority.'",
        "'Final FileProvider paths resource must expose exactly cache/shared through the reviewed shared path.'",
        '$dexUpdateFlowFixtureResult = & $dexUpdateFlowFixtureTest',
        '$dexUpdateFlowFixtureResult.representationStableEncoding.status',
        '$dexUpdateFlowFixtureResult.representationStableEncoding.constStringJumboReplacements',
        '$updateFlowLines = @(Invoke-Captured -Command $Java -Arguments @(',
        '$requiredUpdateFlowChecks = @(',
        "'completeUpdaterGraph'",
        "'storeAntiRollback'",
        "throw 'Signed-DEX updater flow evidence is incomplete.'",
        '$updateReleaseGates = [ordered]@{',
        'updateReleaseGates = $updateReleaseGates',
        '$expectedUpdateSignedDexReviewRequired = $ValidationMode -ceq ''SignedReview''',
        "throw 'Updater raw primary-DEX blocker changed after signed-APK validation state binding.'",
        'generatedD8Fixtures = $dexUpdateFlowFixtureEvidence',
        'signedApk = $dexUpdateFlow',
        'signerCertificateSha256 = [string]$resolution.update.requiredSignerCertificateSha256',
        'metadataDeployed = $false')) {
    if ((Get-PatchletLiteralCount -Text $patchedApkText `
                -Literal $updateSignedApkLiteral) -ne 1) {
        throw "Signed-APK updater proof literal is missing or duplicated: $updateSignedApkLiteral"
    }
}
if ((Get-PatchletLiteralCount -Text $patchedApkText `
            -Literal 'runtimeInstallTested = $false') -ne 2) {
    throw 'Updater release evidence must state the untested runtime-installer boundary in both the static-only installer subresult and final report metadata.'
}
if ((Get-PatchletLiteralCount -Text $patchedApkText `
            -Literal "status = 'passed'") -lt 6 `
        -or (Get-PatchletLiteralCount -Text $patchedApkText `
            -Literal 'authoritative = $true') -lt 6 `
        -or (Get-PatchletLiteralCount -Text $patchedApkText `
            -Literal 'signedDex = $dexUpdateFlow') -ne 5 `
        -or (Get-PatchletLiteralCount -Text $patchedApkText `
            -Literal 'signedApk = $dexUpdateFlow') -ne 1) {
    throw 'Updater release subresults must retain the reviewed authoritative raw primary-DEX topology.'
}
$activityProbeText = Get-NormalizedPatchletText -Path (
    Join-Path $PSScriptRoot 'Test-ActivityUiEmulator.ps1')
$signedReviewModeDeclaration =
    '[ValidateSet(''Release'', ''SignedReview'')][string]$ValidationMode = ''Release'''
foreach ($signedReviewTool in @(
        [pscustomobject]@{ label = 'pipeline'; text = $pipelineText },
        [pscustomobject]@{ label = 'builder'; text = $buildText },
        [pscustomobject]@{ label = 'signed-APK gate'; text = $patchedApkText },
        [pscustomobject]@{ label = 'Activity UI probe'; text = $activityProbeText })) {
    if ((Get-PatchletLiteralCount -Text ([string]$signedReviewTool.text) `
                -Literal $signedReviewModeDeclaration) -ne 1) {
        throw "SignedReview mode declaration is missing or duplicated in $($signedReviewTool.label)."
    }
}
$signedReviewPublishRejectIndex = $pipelineText.IndexOf(
    "throw 'SignedReview mode forbids PublishPath and cannot publish an APK.'",
    [StringComparison]::Ordinal)
$signedReviewRunRootCreateIndex = $pipelineText.IndexOf(
    '[IO.Directory]::CreateDirectory($runRootFull)', [StringComparison]::Ordinal)
$signedReviewReleaseGateIndex = $pipelineText.IndexOf(
    '$currentStage = ''release-gates''', [StringComparison]::Ordinal)
$signedReviewActivityIndex = $pipelineText.IndexOf(
    '$currentStage = ''signed-review-activity-ui''', [StringComparison]::Ordinal)
$signedReviewPreReportIndex = $pipelineText.IndexOf(
    '$currentStage = ''pre-report-input-freeze''', [StringComparison]::Ordinal)
if ((Get-PatchletLiteralCount -Text $pipelineText `
            -Literal '-ValidationMode $ValidationMode') -ne 3 `
        -or $signedReviewPublishRejectIndex -lt 0 `
        -or $signedReviewRunRootCreateIndex -le $signedReviewPublishRejectIndex `
        -or $signedReviewReleaseGateIndex -lt 0 `
        -or $signedReviewActivityIndex -le $signedReviewReleaseGateIndex `
        -or $signedReviewPreReportIndex -le $signedReviewActivityIndex) {
    throw 'SignedReview mode must fail before workspace creation and run signed-APK plus Activity evidence in order.'
}
foreach ($signedReviewPipelineLiteral in @(
        '[string]$ReviewDeviceSerial,',
        "throw 'SignedReview mode requires ReviewDeviceSerial for the exact-primary-DEX Activity UI probe.'",
        "throw 'ReviewDeviceSerial is valid only in SignedReview mode.'",
        '$expectedResolutionStatus = if ($isSignedReview) { ''review-required'' } else { ''verified-current'' }',
        '$expectedUpdateSignedDexReviewRequired = $isSignedReview',
        "throw 'SignedReview Activity UI evidence does not bind the exact signed candidate.'",
        'reviewOnly = $isSignedReview',
        'releaseEligible = -not $isSignedReview',
        "throw 'SignedReview mode cannot enter the publication transaction.'")) {
    if ((Get-PatchletLiteralCount -Text $pipelineText `
                -Literal $signedReviewPipelineLiteral) -ne 1) {
        throw "SignedReview pipeline proof literal is missing or duplicated: $signedReviewPipelineLiteral"
    }
}
foreach ($signedReviewBuildLiteral in @(
        '$workRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot ''work''))',
        '$reviewOutput = Assert-PatchletPathUnderRoot -Path $outputFull -Root $workRoot',
        "throw 'SignedReview output must be a strict child of the workspace work directory.'",
        "throw 'SignedReview mode requires a keystore and may not produce an unsigned review candidate.'",
        "'review-required'",
        "'verified-current'",
        'releaseEligible = $signedResult -and $ValidationMode -ceq ''Release''')) {
    if ((Get-PatchletLiteralCount -Text $buildText `
                -Literal $signedReviewBuildLiteral) -ne 1) {
        throw "SignedReview build proof literal is missing or duplicated: $signedReviewBuildLiteral"
    }
}
foreach ($signedReviewPatchedLiteral in @(
        'throw "Signed-APK validation state does not match ValidationMode ''$ValidationMode''."',
        "throw 'Updater raw primary-DEX blocker changed after signed-APK validation state binding.'",
        'reviewOnly = $ValidationMode -ceq ''SignedReview''',
        'releaseEligible = $ValidationMode -ceq ''Release''')) {
    if ((Get-PatchletLiteralCount -Text $patchedApkText `
                -Literal $signedReviewPatchedLiteral) -ne 1) {
        throw "SignedReview signed-APK proof literal is missing or duplicated: $signedReviewPatchedLiteral"
    }
}
foreach ($signedReviewActivityLiteral in @(
        'throw "Activity UI probe state does not match ValidationMode ''$ValidationMode''."',
        'reviewOnly = $ValidationMode -ceq ''SignedReview''',
        'releaseEligible = $ValidationMode -ceq ''Release''')) {
    if ((Get-PatchletLiteralCount -Text $activityProbeText `
                -Literal $signedReviewActivityLiteral) -ne 1) {
        throw "SignedReview Activity UI proof literal is missing or duplicated: $signedReviewActivityLiteral"
    }
}
$activityUiMatcherLiterals = @(
    '$xmlSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit',
    '$xmlSettings.XmlResolver = $null',
    '$xmlSettings.MaxCharactersInDocument = 1048576L',
    '$xmlSettings.MaxCharactersFromEntities = 0L',
    '$uiDocument.XmlResolver = $null',
    '$node.GetAttribute(''bounds'')',
    '$node.GetAttribute(''text'')',
    '$required + '' '', [StringComparison]::Ordinal',
    '$line.Substring($required.Length).Trim().Length -eq 0',
    '$bounds.left -ge $viewport.right',
    'if ($negativeFixtures.Count -ne 9)',
    "'content-description-only'",
    "'mid-line-prefix'",
    "'wrong-prefix-order'",
    "'missing-prefix'",
    "'malformed-xml'",
    "'zero-bounds'",
    "'offscreen-bounds'",
    "'empty-status-value'",
    "'split-status-nodes'",
    'visibleExactText = $RequiredExactText',
    'visibleOrderedLinePrefixes = $RequiredOrderedLinePrefix',
    'viewportIntersection = $true',
    'nonEmptyStatusValues = $true',
    'matcherFixtures = $matcherFixtureEvidence')
foreach ($activityUiMatcherLiteral in $activityUiMatcherLiterals) {
    if ((Get-PatchletLiteralCount -Text $activityProbeText `
                -Literal $activityUiMatcherLiteral) -ne 1) {
        throw "Activity UI exact-node/ordered-line matcher literal is missing or duplicated: $activityUiMatcherLiteral"
    }
}
if ((Get-PatchletLiteralCount -Text $activityProbeText `
            -Literal '-RequiredExactText @(') -ne 3 `
        -or (Get-PatchletLiteralCount -Text $activityProbeText `
            -Literal '-RequiredOrderedLinePrefix @(') -ne 2 `
        -or (Get-PatchletLiteralCount -Text $activityProbeText `
            -Literal '[Security.SecurityElement]::Escape') -ne 0 `
        -or (Get-PatchletLiteralCount -Text $activityProbeText `
            -Literal '(''text="{0}"'' -f $encodedRequired)') -ne 0) {
    throw 'Activity UI probe must keep fixed labels exact, status labels ordered and line-aware, and reject the retired raw-attribute matcher.'
}
$activityProbeManifestText = Get-NormalizedPatchletText -Path (
    Join-Path $repositoryRoot 'patchlets\assets\release-gates\activity-ui-probe\AndroidManifest.xml')
$dexInspectorText = Get-NormalizedPatchletText -Path (Join-Path $PSScriptRoot 'DexInspector.java')
$dexLiteralCallInspectorText = Get-NormalizedPatchletText -Path (
    Join-Path $PSScriptRoot 'DexLiteralCallInspector.java')
$dexProxyBootstrapFlowInspectorText = Get-NormalizedPatchletText -Path (
    Join-Path $PSScriptRoot 'DexProxyBootstrapFlowInspector.java')
$dexProxyBootstrapFlowFixtureText = Get-NormalizedPatchletText -Path (
    Join-Path $PSScriptRoot 'Test-DexProxyBootstrapFlowInspector.ps1')
$targetedJadxRecoveryText = Get-NormalizedPatchletText -Path (
    Join-Path $PSScriptRoot 'TargetedJadxRecovery.java')
$dexBridgeFlowInspectorText = Get-NormalizedPatchletText -Path (
    Join-Path $PSScriptRoot 'DexBridgeFlowInspector.java')
$dexReportPermalinkFlowInspectorText = Get-NormalizedPatchletText -Path (
    Join-Path $PSScriptRoot 'DexReportPermalinkFlowInspector.java')
$bootstrapAstIndex = $pipelineText.IndexOf('Running pipeline AST differs from the read-locked entry script bytes.', [StringComparison]::Ordinal)
$moduleImportIndex = $pipelineText.IndexOf('Import-Module $moduleEntryPath', [StringComparison]::Ordinal)
$sourceSnapshotIndex = $pipelineText.IndexOf("id = 'source-apk-set-snapshot'", [StringComparison]::Ordinal)
$resolutionSnapshotIndex = $pipelineText.IndexOf("id = 'resolution-snapshot-directory'", [StringComparison]::Ordinal)
$canonicalTreeIndex = $pipelineText.IndexOf("id = 'canonical-patchlets-tree'", [StringComparison]::Ordinal)
$lockIndex = $pipelineText.IndexOf("Enter-PatchletInputFreezeLock -Snapshot `$releaseInputFreeze", [StringComparison]::Ordinal)
$splitContractStageIndex = $pipelineText.IndexOf("`$currentStage = 'split-source-contract-fixtures'", [StringComparison]::Ordinal)
$splitContractInvocationIndex = $pipelineText.IndexOf("'Test-SplitSourceSetContract.ps1'", [StringComparison]::Ordinal)
$universalizationStageIndex = $pipelineText.IndexOf("`$currentStage = 'source-universalization'", [StringComparison]::Ordinal)
$universalizationInvocationIndex = $pipelineText.IndexOf("'Build-SplitSourceUniversalApk.ps1'", [StringComparison]::Ordinal)
$derivedBindingIndex = $pipelineText.IndexOf('Test-PatchletSourceBinding -Resolution $resolution -SourceApk $sourceSnapshotFull', [StringComparison]::Ordinal)
$derivedLockIndex = $pipelineText.IndexOf("-Stage 'derived-source-input-freeze'", [StringComparison]::Ordinal)
$catalogStageIndex = $pipelineText.IndexOf("`$currentStage = 'catalog-check'", [StringComparison]::Ordinal)
$catalogCheckInvocationIndex = $pipelineText.IndexOf("'Test-PatchletCatalog.ps1'", [StringComparison]::Ordinal)
$hostAssetsInvocationIndex = $pipelineText.IndexOf("'Test-HostPatchletAssets.ps1'", [StringComparison]::Ordinal)
$sourceDecodeStageIndex = $pipelineText.IndexOf("`$currentStage = 'source-decode'", [StringComparison]::Ordinal)
$assetRecheckIndex = $pipelineText.IndexOf('Test-PatchletAssets -Resolution $Resolution', [StringComparison]::Ordinal)
$prePublishIndex = $pipelineText.IndexOf("-Stage 'pre-publish'", [StringComparison]::Ordinal)
$postPublishIndex = $pipelineText.IndexOf("-Stage 'post-publish'", [StringComparison]::Ordinal)
$transactionIndex = $pipelineText.IndexOf('Invoke-PatchletPublicationTransaction', [StringComparison]::Ordinal)
$immediatePreMoveIndex = $moduleText.IndexOf("-Stage 'publication-immediate-pre-move'", [StringComparison]::Ordinal)
$publishMoveIndex = $moduleText.IndexOf('Move-Item -LiteralPath $temporary -Destination $publishFull', [StringComparison]::Ordinal)
$publishedHashIndex = $moduleText.IndexOf('Published APK hash differs from the gated output APK.', [StringComparison]::Ordinal)
$modulePostMoveIndex = $moduleText.IndexOf("-Stage 'publication-post-move'", [StringComparison]::Ordinal)
$residueVerificationIndex = $moduleText.IndexOf("PatchletPublicationResiduePaths", [StringComparison]::Ordinal)
$failureResidueIndex = $pipelineText.IndexOf("PatchletPublicationResiduePaths", [StringComparison]::Ordinal)
$decodedResetIndex = $pipelineText.IndexOf("`$currentStage = 'decoded-build-cache-reset'", [StringComparison]::Ordinal)
$decodedFreezeIndex = $pipelineText.IndexOf("kind = 'complete-tree'", [StringComparison]::Ordinal)
$idempotencyIndex = $pipelineText.IndexOf("`$currentStage = 'idempotency-check'", [StringComparison]::Ordinal)
$buildWorkingCopyIndex = $pipelineText.IndexOf('Copy-PatchletCompleteTree', [StringComparison]::Ordinal)
$buildWorkingLockIndex = $pipelineText.IndexOf("-Stage 'build-working-before-apktool'", [StringComparison]::Ordinal)
$signedBuildIndex = $pipelineText.IndexOf("`$currentStage = 'signed-build'", [StringComparison]::Ordinal)
$buildWorkingArgumentIndex = $pipelineText.IndexOf('-DecodedRoot $buildWorkingRoot', [StringComparison]::Ordinal)
$buildWorkingExpectedDigestIndex = $pipelineText.IndexOf('-ExpectedDecodedTreeSha256', [StringComparison]::Ordinal)
$candidateLockIndex = $pipelineText.IndexOf("-Stage 'signed-candidate-before-release-gates'", [StringComparison]::Ordinal)
$buildWorkingRestoreIndex = $pipelineText.IndexOf("`$currentStage = 'build-working-restore'", [StringComparison]::Ordinal)
$buildWorkingRestoredFreezeIndex = $pipelineText.IndexOf("-Stage 'build-working-after-cleanup'", [StringComparison]::Ordinal)
$releaseGatesIndex = $pipelineText.IndexOf("`$currentStage = 'release-gates'", [StringComparison]::Ordinal)
$finalConfinementIndex = $pipelineText.IndexOf('$finalArtifactFull = Assert-PatchletPathUnderRoot', [StringComparison]::Ordinal)
$publishCommittedIndex = $pipelineText.IndexOf('$publishCommitted = $true', [StringComparison]::Ordinal)
$outerRollbackIndex = $pipelineText.IndexOf('Remove-PatchletOwnedPublication', [StringComparison]::Ordinal)
$basenameGuardIndex = $buildText.IndexOf('Assert-PatchletArtifactBaseName', [StringComparison]::Ordinal)
$buildDecodedBindingIndex = $buildText.IndexOf('Build decoded-tree input does not match the bound complete idempotency inventory.', [StringComparison]::Ordinal)
$completeTreeCopyIndex = $moduleText.IndexOf('function Copy-PatchletCompleteTree', [StringComparison]::Ordinal)
$exactFileMutationIndex = $moduleText.IndexOf('Allowed file mutation paths differ from the lock-time configuration', [StringComparison]::Ordinal)
$structuralMonitorIndex = $moduleText.IndexOf('ThreadsModPatchletTreeMonitorV2', [StringComparison]::Ordinal)
$derivedWorkCopyEvidenceIndex = $pipelineText.IndexOf('derivedWorkCopy = $derivedWorkCopyEvidence', [StringComparison]::Ordinal)
$canonicalFailureEvidenceIndex = $pipelineText.IndexOf('canonicalDecoded = [ordered]@{', [StringComparison]::Ordinal)
$canonicalFreezeEvidenceIndex = $pipelineText.IndexOf('freezeMatches = $canonicalDecodedFreezeMatches', [StringComparison]::Ordinal)
$failureLockAssertionIndex = $pipelineText.IndexOf("-Stage 'failure-evidence'", [StringComparison]::Ordinal)
$readableFailureHashIndex = $pipelineText.IndexOf('readableSha256 = $sha256', [StringComparison]::Ordinal)
$manifestFailureHashIndex = $pipelineText.IndexOf('manifestOriginal = Get-PipelineReadableFileFailureEvidence', [StringComparison]::Ordinal)
$buildCacheFailureEvidenceIndex = $pipelineText.IndexOf('buildCache = Get-PipelineCompleteTreeFailureEvidence', [StringComparison]::Ordinal)
$unsignedLockIndex = $buildText.IndexOf('$unsignedLock = [IO.File]::Open(', [StringComparison]::Ordinal)
$alignedLockIndex = $buildText.IndexOf('$alignedLock = [IO.File]::Open(', [StringComparison]::Ordinal)
$signedLockIndex = $buildText.IndexOf('$signedLock = [IO.File]::Open(', [StringComparison]::Ordinal)
$candidateSelfLockIndex = $patchedApkText.IndexOf('$candidateArtifactLock = [IO.File]::Open(', [StringComparison]::Ordinal)
$candidateInventoryIndex = $patchedApkText.IndexOf('Test-PatchletZipInventory -Path $apkFull', [StringComparison]::Ordinal)
$dexDuplicateIndex = $dexInspectorText.IndexOf('duplicate DEX ZIP entry name', [StringComparison]::Ordinal)
$exactDexNamesIndex = $dexInspectorText.IndexOf('root DEX inventory differs from exact expected names', [StringComparison]::Ordinal)
$dexLiteralInvocationIndex = $patchedApkText.IndexOf("'DexLiteralCallInspector'", [StringComparison]::Ordinal)
$dexLiteralReportIndex = $patchedApkText.IndexOf('dexDirectStringCalls = $dexDirectStringCalls', [StringComparison]::Ordinal)
$dexLiteralImmediateFlowIndex = $dexLiteralCallInspectorText.IndexOf(
    'isLiteralLoad(previous, registers[argumentWord], literal)', [StringComparison]::Ordinal)
$dexLiteralOnlyCallIndex = $dexLiteralCallInspectorText.IndexOf(
    'targetCallCount != expectedCount || matchedCount != expectedCount', [StringComparison]::Ordinal)
$dexBridgeFlowInvocationIndex = $patchedApkText.IndexOf("'DexBridgeFlowInspector'", [StringComparison]::Ordinal)
$dexReportPermalinkFlowInvocationIndex = $patchedApkText.IndexOf(
    "'DexReportPermalinkFlowInspector'", [StringComparison]::Ordinal)
$dexReportPermalinkFlowFixtureInvocationIndex = $patchedApkText.IndexOf(
    "'Test-DexReportPermalinkFlowInspector.ps1'", [StringComparison]::Ordinal)
$dexBridgeFlowReportIndex = $patchedApkText.IndexOf('dexBridgeFlows = $dexBridgeFlows', [StringComparison]::Ordinal)
$dexBridgeFixtureDeclarationIndex = $patchedApkText.IndexOf(
    "'Test-DexBridgeFlowInspector.ps1'", [StringComparison]::Ordinal)
$dexBridgeFixtureHashIndex = $patchedApkText.IndexOf(
    'dexBridgeFlowFixtureTreeSha256', [StringComparison]::Ordinal)
$dexBridgeFixtureInvocationIndex = $patchedApkText.IndexOf(
    '$dexBridgeFlowFixtureResult = & $dexBridgeFlowFixtureTest', [StringComparison]::Ordinal)
$dexBridgeFixtureReportIndex = $patchedApkText.IndexOf(
    'dexBridgeFlowFixtures = $dexBridgeFlowFixtureEvidence', [StringComparison]::Ordinal)
$dexBridgeAutomaticCallerIndex = $patchedApkText.IndexOf(
    '[string]$contract.automaticCallerClassDescriptor', [StringComparison]::Ordinal)
$dexBridgeManualCallerIndex = $patchedApkText.IndexOf(
    '[string]$contract.manualCallerClassDescriptor', [StringComparison]::Ordinal)
$dexBridgeFetchWorkerReferenceIndex = $patchedApkText.IndexOf(
    '[string]$contract.fetchWorkerRunMethodReference', $dexBridgeManualCallerIndex,
    [StringComparison]::Ordinal)
$dexBridgeScheduleDrainReferenceIndex = $patchedApkText.IndexOf(
    '[string]$contract.scheduleManualDrainMethodReference', $dexBridgeFetchWorkerReferenceIndex,
    [StringComparison]::Ordinal)
$dexBridgeCallerRequirementIndex = $patchedApkText.IndexOf(
    '$contract.requireCallerProvenance', [StringComparison]::Ordinal)
$dexBridgeCatchRequirementIndex = $patchedApkText.IndexOf(
    '$contract.requireCallerCatchTopology', [StringComparison]::Ordinal)
$dexBridgeDirectCallbackRequirementIndex = $patchedApkText.IndexOf(
    '$contract.requireDirectCallerCallbackExecution', [StringComparison]::Ordinal)
$dexBridgeCallbackEffectRequirementIndex = $patchedApkText.IndexOf(
    '$contract.requireCallerCallbackEffectTopology', [StringComparison]::Ordinal)
$dexBridgeExceptionalCfgRequirementIndex = $patchedApkText.IndexOf(
    '$contract.requireCallbackExceptionalControlFlow', [StringComparison]::Ordinal)
$dexBridgeEntryRequirementIndex = $patchedApkText.IndexOf(
    '$contract.requireBridgeEntryReachability', [StringComparison]::Ordinal)
$dexBridgeSchedulerEnqueueRequirementIndex = $patchedApkText.IndexOf(
    '$contract.requireSchedulerEnqueueAcceptance', [StringComparison]::Ordinal)
$dexBridgeUncertainQuarantineRequirementIndex = $patchedApkText.IndexOf(
    '$contract.requireUncertainMutationQuarantine', [StringComparison]::Ordinal)
$dexBridgePrivateRequirementIndex = $patchedApkText.IndexOf(
    '$contract.requirePrivateSeamCallProvenance', [StringComparison]::Ordinal)
$dexBridgeDispatcherRequirementIndex = $patchedApkText.IndexOf(
    '$contract.requireDispatcherCallProvenance', [StringComparison]::Ordinal)
$dexBridgeCallerCheckIndex = $patchedApkText.IndexOf(
    '$bridgeResult.checks.callerProvenance', [StringComparison]::Ordinal)
$dexBridgeCallerCatchIndex = $patchedApkText.IndexOf(
    '$bridgeResult.callerCatchTopology.automatic.bridgeMethodCount', [StringComparison]::Ordinal)
$dexBridgeCallerHandoffIndex = $patchedApkText.IndexOf(
    '$bridgeResult.callerCatchTopology.automatic.handoffCalls', [StringComparison]::Ordinal)
$dexBridgeCallerHandlerIndex = $patchedApkText.IndexOf(
    '$bridgeResult.callerCatchTopology.manual.handlerLiteralRoutes', [StringComparison]::Ordinal)
$dexBridgeCallerCallbackIndex = $patchedApkText.IndexOf(
    '$bridgeResult.callerCallbackExecution.automatic.immediateRunnableDispatches', [StringComparison]::Ordinal)
$dexBridgeCallbackEffectIndex = $patchedApkText.IndexOf(
    '$bridgeResult.callerCallbackEffectTopology.automatic.startedLatchWrites', [StringComparison]::Ordinal)
$dexBridgeCallbackEffectWaitingClearIndex = $patchedApkText.IndexOf(
    '$bridgeResult.callerCallbackEffectTopology.automatic.waitingClearWrites', [StringComparison]::Ordinal)
$dexBridgeCallbackEffectReviewedTerminalIndex = $patchedApkText.IndexOf(
    '$bridgeResult.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes', [StringComparison]::Ordinal)
$dexBridgeCallbackEffectTerminalCatchIndex = $patchedApkText.IndexOf(
    '$bridgeResult.callerCallbackEffectTopology.automatic.terminalCatchRoutes', [StringComparison]::Ordinal)
$dexBridgeCallbackEffectReleaseIndex = $patchedApkText.IndexOf(
    '$bridgeResult.callerCallbackEffectTopology.manual.schedulerReleaseCalls', [StringComparison]::Ordinal)
$dexBridgeCallerCatchCheckIndex = $patchedApkText.IndexOf(
    '$bridgeResult.checks.callerCatchTopology', [StringComparison]::Ordinal)
$dexBridgeCallerCallbackCheckIndex = $patchedApkText.IndexOf(
    '$bridgeResult.checks.directCallerCallbackExecution', [StringComparison]::Ordinal)
$dexBridgeCallbackEffectCheckIndex = $patchedApkText.IndexOf(
    '$bridgeResult.checks.callerCallbackEffectTopology', [StringComparison]::Ordinal)
$dexBridgeExceptionalCfgCheckIndex = $patchedApkText.IndexOf(
    '$bridgeResult.checks.callbackExceptionalControlFlow', [StringComparison]::Ordinal)
$dexBridgeEntryCheckIndex = $patchedApkText.IndexOf(
    '$bridgeResult.checks.bridgeEntryReachability', [StringComparison]::Ordinal)
$dexBridgeSchedulerEnqueueCheckIndex = $patchedApkText.IndexOf(
    '$bridgeResult.checks.schedulerEnqueueAcceptance', [StringComparison]::Ordinal)
$dexBridgeUncertainQuarantineCheckIndex = $patchedApkText.IndexOf(
    '$bridgeResult.checks.uncertainMutationQuarantine', [StringComparison]::Ordinal)
$dexBridgePrivateSeamIndex = $patchedApkText.IndexOf(
    '$bridgeResult.privateSeamProvenance.cacheLookup', [StringComparison]::Ordinal)
$dexBridgePrivateMutationIndex = $patchedApkText.IndexOf(
    '$bridgeResult.privateSeamProvenance.nativeMutation', [StringComparison]::Ordinal)
$dexBridgePrivateCheckIndex = $patchedApkText.IndexOf(
    '$bridgeResult.checks.privateSeamCallProvenance', [StringComparison]::Ordinal)
$dexBridgeDispatcherBridgeIndex = $patchedApkText.IndexOf(
    '$bridgeResult.dispatcherCallProvenance.bridge.failure', [StringComparison]::Ordinal)
$dexBridgeDispatcherOtherIndex = $patchedApkText.IndexOf(
    '$bridgeResult.dispatcherCallProvenance.other.success', [StringComparison]::Ordinal)
$dexBridgeDispatcherDeliveryIndex = $patchedApkText.IndexOf(
    '$bridgeResult.dispatcherCallProvenance.deliveryConstructor', [StringComparison]::Ordinal)
$dexBridgeDispatcherCheckIndex = $patchedApkText.IndexOf(
    '$bridgeResult.checks.dispatcherCallProvenance', [StringComparison]::Ordinal)
$dexBridgeCallbackInterfaceIndex = $patchedApkText.IndexOf(
    '$bridgeResult.mutationCallbackInterface', [StringComparison]::Ordinal)
$dexBridgeInspectorArgumentIndex = $dexBridgeFlowInspectorText.IndexOf(
    "args.length != $([int]$resolutionForContract.release.expectedDexBridgeFlowInspectorArgumentCount)",
    [StringComparison]::Ordinal)
$dexBridgeInspectorProvenanceIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"callerProvenance\":true', [StringComparison]::Ordinal)
$dexBridgeInspectorCallerCatchIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"callerCatchTopology\":true', [StringComparison]::Ordinal)
$dexBridgeInspectorCallerCallbackIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"directCallerCallbackExecution\":true', [StringComparison]::Ordinal)
$dexBridgeInspectorCallbackEffectIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"callerCallbackEffectTopology\":true', [StringComparison]::Ordinal)
$dexBridgeInspectorExceptionalCfgIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"callbackExceptionalControlFlow\":true', [StringComparison]::Ordinal)
$dexBridgeInspectorEntryIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"bridgeEntryReachability\":true', [StringComparison]::Ordinal)
$dexBridgeInspectorSchedulerEnqueueIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"schedulerEnqueueAcceptance\":true', [StringComparison]::Ordinal)
$dexBridgeInspectorUncertainQuarantineIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"uncertainMutationQuarantine\":true', [StringComparison]::Ordinal)
$dexBridgeInspectorWaitingClearIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"waitingClearWrites\":', [StringComparison]::Ordinal)
$dexBridgeInspectorReviewedTerminalIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"reviewedTerminalRoutes\":', [StringComparison]::Ordinal)
$dexBridgeInspectorTerminalCatchIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"terminalCatchRoutes\":', [StringComparison]::Ordinal)
$dexBridgeInspectorPrivateSeamIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"privateSeamCallProvenance\":true', [StringComparison]::Ordinal)
$dexBridgeInspectorDispatcherIndex = $dexBridgeFlowInspectorText.IndexOf(
    '\"dispatcherCallProvenance\":true', [StringComparison]::Ordinal)
$dexBridgeInspectorHandlerPostIndex = $dexBridgeFlowInspectorText.IndexOf(
    'dispatcher_handler_post_count', [StringComparison]::Ordinal)
$dexReportPermalinkInspectorArgumentIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    "args.length != $([int]$resolutionForContract.release.expectedDexReportPermalinkFlowInspectorArgumentCount)",
    [StringComparison]::Ordinal)
$dexReportPermalinkFactoryFlowIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'factory_permalink_flow', [StringComparison]::Ordinal)
$dexReportPermalinkRequestFlowIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'request_permalink_storage_flow', [StringComparison]::Ordinal)
$dexReportPermalinkValidityFlowIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'request_new_queue_validity_flow', [StringComparison]::Ordinal)
$dexReportPermalinkPayloadTargetFlowIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'payload_target_url_flow', [StringComparison]::Ordinal)
$dexReportPermalinkPayloadEvidenceFlowIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'payload_evidence_flow', [StringComparison]::Ordinal)
$dexReportPermalinkFieldImmutableIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'request_permalink_field_immutable', [StringComparison]::Ordinal)
$dexReportPermalinkFieldWriteCountIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'request_permalink_field_write_count', [StringComparison]::Ordinal)
$dexReportPermalinkArrayConstructorIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'payload_evidence_array_constructor_flow', [StringComparison]::Ordinal)
$dexReportPermalinkArrayUseIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'payload_evidence_array_use_flow', [StringComparison]::Ordinal)
$dexReportPermalinkControllerGuardIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'controller_new_queue_validity_guard_flow', [StringComparison]::Ordinal)
$dexReportPermalinkClientGuardIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'client_new_queue_validity_guard_flow', [StringComparison]::Ordinal)
$dexReportPermalinkRowModifierFlowIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'row_ufi_modifier_flow', [StringComparison]::Ordinal)
$dexReportPermalinkRowDefaultMaskIndex = $dexReportPermalinkFlowInspectorText.IndexOf(
    'row_ufi_default_mask_literal', [StringComparison]::Ordinal)
$jadxOrderedContractIndex = $patchedApkText.IndexOf(
    "PSObject.Properties['orderedStrings']", [StringComparison]::Ordinal)
$jadxForbiddenContractIndex = $patchedApkText.IndexOf(
    "PSObject.Properties['forbiddenStrings']", [StringComparison]::Ordinal)
$jadxForbiddenFailureIndex = $patchedApkText.IndexOf(
    'contains forbidden text', [StringComparison]::Ordinal)
$jadxForbiddenEvidenceIndex = $patchedApkText.IndexOf(
    'forbiddenStrings = $forbiddenStrings', [StringComparison]::Ordinal)
$jadxExactCountContractIndex = $patchedApkText.IndexOf(
    "PSObject.Properties['exactStringCounts']", [StringComparison]::Ordinal)
$jadxExactCountFailureIndex = $patchedApkText.IndexOf(
    'occurrences of', [StringComparison]::Ordinal)
$jadxExactCountEvidenceIndex = $patchedApkText.IndexOf(
    'exactStringCounts = $exactStringCounts', [StringComparison]::Ordinal)
if ((Get-PatchletLiteralCount -Text $targetedJadxRecoveryText `
            -Literal 'jadxArgs.setShowInconsistentCode(true);') -ne 1 `
        -or $targetedJadxRecoveryText.Contains(
            'jadxArgs.setShowInconsistentCode(false);', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $dexProxyBootstrapFlowInspectorText `
            -Literal ("args.length != {0}" -f (
                    [int]$resolutionForContract.release.expectedDexProxyBootstrapFlowInspectorArgumentCount))) -ne 1 `
        -or -not $dexProxyBootstrapFlowInspectorText.Contains(
            'socks5-bootstrap-signed-dex-flow-contract', [StringComparison]::Ordinal) `
        -or -not $dexProxyBootstrapFlowInspectorText.Contains(
            'globalBootstrapCalls == 1', [StringComparison]::Ordinal) `
        -or -not $dexProxyBootstrapFlowInspectorText.Contains(
            'entry_this_move', [StringComparison]::Ordinal) `
        -or -not $dexProxyBootstrapFlowInspectorText.Contains(
            'entry_context_move', [StringComparison]::Ordinal) `
        -or -not $dexProxyBootstrapFlowInspectorText.Contains(
            'bootstrap_not_adjacent', [StringComparison]::Ordinal) `
        -or -not $dexProxyBootstrapFlowInspectorText.Contains(
            'bootstrap_alternate_entry', [StringComparison]::Ordinal) `
        -or -not $dexProxyBootstrapFlowInspectorText.Contains(
            'bootstrap_try_coverage', [StringComparison]::Ordinal) `
        -or -not $dexProxyBootstrapFlowInspectorText.Contains(
            'original_anchor_not_adjacent', [StringComparison]::Ordinal) `
        -or -not $dexProxyBootstrapFlowInspectorText.Contains(
            'bootstrap_fallback_reference', [StringComparison]::Ordinal) `
        -or -not $patchedApkText.Contains(
            "'DexProxyBootstrapFlowInspector'", [StringComparison]::Ordinal) `
        -or -not $patchedApkText.Contains(
            '$dexProxyBootstrapFlowFixtureResult = & $dexProxyBootstrapFlowFixtureTest',
            [StringComparison]::Ordinal) `
        -or -not $patchedApkText.Contains(
            'dexProxyBootstrapFlow = $dexProxyBootstrapFlow', [StringComparison]::Ordinal) `
        -or -not $dexProxyBootstrapFlowFixtureText.Contains(
            'expectedDexProxyBootstrapFlowFixtureCount', [StringComparison]::Ordinal)) {
    throw 'The reviewed JADX recovery and raw signed-DEX proxy-bootstrap flow contract are incomplete.'
}
$proxyBootstrapContract = $resolutionForContract.release.requiredDexProxyBootstrapFlow
$proxyBootstrapFieldReference = [string]$proxyBootstrapContract.originalNextFieldReference
$proxyBootstrapFieldMatch = [regex]::Match(
    $proxyBootstrapFieldReference,
    '^(?<owner>L[A-Za-z0-9_/$]+;)->(?<name>[A-Za-z0-9_$<>]+):(?<type>L[A-Za-z0-9_/$]+;|[ZBSCIJFD])$',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant)
if (-not $proxyBootstrapFieldMatch.Success) {
    throw 'Proxy-bootstrap original field reference is not an exact DEX field reference.'
}
$proxyBootstrapLayoutBranchPattern = '(?s)if\s*\("' +
    [regex]::Escape([string]$proxyBootstrapContract.expectedDexName) +
    '"\.equals\(expectedDex\)\)\s*\{(?<body>.*?)\r?\n\s*\}'
$proxyBootstrapLayoutBranches = @([regex]::Matches(
        $dexProxyBootstrapFlowInspectorText,
        $proxyBootstrapLayoutBranchPattern,
        [Text.RegularExpressions.RegexOptions]::CultureInvariant))
$proxyBootstrapFieldTuple = '"' + $proxyBootstrapFieldMatch.Groups['owner'].Value +
    '", "' + $proxyBootstrapFieldMatch.Groups['name'].Value + '", "' +
    $proxyBootstrapFieldMatch.Groups['type'].Value + '"'
if ($proxyBootstrapLayoutBranches.Count -ne 1 `
        -or (Get-PatchletLiteralCount -Text $proxyBootstrapLayoutBranches[0].Groups['body'].Value `
            -Literal $proxyBootstrapFieldTuple) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $dexProxyBootstrapFlowInspectorText `
            -Literal 'return fieldOwner + "->" + fieldName + ":" + fieldType;') -ne 1) {
    throw 'Proxy-bootstrap inspector source does not reconstruct the resolution field in its exact DEX layout branch.'
}
foreach ($proxyBootstrapMetadataLiteral in @($proxyBootstrapContract.forbiddenMethodReferences) `
        + @($proxyBootstrapContract.forbiddenStringLiterals)) {
    if (-not $dexProxyBootstrapFlowInspectorText.Contains(
            [string]$proxyBootstrapMetadataLiteral, [StringComparison]::Ordinal)) {
        throw "Proxy-bootstrap inspector source diverges from resolution literal '$proxyBootstrapMetadataLiteral'."
    }
}
if (-not $activityProbeText.Contains(
        'Activity probe primary DEX does not exactly equal the candidate primary DEX.',
        [StringComparison]::Ordinal) `
        -or -not $activityProbeText.Contains("'uiautomator', 'dump'", [StringComparison]::Ordinal) `
        -or -not $activityProbeText.Contains("'uninstall', `$package", [StringComparison]::Ordinal) `
        -or -not $activityProbeText.Contains('networkOrAccountActionAttempted = $false', [StringComparison]::Ordinal) `
        -or -not $activityProbeText.Contains(
            "-Activity 'com.threadsmod.ProxySettingsActivity'", [StringComparison]::Ordinal) `
        -or -not $activityProbeText.Contains(
            "-RequiredExactText @(`n            'SOCKS5 proxy', 'Proxy status', 'Route this app through SOCKS5')",
            [StringComparison]::Ordinal) `
        -or -not $activityProbeText.Contains(
            'activities = @($activityResult, $settingsResult, $proxySettingsResult)',
            [StringComparison]::Ordinal) `
        -or -not $activityProbeManifestText.Contains(
            'android:name="com.threadsmod.ProxySettingsActivity"',
            [StringComparison]::Ordinal) `
        -or $activityProbeManifestText.Contains('<uses-permission', [StringComparison]::OrdinalIgnoreCase) `
        -or $activityProbeManifestText.Contains('<service', [StringComparison]::OrdinalIgnoreCase) `
        -or $activityProbeManifestText.Contains('<receiver', [StringComparison]::OrdinalIgnoreCase) `
        -or $activityProbeManifestText.Contains('<provider', [StringComparison]::OrdinalIgnoreCase) `
        -or (Get-PatchletLiteralCount -Text $activityProbeManifestText `
            -Literal 'android:exported="true"') -ne 3) {
    throw 'The exact-Dex Activity emulator probe is not isolated, UI-visible, or cleanup-bounded.'
}
if (-not $splitUniversalizationText.Contains(
        "'m', '-i', `$InputDirectory, '-o', `$OutputApk,", [StringComparison]::Ordinal) `
        -or -not $splitUniversalizationText.Contains(
            "'-clean-meta', '-validate-modules', '-extractNativeLibs', 'false'", [StringComparison]::Ordinal) `
        -or $splitUniversalizationText.Contains("'-f'", [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $splitUniversalizationText `
            -Literal 'Invoke-ExactApkEditorMerge -Java $Java') -ne 2 `
        -or -not $splitUniversalizationText.Contains(
            'Independent APKEditor merges were not byte-identical.', [StringComparison]::Ordinal) `
        -or -not $splitUniversalizationText.Contains(
            'Derived standalone APK hash differs from the exact resolution.', [StringComparison]::Ordinal) `
        -or -not $splitUniversalizationText.Contains(
            "Get-ZipEntryDigestMap -Path `$basePath -Kind 'root-dex'", [StringComparison]::Ordinal) `
        -or -not $splitUniversalizationText.Contains(
            "Get-ZipEntryDigestMap -Path `$abiPath -Kind 'native-library'", [StringComparison]::Ordinal) `
        -or -not $splitUniversalizationText.Contains(
            "Get-ZipEntryDigestMap -Path `$densityPath -Kind 'density-resource'", [StringComparison]::Ordinal) `
        -or -not $splitUniversalizationText.Contains(
            'Derived APK unexpectedly verifies as signed.', [StringComparison]::Ordinal) `
        -or -not $splitSourceContractText.Contains(
            "if (`$negative.Count -ne 10)", [StringComparison]::Ordinal) `
        -or -not $splitSourceContractText.Contains(
            "if (`$toolNegative.Count -ne 6)", [StringComparison]::Ordinal)) {
    throw 'Split-source universalization tool or its focused negative fixture contract drifted.'
}
$proxySignedGateIds = @(
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
    'proxy-settings-activity-contract'
)
foreach ($proxySignedGateId in $proxySignedGateIds) {
    if ((Get-PatchletLiteralCount -Text $patchedApkText `
                -Literal ("'{0}' =" -f $proxySignedGateId)) -ne 1) {
        throw "Signed-APK SOCKS5 gate is not executable exactly once: $proxySignedGateId"
    }
}
foreach ($proxySignedGateLiteral in @(
        'Get-AaptXmlElementBlock',
        'android:foregroundServiceType[^\n]*=0x40000000',
        'TProxyStartService',
        'hev_socks5_tunnel_main_from_str',
        'assets/threadsmod/licenses/hev-socks5-tunnel-and-lwip.txt',
        'proxyReleaseGates = $proxyReleaseGates')) {
    if (-not $patchedApkText.Contains(
            $proxySignedGateLiteral, [StringComparison]::Ordinal)) {
        throw "Signed-APK SOCKS5 release evidence is missing '$proxySignedGateLiteral'."
    }
}
if ($bootstrapAstIndex -lt 0 `
        -or $moduleImportIndex -le $bootstrapAstIndex `
        -or $sourceSnapshotIndex -lt 0 `
        -or $resolutionSnapshotIndex -lt 0 `
        -or $canonicalTreeIndex -lt 0 `
        -or $lockIndex -lt 0 `
        -or $splitContractStageIndex -le $lockIndex `
        -or $splitContractInvocationIndex -le $splitContractStageIndex `
        -or $universalizationStageIndex -le $splitContractInvocationIndex `
        -or $universalizationInvocationIndex -le $universalizationStageIndex `
        -or $derivedBindingIndex -le $universalizationInvocationIndex `
        -or $derivedLockIndex -le $derivedBindingIndex `
        -or $catalogStageIndex -lt 0 `
        -or $derivedLockIndex -ge $catalogStageIndex `
        -or $catalogCheckInvocationIndex -le $catalogStageIndex `
        -or $hostAssetsInvocationIndex -le $catalogCheckInvocationIndex `
        -or $sourceDecodeStageIndex -le $hostAssetsInvocationIndex `
        -or $assetRecheckIndex -lt 0 `
        -or $assetRecheckIndex -ge $prePublishIndex `
        -or $prePublishIndex -lt 0 `
        -or $postPublishIndex -le $prePublishIndex `
        -or $transactionIndex -lt 0 `
        -or $immediatePreMoveIndex -lt 0 `
        -or $publishMoveIndex -lt 0 `
        -or $immediatePreMoveIndex -ge $publishMoveIndex `
        -or $publishedHashIndex -le $publishMoveIndex `
        -or $modulePostMoveIndex -le $publishedHashIndex `
        -or $residueVerificationIndex -le $modulePostMoveIndex `
        -or $failureResidueIndex -lt 0 `
        -or $decodedResetIndex -lt 0 `
        -or $decodedFreezeIndex -le $decodedResetIndex `
        -or $idempotencyIndex -le $decodedFreezeIndex `
        -or $buildWorkingCopyIndex -le $idempotencyIndex `
        -or $buildWorkingLockIndex -le $buildWorkingCopyIndex `
        -or $signedBuildIndex -le $buildWorkingLockIndex `
        -or $buildWorkingArgumentIndex -le $signedBuildIndex `
        -or $buildWorkingExpectedDigestIndex -le $buildWorkingArgumentIndex `
        -or $finalConfinementIndex -le $signedBuildIndex `
        -or $candidateLockIndex -le $finalConfinementIndex `
        -or $buildWorkingRestoreIndex -le $candidateLockIndex `
        -or $buildWorkingRestoredFreezeIndex -le $buildWorkingRestoreIndex `
        -or $releaseGatesIndex -le $buildWorkingRestoredFreezeIndex `
        -or $publishCommittedIndex -le $transactionIndex `
        -or $outerRollbackIndex -le $publishCommittedIndex `
        -or $basenameGuardIndex -lt 0 `
        -or $buildDecodedBindingIndex -lt 0 `
        -or $buildDecodedBindingIndex -ge $basenameGuardIndex `
        -or $completeTreeCopyIndex -lt 0 `
        -or $exactFileMutationIndex -le $completeTreeCopyIndex `
        -or $structuralMonitorIndex -lt 0 `
        -or $derivedWorkCopyEvidenceIndex -lt 0 `
        -or $canonicalFailureEvidenceIndex -lt 0 `
        -or $canonicalFreezeEvidenceIndex -lt 0 `
        -or $failureLockAssertionIndex -lt 0 `
        -or $readableFailureHashIndex -lt 0 `
        -or $manifestFailureHashIndex -lt 0 `
        -or $buildCacheFailureEvidenceIndex -lt 0 `
        -or $unsignedLockIndex -le $basenameGuardIndex `
        -or $alignedLockIndex -le $unsignedLockIndex `
        -or $signedLockIndex -le $alignedLockIndex `
        -or $candidateSelfLockIndex -lt 0 `
        -or $candidateInventoryIndex -le $candidateSelfLockIndex `
        -or $dexDuplicateIndex -lt 0 `
        -or $exactDexNamesIndex -le $dexDuplicateIndex `
        -or $dexLiteralInvocationIndex -lt 0 `
        -or $dexLiteralReportIndex -le $dexLiteralInvocationIndex `
        -or $dexLiteralImmediateFlowIndex -lt 0 `
        -or $dexLiteralOnlyCallIndex -le $dexLiteralImmediateFlowIndex `
        -or $dexBridgeFlowInvocationIndex -lt 0 `
        -or $dexBridgeFlowReportIndex -le $dexBridgeFlowInvocationIndex `
        -or $dexBridgeFixtureDeclarationIndex -lt 0 `
        -or $dexBridgeFixtureHashIndex -le $dexBridgeFixtureDeclarationIndex `
        -or $dexBridgeFixtureInvocationIndex -le $dexBridgeFixtureHashIndex `
        -or $dexBridgeFixtureReportIndex -le $dexBridgeFixtureInvocationIndex `
        -or $dexBridgeAutomaticCallerIndex -le $dexBridgeFlowInvocationIndex `
        -or $dexBridgeManualCallerIndex -le $dexBridgeAutomaticCallerIndex `
        -or $dexBridgeFetchWorkerReferenceIndex -le $dexBridgeManualCallerIndex `
        -or $dexBridgeScheduleDrainReferenceIndex -le $dexBridgeFetchWorkerReferenceIndex `
        -or $dexBridgeCallerRequirementIndex -lt 0 `
        -or $dexBridgeCatchRequirementIndex -le $dexBridgeCallerRequirementIndex `
        -or $dexBridgeDirectCallbackRequirementIndex -le $dexBridgeCatchRequirementIndex `
        -or $dexBridgeCallbackEffectRequirementIndex -le $dexBridgeDirectCallbackRequirementIndex `
        -or $dexBridgeExceptionalCfgRequirementIndex -le $dexBridgeCallbackEffectRequirementIndex `
        -or $dexBridgeEntryRequirementIndex -le $dexBridgeExceptionalCfgRequirementIndex `
        -or $dexBridgeSchedulerEnqueueRequirementIndex -le $dexBridgeEntryRequirementIndex `
        -or $dexBridgeUncertainQuarantineRequirementIndex -le $dexBridgeSchedulerEnqueueRequirementIndex `
        -or $dexBridgePrivateRequirementIndex -le $dexBridgeUncertainQuarantineRequirementIndex `
        -or $dexBridgeDispatcherRequirementIndex -le $dexBridgePrivateRequirementIndex `
        -or $dexBridgeCallerCatchIndex -le $dexBridgeManualCallerIndex `
        -or $dexBridgeCallerHandoffIndex -le $dexBridgeCallerCatchIndex `
        -or $dexBridgeCallerHandlerIndex -le $dexBridgeCallerHandoffIndex `
        -or $dexBridgeCallerCallbackIndex -le $dexBridgeCallerHandlerIndex `
        -or $dexBridgeCallbackEffectIndex -le $dexBridgeCallerCallbackIndex `
        -or $dexBridgeCallbackEffectWaitingClearIndex -le $dexBridgeCallbackEffectIndex `
        -or $dexBridgeCallbackEffectReviewedTerminalIndex -le $dexBridgeFlowInvocationIndex `
        -or $dexBridgeCallbackEffectReviewedTerminalIndex -ge $dexBridgeCallbackEffectIndex `
        -or $dexBridgeCallbackEffectTerminalCatchIndex -le $dexBridgeCallbackEffectWaitingClearIndex `
        -or $dexBridgeCallbackEffectReleaseIndex -le $dexBridgeCallbackEffectTerminalCatchIndex `
        -or $dexBridgePrivateSeamIndex -le $dexBridgeCallbackEffectReleaseIndex `
        -or $dexBridgePrivateMutationIndex -le $dexBridgePrivateSeamIndex `
        -or $dexBridgeDispatcherBridgeIndex -le $dexBridgePrivateMutationIndex `
        -or $dexBridgeDispatcherOtherIndex -le $dexBridgeDispatcherBridgeIndex `
        -or $dexBridgeDispatcherDeliveryIndex -le $dexBridgeDispatcherOtherIndex `
        -or $dexBridgeCallerCheckIndex -le $dexBridgeDispatcherDeliveryIndex `
        -or $dexBridgeCallerCatchCheckIndex -le $dexBridgeCallerCheckIndex `
        -or $dexBridgeCallerCallbackCheckIndex -le $dexBridgeCallerCatchCheckIndex `
        -or $dexBridgeCallbackEffectCheckIndex -le $dexBridgeCallerCallbackCheckIndex `
        -or $dexBridgeExceptionalCfgCheckIndex -le $dexBridgeCallbackEffectCheckIndex `
        -or $dexBridgeEntryCheckIndex -le $dexBridgeExceptionalCfgCheckIndex `
        -or $dexBridgeSchedulerEnqueueCheckIndex -le $dexBridgeEntryCheckIndex `
        -or $dexBridgeUncertainQuarantineCheckIndex -le $dexBridgeSchedulerEnqueueCheckIndex `
        -or $dexBridgePrivateCheckIndex -le $dexBridgeUncertainQuarantineCheckIndex `
        -or $dexBridgeDispatcherCheckIndex -le $dexBridgePrivateCheckIndex `
        -or $dexBridgeCallbackInterfaceIndex -le $dexBridgeFlowInvocationIndex `
        -or $dexBridgeInspectorArgumentIndex -lt 0 `
        -or $dexBridgeInspectorProvenanceIndex -lt 0 `
        -or $dexBridgeInspectorCallerCatchIndex -lt 0 `
        -or $dexBridgeInspectorCallerCallbackIndex -lt 0 `
        -or $dexBridgeInspectorCallbackEffectIndex -lt 0 `
        -or $dexBridgeInspectorExceptionalCfgIndex -lt 0 `
        -or $dexBridgeInspectorEntryIndex -lt 0 `
        -or $dexBridgeInspectorSchedulerEnqueueIndex -lt 0 `
        -or $dexBridgeInspectorUncertainQuarantineIndex -lt 0 `
        -or $dexBridgeInspectorWaitingClearIndex -lt 0 `
        -or $dexBridgeInspectorReviewedTerminalIndex -lt 0 `
        -or $dexBridgeInspectorTerminalCatchIndex -lt 0 `
        -or $dexBridgeInspectorPrivateSeamIndex -lt 0 `
        -or $dexBridgeInspectorDispatcherIndex -lt 0 `
        -or $dexBridgeInspectorHandlerPostIndex -lt 0 `
        -or $dexReportPermalinkFlowInvocationIndex -lt 0 `
        -or $dexReportPermalinkFlowFixtureInvocationIndex -lt 0 `
        -or $dexReportPermalinkInspectorArgumentIndex -lt 0 `
        -or $dexReportPermalinkFactoryFlowIndex -lt 0 `
        -or $dexReportPermalinkRequestFlowIndex -lt 0 `
        -or $dexReportPermalinkValidityFlowIndex -lt 0 `
        -or $dexReportPermalinkPayloadTargetFlowIndex -lt 0 `
        -or $dexReportPermalinkPayloadEvidenceFlowIndex -lt 0 `
        -or $dexReportPermalinkFieldImmutableIndex -lt 0 `
        -or $dexReportPermalinkFieldWriteCountIndex -lt 0 `
        -or $dexReportPermalinkArrayConstructorIndex -lt 0 `
        -or $dexReportPermalinkArrayUseIndex -lt 0 `
        -or $dexReportPermalinkControllerGuardIndex -lt 0 `
        -or $dexReportPermalinkClientGuardIndex -lt 0 `
        -or $dexReportPermalinkRowModifierFlowIndex -lt 0 `
        -or $dexReportPermalinkRowDefaultMaskIndex -lt 0 `
        -or $jadxOrderedContractIndex -lt 0 `
        -or $jadxForbiddenContractIndex -lt 0 `
        -or $jadxForbiddenFailureIndex -lt 0 `
        -or $jadxForbiddenEvidenceIndex -lt 0 `
        -or $jadxExactCountContractIndex -lt 0 `
        -or $jadxExactCountFailureIndex -lt 0 `
        -or $jadxExactCountEvidenceIndex -lt 0) {
    throw 'Release ordering does not prove bootstrap, decoded/candidate locks, path confinement, archive/DEX identity, publication freeze, and rollback.'
}

$runRoot = Join-Path $scratchFull 'pipeline-failure'
$sourceProbe = if ([string]::IsNullOrWhiteSpace($SourceApkSet)) {
    Join-Path $repositoryRoot (
        'Threads-' + [string]$resolutionForContract.source.versionName)
} else {
    [IO.Path]::GetFullPath($SourceApkSet)
}
if (-not (Test-Path -LiteralPath $sourceProbe -PathType Container)) {
    throw "Exact split source set is unavailable for the pipeline failure contract: $sourceProbe"
}
$sourceProbeEvidence = Test-PatchletSplitSourceSet `
    -Resolution $resolutionForContract -SourceApkSet $sourceProbe
$expectedSourceSet = [string]$sourceProbeEvidence.sha256
$failureBuildToolsVersion = '0.0.0-release-contract-probe'
$failureProbeIsSignedReview = [string]$resolutionForContract.status -ceq 'review-required' `
    -and [bool]$resolutionForContract.release.updateSignedDexReviewRequired
$failureProbeIsRelease = [string]$resolutionForContract.status -ceq 'verified-current' `
    -and -not [bool]$resolutionForContract.release.updateSignedDexReviewRequired
if (-not $failureProbeIsSignedReview -and -not $failureProbeIsRelease) {
    throw 'Pipeline failure contract has no authorized validation mode for this resolution state.'
}
$token = [guid]::NewGuid().ToString('N')
$publishProbe = Join-Path $repositoryRoot "dist\.release-contract-probe-$token.apk"
$caught = $null
try {
    if ($failureProbeIsSignedReview) {
        & (Join-Path $PSScriptRoot 'Invoke-PatchletPipeline.ps1') `
            -SourceApkSet $sourceProbe `
            -RunRoot $runRoot `
            -KeyStore $sourceProbe `
            -KeyAlias 'contract-probe' `
            -ResolutionPath ([IO.Path]::GetFullPath($ResolutionPath)) `
            -ValidationMode 'SignedReview' `
            -ReviewDeviceSerial 'release-contract-probe' `
            -BuildToolsVersion $failureBuildToolsVersion | Out-Null
    } else {
        & (Join-Path $PSScriptRoot 'Invoke-PatchletPipeline.ps1') `
            -SourceApkSet $sourceProbe `
            -RunRoot $runRoot `
            -KeyStore $sourceProbe `
            -KeyAlias 'contract-probe' `
            -ResolutionPath ([IO.Path]::GetFullPath($ResolutionPath)) `
            -ValidationMode 'Release' `
            -BuildToolsVersion $failureBuildToolsVersion `
            -PublishPath $publishProbe | Out-Null
    }
} catch {
    $caught = $_
}
if ($null -eq $caught) {
    throw 'Failure-contract probe unexpectedly completed without an error.'
}
if (-not $caught.Exception.Message.Contains(
        "Build Tools version '$failureBuildToolsVersion' differs",
        [StringComparison]::Ordinal)) {
    throw "Failure-contract probe stopped at an unexpected boundary: $($caught.Exception.Message)"
}
if (Test-Path -LiteralPath $publishProbe) {
    throw "Failure-contract probe published an APK: $publishProbe"
}

$failureReportPath = Join-Path $runRoot 'build-report.json'
if (-not (Test-Path -LiteralPath $failureReportPath -PathType Leaf)) {
    throw 'Pipeline failure did not produce build-report.json.'
}
$failure = Read-PatchletJson -Path $failureReportPath
if ([string]$failure.status -ne 'failed' `
        -or [bool]$failure.artifactProduced `
        -or $null -ne $failure.output `
        -or $null -ne $failure.published `
        -or $null -ne $failure.bindings.outputApkSha256 `
        -or $null -eq $failure.PSObject.Properties['derivedWorkCopy']) {
    throw 'Pipeline failure report does not enforce the non-artifact contract.'
}
$resolutionFull = [IO.Path]::GetFullPath($ResolutionPath)
$expectedResolution = Get-PatchletSha256 -Path $resolutionFull
$expectedSource = [string](Read-PatchletJson -Path $resolutionFull).source.sha256
if ([string]$failure.bindings.sourceApkSetSha256 -ne $expectedSourceSet `
        -or [string]$failure.bindings.sourceApkSha256 -ne $expectedSource `
        -or [string]$failure.bindings.resolutionFileSha256 -ne $expectedResolution) {
    throw 'Pipeline failure report did not retain source-set/source/resolution SHA-256 bindings.'
}
if ([string]$failure.input.sourceSetPath -ne [IO.Path]::GetFullPath($sourceProbe) `
        -or [string]$failure.input.sourceSetSha256 -ne $expectedSourceSet `
        -or $null -eq $failure.input.sourceSetSnapshotPath `
        -or $null -ne $failure.input.snapshotPath `
        -or [string]$failure.input.sha256 -ne $expectedSource `
        -or $null -eq $failure.resolution.snapshotPath `
        -or [string]$failure.resolution.sha256 -ne $expectedResolution `
        -or [string]$failure.observedAtFailure.sourceApkSetSha256 -ne $expectedSourceSet `
        -or $null -ne $failure.observedAtFailure.sourceApkSha256 `
        -or [string]$failure.observedAtFailure.resolutionFileSha256 -ne $expectedResolution `
        -or [bool]$failure.observedAtFailure.sourceSetDrifted `
        -or [bool]$failure.observedAtFailure.resolutionFileDrifted) {
    throw 'Pipeline failure report did not retain the source-set boundary and observed-at-failure evidence.'
}

$signedReviewRunRoot = Join-Path $scratchFull 'signed-review-must-not-start'
$signedReviewPublishProbe = Join-Path $repositoryRoot "dist\.signed-review-contract-probe-$token.apk"
$signedReviewPublishCaught = $null
try {
    & (Join-Path $PSScriptRoot 'Invoke-PatchletPipeline.ps1') `
        -SourceApkSet $sourceProbe `
        -RunRoot $signedReviewRunRoot `
        -KeyStore $sourceProbe `
        -KeyAlias 'contract-probe' `
        -ResolutionPath ([IO.Path]::GetFullPath($ResolutionPath)) `
        -ValidationMode 'SignedReview' `
        -ReviewDeviceSerial 'emulator-5554' `
        -PublishPath $signedReviewPublishProbe | Out-Null
} catch {
    $signedReviewPublishCaught = $_
}
if ($null -eq $signedReviewPublishCaught `
        -or $signedReviewPublishCaught.Exception.Message `
            -cne 'SignedReview mode forbids PublishPath and cannot publish an APK.' `
        -or (Test-Path -LiteralPath $signedReviewRunRoot) `
        -or (Test-Path -LiteralPath $signedReviewPublishProbe)) {
    throw 'SignedReview publication negative did not fail closed before creating workspace or output.'
}

$releaseReviewDeviceRunRoot = Join-Path $scratchFull 'release-review-device-must-not-start'
$releaseReviewDeviceCaught = $null
try {
    & (Join-Path $PSScriptRoot 'Invoke-PatchletPipeline.ps1') `
        -SourceApkSet $sourceProbe `
        -RunRoot $releaseReviewDeviceRunRoot `
        -KeyStore $sourceProbe `
        -KeyAlias 'contract-probe' `
        -ResolutionPath ([IO.Path]::GetFullPath($ResolutionPath)) `
        -ReviewDeviceSerial 'emulator-5554' | Out-Null
} catch {
    $releaseReviewDeviceCaught = $_
}
if ($null -eq $releaseReviewDeviceCaught `
        -or $releaseReviewDeviceCaught.Exception.Message `
            -cne 'ReviewDeviceSerial is valid only in SignedReview mode.' `
        -or (Test-Path -LiteralPath $releaseReviewDeviceRunRoot)) {
    throw 'Default Release mode accepted SignedReview-only device authority or created a workspace.'
}

$report = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToString('o')
    status = 'passed'
    failureReport = $failureReportPath
    failedStage = [string]$failure.failedStage
    artifactProduced = [bool]$failure.artifactProduced
    publishPathAbsent = -not (Test-Path -LiteralPath $publishProbe)
    signedReview = [ordered]@{
        policy = 'non-publishing-exact-signed-evidence-only'
        publishRejected = $true
        rejection = $signedReviewPublishCaught.Exception.Message
        runRootAbsent = -not (Test-Path -LiteralPath $signedReviewRunRoot)
        publishPathAbsent = -not (Test-Path -LiteralPath $signedReviewPublishProbe)
        defaultReleaseRejectedReviewDevice = $true
        defaultReleaseRunRootAbsent = -not (Test-Path -LiteralPath $releaseReviewDeviceRunRoot)
        reviewOnly = $true
        releaseEligible = $false
    }
    deterministicDrift = [ordered]@{
        detected = $true
        message = $driftCaught.Exception.Message
        publishPathAbsent = -not (Test-Path -LiteralPath $driftPublishProbe)
        transientWriteLockPassed = $lockBlockedWrite
        transientTreeMutationDetected = $treeLockDetectedTransient
        canonicalDecodedWriteBlocked = $decodedCanonicalWriteBlocked
        omittedBuildWorkingTreeAllowlistRejected = $null -ne $buildWorkingOmittedTreeAllowlistCaught
        omittedBuildWorkingFileAllowlistRejected = $null -ne $buildWorkingOmittedFileAllowlistCaught
        exactApktoolWorkingMutationAccepted = $null -ne $buildWorkingMutationEvents `
            -and [int]$buildWorkingMutationEvents.unexpectedTreeMonitorEvents -eq 0 `
            -and -not (Test-Path -LiteralPath $buildWorkingBuildCache) `
            -and -not (Test-Path -LiteralPath $buildWorkingManifestOriginal)
        buildWorkingStableWriteBlocked = $buildWorkingStableWriteBlocked
        buildWorkingHandleCountExcludedOnlyManifest = $buildWorkingHandleCountPassed
        buildWorkingUnexpectedRenameRejected = $null -ne $buildWorkingUnexpectedRenameCaught
        buildWorkingMonitorErrorRejected = $null -ne $monitorErrorCaught
        generatedBuildCacheMutationAccepted = [int]$generatedTreeAllowed.allowedTreeMonitorEvents -gt 0
        generatedSiblingMutationRejected = $null -ne $generatedSiblingCaught
        transactionDriftBlockedPublish = $null -ne $transactionDriftCaught
        postMoveRollbackPassed = ($null -ne $rollbackCaught -and -not (Test-Path -LiteralPath $rollbackPublishProbe))
        rollbackResidueReportedTruthfully = $residueEvidencePassed
        outerPostCommitRollbackPassed = [bool]$postCommitCleanup.removed
        outerPostCommitResidueTruthful = [bool]$postCommitResidue.residue
    }
    publicationOrdering = [ordered]@{
        splitSourceValidatedAndLockedBeforeMerge = $true
        splitUniversalizationDeterministicBeforeDecode = $true
        splitSourceNegativeFixtures = 10
        apkEditorContractNegativeFixtures = 6
        parsedEntryAndModuleAttested = $true
        canonicalAssetsRechecked = $true
        stageSnapshotsFrozen = $true
        canonicalPatchletsTreeFrozen = $true
        decodedCompleteTreeFrozenBeforeIdempotency = $true
        canonicalDecodedZeroMutationLockPassed = $null -ne $decodedIdempotencyLock
        decodedLockAssertionsChecked = $decodedLockAssertions.Count
        buildWorkingCopyBoundToDecoded = [string]$buildWorkingCopyFixture.sha256 -eq [string]$decodedInputFreeze[0].sha256
        buildWorkingMutationLockAssertionsChecked = $buildWorkingMutationLockAssertions.Count
        buildWorkingSealedLockAssertionsChecked = $buildWorkingSealedLockAssertions.Count
        buildWorkingRestoredBeforeCandidateAcceptance = -not (Test-Path -LiteralPath $buildWorkingManifestOriginal)
        derivedWorkCopyFailureEvidenceRequired = $derivedWorkCopyEvidenceIndex -ge 0
        candidateLockedBeforeReleaseGates = $true
        intermediateArtifactsLocked = $true
        artifactPathsConfined = $true
        wholeArchiveNamesUniqueCanonical = $true
        exactRootDexNamesRequired = $true
        signedDexProxyBootstrapFlowRequired = $true
        signedDexBridgeFlowRequired = $true
        signedDexReportPermalinkFlowRequired = $true
        signedDexUpdateFlowRequired = $true
        releaseToolParameterCompatibility = $releaseToolParameterCompatibility
        releaseToolEvidenceCompatibility = $releaseToolEvidenceCompatibility
        releaseToolInspectorArgumentCompatibility = $releaseToolInspectorArgumentCompatibility
        releaseToolInspectorBindingCompatibility = $releaseToolInspectorBindingCompatibility
        releaseToolReportPermalinkEvidenceCompatibility = `
            $releaseToolReportPermalinkEvidenceCompatibility
        releaseToolReportPermalinkInspectorArgumentCompatibility = `
            $releaseToolReportPermalinkInspectorArgumentCompatibility
        releaseToolReportPermalinkInspectorBindingCompatibility = `
            $releaseToolReportPermalinkInspectorBindingCompatibility
        releaseToolProxyBootstrapEvidenceCompatibility = `
            $releaseToolProxyBootstrapEvidenceCompatibility
        releaseToolProxyBootstrapInspectorArgumentCompatibility = `
            $releaseToolProxyBootstrapInspectorArgumentCompatibility
        releaseToolProxyBootstrapInspectorBindingCompatibility = `
            $releaseToolProxyBootstrapInspectorBindingCompatibility
        releaseToolUpdateFlowCompatibility = $releaseToolUpdateFlowCompatibility
        releaseToolUpdateFlowContractNegativeFixtures = `
            $releaseToolUpdateFlowContractNegativeFixtures
        releaseToolContractNegativeFixtures = $releaseToolContractNegativeFixtures
        signedReviewNoPublishContract = $true
        signedReviewGateIndex = $signedReviewGateIndex
        ambiguousReportSubstringCollisionRecognized = $true
        ambiguousSocksPortSubstringCollisionRecognized = $true
        targetedJadxOrderedAndForbiddenStrings = $true
        targetedJadxClassCount = $resolvedTargetedJadxClassNames.Count
        passiveBlockingSignedGatesRequired = $true
        passiveReleaseGateOrder = $passiveReleaseGateOrder
        inAppUpdateSignedGatesRequired = $true
        inAppUpdateReleaseGateOrder = $updateReleaseGateOrder
        proxyBootstrapRawBeforeTargetedJadx = `
            $proxyBootstrapRawGateIndex -lt $targetedJadxGateIndex
        exactDexActivityProbeContract = $true
        inputLocksHeldBeforeStages = $true
        prePublishFreezeBeforeMove = $true
        postPublishFreezeAfterMove = $true
        rollbackAfterPostPublishCheck = $true
        publishedFileRehashed = $true
    }
    fixtures = [ordered]@{
        targetedJadxVisibilityCallsites = [ordered]@{
            sourceVersionName = $sourceVersionName
            register = [int]$reviewedVisibilityJadxCallCounts[
                'AutoBlockSync.registerVisibleControl(this,']
            update = [int]$reviewedVisibilityJadxCallCounts[
                'AutoBlockSync.updateVisibleControl(this,']
            unregister = [int]$reviewedVisibilityJadxCallCounts[
                'AutoBlockSync.unregisterVisibleControl(this)']
            countDriftRejected = $visibilityJadxCountDriftRejected
        }
        targetedJadxPassiveInvalidGeneration = [ordered]@{
            exactThreePathTupleBound = $passiveInvalidGenerationJadxTupleBound
            countDriftRejected = $passiveInvalidGenerationJadxCountDriftRejected
            literals = @($reviewedPassiveInvalidGenerationJadxCounts.Keys)
            blocklistLocalRecoveryAuthoritative = $false
            blocklistEvidenceBoundaryBound = $blocklistJadxEvidenceBoundaryBound
            impossibleSourceLocalsExcluded = $blocklistJadxLocalsExcluded
            blocklistEvidenceBoundary = $reviewedBlocklistJadxEvidenceBoundary
        }
        targetedJadxPassiveWrapperParity = [ordered]@{
            resolutionOwned = $true
            strings = @($passiveJadxWrapperParity.strings)
            negativeFixtures = @($passiveJadxWrapperNegativeResults)
        }
        semanticProofCaseCollision = [ordered]@{
            candidatePaths = @($semanticCollisionCandidatePaths)
            targetClassDescriptor = $semanticCollisionTargetDescriptor
            siblingClassDescriptor = $semanticCollisionSiblingDescriptor
            positiveArrangements = @($semanticCollisionPositiveResults)
            negativeFixtures = @($semanticCollisionNegativeResults)
            ordinaryPathCompatibility = $true
        }
        dexProxyBootstrapFlow = $dexProxyBootstrapFlowFixtureResult
        dexReportPermalinkFlow = $dexReportPermalinkFlowFixtureResult
        dexUpdateFlowContract = [pscustomobject]@{
            expectedFixtureCount = `
                [int]$resolutionForContract.release.expectedDexUpdateFlowFixtureCount
            inspectorArgumentCount = `
                [int]$resolutionForContract.release.expectedDexUpdateFlowInspectorArgumentCount
            semanticSha256 = `
                [string]$requiredDexUpdateFlow.expectedSemanticSha256
            semanticClassCount = `
                [int]$requiredDexUpdateFlow.expectedSemanticClassCount
        }
        safeArtifactBaseName = $safeArtifactBaseName
        duplicateZipRejected = $null -ne $duplicateZipCaught
        traversalZipRejected = $null -ne $traversalZipCaught
        duplicateDexRejected = $dexProcess.ExitCode -ne 0
        dexDirectStringCalls = $dexLiteralFixtureResult.fixtures
        dexBridgeFlows = $dexBridgeFlowFixtureResult.fixtures
    }
    inAppUpdate = [ordered]@{
        patchlet = '085-in-app-update'
        releaseGateRevision = 56
        releaseGates = $updateReleaseGateOrder
        currentModBuild = [long]$resolutionForContract.update.currentModBuild
        targetModBuild = $targetModBuild
        targetVersionCode = [long]$resolutionForContract.target.versionCode
        targetVersionName = [string]$resolutionForContract.target.versionName
        metadataPurpose = 'threadsmod-app-update'
        metadataEndpoints = $expectedUpdateMetadataEndpoints
        hostPolicyAndSignatureHarnessesRequired = $true
        generatedD8SemanticFixturesRequired = $true
        finalSignedApkSemanticInspectionRequired = $true
        signedApkManifestDexAndSignerChecksRequired = $true
        requestInstallPermissionAuthority = 'manifest-only'
        requiredAsDexMarker = $false
        missingPermissionNegativeRejected = $missingUpdateInstallPermissionRejected
        deploymentProved = $false
        installRuntimeProved = $false
    }
    providerAuthorities = @($requiredProviderAuthorities)
    drawerSettingsRows = @($drawerRows)
    sourceApkSha256 = $expectedSource
    resolutionFileSha256 = $expectedResolution
}
if ($ReportPath) {
    Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath))
}
[pscustomobject]$report
