[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScratchRoot,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$ReportPath,
    [string]$Java = 'java',
    [string]$Javac = 'javac'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

function Invoke-Captured {
    param([string]$Command, [string[]]$Arguments)
    $output = @(& $Command @Arguments)
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Host asset test command failed with exit code ${code}: $Command" }
    return $output
}

function Remove-JavaComments {
    param([Parameter(Mandatory)][string]$Text)
    $result = [Text.StringBuilder]::new($Text.Length)
    $normal = 0
    $stringLiteral = 1
    $characterLiteral = 2
    $lineComment = 3
    $blockComment = 4
    $state = $normal
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }
        if ($state -eq $normal) {
            if ($character -eq [char]47 -and $next -eq [char]47) {
                $null = $result.Append('  ')
                $index++
                $state = $lineComment
            } elseif ($character -eq [char]47 -and $next -eq [char]42) {
                $null = $result.Append('  ')
                $index++
                $state = $blockComment
            } else {
                $null = $result.Append($character)
                if ($character -eq [char]34) { $state = $stringLiteral }
                elseif ($character -eq [char]39) { $state = $characterLiteral }
            }
        } elseif ($state -eq $lineComment) {
            if ($character -eq [char]10 -or $character -eq [char]13) {
                $null = $result.Append($character)
                $state = $normal
            } else {
                $null = $result.Append(' ')
            }
        } elseif ($state -eq $blockComment) {
            if ($character -eq [char]42 -and $next -eq [char]47) {
                $null = $result.Append('  ')
                $index++
                $state = $normal
            } elseif ($character -eq [char]10 -or $character -eq [char]13) {
                $null = $result.Append($character)
            } else {
                $null = $result.Append(' ')
            }
        } else {
            $null = $result.Append($character)
            if ($character -eq [char]92 -and $index + 1 -lt $Text.Length) {
                $index++
                $null = $result.Append($Text[$index])
            } elseif (($state -eq $stringLiteral -and $character -eq [char]34) `
                    -or ($state -eq $characterLiteral -and $character -eq [char]39)) {
                $state = $normal
            }
        }
    }
    if ($state -eq $blockComment) { throw 'Unterminated Java block comment in canonical asset.' }
    return $result.ToString()
}

function Get-JavaCompactCode {
    param([Parameter(Mandatory)][string]$Text)
    return [regex]::Replace((Remove-JavaComments -Text $Text), '\s+', '')
}

function Get-JavaBlockBody {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Anchor,
        [string]$Label = $Anchor,
        [int]$StartIndex = 0
    )
    $anchorIndex = $Text.IndexOf($Anchor, $StartIndex, [StringComparison]::Ordinal)
    if ($anchorIndex -lt 0) { throw "Java structural anchor is missing: $Label" }
    $openIndex = $Text.IndexOf('{', $anchorIndex + $Anchor.Length)
    if ($openIndex -lt 0) { throw "Java structural block is missing: $Label" }
    $depth = 0
    $literal = [char]0
    for ($index = $openIndex; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($literal -ne [char]0) {
            if ($character -eq [char]92) { $index++ }
            elseif ($character -eq $literal) { $literal = [char]0 }
            continue
        }
        if ($character -eq [char]34 -or $character -eq [char]39) {
            $literal = $character
        } elseif ($character -eq [char]123) {
            $depth++
        } elseif ($character -eq [char]125) {
            $depth--
            if ($depth -eq 0) {
                return $Text.Substring($openIndex + 1, $index - $openIndex - 1)
            }
        }
    }
    throw "Java structural block is unterminated: $Label"
}

function Get-JavaTopLevelLiteralIndex {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Literal
    )
    $cursor = 0
    while ($cursor -lt $Text.Length) {
        $candidate = $Text.IndexOf($Literal, $cursor, [StringComparison]::Ordinal)
        if ($candidate -lt 0) { return -1 }
        $depth = 0
        $quoted = [char]0
        for ($index = 0; $index -lt $candidate; $index++) {
            $character = $Text[$index]
            if ($quoted -ne [char]0) {
                if ($character -eq [char]92) { $index++ }
                elseif ($character -eq $quoted) { $quoted = [char]0 }
            } elseif ($character -eq [char]34 -or $character -eq [char]39) {
                $quoted = $character
            } elseif ($character -eq [char]123) {
                $depth++
            } elseif ($character -eq [char]125) {
                $depth--
            }
        }
        if ($depth -eq 0 -and $quoted -eq [char]0) { return $candidate }
        $cursor = $candidate + $Literal.Length
    }
    return -1
}

function Assert-JavaBranchWake {
    param(
        [Parameter(Mandatory)][string]$MethodBody,
        [Parameter(Mandatory)][string]$Condition,
        [Parameter(Mandatory)][string]$WakeCall,
        [Parameter(Mandatory)][string]$Label
    )
    $branch = Get-JavaBlockBody -Text $MethodBody -Anchor $Condition -Label $Label
    $wakeIndex = Get-JavaTopLevelLiteralIndex -Text $branch -Literal $WakeCall
    $returnIndex = Get-JavaTopLevelLiteralIndex -Text $branch -Literal 'return;'
    if ($wakeIndex -lt 0 -or $returnIndex -lt 0 -or $wakeIndex -gt $returnIndex) {
        throw "Scheduler wait branch has no direct wake before return: $Label"
    }
}

function Get-PatchletSingleInsertion {
    param(
        [Parameter(Mandatory)][string]$Before,
        [Parameter(Mandatory)][string]$After,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Before.Equals($After, [StringComparison]::Ordinal)) {
        throw "Exact rewrite '$Label' did not insert any content."
    }
    $beforeLines = $Before.Split([string[]]@("`n"), [StringSplitOptions]::None)
    $afterLines = $After.Split([string[]]@("`n"), [StringSplitOptions]::None)
    $prefixLength = 0
    $maximumPrefix = [Math]::Min($beforeLines.Count, $afterLines.Count)
    while ($prefixLength -lt $maximumPrefix `
            -and $beforeLines[$prefixLength] -ceq $afterLines[$prefixLength]) {
        $prefixLength++
    }
    $suffixLength = 0
    $maximumSuffix = [Math]::Min(
        $beforeLines.Count - $prefixLength,
        $afterLines.Count - $prefixLength)
    while ($suffixLength -lt $maximumSuffix `
            -and $beforeLines[$beforeLines.Count - 1 - $suffixLength] `
                -ceq $afterLines[$afterLines.Count - 1 - $suffixLength]) {
        $suffixLength++
    }
    $removedLength = $beforeLines.Count - $prefixLength - $suffixLength
    $insertedLength = $afterLines.Count - $prefixLength - $suffixLength
    $removed = if ($removedLength -gt 0) {
        @($beforeLines[$prefixLength..($prefixLength + $removedLength - 1)]) -join "`n"
    } else { '' }
    $inserted = if ($insertedLength -gt 0) {
        @($afterLines[$prefixLength..($prefixLength + $insertedLength - 1)]) -join "`n"
    } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($removed) `
            -or [string]::IsNullOrWhiteSpace($inserted)) {
        throw "Exact rewrite '$Label' is not one content-only insertion."
    }
    return $inserted.Trim()
}

$repositoryRoot = Get-PatchletRepositoryRoot
$resolutionPathFull = [IO.Path]::GetFullPath($ResolutionPath)
$resolutionDirectory = Split-Path -Parent $resolutionPathFull
$resolution = Read-PatchletJson -Path $resolutionPathFull
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
        -or [string]$resolution.target.versionName -cne $expectedTargetVersionName) {
    throw 'Resolution target version is not the exact source-plus-one mod-build-1 contract.'
}
$null = Test-PatchletAssets -Resolution $resolution -RepositoryRoot $repositoryRoot
$updateDexInspectorPath = Join-Path $repositoryRoot `
    'patchlets\tools\DexUpdateFlowInspector.java'
$updateDexFixtureTestPath = Join-Path $repositoryRoot `
    'patchlets\tools\Test-DexUpdateFlowInspector.ps1'
$updateDexFixtureRoot = Join-Path $repositoryRoot `
    'patchlets\assets\release-gates\dex-update-flow'
$updateDexFixtureManifestPath = Join-Path $updateDexFixtureRoot `
    'negative\fixtures.json'
$updateDexFixtureManifest = Read-PatchletJson -Path $updateDexFixtureManifestPath
$updateDexFixtureIds = @($updateDexFixtureManifest.fixtures | ForEach-Object {
        [string]$_.id
    })
$updateDexFixtureCodes = @($updateDexFixtureManifest.fixtures | ForEach-Object {
        [string]$_.expectedCode
    })
if ((Get-PatchletSha256 -Path $updateDexInspectorPath) `
        -ne [string]$resolution.assets.dexUpdateFlowInspectorSourceSha256 `
        -or (Get-PatchletSha256 -Path $updateDexFixtureTestPath) `
            -ne [string]$resolution.assets.dexUpdateFlowInspectorTestSourceSha256 `
        -or (Get-PatchletTreeSha256 -Root $updateDexFixtureRoot -Filter '*') `
            -ne [string]$resolution.assets.dexUpdateFlowFixtureTreeSha256 `
        -or [int]$resolution.release.expectedDexUpdateFlowFixtureCount -ne 96 `
        -or [int]$resolution.release.expectedDexUpdateFlowInspectorArgumentCount -ne 12 `
        -or [int]$updateDexFixtureManifest.schemaVersion -ne 1 `
        -or [int]$updateDexFixtureManifest.expectedFixtureCount -ne 96 `
        -or $updateDexFixtureIds.Count -ne 95 `
        -or @($updateDexFixtureIds | Sort-Object -Unique).Count -ne 95 `
        -or @($updateDexFixtureCodes | Where-Object {
                $_ -notmatch '^[a-z0-9]+(?:_[a-z0-9]+)*$' `
                    -or $_ -ceq 'update_semantic_hash_mismatch'
            }).Count -ne 0) {
    throw 'Updater raw DEX proof asset hashes, counts, or negative contracts drifted.'
}
$scratchFull = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $scratchFull) { throw "ScratchRoot must be fresh: $scratchFull" }
[IO.Directory]::CreateDirectory($scratchFull) | Out-Null

$assetsRoot = Join-Path $repositoryRoot 'patchlets\assets'
$patchletsRoot = Join-Path $repositoryRoot 'patchlets'
$bridgeTemplateRoot = Resolve-PatchletTemplateRoot `
    -PatchletsRoot $patchletsRoot `
    -Section $resolution.bridge `
    -DefaultRelativeRoot 'assets\autoblock\bridge-templates' `
    -Kind 'bridge'
$bridgeReferenceRoot = Resolve-PatchletTemplateRoot `
    -PatchletsRoot $patchletsRoot `
    -Section ([pscustomobject]@{ templateRoot = [string]$resolution.bridge.referenceRoot }) `
    -DefaultRelativeRoot 'assets\bridge-reference-415' `
    -Kind 'bridge-reference'
$inlineTemplateRoot = Resolve-PatchletTemplateRoot `
    -PatchletsRoot $patchletsRoot `
    -Section $resolution.inlineControls `
    -DefaultRelativeRoot 'assets\inline-control\templates' `
    -Kind 'inline'
$reportTemplateRoot = Resolve-PatchletTemplateRoot `
    -PatchletsRoot $patchletsRoot `
    -Section $resolution.reporting `
    -DefaultRelativeRoot 'assets\reporting\templates' `
    -Kind 'reporting'
$settingsTemplateRoot = Resolve-PatchletTemplateRoot `
    -PatchletsRoot $patchletsRoot `
    -Section $resolution.drawerSettings `
    -DefaultRelativeRoot 'assets\settings-ui\templates' `
    -Kind 'settings'
foreach ($selectedTemplateRoot in @(
        $bridgeTemplateRoot,
        $bridgeReferenceRoot,
        $inlineTemplateRoot,
        $reportTemplateRoot,
        $settingsTemplateRoot)) {
    if (-not (Test-Path -LiteralPath $selectedTemplateRoot -PathType Container)) {
        throw "Resolution-selected exact-version template root does not exist: $selectedTemplateRoot"
    }
}
$normalizedSourceVersion = [string]$resolution.source.versionName
$selectedRootContracts = @(
    @([string]$resolution.bridge.templateRoot, $bridgeTemplateRoot, 'bridge', 'assets/autoblock/bridge-templates'),
    @([string]$resolution.bridge.referenceRoot, $bridgeReferenceRoot, 'bridge-reference', 'assets/bridge-reference-415'),
    @([string]$resolution.inlineControls.templateRoot, $inlineTemplateRoot, 'inline', 'assets/inline-control/templates'),
    @([string]$resolution.reporting.templateRoot, $reportTemplateRoot, 'reporting', 'assets/reporting/templates'),
    @([string]$resolution.drawerSettings.templateRoot, $settingsTemplateRoot, 'settings', 'assets/settings-ui/templates')
)
foreach ($selectedRootContract in $selectedRootContracts) {
    $relativeRoot = ([string]$selectedRootContract[0]).Replace('\', '/')
    $resolvedRoot = [IO.Path]::GetFullPath([string]$selectedRootContract[1])
    $expectedResolvedRoot = [IO.Path]::GetFullPath(
        (Resolve-PatchletChildPath -Root $patchletsRoot -Child $relativeRoot))
    if (-not $resolvedRoot.Equals($expectedResolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolution-selected template root did not resolve to its exact cataloged path: $relativeRoot"
    }
    if ($relativeRoot.StartsWith('assets/versioned/', [StringComparison]::Ordinal) `
            -and $relativeRoot -cne (
                'assets/versioned/' + $normalizedSourceVersion + '/' +
                [string]$selectedRootContract[2])) {
        throw "Versioned template root is not bound to source version '$normalizedSourceVersion': $relativeRoot"
    }
    if ($normalizedSourceVersion -cne '415.0.0.26.77' `
            -and $relativeRoot -ceq [string]$selectedRootContract[3]) {
        throw "A non-historical resolution must select its own exact-version template root: $relativeRoot"
    }
}
$selectedTemplateFileContracts = @(
    @($bridgeTemplateRoot, '*.tmpl', @(
            'MutationCallback.smali.tmpl',
            'ThreadsBlockBridge.smali.tmpl')),
    @($bridgeReferenceRoot, '*.smali', @(
            'MutationCallback.smali',
            'ThreadsBlockBridge.smali')),
    @($inlineTemplateRoot, '*.tmpl', @(
            'InlineActionClick.smali.tmpl',
            'InlineActionRowAdapter.smali.tmpl',
            'InlineVisibilityCallback.smali.tmpl')),
    @($reportTemplateRoot, '*.tmpl', @(
            $resolution.reporting.templateNames | ForEach-Object { [string]$_ })),
    @($settingsTemplateRoot, '*.tmpl', @(
            'DrawerSettingsClick.smali.tmpl',
            'DrawerSettingsItem.smali.tmpl',
            'DrawerSettingsRowAdapter.smali.tmpl'))
)
foreach ($selectedTemplateFileContract in $selectedTemplateFileContracts) {
    $selectedRoot = [IO.Path]::GetFullPath([string]$selectedTemplateFileContract[0])
    $selectedRootPrefix = $selectedRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $actualTemplateFiles = @(Get-ChildItem -LiteralPath $selectedRoot -Recurse -File `
            -Filter ([string]$selectedTemplateFileContract[1]) |
        ForEach-Object {
            $_.FullName.Substring($selectedRootPrefix.Length).Replace('\', '/')
        } | Sort-Object)
    $expectedTemplateFiles = @($selectedTemplateFileContract[2] |
        ForEach-Object { [string]$_ } | Sort-Object)
    if ($actualTemplateFiles.Count -ne $expectedTemplateFiles.Count `
            -or @(Compare-Object -ReferenceObject $expectedTemplateFiles `
                -DifferenceObject $actualTemplateFiles).Count -ne 0) {
        throw "Resolution-selected template root does not contain exactly its owned files: $selectedRoot"
    }
}
$eddsaJar = Join-Path $assetsRoot 'autoblock\lib\net-i2p-crypto-eddsa-0.3.1.jar'
$fixture = Join-Path $assetsRoot 'tests\fixtures\blocklist-v3-2026-09-06\manifest.json'
$sources = @(
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\CloneBlockerEndpoints.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\BlockDiagnostic.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\BlockLimits.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\BlockLimitsStore.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportValues.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportRequest.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportEndpoint.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportJson.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\InstallStatsPayload.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\proxy\ProxyBypassPolicy.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\proxy\ProxyConfig.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\proxy\ProxyRoutePlanner.java'),
    (Join-Path $assetsRoot 'tests\EndpointHarness.java'),
    (Join-Path $assetsRoot 'tests\VerifierHarness.java'),
    (Join-Path $assetsRoot 'tests\PassiveBlocklistFixtureHarness.java'),
    (Join-Path $assetsRoot 'tests\BlockLimitsHarness.java'),
    (Join-Path $assetsRoot 'tests\android\content\Context.java'),
    (Join-Path $assetsRoot 'tests\android\content\SharedPreferences.java'),
    (Join-Path $assetsRoot 'tests\android\net\IpPrefix.java'),
    (Join-Path $assetsRoot 'tests\android\net\VpnService.java'),
    (Join-Path $assetsRoot 'tests\android\os\Build.java'),
    (Join-Path $assetsRoot 'tests\BlockLimitsStoreHarness.java'),
    (Join-Path $assetsRoot 'tests\ReportValuesHarness.java'),
    (Join-Path $assetsRoot 'tests\StrictJsonHarness.java'),
    (Join-Path $assetsRoot 'tests\InstallStatsHarness.java'),
    (Join-Path $assetsRoot 'tests\ProxyConfigHarness.java'),
    (Join-Path $assetsRoot 'tests\ProxyRoutePlannerHarness.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\update\UpdateEndpoints.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\update\UpdateJson.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\update\UpdateSignature.java'),
    (Join-Path $assetsRoot 'tests\android\util\Base64.java'),
    (Join-Path $assetsRoot 'tests\UpdatePolicyHarness.java'),
    (Join-Path $assetsRoot 'tests\UpdateSignatureHarness.java'),
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\update\UpdateStore.java'),
    (Join-Path $assetsRoot 'tests\update-store-stubs\threadsmod\update\UpdateManifest.java'),
    (Join-Path $assetsRoot 'tests\UpdateStoreFloorHarness.java')
)
$compileOutput = @(Invoke-Captured -Command $Javac -Arguments (@('-encoding', 'UTF-8', '-classpath', $eddsaJar, '-d', $scratchFull) + $sources))
$classpath = "$scratchFull$([IO.Path]::PathSeparator)$eddsaJar"
$endpointOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'threadsmod.autoblock.EndpointHarness'))
$fixtureUri = ([Uri]([IO.Path]::GetFullPath($fixture))).AbsoluteUri
$verifierOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'VerifierHarness', $fixtureUri))
$passiveFixtureOutput = @(Invoke-Captured -Command $Java -Arguments @(
    '-classpath', $classpath, 'PassiveBlocklistFixtureHarness', ([IO.Path]::GetFullPath($fixture))))
$limitsOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'threadsmod.autoblock.BlockLimitsHarness'))
$limitsStoreOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'threadsmod.autoblock.BlockLimitsStoreHarness'))
$reportValuesOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'threadsmod.reporting.ReportValuesHarness'))
$strictJsonOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'threadsmod.reporting.StrictJsonHarness'))
$installStatsOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'threadsmod.reporting.InstallStatsHarness'))
$proxyConfigOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'threadsmod.proxy.ProxyConfigHarness'))
$proxyRouteOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'threadsmod.proxy.ProxyRoutePlannerHarness'))
$updatePolicyOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'threadsmod.update.UpdatePolicyHarness'))
$updateSignatureOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'threadsmod.update.UpdateSignatureHarness'))
$updateStoreFloorOutput = @(Invoke-Captured -Command $Java -Arguments @('-classpath', $classpath, 'threadsmod.update.UpdateStoreFloorHarness'))
if ($endpointOutput[-1] -notlike 'PASS reads=3 write=https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/reports stats=https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/installs') { throw 'Endpoint harness did not report the exact mirror/write contract.' }
if ($verifierOutput[-1] -notlike 'PASS signature=true tamper=false noncanonical=false short=false*') { throw 'Verifier harness did not report all fail-closed checks.' }
if ($passiveFixtureOutput[-1] -ne 'PASS passive-fixture-v3 k=4 chunks=16 idRows=1607 handleRows=26 unique=1607') { throw 'Passive fixture harness did not prove the v3 hash chain, bucket membership and Threads id/username admission.' }
if ($limitsOutput[-1] -ne 'PASS passive-limits fields=2 defaults=4,10 ranges=2-60,3-60 steps=whole-second ordering=true failclosed=true') { throw 'Limits harness did not prove the exact two-field passive-delay bounds, whole-second steps, ordering, defaults, and fail-closed behavior.' }
if ($limitsStoreOutput[-1] -ne 'PASS passive-limits-store keys=2 retired=9 retired-authority=false deletion-only=true atomic=true rollback=all-types partial=true wrong-type=true invalid=true uncertainty=true read-errors=true failclosed=true') { throw 'Limits store harness did not prove two-key atomic persistence, retired-key non-authority/deletion, exact rollback, and fail-closed reads.' }
if ($reportValuesOutput[-1] -ne 'PASS report required=true canonical-id=true utf16=280 username=true link-strict=true link-max=300 code-fallback=true empty-caption=true') { throw 'Report values harness did not prove required fields, canonical IDs, Unicode-safe trimming, code-first permalink fallback, and the no-text excerpt.' }
if ($strictJsonOutput[-1] -ne 'PASS report-json strict=true trailing=false lenient=false duplicates=false utf8=false') { throw 'Report response harness did not reject trailing, lenient, duplicate-name, or malformed-UTF-8 input.' }
if ($installStatsOutput[-1] -ne 'PASS install-stats keys=13 strict=true escape-free=true account-fields=0 bounds=true') { throw 'Activation-statistics harness did not prove the closed 13-key payload, strict escape-free serialization, absence of every account field, and bounded tokens.' }
if ($proxyConfigOutput[-1] -ne 'PASS proxy-config defaults=true host=true bypass=true canonical=true matching=true rejects=true bounds=64/4096 auth=1-255 failclosed=true') { throw 'Proxy configuration harness did not prove defaults, host/bypass grammar, exact bounds, matching, and credential limits.' }
if ($proxyRouteOutput[-1] -ne 'PASS proxy-routes api33=true legacy=true equivalence=true bounded=true exclusions=4') { throw 'Proxy route harness did not prove API 33 exclusions, the bounded legacy complement, and representative policy equivalence.' }
if ($updatePolicyOutput[-1] -ne 'PASS update-policy metadata=3 providers=github,aws redirects=same-provider json=strict utf8=strict') { throw 'Update policy harness did not prove exact metadata ordering, artifact providers, redirect isolation, and strict JSON/UTF-8.' }
if ($updateSignatureOutput[-1] -ne 'PASS update-signature rfc8032=true tamper=false noncanonical=false') { throw 'Update signature harness did not prove the RFC 8032 positive, tamper, and canonical-scalar cases.' }
if ($updateStoreFloorOutput[-1] -ne 'PASS update-store-floor false-commit=true thrown-edit=true uncertain-load-rejected=true stale-rejected=true same-repair=true higher-repair=true envelope-below-typed=true envelope-above-typed=true mismatch-equal-rejected=true mismatch-newer-repair=true retained-required=true first-run-no-lock=true optional-no-lock=true') { throw 'Update store harness did not preserve the strongest rollback floor, reject uncertain reads and ambiguous repair, or retain only a previously verified required policy.' }

$controllerText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\inlinecontrol\InlineBlockController.java')
$requestText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\inlinecontrol\InlineBlockRequest.java')
$dialogText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\inlinecontrol\InlineBlockDialog.java')
$dialogStringsText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\inlinecontrol\InlineBlockStrings.java')
$stateText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\ModStateStore.java')
$schedulerText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\AutoBlockSync.java')
$blocklistStoreText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\BlocklistStore.java')
$chunkInstallerText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\ChunkInstaller.java')
$objectFetcherText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\ObjectFetcher.java')
$passiveFixtureText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'tests\PassiveBlocklistFixtureHarness.java')
$diagnosticText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\BlockDiagnostic.java')
$dispatcherText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\BridgeCallbackDispatcher.java')
$limitsText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\BlockLimits.java')
$limitsStoreText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\BlockLimitsStore.java')
$settingsText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\com\threadsmod\CloneBlockerSettingsActivity.java')
$activityText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\com\threadsmod\CloneBlockerActivity.java')
$uiText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\com\threadsmod\CloneBlockerUi.java')
$bootstrapText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\bootstrap\ModBootstrap.java')
$readEndpointText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\autoblock\CloneBlockerEndpoints.java')
$endpointText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportEndpoint.java')
$reportClientText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportClient.java')
$reportControllerText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportController.java')
$reportRequestText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportRequest.java')
$reportValuesText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportValues.java')
$reportPayloadText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportPayload.java')
$reportStoreText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportStore.java')
$reportJsonText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportJson.java')
$proxyConfigText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\proxy\ProxyConfig.java')
$proxyBypassText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\proxy\ProxyBypassPolicy.java')
$proxyStoreText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\proxy\ProxyConfigStore.java')
$proxyRouteText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\proxy\ProxyRoutePlanner.java')
$proxyControllerText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\proxy\ProxyController.java')
$proxyServiceText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\proxy\Socks5VpnService.java')
$proxySettingsActivityText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\com\threadsmod\ProxySettingsActivity.java')
$updateEndpointsText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\update\UpdateEndpoints.java')
$updateJsonText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\update\UpdateJson.java')
$updateSignatureText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\update\UpdateSignature.java')
$updateManifestText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\update\UpdateManifest.java')
$updateStoreText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\update\UpdateStore.java')
$updateControllerText = Get-NormalizedPatchletText -Path (Join-Path $assetsRoot 'autoblock\java\threadsmod\update\UpdateController.java')
$updateCombinedText = $updateEndpointsText + "`n" + $updateJsonText + "`n" + $updateSignatureText + "`n" + $updateManifestText + "`n" + $updateStoreText + "`n" + $updateControllerText
$updateSignatureCode = Get-JavaCompactCode -Text $updateSignatureText
$updateManifestCode = Get-JavaCompactCode -Text $updateManifestText
$updateStoreCode = Get-JavaCompactCode -Text $updateStoreText
$updateControllerCode = Get-JavaCompactCode -Text $updateControllerText
$expectedUpdateMetadataUrls = @(
    'https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/threadsmod-update.json',
    'https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/threadsmod-update.json',
    'https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/threadsmod-update.json'
)
$lastUpdateEndpointIndex = -1
foreach ($updateUrl in $expectedUpdateMetadataUrls) {
    if ((Get-PatchletLiteralCount -Text $updateEndpointsText -Literal ('"' + $updateUrl + '"')) -ne 1) {
        throw "Update metadata endpoint must occur exactly once: $updateUrl"
    }
    $nextUpdateEndpointIndex = $updateEndpointsText.IndexOf($updateUrl, [StringComparison]::Ordinal)
    if ($nextUpdateEndpointIndex -le $lastUpdateEndpointIndex) {
        throw 'Update metadata endpoints are not in GitHub raw, jsDelivr, AWS order.'
    }
    $lastUpdateEndpointIndex = $nextUpdateEndpointIndex
}
if ($updateCombinedText.IndexOf('tree55.com', [StringComparison]::OrdinalIgnoreCase) -ge 0 `
        -or $updateCombinedText.Contains('DownloadManager', [StringComparison]::Ordinal)) {
    throw 'Updater must contain neither tree55.com nor DownloadManager.'
}
foreach ($literal in @(
    'MAX_INITIAL_URL_CHARS = 1024',
    'MAX_REDIRECT_LOCATION_CHARS = 4096',
    'MAX_REDIRECT_URL_CHARS = 4096',
    'MAX_REDIRECT_PATH_CHARS = 2048',
    'MAX_REDIRECT_QUERY_CHARS = 2048',
    'String bucket = host.substring(0, host.lastIndexOf(".s3."))',
    "bucket.indexOf('.') >= 0 || isIpLiteral(bucket)",
    'bucket.matches("^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$")')) {
    if (-not $updateEndpointsText.Contains($literal, [StringComparison]::Ordinal)) {
        throw "Update URL bound is missing: $literal"
    }
}
foreach ($literal in @(
    'static final String PURPOSE = "threadsmod-app-update";',
    'static final String REQUIRED_SIGNER_SHA256 =',
    '"v", "purpose", "packageName", "revision", "publishedAt", "modBuild",',
    '"minimumModBuild", "versionCode", "versionName", "notes", "apkSize",',
    '"apkSha256", "signerSha256", "downloadUrls"',
    'publishedAtMs = Instant.parse(publishedAt).toEpochMilli()',
    'DateTimeFormatter.ofPattern("uuuu-MM-dd''T''HH:mm:ss.SSS''Z''", Locale.US)',
    'publishedAt.equals(CANONICAL_TIMESTAMP.format(Instant.ofEpochMilli(publishedAtMs)))',
    'versionName.matches("^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$")',
    'UpdateSignature.verifyProduction(payloadJson, signature)',
    'minimumModBuild < 0L || minimumModBuild > modBuild',
    '!providers.contains(UpdateEndpoints.PROVIDER_GITHUB)',
    '!providers.contains(UpdateEndpoints.PROVIDER_AWS)')) {
    if (-not $updateManifestCode.Contains((Get-JavaCompactCode -Text $literal), [StringComparison]::Ordinal)) {
        throw "Strict signed update manifest contract is missing: $literal"
    }
}
foreach ($literal in @(
    'static final String PRODUCTION_PUBLIC_KEY =',
    '"fYcRAV8CRof15IAinUoDOZuBbqqDtDXDPl3lwSLoMhk"',
    'verifyWithKey(key, payload.getBytes(StandardCharsets.UTF_8), signature)',
    'encodedSignature.equals(Base64.encodeToString(signature, Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP))',
    '!isCanonicalScalar(signature)')) {
    if (-not $updateSignatureCode.Contains((Get-JavaCompactCode -Text $literal), [StringComparison]::Ordinal)) {
        throw "Canonical update signature contract is missing: $literal"
    }
}
foreach ($literal in @(
    'KEY_ENVELOPE = "update_verified_envelope"',
    'KEY_REVISION = "update_revision"',
    'KEY_MOD_BUILD = "update_mod_build"',
    'KEY_CHECK_NOT_BEFORE = "update_check_not_before"',
    'KEY_DISMISSED_REVISION = "update_dismissed_revision"',
    'candidate.revision < revisionFloor',
    'candidate.modBuild < modBuildFloor',
    'boolean hasPolicyState = rawEnvelope != null || rawRevision != null || rawModBuild != null',
    'hasPolicyState && (!(rawRevision instanceof Long)',
    '(Long) rawRevision <= 0L',
    '(Long) rawModBuild <= 0L',
    'throw new IllegalStateException("update rollback floors are corrupt")',
    'boolean exactEnvelopeBinding = envelopeFloor != null',
    'envelopeFloor.revision == revisionFloor',
    'envelopeFloor.modBuild == modBuildFloor',
    'long strongestRevisionFloor = envelopeFloor == null',
    'Math.max(revisionFloor, envelopeFloor.revision)',
    'hasPolicyState && !exactEnvelopeBinding',
    'candidate.revision <= strongestRevisionFloor',
    'throw new SecurityException("update manifest repair requires newer revision")',
    'private static boolean policyPersistenceUncertain',
    'private static UpdateManifest policyPersistenceFloor',
    'private static UpdateManifest lastVerifiedManifestForEnforcement',
    'if (policyPersistenceUncertain)',
    'if (policyPersistenceFloor == null)',
    'requireMonotonicCandidate(candidate, policyPersistenceFloor)',
    'policyPersistenceFloor = candidate',
    'lastVerifiedManifestForEnforcement = candidate',
    'throw new IllegalStateException("update policy persistence is uncertain")',
    '!candidate.sameSignedRelease(previous)',
    'candidate.modBuild == previous.modBuild && !candidate.sameBinary(previous)',
    'policyPersistenceFloor = null',
    'static synchronized boolean hasRetainedRequiredForEnforcement(long currentModBuild)',
    '!policyPersistenceUncertain || currentModBuild <= 0L',
    'currentModBuild < retained.minimumModBuild',
    'putLong(KEY_DISMISSED_REVISION, revision).commit()')) {
    if (-not $updateStoreCode.Contains((Get-JavaCompactCode -Text $literal), [StringComparison]::Ordinal)) {
        throw "Monotonic update state contract is missing: $literal"
    }
}
foreach ($literal in @(
    'public static final long CURRENT_MOD_BUILD = 1L',
    'METADATA_ATTEMPT_TIMEOUT_MS = 8000L',
    'METADATA_OPERATION_TIMEOUT_MS = 24000L',
    'DOWNLOAD_ATTEMPT_TIMEOUT_MS = 10L * 60L * 1000L',
    'DOWNLOAD_OPERATION_TIMEOUT_MS = 20L * 60L * 1000L',
    'timeoutBefore(attemptDeadline, 3000)',
    'timeoutBefore(attemptDeadline, 5000)',
    'disconnectAtDeadline(connection, attemptDeadline)',
    'manifest.modBuild > CURRENT_MOD_BUILD && manifest.versionCode > installedVersion',
    'CURRENT_MOD_BUILD < manifest.minimumModBuild',
    'UpdateStore.hasRetainedRequiredForEnforcement(CURRENT_MOD_BUILD)',
    'UpdateStore.dismissedRevision(activity) == manifest.revision',
    '.setPositiveButton("Update", null)',
    'builder.setNegativeButton("Later"',
    'shown.setCancelable(!required)',
    'shown.setCanceledOnTouchOutside(false)',
    'dialog != shown || !shown.isShowing()',
    'apk.length() != manifest.apkSize',
    '!manifest.apkSha256.equals(sha256(apk))',
    'archive.getLongVersionCode() != manifest.versionCode',
    'archive.getLongVersionCode() <= current.getLongVersionCode()',
    '!manifest.versionName.equals(archive.versionName)',
    'signers.length != 1',
    'UpdateManifest.APPLICATION_ID.equals(activity.getPackageName())',
    'FILE_PROVIDER_AUTHORITY = "app.tree55.threads.fileprovider"',
    'CACHE_APK_NAME = "threadsmod-update.apk"',
    'CACHE_PART_NAME = "threadsmod-update.apk.part"',
    'new Intent(Intent.ACTION_VIEW)',
    'Intent.FLAG_GRANT_READ_URI_PERMISSION')) {
    if (-not $updateControllerCode.Contains((Get-JavaCompactCode -Text $literal), [StringComparison]::Ordinal)) {
        throw "Update dialog/installer contract is missing: $literal"
    }
}
$updateRedirectStatusBlock = Get-JavaBlockBody -Text $updateControllerText `
    -Anchor 'private static boolean isAllowedRedirect(' `
    -Label 'UpdateController.isAllowedRedirect'
foreach ($allowedRedirectLiteral in @(
        'HttpsURLConnection.HTTP_MOVED_PERM',
        'HttpsURLConnection.HTTP_MOVED_TEMP',
        'HttpsURLConnection.HTTP_SEE_OTHER',
        'status == 307',
        'status == 308')) {
    if (-not $updateRedirectStatusBlock.Contains(
            $allowedRedirectLiteral, [StringComparison]::Ordinal)) {
        throw "Updater redirect status allowlist omits: $allowedRedirectLiteral"
    }
}
foreach ($forbiddenRedirectStatus in @(300, 304, 305, 306)) {
    if ($updateRedirectStatusBlock.Contains(
            "status == $forbiddenRedirectStatus", [StringComparison]::Ordinal)) {
        throw "Updater redirect status allowlist accepts forbidden status: $forbiddenRedirectStatus"
    }
}
$updateSameBinary = Get-JavaBlockBody -Text $updateManifestText `
    -Anchor 'boolean sameBinary(' -Label 'UpdateManifest.sameBinary'
if ($updateSameBinary.Contains('apkName', [StringComparison]::Ordinal) `
        -or -not $updateSameBinary.Contains(
            'versionName.equals(other.versionName)', [StringComparison]::Ordinal)) {
    throw 'Updater binary identity must bind versionName and must not bind the provider-specific APK basename.'
}
$updateLoad = Get-JavaBlockBody -Text $updateStoreText `
    -Anchor 'static synchronized UpdateManifest load(' -Label 'UpdateStore.load'
$updateInstallVerified = Get-JavaBlockBody -Text $updateStoreText `
    -Anchor 'static synchronized UpdateManifest installVerified(' `
    -Label 'UpdateStore.installVerified'
$uncertainReadIndex = $updateLoad.IndexOf(
    'if (policyPersistenceUncertain)', [StringComparison]::Ordinal)
$uncertainFloorCheckIndex = $updateInstallVerified.IndexOf(
    'requireMonotonicCandidate(candidate, policyPersistenceFloor)', [StringComparison]::Ordinal)
$preferencesIndex = $updateInstallVerified.IndexOf(
    'SharedPreferences preferences = prefs(context)', [StringComparison]::Ordinal)
$floorSetIndex = $updateInstallVerified.IndexOf(
    'policyPersistenceFloor = candidate', [StringComparison]::Ordinal)
$uncertainSetIndex = $updateInstallVerified.IndexOf(
    'policyPersistenceUncertain = true', [StringComparison]::Ordinal)
$commitIndex = $updateInstallVerified.IndexOf('.commit()', [StringComparison]::Ordinal)
$falseFailureIndex = $updateInstallVerified.IndexOf(
    'if (!saved) throw new IllegalStateException("update manifest persistence failed")',
    [StringComparison]::Ordinal)
$retainedPolicySetIndex = $updateInstallVerified.IndexOf(
    'lastVerifiedManifestForEnforcement = candidate', [StringComparison]::Ordinal)
$uncertainClearIndex = $updateInstallVerified.IndexOf(
    'policyPersistenceUncertain = false', [StringComparison]::Ordinal)
$floorClearIndex = $updateInstallVerified.IndexOf(
    'policyPersistenceFloor = null', [StringComparison]::Ordinal)
if ($uncertainReadIndex -lt 0 `
        -or $uncertainFloorCheckIndex -lt 0 `
        -or $preferencesIndex -le $uncertainFloorCheckIndex `
        -or $floorSetIndex -lt 0 `
        -or $uncertainSetIndex -le $floorSetIndex `
        -or $uncertainSetIndex -lt 0 `
        -or $commitIndex -le $uncertainSetIndex `
        -or $falseFailureIndex -le $commitIndex `
        -or $retainedPolicySetIndex -le $falseFailureIndex `
        -or $uncertainClearIndex -le $retainedPolicySetIndex `
        -or $uncertainClearIndex -le $falseFailureIndex `
        -or $floorClearIndex -le $uncertainClearIndex) {
    throw 'Updater persistence uncertainty must check the strongest process floor before preferences, latch that candidate before commit, reject reads, survive throw/false, and clear only after a true commit.'
}
$updateRetainedRequired = Get-JavaBlockBody -Text $updateStoreText `
    -Anchor 'static synchronized boolean hasRetainedRequiredForEnforcement(' `
    -Label 'UpdateStore.hasRetainedRequiredForEnforcement'
if (-not $updateRetainedRequired.Contains(
            '!policyPersistenceUncertain || currentModBuild <= 0L',
            [StringComparison]::Ordinal) `
        -or -not $updateRetainedRequired.Contains(
            'currentModBuild < retained.minimumModBuild',
            [StringComparison]::Ordinal)) {
    throw 'Updater retained enforcement must exist only during persistence uncertainty and expose only a boolean that a previously verified policy requires the running mod build.'
}
$updateBeginInstall = Get-JavaBlockBody -Text $updateControllerText `
    -Anchor 'private static void beginInstall(' -Label 'UpdateController.beginInstall'
$verifiedApkIndex = $updateBeginInstall.IndexOf(
    'obtainVerifiedApk(activity.getApplicationContext(), manifest)', [StringComparison]::Ordinal)
$updateFinishDownload = Get-JavaBlockBody -Text $updateControllerText `
    -Anchor 'private static void finishDownload(' -Label 'UpdateController.finishDownload'
$currentBinaryIndex = $updateFinishDownload.IndexOf(
    'UpdateStore.runIfCurrentBinary(', [StringComparison]::Ordinal)
$installerIndex = $updateFinishDownload.IndexOf(
    'launchInstaller(installerActivity, completed)', [StringComparison]::Ordinal)
$updateRunIfCurrentBinary = Get-JavaBlockBody -Text $updateStoreText `
    -Anchor 'static synchronized int runIfCurrentBinary(' `
    -Label 'UpdateStore.runIfCurrentBinary'
$reloadIndex = $updateRunIfCurrentBinary.IndexOf(
    'UpdateManifest latest = load(context, nowMs)', [StringComparison]::Ordinal)
$sameBinaryIndex = $updateRunIfCurrentBinary.IndexOf(
    '!latest.sameBinary(expected)', [StringComparison]::Ordinal)
$actionIndex = $updateRunIfCurrentBinary.IndexOf('action.run()', [StringComparison]::Ordinal)
if ($verifiedApkIndex -lt 0 `
        -or $updateBeginInstall.Contains('launchInstaller(', [StringComparison]::Ordinal) `
        -or $currentBinaryIndex -lt 0 `
        -or $installerIndex -le $currentBinaryIndex `
        -or $reloadIndex -lt 0 `
        -or $sameBinaryIndex -le $reloadIndex `
        -or $actionIndex -le $sameBinaryIndex `
        -or $updateRunIfCurrentBinary.Contains(
            'hasRetainedRequiredForEnforcement', [StringComparison]::Ordinal)) {
    throw 'Updater verified-file handoff must use finishDownload -> synchronized current-binary persisted reload/check -> action-owned installer launch, with no direct beginInstall launch or retained-enforcement installer authority.'
}
$updateRunFallback = Get-JavaBlockBody -Text $updateControllerText `
    -Anchor 'private static void runFallback(' -Label 'UpdateController.runFallback'
$requiredDialogGuardIndex = $updateRunFallback.IndexOf(
    'dialogRequired && dialogOwnerGeneration == generation', [StringComparison]::Ordinal)
$requiredDialogShowingIndex = $updateRunFallback.IndexOf(
    'dialog != null && dialog.isShowing()', [StringComparison]::Ordinal)
$fallbackActionIndex = $updateRunFallback.IndexOf('action.run()', [StringComparison]::Ordinal)
$startCheck = Get-JavaBlockBody -Text $updateControllerText `
    -Anchor 'private static void startCheck(' -Label 'UpdateController.startCheck'
$retainedReloadIndex = $startCheck.IndexOf(
    'retained = UpdateStore.load(activity, System.currentTimeMillis())', [StringComparison]::Ordinal)
$retainedOnlyGuardIndex = $startCheck.IndexOf(
    'if (UpdateStore.hasRetainedRequiredForEnforcement(', [StringComparison]::Ordinal)
$retainedUnavailableIndex = $startCheck.IndexOf(
    'showRetainedRequiredUnavailable(activity, generation)', [StringComparison]::Ordinal)
$retainedPresentIndex = $startCheck.IndexOf(
    'if (presentIfApplicable(activity, generation, retained)) return', [StringComparison]::Ordinal)
$failureFallbackIndex = if ($retainedPresentIndex -ge 0) {
    $startCheck.IndexOf(
        'runFallback(activity, generation)', $retainedPresentIndex + 1,
        [StringComparison]::Ordinal)
} else { -1 }
if ($requiredDialogGuardIndex -lt 0 `
        -or $requiredDialogShowingIndex -le $requiredDialogGuardIndex `
        -or $fallbackActionIndex -le $requiredDialogShowingIndex `
        -or $retainedReloadIndex -lt 0 `
        -or $retainedOnlyGuardIndex -le $retainedReloadIndex `
        -or $retainedUnavailableIndex -le $retainedOnlyGuardIndex `
        -or $retainedPresentIndex -le $retainedUnavailableIndex `
        -or $retainedPresentIndex -le $retainedReloadIndex `
        -or $failureFallbackIndex -le $retainedPresentIndex) {
    throw 'Updater fallback must preserve a current showing required dialog; refresh failure may show retained-required unavailable UI but may present installable UI only from a successful persisted load.'
}
$retainedAccessorCount = Get-PatchletLiteralCount -Text $updateControllerText `
    -Literal 'UpdateStore.hasRetainedRequiredForEnforcement('
$retainedUnavailableCallCount = Get-PatchletLiteralCount -Text $updateControllerText `
    -Literal 'showRetainedRequiredUnavailable(activity, generation);'
$retainedUnavailableHelper = Get-JavaBlockBody -Text $updateControllerText `
    -Anchor 'private static void showRetainedRequiredUnavailable(' `
    -Label 'UpdateController.showRetainedRequiredUnavailable'
if ($retainedAccessorCount -ne 3 `
        -or $retainedUnavailableCallCount -ne 3 `
        -or -not $retainedUnavailableHelper.Contains(
            'showUnavailable(activity, generation,', [StringComparison]::Ordinal) `
        -or $updateStoreText.Contains(
            'UpdateManifest retainedRequiredForEnforcement(', [StringComparison]::Ordinal)) {
    throw 'Updater retained-required enforcement must have exactly three boolean Store checks and three unavailable-only UI routes, with no retained-manifest accessor.'
}
foreach ($retainedAuthorityForbidden in @(
        'presentIfApplicable(',
        'beginInstall(',
        'obtainVerifiedApk(',
        'ACTION_MANAGE_UNKNOWN_APP_SOURCES',
        'launchInstaller(')) {
    if ($retainedUnavailableHelper.Contains(
            $retainedAuthorityForbidden, [StringComparison]::Ordinal)) {
        throw "Retained-required unavailable UI must not gain update/install authority: $retainedAuthorityForbidden"
    }
}
$reportJavaText = @(Get-ChildItem `
    -LiteralPath (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting') `
    -Recurse -File -Filter '*.java') `
    | ForEach-Object { Get-NormalizedPatchletText -Path $_.FullName }
$productionAssetFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $assetsRoot 'autoblock\java') -Recurse -File -Filter '*.java'
    Get-ChildItem -LiteralPath $bridgeTemplateRoot -Recurse -File -Filter '*.tmpl'
    Get-ChildItem -LiteralPath $inlineTemplateRoot -Recurse -File -Filter '*.tmpl'
    Get-ChildItem -LiteralPath $reportTemplateRoot -Recurse -File -Filter '*.tmpl'
    Get-ChildItem -LiteralPath $settingsTemplateRoot -Recurse -File -Filter '*.tmpl'
)
$joinedProductionAssets = @($productionAssetFiles `
    | Sort-Object FullName `
    | ForEach-Object { Get-NormalizedPatchletText -Path $_.FullName }) -join "`n"
$proxyStoreCode = Get-JavaCompactCode -Text $proxyStoreText
$proxyRouteCode = Get-JavaCompactCode -Text $proxyRouteText
$proxyControllerCode = Get-JavaCompactCode -Text $proxyControllerText
$proxyServiceCode = Get-JavaCompactCode -Text $proxyServiceText
$proxySettingsActivityCode = Get-JavaCompactCode -Text $proxySettingsActivityText
$expectedProxyPreferenceKeys = [ordered]@{
    KEY_SCHEMA_VERSION = 'threadsmod_proxy_schema_version'
    KEY_GENERATION = 'threadsmod_proxy_generation'
    KEY_ENABLED = 'threadsmod_proxy_enabled'
    KEY_HOST = 'threadsmod_proxy_host'
    KEY_PORT = 'threadsmod_proxy_port'
    KEY_AUTH_ENABLED = 'threadsmod_proxy_auth_enabled'
    KEY_CREDENTIALS_CIPHERTEXT = 'threadsmod_proxy_credentials_ciphertext'
    KEY_CREDENTIALS_IV = 'threadsmod_proxy_credentials_iv'
    KEY_BYPASS_RULES = 'threadsmod_proxy_bypass_rules_v1'
    KEY_FAIL_CLOSED = 'threadsmod_proxy_fail_closed'
}
foreach ($proxyPreferenceEntry in $expectedProxyPreferenceKeys.GetEnumerator()) {
    $proxyDeclaration = [string]$proxyPreferenceEntry.Key + '="' `
        + [string]$proxyPreferenceEntry.Value + '"'
    if (-not $proxyStoreCode.Contains($proxyDeclaration, [StringComparison]::Ordinal) `
            -or (Get-PatchletLiteralCount -Text $proxyStoreText `
                -Literal ('"' + [string]$proxyPreferenceEntry.Value + '"')) -ne 1) {
        throw "Proxy preference key is missing, duplicated, or not namespaced: $($proxyPreferenceEntry.Key)"
    }
}
$proxyOwnedKeysBody = Get-JavaBlockBody -Text $proxyStoreText `
    -Anchor 'private static final String[] OWNED_KEYS' -Label 'proxy owned preference keys'
$proxyOwnedKeyNames = @([regex]::Matches($proxyOwnedKeysBody, '\bKEY_[A-Z_]+\b') `
    | ForEach-Object { $_.Value } `
    | Sort-Object -Unique)
$expectedProxyOwnedKeyNames = @($expectedProxyPreferenceKeys.Keys | Sort-Object)
if ($proxyOwnedKeyNames.Count -ne $expectedProxyOwnedKeyNames.Count `
        -or @(Compare-Object -ReferenceObject $expectedProxyOwnedKeyNames `
            -DifferenceObject $proxyOwnedKeyNames).Count -ne 0) {
    throw 'ProxyConfigStore does not own exactly the ten reviewed namespaced preference keys.'
}
$forbiddenPlaintextCredentialKeys = @(
    'threadsmod_proxy_username',
    'threadsmod_proxy_user',
    'threadsmod_proxy_password',
    'threadsmod_proxy_pass',
    'proxy_username',
    'proxy_password'
)
foreach ($forbiddenCredentialKey in $forbiddenPlaintextCredentialKeys) {
    if ($joinedProductionAssets.Contains(
            $forbiddenCredentialKey, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Plaintext proxy credential preference key is forbidden: $forbiddenCredentialKey"
    }
}
if ([regex]::IsMatch($proxyStoreCode, 'KEY_(?:USER|USERNAME|PASS|PASSWORD)=') `
        -or [regex]::IsMatch($proxyStoreCode, '\.putString\(KEY_(?:USER|USERNAME|PASS|PASSWORD),')) {
    throw 'ProxyConfigStore must not declare or write plaintext username/password keys.'
}
$namedProxyStringWriteKeys = @([regex]::Matches(
        $proxyStoreCode, '\.putString\((KEY_[A-Z_]+),') `
    | ForEach-Object { $_.Groups[1].Value })
$expectedProxyStringWriteKeys = @(
    'KEY_BYPASS_RULES',
    'KEY_CREDENTIALS_CIPHERTEXT',
    'KEY_CREDENTIALS_IV',
    'KEY_HOST'
)
if ($namedProxyStringWriteKeys.Count -ne $expectedProxyStringWriteKeys.Count `
        -or @(Compare-Object -ReferenceObject ($expectedProxyStringWriteKeys | Sort-Object) `
            -DifferenceObject ($namedProxyStringWriteKeys | Sort-Object)).Count -ne 0) {
    throw 'ProxyConfigStore named String writes must be limited to host, bypass, ciphertext, and IV.'
}
if (-not $proxyStoreCode.Contains(
            'KEY_ALIAS="threadsmod_proxy_config_aes_v1"', [StringComparison]::Ordinal) `
        -or -not $proxyStoreCode.Contains(
            'CIPHER="AES/GCM/NoPadding"', [StringComparison]::Ordinal) `
        -or -not $proxyStoreCode.Contains(
            'byte[]plaintext=credentialBytes(config);', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $proxyStoreCode `
            -Literal 'cipher.updateAAD(aad);') -ne 2 `
        -or -not $proxyStoreCode.Contains(
            '.putString(KEY_CREDENTIALS_CIPHERTEXT,secret.ciphertext).putString(KEY_CREDENTIALS_IV,secret.iv);',
            [StringComparison]::Ordinal)) {
    throw 'Proxy username/password are not proven to share the reviewed authenticated Keystore ciphertext blob.'
}
if (-not $proxyRouteCode.Contains(
            'if(Build.VERSION.SDK_INT>=33){addRoute(builder,newbyte[4],0);addRoute(builder,newbyte[16],0);',
            [StringComparison]::Ordinal) `
        -or -not $proxyRouteCode.Contains(
            'builder.excludeRoute(newIpPrefix(toInetAddress(prefix.network),prefix.length));',
            [StringComparison]::Ordinal) `
        -or -not $proxyRouteCode.Contains(
            'if(Build.VERSION.SDK_INT<33){ipv4Routes=complement(normalized,32);ipv6Routes=complement(normalized,128);',
            [StringComparison]::Ordinal) `
        -or -not $proxyRouteCode.Contains(
            'publicstaticfinalintMAX_COMPLEMENT_ROUTES=4096;', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $proxyServiceCode `
            -Literal 'builder.addAllowedApplication(getPackageName());') -ne 1 `
        -or $proxyServiceCode.Contains('.allowBypass(', [StringComparison]::Ordinal) `
        -or -not $proxyServiceCode.Contains('routePlan.apply(builder);', [StringComparison]::Ordinal)) {
    throw 'Proxy VPN routing is not statically bound to the app-only, fail-closed reviewed route planner.'
}
$expectedProxyRuntimeStates = [ordered]@{
    STATE_PAUSED_VPN = 'paused_vpn'
    STATE_PAUSED_GUARD_ACTIVE = 'paused_guard_active'
    STATE_PAUSED_GUARD_RETAINED = 'paused_guard_retained'
    STATE_UNPROTECTED_PRIOR_ROUTING = 'unprotected_prior_routing'
}
foreach ($runtimeStateEntry in $expectedProxyRuntimeStates.GetEnumerator()) {
    $stateDeclaration = 'publicstaticfinalString' + [string]$runtimeStateEntry.Key `
        + '="' + [string]$runtimeStateEntry.Value + '";'
    if (-not $proxyServiceCode.Contains($stateDeclaration, [StringComparison]::Ordinal) `
            -or (Get-PatchletLiteralCount -Text $proxyServiceText `
                -Literal ('"' + [string]$runtimeStateEntry.Value + '"')) -ne 1) {
        throw "Proxy runtime state is missing, duplicated, or renamed: $($runtimeStateEntry.Key)"
    }
}
$ensureConnectGuardCode = Get-JavaBlockBody -Text $proxyServiceCode `
    -Anchor 'privatebooleanensureConnectGuard(intgeneration)' `
    -Label 'Socks5VpnService.ensureConnectGuard'
$enterBlackholeCode = Get-JavaBlockBody -Text $proxyServiceCode `
    -Anchor 'privatebooleanenterBlackhole(intgeneration,Stringstate)' `
    -Label 'Socks5VpnService.enterBlackhole'
foreach ($guardStateProof in @(
        @($ensureConnectGuardCode,
            'if(activeTun!=null&&activeTunIsGuard){setRuntimeState(STATE_PAUSED_GUARD_RETAINED,"Trafficremainspaused;priorfull-routeguardretained");}elseif(activeTun!=null){setRuntimeState(STATE_UNPROTECTED_PRIOR_ROUTING,"PriorVPNroutingretained;earliernumericDIRECTexclusionsmayremain");}else{setRuntimeState(STATE_PAUSED_VPN,"VPNguardunavailable;directtrafficmaycontinue");}',
            'fresh connect guard failure split'),
        @($enterBlackholeCode,
            'if(activeTun!=null&&activeTunIsGuard){StringretainedState=STATE_PAUSED_VPN.equals(state)?STATE_PAUSED_GUARD_RETAINED:state;setRuntimeState(retainedState,STATE_PAUSED_GUARD_RETAINED.equals(retainedState)?"Trafficremainspaused;priorfull-routeguardretained":"Trafficremainspausedforsafety");returntrue;}if(activeTun!=null){setRuntimeState(STATE_UNPROTECTED_PRIOR_ROUTING,"PriorVPNroutingretained;earliernumericDIRECTexclusionsmayremain");returnfalse;}setRuntimeState(STATE_PAUSED_VPN,"VPNguardunavailable;directtrafficmaycontinue");returnfalse;',
            'blackhole replacement failure split'),
        @($enterBlackholeCode,
            'if(!adoptBlackholeCandidateLocked(candidate)){setRuntimeState(STATE_PAUSED_NATIVE,"Trafficpaused;nativeshutdownunconfirmed");returntrue;}StringactiveState=STATE_PAUSED_VPN.equals(state)?STATE_PAUSED_GUARD_ACTIVE:state;setRuntimeState(activeState,STATE_PAUSED_GUARD_ACTIVE.equals(activeState)?"Trafficpaused;full-routeguardactive":"Trafficpausedforsafety");returntrue;',
            'successful blackhole guard state'))) {
    if (-not ([string]$guardStateProof[0]).Contains(
            [string]$guardStateProof[1], [StringComparison]::Ordinal)) {
        throw "Proxy does not preserve the reviewed truthful state topology: $($guardStateProof[2])"
    }
}
foreach ($controllerStateProof in @(
        'if(Socks5VpnService.STATE_PAUSED_GUARD_ACTIVE.equals(runtime)){return"Paused:afull-routeguardisactive;apptrafficremainsblocked.";}',
        'if(Socks5VpnService.STATE_PAUSED_GUARD_RETAINED.equals(runtime)){return"Paused:thepriorfull-routeguardisretained;apptrafficremainsblocked.";}',
        'if(Socks5VpnService.STATE_UNPROTECTED_PRIOR_ROUTING.equals(runtime)){return"Unprotected:Androidrefusedthefreshfull-routeguard;priorVPNroutingisretainedandearliernumericDIRECTexclusionsmayremain.";}',
        'if(Socks5VpnService.STATE_PAUSED_VPN.equals(runtime)){return"Unprotected:AndroidcouldnotestablishtheVPN;directtrafficmaycontinue.";}',
        'if(Socks5VpnService.STATE_DISABLED.equals(runtime)){return"Unprotected:proxyserviceisinactive;directtrafficmaycontinue.";}')) {
    if (-not $proxyControllerCode.Contains(
            $controllerStateProof, [StringComparison]::Ordinal)) {
        throw 'Proxy Settings status does not truthfully distinguish active guard, retained guard, retained forwarding, no-TUN, and disabled-runtime states.'
    }
}
$proxyRefreshStatusCode = Get-JavaBlockBody -Text $proxySettingsActivityCode `
    -Anchor 'privatevoidrefreshStatus()' -Label 'ProxySettingsActivity.refreshStatus'
$proxyStartPollingCode = Get-JavaBlockBody -Text $proxySettingsActivityCode `
    -Anchor 'privatevoidstartStatusPolling()' -Label 'ProxySettingsActivity.startStatusPolling'
if ($proxyServiceText.Contains(
        'VPN replacement unavailable; prior routing retained', [StringComparison]::Ordinal) `
        -or -not $proxySettingsActivityCode.Contains(
            'privatestaticfinallongSTATUS_REFRESH_MILLIS=500L;', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $proxySettingsActivityCode `
            -Literal 'Socks5VpnService.runtimeState()') -ne 2 `
        -or (Get-PatchletLiteralCount -Text $proxySettingsActivityCode `
            -Literal 'statusHandler.postDelayed(') -ne 2 `
        -or (Get-PatchletLiteralCount -Text $proxySettingsActivityCode `
            -Literal 'statusHandler.removeCallbacks(statusRefreshTask);') -ne 2 `
        -or -not $proxySettingsActivityCode.Contains(
            'if(!statusHandler.postDelayed(this,STATUS_REFRESH_MILLIS)){statusPolling=false;showStatusRefreshUnavailable();}',
            [StringComparison]::Ordinal) `
        -or -not $proxySettingsActivityCode.Contains(
            'if(!statusHandler.postDelayed(statusRefreshTask,STATUS_REFRESH_MILLIS)){statusPolling=false;showStatusRefreshUnavailable();}',
            [StringComparison]::Ordinal) `
        -or -not $proxySettingsActivityCode.Contains(
            'protectedvoidonResume(){super.onResume();if(contentReady){restoreSensitiveFieldsIfNeeded();refreshStatus();startStatusPolling();}}',
            [StringComparison]::Ordinal) `
        -or -not $proxyRefreshStatusCode.Contains(
            'observedRuntimeState=Socks5VpnService.runtimeState();Stringstatus=ProxyController.status(this);',
            [StringComparison]::Ordinal) `
        -or $proxyStartPollingCode.Contains(
            'Socks5VpnService.runtimeState()', [StringComparison]::Ordinal) `
        -or -not $proxyStartPollingCode.Contains(
            'statusPolling=true;if(!statusHandler.postDelayed(statusRefreshTask,STATUS_REFRESH_MILLIS))',
            [StringComparison]::Ordinal) `
        -or -not $proxySettingsActivityCode.Contains(
            'protectedvoidonPause(){stopStatusPolling();if(usernameInput!=null)',
            [StringComparison]::Ordinal) `
        -or -not $proxySettingsActivityText.Contains(
            'Unavailable: live proxy status refresh stopped. Reopen this page before relying on proxy status.',
            [StringComparison]::Ordinal)) {
    throw 'Proxy Settings live-status polling is not lifecycle-bounded, enqueue-checked, and visibly fail-closed.'
}
$expectedReadUrls = @(
    'https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/blocklist/v3/manifest.json',
    'https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/blocklist/v3/manifest.json',
    'https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/blocklist/v3/manifest.json'
)
$expectedObjectBases = @(
    'https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/blocklist/v3/objects/',
    'https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/blocklist/v3/objects/',
    'https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/blocklist/v3/objects/'
)
$previousObjectBaseIndex = -1
foreach ($expectedObjectBase in $expectedObjectBases) {
    $objectBaseIndex = $readEndpointText.IndexOf($expectedObjectBase, [StringComparison]::Ordinal)
    if ($objectBaseIndex -le $previousObjectBaseIndex `
            -or (Get-PatchletLiteralCount -Text $readEndpointText `
                -Literal $expectedObjectBase) -ne 1) {
        throw 'Clone Blocker object bases must occur exactly once in GitHub raw, jsDelivr, then AWS order.'
    }
    $previousObjectBaseIndex = $objectBaseIndex
}
foreach ($retiredReadUrl in @(
        'published/blocklist.json',
        '@published/blocklist.json',
        'amazonaws.com/blocklist.json')) {
    if ($joinedProductionAssets.Contains($retiredReadUrl, [StringComparison]::Ordinal)) {
        throw "Retired whole-file blocklist URL must not survive in production assets: $retiredReadUrl"
    }
}
$objectUrlBody = Get-JavaBlockBody -Text $readEndpointText `
    -Anchor 'static URL objectUrl(int index, String name)' -Label 'allowlisted object URL'
$objectUrlCode = Get-JavaCompactCode -Text $objectUrlBody
$objectNameGuardIndex = $objectUrlCode.IndexOf('if(!isObjectName(name))', [StringComparison]::Ordinal)
$objectConcatIndex = $objectUrlCode.IndexOf('OBJECT_BASES[index]+name', [StringComparison]::Ordinal)
if ($objectNameGuardIndex -lt 0 -or $objectConcatIndex -le $objectNameGuardIndex `
        -or -not $objectUrlCode.Contains(
            'thrownewSecurityException("CloneBlockerobjectnameisnotallowlisted");',
            [StringComparison]::Ordinal)) {
    throw 'Object names must be validated against the 64-hex + suffix grammar before any URL text is formed.'
}
$previousReadUrlIndex = -1
foreach ($expectedReadUrl in $expectedReadUrls) {
    $readUrlIndex = $readEndpointText.IndexOf($expectedReadUrl, [StringComparison]::Ordinal)
    if ($readUrlIndex -le $previousReadUrlIndex `
            -or (Get-PatchletLiteralCount -Text $readEndpointText `
                -Literal $expectedReadUrl) -ne 1) {
        throw 'Clone Blocker read mirrors must occur exactly once in GitHub raw, jsDelivr, then AWS order.'
    }
    $previousReadUrlIndex = $readUrlIndex
}
$expectedWriteUrl = 'https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/reports'
$expectedStatsUrl = 'https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/installs'
$expectedCanonicalPermalinkPrefix = 'https://www.threads.com/@'
if ((Get-PatchletLiteralCount -Text $joinedProductionAssets -Literal 'https://') -ne 13 `
        -or (Get-PatchletLiteralCount -Text $joinedProductionAssets -Literal 'http://') -ne 0 `
        -or (Get-PatchletLiteralCount -Text $endpointText -Literal $expectedWriteUrl) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $endpointText -Literal 'new URL(WRITE_URL)') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $endpointText -Literal $expectedStatsUrl) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $endpointText -Literal 'new URL(STATS_URL)') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $joinedProductionAssets -Literal $expectedStatsUrl) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reportRequestText `
            -Literal $expectedCanonicalPermalinkPrefix) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reportValuesText `
            -Literal $expectedCanonicalPermalinkPrefix) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $joinedProductionAssets `
            -Literal $expectedCanonicalPermalinkPrefix) -ne 2) {
    throw 'Runtime assets must contain only the reviewed reads, the report write, the activation-statistics write, plus the A75 constructor and shared canonicalizer Threads post-link prefixes.'
}
foreach ($retiredProfileLookupArtifact in @('lookup_failure', 'UserFetchCallback')) {
    if ($joinedProductionAssets.Contains(
            $retiredProfileLookupArtifact, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Retired profile-info lookup artifact remains in a production asset: $retiredProfileLookupArtifact"
    }
}
if (Test-Path -LiteralPath (
        Join-Path $bridgeTemplateRoot 'UserFetchCallback.smali.tmpl')) {
    throw 'Retired UserFetchCallback template remains in the canonical bridge template directory.'
}
$clickTemplateText = Get-NormalizedPatchletText -Path (Join-Path $inlineTemplateRoot 'InlineActionClick.smali.tmpl')
$rowAdapterTemplateText = Get-NormalizedPatchletText -Path (Join-Path $inlineTemplateRoot 'InlineActionRowAdapter.smali.tmpl')
$visibilityTemplateText = Get-NormalizedPatchletText -Path (Join-Path $inlineTemplateRoot 'InlineVisibilityCallback.smali.tmpl')
$bridgeTemplateText = Get-NormalizedPatchletText -Path (Join-Path $bridgeTemplateRoot 'ThreadsBlockBridge.smali.tmpl')
$mutationTemplateText = Get-NormalizedPatchletText -Path (Join-Path $bridgeTemplateRoot 'MutationCallback.smali.tmpl')
$bridgeReferenceText = Get-NormalizedPatchletText -Path (
    Join-Path $bridgeReferenceRoot 'ThreadsBlockBridge.smali')
$mutationReferenceText = Get-NormalizedPatchletText -Path (
    Join-Path $bridgeReferenceRoot 'MutationCallback.smali')

$refreshBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static String refreshBlocklist(' -Label 'passive refresh'
$fetchMirrorBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static VerifiedList fetchMirror(' -Label 'passive mirror fetch'
$installCandidateBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static String installVerifiedCandidate(' -Label 'freshest verified candidate install'
$passiveLoadBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static PassiveTargetSelection loadTarget(' `
    -Label 'single passive target loader'
$passiveLookupBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static final class PassiveLookupWorker' -Label 'passive lookup worker'
$listRefreshWorkerBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static final class ListRefreshWorker' -Label 'list refresh worker'
$requestListRefreshBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static void requestListRefresh(' -Label 'list refresh admission'
$readListRefreshDeadlineBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static DeadlineState readListRefreshDeadline(' `
    -Label 'typed list refresh deadline reader'
$advanceListRefreshDeadlineBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static boolean advanceListRefreshDeadline(' `
    -Label 'durable list refresh deadline advance'
$readDeadlineBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static DeadlineState readDeadline(' `
    -Label 'strict typed deadline reader'
$readDeadlineTryBody = Get-JavaBlockBody -Text $readDeadlineBody `
    -Anchor 'try' -Label 'strict typed deadline SharedPreferences read'
$readDeadlineCatchBody = Get-JavaBlockBody -Text $readDeadlineBody `
    -Anchor 'catch (Throwable ignored)' -Label 'strict typed deadline read failure'
$readListRefreshDeadlineTryBody = Get-JavaBlockBody -Text $readListRefreshDeadlineBody `
    -Anchor 'try' -Label 'list refresh SharedPreferences acquisition'
$readListRefreshDeadlineCatchBody = Get-JavaBlockBody -Text $readListRefreshDeadlineBody `
    -Anchor 'catch (Throwable ignored)' -Label 'list refresh SharedPreferences failure'
$nextListRefreshDelayBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static long millisUntilNextListRefresh(' `
    -Label 'list refresh retry cadence'
$requestListForceRefreshBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static boolean requestListForceRefresh(' `
    -Label 'viewer-scoped forced list refresh request'
$visibilityUpdateBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'public static void updateVisibleControl(' -Label 'Compose visibility update'
$visibilityRegisterBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'public static boolean registerVisibleControl(' -Label 'Compose visibility register'
$visibilityUnregisterBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'public static void unregisterVisibleControl(' -Label 'Compose visibility unregister'
$pauseBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'public static void onPause(' -Label 'foreground pause'
$schedulerStructureText = Remove-JavaComments -Text $schedulerText
$automaticBeginBody = Get-JavaBlockBody -Text $schedulerStructureText `
    -Anchor 'void begin()' -Label 'one-target automatic scheduler admission'
$refreshWakeBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static void armListRefreshWake(' -Label '10-minute refresh wake'
$signedParserBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static VerifiedList parseAndVerify(' -Label 'signed passive-list parser'
$signedRootByteCapBody = Get-JavaBlockBody -Text $signedParserBody `
    -Anchor 'if (body.length() > MAX_ROOT_BYTES)' -Label 'signed root byte cap'
$signedRootVersionBody = Get-JavaBlockBody -Text $signedParserBody `
    -Anchor 'if (!(versionValue instanceof Integer) || ((Integer) versionValue).intValue() != 3)' `
    -Label 'signed root version guard'
$signedRootHashBody = Get-JavaBlockBody -Text $signedParserBody `
    -Anchor 'if (!(hashValue instanceof String) || !"sha256-hi32".equals((String) hashValue))' `
    -Label 'signed root bucket-function guard'
$signedRootThreadsBody = Get-JavaBlockBody -Text $signedParserBody `
    -Anchor 'if (!(threadsValue instanceof JSONObject))' -Label 'signed root threads partition guard'
$chunkRowBody = Get-JavaBlockBody -Text $chunkInstallerText `
    -Anchor 'private static void parseRow(' -Label 'chunk row parser'
$chunkParseBody = Get-JavaBlockBody -Text $chunkInstallerText `
    -Anchor 'private static ArrayList<BlocklistStore.Entry> parseChunk(' -Label 'chunk parser'
$chunkStageBucketBody = Get-JavaBlockBody -Text $chunkInstallerText `
    -Anchor 'private static void stageBucket(' -Label 'chunk stage'
$objectFetchOnceBody = Get-JavaBlockBody -Text $objectFetcherText `
    -Anchor 'static byte[] fetchOnce(int mirror, String name, String accept, int cap, int exactBytes)' `
    -Label 'object fetch'
$currentPassiveMatchBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static PassiveMatchResult currentPassiveMatch(' `
    -Label 'tri-state current passive match'
$latchPassiveStorePauseBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static void latchPassiveStorePause(' `
    -Label 'invalid passive-store latch'
$clearPassiveStorePauseBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static boolean clearPassiveStorePauseAfterVerifiedGeneration(' `
    -Label 'verified-generation pause clear'
$prepareBlocklistBatchBody = Get-JavaBlockBody -Text $blocklistStoreText `
    -Anchor 'private static PreparedBatch prepareBatch(' -Label 'blocklist batch preparation'
$lookupBlocklistIdBody = Get-JavaBlockBody -Text $blocklistStoreText `
    -Anchor 'public static IdMatch lookupId(' -Label 'blocklist exact-ID lookup'
$currentBlocklistIdBody = Get-JavaBlockBody -Text $blocklistStoreText `
    -Anchor 'public static IdMatch isCurrentIdMatch(' -Label 'blocklist current-ID lookup'
$idMatchTypeBody = Get-JavaBlockBody -Text $blocklistStoreText `
    -Anchor 'public static final class IdMatch' -Label 'blocklist exact-ID result type'
$firstBlocklistMetadataReaderIndex = $blocklistStoreText.IndexOf(
    'private static StoredMetadata readMetadata(', [StringComparison]::Ordinal)
$fullBlocklistMetadataReaderIndex = $blocklistStoreText.IndexOf(
    'private static StoredMetadata readMetadata(',
    $firstBlocklistMetadataReaderIndex + 1, [StringComparison]::Ordinal)
if ($firstBlocklistMetadataReaderIndex -lt 0 `
        -or $fullBlocklistMetadataReaderIndex -le $firstBlocklistMetadataReaderIndex) {
    throw 'Blocklist metadata wrapper/full-reader topology is missing.'
}
$readBlocklistMetadataBody = Get-JavaBlockBody -Text $blocklistStoreText `
    -Anchor 'private static StoredMetadata readMetadata(' `
    -StartIndex $fullBlocklistMetadataReaderIndex `
    -Label 'blocklist full metadata reader'
$requireBlocklistRowsBody = Get-JavaBlockBody -Text $blocklistStoreText `
    -Anchor 'private static void requireRowCount(' -Label 'blocklist generation invariants'
$doneIdsReaderBody = Get-JavaBlockBody -Text $stateText `
    -Anchor 'private static HashSet<String> readDoneIds(' `
    -Label 'completed-target fail-closed reader'
$doneIdsSchedulerBody = Get-JavaBlockBody -Text $stateText `
    -Anchor 'static synchronized Set<String> doneIdsForScheduler(' `
    -Label 'completed-target scheduler snapshot'
$markAutomaticDoneBody = Get-JavaBlockBody -Text $stateText `
    -Anchor 'static synchronized boolean markAutomaticDone(' `
    -Label 'automatic completed-target append'
$schedulerCompact = Get-JavaCompactCode -Text $schedulerText

foreach ($requiredPassiveRuntimeLiteral in @(
        'private static final long FETCH_INTERVAL_MS = 10L * 60L * 1000L;',
        'new ListRefreshWorker(activity, viewer, runForced)',
        'private static final Object PASSIVE_ADMISSION_LOCK = new Object();',
        'BlocklistStore.replaceVerified(',
        'scheduleVisibleRegistrationRescan(activity.getApplicationContext())',
        'BlocklistStore.lookupId(context, targetId)',
        'BlocklistStore.isCurrentIdMatch(',
        'ModStateStore.markPassiveRunning(activity, viewer, targetId)',
        'ModStateStore.recoverInterruptedPassive(activity, viewer)')) {
    if (-not $schedulerText.Contains($requiredPassiveRuntimeLiteral, [StringComparison]::Ordinal)) {
        throw "Passive runtime contract is missing: $requiredPassiveRuntimeLiteral"
    }
}
if (-not $refreshBody.Contains('CloneBlockerEndpoints.blocklistMirrorCount()', [StringComparison]::Ordinal) `
        -or -not $refreshBody.Contains('fetchMirror(context, forceRefresh, mirror, snapshot)', [StringComparison]::Ordinal) `
        -or $refreshBody.Contains('new BlockRun', [StringComparison]::Ordinal) `
        -or $refreshBody.Contains('ThreadsBlockBridge', [StringComparison]::Ordinal) `
        -or $fetchMirrorBody.Contains('new BlockRun', [StringComparison]::Ordinal) `
        -or $fetchMirrorBody.Contains('ThreadsBlockBridge', [StringComparison]::Ordinal) `
        -or $fetchMirrorBody.Contains('BlocklistStore.replaceVerified(', [StringComparison]::Ordinal) `
        -or $fetchMirrorBody.Contains('BlocklistStore.markFetchedUnchanged(', [StringComparison]::Ordinal) `
        -or $installCandidateBody.Contains('new BlockRun', [StringComparison]::Ordinal) `
        -or $installCandidateBody.Contains('ThreadsBlockBridge', [StringComparison]::Ordinal) `
        -or $installCandidateBody.Contains('HttpsURLConnection', [StringComparison]::Ordinal)) {
    throw 'Signed-list refresh must only verify and atomically update the index; it cannot create or dispatch Block work, and a mirror fetch cannot install before every mirror was consulted.'
}
$retainedMirrorFailureBody = Get-JavaBlockBody -Text $refreshBody `
    -Anchor 'if (isUsableBlocklistSnapshot(retained, System.currentTimeMillis()))' `
    -Label 'all-mirror failure with retained verified generation'
if (-not $retainedMirrorFailureBody.Contains('throw lastError;', [StringComparison]::Ordinal) `
        -or -not $retainedMirrorFailureBody.Contains(
            'public mirrors failed while a prior verified generation was retained',
            [StringComparison]::Ordinal) `
        -or $refreshBody.Contains(
            'return "Public mirrors failed; retained the previous verified indexed list',
            [StringComparison]::Ordinal)) {
    throw 'All-mirror failure must remain a failed refresh even when the prior verified generation remains usable.'
}
$strictlyNewerGuardIndex = $installCandidateBody.IndexOf(
    'best.publishedAtMs <= previousSnapshot.verifiedUpdatedAtMs', [StringComparison]::Ordinal)
$unchangedAdvanceIndex = $installCandidateBody.IndexOf(
    'BlocklistStore.markFetchedUnchanged(context, best.fetchedAtMs)', [StringComparison]::Ordinal)
$verifiedReplaceIndex = $installCandidateBody.IndexOf(
    'BlocklistStore.replaceVerified(', [StringComparison]::Ordinal)
if ($strictlyNewerGuardIndex -lt 0 -or $unchangedAdvanceIndex -le $strictlyNewerGuardIndex `
        -or $verifiedReplaceIndex -le $unchangedAdvanceIndex) {
    throw 'Only a strictly newer verified candidate may replace the committed generation; an equal or older reachable payload must advance fetch metadata only.'
}
$conditionalMetadataIndex = $installCandidateBody.IndexOf(
    'boolean conditionalMetadataSaved = false', $verifiedReplaceIndex,
    [StringComparison]::Ordinal)
$conditionalMetadataCommitIndex = $installCandidateBody.IndexOf(
    'conditionalMetadataSaved = edit.commit()', $conditionalMetadataIndex,
    [StringComparison]::Ordinal)
$conditionalMetadataReturnIndex = $installCandidateBody.IndexOf(
    'return "Verified and indexed "', $conditionalMetadataCommitIndex,
    [StringComparison]::Ordinal)
$conditionalMetadataTail = if ($conditionalMetadataIndex -ge 0) {
    $installCandidateBody.Substring($conditionalMetadataIndex)
} else {
    ''
}
if ($verifiedReplaceIndex -lt 0 `
        -or $conditionalMetadataIndex -le $verifiedReplaceIndex `
        -or $conditionalMetadataCommitIndex -le $conditionalMetadataIndex `
        -or $conditionalMetadataReturnIndex -le $conditionalMetadataCommitIndex `
        -or -not $conditionalMetadataTail.Contains(
            'catch (Throwable ignored)', [StringComparison]::Ordinal) `
        -or -not $conditionalMetadataTail.Contains(
            'Conditional fetch metadata will retry later.', [StringComparison]::Ordinal) `
        -or $conditionalMetadataTail.Contains('throw ', [StringComparison]::Ordinal)) {
    throw 'Optional ETag persistence may not mislabel an already committed signed SQLite generation as failed.'
}
if (-not $refreshWakeBody.Contains('MAIN.postDelayed(', [StringComparison]::Ordinal) `
        -or -not $refreshWakeBody.Contains('boolean posted', [StringComparison]::Ordinal) `
        -or -not $refreshWakeBody.Contains('if (!posted)', [StringComparison]::Ordinal)) {
    throw 'The 10-minute foreground refresh wake must check Handler enqueue acceptance.'
}
$requestListRefreshCode = Get-JavaCompactCode -Text $requestListRefreshBody
$listRefreshWorkerCode = Get-JavaCompactCode -Text $listRefreshWorkerBody
$readDeadlineCode = Get-JavaCompactCode -Text $readDeadlineBody
$readDeadlineTryCode = Get-JavaCompactCode -Text $readDeadlineTryBody
$readDeadlineCatchCode = Get-JavaCompactCode -Text $readDeadlineCatchBody
$readListRefreshDeadlineCode = Get-JavaCompactCode -Text $readListRefreshDeadlineBody
$readListRefreshDeadlineTryCode = Get-JavaCompactCode -Text $readListRefreshDeadlineTryBody
$readListRefreshDeadlineCatchCode = Get-JavaCompactCode -Text $readListRefreshDeadlineCatchBody
$advanceListRefreshDeadlineCode = Get-JavaCompactCode -Text $advanceListRefreshDeadlineBody
$nextListRefreshDelayCode = Get-JavaCompactCode -Text $nextListRefreshDelayBody
foreach ($requiredRefreshDeadlineProof in @(
        'privatestaticfinalStringKEY_LIST_REFRESH_NOT_BEFORE="list_refresh_not_before";',
        'privatestaticfinallongFETCH_INTERVAL_MS=10L*60L*1000L;',
        'privatestaticfinallongMAX_LIST_REFRESH_DEADLINE_FUTURE_MS=FETCH_INTERVAL_MS+2L*60L*1000L;')) {
    if (-not $schedulerCompact.Contains(
            $requiredRefreshDeadlineProof, [StringComparison]::Ordinal)) {
        throw "Persistent list-refresh cadence is missing typed/bounded state: $requiredRefreshDeadlineProof"
    }
}
foreach ($strictDeadlineReaderProof in @(
        'Map<String,?>values=preferences.getAll();',
        'if(values==null)',
        'if(!values.containsKey(key))',
        'if(!(rawinstanceofLong))',
        'longvalue=((Long)raw).longValue();',
        'if(value<0L||(value>now&&value-now>maximumFutureMs))')) {
    if (-not $readDeadlineCode.Contains(
            $strictDeadlineReaderProof, [StringComparison]::Ordinal)) {
        throw "List-refresh deadline is not raw-type checked and future-bounded: $strictDeadlineReaderProof"
    }
}
if ((Get-PatchletLiteralCount -Text $readDeadlineCode `
            -Literal 'preferences.getAll()') -ne 1 `
        -or -not $readDeadlineTryCode.Contains(
            'Map<String,?>values=preferences.getAll();',
            [StringComparison]::Ordinal) `
        -or $readDeadlineCatchCode -cne 'returnnewDeadlineState(false,0L);' `
        -or (Get-PatchletLiteralCount -Text $readListRefreshDeadlineCode `
            -Literal 'prefs(context)') -ne 1 `
        -or -not $readListRefreshDeadlineTryCode.Contains(
            'stored=readDeadline(prefs(context),KEY_LIST_REFRESH_NOT_BEFORE,now,MAX_LIST_REFRESH_DEADLINE_FUTURE_MS);',
            [StringComparison]::Ordinal) `
        -or $readListRefreshDeadlineCatchCode -cne 'returnnewDeadlineState(false,0L);') {
    throw 'SharedPreferences acquisition and raw deadline reads must be inside narrow Throwable guards that return an invalid deadline without escaping.'
}
if (-not $readListRefreshDeadlineCode.Contains(
        'readDeadline(prefs(context),KEY_LIST_REFRESH_NOT_BEFORE,now,MAX_LIST_REFRESH_DEADLINE_FUTURE_MS)',
        [StringComparison]::Ordinal) `
        -or -not $readListRefreshDeadlineCode.Contains(
            'returnnewDeadlineState(true,Math.max(stored.value,local));',
            [StringComparison]::Ordinal) `
        -or -not $advanceListRefreshDeadlineCode.Contains(
            '.putLong(KEY_LIST_REFRESH_NOT_BEFORE,deadline).commit()',
            [StringComparison]::Ordinal)) {
    throw 'Ordinary list-refresh cadence must bind the typed durable deadline to a process-local fail-closed guard.'
}
$localRefreshGuardIndex = $advanceListRefreshDeadlineCode.IndexOf(
    'localListRefreshNotBefore=deadline;', [StringComparison]::Ordinal)
$durableRefreshDeadlineIndex = $advanceListRefreshDeadlineCode.IndexOf(
    '.putLong(KEY_LIST_REFRESH_NOT_BEFORE,deadline).commit()',
    [StringComparison]::Ordinal)
if ($localRefreshGuardIndex -lt 0 `
        -or $durableRefreshDeadlineIndex -le $localRefreshGuardIndex) {
    throw 'The process-local list-refresh guard must install before its typed durable commit.'
}
$forcedIntentIndex = $requestListRefreshCode.IndexOf(
    'booleanforcedIntent=forceRefresh||hasListForceRefresh(viewer);',
    [StringComparison]::Ordinal)
$ordinaryDeadlineGateIndex = $requestListRefreshCode.IndexOf(
    'if(!forcedIntent)', $forcedIntentIndex, [StringComparison]::Ordinal)
$ordinaryDeadlineReadIndex = $requestListRefreshCode.IndexOf(
    'DeadlineStatedeadline=readListRefreshDeadline(activity,requestNow);',
    $ordinaryDeadlineGateIndex, [StringComparison]::Ordinal)
$refreshLaneAcquireIndex = $requestListRefreshCode.IndexOf(
    'if(!LIST_REFRESH_RUNNING.compareAndSet(false,true))',
    $ordinaryDeadlineReadIndex, [StringComparison]::Ordinal)
$preStartDeadlineIndex = $requestListRefreshCode.IndexOf(
    'if(!advanceListRefreshDeadline(activity,System.currentTimeMillis()))',
    $refreshLaneAcquireIndex, [StringComparison]::Ordinal)
$directRefreshIndex = $requestListRefreshCode.IndexOf(
    'newListRefreshWorker(activity,viewer,runForced)',
    $preStartDeadlineIndex, [StringComparison]::Ordinal)
$directRefreshStartIndex = $requestListRefreshCode.IndexOf(
    'worker.start()', $directRefreshIndex, [StringComparison]::Ordinal)
if ($forcedIntentIndex -lt 0 `
        -or $ordinaryDeadlineGateIndex -le $forcedIntentIndex `
        -or $ordinaryDeadlineReadIndex -le $ordinaryDeadlineGateIndex `
        -or $refreshLaneAcquireIndex -le $ordinaryDeadlineReadIndex `
        -or $preStartDeadlineIndex -le $refreshLaneAcquireIndex `
        -or $directRefreshIndex -le $preStartDeadlineIndex `
        -or $directRefreshStartIndex -le $directRefreshIndex `
        -or $requestListRefreshCode.Contains(
            'if(!forceRefresh){', [StringComparison]::Ordinal)) {
    throw 'Only bounded force intent may bypass the typed 600000 ms ordinary refresh deadline before lane acquisition.'
}
Assert-JavaBranchWake -MethodBody $requestListRefreshBody `
    -Condition 'if (!deadline.valid)' `
    -WakeCall 'armListRefreshWake(activity, viewer, FETCH_INTERVAL_MS);' `
    -Label 'invalid ordinary list-refresh deadline'
Assert-JavaBranchWake -MethodBody $requestListRefreshBody `
    -Condition 'if (deadline.value > requestNow)' `
    -WakeCall 'armListRefreshWake(activity, viewer, deadline.value - requestNow);' `
    -Label 'ordinary list-refresh not-before wait'
Assert-JavaBranchWake -MethodBody $requestListRefreshBody `
    -Condition 'if (!advanceListRefreshDeadline(activity, System.currentTimeMillis()))' `
    -WakeCall 'armListRefreshWake(activity, viewer, FETCH_INTERVAL_MS);' `
    -Label 'list-refresh deadline persistence failure'
$refreshStartCatchIndex = $requestListRefreshCode.IndexOf(
    'catch(Throwableignored)', $directRefreshStartIndex, [StringComparison]::Ordinal)
$rejectedStartDeadlineIndex = $requestListRefreshCode.IndexOf(
    'booleandeadlineSaved=advanceListRefreshDeadline(activity,System.currentTimeMillis());',
    $refreshStartCatchIndex, [StringComparison]::Ordinal)
$refreshOwnershipReleaseIndex = $requestListRefreshCode.IndexOf(
    'LIST_REFRESH_RUNNING.set(false);', $rejectedStartDeadlineIndex,
    [StringComparison]::Ordinal)
$refreshForceRetainIndex = $requestListRefreshCode.IndexOf(
    'booleanforceRetained=!runForced||requestListForceRefresh(viewer);',
    $refreshOwnershipReleaseIndex, [StringComparison]::Ordinal)
$refreshStartDiagnosticIndex = $requestListRefreshCode.IndexOf(
    'blocklist_refresh_worker_start_rejected', $refreshForceRetainIndex,
    [StringComparison]::Ordinal)
$refreshStartWakeIndex = $requestListRefreshCode.IndexOf(
    'armListRefreshWake(activity,viewer,millisUntilNextListRefresh(activity));',
    $refreshStartDiagnosticIndex, [StringComparison]::Ordinal)
if ($refreshStartCatchIndex -lt 0 `
        -or $rejectedStartDeadlineIndex -le $refreshStartCatchIndex `
        -or $refreshOwnershipReleaseIndex -le $rejectedStartDeadlineIndex `
        -or $refreshForceRetainIndex -le $refreshOwnershipReleaseIndex `
        -or $refreshStartDiagnosticIndex -le $refreshForceRetainIndex `
        -or $refreshStartWakeIndex -le $refreshStartDiagnosticIndex) {
    throw 'Worker-start rejection must durably re-advance refresh cadence before lane release, retained force intent, diagnostics, and a checked wake.'
}
$workerCompletionAdvanceIndex = $listRefreshWorkerCode.IndexOf(
    'advanceListRefreshDeadline(activity.getApplicationContext(),System.currentTimeMillis(),nextIntervalMs)',
    [StringComparison]::Ordinal)
$workerCompletionReleaseIndex = $listRefreshWorkerCode.IndexOf(
    'LIST_REFRESH_RUNNING.set(false);', $workerCompletionAdvanceIndex,
    [StringComparison]::Ordinal)
$workerCompletionPostIndex = $listRefreshWorkerCode.IndexOf(
    'booleanposted=MAIN.post(', $workerCompletionReleaseIndex,
    [StringComparison]::Ordinal)
$workerCompletionWakeIndex = $listRefreshWorkerCode.IndexOf(
    'armListRefreshWake(active,viewer,millisUntilNextListRefresh(active));',
    $workerCompletionPostIndex, [StringComparison]::Ordinal)
if ($workerCompletionAdvanceIndex -lt 0 `
        -or $workerCompletionReleaseIndex -le $workerCompletionAdvanceIndex `
        -or $workerCompletionPostIndex -le $workerCompletionReleaseIndex `
        -or $workerCompletionWakeIndex -le $workerCompletionPostIndex `
        -or -not $nextListRefreshDelayCode.Contains(
            'DeadlineStatedeadline=readListRefreshDeadline(context,now);',
            [StringComparison]::Ordinal) `
        -or -not $nextListRefreshDelayCode.Contains(
            'returndeadline.value<=now?1000L:Math.max(1000L,deadline.value-now);',
            [StringComparison]::Ordinal)) {
    throw 'Every completed refresh must re-advance the typed deadline before lane release and rearm from that persisted deadline.'
}
foreach ($boundedRefreshRecoveryProof in @(
        'privatestaticfinalintMAX_RESPONSE_BYTES=4*1024*1024;',
        'staticfinalintMAX_ROOT_BYTES=512*1024;',
        'staticfinalintMAX_GROUP_BYTES=64*1024;',
        'staticfinalintMAX_CHUNK_GZ_BYTES=256*1024;',
        'staticfinalintMAX_CHUNK_INFLATED_BYTES=4*1024*1024;',
        'staticfinalintMAX_CHUNK_ROWS=8192;',
        'staticfinalintMAX_INDEX_ROWS=2000000;',
        'staticfinalintMAX_BUCKET_BITS=16;',
        'staticfinalintMAX_GROUP_BITS=8;',
        'if(body.length()>MAX_ROOT_BYTES)',
        'plan=ChunkInstaller.stage(context,best,previousSnapshot);',
        'listRefreshFailureSummary=describeMirrorFailures(objectFailure.mirrorFailures);',
        'thrownewListFetchFailure(objectFailure.failureClass,"signedobjectscouldnotbestaged");',
        'privatestaticfinallong[]LIST_REFRESH_FAILURE_LADDER_MS=listRefreshFailureLadderMs();',
        'privatestaticfinalintMAX_LIST_REFRESH_FAILURE_RETRIES=LIST_REFRESH_FAILURE_LADDER_MS.length;',
        'long[]ladder=newlong[5];ladder[0]=15L*1000L;ladder[1]=30L*1000L;ladder[2]=60L*1000L;ladder[3]=120L*1000L;ladder[4]=300L*1000L;returnladder;',
        'if(failure){nextIntervalMs=recordListRefreshFailureAndNextIntervalMs();}else{resetListRefreshFailureLadder();nextIntervalMs=FETCH_INTERVAL_MS;}',
        'if(context==null||now<=0L||intervalMs<=0L||intervalMs>FETCH_INTERVAL_MS||now>Long.MAX_VALUE-intervalMs)',
        'returnadvanceListRefreshDeadline(context,now,FETCH_INTERVAL_MS);',
        'if(!isTransportFailure(firstError)){throwfirstError;}',
        'returnerrorinstanceofIOException;',
        'mirrorFailures[mirror]=classifyListFetchFailure(fetchError);',
        'listRefreshFailureSummary=describeMirrorFailures(mirrorFailures);',
        'if(contentLength>MAX_RESPONSE_BYTES)',
        'if(total>MAX_RESPONSE_BYTES)',
        'body=readBounded(input,contentLength);',
        'booleanmissingIndexStart=deadline.value>requestNow&&consumeMissingIndexResumeStart(activity,requestNow);')) {
    if (-not $schedulerCompact.Contains($boundedRefreshRecoveryProof, [StringComparison]::Ordinal)) {
        throw "Bounded list-refresh recovery is missing: $boundedRefreshRecoveryProof"
    }
}
if ((Get-PatchletLiteralCount -Text $fetchMirrorBody -Literal 'fetchMirrorOnce(') -ne 2) {
    throw 'Each mirror may be fetched at most twice per attempt, and only a transport failure may cause the second fetch.'
}
$refreshBusyBody = Get-JavaBlockBody -Text $requestListRefreshBody `
    -Anchor 'if (!LIST_REFRESH_RUNNING.compareAndSet(false, true))' `
    -Label 'active list refresh contention'
$forcedQueueIndex = $refreshBusyBody.IndexOf(
    'forceRefresh && !requestListForceRefresh(viewer)', [StringComparison]::Ordinal)
$busyReturnIndex = Get-JavaTopLevelLiteralIndex -Text $refreshBusyBody -Literal 'return;'
$runForcedIndex = $requestListRefreshBody.IndexOf(
    'boolean runForced = forceRefresh', [StringComparison]::Ordinal)
$sameViewerForceIndex = $requestListRefreshBody.IndexOf(
    'if (!runForced && hasListForceRefresh(viewer))', $runForcedIndex,
    [StringComparison]::Ordinal)
$sameViewerForceConsumeIndex = $requestListRefreshBody.IndexOf(
    'runForced = consumeListForceRefresh(viewer)', $sameViewerForceIndex,
    [StringComparison]::Ordinal)
$rawDirectRefreshIndex = $requestListRefreshBody.IndexOf(
    'new ListRefreshWorker(activity, viewer, runForced)', [StringComparison]::Ordinal)
$rawDirectRefreshStartIndex = $requestListRefreshBody.IndexOf(
    'worker.start()', $rawDirectRefreshIndex, [StringComparison]::Ordinal)
$rawRefreshForceRetainIndex = $requestListRefreshBody.IndexOf(
    'boolean forceRetained = !runForced || requestListForceRefresh(viewer)',
    $rawDirectRefreshStartIndex, [StringComparison]::Ordinal)
$listForceSetLockBody = Get-JavaBlockBody -Text $requestListForceRefreshBody `
    -Anchor 'synchronized (FORCE_REFRESH_LOCK)' `
    -Label 'viewer-scoped forced list refresh set lock'
if ($forcedQueueIndex -lt 0 -or $busyReturnIndex -le $forcedQueueIndex `
        -or $runForcedIndex -lt 0 `
        -or $sameViewerForceIndex -le $runForcedIndex `
        -or $sameViewerForceConsumeIndex -le $sameViewerForceIndex `
        -or $rawDirectRefreshIndex -le $sameViewerForceConsumeIndex `
        -or $rawDirectRefreshStartIndex -le $rawDirectRefreshIndex `
        -or $rawRefreshForceRetainIndex -le $rawDirectRefreshStartIndex `
        -or -not $listForceSetLockBody.Contains(
            'LIST_FORCE_REFRESH_VIEWERS.contains(viewer)', [StringComparison]::Ordinal) `
        -or -not $listForceSetLockBody.Contains(
            'LIST_FORCE_REFRESH_VIEWERS.add(viewer)', [StringComparison]::Ordinal) `
        -or -not $listForceSetLockBody.Contains(
            'LIST_FORCE_REFRESH_VIEWERS.size() >= MAX_PENDING_FORCE_VIEWERS',
            [StringComparison]::Ordinal)) {
    throw 'A forced list refresh must start directly or retain one bounded viewer-scoped intent while another refresh owns the lane.'
}
$forcedRefreshEnabledIndex = $listRefreshWorkerBody.IndexOf(
    'activeViewer != null && isEnabled(active)', [StringComparison]::Ordinal)
$forcedRefreshPendingIndex = $listRefreshWorkerBody.IndexOf(
    'hasListForceRefresh(activeViewer)', [StringComparison]::Ordinal)
$forcedRefreshConsumeIndex = $listRefreshWorkerBody.IndexOf(
    'consumeListForceRefresh(activeViewer)', [StringComparison]::Ordinal)
$forcedRefreshRestartIndex = $listRefreshWorkerBody.IndexOf(
    'requestListRefresh(active, activeViewer, true)', [StringComparison]::Ordinal)
if ($forcedRefreshEnabledIndex -lt 0 `
        -or $forcedRefreshPendingIndex -le $forcedRefreshEnabledIndex `
        -or $forcedRefreshConsumeIndex -le $forcedRefreshPendingIndex `
        -or $forcedRefreshRestartIndex -le $forcedRefreshConsumeIndex `
        -or $listRefreshWorkerBody.Contains(
            'consumeListForceRefresh(viewer)', [StringComparison]::Ordinal)) {
    throw 'Queued list-force intent may be consumed only for the enabled active viewer immediately before its forced refresh starts.'
}
$signedParserCode = Get-JavaCompactCode -Text $signedParserBody
$signedRootOrder = @(
    'if(body.length()>MAX_ROOT_BYTES)',
    'JSONObjectenvelope=newJSONObject(body);',
    'signatureValid=verifySignature(payloadJson,signature);',
    'longpublishedAt=parseInstant(updatedAt);',
    'if(publishedAt>now+24L*60L*60L*1000L)',
    'if(publishedAt<now-SIGNED_LIST_MAX_AGE_MS)',
    'if(previousPublishedAt>0L&&publishedAt<previousPublishedAt)',
    'if(!(versionValueinstanceofInteger)||((Integer)versionValue).intValue()!=3)',
    'if(!(hashValueinstanceofString)||!"sha256-hi32".equals((String)hashValue))',
    'if(maxChunkRows>MAX_CHUNK_ROWS||maxChunkBytes>MAX_CHUNK_GZ_BYTES)',
    'if(!(threadsValueinstanceofJSONObject))',
    'if(bucketBits>MAX_BUCKET_BITS||groupBits>MAX_GROUP_BITS)',
    'if(total>MAX_INDEX_ROWS)',
    'if(groupTable.length()!=groupCount)',
    'returnnewVerifiedList(updatedAt,publishedAt,bucketBits,groupBits,total,maxChunkRows,maxChunkBytes,groups);')
$previousRootIndex = -1
foreach ($signedRootStep in $signedRootOrder) {
    $rootStepIndex = $signedParserCode.IndexOf($signedRootStep, [StringComparison]::Ordinal)
    if ($rootStepIndex -le $previousRootIndex) {
        throw "Signed root parser must verify the envelope, timestamps, version, bucket function, caps and threads partition in order: $signedRootStep"
    }
    $previousRootIndex = $rootStepIndex
}
if ((Get-JavaCompactCode -Text $signedRootByteCapBody) -cne 'thrownewListFetchFailure(FAILURE_TOO_LARGE,"signedrootexceedsthelocalbytecap");' `
        -or (Get-JavaCompactCode -Text $signedRootVersionBody) -cne 'thrownewListFetchFailure(FAILURE_SCHEMA,"signedrootisnotv3");' `
        -or (Get-JavaCompactCode -Text $signedRootHashBody) -cne 'thrownewListFetchFailure(FAILURE_SCHEMA,"signedrootbucketfunctionisnotsha256-hi32");' `
        -or (Get-JavaCompactCode -Text $signedRootThreadsBody) -cne 'thrownewListFetchFailure(FAILURE_SCHEMA,"signedroothasnothreadspartition");' `
        -or -not $signedParserCode.Contains(
            'thrownewListFetchFailure(FAILURE_TARGET_CAP,"signedrootexceedsthelocalrowcap");',
            [StringComparison]::Ordinal) `
        -or -not $signedParserCode.Contains(
            'thrownewListFetchFailure(FAILURE_TARGET_CAP,"signedrootexceedsthelocalbucketcap");',
            [StringComparison]::Ordinal) `
        -or -not $signedParserCode.Contains(
            'thrownewListFetchFailure(FAILURE_SCHEMA,"signedrootthreadspartitionismalformed");',
            [StringComparison]::Ordinal) `
        -or $signedParserBody.Contains('optJSONArray("targets")', [StringComparison]::Ordinal) `
        -or $signedParserBody.Contains('optJSONObject("idNames")', [StringComparison]::Ordinal) `
        -or $signedParserBody.Contains('optJSONArray("ids")', [StringComparison]::Ordinal) `
        -or $signedParserBody.Contains('MAX_TARGETS', [StringComparison]::Ordinal) `
        -or $signedParserBody.Contains('optInt(', [StringComparison]::Ordinal)) {
    throw 'Signed root parser must reject a non-v3 root, a foreign bucket function, a missing threads partition, and every cap breach with a fixed closed-class literal.'
}
$chunkRowCode = Get-JavaCompactCode -Text $chunkRowBody
$chunkRowOrder = @(
    'if(reader.peek()!=JsonToken.BEGIN_OBJECT)',
    'reader.beginObject();',
    'if("i".equals(key))',
    'if("u".equals(key))',
    'reader.endObject();',
    'if(reader.peek()!=JsonToken.END_DOCUMENT)',
    'if(!AutoBlockSync.isDecimalId(id)||id.length()>MAX_ID_CHARS)',
    'if(clean.length()==0)',
    'if(bucketOf(h32,bucketBits)!=bucket)',
    'if(!ids.add(id))',
    'if(!usernameKeys.add(clean.toLowerCase(Locale.US)))',
    'entries.add(newBlocklistStore.Entry(id,clean,h32));',
    'longhandleHash=BlocklistStore.bucketHash(HANDLE_KEY_PREFIX+username);',
    'if(bucketOf(handleHash,bucketBits)!=bucket)')
$previousRowIndex = -1
foreach ($chunkRowStep in $chunkRowOrder) {
    $rowStepIndex = $chunkRowCode.IndexOf($chunkRowStep, [StringComparison]::Ordinal)
    if ($rowStepIndex -le $previousRowIndex) {
        throw "Chunk row parser must validate shape, id grammar, username, bucket membership and uniqueness in order: $chunkRowStep"
    }
    $previousRowIndex = $rowStepIndex
}
$chunkInstallerCode = Get-JavaCompactCode -Text $chunkInstallerText
foreach ($chunkRejectionLiteral in @(
        'throwschemaFailure("chunkrowisnotaJSONobject");',
        'throwschemaFailure("chunkrowhasmalformednumericid");',
        'throwschemaFailure("chunkthreadsidrowhasmalformedusernamemetadata");',
        'throwschemaFailure("chunkrowscontainaduplicatenumericid");',
        'throwschemaFailure("chunkrowshaveconflictingnormalizedusernames");',
        'throwschemaFailure("chunkrowbelongstoadifferentbucket");',
        'throwschemaFailure("chunkrowcountdiffersfromthesignedgroupentry");',
        'throwschemaFailure("chunkisnotvalidgzipNDJSON");',
        'thrownewAutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_TOO_LARGE,"chunkexceedstheinflatedbytecap");',
        'returnschemaFailure("grouptableisnotthev3threadsgrouptherootnamed");',
        'privatestaticintbucketOf(longh32,intbits){returnbits==0?0:(int)(h32>>>(32-bits));}',
        'privatestaticfinalStringID_KEY_PREFIX="threads:";',
        'privatestaticfinalStringHANDLE_KEY_PREFIX="threads:@";')) {
    if (-not $chunkInstallerCode.Contains($chunkRejectionLiteral, [StringComparison]::Ordinal)) {
        throw "Chunk installer lost a fixed whole-chunk rejection or bucket rule: $chunkRejectionLiteral"
    }
}
$chunkStageCode = Get-JavaCompactCode -Text $chunkStageBucketBody
$chunkFetchIndex = $chunkStageCode.IndexOf('ObjectFetcher.fetchObject(', [StringComparison]::Ordinal)
$chunkParseIndex = $chunkStageCode.IndexOf('entries=parseChunk(fetched.bytes,bucket,bucketBits,declaredRows);', [StringComparison]::Ordinal)
$chunkStageIndex = $chunkStageCode.IndexOf('if(!BlocklistStore.stageChunk(context,sha,entries))', [StringComparison]::Ordinal)
if ($chunkFetchIndex -lt 0 -or $chunkParseIndex -le $chunkFetchIndex -or $chunkStageIndex -le $chunkParseIndex `
        -or -not (Get-JavaCompactCode -Text $chunkParseBody).Contains('newGZIPInputStream(', [StringComparison]::Ordinal) `
        -or $chunkInstallerText.Contains('setLenient(true)', [StringComparison]::Ordinal) `
        -or $chunkInstallerText.Contains('HttpsURLConnection', [StringComparison]::Ordinal) `
        -or $chunkInstallerText.Contains('PASSIVE_ADMISSION_LOCK', [StringComparison]::Ordinal) `
        -or $chunkInstallerText.Contains('replaceVerified(', [StringComparison]::Ordinal)) {
    throw 'Every chunk must be hash-proven by the fetcher, then inflated and parsed strictly, then staged; the installer never opens a connection, takes the admission lock, or commits.'
}
$objectFetchOnceCode = Get-JavaCompactCode -Text $objectFetchOnceBody
$objectUrlIndex = $objectFetchOnceCode.IndexOf('URLurl=CloneBlockerEndpoints.objectUrl(mirror,name);', [StringComparison]::Ordinal)
$objectOpenIndex = $objectFetchOnceCode.IndexOf('openConnection()', [StringComparison]::Ordinal)
$objectHashIndex = $objectFetchOnceCode.IndexOf('if(!sha256Hex(bytes).equals(expectedHash))', [StringComparison]::Ordinal)
$objectReturnIndex = $objectFetchOnceCode.IndexOf('returnbytes;', [StringComparison]::Ordinal)
if ($objectUrlIndex -lt 0 -or $objectOpenIndex -le $objectUrlIndex `
        -or $objectHashIndex -le $objectOpenIndex -or $objectReturnIndex -le $objectHashIndex `
        -or -not $objectFetchOnceCode.Contains('setRequestProperty("Accept-Encoding","identity")', [StringComparison]::Ordinal) `
        -or -not $objectFetchOnceCode.Contains('setInstanceFollowRedirects(false)', [StringComparison]::Ordinal) `
        -or -not $objectFetchOnceCode.Contains('if(contentLength>cap)', [StringComparison]::Ordinal) `
        -or -not $objectFetchOnceCode.Contains('if(exactBytes>=0&&bytes.length!=exactBytes)', [StringComparison]::Ordinal) `
        -or -not $objectFetchOnceCode.Contains('thrownewAutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_SIGNATURE,"signedrootnamesanobjectwhosebytesdonotmatch");', [StringComparison]::Ordinal) `
        -or $objectFetcherText.Contains('JsonReader', [StringComparison]::Ordinal) `
        -or $objectFetcherText.Contains('GZIPInputStream', [StringComparison]::Ordinal) `
        -or $objectFetcherText.Contains('BlocklistStore', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $objectFetcherText -Literal 'fetchOnce(') -ne 3 `
        -or -not (Get-JavaCompactCode -Text $objectFetcherText).Contains('if(!AutoBlockSync.isTransportFailure(firstError)){throwfirstError;}', [StringComparison]::Ordinal)) {
    throw 'Object fetches must validate the name before the URL, request identity encoding, bound bytes, prove SHA-256 before returning, and retry a mirror at most once after a transport failure.'
}
if (-not $passiveLoadBody.Contains('PASSIVE_MATCH_GENERATIONS', [StringComparison]::Ordinal) `
        -or -not $passiveLoadBody.Contains('hasVisibleRegistrationLocked(viewer, candidate)', [StringComparison]::Ordinal) `
        -or -not $passiveLoadBody.Contains('BlocklistStore.lookupId(context, targetId)', [StringComparison]::Ordinal) `
        -or $passiveLoadBody.Contains('visibleIds', [StringComparison]::Ordinal) `
        -or $passiveLoadBody.Contains('ArrayList<String>', [StringComparison]::Ordinal) `
        -or $passiveLoadBody.Contains('verified.targets', [StringComparison]::Ordinal) `
        -or $passiveLoadBody.Contains('decodeTargets', [StringComparison]::Ordinal)) {
    throw 'Each drain must copy and index-check at most one current visible target, never accumulate visible rows or consume fetched list rows.'
}
if ($visibilityUpdateBody.Contains('BlocklistStore', [StringComparison]::Ordinal) `
        -or $visibilityUpdateBody.Contains('ThreadsBlockBridge', [StringComparison]::Ordinal) `
        -or -not $passiveLookupBody.Contains('BlocklistStore.lookupId(context, targetId)', [StringComparison]::Ordinal)) {
    throw 'Compose visibility updates must stay memory-only and defer indexed lookup to the bounded worker.'
}
$refreshAdmissionBody = Get-JavaBlockBody -Text $installCandidateBody `
    -Anchor 'synchronized (PASSIVE_ADMISSION_LOCK)' `
    -Label 'verified database replacement admission lock'
$dispatchAdmissionBody = Get-JavaBlockBody -Text $automaticBeginBody `
    -Anchor 'synchronized (PASSIVE_ADMISSION_LOCK)' `
    -Label 'final passive dispatch admission lock'
$automaticBlockRunBody = Get-JavaBlockBody -Text $schedulerStructureText `
    -Anchor 'private static final class BlockRun' -Label 'automatic BlockRun'
$currentPassiveAuthorityBody = Get-JavaBlockBody -Text $automaticBlockRunBody `
    -Anchor 'private PassiveAuthority currentPassiveAuthority(' `
    -Label 'complete current passive authority'
$stopForAuthorityFailureBody = Get-JavaBlockBody -Text $automaticBlockRunBody `
    -Anchor 'private void stopForAuthorityFailure(' `
    -Label 'passive late-authority stop'
$automaticBeginCode = Get-JavaCompactCode -Text $automaticBeginBody
$currentPassiveAuthorityCode = Get-JavaCompactCode -Text $currentPassiveAuthorityBody
$stopForAuthorityFailureCode = Get-JavaCompactCode -Text $stopForAuthorityFailureBody
if ((Get-PatchletLiteralCount -Text $schedulerText `
            -Literal 'synchronized (PASSIVE_ADMISSION_LOCK)') -ne 6 `
        -or -not $refreshAdmissionBody.Contains(
            'BlocklistStore.replaceVerified(', [StringComparison]::Ordinal) `
        -or -not $latchPassiveStorePauseBody.Contains(
            'synchronized (PASSIVE_ADMISSION_LOCK)', [StringComparison]::Ordinal)) {
    throw 'Verified replacement, invalid-store latching, visibility revocation, and final passive admission must share the reviewed admission boundary.'
}
$beforeRunningAuthorityIndex = $automaticBeginCode.IndexOf(
    'PassiveAuthoritybeforeRunning=currentPassiveAuthority(false,false);',
    [StringComparison]::Ordinal)
$lockedRunningPersist = $automaticBeginCode.IndexOf(
    'ModStateStore.markPassiveRunning(activity,viewer,targetId)',
    $beforeRunningAuthorityIndex, [StringComparison]::Ordinal)
$beforeReservationAuthorityIndex = $automaticBeginCode.IndexOf(
    'PassiveAuthoritybeforeReservation=currentPassiveAuthority(true,false);',
    $lockedRunningPersist, [StringComparison]::Ordinal)
$lockedAttemptReserve = $automaticBeginCode.IndexOf(
    'reserveAttempt(activity,viewer,true)', $beforeReservationAuthorityIndex,
    [StringComparison]::Ordinal)
$beforeDispatchAuthorityIndex = $automaticBeginCode.IndexOf(
    'PassiveAuthoritybeforeDispatch=currentPassiveAuthority(true,true);',
    $lockedAttemptReserve, [StringComparison]::Ordinal)
$mutationInFlightIndex = $automaticBeginCode.IndexOf(
    'markSchedulerMutationInFlight(schedulerToken,true)',
    $beforeDispatchAuthorityIndex, [StringComparison]::Ordinal)
$lockedBridgeDispatch = $automaticBeginCode.IndexOf(
    'ThreadsBlockBridge.block(activity,userSession,targetId,this)',
    $mutationInFlightIndex, [StringComparison]::Ordinal)
if ((Get-PatchletLiteralCount -Text $automaticBeginCode `
            -Literal 'currentPassiveAuthority(') -ne 3 `
        -or (Get-PatchletLiteralCount -Text $automaticBeginCode `
            -Literal 'currentPassiveAuthority(false,false)') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $automaticBeginCode `
            -Literal 'currentPassiveAuthority(true,false)') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $automaticBeginCode `
            -Literal 'currentPassiveAuthority(true,true)') -ne 1 `
        -or $beforeRunningAuthorityIndex -lt 0 `
        -or $lockedRunningPersist -le $beforeRunningAuthorityIndex `
        -or $beforeReservationAuthorityIndex -le $lockedRunningPersist `
        -or $lockedAttemptReserve -le $beforeReservationAuthorityIndex `
        -or $beforeDispatchAuthorityIndex -le $lockedAttemptReserve `
        -or $mutationInFlightIndex -le $beforeDispatchAuthorityIndex `
        -or $lockedBridgeDispatch -le $mutationInFlightIndex) {
    throw 'PassiveAuthority must run exactly before passive-running persistence, passive pacing reservation, and bridge dispatch under one admission lock.'
}
foreach ($requiredCurrentAuthorityProof in @(
        'if(!isMainLooperThread())',
        'if(!isCurrentForeground())',
        'if(isPassiveStorePaused())',
        'if(ModStateStore.nextQueued(activity,viewer)!=null)',
        'if(!BlockLimitsStore.isValid(activity))',
        'Set<String>currentDone=doneIds(activity,viewer);',
        'ModStateStore.CompletionReviewStatecurrentReview=ModStateStore.completionReviewState(activity,viewer);',
        'isLocalCompletionReviewPaused(viewer)',
        'currentReview.targets.contains(targetId)',
        'if(!runningPersisted&&!ModStateStore.isPassiveRunningClear(activity,viewer))',
        'PassiveMatchResultcurrentMatch=currentPassiveMatch(activity,viewer,targetId);',
        'if(!currentMatch.storeValid)',
        'if(!currentMatch.matched)',
        'if(!reservationPersisted)',
        'millisUntilPassivePaceAllowed(activity,viewer)')) {
    if (-not $currentPassiveAuthorityCode.Contains(
            $requiredCurrentAuthorityProof, [StringComparison]::Ordinal)) {
        throw "Late passive authority omits a mutable foreground/viewer/limits/state/membership guard: $requiredCurrentAuthorityProof"
    }
}
if ($currentPassiveAuthorityCode.Contains('ThreadsBlockBridge.', [StringComparison]::Ordinal) `
        -or $currentPassiveAuthorityCode.Contains('reserveAttempt(', [StringComparison]::Ordinal) `
        -or $currentPassiveAuthorityCode.Contains('markPassiveRunning(', [StringComparison]::Ordinal)) {
    throw 'PassiveAuthority must remain a read-only admission decision and may not mutate, reserve, or dispatch.'
}
$beforeRunningFailure = Get-JavaBlockBody -Text $automaticBeginBody `
    -Anchor 'if (!beforeRunning.allowed)' -Label 'pre-running authority failure'
$markRunningFailure = Get-JavaBlockBody -Text $automaticBeginBody `
    -Anchor 'if (!ModStateStore.markPassiveRunning(activity, viewer, targetId))' `
    -Label 'passive-running persistence failure'
$beforeReservationFailure = Get-JavaBlockBody -Text $automaticBeginBody `
    -Anchor 'if (!beforeReservation.allowed)' -Label 'pre-reservation authority failure'
$reservationFailure = Get-JavaBlockBody -Text $automaticBeginBody `
    -Anchor 'if (!reserveAttempt(activity, viewer, true))' `
    -Label 'passive reservation failure'
$beforeDispatchFailure = Get-JavaBlockBody -Text $automaticBeginBody `
    -Anchor 'if (!beforeDispatch.allowed)' -Label 'post-reservation authority failure'
$postReservationTail = $automaticBeginCode.Substring($lockedAttemptReserve)
if (-not (Get-JavaCompactCode -Text $beforeRunningFailure).Contains(
            'stopForAuthorityFailure(beforeRunning,false);',
            [StringComparison]::Ordinal) `
        -or -not (Get-JavaCompactCode -Text $beforeReservationFailure).Contains(
            'stopForAuthorityFailure(beforeReservation,true);',
            [StringComparison]::Ordinal) `
        -or -not (Get-JavaCompactCode -Text $beforeDispatchFailure).Contains(
            'stopForAuthorityFailure(beforeDispatch,true);',
            [StringComparison]::Ordinal) `
        -or $stopForAuthorityFailureCode.Contains(
            'removeForegroundPassiveTarget', [StringComparison]::Ordinal) `
        -or $automaticBeginCode.Contains('admitForegroundPassiveTarget', [StringComparison]::Ordinal) `
        -or $automaticBeginCode.Contains('targetBudgetAdded', [StringComparison]::Ordinal) `
        -or $postReservationTail.Contains('.remove(paceKey(', [StringComparison]::Ordinal) `
        -or $postReservationTail.Contains('.remove(attemptsKey(', [StringComparison]::Ordinal)) {
    throw 'Passive pacing reservation must remain conservative after commit, with no retired target-budget admission or rollback path.'
}
foreach ($checkedPassiveMainPost in @(
        @($listRefreshWorkerBody, 'if (!posted && activity != null)', 'list refresh result'),
        @($passiveLookupBody, 'if (!posted)', 'passive lookup result'))) {
    if (-not ([string]$checkedPassiveMainPost[0]).Contains(
            'boolean posted = MAIN.post(', [StringComparison]::Ordinal) `
            -or -not ([string]$checkedPassiveMainPost[0]).Contains(
                [string]$checkedPassiveMainPost[1], [StringComparison]::Ordinal)) {
        throw "Passive main-thread enqueue acceptance is unchecked: $($checkedPassiveMainPost[2])"
    }
}
$passiveLookupCode = Get-JavaCompactCode -Text $passiveLookupBody
$passiveLoadCode = Get-JavaCompactCode -Text $passiveLoadBody
$currentPassiveMatchCode = Get-JavaCompactCode -Text $currentPassiveMatchBody
$latchPassiveStorePauseCode = Get-JavaCompactCode -Text $latchPassiveStorePauseBody
$clearPassiveStorePauseCode = Get-JavaCompactCode -Text $clearPassiveStorePauseBody
$refreshAdmissionCode = Get-JavaCompactCode -Text $refreshAdmissionBody
$idMatchTypeCode = Get-JavaCompactCode -Text $idMatchTypeBody
$lookupBlocklistIdCode = Get-JavaCompactCode -Text $lookupBlocklistIdBody
$currentBlocklistIdCode = Get-JavaCompactCode -Text $currentBlocklistIdBody
if (-not $idMatchTypeCode.Contains(
        'privatestaticIdMatchinvalid(Stringstate){returninvalid(state,0L);}',
        [StringComparison]::Ordinal) `
        -or -not $idMatchTypeCode.Contains(
            'privatestaticIdMatchinvalid(Stringstate,longobservedGeneration){returnnewIdMatch(false,false,Math.max(0L,observedGeneration),"",state);}',
            [StringComparison]::Ordinal)) {
    throw 'Invalid exact-ID lookup results do not carry a bounded observed database generation.'
}
foreach ($lookupGenerationProof in @(
        @($lookupBlocklistIdCode, 'BlocklistStore.lookupId'),
        @($currentBlocklistIdCode, 'BlocklistStore.isCurrentIdMatch'))) {
    $lookupCode = [string]$lookupGenerationProof[0]
    $lookupLabel = [string]$lookupGenerationProof[1]
    $metadataReadIndex = $lookupCode.IndexOf(
        'StoredMetadatametadata=readMetadata(database,true);',
        [StringComparison]::Ordinal)
    $observedGenerationIndex = $lookupCode.IndexOf(
        'observedGeneration=metadata.generation;', $metadataReadIndex,
        [StringComparison]::Ordinal)
    $rowQueryIndex = $lookupCode.IndexOf(
        'Cursorcursor=database.query(', $observedGenerationIndex,
        [StringComparison]::Ordinal)
    if ((Get-PatchletLiteralCount -Text $lookupCode `
                -Literal 'IdMatch.invalid(') -ne 5 `
            -or (Get-PatchletLiteralCount -Text $lookupCode `
                -Literal ',observedGeneration)') -ne 3 `
            -or (Get-PatchletLiteralCount -Text $lookupCode `
                -Literal 'observedGeneration=metadata.generation;') -ne 1 `
            -or $metadataReadIndex -lt 0 `
            -or $observedGenerationIndex -le $metadataReadIndex `
            -or $rowQueryIndex -le $observedGenerationIndex `
            -or -not $lookupCode.Contains(
                'returnIdMatch.invalid(invalidStore.state,observedGeneration);',
                [StringComparison]::Ordinal) `
            -or -not $lookupCode.Contains(
                'returnIdMatch.invalid(STATE_UNAVAILABLE,observedGeneration);',
                [StringComparison]::Ordinal)) {
        throw "$lookupLabel does not preserve the actual metadata generation across every post-metadata invalid result."
    }
}
$lookupInvalidIndex = $passiveLookupCode.IndexOf(
    'if(!match.storeValid)', [StringComparison]::Ordinal)
$lookupLatchIndex = $passiveLookupCode.IndexOf(
    'latchPassiveStorePause(context,viewer,match.generation);', $lookupInvalidIndex,
    [StringComparison]::Ordinal)
$lookupMatchIndex = $passiveLookupCode.IndexOf(
    'elseif(match.matched', $lookupLatchIndex, [StringComparison]::Ordinal)
$currentMatchInvalidIndex = $currentPassiveMatchCode.IndexOf(
    'if(!match.storeValid)', [StringComparison]::Ordinal)
$currentMatchLatchIndex = $currentPassiveMatchCode.IndexOf(
    'latchPassiveStorePause(context,viewer,match.generation);',
    $currentMatchInvalidIndex, [StringComparison]::Ordinal)
$currentMatchBooleanIndex = $currentPassiveMatchCode.IndexOf(
    'booleancurrent;', $currentMatchLatchIndex, [StringComparison]::Ordinal)
$staleLatchSnapshotIndex = $latchPassiveStorePauseCode.IndexOf(
    'BlocklistStore.Snapshotcurrent=BlocklistStore.snapshot(context);',
    [StringComparison]::Ordinal)
$staleLatchSuppressIndex = $latchPassiveStorePauseCode.IndexOf(
    'if(observedGeneration>0L&&current.valid&&current.generation>observedGeneration){return;}',
    $staleLatchSnapshotIndex, [StringComparison]::Ordinal)
$invalidPauseIndex = $latchPassiveStorePauseCode.IndexOf(
    'passiveStorePaused=true;', $staleLatchSuppressIndex, [StringComparison]::Ordinal)
$verifiedReplaceIndexCompact = $refreshAdmissionCode.IndexOf(
    'BlocklistStore.replaceVerified(', [StringComparison]::Ordinal)
$verifiedSnapshotIndexCompact = $refreshAdmissionCode.IndexOf(
    'installed=replaced?BlocklistStore.snapshot(context):null;',
    $verifiedReplaceIndexCompact, [StringComparison]::Ordinal)
$verifiedPauseClearIndex = $refreshAdmissionCode.IndexOf(
    'clearPassiveStorePauseAfterVerifiedGeneration(installed.generation);',
    $verifiedSnapshotIndexCompact, [StringComparison]::Ordinal)
if ($lookupInvalidIndex -lt 0 `
        -or $lookupLatchIndex -le $lookupInvalidIndex `
        -or $lookupMatchIndex -le $lookupLatchIndex `
        -or -not $passiveLoadCode.Contains(
            'if(!match.storeValid){latchPassiveStorePause(context,viewer,match.generation);',
            [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $schedulerCompact `
            -Literal 'latchPassiveStorePause(context,viewer,match.generation);') -ne 3 `
        -or $currentMatchInvalidIndex -lt 0 `
        -or $currentMatchLatchIndex -le $currentMatchInvalidIndex `
        -or $currentMatchBooleanIndex -le $currentMatchLatchIndex `
        -or -not $currentPassiveMatchCode.Contains(
            'returnnewPassiveMatchResult(false,false);', [StringComparison]::Ordinal) `
        -or -not $currentPassiveMatchCode.Contains(
            'returnnewPassiveMatchResult(true,current);', [StringComparison]::Ordinal) `
        -or $staleLatchSnapshotIndex -lt 0 `
        -or $staleLatchSuppressIndex -le $staleLatchSnapshotIndex `
        -or $invalidPauseIndex -le $staleLatchSuppressIndex `
        -or $latchPassiveStorePauseCode.Contains(
            'current.generation>Math.max(0L,observedGeneration)',
            [StringComparison]::Ordinal) `
        -or $verifiedReplaceIndexCompact -lt 0 `
        -or $verifiedSnapshotIndexCompact -le $verifiedReplaceIndexCompact `
        -or $verifiedPauseClearIndex -le $verifiedSnapshotIndexCompact `
        -or -not $clearPassiveStorePauseCode.Contains(
            'if(!passiveStorePaused||generation<=passiveStorePauseGeneration)',
            [StringComparison]::Ordinal) `
        -or -not $clearPassiveStorePauseCode.Contains(
            'passiveStorePaused=false;', [StringComparison]::Ordinal)) {
    throw 'Indexed lookups must propagate their actual observed generation, latch invalid storage, suppress a stale latch only for a positive strictly older generation, and clear only after a newer verified generation.'
}
$enqueueManualAuthorityBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'Object resolvedAuthorModel,' -Label 'manual enqueue authority overload'
$tryAcquireSchedulerBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static long tryAcquireScheduler(' -Label 'scheduler ownership grant'
$visibilityUpdateOffMainBody = Get-JavaBlockBody -Text $visibilityUpdateBody `
    -Anchor 'if (!isMainLooperThread())' -Label 'off-main visibility update revocation'
$visibilityUnregisterOffMainBody = Get-JavaBlockBody -Text $visibilityUnregisterBody `
    -Anchor 'if (!isMainLooperThread())' -Label 'off-main visibility unregister revocation'
$pauseOffMainBody = Get-JavaBlockBody -Text $pauseBody `
    -Anchor 'if (!isMainLooperThread())' -Label 'off-main foreground revocation'
$forgetVisibleControlBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static void forgetVisibleControl(' -Label 'visibility token removal'
$pausePassiveVisibilityBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static void pausePassiveVisibility(' -Label 'visibility pause removal'
foreach ($mainThreadAuthorityGrant in @(
        @($visibilityRegisterBody, 'if (!isMainLooperThread()', 'visibility registration'),
        @($enqueueManualAuthorityBody, 'if (!isMainLooperThread())', 'manual enqueue'),
        @($automaticBeginBody, 'if (!isMainLooperThread())', 'automatic BlockRun admission'),
        @($tryAcquireSchedulerBody, 'if (!isMainLooperThread()', 'scheduler ownership'))) {
    if (-not ([string]$mainThreadAuthorityGrant[0]).Contains(
            [string]$mainThreadAuthorityGrant[1], [StringComparison]::Ordinal)) {
        throw "A state-granting entry is not main-looper bound: $($mainThreadAuthorityGrant[2])"
    }
}
foreach ($serializedOffMainRevocation in @(
        @($visibilityUpdateOffMainBody, 'synchronized (PASSIVE_VISIBILITY_LOCK)', 'visibility update'),
        @($visibilityUnregisterOffMainBody, 'forgetVisibleControl(token)', 'visibility unregister'),
        @($pauseOffMainBody, 'pausePassiveVisibility()', 'foreground pause'))) {
    $revocationBody = [string]$serializedOffMainRevocation[0]
    $admissionIndex = $revocationBody.IndexOf(
        'synchronized (PASSIVE_ADMISSION_LOCK)', [StringComparison]::Ordinal)
    $revocationIndex = $revocationBody.IndexOf(
        [string]$serializedOffMainRevocation[1], [StringComparison]::Ordinal)
    if ($admissionIndex -lt 0 -or $revocationIndex -le $admissionIndex) {
        throw "Off-main lifecycle revocation is not ADMISSION-serialized before visibility removal: $($serializedOffMainRevocation[2])"
    }
}
if (-not $forgetVisibleControlBody.Contains(
            'synchronized (PASSIVE_VISIBILITY_LOCK)', [StringComparison]::Ordinal) `
        -or -not $pausePassiveVisibilityBody.Contains(
            'synchronized (PASSIVE_VISIBILITY_LOCK)', [StringComparison]::Ordinal)) {
    throw 'Serialized off-main lifecycle helpers must preserve ADMISSION then VISIBILITY lock order.'
}
$prepareBlocklistBatchCode = Get-JavaCompactCode -Text $prepareBlocklistBatchBody
$lookupBlocklistIdCode = Get-JavaCompactCode -Text $lookupBlocklistIdBody
$currentBlocklistIdCode = Get-JavaCompactCode -Text $currentBlocklistIdBody
$readBlocklistMetadataCode = Get-JavaCompactCode -Text $readBlocklistMetadataBody
$requireBlocklistRowsCode = Get-JavaCompactCode -Text $requireBlocklistRowsBody
$visibleUsernameBody = Get-JavaBlockBody -Text $schedulerText `
    -Anchor 'private static boolean visibleUsernameMatchesStoredLocked(' `
    -Label 'exact-ID visible/stored username binding'
$visibleUsernameCode = Get-JavaCompactCode -Text $visibleUsernameBody
foreach ($requiredBlocklistInvariant in @(
        @($prepareBlocklistBatchCode, 'Set<String>ids=newHashSet<String>(source.size());', 'duplicate numeric-ID set'),
        @($prepareBlocklistBatchCode, 'Set<String>usernames=newHashSet<String>(source.size());', 'normalized username set'),
        @($prepareBlocklistBatchCode, '||!ids.add(sourceEntry.targetId)', 'duplicate numeric-ID rejection'),
        @($prepareBlocklistBatchCode, '||!usernames.add(usernameKey)', 'normalized username collision rejection'),
        @($lookupBlocklistIdCode, 'if(!validStoredUsername(username,usernameKey))', 'lookup stored-username validation'),
        @($lookupBlocklistIdCode, 'requireUniqueUsername(database,usernameKey);', 'lookup username uniqueness'),
        @($currentBlocklistIdCode, 'if(!targetId.equals(storedId)||!validStoredUsername(username,usernameKey))', 'current exact-ID/stored-username binding'),
        @($currentBlocklistIdCode, 'requireUniqueUsername(database,usernameKey);', 'current username uniqueness'),
        @($visibleUsernameCode, 'if(stored.length()==0)', 'nonempty stored username'),
        @($visibleUsernameCode, 'if(visible.length()==0||!stored.equals(visible))', 'visible/stored exact normalized username'),
        @($readBlocklistMetadataCode, 'parsedUpdatedAtMs=Instant.parse(updatedAt).toEpochMilli();', 'metadata timestamp reparse'),
        @($readBlocklistMetadataCode, '||parsedUpdatedAtMs!=updatedAtMs', 'metadata timestamp exact-ms binding'),
        @($requireBlocklistRowsCode, 'SELECTcount(DISTINCTusername_key)FROMblocklist_targets', 'generation username uniqueness'))) {
    if (-not ([string]$requiredBlocklistInvariant[0]).Contains(
            [string]$requiredBlocklistInvariant[1], [StringComparison]::Ordinal)) {
        throw "Verified blocklist ID/username/timestamp invariant is missing: $($requiredBlocklistInvariant[2])"
    }
}
$passiveFixtureCode = Get-JavaCompactCode -Text $passiveFixtureText
foreach ($requiredPassiveFixtureAssertion in @(
        'runFocusedBoundaryCases();',
        '"duplicatetargetobject"',
        '"duplicateidinachunk"',
        '"normalizedusernamecollision"',
        '"normalizedusernamecollisionacrosschunks"',
        '"handle-onlyrowcollidingwithanidrow"',
        '"rowinthewrongbucket"',
        '"handle-onlyrowinthewrongbucket"',
        '"shamismatch"',
        '"emptybucketwasnothandledasnull"',
        '"handle-onlyrowwasnotskippedfromtheidimport"',
        '"exactISOtimestampbindingwasrejected"',
        'assertTimestampRejected("off-by-onetimestamp"',
        'assertTimestampRejected("staletimestamp"',
        'assertTimestampRejected("malformedtimestamp"',
        'MessageDigest.getInstance("SHA-256")',
        'newGZIPInputStream(',
        '!ids.add(id)',
        '!usernames.add(username.toLowerCase(Locale.US))',
        'longparsed=Instant.parse(text).toEpochMilli();',
        'returnparsed==millis&&parsed>=now-SIGNED_LIST_MAX_AGE_MS&&parsed<=now+MAX_FUTURE_MS;')) {
    if (-not $passiveFixtureCode.Contains(
            $requiredPassiveFixtureAssertion, [StringComparison]::Ordinal)) {
        throw "Passive blocklist fixture lost a focused duplicate/username/timestamp assertion: $requiredPassiveFixtureAssertion"
    }
}
if ($schedulerCompact.Contains('.putString(LEGACY_KEY_TARGET_CACHE', [StringComparison]::Ordinal) `
        -or $schedulerCompact.Contains('getString(LEGACY_KEY_TARGET_CACHE', [StringComparison]::Ordinal) `
        -or $schedulerCompact.Contains('decodeTargets(', [StringComparison]::Ordinal) `
        -or $schedulerCompact.Contains('encodeTargets(', [StringComparison]::Ordinal)) {
    throw 'Retired SharedPreferences target blobs may be deletion-only and can never remain passive mutation authority.'
}
foreach ($requiredDoneStateContract in @(
        'Map<String, ?> values = preferences.getAll();',
        'if (!values.containsKey(key))',
        'if (!(raw instanceof Set<?>))',
        'if (stored.size() > MAX_DONE_IDS)',
        'if (!(value instanceof String))',
        'if (!isTargetId(targetId) || viewerId.equals(targetId))',
        'return done.size() == stored.size() ? done : null;',
        'catch (Throwable ignored)')) {
    if (-not $doneIdsReaderBody.Contains(
            $requiredDoneStateContract, [StringComparison]::Ordinal)) {
        throw "Completed-target reader does not fail closed on corrupt or oversized state: $requiredDoneStateContract"
    }
}
$doneMissingKeyBody = Get-JavaBlockBody -Text $doneIdsReaderBody `
    -Anchor 'if (!values.containsKey(key))' -Label 'missing completed-target state'
$doneWrongTypeBody = Get-JavaBlockBody -Text $doneIdsReaderBody `
    -Anchor 'if (!(raw instanceof Set<?>))' -Label 'type-confused completed-target state'
$doneOversizedBody = Get-JavaBlockBody -Text $doneIdsReaderBody `
    -Anchor 'if (stored.size() > MAX_DONE_IDS)' -Label 'oversized completed-target state'
$doneWrongMemberBody = Get-JavaBlockBody -Text $doneIdsReaderBody `
    -Anchor 'if (!(value instanceof String))' -Label 'non-string completed target'
$doneInvalidMemberBody = Get-JavaBlockBody -Text $doneIdsReaderBody `
    -Anchor 'if (!isTargetId(targetId) || viewerId.equals(targetId))' `
    -Label 'invalid or viewer completed target'
if (-not $doneMissingKeyBody.Contains(
            'return new HashSet<String>();', [StringComparison]::Ordinal) `
        -or $doneMissingKeyBody.Contains('return null;', [StringComparison]::Ordinal)) {
    throw 'Only an actually absent done_threads key may grant an empty completed-target snapshot.'
}
foreach ($corruptDoneBranch in @(
        @($doneWrongTypeBody, 'type-confused'),
        @($doneOversizedBody, 'oversized'),
        @($doneWrongMemberBody, 'non-string'),
        @($doneInvalidMemberBody, 'invalid/self'))) {
    if (-not ([string]$corruptDoneBranch[0]).Contains(
            'return null;', [StringComparison]::Ordinal) `
            -or ([string]$corruptDoneBranch[0]).Contains(
                'new HashSet<String>()', [StringComparison]::Ordinal)) {
        throw "Completed-target $($corruptDoneBranch[1]) state does not fail closed."
    }
}
$automaticDoneFailureBody = Get-JavaBlockBody -Text $markAutomaticDoneBody `
    -Anchor 'if (done == null' -Label 'automatic completed-target capacity guard'
$automaticDoneGuardIndex = $markAutomaticDoneBody.IndexOf(
    'if (done == null', [StringComparison]::Ordinal)
$automaticDoneAppendIndex = $markAutomaticDoneBody.IndexOf(
    'done.add(targetId)', [StringComparison]::Ordinal)
$automaticDoneCommitIndex = $markAutomaticDoneBody.IndexOf(
    'putStringSet(doneKey(viewerId), done).commit()', [StringComparison]::Ordinal)
$schedulerDoneFailureBody = Get-JavaBlockBody -Text $automaticBeginBody `
    -Anchor 'if (done == null)' -Label 'scheduler corrupt completed-target pause'
if (-not $automaticDoneFailureBody.Contains('return false;', [StringComparison]::Ordinal) `
        -or $automaticDoneFailureBody.Contains('done.add(', [StringComparison]::Ordinal) `
        -or $automaticDoneFailureBody.Contains('putStringSet(', [StringComparison]::Ordinal) `
        -or $automaticDoneGuardIndex -lt 0 `
        -or $automaticDoneAppendIndex -le $automaticDoneGuardIndex `
        -or $automaticDoneCommitIndex -le $automaticDoneAppendIndex `
        -or -not $schedulerDoneFailureBody.Contains(
            'Completed-target state needs review; automatic work remains paused.',
            [StringComparison]::Ordinal) `
        -or -not $schedulerDoneFailureBody.Contains('return;', [StringComparison]::Ordinal)) {
    throw 'Corrupt done_threads state must stop both capacity mutation and automatic candidate selection.'
}
if ($stateText.Contains('getStringSet(', [StringComparison]::Ordinal) `
        -or -not $doneIdsSchedulerBody.Contains(
            'return readDoneIds(prefs(context), viewerId);', [StringComparison]::Ordinal) `
        -or -not $markAutomaticDoneBody.Contains(
            'done == null', [StringComparison]::Ordinal) `
        -or -not $markAutomaticDoneBody.Contains(
            '!done.contains(targetId) && done.size() >= MAX_DONE_IDS',
            [StringComparison]::Ordinal) `
        -or -not $automaticBeginBody.Contains(
            'if (done == null)', [StringComparison]::Ordinal)) {
    throw 'Corrupt, type-confused, or oversized done_threads state must pause work without getStringSet crashes or fresh capacity.'
}
foreach ($throwableSafeAsset in @(
        @($schedulerText, 'AutoBlockSync'),
        @($stateText, 'ModStateStore'),
        @($chunkInstallerText, 'ChunkInstaller'),
        @($objectFetcherText, 'ObjectFetcher'))) {
    $throwableAssetText = [string]$throwableSafeAsset[0]
    if ([regex]::IsMatch(
            $throwableAssetText,
            '(?i)(safeMessage\s*\(|\.\s*get(?:Localized)?Message\s*\(|printStackTrace\s*\(|getStackTraceString\s*\()')) {
        throw "Canonical $($throwableSafeAsset[1]) must not copy raw Throwable messages into diagnostics or status."
    }
    foreach ($throwableCatch in [regex]::Matches(
            $throwableAssetText,
            'catch\s*\(\s*(?:final\s+)?[A-Za-z_$][A-Za-z0-9_$.]*(?:\s*\|\s*[A-Za-z_$][A-Za-z0-9_$.]*)*\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\)')) {
        $throwableName = [regex]::Escape($throwableCatch.Groups[1].Value)
        $throwableCatchBody = Get-JavaBlockBody `
            -Text $throwableAssetText `
            -Anchor $throwableCatch.Value `
            -StartIndex $throwableCatch.Index `
            -Label "$($throwableSafeAsset[1]) caught failure"
        $rawThrowableFlow =
                '(?is)(?:\b' + $throwableName `
                + '\s*\.\s*(?:getMessage|getLocalizedMessage|toString|printStackTrace)\s*\(' `
                + '|String\s*\.\s*valueOf\s*\(\s*' + $throwableName + '\s*\)' `
                + '|\.append\s*\(\s*' + $throwableName + '\s*\)' `
                + '|\+\s*' + $throwableName + '\b' `
                + '|getStackTraceString\s*\(\s*' + $throwableName + '\s*\)' `
                + '|Log\s*\.\s*\w+\s*\([^;]*,\s*' + $throwableName + '\s*\)\s*;)'
        if ([regex]::IsMatch($throwableCatchBody, $rawThrowableFlow)) {
            throw "Canonical $($throwableSafeAsset[1]) exposes a caught Throwable through text, stack, or logging flow."
        }
    }
}

foreach ($requiredDatabaseLiteral in @(
        'public static final String DATABASE_NAME = "threadsmod_blocklist.db";',
        'private static final int DATABASE_VERSION = 3;',
        'CREATE TABLE blocklist_targets (',
        'target_id TEXT PRIMARY KEY NOT NULL',
        'CREATE INDEX blocklist_targets_username_idx ON blocklist_targets',
        'CREATE UNIQUE INDEX blocklist_targets_username_idx ON blocklist_targets',
        'CREATE INDEX blocklist_targets_h32_idx ON blocklist_targets(h32)',
        'CREATE TABLE blocklist_chunks (',
        'CREATE TABLE blocklist_groups (',
        'CREATE TABLE blocklist_staging (',
        'h32 INTEGER NOT NULL CHECK(h32 BETWEEN 0 AND 4294967295)',
        'bucket_bits INTEGER NOT NULL DEFAULT 0 CHECK(bucket_bits BETWEEN 0 AND 24)',
        'target_count INTEGER NOT NULL CHECK(target_count BETWEEN 0 AND 16777216)',
        'CREATE TABLE blocklist_metadata (',
        'new_target_count INTEGER NOT NULL DEFAULT -1',
        'metadata.put("new_target_count", newTargetCount);',
        'update.put("new_target_count", 0);',
        'int newTargetCount = 0;',
        'newTargetCount += countNewTargets(',
        'public static boolean stageChunk(Context context, String sha256, List<Entry> rows)',
        'database.beginTransaction();',
        'database.setTransactionSuccessful();',
        'database.endTransaction();',
        '"target_id = ?"',
        'INDEXED BY ',
        'username lookup deliberately returns aggregate metadata without target IDs')) {
    if (-not $blocklistStoreText.Contains($requiredDatabaseLiteral, [StringComparison]::Ordinal)) {
        throw "Indexed blocklist database contract is missing: $requiredDatabaseLiteral"
    }
}
foreach ($forbiddenDatabaseLiteral in @('deleteDatabase(', 'DROP TABLE')) {
    if ($blocklistStoreText.Contains($forbiddenDatabaseLiteral, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Blocklist corruption handling or migration may destroy prior verified data: $forbiddenDatabaseLiteral"
    }
}
$blocklistUpgradeBody = Get-JavaBlockBody -Text $blocklistStoreText `
    -Anchor 'public void onUpgrade(SQLiteDatabase database, int oldVersion, int newVersion)' `
    -Label 'BlocklistStore.DatabaseHelper.onUpgrade'
foreach ($databaseMigrationProof in @(
        'if (newVersion != 3 || oldVersion < 1 || oldVersion > 2)',
        'if (oldVersion == 1)',
        'validateSchemaV1(database);',
        'StoredMetadata previous = readMetadataV1(database, true);',
        'ALTER TABLE blocklist_metadata ADD COLUMN ',
        'validateSchemaV2(database);',
        'StoredMetadata previousV2 = readMetadataV2(database, true);',
        'DROP INDEX blocklist_targets_username_idx',
        'ALTER TABLE blocklist_targets RENAME TO blocklist_targets_v2',
        'ALTER TABLE blocklist_metadata RENAME TO blocklist_metadata_v2',
        'int copied = copyRetainedTargets(database);',
        'DELETE FROM blocklist_targets_v2',
        'DELETE FROM blocklist_metadata_v2',
        'validateSchema(database);',
        'migrated.newTargetCount != NEW_TARGET_COUNT_UNKNOWN')) {
    if (-not $blocklistUpgradeBody.Contains(
            $databaseMigrationProof, [StringComparison]::Ordinal)) {
        throw "Blocklist v1-to-v2-to-v3 migration proof is missing: $databaseMigrationProof"
    }
}
if ((Get-PatchletLiteralCount -Text $blocklistStoreText `
        -Literal 'ALTER TABLE blocklist_metadata ADD COLUMN ') -ne 1) {
    throw 'Blocklist schema migration must contain exactly one reviewed additive v1-to-v2 ALTER.'
}
$blocklistStoreCode = Get-JavaCompactCode -Text $blocklistStoreText
$blocklistSnapshotModelCode = Get-JavaBlockBody -Text $blocklistStoreCode `
    -Anchor 'publicstaticfinalclassSnapshot' -Label 'BlocklistStore.Snapshot'
$blocklistReplaceCode = Get-JavaBlockBody -Text $blocklistStoreCode `
    -Anchor 'publicstaticbooleanreplaceVerified(Contextcontext,InstallPlanplan,StringverifiedUpdatedAt,longverifiedUpdatedAtMs,longfetchedAtMs)' `
    -Label 'BlocklistStore.replaceVerified'
$blocklistUnchangedCode = Get-JavaBlockBody -Text $blocklistStoreCode `
    -Anchor 'publicstaticbooleanmarkFetchedUnchanged(Contextcontext,longfetchedAtMs)' `
    -Label 'BlocklistStore.markFetchedUnchanged'
$blocklistSnapshotCode = Get-JavaBlockBody -Text $blocklistStoreCode `
    -Anchor 'publicstaticSnapshotsnapshot(Contextcontext)' -Label 'BlocklistStore.snapshot'
$blocklistNewCountCode = Get-JavaBlockBody -Text $blocklistStoreCode `
    -Anchor 'privatestaticintcountNewTargets(SQLiteDatabasedatabase,StringstagedSha,intdeclaredIdCount)' `
    -Label 'BlocklistStore.countNewTargets'
$blocklistUpgradeCode = Get-JavaCompactCode -Text $blocklistUpgradeBody
foreach ($databaseStatusModelProof in @(
        'publicfinallonggeneration;',
        'publicfinalinttargetCount;',
        'publicfinalintnewTargetCount;',
        'this.targetCount=targetCount;',
        'this.newTargetCount=newTargetCount;',
        'false,state,0L,"",0L,0L,0,NEW_TARGET_COUNT_UNKNOWN')) {
    if (-not $blocklistSnapshotModelCode.Contains(
            $databaseStatusModelProof, [StringComparison]::Ordinal)) {
        throw "Blocklist DB v2 status model omits exact total/new/generation state: $databaseStatusModelProof"
    }
}
foreach ($databaseReplacementProof in @(
        'if(previous==null)',
        'generation=1L;',
        'intnewTargetCount=0;',
        'booleanfullReplace=plan.replaced.cardinality()==(1<<plan.bucketBits);',
        'if(countRows(database)!=0||!fullReplace)',
        'requireRowCount(database,previous.targetCount);',
        'if(previous.bucketBits!=plan.bucketBits&&!fullReplace)',
        'generation=previous.generation+1L;',
        'newTargetCount+=countNewTargets(database,plan.chunkShas[index],stagedCount);',
        '"DELETEFROMblocklist_targetsWHEREh32BETWEEN?AND?"',
        '"INSERTINTOblocklist_targets(target_id,username,username_key,h32)"',
        '"WHEREsha256=?ANDh32BETWEEN?AND?"',
        'if(copyStaged.executeUpdateDelete()!=stagedCounts[index])',
        '"SELECTcoalesce(sum(id_count),0)FROMblocklist_chunks"',
        '||installedRows!=countRows(database)',
        'metadata.put("target_count",installedRows);',
        'metadata.put("new_target_count",newTargetCount);',
        'metadata.put("bucket_bits",plan.bucketBits);',
        'persisted.targetCount!=installedRows',
        'persisted.newTargetCount!=newTargetCount',
        'persisted.bucketBits!=plan.bucketBits',
        'requireRowCount(database,(int)installedRows);')) {
    if (-not $blocklistReplaceCode.Contains(
            $databaseReplacementProof, [StringComparison]::Ordinal)) {
        throw "Verified generation replacement omits exact total/new-count proof: $databaseReplacementProof"
    }
}
if ($blocklistReplaceCode.IndexOf('newTargetCount+=countNewTargets(', [StringComparison]::Ordinal) -ge `
        $blocklistReplaceCode.IndexOf('deleteRange.executeUpdateDelete();', [StringComparison]::Ordinal)) {
    throw 'The per-bucket set difference must be measured before any replaced bucket is cleared.'
}
foreach ($databaseSetDifferenceProof in @(
        '"SELECTcount(*)FROMblocklist_stagingsWHEREs.sha256=?"',
        '"ANDNOTEXISTS(SELECT1FROMblocklist_targetst"',
        '"WHEREt.target_id=s.target_id)"',
        'if(newTargetCount<0||newTargetCount>declaredIdCount)',
        'returnnewTargetCount;')) {
    if (-not $blocklistNewCountCode.Contains(
            $databaseSetDifferenceProof, [StringComparison]::Ordinal)) {
        throw "New-record metadata is not the exact incoming-ID set difference: $databaseSetDifferenceProof"
    }
}
if ((Get-PatchletLiteralCount -Text $blocklistUnchangedCode -Literal 'update.put(') -ne 2 `
        -or -not $blocklistUnchangedCode.Contains(
            'update.put("fetched_at_ms",fetchedAtMs);update.put("new_target_count",0);',
            [StringComparison]::Ordinal) `
        -or -not $blocklistUnchangedCode.Contains(
            'current.generation!=previous.generation', [StringComparison]::Ordinal) `
        -or -not $blocklistUnchangedCode.Contains(
            'current.targetCount!=previous.targetCount', [StringComparison]::Ordinal) `
        -or -not $blocklistUnchangedCode.Contains(
            'current.newTargetCount!=0', [StringComparison]::Ordinal) `
        -or $blocklistUnchangedCode.Contains('database.delete(', [StringComparison]::Ordinal) `
        -or $blocklistUnchangedCode.Contains('insertOrThrow(', [StringComparison]::Ordinal) `
        -or $blocklistUnchangedCode.Contains('countNewTargets(', [StringComparison]::Ordinal)) {
    throw 'A verified 304 must preserve generation/rows, advance fetch metadata only, and publish exactly zero new IDs.'
}
foreach ($databaseMigrationInvariant in @(
        'migrated.generation!=previous.generation',
        '!migrated.verifiedUpdatedAt.equals(previous.verifiedUpdatedAt)',
        'migrated.verifiedUpdatedAtMs!=previous.verifiedUpdatedAtMs',
        'migrated.fetchedAtMs!=previous.fetchedAtMs',
        'migrated.targetCount!=previous.targetCount',
        'migrated.newTargetCount!=NEW_TARGET_COUNT_UNKNOWN',
        'migratedV3.generation!=previousV2.generation',
        '!migratedV3.verifiedUpdatedAt.equals(previousV2.verifiedUpdatedAt)',
        'migratedV3.verifiedUpdatedAtMs!=previousV2.verifiedUpdatedAtMs',
        'migratedV3.fetchedAtMs!=previousV2.fetchedAtMs',
        'migratedV3.targetCount!=previousV2.targetCount',
        'migratedV3.newTargetCount!=previousV2.newTargetCount',
        'migratedV3.bucketBits!=0',
        'if(copied!=(previousV2==null?0:previousV2.targetCount))',
        'requireRowCount(database,migratedV3==null?0:migratedV3.targetCount);')) {
    if (-not $blocklistUpgradeCode.Contains(
            $databaseMigrationInvariant, [StringComparison]::Ordinal)) {
        throw "Blocklist v1-to-v2-to-v3 migration does not retain the prior generation, counts and timestamps: $databaseMigrationInvariant"
    }
}
if (-not $blocklistStoreCode.Contains(
            'insert.bindLong(4,bucketHash("threads:"+targetId));', [StringComparison]::Ordinal) `
        -or -not $blocklistStoreCode.Contains(
            'if(copied>=MAX_INDEX_ROWS||!isNumericId(targetId)||!validStoredUsername(username,usernameKey))',
            [StringComparison]::Ordinal)) {
    throw 'The v2-to-v3 migration must re-validate and re-hash every retained row.'
}
foreach ($databaseSnapshotProof in @(
        'StoredMetadatametadata=readMetadata(database,true);',
        'metadata.generation,metadata.verifiedUpdatedAt,metadata.verifiedUpdatedAtMs,metadata.fetchedAtMs,metadata.targetCount,metadata.newTargetCount')) {
    if (-not $blocklistSnapshotCode.Contains(
            $databaseSnapshotProof, [StringComparison]::Ordinal)) {
        throw "Live blocklist status snapshot omits DB v3 metadata validation: $databaseSnapshotProof"
    }
}
if ($blocklistSnapshotCode.Contains('requireRowCount(', [StringComparison]::Ordinal) `
        -or $blocklistUnchangedCode.Contains('requireRowCount(', [StringComparison]::Ordinal)) {
    throw 'Status snapshots and 304 confirmations must read committed metadata only; row-count proofs run at install time.'
}

$visibilitySymbols = $resolution.inlineControls.symbols
foreach ($requiredVisibilityLiteral in @(
        '.implements Lkotlin/jvm/functions/Function1;',
        ('.implements ' + [string]$visibilitySymbols.rememberObserverInterface),
        ('invoke-interface {p1}, ' + [string]$visibilitySymbols.layoutAttachedMethod),
        ('invoke-static {p1, v1}, ' + [string]$visibilitySymbols.clippedBoundsMethod),
        ('invoke-virtual {v1}, ' + [string]$visibilitySymbols.rectEmptyMethod),
        'AutoBlockSync;->registerVisibleControl(Ljava/lang/Object;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z',
        'AutoBlockSync;->updateVisibleControl(Ljava/lang/Object;Z)V',
        'AutoBlockSync;->unregisterVisibleControl(Ljava/lang/Object;)V')) {
    if (-not $visibilityTemplateText.Contains($requiredVisibilityLiteral, [StringComparison]::Ordinal)) {
        throw "Viewport visibility template contract is missing: $requiredVisibilityLiteral"
    }
}
$lifecycleVoidMethods = @([regex]::Matches(
        $visibilityTemplateText,
        '(?m)^\.method public final (?<name>[^\s(]+)\(\)V\s*$'))
if ($lifecycleVoidMethods.Count -ne 3 `
        -or (Get-PatchletLiteralCount -Text $visibilityTemplateText `
            -Literal 'InlineVisibilityCallback;->release()V') -ne 2) {
    throw 'Viewport observer must expose exactly three exact-version lifecycle callbacks with two release paths.'
}
$visibilityInvokeStart = $visibilityTemplateText.IndexOf(
    '.method public final invoke(Ljava/lang/Object;)Ljava/lang/Object;',
    [StringComparison]::Ordinal)
$visibilityInvokeEnd = if ($visibilityInvokeStart -ge 0) {
    $visibilityTemplateText.IndexOf('.end method', $visibilityInvokeStart, [StringComparison]::Ordinal)
} else {
    -1
}
if ($visibilityInvokeStart -lt 0 -or $visibilityInvokeEnd -lt 0) {
    throw 'Viewport visibility template is missing its geometry callback body.'
}
$visibilityInvokeText = $visibilityTemplateText.Substring(
    $visibilityInvokeStart,
    $visibilityInvokeEnd + '.end method'.Length - $visibilityInvokeStart)
$visibilityRememberStart = $visibilityTemplateText.IndexOf(
    '.method public final DnW()V', [StringComparison]::Ordinal)
$visibilityRememberEnd = if ($visibilityRememberStart -ge 0) {
    $visibilityTemplateText.IndexOf(
        '.end method', $visibilityRememberStart, [StringComparison]::Ordinal)
} else {
    -1
}
if ($visibilityRememberStart -lt 0 -or $visibilityRememberEnd -lt 0) {
    throw 'Viewport visibility template is missing its remember-observer entry body.'
}
$visibilityRememberText = $visibilityTemplateText.Substring(
    $visibilityRememberStart,
    $visibilityRememberEnd + '.end method'.Length - $visibilityRememberStart)
$visibilityHeartbeat = $visibilityInvokeText.IndexOf(
    'AutoBlockSync;->registerVisibleControl(Ljava/lang/Object;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z',
    [StringComparison]::Ordinal)
$visibilityGeometry = $visibilityInvokeText.IndexOf(
    ('invoke-interface {p1}, ' + [string]$visibilitySymbols.layoutAttachedMethod),
    [StringComparison]::Ordinal)
$visibilityUpdate = $visibilityInvokeText.IndexOf(
    'AutoBlockSync;->updateVisibleControl(Ljava/lang/Object;Z)V',
    [StringComparison]::Ordinal)
if ($visibilityHeartbeat -lt 0 -or $visibilityGeometry -lt 0 -or $visibilityUpdate -lt 0 `
        -or $visibilityHeartbeat -ge $visibilityGeometry `
        -or $visibilityHeartbeat -ge $visibilityUpdate) {
    throw 'Every geometry callback must re-establish its idempotent row registration before resolving or forwarding visibility.'
}
$visibilityOffMainNegativeFixtureCount = 0
if ($normalizedSourceVersion -ceq '444.0.0.45.85') {
    $visibilityRegisterCall =
        'AutoBlockSync;->registerVisibleControl(Ljava/lang/Object;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z'
    $visibilityUnregisterCall =
        'AutoBlockSync;->unregisterVisibleControl(Ljava/lang/Object;)V'
    $testMainOnlyVisibilityEntry = {
        param(
            [string]$MethodText,
            [string]$MainLabel,
            [string]$OffMainLabel,
            [string]$OffMainReturn
        )
        $myLooperIndex = $MethodText.IndexOf(
            'Landroid/os/Looper;->myLooper()Landroid/os/Looper;',
            [StringComparison]::Ordinal)
        $mainLooperIndex = $MethodText.IndexOf(
            'Landroid/os/Looper;->getMainLooper()Landroid/os/Looper;',
            [StringComparison]::Ordinal)
        $branchIndex = $MethodText.IndexOf(
            ('if-eq v0, v1, :' + $MainLabel), [StringComparison]::Ordinal)
        $offMainIndex = $MethodText.IndexOf(
            (':' + $OffMainLabel), [StringComparison]::Ordinal)
        $registeredClearIndex = $MethodText.IndexOf(
            'iput-boolean v0, p0, Lthreadsmod/inlinecontrol/InlineVisibilityCallback;->registered:Z',
            $offMainIndex + 1, [StringComparison]::Ordinal)
        $visibleClearIndex = $MethodText.IndexOf(
            'iput-boolean v0, p0, Lthreadsmod/inlinecontrol/InlineVisibilityCallback;->visible:Z',
            $registeredClearIndex + 1, [StringComparison]::Ordinal)
        $unregisterIndex = $MethodText.IndexOf(
            $visibilityUnregisterCall, $visibleClearIndex + 1, [StringComparison]::Ordinal)
        $offMainReturnIndex = $MethodText.IndexOf(
            $OffMainReturn, $unregisterIndex + 1, [StringComparison]::Ordinal)
        $mainIndex = $MethodText.IndexOf(
            (':' + $MainLabel), $offMainReturnIndex + 1, [StringComparison]::Ordinal)
        $registerIndex = $MethodText.IndexOf(
            $visibilityRegisterCall, $mainIndex + 1, [StringComparison]::Ordinal)
        return $myLooperIndex -ge 0 `
            -and $mainLooperIndex -gt $myLooperIndex `
            -and $branchIndex -gt $mainLooperIndex `
            -and $offMainIndex -gt $branchIndex `
            -and $registeredClearIndex -gt $offMainIndex `
            -and $visibleClearIndex -gt $registeredClearIndex `
            -and $unregisterIndex -gt $visibleClearIndex `
            -and $offMainReturnIndex -gt $unregisterIndex `
            -and $mainIndex -gt $offMainReturnIndex `
            -and $registerIndex -gt $mainIndex `
            -and (Get-PatchletLiteralCount -Text $MethodText `
                -Literal $visibilityRegisterCall) -eq 1 `
            -and (Get-PatchletLiteralCount -Text $MethodText `
                -Literal $visibilityUnregisterCall) -eq 1
    }
    $geometryMainOnly = & $testMainOnlyVisibilityEntry `
        $visibilityInvokeText 'geometry_main_registration' `
        'geometry_off_main_revoke' 'goto :return_unit'
    $rememberMainOnly = & $testMainOnlyVisibilityEntry `
        $visibilityRememberText 'remember_main_registration' `
        'remember_off_main_revoke' 'return-void'
    $geometryWrongBranch = $visibilityInvokeText.Replace(
        'if-eq v0, v1, :geometry_main_registration',
        'if-ne v0, v1, :geometry_main_registration')
    $geometryMissingRevoke = $visibilityInvokeText.Replace(
        $visibilityUnregisterCall, 'AutoBlockSync;->offMainRevokeRemoved()V')
    $rememberWrongBranch = $visibilityRememberText.Replace(
        'if-eq v0, v1, :remember_main_registration',
        'if-ne v0, v1, :remember_main_registration')
    $rememberMissingRevoke = $visibilityRememberText.Replace(
        $visibilityUnregisterCall, 'AutoBlockSync;->offMainRevokeRemoved()V')
    if (-not $geometryMainOnly -or -not $rememberMainOnly `
            -or (& $testMainOnlyVisibilityEntry $geometryWrongBranch `
                'geometry_main_registration' 'geometry_off_main_revoke' 'goto :return_unit') `
            -or (& $testMainOnlyVisibilityEntry $geometryMissingRevoke `
                'geometry_main_registration' 'geometry_off_main_revoke' 'goto :return_unit') `
            -or (& $testMainOnlyVisibilityEntry $rememberWrongBranch `
                'remember_main_registration' 'remember_off_main_revoke' 'return-void') `
            -or (& $testMainOnlyVisibilityEntry $rememberMissingRevoke `
                'remember_main_registration' 'remember_off_main_revoke' 'return-void')) {
        throw '444 visibility entries must grant registration only on main and synchronously revoke off-main; negative branch/revocation fixtures must fail.'
    }
    $visibilityOffMainNegativeFixtureCount = 4
}
if ($visibilityTemplateText.Contains('BlocklistStore', [StringComparison]::Ordinal) `
        -or $visibilityTemplateText.Contains('ThreadsBlockBridge', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $visibilityTemplateText `
            -Literal 'AutoBlockSync;->registerVisibleControl(Ljava/lang/Object;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z') -ne 2 `
        -or (Get-PatchletLiteralCount -Text $rowAdapterTemplateText `
            -Literal ([string]$visibilitySymbols.visibilityModifierMethod)) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $rowAdapterTemplateText `
            -Literal 'new-instance v7, Lthreadsmod/inlinecontrol/InlineVisibilityCallback;') -ne 1) {
    throw 'The sole inline control must own exactly one memory-only clipped-viewport callback and no direct database or mutation call.'
}
foreach ($templateReferencePair in @(
        @($bridgeTemplateText, $bridgeReferenceText, 'ThreadsBlockBridge'),
        @($mutationTemplateText, $mutationReferenceText, 'MutationCallback'))) {
    $renderedReference = [string]$templateReferencePair[0]
    foreach ($property in @($resolution.bridge.symbols.PSObject.Properties)) {
        $renderedReference = $renderedReference.Replace(
            '{{' + $property.Name + '}}', [string]$property.Value)
    }
    if ([regex]::IsMatch($renderedReference, '\{\{[^{}]+\}\}') `
            -or -not $renderedReference.Equals(
                [string]$templateReferencePair[1], [StringComparison]::Ordinal)) {
        throw "Exact-version rendered bridge reference drifted from canonical template: $($templateReferencePair[2])"
    }
}
$inlineTemplateText = @(Get-ChildItem `
    -LiteralPath $inlineTemplateRoot `
    -Recurse -File -Filter '*.tmpl') `
    | ForEach-Object { Get-NormalizedPatchletText -Path $_.FullName }
$reportTemplateText = @(Get-ChildItem `
    -LiteralPath $reportTemplateRoot `
    -Recurse -File -Filter '*.tmpl') `
    | ForEach-Object { Get-NormalizedPatchletText -Path $_.FullName }
$reportActionFactoryTemplateText = Get-NormalizedPatchletText -Path (
    Join-Path $reportTemplateRoot 'InlineReportActionFactory.smali.tmpl')
$retiredCombinedModalPaths = @(
    (Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\ReportDialog.java'),
    (Join-Path $reportTemplateRoot 'InlineReportClick.smali.tmpl')
)
foreach ($retiredCombinedModalPath in $retiredCombinedModalPaths) {
    if (Test-Path -LiteralPath $retiredCombinedModalPath) {
        throw "Retired separate report UI/action asset remains: $retiredCombinedModalPath"
    }
}
$drawerClickTemplateText = Get-NormalizedPatchletText -Path (Join-Path $settingsTemplateRoot 'DrawerSettingsClick.smali.tmpl')
$drawerItemTemplateText = Get-NormalizedPatchletText -Path (Join-Path $settingsTemplateRoot 'DrawerSettingsItem.smali.tmpl')
$drawerRowTemplateText = Get-NormalizedPatchletText -Path (Join-Path $settingsTemplateRoot 'DrawerSettingsRowAdapter.smali.tmpl')
$drawerSettingsRewrites = Read-PatchletJson -Path (
    Join-Path $resolutionDirectory ([string]$resolution.drawerSettings.rewriteSet))
$drawerRows = @($resolution.drawerSettings.rows)
if ([int]$drawerSettingsRewrites.schemaVersion -ne 1 `
        -or $drawerRows.Count -lt 1 `
        -or @($drawerRows | ForEach-Object { [string]$_.hookRuleId } |
            Sort-Object -Unique).Count -ne $drawerRows.Count `
        -or @($drawerSettingsRewrites.rules).Count -ne $drawerRows.Count) {
    throw 'Drawer Settings resolution and rewrite set must own one unique rule per runtime-selectable row.'
}
$drawerAnchorContracts = @($drawerRows | ForEach-Object {
    $row = $_
    $matchingRules = @($drawerSettingsRewrites.rules | Where-Object {
            [string]$_.id -ceq [string]$row.hookRuleId
        })
    if ($matchingRules.Count -ne 1 `
            -or [string]$matchingRules[0].path -cne [string]$row.path `
            -or [int]$matchingRules[0].expectedCount -ne 1) {
        throw "Drawer Settings row '$($row.hookRuleId)' is not bound to one exact rewrite path/count."
    }
    $beforePath = Resolve-PatchletChildPath `
        -Root $resolutionDirectory -Child ([string]$matchingRules[0].beforeFile)
    $afterPath = Resolve-PatchletChildPath `
        -Root $resolutionDirectory -Child ([string]$matchingRules[0].afterFile)
    if (-not (Test-Path -LiteralPath $beforePath -PathType Leaf) `
            -or -not (Test-Path -LiteralPath $afterPath -PathType Leaf)) {
        throw "Drawer Settings row '$($row.hookRuleId)' is missing its exact before/after anchor."
    }
    [pscustomobject]@{
        row = $row
        rule = $matchingRules[0]
        beforeText = Get-NormalizedPatchletText -Path $beforePath
        afterText = Get-NormalizedPatchletText -Path $afterPath
    }
})
$inlineControlRewrites = Read-PatchletJson -Path (
    Join-Path $resolutionDirectory 'inline-control-rewrites.json')
if ([int]$inlineControlRewrites.schemaVersion -ne 1) {
    throw 'Inline-control rewrite set has an unsupported schema version.'
}
$spacingRewriteRules = @($inlineControlRewrites.rules | Where-Object {
        [string]$_.id -ceq 'inline-action-spacing-capture'
    })
$rowRewriteRules = @($inlineControlRewrites.rules | Where-Object {
        [string]$_.id -ceq [string]$resolution.inlineControls.actionRow.hookRuleId
    })
$snapshotRewriteRules = @($inlineControlRewrites.rules | Where-Object {
        [string]$_.id -ceq [string]$resolution.inlineControls.actionRow.snapshotHookRuleId
    })
$ufiRequestFieldProperty = $resolution.inlineControls.symbols.PSObject.Properties['ufiRequestField']
$usesPreboundInlineRequest = $null -ne $ufiRequestFieldProperty `
    -and -not [string]::IsNullOrWhiteSpace([string]$ufiRequestFieldProperty.Value)
$mediaBindRewriteRules = if ($usesPreboundInlineRequest) {
    @($inlineControlRewrites.rules | Where-Object {
            [string]$_.id -ceq 'inline-media-id-bind'
        })
} else { @() }
if ($spacingRewriteRules.Count -gt 1 `
        -or $rowRewriteRules.Count -ne 1 `
        -or $snapshotRewriteRules.Count -ne 1 `
        -or ($usesPreboundInlineRequest -and $mediaBindRewriteRules.Count -ne 1) `
        -or [string]$rowRewriteRules[0].path -cne [string]$resolution.inlineControls.actionRow.path `
        -or ($spacingRewriteRules.Count -eq 1 `
            -and [int]$spacingRewriteRules[0].expectedCount -ne 1) `
        -or [int]$rowRewriteRules[0].expectedCount -ne 1 `
        -or [int]$snapshotRewriteRules[0].expectedCount -ne 1) {
    throw 'Inline-control resolution is not bound to one exact action-row/snapshot rewrite and at most one independent spacing capture.'
}
$spacingAnchorBeforeText = if ($spacingRewriteRules.Count -eq 1) {
    Get-NormalizedPatchletText -Path (
        Resolve-PatchletChildPath -Root $resolutionDirectory `
            -Child ([string]$spacingRewriteRules[0].beforeFile))
} else { '' }
$spacingAnchorText = if ($spacingRewriteRules.Count -eq 1) {
    Get-NormalizedPatchletText -Path (
        Resolve-PatchletChildPath -Root $resolutionDirectory `
            -Child ([string]$spacingRewriteRules[0].afterFile))
} else { '' }
$rowAnchorBeforeText = Get-NormalizedPatchletText -Path (
    Resolve-PatchletChildPath -Root $resolutionDirectory `
        -Child ([string]$rowRewriteRules[0].beforeFile))
$rowAnchorText = Get-NormalizedPatchletText -Path (
    Resolve-PatchletChildPath -Root $resolutionDirectory `
        -Child ([string]$rowRewriteRules[0].afterFile))
$snapshotHostBeforeText = Get-NormalizedPatchletText -Path (
    Resolve-PatchletChildPath -Root $resolutionDirectory `
        -Child ([string]$snapshotRewriteRules[0].beforeFile))
$snapshotHostAfterText = Get-NormalizedPatchletText -Path (
    Resolve-PatchletChildPath -Root $resolutionDirectory `
        -Child ([string]$snapshotRewriteRules[0].afterFile))
$mediaBindAnchorBeforeText = if ($usesPreboundInlineRequest) {
    Get-NormalizedPatchletText -Path (
        Resolve-PatchletChildPath -Root $resolutionDirectory `
            -Child ([string]$mediaBindRewriteRules[0].beforeFile))
} else { '' }
$mediaBindAnchorAfterText = if ($usesPreboundInlineRequest) {
    Get-NormalizedPatchletText -Path (
        Resolve-PatchletChildPath -Root $resolutionDirectory `
            -Child ([string]$mediaBindRewriteRules[0].afterFile))
} else { '' }
$schedulerCode = Get-JavaCompactCode -Text $schedulerText
$controllerCode = Get-JavaCompactCode -Text $controllerText
$requestCode = Get-JavaCompactCode -Text $requestText
$stateCode = Get-JavaCompactCode -Text $stateText
$diagnosticCode = Get-JavaCompactCode -Text $diagnosticText
$dispatcherCode = Get-JavaCompactCode -Text $dispatcherText
$diagnosticForFailureCode = Get-JavaBlockBody -Text $diagnosticCode `
    -Anchor 'publicstaticBlockDiagnosticforFailure(StringinputStage,booleanautomatic,booleanresolvedRowModel,booleannativeStarted,booleanrecoveryStateSaved)' `
    -Label 'BlockDiagnostic.forFailure'
$expectedDiagnosticInputStages = @(
    'already_blocked_exception',
    'already_completed',
    'attempt_reservation',
    'bridge_exception',
    'bridge_dispatch_exception',
    'bridge_stub',
    'cache_factory_exception',
    'cache_lookup_exception',
    'cache_placeholder_exception',
    'callback_timeout',
    'completion_persistence',
    'confirmation_unavailable',
    'foreground_changed',
    'foreground_lost',
    'invalid_or_self_target',
    'invalid_target',
    'model_id_exception',
    'model_id_mismatch',
    'mutation_cancelled',
    'mutation_ended',
    'mutation_exception',
    'mutation_failure',
    'no_foreground_session',
    'placeholder_model_invalid',
    'queue_rejected',
    'queue_start_persistence',
    'report_context_unavailable',
    'resolved_model_invalid',
    'scheduler_handoff',
    'scheduler_rejected',
    'session_model_exception',
    'self_block_refused',
    'viewer_changed'
)
$diagnosticInputStages = @([regex]::Matches(
        $diagnosticForFailureCode,
        '"([^"]+)"\.equals\(inputStage\)') | ForEach-Object { $_.Groups[1].Value })
if ((@($diagnosticInputStages | Sort-Object) -join "`n") -ne `
        (@($expectedDiagnosticInputStages | Sort-Object) -join "`n") `
        -or ([regex]::Matches($diagnosticForFailureCode, 'inputStage')).Count `
            -ne $expectedDiagnosticInputStages.Count) {
    throw 'BlockDiagnostic does not use the exact closed input-stage vocabulary or copies unknown input.'
}
$expectedDiagnosticCodes = @(
    'CB-BRG-103', 'CB-BRG-104', 'CB-BRG-105', 'CB-BRG-106',
    'CB-BRG-107', 'CB-BRG-108', 'CB-BRG-109', 'CB-BRG-110', 'CB-BRG-111',
    'CB-BRG-112', 'CB-BRG-113', 'CB-BRG-999',
    'CB-LOC-101', 'CB-LOC-102', 'CB-LOC-301',
    'CB-MUT-201', 'CB-MUT-202', 'CB-MUT-203', 'CB-MUT-204', 'CB-MUT-205',
    'CB-SCH-101', 'CB-SCH-102', 'CB-SCH-103', 'CB-SCH-104', 'CB-SCH-105', 'CB-SCH-106',
    'CB-SCH-107',
    'CB-UI-101', 'CB-UI-102', 'CB-UNK-000'
)
$diagnosticCodes = @([regex]::Matches(
        $diagnosticForFailureCode,
        'code="([A-Z0-9-]+)"') | ForEach-Object { $_.Groups[1].Value })
if ((@($diagnosticCodes | Sort-Object) -join "`n") -ne `
        (@($expectedDiagnosticCodes | Sort-Object) -join "`n")) {
    throw 'BlockDiagnostic does not expose the exact reviewed stable-code vocabulary.'
}
foreach ($diagnosticBoundProof in @(
        'publicstaticfinalintMAX_DETAIL_CHARS=120;',
        'publicstaticfinalintMAX_STATUS_CHARS=240;',
        'publicstaticfinalintMAX_LOG_CHARS=200;',
        'this.detail=bounded(detail,MAX_DETAIL_CHARS);',
        'this.status=bounded(status,MAX_STATUS_CHARS);',
        'this.logLine=bounded(logLine,MAX_LOG_CHARS);',
        'Stringstage="unknown_failure";',
        'Stringcode="CB-UNK-000";',
        'Stringroute=resolvedRowModel?"row-model":"direct-id";',
        'Stringsource=automatic?"automatic":"inline";',
        'Stringretry=reviewRequired?recoveryStateSaved?"review-saved":"review-local-failclosed":recoveryStateSaved?"backoff":"local-state-failed";',
        'recoveryStateSaved?"Thetargetwasdurablyquarantined;automaticretryisdisabled.":"Aprocess-localquarantineisactive;automaticworkispaused."',
        '+"·mirror=n/a"',
        '+"·bridge=r6"',
        '+";mirror=n/a;bridge=r6]"')) {
    if (-not $diagnosticCode.Contains($diagnosticBoundProof, [StringComparison]::Ordinal)) {
        throw "Closed Block diagnostic bound/context proof is missing: $diagnosticBoundProof"
    }
}
if (-not $diagnosticForFailureCode.Contains(
        'elseif("placeholder_model_invalid".equals(inputStage)){stage="placeholder_model_invalid";code="CB-BRG-106";',
        [StringComparison]::Ordinal) `
        -or -not $diagnosticForFailureCode.Contains(
            'elseif("model_id_exception".equals(inputStage)){stage="model_id_exception";code="CB-BRG-112";',
            [StringComparison]::Ordinal) `
        -or -not $diagnosticForFailureCode.Contains(
            'elseif("already_blocked_exception".equals(inputStage)){stage="already_blocked_exception";code="CB-BRG-113";',
            [StringComparison]::Ordinal) `
        -or -not $diagnosticForFailureCode.Contains(
            'elseif("callback_timeout".equals(inputStage)){stage="callback_timeout";code="CB-MUT-205";' `
                + 'summary="nativecallbacktimedout";explanation="ThreadsdidnotreturnaterminalBlockcallbackintime;theaccountstateneedsreview.";' `
                + 'mutation=nativeStarted?"started":"unknown";reviewRequired=true;}',
            [StringComparison]::Ordinal) `
        -or -not $diagnosticForFailureCode.Contains(
            'elseif("completion_persistence".equals(inputStage)){stage="completion_persistence";code="CB-LOC-301";' `
                + 'summary="localcompletionsavefailed";',
            [StringComparison]::Ordinal) `
        -or $diagnosticForFailureCode.Contains('+inputStage', [StringComparison]::Ordinal) `
        -or $diagnosticForFailureCode.Contains('inputStage+', [StringComparison]::Ordinal) `
        -or -not $stateCode.Contains(
            'addAlert(context,viewerId,diagnostic.code(),diagnostic.status());',
            [StringComparison]::Ordinal) `
        -or -not $stateCode.Contains(
            'value.put("message",cleanText(message,240));',
            [StringComparison]::Ordinal) `
        -or -not $schedulerCode.Contains(
            'if(safe.length()>240){safe=safe.substring(0,240);}',
            [StringComparison]::Ordinal)) {
    throw 'BlockDiagnostic placeholder mapping, identifier exclusion, or 240-character persistence bound is not pinned.'
}
$refreshBlocklistCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticStringrefreshBlocklist(Contextcontext,booleanforceRefresh)' `
    -Label 'AutoBlockSync.refreshBlocklist'
$orderedMirrorLoopIndex = $refreshBlocklistCode.IndexOf(
    'for(intmirror=0;mirror<CloneBlockerEndpoints.blocklistMirrorCount();mirror++)',
    [StringComparison]::Ordinal)
$orderedMirrorFetchIndex = $refreshBlocklistCode.IndexOf(
    'VerifiedListcandidate=fetchMirror(context,forceRefresh,mirror,snapshot);',
    [StringComparison]::Ordinal)
$freshestSelectionIndex = $refreshBlocklistCode.IndexOf(
    'if(candidate!=null&&(best==null||candidate.publishedAtMs>best.publishedAtMs)){best=candidate;}',
    [StringComparison]::Ordinal)
$freshestInstallIndex = $refreshBlocklistCode.IndexOf(
    'if(best!=null){returninstallVerifiedCandidate(context,best,snapshot);}',
    [StringComparison]::Ordinal)
if ($orderedMirrorLoopIndex -lt 0 -or $orderedMirrorFetchIndex -le $orderedMirrorLoopIndex `
        -or $freshestSelectionIndex -le $orderedMirrorFetchIndex `
        -or $freshestInstallIndex -le $freshestSelectionIndex `
        -or $refreshBlocklistCode.Contains('returnfetchMirror(', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $refreshBlocklistCode -Literal 'installVerifiedCandidate(') -ne 1) {
    throw 'Signed-list fetch does not walk the exact mirror array from index zero in declared order, keep only the strictly newest verified candidate, and install that one candidate after every mirror was consulted.'
}
$dialogCode = Get-JavaCompactCode -Text $dialogText
$limitsCode = Get-JavaCompactCode -Text $limitsText
$limitsStoreCode = Get-JavaCompactCode -Text $limitsStoreText
$settingsCode = Get-JavaCompactCode -Text $settingsText
$activityCode = Get-JavaCompactCode -Text $activityText
$uiCode = Get-JavaCompactCode -Text $uiText
$activityRebuildCode = Get-JavaBlockBody -Text $activityCode `
    -Anchor 'privatevoidrebuild()' -Label 'CloneBlockerActivity.rebuild'
$activityAddStatRowCode = Get-JavaBlockBody -Text $activityCode `
    -Anchor 'privatevoidaddStatRow(' -Label 'CloneBlockerActivity.addStatRow'
$activityStatCardCode = Get-JavaBlockBody -Text $activityCode `
    -Anchor 'privateLinearLayoutstatCard(' -Label 'CloneBlockerActivity.statCard'
$activityContentIndex = $activityRebuildCode.IndexOf(
    'setContentView(scroll);', [StringComparison]::Ordinal)
$activitySnapshotIndex = $activityRebuildCode.IndexOf(
    'ModStateStore.snapshot(this);', [StringComparison]::Ordinal)
if ($activityContentIndex -lt 0 -or $activitySnapshotIndex -le $activityContentIndex `
        -or -not $activityRebuildCode.Contains(
        'catch(RuntimeExceptioninvalidLocalState)', [StringComparison]::Ordinal) `
        -or -not $activityRebuildCode.Contains(
        'Activitydataneedsreview', [StringComparison]::Ordinal)) {
    throw 'Activity does not attach a visible fail-closed shell before reading dynamic state.'
}
if ($activityStatCardCode.Contains('setLayoutParams(', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $activityAddStatRowCode `
            -Literal 'row.addView(left,leftParams);') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $activityAddStatRowCode `
            -Literal 'row.addView(right,rightParams);') -ne 1 `
        -or ($activityCode + $settingsCode + $uiCode).Contains(
            'setLayoutParams(null)', [StringComparison]::Ordinal)) {
    throw 'Activity stat cards do not retain parent-owned non-null layout parameters.'
}
foreach ($statusSurface in @(
        @('Activity', $activityCode, 2, 'statusContentReady', 'refreshPolledStatus();'),
        @('Settings', $settingsCode, 1, 'contentReady', 'refreshRuntimeState();'))) {
    $statusSurfaceName = [string]$statusSurface[0]
    $statusSurfaceCode = [string]$statusSurface[1]
    $expectedListStatusCalls = [int]$statusSurface[2]
    $statusReadyField = [string]$statusSurface[3]
    $statusRefreshCall = [string]$statusSurface[4]
    $statusResumeCode = Get-JavaBlockBody -Text $statusSurfaceCode `
        -Anchor 'protectedvoidonResume()' -Label "$statusSurfaceName.onResume status polling"
    $statusStartCode = Get-JavaBlockBody -Text $statusSurfaceCode `
        -Anchor 'privatevoidstartStatusPolling()' `
        -Label "$statusSurfaceName.startStatusPolling"
    $statusStopCode = Get-JavaBlockBody -Text $statusSurfaceCode `
        -Anchor 'privatevoidstopStatusPolling()' `
        -Label "$statusSurfaceName.stopStatusPolling"
    $statusUnavailableCode = Get-JavaBlockBody -Text $statusSurfaceCode `
        -Anchor 'privatevoidshowStatusPollingUnavailable()' `
        -Label "$statusSurfaceName.showStatusPollingUnavailable"
    if (-not $statusSurfaceCode.Contains(
            'privatestaticfinallongSTATUS_POLL_INTERVAL_MS=1000L;',
            [StringComparison]::Ordinal) `
            -or (Get-PatchletLiteralCount -Text $statusSurfaceCode `
                -Literal 'statusHandler.postDelayed(') -ne 2 `
            -or (Get-PatchletLiteralCount -Text $statusSurfaceCode `
                -Literal 'AutoBlockSync.getListStatus(this)') -ne $expectedListStatusCalls `
            -or -not $statusSurfaceCode.Contains(
                'protectedvoidonPause(){stopStatusPolling();super.onPause();}',
                [StringComparison]::Ordinal) `
            -or -not $statusSurfaceCode.Contains(
                'protectedvoidonDestroy(){stopStatusPolling();super.onDestroy();}',
                [StringComparison]::Ordinal) `
            -or -not $statusSurfaceCode.Contains(
                'if(statusPolling&&!statusHandler.postDelayed(statusPoll,STATUS_POLL_INTERVAL_MS)){showStatusPollingUnavailable();}',
                [StringComparison]::Ordinal) `
            -or -not $statusSurfaceCode.Contains(
                'Unavailable:liveblock-liststatusrefreshstopped.Reopenthispage.',
                [StringComparison]::Ordinal) `
            -or -not $statusResumeCode.Contains(
                'startStatusPolling();', [StringComparison]::Ordinal) `
            -or -not $statusStartCode.Contains(
                'statusHandler.removeCallbacks(statusPoll);', [StringComparison]::Ordinal) `
            -or -not $statusStartCode.Contains(
                ('statusPolling=' + $statusReadyField + ';'), [StringComparison]::Ordinal) `
            -or -not $statusStartCode.Contains(
                'statusPollingUnavailable=false;', [StringComparison]::Ordinal) `
            -or -not $statusStartCode.Contains(
                $statusRefreshCall, [StringComparison]::Ordinal) `
            -or -not $statusStopCode.Contains(
                'statusPolling=false;statusHandler.removeCallbacks(statusPoll);',
                [StringComparison]::Ordinal) `
            -or -not $statusUnavailableCode.Contains(
                'statusPolling=false;statusPollingUnavailable=true;statusHandler.removeCallbacks(statusPoll);',
                [StringComparison]::Ordinal)) {
        throw "$statusSurfaceName block-list status polling is not visible, one-second, lifecycle-bounded, and enqueue-checked."
    }
}
$listStatusCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'publicstaticStringgetListStatus(Contextcontext)' `
    -Label 'AutoBlockSync.getListStatus'
foreach ($listStatusProof in @(
        'Listfetch:',
        'Records:',
        'Newthisrefresh:',
        'Databaseindex:',
        'Inlinecontrol:',
        'BlocklistStore.Snapshotsnapshot=BlocklistStore.snapshot(context);',
        'LIST_PHASE_FETCHING.equals(phase)',
        'LIST_PHASE_VERIFYING.equals(phase)',
        'LIST_PHASE_INDEXING.equals(phase)',
        'LIST_PHASE_UNCHANGED.equals(phase)',
        'LIST_PHASE_RETAINED_ERROR.equals(phase)',
        'snapshot.targetCount',
        'snapshot.newTargetCount',
        'generation')) {
    if (-not $listStatusCode.Contains($listStatusProof, [StringComparison]::Ordinal)) {
        throw "Current status omits bounded fetch/index evidence: $listStatusProof"
    }
}
foreach ($inlineStatusStage in @(
        '"hook_seen"', '"button_rendered"', '"report_request_unavailable"',
        '"adapter_exception"')) {
    if ((Get-PatchletLiteralCount -Text $schedulerCode -Literal $inlineStatusStage) -ne 1) {
        throw "Current status does not own one fixed inline render stage: $inlineStatusStage"
    }
}
$recordInlineStageCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'publicstaticvoidrecordInlineRenderStage(Stringstage)' `
    -Label 'AutoBlockSync.recordInlineRenderStage'
$inlineRenderStatusCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticStringgetInlineRenderStatus()' `
    -Label 'AutoBlockSync.getInlineRenderStatus'
$saturatingIncrementCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticintsaturatingIncrement(intvalue)' `
    -Label 'AutoBlockSync.saturatingIncrement'
foreach ($inlineCounterProof in @(
        'if("hook_seen".equals(stage)){inlineHookSeenCount=saturatingIncrement(inlineHookSeenCount);}',
        'elseif("button_rendered".equals(stage)){inlineButtonRenderedCount=saturatingIncrement(inlineButtonRenderedCount);}',
        'elseif("report_request_unavailable".equals(stage)){inlineRequestUnavailableCount=saturatingIncrement(inlineRequestUnavailableCount);}',
        'elseif("adapter_exception".equals(stage)){inlineAdapterExceptionCount=saturatingIncrement(inlineAdapterExceptionCount);}')) {
    if (-not $recordInlineStageCode.Contains($inlineCounterProof, [StringComparison]::Ordinal)) {
        throw "Inline diagnostics do not map one closed stage to one bounded counter: $inlineCounterProof"
    }
}
foreach ($inlineCounterDeclaration in @(
        'privatestaticintinlineHookSeenCount;',
        'privatestaticintinlineButtonRenderedCount;',
        'privatestaticintinlineRequestUnavailableCount;',
        'privatestaticintinlineAdapterExceptionCount;')) {
    if (-not $schedulerCode.Contains($inlineCounterDeclaration, [StringComparison]::Ordinal)) {
        throw "Inline diagnostic counter is missing or has unsafe external scope: $inlineCounterDeclaration"
    }
}
foreach ($inlineAggregateProof in @(
        'inlineHookSeenCount==0&&inlineButtonRenderedCount==0&&inlineRequestUnavailableCount==0&&inlineAdapterExceptionCount==0',
        '"hook="+inlineHookSeenCount',
        '",rendered="+inlineButtonRenderedCount',
        '",request-unavailable="+inlineRequestUnavailableCount',
        '",adapter-errors="+inlineAdapterExceptionCount',
        '"(thisprocess;noaccountdatalogged)"')) {
    if (-not $inlineRenderStatusCode.Contains($inlineAggregateProof, [StringComparison]::Ordinal)) {
        throw "Inline status does not expose the bounded aggregate four-counter shape: $inlineAggregateProof"
    }
}
if ($saturatingIncrementCode -ne 'returnvalue==Integer.MAX_VALUE?value:value+1;' `
        -or (Get-PatchletLiteralCount -Text $recordInlineStageCode `
            -Literal 'saturatingIncrement(') -ne 4 `
        -or $recordInlineStageCode.Contains('getCurrentViewer(', [StringComparison]::Ordinal) `
        -or $recordInlineStageCode.Contains('SharedPreferences', [StringComparison]::Ordinal) `
        -or $recordInlineStageCode.Contains('Log.', [StringComparison]::Ordinal)) {
    throw 'Inline render diagnostics must remain saturating, memory-only, fixed-stage, and identifier-free.'
}
$schedulerEntryPointCount = Get-PatchletLiteralCount -Text $controllerText -Literal 'AutoBlockSync.enqueueManual('
if ($schedulerEntryPointCount -ne 1) {
    throw 'Inline controller must have exactly one stable scheduler entry point.'
}
foreach ($forbidden in @('ThreadsBlockBridge', 'HttpURLConnection', 'WRITE_ENDPOINT', 'tree55.com')) {
    if ($controllerText.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Inline controller crosses the stable scheduler/no-network boundary: $forbidden"
    }
}
$inlineJavaText = $requestText + "`n" + $controllerText + "`n" + $dialogText + "`n" + $dialogStringsText
foreach ($forbidden in @('/v1/reports', '/reports', 'SUBMIT_REPORT', 'HttpURLConnection', 'WRITE_ENDPOINT', 'tree55.com', 'LX/')) {
    if ($inlineJavaText.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Compact inline chooser crosses the stable no-network boundary: $forbidden"
    }
}
foreach ($requestModelProof in @(
        'privatestaticfinalintMAX_LABEL=80;',
        'this.label=cleanText(label,MAX_LABEL);',
        'privatefinalObjectresolvedAuthorModel;',
        'privatefinalObjectresolvedMediaModel;',
        'publicInlineBlockRequest(StringmediaKey,StringauthorId,Stringlabel,ObjectresolvedAuthorModel)',
        'publicObjectgetResolvedAuthorModel(){returnresolvedAuthorModel;}',
        'publicObjectgetResolvedMediaModel(){returnresolvedMediaModel;}',
        'this(mediaKey,authorId,label,null,null);',
        'this(mediaKey,authorId,label,resolvedAuthorModel,null);',
        'privateInlineBlockRequest(StringmediaKey,StringauthorId,Stringlabel,ObjectresolvedAuthorModel,ObjectresolvedMediaModel)',
        'publicstaticInlineBlockRequestcreateHostBound(StringmediaKey,StringauthorId,Stringusername,ObjectresolvedAuthorModel,ObjectresolvedMediaModel)',
        'returnnewInlineBlockRequest(mediaKey,authorId,displayLabel,resolvedAuthorModel,resolvedMediaModel);')) {
    if (-not $requestCode.Contains($requestModelProof, [StringComparison]::Ordinal)) {
        throw "Inline request does not carry one immutable host-bound author/media snapshot as opaque Objects: $requestModelProof"
    }
}
$hostBoundFactoryIndex = $requestCode.IndexOf(
    'publicstaticInlineBlockRequestcreateHostBound(', [StringComparison]::Ordinal)
$usernameCleanIndex = $requestCode.IndexOf(
    'StringcleanUsername=cleanText(username,MAX_LABEL-1);', [StringComparison]::Ordinal)
$usernamePrefixIndex = $requestCode.IndexOf(
    'cleanUsername.startsWith("@")?cleanUsername:"@"+cleanUsername', [StringComparison]::Ordinal)
$hostBoundRequestIndex = $requestCode.IndexOf(
    'returnnewInlineBlockRequest(mediaKey,authorId,displayLabel,resolvedAuthorModel,resolvedMediaModel);',
    [StringComparison]::Ordinal)
if ($hostBoundFactoryIndex -lt 0 `
        -or $usernameCleanIndex -le $hostBoundFactoryIndex `
        -or $usernamePrefixIndex -le $usernameCleanIndex `
        -or $hostBoundRequestIndex -le $usernamePrefixIndex `
        -or -not $dialogCode.Contains(
            'Stringlabel=request.getLabel();', [StringComparison]::Ordinal) `
        -or -not $dialogCode.Contains(
            'label.length()==0?"@"+reportRequest.getProfileUsername():label',
            [StringComparison]::Ordinal)) {
    throw 'Immutable host-bound request does not sanitize, prefix, and hand off a bounded display username.'
}
$requiredAdapterRequestCalls = @(
    'InlineBlockRequest;->hasMediaKey(Ljava/lang/String;)Z',
    'InlineBlockRequest;->isValid()Z',
    'InlineBlockRequest;->getAuthorId()Ljava/lang/String;',
    'InlineBlockRequest;->getLabel()Ljava/lang/String;',
    'InlineBlockRequest;->getResolvedAuthorModel()Ljava/lang/Object;'
)
foreach ($requiredAdapterRequestCall in $requiredAdapterRequestCalls) {
    if ((Get-PatchletLiteralCount -Text $rowAdapterTemplateText `
                -Literal $requiredAdapterRequestCall) -ne 1) {
        throw "SHA-bound row adapter must consume the immutable request getter exactly once: $requiredAdapterRequestCall"
    }
}
if ((Get-PatchletLiteralCount -Text $rowAdapterTemplateText `
            -Literal 'Lthreadsmod/inlinecontrol/InlineBlockRequest;JJ)V') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $rowAdapterTemplateText `
            -Literal 'move-object v9, v3') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $rowAdapterTemplateText `
            -Literal 'InlineReportActionFactory;->createRequest(Lthreadsmod/inlinecontrol/InlineBlockRequest;)Lthreadsmod/reporting/ReportRequest;') -ne 1 `
        -or -not [regex]::IsMatch(
            $rowAdapterTemplateText,
            'move-object/from16\s+v10,\s+v27\s+' +
                'invoke-interface\s+\{v1,\s*v10\},\s+' +
                '\{\{composerDescriptor\}\}->[A-Za-z0-9_$]+\(Ljava/lang/Object;\)Z')) {
    throw 'SHA-bound row adapter does not bind the same immutable request and resolved author to Compose and Report.'
}
    if ((Get-PatchletLiteralCount -Text $clickTemplateText `
            -Literal 'InlineBlockRequest;->getResolvedAuthorModel()Ljava/lang/Object;') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $clickTemplateText `
            -Literal 'InlineBlockController;->onClick(Lthreadsmod/inlinecontrol/InlineBlockRequest;Lthreadsmod/reporting/ReportRequest;Ljava/lang/Object;Lthreadsmod/inlinecontrol/InlineBlockUiCallback;)V') -ne 1 `
        -or -not $controllerCode.Contains(
            'onClick(request,reportRequest,request==null?null:request.getResolvedAuthorModel(),callback);',
            [StringComparison]::Ordinal) `
        -or -not $controllerCode.Contains(
            'reserve(request,resolvedAuthorModel,callback)',
            [StringComparison]::Ordinal) `
        -or -not $controllerCode.Contains(
            'operation.request.getLabel(),operation.resolvedAuthorModel,newManualBlockCallback()',
            [StringComparison]::Ordinal)) {
    throw 'Opaque row author model is not passed request -> click -> controller -> scheduler without host-type inspection.'
}
$inlineDiagnosticRecordCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'publicstaticvoidrecordInlinePreEnqueueFailure(Stringstage,booleanresolvedRowModel)' `
    -Label 'AutoBlockSync.recordInlinePreEnqueueFailure'
$inlinePauseIndex = $inlineDiagnosticRecordCode.IndexOf(
    'backoffPersisted=persistRetryDeadline(activity,viewer);',
    [StringComparison]::Ordinal)
$inlineDiagnosticIndex = $inlineDiagnosticRecordCode.IndexOf(
    'BlockDiagnosticdiagnostic=BlockDiagnostic.forFailure(stage,false,resolvedRowModel,false,backoffPersisted);',
    [StringComparison]::Ordinal)
$inlineAlertIndex = $inlineDiagnosticRecordCode.IndexOf(
    'ModStateStore.recordFailureDiagnostic(activity,viewer,diagnostic);',
    [StringComparison]::Ordinal)
$inlineStatusIndex = $inlineDiagnosticRecordCode.IndexOf(
    'setStatus(activity,viewer,diagnostic.status());', [StringComparison]::Ordinal)
$inlineLogIndex = $inlineDiagnosticRecordCode.IndexOf(
    'Log.w(TAG,diagnostic.logLine());', [StringComparison]::Ordinal)
$inlineWakeIndex = $inlineDiagnosticRecordCode.IndexOf(
    'scheduleManualDrain(FAILURE_BACKOFF_MS+1000L);', [StringComparison]::Ordinal)
if ($inlinePauseIndex -lt 0 -or $inlineDiagnosticIndex -le $inlinePauseIndex `
        -or $inlineAlertIndex -le $inlineDiagnosticIndex `
        -or $inlineStatusIndex -le $inlineAlertIndex `
        -or $inlineLogIndex -le $inlineStatusIndex `
        -or $inlineWakeIndex -le $inlineLogIndex) {
    throw 'Inline pre-enqueue failure recorder does not create, persist, surface, log, and pause through one closed diagnostic.'
}
$controllerFailCode = Get-JavaBlockBody -Text $controllerCode `
    -Anchor 'privatestaticvoidfail(Operationoperation,Stringstage)' `
    -Label 'InlineBlockController.fail'
$controllerFailBeforeCode = Get-JavaBlockBody -Text $controllerCode `
    -Anchor 'privatestaticvoidfailBeforeEnqueue(InlineBlockUiCallbackcallback,InlineBlockRequestrequest,ObjectresolvedAuthorModel,Stringstage)' `
    -Label 'InlineBlockController.failBeforeEnqueue'
$controllerRecordIndex = $controllerFailCode.IndexOf(
    'AutoBlockSync.recordInlinePreEnqueueFailure(closedStage,operation.resolvedAuthorModel!=null);',
    [StringComparison]::Ordinal)
$controllerTransitionIndex = $controllerFailCode.IndexOf(
    'transition(operation,UI_FAILED);', [StringComparison]::Ordinal)
$controllerCallbackIndex = $controllerFailCode.IndexOf(
    'safeFailure(operation.callback(),operation.request,closedStage);',
    [StringComparison]::Ordinal)
$controllerEarlyRecordIndex = $controllerFailBeforeCode.IndexOf(
    'AutoBlockSync.recordInlinePreEnqueueFailure(closedStage,resolvedAuthorModel!=null);',
    [StringComparison]::Ordinal)
$controllerEarlyCallbackIndex = $controllerFailBeforeCode.IndexOf(
    'safeFailure(callback,request,closedStage);', [StringComparison]::Ordinal)
if (-not $controllerFailCode.Contains(
        'if(isCurrentWithState(operation,UI_CONFIRMING))',
        [StringComparison]::Ordinal) `
        -or $controllerRecordIndex -lt 0 `
        -or $controllerTransitionIndex -le $controllerRecordIndex `
        -or $controllerCallbackIndex -le $controllerTransitionIndex `
        -or $controllerEarlyRecordIndex -lt 0 `
        -or $controllerEarlyCallbackIndex -le $controllerEarlyRecordIndex `
        -or (Get-PatchletLiteralCount -Text $controllerCode `
            -Literal 'AutoBlockSync.recordInlinePreEnqueueFailure(') -ne 2 `
        -or (Get-PatchletLiteralCount -Text $controllerCode `
            -Literal 'safeFailure(') -ne 3) {
    throw 'Inline controller does not persist each pre-queue diagnostic before callback while leaving post-queue diagnostics scheduler-owned.'
}
foreach ($requiredInlineTerminalBranch in @(
        'failBeforeEnqueue(callback,request,resolvedAuthorModel,"invalid_target");',
        'failBeforeEnqueue(callback,request,resolvedAuthorModel,"no_foreground_session");',
        'failBeforeEnqueue(callback,request,resolvedAuthorModel,"self_block_refused");',
        'fail(operation,"confirmation_unavailable");',
        'fail(operation,"report_context_unavailable");',
        'fail(operation,"foreground_lost");',
        'fail(operation,"viewer_changed");',
        'fail(operation,"scheduler_rejected");')) {
    if (-not $controllerCode.Contains(
            $requiredInlineTerminalBranch, [StringComparison]::Ordinal)) {
        throw "Inline terminal pre-enqueue branch bypasses the closed diagnostic owner: $requiredInlineTerminalBranch"
    }
}
$clickFailureStart = $clickTemplateText.IndexOf(
    '.method public onFailure(Lthreadsmod/inlinecontrol/InlineBlockRequest;Ljava/lang/String;)V',
    [StringComparison]::Ordinal)
$clickFailureEnd = if ($clickFailureStart -ge 0) {
    $clickTemplateText.IndexOf('.end method', $clickFailureStart, [StringComparison]::Ordinal)
} else { -1 }
$clickFailureMethod = if ($clickFailureStart -ge 0 -and $clickFailureEnd -gt $clickFailureStart) {
    $clickTemplateText.Substring($clickFailureStart, $clickFailureEnd - $clickFailureStart)
} else { '' }
if ([string]::IsNullOrWhiteSpace($clickFailureMethod) `
        -or (Get-PatchletLiteralCount -Text $clickFailureMethod `
            -Literal 'InlineActionClick;->setState(I)V') -ne 1) {
    throw 'InlineActionClick failure callback is not an exact UI reset.'
}
foreach ($forbiddenClickDiagnosticOwner in @(
        'recordInlinePreEnqueueFailure', 'BlockDiagnostic', 'ModStateStore',
        'Lthreadsmod/autoblock/AutoBlockSync;', 'Landroid/util/Log;->')) {
    if ($clickFailureMethod.Contains(
            $forbiddenClickDiagnosticOwner, [StringComparison]::Ordinal)) {
        throw "InlineActionClick duplicates scheduler/controller diagnostic ownership: $forbiddenClickDiagnosticOwner"
    }
}
$earlyJoinedInlineTemplates = $inlineTemplateText -join "`n"
$resolvedBlockMutationMethod = [string]$resolution.bridge.symbols.blockMutationMethod
if ($stateText.Contains('resolvedAuthorModel', [StringComparison]::Ordinal) `
        -or $stateText.Contains('ResolvedAuthorModel', [StringComparison]::Ordinal) `
        -or ($earlyJoinedInlineTemplates + "`n" + $inlineJavaText).Contains(
            '{{blockMutationMethod}}', [StringComparison]::Ordinal) `
        -or ($earlyJoinedInlineTemplates + "`n" + $inlineJavaText).Contains(
            $resolvedBlockMutationMethod, [StringComparison]::Ordinal) `
        -or $earlyJoinedInlineTemplates.Contains(
            'ThreadsBlockBridge;->block', [StringComparison]::Ordinal)) {
    throw 'Inline UI persists or directly mutates through the transient resolved-author hint.'
}
if ((Get-PatchletLiteralCount -Text $controllerText -Literal 'InlineBlockDialog.show(') -ne 1) {
    throw 'Inline action does not route through exactly one compact combined chooser.'
}
if ((Get-PatchletLiteralCount -Text $controllerText -Literal 'transition(operation, UI_SUCCESS)') -ne 1) {
    throw 'Inline success must have exactly one native-callback-driven transition.'
}
foreach ($requiredDialogLiteral in @(
    'strings.accountMetadata(request.getAuthorId())',
    'reportRequest.getPostContent()',
    'new Spinner(activity)',
    'REASON_VALUES[position]',
    'strings.alsoBlockLabel',
    'listener.onAlsoBlockChanged(alsoBlock.isChecked())',
    'listener.onSubmit(',
    'settled.compareAndSet(false, true)'
)) {
    if (-not $dialogText.Contains($requiredDialogLiteral, [StringComparison]::Ordinal)) {
        throw "Compact combined chooser is missing required behavior: $requiredDialogLiteral"
    }
}
if ((Get-PatchletLiteralCount -Text $dialogText -Literal 'card(activity)') -ne 3 `
        -or -not $dialogStringsText.Contains('title = "Block and report"', [StringComparison]::Ordinal) `
        -or -not $dialogStringsText.Contains(
            'alsoBlockLabel = "Also block this profile"',
            [StringComparison]::Ordinal)) {
    throw 'Inline action is not the compact three-card Block-and-report design.'
}
if ((Get-PatchletLiteralCount -Text $dialogText -Literal '.setPositiveButton(') -ne 1 `
        -or $dialogText.Contains('setNeutralButton', [StringComparison]::Ordinal) `
        -or $dialogText.Contains('BUTTON_NEUTRAL', [StringComparison]::Ordinal) `
        -or -not $dialogCode.Contains(
            'positive.setText(checked?strings.block:strings.report);',
            [StringComparison]::Ordinal) `
        -or -not $dialogCode.Contains(
            '.setPositiveButton(alsoBlock.isChecked()?strings.block:strings.report,null)',
            [StringComparison]::Ordinal)) {
    throw 'Combined modal must expose one dynamic Block/Report positive action and no dedicated Report action.'
}
foreach ($forbiddenChooserState in @(
        'new EditText(', 'note', 'consent', 'outbox', 'schedulerBusy',
        'selectedItemDetail', 'safetyTitle', 'Review report')) {
    if ($dialogText.Contains($forbiddenChooserState, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Combined modal contains a retired second-step or non-compact state: $forbiddenChooserState"
    }
}
$submitCombinedCode = Get-JavaBlockBody -Text $controllerCode `
    -Anchor 'privatestaticvoidsubmitCombined(' `
    -Label 'InlineBlockController.submitCombined'
$combinedQueueIndex = $submitCombinedCode.IndexOf(
    'ReportController.queueFromForeground(', [StringComparison]::Ordinal)
$optionalBlockIndex = $submitCombinedCode.IndexOf(
    'if(alsoBlock&&isCurrent(operation))', [StringComparison]::Ordinal)
$schedulerSubmitIndex = $submitCombinedCode.IndexOf(
    'submit(activity,viewer,operation);', $optionalBlockIndex, [StringComparison]::Ordinal)
if ($combinedQueueIndex -lt 0 -or $optionalBlockIndex -le $combinedQueueIndex `
        -or $schedulerSubmitIndex -le $optionalBlockIndex `
        -or -not $submitCombinedCode.Contains(
            'AutoBlockSync.getForegroundActivity()!=activity',
            [StringComparison]::Ordinal) `
        -or -not $submitCombinedCode.Contains(
            'ReportController.queueFromForeground(activity,viewer,reportRequest,reason,newReportResultCallback()',
            [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $submitCombinedCode `
            -Literal 'ReportController.queueFromForeground(') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $submitCombinedCode `
            -Literal 'submit(activity,viewer,operation);') -ne 1 `
        -or $controllerCode.Contains('isOneClickBlockEnabled', [StringComparison]::Ordinal) `
        -or $controllerCode.Contains('openReport(', [StringComparison]::Ordinal) `
        -or -not $controllerCode.Contains(
            'safeCancelled(operation.callback(),operation.request);',
            [StringComparison]::Ordinal)) {
    throw 'The combined positive action does not always queue Report before optionally scheduling Block.'
}
if (-not $stateCode.Contains(
        'KEY_ALSO_BLOCK_PROFILE="ui_also_block_profile"', [StringComparison]::Ordinal) `
        -or -not $stateCode.Contains(
            'getBoolean(KEY_ALSO_BLOCK_PROFILE,true)', [StringComparison]::Ordinal) `
        -or -not $stateCode.Contains(
            'putBoolean(KEY_ALSO_BLOCK_PROFILE,enabled).commit()',
            [StringComparison]::Ordinal) `
        -or $stateText.Contains('KEY_ONE_CLICK', [StringComparison]::Ordinal) `
        -or $stateText.Contains('KEY_DISMISS_AFTER_BLOCK', [StringComparison]::Ordinal) `
        -or $settingsText.Contains('One-click block', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The Also-block checkbox default is not durably persisted or a retired one-click preference remains.'
}
foreach ($activeViewerProof in @(
    'LEGACY_KEY_ACTIVE_VIEWER = "ui_active_viewer"',
    'private static String activeViewer = ""',
    'private static boolean activeViewerSuppressed = true'
)) {
    if (-not $stateText.Contains($activeViewerProof, [StringComparison]::Ordinal)) {
        throw "In-process viewer isolation proof is missing: $activeViewerProof"
    }
}
if ((Get-PatchletLiteralCount -Text $schedulerText `
        -Literal 'ModStateStore.setValidatedActiveViewer(activity, viewer)') -ne 1 `
        -or -not $schedulerText.Contains('ModStateStore.clearActiveViewer(activity)', [StringComparison]::Ordinal) `
        -or $stateText.Contains('.putString(LEGACY_KEY_ACTIVE_VIEWER', [StringComparison]::Ordinal) `
        -or $stateText.Contains('.getString(LEGACY_KEY_ACTIVE_VIEWER', [StringComparison]::Ordinal) `
        -or ($schedulerText + $stateText).Contains('ModStateStore.setActiveViewer(', [StringComparison]::Ordinal)) {
    throw 'A raw persisted or non-session-owned active viewer can re-enter the UI/report scope.'
}
$setViewerCode = Get-JavaBlockBody -Text $stateCode `
    -Anchor 'staticsynchronizedbooleansetValidatedActiveViewer(Contextcontext,StringviewerId)' `
    -Label 'ModStateStore.setValidatedActiveViewer'
$getViewerCode = Get-JavaBlockBody -Text $stateCode `
    -Anchor 'publicstaticsynchronizedStringgetActiveViewer(Contextcontext)' `
    -Label 'ModStateStore.getActiveViewer'
$removeLegacyViewerCode = Get-JavaBlockBody -Text $stateCode `
    -Anchor 'privatestaticbooleanremoveLegacyActiveViewer(Contextcontext)' `
    -Label 'ModStateStore.removeLegacyActiveViewer'
if (-not $setViewerCode.Contains('if(!removeLegacyActiveViewer(context))', [StringComparison]::Ordinal) `
        -or -not $setViewerCode.Contains('activeViewer=viewerId;', [StringComparison]::Ordinal) `
        -or -not $getViewerCode.Contains('Stringvalue=activeViewer;', [StringComparison]::Ordinal) `
        -or -not $getViewerCode.Contains('if(context==null||!removeLegacyActiveViewer(context))', [StringComparison]::Ordinal) `
        -or -not $removeLegacyViewerCode.Contains('.remove(LEGACY_KEY_ACTIVE_VIEWER).commit()', [StringComparison]::Ordinal)) {
    throw 'Viewer scope is not process-memory-only with fail-closed legacy-key removal.'
}
if (-not $schedulerText.Contains(
        'if (userSession == null || !isDecimalId(viewer) || viewer.length() > 24)',
        [StringComparison]::Ordinal)) {
    throw 'Missing or non-canonical extracted viewers must clear the persisted active-viewer scope.'
}
if ((Get-PatchletLiteralCount -Text $schedulerText -Literal 'recoverInterruptedManual(activity, viewer)') -ne 1) {
    throw 'Cold-process recovery for interrupted manual work is not pinned.'
}
foreach ($retiredAdmissionLiteral in @(
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
    if ($schedulerText.Contains($retiredAdmissionLiteral, [StringComparison]::Ordinal)) {
        throw "Scheduler retains removed admission-cap authority: $retiredAdmissionLiteral"
    }
}
$enqueueManualWithModelCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'publicstaticbooleanenqueueManual(StringtargetId,Stringlabel,ObjectresolvedAuthorModel,ManualBlockCallbackcallback)' `
    -Label 'AutoBlockSync.enqueueManual resolved model overload'
$durableEnqueueIndex = $enqueueManualWithModelCode.IndexOf(
    'if(!ModStateStore.enqueueManual(activity,viewer,targetId,label,ModStateStore.SOURCE_INLINE))',
    [StringComparison]::Ordinal)
$rememberModelIndex = $enqueueManualWithModelCode.IndexOf(
    'rememberResolvedAuthorModel(viewer,targetId,session,resolvedAuthorModel);',
    [StringComparison]::Ordinal)
$enqueueSuccessIndex = $enqueueManualWithModelCode.LastIndexOf(
    'returntrue;', [StringComparison]::Ordinal)
if ($durableEnqueueIndex -lt 0 -or $rememberModelIndex -le $durableEnqueueIndex `
        -or $enqueueSuccessIndex -le $rememberModelIndex) {
    throw 'Transient row model is staged before the manual queue item is durably accepted.'
}
foreach ($registryProof in @(
        'privatestaticfinalintMAX_RESOLVED_AUTHOR_MODELS=64;',
        'privatestaticfinallongRESOLVED_AUTHOR_MODEL_TTL_MS=10L*60L*1000L;',
        'newLinkedHashMap<String,ResolvedAuthorModel>(16,0.75f,true);',
        'while(RESOLVED_AUTHOR_MODELS.size()>MAX_RESOLVED_AUTHOR_MODELS)',
        'RESOLVED_AUTHOR_MODELS.remove(resolvedAuthorModelKey(viewer,targetId))',
        'hint.session!=session',
        '!viewer.equals(hint.viewer)',
        '!targetId.equals(hint.targetId)',
        'now-hint.createdAt>RESOLVED_AUTHOR_MODEL_TTL_MS')) {
    if (-not $schedulerCode.Contains($registryProof, [StringComparison]::Ordinal)) {
        throw "Resolved-author registry is not bounded, expiring, viewer/target/session-scoped, and consume-once: $registryProof"
    }
}
if ((Get-PatchletLiteralCount -Text $schedulerCode -Literal 'clearResolvedAuthorModels();') -ne 2 `
        -or (Get-PatchletLiteralCount -Text $schedulerCode `
            -Literal 'scopeResolvedAuthorModels(viewer,userSession);') -ne 1) {
    throw 'Resolved-author registry is not cleared or narrowed on invalid, changed, and resumed viewer contexts.'
}
$blockRunCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticfinalclassBlockRunimplementsBridgeCallback' -Label 'BlockRun'
$automaticBeginCode = Get-JavaBlockBody -Text $blockRunCode `
    -Anchor 'voidbegin()' -Label 'BlockRun.begin'
$passivePreflightIndex = $automaticBeginCode.IndexOf(
    'ThreadsBlockBridge.passivePreflight(userSession,targetId)',
    [StringComparison]::Ordinal)
$postPreflightForegroundIndex = $automaticBeginCode.IndexOf(
    'if(!isCurrentForeground())', $passivePreflightIndex,
    [StringComparison]::Ordinal)
$postPreflightManualIndex = $automaticBeginCode.IndexOf(
    'if(ModStateStore.nextQueued(activity,viewer)!=null)', $postPreflightForegroundIndex,
    [StringComparison]::Ordinal)
$postPreflightMembershipIndex = $automaticBeginCode.IndexOf(
    'PassiveMatchResultpostPreflightMatch=currentPassiveMatch(activity,viewer,targetId);',
    $postPreflightManualIndex, [StringComparison]::Ordinal)
$postPreflightStoreIndex = $automaticBeginCode.IndexOf(
    'if(!postPreflightMatch.storeValid)', $postPreflightMembershipIndex,
    [StringComparison]::Ordinal)
$postPreflightMatchedIndex = $automaticBeginCode.IndexOf(
    'if(!postPreflightMatch.matched)', $postPreflightStoreIndex,
    [StringComparison]::Ordinal)
$alreadyBlockedBranchIndex = $automaticBeginCode.IndexOf(
    'if("already_blocked_success".equals(preflightStage))',
    $postPreflightMatchedIndex, [StringComparison]::Ordinal)
$preflightFailureBranchIndex = $automaticBeginCode.IndexOf(
    'if(preflightStage!=null)', $alreadyBlockedBranchIndex,
    [StringComparison]::Ordinal)
$postPreflightLimitsIndex = $automaticBeginCode.IndexOf(
    'if(!BlockLimitsStore.isValid(activity))', $preflightFailureBranchIndex,
    [StringComparison]::Ordinal)
$postPreflightDoneIndex = $automaticBeginCode.IndexOf(
    'currentDone=doneIds(activity,viewer)', $postPreflightLimitsIndex,
    [StringComparison]::Ordinal)
$postPreflightReviewIndex = $automaticBeginCode.IndexOf(
    'currentReview=ModStateStore.completionReviewState(activity,viewer)',
    $postPreflightDoneIndex, [StringComparison]::Ordinal)
$finalPostPreflightMembershipIndex = $automaticBeginCode.IndexOf(
    'PassiveMatchResultfinalMatch=currentPassiveMatch(activity,viewer,targetId);',
    $postPreflightReviewIndex, [StringComparison]::Ordinal)
$finalPostPreflightStoreIndex = $automaticBeginCode.IndexOf(
    'if(!finalMatch.storeValid)', $finalPostPreflightMembershipIndex,
    [StringComparison]::Ordinal)
$finalPostPreflightMatchedIndex = $automaticBeginCode.IndexOf(
    'if(!finalMatch.matched)', $finalPostPreflightStoreIndex,
    [StringComparison]::Ordinal)
$postPreflightPaceIndex = $automaticBeginCode.IndexOf(
    'longcurrentPaceWait=millisUntilPassivePaceAllowed(activity,viewer)',
    $finalPostPreflightMatchedIndex, [StringComparison]::Ordinal)
$preflightBeforeRunningAuthorityIndex = $automaticBeginCode.IndexOf(
    'PassiveAuthoritybeforeRunning=currentPassiveAuthority(false,false);',
    $postPreflightPaceIndex,
    [StringComparison]::Ordinal)
$passiveRunningIndex = $automaticBeginCode.IndexOf(
    'if(!ModStateStore.markPassiveRunning(activity,viewer,targetId))',
    $preflightBeforeRunningAuthorityIndex, [StringComparison]::Ordinal)
$preflightBeforeReservationAuthorityIndex = $automaticBeginCode.IndexOf(
    'PassiveAuthoritybeforeReservation=currentPassiveAuthority(true,false);',
    $passiveRunningIndex, [StringComparison]::Ordinal)
$passiveReservationIndex = $automaticBeginCode.IndexOf(
    'if(!reserveAttempt(activity,viewer,true))', $preflightBeforeReservationAuthorityIndex,
    [StringComparison]::Ordinal)
$preflightBeforeDispatchAuthorityIndex = $automaticBeginCode.IndexOf(
    'PassiveAuthoritybeforeDispatch=currentPassiveAuthority(true,true);',
    $passiveReservationIndex, [StringComparison]::Ordinal)
$passiveBlockIndex = $automaticBeginCode.IndexOf(
    'ThreadsBlockBridge.block(activity,userSession,targetId,this)',
    $preflightBeforeDispatchAuthorityIndex, [StringComparison]::Ordinal)
if ($passivePreflightIndex -lt 0 `
        -or $postPreflightForegroundIndex -le $passivePreflightIndex `
        -or $postPreflightManualIndex -le $postPreflightForegroundIndex `
        -or $postPreflightMembershipIndex -le $postPreflightManualIndex `
        -or $postPreflightStoreIndex -le $postPreflightMembershipIndex `
        -or $postPreflightMatchedIndex -le $postPreflightStoreIndex `
        -or $alreadyBlockedBranchIndex -le $postPreflightMatchedIndex `
        -or $preflightFailureBranchIndex -le $alreadyBlockedBranchIndex `
        -or $postPreflightLimitsIndex -le $preflightFailureBranchIndex `
        -or $postPreflightDoneIndex -le $postPreflightLimitsIndex `
        -or $postPreflightReviewIndex -le $postPreflightDoneIndex `
        -or $finalPostPreflightMembershipIndex -le $postPreflightReviewIndex `
        -or $finalPostPreflightStoreIndex -le $finalPostPreflightMembershipIndex `
        -or $finalPostPreflightMatchedIndex -le $finalPostPreflightStoreIndex `
        -or $postPreflightPaceIndex -le $finalPostPreflightMatchedIndex `
        -or $preflightBeforeRunningAuthorityIndex -le $postPreflightPaceIndex `
        -or $passiveRunningIndex -le $preflightBeforeRunningAuthorityIndex `
        -or $preflightBeforeReservationAuthorityIndex -le $passiveRunningIndex `
        -or $passiveReservationIndex -le $preflightBeforeReservationAuthorityIndex `
        -or $preflightBeforeDispatchAuthorityIndex -le $passiveReservationIndex `
        -or $passiveBlockIndex -le $preflightBeforeDispatchAuthorityIndex) {
    throw 'Passive preflight is not followed by tri-state membership, passive pacing, and all three late authority checks before running, reservation, and Block dispatch.'
}
foreach ($requiredPreflightCallerProof in @(
        'catch(Throwableignored){preflightStage="bridge_dispatch_exception";}',
        'handleAlreadyBlockedBeforeReservation();',
        'handlePreflightFailure(preflightStage);')) {
    if (-not $automaticBeginCode.Contains(
            $requiredPreflightCallerProof, [StringComparison]::Ordinal)) {
        throw "Passive preflight caller is missing fixed closed handling: $requiredPreflightCallerProof"
    }
}
$alreadyBlockedPreReservationCode = Get-JavaBlockBody -Text $blockRunCode `
    -Anchor 'privatevoidhandleAlreadyBlockedBeforeReservation()' `
    -Label 'BlockRun.handleAlreadyBlockedBeforeReservation'
foreach ($requiredAlreadyBlockedProof in @(
        'completionSaved=markDone(activity,viewer,targetId);',
        'reviewSaved=quarantineCompletionReview(activity,viewer,targetId);',
        'BlockDiagnostic.forFailure("completion_persistence",true,false,false,reviewSaved)',
        'clearRetryDeadline(activity,viewer);',
        'finishAndResume("SkippedonevisibleprofilethatThreadsalreadyreportsblocked.",0L);')) {
    if (-not $alreadyBlockedPreReservationCode.Contains(
            $requiredAlreadyBlockedProof, [StringComparison]::Ordinal)) {
        throw "Native-already-blocked branch is missing completion/quarantine proof: $requiredAlreadyBlockedProof"
    }
}
$preflightFailureCode = Get-JavaBlockBody -Text $blockRunCode `
    -Anchor 'privatevoidhandlePreflightFailure(Stringstage)' `
    -Label 'BlockRun.handlePreflightFailure'
foreach ($requiredPreflightFailureProof in @(
        'backoffPersisted=persistRetryDeadline(activity,viewer);',
        'BlockDiagnostic.forFailure(stage,true,false,false,backoffPersisted)',
        'ModStateStore.recordAutomaticFailure(activity,viewer,targetId,diagnostic);',
        'ModStateStore.recordFailureDiagnostic(activity,viewer,diagnostic);',
        'scheduleManualDrain(FAILURE_BACKOFF_MS+1000L);')) {
    if (-not $preflightFailureCode.Contains(
            $requiredPreflightFailureProof, [StringComparison]::Ordinal)) {
        throw "Passive-preflight failure branch is missing closed backoff proof: $requiredPreflightFailureProof"
    }
}
foreach ($preReservationBranch in @(
        @('already-blocked', $alreadyBlockedPreReservationCode),
        @('preflight failure', $preflightFailureCode))) {
    foreach ($forbiddenPreReservationSideEffect in @(
            'admitForegroundPassiveTarget(',
            'markPassiveRunning(',
            'reserveAttempt(',
            'ThreadsBlockBridge.block(')) {
        if (([string]$preReservationBranch[1]).Contains(
                $forbiddenPreReservationSideEffect, [StringComparison]::Ordinal)) {
            throw "Passive $($preReservationBranch[0]) branch consumes admission, running, reservation, or mutation authority: $forbiddenPreReservationSideEffect"
        }
    }
}
foreach ($forbiddenSameOwnerBatchProof in @(
        'privatefinalList<String>targets;',
        'privateintindex;',
        'while(index<',
        'targets.get(',
        'privatevoidnext()',
        'next();')) {
    if ($blockRunCode.Contains(
            $forbiddenSameOwnerBatchProof, [StringComparison]::Ordinal)) {
        throw "Passive BlockRun still batches or iterates under one scheduler owner: $forbiddenSameOwnerBatchProof"
    }
}
foreach ($requiredSingleTargetDrainProof in @(
        'privatefinalStringtargetId;',
        'loadTarget(activity,viewer,forceRefresh)',
        'activity,userSession,viewer,selection.targetId,forceRefresh,schedulerToken).begin();',
        'privatevoidfinishAndResume(Stringstatus,longdelayMs)',
        'releaseSchedulerAndContinue(schedulerToken,activity,viewer,Math.max(0L,delayMs),true);')) {
    if (-not $schedulerCode.Contains(
            $requiredSingleTargetDrainProof, [StringComparison]::Ordinal)) {
        throw "Passive one-target fresh-drain proof is missing: $requiredSingleTargetDrainProof"
    }
}
$automaticReserveIndex = $automaticBeginCode.IndexOf(
    'if(!reserveAttempt(activity,viewer,true))', [StringComparison]::Ordinal)
if ($automaticReserveIndex -lt 0) {
    throw 'Automatic native Block has no executable durable reservation branch.'
}
$automaticReserveFailureCode = Get-JavaBlockBody -Text $automaticBeginCode `
    -Anchor 'if(!reserveAttempt(activity,viewer,true))' `
    -Label 'BlockRun.begin automatic reservation failure'
$automaticReservePersistIndex = $automaticReserveFailureCode.IndexOf(
    'booleanbackoffPersisted=persistRetryDeadline(activity,viewer);',
    [StringComparison]::Ordinal)
$automaticReserveDiagnosticIndex = $automaticReserveFailureCode.IndexOf(
    'BlockDiagnosticdiagnostic=BlockDiagnostic.forFailure("attempt_reservation",true,false,false,backoffPersisted);',
    [StringComparison]::Ordinal)
$automaticReserveHistoryIndex = $automaticReserveFailureCode.LastIndexOf(
    'ModStateStore.recordAutomaticFailure(activity,viewer,targetId,diagnostic);',
    [StringComparison]::Ordinal)
$automaticReserveAlertIndex = $automaticReserveFailureCode.LastIndexOf(
    'ModStateStore.recordFailureDiagnostic(activity,viewer,diagnostic);',
    [StringComparison]::Ordinal)
$automaticReserveLogIndex = $automaticReserveFailureCode.LastIndexOf(
    'Log.w(TAG,diagnostic.logLine());', [StringComparison]::Ordinal)
$automaticReserveStatusIndex = $automaticReserveFailureCode.LastIndexOf(
    'finish(diagnostic.status());', [StringComparison]::Ordinal)
$automaticReserveWakeIndex = $automaticReserveFailureCode.IndexOf(
    'scheduleManualDrain(FAILURE_BACKOFF_MS+1000L);', [StringComparison]::Ordinal)
if ($automaticReservePersistIndex -lt 0 `
        -or $automaticReserveDiagnosticIndex -le $automaticReservePersistIndex `
        -or $automaticReserveHistoryIndex -le $automaticReserveDiagnosticIndex `
        -or $automaticReserveAlertIndex -le $automaticReserveHistoryIndex `
        -or $automaticReserveLogIndex -le $automaticReserveAlertIndex `
        -or $automaticReserveStatusIndex -le $automaticReserveLogIndex `
        -or $automaticReserveWakeIndex -le $automaticReserveStatusIndex `
        -or $automaticReserveFailureCode.Contains(
            'ThreadsBlockBridge.', [StringComparison]::Ordinal)) {
    throw 'Automatic reservation failure does not persist pause state, history, closed diagnostic, alert/status, log, and fail-closed wake before any bridge call.'
}
$automaticRunningClearFailureCode = Get-JavaBlockBody -Text $automaticReserveFailureCode `
    -Anchor 'if(!runningCleared)' `
    -Label 'BlockRun.begin automatic running-state clear failure'
foreach ($requiredRunningClearFailure in @(
        'quarantineCompletionReview(activity,viewer,targetId)',
        'BlockDiagnostic.forFailure("completion_persistence",true,false,false,reviewSaved)',
        'ModStateStore.recordAutomaticFailure(activity,viewer,targetId,diagnostic);',
        'ModStateStore.recordFailureDiagnostic(activity,viewer,diagnostic);',
        'finish(diagnostic.status());',
        'return;')) {
    if (-not $automaticRunningClearFailureCode.Contains(
            $requiredRunningClearFailure, [StringComparison]::Ordinal)) {
        throw "Automatic running-state clear failure omits quarantine proof: $requiredRunningClearFailure"
    }
}
if ($automaticRunningClearFailureCode.Contains(
        'persistRetryDeadline(', [StringComparison]::Ordinal) `
        -or $automaticRunningClearFailureCode.Contains(
            'scheduleManualDrain(', [StringComparison]::Ordinal)) {
    throw 'Automatic running-state clear failure may not enter backoff or automatic retry after quarantine.'
}
$automaticMutationStateIndex = $automaticBeginCode.IndexOf(
    'if(!markSchedulerMutationInFlight(schedulerToken,true))',
    [StringComparison]::Ordinal)
$automaticMutationStateCode = Get-JavaBlockBody -Text $automaticBeginCode `
    -Anchor 'if(!markSchedulerMutationInFlight(schedulerToken,true))' `
    -Label 'BlockRun.begin scheduler mutation handoff'
$automaticBridgeTryShape = `
    'try{ThreadsBlockBridge.block(activity,userSession,targetId,this);}'
$automaticBridgeTryIndex = $automaticBeginCode.IndexOf(
    $automaticBridgeTryShape, [StringComparison]::Ordinal)
$automaticBridgeTryCode = if ($automaticBridgeTryIndex -ge 0) {
    Get-JavaBlockBody -Text $automaticBeginCode.Substring($automaticBridgeTryIndex) `
        -Anchor 'try' -Label 'BlockRun.begin bridge try'
} else {
    ''
}
$automaticBridgeIndex = Get-JavaTopLevelLiteralIndex -Text $automaticBridgeTryCode `
    -Literal 'ThreadsBlockBridge.block(activity,userSession,targetId,this);'
if ($automaticReserveIndex -lt 0 -or $automaticMutationStateIndex -lt 0 `
        -or $automaticMutationStateIndex -le $automaticReserveIndex `
        -or $automaticBridgeTryIndex -le $automaticMutationStateIndex `
        -or $automaticBridgeIndex -lt 0 `
        -or -not [string]::Equals(
            $automaticBridgeTryCode,
            'ThreadsBlockBridge.block(activity,userSession,targetId,this);',
            [StringComparison]::Ordinal)) {
    throw 'Automatic native Block is not downstream of reservation and scheduler handoff in an invocation-only try.'
}
foreach ($requiredAutomaticHandoffFailure in @(
        'waiting=false;',
        'ModStateStore.clearPassiveRunning(activity,viewer,targetId)',
        'quarantineCompletionReview(activity,viewer,targetId)',
        'finishForForegroundChange("BlockingmovedtothecurrentThreadsscreen.",forceRefresh);',
        'return;')) {
    if (-not $automaticMutationStateCode.Contains(
            $requiredAutomaticHandoffFailure, [StringComparison]::Ordinal)) {
        throw "Automatic scheduler-handoff failure omits durable passive cleanup: $requiredAutomaticHandoffFailure"
    }
}
if ($automaticMutationStateCode.Contains(
        'ThreadsBlockBridge.', [StringComparison]::Ordinal) `
        -or $automaticMutationStateCode.Contains(
            'persistRetryDeadline(', [StringComparison]::Ordinal)) {
    throw 'Automatic scheduler-handoff failure may not dispatch or back off uncertain durable passive state.'
}
$manualDrainCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticvoiddrainManualQueue()' -Label 'drainManualQueue'
$manualStartedIndex = Get-JavaTopLevelLiteralIndex -Text $manualDrainCode `
    -Literal 'if(!ModStateStore.markManualStarted(activity,viewer,item.targetId))'
$manualReserveIndex = Get-JavaTopLevelLiteralIndex -Text $manualDrainCode `
    -Literal 'if(!reserveAttempt(activity,viewer,false))'
$manualModelTakeIndex = Get-JavaTopLevelLiteralIndex -Text $manualDrainCode `
    -Literal 'ObjectresolvedAuthorModel=takeResolvedAuthorModel(viewer,item.targetId,session);'
$manualBeginIndex = Get-JavaTopLevelLiteralIndex -Text $manualDrainCode `
    -Literal 'newManualBlockRun(activity,session,viewer,item.targetId,resolvedAuthorModel,schedulerToken).begin();'
if ($manualStartedIndex -lt 0 -or $manualReserveIndex -le $manualStartedIndex `
        -or $manualModelTakeIndex -le $manualReserveIndex `
        -or $manualBeginIndex -le $manualModelTakeIndex) {
    throw 'Manual model hint and native runner are not downstream of queue-start persistence and durable attempt reservation.'
}
$manualRunCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticfinalclassManualBlockRunimplementsBridgeCallback' -Label 'ManualBlockRun'
$manualBeginCode = Get-JavaBlockBody -Text $manualRunCode `
    -Anchor 'voidbegin()' -Label 'ManualBlockRun.begin'
$manualMutationStateIndex = Get-JavaTopLevelLiteralIndex -Text $manualBeginCode `
    -Literal 'if(!markSchedulerMutationInFlight(schedulerToken,true))'
$manualMutationStateCode = Get-JavaBlockBody -Text $manualBeginCode `
    -Anchor 'if(!markSchedulerMutationInFlight(schedulerToken,true))' `
    -Label 'ManualBlockRun.begin scheduler mutation handoff'
$manualBridgeTryShape = 'try{if(resolvedAuthorModel==null){' `
    + 'ThreadsBlockBridge.block(activity,userSession,targetId,this);' `
    + '}else{ThreadsBlockBridge.blockResolved(' `
    + 'activity,userSession,resolvedAuthorModel,targetId,this);}}'
$manualBridgeTryIndex = $manualBeginCode.IndexOf(
    $manualBridgeTryShape, [StringComparison]::Ordinal)
$manualBridgeTryCode = if ($manualBridgeTryIndex -ge 0) {
    Get-JavaBlockBody -Text $manualBeginCode.Substring($manualBridgeTryIndex) `
        -Anchor 'try' -Label 'ManualBlockRun.begin bridge try'
} else {
    ''
}
$manualNullHintIndex = $manualBridgeTryCode.IndexOf(
    'if(resolvedAuthorModel==null)', [StringComparison]::Ordinal)
$manualDirectIdBridgeIndex = $manualBridgeTryCode.IndexOf(
    'ThreadsBlockBridge.block(activity,userSession,targetId,this);',
    [StringComparison]::Ordinal)
$manualResolvedBridgeIndex = $manualBridgeTryCode.IndexOf(
    'ThreadsBlockBridge.blockResolved(activity,userSession,resolvedAuthorModel,targetId,this);',
    [StringComparison]::Ordinal)
if ((Get-PatchletLiteralCount -Text $schedulerCode -Literal 'ThreadsBlockBridge.block(') -ne 2 `
        -or (Get-PatchletLiteralCount -Text $schedulerCode `
            -Literal 'ThreadsBlockBridge.blockResolved(') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $automaticBeginCode `
            -Literal 'ThreadsBlockBridge.block(activity,userSession,targetId,this);') -ne 1 `
        -or $automaticBeginCode.Contains('blockResolved(', [StringComparison]::Ordinal) `
        -or $manualMutationStateIndex -lt 0 `
        -or $manualBridgeTryIndex -le $manualMutationStateIndex `
        -or -not [string]::Equals(
            $manualMutationStateCode,
            'fail("scheduler_handoff");return;',
            [StringComparison]::Ordinal) `
        -or -not [string]::Equals(
            $manualBridgeTryCode,
            'if(resolvedAuthorModel==null){ThreadsBlockBridge.block(activity,userSession,targetId,this);}' `
                + 'else{ThreadsBlockBridge.blockResolved(' `
                + 'activity,userSession,resolvedAuthorModel,targetId,this);}',
            [StringComparison]::Ordinal) `
        -or $manualNullHintIndex -lt 0 `
        -or $manualDirectIdBridgeIndex -le $manualNullHintIndex `
        -or $manualResolvedBridgeIndex -le $manualDirectIdBridgeIndex) {
    throw 'Automatic and null-hint manual work do not use the direct-ID bridge while a reserved row model uses blockResolved.'
}
$forbiddenBridgeTryCallPattern = `
    '(?i)[A-Za-z_$][A-Za-z0-9_$]*(?:fail|finish|dispatch|scheduler)[A-Za-z0-9_$]*\('
foreach ($bridgeTryContract in @(
        @('BlockRun.begin', $automaticBridgeTryCode),
        @('ManualBlockRun.begin', $manualBridgeTryCode))) {
    $forbiddenBridgeTryCall = [regex]::Match(
        [string]$bridgeTryContract[1], $forbiddenBridgeTryCallPattern)
    if ($forbiddenBridgeTryCall.Success) {
        throw "Bridge try '$($bridgeTryContract[0])' contains failure, finish, dispatch, or scheduler-state work: $($forbiddenBridgeTryCall.Value)"
    }
}
$passivePreflightStart = $bridgeTemplateText.IndexOf(
    '.method public static passivePreflight(', [StringComparison]::Ordinal)
$passivePreflightEnd = if ($passivePreflightStart -ge 0) {
    $bridgeTemplateText.IndexOf('.end method', $passivePreflightStart, [StringComparison]::Ordinal)
} else { -1 }
$directBridgeStart = $bridgeTemplateText.IndexOf(
    '.method public static block(', [StringComparison]::Ordinal)
$directBridgeEnd = if ($directBridgeStart -ge 0) {
    $bridgeTemplateText.IndexOf('.end method', $directBridgeStart, [StringComparison]::Ordinal)
} else { -1 }
$resolvedBridgeStart = $bridgeTemplateText.IndexOf(
    '.method public static blockResolved(', [StringComparison]::Ordinal)
$resolvedBridgeEnd = if ($resolvedBridgeStart -ge 0) {
    $bridgeTemplateText.IndexOf('.end method', $resolvedBridgeStart, [StringComparison]::Ordinal)
} else { -1 }
$prepareModelStart = $bridgeTemplateText.IndexOf(
    '.method private static prepareModel(', [StringComparison]::Ordinal)
$prepareModelEnd = if ($prepareModelStart -ge 0) {
    $bridgeTemplateText.IndexOf('.end method', $prepareModelStart, [StringComparison]::Ordinal)
} else { -1 }
$blockModelStart = $bridgeTemplateText.IndexOf(
    '.method public static blockModel(', [StringComparison]::Ordinal)
$blockModelEnd = if ($blockModelStart -ge 0) {
    $bridgeTemplateText.IndexOf('.end method', $blockModelStart, [StringComparison]::Ordinal)
} else { -1 }
if ($passivePreflightStart -lt 0 `
        -or $passivePreflightEnd -le $passivePreflightStart `
        -or $directBridgeStart -le $passivePreflightEnd `
        -or $directBridgeEnd -le $directBridgeStart `
        -or $resolvedBridgeStart -le $directBridgeEnd `
        -or $resolvedBridgeEnd -le $resolvedBridgeStart `
        -or $prepareModelStart -le $resolvedBridgeEnd `
        -or $prepareModelEnd -le $prepareModelStart `
        -or $blockModelStart -le $prepareModelEnd -or $blockModelEnd -le $blockModelStart) {
    throw 'Passive preflight, direct-ID, resolved-model, preparation, and guarded model bridge methods are not independently recognizable.'
}
$passivePreflightMethod = $bridgeTemplateText.Substring(
    $passivePreflightStart, $passivePreflightEnd - $passivePreflightStart)
$directBridgeMethod = $bridgeTemplateText.Substring(
    $directBridgeStart, $directBridgeEnd - $directBridgeStart)
$resolvedBridgeMethod = $bridgeTemplateText.Substring(
    $resolvedBridgeStart, $resolvedBridgeEnd - $resolvedBridgeStart)
$prepareModelMethod = $bridgeTemplateText.Substring(
    $prepareModelStart, $prepareModelEnd - $prepareModelStart)
$blockModelMethod = $bridgeTemplateText.Substring(
    $blockModelStart, $blockModelEnd - $blockModelStart)
$passivePreflightTryContracts = @(
    @('session', 'session_model_exception', 'check-cast p0, {{sessionDescriptor}}'),
    @('cache_lookup', 'cache_lookup_exception', '{{cacheLookupMethod}}'),
    @('cache_factory', 'cache_factory_exception', '{{userCacheFactoryMethod}}'),
    @('cache_placeholder', 'cache_placeholder_exception', '{{userCacheGetOrPutMethod}}'),
    @('prepare', 'bridge_dispatch_exception', 'ThreadsBlockBridge;->prepareModel(')
)
foreach ($passivePreflightTryContract in $passivePreflightTryContracts) {
    $seam = [string]$passivePreflightTryContract[0]
    $stage = [string]$passivePreflightTryContract[1]
    $privateCall = [string]$passivePreflightTryContract[2]
    $prefix = 'preflight_' + $seam
    $tryStart = $passivePreflightMethod.IndexOf(
        ':try_' + $prefix + '_start', [StringComparison]::Ordinal)
    $callIndex = $passivePreflightMethod.IndexOf(
        $privateCall, $tryStart, [StringComparison]::Ordinal)
    $tryEnd = $passivePreflightMethod.IndexOf(
        ':try_' + $prefix + '_end', $callIndex, [StringComparison]::Ordinal)
    $handler = $passivePreflightMethod.IndexOf(
        ':catch_' + $prefix, $tryEnd, [StringComparison]::Ordinal)
    $literal = $passivePreflightMethod.IndexOf(
        'const-string v0, "' + $stage + '"', $handler, [StringComparison]::Ordinal)
    $return = $passivePreflightMethod.IndexOf(
        'return-object v0', $literal, [StringComparison]::Ordinal)
    $catchDirective = '.catch Ljava/lang/Throwable; {:try_' + $prefix `
        + '_start .. :try_' + $prefix + '_end} :catch_' + $prefix
    if ($tryStart -lt 0 -or $callIndex -le $tryStart -or $tryEnd -le $callIndex `
            -or $handler -le $tryEnd -or $literal -le $handler -or $return -le $literal `
            -or (Get-PatchletLiteralCount -Text $passivePreflightMethod `
                -Literal $catchDirective) -ne 1) {
        throw "Passive native preflight seam '$seam' is not one narrow fixed-stage returning region."
    }
}
if ((Get-PatchletLiteralCount -Text $passivePreflightMethod `
        -Literal 'ThreadsBlockBridge;->prepareModel(') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $passivePreflightMethod `
            -Literal 'const-string v0, "placeholder_model_invalid"') -ne 1 `
        -or $passivePreflightMethod.Contains('BridgeCallback;', [StringComparison]::Ordinal) `
        -or $passivePreflightMethod.Contains('MutationCallback;', [StringComparison]::Ordinal) `
        -or $passivePreflightMethod.Contains('{{blockMutationMethod}}', [StringComparison]::Ordinal) `
        -or $passivePreflightMethod.Contains('SharedPreferences', [StringComparison]::Ordinal) `
        -or $passivePreflightMethod.Contains('reserveAttempt', [StringComparison]::Ordinal)) {
    throw 'Passive native preflight must return only shared preparation/fixed stages and perform no callback, persistence, reservation, or mutation.'
}
$nullFallbackIndex = $resolvedBridgeMethod.IndexOf(
    'if-nez p2, :resolved_present', [StringComparison]::Ordinal)
$directIdFallbackIndex = $resolvedBridgeMethod.IndexOf(
    'ThreadsBlockBridge;->block(Landroid/app/Activity;Ljava/lang/Object;Ljava/lang/String;Lthreadsmod/autoblock/BridgeCallback;)V',
    [StringComparison]::Ordinal)
$resolvedCastIndex = $resolvedBridgeMethod.IndexOf(
    'check-cast p2, {{modelDescriptor}}', [StringComparison]::Ordinal)
$resolvedDispatchIndex = $resolvedBridgeMethod.IndexOf(
    'ThreadsBlockBridge;->blockModel(', [StringComparison]::Ordinal)
if ($nullFallbackIndex -lt 0 -or $directIdFallbackIndex -le $nullFallbackIndex `
        -or $resolvedCastIndex -le $directIdFallbackIndex `
        -or $resolvedDispatchIndex -le $resolvedCastIndex `
        -or -not $resolvedBridgeMethod.Contains(
            'const-string v1, "resolved_model_invalid"', [StringComparison]::Ordinal)) {
    throw 'Null resolved models do not fall back to the cache-placeholder direct-ID bridge or invalid opaque models do not fail closed.'
}
$resolvedTryContracts = @(
    @('resolved_session', 'session_model_exception', 'check-cast p1, {{sessionDescriptor}}'),
    @('resolved_model', 'resolved_model_invalid', 'check-cast p2, {{modelDescriptor}}')
)
foreach ($resolvedTryContract in $resolvedTryContracts) {
    $seam = [string]$resolvedTryContract[0]
    $stage = [string]$resolvedTryContract[1]
    $privateInstruction = [string]$resolvedTryContract[2]
    $tryStart = $resolvedBridgeMethod.IndexOf(':try_' + $seam + '_start', [StringComparison]::Ordinal)
    $instructionIndex = $resolvedBridgeMethod.IndexOf(
        $privateInstruction, $tryStart, [StringComparison]::Ordinal)
    $tryEnd = $resolvedBridgeMethod.IndexOf(
        ':try_' + $seam + '_end', $instructionIndex, [StringComparison]::Ordinal)
    $catchDirective = '.catch Ljava/lang/Throwable; {:try_' + $seam + '_start .. :try_' + `
        $seam + '_end} :catch_' + $seam
    $stageLiteral = 'const-string v1, "' + $stage + '"'
    if ($tryStart -lt 0 -or $instructionIndex -le $tryStart -or $tryEnd -le $instructionIndex `
            -or $tryEnd -ge $resolvedDispatchIndex `
            -or (Get-PatchletLiteralCount -Text $resolvedBridgeMethod -Literal $catchDirective) -ne 1 `
            -or (Get-PatchletLiteralCount -Text $resolvedBridgeMethod -Literal $stageLiteral) -ne 1) {
        throw "Resolved-model bridge seam '$seam' is not isolated from model dispatch and callbacks."
    }
}
if ([regex]::Matches($resolvedBridgeMethod, '(?m)^\s*:try_start_\d+\s*$').Count -ne 0 `
        -or [regex]::Matches($resolvedBridgeMethod, '(?m)^\s*:try_end_\d+\s*$').Count -ne 0) {
    throw 'Resolved-model bridge retains a broad synthetic try range around model dispatch.'
}
$sessionTryStartIndex = $directBridgeMethod.IndexOf(
    ':try_session_start', [StringComparison]::Ordinal)
$sessionCastIndex = $directBridgeMethod.IndexOf(
    'check-cast p1, {{sessionDescriptor}}', [StringComparison]::Ordinal)
$sessionTryEndIndex = $directBridgeMethod.IndexOf(
    ':try_session_end', [StringComparison]::Ordinal)
$cacheLookupTryStartIndex = $directBridgeMethod.IndexOf(
    ':try_cache_lookup_start', [StringComparison]::Ordinal)
$cacheLookupIndex = $directBridgeMethod.IndexOf(
    '{{cacheLookupMethod}}', [StringComparison]::Ordinal)
$cacheLookupMoveIndex = $directBridgeMethod.IndexOf(
    'move-result-object v0', $cacheLookupIndex, [StringComparison]::Ordinal)
$cacheLookupTryEndIndex = $directBridgeMethod.IndexOf(
    ':try_cache_lookup_end', [StringComparison]::Ordinal)
$cacheMissIndex = $directBridgeMethod.IndexOf(
    'if-nez v0, :model_ready', $cacheLookupIndex, [StringComparison]::Ordinal)
$cacheFactoryTryStartIndex = $directBridgeMethod.IndexOf(
    ':try_cache_factory_start', [StringComparison]::Ordinal)
$cacheFactoryIndex = $directBridgeMethod.IndexOf(
    '{{userCacheFactoryMethod}}', [StringComparison]::Ordinal)
$cacheFactoryMoveIndex = $directBridgeMethod.IndexOf(
    'move-result-object v0', $cacheFactoryIndex, [StringComparison]::Ordinal)
$cacheFactoryTryEndIndex = $directBridgeMethod.IndexOf(
    ':try_cache_factory_end', [StringComparison]::Ordinal)
$nullBackingIndex = $directBridgeMethod.IndexOf(
    'const/4 v1, 0x0', $cacheFactoryIndex, [StringComparison]::Ordinal)
$cachePlaceholderTryStartIndex = $directBridgeMethod.IndexOf(
    ':try_cache_placeholder_start', [StringComparison]::Ordinal)
$cacheGetOrPutIndex = $directBridgeMethod.IndexOf(
    '{{userCacheGetOrPutMethod}}', [StringComparison]::Ordinal)
$cachePlaceholderMoveIndex = $directBridgeMethod.IndexOf(
    'move-result-object v0', $cacheGetOrPutIndex, [StringComparison]::Ordinal)
$cachePlaceholderTryEndIndex = $directBridgeMethod.IndexOf(
    ':try_cache_placeholder_end', [StringComparison]::Ordinal)
$placeholderGuardIndex = $directBridgeMethod.IndexOf(
    'if-nez v0, :model_ready', $cacheGetOrPutIndex, [StringComparison]::Ordinal)
$placeholderFailureIndex = $directBridgeMethod.IndexOf(
    'const-string v1, "placeholder_model_invalid"', [StringComparison]::Ordinal)
$directModelDispatchIndex = $directBridgeMethod.IndexOf(
    'ThreadsBlockBridge;->blockModel(', [StringComparison]::Ordinal)
if ($sessionTryStartIndex -lt 0 -or $sessionCastIndex -le $sessionTryStartIndex `
        -or $sessionTryEndIndex -le $sessionCastIndex `
        -or $cacheLookupTryStartIndex -le $sessionTryEndIndex `
        -or $cacheLookupIndex -le $cacheLookupTryStartIndex `
        -or $cacheLookupMoveIndex -le $cacheLookupIndex `
        -or $cacheLookupTryEndIndex -le $cacheLookupMoveIndex `
        -or $cacheMissIndex -le $cacheLookupTryEndIndex `
        -or $cacheFactoryTryStartIndex -le $cacheMissIndex `
        -or $cacheFactoryIndex -le $cacheFactoryTryStartIndex `
        -or $cacheFactoryMoveIndex -le $cacheFactoryIndex `
        -or $cacheFactoryTryEndIndex -le $cacheFactoryMoveIndex `
        -or $nullBackingIndex -le $cacheFactoryTryEndIndex `
        -or $cachePlaceholderTryStartIndex -le $nullBackingIndex `
        -or $cacheGetOrPutIndex -le $cachePlaceholderTryStartIndex `
        -or $cachePlaceholderMoveIndex -le $cacheGetOrPutIndex `
        -or $cachePlaceholderTryEndIndex -le $cachePlaceholderMoveIndex `
        -or $placeholderGuardIndex -le $cachePlaceholderTryEndIndex `
        -or $placeholderFailureIndex -le $placeholderGuardIndex `
        -or $directModelDispatchIndex -le $placeholderFailureIndex `
        -or $directBridgeMethod.Contains(':try_dispatch_', [StringComparison]::Ordinal) `
        -or $directBridgeMethod.Contains(
            'const-string v1, "bridge_dispatch_exception"', [StringComparison]::Ordinal) `
        -or $directBridgeMethod.Contains(
            'const-string v1, "bridge_exception"', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $directBridgeMethod `
            -Literal '{{cacheLookupMethod}}') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $directBridgeMethod `
            -Literal '{{userCacheFactoryMethod}}') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $directBridgeMethod `
            -Literal '{{userCacheGetOrPutMethod}}') -ne 1) {
    throw 'Direct-ID bridge does not use narrow session/cache/factory/getOrPut regions, a closed placeholder failure, and an uncaught model dispatch.'
}
$bridgeTryContracts = @(
    @('session', 'session_model_exception'),
    @('cache_lookup', 'cache_lookup_exception'),
    @('cache_factory', 'cache_factory_exception'),
    @('cache_placeholder', 'cache_placeholder_exception')
)
foreach ($bridgeTryContract in $bridgeTryContracts) {
    $seam = [string]$bridgeTryContract[0]
    $stage = [string]$bridgeTryContract[1]
    $catchDirective = '.catch Ljava/lang/Throwable; {:try_' + $seam + '_start .. :try_' + `
        $seam + '_end} :catch_' + $seam
    $handler = ':catch_' + $seam + "`n    move-exception v0`n`n    const-string v1, `"" + `
        $stage + "`"`n`n    invoke-static {p3, p2, v1}, " + `
        'Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V'
    if ((Get-PatchletLiteralCount -Text $directBridgeMethod -Literal $catchDirective) -ne 1 `
            -or (Get-PatchletLiteralCount -Text $directBridgeMethod -Literal $handler) -ne 1) {
        throw "Direct-ID bridge seam '$seam' is not bounded by one exact Throwable range and fixed '$stage' callback."
    }
    $tryStart = $directBridgeMethod.IndexOf(':try_' + $seam + '_start', [StringComparison]::Ordinal)
    $tryEnd = $directBridgeMethod.IndexOf(':try_' + $seam + '_end', $tryStart, [StringComparison]::Ordinal)
    $tryBody = $directBridgeMethod.Substring($tryStart, $tryEnd - $tryStart)
    if ($tryBody.Contains('BridgeCallbackDispatcher;', [StringComparison]::Ordinal) `
            -or $tryBody.Contains('BridgeCallback;->', [StringComparison]::Ordinal)) {
        throw "Direct-ID bridge seam '$seam' catches callback delivery instead of only the private seam."
    }
}
if ((Get-PatchletLiteralCount -Text $directBridgeMethod `
        -Literal 'invoke-static {p3, p2, v1}, Lthreadsmod/autoblock/BridgeCallbackDispatcher;->failure') -ne 5) {
    throw 'Direct-ID bridge must emit exactly four local private-seam failures plus one invalid-placeholder failure.'
}
$bridgeFailureStages = @([regex]::Matches(
        $bridgeTemplateText + "`n" + $mutationTemplateText,
        'const-string\s+v\d+,\s+"([a-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
foreach ($bridgeFailureStage in $bridgeFailureStages) {
    if ($bridgeFailureStage -ne 'already_blocked_success' `
            -and $expectedDiagnosticInputStages -notcontains $bridgeFailureStage) {
        throw "Bridge callback emits a stage outside BlockDiagnostic's closed map: $bridgeFailureStage"
    }
}
$modelIdIndex = $prepareModelMethod.IndexOf('{{authorIdMethod}}', [StringComparison]::Ordinal)
$targetEqualityIndex = $prepareModelMethod.IndexOf(
    'invoke-virtual {p1, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z',
    [StringComparison]::Ordinal)
$alreadyBlockedIndex = $prepareModelMethod.IndexOf(
    '{{alreadyBlockedMethod}}', [StringComparison]::Ordinal)
$successSentinelIndex = $prepareModelMethod.IndexOf(
    'const-string v0, "already_blocked_success"', [StringComparison]::Ordinal)
$mismatchIndex = $prepareModelMethod.IndexOf(
    'const-string v0, "model_id_mismatch"', [StringComparison]::Ordinal)
$nativeMutationIndex = $blockModelMethod.IndexOf(
    '{{blockMutationMethod}}', [StringComparison]::Ordinal)
if ($modelIdIndex -lt 0 -or $targetEqualityIndex -le $modelIdIndex `
        -or $alreadyBlockedIndex -le $targetEqualityIndex `
        -or $successSentinelIndex -le $alreadyBlockedIndex `
        -or $mismatchIndex -le $successSentinelIndex `
        -or $nativeMutationIndex -lt 0 `
        -or (Get-PatchletLiteralCount -Text $bridgeTemplateText `
            -Literal '{{blockMutationMethod}}') -ne 1) {
    throw 'Bridge preparation does not validate model ID == immutable target before already-blocked success and mutation.'
}
$prepareModelTryContracts = @(
    @('model_id', 'model_id_exception', '{{authorIdMethod}}'),
    @('already_blocked', 'already_blocked_exception', '{{alreadyBlockedMethod}}')
)
foreach ($prepareModelTryContract in $prepareModelTryContracts) {
    $seam = [string]$prepareModelTryContract[0]
    $stage = [string]$prepareModelTryContract[1]
    $privateCall = [string]$prepareModelTryContract[2]
    $catchDirective = '.catch Ljava/lang/Throwable; {:try_' + $seam + '_start .. :try_' + `
        $seam + '_end} :catch_' + $seam
    $tryStart = $prepareModelMethod.IndexOf(':try_' + $seam + '_start', [StringComparison]::Ordinal)
    $privateCallIndex = $prepareModelMethod.IndexOf($privateCall, $tryStart, [StringComparison]::Ordinal)
    $tryEnd = $prepareModelMethod.IndexOf(':try_' + $seam + '_end', $privateCallIndex, [StringComparison]::Ordinal)
    $handlerIndex = $prepareModelMethod.IndexOf(':catch_' + $seam, $tryEnd, [StringComparison]::Ordinal)
    $handlerLiteralIndex = $prepareModelMethod.IndexOf(
        'const-string v0, "' + $stage + '"', $handlerIndex, [StringComparison]::Ordinal)
    $handlerReturnIndex = $prepareModelMethod.IndexOf(
        'return-object v0', $handlerLiteralIndex, [StringComparison]::Ordinal)
    if ($tryStart -lt 0 -or $privateCallIndex -le $tryStart -or $tryEnd -le $privateCallIndex `
            -or $handlerIndex -le $tryEnd -or $handlerLiteralIndex -le $handlerIndex `
            -or $handlerReturnIndex -le $handlerLiteralIndex `
            -or (Get-PatchletLiteralCount -Text $prepareModelMethod -Literal $catchDirective) -ne 1) {
        throw "Model-preparation seam '$seam' is not bounded by one exact Throwable range and fixed '$stage' return."
    }
    $tryBody = $prepareModelMethod.Substring($tryStart, $tryEnd - $tryStart)
    if ((Get-PatchletLiteralCount -Text $tryBody -Literal $privateCall) -ne 1 `
            -or $tryBody.Contains('onBridgeFailure', [StringComparison]::Ordinal) `
            -or $tryBody.Contains('onBridgeSuccess', [StringComparison]::Ordinal) `
            -or $tryBody.Contains('MutationCallback;-><init>', [StringComparison]::Ordinal)) {
        throw "Model-preparation seam '$seam' catches work outside its reviewed private call."
    }
}
if ($prepareModelMethod.Contains('BridgeCallback;', [StringComparison]::Ordinal) `
        -or $prepareModelMethod.Contains('MutationCallback;', [StringComparison]::Ordinal) `
        -or $prepareModelMethod.Contains('{{blockMutationMethod}}', [StringComparison]::Ordinal)) {
    throw 'Model preparation must remain a callback-free and mutation-free value-returning seam.'
}
$blockModelTryContracts = @(
    @('dispatch', 'bridge_dispatch_exception', 'ThreadsBlockBridge;->prepareModel('),
    @('mutation', 'mutation_exception', '{{blockMutationMethod}}')
)
foreach ($blockModelTryContract in $blockModelTryContracts) {
    $seam = [string]$blockModelTryContract[0]
    $stage = [string]$blockModelTryContract[1]
    $privateCall = [string]$blockModelTryContract[2]
    $catchDirective = '.catch Ljava/lang/Throwable; {:try_' + $seam + '_start .. :try_' + `
        $seam + '_end} :catch_' + $seam
    $tryStart = $blockModelMethod.IndexOf(':try_' + $seam + '_start', [StringComparison]::Ordinal)
    $privateCallIndex = $blockModelMethod.IndexOf($privateCall, $tryStart, [StringComparison]::Ordinal)
    $tryEnd = $blockModelMethod.IndexOf(':try_' + $seam + '_end', $privateCallIndex, [StringComparison]::Ordinal)
    $handlerIndex = $blockModelMethod.IndexOf(':catch_' + $seam, $tryEnd, [StringComparison]::Ordinal)
    $handlerLiteralIndex = $blockModelMethod.IndexOf(
        'const-string v1, "' + $stage + '"', $handlerIndex, [StringComparison]::Ordinal)
    $handlerCallbackIndex = $blockModelMethod.IndexOf(
        'BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V',
        $handlerLiteralIndex,
        [StringComparison]::Ordinal)
    if ($tryStart -lt 0 -or $privateCallIndex -le $tryStart -or $tryEnd -le $privateCallIndex `
            -or $handlerIndex -le $tryEnd -or $handlerLiteralIndex -le $handlerIndex `
            -or $handlerCallbackIndex -le $handlerLiteralIndex `
            -or (Get-PatchletLiteralCount -Text $blockModelMethod -Literal $catchDirective) -ne 1) {
        throw "Block-model bridge seam '$seam' is not bounded by one exact Throwable range and fixed '$stage' callback."
    }
    $tryBody = $blockModelMethod.Substring($tryStart, $tryEnd - $tryStart)
    if ((Get-PatchletLiteralCount -Text $tryBody -Literal $privateCall) -ne 1 `
            -or $tryBody.Contains('onBridgeFailure', [StringComparison]::Ordinal) `
            -or $tryBody.Contains('onBridgeSuccess', [StringComparison]::Ordinal) `
            -or $tryBody.Contains('MutationCallback;-><init>', [StringComparison]::Ordinal)) {
        throw "Block-model bridge seam '$seam' catches work outside its reviewed private call."
    }
}
if ((Get-PatchletLiteralCount -Text $blockModelMethod `
        -Literal 'new-instance v3, Lthreadsmod/autoblock/MutationCallback;') -ne 1 `
        -or $blockModelMethod.IndexOf(
            'new-instance v3, Lthreadsmod/autoblock/MutationCallback;',
            [StringComparison]::Ordinal) -ge $blockModelMethod.IndexOf(
            ':try_mutation_start', [StringComparison]::Ordinal)) {
    throw 'Mutation callback construction must remain outside the native mutation try region.'
}
$preparedFailureStart = $blockModelMethod.IndexOf(
    "`n    :prepared_failure`n", [StringComparison]::Ordinal)
$submitMutationStart = $blockModelMethod.IndexOf(
    "`n    :submit_mutation`n", $preparedFailureStart + 1,
    [StringComparison]::Ordinal)
$preparedFailureBody = if ($preparedFailureStart -ge 0 `
        -and $submitMutationStart -gt $preparedFailureStart) {
    $blockModelMethod.Substring(
        $preparedFailureStart, $submitMutationStart - $preparedFailureStart)
} else { '' }
if ((Get-PatchletLiteralCount -Text $blockModelMethod `
        -Literal 'const-string v1, "already_blocked_success"') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $preparedFailureBody `
            -Literal 'BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V') -ne 1) {
    throw 'Prepared success/error values do not route outside the guarded preparation range.'
}
if ((Get-PatchletLiteralCount -Text $bridgeTemplateText `
        -Literal 'BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V') -ne 10 `
        -or (Get-PatchletLiteralCount -Text $bridgeTemplateText `
            -Literal 'BridgeCallbackDispatcher;->success(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;)V') -ne 1 `
        -or $bridgeTemplateText.Contains(
            'Lthreadsmod/autoblock/BridgeCallback;->', [StringComparison]::Ordinal)) {
    throw 'Every pre-mutation bridge result must cross the asynchronous callback dispatcher.'
}
foreach ($dispatcherCall in @(
        'BridgeCallbackDispatcher;->started(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;)V',
        'BridgeCallbackDispatcher;->failure(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;Ljava/lang/String;)V',
        'BridgeCallbackDispatcher;->success(Lthreadsmod/autoblock/BridgeCallback;Ljava/lang/String;)V')) {
    if ((Get-PatchletLiteralCount -Text $mutationTemplateText -Literal $dispatcherCall) -ne 1) {
        throw "Mutation callback does not use the exact asynchronous dispatcher call: $dispatcherCall"
    }
}
if ($mutationTemplateText.Contains(
        'Lthreadsmod/autoblock/BridgeCallback;->', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $joinedProductionAssets `
            -Literal 'callback.onBridgeStarted(') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $joinedProductionAssets `
            -Literal 'callback.onBridgeFailure(') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $joinedProductionAssets `
            -Literal 'callback.onBridgeSuccess(') -ne 1 `
        -or -not $dispatcherCode.Contains(
            'if(!MAIN.post(newDelivery(callback,targetId,stage,kind))){thrownewIllegalStateException();}',
            [StringComparison]::Ordinal) `
        -or $dispatcherCode.Contains('catch(', [StringComparison]::Ordinal)) {
    throw 'Bridge callback delivery is not exclusively firewalled through fail-closed asynchronous posting.'
}
$reserveAttemptCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticbooleanreserveAttempt(Contextcontext,Stringviewer,booleanautomatic)' `
    -Label 'reserveAttempt'
$reserveEditorIndex = $reserveAttemptCode.IndexOf(
    'SharedPreferences.Editoreditor=p.edit().putString(attemptsKey(viewer),encodeEvents(events)).remove(automaticAttemptsKey(viewer));',
    [StringComparison]::Ordinal)
$reservePassiveLimitsIndex = $reserveAttemptCode.IndexOf(
    'BlockLimitslimits=BlockLimitsStore.load(context);', $reserveEditorIndex,
    [StringComparison]::Ordinal)
$reservePassiveDeadlineIndex = $reserveAttemptCode.IndexOf(
    'longpaceUntil=now+randomDelay(limits.passiveMinDelayMs(),limits.passiveMaxDelayMs());',
    $reservePassiveLimitsIndex, [StringComparison]::Ordinal)
$reservePassiveWriteIndex = $reserveAttemptCode.IndexOf(
    'editor.putLong(paceKey(viewer),paceUntil);', $reservePassiveDeadlineIndex,
    [StringComparison]::Ordinal)
$reserveCommitIndex = Get-JavaTopLevelLiteralIndex -Text $reserveAttemptCode `
    -Literal 'returneditor.commit();'
if (-not $reserveAttemptCode.Contains(
        'if(automatic&&!BlockLimitsStore.isValid(context)){returnfalse;}',
        [StringComparison]::Ordinal) `
        -or -not $reserveAttemptCode.Contains(
            'if(automatic&&millisUntilPassivePaceAllowed(context,viewer)>0L){returnfalse;}',
            [StringComparison]::Ordinal) `
        -or -not $reserveAttemptCode.Contains(
            'EventHistoryeventHistory=readEvents(p,attemptsKey(viewer),now);',
            [StringComparison]::Ordinal) `
        -or -not $reserveAttemptCode.Contains(
            'while(events.size()>MAX_HISTORY_EVENTS){events.remove(0);}',
            [StringComparison]::Ordinal) `
        -or $reserveEditorIndex -lt 0 `
        -or $reservePassiveLimitsIndex -le $reserveEditorIndex `
        -or $reservePassiveDeadlineIndex -le $reservePassiveLimitsIndex `
        -or $reservePassiveWriteIndex -le $reservePassiveDeadlineIndex `
        -or $reserveCommitIndex -le $reservePassiveWriteIndex `
        -or $reserveAttemptCode.Contains('FOREGROUND_RUN_LOCK', [StringComparison]::Ordinal) `
        -or $reserveAttemptCode.Contains('rateAllowed(', [StringComparison]::Ordinal) `
        -or $reserveAttemptCode.Contains('automaticPerHour(', [StringComparison]::Ordinal) `
        -or $reserveAttemptCode.Contains('targetBudget(', [StringComparison]::Ordinal) `
        -or $reserveAttemptCode.Contains('totalPerHour(', [StringComparison]::Ordinal) `
        -or $reserveAttemptCode.Contains('totalPerDay(', [StringComparison]::Ordinal)) {
    throw 'Attempt reservation does not persist every attempt and atomically add only passive pacing from the validated two-delay pair.'
}
$passiveReservationBranchCode = Get-JavaBlockBody -Text $reserveAttemptCode `
    -Anchor 'if(automatic)' -StartIndex $reserveEditorIndex `
    -Label 'reserveAttempt passive-only pacing branch'
if ((Get-PatchletLiteralCount -Text $manualDrainCode `
            -Literal 'reserveAttempt(activity,viewer,false)') -ne 1 `
        -or -not $passiveReservationBranchCode.Contains(
            'BlockLimitslimits=BlockLimitsStore.load(context);',
            [StringComparison]::Ordinal) `
        -or -not $passiveReservationBranchCode.Contains(
            'randomDelay(limits.passiveMinDelayMs(),limits.passiveMaxDelayMs())',
            [StringComparison]::Ordinal) `
        -or -not $passiveReservationBranchCode.Contains(
            'editor.putLong(paceKey(viewer),paceUntil);', [StringComparison]::Ordinal)) {
    throw 'Only automatic passive reservation may read the two-delay pair or write a pacing deadline; manual reservation must remain unpaced and uncapped.'
}
if (-not $stateText.Contains('existing == null && queue.size() >= MAX_QUEUE', [StringComparison]::Ordinal) `
        -or -not $stateText.Contains('STATE_RUNNING.equals(existing.state)', [StringComparison]::Ordinal)) {
    throw 'Manual queue saturation/active-item preservation is not pinned.'
}
if (-not $controllerText.Contains('boolean terminal = UI_SUCCESS.equals(operation.state)', [StringComparison]::Ordinal) `
        -or $controllerText.Contains('STALE_OPERATION_MS', [StringComparison]::Ordinal)) {
    throw 'Inline controller may prune active queued or in-flight operations.'
}
$blockRunIndex = $schedulerText.IndexOf(
    'private static final class BlockRun', [StringComparison]::Ordinal)
$manualRunIndex = $schedulerText.IndexOf(
    'private static final class ManualBlockRun', [StringComparison]::Ordinal)
if ($blockRunIndex -lt 0 -or $manualRunIndex -le $blockRunIndex) {
    throw 'Automatic/manual scheduler class boundaries are not recognizable.'
}
$blockRunText = $schedulerText.Substring($blockRunIndex, $manualRunIndex - $blockRunIndex)
$manualPreemptIndex = $blockRunText.IndexOf(
    'if (ModStateStore.nextQueued(activity, viewer) != null)', [StringComparison]::Ordinal)
$passivePreflightIndex = $blockRunText.IndexOf(
    'ThreadsBlockBridge.passivePreflight(', [StringComparison]::Ordinal)
if ($manualPreemptIndex -lt 0 -or $passivePreflightIndex -lt 0 `
        -or $manualPreemptIndex -gt $passivePreflightIndex) {
    throw 'User-requested inline work does not preempt passive work before native preflight.'
}
foreach ($requiredTransition in @(
    'finishForForegroundChange(',
    'releasePassiveSchedulerForContextChange(activity, viewer)',
    'schedulerMutationInFlight',
    'isSchedulerOwner(schedulerToken)',
    'Activity host = getForegroundActivity()',
    'requestForceRefresh(viewer)',
    'if (!viewer.equals(liveViewer) || host != activity)',
    'if (userSession == null)',
    'currentViewer = null',
    'foreground = false'
)) {
    if (-not $schedulerText.Contains($requiredTransition, [StringComparison]::Ordinal)) {
        throw "Activity-replacement recovery is missing transition: $requiredTransition"
    }
}
if ($schedulerText.Contains('forceRefreshPending', [StringComparison]::Ordinal)) {
    throw 'Forced-refresh intent is global instead of viewer-scoped.'
}
if (-not $schedulerText.Contains(
        'LinkedHashSet<String> FORCE_REFRESH_VIEWERS', [StringComparison]::Ordinal) `
        -or -not $schedulerText.Contains(
        'return FORCE_REFRESH_VIEWERS.remove(viewer)', [StringComparison]::Ordinal) `
        -or -not $schedulerText.Contains(
        'preserved every existing viewer intent', [StringComparison]::Ordinal) `
        -or $schedulerText.Contains(
        'FORCE_REFRESH_VIEWERS.remove(removable)', [StringComparison]::Ordinal) `
        -or $schedulerText.Contains(
        'private static String forceRefreshViewer', [StringComparison]::Ordinal)) {
    throw 'Per-viewer forced-refresh requests can overwrite one another.'
}
foreach ($requiredSafetyState in @(
    'EventHistory.invalid()',
    'if (value > now)',
    'readRetryDeadline(',
        'persistRetryDeadline(',
        '.putLong(retryKey(viewer), deadline).commit()',
        'statusKey(viewer)',
        'millisUntilPassivePaceAllowed(',
        'BlockLimitsStore.isValid('
)) {
    if (-not $schedulerText.Contains($requiredSafetyState, [StringComparison]::Ordinal)) {
        throw "Scheduler fail-closed/configuration proof is missing: $requiredSafetyState"
    }
}
if ($schedulerText.Contains('.getLong(retryKey(viewer)', [StringComparison]::Ordinal) `
        -or $schedulerText.Contains('putLong(retryKey(viewer), now + FAILURE_BACKOFF_MS)', [StringComparison]::Ordinal) `
        -or $schedulerText.Contains('putLong(retryKey(viewer), System.currentTimeMillis()', [StringComparison]::Ordinal)) {
    throw 'Retry deadlines bypass strict typed validation or verified commit.'
}
$viewerKeyBodies = [ordered]@{
    'privatestaticStringattemptsKey(Stringviewer)' = 'return"attempts_threads_"+viewer;'
    'privatestaticStringautomaticAttemptsKey(Stringviewer)' = 'return"automatic_attempts_threads_"+viewer;'
    'privatestaticStringpaceKey(Stringviewer)' = 'return"pace_until_threads_"+viewer;'
    'privatestaticStringretryKey(Stringviewer)' = 'return"retry_threads_"+viewer;'
    'privatestaticStringstatusKey(Stringviewer)' = 'returnisDecimalId(viewer)&&viewer.length()<=24?KEY_STATUS+"_threads_"+viewer:KEY_STATUS+"_general";'
}
foreach ($keySignature in $viewerKeyBodies.Keys) {
    $keyBody = Get-JavaBlockBody -Text $schedulerCode -Anchor $keySignature `
        -Label "viewer-scoped scheduler key $keySignature"
    if ($keyBody -ne $viewerKeyBodies[$keySignature]) {
        throw "Scheduler key derivation is not exactly viewer-scoped: $keySignature"
    }
}
$doneKeyBody = Get-JavaBlockBody -Text $stateCode `
    -Anchor 'privatestaticStringdoneKey(StringviewerId)' `
    -Label 'viewer-scoped completed-target key'
if ($doneKeyBody -ne 'return"done_threads_"+viewerId;' `
        -or $schedulerCode.Contains('doneKey(', [StringComparison]::Ordinal)) {
    throw 'ModStateStore must solely own exact viewer-scoped done_threads key derivation.'
}
$paceWaitCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticlongmillisUntilPassivePaceAllowed(Contextcontext,Stringviewer)' `
    -Label 'millisUntilPassivePaceAllowed'
$readRetryCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticDeadlineStatereadRetryDeadline(SharedPreferencespreferences,Stringviewer,longnow)' `
    -Label 'readRetryDeadline'
$persistRetryCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticbooleanpersistRetryDeadline(Contextcontext,Stringviewer)' `
    -Label 'persistRetryDeadline'
$clearRetryCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticbooleanclearRetryDeadline(Contextcontext,Stringviewer)' `
    -Label 'clearRetryDeadline'
$setStatusCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticvoidsetStatus(Contextcontext,Stringviewer,Stringstatus)' `
    -Label 'setStatus'
$getStatusCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'publicstaticStringgetStatus(Contextcontext)' -Label 'getStatus current viewer'
$getScopedStatusCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'staticStringgetStatus(Contextcontext,Stringviewer)' -Label 'getStatus scoped viewer'
$isEnabledCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'publicstaticbooleanisEnabled(Contextcontext)' -Label 'isEnabled'
$snapshotCode = Get-JavaBlockBody -Text $stateCode `
    -Anchor 'publicstaticsynchronizedSnapshotsnapshot(Contextcontext,StringviewerId)' `
    -Label 'ModStateStore.snapshot scoped viewer'
if ($getStatusCode -ne 'returngetStatus(context,getCurrentViewer());' `
        -or -not $getScopedStatusCode.Contains(
            'preferences.getString(statusKey(viewer),fallback)', [StringComparison]::Ordinal) `
        -or -not $snapshotCode.Contains(
            'AutoBlockSync.getStatus(context,viewer)', [StringComparison]::Ordinal) `
        -or -not $isEnabledCode.Contains(
            'returncontext!=null;', [StringComparison]::Ordinal) `
        -or $isEnabledCode.Contains('prefs(', [StringComparison]::Ordinal) `
        -or ($schedulerCode + $stateCode).Contains(
            '.putString(KEY_STATUS,', [StringComparison]::Ordinal) `
        -or $stateCode.Contains('p.getString("status",', [StringComparison]::Ordinal)) {
    throw 'Activity status is not read, written, and failed closed through one viewer-scoped key contract, or passive blocking is not unconditionally enabled.'
}
foreach ($scopedUse in @(
    @($reserveAttemptCode, 'readEvents(p,attemptsKey(viewer),now)', 'reservation total history'),
    @($reserveAttemptCode, '.putString(attemptsKey(viewer),encodeEvents(events)).remove(automaticAttemptsKey(viewer))', 'attempt history plus retired automatic-history deletion'),
    @($reserveAttemptCode, 'editor.putLong(paceKey(viewer),paceUntil)', 'passive pacing deadline'),
    @($paceWaitCode, 'readDeadline(p,paceKey(viewer),now,maximumPace)', 'pace deadline'),
    @($readRetryCode, 'readDeadline(preferences,retryKey(viewer),now,FAILURE_BACKOFF_MS+5000L)', 'retry deadline read'),
    @($persistRetryCode, '.putLong(retryKey(viewer),deadline).commit()', 'retry deadline commit'),
    @($clearRetryCode, '.remove(retryKey(viewer)).commit()', 'retry deadline clear'),
    @($setStatusCode, '.putString(statusKey(viewer),safe)', 'viewer status')
)) {
    if (-not $scopedUse[0].Contains($scopedUse[1], [StringComparison]::Ordinal)) {
        throw "Scheduler persistence bypasses its viewer-scoped key: $($scopedUse[2])"
    }
}

$startCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticvoidstart(Activityactivity,ObjectuserSession,Stringviewer,booleanforceRefresh)' `
    -Label 'start'
Assert-JavaBranchWake -MethodBody $startCode `
    -Condition 'if(!BlockLimitsStore.isValid(activity))' `
    -WakeCall 'scheduleManualDrain(SAFETY_REVIEW_WAKE_MS);' `
    -Label 'automatic invalid limits review'
Assert-JavaBranchWake -MethodBody $startCode `
    -Condition 'if(ModStateStore.nextQueued(activity,viewer)!=null)' `
    -WakeCall 'scheduleManualDrain(0L);' -Label 'manual preemption'
Assert-JavaBranchWake -MethodBody $startCode -Condition 'if(!retry.valid)' `
    -WakeCall 'scheduleManualDrain(SAFETY_REVIEW_WAKE_MS);' `
    -Label 'automatic invalid backoff review'
Assert-JavaBranchWake -MethodBody $startCode -Condition 'if(retryAt>now)' `
    -WakeCall 'scheduleManualDrain(retryAt-now+1000L);' `
    -Label 'automatic failure backoff'
Assert-JavaBranchWake -MethodBody $startCode -Condition 'if(paceWait>0L)' `
    -WakeCall 'scheduleManualDrain(paceWait);' -Label 'automatic initial pacing'

Assert-JavaBranchWake -MethodBody $automaticBeginCode `
    -Condition 'if(!BlockLimitsStore.isValid(activity))' `
    -WakeCall 'scheduleManualDrain(SAFETY_REVIEW_WAKE_MS);' `
    -Label 'automatic live invalid limits review'
Assert-JavaBranchWake -MethodBody $automaticBeginCode -Condition 'if(paceWait>0L)' `
    -WakeCall 'finishAndResume(' -Label 'automatic fresh-drain pacing'

Assert-JavaBranchWake -MethodBody $manualDrainCode -Condition 'if(!retry.valid)' `
    -WakeCall 'scheduleManualDrain(SAFETY_REVIEW_WAKE_MS);' `
    -Label 'manual invalid backoff review'
Assert-JavaBranchWake -MethodBody $manualDrainCode -Condition 'if(retry.value>now)' `
    -WakeCall 'scheduleManualDrain(retryAt-now+1000L);' `
    -Label 'manual failure backoff'
Assert-JavaBranchWake -MethodBody $manualDrainCode `
    -Condition 'if(!ModStateStore.markManualStarted(activity,viewer,item.targetId))' `
    -WakeCall 'releaseSchedulerAndContinue(schedulerToken,activity,viewer,FAILURE_BACKOFF_MS+1000L,true);' `
    -Label 'manual queue-start persistence backoff'
Assert-JavaBranchWake -MethodBody $manualDrainCode `
    -Condition 'if(!reserveAttempt(activity,viewer,false))' `
    -WakeCall 'releaseSchedulerAndContinue(schedulerToken,activity,viewer,FAILURE_BACKOFF_MS+1000L,true);' `
    -Label 'manual reservation failure backoff'
foreach ($forbiddenManualPacing in @(
        'BlockLimitsStore.',
        'millisUntilPassivePaceAllowed(',
        'paceKey(',
        'randomDelay(')) {
    if ($manualDrainCode.Contains($forbiddenManualPacing, [StringComparison]::Ordinal)) {
        throw "Manual inline work must bypass passive pacing configuration: $forbiddenManualPacing"
    }
}

$automaticFailureCode = Get-JavaBlockBody -Text $blockRunCode `
    -Anchor 'privatevoidhandleFailure(StringtargetId,Stringstage)' `
    -Label 'BlockRun.handleFailure'
$automaticFailureWake = Get-JavaTopLevelLiteralIndex -Text $automaticFailureCode `
    -Literal 'scheduleManualDrain(FAILURE_BACKOFF_MS+1000L);'
if ($automaticFailureWake -lt 0 `
        -or -not $automaticFailureCode.Contains(
            'if("completion_persistence".equals(stage)){handleCompletionPersistence(targetId);return;}',
            [StringComparison]::Ordinal) `
        -or $automaticFailureCode.IndexOf(
            'handleCompletionPersistence(targetId);', [StringComparison]::Ordinal) `
            -gt $automaticFailureCode.IndexOf(
                'persistRetryDeadline(activity,viewer);', [StringComparison]::Ordinal)) {
    throw 'Automatic callback failure does not schedule its persisted backoff wake.'
}
$automaticStartedCode = Get-JavaBlockBody -Text $blockRunCode `
    -Anchor 'publicvoidonBridgeStarted(finalStringtargetId)' `
    -Label 'BlockRun.onBridgeStarted'
$automaticSuccessCode = Get-JavaBlockBody -Text $blockRunCode `
    -Anchor 'publicvoidonBridgeSuccess(finalStringtargetId)' -Label 'BlockRun.onBridgeSuccess'
$automaticSuccessRunCode = $automaticSuccessCode
$automaticBridgeFailureCode = Get-JavaBlockBody -Text $blockRunCode `
    -Anchor 'publicvoidonBridgeFailure(finalStringtargetId,finalStringstage)' `
    -Label 'BlockRun.onBridgeFailure'
$automaticUncertainCode = Get-JavaBlockBody -Text $blockRunCode `
    -Anchor 'privatevoidhandleUncertainMutation(StringtargetId)' `
    -Label 'BlockRun.handleUncertainMutation'
$manualStartedCode = Get-JavaBlockBody -Text $manualRunCode `
    -Anchor 'publicvoidonBridgeStarted(finalStringid)' `
    -Label 'ManualBlockRun.onBridgeStarted'
$manualSuccessCode = Get-JavaBlockBody -Text $manualRunCode `
    -Anchor 'publicvoidonBridgeSuccess(finalStringid)' -Label 'ManualBlockRun.onBridgeSuccess'
$manualSuccessRunCode = $manualSuccessCode
$manualBridgeFailureCode = Get-JavaBlockBody -Text $manualRunCode `
    -Anchor 'publicvoidonBridgeFailure(finalStringid,finalStringstage)' `
    -Label 'ManualBlockRun.onBridgeFailure'
$manualFailCode = Get-JavaBlockBody -Text $manualRunCode `
    -Anchor 'privatevoidfail(Stringstage)' -Label 'ManualBlockRun.fail'
$manualUncertainCode = Get-JavaBlockBody -Text $manualRunCode `
    -Anchor 'privatevoidabandonUncertainMutation()' `
    -Label 'ManualBlockRun.abandonUncertainMutation'
foreach ($bridgeCallbackContract in @(
        @('BlockRun.onBridgeStarted', $automaticStartedCode),
        @('BlockRun.onBridgeSuccess', $automaticSuccessCode),
        @('BlockRun.onBridgeFailure', $automaticBridgeFailureCode),
        @('ManualBlockRun.onBridgeStarted', $manualStartedCode),
        @('ManualBlockRun.onBridgeSuccess', $manualSuccessCode),
        @('ManualBlockRun.onBridgeFailure', $manualBridgeFailureCode))) {
    $bridgeCallbackCode = [string]$bridgeCallbackContract[1]
    if ($bridgeCallbackCode.Contains('MAIN.post(', [StringComparison]::Ordinal)) {
        throw "Bridge callback '$($bridgeCallbackContract[0])' redundantly posts after dispatcher delivery."
    }
}
if (-not $automaticStartedCode.StartsWith(
        'if(!isCurrent(targetId)){return;}started=true;',
        [StringComparison]::Ordinal) `
        -or -not [string]::Equals(
            $automaticBridgeFailureCode,
            'handleFailure(targetId,stage);',
            [StringComparison]::Ordinal) `
        -or -not $automaticSuccessCode.StartsWith(
            'if(!isCurrent(targetId)){return;}booleancompletionSaved=false;',
            [StringComparison]::Ordinal) `
        -or -not $manualStartedCode.StartsWith(
            'if(!isCurrent(id)||started){return;}started=true;dispatchManualStarted(viewer,targetId);',
            [StringComparison]::Ordinal) `
        -or -not $manualSuccessCode.StartsWith(
            'if(!isCurrent(id)||!finished.compareAndSet(false,true)){return;}booleancompletionSaved=false;',
            [StringComparison]::Ordinal) `
        -or -not [string]::Equals(
            $manualBridgeFailureCode,
            'if(targetId.equals(id)){fail(stage);}',
            [StringComparison]::Ordinal)) {
    throw 'BridgeCallback methods do not execute their guarded callback bodies directly on dispatcher Delivery.run.'
}
if (-not $automaticFailureCode.StartsWith(
        'if(!isCurrent(targetId)){return;}if("completion_persistence".equals(stage)){handleCompletionPersistence(targetId);return;}if("callback_timeout".equals(stage)){handleUncertainMutation(targetId);return;}',
        [StringComparison]::Ordinal) `
        -or -not $manualFailCode.StartsWith(
            'if("callback_timeout".equals(stage)){abandonUncertainMutation();return;}if(!finished.compareAndSet(false,true)){return;}',
            [StringComparison]::Ordinal)) {
    throw 'Callback timeout does not enter its dedicated uncertain-mutation review path before ordinary retry handling.'
}
$automaticUncertainQuarantineIndex = $automaticUncertainCode.IndexOf(
    'booleanreviewSaved=quarantineCompletionReview(activity,viewer,targetId);',
    [StringComparison]::Ordinal)
$automaticUncertainDiagnosticIndex = $automaticUncertainCode.IndexOf(
    'BlockDiagnosticdiagnostic=BlockDiagnostic.forFailure("callback_timeout",true,false,started,reviewSaved);',
    [StringComparison]::Ordinal)
$automaticUncertainFinishIndex = $automaticUncertainCode.IndexOf(
    'finish(diagnostic.status());', [StringComparison]::Ordinal)
if (-not $automaticUncertainCode.StartsWith(
        'if(!isCurrent(targetId)){return;}waiting=false;markSchedulerMutationInFlight(schedulerToken,false);',
        [StringComparison]::Ordinal) `
        -or $automaticUncertainQuarantineIndex -lt 0 `
        -or $automaticUncertainDiagnosticIndex -le $automaticUncertainQuarantineIndex `
        -or $automaticUncertainFinishIndex -le $automaticUncertainDiagnosticIndex `
        -or $automaticUncertainCode.Contains('persistRetryDeadline(', [StringComparison]::Ordinal) `
        -or $automaticUncertainCode.Contains('scheduleManualDrain(', [StringComparison]::Ordinal)) {
    throw 'Automatic callback silence can retry without first entering durable or process-local review quarantine.'
}
$manualUncertainQuarantineIndex = $manualUncertainCode.IndexOf(
    'booleanreviewSaved=quarantineCompletionReview(activity,viewer,targetId);',
    [StringComparison]::Ordinal)
$manualUncertainAbandonIndex = $manualUncertainCode.IndexOf(
    'ModStateStore.markManualAbandoned(activity,viewer,targetId,diagnostic.detail());',
    [StringComparison]::Ordinal)
$manualUncertainReleaseIndex = $manualUncertainCode.IndexOf(
    'releaseSchedulerAndContinue(schedulerToken,activity,viewer,0L,false);',
    [StringComparison]::Ordinal)
$manualUncertainDispatchIndex = $manualUncertainCode.IndexOf(
    'dispatchManualFailure(viewer,targetId,diagnostic.stage());',
    [StringComparison]::Ordinal)
$markManualAbandonedCode = Get-JavaBlockBody -Text $stateCode `
    -Anchor 'publicstaticsynchronizedbooleanmarkManualAbandoned(' `
    -Label 'ModStateStore.markManualAbandoned'
$expectedMarkManualAbandonedCode = 'booleanupdated=updateQueueState(' `
    + 'context,viewerId,targetId,STATE_ABANDONED,detail,false,false);' `
    + 'if(updated){appendHistory(context,viewerId,targetId,"",SOURCE_INLINE,' `
    + 'OUTCOME_ABANDONED,detail);}returnupdated;'
if (-not $manualUncertainCode.StartsWith(
        'if(!finished.compareAndSet(false,true)){return;}markSchedulerMutationInFlight(schedulerToken,false);',
        [StringComparison]::Ordinal) `
        -or $manualUncertainQuarantineIndex -lt 0 `
        -or $manualUncertainAbandonIndex -le $manualUncertainQuarantineIndex `
        -or $manualUncertainReleaseIndex -le $manualUncertainAbandonIndex `
        -or $manualUncertainDispatchIndex -le $manualUncertainReleaseIndex `
        -or $manualUncertainCode.Contains('persistRetryDeadline(', [StringComparison]::Ordinal) `
        -or $manualUncertainCode.Contains('markManualFailed(', [StringComparison]::Ordinal) `
        -or $manualUncertainCode.Contains('scheduleManualDrain(', [StringComparison]::Ordinal) `
        -or $markManualAbandonedCode.Contains('addAlert(', [StringComparison]::Ordinal) `
        -or $markManualAbandonedCode.Contains('recordFailureDiagnostic(', [StringComparison]::Ordinal) `
        -or -not [string]::Equals(
            $markManualAbandonedCode, $expectedMarkManualAbandonedCode,
            [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $manualUncertainCode `
            -Literal 'ModStateStore.recordFailureDiagnostic(activity,viewer,diagnostic);') -ne 1) {
    throw 'Inline callback silence is not abandoned and quarantined until an explicit atomic retry.'
}
$automaticWatchdogEnqueueProof = 'booleanwatchdogPosted=MAIN.postDelayed(newRunnable(){@Overridepublicvoidrun(){' `
    + 'if(!finished.get()&&waiting&&token==watchdogToken){handleUncertainMutation(targetId);}}},WATCHDOG_MS);' `
    + 'if(!watchdogPosted){handleUncertainMutation(targetId);}'
$manualWatchdogEnqueueProof = 'booleanwatchdogPosted=MAIN.postDelayed(newRunnable(){@Overridepublicvoidrun(){' `
    + 'abandonUncertainMutation();}},WATCHDOG_MS);if(!watchdogPosted){abandonUncertainMutation();}'
foreach ($checkedEnqueueProof in @(
        @($automaticBeginCode, $automaticWatchdogEnqueueProof, 'automatic watchdog'),
        @($manualBeginCode, $manualWatchdogEnqueueProof, 'manual watchdog'))) {
    if (-not ([string]$checkedEnqueueProof[0]).Contains(
            [string]$checkedEnqueueProof[1], [StringComparison]::Ordinal)) {
        throw "Scheduler-critical Handler enqueue result is not checked fail-closed: $($checkedEnqueueProof[2])"
    }
}
$automaticCompletionSaveProof = 'booleancompletionSaved=false;' `
    + 'try{completionSaved=markDone(activity,viewer,targetId)&&ModStateStore.clearPassiveRunning(activity,viewer,targetId);}catch(Throwableignored){}' `
    + 'if(!completionSaved){handleCompletionPersistence(targetId);return;}'
if (-not $automaticSuccessRunCode.Contains(
        $automaticCompletionSaveProof, [StringComparison]::Ordinal)) {
    throw 'Automatic native success does not converge false and thrown completion saves on the dedicated quarantine handler.'
}
foreach ($automaticPostSuccessGuard in @(
        'try{ModStateStore.recordAutomaticBlocked(activity,viewer,targetId);}catch(Throwableignored){}',
        'try{clearRetryDeadline(activity,viewer);}catch(Throwableignored){}')) {
    if (-not $automaticSuccessRunCode.Contains(
            $automaticPostSuccessGuard, [StringComparison]::Ordinal)) {
        throw "Automatic normal-success local state access can strand scheduler ownership: $automaticPostSuccessGuard"
    }
}
$automaticPostSuccessGuardIndex = $automaticSuccessRunCode.IndexOf(
    'try{if(!isCurrentForeground())', [StringComparison]::Ordinal)
$successDelayIndex = $automaticSuccessRunCode.IndexOf(
    'longdelay=millisUntilPassivePaceAllowed(activity,viewer);', [StringComparison]::Ordinal)
$successFreshDrainIndex = $automaticSuccessRunCode.IndexOf(
    'finishAndResume(', $successDelayIndex, [StringComparison]::Ordinal)
$automaticPostSuccessCatchIndex = $automaticSuccessRunCode.IndexOf(
    'catch(Throwableignored){finish("Blockcompleted;localschedulerstateneedsreview.");}',
    [StringComparison]::Ordinal)
if ($automaticPostSuccessGuardIndex -lt 0 `
        -or $successDelayIndex -le $automaticPostSuccessGuardIndex `
        -or $successFreshDrainIndex -le $successDelayIndex `
        -or $automaticPostSuccessCatchIndex -le $successFreshDrainIndex `
        -or $automaticSuccessRunCode.Contains('MAIN.postDelayed(', [StringComparison]::Ordinal) `
        -or $automaticSuccessRunCode.Contains('next();', [StringComparison]::Ordinal)) {
    throw 'Automatic success must release into one paced fresh drain instead of iterating under the same scheduler owner.'
}
$automaticCompletionCode = Get-JavaBlockBody -Text $blockRunCode `
    -Anchor 'privatevoidhandleCompletionPersistence(StringtargetId)' `
    -Label 'BlockRun.handleCompletionPersistence'
$automaticCompletionQuarantineIndex = $automaticCompletionCode.IndexOf(
    'booleanreviewSaved=quarantineCompletionReview(activity,viewer,targetId);',
    [StringComparison]::Ordinal)
$automaticCompletionDiagnosticIndex = $automaticCompletionCode.IndexOf(
    'BlockDiagnosticdiagnostic=BlockDiagnostic.forFailure("completion_persistence",true,false,true,reviewSaved);',
    [StringComparison]::Ordinal)
$automaticCompletionHistoryIndex = $automaticCompletionCode.IndexOf(
    'ModStateStore.recordAutomaticFailure(activity,viewer,targetId,diagnostic);',
    [StringComparison]::Ordinal)
$automaticCompletionAlertIndex = $automaticCompletionCode.IndexOf(
    'ModStateStore.recordFailureDiagnostic(activity,viewer,diagnostic);',
    [StringComparison]::Ordinal)
$automaticCompletionLogIndex = $automaticCompletionCode.IndexOf(
    'Log.w(TAG,diagnostic.logLine());', [StringComparison]::Ordinal)
$automaticCompletionFinishIndex = $automaticCompletionCode.IndexOf(
    'finish(diagnostic.status());', [StringComparison]::Ordinal)
if ($automaticCompletionQuarantineIndex -lt 0 `
        -or $automaticCompletionDiagnosticIndex -le $automaticCompletionQuarantineIndex `
        -or $automaticCompletionHistoryIndex -le $automaticCompletionDiagnosticIndex `
        -or $automaticCompletionAlertIndex -le $automaticCompletionHistoryIndex `
        -or $automaticCompletionLogIndex -le $automaticCompletionAlertIndex `
        -or $automaticCompletionFinishIndex -le $automaticCompletionLogIndex) {
    throw 'Automatic native-success persistence failure does not quarantine before its closed review diagnostic and scheduler release.'
}
foreach ($automaticCompletionBestEffortProof in @(
        'try{ModStateStore.recordAutomaticFailure(activity,viewer,targetId,diagnostic);}catch(Throwableignored){}',
        'try{ModStateStore.recordFailureDiagnostic(activity,viewer,diagnostic);}catch(Throwableignored){}',
        'try{Log.w(TAG,diagnostic.logLine());}catch(Throwableignored){}')) {
    if (-not $automaticCompletionCode.Contains(
            $automaticCompletionBestEffortProof, [StringComparison]::Ordinal)) {
        throw "Automatic post-quarantine diagnostic work can prevent scheduler release: $automaticCompletionBestEffortProof"
    }
}
foreach ($forbiddenCompletionRetryPath in @(
        'persistRetryDeadline(',
        'clearRetryDeadline(',
        'scheduleManualDrain(',
        'ThreadsBlockBridge.',
        'MAIN.postDelayed(',
        'next();')) {
    if ($automaticCompletionCode.Contains(
            $forbiddenCompletionRetryPath, [StringComparison]::Ordinal)) {
        throw "Automatic completion review contains a retry or duplicate-mutation path: $forbiddenCompletionRetryPath"
    }
}
$automaticFinishCode = Get-JavaBlockBody -Text $blockRunCode `
    -Anchor 'privatevoidfinish(Stringstatus)' -Label 'BlockRun.finish'
$automaticForegroundFinishCode = Get-JavaBlockBody -Text $blockRunCode `
    -Anchor 'privatevoidfinishForForegroundChange(Stringstatus,booleanpreserveForceRefresh)' `
    -Label 'BlockRun.finishForForegroundChange'
if (-not $automaticFinishCode.Contains(
        'try{setStatus(activity,viewer,status);}catch(Throwableignored){}finally{releaseSchedulerAndContinue(schedulerToken,activity,viewer,0L,false);}',
        [StringComparison]::Ordinal) `
        -or -not $automaticForegroundFinishCode.Contains(
            'try{setStatus(activity,viewer,status);}catch(Throwableignored){}finally{releaseSchedulerAndContinue(schedulerToken,activity,viewer,0L,true);}',
            [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $automaticSuccessRunCode `
            -Literal 'handleCompletionPersistence(targetId);') -ne 1) {
    throw 'Automatic completion review can resume automatic work, propagate status failure, or bypass its dedicated no-retry handler.'
}
if ((Get-JavaTopLevelLiteralIndex -Text $manualFailCode `
        -Literal 'releaseSchedulerAndContinue(schedulerToken,activity,viewer,FAILURE_BACKOFF_MS+1000L,true);') -lt 0) {
    throw 'Manual callback failure does not schedule its backoff through scheduler release.'
}
$manualCompletionSaveProof = 'booleancompletionSaved=false;' `
    + 'try{completionSaved=ModStateStore.markManualBlocked(activity,viewer,targetId);}catch(Throwableignored){}' `
    + 'if(!completionSaved){handleCompletionPersistenceAfterSuccess();return;}'
if (-not $manualSuccessRunCode.Contains(
        $manualCompletionSaveProof, [StringComparison]::Ordinal)) {
    throw 'Manual native success does not converge false and thrown completion saves on the dedicated quarantine handler.'
}
foreach ($manualPostSuccessGuard in @(
        'try{clearRetryDeadline(activity,viewer);}catch(Throwableignored){}',
        'try{setStatus(activity,viewer,"InlineBlockcompletedafterThreadsconfirmedsuccess.");ModStateStore.recordRuntimeState(activity,viewer,"manual_succeeded","Threadsconfirmedtheinlineblock.",false);}catch(Throwableignored){}')) {
    if (-not $manualSuccessRunCode.Contains(
            $manualPostSuccessGuard, [StringComparison]::Ordinal)) {
        throw "Manual normal-success local state access can strand scheduler ownership: $manualPostSuccessGuard"
    }
}
$manualPostSuccessGuardIndex = $manualSuccessRunCode.IndexOf(
    'try{try{clearRetryDeadline(activity,viewer);', [StringComparison]::Ordinal)
$manualSuccessDispatchIndex = $manualSuccessRunCode.IndexOf(
    'dispatchManualSuccess(viewer,targetId);', [StringComparison]::Ordinal)
$manualPostSuccessFinallyIndex = $manualSuccessRunCode.IndexOf(
    '}finally{', [StringComparison]::Ordinal)
$manualPostSuccessReleaseIndex = $manualSuccessRunCode.IndexOf(
    'releaseSchedulerAndContinue(schedulerToken,activity,viewer,0L,true);',
    [StringComparison]::Ordinal)
if ($manualPostSuccessGuardIndex -lt 0 `
        -or $manualSuccessDispatchIndex -le $manualPostSuccessGuardIndex `
        -or $manualPostSuccessFinallyIndex -le $manualSuccessDispatchIndex `
        -or $manualPostSuccessReleaseIndex -le $manualPostSuccessFinallyIndex `
        -or $manualSuccessRunCode.Contains(
            'millisUntilPassivePaceAllowed(', [StringComparison]::Ordinal)) {
    throw 'Manual normal-success persistence or callback failure can strand scheduler ownership, or manual work inherits passive pacing.'
}
$manualCompletionCode = Get-JavaBlockBody -Text $manualRunCode `
    -Anchor 'privatevoidhandleCompletionPersistenceAfterSuccess()' `
    -Label 'ManualBlockRun.handleCompletionPersistenceAfterSuccess'
$manualCompletionQuarantineIndex = $manualCompletionCode.IndexOf(
    'booleanreviewSaved=quarantineCompletionReview(activity,viewer,targetId);',
    [StringComparison]::Ordinal)
$manualCompletionDiagnosticIndex = $manualCompletionCode.IndexOf(
    'BlockDiagnosticdiagnostic=BlockDiagnostic.forFailure("completion_persistence",false,resolvedAuthorModel!=null,true,reviewSaved);',
    [StringComparison]::Ordinal)
$manualCompletionQueueIndex = $manualCompletionCode.IndexOf(
    'ModStateStore.markManualFailed(activity,viewer,targetId,diagnostic);',
    [StringComparison]::Ordinal)
$manualCompletionAlertIndex = $manualCompletionCode.IndexOf(
    'ModStateStore.recordFailureDiagnostic(activity,viewer,diagnostic);',
    [StringComparison]::Ordinal)
$manualCompletionReleaseIndex = $manualCompletionCode.IndexOf(
    'releaseSchedulerAndContinue(schedulerToken,activity,viewer,0L,false);',
    [StringComparison]::Ordinal)
$manualCompletionDispatchIndex = $manualCompletionCode.IndexOf(
    'dispatchManualFailure(viewer,targetId,diagnostic.stage());',
    [StringComparison]::Ordinal)
if ($manualCompletionQuarantineIndex -lt 0 `
        -or $manualCompletionDiagnosticIndex -le $manualCompletionQuarantineIndex `
        -or $manualCompletionQueueIndex -le $manualCompletionDiagnosticIndex `
        -or $manualCompletionAlertIndex -le $manualCompletionQueueIndex `
        -or $manualCompletionReleaseIndex -le $manualCompletionAlertIndex `
        -or $manualCompletionDispatchIndex -le $manualCompletionReleaseIndex `
        -or (Get-PatchletLiteralCount -Text $manualSuccessRunCode `
            -Literal 'handleCompletionPersistenceAfterSuccess();') -ne 1) {
    throw 'Manual native-success persistence failure does not quarantine and remain reviewable before a no-resume scheduler release.'
}
foreach ($manualCompletionBestEffortProof in @(
        'try{ModStateStore.markManualFailed(activity,viewer,targetId,diagnostic);}catch(Throwableignored){}',
        'try{ModStateStore.recordFailureDiagnostic(activity,viewer,diagnostic);setStatus(activity,viewer,diagnostic.status());}catch(Throwableignored){}',
        'try{Log.w(TAG,diagnostic.logLine());}catch(Throwableignored){}')) {
    if (-not $manualCompletionCode.Contains(
            $manualCompletionBestEffortProof, [StringComparison]::Ordinal)) {
        throw "Manual post-quarantine diagnostic work can prevent scheduler release: $manualCompletionBestEffortProof"
    }
}
if (-not $manualCompletionCode.Contains(
        'finally{try{releaseSchedulerAndContinue(schedulerToken,activity,viewer,0L,false);}finally{dispatchManualFailure(viewer,targetId,diagnostic.stage());}}',
        [StringComparison]::Ordinal)) {
    throw 'Manual post-quarantine release and failure callback are not protected by nested finally blocks.'
}
foreach ($forbiddenManualCompletionRetryPath in @(
        'persistRetryDeadline(',
        'clearRetryDeadline(',
        'scheduleManualDrain(',
        'ThreadsBlockBridge.',
        'MAIN.postDelayed(')) {
    if ($manualCompletionCode.Contains(
            $forbiddenManualCompletionRetryPath, [StringComparison]::Ordinal)) {
        throw "Manual completion review contains a retry or duplicate-mutation path: $forbiddenManualCompletionRetryPath"
    }
}
$singleTargetLoadCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticPassiveTargetSelectionloadTarget(Contextcontext,Stringviewer,booleanforceRefresh)' `
    -Label 'AutoBlockSync.loadTarget'
foreach ($requiredReviewSelectorProof in @(
        'ModStateStore.CompletionReviewStatereview=ModStateStore.completionReviewState(context,viewer);',
        'if(!review.valid||review.full||isLocalCompletionReviewPaused(viewer)){returnnewPassiveTargetSelection(null,true,false,false);}',
        'review.targets.contains(candidate)',
        'if(selection.completionReviewBlocked)',
        'ModStateStore.CompletionReviewStatereview=ModStateStore.completionReviewState(activity,viewer);',
        'if(!review.valid||review.full||isLocalCompletionReviewPaused(viewer)){finish("Completion-reviewstateneedsattention;automaticworkremainspaused.");return;}',
        'currentReview.targets.contains(targetId)')) {
    if (-not ($singleTargetLoadCode + $schedulerCode + $blockRunCode).Contains(
            $requiredReviewSelectorProof, [StringComparison]::Ordinal)) {
        throw "Automatic target selection does not fail closed on completion-review state: $requiredReviewSelectorProof"
    }
}
$readCompletionReviewCode = Get-JavaBlockBody -Text $stateCode `
    -Anchor 'privatestaticCompletionReviewStatereadCompletionReview(SharedPreferencesp,StringviewerId)' `
    -Label 'ModStateStore.readCompletionReview'
foreach ($strictReviewStoreProof in @(
        'staticfinalintMAX_COMPLETION_REVIEW_TARGETS=200;',
        'finalbooleanfull;',
        'returnnewCompletionReviewState(true,targets.size()>=MAX_COMPLETION_REVIEW_TARGETS,targets);',
        'returnnewCompletionReviewState(false,true,newHashSet<String>());',
        'Map<String,?>values=p.getAll();',
        'if(!values.containsKey(key)){returnCompletionReviewState.valid(newHashSet<String>());}',
        'if(!(rawinstanceofSet<?>)){returnCompletionReviewState.invalid();}',
        'if(stored.size()>MAX_COMPLETION_REVIEW_TARGETS){returnCompletionReviewState.invalid();}',
        'if(!(valueinstanceofString)){returnCompletionReviewState.invalid();}',
        'if(!isTargetId(target)||viewerId.equals(target)){returnCompletionReviewState.invalid();}',
        'catch(Throwableignored){returnCompletionReviewState.invalid();}')) {
    if (-not ($stateCode + $readCompletionReviewCode).Contains(
            $strictReviewStoreProof, [StringComparison]::Ordinal)) {
        throw "Completion-review storage does not reject corrupt or oversized state: $strictReviewStoreProof"
    }
}
$stateQuarantineCode = Get-JavaBlockBody -Text $stateCode `
    -Anchor 'staticsynchronizedbooleanquarantineCompletionReview(Contextcontext,StringviewerId,StringtargetId)' `
    -Label 'ModStateStore.quarantineCompletionReview'
if (-not $stateQuarantineCode.Contains(
        'if(!review.valid){returnfalse;}', [StringComparison]::Ordinal) `
        -or -not $stateQuarantineCode.Contains(
            'if(!targets.contains(targetId)&&targets.size()>=MAX_COMPLETION_REVIEW_TARGETS){returnfalse;}',
            [StringComparison]::Ordinal) `
        -or -not $stateQuarantineCode.Contains(
            'putCompletionReview(editor,viewerId,targets);returneditor.commit();',
            [StringComparison]::Ordinal) `
        -or -not $stateQuarantineCode.Contains(
            'catch(Throwableignored){returnfalse;}', [StringComparison]::Ordinal)) {
    throw 'Completion-review quarantine does not fail closed and commit one bounded viewer-scoped target set.'
}
$schedulerQuarantineCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticbooleanquarantineCompletionReview(Contextcontext,Stringviewer,StringtargetId)' `
    -Label 'AutoBlockSync.quarantineCompletionReview'
$localInstallIndex = $schedulerQuarantineCode.IndexOf(
    'installLocalCompletionReview(viewer,targetId);', [StringComparison]::Ordinal)
$durableQuarantineIndex = $schedulerQuarantineCode.IndexOf(
    'ModStateStore.quarantineCompletionReview(context,viewer,targetId);',
    [StringComparison]::Ordinal)
$localClearIndex = $schedulerQuarantineCode.IndexOf(
    'clearLocalCompletionReviewAfterRetry(viewer,targets);', [StringComparison]::Ordinal)
if ($localInstallIndex -lt 0 -or $durableQuarantineIndex -le $localInstallIndex `
        -or $localClearIndex -le $durableQuarantineIndex `
        -or -not $schedulerQuarantineCode.Contains(
            'booleansaved=false;try{saved=ModStateStore.quarantineCompletionReview(context,viewer,targetId);}catch(Throwableignored){}',
            [StringComparison]::Ordinal) `
        -or -not $schedulerCode.Contains(
            'localCompletionReviewOverflow=true;', [StringComparison]::Ordinal) `
        -or -not $schedulerCode.Contains(
            'returnlocalCompletionReviewOverflow||LOCAL_COMPLETION_REVIEW_PAUSED_VIEWERS.contains(viewer);',
            [StringComparison]::Ordinal)) {
    throw 'Process-local completion-review quarantine is not installed before durable write or retained fail-closed on failure/overflow.'
}
$retryManualCode = Get-JavaBlockBody -Text $stateCode `
    -Anchor 'publicstaticsynchronizedbooleanretryManual(Contextcontext,StringviewerId,StringtargetId)' `
    -Label 'ModStateStore.retryManual'
$retryAllCode = Get-JavaBlockBody -Text $stateCode `
    -Anchor 'publicstaticsynchronizedintretryAllManual(Contextcontext,StringviewerId)' `
    -Label 'ModStateStore.retryAllManual'
foreach ($retryContract in @(
        @($retryManualCode, 'remainingReview.remove(targetId);', 'retry one review removal'),
        @($retryAllCode, 'remainingReview.removeAll(retried);', 'retry-all review removal')
    )) {
    $retryBody = [string]$retryContract[0]
    $reviewRemovalIndex = $retryBody.IndexOf(
        [string]$retryContract[1], [StringComparison]::Ordinal)
    $queueCommitIndex = $retryBody.IndexOf(
        '.putString(queueKey(viewerId),encoded.toString());', [StringComparison]::Ordinal)
    $reviewCommitIndex = $retryBody.IndexOf(
        'putCompletionReview(editor,viewerId,remainingReview);', [StringComparison]::Ordinal)
    $commitIndex = $retryBody.IndexOf('editor.commit()', [StringComparison]::Ordinal)
    $clearIndex = $retryBody.IndexOf(
        'AutoBlockSync.clearLocalCompletionReviewAfterRetry(viewerId,',
        [StringComparison]::Ordinal)
    if ($reviewRemovalIndex -lt 0 -or $queueCommitIndex -le $reviewRemovalIndex `
            -or $reviewCommitIndex -le $queueCommitIndex `
            -or $commitIndex -le $reviewCommitIndex `
            -or $clearIndex -le $commitIndex `
            -or (Get-PatchletLiteralCount -Text $retryBody -Literal 'editor.commit()') -ne 1 `
            -or $retryBody.Contains('.apply()', [StringComparison]::Ordinal)) {
        throw "Manual retry does not atomically commit queue and quarantine removal before clearing the local latch: $($retryContract[2])"
    }
}
if (-not $diagnosticForFailureCode.Contains('"review-saved"', [StringComparison]::Ordinal) `
        -or -not $diagnosticForFailureCode.Contains(
            '"review-local-failclosed"', [StringComparison]::Ordinal) `
        -or -not $diagnosticForFailureCode.Contains(
            '"Thetargetwasdurablyquarantined;automaticretryisdisabled."',
            [StringComparison]::Ordinal) `
        -or -not $diagnosticForFailureCode.Contains(
            '"Aprocess-localquarantineisactive;automaticworkispaused."',
            [StringComparison]::Ordinal)) {
    throw 'Completion diagnostic does not distinguish durable review from process-local fail-closed quarantine.'
}
$fetchWorkerCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticfinalclassFetchWorkerimplementsRunnable' -Label 'FetchWorker'
$fetchRunCode = Get-JavaBlockBody -Text $fetchWorkerCode `
    -Anchor 'publicvoidrun()' -Label 'FetchWorker.run'
$fetchFailureCode = Get-JavaBlockBody -Text $fetchRunCode `
    -Anchor 'catch(finalThrowableerror)' -Label 'FetchWorker failure'
$fetchPostIndex = $fetchRunCode.IndexOf(
    'booleanposted=MAIN.post(newRunnable(){', [StringComparison]::Ordinal)
$fetchRefusalCode = Get-JavaBlockBody -Text $fetchRunCode `
    -Anchor 'if(!posted)' -Label 'FetchWorker rejected main-thread enqueue'
if ($fetchPostIndex -lt 0 `
        -or -not $fetchRefusalCode.Contains(
            'if(forceRefresh){requestForceRefresh(viewer);}', [StringComparison]::Ordinal) `
        -or -not $fetchRefusalCode.Contains(
            'setStatus(activity,viewer,"PassivematchingcouldnotreturntotheThreadsscreen;reopenThreadsto"' `
                + '+"resumesafely.");',
            [StringComparison]::Ordinal) `
        -or -not $fetchRefusalCode.Contains(
            'releaseSchedulerAndContinue(schedulerToken,activity,viewer,0L,true);',
            [StringComparison]::Ordinal)) {
    throw 'FetchWorker can strand scheduler ownership when the main-thread enqueue is rejected.'
}
if ((Get-JavaTopLevelLiteralIndex -Text $fetchFailureCode `
        -Literal 'releaseSchedulerAndContinue(schedulerToken,stateActivity,viewer,FAILURE_BACKOFF_MS+1000L,true);') -lt 0) {
    throw 'Passive-match failure does not release the scheduler with its backoff wake.'
}
$releaseCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticvoidreleaseSchedulerAndContinue(longschedulerToken,Activityactivity,Stringviewer,longdelayMs,booleanresumeAuto)' `
    -Label 'releaseSchedulerAndContinue'
Assert-JavaBranchWake -MethodBody $releaseCode `
    -Condition 'if(!viewer.equals(liveViewer)||host!=activity)' `
    -WakeCall 'scheduleManualDrain(0L);' -Label 'scheduler context replacement'
$releasePendingBranch = Get-JavaBlockBody -Text $releaseCode `
    -Anchor 'if(manualPending||(resumeAuto&&isEnabled(host)))' `
    -Label 'scheduler durable-work continuation'
if ((Get-JavaTopLevelLiteralIndex -Text $releasePendingBranch `
        -Literal 'scheduleManualDrain(delayMs);') -lt 0) {
    throw 'Scheduler release does not wake remaining durable work with the requested delay.'
}
$scheduleDrainCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticvoidscheduleManualDrain(longdelayMs)' -Label 'scheduleManualDrain'
$scheduleDrainRefusalCode = Get-JavaBlockBody -Text $scheduleDrainCode `
    -Anchor 'if(!posted)' -Label 'scheduleManualDrain rejected enqueue'
if ((Get-JavaTopLevelLiteralIndex -Text $scheduleDrainCode `
            -Literal 'booleanposted=MAIN.postDelayed(') -lt 0 `
        -or -not $scheduleDrainCode.Contains('},Math.max(0L,delayMs));', [StringComparison]::Ordinal) `
        -or -not $scheduleDrainRefusalCode.Contains(
            'Stringviewer=getCurrentViewer();', [StringComparison]::Ordinal) `
        -or -not $scheduleDrainRefusalCode.Contains(
            'ModStateStore.recordRuntimeState(activity,viewer,"scheduler_wake_rejected",' `
                + '"QueuedworkispauseduntilThreadsresumesintheforeground.",true);',
            [StringComparison]::Ordinal)) {
    throw 'Scheduler wake helper does not check rejection and preserve durable work in bounded review state.'
}
$showToastCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'privatestaticvoidshowToast(finalContextcontext,finalStringmessage)' `
    -Label 'showToast'
if ((Get-PatchletLiteralCount -Text $schedulerCode -Literal 'MAIN.post(') -ne 4 `
        -or (Get-PatchletLiteralCount -Text $schedulerCode -Literal 'MAIN.postDelayed(') -ne 4 `
        -or (Get-PatchletLiteralCount -Text $fetchRunCode -Literal 'MAIN.post(') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $showToastCode -Literal 'MAIN.post(') -ne 1 `
        -or -not $showToastCode.StartsWith('MAIN.post(newRunnable(){', [StringComparison]::Ordinal)) {
    throw 'Within the Block scheduler, only optional toast delivery may ignore Handler enqueue acceptance.'
}
$limitsChangedCode = Get-JavaBlockBody -Text $schedulerCode `
    -Anchor 'publicstaticvoidonLimitsChanged(Contextcontext)' -Label 'onLimitsChanged'
if ((Get-JavaTopLevelLiteralIndex -Text $limitsChangedCode `
        -Literal 'scheduleManualDrain(0L);') -lt 0) {
    throw 'A valid atomic limits update does not wake parked scheduler work.'
}
foreach ($requiredLimitDeclaration in @(
    'publicstaticfinalintMIN_PASSIVE_MIN_DELAY_MS=2000;',
    'publicstaticfinalintMAX_PASSIVE_MIN_DELAY_MS=60000;',
    'publicstaticfinalintMIN_PASSIVE_MAX_DELAY_MS=3000;',
    'publicstaticfinalintMAX_PASSIVE_MAX_DELAY_MS=60000;',
    'publicstaticfinalintDEFAULT_PASSIVE_MIN_DELAY_MS=4000;',
    'publicstaticfinalintDEFAULT_PASSIVE_MAX_DELAY_MS=10000;'
)) {
    if (-not $limitsCode.Contains($requiredLimitDeclaration, [StringComparison]::Ordinal)) {
        throw "Limits model declaration is not exact: $requiredLimitDeclaration"
    }
}
foreach ($retiredLimitSymbol in @(
        'manualMinDelay', 'manualMaxDelay',
        'automaticMinDelay', 'automaticMaxDelay', 'automaticPerHour',
        'targetBudget', 'totalPerHour', 'totalPerDay', 'maxPerRun',
        'DEFAULT_MAX_PER_RUN', 'MIN_FOREGROUND_RUN', 'MAX_FOREGROUND_RUN',
        'foregroundRunCap', 'viewerScopedLimitHistories',
        'MIN_MANUAL_', 'MAX_MANUAL_', 'MIN_AUTOMATIC_', 'MAX_AUTOMATIC_',
        'MIN_TARGET_', 'MAX_TARGET_', 'MIN_TOTAL_', 'MAX_TOTAL_',
        'MIN_PER_RUN', 'MAX_PER_RUN')) {
    if ($joinedProductionAssets.Contains(
            $retiredLimitSymbol, [StringComparison]::Ordinal)) {
        throw "Removed manual/capacity limit remains in a production asset: $retiredLimitSymbol"
    }
}
if ((Get-PatchletLiteralCount -Text $limitsCode -Literal 'privatefinalint') -ne 2 `
        -or (Get-PatchletLiteralCount -Text $limitsCode `
            -Literal 'publicintpassiveMinDelayMs()') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $limitsCode `
            -Literal 'publicintpassiveMaxDelayMs()') -ne 1) {
    throw 'BlockLimits must expose exactly the two passive delay fields and no capacity/manual field.'
}
$defaultsCode = Get-JavaBlockBody -Text $limitsCode `
    -Anchor 'publicstaticBlockLimitsdefaults()' -Label 'BlockLimits.defaults'
$expectedDefaults = 'returnnewBlockLimits(' `
    + 'DEFAULT_PASSIVE_MIN_DELAY_MS,DEFAULT_PASSIVE_MAX_DELAY_MS);'
if ($defaultsCode -ne $expectedDefaults) {
    throw 'Limits defaults are not constructed in the exact reviewed field order.'
}
$checkedLimitsCode = Get-JavaBlockBody -Text $limitsCode `
    -Anchor 'publicstaticBlockLimitschecked(intpassiveMinDelayMs,intpassiveMaxDelayMs)' `
    -Label 'BlockLimits.checked'
foreach ($checkedRule in @(
    'requireRange("passiveminimumdelay",passiveMinDelayMs,MIN_PASSIVE_MIN_DELAY_MS,MAX_PASSIVE_MIN_DELAY_MS);',
    'requireRange("passivemaximumdelay",passiveMaxDelayMs,MIN_PASSIVE_MAX_DELAY_MS,MAX_PASSIVE_MAX_DELAY_MS);',
    'requireWholeSecond("passiveminimumdelay",passiveMinDelayMs);',
    'requireWholeSecond("passivemaximumdelay",passiveMaxDelayMs);',
    'if(passiveMinDelayMs>passiveMaxDelayMs)'
)) {
    if (-not $checkedLimitsCode.Contains($checkedRule, [StringComparison]::Ordinal)) {
        throw "Limits checked method is missing an exact executable rule: $checkedRule"
    }
}
$readLimitsCode = Get-JavaBlockBody -Text $limitsStoreCode `
    -Anchor 'privatestaticReadResultreadSnapshot(Map<String,?>values)' `
    -Label 'BlockLimitsStore.readSnapshot'
if ($readLimitsCode.Contains('instanceofNumber', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $readLimitsCode -Literal 'instanceofInteger') -ne 2) {
    throw 'Limits persistence does not execute exact-Integer fail-closed validation.'
}
$readLimitsTryCode = Get-JavaBlockBody -Text $readLimitsCode `
    -Anchor 'try' -Label 'BlockLimitsStore.readSnapshot checked validation'
$expectedStoredCheck = 'returnnewReadResult(true,BlockLimits.checked(' `
    + '((Integer)values.get(KEY_PASSIVE_MIN_DELAY_MS)).intValue(),' `
    + '((Integer)values.get(KEY_PASSIVE_MAX_DELAY_MS)).intValue()));'
$readLimitsCatchCode = Get-JavaBlockBody -Text $readLimitsCode `
    -Anchor 'catch(IllegalArgumentExceptioninvalid)' `
    -Label 'BlockLimitsStore.readSnapshot invalid snapshot catch'
if ((Get-JavaTopLevelLiteralIndex -Text $readLimitsTryCode -Literal $expectedStoredCheck) -lt 0 `
        -or $readLimitsCatchCode -ne 'returnnewReadResult(false,BlockLimits.defaults());') {
    throw 'Stored Integer limits do not route through checked validation and fail closed.'
}
$loadLimitsStoreCode = Get-JavaBlockBody -Text $limitsStoreCode `
    -Anchor 'publicstaticBlockLimitsload(Contextcontext)' -Label 'BlockLimitsStore.load'
$validLimitsStoreCode = Get-JavaBlockBody -Text $limitsStoreCode `
    -Anchor 'publicstaticbooleanisValid(Contextcontext)' -Label 'BlockLimitsStore.isValid'
$persistLimitsStoreCode = Get-JavaBlockBody -Text $limitsStoreCode `
    -Anchor 'publicstaticbooleansave(Contextcontext,BlockLimitslimits)' -Label 'BlockLimitsStore.save'
$readAllLimitsStoreCode = Get-JavaBlockBody -Text $limitsStoreCode `
    -Anchor 'privatestaticMap<String,?>readAll(SharedPreferencespreferences)' `
    -Label 'BlockLimitsStore.readAll'
foreach ($uncertaintyProof in @(
    @($loadLimitsStoreCode, 'readSnapshot(readAll(preferences(context)))', 'load checked read'),
    @($loadLimitsStoreCode, 'if(persistenceUncertain){returnBlockLimits.defaults();}', 'load latch'),
    @($loadLimitsStoreCode, 'catch(RuntimeExceptionunreadable){persistenceUncertain=true;returnBlockLimits.defaults();}', 'load read failure'),
    @($validLimitsStoreCode, 'if(persistenceUncertain){returnfalse;}', 'validity latch'),
    @($validLimitsStoreCode, 'catch(RuntimeExceptionunreadable){persistenceUncertain=true;returnfalse;}', 'validity read failure'),
    @($persistLimitsStoreCode, 'Map<String,?>before=readAll(preferences);', 'save checked read'),
    @($persistLimitsStoreCode, 'booleanwasUncertain=persistenceUncertain;', 'prior uncertainty capture'),
    @($persistLimitsStoreCode, 'persistenceUncertain=true;SharedPreferences.Editorwrite=', 'pre-commit latch'),
    @($persistLimitsStoreCode, 'if(restore.commit()){persistenceUncertain=wasUncertain;}', 'rollback preserves prior uncertainty'),
    @($persistLimitsStoreCode, 'catch(RuntimeExceptionpersistenceFailure){persistenceUncertain=true;returnfalse;}', 'save failure latch')
)) {
    if (-not $uncertaintyProof[0].Contains($uncertaintyProof[1], [StringComparison]::Ordinal)) {
        throw "Limits persistence uncertainty proof is missing: $($uncertaintyProof[2])"
    }
}
if (-not $readAllLimitsStoreCode.Contains(
        'if(values==null){thrownewIllegalStateException(', [StringComparison]::Ordinal)) {
    throw 'Limits preference reads do not reject a missing snapshot fail-closed.'
}
$retiredLimitKeys = @(
    'limit_manual_min_delay_ms',
    'limit_manual_max_delay_ms',
    'limit_automatic_min_delay_ms',
    'limit_automatic_max_delay_ms',
    'limit_automatic_per_hour',
    'limit_target_budget',
    'limit_total_per_hour',
    'limit_total_per_day',
    'limit_max_per_run'
)
foreach ($retiredLimitKey in $retiredLimitKeys) {
    if ((Get-PatchletLiteralCount -Text $limitsStoreText -Literal ('"' + $retiredLimitKey + '"')) -ne 1 `
            -or (Get-PatchletLiteralCount -Text $joinedProductionAssets `
                -Literal ('"' + $retiredLimitKey + '"')) -ne 1 `
            -or -not $persistLimitsStoreCode.Contains(
                'write.remove(retiredKey);', [StringComparison]::Ordinal) `
            -or -not $persistLimitsStoreCode.Contains(
                'restoreValue(restore,before,retiredKey);', [StringComparison]::Ordinal)) {
        throw "Retired limit key is not deletion-only with exact rollback: $retiredLimitKey"
    }
}
$livePassiveLimitKeys = @(
    'limit_passive_min_delay_ms',
    'limit_passive_max_delay_ms'
)
foreach ($livePassiveLimitKey in $livePassiveLimitKeys) {
    if ((Get-PatchletLiteralCount -Text $limitsStoreText `
            -Literal ('"' + $livePassiveLimitKey + '"')) -ne 1 `
            -or (Get-PatchletLiteralCount -Text $joinedProductionAssets `
                -Literal ('"' + $livePassiveLimitKey + '"')) -ne 1) {
        throw "Passive limit key is missing, duplicated, or owned outside BlockLimitsStore: $livePassiveLimitKey"
    }
}
$saveLimitsCode = Get-JavaBlockBody -Text $settingsCode `
    -Anchor 'privatevoidsavePassiveDelay()' -Label 'CloneBlockerSettingsActivity.savePassiveDelay'
$saveLimitsTryCode = Get-JavaBlockBody -Text $saveLimitsCode `
    -Anchor 'try' -Label 'CloneBlockerSettingsActivity.savePassiveDelay try'
$expectedCheckedWiring = 'BlockLimitslimits=BlockLimits.checked(' `
    + 'parseWholeSeconds(passiveMinDelay),' `
    + 'parseWholeSeconds(passiveMaxDelay));'
$settingsCheckedIndex = Get-JavaTopLevelLiteralIndex -Text $saveLimitsTryCode `
    -Literal $expectedCheckedWiring
if ((Get-PatchletLiteralCount -Text $saveLimitsCode -Literal 'BlockLimits.checked(') -ne 1 `
        -or $settingsCheckedIndex -lt 0) {
    throw 'Settings fields are not wired to BlockLimits.checked in the exact reviewed order/step.'
}
$settingsSaveAnchor = 'if(!BlockLimitsStore.save(this,limits))'
$settingsSaveIndex = Get-JavaTopLevelLiteralIndex -Text $saveLimitsTryCode `
    -Literal $settingsSaveAnchor
$settingsSaveFailureCode = Get-JavaBlockBody -Text $saveLimitsTryCode `
    -Anchor $settingsSaveAnchor -Label 'CloneBlockerSettingsActivity.saveLimits failed save'
$settingsRefreshIndex = Get-JavaTopLevelLiteralIndex -Text $saveLimitsTryCode `
    -Literal 'refreshPassiveDelayFields();'
$settingsNotifyIndex = Get-JavaTopLevelLiteralIndex -Text $saveLimitsTryCode `
    -Literal 'AutoBlockSync.onLimitsChanged(this);'
if ($settingsSaveIndex -le $settingsCheckedIndex -or $settingsRefreshIndex -le $settingsSaveIndex `
        -or $settingsNotifyIndex -le $settingsRefreshIndex `
        -or -not $settingsSaveFailureCode.Contains(
            '"Couldnotconfirmpassive-delaypersistence;passiveblockingis"',
            [StringComparison]::Ordinal) `
        -or -not $settingsSaveFailureCode.Contains(
            '"pauseduntilacompletevalidpairissaved."',
            [StringComparison]::Ordinal) `
        -or -not $settingsSaveFailureCode.Contains('return;', [StringComparison]::Ordinal)) {
    throw 'Settings must refresh/wake only after atomic save success and truthfully pause on persistence uncertainty.'
}
$settingsBuildCode = Get-JavaBlockBody -Text $settingsCode `
    -Anchor 'privatevoidbuildContent()' `
    -Label 'CloneBlockerSettingsActivity.buildContent'
foreach ($fieldBinding in @(
    'passiveMinDelay=numericSetting("Passiveminimumdelay(seconds)","2–60,inwholeseconds",passiveDelayCard);',
    'passiveMaxDelay=numericSetting("Passivemaximumdelay(seconds)","3–60,inwholeseconds",passiveDelayCard);'
)) {
    if ((Get-JavaTopLevelLiteralIndex -Text $settingsBuildCode -Literal $fieldBinding) -lt 0) {
        throw "Settings field is not bound to its exact reviewed label/range: $fieldBinding"
    }
}
$parseSecondsCode = Get-JavaBlockBody -Text $settingsCode `
    -Anchor 'privatestaticintparseWholeSeconds(EditTextinput)' `
    -Label 'CloneBlockerSettingsActivity.parseWholeSeconds'
if (-not $parseSecondsCode.Contains('Integer.parseInt(raw)', [StringComparison]::Ordinal) `
        -or -not $parseSecondsCode.Contains('Math.multiplyExact(seconds,1000)', [StringComparison]::Ordinal) `
        -or $parseSecondsCode.Contains('BigDecimal', [StringComparison]::Ordinal)) {
    throw 'Settings passive-delay parsing is not exact whole-second integer validation.'
}
$joinedReportJava = $reportJavaText -join "`n"
$reportClientCode = Get-JavaCompactCode -Text $reportClientText
$reportControllerCode = Get-JavaCompactCode -Text $reportControllerText
$reportRequestCode = Get-JavaCompactCode -Text $reportRequestText
$reportValuesCode = Get-JavaCompactCode -Text $reportValuesText
$reportPayloadCode = Get-JavaCompactCode -Text $reportPayloadText
$reportStoreCode = Get-JavaCompactCode -Text $reportStoreText
$reportJsonCode = Get-JavaCompactCode -Text $reportJsonText
$resolveHostPermalinkCode = Get-JavaBlockBody -Text $reportRequestCode `
    -Anchor 'publicstaticStringresolveHostPermalink(StringprofileUsername,Stringcandidate,Stringshortcode)' `
    -Label 'ReportRequest.resolveHostPermalink'
$resolveHostExcerptCode = Get-JavaBlockBody -Text $reportRequestCode `
    -Anchor 'publicstaticStringresolveHostExcerpt(Stringcandidate)' `
    -Label 'ReportRequest.resolveHostExcerpt'
foreach ($hostPermalinkProof in @(
        'privatestaticfinalintMAX_SHORTCODE=64;',
        '"https://www.threads.com/@"+username+"/post/"+shortcode',
        'returnReportValues.httpsThreadsPermalink(candidate,username);')) {
    if (-not $reportRequestCode.Contains($hostPermalinkProof, [StringComparison]::Ordinal)) {
        throw "ReportRequest code-first permalink proof is missing: $hostPermalinkProof"
    }
}
if (-not $resolveHostPermalinkCode.Contains(
        "c=='_'||c=='-'", [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $resolveHostPermalinkCode `
            -Literal 'ReportValues.httpsThreadsPermalink(') -ne 2 `
        -or -not $reportRequestCode.Contains(
            'privatestaticfinalStringNO_TEXT_EXCERPT="(notextinthispost)";',
            [StringComparison]::Ordinal) `
        -or $resolveHostExcerptCode -ne `
            'Stringexcerpt=ReportValues.cleanText(candidate,ReportValues.MAX_POST_CONTENT);returnexcerpt.length()==0?NO_TEXT_EXCERPT:excerpt;') {
    throw 'ReportRequest does not strictly bind A75-style shortcode authority, validated A7o fallback, and the bounded no-text excerpt.'
}
$hostCodeUrlIndex = $resolveHostPermalinkCode.IndexOf(
    'StringfromCode=ReportValues.httpsThreadsPermalink(', [StringComparison]::Ordinal)
$hostCodeReturnIndex = $resolveHostPermalinkCode.IndexOf(
    'if(fromCode.length()>0){returnfromCode;}', $hostCodeUrlIndex,
    [StringComparison]::Ordinal)
$hostCandidateFallbackIndex = $resolveHostPermalinkCode.LastIndexOf(
    'returnReportValues.httpsThreadsPermalink(candidate,username);',
    [StringComparison]::Ordinal)
if ($hostCodeUrlIndex -lt 0 `
        -or $hostCodeReturnIndex -le $hostCodeUrlIndex `
        -or $hostCandidateFallbackIndex -le $hostCodeReturnIndex) {
    throw 'ReportRequest must validate and return the A75-derived canonical URL before consulting the A7o candidate fallback.'
}
$permalinkSanitizerCode = Get-JavaBlockBody -Text $reportValuesCode `
    -Anchor 'staticStringhttpsThreadsPermalink(Stringvalue,StringexpectedUsername)' `
    -Label 'ReportValues.httpsThreadsPermalink'
if (-not $reportValuesCode.Contains(
        'staticfinalintMAX_PERMALINK=300;', [StringComparison]::Ordinal)) {
    throw 'ReportValues must cap canonical permalinks at the backend-compatible 300 UTF-16 units.'
}
foreach ($permalinkSanitizerProof in @(
        'Stringexpected=normalizeUsername(expectedUsername);',
        'Stringclean=cleanText(value,MAX_PERMALINK);',
        'if(!clean.equals(value)){return"";}',
        '!"https".equalsIgnoreCase(scheme)',
        'uri.isOpaque()',
        'uri.getUserInfo()!=null',
        'uri.getPort()!=-1',
        'uri.getRawQuery()!=null',
        'uri.getRawFragment()!=null',
        '"www.threads.com".equals(normalizedHost)',
        '"www.threads.net".equals(normalizedHost)',
        '!normalizedHost.equals(authority.toLowerCase(Locale.US))',
        "path.indexOf('%')>=0",
        '!path.startsWith("/@")',
        'intpostMarker=path.indexOf("/post/",2);',
        'postMarker!=path.lastIndexOf("/post/")',
        '!expected.equals(pathUsername)',
        'charc=shortcode.charAt(i);',
        'return"https://www.threads.com/@"+expected+"/post/"+shortcode;')) {
    if (-not $permalinkSanitizerCode.Contains(
            $permalinkSanitizerProof, [StringComparison]::Ordinal)) {
        throw "Strict Threads permalink canonicalization proof is missing: $permalinkSanitizerProof"
    }
}
foreach ($permissivePermalinkProof in @(
        '.endsWith(".threads.com")',
        '.endsWith(".threads.net")',
        'equalsIgnoreCase(pathUsername)')) {
    if ($permalinkSanitizerCode.Contains(
            $permissivePermalinkProof, [StringComparison]::Ordinal)) {
        throw "Threads permalink canonicalization contains a permissive host/user binding: $permissivePermalinkProof"
    }
}
$sixStringRequestConstructor = `
    'publicReportRequest(StringitemKey,StringprofileUsername,StringprofileId,StringpostContent,StringdisplayName,Stringpermalink)'
$sixStringRequestConstructorCode = Get-JavaBlockBody -Text $reportRequestCode `
    -Anchor $sixStringRequestConstructor `
    -Label 'ReportRequest public six-string row constructor'
foreach ($requestConstructorProof in @(
        'this.itemKey=ReportValues.cleanText(itemKey,MAX_ITEM_KEY);',
        'this.profileUsername=ReportValues.normalizeUsername(profileUsername);',
        'this.profileId=ReportValues.isNumericId(profileId)?profileId:"";',
        'this.postContent=ReportValues.cleanText(postContent,ReportValues.MAX_POST_CONTENT);',
        'this.displayName=ReportValues.cleanText(displayName,ReportValues.MAX_DISPLAY_NAME);',
        'this.permalink=ReportValues.httpsThreadsPermalink(permalink,this.profileUsername);')) {
    if (-not $sixStringRequestConstructorCode.Contains(
            $requestConstructorProof, [StringComparison]::Ordinal)) {
        throw "ReportRequest six-string constructor proof is missing: $requestConstructorProof"
    }
}
if ((Get-PatchletLiteralCount -Text $reportRequestCode `
            -Literal $sixStringRequestConstructor) -ne 1) {
    throw 'ReportRequest must expose exactly one public six-string row-bound constructor.'
}
$legacyFourStringRequestConstructorCode = Get-JavaBlockBody -Text $reportRequestCode `
    -Anchor 'publicReportRequest(StringitemKey,StringprofileUsername,StringprofileId,StringpostContent)' `
    -Label 'ReportRequest legacy four-string row constructor'
if (-not $legacyFourStringRequestConstructorCode.Contains(
        'this(itemKey,profileUsername,profileId,postContent,"","");',
        [StringComparison]::Ordinal)) {
    throw 'ReportRequest no longer preserves legacy four-string row decoding without permalink evidence.'
}
$legacyRequestValidityCode = Get-JavaBlockBody -Text $reportRequestCode `
    -Anchor 'publicbooleanisValid()' `
    -Label 'ReportRequest.isValid'
if (-not $legacyRequestValidityCode.Contains(
        'profileUsername.length()>0&&ReportValues.isNumericId(profileId)&&postContent.length()>0',
        [StringComparison]::Ordinal) `
        -or $legacyRequestValidityCode.Contains('permalink', [StringComparison]::Ordinal)) {
    throw 'ReportRequest.isValid must remain legacy-compatible and independent of permalink evidence.'
}
$newQueueRequestValidityCode = Get-JavaBlockBody -Text $reportRequestCode `
    -Anchor 'publicbooleanisValidForNewQueue()' `
    -Label 'ReportRequest.isValidForNewQueue'
if (-not $newQueueRequestValidityCode.Contains(
        'returnisValid()&&permalink.length()>0;', [StringComparison]::Ordinal)) {
    throw 'ReportRequest.isValidForNewQueue must require a sanitized non-empty permalink.'
}
$payloadMatchCode = Get-JavaBlockBody -Text $reportPayloadCode `
    -Anchor 'booleanmatchesStoredJson(JSONObjectvalue)' `
    -Label 'ReportPayload.matchesStoredJson'
$payloadToJsonCode = Get-JavaBlockBody -Text $reportPayloadCode `
    -Anchor 'JSONObjecttoJson()' `
    -Label 'ReportPayload.toJson'
$payloadFromJsonCode = Get-JavaBlockBody -Text $reportPayloadCode `
    -Anchor 'staticReportPayloadfromJson(JSONObjectvalue)' `
    -Label 'ReportPayload.fromJson'
$payloadCanonicalKeysCode = Get-JavaBlockBody -Text $reportPayloadCode `
    -Anchor 'privatebooleanhasOnlyCanonicalKeys(JSONObjectvalue)' `
    -Label 'ReportPayload.hasOnlyCanonicalKeys'
foreach ($payloadPermalinkProof in @(
        '!exactString(value,"targetUrl",request.getPermalink())',
        'Stringpermalink=request.getPermalink();',
        '!permalink.equals(evidence.optString(0,""))')) {
    if (-not $payloadMatchCode.Contains($payloadPermalinkProof, [StringComparison]::Ordinal)) {
        throw "Stored report permalink/evidence match proof is missing: $payloadPermalinkProof"
    }
}
$payloadTargetUrlIndex = $payloadToJsonCode.IndexOf(
    'value.put("targetUrl",request.getPermalink());', [StringComparison]::Ordinal)
$payloadEvidenceGuardIndex = $payloadToJsonCode.IndexOf(
    'if(request.getPermalink().length()>0)', [StringComparison]::Ordinal)
$payloadEvidenceWriteIndex = $payloadToJsonCode.IndexOf(
    'evidence.put(request.getPermalink());', [StringComparison]::Ordinal)
$payloadEvidenceFieldIndex = $payloadToJsonCode.IndexOf(
    'value.put("evidence",evidence);', [StringComparison]::Ordinal)
if ($payloadTargetUrlIndex -lt 0 `
        -or $payloadEvidenceGuardIndex -le $payloadTargetUrlIndex `
        -or $payloadEvidenceWriteIndex -le $payloadEvidenceGuardIndex `
        -or $payloadEvidenceFieldIndex -le $payloadEvidenceWriteIndex) {
    throw 'ReportPayload does not map the same immutable permalink to targetUrl and sole evidence.'
}
if (-not $payloadFromJsonCode.Contains(
        'value.optString("targetUrl","")', [StringComparison]::Ordinal) `
        -or -not $payloadCanonicalKeysCode.Contains(
            'allowed.add("targetUrl");', [StringComparison]::Ordinal) `
        -or -not $payloadCanonicalKeysCode.Contains(
            'allowed.add("evidence");', [StringComparison]::Ordinal)) {
    throw 'ReportPayload cannot round-trip and validate the canonical permalink wire fields.'
}
foreach ($forbiddenPermalinkWireField in @('"postUrl"', '"postId"', '"itemKey"')) {
    if ($reportPayloadCode.Contains(
            $forbiddenPermalinkWireField, [StringComparison]::Ordinal)) {
        throw "ReportPayload exposes a forbidden permalink/local-identity wire field: $forbiddenPermalinkWireField"
    }
}
foreach ($forbidden in @(
    'tree55.com',
    'ThreadsBlockBridge',
    'LX/',
    'setRequestProperty("Cookie"',
    'setRequestProperty("Authorization"'
)) {
    if ($joinedReportJava.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Reporting runtime crosses its reviewed privacy/mutation boundary: $forbidden"
    }
}
if ((Get-PatchletLiteralCount -Text $joinedProductionAssets `
        -Literal 'https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/reports') -ne 1) {
    throw 'The exact report write URL must occur once, only in the patchlet-070 endpoint class.'
}
$installStatsText = Get-NormalizedPatchletText -Path (
    Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\InstallStats.java')
$installStatsPayloadText = Get-NormalizedPatchletText -Path (
    Join-Path $assetsRoot 'autoblock\java\threadsmod\reporting\InstallStatsPayload.java')
if ((Get-PatchletLiteralCount -Text $joinedProductionAssets -Literal 'setRequestMethod("POST")') -ne 2 `
        -or (Get-PatchletLiteralCount -Text $joinedProductionAssets -Literal 'getOutputStream()') -ne 2 `
        -or (Get-PatchletLiteralCount -Text $reportClientText -Literal 'ReportEndpoint.writeUrl()') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reportClientText -Literal 'ReportEndpoint.statsUrl()') -ne 0 `
        -or (Get-PatchletLiteralCount -Text $installStatsText -Literal 'ReportEndpoint.statsUrl()') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $installStatsText -Literal 'ReportEndpoint.writeUrl()') -ne 0 `
        -or (Get-PatchletLiteralCount -Text $installStatsText -Literal 'setRequestMethod("POST")') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $installStatsText -Literal 'getOutputStream()') -ne 1) {
    throw 'The two reviewed write paths must be exactly one consented report POST through ReportEndpoint.writeUrl and one activation-statistics POST through ReportEndpoint.statsUrl.'
}
foreach ($forbiddenStatsInput in @(
    'getCurrentViewer', 'viewerId', 'targetId', 'getProfileId', 'ReportPayload',
    'ReportStore', 'ANDROID_ID', 'getDeviceId', 'AdvertisingId', 'ReportEndpoint.writeUrl'
)) {
    if ($installStatsText.Contains($forbiddenStatsInput, [StringComparison]::Ordinal) `
            -or $installStatsPayloadText.Contains($forbiddenStatsInput, [StringComparison]::Ordinal)) {
        throw "Activation statistics must not read account, report, or device-identifier state: $forbiddenStatsInput"
    }
}
if (-not $installStatsText.Contains('"install:v1"', [StringComparison]::Ordinal) `
        -or -not $installStatsText.Contains('stats_install_secret_v1', [StringComparison]::Ordinal) `
        -or -not $installStatsText.Contains('stats_sent_build_v1', [StringComparison]::Ordinal)) {
    throw 'Activation statistics must derive one domain-separated install identifier and persist its send-once marker.'
}
foreach ($requiredReportProof in @(
    'ReportEndpoint.writeUrl()',
    'CookieHandler.getDefault() != null',
    'ReportStore.reserveNextDue(',
    'ReportStore.EnqueueResult.NEEDS_REVIEW',
    'ReportResult.OUTBOX_NEEDS_REVIEW',
    'setInstanceFollowRedirects(false)',
    'response.complete && response.validUtf8 && hasOkTrue(response.text)',
    'ReportJson.isCompleteObject(body)',
    'Boolean.TRUE.equals(response.opt("ok"))',
    'transport.httpStatus == 403',
    'retryPendingNowAsync(',
    'cancelPendingAsync('
)) {
    if (-not $reportClientText.Contains($requiredReportProof, [StringComparison]::Ordinal)) {
        throw "Report client proof is missing: $requiredReportProof"
    }
}
foreach ($retiredReportFlowSymbol in @(
        'ReportDialog',
        'InlineReportClick',
        'showFromForeground(',
        'showConsent(',
        'prepareExplicit(',
        'submitPrepared(',
        'PreparedReport',
        'previewJson(',
        'Review report',
        'Block or report?',
        'ui_one_click_block',
        'ui_dismiss_after_block')) {
    if ($joinedProductionAssets.Contains(
            $retiredReportFlowSymbol, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Retired separate report/review/one-click symbol remains: $retiredReportFlowSymbol"
    }
}
$queueControllerCode = Get-JavaBlockBody -Text $reportControllerCode `
    -Anchor 'publicstaticvoidqueueFromForeground(finalActivityinitiatingActivity,finalStringinitiatingViewerId,finalReportRequestrequest,finalStringreason,finalReportResultCallbackcallback)' `
    -Label 'ReportController.queueFromForeground'
foreach ($queueControllerProof in @(
        'Looper.myLooper()!=Looper.getMainLooper()',
        'AutoBlockSync.getForegroundActivity()!=initiatingActivity',
        '!initiatingViewerId.equals(AutoBlockSync.getCurrentViewer())',
        '!request.isValidForNewQueue()',
        'ReportPayload.isReason(reason)',
        'request.isViewer(initiatingViewerId)',
        'ReportClient.queueExplicit(')) {
    if (-not $queueControllerCode.Contains(
            $queueControllerProof, [StringComparison]::Ordinal)) {
        throw "Combined-modal report controller proof is missing: $queueControllerProof"
    }
}
if ((Get-PatchletLiteralCount -Text $reportControllerCode `
        -Literal 'ReportClient.queueExplicit(') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $queueControllerCode `
            -Literal 'request.isValidForNewQueue()') -ne 1 `
        -or $reportControllerCode.Contains('ReportDialog', [StringComparison]::Ordinal) `
        -or $reportControllerCode.Contains('CheckBox', [StringComparison]::Ordinal)) {
    throw 'Combined-modal Report controller does not expose one direct queue handoff without a second UI.'
}
$queueExplicitCode = Get-JavaBlockBody -Text $reportClientCode `
    -Anchor 'staticvoidqueueExplicit(' `
    -Label 'ReportClient.queueExplicit'
foreach ($queueExplicitProof in @(
        '!request.isValidForNewQueue()',
        'ReportStore.preparePseudonym(',
        'ReportPayload.create(',
        'safeReason,"",currentLanguage(),currentTimeZone()',
        'finalintsafeGeneration=foregroundGeneration(viewerId);',
        'persistExplicit(')) {
    if (-not $queueExplicitCode.Contains($queueExplicitProof, [StringComparison]::Ordinal)) {
        throw "One-step explicit report preparation is missing: $queueExplicitProof"
    }
}
if ($queueExplicitCode.Contains('ReportStore.enqueue(', [StringComparison]::Ordinal) `
        -or $queueExplicitCode.Contains('startDrain(', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $queueExplicitCode `
            -Literal 'request.isValidForNewQueue()') -ne 1) {
    throw 'Report preparation may not deliver before the dedicated durable persistence method succeeds.'
}
$preparePseudonymCode = Get-JavaBlockBody -Text $reportStoreCode `
    -Anchor 'staticsynchronizedPseudonymDraftpreparePseudonym(Contextcontext,StringviewerId)' `
    -Label 'ReportStore.preparePseudonym'
foreach ($forbiddenPseudonymWrite in @('.commit()', 'writableDatabase(', 'getWritableDatabase(', 'insertOrThrow(', 'update(', 'delete(')) {
    if ($preparePseudonymCode.Contains($forbiddenPseudonymWrite, [StringComparison]::Ordinal)) {
        throw "Pseudonym preparation writes before the durable report transaction: $forbiddenPseudonymWrite"
    }
}
$persistExplicitCode = Get-JavaBlockBody -Text $reportClientCode `
    -Anchor 'privatestaticvoidpersistExplicit(' `
    -Label 'ReportClient.persistExplicit'
$commitPseudonymIndex = $persistExplicitCode.IndexOf(
    'ReportStore.commitPseudonym(', [StringComparison]::Ordinal)
$enqueueExplicitIndex = $persistExplicitCode.IndexOf(
    'ReportStore.enqueue(', [StringComparison]::Ordinal)
$acceptedIndex = $persistExplicitCode.IndexOf(
    'stored.code==ReportStore.EnqueueResult.ACCEPTED', $enqueueExplicitIndex,
    [StringComparison]::Ordinal)
$acceptedDrainIndex = $persistExplicitCode.IndexOf(
    'startDrain();', $acceptedIndex, [StringComparison]::Ordinal)
if ($commitPseudonymIndex -lt 0 `
        -or $enqueueExplicitIndex -le $commitPseudonymIndex `
        -or $acceptedIndex -le $enqueueExplicitIndex `
        -or $acceptedDrainIndex -le $acceptedIndex `
        -or (Get-PatchletLiteralCount -Text $persistExplicitCode `
            -Literal 'ReportStore.enqueue(') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $persistExplicitCode `
            -Literal 'startDrain();') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $persistExplicitCode `
            -Literal 'isActive(viewerId,expectedGeneration)') -lt 2 `
        -or $persistExplicitCode.Contains('ReportPayload.create(', [StringComparison]::Ordinal) `
        -or $reportClientCode.Contains('EnqueueResult.DUPLICATE', [StringComparison]::Ordinal) `
        -or $joinedReportJava.Contains('ALREADY_QUEUED', [StringComparison]::Ordinal)) {
    throw 'Report delivery is not generation-bound and strictly after one durable per-action enqueue.'
}
foreach ($strictResponseProof in @(
    'Stringtext=ReportJson.decodeUtf8(collected.toByteArray());',
    'response.complete&&response.validUtf8&&hasOkTrue(response.text)',
    'ReportJson.isCompleteObject(body)',
    'Boolean.TRUE.equals(response.opt("ok"))'
)) {
    if (-not $reportClientCode.Contains($strictResponseProof, [StringComparison]::Ordinal)) {
        throw "Report acknowledgement boundary is missing: $strictResponseProof"
    }
}
foreach ($strictParserProof in @(
    'onMalformedInput(CodingErrorAction.REPORT)',
    'onUnmappableCharacter(CodingErrorAction.REPORT)',
    'Set<String>names=newHashSet<String>();',
    'name==null||!names.add(name)',
    'parser.skipWhitespace();returnparser.atEnd();'
)) {
    if (-not $reportJsonCode.Contains($strictParserProof, [StringComparison]::Ordinal)) {
        throw "Strict report JSON/UTF-8 parser proof is missing: $strictParserProof"
    }
}
if ((Get-PatchletLiteralCount -Text $reportStoreText `
        -Literal 'result = new EnqueueResult(EnqueueResult.NEEDS_REVIEW, "");') -lt 3) {
    throw 'Report enqueue must return review state after either transaction exception or uncertain commit.'
}
$snapshotCode = Get-JavaBlockBody -Text $reportStoreCode `
    -Anchor 'publicstaticsynchronizedSnapshotgetSnapshot(Contextcontext,StringviewerId)' `
    -Label 'ReportStore.getSnapshot'
$snapshotPseudonymIndex = $snapshotCode.IndexOf(
    'StringexpectedPseudonym=pseudonymFor(context,viewerId);', [StringComparison]::Ordinal)
$snapshotReviewIndex = $snapshotCode.IndexOf(
    'StringdetectedReview=reviewState(scope);', $snapshotPseudonymIndex, [StringComparison]::Ordinal)
$snapshotReviewReturnIndex = $snapshotCode.IndexOf(
    'returnemptySnapshot(detectedReview);', $snapshotReviewIndex, [StringComparison]::Ordinal)
$snapshotLoadIndex = $snapshotCode.IndexOf(
    'List<StoredRow>rows=loadOutbox(', $snapshotReviewReturnIndex, [StringComparison]::Ordinal)
if ($snapshotPseudonymIndex -lt 0 -or $snapshotReviewIndex -le $snapshotPseudonymIndex `
        -or $snapshotReviewReturnIndex -le $snapshotReviewIndex `
        -or $snapshotLoadIndex -le $snapshotReviewReturnIndex) {
    throw 'Report snapshot must surface a pseudonym read failure as the exact review state before loading rows.'
}
$nextWakeCode = Get-JavaBlockBody -Text $reportStoreCode `
    -Anchor 'staticsynchronizedlongnextWakeAt(Contextcontext,StringviewerId)' `
    -Label 'ReportStore.nextWakeAt'
$nextWakePseudonymIndex = $nextWakeCode.IndexOf(
    'StringexpectedPseudonym=pseudonymFor(context,viewerId);', [StringComparison]::Ordinal)
$nextWakeReviewIndex = $nextWakeCode.IndexOf(
    'if(reviewState(scope)!=null){return0L;}', $nextWakePseudonymIndex, [StringComparison]::Ordinal)
$nextWakeCountIndex = $nextWakeCode.IndexOf(
    'countOutbox(db,scope)', $nextWakeReviewIndex, [StringComparison]::Ordinal)
if ($nextWakePseudonymIndex -lt 0 -or $nextWakeReviewIndex -le $nextWakePseudonymIndex `
        -or $nextWakeCountIndex -le $nextWakeReviewIndex) {
    throw 'Report wake scheduling must stop on a pseudonym read review state before treating the outbox as empty.'
}
if ((Get-PatchletLiteralCount -Text $reportClientText -Literal '!storageReady(preflight)') -ne 7) {
    throw 'Every report persist/retry/cancel/drain path must fail closed on the full-store preflight.'
}
$drainStart = $reportClientText.IndexOf('private static void drain(', [StringComparison]::Ordinal)
$drainPreflight = $reportClientText.IndexOf('ReportStore.getSnapshot(context, viewerId)', $drainStart, [StringComparison]::Ordinal)
$drainGuard = $reportClientText.IndexOf('if (!storageReady(preflight)', $drainPreflight, [StringComparison]::Ordinal)
$drainReserve = $reportClientText.IndexOf('ReportStore.reserveNextDue(', $drainGuard, [StringComparison]::Ordinal)
if ($drainStart -lt 0 -or $drainPreflight -lt $drainStart -or $drainGuard -lt $drainPreflight `
        -or $drainReserve -lt $drainGuard) {
    throw 'Report drain must validate the complete viewer store before reserving any POST attempt.'
}
if (-not $reportRequestText.Contains('&& postContent.length() > 0', [StringComparison]::Ordinal)) {
    throw 'Report request does not require a non-empty trimmed post excerpt.'
}
foreach ($requiredCombinedDisclosureText in @(
    'queues a report for background delivery',
    'stable pseudonym',
    'language/time zone',
    'IP address',
    'User-Agent',
    'approximate location',
    'cancellation can fail once delivery is active',
    'accepted report cannot be recalled'
)) {
    if (-not $dialogStringsText.Contains(
            $requiredCombinedDisclosureText,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Combined modal report disclosure is incomplete: $requiredCombinedDisclosureText"
    }
}
foreach ($requiredStoreProof in @(
    'NEEDS_REVIEW',
    'extends SQLiteOpenHelper',
    'DATABASE_NAME = "threadsmod_reporting.db"',
    'DATABASE_VERSION = 2',
    'OUTBOX_V1_SQL',
    'OUTBOX_V2_SQL',
    'TABLE_OUTBOX = "report_outbox"',
    'TABLE_HISTORY = "report_history"',
    'MAX_OUTBOX = 1000',
    'MAX_HISTORY = 500',
    'MAX_PAYLOAD_BYTES = 16 * 1024',
    'utf8Length(payloadJson)',
    'ReportJson.isCompleteObject(payloadJson)',
    'payload.targetKey().equals(targetKey)',
    'expectedPseudonym',
    'db.beginTransaction()',
    'db.setTransactionSuccessful()',
    'PRAGMA quick_check(1)',
    'UNIQUE(viewer_key,target_key)',
    'CREATE INDEX report_outbox_due_idx',
    'CREATE INDEX report_history_viewer_idx',
    'report database corruption requires review',
    'ACTIVE_DELIVERIES.containsKey(safeReportId)',
    'LOCAL_STATE_DURABILITY_UNCERTAIN',
    'Delivery could not be confirmed after 15 attempts',
    'the server may have accepted it'
)) {
    if (-not $reportStoreText.Contains($requiredStoreProof, [StringComparison]::Ordinal)) {
        throw "Report durable outbox proof is missing: $requiredStoreProof"
    }
}
$reportUpgradeCode = Get-JavaBlockBody -Text $reportStoreCode `
    -Anchor 'publicvoidonUpgrade(SQLiteDatabasedb,intoldVersion,intnewVersion)' `
    -Label 'ReportStore.DatabaseHelper.onUpgrade'
foreach ($requiredReportUpgradeProof in @(
        'if(oldVersion!=1||newVersion!=2)',
        'requireMigrationIntegrity(db);',
        'longsourceRows=countAllRows(db,TABLE_OUTBOX);',
        'db.execSQL("DROPINDEXreport_outbox_due_idx")',
        'db.execSQL("ALTERTABLE"+TABLE_OUTBOX+"RENAMETOreport_outbox_v1")',
        'createOutboxV2(db);',
        'INSERTINTO',
        'longcopiedRows=countAllRows(db,TABLE_OUTBOX);',
        'if(copiedRows!=sourceRows)',
        'db.execSQL("DROPTABLEreport_outbox_v1")',
        'createOutboxDueIndex(db);')) {
    if (-not $reportUpgradeCode.Contains(
            $requiredReportUpgradeProof, [StringComparison]::Ordinal)) {
        throw "Report v1-to-v2 migration proof is missing: $requiredReportUpgradeProof"
    }
}
if (-not $reportStoreCode.Contains(
        'forbidSchemaObjectFragment(database,"table",TABLE_OUTBOX,"unique(viewer_key,target_key)")',
        [StringComparison]::Ordinal) `
        -or -not $reportStoreCode.Contains(
            'requireExactSchemaObject(database,"table",TABLE_OUTBOX,OUTBOX_V2_SQL);',
            [StringComparison]::Ordinal) `
        -or $reportStoreCode.Contains('staticfinalintDUPLICATE=', [StringComparison]::Ordinal)) {
    throw 'Report schema v2 does not allow one durable outbox row per explicit positive action.'
}
foreach ($requiredMutationProof in @(
    'boolean insertedHistory = false;',
    'if (insertedHistory) {',
    'WHERE viewer_key=? ORDER BY row_id DESC LIMIT',
    'isPlausibleStoredTime(createdAt)',
    'isPlausibleStoredTime(nextAt)',
    'validateSnapshotIdentity(rows, storedHistory, viewerId);',
    'viewerId.equals(row.payload.getTargetId())',
    'viewerId.equals(row.targetId)',
    'targetUser.length() == 0',
    'HISTORY_GAVE_UP.equals(outcome) && tries == 15L'
)) {
    if (-not $reportStoreText.Contains($requiredMutationProof, [StringComparison]::Ordinal)) {
        throw "Report full-store/trim safety proof is missing: $requiredMutationProof"
    }
}
if ($reportStoreText.Contains('validateScope(', [StringComparison]::Ordinal)) {
    throw 'Full report-store scans must stay in asynchronous Snapshot preflights, not indexed row mutations.'
}
foreach ($requiredEpochProof in @(
    'hasTrustedStore(viewerId, expectedGeneration)',
    'trustStoreIfActive(viewerId, expectedGeneration)',
    'boolean immediatePending = isActive(viewerId, expectedGeneration)',
    'if (!immediatePending) {',
    'Math.min(nextAt - now, MAX_WAKE_DELAY_MS)',
    'finishDrain(viewerId, expectedGeneration, nextAt)',
    'workerGeneration != generation',
    '!workerViewerId.equals(activeViewerId)',
    'drainRequested = true;',
    'drainRequestedGeneration = generation;',
    'drainRequestedGeneration == workerGeneration',
    'if (contextReplaced || rerunRequested) {',
    'startDrain();'
)) {
    if (-not $reportClientText.Contains($requiredEpochProof, [StringComparison]::Ordinal)) {
        throw "Report delivery epoch/wake safety proof is missing: $requiredEpochProof"
    }
}
if ($reportStoreText.Contains('deleteDatabase(', [StringComparison]::OrdinalIgnoreCase) `
        -or $reportStoreText.Contains('validateOutbox(', [StringComparison]::Ordinal)) {
    throw 'Report SQLite corruption cannot be deleted/reset or routed through the retired JSON-array store.'
}
foreach ($requiredUiProof in @(
    'ReportClient.getLocalStatusAsync(',
    'ReportClient.retryPendingNowAsync(',
    'ReportClient.cancelPendingAsync(',
    'pending.inFlight',
    'reports.needsReview',
    'reports.terminalNotice',
    'ReportStore.CancelResult.IN_FLIGHT',
    'Cancellation can race an active POST',
    'cannot retract a server-accepted copy',
    'Unconfirmed'
)) {
    if (-not $activityText.Contains($requiredUiProof, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Report Activity review/cancel proof is missing: $requiredUiProof"
    }
}
foreach ($requiredSettingsProof in @(
    'ReportClient.getLocalStatusAsync(',
    '280 UTF-16 units',
    'canonical Threads post permalink as targetUrl and the sole evidence entry',
    'stored before any network attempt',
    'full connection IP address',
    'server backups include',
    'no automatic expiry before administrative deletion',
    'Pending payloads can remain viewer-scoped indefinitely',
    'no time-based expiry',
    'Cancellation can race active delivery',
    'Unconfirmed'
)) {
    if (-not $settingsText.Contains($requiredSettingsProof, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Report Settings disclosure/status proof is missing: $requiredSettingsProof"
    }
}
foreach ($requiredOwnerProof in @(
    'ReportClient.ForegroundOwner',
    'reportOwnerActivity.get() == activity',
    'ReportClient.onBackground(owner)'
)) {
    if (-not $bootstrapText.Contains($requiredOwnerProof, [StringComparison]::Ordinal)) {
        throw "Report foreground owner-token proof is missing: $requiredOwnerProof"
    }
}
foreach ($requiredEndpointProof in @(
    'public final class ReportEndpoint',
    'WRITE_PATH = "/v1/reports"',
    '!WRITE_URL.equals(url.toExternalForm())'
)) {
    if (-not $endpointText.Contains($requiredEndpointProof, [StringComparison]::Ordinal)) {
        throw "Patchlet-070 endpoint proof is missing: $requiredEndpointProof"
    }
}
$forbiddenOrigin = 'tree55.com'
if ($joinedProductionAssets.Contains($forbiddenOrigin, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Forbidden ISP-blocked origin appears in a compiled Java or rendered-template asset.'
}
$joinedInlineTemplates = $inlineTemplateText -join "`n"
$joinedReportTemplates = $reportTemplateText -join "`n"
$joinedStableInlineReportTemplates = $joinedInlineTemplates + "`n" + $joinedReportTemplates
$expectedReportSymbolNames = @(
    'captionTextMethod',
    'mediaBackingField',
    'mediaCaptionMethod',
    'mediaCodeMethod',
    'mediaDescriptor',
    'mediaPermalinkMethod'
)
$actualReportSymbolNames = @(
    $resolution.reporting.symbols.PSObject.Properties.Name | Sort-Object)
if (@(Compare-Object -ReferenceObject $expectedReportSymbolNames `
            -DifferenceObject $actualReportSymbolNames).Count -ne 0) {
    throw 'Reporting resolution must own only the captured media descriptor, code, permalink, and caption extraction symbols.'
}
$reportMediaDescriptor = [string]$resolution.reporting.symbols.mediaDescriptor
$inlineMediaLookupMethod = [string]$resolution.inlineControls.symbols.mediaLookupMethod
if ([string]::IsNullOrWhiteSpace($reportMediaDescriptor) `
        -or -not $inlineMediaLookupMethod.EndsWith(")$reportMediaDescriptor", [StringComparison]::Ordinal) `
        -or -not ([string]$resolution.reporting.symbols.mediaBackingField).StartsWith(
            "$reportMediaDescriptor->", [StringComparison]::Ordinal)) {
    throw 'Reporting mediaDescriptor does not exactly match the host-captured media model and backing-field receiver.'
}
if ($normalizedSourceVersion -ceq '444.0.0.45.85' `
        -and (([string]$resolution.reporting.symbols.mediaCodeMethod) -cne `
            'Lcom/instagram/feed/media/Media;->A75()Ljava/lang/String;' `
        -or ([string]$resolution.reporting.symbols.mediaPermalinkMethod) -cne `
            'Lcom/instagram/feed/media/Media;->A7o()Ljava/lang/String;')) {
    throw 'The exact 444 reporting resolution must bind Media.A75 as code and Media.A7o as fallback permalink.'
}
foreach ($retiredReportSymbol in @(
        'ufiConfigDescriptor', 'sessionDescriptor', 'ufiMediaIdField',
        'mediaLookupMethod', 'mediaAuthorMethod', 'authorIdMethod',
        'authorUsernameMethod', 'alreadyBlockedMethod')) {
    if ($resolution.reporting.symbols.PSObject.Properties.Name -contains $retiredReportSymbol) {
        throw "Reporting resolution still owns a retired duplicate row/private seam: $retiredReportSymbol"
    }
}
$privateInlineSymbols = $resolution.inlineControls.symbols
$bridgeAlreadyBlockedMethod = [string]$resolution.bridge.symbols.alreadyBlockedMethod
$forbiddenStableTemplateSeams = @(
    '{{mediaLookupMethod}}',
    '{{mediaAuthorMethod}}',
    '{{authorIdMethod}}',
    '{{authorUsernameMethod}}',
    '{{alreadyBlockedMethod}}',
    [string]$privateInlineSymbols.mediaLookupMethod,
    [string]$privateInlineSymbols.mediaAuthorMethod,
    [string]$privateInlineSymbols.authorIdMethod,
    [string]$privateInlineSymbols.authorUsernameMethod,
    $bridgeAlreadyBlockedMethod,
    '->getId()Ljava/lang/String;'
)
foreach ($forbiddenStableTemplateSeam in @($forbiddenStableTemplateSeams | Select-Object -Unique)) {
    if (-not [string]::IsNullOrWhiteSpace($forbiddenStableTemplateSeam) `
            -and $joinedStableInlineReportTemplates.Contains(
                $forbiddenStableTemplateSeam, [StringComparison]::Ordinal)) {
        throw "Stable inline/report templates retain a raw host author/private seam: $forbiddenStableTemplateSeam"
    }
}
foreach ($requiredTemplateProof in @(
    '{{mediaDescriptor}}',
    '{{mediaPermalinkMethod}}',
    '{{mediaCodeMethod}}',
    '{{mediaCaptionMethod}}',
    '{{captionTextMethod}}',
    'InlineBlockRequest;->getMediaKey()Ljava/lang/String;',
    'InlineBlockRequest;->getAuthorId()Ljava/lang/String;',
    'InlineBlockRequest;->getLabel()Ljava/lang/String;',
    'InlineBlockRequest;->getResolvedMediaModel()Ljava/lang/Object;',
    'ReportRequest;-><init>(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V',
    'ReportRequest;->isValid()Z',
    'ReportRequest;->getPermalink()Ljava/lang/String;',
    'ReportRequest;->resolveHostPermalink(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;',
    'ReportRequest;->resolveHostExcerpt(Ljava/lang/String;)Ljava/lang/String;',
    '.class public final Lthreadsmod/reporting/InlineReportActionFactory;',
    '.method public static createRequest'
)) {
    if (-not $joinedReportTemplates.Contains($requiredTemplateProof, [StringComparison]::Ordinal)) {
        throw "Inline Report template proof is missing: $requiredTemplateProof"
    }
}
$requiredReportRequestCalls = @(
    'InlineBlockRequest;->isValid()Z',
    'InlineBlockRequest;->getMediaKey()Ljava/lang/String;',
    'InlineBlockRequest;->getAuthorId()Ljava/lang/String;',
    'InlineBlockRequest;->getLabel()Ljava/lang/String;',
    'InlineBlockRequest;->getResolvedMediaModel()Ljava/lang/Object;'
)
foreach ($requiredReportRequestCall in $requiredReportRequestCalls) {
    if ((Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
                -Literal $requiredReportRequestCall) -ne 1) {
        throw "Inline Report factory must consume the immutable request getter exactly once: $requiredReportRequestCall"
    }
}
$factoryPermalinkInvoke = '{{mediaPermalinkMethod}}'
$factoryCodeInvoke = '{{mediaCodeMethod}}'
$factoryCaptionInvoke = '{{mediaCaptionMethod}}'
$factoryPermalinkResolver = `
    'invoke-static {v5, v9, v7}, Lthreadsmod/reporting/ReportRequest;->resolveHostPermalink(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;'
$factoryExcerptResolver = `
    'invoke-static {v6}, Lthreadsmod/reporting/ReportRequest;->resolveHostExcerpt(Ljava/lang/String;)Ljava/lang/String;'
$factorySixStringConstructor = `
    'invoke-direct/range {v8 .. v14}, Lthreadsmod/reporting/ReportRequest;-><init>(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V'
$factoryLegacyFourStringConstructor = `
    'ReportRequest;-><init>(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V'
$factoryPermalinkGetter = `
    'invoke-virtual {v8}, Lthreadsmod/reporting/ReportRequest;->getPermalink()Ljava/lang/String;'
$factoryCodeIndex = $reportActionFactoryTemplateText.IndexOf(
    $factoryCodeInvoke, [StringComparison]::Ordinal)
$factoryCodeResultIndex = $reportActionFactoryTemplateText.IndexOf(
    'move-result-object v7', $factoryCodeIndex + $factoryCodeInvoke.Length,
    [StringComparison]::Ordinal)
$factoryEmptyCandidateIndex = $reportActionFactoryTemplateText.IndexOf(
    'const-string v9, ""', $factoryCodeResultIndex,
    [StringComparison]::Ordinal)
$factoryFirstPermalinkResolverIndex = $reportActionFactoryTemplateText.IndexOf(
    $factoryPermalinkResolver, $factoryEmptyCandidateIndex,
    [StringComparison]::Ordinal)
$factoryFirstResolverResultIndex = $reportActionFactoryTemplateText.IndexOf(
    'move-result-object v9',
    $factoryFirstPermalinkResolverIndex + $factoryPermalinkResolver.Length,
    [StringComparison]::Ordinal)
$factoryFirstResolverLengthIndex = $reportActionFactoryTemplateText.IndexOf(
    'invoke-virtual {v9}, Ljava/lang/String;->length()I',
    $factoryFirstResolverResultIndex, [StringComparison]::Ordinal)
$factoryFirstResolverLengthResultIndex = $reportActionFactoryTemplateText.IndexOf(
    'move-result v4', $factoryFirstResolverLengthIndex,
    [StringComparison]::Ordinal)
$factoryFallbackGuardIndex = $reportActionFactoryTemplateText.IndexOf(
    'if-nez v4, :permalink_ready', $factoryFirstResolverLengthResultIndex,
    [StringComparison]::Ordinal)
$factoryPermalinkIndex = $reportActionFactoryTemplateText.IndexOf(
    $factoryPermalinkInvoke, $factoryFallbackGuardIndex,
    [StringComparison]::Ordinal)
$factoryPermalinkResultIndex = $reportActionFactoryTemplateText.IndexOf(
    'move-result-object v9', $factoryPermalinkIndex + $factoryPermalinkInvoke.Length,
    [StringComparison]::Ordinal)
$factoryEmptyCodeIndex = $reportActionFactoryTemplateText.IndexOf(
    'const-string v7, ""', $factoryPermalinkResultIndex,
    [StringComparison]::Ordinal)
$factorySecondPermalinkResolverIndex = $reportActionFactoryTemplateText.IndexOf(
    $factoryPermalinkResolver, $factoryEmptyCodeIndex,
    [StringComparison]::Ordinal)
$factorySecondResolverResultIndex = $reportActionFactoryTemplateText.IndexOf(
    'move-result-object v9',
    $factorySecondPermalinkResolverIndex + $factoryPermalinkResolver.Length,
    [StringComparison]::Ordinal)
$factoryPermalinkReadyIndex = $reportActionFactoryTemplateText.IndexOf(
    ':permalink_ready', $factorySecondResolverResultIndex,
    [StringComparison]::Ordinal)
$factoryCaptionIndex = $reportActionFactoryTemplateText.IndexOf(
    $factoryCaptionInvoke, $factoryPermalinkReadyIndex,
    [StringComparison]::Ordinal)
$factoryExcerptResolverIndex = $reportActionFactoryTemplateText.IndexOf(
    $factoryExcerptResolver, [StringComparison]::Ordinal)
$factoryPermalinkCall = [regex]::Match(
    $reportActionFactoryTemplateText,
    '(?m)^\s*invoke-(?<opcode>interface|virtual)\s+\{(?<receiver>v\d+)\},\s+' +
        [regex]::Escape($factoryPermalinkInvoke) + '\s*$')
$factoryCodeCall = [regex]::Match(
    $reportActionFactoryTemplateText,
    '(?m)^\s*invoke-(?<opcode>interface|virtual)\s+\{(?<receiver>v\d+)\},\s+' +
        [regex]::Escape($factoryCodeInvoke) + '\s*$')
$factoryCaptionCall = [regex]::Match(
    $reportActionFactoryTemplateText,
    '(?m)^\s*invoke-(?<opcode>interface|virtual)\s+\{(?<receiver>v\d+)\},\s+' +
        [regex]::Escape($factoryCaptionInvoke) + '\s*$')
$factoryBackingTokenCount = Get-PatchletLiteralCount `
    -Text $reportActionFactoryTemplateText -Literal '{{mediaBackingField}}'
$factoryMediaAccessTopologyValid = $factoryPermalinkCall.Success `
    -and $factoryCodeCall.Success `
    -and $factoryCaptionCall.Success `
    -and $factoryPermalinkCall.Groups['receiver'].Value `
        -ceq $factoryCodeCall.Groups['receiver'].Value `
    -and $factoryPermalinkCall.Groups['receiver'].Value `
        -ceq $factoryCaptionCall.Groups['receiver'].Value
if ($factoryMediaAccessTopologyValid -and $factoryBackingTokenCount -eq 1) {
    $factoryMediaAccessTopologyValid =
        $factoryPermalinkCall.Groups['opcode'].Value -ceq 'interface' `
        -and $factoryCodeCall.Groups['opcode'].Value -ceq 'interface' `
        -and $factoryCaptionCall.Groups['opcode'].Value -ceq 'interface' `
        -and [regex]::IsMatch(
            $reportActionFactoryTemplateText,
            '(?m)^\s*iget-object\s+' +
                [regex]::Escape($factoryPermalinkCall.Groups['receiver'].Value) +
                ',\s+v1,\s+\{\{mediaBackingField\}\}\s*$')
} elseif ($factoryMediaAccessTopologyValid -and $factoryBackingTokenCount -eq 0) {
    $factoryMediaAccessTopologyValid =
        $factoryPermalinkCall.Groups['opcode'].Value -ceq 'virtual' `
        -and $factoryCodeCall.Groups['opcode'].Value -ceq 'virtual' `
        -and $factoryCaptionCall.Groups['opcode'].Value -ceq 'virtual' `
        -and $factoryPermalinkCall.Groups['receiver'].Value -ceq 'v1'
} else {
    $factoryMediaAccessTopologyValid = $false
}
$factoryConstructorIndex = $reportActionFactoryTemplateText.IndexOf(
    $factorySixStringConstructor, [StringComparison]::Ordinal)
$factoryPermalinkGetterIndex = $reportActionFactoryTemplateText.IndexOf(
    $factoryPermalinkGetter, [StringComparison]::Ordinal)
$factoryPermalinkLengthIndex = $reportActionFactoryTemplateText.IndexOf(
    'invoke-virtual {v4}, Ljava/lang/String;->length()I',
    $factoryPermalinkGetterIndex + $factoryPermalinkGetter.Length,
    [StringComparison]::Ordinal)
$factoryEmptyPermalinkRejectIndex = $reportActionFactoryTemplateText.IndexOf(
    'if-eqz v4, :return_null',
    $factoryPermalinkLengthIndex + 'invoke-virtual {v4}, Ljava/lang/String;->length()I'.Length,
    [StringComparison]::Ordinal)
$factoryReturnIndex = $reportActionFactoryTemplateText.IndexOf(
    'return-object v8', [StringComparison]::Ordinal)
$factoryFallbackSlice = if ($factoryFallbackGuardIndex -ge 0 `
        -and $factoryPermalinkReadyIndex -gt $factoryFallbackGuardIndex) {
    $reportActionFactoryTemplateText.Substring(
        $factoryFallbackGuardIndex,
        $factoryPermalinkReadyIndex - $factoryFallbackGuardIndex)
} else { '' }
if ((Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal $factoryPermalinkInvoke) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal $factoryCodeInvoke) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal $factoryPermalinkResolver) -ne 2 `
        -or (Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal $factoryCaptionInvoke) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal $factoryExcerptResolver) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal $factoryPermalinkGetter) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal $factorySixStringConstructor) -ne 1 `
        -or $reportActionFactoryTemplateText.Contains(
            $factoryLegacyFourStringConstructor, [StringComparison]::Ordinal) `
        -or $factoryCodeIndex -lt 0 `
        -or $factoryCodeResultIndex -le $factoryCodeIndex `
        -or $factoryEmptyCandidateIndex -le $factoryCodeResultIndex `
        -or $factoryFirstPermalinkResolverIndex -le $factoryEmptyCandidateIndex `
        -or $factoryFirstResolverResultIndex -le $factoryFirstPermalinkResolverIndex `
        -or $factoryFirstResolverLengthIndex -le $factoryFirstResolverResultIndex `
        -or $factoryFirstResolverLengthResultIndex -le $factoryFirstResolverLengthIndex `
        -or $factoryFallbackGuardIndex -le $factoryFirstResolverLengthResultIndex `
        -or $factoryPermalinkIndex -le $factoryFallbackGuardIndex `
        -or $factoryPermalinkResultIndex -le $factoryPermalinkIndex `
        -or $factoryEmptyCodeIndex -le $factoryPermalinkResultIndex `
        -or $factorySecondPermalinkResolverIndex -le $factoryEmptyCodeIndex `
        -or $factorySecondResolverResultIndex -le $factorySecondPermalinkResolverIndex `
        -or $factoryPermalinkReadyIndex -le $factorySecondResolverResultIndex `
        -or (Get-PatchletLiteralCount -Text $factoryFallbackSlice `
            -Literal $factoryPermalinkInvoke) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $factoryFallbackSlice `
            -Literal $factoryPermalinkResolver) -ne 1 `
        -or [regex]::Matches($factoryFallbackSlice, '(?m)^\s*:[A-Za-z0-9_]+\s*$').Count -ne 0 `
        -or $factoryFallbackSlice.Contains('goto ', [StringComparison]::Ordinal) `
        -or $factoryCaptionIndex -le $factoryPermalinkReadyIndex `
        -or $factoryExcerptResolverIndex -le $factoryCaptionIndex `
        -or -not $factoryMediaAccessTopologyValid `
        -or $factoryConstructorIndex -le $factoryExcerptResolverIndex `
        -or $factoryPermalinkGetterIndex -le $factoryConstructorIndex `
        -or $factoryPermalinkLengthIndex -le $factoryPermalinkGetterIndex `
        -or $factoryEmptyPermalinkRejectIndex -le $factoryPermalinkLengthIndex `
        -or $factoryReturnIndex -le $factoryEmptyPermalinkRejectIndex) {
    throw 'Inline Report factory must call A75 first, consult A7o only on the empty resolved-code branch, and resolve the no-text excerpt before constructing one valid request.'
}
if ((Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal '.method public static createRequest(Lthreadsmod/inlinecontrol/InlineBlockRequest;)Lthreadsmod/reporting/ReportRequest;') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal 'move-object/from16 v2, p0') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal 'invoke-virtual {v2}, Lthreadsmod/inlinecontrol/InlineBlockRequest;->') -ne 5 `
        -or $reportActionFactoryTemplateText.Contains(
            'invoke-virtual {p0}, Lthreadsmod/inlinecontrol/InlineBlockRequest;->',
            [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal 'check-cast v1, {{mediaDescriptor}}') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $reportActionFactoryTemplateText `
            -Literal '{{mediaDescriptor}}') -ne 1 `
        -or $reportActionFactoryTemplateText.Contains(
            'AutoBlockSync;->getCurrentViewer()', [StringComparison]::Ordinal)) {
    throw 'Inline Report factory does not safely consume exactly one captured media model from the immutable low-register request.'
}
foreach ($forbiddenReportActionCall in @(
        'ReportClient;->', 'ReportStore;->', 'ReportEndpoint;->',
        'ThreadsBlockBridge', 'enqueueManual', 'HttpURLConnection',
        'getOutputStream', 'setRequestMethod', '/v1/reports',
        'ReportController;->', 'Ljava/lang/Runnable;')) {
    if ($reportActionFactoryTemplateText.Contains(
            $forbiddenReportActionCall, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Inline Report request factory contains a direct action/delivery/block path: $forbiddenReportActionCall"
    }
}
if ((Get-PatchletLiteralCount -Text $joinedInlineTemplates `
        -Literal 'InlineReportActionFactory;->createRequest') -ne 1 `
        -or -not $joinedInlineTemplates.Contains(
            'createRequest(Lthreadsmod/inlinecontrol/InlineBlockRequest;)Lthreadsmod/reporting/ReportRequest;',
            [StringComparison]::Ordinal) `
        -or -not $joinedInlineTemplates.Contains(
            'InlineActionClick;-><init>(Lthreadsmod/inlinecontrol/InlineBlockRequest;Lthreadsmod/reporting/ReportRequest;Landroidx/compose/runtime/MutableState;)V',
            [StringComparison]::Ordinal) `
        -or -not $joinedInlineTemplates.Contains(
            'InlineBlockController;->onClick(Lthreadsmod/inlinecontrol/InlineBlockRequest;Lthreadsmod/reporting/ReportRequest;Ljava/lang/Object;Lthreadsmod/inlinecontrol/InlineBlockUiCallback;)V',
            [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text ($joinedInlineTemplates + "`n" + $joinedReportTemplates) `
        -Literal '{{ufiButtonMethod}}') -ne 1 `
        -or (Get-PatchletLiteralCount -Text ($joinedInlineTemplates + "`n" + $joinedReportTemplates) `
        -Literal 'threadsmod_inline_block') -ne 1 `
        -or ($joinedInlineTemplates + "`n" + $joinedReportTemplates).Contains(
            'threadsmod_inline_report', [StringComparison]::Ordinal) `
        -or $joinedReportTemplates.Contains('{{reportIconResourceId}}', [StringComparison]::Ordinal) `
        -or $joinedReportTemplates.Contains('{{ufiButtonMethod}}', [StringComparison]::Ordinal)) {
    throw 'Template families do not prove one immutable ReportRequest feeding exactly one Block UFI control.'
}
$inlineHookSeenIndex = $rowAdapterTemplateText.IndexOf(
    'const-string v4, "hook_seen"', [StringComparison]::Ordinal)
$inlineReportFactoryIndex = $rowAdapterTemplateText.IndexOf(
    'InlineReportActionFactory;->createRequest', [StringComparison]::Ordinal)
$inlineReportUnavailableIndex = $rowAdapterTemplateText.IndexOf(
    'const-string v4, "report_request_unavailable"', [StringComparison]::Ordinal)
$inlineButtonCallIndex = $rowAdapterTemplateText.IndexOf(
    '{{ufiButtonMethod}}', [StringComparison]::Ordinal)
$inlineVisibilityModifierIndex = $rowAdapterTemplateText.IndexOf(
    ([string]$visibilitySymbols.visibilityModifierMethod), [StringComparison]::Ordinal)
$inlineTestTagIndex = $rowAdapterTemplateText.IndexOf(
    '{{testTagMethod}}', $inlineVisibilityModifierIndex, [StringComparison]::Ordinal)
$inlineModifierMaskIndex = $rowAdapterTemplateText.IndexOf(
    'const v12, 0xf700', $inlineTestTagIndex, [StringComparison]::Ordinal)
$inlineButtonRenderedIndex = $rowAdapterTemplateText.IndexOf(
    'const-string v4, "button_rendered"', [StringComparison]::Ordinal)
$inlineAdapterExceptionIndex = $rowAdapterTemplateText.IndexOf(
    'const-string v0, "adapter_exception"', [StringComparison]::Ordinal)
if ($rowAdapterTemplateText.Contains(
        'AutoBlockSync;->getCurrentViewer()', [StringComparison]::Ordinal) `
        -or $reportActionFactoryTemplateText.Contains(
            'AutoBlockSync;->getCurrentViewer()', [StringComparison]::Ordinal) `
        -or $rowAdapterTemplateText.Contains(
            'getCurrentViewer', [StringComparison]::Ordinal) `
        -or $reportActionFactoryTemplateText.Contains(
            'getCurrentViewer', [StringComparison]::Ordinal) `
        -or $rowAdapterTemplateText.Contains(
            'if-eqz v3, :return', [StringComparison]::Ordinal) `
        -or $inlineHookSeenIndex -lt 0 `
        -or $inlineReportFactoryIndex -le $inlineHookSeenIndex `
        -or $inlineReportUnavailableIndex -le $inlineReportFactoryIndex `
        -or $inlineVisibilityModifierIndex -le $inlineReportFactoryIndex `
        -or $inlineTestTagIndex -le $inlineVisibilityModifierIndex `
        -or $inlineModifierMaskIndex -le $inlineTestTagIndex `
        -or $inlineButtonCallIndex -le $inlineReportFactoryIndex `
        -or $inlineButtonCallIndex -le $inlineModifierMaskIndex `
        -or (Get-PatchletLiteralCount -Text $rowAdapterTemplateText `
            -Literal 'const v12, 0xf700') -ne 1 `
        -or $rowAdapterTemplateText.Contains('const v12, 0xf680', [StringComparison]::Ordinal) `
        -or $rowAdapterTemplateText.Contains('const v12, 0xf600', [StringComparison]::Ordinal) `
        -or $inlineButtonRenderedIndex -le $inlineButtonCallIndex `
        -or $inlineAdapterExceptionIndex -le $inlineButtonRenderedIndex) {
    throw 'The 444 inline row must keep its decorated visibility modifier, avoid the 0x80 default-mask replacement, keep the 0x100 native icon-size default so the control is not composed at zero size, remain independent of viewer initialization, and emit fixed diagnostics around its sole native control.'
}
foreach ($inlineDiagnosticStage in @(
        'hook_seen', 'report_request_unavailable', 'button_rendered', 'adapter_exception')) {
    if ((Get-PatchletLiteralCount -Text $rowAdapterTemplateText `
            -Literal ('"' + $inlineDiagnosticStage + '"')) -ne 1) {
        throw "Inline row diagnostic stage is missing or duplicated: $inlineDiagnosticStage"
    }
}
$inlineUnavailableLabelIndex = $rowAdapterTemplateText.IndexOf(
    '    :report_request_unavailable', $inlineHookSeenIndex,
    [StringComparison]::Ordinal)
$inlineRequestReadyLabelIndex = $rowAdapterTemplateText.IndexOf(
    '    :report_request_ready', $inlineUnavailableLabelIndex,
    [StringComparison]::Ordinal)
$inlinePrerequisiteSlice = if ($inlineUnavailableLabelIndex -gt $inlineHookSeenIndex) {
    $rowAdapterTemplateText.Substring(
        $inlineHookSeenIndex, $inlineUnavailableLabelIndex - $inlineHookSeenIndex)
} else { '' }
$inlineUnavailableSlice = if ($inlineUnavailableLabelIndex -ge 0 `
        -and $inlineRequestReadyLabelIndex -gt $inlineUnavailableLabelIndex) {
    $rowAdapterTemplateText.Substring(
        $inlineUnavailableLabelIndex,
        $inlineRequestReadyLabelIndex - $inlineUnavailableLabelIndex)
} else { '' }
foreach ($inlinePrerequisiteBranch in @(
        @('if-eqz v3, :report_request_unavailable', 1, 'host row snapshot'),
        @('if-eqz v7, :report_request_unavailable', 1, 'media ID'),
        @('if-eqz v4, :report_request_unavailable', 2, 'media-key/request validity'),
        @('if-eqz v8, :report_request_unavailable', 1, 'author ID'),
        @('if-eqz v6, :report_request_unavailable', 1, 'author model'),
        @('if-nez v23, :report_request_ready', 1, 'ReportRequest'))) {
    if ((Get-PatchletLiteralCount -Text $inlinePrerequisiteSlice `
            -Literal ([string]$inlinePrerequisiteBranch[0])) -ne `
            ([int]$inlinePrerequisiteBranch[1])) {
        throw "Inline prerequisite may disappear without a safe diagnostic: $($inlinePrerequisiteBranch[2])"
    }
}
if ($inlinePrerequisiteSlice.Contains(':end_group', [StringComparison]::Ordinal) `
        -or (Get-PatchletLiteralCount -Text $inlineUnavailableSlice `
            -Literal 'const-string v4, "report_request_unavailable"') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $inlineUnavailableSlice `
            -Literal 'invoke-static {v4}, Lthreadsmod/autoblock/AutoBlockSync;->recordInlineRenderStage(Ljava/lang/String;)V') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $inlineUnavailableSlice `
            -Literal 'goto :end_group') -ne 1) {
    throw 'Every post-hook row/request prerequisite failure must converge on the one identifier-free request-unavailable diagnostic before exiting.'
}
foreach ($inlineDiagnosticCall in @(
        "const-string v4, `"hook_seen`"`n    invoke-static {v4}, Lthreadsmod/autoblock/AutoBlockSync;->recordInlineRenderStage(Ljava/lang/String;)V",
        "const-string v4, `"report_request_unavailable`"`n    invoke-static {v4}, Lthreadsmod/autoblock/AutoBlockSync;->recordInlineRenderStage(Ljava/lang/String;)V",
        "const-string v4, `"button_rendered`"`n    invoke-static {v4}, Lthreadsmod/autoblock/AutoBlockSync;->recordInlineRenderStage(Ljava/lang/String;)V",
        "const-string v0, `"adapter_exception`"`n    invoke-static {v0}, Lthreadsmod/autoblock/AutoBlockSync;->recordInlineRenderStage(Ljava/lang/String;)V")) {
    if ((Get-PatchletLiteralCount -Text $rowAdapterTemplateText `
            -Literal $inlineDiagnosticCall) -ne 1) {
        throw 'Inline diagnostics must pass only an immediate fixed literal to the memory-only recorder.'
    }
}
if ((Get-PatchletLiteralCount -Text $rowAdapterTemplateText `
        -Literal 'AutoBlockSync;->recordInlineRenderStage(Ljava/lang/String;)V') -ne 4) {
    throw 'The exact 444 inline adapter must own exactly four fixed diagnostic calls.'
}
foreach ($removedModalText in @('Safe processing', 'Before exact review')) {
    if ($joinedProductionAssets.Contains($removedModalText, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Removed modal copy remains in a production asset: $removedModalText"
    }
}
$routesThroughController = $clickTemplateText.Contains(
    'InlineBlockController;->onClick', [StringComparison]::Ordinal)
$containsDirectMutation = $clickTemplateText.Contains(
    $resolvedBlockMutationMethod, [StringComparison]::Ordinal)
if (-not $routesThroughController -or $containsDirectMutation) {
    throw 'Inline click template does not route exclusively through the stable controller.'
}
if (-not $drawerClickTemplateText.Contains(
        'CloneBlockerSettingsActivity;->openFromForeground()Z', [StringComparison]::Ordinal) `
        -or $drawerClickTemplateText.Contains('android.intent.action', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Drawer settings click does not route through the stable private-activity launcher.'
}
$drawerLabels = @($drawerRows | ForEach-Object { [string]$_.label } | Sort-Object -Unique)
if ($drawerLabels.Count -ne 1 `
        -or -not $drawerRowTemplateText.Contains($drawerLabels[0], [StringComparison]::Ordinal) `
        -or -not $drawerRowTemplateText.Contains('{{nativeDrawerRowMethod}}', [StringComparison]::Ordinal)) {
    throw 'Drawer settings row does not use the resolved native labeled-row primitive.'
}
if (-not $drawerItemTemplateText.Contains(
        'DrawerSettingsRowAdapter;->render({{composerDescriptor}}{{modifierDescriptor}})V', [StringComparison]::Ordinal) `
        -or -not $drawerItemTemplateText.Contains('{{drawerRowModifierMethod}}', [StringComparison]::Ordinal)) {
    throw 'Drawer settings lazy item does not reconstruct the resolved native row modifier and adapter.'
}
foreach ($drawerAnchorContract in $drawerAnchorContracts) {
    $drawerAnchorBeforeText = [string]$drawerAnchorContract.beforeText
    $drawerAnchorAfterText = [string]$drawerAnchorContract.afterText
    $drawerBottomSpacerKey = [string]$drawerAnchorContract.row.key
    $settingsKeyIndex = $drawerAnchorAfterText.IndexOf(
        'threadsmod-drawer-settings', [StringComparison]::Ordinal)
    $bottomSpacerIndex = $drawerAnchorAfterText.IndexOf(
        $drawerBottomSpacerKey, [StringComparison]::Ordinal)
    if ($drawerAnchorBeforeText.Contains(
            'DrawerSettingsItem;->INSTANCE:Lthreadsmod/drawer/DrawerSettingsItem;',
            [StringComparison]::Ordinal) `
            -or $drawerAnchorBeforeText.Contains(
                'threadsmod-drawer-settings', [StringComparison]::Ordinal) `
            -or (Get-PatchletLiteralCount -Text $drawerAnchorAfterText `
                -Literal 'DrawerSettingsItem;->INSTANCE:Lthreadsmod/drawer/DrawerSettingsItem;') -ne 1 `
            -or (Get-PatchletLiteralCount -Text $drawerAnchorAfterText `
                -Literal 'threadsmod-drawer-settings') -ne 1 `
            -or (Get-PatchletLiteralCount -Text $drawerAnchorAfterText `
                -Literal $drawerBottomSpacerKey) -ne 1 `
            -or $settingsKeyIndex -lt 0 `
            -or $bottomSpacerIndex -le $settingsKeyIndex) {
        throw "Drawer Settings row '$($drawerAnchorContract.row.hookRuleId)' is not one keyed native item immediately before its exact bottom spacer."
    }
}
$styleCaptureRegister = ''
$composerCaptureRegister = ''
if ($spacingRewriteRules.Count -eq 1) {
    $spacingInsertion = Get-PatchletSingleInsertion `
        -Before $spacingAnchorBeforeText -After $spacingAnchorText `
        -Label ([string]$spacingRewriteRules[0].id)
    $spacingInsertionLines = @($spacingInsertion -split "`n" | ForEach-Object {
            $_.Trim()
        } | Where-Object { $_.Length -gt 0 })
    $spacingInsertionMatches = @($spacingInsertionLines | ForEach-Object {
            [regex]::Match(
                $_,
                '^move-object(?:/from16)?\s+(?<destination>v\d+),\s+(?<source>[vp]\d+)$')
        })
    if ($spacingInsertionMatches.Count -lt 1 `
            -or $spacingInsertionMatches.Count -gt 2 `
            -or @($spacingInsertionMatches | Where-Object { -not $_.Success }).Count -ne 0) {
        throw 'Share style is not preserved before the host popup can overwrite its register.'
    }
    $styleCaptureRegister = $spacingInsertionMatches[0].Groups['destination'].Value
    $composerCaptureRegister = if ($spacingInsertionMatches.Count -eq 2) {
        $spacingInsertionMatches[1].Groups['destination'].Value
    } else { '' }
}
if ([string]$snapshotRewriteRules[0].id `
        -cne [string]$resolution.inlineControls.actionRow.snapshotHookRuleId `
        -or [string]$snapshotRewriteRules[0].beforeFile `
            -notmatch '^anchors/[A-Za-z0-9._-]+\.smali$' `
        -or [string]$snapshotRewriteRules[0].afterFile `
            -notmatch '^anchors/[A-Za-z0-9._-]+\.smali$' `
        -or [string]$snapshotRewriteRules[0].beforeFile `
            -ceq [string]$snapshotRewriteRules[0].afterFile) {
    throw 'Inline-control rewrite set does not exactly own the one host snapshot helper insertion.'
}
$snapshotMethodName = 'threadsmodResolveAuthorSnapshot'
$snapshotMethodReference = [string]$resolution.inlineControls.actionRow.snapshotMethod
$snapshotMethodSignature = '.method private static ' + $snapshotMethodReference
$snapshotOwnerMarkerCandidates = @(
    '# threadsmod exact-SHA inline author snapshot owner',
    '# threadsmod exact-SHA immutable inline snapshot owner'
)
$snapshotOwnerMarkers = @($snapshotOwnerMarkerCandidates | Where-Object {
        $snapshotHostAfterText.Contains($_, [StringComparison]::Ordinal)
    })
$snapshotOwnerMarker = if ($snapshotOwnerMarkers.Count -eq 1) {
    [string]$snapshotOwnerMarkers[0]
} else { '' }
$snapshotMarkerIndex = $snapshotHostAfterText.IndexOf(
    $snapshotOwnerMarker, [StringComparison]::Ordinal)
$snapshotOwnerEndIndex = if ($snapshotMarkerIndex -ge 0) {
    $snapshotHostAfterText.IndexOf(
        '.end method', $snapshotMarkerIndex + $snapshotOwnerMarker.Length,
        [StringComparison]::Ordinal)
} else { -1 }
$snapshotHelperIndex = $snapshotHostAfterText.IndexOf(
    $snapshotMethodSignature, [StringComparison]::Ordinal)
$snapshotBeforeEndIndex = $snapshotHostBeforeText.LastIndexOf(
    '.end method', [StringComparison]::Ordinal)
$snapshotBeforePrefix = if ($snapshotBeforeEndIndex -ge 0) {
    $snapshotHostBeforeText.Substring(0, $snapshotBeforeEndIndex).TrimEnd()
} else { '' }
$snapshotAfterPrefix = if ($snapshotMarkerIndex -ge 0) {
    $snapshotHostAfterText.Substring(0, $snapshotMarkerIndex).TrimEnd()
} else { '' }
$snapshotOwnerClose = if ($snapshotMarkerIndex -ge 0 `
        -and $snapshotHelperIndex -gt $snapshotMarkerIndex) {
    $snapshotHostAfterText.Substring(
        $snapshotMarkerIndex + $snapshotOwnerMarker.Length,
        $snapshotHelperIndex - ($snapshotMarkerIndex + $snapshotOwnerMarker.Length)).Trim()
} else { '' }
if ($snapshotOwnerMarkers.Count -ne 1 `
        -or $snapshotHostBeforeText.Contains($snapshotMethodName, [StringComparison]::Ordinal) `
        -or $snapshotHostBeforeText.Contains($snapshotOwnerMarker, [StringComparison]::Ordinal) `
        -or $snapshotBeforeEndIndex -lt 0 `
        -or -not $snapshotBeforePrefix.Equals(
            $snapshotAfterPrefix, [StringComparison]::Ordinal) `
        -or $snapshotOwnerClose -cne '.end method' `
        -or (Get-PatchletLiteralCount -Text $snapshotHostAfterText `
            -Literal $snapshotOwnerMarker) -ne 1 `
        -or $snapshotMarkerIndex -lt 0 `
        -or $snapshotOwnerEndIndex -le $snapshotMarkerIndex `
        -or $snapshotHelperIndex -le $snapshotOwnerEndIndex `
        -or (Get-PatchletLiteralCount -Text $snapshotHostAfterText `
            -Literal $snapshotMethodSignature) -ne 1) {
    throw 'Host snapshot rewrite anchors overlap or do not prove exact marker/tail/helper ordering with applied old=0,new=1.'
}
$snapshotHostHelperText = $snapshotHostAfterText.Substring($snapshotHelperIndex)
$snapshotFactoryCall =
    'Lthreadsmod/inlinecontrol/InlineBlockRequest;->createHostBound(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/Object;Ljava/lang/Object;)Lthreadsmod/inlinecontrol/InlineBlockRequest;'
$snapshotHostSteps = @(
    [string]$privateInlineSymbols.mediaLookupMethod,
    [string]$privateInlineSymbols.mediaAuthorMethod,
    [string]$privateInlineSymbols.authorIdMethod,
    [string]$privateInlineSymbols.authorUsernameMethod,
    $snapshotFactoryCall
)
$snapshotMediaLookupIndex = $snapshotHostHelperText.IndexOf(
    [string]$privateInlineSymbols.mediaLookupMethod, [StringComparison]::Ordinal)
$snapshotMediaKeyPrefix = if ($snapshotMediaLookupIndex -gt 0) {
    $snapshotHostHelperText.Substring(0, $snapshotMediaLookupIndex)
} else { '' }
$snapshotMediaKeyResolved = $snapshotMediaKeyPrefix.Contains(
    [string]$privateInlineSymbols.ufiMediaIdField, [StringComparison]::Ordinal) `
    -or [regex]::IsMatch(
        $snapshotMediaKeyPrefix,
        '(?s)invoke-(?:interface|virtual)\s+\{p0\},\s+' +
            'L[^;]+;->[A-Za-z0-9_$]+\(\)Ljava/lang/String;\s+' +
            'move-result-object\s+v0')
$previousSnapshotStepIndex = -1
foreach ($snapshotHostStep in $snapshotHostSteps) {
    $snapshotHostStepIndex = $snapshotHostHelperText.IndexOf(
        $snapshotHostStep, [StringComparison]::Ordinal)
    if ($snapshotHostStepIndex -le $previousSnapshotStepIndex `
            -or (Get-PatchletLiteralCount -Text $snapshotHostHelperText `
                -Literal $snapshotHostStep) -ne 1) {
        throw "Host snapshot helper does not resolve and bind one immutable row snapshot in exact order: $snapshotHostStep"
    }
    $previousSnapshotStepIndex = $snapshotHostStepIndex
}
if (-not $snapshotMediaKeyResolved `
        -or (Get-PatchletLiteralCount -Text $snapshotHostHelperText `
            -Literal $snapshotMethodSignature) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $snapshotHostHelperText `
            -Literal '.method ') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $snapshotHostHelperText `
            -Literal '.catch Ljava/lang/Throwable;') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $snapshotHostHelperText `
            -Literal ([string]$privateInlineSymbols.authorIdMethod)) -ne 1 `
        -or (Get-PatchletLiteralCount -Text $requestCode `
            -Literal 'publicstaticInlineBlockRequestcreateHostBound(') -ne 1 `
        -or $snapshotHostHelperText.Contains(
            $bridgeAlreadyBlockedMethod, [StringComparison]::Ordinal)) {
    throw 'Host snapshot helper is not the one bounded raw author-ID owner and immutable request factory caller.'
}
$rowInsertion = Get-PatchletSingleInsertion `
    -Before $rowAnchorBeforeText -After $rowAnchorText `
    -Label ([string]$rowRewriteRules[0].id)
$snapshotOwnerPath = ([string]$snapshotRewriteRules[0].path).Replace('\', '/')
$snapshotOwnerPathMatch = [regex]::Match(
    $snapshotOwnerPath,
    '^smali(?:_classes\d+)?/(?<class>.+)\.smali$')
$snapshotOwnerDescriptor = if ($snapshotOwnerPathMatch.Success) {
    'L' + $snapshotOwnerPathMatch.Groups['class'].Value + ';'
} else { '' }
$snapshotRowCall = $snapshotOwnerDescriptor + '->' + $snapshotMethodReference
$requestBindingValid = $false
$requestBindingIndex = -1
$snapshotResultRegister = ''
if ($usesPreboundInlineRequest) {
    $ufiRequestField = [string]$ufiRequestFieldProperty.Value
    $mediaBindInsertion = Get-PatchletSingleInsertion `
        -Before $mediaBindAnchorBeforeText -After $mediaBindAnchorAfterText `
        -Label ([string]$mediaBindRewriteRules[0].id)
    $mediaBindSnapshotInvoke = [regex]::Match(
        $mediaBindInsertion,
        '(?m)^\s*invoke-static(?<range>/range)?\s+\{(?<registers>[^}]+)\},\s+' +
            [regex]::Escape($snapshotRowCall) + '\s*$')
    $mediaBindSnapshotTail = if ($mediaBindSnapshotInvoke.Success) {
        $mediaBindInsertion.Substring(
            $mediaBindSnapshotInvoke.Index + $mediaBindSnapshotInvoke.Length)
    } else { '' }
    $mediaBindSnapshotResult = [regex]::Match(
        $mediaBindSnapshotTail,
        '^\s*move-result-object\s+(?<register>v\d+)')
    $mediaBindSnapshotRegister = if ($mediaBindSnapshotResult.Success) {
        $mediaBindSnapshotResult.Groups['register'].Value
    } else { '' }
    $mediaBindRequestStore = [regex]::Match(
        $mediaBindSnapshotTail,
        '(?m)^\s*iput-object\s+' + [regex]::Escape($mediaBindSnapshotRegister) +
            ',\s+(?<carrier>v\d+),\s+' + [regex]::Escape($ufiRequestField) + '\s*$')
    $rowRequestLoad = [regex]::Match(
        $rowInsertion,
        '(?m)^\s*iget-object\s+(?<request>v\d+),\s+(?<carrier>[vp]\d+),\s+' +
            [regex]::Escape($ufiRequestField) + '\s*$')
    $requestBindingIndex = $rowRequestLoad.Index
    $snapshotResultRegister = if ($rowRequestLoad.Success) {
        $rowRequestLoad.Groups['request'].Value
    } else { '' }
    $requestBindingValid =
        $ufiRequestField.StartsWith(
            [string]$resolution.inlineControls.carrier.descriptor,
            [StringComparison]::Ordinal) `
        -and $ufiRequestField.EndsWith(
            ':Lthreadsmod/inlinecontrol/InlineBlockRequest;',
            [StringComparison]::Ordinal) `
        -and $mediaBindSnapshotInvoke.Success `
        -and $mediaBindSnapshotResult.Success `
        -and $mediaBindRequestStore.Success `
        -and $rowRequestLoad.Success `
        -and (Get-PatchletLiteralCount -Text $mediaBindInsertion `
            -Literal $snapshotRowCall) -eq 1 `
        -and (Get-PatchletLiteralCount -Text $rowInsertion `
            -Literal $snapshotRowCall) -eq 0 `
        -and (Get-PatchletLiteralCount -Text $mediaBindInsertion `
            -Literal 'InlineBlockRequest;->getMediaKey()Ljava/lang/String;') -eq 1 `
        -and (Get-PatchletLiteralCount -Text $mediaBindInsertion `
            -Literal 'InlineBlockRequest;->getMediaId()Ljava/lang/String;') -eq 0 `
        -and $requestCode.Contains(
            'publicStringgetMediaKey(){returnmediaKey;}', [StringComparison]::Ordinal) `
        -and (Get-PatchletLiteralCount -Text $mediaBindInsertion `
            -Literal ([string]$privateInlineSymbols.ufiMediaIdField)) -eq 1
    $invalidMediaGetterBinding = $mediaBindInsertion.Replace(
        'InlineBlockRequest;->getMediaKey()Ljava/lang/String;',
        'InlineBlockRequest;->getMediaId()Ljava/lang/String;')
    $invalidMediaGetterAccepted =
        (Get-PatchletLiteralCount -Text $invalidMediaGetterBinding `
            -Literal 'InlineBlockRequest;->getMediaKey()Ljava/lang/String;') -eq 1 `
        -and (Get-PatchletLiteralCount -Text $invalidMediaGetterBinding `
            -Literal 'InlineBlockRequest;->getMediaId()Ljava/lang/String;') -eq 0
    if ($invalidMediaGetterAccepted) {
        throw 'The invalid legacy inline media getter negative fixture was accepted.'
    }
} else {
    $snapshotRowInvokeMatch = [regex]::Match(
        $rowInsertion,
        '(?m)^\s*invoke-static(?<range>/range)?\s+\{(?<registers>[^}]+)\},\s+' +
            [regex]::Escape($snapshotRowCall) + '\s*$')
    $snapshotRowTail = if ($snapshotRowInvokeMatch.Success) {
        $rowInsertion.Substring($snapshotRowInvokeMatch.Index + $snapshotRowInvokeMatch.Length)
    } else { '' }
    $snapshotRowResultMatch = [regex]::Match(
        $snapshotRowTail, '^\s*move-result-object\s+(?<register>[vp]\d+)')
    $requestBindingIndex = $snapshotRowInvokeMatch.Index
    $snapshotResultRegister = if ($snapshotRowResultMatch.Success) {
        $snapshotRowResultMatch.Groups['register'].Value
    } else { '' }
    $requestBindingValid = $snapshotRowInvokeMatch.Success `
        -and $snapshotRowResultMatch.Success `
        -and (Get-PatchletLiteralCount -Text $rowInsertion `
            -Literal $snapshotRowCall) -eq 1
}
$blockRenderReference =
    'Lthreadsmod/inlinecontrol/InlineActionRowAdapter;->render(' +
    [string]$privateInlineSymbols.ufiStyleDescriptor +
    [string]$privateInlineSymbols.composerDescriptor +
    [string]$privateInlineSymbols.ufiConfigDescriptor +
    'Lthreadsmod/inlinecontrol/InlineBlockRequest;JJ)V'
$blockRenderMatch = [regex]::Match(
    $rowInsertion,
    '(?m)^\s*invoke-static(?<range>/range)?\s+\{(?<registers>[^}]+)\},\s+' +
        [regex]::Escape($blockRenderReference) + '\s*$')
$blockRenderIndex = $blockRenderMatch.Index
$renderCarriesStyleAndSnapshot = $false
$shareCaptureValid = $spacingRewriteRules.Count -eq 1
if ($blockRenderMatch.Success) {
    $renderRegisters = $blockRenderMatch.Groups['registers'].Value.Trim()
    $renderRangeMatch = [regex]::Match(
        $renderRegisters,
        '^(?<prefix>[vp])(?<start>\d+)\s+\.\.\s+\k<prefix>(?<end>\d+)$')
    if ($renderRangeMatch.Success) {
        $renderStart = [int]$renderRangeMatch.Groups['start'].Value
        $renderEnd = [int]$renderRangeMatch.Groups['end'].Value
        $expectedStyleRegister = $renderRangeMatch.Groups['prefix'].Value + $renderStart
        $expectedComposerRegister =
            $renderRangeMatch.Groups['prefix'].Value + ($renderStart + 1)
        $expectedSnapshotRenderRegister =
            $renderRangeMatch.Groups['prefix'].Value + ($renderStart + 3)
        if ($spacingRewriteRules.Count -eq 0 -and $requestBindingIndex -gt 0) {
            $rowCapturePrefix = $rowInsertion.Substring(0, $requestBindingIndex)
            $styleCaptureRegister = $expectedStyleRegister
            $composerCaptureRegister = $expectedComposerRegister
            $shareCaptureValid =
                [regex]::Matches(
                    $rowCapturePrefix,
                    '(?m)^\s*move-object(?:/from16)?\s+' +
                        [regex]::Escape($styleCaptureRegister) + ',\s+[vp]\d+\s*$').Count -eq 1 `
                -and [regex]::Matches(
                    $rowCapturePrefix,
                    '(?m)^\s*move-object(?:/from16)?\s+' +
                        [regex]::Escape($composerCaptureRegister) + ',\s+[vp]\d+\s*$').Count -eq 1
        } elseif ($composerCaptureRegister.Length -gt 0) {
            $shareCaptureValid = $composerCaptureRegister -ceq $expectedComposerRegister
        }
        $requestRenderFlowValid = $false
        if ($normalizedSourceVersion -ceq '415.0.0.26.77') {
            $requestRenderFlowValid =
                $snapshotResultRegister -ceq $expectedSnapshotRenderRegister
        } elseif ($normalizedSourceVersion -ceq '444.0.0.45.85' `
                -and $usesPreboundInlineRequest `
                -and $rowRequestLoad.Success `
                -and $blockRenderIndex -gt (
                    $rowRequestLoad.Index + $rowRequestLoad.Length)) {
            $requestLoadRegister = $rowRequestLoad.Groups['request'].Value
            $requestCarrierRegister = $rowRequestLoad.Groups['carrier'].Value
            $requestLoadNumber = if ($requestLoadRegister -match '^v(?<number>\d+)$') {
                [int]$Matches['number']
            } else { -1 }
            $requestCarrierNumber = if ($requestCarrierRegister -match '^v(?<number>\d+)$') {
                [int]$Matches['number']
            } else { -1 }
            $requestAliasSpanStart = $rowRequestLoad.Index + $rowRequestLoad.Length
            $requestAliasSpan = $rowInsertion.Substring(
                $requestAliasSpanStart, $blockRenderIndex - $requestAliasSpanStart)
            $exactRequestAlias =
                '(?m)^\s*move-object/from16\s+' +
                [regex]::Escape($expectedSnapshotRenderRegister) + ',\s*' +
                [regex]::Escape($requestLoadRegister) + '\s*$'
            $anyRenderSlotWrite =
                '(?m)^\s*move-object(?:/from16)?\s+' +
                [regex]::Escape($expectedSnapshotRenderRegister) + ',\s*[vp]\d+\s*$'
            $requestRenderFlowValid =
                $requestLoadNumber -ge 0 -and $requestLoadNumber -le 15 `
                -and $requestCarrierNumber -ge 0 -and $requestCarrierNumber -le 15 `
                -and [regex]::Matches($requestAliasSpan, $exactRequestAlias).Count -eq 1 `
                -and [regex]::Matches($requestAliasSpan, $anyRenderSlotWrite).Count -eq 1
        }
        $renderCarriesStyleAndSnapshot =
            ($styleCaptureRegister -ceq $expectedStyleRegister) `
            -and $requestRenderFlowValid `
            -and ($renderEnd - $renderStart -eq 7)
    } elseif ($normalizedSourceVersion -ceq '415.0.0.26.77') {
        $renderRegisterList = @($renderRegisters -split '\s*,\s*')
        if ($spacingRewriteRules.Count -eq 0 `
                -and $requestBindingIndex -gt 0 `
                -and $renderRegisterList.Count -ge 4) {
            $rowCapturePrefix = $rowInsertion.Substring(0, $requestBindingIndex)
            $styleCaptureRegister = $renderRegisterList[0]
            $composerCaptureRegister = $renderRegisterList[1]
            $shareCaptureValid =
                [regex]::Matches(
                    $rowCapturePrefix,
                    '(?m)^\s*move-object(?:/from16)?\s+' +
                        [regex]::Escape($styleCaptureRegister) + ',\s+[vp]\d+\s*$').Count -eq 1 `
                -and [regex]::Matches(
                    $rowCapturePrefix,
                    '(?m)^\s*move-object(?:/from16)?\s+' +
                        [regex]::Escape($composerCaptureRegister) + ',\s+[vp]\d+\s*$').Count -eq 1
        } elseif ($composerCaptureRegister.Length -gt 0 `
                -and $renderRegisterList.Count -ge 2) {
            $shareCaptureValid = $composerCaptureRegister -ceq $renderRegisterList[1]
        }
        $renderCarriesStyleAndSnapshot = $renderRegisterList.Count -eq 6 `
            -and $renderRegisterList[0] -ceq $styleCaptureRegister `
            -and $renderRegisterList[3] -ceq $snapshotResultRegister
    }
}
if (-not $snapshotOwnerPathMatch.Success `
        -or -not $requestBindingValid `
        -or -not $blockRenderMatch.Success `
        -or $blockRenderIndex -le $requestBindingIndex `
        -or -not $shareCaptureValid `
        -or -not $renderCarriesStyleAndSnapshot `
        -or (Get-PatchletLiteralCount -Text $rowAnchorText `
            -Literal 'InlineActionRowAdapter;->render') -ne 1 `
        -or (Get-PatchletLiteralCount -Text $rowAnchorText `
            -Literal $blockRenderReference) -ne 1 `
        -or $rowAnchorText.Contains('InlineReportRowAdapter;->render', [StringComparison]::Ordinal) `
        -or $rowAnchorText.Contains('InlineReportActionFactory;->createRequest', [StringComparison]::Ordinal)) {
    throw 'Exactly one host-bound snapshot and Block adapter are not proven in the parent row after Share.'
}
$reportRequestFactoryCall =
    'InlineReportActionFactory;->createRequest(Lthreadsmod/inlinecontrol/InlineBlockRequest;)Lthreadsmod/reporting/ReportRequest;'
$reportRequestGuardPattern =
    [regex]::Escape($reportRequestFactoryCall) +
    '\s*\r?\n\s*move-result-object\s+v23\s*\r?\n\s*if-nez\s+v23,\s*:report_request_ready'
$testInlineReportRequestGuard = {
    param([string]$TemplateText)
    $factoryIndex = $TemplateText.IndexOf(
        $reportRequestFactoryCall, [StringComparison]::Ordinal)
    $guardIndex = $TemplateText.IndexOf(
        'if-nez v23, :report_request_ready', [StringComparison]::Ordinal)
    $unavailableIndex = if ($guardIndex -ge 0) {
        $TemplateText.IndexOf(
            ':report_request_unavailable', $guardIndex, [StringComparison]::Ordinal)
    } else { -1 }
    $readyIndex = if ($unavailableIndex -ge 0) {
        $TemplateText.IndexOf(
            ':report_request_ready', $unavailableIndex + 1, [StringComparison]::Ordinal)
    } else { -1 }
    $firstComposerAuthorityIndex = $TemplateText.IndexOf(
        'invoke-interface {v1, v9},', [StringComparison]::Ordinal)
    $clickIndex = $TemplateText.IndexOf(
        'new-instance v7, Lthreadsmod/inlinecontrol/InlineActionClick;',
        [StringComparison]::Ordinal)
    $visibilityIndex = $TemplateText.IndexOf(
        'new-instance v7, Lthreadsmod/inlinecontrol/InlineVisibilityCallback;',
        [StringComparison]::Ordinal)
    $renderIndex = $TemplateText.IndexOf(':call_button', [StringComparison]::Ordinal)
    return $factoryIndex -ge 0 `
        -and [regex]::Matches($TemplateText, $reportRequestGuardPattern).Count -eq 1 `
        -and (Get-PatchletLiteralCount -Text $TemplateText `
            -Literal 'if-nez v23, :report_request_ready') -eq 1 `
        -and $guardIndex -gt $factoryIndex `
        -and $unavailableIndex -gt $guardIndex `
        -and $readyIndex -gt $unavailableIndex `
        -and $firstComposerAuthorityIndex -gt $readyIndex `
        -and $clickIndex -gt $readyIndex `
        -and $visibilityIndex -gt $readyIndex `
        -and $renderIndex -gt $readyIndex
}
$reportRequestGuardNegativeFixtureCount = 0
if ($normalizedSourceVersion -ceq '444.0.0.45.85') {
    $missingReportRequestGuard = $rowAdapterTemplateText.Replace(
        "    if-nez v23, :report_request_ready`n", '')
    $lateReportRequestGuard = $rowAdapterTemplateText.Replace(
        "    if-nez v23, :report_request_ready`n", '').Replace(
        '    :call_button',
        "    if-nez v23, :report_request_ready`n`n    :call_button")
    if (-not (& $testInlineReportRequestGuard $rowAdapterTemplateText) `
            -or (& $testInlineReportRequestGuard $missingReportRequestGuard) `
            -or (& $testInlineReportRequestGuard $lateReportRequestGuard)) {
        throw '444 rows must route a null ReportRequest through the fixed unavailable diagnostic before state, click, visibility, or render authority; missing/late guard fixtures must fail.'
    }
    $reportRequestGuardNegativeFixtureCount = 2
}
$successStateIndex = $rowAdapterTemplateText.IndexOf(
    "const/4 v4, 0x2`n    if-ne v10, v4, :not_success", [StringComparison]::Ordinal)
$successLabelIndex = $rowAdapterTemplateText.IndexOf(
    'const-string v3, "Blocked"', [StringComparison]::Ordinal)
$buttonIndex = $rowAdapterTemplateText.IndexOf(':call_button', [StringComparison]::Ordinal)
if ($successStateIndex -lt 0 `
        -or $successLabelIndex -le $successStateIndex `
        -or $buttonIndex -le $successLabelIndex) {
    throw 'An already-blocked target can still hide the only Report-capable entry.'
}
if (($inlineTemplateText -join "`n").Contains('tree55.com', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Forbidden ISP-blocked origin appears in runtime/template assets.'
}

$report = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToString('o')
    status = 'passed'
    selectedTemplateRoots = [ordered]@{
        bridge = [string]$resolution.bridge.templateRoot
        bridgeReference = [string]$resolution.bridge.referenceRoot
        inline = [string]$resolution.inlineControls.templateRoot
        reporting = [string]$resolution.reporting.templateRoot
        settings = [string]$resolution.drawerSettings.templateRoot
        sourceVersionBound = $true
    }
    endpointHarness = $endpointOutput[-1]
    verifierHarness = $verifierOutput[-1]
    passiveFixtureHarness = $passiveFixtureOutput[-1]
    limitsHarness = $limitsOutput[-1]
    limitsStoreHarness = $limitsStoreOutput[-1]
    reportValuesHarness = $reportValuesOutput[-1]
    installStatsHarness = $installStatsOutput[-1]
    strictJsonHarness = $strictJsonOutput[-1]
    proxyConfigHarness = $proxyConfigOutput[-1]
    proxyRouteHarness = $proxyRouteOutput[-1]
    updatePolicyHarness = $updatePolicyOutput[-1]
    updateSignatureHarness = $updateSignatureOutput[-1]
    updateStoreFloorHarness = $updateStoreFloorOutput[-1]
    updateSafety = [ordered]@{
        metadataOrder = $expectedUpdateMetadataUrls
        purpose = 'threadsmod-app-update'
        schemaVersion = 1
        currentModBuild = [long]$resolution.update.currentModBuild
        targetModBuild = $targetModBuild
        targetVersionCode = [long]$resolution.target.versionCode
        targetVersionName = [string]$resolution.target.versionName
        antiRollback = 'revision-and-modBuild'
        optionalDismissal = 'exact-revision'
        requiredPolicy = 'minimumModBuild'
        artifactProviders = @('github-release', 'aws-object')
        redirectProviderIsolation = $true
        archiveChecks = @('size', 'sha256', 'package', 'versionCode', 'single-signer')
        installer = 'fileprovider-visible-android-consent'
        rawDexProofAssets = [ordered]@{
            fixtureCount = 96
            negativeCount = 95
            inspectorArgumentCount = 12
            inspectorSha256 = `
                [string]$resolution.assets.dexUpdateFlowInspectorSourceSha256
            fixtureHarnessSha256 = `
                [string]$resolution.assets.dexUpdateFlowInspectorTestSourceSha256
            fixtureTreeSha256 = `
                [string]$resolution.assets.dexUpdateFlowFixtureTreeSha256
            executedByHostAssetGate = $false
        }
        liveNetworkUsed = $false
        apkInstalled = $false
    }
    passiveBlocking = [ordered]@{
        database = 'threadsmod_blocklist.db'
        schemaVersion = 3
        idIndex = 'primary-key'
        usernameIndex = 'blocklist_targets_username_idx-unique'
        bucketIndex = 'blocklist_targets_h32_idx'
        bucketFunction = 'sha256-hi32'
        chunkTables = @('blocklist_chunks', 'blocklist_groups', 'blocklist_staging')
        totalRecordCount = 'committed-generation-metadata'
        newRecordCount = 'exact-incoming-id-set-difference-per-replaced-bucket'
        firstVerifiedInstallNewCount = 'all-rows'
        migratedV1NewCount = -1
        migratedV2NewCount = 'preserved'
        verified304NewCount = 0
        refreshIntervalMillis = 600000
        foregroundOnly = $true
        fetchedRowsCreateBlockWork = $false
        composeDatabaseLookup = $false
        viewport = 'attached-and-nonempty-clipped-root-bounds'
        manualPriority = $true
        finalGenerationMembershipRecheck = $true
        runningIdentityPersistedBeforeReservation = $true
        interruptedPassiveState = 'abandoned-review'
        legacyTargetBlobAuthority = $false
        coveredHostSurface = 'post-reply-action-row-control'
        mainOnlyVisibilityRegistration = $normalizedSourceVersion -ceq '444.0.0.45.85'
        offMainVisibilityRevocation = $normalizedSourceVersion -ceq '444.0.0.45.85'
        visibilityOffMainNegativeFixtures = $visibilityOffMainNegativeFixtureCount
        statusSurfaces = @('Activity', 'Settings')
        statusPollMillis = 1000
        statusPollLifecycleBounded = $true
        statusPollAcceptanceChecked = $true
    }
    proxySafety = [ordered]@{
        defaultEnabled = $false
        acceptedHostKinds = @('idna-hostname', 'ipv4', 'ipv6')
        bypassGrammar = 'numeric-ip-or-cidr-one-per-line'
        maximumBypassRules = 64
        maximumBypassUtf16Units = 4096
        bypassHostnameAccepted = $false
        minimumPort = 1
        maximumPort = 65535
        authenticationEncoding = 'printable-ascii'
        minimumAuthenticationBytes = 1
        maximumAuthenticationBytes = 255
        ownedPreferenceKeys = @($expectedProxyPreferenceKeys.Values)
        plaintextCredentialPreferenceKeys = $false
        credentialCipher = 'AES/GCM/NoPadding'
        credentialKeystoreAlias = 'threadsmod_proxy_config_aes_v1'
        usernameAndPasswordShareCiphertext = $true
        api33NativeExclusionsExecuted = $true
        legacyComplementExecuted = $true
        representativeRouteEquivalence = $true
        maximumLegacyRoutes = 4096
        appOnlyVpnCapture = $true
        platformAllowBypass = $false
        runtimeStateSplit = @(
            'paused_guard_active',
            'paused_guard_retained',
            'unprotected_prior_routing',
            'paused_vpn'
        )
        retainedGuardReportedPaused = $true
        retainedForwardingDisclosesPriorDirectExclusions = $true
        settingsRuntimePollMillis = 500
        settingsPollAcceptanceChecked = $true
        settingsPollLifecycleBounded = $true
        liveNetworkUsed = $false
    }
    inlineSafety = [ordered]@{
        schedulerEntryPoints = $schedulerEntryPointCount
        oneClickBypass = $false
        alsoBlockProfileDefault = $true
        alsoBlockProfilePreference = 'ui_also_block_profile'
        alsoBlockProfileCommitChecked = $true
        directNativeMutation = $false
        controllerNetworkPath = $false
        forbiddenOrigin = $false
        coldProcessRecovery = $true
        passiveDelayFields = 2
        passiveMinimumDelayRangeSeconds = @(2, 60)
        passiveMaximumDelayRangeSeconds = @(3, 60)
        passiveDelayDefaultsSeconds = @(4, 10)
        passiveDelayStep = 'whole-second'
        manualPassivePacing = $false
        manualCapacityAdmission = $false
        retiredLimitKeyAuthority = $false
        retiredLimitKeysDeleted = 9
        attemptReservedBeforeNativeSubmission = $true
        automaticReservationFailureDiagnostic = $true
        atomicLimitStoreExecution = $true
        failedCommitRollbackTypes = @('integer', 'string', 'boolean', 'long', 'float', 'string-set', 'missing')
        bothPassiveDelayBoundsAndStepExecutable = $true
        partialIntegerSnapshotFailsClosed = $true
        invalidIntegerSnapshotFailsClosed = $true
        rollbackFailureUncertaintyLatched = $true
        preferenceReadErrorsFailClosed = $true
        viewerScopedAttemptHistory = 'bounded-diagnostics-not-admission'
        schedulerWaitWakePaths = 23
        schedulerCriticalHandlerEnqueuesChecked = 6
        schedulerRejectedEnqueuesFailClosed = $true
        optionalUncheckedUiPosts = 1
        settingsFieldWiringExact = $true
        queueOverflowEviction = $false
        activeOperationPruning = $false
        manualPreemptsAutomaticWork = $true
        activityReplacementRecovery = $true
        forcedRefreshPreservedAcrossReplacement = $true
        accountSwitchWakeup = $true
        forcedRefreshViewerScoped = $true
        forcedRefreshCrossViewerClobber = $false
        compactCombinedActionDialog = $true
        callbackOnlySuccessTransition = $true
        singleInlineControlTopology = $true
        compositionCurrentViewerGate = $false
        inlineDiagnosticStages = @(
            'hook_seen',
            'report_request_unavailable',
            'button_rendered',
            'adapter_exception'
        )
        inlineDiagnosticAggregate = $true
        immutableHostSnapshotResolution = $true
        stableMediaKeyGetterBinding = $usesPreboundInlineRequest
        stableMediaGetterNegativeFixtures = if ($usesPreboundInlineRequest) { 1 } else { 0 }
        reportRequestGuardBeforeRenderAuthority = `
            $normalizedSourceVersion -ceq '444.0.0.45.85'
        reportRequestGuardNegativeFixtures = $reportRequestGuardNegativeFixtureCount
        hostSnapshotRawAuthorIdCalls = 1
        stableInlineReportRawAuthorIdCalls = 0
        stableInlineReportAlreadyBlockedCalls = 0
        resolvedAuthorModelOpaqueHandoff = $true
        resolvedMediaModelOpaqueHandoff = $true
        resolvedAuthorModelRegistryCapacity = 64
        resolvedAuthorModelViewerSessionScoped = $true
        resolvedAuthorModelPersisted = $false
        manualQueueStartedAndAttemptReservedBeforeHint = $true
        automaticDirectIdCachePlaceholderPath = $true
        nullModelFallsBackToCachePlaceholderBridge = $true
        resolvedModelIdMustMatchTarget = $true
        retiredProfileLookupArtifacts = $false
        closedBlockDiagnosticVocabulary = $true
        blockDiagnosticMaximumDetailChars = 120
        blockDiagnosticMaximumStatusChars = 240
        blockDiagnosticMaximumLogChars = 200
        completionReviewDurableTargetLimit = 200
        completionReviewCorruptStateFailsClosed = $true
        completionReviewFullCapacityPausesAutomaticSelection = $true
        completionReviewProcessLocalFallback = $true
        completionReviewPreferenceExceptionRetainsLocalLatch = $true
        completionPersistenceAutomaticRetry = $false
        completionPersistenceManualRetry = $false
        callbackTimeoutAutomaticRetry = $false
        callbackTimeoutManualState = 'abandoned-review'
        completionRetryRequiresExplicitManualAction = $true
        completionSaveThrowableConvergesOnQuarantine = $true
        completionDiagnosticFailureCannotStrandScheduler = $true
        completionStatusFailureCannotCrashLocalLatch = $true
        manualCompletionFailureDispatchIsFinallyProtected = $true
        normalSuccessStateReadFailureCannotStrandScheduler = $true
        inlinePreEnqueueDiagnosticBeforeCallback = $true
        inlinePostEnqueueDiagnosticOwner = 'scheduler'
        inlineUsernameCapturedByExactHostSnapshot = $true
        inlineUsernameMaximumDisplayChars = 80
        reportCapableEntrySurvivesBlockedAndSuccess = $true
        drawerSettingsRoute = $true
        activityShellBeforeStateRead = $true
        activityStatCardLayoutOwner = 'parent-addView'
        nullLayoutParameterCalls = 0
        viewerScopedActivityStatus = $true
    }
    reportingSafety = [ordered]@{
        explicitCombinedPositiveAction = $true
        separateReportAction = $false
        separateEditorOrReview = $false
        consentStep = $false
        modalReasonAndExcerpt = $true
        dynamicBlockOrReportLabel = $true
        reportAlwaysQueued = $true
        optionalSchedulerBlock = $true
        durableQueueBeforeDrain = $true
        initiatingActivityAndViewerBound = $true
        requiredIdentityAndExcerpt = $true
        permalinkRequiredForNewQueue = $true
        legacyRowsWithoutPermalinkRemainReadable = $true
        permalinkSource = 'Media.A75-code-first-with-A7o-empty-result-fallback'
        permalinkCanonicalHost = 'www.threads.com'
        permalinkLegacyInputHost = 'www.threads.net'
        permalinkUsernameBound = $true
        permalinkTargetUrlAndEvidenceSame = $true
        permalinkForbiddenWireFields = @('postUrl', 'postId', 'itemKey')
        settingsDisclosesPermalink = $true
        unicodeSafeExcerptUnits = 280
        emptyCaptionExcerpt = '(no text in this post)'
        viewerScopedDurableOutbox = $true
        corruptOutboxFailsClosed = $true
        sqliteSchemaVersion = 2
        perActionOutboxRows = $true
        v1ToV2MigrationRowCountChecked = $true
        maximumPendingPerViewer = 1000
        maximumHistoryPerViewer = 500
        maximumPayloadUtf8Bytes = 16384
        asyncActivityStorage = $true
        foregroundOwnerToken = $true
        successRequires2xxAndOkTrue = $true
        responseRequiresStrictDuplicateFreeJson = $true
        responseRequiresValidUtf8 = $true
        pseudonymReadReviewSurfaced = $true
        wakeSchedulingReviewMasked = $false
        readEndpointOrder = $expectedReadUrls
        objectBaseOrder = $expectedObjectBases
        writeEndpoint = $expectedWriteUrl
        alternateWriteFallback = $false
        solePostPath = $true
        nativeBlockBridgeReachable = $false
        cookieOrAuthorizationHeader = $false
        liveNetworkUsed = $false
    }
    fixture = [ordered]@{ path = $fixture; sha256 = Get-PatchletSha256 -Path $fixture; liveNetworkUsed = $false }
}
if ($ReportPath) { Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath)) }
[pscustomobject]$report
