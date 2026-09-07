[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScratchRoot,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$Java = 'java',
    [string]$Javac = 'javac',
    [string]$Jar = 'jar',
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

function Invoke-RequiredNative {
    param([string]$Command, [string[]]$Arguments)
    $lines = @(& $Command @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $lines | ForEach-Object { Write-Host $_ }
        throw "Native fixture command failed with exit code ${code}: $Command"
    }
    return $lines
}

function Invoke-ProbeNative {
    param([string]$Command, [string[]]$Arguments)
    $lines = @(& $Command @Arguments 2>&1)
    [pscustomobject]@{ exitCode = $LASTEXITCODE; lines = $lines }
}

$repositoryRoot = Get-PatchletRepositoryRoot
$scratchFull = Assert-PatchletPathUnderRoot `
    -Path ([IO.Path]::GetFullPath($ScratchRoot)) -Root (Join-Path $repositoryRoot 'work')
if (Test-Path -LiteralPath $scratchFull) { throw "ScratchRoot must be fresh: $scratchFull" }
[IO.Directory]::CreateDirectory($scratchFull) | Out-Null

$resolution = Read-PatchletJson -Path ([IO.Path]::GetFullPath($ResolutionPath))
$buildTools = Join-Path $AndroidSdk "build-tools\$($resolution.toolchain.buildToolsVersion)"
$d8Jar = Join-Path $buildTools 'lib\d8.jar'
$androidJar = Join-Path $AndroidSdk "platforms\android-$($resolution.toolchain.androidPlatform)\android.jar"
$apktoolJar = Join-Path $repositoryRoot '.tools\apktool\apktool_3.0.3.jar'
$helperSource = Join-Path $PSScriptRoot 'DexLiteralCallInspector.java'
$fixtureRoot = Join-Path $repositoryRoot 'patchlets\assets\release-gates\dex-literal-call'
foreach ($required in @($d8Jar, $androidJar, $apktoolJar, $helperSource, $fixtureRoot)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required literal-call fixture input is missing: $required" }
}
if ((Get-PatchletSha256 -Path $d8Jar) -ne [string]$resolution.toolchain.d8JarSha256 `
        -or (Get-PatchletSha256 -Path $apktoolJar) -ne [string]$resolution.toolchain.apktoolJarSha256 `
        -or (Get-PatchletSha256 -Path $helperSource) -ne [string]$resolution.assets.dexLiteralCallInspectorSourceSha256 `
        -or (Get-PatchletTreeSha256 -Root $fixtureRoot -Filter '*.java') `
            -ne [string]$resolution.assets.dexLiteralCallFixtureTreeSha256) {
    throw 'Literal-call fixture tool or source hash differs from the exact resolution.'
}

$helperClasses = Join-Path $scratchFull 'helper-classes'
[IO.Directory]::CreateDirectory($helperClasses) | Out-Null
$null = Invoke-RequiredNative -Command $Javac -Arguments @(
    '-encoding', 'UTF-8', '-cp', $apktoolJar, '-d', $helperClasses, $helperSource)
$helperClasspath = $helperClasses + [IO.Path]::PathSeparator + $apktoolJar
$ownerDescriptor = 'Lthreadsmod/reporting/ReportClient;'
$ownerMethod = 'post'
$ownerMethodDescriptor = '(Ljava/lang/Object;Ljava/lang/String;I)Ljava/lang/Object;'
$calleeClass = 'Ljavax/net/ssl/HttpsURLConnection;'
$calleeMethod = 'setRequestMethod'
$calleeDescriptor = '(Ljava/lang/String;)V'
$commonArguments = @(
    $ownerDescriptor, $ownerMethod, $ownerMethodDescriptor,
    $calleeClass, $calleeMethod, $calleeDescriptor,
    'INVOKE_VIRTUAL', '0', 'POST', '1')

$results = @()
foreach ($fixture in @(
        [pscustomobject]@{ id = 'positive'; shouldPass = $true },
        [pscustomobject]@{ id = 'decoy'; shouldPass = $false },
        [pscustomobject]@{ id = 'different-method'; shouldPass = $false },
        [pscustomobject]@{ id = 'duplicate-call'; shouldPass = $false },
        [pscustomobject]@{ id = 'branch-entry'; shouldPass = $false }
    )) {
    $fixtureScratch = Join-Path $scratchFull ([string]$fixture.id)
    $classes = Join-Path $fixtureScratch 'classes'
    $dex = Join-Path $fixtureScratch 'dex'
    [IO.Directory]::CreateDirectory($classes) | Out-Null
    [IO.Directory]::CreateDirectory($dex) | Out-Null
    $source = Join-Path $fixtureRoot "$($fixture.id)\threadsmod\reporting\ReportClient.java"
    $null = Invoke-RequiredNative -Command $Javac -Arguments @('-encoding', 'UTF-8', '-d', $classes, $source)
    $classFile = Join-Path $classes 'threadsmod\reporting\ReportClient.class'
    $null = Invoke-RequiredNative -Command $Java -Arguments @(
        '-cp', $d8Jar, 'com.android.tools.r8.D8', '--min-api', '28', '--lib', $androidJar,
        '--output', $dex, $classFile)
    $fixtureApk = Join-Path $fixtureScratch 'fixture.apk'
    $null = Invoke-RequiredNative -Command $Jar -Arguments @(
        '--create', '--file', $fixtureApk, '-C', $dex, 'classes.dex')
    $probe = Invoke-ProbeNative -Command $Java -Arguments (@(
        '-cp', $helperClasspath, 'DexLiteralCallInspector', $fixtureApk) + $commonArguments)
    $passed = [int]$probe.exitCode -eq 0
    if ($passed -ne [bool]$fixture.shouldPass) {
        $probe.lines | ForEach-Object { Write-Host $_ }
        throw "Literal-call fixture '$($fixture.id)' produced unexpected pass=$passed."
    }
    if ($passed) {
        $parsed = [string]$probe.lines[-1] | ConvertFrom-Json
        if ([string]$parsed.status -ne 'passed' -or [int]$parsed.matchedCount -ne 1) {
            throw 'Positive literal-call fixture did not return the exact passing evidence.'
        }
    } elseif (-not (([string]($probe.lines -join "`n")).Contains(
            'literal-call contract failed', [StringComparison]::Ordinal))) {
        throw "Negative literal-call fixture '$($fixture.id)' failed for an unexpected reason."
    }
    $results += [pscustomobject]@{
        id = [string]$fixture.id
        expectedPass = [bool]$fixture.shouldPass
        observedPass = $passed
    }
}

$report = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToString('o')
    status = 'passed'
    fixtures = $results
}
if ($ReportPath) { Write-PatchletJson -Value $report -Path ([IO.Path]::GetFullPath($ReportPath)) }
[pscustomobject]$report
