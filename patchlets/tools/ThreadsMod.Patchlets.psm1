Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PatchletRepositoryRoot {
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}

function Get-PatchletSha256 {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file does not exist: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PatchletTreeSha256 {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Filter
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { throw "Tree root does not exist: $rootFull" }
    $lines = foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Filter $Filter | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
        "$relative`t$(Get-PatchletSha256 -Path $file.FullName)`n"
    }
    if (@($lines).Count -eq 0) { throw "Tree hash matched no files below '$rootFull' with filter '$Filter'." }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join ''))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-PatchletSplitSourceSet {
    param(
        [Parameter(Mandatory)]$Resolution,
        [Parameter(Mandatory)][string]$SourceApkSet
    )

    $sourceRoot = [IO.Path]::GetFullPath($SourceApkSet).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Split source-set directory does not exist: $sourceRoot"
    }
    if ([string]$Resolution.source.delivery -ne 'split-apk-set') {
        throw "Resolution source.delivery must be 'split-apk-set'."
    }

    $members = @($Resolution.source.splitMembers)
    if ($members.Count -ne 3) {
        throw "Split source set must declare exactly three APK members; observed $($members.Count)."
    }
    $requiredRoles = @('base', 'abi', 'density')
    $declaredNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $memberEvidence = @()
    for ($index = 0; $index -lt $members.Count; $index++) {
        $member = $members[$index]
        $role = [string]$member.role
        if ($role -ne $requiredRoles[$index]) {
            throw "Split source member index $index must have role '$($requiredRoles[$index])'; observed '$role'."
        }
        $fileName = [string]$member.fileName
        if ([string]::IsNullOrWhiteSpace($fileName) `
                -or $fileName -ne [IO.Path]::GetFileName($fileName) `
                -or -not $fileName.EndsWith('.apk', [StringComparison]::Ordinal) `
                -or -not $declaredNames.Add($fileName)) {
            throw "Split source member has an unsafe or duplicate APK fileName: '$fileName'."
        }
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Force -Recurse)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Split source set contains an unsupported reparse point: '$($item.FullName)'."
        }
    }
    $actualApks = @(Get-ChildItem -LiteralPath $sourceRoot -Force -Recurse -File -Filter '*.apk')
    $actualNames = @($actualApks | ForEach-Object {
        $_.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
    } | Sort-Object -CaseSensitive)
    $expectedNames = @($members | ForEach-Object { [string]$_.fileName } | Sort-Object -CaseSensitive)
    if ($actualNames.Count -ne $expectedNames.Count `
            -or [string]::Join("`n", $actualNames) -cne [string]::Join("`n", $expectedNames)) {
        throw "Split source APK inventory differs from the exact resolution. Expected '$($expectedNames -join ', ')'; observed '$($actualNames -join ', ')'."
    }

    foreach ($member in $members) {
        $path = Join-Path $sourceRoot ([string]$member.fileName)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required split source member is missing: $($member.fileName)"
        }
        $item = Get-Item -LiteralPath $path -Force
        $expectedSize = [long]$member.size
        if ([long]$item.Length -ne $expectedSize) {
            throw "Split source member size mismatch for '$($member.fileName)'. Expected '$expectedSize', observed '$($item.Length)'."
        }
        $expectedSha256 = ([string]$member.sha256).ToLowerInvariant()
        $observedSha256 = Get-PatchletSha256 -Path $path
        if ($observedSha256 -ne $expectedSha256) {
            throw "Split source member hash mismatch for '$($member.fileName)'."
        }
        $memberEvidence += [pscustomobject]@{
            role = [string]$member.role
            fileName = [string]$member.fileName
            size = [long]$item.Length
            sha256 = $observedSha256
        }
    }

    $setSha256 = Get-PatchletTreeSha256 -Root $sourceRoot -Filter '*.apk'
    $expectedSetSha256 = ([string]$Resolution.source.splitSetSha256).ToLowerInvariant()
    if ($setSha256 -ne $expectedSetSha256) {
        throw 'Split source-set aggregate hash differs from the exact resolution.'
    }
    return [pscustomobject]@{
        status = 'matched'
        path = $sourceRoot
        sha256 = $setSha256
        memberCount = $members.Count
        members = @($memberEvidence)
    }
}

function Test-PatchletApkEditorContract {
    param(
        [Parameter(Mandatory)]$Resolution,
        [Parameter(Mandatory)][string]$ApkEditorJar
    )

    $expectedArguments = @(
        'm', '-i', '{sourceSet}', '-o', '{outputApk}',
        '-clean-meta', '-validate-modules', '-extractNativeLibs', 'false'
    )
    $declaredArguments = @($Resolution.toolchain.apkEditorMergeArguments | ForEach-Object { [string]$_ })
    if ([string]$Resolution.toolchain.apkEditorVersion -ne '1.4.9' `
            -or [string]$Resolution.toolchain.apkEditorArscLibVersion -ne '1.3.9' `
            -or [string]::Join("`n", $declaredArguments) -cne [string]::Join("`n", $expectedArguments)) {
        throw 'APKEditor version, ARSCLib version, or exact ordered merge arguments differ from patchlet 005.'
    }
    $jarSha256 = Get-PatchletSha256 -Path ([IO.Path]::GetFullPath($ApkEditorJar))
    if ($jarSha256 -ne ([string]$Resolution.toolchain.apkEditorJarSha256).ToLowerInvariant()) {
        throw 'APKEditor JAR hash differs from the exact resolution.'
    }
    return [pscustomobject]@{
        status = 'matched'
        apkEditorVersion = '1.4.9'
        arscLibVersion = '1.3.9'
        jarSha256 = $jarSha256
        orderedArguments = $expectedArguments
    }
}

function Get-PatchletCompleteTreeState {
    param([Parameter(Mandatory)][string]$Root)

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
        throw "Complete tree root does not exist: $rootFull"
    }

    $records = [Collections.Generic.List[string]]::new()
    $fileCount = 0
    $directoryCount = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $rootFull -Force -Recurse)) {
        $relative = $item.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Complete tree contains an unsupported reparse point: '$relative'."
        }
        if ($item.PSIsContainer) {
            $directoryCount++
            $records.Add("D:$($relative.Length):$relative`n")
            continue
        }
        if (-not (Test-Path -LiteralPath $item.FullName -PathType Leaf)) {
            throw "Complete tree contains an unsupported inventory entry: '$relative'."
        }
        $fileCount++
        $records.Add("F:$($relative.Length):${relative}:$($item.Length):$(Get-PatchletSha256 -Path $item.FullName)`n")
    }
    if ($fileCount -eq 0) { throw "Complete tree contains no files: $rootFull" }

    $orderedRecords = $records.ToArray()
    [Array]::Sort($orderedRecords, [StringComparer]::Ordinal)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($orderedRecords -join ''))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [pscustomobject]@{
            sha256 = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
            files = $fileCount
            directories = $directoryCount
            entries = $fileCount + $directoryCount
            records = @($orderedRecords)
        }
    }
    finally { $sha.Dispose() }
}

