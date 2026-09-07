[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScratchRoot,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$Java = 'java',
    [string]$Javac = 'javac',
    [string]$Jar = 'jar',
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$BuildToolsVersion = '36.0.0',
    [string]$SevenZip = 'C:\Program Files\7-Zip\7z.exe',
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

function Invoke-RequiredNative {
    param([string]$Command, [string[]]$Arguments)
    $lines = @(& $Command @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $lines | ForEach-Object { Write-Host $_ }
        throw "Native bridge-flow fixture command failed with exit code ${code}: $Command"
    }
    return $lines
}

function Invoke-ProbeNative {
    param([string]$Command, [string[]]$Arguments)
    $lines = @(& $Command @Arguments 2>&1)
    return [pscustomobject]@{ exitCode = [int]$LASTEXITCODE; lines = $lines }
}

function Get-JsonResult {
    param([Parameter(Mandatory)][object[]]$Lines, [Parameter(Mandatory)][string]$FixtureId)
    if (@($Lines).Count -eq 0) { throw "Bridge-flow fixture '$FixtureId' returned no evidence." }
    $line = [string]$Lines[-1]
    if ($line.Length -gt 16384) { throw "Bridge-flow fixture '$FixtureId' returned oversized evidence." }
    try { return $line | ConvertFrom-Json }
    catch { throw "Bridge-flow fixture '$FixtureId' did not return bounded JSON evidence." }
}

function Get-PropertyCount {
    param([Parameter(Mandatory)][object]$Value)
    return @($Value.PSObject.Properties).Count
}

function Set-ExactFixtureMutations {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][object]$Fixture
    )
    $relativePath = [string]$Fixture.relativePath
    if ([string]::IsNullOrWhiteSpace($relativePath) `
            -or [IO.Path]::IsPathRooted($relativePath) `
            -or $relativePath.Contains('..', [StringComparison]::Ordinal)) {
        throw "Bridge-flow fixture '$($Fixture.id)' has an invalid relative path."
    }
    $target = Assert-PatchletPathUnderRoot `
        -Path ([IO.Path]::GetFullPath((Join-Path $SourceRoot $relativePath))) -Root $SourceRoot
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        throw "Bridge-flow fixture '$($Fixture.id)' targets a missing source."
    }
    $content = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
    foreach ($replacement in @($Fixture.replacements)) {
        $before = [string]$replacement.before
        $after = [string]$replacement.after
        $expectedCount = [int]$replacement.expectedCount
        if ([string]::IsNullOrEmpty($before) -or $expectedCount -lt 1) {
            throw "Bridge-flow fixture '$($Fixture.id)' has an invalid replacement."
        }
        $observedCount = [regex]::Matches(
            $content, [regex]::Escape($before),
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
        if ($observedCount -ne $expectedCount) {
            throw "Bridge-flow fixture '$($Fixture.id)' replacement count drifted: expected $expectedCount, observed $observedCount."
        }
        $content = $content.Replace($before, $after)
    }
    [IO.File]::WriteAllText($target, $content, [Text.UTF8Encoding]::new($false))
}

function Assert-PositiveEvidence {
    param([Parameter(Mandatory)][object]$Result)
    if ([int]$Result.schemaVersion -ne 1 `
            -or [string]$Result.status -ne 'passed' `
            -or [string]$Result.contract -ne 'threads-block-bridge-flow-v1' `
            -or [string]$Result.dex -ne 'classes.dex' `
            -or [string]$Result.classDescriptor -ne 'Lthreadsmod/autoblock/ThreadsBlockBridge;' `
            -or [string]$Result.mutationCallbackInterface -ne 'Lfixture/MutationEvents;' `
            -or [int]$Result.rawCalls.block -ne 3 `
            -or [int]$Result.rawCalls.blockResolved -ne 1 `
            -or [int]$Result.rawCalls.blockModel -ne 2 `
            -or [int]$Result.rawCalls.prepareModel -ne 2 `
            -or [int]$Result.rawCalls.passivePreflight -ne 1 `
            -or [int]$Result.definitions.block -ne 1 `
            -or [int]$Result.definitions.blockResolved -ne 1 `
            -or [int]$Result.definitions.blockModel -ne 1 `
            -or [int]$Result.definitions.prepareModel -ne 1 `
            -or [int]$Result.definitions.passivePreflight -ne 1 `
            -or [string]$Result.callerProvenance.automatic.descriptor -ne 'Lfixture/AutomaticCaller;' `
            -or [string]$Result.callerProvenance.automatic.ownerMode -ne 'legacy-batch' `
            -or [int]$Result.callerProvenance.automatic.block -ne 1 `
            -or [int]$Result.callerProvenance.automatic.blockResolved -ne 0 `
            -or [int]$Result.callerProvenance.automatic.blockModel -ne 0 `
            -or [int]$Result.callerProvenance.automatic.prepareModel -ne 0 `
            -or [int]$Result.callerProvenance.automatic.passivePreflight -ne 1 `
            -or [string]$Result.callerProvenance.manual.descriptor -ne 'Lfixture/ManualCaller;' `
            -or [int]$Result.callerProvenance.manual.block -ne 1 `
            -or [int]$Result.callerProvenance.manual.blockResolved -ne 1 `
            -or [int]$Result.callerProvenance.manual.blockModel -ne 0 `
            -or [int]$Result.callerProvenance.manual.prepareModel -ne 0 `
            -or [int]$Result.callerProvenance.manual.passivePreflight -ne 0 `
            -or [int]$Result.callerProvenance.bridge.block -ne 1 `
            -or [int]$Result.callerProvenance.bridge.blockResolved -ne 0 `
            -or [int]$Result.callerProvenance.bridge.blockModel -ne 2 `
            -or [int]$Result.callerProvenance.bridge.prepareModel -ne 2 `
            -or [int]$Result.callerProvenance.bridge.passivePreflight -ne 0 `
            -or [int]$Result.callerProvenance.other.block -ne 0 `
            -or [int]$Result.callerProvenance.other.blockResolved -ne 0 `
            -or [int]$Result.callerProvenance.other.blockModel -ne 0 `
            -or [int]$Result.callerProvenance.other.prepareModel -ne 0 `
            -or [int]$Result.callerProvenance.other.passivePreflight -ne 0 `
            -or [int]$Result.callerCatchTopology.automatic.bridgeMethodCount -ne 1 `
            -or [int]$Result.callerCatchTopology.automatic.tryCount -ne 1 `
            -or [int]$Result.callerCatchTopology.automatic.block -ne 1 `
            -or [int]$Result.callerCatchTopology.automatic.blockResolved -ne 0 `
            -or [int]$Result.callerCatchTopology.automatic.handoffCalls -ne 1 `
            -or [int]$Result.callerCatchTopology.automatic.falseReturns -ne 1 `
            -or [int]$Result.callerCatchTopology.automatic.handlerLiteralRoutes -ne 1 `
            -or [int]$Result.callerCatchTopology.automatic.unreviewedInvokes -ne 0 `
            -or [int]$Result.callerCatchTopology.automatic.unreviewedOpcodes -ne 0 `
            -or [int]$Result.callerCatchTopology.manual.bridgeMethodCount -ne 1 `
            -or [int]$Result.callerCatchTopology.manual.tryCount -ne 1 `
            -or [int]$Result.callerCatchTopology.manual.block -ne 1 `
            -or [int]$Result.callerCatchTopology.manual.blockResolved -ne 1 `
            -or [int]$Result.callerCatchTopology.manual.handoffCalls -ne 1 `
            -or [int]$Result.callerCatchTopology.manual.falseReturns -ne 1 `
            -or [int]$Result.callerCatchTopology.manual.handlerLiteralRoutes -ne 1 `
            -or [int]$Result.callerCatchTopology.manual.unreviewedInvokes -ne 0 `
            -or [int]$Result.callerCatchTopology.manual.unreviewedOpcodes -ne 0 `
            -or -not [bool]$Result.callerCallbackExecution.automatic.interface `
            -or [int]$Result.callerCallbackExecution.automatic.started -ne 1 `
            -or [int]$Result.callerCallbackExecution.automatic.failure -ne 1 `
            -or [int]$Result.callerCallbackExecution.automatic.success -ne 1 `
            -or [int]$Result.callerCallbackExecution.automatic.immediateRunnableDispatches -ne 0 `
            -or -not [bool]$Result.callerCallbackExecution.manual.interface `
            -or [int]$Result.callerCallbackExecution.manual.started -ne 1 `
            -or [int]$Result.callerCallbackExecution.manual.failure -ne 1 `
            -or [int]$Result.callerCallbackExecution.manual.success -ne 1 `
            -or [int]$Result.callerCallbackExecution.manual.immediateRunnableDispatches -ne 0 `
            -or [int]$Result.callerCallbackEffectTopology.automatic.startedLatchWrites -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.automatic.statusCalls -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.automatic.failureRoutes -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.automatic.completionSaveCalls -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.automatic.completionQuarantineBranches -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.automatic.ownershipReleaseCalls -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.automatic.successRecordCalls -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.automatic.waitingClearWrites -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.automatic.pacedNextPosts -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne 5 `
            -or [int]$Result.callerCallbackEffectTopology.automatic.terminalCatchRoutes -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.manual.startedLatchWrites -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.manual.startedDispatchCalls -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.manual.statusCalls -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.manual.runtimeStateCalls -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.manual.failureRoutes -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.manual.completionSaveCalls -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.manual.completionQuarantineBranches -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.manual.ownershipReleaseCalls -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.manual.successDispatchCalls -ne 1 `
            -or [int]$Result.callerCallbackEffectTopology.manual.schedulerReleaseCalls -ne 2 `
            -or [int]$Result.bridgeCallbackRouting.failure -ne 10 `
            -or [int]$Result.bridgeCallbackRouting.success -ne 1 `
            -or [int]$Result.bridgeCallbackRouting.directOutsideDelivery -ne 0 `
            -or [int]$Result.dispatcherCallProvenance.bridge.started -ne 0 `
            -or [int]$Result.dispatcherCallProvenance.bridge.failure -ne 10 `
            -or [int]$Result.dispatcherCallProvenance.bridge.success -ne 1 `
            -or [int]$Result.dispatcherCallProvenance.mutationCallback.started -ne 1 `
            -or [int]$Result.dispatcherCallProvenance.mutationCallback.failure -ne 1 `
            -or [int]$Result.dispatcherCallProvenance.mutationCallback.success -ne 1 `
            -or [int]$Result.dispatcherCallProvenance.other.started -ne 0 `
            -or [int]$Result.dispatcherCallProvenance.other.failure -ne 0 `
            -or [int]$Result.dispatcherCallProvenance.other.success -ne 0 `
            -or [int]$Result.dispatcherCallProvenance.aggregate.started -ne 1 `
            -or [int]$Result.dispatcherCallProvenance.aggregate.failure -ne 11 `
            -or [int]$Result.dispatcherCallProvenance.aggregate.success -ne 2 `
            -or [int]$Result.dispatcherCallProvenance.enqueue -ne 3 `
            -or [int]$Result.dispatcherCallProvenance.deliveryConstructor -ne 1 `
            -or [int]$Result.dispatcherCallProvenance.directDeliveryRun -ne 0 `
            -or [int]$Result.privateSeamProvenance.cacheLookup -ne 2 `
            -or [int]$Result.privateSeamProvenance.cacheFactory -ne 2 `
            -or [int]$Result.privateSeamProvenance.cachePlaceholder -ne 2 `
            -or -not [bool]$Result.checks.passiveNativePreflight `
            -or -not [bool]$Result.checks.passiveMatchFailClosed `
            -or [int]$Result.passiveInvalidGeneration.loadTarget.lookup -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.loadTarget.generationRead -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.loadTarget.latch -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.lookupWorker.lookup -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.lookupWorker.generationRead -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.lookupWorker.latch -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.currentPassiveMatch.lookup -lt 0 `
            -or [int]$Result.passiveInvalidGeneration.currentPassiveMatch.generationRead `
                -le [int]$Result.passiveInvalidGeneration.currentPassiveMatch.lookup `
            -or [int]$Result.passiveInvalidGeneration.currentPassiveMatch.latch `
                -le [int]$Result.passiveInvalidGeneration.currentPassiveMatch.generationRead `
            -or [int]$Result.passiveInvalidGeneration.lookupIdProducer.metadataRead -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.lookupIdProducer.generationRead -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.lookupIdProducer.invalidCalls -ne 0 `
            -or [int]$Result.passiveInvalidGeneration.lookupIdProducer.outerHandlers -ne 0 `
            -or [int]$Result.passiveInvalidGeneration.currentIdProducer.metadataRead -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.currentIdProducer.generationRead -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.currentIdProducer.invalidCalls -ne 0 `
            -or [int]$Result.passiveInvalidGeneration.currentIdProducer.outerHandlers -ne 0 `
            -or [int]$Result.passiveInvalidGeneration.invalidFactory.accessor -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.invalidFactory.max -ne -1 `
            -or [int]$Result.passiveInvalidGeneration.invalidFactory.constructor -ne -1 `
            -or [int]$Result.privateSeamProvenance.authorId -ne 1 `
            -or [int]$Result.privateSeamProvenance.alreadyBlocked -ne 1 `
            -or [int]$Result.privateSeamProvenance.nativeMutation -ne 1 `
            -or [int]$Result.stablePrivateSeamProvenance.mediaLookup -ne 0 `
            -or [int]$Result.stablePrivateSeamProvenance.authorLookup -ne 0 `
            -or [int]$Result.stablePrivateSeamProvenance.username -ne 0 `
            -or (Get-PropertyCount -Value $Result.block.handlers) -ne 4 `
            -or (Get-PropertyCount -Value $Result.blockResolved.handlers) -ne 2 `
            -or (Get-PropertyCount -Value $Result.passivePreflight.handlers) -ne 5 `
            -or (Get-PropertyCount -Value $Result.prepareModel.handlers) -ne 2 `
            -or (Get-PropertyCount -Value $Result.blockModel.handlers) -ne 2 `
            -or [int]$Result.mutationCallback.dispatcherStarted -ne 1 `
            -or [int]$Result.mutationCallback.dispatcherFailure -ne 1 `
            -or [int]$Result.mutationCallback.dispatcherSuccess -ne 1 `
            -or [int]$Result.mutationCallback.handlerPost -ne 1 `
            -or [int]$Result.mutationCallback.deliveryStarted -ne 1 `
            -or [int]$Result.mutationCallback.deliveryFailure -ne 1 `
            -or [int]$Result.mutationCallback.deliverySuccess -ne 1) {
        throw 'Positive bridge-flow fixture did not return the exact structural evidence.'
    }
    $requiredChecks = @(
        'directIdCacheFallback', 'nullPlaceholderSeed', 'passiveNativePreflight',
        'passiveMatchFailClosed',
        'exactRawBridgeCalls',
        'immutableTargetFlow', 'narrowSeamHandlers', 'callbacksOutsidePrivateSeams',
        'modelIdGuard', 'preparationResultFlow', 'mutationAfterIdEquality',
        'nativeMutationIdentity', 'asyncCallbackFirewall', 'terminalCallbackMap',
        'callerProvenance', 'callerCatchTopology', 'directCallerCallbackExecution',
        'callerCallbackEffectTopology', 'dispatcherCallProvenance',
        'privateSeamCallProvenance', 'callbackExceptionalControlFlow',
        'bridgeEntryReachability', 'schedulerEnqueueAcceptance',
        'uncertainMutationQuarantine', 'stableInlinePrivateSeamAbsence')
    if ((Get-PropertyCount -Value $Result.checks) -ne $requiredChecks.Count) {
        throw 'Positive bridge-flow fixture returned an unexpected check set.'
    }
    foreach ($check in $requiredChecks) {
        $property = $Result.checks.PSObject.Properties[$check]
        if ($null -eq $property -or -not [bool]$property.Value) {
            throw "Positive bridge-flow fixture did not prove '$check'."
        }
    }
}

