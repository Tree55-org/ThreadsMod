[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScratchRoot,
    [Parameter(Mandatory)][string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

function New-Fixture {
    param([Parameter(Mandatory)][string]$Name)

    $root = Join-Path $script:scratchRootFull $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $files = [ordered]@{
        'base.apk' = "base-$Name"
        'split_config.arm64_v8a.apk' = "abi-$Name"
        'split_config.xhdpi.apk' = "density-$Name"
    }
    foreach ($pair in $files.GetEnumerator()) {
        [IO.File]::WriteAllText((Join-Path $root $pair.Key), $pair.Value, [Text.UTF8Encoding]::new($false))
    }
    $members = @(
        [pscustomobject]@{ role='base'; fileName='base.apk'; sha256=Get-PatchletSha256 (Join-Path $root 'base.apk'); size=(Get-Item (Join-Path $root 'base.apk')).Length; splitName=$null; splitType=$null; qualifier=$null },
        [pscustomobject]@{ role='abi'; fileName='split_config.arm64_v8a.apk'; sha256=Get-PatchletSha256 (Join-Path $root 'split_config.arm64_v8a.apk'); size=(Get-Item (Join-Path $root 'split_config.arm64_v8a.apk')).Length; splitName='config.arm64_v8a'; splitType='base__abi'; qualifier='arm64-v8a' },
        [pscustomobject]@{ role='density'; fileName='split_config.xhdpi.apk'; sha256=Get-PatchletSha256 (Join-Path $root 'split_config.xhdpi.apk'); size=(Get-Item (Join-Path $root 'split_config.xhdpi.apk')).Length; splitName='config.xhdpi'; splitType='base__density'; qualifier='xhdpi' }
    )
    return [pscustomobject]@{
        root = $root
        resolution = [pscustomobject]@{
            source = [pscustomobject]@{
                delivery = 'split-apk-set'
                splitSetSha256 = Get-PatchletTreeSha256 -Root $root -Filter '*.apk'
                splitMembers = $members
            }
        }
    }
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $message = $null
    try {
        & $Action
    } catch {
        $message = $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($message)) { throw "Negative split-source fixture unexpectedly passed: $Id" }
    return [pscustomobject]@{ id=$Id; status='rejected'; message=$message }
}

function Assert-UniversalizerPathRejectedBeforeWrite {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Universalizer,
        [Parameter(Mandatory)][string]$SourceApkSet,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$ResolutionPath,
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][string]$ApkEditorJar,
        [Parameter(Mandatory)][string]$ExpectedMessage
    )

    $outputExisted = Test-Path -LiteralPath $OutputDirectory
    $reportExisted = Test-Path -LiteralPath $ReportPath
    $message = $null
    try {
        & $Universalizer `
            -SourceApkSet $SourceApkSet `
            -OutputDirectory $OutputDirectory `
            -ResolutionPath $ResolutionPath `
            -ReportPath $ReportPath `
            -AndroidSdk $script:scratchRootFull `
            -BuildToolsVersion 'path-contract-only' `
            -Java 'path-contract-must-not-run' `
            -ApkEditorJar $ApkEditorJar | Out-Null
    } catch {
        $message = $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($message) `
            -or -not $message.Contains($ExpectedMessage, [StringComparison]::Ordinal)) {
        throw "Universalizer path fixture '$Id' did not fail with '$ExpectedMessage'. Observed: $message"
    }
    if (-not $outputExisted -and (Test-Path -LiteralPath $OutputDirectory)) {
        throw "Universalizer path fixture '$Id' wrote its output directory before rejection."
    }
    if (-not $reportExisted -and (Test-Path -LiteralPath $ReportPath)) {
        throw "Universalizer path fixture '$Id' wrote its report before rejection."
    }
    return [pscustomobject]@{ id=$Id; status='rejected-before-write'; message=$message }
}

$scratchRootFull = [IO.Path]::GetFullPath($ScratchRoot)
$reportPathFull = [IO.Path]::GetFullPath($ReportPath)
if (Test-Path -LiteralPath $scratchRootFull) { throw "ScratchRoot must be fresh: $scratchRootFull" }
[IO.Directory]::CreateDirectory($scratchRootFull) | Out-Null

$positive = New-Fixture -Name 'positive'
$positiveEvidence = Test-PatchletSplitSourceSet -Resolution $positive.resolution -SourceApkSet $positive.root
if ($positiveEvidence.status -ne 'matched' -or $positiveEvidence.memberCount -ne 3) {
    throw 'Positive split-source fixture did not return the exact matched evidence.'
}

$negative = @()
$fixture = New-Fixture -Name 'missing-member'
[IO.File]::Delete((Join-Path $fixture.root 'split_config.xhdpi.apk'))
$negative += Assert-Rejected -Id 'missing-member' -Action { Test-PatchletSplitSourceSet -Resolution $fixture.resolution -SourceApkSet $fixture.root }

$fixture = New-Fixture -Name 'extra-apk'
[IO.File]::WriteAllText((Join-Path $fixture.root 'extra.apk'), 'extra', [Text.UTF8Encoding]::new($false))
$negative += Assert-Rejected -Id 'extra-apk' -Action { Test-PatchletSplitSourceSet -Resolution $fixture.resolution -SourceApkSet $fixture.root }

$fixture = New-Fixture -Name 'nested-apk'
[IO.Directory]::CreateDirectory((Join-Path $fixture.root 'nested')) | Out-Null
[IO.File]::WriteAllText((Join-Path $fixture.root 'nested\extra.apk'), 'extra', [Text.UTF8Encoding]::new($false))
$negative += Assert-Rejected -Id 'nested-apk' -Action { Test-PatchletSplitSourceSet -Resolution $fixture.resolution -SourceApkSet $fixture.root }

$fixture = New-Fixture -Name 'renamed-member'
[IO.File]::Move((Join-Path $fixture.root 'base.apk'), (Join-Path $fixture.root 'renamed.apk'))
$negative += Assert-Rejected -Id 'renamed-member' -Action { Test-PatchletSplitSourceSet -Resolution $fixture.resolution -SourceApkSet $fixture.root }

$fixture = New-Fixture -Name 'member-hash'
$fixture.resolution.source.splitMembers[0].sha256 = '1' * 64
$negative += Assert-Rejected -Id 'member-hash' -Action { Test-PatchletSplitSourceSet -Resolution $fixture.resolution -SourceApkSet $fixture.root }

$fixture = New-Fixture -Name 'member-size'
$fixture.resolution.source.splitMembers[1].size = [long]$fixture.resolution.source.splitMembers[1].size + 1
$negative += Assert-Rejected -Id 'member-size' -Action { Test-PatchletSplitSourceSet -Resolution $fixture.resolution -SourceApkSet $fixture.root }

$fixture = New-Fixture -Name 'set-hash'
$fixture.resolution.source.splitSetSha256 = '2' * 64
$negative += Assert-Rejected -Id 'set-hash' -Action { Test-PatchletSplitSourceSet -Resolution $fixture.resolution -SourceApkSet $fixture.root }

$fixture = New-Fixture -Name 'unsafe-name'
$fixture.resolution.source.splitMembers[0].fileName = '..\base.apk'
$negative += Assert-Rejected -Id 'unsafe-name' -Action { Test-PatchletSplitSourceSet -Resolution $fixture.resolution -SourceApkSet $fixture.root }

$fixture = New-Fixture -Name 'role-order'
$fixture.resolution.source.splitMembers[0].role = 'density'
$negative += Assert-Rejected -Id 'role-order' -Action { Test-PatchletSplitSourceSet -Resolution $fixture.resolution -SourceApkSet $fixture.root }

$fixture = New-Fixture -Name 'duplicate-name'
$fixture.resolution.source.splitMembers[2].fileName = 'base.apk'
$negative += Assert-Rejected -Id 'duplicate-name' -Action { Test-PatchletSplitSourceSet -Resolution $fixture.resolution -SourceApkSet $fixture.root }

if ($negative.Count -ne 10) { throw "Split-source negative fixture count drifted: $($negative.Count)." }

$toolJar = Join-Path $scratchRootFull 'APKEditor-1.4.9.jar'
[IO.File]::WriteAllText($toolJar, 'reviewed-tool-fixture', [Text.UTF8Encoding]::new($false))
$toolResolution = [pscustomobject]@{
    toolchain = [pscustomobject]@{
        apkEditorVersion = '1.4.9'
        apkEditorArscLibVersion = '1.3.9'
        apkEditorJarSha256 = Get-PatchletSha256 -Path $toolJar
        apkEditorMergeArguments = @(
            'm', '-i', '{sourceSet}', '-o', '{outputApk}',
            '-clean-meta', '-validate-modules', '-extractNativeLibs', 'false'
        )
    }
}
$toolPositiveEvidence = Test-PatchletApkEditorContract -Resolution $toolResolution -ApkEditorJar $toolJar
function Copy-ToolResolution {
    return ($toolResolution | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
}
$toolNegative = @()
$toolFixture = Copy-ToolResolution
$toolFixture.toolchain.apkEditorVersion = '1.5.0'
$toolNegative += Assert-Rejected -Id 'apkeditor-version' -Action { Test-PatchletApkEditorContract -Resolution $toolFixture -ApkEditorJar $toolJar }
$toolFixture = Copy-ToolResolution
$toolFixture.toolchain.apkEditorArscLibVersion = '1.4.0'
$toolNegative += Assert-Rejected -Id 'arsclib-version' -Action { Test-PatchletApkEditorContract -Resolution $toolFixture -ApkEditorJar $toolJar }
$toolFixture = Copy-ToolResolution
$toolFixture.toolchain.apkEditorJarSha256 = '4' * 64
$toolNegative += Assert-Rejected -Id 'apkeditor-hash' -Action { Test-PatchletApkEditorContract -Resolution $toolFixture -ApkEditorJar $toolJar }
$toolFixture = Copy-ToolResolution
$toolFixture.toolchain.apkEditorMergeArguments = @($toolFixture.toolchain.apkEditorMergeArguments | Where-Object { $_ -ne '-validate-modules' })
$toolNegative += Assert-Rejected -Id 'missing-validate-modules' -Action { Test-PatchletApkEditorContract -Resolution $toolFixture -ApkEditorJar $toolJar }
$toolFixture = Copy-ToolResolution
$toolFixture.toolchain.apkEditorMergeArguments += '-f'
$toolNegative += Assert-Rejected -Id 'unexpected-force-option' -Action { Test-PatchletApkEditorContract -Resolution $toolFixture -ApkEditorJar $toolJar }
$toolFixture = Copy-ToolResolution
$temporaryArgument = $toolFixture.toolchain.apkEditorMergeArguments[5]
$toolFixture.toolchain.apkEditorMergeArguments[5] = $toolFixture.toolchain.apkEditorMergeArguments[6]
$toolFixture.toolchain.apkEditorMergeArguments[6] = $temporaryArgument
$toolNegative += Assert-Rejected -Id 'reordered-options' -Action { Test-PatchletApkEditorContract -Resolution $toolFixture -ApkEditorJar $toolJar }
if ($toolNegative.Count -ne 6) { throw "APKEditor negative fixture count drifted: $($toolNegative.Count)." }

$repositoryRoot = Get-PatchletRepositoryRoot
$universalizer = Join-Path $PSScriptRoot 'Build-SplitSourceUniversalApk.ps1'
$pathContractResolution = Join-Path $scratchRootFull 'path-contract-resolution.json'
[IO.File]::WriteAllText(
    $pathContractResolution,
    '{}',
    [Text.UTF8Encoding]::new($false))
$outsideOutput = Join-Path $repositoryRoot 'patchlets\.universalizer-output-must-not-exist'
$outsideReport = Join-Path $repositoryRoot 'patchlets\.universalizer-report-must-not-exist.json'
foreach ($mustNotExist in @($outsideOutput, $outsideReport)) {
    if (Test-Path -LiteralPath $mustNotExist) {
        throw "Universalizer path fixture requires an absent sentinel path: $mustNotExist"
    }
}
$pathNegative = @()
$pathNegative += Assert-UniversalizerPathRejectedBeforeWrite `
    -Id 'output-outside-work' `
    -Universalizer $universalizer `
    -SourceApkSet $positive.root `
    -OutputDirectory $outsideOutput `
    -ResolutionPath $pathContractResolution `
    -ReportPath (Join-Path $scratchRootFull 'output-outside-report.json') `
    -ApkEditorJar $toolJar `
    -ExpectedMessage 'output must be a strict child of the workspace work directory'
$pathNegative += Assert-UniversalizerPathRejectedBeforeWrite `
    -Id 'report-outside-work' `
    -Universalizer $universalizer `
    -SourceApkSet $positive.root `
    -OutputDirectory (Join-Path $scratchRootFull 'report-outside-output') `
    -ResolutionPath $pathContractResolution `
    -ReportPath $outsideReport `
    -ApkEditorJar $toolJar `
    -ExpectedMessage 'report must be a strict child of the workspace work directory'
$pathNegative += Assert-UniversalizerPathRejectedBeforeWrite `
    -Id 'output-inside-source' `
    -Universalizer $universalizer `
    -SourceApkSet $positive.root `
    -OutputDirectory (Join-Path $positive.root 'universal-output') `
    -ResolutionPath $pathContractResolution `
    -ReportPath (Join-Path $scratchRootFull 'output-inside-source-report.json') `
    -ApkEditorJar $toolJar `
    -ExpectedMessage 'source set and output directory must be disjoint'
$reportInsideOutputRoot = Join-Path $scratchRootFull 'report-inside-output'
$pathNegative += Assert-UniversalizerPathRejectedBeforeWrite `
    -Id 'report-inside-output' `
    -Universalizer $universalizer `
    -SourceApkSet $positive.root `
    -OutputDirectory $reportInsideOutputRoot `
    -ResolutionPath $pathContractResolution `
    -ReportPath (Join-Path $reportInsideOutputRoot 'report.json') `
    -ApkEditorJar $toolJar `
    -ExpectedMessage 'report must be outside the source set and output directory'
$pathNegative += Assert-UniversalizerPathRejectedBeforeWrite `
    -Id 'report-resolution-alias' `
    -Universalizer $universalizer `
    -SourceApkSet $positive.root `
    -OutputDirectory (Join-Path $scratchRootFull 'report-resolution-alias-output') `
    -ResolutionPath $pathContractResolution `
    -ReportPath $pathContractResolution `
    -ApkEditorJar $toolJar `
    -ExpectedMessage 'aliasing between resolution and report'
$pathNegative += Assert-UniversalizerPathRejectedBeforeWrite `
    -Id 'resolution-apkeditor-alias' `
    -Universalizer $universalizer `
    -SourceApkSet $positive.root `
    -OutputDirectory (Join-Path $scratchRootFull 'resolution-apkeditor-alias-output') `
    -ResolutionPath $pathContractResolution `
    -ReportPath (Join-Path $scratchRootFull 'resolution-apkeditor-alias-report.json') `
    -ApkEditorJar $pathContractResolution `
    -ExpectedMessage 'aliasing between resolution and APKEditor'
$pathNegative += Assert-UniversalizerPathRejectedBeforeWrite `
    -Id 'resolution-inside-source' `
    -Universalizer $universalizer `
    -SourceApkSet $positive.root `
    -OutputDirectory (Join-Path $scratchRootFull 'resolution-inside-source-output') `
    -ResolutionPath (Join-Path $positive.root 'base.apk') `
    -ReportPath (Join-Path $scratchRootFull 'resolution-inside-source-report.json') `
    -ApkEditorJar $toolJar `
    -ExpectedMessage 'must not contain the resolution or APKEditor file'
if ($pathNegative.Count -ne 7) {
    throw "Universalizer path negative fixture count drifted: $($pathNegative.Count)."
}

$report = [ordered]@{
    schemaVersion = 1
    status = 'passed'
    positive = $positiveEvidence
    negativeFixtureCount = $negative.Count
    negativeFixtures = @($negative)
    apkEditor = $toolPositiveEvidence
    apkEditorNegativeFixtureCount = $toolNegative.Count
    apkEditorNegativeFixtures = @($toolNegative)
    pathNegativeFixtureCount = $pathNegative.Count
    pathNegativeFixtures = @($pathNegative)
}
Write-PatchletJson -Value $report -Path $reportPathFull
[pscustomobject]$report