function Copy-PatchletCompleteTree {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $sourceFull = [IO.Path]::GetFullPath($SourceRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $destinationFull = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Container)) {
        throw "Complete-tree copy source does not exist: $sourceFull"
    }
    if (Test-Path -LiteralPath $destinationFull) {
        throw "Complete-tree copy destination must be absent: $destinationFull"
    }
    $sourcePrefix = $sourceFull + [IO.Path]::DirectorySeparatorChar
    $destinationPrefix = $destinationFull + [IO.Path]::DirectorySeparatorChar
    if ($sourceFull.Equals($destinationFull, [StringComparison]::OrdinalIgnoreCase) `
            -or $destinationFull.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase) `
            -or $sourceFull.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Complete-tree copy source and destination must be disjoint.'
    }

    $sourceBefore = Get-PatchletCompleteTreeState -Root $sourceFull
    [IO.Directory]::CreateDirectory($destinationFull) | Out-Null
    foreach ($directory in @(Get-ChildItem -LiteralPath $sourceFull -Force -Recurse -Directory |
            Sort-Object { $_.FullName.Length }, FullName)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Complete-tree copy encountered a directory reparse point: $($directory.FullName)"
        }
        $relative = $directory.FullName.Substring($sourceFull.Length + 1)
        [IO.Directory]::CreateDirectory((Join-Path $destinationFull $relative)) | Out-Null
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceFull -Force -Recurse -File | Sort-Object FullName)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Complete-tree copy encountered a file reparse point: $($file.FullName)"
        }
        $relative = $file.FullName.Substring($sourceFull.Length + 1)
        [IO.File]::Copy($file.FullName, (Join-Path $destinationFull $relative), $false)
    }

    $sourceAfter = Get-PatchletCompleteTreeState -Root $sourceFull
    $destinationState = Get-PatchletCompleteTreeState -Root $destinationFull
    foreach ($field in @('sha256', 'files', 'directories', 'entries')) {
        if ([string]$sourceBefore.$field -ne [string]$sourceAfter.$field `
                -or [string]$sourceBefore.$field -ne [string]$destinationState.$field) {
            throw "Complete-tree copy did not preserve '$field'."
        }
    }
    return [pscustomobject]@{
        status = 'content-identical'
        source = $sourceFull
        destination = $destinationFull
        sha256 = [string]$destinationState.sha256
        files = [int]$destinationState.files
        directories = [int]$destinationState.directories
        entries = [int]$destinationState.entries
    }
}

function Test-PatchletZipInventory {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($fullPath)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $files = 0
        $directories = 0
        foreach ($entry in @($archive.Entries)) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrEmpty($name) -or -not $seen.Add($name)) {
                throw "ZIP inventory contains an empty or duplicate entry FullName '$name' in '$fullPath'."
            }
            if ($name.Contains('\', [StringComparison]::Ordinal) `
                    -or $name.StartsWith('/', [StringComparison]::Ordinal) `
                    -or $name.Contains(':', [StringComparison]::Ordinal) `
                    -or $name.Contains('//', [StringComparison]::Ordinal)) {
                throw "ZIP inventory contains a non-canonical entry path '$name' in '$fullPath'."
            }
            $pathPart = $name.TrimEnd('/')
            if ([string]::IsNullOrEmpty($pathPart) `
                    -or @($pathPart.Split('/') | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
                throw "ZIP inventory contains a traversal or empty canonical path '$name' in '$fullPath'."
            }
            if ([string]::IsNullOrEmpty([string]$entry.Name)) { $directories++ } else { $files++ }
        }
        if ($files -eq 0) { throw "ZIP inventory contains no files: $fullPath" }
        return [pscustomobject]@{
            status = 'unique-canonical'
            path = $fullPath
            entries = $seen.Count
            files = $files
            directories = $directories
        }
    }
    finally { $archive.Dispose() }
}

function New-PatchletInputFreeze {
    param([Parameter(Mandatory)][object[]]$Inputs)

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $items = @()
    foreach ($input in @($Inputs)) {
        $id = [string]$input.id
        $kind = [string]$input.kind
        $path = [IO.Path]::GetFullPath([string]$input.path)
        $filterProperty = $input.PSObject.Properties['filter']
        $filter = if ($null -ne $filterProperty -and $null -ne $filterProperty.Value) {
            [string]$filterProperty.Value
        } else { $null }
        if ([string]::IsNullOrWhiteSpace($id) -or -not $ids.Add($id)) {
            throw "Release-input freeze IDs must be non-empty and unique: '$id'"
        }
        $completeTreeState = $null
        $sha256 = if ($kind -eq 'file') {
            Get-PatchletSha256 -Path $path
        } elseif ($kind -eq 'tree') {
            if ([string]::IsNullOrWhiteSpace($filter)) {
                throw "Tree release-input freeze requires a filter: $id"
            }
            Get-PatchletTreeSha256 -Root $path -Filter $filter
        } elseif ($kind -eq 'complete-tree') {
            $completeTreeState = Get-PatchletCompleteTreeState -Root $path
            [string]$completeTreeState.sha256
        } else {
            throw "Unsupported release-input freeze kind '$kind' for '$id'."
        }
        $items += [pscustomobject]@{
            id = $id
            kind = $kind
            path = $path
            filter = $filter
            sha256 = $sha256
            files = if ($null -ne $completeTreeState) { [int]$completeTreeState.files } else { $null }
            directories = if ($null -ne $completeTreeState) { [int]$completeTreeState.directories } else { $null }
            entries = if ($null -ne $completeTreeState) { [int]$completeTreeState.entries } else { $null }
        }
    }
    return @($items)
}

function Assert-PatchletInputFreeze {
    param(
        [Parameter(Mandatory)][object[]]$Snapshot,
        [Parameter(Mandatory)][string]$Stage
    )

    $checked = @()
    foreach ($item in @($Snapshot)) {
        $completeTreeState = $null
        $actual = if ([string]$item.kind -eq 'file') {
            Get-PatchletSha256 -Path ([string]$item.path)
        } elseif ([string]$item.kind -eq 'tree') {
            Get-PatchletTreeSha256 -Root ([string]$item.path) -Filter ([string]$item.filter)
        } elseif ([string]$item.kind -eq 'complete-tree') {
            $completeTreeState = Get-PatchletCompleteTreeState -Root ([string]$item.path)
            [string]$completeTreeState.sha256
        } else {
            throw "Unsupported frozen release-input kind '$($item.kind)' for '$($item.id)'."
        }
        if ($actual -ne [string]$item.sha256) {
            throw "Release input drift at '$Stage' for '$($item.id)'. Expected '$($item.sha256)', observed '$actual'."
        }
        if ($null -ne $completeTreeState `
                -and ([int]$completeTreeState.files -ne [int]$item.files `
                    -or [int]$completeTreeState.directories -ne [int]$item.directories `
                    -or [int]$completeTreeState.entries -ne [int]$item.entries)) {
            throw "Complete release-input inventory drift at '$Stage' for '$($item.id)'."
        }
        $checked += [pscustomobject]@{
            id = [string]$item.id
            sha256 = $actual
            files = if ($null -ne $completeTreeState) { [int]$completeTreeState.files } else { $null }
            directories = if ($null -ne $completeTreeState) { [int]$completeTreeState.directories } else { $null }
            entries = if ($null -ne $completeTreeState) { [int]$completeTreeState.entries } else { $null }
        }
    }
    return [pscustomobject]@{
        stage = $Stage
        checkedAt = (Get-Date).ToString('o')
        status = 'matched'
        inputs = $checked
    }
}

