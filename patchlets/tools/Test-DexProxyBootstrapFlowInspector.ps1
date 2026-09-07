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
        throw "Native proxy-bootstrap fixture command failed with exit code $code for $Command"
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
        throw "Proxy-bootstrap fixture '$FixtureId' returned no evidence."
    }
    $line = [string]$Lines[-1]
    if ($line.Length -gt 16384) {
        throw "Proxy-bootstrap fixture '$FixtureId' returned oversized evidence."
    }
    try { return $line | ConvertFrom-Json }
    catch { throw "Proxy-bootstrap fixture '$FixtureId' returned invalid JSON evidence." }
}

function Get-FixtureRelativePath {
    param(
        [Parameter(Mandatory)][object]$Fixture,
        [Parameter(Mandatory)][object]$Replacement
    )
    $relativePath = if ($Replacement.PSObject.Properties['relativePath']) {
        [string]$Replacement.relativePath
    } else {
        [string]$Fixture.relativePath
    }
    if ([string]::IsNullOrWhiteSpace($relativePath) -or
            [IO.Path]::IsPathRooted($relativePath) -or
            $relativePath.Contains('..', [StringComparison]::Ordinal)) {
        throw "Proxy-bootstrap fixture '$($Fixture.id)' has an invalid relative path."
    }
    return $relativePath
}

function Set-ExactFixtureMutations {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][object]$Fixture
    )
    $appliedReplacements = 0
    foreach ($replacement in @($Fixture.replacements)) {
        $relativePath = Get-FixtureRelativePath -Fixture $Fixture -Replacement $replacement
        $target = Assert-PatchletPathUnderRoot -Path (
            [IO.Path]::GetFullPath((Join-Path $SourceRoot $relativePath))) -Root $SourceRoot
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Proxy-bootstrap fixture '$($Fixture.id)' targets a missing source."
        }
        $content = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
        $before = [string]$replacement.before
        $after = [string]$replacement.after
        $expectedCount = [int]$replacement.expectedCount
        if ([string]::IsNullOrEmpty($before) -or $expectedCount -lt 1 -or
                $before.Equals($after, [StringComparison]::Ordinal)) {
            throw "Proxy-bootstrap fixture '$($Fixture.id)' has an invalid replacement."
        }
        $observedCount = [regex]::Matches(
            $content, [regex]::Escape($before),
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
        if ($observedCount -ne $expectedCount) {
            throw "Proxy-bootstrap fixture '$($Fixture.id)' replacement count drifted: expected $expectedCount, observed $observedCount."
        }
        $content = $content.Replace($before, $after)
        [IO.File]::WriteAllText($target, $content, [Text.UTF8Encoding]::new($false))
        $appliedReplacements += $observedCount
    }
    if ($appliedReplacements -lt 1) {
        throw "Proxy-bootstrap fixture '$($Fixture.id)' applies no mutation."
    }
}

$repositoryRoot = Get-PatchletRepositoryRoot
$scratchFull = Assert-PatchletPathUnderRoot -Path (
    [IO.Path]::GetFullPath($ScratchRoot)) -Root (Join-Path $repositoryRoot 'work')
if (Test-Path -LiteralPath $scratchFull) { throw "ScratchRoot must be fresh: $scratchFull" }
[IO.Directory]::CreateDirectory($scratchFull) | Out-Null

