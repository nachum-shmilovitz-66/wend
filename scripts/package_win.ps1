# package_win.ps1 — build a runnable Wend folder on Windows. The counterpart of package.sh.
#
# There is no installer yet (WND-27), so the output is a self-contained folder rather than
# a .msi: Wend.exe with its icon and version stamped in, the Swift runtime DLLs it links
# against, and Wend.ico for the tray. It runs on a machine with no Swift toolchain.
#
#     pwsh -File scripts/package_win.ps1
#
# Run it from a Visual Studio developer prompt, or anywhere the Swift toolchain and the
# MSVC tools are on PATH — the same environment `swift build` itself needs.
#
# Like release.sh, this refuses to call a build packaged if it can't verify it: the icon
# and version are read back out of the linked exe afterwards, and a failure there is fatal.

[CmdletBinding()]
param(
    # Where the staged folder goes. Under .build/ by default, beside the compiler's own
    # output and gitignored with it: this is an intermediate, and dist/ is reserved for the
    # thing you actually hand to someone — the installer make_setup_win.ps1 builds from it.
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root '.build\win-stage\Wend' }

function Assert-Command([string] $name, [string] $why) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $command) { throw "$name not found on PATH — needed to $why." }
    return $command.Source
}

# --- Version -----------------------------------------------------------------------
#
# scripts/package.sh owns the version for both platforms; it is read out of there rather
# than duplicated, so a Windows release can't ship a number the macOS one doesn't have.
# Version.swift has to carry the same string because the running app shows it in its menu
# and in feedback reports, and nothing but this check enforces that they agree.

$packageScript = Get-Content (Join-Path $root 'scripts\package.sh') -Raw
if ($packageScript -notmatch 'SHORT_VERSION="\$\{SHORT_VERSION:-([^}]+)\}"') {
    throw 'could not read SHORT_VERSION out of scripts/package.sh'
}
$shortVersion = $Matches[1]
if ($packageScript -notmatch 'BUILD_VERSION="\$\{BUILD_VERSION:-([^}]+)\}"') {
    throw 'could not read BUILD_VERSION out of scripts/package.sh'
}
$buildVersion = $Matches[1]

$versionSwift = Get-Content (Join-Path $root 'Sources\WendWin\Version.swift') -Raw
if ($versionSwift -notmatch 'static let short = "([^"]+)"') {
    throw 'could not read Version.short out of Sources/WendWin/Version.swift'
}
if ($Matches[1] -ne $shortVersion) {
    throw "version drift: Version.swift says $($Matches[1]), package.sh says $shortVersion. " +
          'Update Sources/WendWin/Version.swift to match.'
}

Write-Host "Wend $shortVersion ($buildVersion)"

# --- Icon --------------------------------------------------------------------------

$ico = Join-Path $root 'Packaging\Wend.ico'
if (-not (Test-Path $ico)) {
    throw "Packaging/Wend.ico is missing — regenerate it with scripts/make_icon_win.py."
}

# --- Build -------------------------------------------------------------------------

Assert-Command 'swift' 'build the app' | Out-Null
$python = Assert-Command 'python' 'stamp and verify the PE resources'
Assert-Command 'dumpbin' 'discover which runtime DLLs to ship' | Out-Null

Push-Location $root
try {
    & swift build -c release
    if ($LASTEXITCODE -ne 0) { throw "swift build failed ($LASTEXITCODE)" }
    # SwiftPM prints a symlink warning alongside the path on Windows, so take the last
    # line that actually looks like one.
    $binPath = (& swift build -c release --show-bin-path |
                Where-Object { $_ -match '^[A-Za-z]:\\' } |
                Select-Object -Last 1).Trim()
} finally {
    Pop-Location
}

$builtExe = Join-Path $binPath 'Wend.exe'
if (-not (Test-Path $builtExe)) { throw "no Wend.exe at $binPath" }

