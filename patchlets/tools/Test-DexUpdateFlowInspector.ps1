[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScratchRoot,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$BuildToolsVersion = '36.0.0',
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
        throw "Native update-flow fixture command failed with exit code $code for $Command"
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
        throw "Update-flow fixture '$FixtureId' returned no evidence."
    }
    $line = [string]$Lines[-1]
    if ($line.Length -gt 32768) {
        throw "Update-flow fixture '$FixtureId' returned oversized evidence."
    }
    try { return $line | ConvertFrom-Json }
    catch { throw "Update-flow fixture '$FixtureId' returned invalid JSON evidence." }
}

function Test-ExactProperties {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string[]]$Names
    )
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    return [string]::Join([char]10, $actual) -ceq [string]::Join([char]10, $expected)
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
    $segments = @($relativePath -split '[\\/]')
    if ([string]::IsNullOrWhiteSpace($relativePath) -or
            [IO.Path]::IsPathRooted($relativePath) -or
            $segments -contains '..' -or $segments -contains '.' -or
            -not $relativePath.EndsWith('.java', [StringComparison]::Ordinal)) {
        throw "Update-flow fixture '$($Fixture.id)' has an invalid relative path."
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
            throw "Update-flow fixture '$($Fixture.id)' targets a missing source."
        }
        $content = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
        $before = [string]$replacement.before
        $after = [string]$replacement.after
        $expectedCount = [int]$replacement.expectedCount
        if ([string]::IsNullOrEmpty($before) -or [string]::IsNullOrEmpty($after) -or
                $before.Length -gt 65536 -or $after.Length -gt 65536 -or
                $expectedCount -lt 1 -or $expectedCount -gt 16 -or
                $before.Equals($after, [StringComparison]::Ordinal)) {
            throw "Update-flow fixture '$($Fixture.id)' has an invalid replacement."
        }
        $observedCount = [regex]::Matches(
            $content, [regex]::Escape($before),
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
        if ($observedCount -ne $expectedCount) {
            throw "Update-flow fixture '$($Fixture.id)' replacement count drifted: expected $expectedCount, observed $observedCount."
        }
        $content = $content.Replace($before, $after)
        [IO.File]::WriteAllText($target, $content, [Text.UTF8Encoding]::new($false))
        $appliedReplacements += $observedCount
    }
    if ($appliedReplacements -lt 1) {
        throw "Update-flow fixture '$($Fixture.id)' applies no mutation."
    }
}

$repositoryRoot = Get-PatchletRepositoryRoot
$workRoot = Join-Path $repositoryRoot 'work'
$scratchFull = Assert-PatchletPathUnderRoot -Path (
    [IO.Path]::GetFullPath($ScratchRoot)) -Root $workRoot
if (Test-Path -LiteralPath $scratchFull) { throw "ScratchRoot must be fresh: $scratchFull" }
[IO.Directory]::CreateDirectory($scratchFull) | Out-Null

