[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [string]$WorkRoot,
    [string]$AndroidNdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk\ndk\27.1.12297006'),
    [string]$Git = 'git'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceUrl = 'https://github.com/heiher/hev-socks5-tunnel.git'
$sourceCommit = 'a404c11cd61d8e29e6f4c590b7e659d127fb843e'
$submoduleCommits = [ordered]@{
    'src/core' = '162dd996299fc2d2bff2dd63728f8a2cd71ed31a'
    'third-part/hev-task-system' = '328f35d903221b51811b3d02b277d665dfbdc75f'
    'third-part/lwip' = '2a11c14c7a32887af25a034e82ef18b0b12076ac'
    'third-part/yaml' = 'efa36117a8646d26d12b58e05bac472d7854a70d'
}
$expectedSha256 = '3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$patchPath = Join-Path $repositoryRoot 'patchlets\assets\socks5-proxy\native\hev-config-string.patch'
$ndkBuild = Join-Path ([IO.Path]::GetFullPath($AndroidNdk)) 'ndk-build.cmd'
$llvmObjcopy = Join-Path ([IO.Path]::GetFullPath($AndroidNdk)) 'toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-objcopy.exe'
$destinationFull = [IO.Path]::GetFullPath($Destination)

foreach ($required in @($patchPath, $ndkBuild, $llvmObjcopy)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required native build input is missing: $required"
    }
}
if (Test-Path -LiteralPath $destinationFull) {
    throw "Destination must not already exist: $destinationFull"
}

if ($WorkRoot) {
    $workRootFull = [IO.Path]::GetFullPath($WorkRoot)
} else {
    $workRootFull = Join-Path ([IO.Path]::GetTempPath()) (
        'threadsmod-hev-build-' + [Guid]::NewGuid().ToString('N'))
}
if (Test-Path -LiteralPath $workRootFull) {
    throw "WorkRoot must be a fresh, non-existing directory: $workRootFull"
}
$parent = Split-Path -Parent $workRootFull
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [IO.Directory]::CreateDirectory($parent) | Out-Null
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory
    )
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        & $Command @Arguments | Out-Host
        $exitCode = $LASTEXITCODE
    } finally {
        if ($WorkingDirectory) { Pop-Location }
    }
    if ($exitCode -ne 0) {
        throw "Native command failed with exit code ${exitCode}: $Command"
    }
}

function Get-ExactGitHead {
    param([Parameter(Mandatory)][string]$Repository)
    $value = (& $Git -C $Repository rev-parse HEAD)
    if ($LASTEXITCODE -ne 0) { throw "Unable to read Git HEAD: $Repository" }
    return ([string]$value).Trim().ToLowerInvariant()
}

function Expand-WindowsGitSymlinks {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Repositories
    )

    $links = @{}
    foreach ($repository in $Repositories) {
        $lines = @(& $Git -C $repository ls-files -s)
        if ($LASTEXITCODE -ne 0) { throw "Unable to inventory Git symlinks: $repository" }
        foreach ($line in $lines) {
            if ($line -notmatch '^120000 [0-9a-f]+ 0\t(.+)$') { continue }
            $relative = $Matches[1]
            $linkPath = [IO.Path]::GetFullPath((Join-Path $repository $relative))
            $item = Get-Item -LiteralPath $linkPath -Force
            if ($item.LinkType) { continue }
            $targetText = (Get-Content -Raw -LiteralPath $linkPath).Trim()
            if ([string]::IsNullOrWhiteSpace($targetText)) {
                throw "Empty Windows Git symlink stub: $linkPath"
            }
            $targetPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $linkPath) $targetText))
            if (-not $targetPath.StartsWith($Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Git symlink target escapes the native source tree: $linkPath"
            }
            $links[$linkPath] = $targetPath
        }
    }

    function Resolve-LinkTarget {
        param([Parameter(Mandatory)][string]$Path, [int]$Depth = 0)
        if ($Depth -gt 32) { throw "Git symlink chain is too deep: $Path" }
        if ($links.ContainsKey($Path)) {
            return Resolve-LinkTarget -Path ([string]$links[$Path]) -Depth ($Depth + 1)
        }
        return $Path
    }

    foreach ($linkPath in @($links.Keys | Sort-Object)) {
        $targetPath = Resolve-LinkTarget -Path ([string]$links[$linkPath])
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            throw "Git symlink target is not a file: $linkPath"
        }
        Remove-Item -LiteralPath $linkPath -Force
        Copy-Item -LiteralPath $targetPath -Destination $linkPath
    }
    return $links.Count
}

