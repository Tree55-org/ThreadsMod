[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScratchRoot,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$Java = 'java',
    [string]$Javac = 'javac',
    [string]$Jar = 'jar',
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
        throw "Native report-permalink fixture command failed with exit code ${code}: $Command"
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
    if (@($Lines).Count -eq 0) {
        throw "Report-permalink fixture '$FixtureId' returned no evidence."
    }
    $line = [string]$Lines[-1]
    if ($line.Length -gt 16384) {
        throw "Report-permalink fixture '$FixtureId' returned oversized evidence."
    }
    try { return $line | ConvertFrom-Json }
    catch { throw "Report-permalink fixture '$FixtureId' returned invalid JSON evidence." }
}

function Resolve-ReportFixtureTokens {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $resolved = $Text
    foreach ($entry in $script:reportFixtureTokens.GetEnumerator()) {
        $resolved = $resolved.Replace([string]$entry.Key, [string]$entry.Value)
    }
    $unresolved = @([regex]::Matches($resolved, '\{\{[^{}]+\}\}') |
        ForEach-Object Value | Sort-Object -Unique)
    if ($unresolved.Count -ne 0) {
        throw "Report-permalink fixture contains unresolved tokens: $($unresolved -join ', ')"
    }
    return $resolved
}

function Expand-ReportFactoryFixture {
    param([Parameter(Mandatory)][string]$SourceRoot)

    $relativePath = 'threadsmod/reporting/InlineReportActionFactory.smali'
    $path = Assert-PatchletPathUnderRoot `
        -Path ([IO.Path]::GetFullPath((Join-Path $SourceRoot $relativePath))) -Root $SourceRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Report-permalink factory fixture is missing.'
    }
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $expectedTokenCounts = [ordered]@{
        '{{mediaDescriptor}}' = 1
        '{{mediaReceiverSetup}}' = 1
        '{{mediaInvokeOpcode}}' = 3
        '{{mediaPermalinkMethod}}' = 1
        '{{mediaCodeMethod}}' = 1
        '{{mediaCaptionMethod}}' = 1
        '{{captionTextMethod}}' = 1
    }
    foreach ($entry in $expectedTokenCounts.GetEnumerator()) {
        $count = [regex]::Matches(
            $text, [regex]::Escape([string]$entry.Key),
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
        if ($count -ne [int]$entry.Value) {
            throw "Report-permalink factory token '$($entry.Key)' count drifted."
        }
    }
    [IO.File]::WriteAllText(
        $path, (Resolve-ReportFixtureTokens -Text $text),
        [Text.UTF8Encoding]::new($false))
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
        throw "Report-permalink fixture '$($Fixture.id)' has an invalid relative path."
    }
    $target = Assert-PatchletPathUnderRoot `
        -Path ([IO.Path]::GetFullPath((Join-Path $SourceRoot $relativePath))) -Root $SourceRoot
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        throw "Report-permalink fixture '$($Fixture.id)' targets a missing source."
    }
    $content = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
    $appliedReplacements = 0
    foreach ($replacement in @($Fixture.replacements)) {
        $before = Resolve-ReportFixtureTokens -Text ([string]$replacement.before)
        $after = Resolve-ReportFixtureTokens -Text ([string]$replacement.after)
        $expectedCount = [int]$replacement.expectedCount
        if ([string]::IsNullOrEmpty($before) -or $expectedCount -lt 1 `
                -or $before.Equals($after, [StringComparison]::Ordinal)) {
            throw "Report-permalink fixture '$($Fixture.id)' has an invalid replacement."
        }
        $observedCount = [regex]::Matches(
            $content, [regex]::Escape($before),
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
        if ($observedCount -ne $expectedCount) {
            throw "Report-permalink fixture '$($Fixture.id)' replacement count drifted: expected $expectedCount, observed $observedCount."
        }
        $content = $content.Replace($before, $after)
        $appliedReplacements += $observedCount
    }
    if ($appliedReplacements -lt 1) {
        throw "Report-permalink fixture '$($Fixture.id)' applies no mutation."
    }
    [IO.File]::WriteAllText($target, $content, [Text.UTF8Encoding]::new($false))
}

$repositoryRoot = Get-PatchletRepositoryRoot
$scratchFull = Assert-PatchletPathUnderRoot `
    -Path ([IO.Path]::GetFullPath($ScratchRoot)) -Root (Join-Path $repositoryRoot 'work')
if (Test-Path -LiteralPath $scratchFull) { throw "ScratchRoot must be fresh: $scratchFull" }
[IO.Directory]::CreateDirectory($scratchFull) | Out-Null

$resolution = Read-PatchletJson -Path ([IO.Path]::GetFullPath($ResolutionPath))
$mediaDescriptor = [string]$resolution.reporting.symbols.mediaDescriptor
$mediaBackingField = [string]$resolution.reporting.symbols.mediaBackingField
$mediaPermalinkMethod = [string]$resolution.reporting.symbols.mediaPermalinkMethod
$mediaCodeMethod = [string]$resolution.reporting.symbols.mediaCodeMethod
$mediaCaptionMethod = [string]$resolution.reporting.symbols.mediaCaptionMethod
$captionTextMethod = [string]$resolution.reporting.symbols.captionTextMethod
$mediaBackingMatch = [regex]::Match($mediaBackingField, '^(?<owner>L[^;]+;)->')
$mediaPermalinkMatch = [regex]::Match($mediaPermalinkMethod, '^(?<owner>L[^;]+;)->')
$mediaCodeMatch = [regex]::Match($mediaCodeMethod, '^(?<owner>L[^;]+;)->')
$mediaCaptionMatch = [regex]::Match($mediaCaptionMethod, '^(?<owner>L[^;]+;)->')
if (-not $mediaBackingMatch.Success `
        -or -not $mediaPermalinkMatch.Success `
        -or -not $mediaCodeMatch.Success `
        -or -not $mediaCaptionMatch.Success `
        -or $mediaBackingMatch.Groups['owner'].Value -cne $mediaDescriptor) {
    throw 'Report-permalink fixture symbols have invalid owner descriptors.'
}
$directMediaAccess =
    $mediaBackingMatch.Groups['owner'].Value -ceq $mediaPermalinkMatch.Groups['owner'].Value `
    -and $mediaBackingMatch.Groups['owner'].Value -ceq $mediaCodeMatch.Groups['owner'].Value `
    -and $mediaBackingMatch.Groups['owner'].Value -ceq $mediaCaptionMatch.Groups['owner'].Value
$script:reportFixtureTokens = [ordered]@{
    '{{mediaDescriptor}}' = $mediaDescriptor
    '{{mediaReceiverSetup}}' = if ($directMediaAccess) {
        ''
    } else {
        '    iget-object v0, v0, ' + $mediaBackingField
    }
    '{{mediaInvokeOpcode}}' = if ($directMediaAccess) { 'invoke-virtual' } else { 'invoke-interface' }
    '{{mediaPermalinkMethod}}' = $mediaPermalinkMethod
    '{{mediaCodeMethod}}' = $mediaCodeMethod
    '{{mediaCaptionMethod}}' = $mediaCaptionMethod
    '{{captionTextMethod}}' = $captionTextMethod
}
$apktoolJar = Join-Path $repositoryRoot '.tools\apktool\apktool_3.0.3.jar'
$inspectorSource = Join-Path $PSScriptRoot 'DexReportPermalinkFlowInspector.java'
$assemblerSource = Join-Path $PSScriptRoot 'DexBridgeFlowFixtureAssembler.java'
$fixtureRoot = Join-Path $repositoryRoot 'patchlets\assets\release-gates\dex-report-permalink-flow'
$positiveRoot = Join-Path $fixtureRoot 'positive\smali'
$negativeManifestPath = Join-Path $fixtureRoot 'negative\fixtures.json'
foreach ($required in @(
        $apktoolJar, $inspectorSource, $assemblerSource,
        $positiveRoot, $negativeManifestPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required report-permalink fixture input is missing: $required"
    }
}
if ((Get-PatchletSha256 -Path $apktoolJar) -ne [string]$resolution.toolchain.apktoolJarSha256 `
        -or (Get-PatchletSha256 -Path $inspectorSource) `
            -ne [string]$resolution.assets.dexReportPermalinkFlowInspectorSourceSha256 `
        -or (Get-PatchletSha256 -Path $assemblerSource) `
            -ne [string]$resolution.assets.dexBridgeFlowFixtureAssemblerSourceSha256 `
        -or (Get-PatchletTreeSha256 -Root $fixtureRoot -Filter '*') `
            -ne [string]$resolution.assets.dexReportPermalinkFlowFixtureTreeSha256) {
    throw 'Report-permalink flow fixture tool or source hash differs from the exact resolution.'
}

$negativeManifest = Read-PatchletJson -Path $negativeManifestPath
$negativeFixtures = @($negativeManifest.fixtures)
$expectedFixtureCount = [int]$negativeManifest.expectedFixtureCount
$inspectorArgumentCount = 33
if ([int]$negativeManifest.schemaVersion -ne 1 `
        -or (1 + $negativeFixtures.Count) -ne $expectedFixtureCount `
        -or [int]$expectedFixtureCount -ne 41 `
        -or [int]$resolution.release.expectedDexReportPermalinkFlowFixtureCount -ne 41 `
        -or [int]$inspectorArgumentCount -ne 33 `
        -or [int]$resolution.release.expectedDexReportPermalinkFlowInspectorArgumentCount -ne 33 `
        -or $negativeFixtures.Count -lt 1) {
    throw 'Report-permalink negative fixture manifest count is invalid.'
}
$fixtureIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($fixture in $negativeFixtures) {
    $id = [string]$fixture.id
    if ([string]::IsNullOrWhiteSpace($id) -or -not $fixtureIds.Add($id) `
            -or [string]::IsNullOrWhiteSpace([string]$fixture.expectedCode) `
            -or [string]$fixture.expectedCode -eq 'unexpected_result') {
        throw "Report-permalink fixture identity is invalid: '$id'."
    }
}

$contract = $resolution.release.requiredDexReportPermalinkFlow
if ([string]$contract.id -ne 'report-post-permalink-contract' `
        -or [string]$contract.expectedDexName -ne 'classes.dex' `
        -or [string]$contract.mediaPermalinkMethodPointer `
            -ne '/reporting/symbols/mediaPermalinkMethod' `
        -or [string]$contract.mediaCodeMethodPointer `
            -ne '/reporting/symbols/mediaCodeMethod' `
        -or [string]$contract.mediaBackingFieldPointer `
            -ne '/reporting/symbols/mediaBackingField' `
        -or [string]$contract.mediaCaptionMethodPointer `
            -ne '/reporting/symbols/mediaCaptionMethod' `
        -or [string]$contract.captionTextMethodPointer `
            -ne '/reporting/symbols/captionTextMethod' `
        -or [string]$contract.ufiButtonMethodPointer `
            -ne '/inlineControls/symbols/ufiButtonMethod' `
        -or [string]$contract.visibilityModifierMethodPointer `
            -ne '/inlineControls/symbols/visibilityModifierMethod' `
        -or [string]$contract.testTagMethodPointer `
            -ne '/inlineControls/symbols/testTagMethod' `
        -or [string]$contract.modifierComposedMethodPointer `
            -ne '/inlineControls/symbols/modifierComposedMethod' `
        -or [int]$contract.ufiButtonDefaultMask -ne 63232) {
    throw 'Report-permalink signed-Dex contract metadata is incomplete.'
}
$commonArguments = @(
    [string]$contract.factoryMethodReference,
    [string]$contract.resolvedMediaGetterReference,
    [string]$resolution.reporting.symbols.mediaBackingField,
    [string]$resolution.reporting.symbols.mediaPermalinkMethod,
    [string]$resolution.reporting.symbols.mediaCaptionMethod,
    [string]$contract.requestConstructorReference,
    [string]$contract.permalinkSanitizerMethodReference,
    [string]$contract.requestPermalinkFieldReference,
    [string]$contract.requestNewQueueValidityMethodReference,
    [string]$contract.requestBaseValidityMethodReference,
    [string]$contract.requestPermalinkGetterReference,
    [string]$contract.payloadToJsonMethodReference,
    [string]$contract.payloadRequestFieldReference,
    [string]$contract.jsonPutMethodReference,
    [string]$contract.jsonArrayPutMethodReference,
    [string]$contract.stringLengthMethodReference,
    [string]$contract.controllerQueueMethodReference,
    [string]$contract.clientQueueMethodReference,
    [string]$contract.threadStartMethodReference,
    [string]$contract.jsonArrayConstructorMethodReference,
    [string]$resolution.reporting.symbols.mediaCodeMethod,
    [string]$resolution.reporting.symbols.captionTextMethod,
    [string]$contract.permalinkResolverMethodReference,
    [string]$contract.excerptResolverMethodReference,
    [string]$contract.rowLabelGetterReference,
    [string]$contract.inlineRowRenderMethodReference,
    [string]$contract.currentViewerMethodReference,
    [string]$resolution.inlineControls.symbols.ufiButtonMethod,
    [string]$resolution.inlineControls.symbols.visibilityModifierMethod,
    [string]$resolution.inlineControls.symbols.testTagMethod,
    [string]$resolution.inlineControls.symbols.modifierComposedMethod,
    [string]$contract.ufiButtonDefaultMask)
if ($commonArguments.Count -ne 32) {
    throw 'Report-permalink generated-Smali semantic argument binding count drifted.'
}

$helperClasses = Join-Path $scratchFull 'helper-classes'
[IO.Directory]::CreateDirectory($helperClasses) | Out-Null
$null = Invoke-RequiredNative -Command $Javac -Arguments @(
    '-encoding', 'UTF-8', '-cp', $apktoolJar, '-d', $helperClasses,
    $inspectorSource, $assemblerSource)
$helperClasspath = $helperClasses + [IO.Path]::PathSeparator + $apktoolJar

$mutationGuardScratch = Join-Path $scratchFull 'mutation-guard'
Copy-PatchletCompleteTree -SourceRoot $positiveRoot -DestinationRoot $mutationGuardScratch | Out-Null
$mutationGuardCaught = $false
try {
    Set-ExactFixtureMutations -SourceRoot $mutationGuardScratch -Fixture ([pscustomobject]@{
        id = 'unchanged-mutation-guard'
        relativePath = 'threadsmod/reporting/ReportRequest.smali'
        replacements = @([pscustomobject]@{
            before = '.class public final Lthreadsmod/reporting/ReportRequest;'
            after = '.class public final Lthreadsmod/reporting/ReportRequest;'
            expectedCount = 1
        })
    })
} catch {
    $mutationGuardCaught = $true
}
if (-not $mutationGuardCaught) {
    throw 'Report-permalink fixture mutation guard accepted an unchanged replacement.'
}

function New-FixtureApk {
    param(
        [Parameter(Mandatory)][string]$FixtureScratch,
        [Parameter(Mandatory)][string]$SourceRoot
    )
    [IO.Directory]::CreateDirectory($FixtureScratch) | Out-Null
    $dexPath = Join-Path $FixtureScratch 'classes.dex'
    $null = Invoke-RequiredNative -Command $Java -Arguments @(
        '-cp', $helperClasspath, 'DexBridgeFlowFixtureAssembler', $SourceRoot, $dexPath)
    $apkPath = Join-Path $FixtureScratch 'fixture.apk'
    $null = Invoke-RequiredNative -Command $Jar -Arguments @(
        '--create', '--file', $apkPath, '-C', $FixtureScratch, 'classes.dex')
    return $apkPath
}

$results = @()
$positiveScratch = Join-Path $scratchFull 'positive'
$positiveSources = Join-Path $positiveScratch 'smali'
Copy-PatchletCompleteTree -SourceRoot $positiveRoot -DestinationRoot $positiveSources | Out-Null
Expand-ReportFactoryFixture -SourceRoot $positiveSources
$positiveApk = New-FixtureApk -FixtureScratch $positiveScratch -SourceRoot $positiveSources
$positiveProbe = Invoke-ProbeNative -Command $Java -Arguments (@(
    '-cp', $helperClasspath, 'DexReportPermalinkFlowInspector', $positiveApk) + $commonArguments)
$positiveResult = Get-JsonResult -Lines $positiveProbe.lines -FixtureId 'positive'
if ($positiveProbe.exitCode -ne 0 `
        -or [string]$positiveResult.status -ne 'passed' `
        -or [string]$positiveResult.contract -ne 'report-post-permalink-contract' `
        -or [string]$positiveResult.dex -ne 'classes.dex' `
        -or [int]$positiveResult.factory.codeCallOffset -lt 0 `
        -or [int]$positiveResult.factory.permalinkResolverOffset `
            -le [int]$positiveResult.factory.codeCallOffset `
        -or [int]$positiveResult.factory.permalinkFallbackGuardOffset `
            -le [int]$positiveResult.factory.permalinkResolverOffset `
        -or [int]$positiveResult.factory.permalinkCallOffset `
            -le [int]$positiveResult.factory.permalinkFallbackGuardOffset `
        -or [int]$positiveResult.factory.fallbackPermalinkResolverOffset `
            -le [int]$positiveResult.factory.permalinkCallOffset `
        -or [int]$positiveResult.factory.captionTextCallOffset `
            -le [int]$positiveResult.factory.fallbackPermalinkResolverOffset `
        -or [int]$positiveResult.factory.excerptResolverOffset `
            -le [int]$positiveResult.factory.captionTextCallOffset `
        -or [int]$positiveResult.factory.constructorOffset `
            -le [int]$positiveResult.factory.excerptResolverOffset `
        -or [int]$positiveResult.request.sanitizerOffset -lt 0 `
        -or [int]$positiveResult.request.storeOffset `
            -le [int]$positiveResult.request.sanitizerOffset `
        -or [int]$positiveResult.request.baseValidityGuardOffset -lt 0 `
        -or [int]$positiveResult.request.permalinkGuardOffset `
            -le [int]$positiveResult.request.baseValidityGuardOffset `
        -or [int]$positiveResult.payload.targetUrlOffset -lt 0 `
        -or [int]$positiveResult.payload.evidenceValueOffset `
            -le [int]$positiveResult.payload.targetUrlOffset `
        -or [int]$positiveResult.payload.evidenceContainerOffset `
            -le [int]$positiveResult.payload.evidenceValueOffset `
        -or [int]$positiveResult.queueBoundaries.controllerValidityGuardOffset -lt 0 `
        -or [int]$positiveResult.queueBoundaries.clientValidityGuardOffset -lt 0 `
        -or [int]$positiveResult.rowControl.visibilityModifierOffset -lt 0 `
        -or [int]$positiveResult.rowControl.testTagOffset `
            -le [int]$positiveResult.rowControl.visibilityModifierOffset `
        -or [int]$positiveResult.rowControl.modifierComposedOffset `
            -le [int]$positiveResult.rowControl.testTagOffset `
        -or [int]$positiveResult.rowControl.ufiButtonOffset `
            -le [int]$positiveResult.rowControl.modifierComposedOffset `
        -or [int]$positiveResult.rowControl.ufiButtonDefaultMask -ne 63232 `
        -or $positiveResult.checks.permalinkFieldFinal -ne $true `
        -or $positiveResult.checks.singlePermalinkWrite -ne $true `
        -or $positiveResult.checks.soleInitializedEvidenceEntry -ne $true `
        -or $positiveResult.checks.controllerBoundary -ne $true `
        -or $positiveResult.checks.clientBoundary -ne $true `
        -or $positiveResult.checks.hostPermalinkResolverFlow -ne $true `
        -or $positiveResult.checks.shortcodeFirstFallbackFlow -ne $true `
        -or $positiveResult.checks.hostExcerptResolverFlow -ne $true `
        -or $positiveResult.checks.factoryViewerGuardAbsent -ne $true `
        -or $positiveResult.checks.rowViewerGuardAbsent -ne $true `
        -or -not [bool]$positiveResult.checks.rowDecoratedModifierFlow `
        -or -not [bool]$positiveResult.checks.rowUfiDefaultMaskExact) {
    throw "Positive report-permalink fixture failed with '$($positiveResult.code)'."
}
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
    Expand-ReportFactoryFixture -SourceRoot $fixtureSources
    Set-ExactFixtureMutations -SourceRoot $fixtureSources -Fixture $fixture
    $fixtureApk = New-FixtureApk -FixtureScratch $fixtureScratch -SourceRoot $fixtureSources
    $probe = Invoke-ProbeNative -Command $Java -Arguments (@(
        '-cp', $helperClasspath, 'DexReportPermalinkFlowInspector', $fixtureApk) + $commonArguments)
    $parsed = Get-JsonResult -Lines $probe.lines -FixtureId $fixtureId
    $observedCode = if ($probe.exitCode -ne 0 -and [string]$parsed.status -eq 'failed') {
        [string]$parsed.code
    } else {
        'unexpected_result'
    }
    if ($observedCode -ne [string]$fixture.expectedCode) {
        throw "Report-permalink fixture '$fixtureId' returned '$observedCode', expected '$($fixture.expectedCode)'."
    }
    $results += [pscustomobject]@{
        id = $fixtureId
        expectedPass = $false
        observedPass = $false
        code = $observedCode
        dex = if ($parsed.PSObject.Properties['dex']) { [string]$parsed.dex } else { $null }
    }
}

if ($results.Count -ne 41) {
    throw "Report-permalink fixture count drifted: expected 41, observed $($results.Count)."
}
$report = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToString('o')
    status = 'passed'
    expectedFixtureCount = $expectedFixtureCount
    inspectorArgumentCount = $inspectorArgumentCount
    unchangedMutationRejected = $mutationGuardCaught
    fixtures = $results
}
if ($ReportPath) {
    Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath))
}
[pscustomobject]$report