function Enter-PatchletInputFreezeLock {
    param(
        [Parameter(Mandatory)][object[]]$Snapshot,
        [Parameter(Mandatory)][string]$Stage,
        [string[]]$AllowedTreeMutationRoots = @(),
        [string[]]$AllowedFileMutationPaths = @()
    )

    $null = Assert-PatchletInputFreeze -Snapshot $Snapshot -Stage "$Stage-before-lock"
    if ($null -eq ('ThreadsModPatchletTreeMonitorV2' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;

public sealed class ThreadsModPatchletTreeMonitorV2 : IDisposable {
    private readonly ConcurrentQueue<string> events = new ConcurrentQueue<string>();
    private readonly FileSystemWatcher watcher;

    public ThreadsModPatchletTreeMonitorV2(
            string path, bool includeSubdirectories, bool includeContentChanges) {
        watcher = new FileSystemWatcher(path, "*");
        watcher.IncludeSubdirectories = includeSubdirectories;
        watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName;
        if (includeContentChanges) {
            watcher.NotifyFilter |= NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime;
            watcher.Changed += (sender, args) => {
                if (!Directory.Exists(args.FullPath)) {
                    events.Enqueue("changed:" + args.FullPath);
                }
            };
        }
        watcher.Created += (sender, args) => events.Enqueue("created:" + args.FullPath);
        watcher.Deleted += (sender, args) => events.Enqueue("deleted:" + args.FullPath);
        watcher.Renamed += (sender, args) => events.Enqueue("renamed:" + args.OldFullPath + "->" + args.FullPath);
        watcher.Error += (sender, args) => events.Enqueue("monitor-error:" + args.GetException().Message);
        watcher.EnableRaisingEvents = true;
    }

    public int EventCount { get { return events.Count; } }
    public string[] SnapshotEvents() { return events.ToArray(); }
    public void InjectErrorForContractTest(string message) {
        events.Enqueue("monitor-error:" + message);
    }
    public void Dispose() { watcher.Dispose(); }
}
'@
    }

    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $treeRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Snapshot)) {
        if ([string]$item.kind -eq 'file') {
            $null = $paths.Add([IO.Path]::GetFullPath([string]$item.path))
        } elseif ([string]$item.kind -eq 'tree' -or [string]$item.kind -eq 'complete-tree') {
            $treeRoot = [IO.Path]::GetFullPath([string]$item.path)
            $null = $treeRoots.Add($treeRoot)
            $treeFiles = if ([string]$item.kind -eq 'complete-tree') {
                @(Get-ChildItem -LiteralPath $treeRoot -Force -Recurse -File)
            } else {
                @(Get-ChildItem -LiteralPath $treeRoot -Recurse -File -Filter ([string]$item.filter))
            }
            foreach ($file in $treeFiles) {
                $null = $paths.Add($file.FullName)
            }
        } else {
            throw "Unsupported frozen release-input kind '$($item.kind)' for '$($item.id)'."
        }
    }

    $handles = [Collections.Generic.List[IO.FileStream]]::new()
    $monitors = [Collections.Generic.List[ThreadsModPatchletTreeMonitorV2]]::new()
    try {
        $monitorRoots = [Collections.Generic.List[string]]::new()
        foreach ($candidate in @($treeRoots | Sort-Object { $_.Length }, { $_ })) {
            $nested = $false
            foreach ($existing in @($monitorRoots)) {
                $prefix = $existing.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                if ($candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $nested = $true
                    break
                }
            }
            if (-not $nested) { $monitorRoots.Add($candidate) }
        }
        $allowedMutationRoots = @($AllowedTreeMutationRoots | ForEach-Object {
                [IO.Path]::GetFullPath([string]$_).TrimEnd(
                    [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            } | Sort-Object -Unique)
        $allowedMutationFiles = @($AllowedFileMutationPaths | ForEach-Object {
                [IO.Path]::GetFullPath([string]$_)
            } | Sort-Object -Unique)
        $monitorSpecs = [Collections.Generic.List[object]]::new()
        $monitorSpecKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($allowedRoot in $allowedMutationRoots) {
            if (Test-Path -LiteralPath $allowedRoot) {
                throw "Allowed generated mutation root must be absent when the input lock is acquired: $allowedRoot"
            }
            $parent = Split-Path -Parent $allowedRoot
            if (@($monitorRoots | Where-Object {
                        $parent.Equals([string]$_, [StringComparison]::OrdinalIgnoreCase)
                    }).Count -ne 1) {
                throw "Allowed generated mutation root must be a direct child of exactly one frozen tree: $allowedRoot"
            }
        }
        foreach ($allowedFile in $allowedMutationFiles) {
            if (Test-Path -LiteralPath $allowedFile -PathType Container) {
                throw "Allowed generated mutation file is a directory: $allowedFile"
            }
            $covered = @($treeRoots | Where-Object {
                    $prefix = ([string]$_).TrimEnd(
                        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) `
                        + [IO.Path]::DirectorySeparatorChar
                    $allowedFile.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0
            if (-not $covered) {
                throw "Allowed generated mutation file is outside every frozen tree: $allowedFile"
            }
            foreach ($allowedRoot in $allowedMutationRoots) {
                $prefix = $allowedRoot + [IO.Path]::DirectorySeparatorChar
                if ($allowedFile.Equals($allowedRoot, [StringComparison]::OrdinalIgnoreCase) `
                        -or $allowedFile.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Allowed generated mutation file is redundantly covered by a mutation root: $allowedFile"
                }
            }
            $null = $paths.Remove($allowedFile)
        }
        foreach ($monitorRoot in @($monitorRoots)) {
            $directAllowed = @($allowedMutationRoots | Where-Object {
                    (Split-Path -Parent $_).Equals($monitorRoot, [StringComparison]::OrdinalIgnoreCase)
                })
            if ($directAllowed.Count -eq 0) {
                $key = "$monitorRoot|recursive"
                if ($monitorSpecKeys.Add($key)) {
                    $monitorSpecs.Add([pscustomobject]@{ path = $monitorRoot; recursive = $true })
                }
                continue
            }
            $rootKey = "$monitorRoot|root-only"
            if ($monitorSpecKeys.Add($rootKey)) {
                $monitorSpecs.Add([pscustomobject]@{ path = $monitorRoot; recursive = $false })
            }
            foreach ($child in @(Get-ChildItem -LiteralPath $monitorRoot -Force -Directory)) {
                if ($directAllowed -contains $child.FullName) { continue }
                $childKey = "$($child.FullName)|recursive"
                if ($monitorSpecKeys.Add($childKey)) {
                    $monitorSpecs.Add([pscustomobject]@{ path = $child.FullName; recursive = $true })
                }
            }
        }
        foreach ($monitorSpec in @($monitorSpecs)) {
            $monitorPath = [string]$monitorSpec.path
            $monitorPrefix = $monitorPath.TrimEnd(
                [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) `
                + [IO.Path]::DirectorySeparatorChar
            $contentChanges = @($allowedMutationFiles | Where-Object {
                    if ([bool]$monitorSpec.recursive) {
                        $_.StartsWith($monitorPrefix, [StringComparison]::OrdinalIgnoreCase)
                    } else {
                        (Split-Path -Parent $_).Equals($monitorPath, [StringComparison]::OrdinalIgnoreCase)
                    }
                }).Count -gt 0
            $monitors.Add([ThreadsModPatchletTreeMonitorV2]::new(
                    $monitorPath, [bool]$monitorSpec.recursive, $contentChanges))
        }
        foreach ($path in @($paths | Sort-Object)) {
            $handles.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
        }
        $null = Assert-PatchletInputFreeze -Snapshot $Snapshot -Stage "$Stage-after-lock"
    } catch {
        foreach ($handle in @($handles)) { $handle.Dispose() }
        foreach ($monitor in @($monitors)) { $monitor.Dispose() }
        throw
    }
    return [pscustomobject]@{
        acquiredAt = (Get-Date).ToString('o')
        stage = $Stage
        status = 'held'
        fileCount = $handles.Count
        treeMonitorCount = $monitors.Count
        handles = @($handles)
        monitors = @($monitors)
        treeRoots = @($monitorRoots)
        allowedTreeMutationRoots = $allowedMutationRoots
        allowedFileMutationPaths = $allowedMutationFiles
    }
}

function Assert-PatchletInputFreezeLock {
    param(
        [Parameter(Mandatory)]$Lock,
        [Parameter(Mandatory)][string]$Stage,
        [string[]]$AllowedTreeMutationRoots = @(),
        [string[]]$AllowedFileMutationPaths = @()
    )

    if ([string]$Lock.status -ne 'held') {
        throw "Release-input lock is not held at '$Stage'."
    }
    $allowedRoots = @($AllowedTreeMutationRoots | ForEach-Object {
            [IO.Path]::GetFullPath([string]$_).TrimEnd(
                [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        } | Sort-Object -Unique)
    $configuredAllowedRoots = @($Lock.allowedTreeMutationRoots | Sort-Object -Unique)
    if (($allowedRoots -join "`n") -ne ($configuredAllowedRoots -join "`n")) {
        throw "Allowed tree mutation roots differ from the lock-time configuration at '$Stage'."
    }
    $allowedFiles = @($AllowedFileMutationPaths | ForEach-Object {
            [IO.Path]::GetFullPath([string]$_)
        } | Sort-Object -Unique)
    $configuredAllowedFiles = @($Lock.allowedFileMutationPaths | Sort-Object -Unique)
    if (($allowedFiles -join "`n") -ne ($configuredAllowedFiles -join "`n")) {
        throw "Allowed file mutation paths differ from the lock-time configuration at '$Stage'."
    }
    foreach ($allowedRoot in $allowedRoots) {
        $covered = @($Lock.treeRoots | Where-Object {
                $treeRoot = [string]$_
                $prefix = $treeRoot.TrimEnd(
                    [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) `
                    + [IO.Path]::DirectorySeparatorChar
                $allowedRoot.Equals($treeRoot, [StringComparison]::OrdinalIgnoreCase) `
                    -or $allowedRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
        if (-not $covered) {
            throw "Allowed tree mutation root is outside every frozen tree at '$Stage': $allowedRoot"
        }
    }

    $isAllowedPath = {
        param([string]$Candidate)
        $candidateFull = [IO.Path]::GetFullPath($Candidate)
        foreach ($allowedRoot in $allowedRoots) {
            $prefix = $allowedRoot + [IO.Path]::DirectorySeparatorChar
            if ($candidateFull.Equals($allowedRoot, [StringComparison]::OrdinalIgnoreCase) `
                    -or $candidateFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        foreach ($allowedFile in $allowedFiles) {
            if ($candidateFull.Equals($allowedFile, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    }
    $isAllowedEvent = {
        param([string]$EventText)
        if ($EventText.StartsWith('renamed:', [StringComparison]::Ordinal)) {
            $payload = $EventText.Substring('renamed:'.Length)
            $separator = $payload.IndexOf('->', [StringComparison]::Ordinal)
            if ($separator -lt 0) { return $false }
            return (& $isAllowedPath $payload.Substring(0, $separator)) `
                -and (& $isAllowedPath $payload.Substring($separator + 2))
        }
        foreach ($prefix in @('changed:', 'created:', 'deleted:')) {
            if ($EventText.StartsWith($prefix, [StringComparison]::Ordinal)) {
                return & $isAllowedPath $EventText.Substring($prefix.Length)
            }
        }
        return $false
    }

    $events = @($Lock.monitors | ForEach-Object { @($_.SnapshotEvents()) })
    $unexpectedEvents = @($events | Where-Object { -not (& $isAllowedEvent ([string]$_)) })
    if ($unexpectedEvents.Count -gt 0) {
        $sample = @($unexpectedEvents | Select-Object -First 5) -join '; '
        throw "Release input tree drift at '$Stage'. Monitor events: $sample"
    }
    return [pscustomobject]@{
        stage = $Stage
        status = 'held'
        treeMonitorEvents = $events.Count
        allowedTreeMonitorEvents = $events.Count
        unexpectedTreeMonitorEvents = 0
        allowedTreeMutationRoots = $allowedRoots
        allowedFileMutationPaths = $allowedFiles
    }
}

function Exit-PatchletInputFreezeLock {
    param([Parameter(Mandatory)]$Lock)

    foreach ($handle in @($Lock.handles)) { $handle.Dispose() }
    foreach ($monitor in @($Lock.monitors)) { $monitor.Dispose() }
    $Lock.status = 'released'
}

function Invoke-PatchletPublicationTransaction {
    param(
        [Parameter(Mandatory)][string]$SourceArtifact,
        [Parameter(Mandatory)][string]$PublishPath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][object[]]$InputSnapshot,
        [Parameter(Mandatory)]$InputLock,
        [scriptblock]$PreMoveValidation,
        [scriptblock]$PostMoveValidation
    )

    $sourceFull = [IO.Path]::GetFullPath($SourceArtifact)
    $publishFull = [IO.Path]::GetFullPath($PublishPath)
    if (Test-Path -LiteralPath $publishFull) {
        throw "Refusing to overwrite published artifact: $publishFull"
    }
    if ((Get-PatchletSha256 -Path $sourceFull) -ne $ExpectedSha256) {
        throw 'Publication source hash differs from the gated output APK.'
    }

    $temporary = $publishFull + '.publishing-' + [guid]::NewGuid().ToString('N') + '.tmp'
    $moveCommitted = $false
    $publishedLock = $null
    try {
        Copy-Item -LiteralPath $sourceFull -Destination $temporary
        if ((Get-PatchletSha256 -Path $temporary) -ne $ExpectedSha256) {
            throw 'Temporary publication copy hash differs from the gated output APK.'
        }
        $null = Assert-PatchletInputFreeze -Snapshot $InputSnapshot -Stage 'publication-pre-move'
        $null = Assert-PatchletInputFreezeLock -Lock $InputLock -Stage 'publication-pre-move'
        $preMoveResult = if ($null -ne $PreMoveValidation) { & $PreMoveValidation } else { $null }
        $null = Assert-PatchletInputFreeze -Snapshot $InputSnapshot -Stage 'publication-immediate-pre-move'
        $null = Assert-PatchletInputFreezeLock -Lock $InputLock -Stage 'publication-immediate-pre-move'

        Move-Item -LiteralPath $temporary -Destination $publishFull
        $moveCommitted = $true
        $publishedLock = [IO.File]::Open(
            $publishFull, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ((Get-PatchletSha256 -Path $publishFull) -ne $ExpectedSha256) {
            throw 'Published APK hash differs from the gated output APK.'
        }
        $null = Assert-PatchletInputFreeze -Snapshot $InputSnapshot -Stage 'publication-post-move'
        $null = Assert-PatchletInputFreezeLock -Lock $InputLock -Stage 'publication-post-move'
        $postMoveResult = if ($null -ne $PostMoveValidation) { & $PostMoveValidation } else { $null }
        if ((Get-PatchletSha256 -Path $publishFull) -ne $ExpectedSha256) {
            throw 'Published APK changed while committing the success report.'
        }
        $publishedLock.Dispose()
        $publishedLock = $null
        return [pscustomobject]@{
            path = $publishFull
            sha256 = $ExpectedSha256
            preMoveValidation = $preMoveResult
            postMoveValidation = $postMoveResult
        }
    } catch {
        $originalError = $_
        if ($null -ne $publishedLock) {
            $publishedLock.Dispose()
            $publishedLock = $null
        }
        foreach ($cleanupPath in @($temporary, $(if ($moveCommitted) { $publishFull }))) {
            if (-not [string]::IsNullOrWhiteSpace([string]$cleanupPath) `
                    -and (Test-Path -LiteralPath $cleanupPath)) {
                try { Remove-Item -LiteralPath $cleanupPath -Force } catch { }
            }
        }
        $residue = @($temporary, $(if ($moveCommitted) { $publishFull }) | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_) -and (Test-Path -LiteralPath $_)
            })
        if ($residue.Count -gt 0) {
            $cleanupError = [InvalidOperationException]::new(
                "Publication rollback left exact-path residue after '$($originalError.Exception.Message)': $($residue -join '; ')",
                $originalError.Exception)
            $cleanupError.Data['PatchletPublicationResiduePaths'] = ($residue -join '|')
            throw $cleanupError
        }
        throw $originalError
    }
}

function Remove-PatchletOwnedPublication {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRoot
    )

    $fullPath = Assert-PatchletPathUnderRoot -Path $Path -Root $AllowedRoot
    if (Test-Path -LiteralPath $fullPath) {
        try { Remove-Item -LiteralPath $fullPath -Force } catch { }
    }
    $residue = Test-Path -LiteralPath $fullPath -PathType Leaf
    return [pscustomobject]@{
        path = $fullPath
        removed = -not $residue
        residue = $residue
        sha256 = if ($residue) {
            try { Get-PatchletSha256 -Path $fullPath } catch { $null }
        } else { $null }
    }
}

function Read-PatchletJson {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file does not exist: $Path"
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-PatchletJson {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $json = ($Value | ConvertTo-Json -Depth 100).Replace("`r`n", "`n").TrimEnd() + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Get-NormalizedPatchletText {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Text file does not exist: $Path"
    }
    return [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Set-NormalizedPatchletText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Assert-PatchletPathUnderRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [switch]$AllowRoot
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    $inside = $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    if ($AllowRoot -and $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $inside = $true
    }
    if (-not $inside) {
        throw "Resolved path escapes its allowed root. Path='$fullPath' Root='$fullRoot'"
    }
    return $fullPath
}

function Assert-PatchletArtifactBaseName {
    param([Parameter(Mandatory)][string]$Name)

    if ([IO.Path]::IsPathRooted($Name) `
            -or [IO.Path]::GetFileName($Name) -ne $Name `
            -or $Name.Length -gt 128 `
            -or $Name -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$') {
        throw "Artifact basename must not contain separators, traversal, ADS, or trailing punctuation: '$Name'"
    }
    return $Name
}

function Resolve-PatchletChildPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Child
    )

    return Assert-PatchletPathUnderRoot -Path (Join-Path $Root $Child) -Root $Root
}

function Resolve-PatchletTemplateRoot {
    param(
        [Parameter(Mandatory)][string]$PatchletsRoot,
        [Parameter(Mandatory)]$Section,
        [Parameter(Mandatory)][string]$DefaultRelativeRoot,
        [Parameter(Mandatory)][ValidateSet('bridge', 'bridge-reference', 'inline', 'reporting', 'settings')][string]$Kind
    )

    $property = $Section.PSObject.Properties['templateRoot']
    if ($null -eq $property) {
        return Resolve-PatchletChildPath -Root $PatchletsRoot -Child $DefaultRelativeRoot
    }

    $relative = ([string]$property.Value).Replace('\', '/')
    $defaultRelative = $DefaultRelativeRoot.Replace('\', '/')
    $escapedKind = [regex]::Escape($Kind)
    if (-not $relative.Equals($defaultRelative, [StringComparison]::Ordinal) `
            -and $relative -notmatch "^assets/versioned/[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?/$escapedKind$") {
        throw "Invalid versioned $Kind template root '$relative'."
    }
    return Resolve-PatchletChildPath -Root $PatchletsRoot -Child $relative
}

function Get-PatchletLiteralCount {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Literal
    )

    if ($Literal.Length -eq 0) {
        throw 'Patchlet anchors may not be empty.'
    }
    $count = 0
    $offset = 0
    while ($offset -le ($Text.Length - $Literal.Length)) {
        $index = $Text.IndexOf($Literal, $offset, [StringComparison]::Ordinal)
        if ($index -lt 0) {
            break
        }
        $count++
        $offset = $index + $Literal.Length
    }
    return $count
}

function Assert-PatchletManifestPermission {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ManifestText,
        [Parameter(Mandatory)][string]$Permission,
        [Parameter(Mandatory)][ValidateSet('decoded-xml', 'aapt2-xmltree')][string]$Format,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    if ($Permission -notmatch '^android\.permission\.[A-Z0-9_]+$') {
        throw 'Manifest permission proof requires one canonical Android permission name.'
    }
    $matches = 0
    if ($Format -ceq 'decoded-xml') {
        if ($ManifestText.Contains('<!DOCTYPE', [StringComparison]::OrdinalIgnoreCase)) {
            throw $FailureMessage
        }
        $document = [Xml.XmlDocument]::new()
        $document.PreserveWhitespace = $true
        $document.XmlResolver = $null
        try {
            $document.LoadXml($ManifestText)
        } catch {
            throw $FailureMessage
        }
        $root = $document.DocumentElement
        if ($null -ne $root -and $root.LocalName -ceq 'manifest' `
                -and $root.NamespaceURI.Length -eq 0) {
            foreach ($child in @($root.ChildNodes)) {
                if ($child -isnot [Xml.XmlElement] `
                        -or $child.LocalName -cne 'uses-permission' `
                        -or $child.NamespaceURI.Length -ne 0) {
                    continue
                }
                $name = $child.GetAttributeNode(
                    'name', 'http://schemas.android.com/apk/res/android')
                if ($null -ne $name -and $name.Value -ceq $Permission) {
                    $matches++
                }
            }
        }
    } else {
        $lines = @($ManifestText.Replace("`r`n", "`n").Replace("`r", "`n") -split "`n")
        $manifestElements = @()
        for ($index = 0; $index -lt $lines.Count; $index++) {
            $rootMatch = [regex]::Match(
                [string]$lines[$index], '^(?<indent>\s*)E:\s+manifest(?:\s|\(|$)')
            if ($rootMatch.Success) {
                $manifestElements += [pscustomobject]@{
                    index = $index
                    indent = $rootMatch.Groups['indent'].Value.Length
                }
            }
        }
        if ($manifestElements.Count -ne 1) {
            throw $FailureMessage
        }
        $rootIndex = [int]$manifestElements[0].index
        $rootIndent = [int]$manifestElements[0].indent
        for ($index = $rootIndex + 1; $index -lt $lines.Count; $index++) {
            $anyElement = [regex]::Match(
                [string]$lines[$index], '^(?<indent>\s*)E:\s+')
            if ($anyElement.Success `
                    -and $anyElement.Groups['indent'].Value.Length -le $rootIndent) {
                break
            }
            $element = [regex]::Match(
                [string]$lines[$index], '^(?<indent>\s*)E:\s+uses-permission(?:\s|\(|$)')
            if (-not $element.Success `
                    -or $element.Groups['indent'].Value.Length -ne ($rootIndent + 4)) {
                continue
            }
            $indent = $element.Groups['indent'].Value.Length
            $nameValues = [Collections.Generic.List[string]]::new()
            $nestedElement = $false
            for ($childIndex = $index + 1; $childIndex -lt $lines.Count; $childIndex++) {
                $line = [string]$lines[$childIndex]
                $nextElement = [regex]::Match($line, '^(?<indent>\s*)E:\s+')
                if ($nextElement.Success `
                        -and $nextElement.Groups['indent'].Value.Length -le $indent) {
                    break
                }
                if ($nextElement.Success) {
                    $nestedElement = $true
                    continue
                }
                $nameAttribute = [regex]::Match(
                    $line,
                    '^(?<indent>\s*)A:\s+(?:android:|http://schemas\.android\.com/apk/res/android:)name(?:\(0x[0-9a-fA-F]+\))?="(?<value>[^"]*)"(?:\s+\(Raw:\s+"[^"]*"\))?\s*$')
                if ($nameAttribute.Success `
                        -and $nameAttribute.Groups['indent'].Value.Length -eq ($indent + 2)) {
                    $nameValues.Add($nameAttribute.Groups['value'].Value)
                }
            }
            if (-not $nestedElement -and $nameValues.Count -eq 1 `
                    -and $nameValues[0] -ceq $Permission) {
                $matches++
            }
        }
    }
    if ($matches -ne 1) {
        throw $FailureMessage
    }
    return $true
}

function Get-PatchletRuleAnchor {
    param(
        [Parameter(Mandatory)]$Rule,
        [Parameter(Mandatory)][ValidateSet('before', 'after')][string]$Kind,
        [Parameter(Mandatory)][string]$ResolutionDirectory
    )

    $inlineName = $Kind
    $fileName = $Kind + 'File'
    $properties = @($Rule.PSObject.Properties.Name)
    if ($properties -contains $inlineName) {
        return ([string]$Rule.$inlineName).Replace("`r`n", "`n").Replace("`r", "`n")
    }
    if ($properties -contains $fileName) {
        $anchorPath = Resolve-PatchletChildPath -Root $ResolutionDirectory -Child ([string]$Rule.$fileName)
        return Get-NormalizedPatchletText -Path $anchorPath
    }
    throw "Rule '$($Rule.id)' has neither '$inlineName' nor '$fileName'."
}

function Get-PatchletRewriteState {
    param(
        [Parameter(Mandatory)]$Rule,
        [Parameter(Mandatory)][string]$DecodedRoot,
        [Parameter(Mandatory)][string]$ResolutionDirectory
    )

    $targetPath = Resolve-PatchletChildPath -Root $DecodedRoot -Child ([string]$Rule.path)
    $text = Get-NormalizedPatchletText -Path $targetPath
    $before = Get-PatchletRuleAnchor -Rule $Rule -Kind before -ResolutionDirectory $ResolutionDirectory
    $after = Get-PatchletRuleAnchor -Rule $Rule -Kind after -ResolutionDirectory $ResolutionDirectory
    if ($before.Equals($after, [StringComparison]::Ordinal)) {
        throw "Rule '$($Rule.id)' has identical before and after anchors."
    }

    $expected = [int]$Rule.expectedCount
    if ($expected -le 0) {
        throw "Rule '$($Rule.id)' must have a positive expectedCount."
    }
    $beforeCount = Get-PatchletLiteralCount -Text $text -Literal $before
    $afterCount = Get-PatchletLiteralCount -Text $text -Literal $after
    $state = 'drifted'
    if (($beforeCount -eq $expected) -and ($afterCount -eq 0)) {
        $state = 'pristine'
    } elseif (($beforeCount -eq 0) -and ($afterCount -eq $expected)) {
        $state = 'applied'
    }

    return [pscustomobject]@{
        id = [string]$Rule.id
        path = [string]$Rule.path
        targetPath = $targetPath
        state = $state
        expectedCount = $expected
        beforeCount = $beforeCount
        afterCount = $afterCount
        before = $before
        after = $after
        text = $text
    }
}

function Test-PatchletRewriteSet {
    param(
        [Parameter(Mandatory)][string]$RewriteSetPath,
        [Parameter(Mandatory)][string]$DecodedRoot
    )

    $rewriteSchema = Join-Path (Get-PatchletRepositoryRoot) 'patchlets\schemas\rewrite-set.schema.json'
    if (-not (Test-Json -LiteralPath $RewriteSetPath -SchemaFile $rewriteSchema -ErrorAction Stop)) {
        throw "Rewrite set failed schema validation: $RewriteSetPath"
    }
    $set = Read-PatchletJson -Path $RewriteSetPath
    $resolutionDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($RewriteSetPath))
    $results = @()
    foreach ($rule in @($set.rules)) {
        $state = Get-PatchletRewriteState -Rule $rule -DecodedRoot $DecodedRoot -ResolutionDirectory $resolutionDirectory
        if ($state.state -eq 'drifted') {
            throw "Patchlet drift at rule '$($state.id)' ($($state.path)): expected old=$($state.expectedCount),new=0 or old=0,new=$($state.expectedCount); observed old=$($state.beforeCount),new=$($state.afterCount)."
        }
        $results += [pscustomobject]@{
            id = $state.id
            path = $state.path
            state = $state.state
            expectedCount = $state.expectedCount
            beforeCount = $state.beforeCount
            afterCount = $state.afterCount
        }
    }
    return $results
}

function Apply-PatchletRewriteSet {
    param(
        [Parameter(Mandatory)][string]$RewriteSetPath,
        [Parameter(Mandatory)][string]$DecodedRoot
    )

    $rewriteSchema = Join-Path (Get-PatchletRepositoryRoot) 'patchlets\schemas\rewrite-set.schema.json'
    if (-not (Test-Json -LiteralPath $RewriteSetPath -SchemaFile $rewriteSchema -ErrorAction Stop)) {
        throw "Rewrite set failed schema validation: $RewriteSetPath"
    }
    $set = Read-PatchletJson -Path $RewriteSetPath
    $resolutionDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($RewriteSetPath))
    $results = @()
    foreach ($rule in @($set.rules)) {
        $state = Get-PatchletRewriteState -Rule $rule -DecodedRoot $DecodedRoot -ResolutionDirectory $resolutionDirectory
        if ($state.state -eq 'drifted') {
            throw "Refusing ambiguous rewrite '$($state.id)' ($($state.path)): expected old=$($state.expectedCount),new=0; observed old=$($state.beforeCount),new=$($state.afterCount)."
        }
        $action = 'no-op'
        if ($state.state -eq 'pristine') {
            $patched = $state.text.Replace($state.before, $state.after)
            Set-NormalizedPatchletText -Path $state.targetPath -Text $patched
            $verified = Get-PatchletRewriteState -Rule $rule -DecodedRoot $DecodedRoot -ResolutionDirectory $resolutionDirectory
            if ($verified.state -ne 'applied') {
                throw "Postcondition failed for rewrite '$($state.id)'."
            }
            $action = 'applied'
            $state = $verified
        }
        $results += [pscustomobject]@{
            id = $state.id
            path = $state.path
            action = $action
            state = $state.state
            expectedCount = $state.expectedCount
            beforeCount = $state.beforeCount
            afterCount = $state.afterCount
        }
    }
    return $results
}

