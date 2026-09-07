[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Apk,
    [Parameter(Mandatory)][string]$ScratchRoot,
    [Parameter(Mandatory)][string]$DeviceSerial,
    [Parameter(Mandatory)][string]$KeyStore,
    [Parameter(Mandatory)][string]$KeyAlias,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [ValidateSet('Release', 'SignedReview')][string]$ValidationMode = 'Release',
    [string]$KeyStorePasswordEnvironment = 'THREADSMOD_KS_PASS',
    [string]$KeyPasswordEnvironment = 'THREADSMOD_KEY_PASS',
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$BuildToolsVersion = '36.0.0',
    [string]$Java = 'java',
    [string]$SevenZip = 'C:\Program Files\7-Zip\7z.exe',
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

function Invoke-ActivityProbeCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $lines = @(& $Command @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        $lines | ForEach-Object { Write-Host $_ }
        throw "Activity UI probe command failed with exit code ${exitCode}: $Command"
    }
    return [pscustomobject]@{
        exitCode = $exitCode
        lines = $lines
        text = $lines -join "`n"
    }
}

function Get-ExactPrimaryDex {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Destination
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entries = @($archive.Entries | Where-Object {
                $_.FullName.Equals('classes.dex', [StringComparison]::Ordinal)
            })
        if ($entries.Count -ne 1) {
            throw "Candidate must contain exactly one canonical root classes.dex entry; observed $($entries.Count)."
        }
        $input = $entries[0].Open()
        $output = [IO.File]::Open(
            $Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $input.CopyTo($output) } finally {
            $output.Dispose()
            $input.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
    return Get-PatchletSha256 -Path $Destination
}

function ConvertFrom-ActivityUiBounds {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -notmatch '^\[(?<left>-?\d+),(?<top>-?\d+)\]\[(?<right>-?\d+),(?<bottom>-?\d+)\]$') {
        return $null
    }
    try {
        return [pscustomobject]@{
            left = [long]$Matches.left
            top = [long]$Matches.top
            right = [long]$Matches.right
            bottom = [long]$Matches.bottom
        }
    } catch {
        return $null
    }
}

