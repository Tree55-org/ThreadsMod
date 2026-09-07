[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceApk,
    [Parameter(Mandatory)][string]$DecodedRoot,
    [Parameter(Mandatory)][string]$ScratchRoot,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$LedgerPath,
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$BuildToolsVersion = '36.0.0',
    [string]$Java = 'java',
    [string]$Javac = 'javac',
    [string]$Jar = 'jar'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

function Install-PatchletProxyNativeLibrary {
    param(
        [Parameter(Mandatory)]$Resolution,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$DecodedRoot
    )

    $proxyProperty = $Resolution.PSObject.Properties['proxy']
    if ($null -eq $proxyProperty) { return @() }
    if (@($Resolution.patchlets | Where-Object {
                [string]$_ -eq '080-socks5-proxy'
            }).Count -ne 1) {
        throw 'A proxy native library requires exactly one 080-socks5-proxy resolution entry.'
    }

    $native = $proxyProperty.Value.nativeLibrary
    $patchletsRoot = Join-Path $RepositoryRoot 'patchlets'
    $sourcePath = Resolve-PatchletChildPath `
        -Root $patchletsRoot -Child ([string]$native.assetPath)
    $destinationPath = Resolve-PatchletChildPath `
        -Root $DecodedRoot -Child ([string]$native.decodedPath)
    $expectedSha256 = ([string]$native.sha256).ToLowerInvariant()
    $decodedArchivePath = ([string]$native.decodedPath).Replace('\', '/')
    $declaredArchivePath = ([string]$native.apkPath).Replace('\', '/')
    if ($decodedArchivePath -ne $declaredArchivePath) {
        throw 'Proxy native decodedPath and apkPath must identify the same APK entry.'
    }
    if ([IO.Path]::GetFileName($sourcePath) -ne [IO.Path]::GetFileName($destinationPath)) {
        throw 'Proxy native asset and decoded destination must retain one library basename.'
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Pinned proxy native asset does not exist: $sourcePath"
    }
    $sourceSha256 = Get-PatchletSha256 -Path $sourcePath
    if ($sourceSha256 -ne $expectedSha256) {
        throw "Proxy native asset hash mismatch. Expected '$expectedSha256', observed '$sourceSha256'."
    }

    $action = 'no-op'
    if (Test-Path -LiteralPath $destinationPath) {
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            throw "Proxy native destination is not a regular file: $destinationPath"
        }
        $destinationSha256 = Get-PatchletSha256 -Path $destinationPath
        if ($destinationSha256 -ne $expectedSha256) {
            throw "Refusing conflicting proxy native destination '$destinationPath'."
        }
    } else {
        $destinationDirectory = Split-Path -Parent $destinationPath
        [IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
        $temporaryPath = Join-Path $destinationDirectory (
            '.threadsmod-proxy-native-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::Copy($sourcePath, $temporaryPath, $false)
            if ((Get-PatchletSha256 -Path $temporaryPath) -ne $expectedSha256) {
                throw 'Proxy native temporary copy failed its pinned hash check.'
            }
            [IO.File]::Move($temporaryPath, $destinationPath)
        } finally {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
        if ((Get-PatchletSha256 -Path $destinationPath) -ne $expectedSha256) {
            throw 'Installed proxy native library failed its final pinned hash check.'
        }
        $action = 'applied'
    }

    return @([pscustomobject]@{
        id = 'install-socks5-native-library'
        path = $decodedArchivePath
        action = $action
        state = 'applied'
        sha256 = $expectedSha256
        ownerPatchlet = '080-socks5-proxy'
    })
}

function Install-PatchletProxyLicenseAsset {
    param(
        [Parameter(Mandatory)]$Resolution,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$DecodedRoot
    )

    $proxyProperty = $Resolution.PSObject.Properties['proxy']
    if ($null -eq $proxyProperty) { return @() }
    if (@($Resolution.patchlets | Where-Object {
                [string]$_ -eq '080-socks5-proxy'
            }).Count -ne 1) {
        throw 'A proxy license asset requires exactly one 080-socks5-proxy resolution entry.'
    }

    $license = $proxyProperty.Value.licenseAsset
    $patchletsRoot = Join-Path $RepositoryRoot 'patchlets'
    $sourcePath = Resolve-PatchletChildPath `
        -Root $patchletsRoot -Child ([string]$license.assetPath)
    $destinationPath = Resolve-PatchletChildPath `
        -Root $DecodedRoot -Child ([string]$license.decodedPath)
    $expectedSha256 = ([string]$license.sha256).ToLowerInvariant()
    $decodedArchivePath = ([string]$license.decodedPath).Replace('\', '/')
    $declaredArchivePath = ([string]$license.apkPath).Replace('\', '/')
    if ($decodedArchivePath -ne $declaredArchivePath) {
        throw 'Proxy license decodedPath and apkPath must identify the same APK entry.'
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Pinned proxy license asset does not exist: $sourcePath"
    }
    if ((Get-PatchletSha256 -Path $sourcePath) -ne $expectedSha256) {
        throw 'Proxy license asset hash differs from the exact resolution.'
    }

    $action = 'no-op'
    if (Test-Path -LiteralPath $destinationPath) {
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf) `
                -or (Get-PatchletSha256 -Path $destinationPath) -ne $expectedSha256) {
            throw "Refusing conflicting proxy license destination '$destinationPath'."
        }
    } else {
        $destinationDirectory = Split-Path -Parent $destinationPath
        [IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
        $temporaryPath = Join-Path $destinationDirectory (
            '.threadsmod-proxy-license-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::Copy($sourcePath, $temporaryPath, $false)
            if ((Get-PatchletSha256 -Path $temporaryPath) -ne $expectedSha256) {
                throw 'Proxy license temporary copy failed its pinned hash check.'
            }
            [IO.File]::Move($temporaryPath, $destinationPath)
        } finally {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
        if ((Get-PatchletSha256 -Path $destinationPath) -ne $expectedSha256) {
            throw 'Installed proxy license failed its final pinned hash check.'
        }
        $action = 'applied'
    }

    return @([pscustomobject]@{
        id = 'install-socks5-license-notice'
        path = $decodedArchivePath
        action = $action
        state = 'applied'
        sha256 = $expectedSha256
        ownerPatchlet = '080-socks5-proxy'
    })
}

$resolutionPathFull = [IO.Path]::GetFullPath($ResolutionPath)
$resolutionDirectory = Split-Path -Parent $resolutionPathFull
$decodedRootFull = [IO.Path]::GetFullPath($DecodedRoot)
$repositoryRoot = Get-PatchletRepositoryRoot
$resolution = Read-PatchletJson -Path $resolutionPathFull

$binding = Test-PatchletSourceBinding -Resolution $resolution -SourceApk $SourceApk
$assets = @(Test-PatchletAssets -Resolution $resolution -RepositoryRoot $repositoryRoot)
$proofs = @(Test-PatchletProofs -Resolution $resolution -DecodedRoot $decodedRootFull)

$identitySet = Resolve-PatchletChildPath -Root $resolutionDirectory -Child 'identity-rewrites.json'
$settingsSet = Resolve-PatchletChildPath -Root $resolutionDirectory -Child 'settings-manifest-rewrites.json'
$drawerSettingsSet = Resolve-PatchletChildPath -Root $resolutionDirectory -Child 'drawer-settings-rewrites.json'
$hookSet = Resolve-PatchletChildPath -Root $resolutionDirectory -Child 'hook-rewrites.json'
$inlineSet = Resolve-PatchletChildPath -Root $resolutionDirectory -Child 'inline-control-rewrites.json'
$updateProperty = $resolution.PSObject.Properties['update']
$updateSet = if ($null -eq $updateProperty) {
    $null
} else {
    if ([string]$updateProperty.Value.rewriteSet -ne 'update-manifest-rewrites.json') {
        throw 'The update resolution must use update-manifest-rewrites.json.'
    }
    if (@($resolution.patchlets | Where-Object {
                [string]$_ -eq '085-in-app-update'
            }).Count -ne 1) {
        throw 'An update resolution requires exactly one 085-in-app-update entry.'
    }
    if (@($resolution.rewriteSets | Where-Object {
                [string]$_ -eq 'update-manifest-rewrites.json'
            }).Count -ne 1) {
        throw 'The update rewrite set must occur exactly once in resolution.rewriteSets.'
    }
    Resolve-PatchletChildPath `
        -Root $resolutionDirectory -Child ([string]$updateProperty.Value.rewriteSet)
}
$proxyProperty = $resolution.PSObject.Properties['proxy']
$proxySet = if ($null -eq $proxyProperty) {
    $null
} else {
    if ([string]$proxyProperty.Value.rewriteSet -ne 'proxy-manifest-rewrites.json') {
        throw 'The proxy resolution must use proxy-manifest-rewrites.json.'
    }
    if (@($resolution.rewriteSets | Where-Object {
                [string]$_ -eq 'proxy-manifest-rewrites.json'
            }).Count -ne 1) {
        throw 'The proxy rewrite set must occur exactly once in resolution.rewriteSets.'
    }
    Resolve-PatchletChildPath `
        -Root $resolutionDirectory -Child ([string]$proxyProperty.Value.rewriteSet)
}
$identity = @(Apply-PatchletRewriteSet -RewriteSetPath $identitySet -DecodedRoot $decodedRootFull)
$settings = @(Apply-PatchletRewriteSet -RewriteSetPath $settingsSet -DecodedRoot $decodedRootFull)

$injection = & (Join-Path $PSScriptRoot 'Build-JavaInjection.ps1') `
    -DecodedRoot $decodedRootFull `
    -ScratchRoot $ScratchRoot `
    -ResolutionPath $resolutionPathFull `
    -AndroidSdk $AndroidSdk `
    -BuildToolsVersion $BuildToolsVersion `
    -Java $Java `
    -Javac $Javac `
    -Jar $Jar

$hooks = @(Apply-PatchletRewriteSet -RewriteSetPath $hookSet -DecodedRoot $decodedRootFull)
$drawerSettings = @(Apply-PatchletRewriteSet -RewriteSetPath $drawerSettingsSet -DecodedRoot $decodedRootFull)
$inline = @(Apply-PatchletRewriteSet -RewriteSetPath $inlineSet -DecodedRoot $decodedRootFull)
$proxyManifest = @(
    if ($null -ne $proxySet) {
        Apply-PatchletRewriteSet -RewriteSetPath $proxySet -DecodedRoot $decodedRootFull
    }
)
$proxyNative = @(Install-PatchletProxyNativeLibrary `
    -Resolution $resolution -RepositoryRoot $repositoryRoot -DecodedRoot $decodedRootFull)
$proxyLicense = @(Install-PatchletProxyLicenseAsset `
    -Resolution $resolution -RepositoryRoot $repositoryRoot -DecodedRoot $decodedRootFull)
$update = @(
    if ($null -ne $updateSet) {
        Apply-PatchletRewriteSet -RewriteSetPath $updateSet -DecodedRoot $decodedRootFull
    }
)
$postIdentity = @(Test-PatchletRewriteSet -RewriteSetPath $identitySet -DecodedRoot $decodedRootFull)
$postSettings = @(Test-PatchletRewriteSet -RewriteSetPath $settingsSet -DecodedRoot $decodedRootFull)
$postHooks = @(Test-PatchletRewriteSet -RewriteSetPath $hookSet -DecodedRoot $decodedRootFull)
$postDrawerSettings = @(Test-PatchletRewriteSet -RewriteSetPath $drawerSettingsSet -DecodedRoot $decodedRootFull)
$postInline = @(Test-PatchletRewriteSet -RewriteSetPath $inlineSet -DecodedRoot $decodedRootFull)
$postProxyManifest = @(
    if ($null -ne $proxySet) {
        Test-PatchletRewriteSet -RewriteSetPath $proxySet -DecodedRoot $decodedRootFull
    }
)
$postUpdate = @(
    if ($null -ne $updateSet) {
        Test-PatchletRewriteSet -RewriteSetPath $updateSet -DecodedRoot $decodedRootFull
    }
)
if (@($postIdentity | Where-Object state -ne 'applied').Count -ne 0) { throw 'Identity rewrite postcondition failed.' }
if (@($postSettings | Where-Object state -ne 'applied').Count -ne 0) { throw 'Settings UI manifest rewrite postcondition failed.' }
if (@($postHooks | Where-Object state -ne 'applied').Count -ne 0) { throw 'Lifecycle rewrite postcondition failed.' }
if (@($postDrawerSettings | Where-Object state -ne 'applied').Count -ne 0) { throw 'Drawer settings rewrite postcondition failed.' }
if (@($postInline | Where-Object state -ne 'applied').Count -ne 0) { throw 'Inline-control rewrite postcondition failed.' }
if (@($postProxyManifest | Where-Object state -ne 'applied').Count -ne 0) { throw 'Proxy manifest/bootstrap rewrite postcondition failed.' }
if (@($postUpdate | Where-Object state -ne 'applied').Count -ne 0) { throw 'Update manifest/version rewrite postcondition failed.' }

$ledger = [ordered]@{
    schemaVersion = 1
    appliedAt = (Get-Date).ToString('o')
    resolutionId = [string]$resolution.resolutionId
    source = $binding
    assets = $assets
    semanticProofs = $proofs
    identity = [ordered]@{
        total = $identity.Count
        applied = @($identity | Where-Object action -eq 'applied').Count
        noOp = @($identity | Where-Object action -eq 'no-op').Count
        rules = $identity
    }
    settingsUi = [ordered]@{
        total = $settings.Count
        applied = @($settings | Where-Object action -eq 'applied').Count
        noOp = @($settings | Where-Object action -eq 'no-op').Count
        rules = $settings
    }
    injection = $injection
    hooks = [ordered]@{
        total = $hooks.Count
        applied = @($hooks | Where-Object action -eq 'applied').Count
        noOp = @($hooks | Where-Object action -eq 'no-op').Count
        rules = $hooks
    }
    drawerSettings = [ordered]@{
        total = $drawerSettings.Count
        applied = @($drawerSettings | Where-Object action -eq 'applied').Count
        noOp = @($drawerSettings | Where-Object action -eq 'no-op').Count
        rules = $drawerSettings
    }
    inlineControls = [ordered]@{
        total = $inline.Count
        applied = @($inline | Where-Object action -eq 'applied').Count
        noOp = @($inline | Where-Object action -eq 'no-op').Count
        rules = $inline
    }
    proxyManifest = [ordered]@{
        total = $proxyManifest.Count
        applied = @($proxyManifest | Where-Object action -eq 'applied').Count
        noOp = @($proxyManifest | Where-Object action -eq 'no-op').Count
        rules = $proxyManifest
    }
    proxyNative = [ordered]@{
        total = $proxyNative.Count
        applied = @($proxyNative | Where-Object action -eq 'applied').Count
        noOp = @($proxyNative | Where-Object action -eq 'no-op').Count
        files = $proxyNative
    }
    proxyLicense = [ordered]@{
        total = $proxyLicense.Count
        applied = @($proxyLicense | Where-Object action -eq 'applied').Count
        noOp = @($proxyLicense | Where-Object action -eq 'no-op').Count
        files = $proxyLicense
    }
    update = [ordered]@{
        total = $update.Count
        applied = @($update | Where-Object action -eq 'applied').Count
        noOp = @($update | Where-Object action -eq 'no-op').Count
        rules = $update
    }
    status = 'passed'
}

if ($LedgerPath) {
    Write-PatchletJson -Value $ledger -Path ([IO.Path]::GetFullPath($LedgerPath))
}
[pscustomobject]$ledger