function Assert-SingleTargetPositiveEvidence {
    param(
        [Parameter(Mandatory)][object]$CurrentResult,
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][object]$Symbols
    )
    if ([int]$CurrentResult.schemaVersion -ne 1 `
            -or [string]$CurrentResult.status -ne 'passed' `
            -or [string]$CurrentResult.contract -ne 'threads-block-bridge-flow-v1' `
            -or [string]$CurrentResult.dex -ne 'classes.dex' `
            -or [string]$CurrentResult.classDescriptor -ne [string]$Contract.ownerClassDescriptor `
            -or [string]$CurrentResult.mutationCallbackInterface -ne [string]$Symbols.mutationCallbackInterface `
            -or [int]$CurrentResult.rawCalls.prepareModel -ne 2 `
            -or [int]$CurrentResult.rawCalls.passivePreflight -ne 1 `
            -or [int]$CurrentResult.definitions.passivePreflight -ne 1 `
            -or [string]$CurrentResult.callerProvenance.automatic.descriptor `
                -ne [string]$Contract.automaticCallerClassDescriptor `
            -or [string]$CurrentResult.callerProvenance.automatic.ownerMode -ne 'single-target' `
            -or [int]$CurrentResult.callerProvenance.automatic.passivePreflight -ne 1 `
            -or [string]$CurrentResult.callerProvenance.manual.descriptor `
                -ne [string]$Contract.manualCallerClassDescriptor `
            -or [int]$CurrentResult.callerProvenance.manual.passivePreflight -ne 0 `
            -or [int]$CurrentResult.callerProvenance.bridge.prepareModel -ne 2 `
            -or [int]$CurrentResult.callerProvenance.bridge.passivePreflight -ne 0 `
            -or [int]$CurrentResult.callerProvenance.other.passivePreflight -ne 0 `
            -or [int]$CurrentResult.privateSeamProvenance.cacheLookup -ne 2 `
            -or [int]$CurrentResult.privateSeamProvenance.cacheFactory -ne 2 `
            -or [int]$CurrentResult.privateSeamProvenance.cachePlaceholder -ne 2 `
            -or [int]$CurrentResult.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne 3 `
            -or [int]$CurrentResult.callerCallbackEffectTopology.automatic.terminalCatchRoutes -ne 1 `
            -or [int]$CurrentResult.callerCallbackEffectTopology.automatic.pacedNextPosts -ne 0 `
            -or [int]$CurrentResult.callerCallbackEffectTopology.automatic.startedLatchWrites -ne 1 `
            -or [int]$CurrentResult.callerCallbackEffectTopology.automatic.statusCalls -ne 1 `
            -or [int]$CurrentResult.callerCallbackEffectTopology.automatic.failureRoutes -ne 1 `
            -or [int]$CurrentResult.callerCallbackEffectTopology.automatic.completionSaveCalls -ne 1 `
            -or [int]$CurrentResult.callerCallbackEffectTopology.automatic.completionQuarantineBranches -ne 1 `
            -or [int]$CurrentResult.callerCallbackEffectTopology.automatic.ownershipReleaseCalls -ne 1 `
            -or [int]$CurrentResult.callerCallbackEffectTopology.automatic.successRecordCalls -ne 1 `
            -or [int]$CurrentResult.callerCallbackEffectTopology.automatic.waitingClearWrites -ne 1 `
            -or -not [bool]$CurrentResult.checks.immutableTargetFlow `
            -or -not [bool]$CurrentResult.checks.passiveNativePreflight `
            -or -not [bool]$CurrentResult.checks.passiveMatchFailClosed `
            -or [int]$CurrentResult.passiveInvalidGeneration.loadTarget.lookup -lt 0 `
            -or [int]$CurrentResult.passiveInvalidGeneration.loadTarget.generationRead `
                -le [int]$CurrentResult.passiveInvalidGeneration.loadTarget.lookup `
            -or [int]$CurrentResult.passiveInvalidGeneration.loadTarget.latch `
                -le [int]$CurrentResult.passiveInvalidGeneration.loadTarget.generationRead `
            -or [int]$CurrentResult.passiveInvalidGeneration.lookupWorker.lookup -lt 0 `
            -or [int]$CurrentResult.passiveInvalidGeneration.lookupWorker.generationRead `
                -le [int]$CurrentResult.passiveInvalidGeneration.lookupWorker.lookup `
            -or [int]$CurrentResult.passiveInvalidGeneration.lookupWorker.latch `
                -le [int]$CurrentResult.passiveInvalidGeneration.lookupWorker.generationRead `
            -or [int]$CurrentResult.passiveInvalidGeneration.currentPassiveMatch.lookup -lt 0 `
            -or [int]$CurrentResult.passiveInvalidGeneration.currentPassiveMatch.generationRead `
                -le [int]$CurrentResult.passiveInvalidGeneration.currentPassiveMatch.lookup `
            -or [int]$CurrentResult.passiveInvalidGeneration.currentPassiveMatch.latch `
                -le [int]$CurrentResult.passiveInvalidGeneration.currentPassiveMatch.generationRead `
            -or [int]$CurrentResult.passiveInvalidGeneration.lookupIdProducer.metadataRead -lt 0 `
            -or [int]$CurrentResult.passiveInvalidGeneration.lookupIdProducer.generationRead `
                -le [int]$CurrentResult.passiveInvalidGeneration.lookupIdProducer.metadataRead `
            -or [int]$CurrentResult.passiveInvalidGeneration.lookupIdProducer.invalidCalls -ne 3 `
            -or [int]$CurrentResult.passiveInvalidGeneration.lookupIdProducer.outerHandlers -ne 5 `
            -or [int]$CurrentResult.passiveInvalidGeneration.currentIdProducer.metadataRead -lt 0 `
            -or [int]$CurrentResult.passiveInvalidGeneration.currentIdProducer.generationRead `
                -le [int]$CurrentResult.passiveInvalidGeneration.currentIdProducer.metadataRead `
            -or [int]$CurrentResult.passiveInvalidGeneration.currentIdProducer.invalidCalls -ne 3 `
            -or [int]$CurrentResult.passiveInvalidGeneration.currentIdProducer.outerHandlers -ne 5 `
            -or [int]$CurrentResult.passiveInvalidGeneration.invalidFactory.accessor -lt 0 `
            -or [int]$CurrentResult.passiveInvalidGeneration.invalidFactory.max -lt 0 `
            -or [int]$CurrentResult.passiveInvalidGeneration.invalidFactory.constructor `
                -le [int]$CurrentResult.passiveInvalidGeneration.invalidFactory.max `
            -or -not [bool]$CurrentResult.checks.schedulerEnqueueAcceptance `
            -or -not [bool]$CurrentResult.checks.uncertainMutationQuarantine `
            -or -not [bool]$CurrentResult.checks.callerCallbackEffectTopology `
            -or -not [bool]$CurrentResult.schedulerPolicy.passiveDelayReservation `
            -or -not [bool]$CurrentResult.schedulerPolicy.manualPassiveDelayBypass `
            -or -not [bool]$CurrentResult.schedulerPolicy.retiredCapacityAbsence `
            -or -not [bool]$CurrentResult.schedulerPolicy.postReservationNonClearing `
            -or -not [bool]$CurrentResult.schedulerPolicy.completePassiveAuthority) {
        throw 'Current single-target bridge-flow fixture did not return the exact reviewed structural evidence.'
    }
}