$resolution = Read-PatchletJson -Path ([IO.Path]::GetFullPath($ResolutionPath))
$apktoolJar = Join-Path $repositoryRoot '.tools\apktool\apktool_3.0.3.jar'
$inspectorSource = Join-Path $PSScriptRoot 'DexUpdateFlowInspector.java'
$fixtureRoot = Join-Path $repositoryRoot 'patchlets\assets\release-gates\dex-update-flow'
$negativeManifestPath = Join-Path $fixtureRoot 'negative\fixtures.json'
$representationSource = Join-Path $fixtureRoot `
    'representation\EncodingNormalizationFixture.java'
$sourceRoot = Join-Path $repositoryRoot 'patchlets\assets\autoblock\java'
$eddsaJar = Join-Path $repositoryRoot (
    'patchlets\assets\autoblock\lib\net-i2p-crypto-eddsa-0.3.1.jar')
$androidJar = Join-Path $AndroidSdk (
    "platforms\android-$($resolution.toolchain.androidPlatform)\android.jar")
$d8Jar = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion\lib\d8.jar"
foreach ($required in @(
        $apktoolJar, $inspectorSource, $negativeManifestPath, $sourceRoot,
        $representationSource, $eddsaJar, $androidJar, $d8Jar)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required update-flow fixture input is missing: $required"
    }
}
if ($BuildToolsVersion -ne [string]$resolution.toolchain.buildToolsVersion -or
        [int]$resolution.source.minSdk -ne 28 -or
        (Get-PatchletSha256 -Path $apktoolJar) -ne
            [string]$resolution.toolchain.apktoolJarSha256 -or
        (Get-PatchletSha256 -Path $d8Jar) -ne
            [string]$resolution.toolchain.d8JarSha256 -or
        (Get-PatchletSha256 -Path $eddsaJar) -ne
            [string]$resolution.assets.eddsaJarSha256 -or
        (Get-PatchletSha256 -Path $inspectorSource) -ne
            [string]$resolution.assets.dexUpdateFlowInspectorSourceSha256 -or
        (Get-PatchletTreeSha256 -Root $fixtureRoot -Filter '*') -ne
            [string]$resolution.assets.dexUpdateFlowFixtureTreeSha256 -or
        (Get-PatchletTreeSha256 -Root $sourceRoot -Filter '*.java') -ne
            [string]$resolution.assets.autoblockJavaTreeSha256) {
    throw 'Update-flow fixture tool, canonical source, or dependency hash differs from the exact resolution.'
}

$negativeManifest = Read-PatchletJson -Path $negativeManifestPath
$negativeFixtures = @($negativeManifest.fixtures)
$expectedFixtureCount = [int]$negativeManifest.expectedFixtureCount
$expectedDexUpdateFlowFixtureCount = 96
$expectedDexUpdateFlowInspectorArgumentCount = 12
if (-not (Test-ExactProperties -Value $negativeManifest -Names @(
            'schemaVersion', 'expectedFixtureCount', 'fixtures')) -or
        [int]$negativeManifest.schemaVersion -ne 1 -or
        (1 + $negativeFixtures.Count) -ne $expectedFixtureCount -or
        $expectedFixtureCount -ne $expectedDexUpdateFlowFixtureCount -or
        [int]$resolution.release.expectedDexUpdateFlowFixtureCount `
            -ne $expectedDexUpdateFlowFixtureCount -or
        [int]$resolution.release.expectedDexUpdateFlowInspectorArgumentCount `
            -ne $expectedDexUpdateFlowInspectorArgumentCount -or
        $negativeFixtures.Count -lt 1 -or $negativeFixtures.Count -gt 128) {
    throw 'Update-flow negative fixture manifest count or schema is invalid.'
}
$fixtureIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($fixture in $negativeFixtures) {
    $id = [string]$fixture.id
    if (-not (Test-ExactProperties -Value $fixture -Names @(
                'id', 'relativePath', 'replacements', 'expectedCode')) -or
            $id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
            -not $fixtureIds.Add($id) -or
            [string]$fixture.expectedCode -notmatch '^[a-z0-9]+(?:_[a-z0-9]+)*$' -or
            [string]$fixture.expectedCode -eq 'unexpected_result' -or
            [string]$fixture.expectedCode -eq 'update_semantic_hash_mismatch' -or
            @($fixture.replacements).Count -lt 1 -or
            @($fixture.replacements).Count -gt 8) {
        throw "Update-flow fixture identity or shape is invalid: '$id'."
    }
    foreach ($replacement in @($fixture.replacements)) {
        $replacementNames = @('before', 'after', 'expectedCount')
        if ($replacement.PSObject.Properties['relativePath']) {
            $replacementNames += 'relativePath'
        }
        if (-not (Test-ExactProperties -Value $replacement -Names $replacementNames)) {
            throw "Update-flow fixture '$id' has an invalid replacement shape."
        }
        $null = Get-FixtureRelativePath -Fixture $fixture -Replacement $replacement
    }
}

$contract = $resolution.release.requiredDexUpdateFlow
$expectedRoots = @(
    'Lthreadsmod/update/UpdateController;',
    'Lthreadsmod/update/UpdateEndpoints;',
    'Lthreadsmod/update/UpdateJson;',
    'Lthreadsmod/update/UpdateManifest;',
    'Lthreadsmod/update/UpdateSignature;',
    'Lthreadsmod/update/UpdateStore;',
    'Lthreadsmod/bootstrap/ModBootstrap;'
)
if (-not (Test-ExactProperties -Value $contract -Names @(
            'id', 'expectedDexName', 'classPrefix', 'expectedSemanticSha256',
            'expectedSemanticClassCount', 'orderedRootDescriptors')) -or
        [string]$contract.id -ne 'threadsmod-update-flow-v1' -or
        [string]$contract.expectedDexName -ne 'classes.dex' -or
        [string]$contract.classPrefix -ne 'Lthreadsmod/update/' -or
        [string]$contract.expectedSemanticSha256 -notmatch '^[0-9a-f]{64}$' -or
        [int]$contract.expectedSemanticClassCount -ne 24 -or
        [string]::Join([char]10, @($contract.orderedRootDescriptors)) -cne
            [string]::Join([char]10, $expectedRoots) -or
        $expectedDexUpdateFlowInspectorArgumentCount -ne 12) {
    throw 'Update-flow signed-Dex contract metadata is incomplete.'
}
$commonArguments = @(
    [string]$contract.expectedDexName,
    [string]$contract.classPrefix,
    [string]$contract.expectedSemanticSha256,
    ([string]$contract.expectedSemanticClassCount)
) + @($contract.orderedRootDescriptors | ForEach-Object { [string]$_ })
if ((1 + $commonArguments.Count) -ne $expectedDexUpdateFlowInspectorArgumentCount) {
    throw 'Update-flow inspector argument count drifted.'
}

$helperClasses = Join-Path $scratchFull 'helper-classes'
[IO.Directory]::CreateDirectory($helperClasses) | Out-Null
$null = Invoke-RequiredNative -Command $Javac -Arguments @(
    '-encoding', 'UTF-8', '-cp', $apktoolJar, '-d', $helperClasses,
    $inspectorSource)
$helperClasspath = $helperClasses + [IO.Path]::PathSeparator + $apktoolJar

$argumentGuardProbe = Invoke-ProbeNative -Command $Java -Arguments @(
    '-cp', $helperClasspath, 'DexUpdateFlowInspector')
$argumentGuardResult = Get-JsonResult -Lines $argumentGuardProbe.lines `
    -FixtureId 'argument-count-guard'