Invoke-Checked -Command $Git -Arguments @('clone', '--quiet', $sourceUrl, $workRootFull)
Invoke-Checked -Command $Git -Arguments @('-C', $workRootFull, 'checkout', '--quiet', '--detach', $sourceCommit)
Invoke-Checked -Command $Git -Arguments @('-C', $workRootFull, 'submodule', 'update', '--init', '--recursive')

if ((Get-ExactGitHead -Repository $workRootFull) -ne $sourceCommit) {
    throw 'Native source commit mismatch after checkout.'
}
$repositories = @($workRootFull)
foreach ($entry in $submoduleCommits.GetEnumerator()) {
    $submodulePath = [IO.Path]::GetFullPath((Join-Path $workRootFull ([string]$entry.Key)))
    if ((Get-ExactGitHead -Repository $submodulePath) -ne [string]$entry.Value) {
        throw "Native submodule commit mismatch: $($entry.Key)"
    }
    $repositories += $submodulePath
}

$materializedLinks = Expand-WindowsGitSymlinks -Root $workRootFull -Repositories $repositories
Invoke-Checked -Command $Git -Arguments @('-C', $workRootFull, 'apply', '--check', $patchPath)
Invoke-Checked -Command $Git -Arguments @('-C', $workRootFull, 'apply', $patchPath)

Invoke-Checked -Command $ndkBuild -WorkingDirectory $workRootFull -Arguments @(
    'NDK_PROJECT_PATH=.',
    'APP_BUILD_SCRIPT=Android.mk',
    'NDK_APPLICATION_MK=Application.mk',
    'APP_ABI=arm64-v8a',
    'APP_PLATFORM=android-28',
    'APP_CFLAGS=-O3 -DPKGNAME=threadsmod/proxy -DCLSNAME=Socks5VpnService'
)

$builtLibrary = Join-Path $workRootFull 'libs\arm64-v8a\libhev-socks5-tunnel.so'
if (-not (Test-Path -LiteralPath $builtLibrary -PathType Leaf)) {
    throw 'NDK build did not produce the expected arm64 library.'
}
$normalizedLibrary = Join-Path $workRootFull 'libs\arm64-v8a\libhev-socks5-tunnel.normalized.so'
Invoke-Checked -Command $llvmObjcopy -Arguments @(
    '--remove-section=.note.gnu.build-id',
    $builtLibrary,
    $normalizedLibrary
)
$actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $normalizedLibrary).Hash.ToLowerInvariant()
if ($actualSha256 -ne $expectedSha256) {
    throw "Native output hash mismatch. Expected '$expectedSha256', observed '$actualSha256'. Work tree retained at '$workRootFull'."
}

$destinationParent = Split-Path -Parent $destinationFull
if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
    [IO.Directory]::CreateDirectory($destinationParent) | Out-Null
}
Copy-Item -LiteralPath $normalizedLibrary -Destination $destinationFull

[pscustomobject]@{
    schemaVersion = 1
    status = 'passed'
    sourceUrl = $sourceUrl
    sourceCommit = $sourceCommit
    ndkVersion = '27.1.12297006'
    abi = 'arm64-v8a'
    minimumApi = 28
    normalization = 'llvm-objcopy --remove-section=.note.gnu.build-id'
    materializedWindowsGitSymlinks = $materializedLinks
    output = $destinationFull
    sha256 = $actualSha256
    workRoot = $workRootFull
}