$repositoryRoot = Get-PatchletRepositoryRoot
$scratchFull = Assert-PatchletPathUnderRoot `
    -Path ([IO.Path]::GetFullPath($ScratchRoot)) -Root (Join-Path $repositoryRoot 'work')
if (Test-Path -LiteralPath $scratchFull) { throw "ScratchRoot must be fresh: $scratchFull" }
[IO.Directory]::CreateDirectory($scratchFull) | Out-Null

$resolution = Read-PatchletJson -Path ([IO.Path]::GetFullPath($ResolutionPath))
$apktoolJar = Join-Path $repositoryRoot '.tools\apktool\apktool_3.0.3.jar'
$inspectorSource = Join-Path $PSScriptRoot 'DexBridgeFlowInspector.java'
$assemblerSource = Join-Path $PSScriptRoot 'DexBridgeFlowFixtureAssembler.java'
$buildJavaInjection = Join-Path $PSScriptRoot 'Build-JavaInjection.ps1'
$fixtureRoot = Join-Path $repositoryRoot 'patchlets\assets\release-gates\dex-bridge-flow'
$positiveRoot = Join-Path $fixtureRoot 'positive\smali'
$negativeManifestPath = Join-Path $fixtureRoot 'negative\fixtures.json'
$singleTargetNegativeManifestPath = Join-Path $fixtureRoot `
    'negative-passive-delay\fixtures.json'