function Test-PatchletProofs {
    param(
        [Parameter(Mandatory)]$Resolution,
        [Parameter(Mandatory)][string]$DecodedRoot
    )

    $results = @()
    foreach ($proof in @($Resolution.proofs)) {
        $propertyNames = @($proof.PSObject.Properties.Name)
        $pathProperty = $proof.PSObject.Properties['path']
        $candidatePathsProperty = $proof.PSObject.Properties['candidatePaths']
        $hasPath = $null -ne $pathProperty
        $hasCandidatePaths = $null -ne $candidatePathsProperty
        if ($hasPath -eq $hasCandidatePaths) {
            throw "Semantic proof '$($proof.id)' must declare exactly one path mode."
        }

        $minimum = [int]$proof.minimumCount
        if ($minimum -lt 1 -or [string]::IsNullOrEmpty([string]$proof.contains)) {
            throw "Semantic proof '$($proof.id)' has an invalid literal-count contract."
        }

        if ($hasPath) {
            $expectedProperties = @('id', 'path', 'contains', 'minimumCount')
            if ($propertyNames.Count -ne $expectedProperties.Count `
                    -or @($expectedProperties | Where-Object {
                            -not ($propertyNames -ccontains $_)
                        }).Count -ne 0) {
                throw "Semantic proof '$($proof.id)' has an unexpected ordinary-path mapping."
            }
            $relativePath = [string]$proof.path
            $path = Resolve-PatchletChildPath -Root $DecodedRoot -Child $relativePath
            $text = Get-NormalizedPatchletText -Path $path
            $count = Get-PatchletLiteralCount -Text $text -Literal ([string]$proof.contains)
            if ($count -lt $minimum) {
                throw "Semantic proof '$($proof.id)' failed in '$relativePath': expected at least $minimum, observed $count."
            }
            $results += [pscustomobject]@{
                id = [string]$proof.id
                path = $relativePath
                count = $count
                minimumCount = $minimum
            }
            continue
        }

        $expectedCollisionProperties = @(
            'id',
            'candidatePaths',
            'targetClassDescriptor',
            'siblingClassDescriptor',
            'contains',
            'minimumCount'
        )
        if ($propertyNames.Count -ne $expectedCollisionProperties.Count `
                -or @($expectedCollisionProperties | Where-Object {
                        -not ($propertyNames -ccontains $_)
                    }).Count -ne 0) {
            throw "Semantic proof '$($proof.id)' has an unexpected descriptor-collision mapping."
        }

        $candidatePaths = @($candidatePathsProperty.Value | ForEach-Object { [string]$_ })
        $targetDescriptor = [string]$proof.targetClassDescriptor
        $siblingDescriptor = [string]$proof.siblingClassDescriptor
        $descriptorPattern = '^L(?:[A-Za-z0-9_$-]+/)*[A-Za-z0-9_$-]+;$'
        if ($candidatePaths.Count -ne 2 `
                -or [string]::IsNullOrEmpty($candidatePaths[0]) `
                -or [string]::IsNullOrEmpty($candidatePaths[1]) `
                -or $candidatePaths[0] -ceq $candidatePaths[1] `
                -or -not [regex]::IsMatch($targetDescriptor, $descriptorPattern) `
                -or -not [regex]::IsMatch($siblingDescriptor, $descriptorPattern) `
                -or $targetDescriptor -ceq $siblingDescriptor) {
            throw "Semantic proof '$($proof.id)' has an invalid descriptor-collision contract."
        }

        $candidateMappings = @()
        foreach ($candidatePath in $candidatePaths) {
            $resolvedCandidate = Resolve-PatchletChildPath `
                -Root $DecodedRoot -Child $candidatePath
            if (-not (Test-Path -LiteralPath $resolvedCandidate -PathType Leaf)) {
                throw "Semantic proof '$($proof.id)' candidate '$candidatePath' is absent."
            }
            $candidateText = Get-NormalizedPatchletText -Path $resolvedCandidate
            $classLines = @($candidateText -split "`n" | Where-Object {
                    $_.StartsWith('.class ', [StringComparison]::Ordinal)
                })
            if ($classLines.Count -ne 1) {
                throw "Semantic proof '$($proof.id)' candidate '$candidatePath' does not contain exactly one class declaration."
            }
            $classTokens = @($classLines[0].TrimEnd("`r") -split '[ `t]+' | Where-Object {
                    -not [string]::IsNullOrEmpty($_)
                })
            if ($classTokens.Count -lt 3 `
                    -or $classTokens[0] -cne '.class') {
                throw "Semantic proof '$($proof.id)' candidate '$candidatePath' has a malformed class declaration."
            }
            $resolvedDescriptor = [string]$classTokens[$classTokens.Count - 1]
            if ($resolvedDescriptor -cne $targetDescriptor `
                    -and $resolvedDescriptor -cne $siblingDescriptor) {
                throw "Semantic proof '$($proof.id)' candidate '$candidatePath' declares unexpected class '$resolvedDescriptor'."
            }
            $candidateMappings += [pscustomobject]@{
                path = $candidatePath
                descriptor = $resolvedDescriptor
                text = $candidateText
            }
        }

        $targetMappings = @($candidateMappings | Where-Object {
                [string]$_.descriptor -ceq $targetDescriptor
            })
        $siblingMappings = @($candidateMappings | Where-Object {
                [string]$_.descriptor -ceq $siblingDescriptor
            })
        if ($targetMappings.Count -ne 1 -or $siblingMappings.Count -ne 1) {
            throw "Semantic proof '$($proof.id)' descriptor-collision mapping must contain one exact target and one exact sibling."
        }

        $selectedPath = [string]$targetMappings[0].path
        $count = Get-PatchletLiteralCount `
            -Text ([string]$targetMappings[0].text) -Literal ([string]$proof.contains)
        if ($count -lt $minimum) {
            throw "Semantic proof '$($proof.id)' failed in descriptor-selected '$selectedPath': expected at least $minimum, observed $count."
        }
        $results += [pscustomobject]@{
            id = [string]$proof.id
            path = $selectedPath
            candidatePaths = @($candidatePaths)
            targetClassDescriptor = $targetDescriptor
            siblingClassDescriptor = $siblingDescriptor
            count = $count
            minimumCount = $minimum
        }
    }
    return $results
}

function Test-PatchletSourceBinding {
    param(
        [Parameter(Mandatory)]$Resolution,
        [Parameter(Mandatory)][string]$SourceApk
    )

    $actual = Get-PatchletSha256 -Path $SourceApk
    $expected = ([string]$Resolution.source.sha256).ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "This resolution is bound to APK SHA-256 '$expected', but '$SourceApk' is '$actual'. Create a new AI-assisted resolution instead of forcing this one."
    }
    return [pscustomobject]@{ expectedSha256 = $expected; actualSha256 = $actual; status = 'matched' }
}

function Test-PatchletAssets {
    param(
        [Parameter(Mandatory)]$Resolution,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $patchletsRoot = Join-Path $RepositoryRoot 'patchlets'
    $assetsRoot = Join-Path $patchletsRoot 'assets\autoblock'
    $bridgeTemplateRoot = Resolve-PatchletTemplateRoot `
        -PatchletsRoot $patchletsRoot `
        -Section $Resolution.bridge `
        -DefaultRelativeRoot 'assets\autoblock\bridge-templates' `
        -Kind 'bridge'
    $bridgeReferenceRoot = Resolve-PatchletTemplateRoot `
        -PatchletsRoot $patchletsRoot `
        -Section ([pscustomobject]@{
            templateRoot = [string]$Resolution.bridge.referenceRoot
        }) `
        -DefaultRelativeRoot 'assets\bridge-reference-415' `
        -Kind 'bridge-reference'
    $inlineTemplateRoot = Resolve-PatchletTemplateRoot `
        -PatchletsRoot $patchletsRoot `
        -Section $Resolution.inlineControls `
        -DefaultRelativeRoot 'assets\inline-control\templates' `
        -Kind 'inline'
    $reportTemplateRoot = Resolve-PatchletTemplateRoot `
        -PatchletsRoot $patchletsRoot `
        -Section $Resolution.reporting `
        -DefaultRelativeRoot 'assets\reporting\templates' `
        -Kind 'reporting'
    $settingsTemplateRoot = Resolve-PatchletTemplateRoot `
        -PatchletsRoot $patchletsRoot `
        -Section $Resolution.drawerSettings `
        -DefaultRelativeRoot 'assets\settings-ui\templates' `
        -Kind 'settings'
    $checks = @(
        [pscustomobject]@{
            id = 'eddsa-jar'
            kind = 'file'
            path = Join-Path $assetsRoot 'lib\net-i2p-crypto-eddsa-0.3.1.jar'
            expected = ([string]$Resolution.assets.eddsaJarSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'smali-carrier'
            kind = 'file'
            path = Join-Path $assetsRoot 'stub\smali-carrier.apk'
            expected = ([string]$Resolution.assets.smaliCarrierSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'signed-blocklist-v3-fixture'
            kind = 'tree'
            path = Join-Path $RepositoryRoot 'patchlets\assets\tests\fixtures\blocklist-v3-2026-09-06'
            filter = '*'
            expected = ([string]$Resolution.assets.signedBlocklistV3FixtureTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'autoblock-java-tree'
            kind = 'tree'
            path = Join-Path $assetsRoot 'java'
            filter = '*.java'
            expected = ([string]$Resolution.assets.autoblockJavaTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'report-java-tree'
            kind = 'tree'
            path = Join-Path $assetsRoot 'java\threadsmod\reporting'
            filter = '*.java'
            expected = ([string]$Resolution.assets.reportJavaTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'bridge-template-tree'
            kind = 'tree'
            path = $bridgeTemplateRoot
            filter = '*.tmpl'
            expected = ([string]$Resolution.assets.bridgeTemplateTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'exact-version-rendered-bridge-reference'
            kind = 'tree'
            path = $bridgeReferenceRoot
            filter = '*.smali'
            expected = ([string]$Resolution.assets.bridgeReferenceTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'inline-template-tree'
            kind = 'tree'
            path = $inlineTemplateRoot
            filter = '*.tmpl'
            expected = ([string]$Resolution.assets.inlineTemplateTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'report-template-tree'
            kind = 'tree'
            path = $reportTemplateRoot
            filter = '*.tmpl'
            expected = ([string]$Resolution.assets.reportTemplateTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'settings-ui-template-tree'
            kind = 'tree'
            path = $settingsTemplateRoot
            filter = '*.tmpl'
            expected = ([string]$Resolution.assets.settingsUiTemplateTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'host-harness-tree'
            kind = 'tree'
            path = Join-Path $RepositoryRoot 'patchlets\assets\tests'
            filter = '*.java'
            expected = ([string]$Resolution.assets.hostHarnessTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'targeted-jadx-recovery-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\TargetedJadxRecovery.java'
            expected = ([string]$Resolution.assets.targetedJadxRecoverySourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'dex-inspector-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\DexInspector.java'
            expected = ([string]$Resolution.assets.dexInspectorSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'dex-literal-call-inspector-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\DexLiteralCallInspector.java'
            expected = ([string]$Resolution.assets.dexLiteralCallInspectorSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'dex-literal-call-inspector-test-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\Test-DexLiteralCallInspector.ps1'
            expected = ([string]$Resolution.assets.dexLiteralCallInspectorTestSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'dex-literal-call-fixture-tree'
            kind = 'tree'
            path = Join-Path $RepositoryRoot 'patchlets\assets\release-gates\dex-literal-call'
            filter = '*.java'
            expected = ([string]$Resolution.assets.dexLiteralCallFixtureTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'dex-bridge-flow-inspector-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\DexBridgeFlowInspector.java'
            expected = ([string]$Resolution.assets.dexBridgeFlowInspectorSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'dex-bridge-flow-fixture-assembler'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\DexBridgeFlowFixtureAssembler.java'
            expected = ([string]$Resolution.assets.dexBridgeFlowFixtureAssemblerSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'dex-bridge-flow-inspector-test-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\Test-DexBridgeFlowInspector.ps1'
            expected = ([string]$Resolution.assets.dexBridgeFlowInspectorTestSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'dex-bridge-flow-fixture-tree'
            kind = 'tree'
            path = Join-Path $RepositoryRoot 'patchlets\assets\release-gates\dex-bridge-flow'
            filter = '*'
            expected = ([string]$Resolution.assets.dexBridgeFlowFixtureTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'dex-report-permalink-flow-inspector-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\DexReportPermalinkFlowInspector.java'
            expected = ([string]$Resolution.assets.dexReportPermalinkFlowInspectorSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'dex-report-permalink-flow-inspector-test-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\Test-DexReportPermalinkFlowInspector.ps1'
            expected = ([string]$Resolution.assets.dexReportPermalinkFlowInspectorTestSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'dex-report-permalink-flow-fixture-tree'
            kind = 'tree'
            path = Join-Path $RepositoryRoot 'patchlets\assets\release-gates\dex-report-permalink-flow'
            filter = '*'
            expected = ([string]$Resolution.assets.dexReportPermalinkFlowFixtureTreeSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'split-universalization-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\Build-SplitSourceUniversalApk.ps1'
            expected = ([string]$Resolution.assets.splitUniversalizationToolSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'split-source-contract-test-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\Test-SplitSourceSetContract.ps1'
            expected = ([string]$Resolution.assets.splitSourceContractTestSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'release-tool-contract-module'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\ThreadsMod.ReleaseToolContract.psm1'
            expected = ([string]$Resolution.assets.releaseToolContractModuleSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'patchlet-core-module'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\ThreadsMod.Patchlets.psm1'
            expected = ([string]$Resolution.assets.patchletCoreModuleSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'resolution-schema'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\schemas\resolution.schema.json'
            expected = ([string]$Resolution.assets.resolutionSchemaSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'patchlet-schema'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\schemas\patchlet.schema.json'
            expected = ([string]$Resolution.assets.patchletSchemaSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'patchlet-catalog-test-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\Test-PatchletCatalog.ps1'
            expected = ([string]$Resolution.assets.patchletCatalogTestSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'activity-ui-emulator-test-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\Test-ActivityUiEmulator.ps1'
            expected = ([string]$Resolution.assets.activityUiEmulatorTestSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'activity-ui-probe-manifest'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\assets\release-gates\activity-ui-probe\AndroidManifest.xml'
            expected = ([string]$Resolution.assets.activityUiProbeManifestSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'patched-apk-test-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\Test-PatchedApk.ps1'
            expected = ([string]$Resolution.assets.patchedApkTestSourceSha256).ToLowerInvariant()
        },
        [pscustomobject]@{
            id = 'release-contract-test-tool'
            kind = 'file'
            path = Join-Path $RepositoryRoot 'patchlets\tools\Test-ReleaseContract.ps1'
            expected = ([string]$Resolution.assets.releaseContractTestSourceSha256).ToLowerInvariant()
        }
    )
    if ($null -ne $Resolution.PSObject.Properties['proxy']) {
        $checks += @(
            [pscustomobject]@{
                id = 'proxy-java-tree'
                kind = 'tree'
                path = Join-Path $assetsRoot 'java\threadsmod\proxy'
                filter = '*.java'
                expected = ([string]$Resolution.assets.proxyJavaTreeSha256).ToLowerInvariant()
            },
            [pscustomobject]@{
                id = 'socks5-native-asset-tree'
                kind = 'tree'
                path = Join-Path $RepositoryRoot 'patchlets\assets\socks5-proxy\native'
                filter = '*'
                expected = ([string]$Resolution.assets.socks5NativeAssetTreeSha256).ToLowerInvariant()
            },
            [pscustomobject]@{
                id = 'socks5-native-build-tool'
                kind = 'file'
                path = Join-Path $RepositoryRoot 'patchlets\tools\Build-Socks5Native.ps1'
                expected = ([string]$Resolution.assets.socks5NativeBuildToolSha256).ToLowerInvariant()
            }
        )
    }
    if ($null -ne $Resolution.PSObject.Properties['update']) {
        $checks += @(
            [pscustomobject]@{
                id = 'update-java-tree'
                kind = 'tree'
                path = Join-Path $assetsRoot 'java\threadsmod\update'
                filter = '*.java'
                expected = ([string]$Resolution.assets.updateJavaTreeSha256).ToLowerInvariant()
            },
            [pscustomobject]@{
                id = 'dex-update-flow-inspector-tool'
                kind = 'file'
                path = Join-Path $RepositoryRoot 'patchlets\tools\DexUpdateFlowInspector.java'
                expected = ([string]$Resolution.assets.dexUpdateFlowInspectorSourceSha256).ToLowerInvariant()
            },
            [pscustomobject]@{
                id = 'dex-update-flow-inspector-test-tool'
                kind = 'file'
                path = Join-Path $RepositoryRoot 'patchlets\tools\Test-DexUpdateFlowInspector.ps1'
                expected = ([string]$Resolution.assets.dexUpdateFlowInspectorTestSourceSha256).ToLowerInvariant()
            },
            [pscustomobject]@{
                id = 'dex-update-flow-fixture-tree'
                kind = 'tree'
                path = Join-Path $RepositoryRoot `
                    'patchlets\assets\release-gates\dex-update-flow'
                filter = '*'
                expected = ([string]$Resolution.assets.dexUpdateFlowFixtureTreeSha256).ToLowerInvariant()
            }
        )
    }
    $results = @()
    foreach ($check in $checks) {
        $actual = if ($check.kind -eq 'tree') {
            Get-PatchletTreeSha256 -Root $check.path -Filter ([string]$check.filter)
        } else {
            Get-PatchletSha256 -Path $check.path
        }
        if ($actual -ne $check.expected) {
            throw "Pinned asset '$($check.id)' hash mismatch. Expected '$($check.expected)', observed '$actual'."
        }
        $results += [pscustomobject]@{
            id = $check.id
            kind = $check.kind
            path = $check.path
            filter = if ($check.kind -eq 'tree') { [string]$check.filter } else { $null }
            sha256 = $actual
        }
    }
    return $results
}

