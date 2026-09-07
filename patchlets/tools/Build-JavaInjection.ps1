[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DecodedRoot,
    [Parameter(Mandatory)][string]$ScratchRoot,
    [string]$ResolutionPath = (Join-Path $PSScriptRoot '..\resolutions\444.0.0.45.85\resolution.json'),
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$BuildToolsVersion = '36.0.0',
    [string]$Java = 'java',
    [string]$Javac = 'javac',
    [string]$Jar = 'jar',
    [string]$SevenZip = 'C:\Program Files\7-Zip\7z.exe',
    [string]$ApktoolJar,
    [string]$FrameworkDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ThreadsMod.Patchlets.psm1') -Force -DisableNameChecking

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments, [string]$WorkingDirectory)
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        & $Command @Arguments | Out-Host
        $code = $LASTEXITCODE
    } finally {
        if ($WorkingDirectory) { Pop-Location }
    }
    if ($code -ne 0) {
        throw "Native command failed with exit code ${code}: $Command"
    }
}

function Add-GeneratedOwnerAttribution {
    param(
        [Parameter(Mandatory)][object[]]$Generated,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $patchletsRoot = Join-Path $RepositoryRoot 'patchlets'
    $catalog = Read-PatchletJson -Path (Join-Path $patchletsRoot 'catalog.json')
    $owners = @()
    foreach ($entry in @($catalog.patchlets)) {
        $manifest = Read-PatchletJson -Path (Resolve-PatchletChildPath `
            -Root $patchletsRoot -Child ([string]$entry.path))
        $owners += [pscustomobject]@{
            id = [string]$manifest.id
            prefixes = @($manifest.ownership.classPrefixes | ForEach-Object { [string]$_ })
            descriptors = @($manifest.ownership.classDescriptors | ForEach-Object { [string]$_ })
        }
    }

    foreach ($item in $Generated) {
        $relative = [string]$item.file
        if (-not $relative.EndsWith('.smali', [StringComparison]::Ordinal)) {
            throw "Generated class has an unexpected path: $relative"
        }
        $descriptor = 'L' + $relative.Substring(0, $relative.Length - 6) + ';'
        $matches = @($owners | Where-Object {
            $candidate = $_
            if ($candidate.descriptors -contains $descriptor) { return $true }
            foreach ($prefix in @($candidate.prefixes)) {
                if ($descriptor.StartsWith($prefix, [StringComparison]::Ordinal)) {
                    return $true
                }
            }
            return $false
        })
        if ($matches.Count -ne 1) {
            throw "Generated descriptor '$descriptor' has $($matches.Count) owning patchlets; expected exactly one."
        }
        $item | Add-Member -NotePropertyName descriptor -NotePropertyValue $descriptor
        $item | Add-Member -NotePropertyName ownerPatchlet -NotePropertyValue ([string]$matches[0].id)
    }
}

function Add-FixedOwnerAttribution {
    param([Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)][string]$Owner)
    foreach ($item in $Items) {
        $item | Add-Member -NotePropertyName ownerPatchlet -NotePropertyValue $Owner
    }
}

$repositoryRoot = Get-PatchletRepositoryRoot
if (-not $ApktoolJar) { $ApktoolJar = Join-Path $repositoryRoot '.tools\apktool\apktool_3.0.3.jar' }
if (-not $FrameworkDirectory) { $FrameworkDirectory = Join-Path $repositoryRoot 'decompiled\apktool-framework' }

$decodedRootFull = [IO.Path]::GetFullPath($DecodedRoot)
$scratchRootFull = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $scratchRootFull) {
    throw "ScratchRoot must be a fresh, non-existing directory: $scratchRootFull"
}
[IO.Directory]::CreateDirectory($scratchRootFull) | Out-Null

$resolution = Read-PatchletJson -Path ([IO.Path]::GetFullPath($ResolutionPath))
Test-PatchletAssets -Resolution $resolution -RepositoryRoot $repositoryRoot | Out-Null
if ($BuildToolsVersion -ne [string]$resolution.toolchain.buildToolsVersion) {
    throw "Build Tools version '$BuildToolsVersion' differs from the resolution's pinned '$($resolution.toolchain.buildToolsVersion)'."
}

$assetsRoot = Join-Path $repositoryRoot 'patchlets\assets\autoblock'
$patchletsRoot = Join-Path $repositoryRoot 'patchlets'
$sourceRoot = Join-Path $assetsRoot 'java'
$eddsaJar = Join-Path $assetsRoot 'lib\net-i2p-crypto-eddsa-0.3.1.jar'
$carrierAsset = Join-Path $assetsRoot 'stub\smali-carrier.apk'
$templateRoot = Resolve-PatchletTemplateRoot `
    -PatchletsRoot $patchletsRoot `
    -Section $resolution.bridge `
    -DefaultRelativeRoot 'assets\autoblock\bridge-templates' `
    -Kind 'bridge'
$inlineTemplateRoot = Resolve-PatchletTemplateRoot `
    -PatchletsRoot $patchletsRoot `
    -Section $resolution.inlineControls `
    -DefaultRelativeRoot 'assets\inline-control\templates' `
    -Kind 'inline'
$reportTemplateRoot = Resolve-PatchletTemplateRoot `
    -PatchletsRoot $patchletsRoot `
    -Section $resolution.reporting `
    -DefaultRelativeRoot 'assets\reporting\templates' `
    -Kind 'reporting'
$settingsTemplateRoot = Resolve-PatchletTemplateRoot `
    -PatchletsRoot $patchletsRoot `
    -Section $resolution.drawerSettings `
    -DefaultRelativeRoot 'assets\settings-ui\templates' `
    -Kind 'settings'
$androidJar = Join-Path $AndroidSdk "platforms\android-$($resolution.toolchain.androidPlatform)\android.jar"
$d8Jar = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion\lib\d8.jar"

foreach ($requiredPath in @($decodedRootFull, $sourceRoot, $eddsaJar, $carrierAsset, $templateRoot, $inlineTemplateRoot, $reportTemplateRoot, $settingsTemplateRoot, $androidJar, $d8Jar, $ApktoolJar, $FrameworkDirectory, $SevenZip)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Required build input does not exist: $requiredPath" }
}
foreach ($toolCheck in @(
    @($ApktoolJar, [string]$resolution.toolchain.apktoolJarSha256, 'Apktool'),
    @((Join-Path $FrameworkDirectory '1.apk'), [string]$resolution.toolchain.frameworkApkSha256, 'Apktool framework'),
    @($d8Jar, [string]$resolution.toolchain.d8JarSha256, 'D8')
)) {
    $actualHash = Get-PatchletSha256 -Path $toolCheck[0]
    if ($actualHash -ne $toolCheck[1]) { throw "$($toolCheck[2]) hash mismatch. Expected '$($toolCheck[1])', observed '$actualHash'." }
}

$classesDirectory = Join-Path $scratchRootFull 'classes'
$dexDirectory = Join-Path $scratchRootFull 'dex'
$generatedDirectory = Join-Path $scratchRootFull 'generated'
$classesJar = Join-Path $scratchRootFull 'patchlet-runtime.jar'
$carrierApk = Join-Path $scratchRootFull 'smali-carrier.apk'
[IO.Directory]::CreateDirectory($classesDirectory) | Out-Null
[IO.Directory]::CreateDirectory($dexDirectory) | Out-Null

$sources = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter '*.java' | Sort-Object FullName | ForEach-Object FullName)
if ($sources.Count -eq 0) { throw "No canonical Java patchlet sources found below $sourceRoot" }

$javacArguments = @(
    '-encoding', 'UTF-8',
    '-source', '8',
    '-target', '8',
    '-bootclasspath', $androidJar,
    '-classpath', $eddsaJar,
    '-d', $classesDirectory
) + $sources
Invoke-Checked -Command $Javac -Arguments $javacArguments
Invoke-Checked -Command $Jar -Arguments @('--create', '--file', $classesJar, '-C', $classesDirectory, '.')
Invoke-Checked -Command $Java -Arguments @(
    '-Xmx1024M', '-Xss1m', '-cp', $d8Jar, 'com.android.tools.r8.D8',
    '--min-api', ([string]$resolution.source.minSdk),
    '--lib', $androidJar,
    '--output', $dexDirectory,
    $classesJar,
    $eddsaJar
)

$classesDex = Join-Path $dexDirectory 'classes.dex'
if (-not (Test-Path -LiteralPath $classesDex -PathType Leaf)) { throw 'D8 did not produce classes.dex.' }
Copy-Item -LiteralPath $carrierAsset -Destination $carrierApk
Invoke-Checked -Command $SevenZip -Arguments @('u', '-tzip', $carrierApk, 'classes.dex') -WorkingDirectory $dexDirectory
Invoke-Checked -Command $Java -Arguments @(
    '-jar', $ApktoolJar, 'd',
    '--jobs', '8',
    '--frame-path', $FrameworkDirectory,
    '--output', $generatedDirectory,
    $carrierApk
)

$generatedSmaliRoot = Join-Path $generatedDirectory 'smali'
$destinationSmaliRoot = Join-Path $decodedRootFull 'smali'
if (-not (Test-Path -LiteralPath $generatedSmaliRoot -PathType Container)) { throw 'Apktool did not decode generated smali.' }
if (-not (Test-Path -LiteralPath $destinationSmaliRoot -PathType Container)) { throw "Primary smali directory is missing: $destinationSmaliRoot" }

$generated = @(Install-PatchletGeneratedSmali -GeneratedSmaliRoot $generatedSmaliRoot -DestinationSmaliRoot $destinationSmaliRoot)
Add-GeneratedOwnerAttribution -Generated $generated -RepositoryRoot $repositoryRoot
$bridgeDestination = Join-Path $destinationSmaliRoot 'threadsmod\autoblock'
[IO.Directory]::CreateDirectory($bridgeDestination) | Out-Null
$bridges = @(Expand-PatchletBridgeTemplates -Symbols $resolution.bridge.symbols -TemplateRoot $templateRoot -DestinationRoot $bridgeDestination)
$inlineDestination = Join-Path $destinationSmaliRoot 'threadsmod\inlinecontrol'
[IO.Directory]::CreateDirectory($inlineDestination) | Out-Null
$inline = @(Expand-PatchletInlineTemplates `
    -Symbols $resolution.inlineControls.symbols `
    -TemplateRoot $inlineTemplateRoot `
    -DestinationRoot $inlineDestination)
$reportDestination = Join-Path $destinationSmaliRoot 'threadsmod\reporting'
[IO.Directory]::CreateDirectory($reportDestination) | Out-Null
$report = @(Expand-PatchletReportTemplates `
    -Symbols $resolution.reporting.symbols `
    -TemplateRoot $reportTemplateRoot `
    -DestinationRoot $reportDestination `
    -TemplateNames @($resolution.reporting.templateNames))
$settingsDestination = Join-Path $destinationSmaliRoot 'threadsmod\drawer'
[IO.Directory]::CreateDirectory($settingsDestination) | Out-Null
$settings = @(Expand-PatchletSettingsTemplates `
    -Symbols $resolution.drawerSettings.symbols `
    -TemplateRoot $settingsTemplateRoot `
    -DestinationRoot $settingsDestination)
Add-FixedOwnerAttribution -Items $bridges -Owner '030-native-block-bridge'
Add-FixedOwnerAttribution -Items $inline -Owner '060-inline-block-controls'
Add-FixedOwnerAttribution -Items $report -Owner '070-consented-reporting'
Add-FixedOwnerAttribution -Items $settings -Owner '050-mod-settings-ui'

$generatedByPatchlet = @($generated `
    | Group-Object ownerPatchlet `
    | Sort-Object Name `
    | ForEach-Object {
        [pscustomobject]@{
            patchletId = $_.Name
            total = $_.Count
            created = @($_.Group | Where-Object action -eq 'created').Count
            noOp = @($_.Group | Where-Object action -eq 'no-op').Count
        }
    })

$stubDestination = Join-Path $bridgeDestination 'ThreadsBlockBridge.smali'
$stubText = Get-NormalizedPatchletText -Path $stubDestination
if ($stubText.Contains('bridge_stub')) {
    throw 'Compile-time bridge stub escaped into the target tree.'
}

[pscustomobject]@{
    schemaVersion = 1
    sourceFiles = $sources.Count
    generatedSmaliFiles = $generated.Count
    generatedCreated = @($generated | Where-Object action -eq 'created').Count
    generatedNoOp = @($generated | Where-Object action -eq 'no-op').Count
    generatedOwnershipVerified = $true
    generatedByPatchlet = $generatedByPatchlet
    bridgeFiles = $bridges.Count
    bridgeCreated = @($bridges | Where-Object action -eq 'created').Count
    bridgeNoOp = @($bridges | Where-Object action -eq 'no-op').Count
    inlineFiles = $inline.Count
    inlineCreated = @($inline | Where-Object action -eq 'created').Count
    inlineNoOp = @($inline | Where-Object action -eq 'no-op').Count
    reportTemplateFiles = $report.Count
    reportTemplateCreated = @($report | Where-Object action -eq 'created').Count
    reportTemplateNoOp = @($report | Where-Object action -eq 'no-op').Count
    settingsTemplateFiles = $settings.Count
    settingsTemplateCreated = @($settings | Where-Object action -eq 'created').Count
    settingsTemplateNoOp = @($settings | Where-Object action -eq 'no-op').Count
    scratchRoot = $scratchRootFull
}
