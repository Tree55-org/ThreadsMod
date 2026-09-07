[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceApk,
    [Parameter(Mandatory)][string]$DecodedRoot,
    [Parameter(Mandatory)][string]$ScratchRoot,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$ReportPath,
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$BuildToolsVersion = '36.0.0',
    [string]$Java = 'java',
    [string]$Javac = 'javac',
    [string]$Jar = 'jar'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

$decodedRootFull = [IO.Path]::GetFullPath($DecodedRoot)
$resolutionPathFull = [IO.Path]::GetFullPath($ResolutionPath)
$before = Get-PatchletCompleteTreeState -Root $decodedRootFull

$reapply = & (Join-Path $PSScriptRoot 'Apply-Patchlets.ps1') `
    -SourceApk $SourceApk `
    -DecodedRoot $decodedRootFull `
    -ScratchRoot $ScratchRoot `
    -ResolutionPath $resolutionPathFull `
    -AndroidSdk $AndroidSdk `
    -BuildToolsVersion $BuildToolsVersion `
    -Java $Java `
    -Javac $Javac `
    -Jar $Jar

$after = Get-PatchletCompleteTreeState -Root $decodedRootFull
$unexpectedWrites = [int]$reapply.identity.applied `
    + [int]$reapply.settingsUi.applied `
    + [int]$reapply.injection.generatedCreated `
    + [int]$reapply.injection.bridgeCreated `
    + [int]$reapply.injection.inlineCreated `
    + [int]$reapply.injection.reportTemplateCreated `
    + [int]$reapply.injection.settingsTemplateCreated `
    + [int]$reapply.hooks.applied `
    + [int]$reapply.drawerSettings.applied `
    + [int]$reapply.inlineControls.applied `
    + [int]$reapply.proxyManifest.applied `
    + [int]$reapply.proxyNative.applied `
    + [int]$reapply.proxyLicense.applied `
    + [int]$reapply.update.applied
if ($before.sha256 -ne $after.sha256 -or $unexpectedWrites -ne 0) {
    throw "Patchlet idempotency failed. Before='$($before.sha256)' After='$($after.sha256)' BeforeFiles=$($before.files) AfterFiles=$($after.files) BeforeDirectories=$($before.directories) AfterDirectories=$($after.directories) UnexpectedWrites=$unexpectedWrites"
}

$report = [ordered]@{
    schemaVersion = 2
    checkedAt = (Get-Date).ToString('o')
    status = 'passed'
    scope = 'complete-decoded-tree'
    exclusions = @()
    decodedFiles = $before.files
    decodedDirectories = $before.directories
    decodedEntries = $before.entries
    beforeSha256 = $before.sha256
    afterSha256 = $after.sha256
    unchanged = $true
    noOpCounts = [ordered]@{
        identity = [int]$reapply.identity.noOp
        settingsUi = [int]$reapply.settingsUi.noOp
        generatedSmali = [int]$reapply.injection.generatedNoOp
        bridge = [int]$reapply.injection.bridgeNoOp
        inlineTemplates = [int]$reapply.injection.inlineNoOp
        reportTemplates = [int]$reapply.injection.reportTemplateNoOp
        settingsTemplates = [int]$reapply.injection.settingsTemplateNoOp
        hooks = [int]$reapply.hooks.noOp
        drawerSettings = [int]$reapply.drawerSettings.noOp
        inlineControls = [int]$reapply.inlineControls.noOp
        proxyManifest = [int]$reapply.proxyManifest.noOp
        proxyNative = [int]$reapply.proxyNative.noOp
        proxyLicense = [int]$reapply.proxyLicense.noOp
        update = [int]$reapply.update.noOp
    }
}
if ($ReportPath) { Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath)) }
[pscustomobject]$report
