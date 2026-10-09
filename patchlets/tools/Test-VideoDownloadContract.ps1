[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScratchRoot,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$Apk,
    [string]$SourceApk,
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$BuildToolsVersion = '36.0.0',
    [string]$Java = 'java',
    [string]$Javac = 'javac',
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

function Invoke-VideoGateNative {
    param([string]$Command, [string[]]$Arguments, [switch]$AllowFailure)
    $lines = @(& $Command @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) {
        $lines | ForEach-Object { Write-Host $_ }
        throw "Video contract command failed: $Command ($code)."
    }
    return [pscustomobject]@{ exitCode = $code; lines = $lines }
}

function Test-VideoSourceContract {
    param([Parameter(Mandatory)][Collections.IDictionary]$Texts)
    $required = [ordered]@{
        'VideoSaveRequest.java' = @('"https".equals(uri.getScheme())', 'uri.getRawUserInfo() != null',
            'uri.getRawFragment() != null', 'uri.getPort() != -1', 'host.endsWith(".cdninstagram.com")',
            'host.endsWith(".fbcdn.net")', 'hops > 3')
        'VideoTransfer.java' = @('MAX_BYTES = 268435456L', 'MAX_DURATION_MS = 180000L',
            'OWNER.compareAndSet(false, true)', 'connection.setInstanceFollowRedirects(false)',
            'connection.setRequestMethod("GET")', 'CookieHandler.getDefault() != null',
            'declared > MAX_BYTES', 'read > maximum - total', 'verifyMp4(cache)',
            'destination.open()', 'output.flush()', 'destination.discard()', 'cache.delete()')
        'VideoSaveController.java' = @('Looper.myLooper() != Looper.getMainLooper()',
            'new VideoSaveRequest(', 'new Intent(activity, VideoSaveActivity.class)')
        'VideoSaveActivity.java' = @('attachShell();', 'setContentView(scroll);',
            'Intent.ACTION_CREATE_DOCUMENT', 'Intent.CATEGORY_OPENABLE', 'intent.setType("video/mp4")',
            '"content".equals(destination.getScheme())', 'openFileDescriptor(', 'ParcelFileDescriptor.AutoCloseOutputStream',
            'VideoTransfer.save(', 'if (!main.post(', 'Video saved.', 'Choose location')
    }
    foreach ($file in $required.Keys) {
        if (-not $Texts.Contains($file)) { return $false }
        foreach ($literal in $required[$file]) {
            if (-not ([string]$Texts[$file]).Contains($literal, [StringComparison]::Ordinal)) { return $false }
        }
    }
    $all = $Texts.Values -join "`n"
    foreach ($forbidden in @('DownloadManager', 'Environment.getExternalStorage', 'MediaStore',
            'READ_MEDIA_VIDEO', 'WRITE_EXTERNAL_STORAGE', 'MANAGE_EXTERNAL_STORAGE',
            'setRequestProperty("Authorization"', 'setRequestProperty("Cookie"',
            'getDefaultSSLSocketFactory', 'setHostnameVerifier', 'ThreadsBlockBridge',
            'ReportController', 'getMessage()', 'printStackTrace(', 'setLayoutParams(null)',
            'Lcom/instagram/', 'LX/')) {
        if ($all.Contains($forbidden, [StringComparison]::Ordinal)) { return $false }
    }
    $activity = [string]$Texts['VideoSaveActivity.java']
    if ($activity.IndexOf('attachShell();', [StringComparison]::Ordinal) -ge
            $activity.IndexOf('getIntent()', [StringComparison]::Ordinal)) { return $false }
    return $true
}

function New-VideoDexArchive {
    param(
        [Parameter(Mandatory)][string]$Dex,
        [Parameter(Mandatory)][string]$Path,
        [string]$SecondaryDex,
        [ValidateSet('classes2.dex', 'assets/longtail/classes.dex')]
        [string]$SecondaryDexEntry = 'classes2.dex'
    )
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $dexEntries = [ordered]@{ 'classes.dex' = $Dex }
        if ($SecondaryDex) { $dexEntries[$SecondaryDexEntry] = $SecondaryDex }
        foreach ($name in $dexEntries.Keys) {
            $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::NoCompression)
            $output = $entry.Open()
            $input = [IO.File]::OpenRead([string]$dexEntries[$name])
            try { $input.CopyTo($output) } finally { $input.Dispose(); $output.Dispose() }
        }
    } finally { $archive.Dispose(); $stream.Dispose() }
}