function Expand-PatchletSmaliTemplates {
    param(
        [Parameter(Mandatory)]$Symbols,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][string[]]$TemplateNames,
        [Parameter(Mandatory)][string]$Owner
    )

    $results = @()
    foreach ($templateName in $TemplateNames) {
        $templatePath = Resolve-PatchletChildPath -Root $TemplateRoot -Child $templateName
        $rendered = Get-NormalizedPatchletText -Path $templatePath
        foreach ($property in @($Symbols.PSObject.Properties)) {
            $token = '{{' + $property.Name + '}}'
            $rendered = $rendered.Replace($token, [string]$property.Value)
        }
        $unresolved = @([regex]::Matches($rendered, '\{\{[^{}]+\}\}') | ForEach-Object Value | Sort-Object -Unique)
        if ($unresolved.Count -gt 0) {
            throw "Template '$templateName' contains unresolved tokens: $($unresolved -join ', ')"
        }

        $destinationName = $templateName.Substring(0, $templateName.Length - '.tmpl'.Length)
        $destinationPath = Resolve-PatchletChildPath -Root $DestinationRoot -Child $destinationName
        $action = 'created'
        if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
            $existing = Get-NormalizedPatchletText -Path $destinationPath
            if (-not $existing.Equals($rendered, [StringComparison]::Ordinal)) {
                throw "Version-specific $Owner destination already exists with different content: $destinationPath"
            }
            $action = 'no-op'
        } else {
            Set-NormalizedPatchletText -Path $destinationPath -Text $rendered
        }
        $results += [pscustomobject]@{ file = $destinationName; action = $action; path = $destinationPath }
    }
    return $results
}