foreach ($required in @(
        $apktoolJar, $inspectorSource, $assemblerSource, $buildJavaInjection,
        $positiveRoot, $negativeManifestPath, $singleTargetNegativeManifestPath,
        $AndroidSdk, $SevenZip)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required bridge-flow fixture input is missing: $required"
    }
}
if ((Get-PatchletSha256 -Path $apktoolJar) -ne [string]$resolution.toolchain.apktoolJarSha256 `
        -or (Get-PatchletSha256 -Path $inspectorSource) `
            -ne [string]$resolution.assets.dexBridgeFlowInspectorSourceSha256 `
        -or (Get-PatchletSha256 -Path $assemblerSource) `
            -ne [string]$resolution.assets.dexBridgeFlowFixtureAssemblerSourceSha256 `
        -or (Get-PatchletTreeSha256 -Root $fixtureRoot -Filter '*') `
            -ne [string]$resolution.assets.dexBridgeFlowFixtureTreeSha256) {
    throw 'Bridge-flow fixture tool or source hash differs from the exact resolution.'
}

$negativeManifest = Read-PatchletJson -Path $negativeManifestPath
$negativeFixtures = @($negativeManifest.fixtures)
$singleTargetNegativeManifest = Read-PatchletJson `
    -Path $singleTargetNegativeManifestPath
$singleTargetNegativeFixtures = @($singleTargetNegativeManifest.fixtures)
$expectedFixtureCount = 328
if ([int]$negativeManifest.schemaVersion -ne 1 `
        -or [int]$singleTargetNegativeManifest.schemaVersion -ne 1 `
        -or (1 + $negativeFixtures.Count) `
            -ne [int]$negativeManifest.expectedFixtureCount `
        -or (1 + $singleTargetNegativeFixtures.Count) `
            -ne [int]$singleTargetNegativeManifest.expectedFixtureCount `
        -or ([int]$negativeManifest.expectedFixtureCount `
            + [int]$singleTargetNegativeManifest.expectedFixtureCount) `
            -ne $expectedFixtureCount `
        -or [int]$expectedFixtureCount -ne 328 `
        -or [int]$resolution.release.expectedDexBridgeFlowFixtureCount `
            -ne $expectedFixtureCount `
        -or $negativeFixtures.Count -lt 1) {
    throw 'Bridge-flow negative fixture manifest count is invalid.'
}
$fixtureIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($fixture in $negativeFixtures) {
    $id = [string]$fixture.id
    if ([string]::IsNullOrWhiteSpace($id) -or -not $fixtureIds.Add($id) `
            -or [string]::IsNullOrWhiteSpace([string]$fixture.expectedCode)) {
        throw "Bridge-flow negative fixture identity is invalid: '$id'."
    }
}
foreach ($fixture in $singleTargetNegativeFixtures) {
    $id = [string]$fixture.id
    if ([string]::IsNullOrWhiteSpace($id) -or -not $fixtureIds.Add($id) `
            -or [string]::IsNullOrWhiteSpace([string]$fixture.expectedCode)) {
        throw "Bridge-flow single-target negative fixture identity is invalid: '$id'."
    }
}

$helperClasses = Join-Path $scratchFull 'helper-classes'
[IO.Directory]::CreateDirectory($helperClasses) | Out-Null
$null = Invoke-RequiredNative -Command $Javac -Arguments @(
    '-encoding', 'UTF-8', '-cp', $apktoolJar, '-d', $helperClasses,
    $inspectorSource, $assemblerSource)
$helperClasspath = $helperClasses + [IO.Path]::PathSeparator + $apktoolJar
$bridgeFlowContracts = @($resolution.release.requiredDexBridgeFlows | Where-Object {
        [string]$_.id -eq 'threads-block-bridge-flow-v1'
    })
if ($bridgeFlowContracts.Count -ne 1 `
        -or [string]::IsNullOrWhiteSpace(
            [string]$bridgeFlowContracts[0].fetchWorkerRunMethodReference) `
        -or [string]::IsNullOrWhiteSpace(
            [string]$bridgeFlowContracts[0].scheduleManualDrainMethodReference) `
        -or [string]$bridgeFlowContracts[0].inlineSymbolsPointer `
            -ne '/inlineControls/symbols' `
        -or -not [bool]$bridgeFlowContracts[0].requireStableInlinePrivateSeamAbsence) {
    throw 'Bridge-flow fixture contract is missing enqueue-owner or stable-inline private-seam requirements.'
}
$bridgeFlowContract = $bridgeFlowContracts[0]
$commonArguments = @(
    'Lthreadsmod/autoblock/ThreadsBlockBridge;',
    'block', 'blockResolved', 'blockModel', 'prepareModel',
    'Lfixture/Session;', 'Lfixture/Model;',
    'Lfixture/CacheLookup;->find(Lfixture/Session;Ljava/lang/String;)Lfixture/Model;',
    'Lfixture/CacheFactory;->create(Lfixture/Session;)Lfixture/Cache;',
    'Lfixture/Cache;->getOrPut(Lfixture/Seed;Ljava/lang/String;)Lfixture/Model;',
    'Lfixture/Model;->id()Ljava/lang/String;',
    'Lfixture/BlockState;->isBlocked(Lfixture/Model;)Z',
    'Lfixture/MutationApi;->block(Landroid/content/Context;Lfixture/ModelInterface;Lfixture/Session;Lfixture/MutationEvents;Ljava/lang/Integer;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;I)V',
    'fixture_surface', 'started', 'failed', 'ended', 'cancelled', 'succeeded',
    'Lfixture/MutationEvents;', 'Lfixture/AutomaticCaller;', 'Lfixture/ManualCaller;',
    [string]$bridgeFlowContract.fetchWorkerRunMethodReference,
    [string]$bridgeFlowContract.scheduleManualDrainMethodReference,
    'Lfixture/MediaLookup;->find(Lfixture/Session;Ljava/lang/String;)Lfixture/Media;',
    'Lfixture/MediaAuthor;->author(Lfixture/Media;)Lfixture/Model;',
    'Lfixture/Username;->name(Lfixture/Model;)Ljava/lang/String;')
$currentArguments = @(
    [string]$bridgeFlowContract.ownerClassDescriptor,
    [string]$bridgeFlowContract.blockMethodName,
    [string]$bridgeFlowContract.blockResolvedMethodName,
    [string]$bridgeFlowContract.blockModelMethodName,
    [string]$bridgeFlowContract.prepareModelMethodName,
    [string]$resolution.bridge.symbols.sessionDescriptor,
    [string]$resolution.bridge.symbols.modelDescriptor,
    [string]$resolution.bridge.symbols.cacheLookupMethod,
    [string]$resolution.bridge.symbols.userCacheFactoryMethod,
    [string]$resolution.bridge.symbols.userCacheGetOrPutMethod,
    [string]$resolution.bridge.symbols.authorIdMethod,
    [string]$resolution.bridge.symbols.alreadyBlockedMethod,
    [string]$resolution.bridge.symbols.blockMutationMethod,
    [string]$resolution.bridge.symbols.surface,
    [string]$resolution.bridge.symbols.mutationStartedCallback,
    [string]$resolution.bridge.symbols.mutationFailureCallback,
    [string]$resolution.bridge.symbols.mutationEndedCallback,
    [string]$resolution.bridge.symbols.mutationCancelCallback,
    [string]$resolution.bridge.symbols.mutationSuccessCallback,
    [string]$resolution.bridge.symbols.mutationCallbackInterface,
    [string]$bridgeFlowContract.automaticCallerClassDescriptor,
    [string]$bridgeFlowContract.manualCallerClassDescriptor,
    [string]$bridgeFlowContract.fetchWorkerRunMethodReference,
    [string]$bridgeFlowContract.scheduleManualDrainMethodReference,
    [string]$resolution.inlineControls.symbols.mediaLookupMethod,
    [string]$resolution.inlineControls.symbols.mediaAuthorMethod,
    [string]$resolution.inlineControls.symbols.authorUsernameMethod)
if ($currentArguments.Count -ne 27) {
    throw 'Current bridge-flow generated-Smali argument binding count drifted.'
}

function New-FixtureApk {
    param(
        [Parameter(Mandatory)][string]$FixtureScratch,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DexEntryName
    )
    [IO.Directory]::CreateDirectory($FixtureScratch) | Out-Null
    $dexPath = Join-Path $FixtureScratch $DexEntryName
    $null = Invoke-RequiredNative -Command $Java -Arguments @(
        '-cp', $helperClasspath, 'DexBridgeFlowFixtureAssembler', $SourceRoot, $dexPath)
    $apkPath = Join-Path $FixtureScratch 'fixture.apk'
    $null = Invoke-RequiredNative -Command $Jar -Arguments @(
        '--create', '--file', $apkPath, '-C', $FixtureScratch, $DexEntryName)
    return $apkPath
}

$results = @()
$positiveScratch = Join-Path $scratchFull 'positive'
$positiveSources = Join-Path $positiveScratch 'smali'
Copy-PatchletCompleteTree -SourceRoot $positiveRoot -DestinationRoot $positiveSources | Out-Null
$positiveApk = New-FixtureApk `
    -FixtureScratch $positiveScratch -SourceRoot $positiveSources -DexEntryName 'classes.dex'
$positiveProbe = Invoke-ProbeNative -Command $Java -Arguments (@(
    '-cp', $helperClasspath, 'DexBridgeFlowInspector', $positiveApk) + $commonArguments)
$positiveResult = Get-JsonResult -Lines $positiveProbe.lines -FixtureId 'positive'
if ($positiveProbe.exitCode -ne 0) {
    throw "Positive bridge-flow fixture failed with '$($positiveResult.code)'."
}
Assert-PositiveEvidence -Result $positiveResult
$results += [pscustomobject]@{
    id = 'positive'
    expectedPass = $true
    observedPass = $true
    code = $null
    dex = [string]$positiveResult.dex
}

foreach ($fixture in $negativeFixtures) {
    $fixtureId = [string]$fixture.id
    $fixtureScratch = Join-Path $scratchFull $fixtureId
    $fixtureSources = Join-Path $fixtureScratch 'smali'
    Copy-PatchletCompleteTree -SourceRoot $positiveRoot -DestinationRoot $fixtureSources | Out-Null
    Set-ExactFixtureMutations -SourceRoot $fixtureSources -Fixture $fixture
    $dexEntryProperty = $fixture.PSObject.Properties['dexEntryName']
    $dexEntryName = if ($null -eq $dexEntryProperty) {
        'classes.dex'
    } else {
        [string]$dexEntryProperty.Value
    }
    if ($dexEntryName -notin @('classes.dex', 'classes2.dex')) {
        throw "Bridge-flow fixture '$fixtureId' has an unsupported DEX entry name."
    }
    $fixtureApk = New-FixtureApk `
        -FixtureScratch $fixtureScratch -SourceRoot $fixtureSources -DexEntryName $dexEntryName
    $probe = Invoke-ProbeNative -Command $Java -Arguments (@(
        '-cp', $helperClasspath, 'DexBridgeFlowInspector', $fixtureApk) + $commonArguments)
    $parsed = Get-JsonResult -Lines $probe.lines -FixtureId $fixtureId
    $observedCode = if ($probe.exitCode -eq 0 `
            -and [string]$parsed.status -eq 'passed' `
            -and [string]$parsed.dex -ne 'classes.dex') {
        'unexpected_dex'
    } elseif ($probe.exitCode -ne 0 -and [string]$parsed.status -eq 'failed') {
        [string]$parsed.code
    } else {
        'unexpected_result'
    }
    if ($observedCode -ne [string]$fixture.expectedCode) {
        throw "Bridge-flow fixture '$fixtureId' returned '$observedCode', expected '$($fixture.expectedCode)'."
    }
    $results += [pscustomobject]@{
        id = $fixtureId
        expectedPass = $false
        observedPass = $false
        code = $observedCode
        dex = if ($parsed.PSObject.Properties['dex']) { [string]$parsed.dex } else { $null }
    }
}