function Test-VisibleUiRequirements {
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string]$XmlText,
        [Parameter(Mandatory)][string[]]$RequiredExactText,
        [string[]]$RequiredOrderedLinePrefix = @()
    )
    if ($XmlText.Length -eq 0 -or $XmlText.Length -gt 1048576) {
        throw "Probe Activity '$Activity' returned an empty or oversized UI hierarchy."
    }
    $stringReader = $null
    $xmlReader = $null
    try {
        $xmlSettings = [Xml.XmlReaderSettings]::new()
        $xmlSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $xmlSettings.XmlResolver = $null
        $xmlSettings.MaxCharactersInDocument = 1048576L
        $xmlSettings.MaxCharactersFromEntities = 0L
        $stringReader = [IO.StringReader]::new($XmlText)
        $xmlReader = [Xml.XmlReader]::Create($stringReader, $xmlSettings)
        $uiDocument = [Xml.XmlDocument]::new()
        $uiDocument.XmlResolver = $null
        $uiDocument.Load($xmlReader)
    } catch {
        throw "Probe Activity '$Activity' returned an invalid UI hierarchy."
    } finally {
        if ($null -ne $xmlReader) { $xmlReader.Dispose() }
        if ($null -ne $stringReader) { $stringReader.Dispose() }
    }
    $nodes = @($uiDocument.SelectNodes('//node'))
    if ($nodes.Count -eq 0) {
        throw "Probe Activity '$Activity' returned a UI hierarchy without nodes."
    }
    $viewport = ConvertFrom-ActivityUiBounds `
        -Value ([string]$nodes[0].GetAttribute('bounds'))
    if ($null -eq $viewport `
            -or $viewport.right -le $viewport.left `
            -or $viewport.bottom -le $viewport.top) {
        throw "Probe Activity '$Activity' returned an invalid UI viewport."
    }
    $visibleNodeText = @()
    foreach ($node in $nodes) {
        $bounds = ConvertFrom-ActivityUiBounds `
            -Value ([string]$node.GetAttribute('bounds'))
        if ($null -eq $bounds `
                -or $bounds.right -le $bounds.left `
                -or $bounds.bottom -le $bounds.top `
                -or $bounds.right -le $viewport.left `
                -or $bounds.bottom -le $viewport.top `
                -or $bounds.left -ge $viewport.right `
                -or $bounds.top -ge $viewport.bottom) {
            continue
        }
        $visibleNodeText += [string]$node.GetAttribute('text')
    }
    foreach ($required in $RequiredExactText) {
        if (-not @($visibleNodeText | Where-Object {
                    $_.Equals($required, [StringComparison]::Ordinal)
                }).Count) {
            throw "Probe Activity '$Activity' is missing exact visible UI text '$required'."
        }
    }
    if ($RequiredOrderedLinePrefix.Count -gt 0) {
        $orderedPrefixesFound = $false
        foreach ($nodeText in $visibleNodeText) {
            $lines = @($nodeText -split '\r?\n')
            for ($start = 0; $start -le $lines.Count - $RequiredOrderedLinePrefix.Count; $start++) {
                $sequenceMatches = $true
                for ($offset = 0; $offset -lt $RequiredOrderedLinePrefix.Count; $offset++) {
                    $required = [string]$RequiredOrderedLinePrefix[$offset]
                    $line = [string]$lines[$start + $offset]
                    if (-not $line.StartsWith(
                            $required + ' ', [StringComparison]::Ordinal) `
                            -or $line.Substring($required.Length).Trim().Length -eq 0) {
                        $sequenceMatches = $false
                        break
                    }
                }
                if ($sequenceMatches) {
                    $orderedPrefixesFound = $true
                    break
                }
            }
            if ($orderedPrefixesFound) { break }
        }
        if (-not $orderedPrefixesFound) {
            throw "Probe Activity '$Activity' is missing its ordered visible UI status lines."
        }
    }
}

function Assert-ActivityUiMatcherRejects {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$XmlText,
        [Parameter(Mandatory)][string[]]$RequiredExactText,
        [Parameter(Mandatory)][string[]]$RequiredOrderedLinePrefix
    )
    $rejected = $false
    try {
        Test-VisibleUiRequirements `
            -Activity "fixture-$Label" `
            -XmlText $XmlText `
            -RequiredExactText $RequiredExactText `
            -RequiredOrderedLinePrefix $RequiredOrderedLinePrefix
    } catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "Activity UI matcher bypass fixture passed unexpectedly: $Label"
    }
}

function Test-ActivityUiMatcherContract {
    $exact = @('Current status')
    $prefixes = @(
        'List fetch:', 'Records:', 'New this refresh:',
        'Database index:', 'Inline control:')
    $rootStart = '<hierarchy><node text="" bounds="[0,0][100,140]">'
    $rootEnd = '</node></hierarchy>'
    $positive = $rootStart `
        + '<node text="Current status" bounds="[0,0][100,20]"/>' `
        + '<node text="Disabled&#10;&#10;List fetch: Waiting for first verified refresh' `
        + '&#10;Records: 2&#10;New this refresh: 1&#10;Database index: Ready' `
        + '&#10;Inline control: observed" bounds="[0,20][100,140]"/>' `
        + $rootEnd
    Test-VisibleUiRequirements `
        -Activity 'fixture-positive' `
        -XmlText $positive `
        -RequiredExactText $exact `
        -RequiredOrderedLinePrefix $prefixes

    $negativeFixtures = [ordered]@{
        'content-description-only' = $rootStart `
            + '<node text="" content-desc="Current status" bounds="[0,0][100,20]"/>' `
            + '<node text="List fetch: Ready&#10;Records: 2&#10;New this refresh: 1&#10;Database index: Ready&#10;Inline control: observed" bounds="[0,20][100,140]"/>' `
            + $rootEnd
        'mid-line-prefix' = $rootStart `
            + '<node text="Current status" bounds="[0,0][100,20]"/>' `
            + '<node text="prefix List fetch: Ready&#10;Records: 2&#10;New this refresh: 1&#10;Database index: Ready&#10;Inline control: observed" bounds="[0,20][100,140]"/>' `
            + $rootEnd
        'wrong-prefix-order' = $rootStart `
            + '<node text="Current status" bounds="[0,0][100,20]"/>' `
            + '<node text="Records: 2&#10;List fetch: Ready&#10;New this refresh: 1&#10;Database index: Ready&#10;Inline control: observed" bounds="[0,20][100,140]"/>' `
            + $rootEnd
        'missing-prefix' = $rootStart `
            + '<node text="Current status" bounds="[0,0][100,20]"/>' `
            + '<node text="List fetch: Ready&#10;Records: 2&#10;New this refresh: 1&#10;Inline control: observed" bounds="[0,20][100,140]"/>' `
            + $rootEnd
        'malformed-xml' = '<hierarchy><node text="Current status"'
        'zero-bounds' = $rootStart `
            + '<node text="Current status" bounds="[0,0][100,20]"/>' `
            + '<node text="List fetch: Ready&#10;Records: 2&#10;New this refresh: 1&#10;Database index: Ready&#10;Inline control: observed" bounds="[10,10][10,140]"/>' `
            + $rootEnd
        'offscreen-bounds' = $rootStart `
            + '<node text="Current status" bounds="[0,0][100,20]"/>' `
            + '<node text="List fetch: Ready&#10;Records: 2&#10;New this refresh: 1&#10;Database index: Ready&#10;Inline control: observed" bounds="[200,200][300,340]"/>' `
            + $rootEnd
        'empty-status-value' = $rootStart `
            + '<node text="Current status" bounds="[0,0][100,20]"/>' `
            + '<node text="List fetch: &#10;Records: 2&#10;New this refresh: 1&#10;Database index: Ready&#10;Inline control: observed" bounds="[0,20][100,140]"/>' `
            + $rootEnd
        'split-status-nodes' = $rootStart `
            + '<node text="Current status" bounds="[0,0][100,20]"/>' `
            + '<node text="List fetch: Ready" bounds="[0,20][100,40]"/>' `
            + '<node text="Records: 2" bounds="[0,40][100,60]"/>' `
            + '<node text="New this refresh: 1" bounds="[0,60][100,80]"/>' `
            + '<node text="Database index: Ready" bounds="[0,80][100,100]"/>' `
            + '<node text="Inline control: observed" bounds="[0,100][100,120]"/>' `
            + $rootEnd
    }
    if ($negativeFixtures.Count -ne 9) {
        throw 'Activity UI matcher negative fixture count drifted.'
    }
    foreach ($fixture in $negativeFixtures.GetEnumerator()) {
        Assert-ActivityUiMatcherRejects `
            -Label ([string]$fixture.Key) `
            -XmlText ([string]$fixture.Value) `
            -RequiredExactText $exact `
            -RequiredOrderedLinePrefix $prefixes
    }
    return [pscustomobject]@{
        positiveFixtures = 1
        negativeFixtures = $negativeFixtures.Count
        exactVisibleNodeText = $true
        orderedMultilineStatus = $true
        nonZeroBounds = $true
        viewportIntersection = $true
        nonEmptyStatusValues = $true
    }
}

function Test-ProbeActivity {
    param(
        [Parameter(Mandatory)][string]$Adb,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string[]]$RequiredExactText,
        [string[]]$RequiredOrderedLinePrefix = @(),
        [Parameter(Mandatory)][string]$RemoteDump
    )
    $component = "$Package/$Activity"
    $null = Invoke-ActivityProbeCommand -Command $Adb -Arguments @(
        '-s', $Serial, 'shell', 'am', 'force-stop', $Package)
    $null = Invoke-ActivityProbeCommand -Command $Adb -Arguments @(
        '-s', $Serial, 'logcat', '-c')
    $start = Invoke-ActivityProbeCommand -Command $Adb -Arguments @(
        '-s', $Serial, 'shell', 'am', 'start', '-W', '-n', $component)
    Start-Sleep -Milliseconds 1500
    $activities = Invoke-ActivityProbeCommand -Command $Adb -Arguments @(
        '-s', $Serial, 'shell', 'dumpsys', 'activity', 'activities')
    if (-not $activities.text.Contains($component, [StringComparison]::Ordinal)) {
        throw "Probe Activity did not remain present/resumed after launch: $component"
    }
    $dump = Invoke-ActivityProbeCommand -Command $Adb -Arguments @(
        '-s', $Serial, 'shell', 'uiautomator', 'dump', $RemoteDump)
    $xml = Invoke-ActivityProbeCommand -Command $Adb -Arguments @(
        '-s', $Serial, 'exec-out', 'cat', $RemoteDump)
    Test-VisibleUiRequirements `
        -Activity $Activity `
        -XmlText $xml.text `
        -RequiredExactText $RequiredExactText `
        -RequiredOrderedLinePrefix $RequiredOrderedLinePrefix
    $crash = Invoke-ActivityProbeCommand -Command $Adb -Arguments @(
        '-s', $Serial, 'logcat', '-d', '-b', 'crash', '-v', 'threadtime')
    if ($crash.text.Contains('FATAL EXCEPTION', [StringComparison]::Ordinal) `
            -or $crash.text.Contains(('Process: ' + $Package), [StringComparison]::Ordinal)) {
        throw "Probe Activity crashed: $Activity`n$($crash.text)"
    }
    return [pscustomobject]@{
        component = $component
        start = $start.text
        resumedEvidence = @($activities.lines | Where-Object {
                $_.Contains($component, [StringComparison]::Ordinal)
            } | Select-Object -First 8)
        uiDumpCommand = $dump.text
        visibleExactText = $RequiredExactText
        visibleOrderedLinePrefixes = $RequiredOrderedLinePrefix
        uiXml = $xml.text
        crashLog = $crash.text
        status = 'passed'
    }
}

$repositoryRoot = Get-PatchletRepositoryRoot
$workRoot = Join-Path $repositoryRoot 'work'
$apkFull = [IO.Path]::GetFullPath($Apk)
$scratchFull = Assert-PatchletPathUnderRoot `
    -Path ([IO.Path]::GetFullPath($ScratchRoot)) -Root $workRoot
$resolutionFull = [IO.Path]::GetFullPath($ResolutionPath)
$manifestSource = Join-Path $repositoryRoot `
    'patchlets\assets\release-gates\activity-ui-probe\AndroidManifest.xml'
$probeTool = [IO.Path]::GetFullPath($PSCommandPath)
$package = 'com.threadsmod.activityprobe'
$remoteDump = '/sdcard/threadsmod-activity-ui-probe.xml'
$installed = $false
$candidateLock = $null

if ($DeviceSerial -notmatch '^[A-Za-z0-9._:-]+$') {
    throw 'DeviceSerial contains unsupported characters.'
}
if (Test-Path -LiteralPath $scratchFull) {
    throw "ScratchRoot must be fresh: $scratchFull"
}
foreach ($path in @($apkFull, $resolutionFull, $manifestSource, $probeTool, $KeyStore, $SevenZip)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required Activity UI probe input does not exist: $path"
    }
}
if (-not [Environment]::GetEnvironmentVariable($KeyStorePasswordEnvironment) `
        -or -not [Environment]::GetEnvironmentVariable($KeyPasswordEnvironment)) {
    throw 'Activity UI probe signing password environment variables are not both set.'
}

$resolution = Read-PatchletJson -Path $resolutionFull
$expectedResolutionStatus = if ($ValidationMode -ceq 'SignedReview') {
    'review-required'
} else {
    'verified-current'
}
$expectedUpdateSignedDexReviewRequired = $ValidationMode -ceq 'SignedReview'
if ([string]$resolution.status -cne $expectedResolutionStatus `
        -or $resolution.release.updateSignedDexReviewRequired `
            -ne $expectedUpdateSignedDexReviewRequired) {
    throw "Activity UI probe state does not match ValidationMode '$ValidationMode'."
}
if ($BuildToolsVersion -ne [string]$resolution.toolchain.buildToolsVersion) {
    throw 'Activity UI probe Build Tools version differs from the exact resolution.'
}
if ((Get-PatchletSha256 -Path $probeTool) `
        -ne [string]$resolution.assets.activityUiEmulatorTestSourceSha256 `
        -or (Get-PatchletSha256 -Path $manifestSource) `
        -ne [string]$resolution.assets.activityUiProbeManifestSha256) {
    throw 'Activity UI probe tool or manifest hash differs from the exact resolution.'
}
$matcherFixtureEvidence = Test-ActivityUiMatcherContract

$buildTools = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion"
$aapt2 = Join-Path $buildTools 'aapt2.exe'
$zipalign = Join-Path $buildTools 'zipalign.exe'
$apksignerJar = Join-Path $buildTools 'lib\apksigner.jar'
$androidJar = Join-Path $AndroidSdk "platforms\android-$($resolution.toolchain.androidPlatform)\android.jar"
$adb = Join-Path $AndroidSdk 'platform-tools\adb.exe'
foreach ($path in @($aapt2, $zipalign, $apksignerJar, $androidJar, $adb)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required Android Activity UI probe tool does not exist: $path"
    }
}
if ((Get-PatchletSha256 -Path $apksignerJar) `
        -ne [string]$resolution.toolchain.apksignerJarSha256) {
    throw 'Activity UI probe apksigner differs from the exact resolution.'
}

[IO.Directory]::CreateDirectory($scratchFull) | Out-Null
$manifest = Join-Path $scratchFull 'AndroidManifest.xml'
$classesDex = Join-Path $scratchFull 'classes.dex'
$baseApk = Join-Path $scratchFull 'base.apk'
$alignedApk = Join-Path $scratchFull 'aligned.apk'
$probeApk = Join-Path $scratchFull 'activity-ui-probe.apk'
Copy-Item -LiteralPath $manifestSource -Destination $manifest

try {
    $candidateSha256 = Get-PatchletSha256 -Path $apkFull
    $candidateLock = [IO.File]::Open(
        $apkFull, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $primaryDexSha256 = Get-ExactPrimaryDex -ArchivePath $apkFull -Destination $classesDex

    $device = Invoke-ActivityProbeCommand -Command $adb -Arguments @(
        '-s', $DeviceSerial, 'get-state')
    if ($device.text.Trim() -ne 'device') {
        throw "Android device is not ready: $DeviceSerial"
    }
    $api = (Invoke-ActivityProbeCommand -Command $adb -Arguments @(
            '-s', $DeviceSerial, 'shell', 'getprop', 'ro.build.version.sdk')).text.Trim()
    $abi = (Invoke-ActivityProbeCommand -Command $adb -Arguments @(
            '-s', $DeviceSerial, 'shell', 'getprop', 'ro.product.cpu.abi')).text.Trim()
    $fingerprint = (Invoke-ActivityProbeCommand -Command $adb -Arguments @(
            '-s', $DeviceSerial, 'shell', 'getprop', 'ro.build.fingerprint')).text.Trim()
    if ($api -notmatch '^\d+$' -or [int]$api -lt [int]$resolution.source.minSdk) {
        throw "Android device API is below the candidate minimum SDK: $api"
    }

    $null = Invoke-ActivityProbeCommand -Command $aapt2 -Arguments @(
        'link', '-o', $baseApk, '--manifest', $manifest, '-I', $androidJar)
    Push-Location $scratchFull
    try {
        $null = Invoke-ActivityProbeCommand -Command $SevenZip -Arguments @(
            'a', '-tzip', 'base.apk', 'classes.dex')
    } finally { Pop-Location }
    $null = Invoke-ActivityProbeCommand -Command $zipalign -Arguments @(
        '-P', '16', '-f', '4', $baseApk, $alignedApk)
    $null = Invoke-ActivityProbeCommand -Command $Java -Arguments @(
        '-jar', $apksignerJar, 'sign',
        '--ks', ([IO.Path]::GetFullPath($KeyStore)),
        '--ks-key-alias', $KeyAlias,
        '--ks-pass', "env:$KeyStorePasswordEnvironment",
        '--key-pass', "env:$KeyPasswordEnvironment",
        '--v1-signing-enabled', 'false',
        '--v2-signing-enabled', 'true',
        '--v3-signing-enabled', 'false',
        '--v4-signing-enabled', 'false',
        '--out', $probeApk,
        $alignedApk)
    $null = Invoke-ActivityProbeCommand -Command $Java -Arguments @(
        '-jar', $apksignerJar, 'verify', '-Werr', '--verbose', $probeApk)
    $null = Invoke-ActivityProbeCommand -Command $zipalign -Arguments @(
        '-c', '-P', '16', '4', $probeApk)

    $probeDex = Join-Path $scratchFull 'probe-classes.dex'
    $probeDexSha256 = Get-ExactPrimaryDex -ArchivePath $probeApk -Destination $probeDex
    if ($probeDexSha256 -ne $primaryDexSha256) {
        throw 'Activity probe primary DEX does not exactly equal the candidate primary DEX.'
    }

    $null = Invoke-ActivityProbeCommand -Command $adb -Arguments @(
        '-s', $DeviceSerial, 'uninstall', $package) -AllowFailure
    $install = Invoke-ActivityProbeCommand -Command $adb -Arguments @(
        '-s', $DeviceSerial, 'install', '-r', $probeApk)
    $installed = $true
    if (-not $install.text.Contains('Success', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Activity UI probe package installation did not report success.'
    }
    $null = Invoke-ActivityProbeCommand -Command $adb -Arguments @(
        '-s', $DeviceSerial, 'shell', 'pm', 'clear', $package)

    $activityResult = Test-ProbeActivity `
        -Adb $adb -Serial $DeviceSerial -Package $package `
        -Activity 'com.threadsmod.CloneBlockerActivity' `
        -RequiredExactText @(
            'Activity', 'Refresh', 'Settings', 'Current status') `
        -RequiredOrderedLinePrefix @(
            'List fetch:', 'Records:', 'New this refresh:',
            'Database index:', 'Inline control:') `
        -RemoteDump $remoteDump
    $settingsResult = Test-ProbeActivity `
        -Adb $adb -Serial $DeviceSerial -Package $package `
        -Activity 'com.threadsmod.CloneBlockerSettingsActivity' `
        -RequiredExactText @(
            'Settings', 'Activity', 'Current status', 'Sync now') `
        -RequiredOrderedLinePrefix @(
            'List fetch:', 'Records:', 'New this refresh:',
            'Database index:', 'Inline control:') `
        -RemoteDump $remoteDump
    $proxySettingsResult = Test-ProbeActivity `
        -Adb $adb -Serial $DeviceSerial -Package $package `
        -Activity 'com.threadsmod.ProxySettingsActivity' `
        -RequiredExactText @(
            'SOCKS5 proxy', 'Proxy status', 'Route this app through SOCKS5') `
        -RemoteDump $remoteDump

    if ((Get-PatchletSha256 -Path $apkFull) -ne $candidateSha256) {
        throw 'Candidate APK changed during the Activity UI probe.'
    }
    $report = [ordered]@{
        schemaVersion = 1
        checkedAt = (Get-Date).ToString('o')
        status = 'passed'
        validationMode = $ValidationMode
        reviewOnly = $ValidationMode -ceq 'SignedReview'
        releaseEligible = $ValidationMode -ceq 'Release'
        candidate = [ordered]@{
            path = $apkFull
            sha256 = $candidateSha256
            primaryDexSha256 = $primaryDexSha256
        }
        probe = [ordered]@{
            package = $package
            apkSha256 = Get-PatchletSha256 -Path $probeApk
            primaryDexSha256 = $probeDexSha256
            exactCandidatePrimaryDex = $true
            manifestSha256 = Get-PatchletSha256 -Path $manifestSource
            permissions = @()
            matcherFixtures = $matcherFixtureEvidence
        }
        device = [ordered]@{
            serial = $DeviceSerial
            api = [int]$api
            abi = $abi
            fingerprint = $fingerprint
        }
        activities = @($activityResult, $settingsResult, $proxySettingsResult)
        networkOrAccountActionAttempted = $false
    }
    if ($ReportPath) {
        Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath))
    }
    [pscustomobject]$report
} finally {
    if ($null -ne $candidateLock) { $candidateLock.Dispose() }
    if ($installed) {
        $null = Invoke-ActivityProbeCommand -Command $adb -Arguments @(
            '-s', $DeviceSerial, 'uninstall', $package) -AllowFailure
    }
    $null = Invoke-ActivityProbeCommand -Command $adb -Arguments @(
        '-s', $DeviceSerial, 'shell', 'rm', '-f', $remoteDump) -AllowFailure
}