$repositoryRoot = Get-PatchletRepositoryRoot
$scratchFull = Assert-PatchletPathUnderRoot -Path ([IO.Path]::GetFullPath($ScratchRoot)) -Root (Join-Path $repositoryRoot 'work')
if (Test-Path -LiteralPath $scratchFull) { throw "Video ScratchRoot must be fresh: $scratchFull" }
[IO.Directory]::CreateDirectory($scratchFull) | Out-Null
$resolutionFull = [IO.Path]::GetFullPath($ResolutionPath)
$resolution = Read-PatchletJson -Path $resolutionFull
if ($null -eq $resolution.PSObject.Properties['videoDownload']) { throw 'Video resolution section missing.' }
$sourceRoot = Join-Path $repositoryRoot 'patchlets\assets\autoblock\java\threadsmod\video'
$fixtureRoot = Join-Path $repositoryRoot 'patchlets\assets\release-gates\video-download'
$harness = Join-Path $repositoryRoot 'patchlets\assets\tests\VideoSaveHarness.java'
$inspectorSource = Join-Path $PSScriptRoot 'DexVideoDownloadInspector.java'
foreach ($check in @(
        @((Get-PatchletTreeSha256 -Root $sourceRoot -Filter '*.java'), [string]$resolution.assets.videoJavaTreeSha256),
        @((Get-PatchletTreeSha256 -Root $fixtureRoot -Filter '*'), [string]$resolution.assets.videoContractFixtureTreeSha256),
        @((Get-PatchletSha256 -Path $PSCommandPath), [string]$resolution.assets.videoContractTestSourceSha256),
        @((Get-PatchletSha256 -Path $inspectorSource), [string]$resolution.assets.videoDexInspectorSourceSha256))) {
    if ([string]$check[0] -cne [string]$check[1]) { throw 'Video canonical input hash differs from its exact resolution.' }
}
$texts = [ordered]@{}
Get-ChildItem -LiteralPath $sourceRoot -File -Filter '*.java' | ForEach-Object {
    $texts[$_.Name] = Get-NormalizedPatchletText -Path $_.FullName
}
if (-not (Test-VideoSourceContract -Texts $texts)) { throw 'Video canonical source contract failed.' }
$fixture = Read-PatchletJson -Path (Join-Path $fixtureRoot 'fixtures.json')
$sourceFixtureResults = @()
foreach ($negative in @($fixture.sourceNegatives)) {
    $changed = [ordered]@{}
    foreach ($name in $texts.Keys) { $changed[$name] = [string]$texts[$name] }
    $file = [string]$negative.file
    $before = [string]$negative.before
    if ((Get-PatchletLiteralCount -Text $changed[$file] -Literal $before) -ne [int]$negative.expectedCount) {
        throw "Video source fixture anchor drifted: $($negative.id)."
    }
    $changed[$file] = $changed[$file].Replace($before, [string]$negative.after)
    if (Test-VideoSourceContract -Texts $changed) { throw "Video source negative passed: $($negative.id)." }
    $sourceFixtureResults += [string]$negative.id
}
$classes = Join-Path $scratchFull 'host-classes'
[IO.Directory]::CreateDirectory($classes) | Out-Null
$null = Invoke-VideoGateNative -Command $Javac -Arguments @('-encoding', 'UTF-8', '-d', $classes,
    (Join-Path $sourceRoot 'VideoSaveRequest.java'), (Join-Path $sourceRoot 'VideoTransfer.java'), $harness)
$hostScratch = Join-Path $scratchFull 'host-fixture-cache'
[IO.Directory]::CreateDirectory($hostScratch) | Out-Null
$videoHarnessOutput = Invoke-VideoGateNative -Command $Java -Arguments @('-cp', $classes, 'threadsmod.video.VideoSaveHarness', $hostScratch)