$currentPositiveScratch = Join-Path $scratchFull 'positive-single-target'
$currentDecodedRoot = Join-Path $currentPositiveScratch 'decoded'
$currentSmaliRoot = Join-Path $currentDecodedRoot 'smali'
[IO.Directory]::CreateDirectory($currentSmaliRoot) | Out-Null
$currentBuildScratch = Join-Path $currentPositiveScratch 'java-injection'
$frameworkDirectory = Join-Path $repositoryRoot 'decompiled\apktool-framework'
$null = & $buildJavaInjection `
    -DecodedRoot $currentDecodedRoot `
    -ScratchRoot $currentBuildScratch `
    -ResolutionPath ([IO.Path]::GetFullPath($ResolutionPath)) `
    -AndroidSdk $AndroidSdk `
    -BuildToolsVersion $BuildToolsVersion `
    -Java $Java `
    -Javac $Javac `
    -Jar $Jar `
    -SevenZip $SevenZip `
    -ApktoolJar $apktoolJar `
    -FrameworkDirectory $frameworkDirectory
$currentPositiveApk = New-FixtureApk `
    -FixtureScratch $currentPositiveScratch `
    -SourceRoot $currentSmaliRoot -DexEntryName 'classes.dex'
$currentPositiveProbe = Invoke-ProbeNative -Command $Java -Arguments (@(
    '-cp', $helperClasspath, 'DexBridgeFlowInspector', $currentPositiveApk) `
    + $currentArguments)