$argumentCountCaught = $argumentGuardProbe.exitCode -ne 0 -and
    [string]$argumentGuardResult.status -eq 'failed' -and
    [string]$argumentGuardResult.contract -eq [string]$contract.id -and
    [string]$argumentGuardResult.code -eq 'argument_count'
if (-not $argumentCountCaught) {
    throw 'Update-flow inspector accepted an invalid argument count.'
}

$mutationGuardScratch = Join-Path $scratchFull 'mutation-guard'
Copy-PatchletCompleteTree -SourceRoot $sourceRoot -DestinationRoot $mutationGuardScratch |
    Out-Null
$unchangedMutationCaught = $false
try {
    Set-ExactFixtureMutations -SourceRoot $mutationGuardScratch -Fixture ([pscustomobject]@{
        id = 'unchanged-mutation-guard'
        relativePath = 'threadsmod/update/UpdateController.java'
        replacements = @([pscustomobject]@{
            before = 'final class UpdateController {'
            after = 'final class UpdateController {'
            expectedCount = 1
        })
    })
} catch { $unchangedMutationCaught = $true }
if (-not $unchangedMutationCaught) {
    throw 'Update-flow fixture mutation guard accepted an unchanged replacement.'
}
$countDriftCaught = $false
try {
    Set-ExactFixtureMutations -SourceRoot $mutationGuardScratch -Fixture ([pscustomobject]@{
        id = 'count-drift-guard'
        relativePath = 'threadsmod/update/UpdateController.java'
        replacements = @([pscustomobject]@{
            before = 'final class UpdateController {'
            after = 'final class UpdateController /* mutation guard */ {'
            expectedCount = 2
        })
    })
} catch { $countDriftCaught = $true }
if (-not $countDriftCaught) {
    throw 'Update-flow fixture mutation guard accepted a drifted replacement count.'
}
$pathEscapeCaught = $false
try {
    Set-ExactFixtureMutations -SourceRoot $mutationGuardScratch -Fixture ([pscustomobject]@{
        id = 'path-escape-guard'
        relativePath = '..\outside.java'
        replacements = @([pscustomobject]@{
            before = 'before'
            after = 'after'
            expectedCount = 1
        })
    })
} catch { $pathEscapeCaught = $true }
if (-not $pathEscapeCaught) {
    throw 'Update-flow fixture mutation guard accepted a path escape.'
}