function Expand-PatchletBridgeTemplates {
    param(
        [Parameter(Mandatory)]$Symbols,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    return @(Expand-PatchletSmaliTemplates `
        -Symbols $Symbols `
        -TemplateRoot $TemplateRoot `
        -DestinationRoot $DestinationRoot `
        -TemplateNames @(
            'ThreadsBlockBridge.smali.tmpl',
            'MutationCallback.smali.tmpl') `
        -Owner 'native bridge')
}

function Expand-PatchletInlineTemplates {
    param(
        [Parameter(Mandatory)]$Symbols,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    return @(Expand-PatchletSmaliTemplates `
        -Symbols $Symbols `
        -TemplateRoot $TemplateRoot `
        -DestinationRoot $DestinationRoot `
        -TemplateNames @(
            'InlineActionClick.smali.tmpl',
            'InlineActionRowAdapter.smali.tmpl',
            'InlineVisibilityCallback.smali.tmpl') `
        -Owner 'inline control')
}

function Expand-PatchletReportTemplates {
    param(
        [Parameter(Mandatory)]$Symbols,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][string[]]$TemplateNames
    )

    return @(Expand-PatchletSmaliTemplates `
        -Symbols $Symbols `
        -TemplateRoot $TemplateRoot `
        -DestinationRoot $DestinationRoot `
        -TemplateNames $TemplateNames `
        -Owner 'consented reporting control')
}

function Expand-PatchletSettingsTemplates {
    param(
        [Parameter(Mandatory)]$Symbols,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    return @(Expand-PatchletSmaliTemplates `
        -Symbols $Symbols `
        -TemplateRoot $TemplateRoot `
        -DestinationRoot $DestinationRoot `
        -TemplateNames @(
            'DrawerSettingsClick.smali.tmpl',
            'DrawerSettingsItem.smali.tmpl',
            'DrawerSettingsRowAdapter.smali.tmpl') `
        -Owner 'drawer settings control')
}