$currentPositiveResult = Get-JsonResult `
    -Lines $currentPositiveProbe.lines -FixtureId 'positive-single-target'
if ($currentPositiveProbe.exitCode -ne 0) {
    throw "Current single-target bridge-flow fixture failed with '$($currentPositiveResult.code)'."
}
Assert-SingleTargetPositiveEvidence `
    -CurrentResult $currentPositiveResult `
    -Contract $bridgeFlowContract `
    -Symbols $resolution.bridge.symbols
$results += [pscustomobject]@{
    id = 'positive-single-target'
    expectedPass = $true
    observedPass = $true
    code = $null
    dex = [string]$currentPositiveResult.dex
    ownerMode = [string]$currentPositiveResult.callerProvenance.automatic.ownerMode
}

foreach ($fixture in $singleTargetNegativeFixtures) {
    $fixtureId = [string]$fixture.id
    $fixtureScratch = Join-Path $scratchFull $fixtureId
    $fixtureSources = Join-Path $fixtureScratch 'smali'
    Copy-PatchletCompleteTree `
        -SourceRoot $currentSmaliRoot -DestinationRoot $fixtureSources | Out-Null
    Set-ExactFixtureMutations -SourceRoot $fixtureSources -Fixture $fixture
    $fixtureApk = New-FixtureApk `
        -FixtureScratch $fixtureScratch `
        -SourceRoot $fixtureSources -DexEntryName 'classes.dex'
    $probe = Invoke-ProbeNative -Command $Java -Arguments (@(
        '-cp', $helperClasspath, 'DexBridgeFlowInspector', $fixtureApk) `
        + $currentArguments)
    $parsed = Get-JsonResult -Lines $probe.lines -FixtureId $fixtureId
    $observedCode = if ($probe.exitCode -ne 0 `
            -and [string]$parsed.status -eq 'failed') {
        [string]$parsed.code
    } else {
        'unexpected_result'
    }
    if ($observedCode -ne [string]$fixture.expectedCode) {
        throw "Bridge-flow single-target fixture '$fixtureId' returned '$observedCode', expected '$($fixture.expectedCode)'."
    }
    $results += [pscustomobject]@{
        id = $fixtureId
        expectedPass = $false
        observedPass = $false
        code = $observedCode
        dex = if ($parsed.PSObject.Properties['dex']) {
            [string]$parsed.dex
        } else {
            $null
        }
    }
}

if ($results.Count -ne 328) {
    throw "Bridge-flow fixture count drifted: expected 328, observed $($results.Count)."
}
$report = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToString('o')
    status = 'passed'
    expectedFixtureCount = $expectedFixtureCount
    fixtures = $results
}
if ($ReportPath) {
    Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath))
}
[pscustomobject]$report