function New-FixtureApk {
    param(
        [Parameter(Mandatory)][string]$FixtureScratch,
        [Parameter(Mandatory)][string]$FixtureSourceRoot
    )
    [IO.Directory]::CreateDirectory($FixtureScratch) | Out-Null
    $classesDirectory = Join-Path $FixtureScratch 'classes'
    $dexDirectory = Join-Path $FixtureScratch 'dex'
    $classesJar = Join-Path $FixtureScratch 'patchlet-runtime.jar'
    [IO.Directory]::CreateDirectory($classesDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($dexDirectory) | Out-Null
    $sources = @(Get-ChildItem -LiteralPath $FixtureSourceRoot -Recurse -File `
        -Filter '*.java' | Sort-Object FullName | ForEach-Object FullName)
    if ($sources.Count -eq 0) {
        throw "Update-flow fixture has no Java sources: $FixtureSourceRoot"
    }
    $null = Invoke-RequiredNative -Command $Javac -Arguments (@(
        '-encoding', 'UTF-8',
        '-source', '8',
        '-target', '8',
        '-bootclasspath', $androidJar,
        '-classpath', $eddsaJar,
        '-d', $classesDirectory
    ) + $sources)
    $null = Invoke-RequiredNative -Command $Jar -Arguments @(
        '--create', '--file', $classesJar, '-C', $classesDirectory, '.')
    $null = Invoke-RequiredNative -Command $Java -Arguments @(
        '-Xmx1024M', '-Xss1m', '-cp', $d8Jar, 'com.android.tools.r8.D8',
        '--min-api', ([string]$resolution.source.minSdk),
        '--lib', $androidJar,
        '--output', $dexDirectory,
        $classesJar,
        $eddsaJar)
    $dexFiles = @(Get-ChildItem -LiteralPath $dexDirectory -File -Filter '*.dex')
    $classesDex = Join-Path $dexDirectory ([string]$contract.expectedDexName)
    if ($dexFiles.Count -ne 1 -or
            -not (Test-Path -LiteralPath $classesDex -PathType Leaf)) {
        throw "Update-flow D8 carrier must contain exactly one classes.dex."
    }
    $apkPath = Join-Path $FixtureScratch 'fixture.apk'
    $null = Invoke-RequiredNative -Command $Jar -Arguments @(
        '--create', '--file', $apkPath, '-C', $dexDirectory,
        [string]$contract.expectedDexName)
    return $apkPath
}

function New-StringEncodingVariantApk {
    param(
        [Parameter(Mandatory)][string]$FixtureApk,
        [Parameter(Mandatory)][string]$VariantScratch
    )

    $decoded = Join-Path $VariantScratch 'decoded'
    [IO.Directory]::CreateDirectory($VariantScratch) | Out-Null
    $null = Invoke-RequiredNative -Command $Java -Arguments @(
        '-jar', $apktoolJar, 'd', '-f', $FixtureApk, '-o', $decoded)
    $smaliRoot = Join-Path $decoded 'smali'
    $updateRoot = Join-Path $smaliRoot 'threadsmod\update'
    $bootstrapRoot = Join-Path $smaliRoot 'threadsmod\bootstrap'
    $files = @(Get-ChildItem -LiteralPath $updateRoot -Recurse -File -Filter '*.smali')
    $files += @(Get-ChildItem -LiteralPath $bootstrapRoot -File `
        -Filter 'ModBootstrap*.smali')
    if ($files.Count -ne 25) {
        throw "Update encoding-variant fixture must contain exactly 25 scoped classes."
    }
    $replacementCount = 0
    $tryCount = 0
    $switchCount = 0
    $branchCount = 0
    foreach ($file in $files) {
        $content = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
        $replacementCount += [regex]::Matches(
            $content, '(?m)^(\s*)const-string\s').Count
        $tryCount += [regex]::Matches($content, '(?m)^\s*\.catch(?:all)?\s').Count
        $switchCount += [regex]::Matches(
            $content, '(?m)^\s*(?:packed-switch|sparse-switch)\s').Count
        $branchCount += [regex]::Matches(
            $content, '(?m)^\s*(?:if-[a-z]+|goto(?:/16|/32)?)\s').Count
        $content = [regex]::Replace(
            $content, '(?m)^(\s*)const-string\s', '$1const-string/jumbo ')
        [IO.File]::WriteAllText(
            $file.FullName, $content, [Text.UTF8Encoding]::new($false))
    }
    if ($replacementCount -lt 1 -or $tryCount -lt 1 -or $switchCount -lt 1 `
            -or $branchCount -lt 1) {
        throw 'Update encoding-variant fixture does not exercise string width, branch, try, and switch normalization.'
    }
    $variantApk = Join-Path $VariantScratch 'string-jumbo-variant.apk'
    $null = Invoke-RequiredNative -Command $Java -Arguments @(
        '-jar', $apktoolJar, 'b', $decoded, '-o', $variantApk)
    return [pscustomobject]@{
        apk = $variantApk
        constStringJumboReplacements = $replacementCount
        tryCount = $tryCount
        switchCount = $switchCount
        branchCount = $branchCount
    }
}

function Invoke-Inspector {
    param(
        [Parameter(Mandatory)][string]$FixtureApk,
        [Parameter(Mandatory)][string]$FixtureId,
        [string]$ExpectedHash = [string]$contract.expectedSemanticSha256,
        [int]$ExpectedClassCount = [int]$contract.expectedSemanticClassCount
    )
    $arguments = @(
        '-cp', $helperClasspath, 'DexUpdateFlowInspector', $FixtureApk,
        [string]$contract.expectedDexName,
        [string]$contract.classPrefix,
        $ExpectedHash,
        ([string]$ExpectedClassCount)
    ) + @($contract.orderedRootDescriptors | ForEach-Object { [string]$_ })
    if (($arguments.Count - 3) -ne $expectedDexUpdateFlowInspectorArgumentCount) {
        throw "Update-flow fixture '$FixtureId' invocation argument count drifted."
    }
    $probe = Invoke-ProbeNative -Command $Java -Arguments $arguments
    return [pscustomobject]@{
        exitCode = [int]$probe.exitCode
        result = Get-JsonResult -Lines $probe.lines -FixtureId $FixtureId
    }
}

$results = @()
$positiveScratch = Join-Path $scratchFull 'positive'
$positiveSources = Join-Path $positiveScratch 'java'
Copy-PatchletCompleteTree -SourceRoot $sourceRoot -DestinationRoot $positiveSources |
    Out-Null
$positiveApk = New-FixtureApk -FixtureScratch $positiveScratch `
    -FixtureSourceRoot $positiveSources

$discovery = Invoke-Inspector -FixtureApk $positiveApk -FixtureId 'positive-discovery' `
    -ExpectedHash ('0' * 64)
if ($discovery.exitCode -eq 0 -or
        [string]$discovery.result.status -ne 'failed' -or
        [string]$discovery.result.contract -ne [string]$contract.id -or
        [string]$discovery.result.code -ne 'update_semantic_hash_mismatch' -or
        [string]$discovery.result.observedSemanticSha256 -notmatch '^[0-9a-f]{64}$') {
    throw "Positive update-flow semantic-hash discovery did not reach the digest after semantic proofs."
}
$observedSemanticHash = [string]$discovery.result.observedSemanticSha256
if ($observedSemanticHash -cne [string]$contract.expectedSemanticSha256) {
    throw "Positive update-flow semantic hash differs from the exact resolution: observed '$observedSemanticHash'."
}
$positiveProbe = Invoke-Inspector -FixtureApk $positiveApk -FixtureId 'positive'
$positiveResult = $positiveProbe.result
$expectedCheckNames = @(
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
if ($positiveProbe.exitCode -ne 0 -or
        [string]$positiveResult.status -ne 'passed' -or
        [string]$positiveResult.contract -ne [string]$contract.id -or
        [string]$positiveResult.dex -ne [string]$contract.expectedDexName -or
        [int]$positiveResult.updaterClassCount -ne
            [int]$contract.expectedSemanticClassCount -or
        [string]$positiveResult.semanticSha256 -cne $observedSemanticHash -or
        -not (Test-ExactProperties -Value $positiveResult.checks `
            -Names $expectedCheckNames)) {
    throw "Positive update-flow fixture failed with '$($positiveResult.code)'."
}
foreach ($name in $expectedCheckNames) {
    if ($positiveResult.checks.$name -ne $true) {
        throw "Positive update-flow fixture omitted check '$name'."
    }
}
$results += [pscustomobject]@{
    id = 'positive'
    expectedPass = $true
    observedPass = $true
    code = $null
    semanticSha256 = $observedSemanticHash
}

$representationScratch = Join-Path $scratchFull 'representation-stability'
$representationSources = Join-Path $representationScratch 'java'
Copy-PatchletCompleteTree -SourceRoot $sourceRoot `
    -DestinationRoot $representationSources | Out-Null
$representationTarget = Join-Path $representationSources `
    'threadsmod\update\EncodingNormalizationFixture.java'
[IO.File]::Copy($representationSource, $representationTarget, $false)
$representationApk = New-FixtureApk -FixtureScratch $representationScratch `
    -FixtureSourceRoot $representationSources
$representationDiscovery = Invoke-Inspector -FixtureApk $representationApk `
    -FixtureId 'representation-stability-discovery' -ExpectedHash ('0' * 64) `
    -ExpectedClassCount 25
if ($representationDiscovery.exitCode -eq 0 `
        -or [string]$representationDiscovery.result.status -ne 'failed' `
        -or [string]$representationDiscovery.result.code `
            -ne 'update_semantic_hash_mismatch' `
        -or [string]$representationDiscovery.result.observedSemanticSha256 `
            -notmatch '^[0-9a-f]{64}$') {
    throw 'Update representation-stability baseline did not reach semantic hashing.'
}
$representationHash = `
    [string]$representationDiscovery.result.observedSemanticSha256
$encodingVariant = New-StringEncodingVariantApk `
    -FixtureApk $representationApk `
    -VariantScratch (Join-Path $representationScratch 'variant')
$representationProbe = Invoke-Inspector -FixtureApk ([string]$encodingVariant.apk) `
    -FixtureId 'representation-stability-jumbo' -ExpectedHash $representationHash `
    -ExpectedClassCount 25
if ($representationProbe.exitCode -ne 0 `
        -or [string]$representationProbe.result.status -ne 'passed' `
        -or [string]$representationProbe.result.semanticSha256 -cne $representationHash `
        -or [int]$representationProbe.result.updaterClassCount -ne 25) {
    throw 'Update representation-stability jumbo/offset/try/switch fixture failed.'
}