# --- Runtime DLLs ------------------------------------------------------------------
#
# Walk the import table transitively and keep only what resolves inside the Swift
# redistributable directory; everything else is a Windows system DLL that is already
# there. Copying the whole runtime folder instead would ship a good deal that never loads.

# swift.exe lives at <swift>\Toolchains\<version>\usr\bin; the redistributable runtime sits
# beside it at <swift>\Runtimes\<version>\usr\bin, under a version without the toolchain's
# "+Asserts" suffix.
$swiftBin = Split-Path -Parent (Get-Command swift).Source
$toolchainDirectory = Split-Path -Parent (Split-Path -Parent $swiftBin)
$toolchainVersion = (Split-Path -Leaf $toolchainDirectory) -replace '\+.*$', ''
$swiftHome = Split-Path -Parent (Split-Path -Parent $toolchainDirectory)
$runtimeBin = Join-Path $swiftHome "Runtimes\$toolchainVersion\usr\bin"
if (-not (Test-Path $runtimeBin)) {
    throw "Swift runtime not found at $runtimeBin — cannot work out which DLLs to ship."
}

function Get-Dependents([string] $path) {
    & dumpbin /nologo /dependents $path |
        Select-String -Pattern '^\s{4}(\S+\.dll)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
}

$needed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$pending = [System.Collections.Queue]::new()
Get-Dependents $builtExe | ForEach-Object { $pending.Enqueue($_) }

while ($pending.Count -gt 0) {
    $dll = $pending.Dequeue()
    $candidate = Join-Path $runtimeBin $dll
    if (-not (Test-Path $candidate)) { continue }   # a system DLL, already on the machine
    if (-not $needed.Add($dll)) { continue }        # already walked
    Get-Dependents $candidate | ForEach-Object { $pending.Enqueue($_) }
}

# --- Stage -------------------------------------------------------------------------

# A running Wend holds its own image open, so the copy below would fail with a bare
# "access is denied". Say why, rather than leaving it to be guessed at.
#
# Only a copy running *from the output directory* is a problem. An installed Wend going
# about its business in %LOCALAPPDATA% locks a different file entirely, and refusing to
# build because of it would mean quitting the app every time — which is exactly the sort of
# needless ceremony that gets a check disabled.
$conflicting = Get-Process -Name 'Wend' -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($OutputDirectory, [StringComparison]::OrdinalIgnoreCase)
}
if ($conflicting) {
    throw ("Wend is running from the output directory (PID {0}) — quit it first; " -f
           ($conflicting.Id -join ', ')) + 'Windows locks a loaded image.'
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Copy-Item $builtExe -Destination $OutputDirectory -Force
Copy-Item $ico -Destination (Join-Path $OutputDirectory 'Wend.ico') -Force
foreach ($dll in $needed) { Copy-Item (Join-Path $runtimeBin $dll) -Destination $OutputDirectory -Force }

$stagedExe = Join-Path $OutputDirectory 'Wend.exe'

# --- Stamp + verify ----------------------------------------------------------------

& $python (Join-Path $PSScriptRoot 'stamp_resources.py') $stagedExe $ico $shortVersion $buildVersion
if ($LASTEXITCODE -ne 0) { throw "stamping resources failed ($LASTEXITCODE)" }

& $python (Join-Path $PSScriptRoot 'verify_resources.py') $stagedExe $shortVersion $buildVersion
if ($LASTEXITCODE -ne 0) { throw "resource verification failed — refusing to call this packaged" }

$total = (Get-ChildItem $OutputDirectory | Measure-Object -Property Length -Sum)
Write-Host ''
Write-Host ("staged -> {0}" -f $OutputDirectory)
Write-Host ("{0} files, {1:N1} MB, {2} runtime DLLs" -f $total.Count, ($total.Sum / 1MB), $needed.Count)
Write-Host 'runnable in place; scripts/make_setup_win.ps1 turns this into dist/Wend-<version>-windows-x64.msi'