$video = $resolution.videoDownload
if ([string]$resolution.source.versionName -cne '444.0.0.45.85' `
        -or [long]$video.maximumBytes -ne 268435456L `
        -or (@($video.allowedCdnHosts) -join "`n") -cne "cdninstagram.com`nfbcdn.net" `
        -or [string]$video.activity.name -cne 'threadsmod.video.VideoSaveActivity' `
        -or $video.activity.exported -ne $false `
        -or [string]$video.templateRoot -cne 'assets/versioned/444.0.0.45.85/video') {
    throw 'Video source digest/version, compiled bounds, host policy, Activity or template root drifted.'
}
$templateRoot = Resolve-PatchletTemplateRoot -PatchletsRoot (Join-Path $repositoryRoot 'patchlets') `
    -Section $video -DefaultRelativeRoot 'assets\video-download\templates' -Kind 'video'
$expectedTemplates = @('VideoMenuAdapter.smali.tmpl', 'VideoMenuClick.smali.tmpl')
if ((@($video.templateNames) -join "`n") -cne ($expectedTemplates -join "`n")) { throw 'Video template inventory drifted.' }
$actualTemplates = @(Get-ChildItem -LiteralPath $templateRoot -File -Filter '*.tmpl' | ForEach-Object Name | Sort-Object)
if (($actualTemplates -join "`n") -cne (($expectedTemplates | Sort-Object) -join "`n")) { throw 'Video template root has unowned files.' }
$renderRoot = Join-Path $scratchFull 'rendered-video'
[IO.Directory]::CreateDirectory($renderRoot) | Out-Null
$rendered = @(Expand-PatchletSmaliTemplates -Symbols $video.symbols -TemplateRoot $templateRoot `
    -DestinationRoot $renderRoot -TemplateNames $expectedTemplates -Owner 'video download')
$adapterText = Get-NormalizedPatchletText -Path (Join-Path $renderRoot 'VideoMenuAdapter.smali')
$clickText = Get-NormalizedPatchletText -Path (Join-Path $renderRoot 'VideoMenuClick.smali')
$privateCalls = [ordered]@{
    mediaVideoVersionsMethod = 'Lcom/instagram/feed/media/Media;->AAM()Ljava/util/List;'
    videoUrlMethod = 'Lcom/instagram/api/schemas/VideoVersionIntf;->getUrl()Ljava/lang/String;'
    videoHeightMethod = 'Lcom/instagram/api/schemas/VideoVersionIntf;->Bln()Ljava/lang/Integer;'
    videoWidthMethod = 'Lcom/instagram/api/schemas/VideoVersionIntf;->CyI()Ljava/lang/Integer;'
    nativeMenuRowMethod = 'LX/02Gc;->A02(LX/09dm;LX/08ub;Ljava/lang/String;Lkotlin/jvm/functions/Function0;LX/0SBF;IIZ)V'
}
foreach ($name in $privateCalls.Keys) {
    if ([string]$video.symbols.$name -cne [string]$privateCalls[$name] `
            -or (Get-PatchletLiteralCount -Text $adapterText -Literal ([string]$privateCalls[$name])) -ne 1) {
        throw "Video private seam symbol or raw template callsite drifted: $name."
    }
}
foreach ($literal in @('const/16 v12, 0x20', 'const/16 v12, 0x4000',
        'Lthreadsmod/video/VideoSaveRequest;->isAllowed(Ljava/lang/String;)Z',
        'Lthreadsmod/video/VideoMenuClick;-><init>(Landroid/app/Activity;Ljava/lang/String;)V')) {
    if ((Get-PatchletLiteralCount -Text $adapterText -Literal $literal) -ne 1) { throw 'Video bounded immutable native menu contract drifted.' }
}
if ((Get-PatchletLiteralCount -Text $clickText -Literal `
        'Lthreadsmod/video/VideoSaveController;->open(Landroid/app/Activity;Ljava/lang/String;)Z') -ne 1) {
    throw 'Video click must open only its private save Activity controller.'
}
foreach ($forbidden in @('AutoBlockSync', 'ThreadsBlockBridge', 'ReportController', 'UserSession',
        'getId()Ljava/lang/String;', 'java/net/', 'recordInlineRenderStage', 'InlineVisibilityCallback')) {
    if (($adapterText + $clickText).Contains($forbidden, [StringComparison]::Ordinal)) {
        throw 'Video menu adapter reached account, network, or another visibility seam.'
    }
}
$renderBefore = Get-PatchletTreeSha256 -Root $renderRoot -Filter '*.smali'
$renderAgain = @(Expand-PatchletSmaliTemplates -Symbols $video.symbols -TemplateRoot $templateRoot `
    -DestinationRoot $renderRoot -TemplateNames $expectedTemplates -Owner 'video download')
if ((Get-PatchletTreeSha256 -Root $renderRoot -Filter '*.smali') -cne $renderBefore `
        -or @($renderAgain | Where-Object action -ne 'no-op').Count -ne 0) { throw 'Video template replay changed content.' }
$resolutionDirectory = Split-Path -Parent $resolutionFull
$rewritePath = Resolve-PatchletChildPath -Root $resolutionDirectory -Child 'video-download-rewrites.json'
$rewrite = Read-PatchletJson -Path $rewritePath
if (@($rewrite.rules).Count -ne 2 `
        -or [string]$rewrite.rules[0].id -cne 'video-menu-captured-media-hook' `
        -or [string]$rewrite.rules[0].path -cne 'smali_classes6/X/0Lbf.smali' `
        -or [string]$rewrite.rules[1].id -cne 'video-private-save-activity' `
        -or [string]$rewrite.rules[1].path -cne 'AndroidManifest.xml') {
    throw 'Video exact host path, anchor ownership or manifest rewrite drifted.'
}
$rewriteFixtures = Join-Path $scratchFull 'rewrite-fixtures'
[IO.Directory]::CreateDirectory($rewriteFixtures) | Out-Null
foreach ($rule in @($rewrite.rules)) {
    if ([int]$rule.expectedCount -ne 1) { throw 'Video host and manifest anchors must occur exactly once.' }
    $before = if ($null -ne $rule.PSObject.Properties['beforeFile']) {
        Get-NormalizedPatchletText -Path (Resolve-PatchletChildPath -Root $resolutionDirectory -Child ([string]$rule.beforeFile))
    } else { [string]$rule.before }
    $target = Resolve-PatchletChildPath -Root $rewriteFixtures -Child ([string]$rule.path)
    Set-NormalizedPatchletText -Path $target -Text $before
}
$first = @(Apply-PatchletRewriteSet -RewriteSetPath $rewritePath -DecodedRoot $rewriteFixtures)
$second = @(Apply-PatchletRewriteSet -RewriteSetPath $rewritePath -DecodedRoot $rewriteFixtures)
if (@($first | Where-Object action -ne 'applied').Count -ne 0 `
        -or @($second | Where-Object action -ne 'no-op').Count -ne 0) { throw 'Video rewrite fixture did not apply then no-op.' }
$driftRule = @($rewrite.rules | Where-Object { ([string]$_.path).EndsWith('.smali', [StringComparison]::Ordinal) })
if ($driftRule.Count -ne 1) { throw 'Video download must own exactly one native menu host rewrite.' }
$driftFile = Resolve-PatchletChildPath -Root $rewriteFixtures -Child ([string]$driftRule[0].path)
Set-NormalizedPatchletText -Path $driftFile -Text '.class public Lwrong/VideoHost;'
$rejected = $false
try { $null = Apply-PatchletRewriteSet -RewriteSetPath $rewritePath -DecodedRoot $rewriteFixtures }
catch { $rejected = $true }
if (-not $rejected) { throw 'Video host-anchor drift was accepted.' }

$rawEvidence = $null
$rawNegatives = @()
if ($Apk -or $SourceApk) {
    if ([string]::IsNullOrWhiteSpace($SourceApk)) { throw 'Signed video proof requires its exact pristine SourceApk.' }
    $null = Test-PatchletSourceBinding -Resolution $resolution -SourceApk $SourceApk
    $androidJar = Join-Path $AndroidSdk "platforms\android-$($resolution.toolchain.androidPlatform)\android.jar"
    $apktoolJar = Join-Path $repositoryRoot '.tools\apktool\apktool_3.0.3.jar'
    $expectedRoot = Join-Path $scratchFull 'canonical-decoded'
    [IO.Directory]::CreateDirectory((Join-Path $expectedRoot 'smali')) | Out-Null
    $null = & (Join-Path $PSScriptRoot 'Build-JavaInjection.ps1') `
        -DecodedRoot $expectedRoot -ScratchRoot (Join-Path $scratchFull 'canonical-build') `
        -ResolutionPath $resolutionFull -AndroidSdk $AndroidSdk -BuildToolsVersion $BuildToolsVersion `
        -Java $Java -Javac $Javac -Jar 'jar'
    $pristineRoot = Join-Path $scratchFull 'pristine-source'
    $null = Invoke-VideoGateNative -Command $Java -Arguments @('-jar', $apktoolJar, 'd', '--jobs', '8',
        '--frame-path', (Join-Path $repositoryRoot 'decompiled\apktool-framework'),
        '--output', $pristineRoot, ([IO.Path]::GetFullPath($SourceApk)))
    $null = Apply-PatchletRewriteSet -RewriteSetPath $rewritePath -DecodedRoot $pristineRoot
    $smaliRoot = Join-Path $scratchFull 'video-smali'
    [IO.Directory]::CreateDirectory((Join-Path $smaliRoot 'threadsmod')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $expectedRoot 'smali\threadsmod\video') `
        -Destination (Join-Path $smaliRoot 'threadsmod\video') -Recurse
    [IO.Directory]::CreateDirectory((Join-Path $smaliRoot 'X')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $pristineRoot 'smali_classes6\X\0Lbf.smali') `
        -Destination (Join-Path $smaliRoot 'X\0Lbf.smali')
    $helperClasses = Join-Path $scratchFull 'dex-helpers'
    [IO.Directory]::CreateDirectory($helperClasses) | Out-Null
    $null = Invoke-VideoGateNative -Command $Javac -Arguments @('-encoding', 'UTF-8', '-cp', $apktoolJar,
        '-d', $helperClasses, $inspectorSource, (Join-Path $PSScriptRoot 'DexUpdateFlowInspector.java'),
        (Join-Path $PSScriptRoot 'DexBridgeFlowFixtureAssembler.java'))
    $helperClasspath = $helperClasses + [IO.Path]::PathSeparator + $apktoolJar
    $canonicalDex = Join-Path $scratchFull 'canonical-video.dex'
    $canonicalApk = Join-Path $scratchFull 'canonical-video.apk'
    $null = Invoke-VideoGateNative -Command $Java -Arguments @('-cp', $helperClasspath,
        'DexBridgeFlowFixtureAssembler', $smaliRoot, $canonicalDex)
    New-VideoDexArchive -Dex $canonicalDex -Path $canonicalApk
    $positive = Invoke-VideoGateNative -Command $Java -Arguments @('-cp', $helperClasspath,
        'DexVideoDownloadInspector', $canonicalApk, $canonicalApk, 'require-host')
    foreach ($negative in @($fixture.rawNegatives)) {
        $negativeRoot = Join-Path $scratchFull ([string]$negative.id)
        $negativeDex = Join-Path $scratchFull ([string]$negative.id + '.dex')
        $negativeApk = Join-Path $scratchFull ([string]$negative.id + '.apk')
        $kindProperty = $negative.PSObject.Properties['kind']
        $kind = if ($null -eq $kindProperty) { 'primary-mutation' } else { [string]$kindProperty.Value }
        if ($kind -ceq 'primary-mutation') {
            Copy-Item -LiteralPath $smaliRoot -Destination $negativeRoot -Recurse
            $target = Resolve-PatchletChildPath -Root $negativeRoot -Child ([string]$negative.file)
            $text = Get-NormalizedPatchletText -Path $target
            if ((Get-PatchletLiteralCount -Text $text -Literal ([string]$negative.before)) -ne [int]$negative.expectedCount) {
                throw "Video raw fixture anchor drifted: $($negative.id)."
            }
            Set-NormalizedPatchletText -Path $target -Text $text.Replace([string]$negative.before, [string]$negative.after)
            $null = Invoke-VideoGateNative -Command $Java -Arguments @('-cp', $helperClasspath,
                'DexBridgeFlowFixtureAssembler', $negativeRoot, $negativeDex)
            New-VideoDexArchive -Dex $negativeDex -Path $negativeApk
        } elseif ($kind -cin @('secondary-extra', 'secondary-duplicate', 'embedded-extra', 'embedded-duplicate')) {
            [IO.Directory]::CreateDirectory($negativeRoot) | Out-Null
            if ($kind.EndsWith('-extra', [StringComparison]::Ordinal)) {
                Set-NormalizedPatchletText -Path (Join-Path $negativeRoot 'UnexpectedVideoClass.smali') `
                    -Text ".class public final Lthreadsmod/video/UnexpectedVideoClass;`n.super Ljava/lang/Object;`n"
            } else {
                Copy-Item -LiteralPath (Join-Path $smaliRoot 'threadsmod\video\VideoSaveRequest.smali') `
                    -Destination (Join-Path $negativeRoot 'VideoSaveRequest.smali')
            }
            $null = Invoke-VideoGateNative -Command $Java -Arguments @('-cp', $helperClasspath,
                'DexBridgeFlowFixtureAssembler', $negativeRoot, $negativeDex)
            $secondaryEntry = if ($kind.StartsWith('embedded-', [StringComparison]::Ordinal)) {
                'assets/longtail/classes.dex'
            } else { 'classes2.dex' }
            New-VideoDexArchive -Dex $canonicalDex -Path $negativeApk -SecondaryDex $negativeDex `
                -SecondaryDexEntry $secondaryEntry
        } else { throw 'Unknown video raw fixture kind.' }
        $result = Invoke-VideoGateNative -Command $Java -Arguments @('-cp', $helperClasspath,
            'DexVideoDownloadInspector', $negativeApk, $canonicalApk, 'require-host') -AllowFailure
        if ($result.exitCode -eq 0) { throw "Video raw negative was accepted: $($negative.id)." }
        $failure = $result.lines[-1] | ConvertFrom-Json
        if ([int]$failure.schemaVersion -ne 1 -or [string]$failure.status -cne 'failed' `
                -or [string]$failure.contract -cne 'video-canonical-instruction-graph-v1' `
                -or [string]$negative.expectedCode -cnotmatch '^video_[a-z_]+$' `
                -or [string]$failure.code -cne [string]$negative.expectedCode) {
            throw "Video negative did not fail with its reviewed exact code: $($negative.id)."
        }
        $rawNegatives += [string]$negative.id
    }
    $candidateForComparison = if ($Apk) { [IO.Path]::GetFullPath($Apk) } else { $canonicalApk }
    $signed = Invoke-VideoGateNative -Command $Java -Arguments @('-cp', $helperClasspath,
        'DexVideoDownloadInspector', $candidateForComparison, $canonicalApk, 'require-host')
    $rawEvidence = $signed.lines[-1] | ConvertFrom-Json
}
$report = [ordered]@{
    schemaVersion = 1; status = 'passed'; sourceSha256 = [string]$resolution.source.sha256
    canonicalSourceContract = $true; sourceNegativeFixtures = $sourceFixtureResults
    offlineTransferHarness = $videoHarnessOutput.lines[-1]; templateIdempotency = $true
    nativeRewritePositiveAndIdempotent = $true; nativeHookDriftRejected = $true
    nativePrivateCallsitesExact = $true
    rawDex = $rawEvidence; rawNegativeFixtures = $rawNegatives; signedCandidateBound = [bool]$Apk
    runtimeDownloadTested = $false; liveNetworkUsed = $false
}
if ($ReportPath) { Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath)) }
[pscustomobject]$report
