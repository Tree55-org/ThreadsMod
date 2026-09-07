[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceApkSet,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$KeyStore,
    [Parameter(Mandatory)][string]$KeyAlias,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$KeyStorePasswordEnvironment = 'THREADSMOD_KS_PASS',
    [string]$KeyPasswordEnvironment = 'THREADSMOD_KEY_PASS',
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$BuildToolsVersion = '36.0.0',
    [string]$Java = 'java',
    [string]$Javac = 'javac',
    [string]$Jar = 'jar',
    [ValidateSet('Release', 'SignedReview')][string]$ValidationMode = 'Release',
    [string]$ReviewDeviceSerial,
    [string]$PublishPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pipelineEntryPath = [IO.Path]::GetFullPath($PSCommandPath)
$moduleEntryPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1'))
$bootstrapEntryHandles = @()
try {
    $bootstrapEntryHandles = @(
        [IO.File]::Open($pipelineEntryPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read),
        [IO.File]::Open($moduleEntryPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    )
    $parsedEntryText = ([string]$MyInvocation.MyCommand.ScriptBlock.Ast.Extent.Text).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n")
    $diskEntryText = ([IO.File]::ReadAllText($pipelineEntryPath)).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n")
    if (-not $parsedEntryText.Equals($diskEntryText, [StringComparison]::Ordinal)) {
        throw 'Running pipeline AST differs from the read-locked entry script bytes.'
    }
    $pipelineEntrySha256 = (Get-FileHash -LiteralPath $pipelineEntryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $moduleEntrySha256 = (Get-FileHash -LiteralPath $moduleEntryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Import-Module $moduleEntryPath -Force -DisableNameChecking
} catch {
    foreach ($handle in @($bootstrapEntryHandles)) { $handle.Dispose() }
    $bootstrapEntryHandles = @()
    throw
}

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Native command failed with exit code ${code}: $Command" }
}

function Assert-ReleaseInputsFrozen {
    param(
        [Parameter(Mandatory)][object[]]$Snapshot,
        [Parameter(Mandatory)]$Resolution,
        [Parameter(Mandatory)][string]$CanonicalResolutionPath,
        [Parameter(Mandatory)][string]$ExpectedSourceSha256,
        [Parameter(Mandatory)][string]$ExpectedResolutionSha256,
        [Parameter(Mandatory)][string]$ExpectedResolutionStatus,
        [Parameter(Mandatory)][bool]$ExpectedUpdateSignedDexReviewRequired,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)]$InputLock,
        [Parameter(Mandatory)]$DerivedSourceLock,
        [Parameter(Mandatory)][string]$Stage
    )

    $lockCheck = Assert-PatchletInputFreezeLock -Lock $InputLock -Stage $Stage
    $derivedLockCheck = Assert-PatchletInputFreezeLock -Lock $DerivedSourceLock -Stage "$Stage-derived-source"
    $freeze = Assert-PatchletInputFreeze -Snapshot $Snapshot -Stage $Stage
    $beforeRead = Get-PatchletSha256 -Path $CanonicalResolutionPath
    $currentResolution = Read-PatchletJson -Path $CanonicalResolutionPath
    $afterRead = Get-PatchletSha256 -Path $CanonicalResolutionPath
    if ($beforeRead -ne $ExpectedResolutionSha256 -or $afterRead -ne $ExpectedResolutionSha256) {
        throw "Resolution file drifted while checking '$Stage'."
    }
    if ([string]$currentResolution.status -cne $ExpectedResolutionStatus `
            -or [string]$currentResolution.source.sha256 -ne $ExpectedSourceSha256 `
            -or $currentResolution.release.updateSignedDexReviewRequired `
                -ne $ExpectedUpdateSignedDexReviewRequired `
            -or [string]$Resolution.status -cne $ExpectedResolutionStatus `
            -or [string]$Resolution.source.sha256 -ne $ExpectedSourceSha256 `
            -or $Resolution.release.updateSignedDexReviewRequired `
                -ne $ExpectedUpdateSignedDexReviewRequired) {
        throw "Snapshotted resolution semantics do not match the bound validation mode at '$Stage'."
    }
    $assets = @(Test-PatchletAssets -Resolution $Resolution -RepositoryRoot $RepositoryRoot)
    return [pscustomobject]@{
        stage = $Stage
        checkedAt = (Get-Date).ToString('o')
        status = 'matched'
        sourceApkSha256 = $ExpectedSourceSha256
        resolutionFileSha256 = $ExpectedResolutionSha256
        canonicalAssets = $assets.Count
        treeMonitorEvents = $lockCheck.treeMonitorEvents
        derivedSourceLock = $derivedLockCheck
        inputs = @($freeze.inputs)
    }
}

function Assert-GeneratedReleaseInputsFrozen {
    param(
        [Parameter(Mandatory)][object[]]$DecodedSnapshot,
        [Parameter(Mandatory)]$DecodedLock,
        [Parameter(Mandatory)][string]$DecodedBuildCache,
        [Parameter(Mandatory)][object[]]$BuildWorkingSnapshot,
        [Parameter(Mandatory)]$BuildWorkingLock,
        [Parameter(Mandatory)][string]$BuildWorkingBuildCache,
        [Parameter(Mandatory)][string]$BuildWorkingManifest,
        [Parameter(Mandatory)][string]$BuildWorkingManifestOriginal,
        [Parameter(Mandatory)][object[]]$CandidateSnapshot,
        [Parameter(Mandatory)]$CandidateLock,
        [Parameter(Mandatory)][string]$Stage
    )

    if (Test-Path -LiteralPath $DecodedBuildCache) {
        throw "Derived Apktool build cache unexpectedly remains at '$Stage': $DecodedBuildCache"
    }
    if (Test-Path -LiteralPath $BuildWorkingBuildCache) {
        throw "Build-working Apktool cache unexpectedly remains at '$Stage': $BuildWorkingBuildCache"
    }
    if (Test-Path -LiteralPath $BuildWorkingManifestOriginal) {
        throw "Build-working manifest backup unexpectedly remains at '$Stage': $BuildWorkingManifestOriginal"
    }
    $decodedLockCheck = Assert-PatchletInputFreezeLock `
        -Lock $DecodedLock -Stage "$Stage-decoded-lock"
    $decodedFreezeCheck = Assert-PatchletInputFreeze `
        -Snapshot $DecodedSnapshot -Stage "$Stage-decoded-tree"
    $buildWorkingLockCheck = Assert-PatchletInputFreezeLock `
        -Lock $BuildWorkingLock -Stage "$Stage-build-working-sealed-lock"
    $buildWorkingFreezeCheck = Assert-PatchletInputFreeze `
        -Snapshot $BuildWorkingSnapshot -Stage "$Stage-build-working-tree"
    $candidateLockCheck = Assert-PatchletInputFreezeLock `
        -Lock $CandidateLock -Stage "$Stage-candidate-lock"
    $candidateFreezeCheck = Assert-PatchletInputFreeze `
        -Snapshot $CandidateSnapshot -Stage "$Stage-candidate-apk"
    return [pscustomobject]@{
        stage = $Stage
        checkedAt = (Get-Date).ToString('o')
        status = 'matched'
        decoded = [pscustomobject]@{ lock = $decodedLockCheck; freeze = $decodedFreezeCheck }
        buildWorking = [pscustomobject]@{ lock = $buildWorkingLockCheck; freeze = $buildWorkingFreezeCheck }
        candidate = [pscustomobject]@{ lock = $candidateLockCheck; freeze = $candidateFreezeCheck }
    }
}

function Get-PipelineReadableFileFailureEvidence {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $exists = Test-Path -LiteralPath $fullPath
    $kind = if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        'file'
    } elseif (Test-Path -LiteralPath $fullPath -PathType Container) {
        'directory'
    } elseif ($exists) {
        'other'
    } else {
        'absent'
    }
    $sha256 = $null
    $readError = $null
    if ($kind -eq 'file') {
        try { $sha256 = Get-PatchletSha256 -Path $fullPath } catch { $readError = $_.Exception.Message }
    }
    return [pscustomobject]@{
        path = $fullPath
        exists = $exists
        kind = $kind
        readableSha256 = $sha256
        readError = $readError
    }
}

function Get-PipelineCompleteTreeFailureEvidence {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $exists = Test-Path -LiteralPath $fullPath
    $kind = if (Test-Path -LiteralPath $fullPath -PathType Container) {
        'directory'
    } elseif (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        'file'
    } elseif ($exists) {
        'other'
    } else {
        'absent'
    }
    $state = $null
    $readError = $null
    if ($kind -eq 'directory') {
        try {
            $complete = Get-PatchletCompleteTreeState -Root $fullPath
            $state = [pscustomobject]@{
                sha256 = [string]$complete.sha256
                files = [int]$complete.files
                directories = [int]$complete.directories
                entries = [int]$complete.entries
            }
        } catch {
            $readError = $_.Exception.Message
        }
    } elseif ($kind -eq 'file') {
        try {
            $state = [pscustomobject]@{ readableSha256 = Get-PatchletSha256 -Path $fullPath }
        } catch {
            $readError = $_.Exception.Message
        }
    }
    return [pscustomobject]@{
        path = $fullPath
        exists = $exists
        kind = $kind
        completeState = $state
        readError = $readError
    }
}

function Get-PipelineLockFailureEvidence {
    param(
        [AllowNull()]$Lock,
        [string[]]$AllowedTreeMutationRoots = @(),
        [string[]]$AllowedFileMutationPaths = @()
    )

    if ($null -eq $Lock) { return $null }
    $events = @($Lock.monitors | ForEach-Object { @($_.SnapshotEvents()) })
    $assertionStatus = 'passed'
    $assertionError = $null
    try {
        $null = Assert-PatchletInputFreezeLock `
            -Lock $Lock `
            -Stage 'failure-evidence' `
            -AllowedTreeMutationRoots $AllowedTreeMutationRoots `
            -AllowedFileMutationPaths $AllowedFileMutationPaths
    } catch {
        $assertionStatus = 'failed'
        $assertionError = $_.Exception.Message
    }
    return [pscustomobject]@{
        acquiredAt = $Lock.acquiredAt
        status = [string]$Lock.status
        assertionStatus = $assertionStatus
        assertionError = $assertionError
        fileCount = [int]$Lock.fileCount
        treeMonitorCount = [int]$Lock.treeMonitorCount
        allowedTreeMutationRoots = @($Lock.allowedTreeMutationRoots)
        allowedFileMutationPaths = @($Lock.allowedFileMutationPaths)
        monitorEventCount = $events.Count
        monitorEvents = @($events | Select-Object -First 100)
        monitorEventsTruncated = $events.Count -gt 100
    }
}

try {
$repositoryRoot = Get-PatchletRepositoryRoot
$allowedRunsRoot = Join-Path $repositoryRoot 'work'
$isSignedReview = $ValidationMode -ceq 'SignedReview'
if ($isSignedReview -and -not [string]::IsNullOrWhiteSpace($PublishPath)) {
    throw 'SignedReview mode forbids PublishPath and cannot publish an APK.'
}
if ($isSignedReview -and [string]::IsNullOrWhiteSpace($ReviewDeviceSerial)) {
    throw 'SignedReview mode requires ReviewDeviceSerial for the exact-primary-DEX Activity UI probe.'
}
if (-not $isSignedReview -and -not [string]::IsNullOrWhiteSpace($ReviewDeviceSerial)) {
    throw 'ReviewDeviceSerial is valid only in SignedReview mode.'
}
$expectedResolutionStatus = if ($isSignedReview) { 'review-required' } else { 'verified-current' }
$expectedUpdateSignedDexReviewRequired = $isSignedReview
$runRootFull = Assert-PatchletPathUnderRoot -Path ([IO.Path]::GetFullPath($RunRoot)) -Root $allowedRunsRoot
if (Test-Path -LiteralPath $runRootFull) { throw "RunRoot must be fresh and may not be reused: $runRootFull" }
[IO.Directory]::CreateDirectory($runRootFull) | Out-Null

$sourceApkSetFull = [IO.Path]::GetFullPath($SourceApkSet)
$resolutionPathFull = [IO.Path]::GetFullPath($ResolutionPath)
$resolutionDirectoryFull = Split-Path -Parent $resolutionPathFull
$canonicalPatchletsRoot = Join-Path $repositoryRoot 'patchlets'
$sourceSetSnapshotDirectory = Join-Path $runRootFull 'source-set-snapshot'
$universalizationOutputDirectory = Join-Path $runRootFull 'source-universalization'
$sourceSnapshotFull = Join-Path $universalizationOutputDirectory 'source-universal-a.apk'
$sourceRepeatFull = Join-Path $universalizationOutputDirectory 'source-universal-b.apk'
$sourceApkFull = $sourceSnapshotFull
$universalizationReportPath = Join-Path $runRootFull 'universalization-check.json'
$splitSourceContractReportPath = Join-Path $runRootFull 'split-source-contract-check.json'
$resolutionSnapshotDirectory = Join-Path $runRootFull 'resolution-snapshot'
$resolutionSnapshotPath = Join-Path $resolutionSnapshotDirectory 'resolution.json'
$buildReportPath = Join-Path $runRootFull 'build-report.json'
$publishFull = $null
$publishTemporary = $null
$publishCommitted = $false
$publicationMoveAttempted = $false
$postCommitRollback = $null
$resolution = $null
$final = $null
$initialSourceSha256 = $null
$initialSourceSetSha256 = $null
$initialResolutionSha256 = $null
$initialResolutionTreeSha256 = $null
$initialPatchletsTreeSha256 = $null
$inputSnapshotCapturedAt = $null
$releaseInputFreeze = @()
$releaseInputCapturedAt = $null
$releaseInputLock = $null
$derivedSourceInputFreeze = @()
$derivedSourceInputLock = $null
$sourceSetEvidence = $null
$sourceSetSnapshotEvidence = $null
$universalization = $null
$splitSourceContractCheck = $null
$decodedRoot = $null
$decodedBuildCache = $null
$decodedInputFreeze = @()
$decodedInputLock = $null
$decodedInputChecks = @()
$buildWorkingCopy = $null
$buildWorkingRoot = $null
$buildWorkingBuildCache = $null
$buildWorkingManifest = $null
$buildWorkingManifestOriginal = $null
$buildWorkingInputFreeze = @()
$buildWorkingMutationLock = $null
$buildWorkingInputLock = $null
$buildWorkingInputChecks = @()
$candidateInputFreeze = @()
$candidateInputLock = $null
$candidateInputChecks = @()
$activityUiReview = $null
$currentStage = 'publish-path-validation'
} catch {
    foreach ($handle in @($bootstrapEntryHandles)) { $handle.Dispose() }
    $bootstrapEntryHandles = @()
    throw
}

try {
if ($PublishPath) {
    $distRoot = Join-Path $repositoryRoot 'dist'
    $publishFull = Assert-PatchletPathUnderRoot `
        -Path ([IO.Path]::GetFullPath($PublishPath)) -Root $distRoot
    if (Test-Path -LiteralPath $publishFull) {
        throw "Refusing to overwrite published artifact: $publishFull"
    }
}
$currentStage = 'input-snapshot'
foreach ($requiredInput in @($sourceApkSetFull, $resolutionPathFull, $resolutionDirectoryFull)) {
    if (-not (Test-Path -LiteralPath $requiredInput)) {
        throw "Required release input does not exist: $requiredInput"
    }
}
$initialResolutionSha256 = Get-PatchletSha256 -Path $resolutionPathFull
$initialResolutionTreeSha256 = Get-PatchletTreeSha256 -Root $resolutionDirectoryFull -Filter '*'
$initialPatchletsTreeSha256 = Get-PatchletTreeSha256 -Root $canonicalPatchletsRoot -Filter '*'
$inputSnapshotCapturedAt = (Get-Date).ToString('o')
Copy-Item -LiteralPath $resolutionDirectoryFull -Destination $resolutionSnapshotDirectory -Recurse
if ((Get-PatchletSha256 -Path $resolutionSnapshotPath) -ne $initialResolutionSha256 `
        -or (Get-PatchletTreeSha256 -Root $resolutionSnapshotDirectory -Filter '*') -ne $initialResolutionTreeSha256 `
        -or (Get-PatchletSha256 -Path $resolutionPathFull) -ne $initialResolutionSha256 `
        -or (Get-PatchletTreeSha256 -Root $resolutionDirectoryFull -Filter '*') -ne $initialResolutionTreeSha256 `
        -or (Get-PatchletTreeSha256 -Root $canonicalPatchletsRoot -Filter '*') -ne $initialPatchletsTreeSha256) {
    throw 'Resolution directory or canonical patchlets tree drifted while creating the release snapshot.'
}

$currentStage = 'resolution-binding'
$resolution = Read-PatchletJson -Path $resolutionSnapshotPath
if ([string]$resolution.status -cne $expectedResolutionStatus `
        -or $resolution.release.updateSignedDexReviewRequired `
            -ne $expectedUpdateSignedDexReviewRequired) {
    throw "Resolution state does not match ValidationMode '$ValidationMode'."
}
if ([string]$resolution.source.delivery -ne 'split-apk-set') {
    throw "Installable pipeline requires a split-apk-set source resolution."
}
$initialSourceSha256 = ([string]$resolution.source.sha256).ToLowerInvariant()
$sourceSetEvidence = Test-PatchletSplitSourceSet -Resolution $resolution -SourceApkSet $sourceApkSetFull
$initialSourceSetSha256 = [string]$sourceSetEvidence.sha256
[IO.Directory]::CreateDirectory($sourceSetSnapshotDirectory) | Out-Null
foreach ($member in @($resolution.source.splitMembers)) {
    [IO.File]::Copy(
        (Join-Path $sourceApkSetFull ([string]$member.fileName)),
        (Join-Path $sourceSetSnapshotDirectory ([string]$member.fileName)),
        $false)
}
$sourceSetSnapshotEvidence = Test-PatchletSplitSourceSet -Resolution $resolution -SourceApkSet $sourceSetSnapshotDirectory
$canonicalSourceSetRecheck = Test-PatchletSplitSourceSet -Resolution $resolution -SourceApkSet $sourceApkSetFull
if ([string]$sourceSetSnapshotEvidence.sha256 -ne $initialSourceSetSha256 `
        -or [string]$canonicalSourceSetRecheck.sha256 -ne $initialSourceSetSha256 `
        -or (Get-PatchletSha256 -Path $resolutionPathFull) -ne $initialResolutionSha256 `
        -or (Get-PatchletTreeSha256 -Root $resolutionDirectoryFull -Filter '*') -ne $initialResolutionTreeSha256 `
        -or (Get-PatchletTreeSha256 -Root $canonicalPatchletsRoot -Filter '*') -ne $initialPatchletsTreeSha256) {
    throw 'Split source set, resolution, or canonical patchlets drifted while creating the exact source snapshot.'
}

if ($BuildToolsVersion -ne [string]$resolution.toolchain.buildToolsVersion) {
    throw "Build Tools version '$BuildToolsVersion' differs from the snapshotted resolution's '$($resolution.toolchain.buildToolsVersion)'."
}
$buildToolsDirectory = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion"
$apktoolJar = Join-Path $repositoryRoot '.tools\apktool\apktool_3.0.3.jar'
$apkEditorJar = Join-Path $repositoryRoot '.tools\apkeditor\APKEditor-1.4.9.jar'
$frameworkDirectory = Join-Path $repositoryRoot 'decompiled\apktool-framework'
$frameworkApk = Join-Path $frameworkDirectory '1.apk'
$androidJar = Join-Path $AndroidSdk "platforms\android-$($resolution.toolchain.androidPlatform)\android.jar"
$d8Jar = Join-Path $buildToolsDirectory 'lib\d8.jar'
$apksignerJar = Join-Path $buildToolsDirectory 'lib\apksigner.jar'
$aapt2 = Join-Path $buildToolsDirectory 'aapt2.exe'
$zipalign = Join-Path $buildToolsDirectory 'zipalign.exe'
$jadxJar = Join-Path $repositoryRoot '.tools\jadx-1.5.6\lib\jadx-1.5.6-all.jar'
$dexInspectorSource = Join-Path $PSScriptRoot 'DexInspector.java'
$sevenZip = 'C:\Program Files\7-Zip\7z.exe'
$javaExecutable = (Get-Command $Java -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$javacExecutable = (Get-Command $Javac -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$jarExecutable = (Get-Command $Jar -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$Java = $javaExecutable
$Javac = $javacExecutable
$Jar = $jarExecutable

$canonicalAssets = @(Test-PatchletAssets -Resolution $resolution -RepositoryRoot $repositoryRoot)
$freezeInputs = @(
    [pscustomobject]@{ id = 'source-apk-set'; kind = 'tree'; path = $sourceApkSetFull; filter = '*.apk' },
    [pscustomobject]@{ id = 'source-apk-set-snapshot'; kind = 'tree'; path = $sourceSetSnapshotDirectory; filter = '*.apk' },
    [pscustomobject]@{ id = 'resolution-file'; kind = 'file'; path = $resolutionPathFull; filter = $null },
    [pscustomobject]@{ id = 'resolution-directory'; kind = 'tree'; path = $resolutionDirectoryFull; filter = '*' },
    [pscustomobject]@{ id = 'resolution-snapshot-directory'; kind = 'tree'; path = $resolutionSnapshotDirectory; filter = '*' },
    [pscustomobject]@{ id = 'canonical-patchlets-tree'; kind = 'tree'; path = $canonicalPatchletsRoot; filter = '*' },
    [pscustomobject]@{ id = 'entry:pipeline'; kind = 'file'; path = $pipelineEntryPath; filter = $null },
    [pscustomobject]@{ id = 'entry:module'; kind = 'file'; path = $moduleEntryPath; filter = $null }
)
foreach ($asset in $canonicalAssets) {
    $freezeInputs += [pscustomobject]@{
        id = "asset:$($asset.id)"
        kind = [string]$asset.kind
        path = [string]$asset.path
        filter = $asset.filter
    }
}
$toolInputs = @(
    [pscustomobject]@{ id = 'apkeditor'; path = $apkEditorJar; expected = [string]$resolution.toolchain.apkEditorJarSha256 },
    [pscustomobject]@{ id = 'apktool'; path = $apktoolJar; expected = [string]$resolution.toolchain.apktoolJarSha256 },
    [pscustomobject]@{ id = 'framework'; path = $frameworkApk; expected = [string]$resolution.toolchain.frameworkApkSha256 },
    [pscustomobject]@{ id = 'android-jar'; path = $androidJar; expected = $null },
    [pscustomobject]@{ id = 'd8'; path = $d8Jar; expected = [string]$resolution.toolchain.d8JarSha256 },
    [pscustomobject]@{ id = 'apksigner'; path = $apksignerJar; expected = [string]$resolution.toolchain.apksignerJarSha256 },
    [pscustomobject]@{ id = 'aapt2'; path = $aapt2; expected = $null },
    [pscustomobject]@{ id = 'zipalign'; path = $zipalign; expected = $null },
    [pscustomobject]@{ id = 'jadx'; path = $jadxJar; expected = [string]$resolution.toolchain.jadxJarSha256 },
    [pscustomobject]@{ id = 'dex-inspector-source'; path = $dexInspectorSource; expected = [string]$resolution.assets.dexInspectorSourceSha256 },
    [pscustomobject]@{ id = 'seven-zip'; path = $sevenZip; expected = $null },
    [pscustomobject]@{ id = 'java'; path = $javaExecutable; expected = $null },
    [pscustomobject]@{ id = 'javac'; path = $javacExecutable; expected = $null },
    [pscustomobject]@{ id = 'jar'; path = $jarExecutable; expected = $null }
)
foreach ($tool in $toolInputs) {
    $freezeInputs += [pscustomobject]@{
        id = "tool:$($tool.id)"; kind = 'file'; path = [string]$tool.path; filter = $null
    }
}
$releaseInputFreeze = @(New-PatchletInputFreeze -Inputs $freezeInputs)
$releaseInputCapturedAt = (Get-Date).ToString('o')
$requiredCoreFreeze = [ordered]@{
    'source-apk-set' = $initialSourceSetSha256
    'source-apk-set-snapshot' = $initialSourceSetSha256
    'resolution-file' = $initialResolutionSha256
    'resolution-directory' = $initialResolutionTreeSha256
    'resolution-snapshot-directory' = $initialResolutionTreeSha256
    'canonical-patchlets-tree' = $initialPatchletsTreeSha256
    'entry:pipeline' = $pipelineEntrySha256
    'entry:module' = $moduleEntrySha256
}
foreach ($coreId in @($requiredCoreFreeze.Keys)) {
    $frozenCore = @($releaseInputFreeze | Where-Object id -eq $coreId)
    if ($frozenCore.Count -ne 1 -or [string]$frozenCore[0].sha256 -ne [string]$requiredCoreFreeze[$coreId]) {
        throw "Core release input drifted before the complete freeze was captured: $coreId"
    }
}
foreach ($tool in $toolInputs) {
    if ($null -ne $tool.expected) {
        $frozenTool = @($releaseInputFreeze | Where-Object id -eq "tool:$($tool.id)")
        if ($frozenTool.Count -ne 1 -or [string]$frozenTool[0].sha256 -ne [string]$tool.expected) {
            throw "Pinned release tool hash mismatch: $($tool.id)"
        }
    }
}
$releaseInputLock = Enter-PatchletInputFreezeLock -Snapshot $releaseInputFreeze -Stage 'complete-release-input-freeze'
if ((Get-PatchletSha256 -Path $pipelineEntryPath) -ne $pipelineEntrySha256 `
        -or (Get-PatchletSha256 -Path $moduleEntryPath) -ne $moduleEntrySha256) {
    throw 'Pipeline or module entry bytes drifted between bootstrap attestation and complete freeze.'
}
foreach ($handle in @($bootstrapEntryHandles)) { $handle.Dispose() }
$bootstrapEntryHandles = @()

$currentStage = 'split-source-contract-fixtures'
$splitSourceContractCheck = & (Join-Path $PSScriptRoot 'Test-SplitSourceSetContract.ps1') `
    -ScratchRoot (Join-Path $runRootFull 'split-source-contract-fixtures') `
    -ReportPath $splitSourceContractReportPath

$currentStage = 'source-universalization'
$universalizationResults = @(& (Join-Path $PSScriptRoot 'Build-SplitSourceUniversalApk.ps1') `
    -SourceApkSet $sourceSetSnapshotDirectory `
    -OutputDirectory $universalizationOutputDirectory `
    -ResolutionPath $resolutionSnapshotPath `
    -ReportPath $universalizationReportPath `
    -AndroidSdk $AndroidSdk `
    -BuildToolsVersion $BuildToolsVersion `
    -Java $Java `
    -ApkEditorJar $apkEditorJar)
if ($universalizationResults.Count -ne 1) {
    throw "Split universalization must return exactly one evidence object; observed $($universalizationResults.Count)."
}
$universalization = $universalizationResults[0]
if ([string]$universalization.status -ne 'passed' `
        -or [IO.Path]::GetFullPath([string]$universalization.derived.path) -ne [IO.Path]::GetFullPath($sourceSnapshotFull) `
        -or [IO.Path]::GetFullPath([string]$universalization.derived.repeatPath) -ne [IO.Path]::GetFullPath($sourceRepeatFull) `
        -or [string]$universalization.derived.sha256 -ne $initialSourceSha256 `
        -or [string]$universalization.derived.repeatSha256 -ne $initialSourceSha256) {
    throw 'Split universalization evidence does not bind both exact derived APKs.'
}
$null = Assert-PatchletInputFreezeLock -Lock $releaseInputLock -Stage 'after-source-universalization'
$null = Test-PatchletSplitSourceSet -Resolution $resolution -SourceApkSet $sourceApkSetFull
$null = Test-PatchletSplitSourceSet -Resolution $resolution -SourceApkSet $sourceSetSnapshotDirectory
$null = Test-PatchletSourceBinding -Resolution $resolution -SourceApk $sourceSnapshotFull
$derivedSourceInputFreeze = @(New-PatchletInputFreeze -Inputs @(
    [pscustomobject]@{ id = 'derived-source-apk'; kind = 'file'; path = $sourceSnapshotFull; filter = $null },
    [pscustomobject]@{ id = 'derived-source-repeat-apk'; kind = 'file'; path = $sourceRepeatFull; filter = $null }
))
foreach ($derivedInput in $derivedSourceInputFreeze) {
    if ([string]$derivedInput.sha256 -ne $initialSourceSha256) {
        throw "Derived source freeze hash mismatch for '$($derivedInput.id)'."
    }
}
$derivedSourceInputLock = Enter-PatchletInputFreezeLock `
    -Snapshot $derivedSourceInputFreeze -Stage 'derived-source-input-freeze'
$releaseInputFreeze += $derivedSourceInputFreeze
$releaseInputCapturedAt = (Get-Date).ToString('o')

$decodedRoot = Join-Path $runRootFull 'decoded'
$baselineOutput = Join-Path $runRootFull 'baseline-roundtrip'
$finalOutput = Join-Path $runRootFull 'release'
$ledgerPath = Join-Path $runRootFull 'patch-ledger.json'
$resolutionReportPath = Join-Path $runRootFull 'resolution-check.json'
$catalogReportPath = Join-Path $runRootFull 'catalog-check.json'
$hostAssetsReportPath = Join-Path $runRootFull 'host-assets-check.json'
$releaseReportPath = Join-Path $runRootFull 'release-check.json'
$idempotencyReportPath = Join-Path $runRootFull 'idempotency-check.json'

$currentStage = 'catalog-check'
$catalogCheck = & (Join-Path $PSScriptRoot 'Test-PatchletCatalog.ps1') -ResolutionPath $resolutionSnapshotPath -ReportPath $catalogReportPath
$currentStage = 'host-assets-check'
$hostAssetsCheck = & (Join-Path $PSScriptRoot 'Test-HostPatchletAssets.ps1') `
    -ScratchRoot (Join-Path $runRootFull 'host-asset-tests') `
    -ResolutionPath $resolutionSnapshotPath `
    -ReportPath $hostAssetsReportPath `
    -Java $Java `
    -Javac $Javac

$currentStage = 'source-decode'
Invoke-Checked -Command $Java -Arguments @(
    '-jar', $apktoolJar, 'd',
    '--all-src', '--jobs', '8',
    '--frame-path', $frameworkDirectory,
    '--output', $decodedRoot,
    $sourceSnapshotFull
)

$currentStage = 'resolution-check'
$resolutionCheck = & (Join-Path $PSScriptRoot 'Test-Resolution.ps1') `
    -SourceApk $sourceSnapshotFull `
    -DecodedRoot $decodedRoot `
    -ResolutionPath $resolutionSnapshotPath `
    -ReportPath $resolutionReportPath

$currentStage = 'no-change-roundtrip'
$baseline = & (Join-Path $PSScriptRoot 'Build-PatchedApk.ps1') `
    -DecodedRoot $decodedRoot `
    -OutputDirectory $baselineOutput `
    -ArtifactBaseName 'baseline-roundtrip' `
    -ResolutionPath $resolutionSnapshotPath `
    -AndroidSdk $AndroidSdk `
    -BuildToolsVersion $BuildToolsVersion `
    -Java $Java

$baselineBadging = @(& $aapt2 dump badging $baseline.artifact)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect no-change round-trip APK.' }
$baselinePackage = [string]($baselineBadging | Where-Object { $_ -like 'package:*' } | Select-Object -First 1)
if ($baselinePackage -notmatch "name='$([regex]::Escape([string]$resolution.source.applicationId))'") { throw 'No-change round-trip changed the source application ID.' }
if ($baselinePackage -notmatch "versionCode='$($resolution.source.versionCode)'") { throw 'No-change round-trip changed versionCode.' }

$currentStage = 'apply-patchlets'
$ledger = & (Join-Path $PSScriptRoot 'Apply-Patchlets.ps1') `
    -SourceApk $sourceSnapshotFull `
    -DecodedRoot $decodedRoot `
    -ScratchRoot (Join-Path $runRootFull 'java-injection') `
    -ResolutionPath $resolutionSnapshotPath `
    -LedgerPath $ledgerPath `
    -AndroidSdk $AndroidSdk `
    -BuildToolsVersion $BuildToolsVersion `
    -Java $Java `
    -Javac $Javac `
    -Jar $Jar

$currentStage = 'decoded-build-cache-reset'
$decodedBuildCache = Assert-PatchletPathUnderRoot `
    -Path (Join-Path $decodedRoot 'build') -Root $decodedRoot
$baselineBuildCacheRemoved = $false
if (Test-Path -LiteralPath $decodedBuildCache) {
    if (-not (Test-Path -LiteralPath $decodedBuildCache -PathType Container)) {
        throw "Decoded Apktool build cache is not a directory: $decodedBuildCache"
    }
    Remove-Item -LiteralPath $decodedBuildCache -Recurse -Force
    $baselineBuildCacheRemoved = $true
}
if (Test-Path -LiteralPath $decodedBuildCache) {
    throw "Unable to remove the exact derived Apktool build cache: $decodedBuildCache"
}

$currentStage = 'decoded-input-freeze'
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

$currentStage = 'idempotency-check'
$idempotency = & (Join-Path $PSScriptRoot 'Test-PatchletIdempotency.ps1') `
    -SourceApk $sourceSnapshotFull `
    -DecodedRoot $decodedRoot `
    -ScratchRoot (Join-Path $runRootFull 'java-injection-idempotency') `
    -ResolutionPath $resolutionSnapshotPath `
    -ReportPath $idempotencyReportPath `
    -AndroidSdk $AndroidSdk `
    -BuildToolsVersion $BuildToolsVersion `
    -Java $Java `
    -Javac $Javac `
    -Jar $Jar
$decodedIdempotencyFreeze = Assert-PatchletInputFreeze `
    -Snapshot $decodedInputFreeze -Stage 'decoded-input-after-idempotency'
$decodedIdempotencyLock = Assert-PatchletInputFreezeLock `
    -Lock $decodedInputLock `
    -Stage 'decoded-input-after-idempotency'
if ([string]$idempotency.beforeSha256 -ne [string]$decodedInputFreeze[0].sha256 `
        -or [string]$idempotency.afterSha256 -ne [string]$decodedInputFreeze[0].sha256 `
        -or [int]$idempotency.decodedFiles -ne [int]$decodedInputFreeze[0].files `
        -or [int]$idempotency.decodedDirectories -ne [int]$decodedInputFreeze[0].directories `
        -or [int]$idempotency.decodedEntries -ne [int]$decodedInputFreeze[0].entries) {
    throw 'Complete decoded-tree freeze does not bind the idempotency v2 proof.'
}
$decodedInputChecks += [pscustomobject]@{
    stage = 'after-idempotency'
    freeze = $decodedIdempotencyFreeze
    lock = $decodedIdempotencyLock
}

$currentStage = 'build-working-copy'
$buildWorkingRoot = Assert-PatchletPathUnderRoot `
    -Path (Join-Path $runRootFull 'build-working-decoded') -Root $runRootFull
$buildWorkingCopy = Copy-PatchletCompleteTree `
    -SourceRoot $decodedRoot -DestinationRoot $buildWorkingRoot
$buildWorkingBuildCache = Assert-PatchletPathUnderRoot `
    -Path (Join-Path $buildWorkingRoot 'build') -Root $buildWorkingRoot
$buildWorkingManifest = Assert-PatchletPathUnderRoot `
    -Path (Join-Path $buildWorkingRoot 'AndroidManifest.xml') -Root $buildWorkingRoot
$buildWorkingManifestOriginal = Assert-PatchletPathUnderRoot `
    -Path (Join-Path $buildWorkingRoot 'AndroidManifest.xml.orig') -Root $buildWorkingRoot
if (-not (Test-Path -LiteralPath $buildWorkingManifest -PathType Leaf) `
        -or (Test-Path -LiteralPath $buildWorkingManifestOriginal) `
        -or (Test-Path -LiteralPath $buildWorkingBuildCache)) {
    throw 'Build-working copy must begin with one manifest and no manifest backup or build cache.'
}
$buildWorkingInputFreeze = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{
            id = 'build-working-decoded-input'
            kind = 'complete-tree'
            path = $buildWorkingRoot
            filter = $null
        }
    ))
foreach ($field in @('sha256', 'files', 'directories', 'entries')) {
    $idempotencyField = switch ($field) {
        'sha256' { 'afterSha256' }
        'files' { 'decodedFiles' }
        'directories' { 'decodedDirectories' }
        'entries' { 'decodedEntries' }
    }
    if ([string]$buildWorkingInputFreeze[0].$field -ne [string]$decodedInputFreeze[0].$field `
            -or [string]$buildWorkingInputFreeze[0].$field -ne [string]$idempotency.$idempotencyField) {
        throw "Build-working complete-tree '$field' does not bind the idempotency proof."
    }
}
$buildWorkingMutationLock = Enter-PatchletInputFreezeLock `
    -Snapshot $buildWorkingInputFreeze `
    -Stage 'build-working-before-apktool' `
    -AllowedTreeMutationRoots @($buildWorkingBuildCache) `
    -AllowedFileMutationPaths @($buildWorkingManifest, $buildWorkingManifestOriginal)
$buildWorkingInitialLock = Assert-PatchletInputFreezeLock `
    -Lock $buildWorkingMutationLock `
    -Stage 'build-working-before-apktool' `
    -AllowedTreeMutationRoots @($buildWorkingBuildCache) `
    -AllowedFileMutationPaths @($buildWorkingManifest, $buildWorkingManifestOriginal)
$buildWorkingInitialFreeze = Assert-PatchletInputFreeze `
    -Snapshot $buildWorkingInputFreeze -Stage 'build-working-before-apktool'
$decodedAfterWorkingCopyLock = Assert-PatchletInputFreezeLock `
    -Lock $decodedInputLock -Stage 'decoded-input-after-working-copy'
$decodedAfterWorkingCopyFreeze = Assert-PatchletInputFreeze `
    -Snapshot $decodedInputFreeze -Stage 'decoded-input-after-working-copy'
$buildWorkingInputChecks += [pscustomobject]@{
    stage = 'before-apktool'
    copy = $buildWorkingCopy
    freeze = $buildWorkingInitialFreeze
    lock = $buildWorkingInitialLock
}
$decodedInputChecks += [pscustomobject]@{
    stage = 'after-working-copy'
    freeze = $decodedAfterWorkingCopyFreeze
    lock = $decodedAfterWorkingCopyLock
}

$artifactBaseName = [string]$resolution.target.artifactBaseName
$currentStage = 'signed-build'
$final = & (Join-Path $PSScriptRoot 'Build-PatchedApk.ps1') `
    -DecodedRoot $buildWorkingRoot `
    -OutputDirectory $finalOutput `
    -ArtifactBaseName $artifactBaseName `
    -ResolutionPath $resolutionSnapshotPath `
    -ValidationMode $ValidationMode `
    -AndroidSdk $AndroidSdk `
    -BuildToolsVersion $BuildToolsVersion `
    -Java $Java `
    -KeyStore $KeyStore `
    -KeyAlias $KeyAlias `
    -KeyStorePasswordEnvironment $KeyStorePasswordEnvironment `
    -KeyPasswordEnvironment $KeyPasswordEnvironment `
    -ExpectedDecodedTreeSha256 ([string]$buildWorkingInputFreeze[0].sha256) `
    -ExpectedDecodedFiles ([int]$buildWorkingInputFreeze[0].files) `
    -ExpectedDecodedDirectories ([int]$buildWorkingInputFreeze[0].directories) `
    -ExpectedDecodedEntries ([int]$buildWorkingInputFreeze[0].entries)
foreach ($field in @('sha256', 'files', 'directories', 'entries')) {
    if ([string]$final.decodedInput.$field -ne [string]$buildWorkingInputFreeze[0].$field) {
        throw "Build result does not bind the frozen build-working '$field'."
    }
}
if ($final.signed -ne $true `
        -or [string]$final.validationMode -cne $ValidationMode `
        -or $final.releaseEligible -ne (-not $isSignedReview)) {
    throw 'Signed build result does not match the bound validation mode.'
}
$finalArtifactFull = Assert-PatchletPathUnderRoot `
    -Path ([IO.Path]::GetFullPath([string]$final.artifact)) -Root $finalOutput
$final.artifact = $finalArtifactFull
$candidateInputFreeze = @(New-PatchletInputFreeze -Inputs @(
        [pscustomobject]@{
            id = 'signed-candidate-apk'
            kind = 'file'
            path = $finalArtifactFull
            filter = $null
        }
    ))
if ([string]$candidateInputFreeze[0].sha256 -ne [string]$final.sha256) {
    throw 'Signed candidate changed between build completion and candidate freeze.'
}
$candidateInputLock = Enter-PatchletInputFreezeLock `
    -Snapshot $candidateInputFreeze -Stage 'signed-candidate-before-release-gates'
$buildWorkingMutationEvents = Assert-PatchletInputFreezeLock `
    -Lock $buildWorkingMutationLock `
    -Stage 'build-working-after-apktool' `
    -AllowedTreeMutationRoots @($buildWorkingBuildCache) `
    -AllowedFileMutationPaths @($buildWorkingManifest, $buildWorkingManifestOriginal)
$currentStage = 'build-working-restore'
if (Test-Path -LiteralPath $buildWorkingBuildCache) {
    if (-not (Test-Path -LiteralPath $buildWorkingBuildCache -PathType Container)) {
        throw "Generated build-working Apktool cache is not a directory: $buildWorkingBuildCache"
    }
    Remove-Item -LiteralPath $buildWorkingBuildCache -Recurse -Force
}
if (Test-Path -LiteralPath $buildWorkingBuildCache) {
    throw "Unable to remove the exact generated build-working Apktool cache: $buildWorkingBuildCache"
}
if (Test-Path -LiteralPath $buildWorkingManifestOriginal) {
    throw "Pinned Apktool did not remove its exact build-working manifest backup: $buildWorkingManifestOriginal"
}
$buildWorkingPostBuildFreeze = Assert-PatchletInputFreeze `
    -Snapshot $buildWorkingInputFreeze -Stage 'build-working-after-cleanup'
$buildWorkingPostBuildLock = Assert-PatchletInputFreezeLock `
    -Lock $buildWorkingMutationLock `
    -Stage 'build-working-after-cleanup' `
    -AllowedTreeMutationRoots @($buildWorkingBuildCache) `
    -AllowedFileMutationPaths @($buildWorkingManifest, $buildWorkingManifestOriginal)
$buildWorkingInputLock = Enter-PatchletInputFreezeLock `
    -Snapshot $buildWorkingInputFreeze -Stage 'build-working-sealed-after-cleanup'
$buildWorkingSealOverlapCheck = Assert-PatchletInputFreezeLock `
    -Lock $buildWorkingMutationLock `
    -Stage 'build-working-mutation-lock-during-seal' `
    -AllowedTreeMutationRoots @($buildWorkingBuildCache) `
    -AllowedFileMutationPaths @($buildWorkingManifest, $buildWorkingManifestOriginal)
Exit-PatchletInputFreezeLock -Lock $buildWorkingMutationLock
$buildWorkingMutationLock = $null
$buildWorkingSealedLock = Assert-PatchletInputFreezeLock `
    -Lock $buildWorkingInputLock -Stage 'build-working-sealed-after-cleanup'
$buildWorkingSealedFreeze = Assert-PatchletInputFreeze `
    -Snapshot $buildWorkingInputFreeze -Stage 'build-working-sealed-after-cleanup'
$decodedPostBuildFreeze = Assert-PatchletInputFreeze `
    -Snapshot $decodedInputFreeze -Stage 'decoded-input-after-working-build'
$decodedPostBuildLock = Assert-PatchletInputFreezeLock `
    -Lock $decodedInputLock `
    -Stage 'decoded-input-after-working-build'
$buildWorkingInputChecks += [pscustomobject]@{
    stage = 'after-apktool-cleanup'
    mutationEvents = $buildWorkingMutationEvents
    freeze = $buildWorkingPostBuildFreeze
    lock = $buildWorkingPostBuildLock
    sealOverlap = $buildWorkingSealOverlapCheck
    sealedFreeze = $buildWorkingSealedFreeze
    sealedLock = $buildWorkingSealedLock
}
$decodedInputChecks += [pscustomobject]@{
    stage = 'after-working-build'
    freeze = $decodedPostBuildFreeze
    lock = $decodedPostBuildLock
}
$candidateInitialFreeze = Assert-PatchletInputFreeze `
    -Snapshot $candidateInputFreeze -Stage 'signed-candidate-before-release-gates'
$candidateInitialLock = Assert-PatchletInputFreezeLock `
    -Lock $candidateInputLock -Stage 'signed-candidate-before-release-gates'
$candidateInputChecks += [pscustomobject]@{
    stage = 'before-release-gates-after-working-restore'
    buildWorkingSha256 = [string]$buildWorkingInputFreeze[0].sha256
    freeze = $candidateInitialFreeze
    lock = $candidateInitialLock
}

$currentStage = 'release-gates'
$release = & (Join-Path $PSScriptRoot 'Test-PatchedApk.ps1') `
    -Apk $final.artifact `
    -SourceApk $sourceSnapshotFull `
    -ScratchRoot (Join-Path $runRootFull 'release-validation') `
    -ResolutionPath $resolutionSnapshotPath `
    -ValidationMode $ValidationMode `
    -ReportPath $releaseReportPath `
    -AndroidSdk $AndroidSdk `
    -BuildToolsVersion $BuildToolsVersion `
    -Java $Java `
    -Javac $Javac

if ($isSignedReview) {
    $currentStage = 'signed-review-activity-ui'
    $activityUiReviewReportPath = Join-Path $runRootFull 'activity-ui-review.json'
    $activityUiReview = & (Join-Path $PSScriptRoot 'Test-ActivityUiEmulator.ps1') `
        -Apk $final.artifact `
        -ScratchRoot (Join-Path $runRootFull 'activity-ui-review') `
        -DeviceSerial $ReviewDeviceSerial `
        -KeyStore $KeyStore `
        -KeyAlias $KeyAlias `
        -ResolutionPath $resolutionSnapshotPath `
        -ValidationMode $ValidationMode `
        -KeyStorePasswordEnvironment $KeyStorePasswordEnvironment `
        -KeyPasswordEnvironment $KeyPasswordEnvironment `
        -AndroidSdk $AndroidSdk `
        -BuildToolsVersion $BuildToolsVersion `
        -Java $Java `
        -SevenZip $sevenZip `
        -ReportPath $activityUiReviewReportPath
    if ([string]$activityUiReview.status -cne 'passed' `
            -or [string]$activityUiReview.validationMode -cne 'SignedReview' `
            -or $activityUiReview.releaseEligible -ne $false `
            -or [string]$activityUiReview.candidate.sha256 -ne [string]$final.sha256) {
        throw 'SignedReview Activity UI evidence does not bind the exact signed candidate.'
    }
}

$currentStage = 'pre-report-input-freeze'
$preReportFreeze = Assert-ReleaseInputsFrozen `
    -Snapshot $releaseInputFreeze `
    -Resolution $resolution `
    -CanonicalResolutionPath $resolutionPathFull `
    -ExpectedSourceSha256 $initialSourceSha256 `
    -ExpectedResolutionSha256 $initialResolutionSha256 `
    -ExpectedResolutionStatus $expectedResolutionStatus `
    -ExpectedUpdateSignedDexReviewRequired $expectedUpdateSignedDexReviewRequired `
    -RepositoryRoot $repositoryRoot `
    -InputLock $releaseInputLock `
    -DerivedSourceLock $derivedSourceInputLock `
    -Stage 'pre-report'
$preReportGeneratedFreeze = Assert-GeneratedReleaseInputsFrozen `
    -DecodedSnapshot $decodedInputFreeze `
    -DecodedLock $decodedInputLock `
    -DecodedBuildCache $decodedBuildCache `
    -BuildWorkingSnapshot $buildWorkingInputFreeze `
    -BuildWorkingLock $buildWorkingInputLock `
    -BuildWorkingBuildCache $buildWorkingBuildCache `
    -BuildWorkingManifest $buildWorkingManifest `
    -BuildWorkingManifestOriginal $buildWorkingManifestOriginal `
    -CandidateSnapshot $candidateInputFreeze `
    -CandidateLock $candidateInputLock `
    -Stage 'pre-report'
$decodedInputChecks += $preReportGeneratedFreeze.decoded
$buildWorkingInputChecks += $preReportGeneratedFreeze.buildWorking
$candidateInputChecks += $preReportGeneratedFreeze.candidate
$outputSha256 = Get-PatchletSha256 -Path $final.artifact
if ([string]$final.sha256 -ne $outputSha256 `
        -or [string]$release.bindings.sourceApkSha256 -ne $initialSourceSha256 `
        -or [string]$release.bindings.resolutionFileSha256 -ne $initialResolutionSha256 `
        -or [string]$release.bindings.outputApkSha256 -ne $outputSha256 `
        -or [string]$release.validationMode -cne $ValidationMode `
        -or $release.releaseEligible -ne (-not $isSignedReview)) {
    throw 'Stage reports do not match the snapshotted source/resolution/output SHA-256 bindings.'
}
$currentStage = 'success-report'
$lockHoldStatus = if ($isSignedReview) {
    'held-through-signed-review-completion'
} else {
    'held-through-publication'
}
$report = [ordered]@{
    schemaVersion = 1
    completedAt = (Get-Date).ToString('o')
    status = 'passed'
    artifactProduced = $true
    validationMode = $ValidationMode
    reviewOnly = $isSignedReview
    releaseEligible = -not $isSignedReview
    runRoot = $runRootFull
    resolutionId = [string]$resolution.resolutionId
    bindings = [ordered]@{
        sourceApkSetSha256 = $initialSourceSetSha256
        sourceApkSha256 = $initialSourceSha256
        resolutionFileSha256 = $initialResolutionSha256
        outputApkSha256 = $outputSha256
    }
    input = [ordered]@{
        delivery = 'split-apk-set'
        sourceSetPath = $sourceApkSetFull
        sourceSetSnapshotPath = $sourceSetSnapshotDirectory
        sourceSetSha256 = $initialSourceSetSha256
        sourceSet = $sourceSetEvidence
        path = $sourceApkFull
        snapshotPath = $sourceSnapshotFull
        sha256 = $initialSourceSha256
    }
    resolution = [ordered]@{
        path = $resolutionPathFull
        snapshotPath = $resolutionSnapshotPath
        sha256 = $initialResolutionSha256
        directorySha256 = $initialResolutionTreeSha256
        canonicalPatchletsTreeSha256 = $initialPatchletsTreeSha256
        id = [string]$resolution.resolutionId
    }
    releaseInputSnapshot = [ordered]@{
        sourceAndResolutionCapturedAt = $inputSnapshotCapturedAt
        completeFreezeCapturedAt = $releaseInputCapturedAt
        canonicalPatchletsTreeSha256 = $initialPatchletsTreeSha256
        inputs = $releaseInputFreeze
        lock = [ordered]@{
            acquiredAt = $releaseInputLock.acquiredAt
            status = $lockHoldStatus
            fileCount = $releaseInputLock.fileCount
            treeMonitorCount = $releaseInputLock.treeMonitorCount
        }
        derivedSourceLock = [ordered]@{
            acquiredAt = $derivedSourceInputLock.acquiredAt
            status = $lockHoldStatus
            fileCount = $derivedSourceInputLock.fileCount
            treeMonitorCount = $derivedSourceInputLock.treeMonitorCount
        }
    }
    entryAttestation = [ordered]@{
        boundary = 'PowerShell parses the entry script before its first statement; this attests and locks ordinary post-start drift, not a malicious host.'
        pipeline = [ordered]@{ path = $pipelineEntryPath; sha256 = $pipelineEntrySha256 }
        module = [ordered]@{ path = $moduleEntryPath; sha256 = $moduleEntrySha256 }
    }
    generatedInputSnapshot = [ordered]@{
        baselineBuildCacheRemoved = $baselineBuildCacheRemoved
        decodedBuildCache = $decodedBuildCache
        decoded = $decodedInputFreeze
        buildWorkingCopy = $buildWorkingCopy
        buildWorking = [ordered]@{
            root = $buildWorkingRoot
            buildCache = $buildWorkingBuildCache
            manifest = $buildWorkingManifest
            manifestOriginal = $buildWorkingManifestOriginal
            snapshot = $buildWorkingInputFreeze
        }
        candidate = $candidateInputFreeze
        decodedLock = [ordered]@{
            acquiredAt = $decodedInputLock.acquiredAt
            status = $lockHoldStatus
            fileCount = $decodedInputLock.fileCount
            treeMonitorCount = $decodedInputLock.treeMonitorCount
        }
        buildWorkingLock = [ordered]@{
            acquiredAt = $buildWorkingInputLock.acquiredAt
            status = $lockHoldStatus
            fileCount = $buildWorkingInputLock.fileCount
            treeMonitorCount = $buildWorkingInputLock.treeMonitorCount
            allowedTreeMutationRoots = @($buildWorkingInputLock.allowedTreeMutationRoots)
            allowedFileMutationPaths = @($buildWorkingInputLock.allowedFileMutationPaths)
        }
        candidateLock = [ordered]@{
            acquiredAt = $candidateInputLock.acquiredAt
            status = $lockHoldStatus
            fileCount = $candidateInputLock.fileCount
            treeMonitorCount = $candidateInputLock.treeMonitorCount
        }
        checks = @($decodedInputChecks) + @($buildWorkingInputChecks) + @($candidateInputChecks)
    }
    inputFreezeChecks = @($preReportFreeze)
    splitSourceContractCheck = $splitSourceContractCheck
    universalization = $universalization
    catalogCheck = $catalogCheck
    hostAssetsCheck = $hostAssetsCheck
    resolutionCheck = $resolutionCheck
    noChangeRoundTrip = $baseline
    patchLedger = $ledger
    idempotency = $idempotency
    output = $final
    releaseCheck = $release
    activityUiReview = $activityUiReview
    published = $null
    publicationRequested = $publishFull
    runtimeValidation = if ($isSignedReview) {
        'isolated-activity-ui-probe-passed'
    } else {
        'not-run'
    }
}
Write-PatchletJson -Value $report -Path $buildReportPath

if ($publishFull) {
    if ($isSignedReview) {
        throw 'SignedReview mode cannot enter the publication transaction.'
    }
    $currentStage = 'publication-transaction'
    $publicationMoveAttempted = $true
    $publicationResult = Invoke-PatchletPublicationTransaction `
        -SourceArtifact $final.artifact `
        -PublishPath $publishFull `
        -ExpectedSha256 $outputSha256 `
        -InputSnapshot $releaseInputFreeze `
        -InputLock $releaseInputLock `
        -PreMoveValidation {
            $prePublishFreeze = Assert-ReleaseInputsFrozen `
                -Snapshot $releaseInputFreeze `
                -Resolution $resolution `
                -CanonicalResolutionPath $resolutionPathFull `
                -ExpectedSourceSha256 $initialSourceSha256 `
                -ExpectedResolutionSha256 $initialResolutionSha256 `
                -ExpectedResolutionStatus $expectedResolutionStatus `
                -ExpectedUpdateSignedDexReviewRequired $expectedUpdateSignedDexReviewRequired `
                -RepositoryRoot $repositoryRoot `
                -InputLock $releaseInputLock `
                -DerivedSourceLock $derivedSourceInputLock `
                -Stage 'pre-publish'
            $prePublishGeneratedFreeze = Assert-GeneratedReleaseInputsFrozen `
                -DecodedSnapshot $decodedInputFreeze `
                -DecodedLock $decodedInputLock `
                -DecodedBuildCache $decodedBuildCache `
                -BuildWorkingSnapshot $buildWorkingInputFreeze `
                -BuildWorkingLock $buildWorkingInputLock `
                -BuildWorkingBuildCache $buildWorkingBuildCache `
                -BuildWorkingManifest $buildWorkingManifest `
                -BuildWorkingManifestOriginal $buildWorkingManifestOriginal `
                -CandidateSnapshot $candidateInputFreeze `
                -CandidateLock $candidateInputLock `
                -Stage 'pre-publish'
            $report['inputFreezeChecks'] = @($report['inputFreezeChecks']) + @($prePublishFreeze)
            $report['generatedInputSnapshot']['checks'] = @($report['generatedInputSnapshot']['checks']) + @($prePublishGeneratedFreeze)
            Write-PatchletJson -Value $report -Path $buildReportPath
            [pscustomobject]@{ canonical = $prePublishFreeze; generated = $prePublishGeneratedFreeze }
        } `
        -PostMoveValidation {
            $postPublishFreeze = Assert-ReleaseInputsFrozen `
                -Snapshot $releaseInputFreeze `
                -Resolution $resolution `
                -CanonicalResolutionPath $resolutionPathFull `
                -ExpectedSourceSha256 $initialSourceSha256 `
                -ExpectedResolutionSha256 $initialResolutionSha256 `
                -ExpectedResolutionStatus $expectedResolutionStatus `
                -ExpectedUpdateSignedDexReviewRequired $expectedUpdateSignedDexReviewRequired `
                -RepositoryRoot $repositoryRoot `
                -InputLock $releaseInputLock `
                -DerivedSourceLock $derivedSourceInputLock `
                -Stage 'post-publish'
            $postPublishGeneratedFreeze = Assert-GeneratedReleaseInputsFrozen `
                -DecodedSnapshot $decodedInputFreeze `
                -DecodedLock $decodedInputLock `
                -DecodedBuildCache $decodedBuildCache `
                -BuildWorkingSnapshot $buildWorkingInputFreeze `
                -BuildWorkingLock $buildWorkingInputLock `
                -BuildWorkingBuildCache $buildWorkingBuildCache `
                -BuildWorkingManifest $buildWorkingManifest `
                -BuildWorkingManifestOriginal $buildWorkingManifestOriginal `
                -CandidateSnapshot $candidateInputFreeze `
                -CandidateLock $candidateInputLock `
                -Stage 'post-publish'
            $report['inputFreezeChecks'] = @($report['inputFreezeChecks']) + @($postPublishFreeze)
            $report['generatedInputSnapshot']['checks'] = @($report['generatedInputSnapshot']['checks']) + @($postPublishGeneratedFreeze)
            $report['published'] = $publishFull
            $report['publicationRequested'] = $null
            Write-PatchletJson -Value $report -Path $buildReportPath
            [pscustomobject]@{ canonical = $postPublishFreeze; generated = $postPublishGeneratedFreeze }
        }
    $publishCommitted = $true
    if ([string]$publicationResult.path -ne $publishFull `
            -or [string]$publicationResult.sha256 -ne $outputSha256) {
        throw 'Publication transaction result does not bind the exact requested target and output hash.'
    }
}

if ($null -ne $candidateInputLock) {
    Exit-PatchletInputFreezeLock -Lock $candidateInputLock
    $candidateInputLock = $null
}
if ($null -ne $buildWorkingInputLock) {
    Exit-PatchletInputFreezeLock -Lock $buildWorkingInputLock
    $buildWorkingInputLock = $null
}
if ($null -ne $decodedInputLock) {
    Exit-PatchletInputFreezeLock -Lock $decodedInputLock
    $decodedInputLock = $null
}
if ($null -ne $derivedSourceInputLock) {
    Exit-PatchletInputFreezeLock -Lock $derivedSourceInputLock
    $derivedSourceInputLock = $null
}
if ($null -ne $releaseInputLock) {
    Exit-PatchletInputFreezeLock -Lock $releaseInputLock
    $releaseInputLock = $null
}
[pscustomobject]$report
$publishCommitted = $false
} catch {
    $originalError = $_
    $postCommitWasCommitted = $publishCommitted
    $publicationResiduePaths = @()
    if ($originalError.Exception.Data.Contains('PatchletPublicationResiduePaths')) {
        $publicationResiduePaths = @(([string]$originalError.Exception.Data['PatchletPublicationResiduePaths']).Split('|') | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            })
    }
    if ($publishCommitted -and $publishFull) {
        $postCommitRollback = Remove-PatchletOwnedPublication `
            -Path $publishFull -AllowedRoot (Join-Path $repositoryRoot 'dist')
        if ([bool]$postCommitRollback.residue) {
            $publicationResiduePaths += $publishFull
        } else {
            $publishCommitted = $false
        }
    }
    $publicationResiduePaths = @($publicationResiduePaths | Sort-Object -Unique)
    $failureArtifactProduced = $publicationResiduePaths.Count -gt 0
    $publishedResidue = if ($publishFull -and $publicationResiduePaths -contains $publishFull) { $publishFull } else { $null }
    $residueOutputSha256 = if ($null -ne $publishedResidue -and (Test-Path -LiteralPath $publishedResidue -PathType Leaf)) {
        try { Get-PatchletSha256 -Path $publishedResidue } catch { $null }
    } else { $null }
    $observedSourceSha256 = if (Test-Path -LiteralPath $sourceApkFull -PathType Leaf) {
        try { Get-PatchletSha256 -Path $sourceApkFull } catch { $null }
    } else { $null }
    $observedSourceSetSha256 = if (Test-Path -LiteralPath $sourceApkSetFull -PathType Container) {
        try { Get-PatchletTreeSha256 -Root $sourceApkSetFull -Filter '*.apk' } catch { $null }
    } else { $null }
    $observedResolutionSha256 = if (Test-Path -LiteralPath $resolutionPathFull -PathType Leaf) {
        try { Get-PatchletSha256 -Path $resolutionPathFull } catch { $null }
    } else { $null }
    $observedResolutionTreeSha256 = if (Test-Path -LiteralPath $resolutionDirectoryFull -PathType Container) {
        try { Get-PatchletTreeSha256 -Root $resolutionDirectoryFull -Filter '*' } catch { $null }
    } else { $null }
    $observedPatchletsTreeSha256 = if (Test-Path -LiteralPath $canonicalPatchletsRoot -PathType Container) {
        try { Get-PatchletTreeSha256 -Root $canonicalPatchletsRoot -Filter '*' } catch { $null }
    } else { $null }
    $derivedWorkCopyEvidence = $null
    if (-not [string]::IsNullOrWhiteSpace($buildWorkingRoot) `
            -or @($buildWorkingInputFreeze).Count -gt 0 `
            -or $null -ne $buildWorkingMutationLock `
            -or $null -ne $buildWorkingInputLock) {
        try {
            $canonicalDecodedObserved = Get-PipelineCompleteTreeFailureEvidence -Path $decodedRoot
            $buildWorkingObserved = Get-PipelineCompleteTreeFailureEvidence -Path $buildWorkingRoot
            $canonicalDecodedExpected = if (@($decodedInputFreeze).Count -gt 0) {
                $decodedInputFreeze[0]
            } else { $null }
            $buildWorkingExpected = if (@($buildWorkingInputFreeze).Count -gt 0) {
                $buildWorkingInputFreeze[0]
            } else { $null }
            $canonicalDecodedFreezeMatches = if ($null -ne $canonicalDecodedExpected `
                    -and $null -ne $canonicalDecodedObserved.completeState) {
                [string]$canonicalDecodedExpected.sha256 -eq [string]$canonicalDecodedObserved.completeState.sha256 `
                    -and [int]$canonicalDecodedExpected.files -eq [int]$canonicalDecodedObserved.completeState.files `
                    -and [int]$canonicalDecodedExpected.directories -eq [int]$canonicalDecodedObserved.completeState.directories `
                    -and [int]$canonicalDecodedExpected.entries -eq [int]$canonicalDecodedObserved.completeState.entries
            } else { $null }
            $buildWorkingFreezeMatches = if ($null -ne $buildWorkingExpected `
                    -and $null -ne $buildWorkingObserved.completeState) {
                [string]$buildWorkingExpected.sha256 -eq [string]$buildWorkingObserved.completeState.sha256 `
                    -and [int]$buildWorkingExpected.files -eq [int]$buildWorkingObserved.completeState.files `
                    -and [int]$buildWorkingExpected.directories -eq [int]$buildWorkingObserved.completeState.directories `
                    -and [int]$buildWorkingExpected.entries -eq [int]$buildWorkingObserved.completeState.entries
            } else { $null }
            $workAllowedTrees = @()
            if (-not [string]::IsNullOrWhiteSpace($buildWorkingBuildCache)) {
                $workAllowedTrees = @($buildWorkingBuildCache)
            }
            $workAllowedFiles = @()
            if (-not [string]::IsNullOrWhiteSpace($buildWorkingManifest) `
                    -and -not [string]::IsNullOrWhiteSpace($buildWorkingManifestOriginal)) {
                $workAllowedFiles = @($buildWorkingManifest, $buildWorkingManifestOriginal)
            }
            $derivedWorkCopyEvidence = [ordered]@{
                copy = $buildWorkingCopy
                canonicalDecoded = [ordered]@{
                    root = $decodedRoot
                    snapshot = $decodedInputFreeze
                    observed = $canonicalDecodedObserved
                    freezeMatches = $canonicalDecodedFreezeMatches
                    lock = Get-PipelineLockFailureEvidence -Lock $decodedInputLock
                }
                root = $buildWorkingRoot
                snapshot = $buildWorkingInputFreeze
                observed = $buildWorkingObserved
                freezeMatches = $buildWorkingFreezeMatches
                mutationLock = Get-PipelineLockFailureEvidence `
                    -Lock $buildWorkingMutationLock `
                    -AllowedTreeMutationRoots $workAllowedTrees `
                    -AllowedFileMutationPaths $workAllowedFiles
                sealedLock = Get-PipelineLockFailureEvidence -Lock $buildWorkingInputLock
                manifest = Get-PipelineReadableFileFailureEvidence -Path $buildWorkingManifest
                manifestOriginal = Get-PipelineReadableFileFailureEvidence -Path $buildWorkingManifestOriginal
                buildCache = Get-PipelineCompleteTreeFailureEvidence -Path $buildWorkingBuildCache
            }
        } catch {
            $derivedWorkCopyEvidence = [ordered]@{
                root = $buildWorkingRoot
                observationError = $_.Exception.Message
            }
        }
    }
    $boundSourceSha256 = if ($null -ne $initialSourceSha256) {
        $initialSourceSha256
    } else { $observedSourceSha256 }
    $boundResolutionSha256 = if ($null -ne $initialResolutionSha256) {
        $initialResolutionSha256
    } else { $observedResolutionSha256 }
    $failureReport = [ordered]@{
        schemaVersion = 1
        completedAt = (Get-Date).ToString('o')
        status = 'failed'
        artifactProduced = $failureArtifactProduced
        runRoot = $runRootFull
        failedStage = $currentStage
        resolutionId = if ($null -ne $resolution) { [string]$resolution.resolutionId } else { $null }
        bindings = [ordered]@{
            sourceApkSetSha256 = $initialSourceSetSha256
            sourceApkSha256 = $boundSourceSha256
            resolutionFileSha256 = $boundResolutionSha256
            outputApkSha256 = $residueOutputSha256
        }
        input = [ordered]@{
            delivery = 'split-apk-set'
            sourceSetPath = $sourceApkSetFull
            sourceSetSnapshotPath = if (Test-Path -LiteralPath $sourceSetSnapshotDirectory -PathType Container) { $sourceSetSnapshotDirectory } else { $null }
            sourceSetSha256 = $initialSourceSetSha256
            path = $sourceApkFull
            snapshotPath = if (Test-Path -LiteralPath $sourceSnapshotFull -PathType Leaf) { $sourceSnapshotFull } else { $null }
            sha256 = $boundSourceSha256
        }
        resolution = [ordered]@{
            path = $resolutionPathFull
            snapshotPath = if (Test-Path -LiteralPath $resolutionSnapshotPath -PathType Leaf) { $resolutionSnapshotPath } else { $null }
            sha256 = $boundResolutionSha256
            directorySha256 = $initialResolutionTreeSha256
            canonicalPatchletsTreeSha256 = $initialPatchletsTreeSha256
            id = if ($null -ne $resolution) { [string]$resolution.resolutionId } else { $null }
        }
        releaseInputSnapshot = if (@($releaseInputFreeze).Count -gt 0) {
            [ordered]@{
                sourceAndResolutionCapturedAt = $inputSnapshotCapturedAt
                completeFreezeCapturedAt = $releaseInputCapturedAt
                canonicalPatchletsTreeSha256 = $initialPatchletsTreeSha256
                inputs = $releaseInputFreeze
                lock = if ($null -ne $releaseInputLock) {
                    [ordered]@{
                        acquiredAt = $releaseInputLock.acquiredAt
                        status = [string]$releaseInputLock.status
                        fileCount = $releaseInputLock.fileCount
                        treeMonitorCount = $releaseInputLock.treeMonitorCount
                    }
                } else { $null }
                derivedSourceLock = if ($null -ne $derivedSourceInputLock) {
                    [ordered]@{
                        acquiredAt = $derivedSourceInputLock.acquiredAt
                        status = [string]$derivedSourceInputLock.status
                        fileCount = $derivedSourceInputLock.fileCount
                        treeMonitorCount = $derivedSourceInputLock.treeMonitorCount
                    }
                } else { $null }
            }
        } else { $null }
        derivedWorkCopy = $derivedWorkCopyEvidence
        splitSourceContractCheck = $splitSourceContractCheck
        universalization = $universalization
        observedAtFailure = [ordered]@{
            sourceApkSetSha256 = $observedSourceSetSha256
            sourceApkSha256 = $observedSourceSha256
            resolutionFileSha256 = $observedResolutionSha256
            resolutionDirectorySha256 = $observedResolutionTreeSha256
            canonicalPatchletsTreeSha256 = $observedPatchletsTreeSha256
            sourceSetDrifted = ($null -ne $initialSourceSetSha256 -and $observedSourceSetSha256 -ne $initialSourceSetSha256)
            sourceDrifted = ($null -ne $initialSourceSha256 -and $observedSourceSha256 -ne $initialSourceSha256)
            resolutionFileDrifted = ($null -ne $initialResolutionSha256 -and $observedResolutionSha256 -ne $initialResolutionSha256)
            resolutionDirectoryDrifted = ($null -ne $initialResolutionTreeSha256 -and $observedResolutionTreeSha256 -ne $initialResolutionTreeSha256)
            canonicalPatchletsTreeDrifted = ($null -ne $initialPatchletsTreeSha256 -and $observedPatchletsTreeSha256 -ne $initialPatchletsTreeSha256)
        }
        output = if ($failureArtifactProduced) {
            [ordered]@{ residuePaths = $publicationResiduePaths; sha256 = $residueOutputSha256 }
        } else { $null }
        published = $publishedResidue
        publicationRequested = $null
        publicationState = [ordered]@{
            moveAttempted = $publicationMoveAttempted
            committedBeforeFailure = $postCommitWasCommitted
            postCommitRollback = $postCommitRollback
        }
        failure = [ordered]@{
            type = $originalError.Exception.GetType().FullName
            message = $originalError.Exception.Message
            publicationRollbackVerified = -not $failureArtifactProduced
        }
        runtimeValidation = 'not-run'
    }
    try {
        Write-PatchletJson -Value $failureReport -Path $buildReportPath
    } catch {
        Write-Warning "Unable to write pipeline failure report: $($_.Exception.Message)"
    }
    if ($null -ne $candidateInputLock) {
        try { Exit-PatchletInputFreezeLock -Lock $candidateInputLock } catch { }
        $candidateInputLock = $null
    }
    if ($null -ne $buildWorkingInputLock) {
        try { Exit-PatchletInputFreezeLock -Lock $buildWorkingInputLock } catch { }
        $buildWorkingInputLock = $null
    }
    if ($null -ne $buildWorkingMutationLock) {
        try { Exit-PatchletInputFreezeLock -Lock $buildWorkingMutationLock } catch { }
        $buildWorkingMutationLock = $null
    }
    if ($null -ne $decodedInputLock) {
        try { Exit-PatchletInputFreezeLock -Lock $decodedInputLock } catch { }
        $decodedInputLock = $null
    }
    if ($null -ne $derivedSourceInputLock) {
        try { Exit-PatchletInputFreezeLock -Lock $derivedSourceInputLock } catch { }
        $derivedSourceInputLock = $null
    }
    if ($null -ne $releaseInputLock) {
        try { Exit-PatchletInputFreezeLock -Lock $releaseInputLock } catch { }
        $releaseInputLock = $null
    }
    foreach ($handle in @($bootstrapEntryHandles)) {
        try { $handle.Dispose() } catch { }
    }
    $bootstrapEntryHandles = @()
    throw $originalError
}