$resolution = Read-PatchletJson -Path ([IO.Path]::GetFullPath($ResolutionPath))
$contract = $resolution.release.requiredDexProxyBootstrapFlow
$layout = if ([string]$contract.expectedDexName -ceq 'classes10.dex' -and
        [string]$contract.originalNextFieldReference -ceq 'LX/319;->A05:LX/319;') {
    [pscustomobject][ordered]@{
        positiveDirectory = 'positive'
        negativeManifest = 'fixtures.json'
        thisRegister = 18
        contextRegister = 19
        superOffset = 4
        bootstrapOffset = 7
        originalAnchorOffset = 10
    }
} elseif ([string]$contract.expectedDexName -ceq 'classes6.dex' -and
        [string]$contract.originalNextFieldReference -ceq 'LX/0143;->A06:LX/0143;') {
    [pscustomobject][ordered]@{
        positiveDirectory = 'positive-444'
        negativeManifest = 'fixtures-444.json'
        thisRegister = 22
        contextRegister = 23
        superOffset = 8
        bootstrapOffset = 11
        originalAnchorOffset = 14
    }
} else {
    throw 'Proxy-bootstrap fixture harness has no reviewed layout for this exact resolution.'
}
$apktoolJar = Join-Path $repositoryRoot '.tools\apktool\apktool_3.0.3.jar'
$inspectorSource = Join-Path $PSScriptRoot 'DexProxyBootstrapFlowInspector.java'
$assemblerSource = Join-Path $PSScriptRoot 'DexBridgeFlowFixtureAssembler.java'
$fixtureRoot = Join-Path $repositoryRoot 'patchlets\assets\release-gates\dex-proxy-bootstrap-flow'
$positiveRoot = Join-Path $fixtureRoot ([string]$layout.positiveDirectory + '\smali')
$negativeManifestPath = Join-Path $fixtureRoot ('negative\' + [string]$layout.negativeManifest)
foreach ($required in @(
        $apktoolJar, $inspectorSource, $assemblerSource,
        $positiveRoot, $negativeManifestPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required proxy-bootstrap fixture input is missing: $required"
    }
}
if ((Get-PatchletSha256 -Path $apktoolJar) -ne [string]$resolution.toolchain.apktoolJarSha256 -or
        (Get-PatchletSha256 -Path $inspectorSource) -ne
            [string]$resolution.assets.dexProxyBootstrapFlowInspectorSourceSha256 -or
        (Get-PatchletSha256 -Path $assemblerSource) -ne
            [string]$resolution.assets.dexBridgeFlowFixtureAssemblerSourceSha256 -or
        (Get-PatchletTreeSha256 -Root $fixtureRoot -Filter '*') -ne
            [string]$resolution.assets.dexProxyBootstrapFlowFixtureTreeSha256) {
    throw 'Proxy-bootstrap flow fixture tool or source hash differs from the exact resolution.'
}

$negativeManifest = Read-PatchletJson -Path $negativeManifestPath
$negativeFixtures = @($negativeManifest.fixtures)
$expectedFixtureCount = [int]$negativeManifest.expectedFixtureCount
$inspectorArgumentCount = 11
if ([int]$negativeManifest.schemaVersion -ne 1 -or
        (1 + $negativeFixtures.Count) -ne $expectedFixtureCount -or
        [int]$expectedFixtureCount -ne 13 -or
        [int]$resolution.release.expectedDexProxyBootstrapFlowFixtureCount -ne 13 -or
        [int]$inspectorArgumentCount -ne 11 -or
        [int]$resolution.release.expectedDexProxyBootstrapFlowInspectorArgumentCount -ne 11 -or
        $negativeFixtures.Count -lt 1) {
    throw 'Proxy-bootstrap negative fixture manifest count is invalid.'
}
$fixtureIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($fixture in $negativeFixtures) {
    $id = [string]$fixture.id
    if ([string]::IsNullOrWhiteSpace($id) -or -not $fixtureIds.Add($id) -or
            [string]::IsNullOrWhiteSpace([string]$fixture.expectedCode) -or
            [string]$fixture.expectedCode -eq 'unexpected_result' -or
            @($fixture.replacements).Count -lt 1) {
        throw "Proxy-bootstrap fixture identity is invalid: '$id'."
    }
}

$expectedFallbackMethods = @(
    'Landroid/net/VpnService$Builder;->allowBypass()Landroid/net/VpnService$Builder;',
    'Ljava/lang/System;->setProperty(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;',
    'Ljava/net/ProxySelector;->setDefault(Ljava/net/ProxySelector;)V'
)
$expectedFallbackStrings = @(
    'socksProxyHost',
    'socksProxyPort',
    'java.net.useSystemProxies'
)
$expectedMethodText = [string]::Join([char]10, $expectedFallbackMethods)
$expectedStringText = [string]::Join([char]10, $expectedFallbackStrings)
if ([string]$contract.id -ne 'socks5-bootstrap-signed-dex-flow-contract' -or
        [string]::Join([char]10, @($contract.forbiddenMethodReferences)) -ne
            $expectedMethodText -or
        [string]::Join([char]10, @($contract.forbiddenStringLiterals)) -ne
            $expectedStringText -or
        -not [bool]$contract.requireExactEntryPrefix -or
        -not [bool]$contract.requireSoleBootstrapCaller -or
        -not [bool]$contract.requireParameterRegisterFlow -or
        -not [bool]$contract.requireImmediateAdjacency -or
        -not [bool]$contract.requireNoAlternateEntry -or
        -not [bool]$contract.requireNoBootstrapTryCoverage -or
        -not [bool]$contract.requireOriginalNextField -or
        -not [bool]$contract.requireExactFallbackAbsence) {
    throw 'Proxy-bootstrap signed-Dex contract metadata is incomplete.'
}
$commonArguments = @(
    [string]$contract.expectedDexName,
    [string]$contract.ownerClassDescriptor,
    [string]$contract.ownerMethodName,
    [string]$contract.ownerMethodDescriptor,
    [string]$contract.superClassDescriptor,
    [string]$contract.superMethodName,
    [string]$contract.superMethodDescriptor,
    [string]$contract.bootstrapClassDescriptor,
    [string]$contract.bootstrapMethodName,
    [string]$contract.bootstrapMethodDescriptor)

$helperClasses = Join-Path $scratchFull 'helper-classes'
[IO.Directory]::CreateDirectory($helperClasses) | Out-Null
$null = Invoke-RequiredNative -Command $Javac -Arguments @(
    '-encoding', 'UTF-8', '-cp', $apktoolJar, '-d', $helperClasses,
    $inspectorSource, $assemblerSource)
$helperClasspath = $helperClasses + [IO.Path]::PathSeparator + $apktoolJar

$mutationGuardScratch = Join-Path $scratchFull 'mutation-guard'
Copy-PatchletCompleteTree -SourceRoot $positiveRoot -DestinationRoot $mutationGuardScratch |
    Out-Null
$mutationGuardCaught = $false
try {
    Set-ExactFixtureMutations -SourceRoot $mutationGuardScratch -Fixture ([pscustomobject]@{
        id = 'unchanged-mutation-guard'
        relativePath = 'com/instagram/barcelona/app/BarcelonaAppShell.smali'
        replacements = @([pscustomobject]@{
            before = '.class public final Lcom/instagram/barcelona/app/BarcelonaAppShell;'
            after = '.class public final Lcom/instagram/barcelona/app/BarcelonaAppShell;'
            expectedCount = 1
        })
    })
} catch {
    $mutationGuardCaught = $true
}
if (-not $mutationGuardCaught) {
    throw 'Proxy-bootstrap fixture mutation guard accepted an unchanged replacement.'
}

function New-FixtureApk {
    param(
        [Parameter(Mandatory)][string]$FixtureScratch,
        [Parameter(Mandatory)][string]$SourceRoot
    )
    [IO.Directory]::CreateDirectory($FixtureScratch) | Out-Null
    $dexPath = Join-Path $FixtureScratch ([string]$contract.expectedDexName)
    $null = Invoke-RequiredNative -Command $Java -Arguments @(
        '-cp', $helperClasspath, 'DexBridgeFlowFixtureAssembler', $SourceRoot, $dexPath)
    $apkPath = Join-Path $FixtureScratch 'fixture.apk'
    $null = Invoke-RequiredNative -Command $Jar -Arguments @(
        '--create', '--file', $apkPath, '-C', $FixtureScratch,
        [string]$contract.expectedDexName)
    return $apkPath
}

$results = @()
$positiveScratch = Join-Path $scratchFull 'positive'
$positiveSources = Join-Path $positiveScratch 'smali'
Copy-PatchletCompleteTree -SourceRoot $positiveRoot -DestinationRoot $positiveSources |
    Out-Null
$positiveApk = New-FixtureApk -FixtureScratch $positiveScratch -SourceRoot $positiveSources
$positiveProbe = Invoke-ProbeNative -Command $Java -Arguments (@(
    '-cp', $helperClasspath, 'DexProxyBootstrapFlowInspector',
    $positiveApk) + $commonArguments)
$positiveResult = Get-JsonResult -Lines $positiveProbe.lines -FixtureId 'positive'
if ($positiveProbe.exitCode -ne 0 -or
        [string]$positiveResult.status -ne 'passed' -or
        [string]$positiveResult.contract -ne [string]$contract.id -or
        [string]$positiveResult.dex -ne [string]$contract.expectedDexName -or
        [string]$positiveResult.owner -ne [string]$contract.ownerClassDescriptor -or
        [string]$positiveResult.method -ne
            ([string]$contract.ownerMethodName + [string]$contract.ownerMethodDescriptor) -or
        [string]$positiveResult.originalAnchorField -ne
            [string]$contract.originalNextFieldReference -or
        [string]::Join([char]10, @($positiveResult.forbiddenFallbackMethods)) -ne
            $expectedMethodText -or
        [string]::Join([char]10, @($positiveResult.forbiddenFallbackStrings)) -ne
            $expectedStringText -or
        [int]$positiveResult.bootstrapCallCount -ne 1 -or
        [int]$positiveResult.thisRegister -ne [int]$layout.thisRegister -or
        [int]$positiveResult.contextRegister -ne [int]$layout.contextRegister -or
        [int]$positiveResult.superOffset -ne [int]$layout.superOffset -or
        [int]$positiveResult.bootstrapOffset -ne [int]$layout.bootstrapOffset -or
        [int]$positiveResult.originalAnchorOffset -ne
            [int]$layout.originalAnchorOffset -or
        $positiveResult.checks.exactEntryPrefix -ne $true -or
        $positiveResult.checks.soleBootstrapCaller -ne $true -or
        $positiveResult.checks.sameContextRegister -ne $true -or
        $positiveResult.checks.adjacentAfterSuper -ne $true -or
        $positiveResult.checks.noAlternateEntry -ne $true -or
        $positiveResult.checks.outsideTryRanges -ne $true -or
        $positiveResult.checks.originalAnchorAdjacent -ne $true -or
        $positiveResult.checks.fallbackReferencesAbsent -ne $true) {
    throw "Positive proxy-bootstrap fixture failed with '$($positiveResult.code)'."
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
    Copy-PatchletCompleteTree -SourceRoot $positiveRoot -DestinationRoot $fixtureSources |
        Out-Null
    Set-ExactFixtureMutations -SourceRoot $fixtureSources -Fixture $fixture
    $fixtureApk = New-FixtureApk -FixtureScratch $fixtureScratch -SourceRoot $fixtureSources
    $probe = Invoke-ProbeNative -Command $Java -Arguments (@(
        '-cp', $helperClasspath, 'DexProxyBootstrapFlowInspector',
        $fixtureApk) + $commonArguments)
    $parsed = Get-JsonResult -Lines $probe.lines -FixtureId $fixtureId
    $observedCode = if ($probe.exitCode -ne 0 -and
            [string]$parsed.status -eq 'failed' -and
            [string]$parsed.contract -eq [string]$contract.id) {
        [string]$parsed.code
    } else {
        'unexpected_result'
    }
    if ($observedCode -ne [string]$fixture.expectedCode) {
        throw "Proxy-bootstrap fixture '$fixtureId' returned '$observedCode', expected '$($fixture.expectedCode)'."
    }
    $results += [pscustomobject]@{
        id = $fixtureId
        expectedPass = $false
        observedPass = $false
        code = $observedCode
        dex = if ($parsed.PSObject.Properties['dex']) { [string]$parsed.dex } else { $null }
    }
}

if ($results.Count -ne 13) {
    throw "Proxy-bootstrap fixture count drifted: expected 13, observed $($results.Count)."
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