foreach ($fixture in $negativeFixtures) {
    $fixtureId = [string]$fixture.id
    $fixtureScratch = Join-Path $scratchFull $fixtureId
    $fixtureSources = Join-Path $fixtureScratch 'java'
    Copy-PatchletCompleteTree -SourceRoot $sourceRoot -DestinationRoot $fixtureSources |
        Out-Null
    Set-ExactFixtureMutations -SourceRoot $fixtureSources -Fixture $fixture
    $fixtureApk = New-FixtureApk -FixtureScratch $fixtureScratch `
        -FixtureSourceRoot $fixtureSources
    $probe = Invoke-Inspector -FixtureApk $fixtureApk -FixtureId $fixtureId
    $parsed = $probe.result
    $observedCode = if ($probe.exitCode -ne 0 -and
            [string]$parsed.status -eq 'failed' -and
            [string]$parsed.contract -eq [string]$contract.id) {
        [string]$parsed.code
    } else {
        'unexpected_result'
    }
    if ($observedCode -ne [string]$fixture.expectedCode) {
        throw "Update-flow fixture '$fixtureId' returned '$observedCode', expected '$($fixture.expectedCode)'."
    }
    if ($observedCode -eq 'update_semantic_hash_mismatch' -or
            $parsed.PSObject.Properties['observedSemanticSha256']) {
        throw "Update-flow fixture '$fixtureId' reached graph hashing instead of its semantic rejection."
    }
    $results += [pscustomobject]@{
        id = $fixtureId
        expectedPass = $false
        observedPass = $false
        code = $observedCode
        semanticSha256 = $null
    }
}

if ($results.Count -ne $expectedFixtureCount) {
    throw "Update-flow fixture count drifted: expected $expectedFixtureCount, observed $($results.Count)."
}
$report = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToString('o')
    status = 'passed'
    expectedFixtureCount = $expectedFixtureCount
    inspectorArgumentCount = $expectedDexUpdateFlowInspectorArgumentCount
    semanticChecksBeforeDigest = $true
    argumentCountRejected = $argumentCountCaught
    unchangedMutationRejected = $unchangedMutationCaught
    countDriftRejected = $countDriftCaught
    pathEscapeRejected = $pathEscapeCaught
    positiveSemanticSha256 = $observedSemanticHash
    representationStableEncoding = [ordered]@{
        status = 'passed'
        semanticSha256 = $representationHash
        scopedClassCount = 25
        constStringJumboReplacements = `
            [int]$encodingVariant.constStringJumboReplacements
        tryCount = [int]$encodingVariant.tryCount
        switchCount = [int]$encodingVariant.switchCount
        branchCount = [int]$encodingVariant.branchCount
    }
    fixtures = $results
}
if ($ReportPath) {
    Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath))
}
[pscustomobject]$report