function Install-PatchletGeneratedSmali {
    param(
        [Parameter(Mandatory)][string]$GeneratedSmaliRoot,
        [Parameter(Mandatory)][string]$DestinationSmaliRoot
    )

    $excluded = 'threadsmod/autoblock/ThreadsBlockBridge.smali'
    $stubSeen = $false
    $results = @()
    $files = Get-ChildItem -LiteralPath $GeneratedSmaliRoot -Recurse -File -Filter '*.smali' | Sort-Object FullName
    foreach ($file in $files) {
        $relative = $file.FullName.Substring(([IO.Path]::GetFullPath($GeneratedSmaliRoot).TrimEnd('\') + '\').Length).Replace('\', '/')
        if ($relative -eq $excluded) {
            $stubSeen = $true
            continue
        }
        $destination = Resolve-PatchletChildPath -Root $DestinationSmaliRoot -Child $relative
        $content = Get-NormalizedPatchletText -Path $file.FullName
        $action = 'created'
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $existing = Get-NormalizedPatchletText -Path $destination
            if (-not $existing.Equals($content, [StringComparison]::Ordinal)) {
                throw "Patchlet-owned class collision at '$relative'. A future input must be resolved explicitly."
            }
            $action = 'no-op'
        } else {
            Set-NormalizedPatchletText -Path $destination -Text $content
        }
        $results += [pscustomobject]@{ file = $relative; action = $action; path = $destination }
    }
    if (-not $stubSeen) {
        throw "Generated compile-time bridge stub '$excluded' was not found. Refusing to copy an unexpected generated tree."
    }
    return $results
}

function Invoke-PatchletNative {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory
    )

    if ($WorkingDirectory) {
        Push-Location -LiteralPath $WorkingDirectory
    }
    try {
        & $Command @Arguments | Out-Host
        $exitCode = $LASTEXITCODE
    } finally {
        if ($WorkingDirectory) {
            Pop-Location
        }
    }
    if ($exitCode -ne 0) {
        throw "Native command failed with exit code ${exitCode}: $Command $($Arguments -join ' ')"
    }
}

Export-ModuleMember -Function @(
    'Get-PatchletRepositoryRoot',
    'Get-PatchletSha256',
    'Get-PatchletTreeSha256',
    'Test-PatchletSplitSourceSet',
    'Test-PatchletApkEditorContract',
    'Get-PatchletCompleteTreeState',
    'Copy-PatchletCompleteTree',
    'Test-PatchletZipInventory',
    'New-PatchletInputFreeze',
    'Assert-PatchletInputFreeze',
    'Enter-PatchletInputFreezeLock',
    'Assert-PatchletInputFreezeLock',
    'Exit-PatchletInputFreezeLock',
    'Invoke-PatchletPublicationTransaction',
    'Remove-PatchletOwnedPublication',
    'Read-PatchletJson',
    'Write-PatchletJson',
    'Get-NormalizedPatchletText',
    'Set-NormalizedPatchletText',
    'Assert-PatchletPathUnderRoot',
    'Assert-PatchletArtifactBaseName',
    'Resolve-PatchletChildPath',
    'Resolve-PatchletTemplateRoot',
    'Get-PatchletLiteralCount',
    'Assert-PatchletManifestPermission',
    'Test-PatchletRewriteSet',
    'Apply-PatchletRewriteSet',
    'Test-PatchletProofs',
    'Test-PatchletSourceBinding',
    'Test-PatchletAssets',
    'Expand-PatchletSmaliTemplates',
    'Expand-PatchletBridgeTemplates',
    'Expand-PatchletInlineTemplates',
    'Expand-PatchletReportTemplates',
    'Expand-PatchletSettingsTemplates',
    'Install-PatchletGeneratedSmali',
    'Invoke-PatchletNative'
)
