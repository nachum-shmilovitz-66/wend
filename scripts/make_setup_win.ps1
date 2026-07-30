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

    # Skip the portable .zip and emit only the .msi.
    [switch] $SkipPortable,

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

# --- Portable zip ----------------------------------------------------------------
#
# Not every host will run the MSI. A non-admin account on a Windows Server SKU is refused
# a per-user package outright ("Non-assigned apps are disabled for non-admin users",
# error 1625) with no policy set — it is simply the SKU default. Locked-down corporate
# images do the same by policy. Wend needs no installation to work, so the folder it would
# have installed is worth shipping as-is: unzip anywhere, run Wend.exe.
#
# What is lost without the installer is only the shell integration — no Start-menu entry,
# no Apps & Features entry, no upgrade-in-place — so the note below says so rather than
# leaving it to be discovered.

if (-not $SkipPortable) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = Join-Path $OutputDirectory "Wend-$shortVersion-x64-portable.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }

    # includeBaseDirectory, so unzipping yields a single Wend\ folder rather than spraying
    # eighteen files into whatever directory the user happened to be in.
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        (Resolve-Path $PayloadDirectory).Path, $zip,
        [System.IO.Compression.CompressionLevel]::Optimal, $true)

    $readme = @"
Wend $shortVersion - portable
=============================

Fix text typed in the wrong keyboard layout. Select the text and double-tap Shift.

This is the portable build: there is nothing to install. Unzip this folder wherever
you like and run Wend.exe. A keyboard icon appears in the notification area; its menu
has Fix Selection, Switch Layout After Fix, Launch at Login, Enable Diagnostic Logging,
Send Feedback and About.

Wend needs no permission grant on Windows, and no administrator rights.

Keep the folder together - Wend.exe needs the DLLs beside it, and reads Wend.ico for
its tray icon.

Because this is not an installed copy:

  * there is no Start-menu entry and no Apps & Features entry;
  * Launch at Login points at wherever you unzipped this, so turn it off from the menu
    before moving or deleting the folder, or it will try to start a file that is gone;
  * upgrading means replacing the folder yourself. Quit Wend first - Windows will not
    let you overwrite a running program.

To remove it: quit Wend from its menu (turning Launch at Login off first), then delete
this folder.

Settings live in HKCU\Software\Wend. The diagnostic log, when you switch it on, is at
%LOCALAPPDATA%\Wend\Wend.log and records no part of your text - only lengths and counts.

This build is not code-signed, so Windows SmartScreen may warn the first time you run it.
"@

    $archive = [System.IO.Compression.ZipFile]::Open($zip, 'Update')
    try {
        $entry = $archive.CreateEntry('Wend/README.txt')
        $writer = New-Object System.IO.StreamWriter($entry.Open())
        try { $writer.Write(($readme -replace "`r?`n", "`r`n")) } finally { $writer.Dispose() }
    } finally {
        $archive.Dispose()
    }

    # Same rule as the MSI: read back what was emitted rather than trusting that it worked.
    $check = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $names = $check.Entries | ForEach-Object { $_.FullName }
        $staged = (Get-ChildItem -File $PayloadDirectory).Count
        foreach ($required in 'Wend/Wend.exe', 'Wend/Wend.ico', 'Wend/README.txt') {
            if ($names -notcontains $required) { throw "$required missing from $zip" }
        }
        if ($names.Count -ne $staged + 1) {
            throw "zip holds $($names.Count) entries, expected $($staged + 1) (payload plus README)"
        }
    } finally {
        $check.Dispose()
    }

    Write-Host ("built -> {0}" -f $zip)
    Write-Host ("{0} files, {1:N1} MB, no install required" -f `
                $names.Count, ((Get-Item $zip).Length / 1MB))
}

# --- Checksums -------------------------------------------------------------------
#
# The Windows artifacts are deliberately unsigned (WND-27), so there is no signature for
# anyone to check. A published SHA-256 is the substitute: it does not prove who built the
# file, but it does prove the download is the file that was built, which is the part a
# mirror or a truncated download can get wrong. Written in `sha256sum` format so it can be
# checked with the ordinary tools on either platform.

$artifacts = Get-ChildItem $OutputDirectory -File |
    Where-Object { $_.Extension -in '.msi', '.zip' } |
    Sort-Object Name

$sums = Join-Path $OutputDirectory "Wend-$shortVersion-SHA256SUMS.txt"
$lines = foreach ($artifact in $artifacts) {
    "{0}  {1}" -f (Get-FileHash $artifact.FullName -Algorithm SHA256).Hash.ToLower(), $artifact.Name
}
Set-Content -Path $sums -Value $lines -Encoding ascii

Write-Host ("built -> {0}" -f $sums)
foreach ($line in $lines) { Write-Host "  $line" }

Write-Host ''
Write-Host 'unsigned by design (WND-27): SmartScreen will warn on first run on another machine.'
Write-Host 'The checksums above are what a user can verify instead.'
