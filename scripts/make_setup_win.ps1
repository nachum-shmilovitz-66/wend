# make_setup_win.ps1 — build the Windows installer. The counterpart of make_pkg.sh.
#
#     pwsh -File scripts/make_setup_win.ps1        # -> dist/Wend-<version>-x64.msi
#
# Stages the app with package_win.ps1 (unless -SkipBuild), then wraps that folder in an MSI
# defined by Packaging/Wend.wxs. dist/ holds the installer and nothing else; the staged
# payload it was built from stays under .build/, where the rest of the build output lives.
#
# Needs WiX 5 and its Util extension, both dotnet global tools:
#
#     dotnet tool install --global wix
#     wix extension add --global WixToolset.Util.wixext
#
# The MSI is a **per-user** install to %LOCALAPPDATA%\Programs\Wend, so it needs no
# elevation — see the reasoning in Packaging/Wend.wxs.

[CmdletBinding()]
param(
    # Use whatever is already staged instead of rebuilding. Only safe when the staged folder
    # came from the current source; the version check below still applies.
    [switch] $SkipBuild,

    # Staged payload to wrap. Defaults to package_win.ps1's own output location.
    [string] $PayloadDirectory,

    # Where the .msi lands.
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
if (-not $PayloadDirectory) { $PayloadDirectory = Join-Path $root '.build\win-stage\Wend' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }

$wix = Get-Command 'wix' -ErrorAction SilentlyContinue
if (-not $wix) {
    throw "wix not found on PATH. Install it with: dotnet tool install --global wix"
}

# --- Version ---------------------------------------------------------------------
#
# Read from scripts/package.sh exactly as package_win.ps1 does, so the installer, the
# stamped exe and the macOS build can never disagree about what version this is.

$packageScript = Get-Content (Join-Path $root 'scripts\package.sh') -Raw
if ($packageScript -notmatch 'SHORT_VERSION="\$\{SHORT_VERSION:-([^}]+)\}"') {
    throw 'could not read SHORT_VERSION out of scripts/package.sh'
}
$shortVersion = $Matches[1]

# --- Stage -----------------------------------------------------------------------

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'package_win.ps1') -OutputDirectory $PayloadDirectory
    if ($LASTEXITCODE -ne 0) { throw "staging failed ($LASTEXITCODE)" }
}

foreach ($required in 'Wend.exe', 'Wend.ico') {
    if (-not (Test-Path (Join-Path $PayloadDirectory $required))) {
        throw "$required missing from $PayloadDirectory — run without -SkipBuild."
    }
}

# Wend.wxs harvests the payload by extension, because the executable needs a component of
# its own and WiX's Files element has no exclude. Anything staged that isn't one of those
# extensions would be dropped from the installer without a word, so refuse it here instead:
# a payload silently missing a file is exactly the failure this is meant to prevent.
$unexpected = Get-ChildItem -File -Recurse $PayloadDirectory |
    Where-Object { $_.Extension -notin '.exe', '.dll', '.ico' }
if ($unexpected) {
    throw ("staged payload holds {0} file(s) the installer would not pick up: {1}. " -f
           $unexpected.Count, ($unexpected.Name -join ', ')) +
          'Add the extension to Packaging/Wend.wxs before shipping this.'
}

# The staged exe carries the version in its own resources. If that disagrees with
# package.sh the payload is stale, and the MSI would advertise a version its own
# executable denies — which is exactly the drift the version check exists to catch.
$stampedVersion = (Get-Item (Join-Path $PayloadDirectory 'Wend.exe')).VersionInfo.ProductVersion
if ($stampedVersion -ne $shortVersion) {
    throw "staged Wend.exe reports version $stampedVersion, package.sh says $shortVersion. " +
          'The payload is stale — re-run without -SkipBuild.'
}

# --- Build the MSI ---------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$msi = Join-Path $OutputDirectory "Wend-$shortVersion-x64.msi"

# The .wixpdb is worth keeping — it is what a future patch or upgrade diff would be built
# against — but it is build output, not something to hand anyone, so it goes under .build
# with the staged payload rather than sitting in dist beside the installer.
$pdb = Join-Path (Split-Path -Parent $PayloadDirectory) "Wend-$shortVersion-x64.wixpdb"

& $wix.Source build `
    -arch x64 `
    -ext WixToolset.Util.wixext `
    -d "Version=$shortVersion" `
    -d "PayloadDir=$((Resolve-Path $PayloadDirectory).Path)" `
    -o $msi `
    -pdb $pdb `
    (Join-Path $root 'Packaging\Wend.wxs')

if ($LASTEXITCODE -ne 0) { throw "wix build failed ($LASTEXITCODE)" }
if (-not (Test-Path $msi)) { throw "wix reported success but produced no $msi" }

# --- Verify ----------------------------------------------------------------------
#
# Read the version and the install scope back out of the built package rather than
# trusting that the arguments above did what they were meant to. release.sh refuses to
# emit an artifact it cannot vouch for; same rule here.

$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase($msi, 0)
$view = $database.OpenView('SELECT `Property`,`Value` FROM `Property`')
$view.Execute()

$properties = @{}
$record = $view.Fetch()
while ($null -ne $record) {
    $properties[$record.StringData(1)] = $record.StringData(2)
    $record = $view.Fetch()
}

$builtVersion = $properties['ProductVersion']
$upgradeCode = $properties['UpgradeCode']
# A per-user package carries no ALLUSERS at all; any value here means it would want
# elevation, which is the one thing this installer is built to avoid.
$scope = $properties['ALLUSERS']

if ($builtVersion -ne $shortVersion) {
    throw "the built MSI says version $builtVersion, expected $shortVersion"
}
if ($scope) {
    throw "the built MSI has ALLUSERS=$scope — it should be a per-user install, needing no elevation"
}

$size = (Get-Item $msi).Length
Write-Host ''
Write-Host ("built -> {0}" -f $msi)
Write-Host ("version {0}, {1:N1} MB, per-user (no elevation), upgrade code {2}" -f `
            $builtVersion, ($size / 1MB), $upgradeCode)
Write-Host 'unsigned: SmartScreen will warn on first run on another machine (WND-27)'
