[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TaskPath,
    [Parameter(Mandatory)][string]$ProposalPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

$repositoryRoot = Get-PatchletRepositoryRoot
if (-not (Test-Json -LiteralPath ([IO.Path]::GetFullPath($TaskPath)) -SchemaFile (Join-Path $repositoryRoot 'patchlets\schemas\ai-task.schema.json') -ErrorAction Stop)) { throw 'AI task failed schema validation.' }
if (-not (Test-Json -LiteralPath ([IO.Path]::GetFullPath($ProposalPath)) -SchemaFile (Join-Path $repositoryRoot 'patchlets\schemas\ai-resolution.schema.json') -ErrorAction Stop)) { throw 'AI proposal failed schema validation.' }
$task = Read-PatchletJson -Path ([IO.Path]::GetFullPath($TaskPath))
$proposal = Read-PatchletJson -Path ([IO.Path]::GetFullPath($ProposalPath))
if ([string]$proposal.taskId -ne [string]$task.taskId) { throw 'AI proposal taskId does not match its bounded task.' }
if ([string]$proposal.sourceApkSha256 -ne [string]$task.source.apkSha256) { throw 'AI proposal source APK digest does not match its bounded task.' }

$roles = @($task.roles | ForEach-Object { [string]$_ })
$evidenceIds = @($task.evidence | ForEach-Object { [string]$_.id })
$candidateById = @{}
foreach ($candidate in @($task.candidates)) { $candidateById[[string]$candidate.id] = $candidate }
$proposedRoles = @()
$highRiskPattern = '(?i)(mutation|callback|session|identity-preserve|block-mode|operation)'

foreach ($selection in @($proposal.proposals)) {
    $role = [string]$selection.role
    $candidateId = [string]$selection.selectedCandidateId
    if ($roles -notcontains $role) { throw "Proposal references undeclared role '$role'." }
    if (-not $candidateById.ContainsKey($candidateId)) { throw "Proposal invented candidate '$candidateId'." }
    if ([string]$candidateById[$candidateId].role -ne $role) { throw "Candidate '$candidateId' does not belong to role '$role'." }
    $candidateEvidenceIds = @($candidateById[$candidateId].evidenceIds | ForEach-Object { [string]$_ })
    foreach ($evidenceId in @($selection.evidenceIds)) {
        if ($evidenceIds -notcontains [string]$evidenceId) { throw "Proposal invented evidence '$evidenceId'." }
        if ($candidateEvidenceIds -notcontains [string]$evidenceId) { throw "Evidence '$evidenceId' is not attached to selected candidate '$candidateId'." }
    }
    foreach ($alternative in @($selection.alternatives)) {
        $alternativeId = [string]$alternative
        if (-not $candidateById.ContainsKey($alternativeId)) { throw "Proposal invented alternative '$alternativeId'." }
        if ([string]$candidateById[$alternativeId].role -ne $role) { throw "Alternative '$alternativeId' belongs to a different role." }
    }
    if ($role -match $highRiskPattern -and -not [bool]$selection.requiresHumanReview) {
        throw "High-risk role '$role' must remain marked for human review."
    }
    $proposedRoles += $role
}
if (@($proposedRoles | Sort-Object -Unique).Count -ne $proposedRoles.Count) { throw 'AI proposal contains duplicate role selections.' }

$unresolved = @($proposal.unresolved | ForEach-Object { [string]$_ })
if (@($unresolved | Sort-Object -Unique).Count -ne $unresolved.Count) { throw 'AI proposal contains duplicate unresolved roles.' }
foreach ($role in $unresolved) {
    if ($roles -notcontains $role) { throw "Proposal invented unresolved role '$role'." }
    if ($proposedRoles -contains $role) { throw "Role '$role' is both proposed and unresolved." }
}
$covered = @($proposedRoles + $unresolved | Sort-Object -Unique)
$missing = @($roles | Where-Object { $covered -notcontains $_ })
if ($missing.Count -gt 0) { throw "Proposal omitted roles without marking them unresolved: $($missing -join ', ')" }

$report = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToString('o')
    status = if ($unresolved.Count -eq 0) { 'valid-proposal-needs-human-review' } else { 'valid-but-unresolved' }
    taskId = [string]$task.taskId
    sourceApkSha256 = [string]$task.source.apkSha256
    selectedRoles = $proposedRoles.Count
    unresolvedRoles = $unresolved
    productionAuthorityGranted = $false
    nextStep = 'human-review-and-new-resolution'
}
if ($ReportPath) { Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath)) }
[pscustomobject]$report
