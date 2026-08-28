#
# EngineShelf - run an old Chromium engine on a modern machine (Windows)
#
# PowerShell 5.1+, which ships with Windows 10/11. Downloads a pinned Chromium
# build once, then launches it as an ordinary desktop browser with its own
# profile. Any milestone in catalog.tsv works, as does any raw revision from the
# Chromium snapshot archive.
#
#   .\engineshelf.ps1 catalog                    # versions available here
#   .\engineshelf.ps1 run 74                     # install if needed, launch
#   .\engineshelf.ps1 run 120 localhost:4173     # launch 120 on a URL
#   .\engineshelf.ps1 list                       # what is installed, how big
#   .\engineshelf.ps1 remove 74                  # free the disk space
#
# The GUI (.\gui.ps1) drives this same script, so both agree by construction.
#
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = '',
    [Parameter(Position = 1)][string]$Selector = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest is ~20x slower with the progress bar on large downloads.
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Catalog   = Join-Path $ScriptDir 'catalog.tsv'
. (Join-Path $ScriptDir 'lib\preflight.ps1')
. (Join-Path $ScriptDir 'lib\engines.ps1')
$BaseUrl   = 'https://commondatastorage.googleapis.com/chromium-browser-snapshots'
$ListApi   = 'https://www.googleapis.com/storage/v1/b/chromium-browser-snapshots/o'

# This tool has been named three things; both old variables are still honoured so an
# existing setup does not break on a rename.
$RootIsDefault = $false
if ($env:ENGINESHELF_HOME) {
    $Root = $env:ENGINESHELF_HOME
} elseif ($env:CHROMIUM_STACK_HOME) {
    $Root = $env:CHROMIUM_STACK_HOME
} elseif ($env:BROWSERS_EMU_HOME) {
    $Root = $env:BROWSERS_EMU_HOME
} else {
    $Root = Join-Path $env:USERPROFILE '.engineshelf'
    $RootIsDefault = $true
}
$BuildsDir   = Join-Path $Root 'builds'
$ProfilesDir = Join-Path $Root 'profiles'
$LogsDir     = Join-Path $Root 'logs'

function Write-Info { param($m) Write-Host $m }
function Write-Warn { param($m) Write-Host "!  $m" -ForegroundColor Yellow }
function Write-Ok   { param($m) Write-Host "OK $m" -ForegroundColor Green }
function Die        { param($m) Write-Host "X  $m" -ForegroundColor Red; exit 1 }

# This tool used to be called browsers-emu and kept the same layout under
# .browsers-emu. Nothing inside changed, so moving the directory across is the
# whole migration - and it has to happen before the new root is created empty.
$previousRoot = Join-Path $env:USERPROFILE '.browsers-emu'
if ($RootIsDefault -and (Test-Path $previousRoot) -and -not (Test-Path $Root)) {
    try {
        Move-Item -Path $previousRoot -Destination $Root
        Write-Host "Moved your existing browsers into $Root (renamed from browsers-emu)."
    } catch { }
}

foreach ($dir in @($Root, $BuildsDir, $ProfilesDir, $LogsDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# ---------- catalog ----------
# Two record types, in both the shipped catalog and the runtime cache:
#   V <milestone> <version> <note>
#   B <milestone> <platform> <revision> <archive> <root>
#
# catalog.tsv ships inside the release and may sit somewhere unwritable, so
# anything learned at runtime goes to the cache under $Root instead. The cache is
# read second and therefore wins: it is the newer of the two answers.
$CacheFile   = Join-Path $Root 'catalog.cache.tsv'
$StableCache = Join-Path $Root 'stable.cache'
$StableTtl   = 86400                 # how long "newest stable milestone" stays fresh
$MaxDrift    = 3000                  # refuse a build this far past the branch point
$DashApi     = 'https://chromiumdash.appspot.com/fetch_milestones'
$CftStable   = 'https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json'

$CatalogVersions = @{}
$CatalogBuilds   = @{}
$CatalogOrder    = @()
$CatalogShelf    = @()

function Import-CatalogFile {
    param($path)
    if (-not (Test-Path $path)) { return }
    foreach ($line in Get-Content $path) {
        if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
        $f = $line -split "`t"
        if ($f[0] -eq 'V') {
            $m = [int]$f[1]
            $note = ''
            if ($f.Count -gt 3) { $note = $f[3] }
            $CatalogVersions[$m] = @{ Version = $f[2]; Note = $note }
        } elseif ($f[0] -eq 'B') {
            $m = [int]$f[1]
            if (-not $CatalogBuilds.ContainsKey($m)) { $CatalogBuilds[$m] = @{} }
            $CatalogBuilds[$m][$f[2]] = @{ Revision = $f[3]; Archive = $f[4]; Root = $f[5] }
        } elseif ($f[0] -eq 'S' -and $f.Count -ge 6) {
            # Shelf rows, written by tools/discover.py from each vendor's own
            # index. These answer "what is WebKit 26.5 called on disk" for engines
            # whose published name and download identifier are different things -
            # no URL anywhere contains the string "26.5".
            $script:CatalogShelf += ,@{ Engine = $f[1]; Year = [int]$f[2]
                                        Id = $f[3]; Label = $f[4]; Date = $f[5] }
        }
    }
}

# Newest matching id wins: a WebKit version name is not unique - 26.5 covers two
# different builds - and the later one is the one anybody means.
function Get-ShelfIdForLabel {
    param([string]$Engine, [string]$Label)
    $found = $null
    foreach ($row in $CatalogShelf) {
        if ($row.Engine -eq $Engine -and ($row.Label -eq $Label -or $row.Id -eq $Label)) {
            $found = $row.Id
        }
    }
    return $found
}

function Get-ShelfLabelForId {
    param([string]$Engine, [string]$Id)
    foreach ($row in $CatalogShelf) {
        if ($row.Engine -eq $Engine -and $row.Id -eq $Id) { return $row.Label }
    }
    return $null
}

function Update-Catalog {
    $script:CatalogVersions = @{}
    $script:CatalogBuilds   = @{}
    $script:CatalogShelf    = @()
    Import-CatalogFile $Catalog
    Import-CatalogFile $CacheFile
    $script:CatalogOrder = @($CatalogVersions.Keys | Sort-Object)
}
Update-Catalog
if ($CatalogOrder.Count -eq 0 -and -not (Test-Path $Catalog)) {
    Write-Warn "No catalog at $Catalog - milestones will be resolved from the archive."
}

# Windows-on-ARM runs the x64 build through the OS emulation layer, so there is
# only ever one platform to choose here.
$HostPlatform = 'Win_x64'

function Get-BuildDir   { param($rev) Join-Path $BuildsDir $rev }
function Get-ProfileDir { param($rev) Join-Path $ProfilesDir $rev }
function Get-LogFile    { param($rev) Join-Path $LogsDir "$rev.log" }
function Test-Installed { param($rev) Test-Path (Join-Path (Get-BuildDir $rev) '.complete') }

function Get-Meta {
    param($rev)
    $path = Join-Path (Get-BuildDir $rev) '.meta'
    $meta = @{}
    if (Test-Path $path) {
        foreach ($line in Get-Content $path) {
            if ($line -match "^([A-Z_]+)='(.*)'$") { $meta[$Matches[1]] = $Matches[2] }
        }
    }
    return $meta
}

function Write-Meta {
    param($key, $milestone, $version, $platform, $archive, $root, $engine)
    if (-not $engine) { $engine = 'chromium' }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $body = @(
        "META_ENGINE='$engine'",
        "META_MILESTONE='$milestone'",
        "META_VERSION='$version'",
        "META_PLATFORM='$platform'",
        "META_ARCHIVE='$archive'",
        "META_ROOT='$root'",
        "META_INSTALLED='$stamp'"
    ) -join "`n"
    # The Python backend parses this file too, so keep it LF and quoted.
    [IO.File]::WriteAllText((Join-Path (Get-BuildDir $key) '.meta'), $body + "`n")
}

# ---------- runtime cache ----------
# Written as a whole new file and moved into place: several versions can be
# launched at once, each resolving something different, and a reader must never
# see a half-written line.
function Add-CacheRows {
    param($rows)
    if (-not $rows -or @($rows).Count -eq 0) { return }
    $existing = @('# EngineShelf cache - milestones resolved against the live archive.')
    if (Test-Path $CacheFile) { $existing = @(Get-Content $CacheFile) }
    $tmp = "$CacheFile.$PID"
    try {
        Set-Content -Path $tmp -Value ($existing + @($rows)) -Encoding UTF8
        Move-Item -Path $tmp -Destination $CacheFile -Force
    } catch {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

function Test-CacheMilestone {
    param($m)
    if (-not (Test-Path $CacheFile)) { return $false }
    foreach ($line in Get-Content $CacheFile) {
        $f = $line -split "`t"
        if ($f[0] -eq 'B' -and $f[1] -eq "$m") { return $true }
    }
    return $false
}

# A cached row goes stale in exactly one way: the bucket drops a revision. Forget
# it and the next lookup asks the archive again instead of failing forever.
function Remove-CacheMilestone {
    param($m)
    if (-not (Test-Path $CacheFile)) { return }
    $kept = @(Get-Content $CacheFile | Where-Object {
        $f = $_ -split "`t"
        -not (($f[0] -eq 'V' -or $f[0] -eq 'B') -and $f[1] -eq "$m")
    })
    $tmp = "$CacheFile.$PID"
    try {
        Set-Content -Path $tmp -Value $kept -Encoding UTF8
        Move-Item -Path $tmp -Destination $CacheFile -Force
    } catch {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

# ---------- live resolution ----------
# The shipped catalog freezes at whatever was current when the release was cut.
# Everything below asks the archive the same questions instead, so a milestone
# that shipped after this copy was built still runs. An answer is permanent - a
# branch point never moves and the snapshot bucket only ever grows - so it is
# cached without a TTL. Only "which milestone is stable now" gets one.

function Get-MilestoneInfo {
    param($m)
    try { $data = Invoke-RestMethod -Uri "${DashApi}?mstone=$m" -TimeoutSec 30 } catch { return $null }
    $entry = @($data)[0]
    if (-not $entry -or -not $entry.chromium_main_branch_position) { return $null }
    return @{ Position = [int64]$entry.chromium_main_branch_position; Branch = "$($entry.chromium_branch)" }
}

# First archived revision at or after target. Not every commit position is built
# and the gap runs to tens of commits, so the bucket listing is what decides.
# GCS lists lexicographically and the bucket still holds ancient short revision
# folders - Linux_x64/97277 sorts after 972766 - so only tokens of the target's
# own digit width are compared.
function Get-NearestRevision {
    param($platform, $target)
    $width = "$target".Length
    $low   = "$platform/$target"
    $high  = "$platform/" + ('9' * $width)
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        try {
            $listing = Invoke-RestMethod -TimeoutSec 30 `
                -Uri "${ListApi}?delimiter=/&prefix=$platform/&startOffset=$low&endOffset=$high&maxResults=200"
        } catch { return $null }
        if (-not $listing.prefixes) { return $null }
        $tokens = @($listing.prefixes | ForEach-Object { $_.TrimEnd('/').Split('/')[-1] })
        $found = @($tokens |
            Where-Object { $_ -match '^\d+$' -and $_.Length -eq $width -and [int64]$_ -ge $target } |
            ForEach-Object { [int64]$_ } | Sort-Object)
        if ($found.Count -gt 0) {
            if (($found[0] - $target) -ge $MaxDrift) { return $null }
            return $found[0]
        }
        $low = "$platform/" + $tokens[-1]
    }
    return $null
}

# Windows switched from chrome-win32.zip to chrome-win.zip partway through the
# catalogued range, so the listing decides this too rather than a guess.
function Get-ArchiveAt {
    param($platform, $revision)
    try {
        $listing = Invoke-RestMethod -Uri "${ListApi}?delimiter=/&prefix=$platform/$revision/" -TimeoutSec 30
    } catch { return $null }
    if (-not $listing.items) { return $null }
    $names = @($listing.items | ForEach-Object { $_.name.Split('/')[-1] })
    foreach ($candidate in @('chrome-win.zip', 'chrome-win32.zip')) {
        if ($names -contains $candidate) { return $candidate }
    }
    return $null
}

function Resolve-MilestoneLive {
    param($m)
    $info = Get-MilestoneInfo $m
    if (-not $info) { return $null }
    $revision = Get-NearestRevision $HostPlatform $info.Position
    if (-not $revision) { return $null }
    $archive = Get-ArchiveAt $HostPlatform $revision
    if (-not $archive) { return $null }
    $version = "$m.0.$($info.Branch).0"
    $root = $archive -replace '\.zip$', ''
    return @(
        "V`t$m`t$version`tResolved from the live archive.",
        "B`t$m`t$HostPlatform`t$revision`t$archive`t$root"
    )
}

# Newest stable milestone. This is the one thing here that does go out of date,
# roughly every four weeks, so it carries a TTL - and offline the last answer
# stands rather than nothing.
function Get-NewestStableMilestone {
    $cached = $null
    if (Test-Path $StableCache) {
        $parts = (Get-Content $StableCache -First 1) -split '\s+'
        if ($parts.Count -ge 2 -and $parts[0] -match '^\d+$') {
            $age = [int64][Math]::Floor((Get-Date -UFormat %s)) - [int64]$parts[0]
            $cached = $parts[1]
            if ($age -lt $StableTtl) { return [int]$cached }
        }
    }
    try { $data = Invoke-RestMethod -Uri $CftStable -TimeoutSec 30 } catch { $data = $null }
    $version = $null
    if ($data -and $data.channels -and $data.channels.Stable) { $version = $data.channels.Stable.version }
    if ($version -match '^(\d+)\.') {
        $milestone = [int]$Matches[1]
        $stamp = [int64][Math]::Floor((Get-Date -UFormat %s))
        try { Set-Content -Path $StableCache -Value "$stamp $milestone" -Encoding UTF8 } catch { }
        return $milestone
    }
    if ($cached) { return [int]$cached }
    return $null
}

# Milestones past the end of what is known, on the same five-milestone spacing,
# plus the current stable itself.
function Get-NewMilestones {
    $newest = Get-NewestStableMilestone
    if (-not $newest) { return @() }
    $known = @($CatalogOrder)
    $last = 60
    if ($known.Count -gt 0) { $last = [int]($known[-1]) }
    $out = @()
    for ($m = [int](([Math]::Floor($last / 5) * 5) + 5); $m -le $newest; $m += 5) {
        if ($known -notcontains $m) { $out += $m }
    }
    if ($known -notcontains $newest -and $out -notcontains $newest) { $out += $newest }
    return $out
}

# Sequential rather than parallel: PowerShell background jobs cost more to start
# than these requests take, and this runs once per newly released milestone.
function Update-NewMilestones {
    $missing = Get-NewMilestones
    if ($missing.Count -eq 0) { return }
    Write-Host "Resolving $($missing.Count) new milestone(s) against the archive - once only." -ForegroundColor DarkGray
    $rows = @()
    foreach ($m in $missing) {
        $resolved = Resolve-MilestoneLive $m
        if ($resolved) { $rows += $resolved }
    }
    if ($rows.Count -gt 0) {
        Add-CacheRows $rows
        Update-Catalog
    }
}

# ---------- selector resolution ----------
# A selector is a milestone (74, M74) or a raw archive revision (638880).
# Milestones are small and revisions are six digits or more, so the split needs
# no extra syntax from the user.
# Chromium's identity on disk stays the bare revision it has always been, so
# builds already downloaded are still found, and its download URL is built from
# the snapshot archive layout rather than resolved.
function Add-ChromiumFields {
    param($sel)
    $sel.Engine = 'chromium'
    $sel.Id     = $sel.Revision
    $sel.Key    = Get-EngineKey 'chromium' $sel.Revision
    $sel.Url    = "$BaseUrl/$($sel.Platform)/$($sel.Revision)/$($sel.Archive)"
    $sel.Format = 'zip'
    return $sel
}

# A selector names an engine and a version: firefox:115, webkit:26.5. A bare
# number means Chromium, which is every selector this tool accepted before there
# was more than one engine.
#
# Returns, for every engine: Engine, Id (what identifies the build to its vendor,
# and what the on-disk name is built from), Key, Version (what to print - not
# always unique, two WebKit builds are both called 26.5), Platform, Url, Format,
# Root; and for Chromium also Milestone, Revision and Archive, which the snapshot
# archive needs and no other engine has an equivalent of.
function Resolve-Selector {
    param([string]$Raw)
    if (-not $Raw) {
        Die @"
Which version? A bare number is Chromium: 74. Otherwise name the engine:
   firefox:115   webkit:26.5   chromium:120
   Try: .\engineshelf.ps1 catalog
"@
    }

    $engine = 'chromium'
    $token = $Raw
    if ($Raw.Contains(':')) {
        $parts = $Raw.Split(':', 2)
        $engine = $parts[0].ToLowerInvariant()
        $token = $parts[1]
    }
    if (-not (Test-EngineKnown $engine)) { Die "Unknown engine: $engine. Known: $($EngineList -join ', ')" }
    if (-not $token) { Die "Which version of $(Get-EngineDisplay $engine)?" }

    if ($engine -ne 'chromium') {
        $sel = Resolve-Engine $engine $token
        $sel.Key = Get-EngineKey $sel.Engine $sel.Id
        # Fields the Chromium paths read; absent for every other engine.
        $sel.Milestone = ''
        $sel.Revision = ''
        $sel.Archive = ''
        return $sel
    }

    $token = $token -replace '^[MmRr]', ''
    if ($token -notmatch '^\d+$') { Die "Not a Chromium version or revision: $Raw" }

    if ([int64]$token -lt 1000) {
        $m = [int]$token
        if (-not ($CatalogBuilds.ContainsKey($m) -and $CatalogBuilds[$m].ContainsKey($HostPlatform))) {
            # Known to neither the cache nor the shipped catalog. Ask the archive,
            # keep the answer, and try once more - this is how a milestone released
            # after this copy was packaged becomes runnable without an update.
            Write-Host "Chromium $m is not catalogued here - asking the archive..." -ForegroundColor DarkGray
            $resolved = Resolve-MilestoneLive $m
            if ($resolved) { Add-CacheRows $resolved; Update-Catalog }
        }
        if (-not ($CatalogBuilds.ContainsKey($m) -and $CatalogBuilds[$m].ContainsKey($HostPlatform))) {
            Die "No $HostPlatform build of Chromium $m is available. It is in neither the catalog nor the cache, and the archive could not be reached to look it up. Try: .\engineshelf.ps1 catalog"
        }
        $b = $CatalogBuilds[$m][$HostPlatform]
        return Add-ChromiumFields @{ Milestone = "$m"; Version = $CatalogVersions[$m].Version
                  Platform = $HostPlatform; Revision = $b.Revision
                  Archive = $b.Archive; Root = $b.Root }
    }

    # Already installed: the recorded metadata answers without a network call.
    $meta = Get-Meta $token
    if ($meta.Count -gt 0) {
        return Add-ChromiumFields @{ Milestone = $meta['META_MILESTONE']
                  Version = $meta['META_VERSION']; Platform = $meta['META_PLATFORM']
                  Revision = $token; Archive = $meta['META_ARCHIVE']; Root = $meta['META_ROOT'] }
    }

    # A catalogued revision for this platform.
    foreach ($m in $CatalogOrder) {
        if ($CatalogBuilds.ContainsKey($m) -and $CatalogBuilds[$m].ContainsKey($HostPlatform)) {
            $b = $CatalogBuilds[$m][$HostPlatform]
            if ($b.Revision -eq $token) {
                return Add-ChromiumFields @{ Milestone = "$m"
                          Version = $CatalogVersions[$m].Version; Platform = $HostPlatform
                          Revision = $token; Archive = $b.Archive; Root = $b.Root }
            }
        }
    }

    # Unknown revision: believe the archive rather than guessing a filename.
    try {
        $listing = Invoke-RestMethod -Uri "${ListApi}?delimiter=/&prefix=${HostPlatform}/${token}/" -TimeoutSec 30
        $names = @()
        if ($listing.items) { $names = $listing.items | ForEach-Object { ($_.name -split '/')[-1] } }
    } catch {
        Die "Could not reach the Chromium snapshot archive to check revision $token."
    }
    foreach ($candidate in @('chrome-win.zip', 'chrome-win32.zip')) {
        if ($names -contains $candidate) {
            return Add-ChromiumFields @{ Milestone = '?'; Version = "r$token"
                      Platform = $HostPlatform; Revision = $token; Archive = $candidate
                      Root = ($candidate -replace '\.zip$', '') }
        }
    }
    Die "Revision $token is not archived for $HostPlatform. Pick a nearby position, or a catalogued version: .\engineshelf.ps1 catalog"
}

# key root [engine] -> the executable, asked of the engine itself.
function Get-BinaryPath {
    param($key, $root, $engine)
    if (-not $engine) { $engine = Get-EngineOfBuildKey $key }
    Get-EngineBinary $engine (Get-BuildDir $key) $root
}

# ---------- migration ----------
# The single-version layout was .chrome74\<revision>\ plus one shared profile.
# Adopt it once so an existing install is not re-downloaded. Only ever runs
# against the default root: an overridden home belongs to a different setup.
function Invoke-Migration {
    if (-not $RootIsDefault) { return }
    $legacy = Join-Path $env:USERPROFILE '.chrome74'
    if (-not (Test-Path $legacy)) { return }
    if (Test-Path (Join-Path $Root '.migrated')) { return }

    foreach ($dir in Get-ChildItem -Path $legacy -Directory -ErrorAction SilentlyContinue) {
        if ($dir.Name -notmatch '^\d+$') { continue }
        if (-not (Test-Path (Join-Path $dir.FullName '.complete'))) { continue }
        $target = Join-Path $BuildsDir $dir.Name
        if (Test-Path $target) { continue }
        try { Move-Item -Path $dir.FullName -Destination $target } catch { continue }

        $m = '?'; $version = "r$($dir.Name)"
        foreach ($ms in $CatalogOrder) {
            if ($CatalogBuilds.ContainsKey($ms) -and $CatalogBuilds[$ms].ContainsKey($HostPlatform) `
                -and $CatalogBuilds[$ms][$HostPlatform].Revision -eq $dir.Name) {
                $m = "$ms"; $version = $CatalogVersions[$ms].Version; break
            }
        }
        $root = 'chrome-win'
        if (-not (Test-Path (Join-Path $target 'chrome-win'))) { $root = 'chrome-win32' }
        Write-Meta $dir.Name $m $version $HostPlatform "$root.zip" $root
        Write-Info "Adopted the existing Chromium install (r$($dir.Name)) - not re-downloading."

        $legacyProfile = Join-Path $legacy 'profile'
        $targetProfile = Join-Path $ProfilesDir $dir.Name
        if ((Test-Path $legacyProfile) -and -not (Test-Path $targetProfile)) {
            try { Move-Item -Path $legacyProfile -Destination $targetProfile } catch { }
        }
    }
    New-Item -ItemType File -Force -Path (Join-Path $Root '.migrated') | Out-Null
}

# ---------- downloading ----------
# On macOS and Linux curl draws the meter and the manager reads the percentage
# straight out of it. Nothing here draws one: Invoke-WebRequest is ~20x slower
# with its progress bar on (see $ProgressPreference at the top), and with it off
# it prints nothing at all - so a 60-300 MB download was minutes of silence, the
# row stuck on "installing..." with no bar and the job log empty between
# "Downloading" and "Extracting".
#
# So the copying is done here, and this prints its own meter in the shape the
# page parses - see OWN_METER in gui/app.js, which is the other half of this and
# the only place that has to agree with it.
#
# One line per frame, not one carriage-return redraw: the Windows manager renders
# a log by re-reading the job's output file, and it holds back a trailing line
# with no newline behind it because a half-written line cannot be handed to the
# page. Consecutive frames are collapsed back into one line by the manager, the
# same way server.py collapses curl's.

# Deliberately not the page's mb(): this is what a human reads in the log, and a
# 232 MB archive should not be "232.4 MB".
#
# Formatted against the invariant culture, not the machine's. `-f` uses the
# current one, so on a Windows set to Vietnamese, German or French - anywhere the
# decimal separator is a comma - a gigabyte-sized archive printed "1,3 GB", which
# the page's meter pattern does not match. The row would have gone back to having
# no progress at all, on exactly the machines nobody tests on.
function Format-Bytes {
    param([long]$Bytes)
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1GB) { return [string]::Format($invariant, '{0:0.#} GB', ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return [string]::Format($invariant, '{0:0} MB', ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return [string]::Format($invariant, '{0:0} KB', ($Bytes / 1KB)) }
    return "$Bytes B"
}

# The same words gui/app.js puts beside a curl meter, so a Windows log and a
# macOS log read alike - and so the page can lift this straight out as the
# detail it shows on the row.
function Format-Left {
    param([int]$Seconds)
    if ($Seconds -le 0) { return '' }
    if ($Seconds -lt 60) { return "${Seconds}s left" }
    $minutes = [int][Math]::Floor($Seconds / 60)
    if ($minutes -lt 60) {
        $rest = $Seconds % 60
        if ($rest -gt 0) { return "${minutes}m ${rest}s left" }
        return "${minutes}m left"
    }
    return "$([int][Math]::Floor($minutes / 60))h $($minutes % 60)m left"
}

# This file is ASCII - PowerShell 5.1 reads a .ps1 with no BOM as ANSI - so the
# separator the page joins on is written as its code point.
$MeterDot = [string][char]0x00B7

function Write-Meter {
    param([long]$Done, [long]$Total, [datetime]$Started, [datetime]$Now)
    $seconds = ($Now - $Started).TotalSeconds
    $speed = ''
    if ($seconds -ge 1) { $speed = "$(Format-Bytes ([long]($Done / $seconds)))/s" }

    if ($Total -le 0) {
        # A server that will not say how big the file is. No percentage to give,
        # so the row shows the phase without a bar rather than a made-up number.
        $parts = @("$(Format-Bytes $Done) fetched", $speed) | Where-Object { $_ }
        Write-Host ('  ' + ($parts -join " $MeterDot "))
        return
    }

    $percent = [int][Math]::Floor(100 * $Done / $Total)
    if ($percent -gt 100) { $percent = 100 }
    $left = ''
    if ($seconds -ge 1 -and $Done -gt 0 -and $Done -lt $Total) {
        $left = Format-Left ([int](($Total - $Done) / ($Done / $seconds)))
    }
    # Bytes first, then the estimate, then the rate, then the percentage last:
    # the page reads the first two as the detail beside the bar and takes the
    # percentage off the end of the line.
    $parts = @("$(Format-Bytes $Done) / $(Format-Bytes $Total)", $left, $speed) |
             Where-Object { $_ }
    Write-Host ('  ' + ($parts -join " $MeterDot ") + "  $percent%")
}

function Save-Download {
    <#
      Fetch $Url to $Path, printing a meter as it goes.

      Fetched whole, like the other platforms: an archive that stops halfway is
      deleted by the caller rather than resumed, because a part-file that lies
      about being complete is the worse failure.
    #>
    param([string]$Url, [string]$Path)

    $request = [Net.HttpWebRequest]::Create($Url)
    # HttpWebRequest sends no user agent of its own and some CDNs answer 403 to
    # that; Invoke-WebRequest always sent one.
    $request.UserAgent = 'EngineShelf'
    $request.Timeout = 60000            # getting the response at all
    $request.ReadWriteTimeout = 120000  # a stalled connection mid-file
    $response = $request.GetResponse()

    $total = [long]$response.ContentLength
    $source = $response.GetResponseStream()
    $sink = [IO.File]::Create($Path)
    $buffer = New-Object byte[] (256 * 1024)
    $done = 0L
    $started = Get-Date
    $said = $started
    try {
        while ($true) {
            $read = $source.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $sink.Write($buffer, 0, $read)
            $done += $read
            # Twice a second. Often enough to watch, rare enough that a long
            # download does not fill the manager's buffer with meter frames.
            $now = Get-Date
            if (($now - $said).TotalMilliseconds -lt 500) { continue }
            $said = $now
            Write-Meter $done $total $started $now
        }
    } finally {
        $sink.Dispose()
        $source.Dispose()
        $response.Dispose()
    }

    # The last frame is the only one that says what actually arrived.
    Write-Meter $done $total $started (Get-Date)
    if ($total -gt 0 -and $done -lt $total) {
        throw "Connection closed after $(Format-Bytes $done) of $(Format-Bytes $total)."
    }
}

# ---------- install ----------
function Install-Build {
    param($sel)
    $key = $sel.Key
    # A build directory is removed before it is written, so an empty key here
    # would mean deleting builds\ itself and every browser already downloaded.
    # That is a resolver bug rather than user input, so it is a hard stop.
    if (-not $key -or $key.Contains('\\') -or $key.Contains('/')) {
        Die "Internal error: refusing to install with build key '$key'."
    }
    if (Test-Installed $key) { return }

    $name = Get-EngineDisplay $sel.Engine
    $dir = Get-BuildDir $key
    Write-Info ""
    Write-Info "Downloading $name $($sel.Version) ($($sel.Platform), one time only)"
    Write-Info "-> $dir"
    Write-Info "   ~60-300 MB, this can take a few minutes..."
    Write-Info ""

    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $Root ".download-$key.zip"

    try {
        Save-Download $sel.Url $zip
    } catch {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        Remove-Item -Force $zip -ErrorAction SilentlyContinue
        # The one way a cached Chromium row goes bad: the bucket dropped that
        # revision. Drop the row too, so the retry resolves afresh rather than
        # failing forever. No other engine has a cache to invalidate.
        if ($sel.Engine -eq 'chromium' -and $sel.Milestone -and $sel.Milestone -ne '?' `
            -and (Test-CacheMilestone $sel.Milestone)) {
            Remove-CacheMilestone $sel.Milestone
            Die "Download failed - r$($sel.Revision) is no longer in the archive. The stale entry has been forgotten; run the same command again to re-resolve."
        }
        Die "Download failed: $($_.Exception.Message)"
    }

    Write-Info "Extracting..."
    # Every Windows download is a plain zip - Chromium's snapshot, Mozilla's
    # candidates build, Playwright's win64 archive. The dmg, pkg, deb and tarball
    # handling in lib/engines.sh has no counterpart here because no vendor ships
    # those to Windows.
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
    } catch {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        Remove-Item -Force $zip -ErrorAction SilentlyContinue
        Die "Extraction failed: $($_.Exception.Message)"
    }
    Remove-Item -Force $zip

    $binary = Get-BinaryPath $key $sel.Root $sel.Engine
    if (-not (Test-Path $binary)) {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        Die @"
Expected browser binary missing: $binary
   The archive unpacked, but not into the shape this engine expects. Please
   report the engine and version.
"@
    }

    Write-Meta $key $sel.Milestone $sel.Version $sel.Platform $sel.Archive $sel.Root $sel.Engine
    New-Item -ItemType File -Force -Path (Join-Path $dir '.complete') | Out-Null
    Write-Ok "$name $($sel.Version) ready."
}

function Get-DirSize {
    param($path)
    if (-not (Test-Path $path)) { return 0 }
    $sum = (Get-ChildItem -Path $path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [int64]$sum
}

# ---------- commands ----------
function Invoke-Catalog {
    # Anything Chrome has shipped since this copy was packaged gets resolved and
    # cached here, so the list keeps growing without a new release of this tool.
    Update-NewMilestones
    Write-Host ""
    Write-Host "Available versions (host: $HostPlatform)" -ForegroundColor White
    Write-Host ""
    Write-Host "Chromium " -ForegroundColor White -NoNewline
    Write-Host "$($CatalogOrder.Count) catalogued milestones; any other snapshot revision works too" -ForegroundColor DarkGray
    Write-Host ""
    foreach ($m in $CatalogOrder) {
        $version = $CatalogVersions[$m].Version
        if (-not ($CatalogBuilds.ContainsKey($m) -and $CatalogBuilds[$m].ContainsKey($HostPlatform))) {
            Write-Host ("  {0,-6} {1,-16} no build for this host" -f $m, $version) -ForegroundColor DarkGray
            continue
        }
        $rev = $CatalogBuilds[$m][$HostPlatform].Revision
        if (Test-Installed $rev) { $state = 'installed'; $colour = 'Green' }
        else { $state = 'not installed'; $colour = 'DarkGray' }
        Write-Host ("  {0,-6} {1,-16} r{2,-9} " -f $m, $version, $rev) -NoNewline
        Write-Host $state -ForegroundColor $colour
    }
    foreach ($engine in $Engines) {
        if ($engine -ne 'chromium') { Show-EngineShelf $engine }
    }
    Write-Host ""
    Write-Host "Install and run:  .\engineshelf.ps1 run <version>   .\engineshelf.ps1 run firefox:115   .\engineshelf.ps1 run webkit:26.5" -ForegroundColor DarkGray
    if (Test-Path $CacheFile) {
        Write-Host "Milestones newer than this release are resolved live and cached in $CacheFile" -ForegroundColor DarkGray
    }
}

<#
  One engine's shelf, a line per year.

  Chromium gets the long form above because its identity is a snapshot revision,
  and the version, the revision and the platform are three different things you
  may need. The other three name their build after their own version, so the
  version is the whole answer - and there are nearly two hundred of them, which
  as one line each is a wall nobody reads.
#>
function Show-EngineShelf {
    param([string]$engine)

    # The cache is read after the shipped catalog and wins, which is the
    # precedence everything else here uses.
    $rows = @{}
    foreach ($path in @($script:Catalog, $script:CacheFile)) {
        if (-not (Test-Path $path)) { continue }
        foreach ($line in Get-Content $path) {
            $f = $line -split "`t"
            if ($f.Count -lt 6 -or $f[0] -ne 'S' -or $f[1] -ne $engine) { continue }
            $rows[$f[3]] = @{ year = [int]$f[2]; id = $f[3]; label = $f[4]; date = $f[5] }
        }
    }
    if ($rows.Count -eq 0) { return }

    $all = @($rows.Values | Sort-Object -Property { $_.date } -Descending)
    $years = @($all | ForEach-Object { $_.year } | Sort-Object -Unique -Descending)
    $name = $EngineNames[$engine]

    Write-Host ""
    Write-Host "$name " -ForegroundColor White -NoNewline
    Write-Host "$($all.Count) releases, $($years[-1]) - $($years[0])" -ForegroundColor DarkGray

    # WebKit reuses one Safari version across many builds - five releases all
    # call themselves 17.4 - so printing labels would list the same word five
    # times and only one of them could be asked for. Where labels are not unique
    # the build's own id is printed, because that is what resolves.
    $distinct = @($all | ForEach-Object { $_.label } | Sort-Object -Unique).Count
    $byLabel = ($distinct -eq $all.Count)
    if (-not $byLabel) {
        Write-Host "  shown by build, because $name reuses a version across builds" -ForegroundColor DarkGray
    }

    foreach ($year in $years) {
        Write-Host ("  {0,-6}" -f $year) -NoNewline
        foreach ($row in $all) {
            if ($row.year -ne $year) { continue }
            $shown = if ($byLabel) { $row.label } else { $row.id }
            Write-Host "  $shown" -NoNewline -ForegroundColor $(
                if (Test-Installed (Get-EngineKey $engine $row.id)) { 'Green' } else { 'Gray' })
        }
        Write-Host ""
    }
}

function Invoke-List {
    Write-Host ""
    Write-Host "Installed browsers ($Root)" -ForegroundColor White
    Write-Host ""
    $total = 0
    $any = $false
    foreach ($dir in Get-ChildItem -Path $BuildsDir -Directory -ErrorAction SilentlyContinue) {
        if (-not (Test-Installed $dir.Name)) { continue }
        $any = $true
        $meta = Get-Meta $dir.Name
        $size = Get-DirSize $dir.FullName
        $prof = Get-DirSize (Get-ProfileDir $dir.Name)
        $total += $size + $prof
        $version = $meta['META_VERSION']; if (-not $version) { $version = $dir.Name }
        $engine = $meta['META_ENGINE']
        if (-not $engine) { $engine = Get-EngineOfBuildKey $dir.Name }
        Write-Host ("  {0,-9} {1,-16} {2,-12} {3,7:N0} MB browser {4,7:N0} MB profile" -f `
            (Get-EngineDisplay $engine), $version, $meta['META_PLATFORM'], ($size / 1MB), ($prof / 1MB))
    }
    if (-not $any) {
        Write-Host "  Nothing installed yet. See: .\engineshelf.ps1 catalog" -ForegroundColor DarkGray
        Write-Host ""
        return
    }
    Write-Host ""
    Write-Host ("  Total: {0:N0} MB" -f ($total / 1MB)) -ForegroundColor DarkGray
    Write-Host "  Remove one with: .\engineshelf.ps1 remove <version|revision>" -ForegroundColor DarkGray
}

function Invoke-Run {
    param($sel, $rest)

    $url = ''; $windowSize = ''; $useGpu = $null; $autoRestart = $true; $extra = @()
    $i = 0
    while ($i -lt $rest.Count) {
        $a = [string]$rest[$i]
        switch -Regex ($a) {
            '^-{1,2}gpu$'        { $useGpu = $true;  $i++; break }
            '^-{1,2}no-gpu$'     { $useGpu = $false; $i++; break }
            '^-{1,2}no-restart$' { $autoRestart = $false; $i++; break }
            '^-{1,2}size$'       { $windowSize = [string]$rest[$i + 1]; $i += 2; break }
            '^--$'               { if ($i + 1 -lt $rest.Count) { $extra += $rest[($i + 1)..($rest.Count - 1)] }
                                   $i = $rest.Count; break }
            '^-'                 { Die "Unknown option: $a" }
            default              { $url = $a; $i++ }
        }
    }

    Install-Build $sel

    $binary     = Get-BinaryPath $sel.Key $sel.Root $sel.Engine
    $profileDir = Get-ProfileDir $sel.Key
    $log        = Get-LogFile $sel.Key
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    Set-EngineProfile $sel.Engine $profileDir

    # Bare host:port typed by hand - be forgiving.
    if ($url -ne '' -and $url -notmatch '^(https?|file|data)://' -and $url -notmatch '^about:') {
        $url = "http://$url"
    }

    # The flags that isolate the profile and disable the updater are the engine's
    # own answer: Chromium takes --user-data-dir, Firefox takes -profile, and the
    # WebKit MiniBrowser takes neither.
    $browserArgs = @(Get-EngineLaunchArgs $sel.Engine $profileDir)
    # Old GPU drivers are a common crash source when a years-old browser meets a
    # current driver. Software rendering costs a little speed and removes it.
    # These are Chromium switches; an unknown -flag opens a dialog in Firefox
    # rather than being ignored.
    if ($sel.Engine -eq 'chromium') {
        if ($useGpu -ne $true) { $browserArgs += '--disable-gpu' }
        if ($windowSize -ne '') { $browserArgs += "--window-size=$($windowSize -replace 'x', ',')" }
    } elseif ($sel.Engine -eq 'firefox' -and $windowSize -ne '') {
        $parts = $windowSize -split 'x'
        $browserArgs += @('-width', $parts[0], '-height', $parts[1])
    }
    $browserArgs += $extra

    $name = Get-EngineDisplay $sel.Engine
    Write-Host ""
    Write-Host "  > $name $($sel.Version) ($($sel.Platform))" -ForegroundColor Green
    if ($url -ne '') { Write-Host "  > $url" }
    Write-Host "  Profile: $profileDir" -ForegroundColor DarkGray
    Write-Host "  Log: $log" -ForegroundColor DarkGray
    Write-Host ""

    # Start-Process joins -ArgumentList with plain spaces and does not quote, so
    # any argument containing a space (a profile path under "C:\Users\Some Name")
    # would arrive at Chromium split into pieces.
    function Quote-Args { param($items) $items | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } } }

    $attempt = 0; $fastCrashes = 0
    $launchArgs = $browserArgs
    if ($url -ne '') { $launchArgs = $browserArgs + $url }

    while ($true) {
        $started = Get-Date
        $proc = Start-Process -FilePath $binary -ArgumentList (Quote-Args $launchArgs) -Wait -PassThru
        $status = $proc.ExitCode
        if ($status -eq 0) { break }   # user closed the window

        $ran = [int]((Get-Date) - $started).TotalSeconds
        if (-not $autoRestart) { Write-Warn "$name exited with status $status after ${ran}s."; exit $status }

        $attempt++
        # A fast crash still deserves a retry, but three in a row means the setup
        # itself is broken and looping would only spin.
        if ($ran -lt 5) { $fastCrashes++ } else { $fastCrashes = 0 }
        if ($fastCrashes -ge 3 -or $attempt -gt 5) {
            Write-Warn "$name crashed after ${ran}s (status $status), giving up after $attempt attempt(s)."
            exit $status
        }
        Write-Warn "$name crashed after ${ran}s - restarting ($attempt/5)."
        # Restoring the session is a Chromium switch; Firefox does it by itself
        # and would show an unknown-argument dialog instead.
        $launchArgs = $browserArgs
        if ($sel.Engine -eq 'chromium') { $launchArgs = $browserArgs + '--restore-last-session' }
    }
}

function Invoke-ResolveFor {
    <#
      Resolve one milestone for a platform this machine does not run, and print
      the revision. Not in the help, because nobody types it: engineshelf-docker
      needs the Linux x86_64 revision of a milestone while running on Windows,
      and the live resolver here has only ever asked about the host's own
      platform - which is why a container was on offer for the hand-catalogued
      milestones and no others. The answer lands in the same cache the native
      side writes, so the manager sees it on its next read.
    #>
    param([string]$Platform, [string]$Milestone)
    if (-not $Platform -or -not $Milestone) {
        Die "usage: engineshelf.ps1 resolve-for <platform> <milestone>"
    }
    if ($Milestone -notmatch '^\d+$') { Die "Not a milestone: $Milestone" }
    # What Resolve-MilestoneLive resolves against. Script scope, for this run only.
    $script:HostPlatform = $Platform
    $m = [int]$Milestone
    $build = $null
    if ($CatalogBuilds.ContainsKey($m)) { $build = $CatalogBuilds[$m][$Platform] }
    if (-not $build) {
        $rows = Resolve-MilestoneLive $m
        if ($rows) {
            Add-CacheRows $rows
            foreach ($line in $rows) {
                $f = $line -split "`t"
                if ($f[0] -eq 'B' -and $f[2] -eq $Platform) {
                    $build = @{ Revision = $f[3]; Archive = $f[4]; Root = $f[5] }
                }
            }
        }
    }
    if (-not $build) { Die "No $Platform build of Chromium $Milestone is available." }
    Write-Output $build.Revision
}

function Invoke-Probe {
    <#
      Can this host download this one version natively, right now? Exit 0 yes,
      1 no, and nothing on stdout: the status is the whole answer. Asked through
      the same resolver a launch uses, so the answer cannot drift from what a
      launch will find - which is the whole point of not reimplementing the
      vendor checks in the manager.

      Not in the help; nobody types it. The manager uses it to find where a
      vendor's archive stops.
    #>
    param([string]$Sel)
    try {
        Resolve-Selector $Sel | Out-Null
    } catch {
        exit 1
    }
    exit 0
}

# ---------- what the vendors still serve, and what a milestone is called -------
# A shelf row says a version was released. Whether it can still be downloaded is
# a different question and only the vendor can answer it: Playwright deletes its
# older WebKit archives, and seventy of the ninety-two Chromium milestones on the
# shelf carry no version string in the shipped catalog.
#
# On macOS and Linux the manager asks these questions itself, on background
# threads. This process is the answer to the same need on Windows, where the
# manager is a single thread serving HTTP and cannot go and wait on a CDN: it
# fires this hidden and never waits for it, and reads the answer off disk on a
# later poll. Which is why the storing lives here rather than there.
#
#   engineshelf.ps1 refresh-native webkit versions
#
# Not in the help; nobody types it.

$NativeFile = Join-Path $Root 'native.json'

function Read-NativeRecord {
    if (-not (Test-Path $NativeFile)) { return @{} }
    try {
        $found = @{}
        $data = Get-Content $NativeFile -Raw | ConvertFrom-Json
        foreach ($prop in $data.PSObject.Properties) { $found[$prop.Name] = $prop.Value }
        return $found
    } catch { return @{} }
}

function Write-NativeRecord {
    param($Record)
    $tmp = "$NativeFile.$PID"
    try {
        Set-Content -Path $tmp -Value ($Record | ConvertTo-Json -Depth 6 -Compress) -Encoding UTF8
        Move-Item -Path $tmp -Destination $NativeFile -Force
    } catch {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

function Get-EpochSeconds { return [int64](([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds) }

function Test-CanDownload {
    <# One probe, in this process: the resolver a launch uses, asked quietly. #>
    param([string]$Sel)
    try { Resolve-Selector $Sel | Out-Null } catch { return $false }
    return $true
}

function Get-WebKitFloor {
    <#
      The oldest WebKit build this host can still download, found by halving.

      Playwright deletes from the old end and never from the middle, so one probe
      rules out or admits half the shelf at a time: six requests instead of the
      fifty-three that asking about every row would take. Returns $null when even
      the newest has no archive for this host, which is the answer that means "no
      native WebKit here at all".
    #>
    $ids = @($CatalogShelf | Where-Object { $_.Engine -eq 'webkit' } |
             ForEach-Object { $_.Id } | Sort-Object)
    if ($ids.Count -eq 0) { return $null }
    if (-not (Test-CanDownload "webkit:$($ids[-1])")) { return $null }
    $low = 0
    $high = $ids.Count - 1
    while ($low -lt $high) {
        $middle = [int][Math]::Floor(($low + $high) / 2)
        if (Test-CanDownload "webkit:$($ids[$middle])") { $high = $middle }
        else { $low = $middle + 1 }
    }
    return $ids[$low]
}

function Set-MilestoneNames {
    <#
      Ask the dashboard what the uncatalogued Chromium milestones are called.

      One request each, and the answer is a V row in the catalog cache -
      permanent, because a branch point never moves. A V row with no B row beside
      it is exactly what this is: it says what Chromium 62 is called, not that a
      build of it has been found for this machine.

      Sequential, where the shell version fans out six at a time. Nothing waits
      on this process, and PowerShell 5.1 has no cheap way to parallelise that is
      worth the two dozen lines of runspace plumbing.
    #>
    $rows = @()
    foreach ($row in $CatalogShelf) {
        if ($row.Engine -ne 'chromium') { continue }
        if ($row.Id -notmatch '^\d+$') { continue }
        $m = [int]$row.Id
        if ($CatalogVersions.ContainsKey($m)) { continue }
        $info = Get-MilestoneInfo $m
        if (-not $info -or -not $info.Branch) { continue }
        # No note: this row is a name, not a changelog, and the page shows the
        # note as what a version brought.
        $rows += "V`t$m`t$m.0.$($info.Branch).0`t"
    }
    if ($rows.Count) { Add-CacheRows $rows }
    return $rows.Count
}

function Invoke-RefreshNative {
    param([string[]]$What)
    $wanted = @($What | Where-Object { $_ })
    if ($wanted.Count -eq 0) { $wanted = @('webkit', 'versions') }
    foreach ($item in $wanted) {
        if (@('webkit', 'versions') -notcontains $item) {
            Die "Nothing to refresh called '$item' (one of: webkit, versions)"
        }
    }

    # Read once, write once, at the end: two of these running at the same time
    # would otherwise each write back what it read.
    $record = Read-NativeRecord
    foreach ($item in $wanted) {
        if ($item -eq 'webkit') {
            $floor = Get-WebKitFloor
            Write-Info "webkit floor: $(if ($null -ne $floor) { $floor } else { 'none downloadable' })"
            $record['webkit'] = @{ floor = $floor; at = (Get-EpochSeconds) }
        } else {
            $named = Set-MilestoneNames
            Write-Info "named $named milestone$(if ($named -eq 1) { '' } else { 's' })"
            # Stamped even when nothing could be resolved, so a dashboard that is
            # down does not turn into a request every four seconds for as long as
            # the manager is open.
            $record['versions'] = @{ at = (Get-EpochSeconds) }
        }
    }
    Write-NativeRecord $record
}

function Invoke-Doctor {
    param([string[]]$Options)

    if ($Options -contains '--json') {
        Get-PfReport | ConvertTo-Json -Depth 6 -Compress
        return
    }

    if ($Options -contains '--install') {
        $index = [array]::IndexOf($Options, '--install')
        $component = $Options[$index + 1]
        if (-not $component) { Die "Which component? e.g. --install docker" }
        if ($PfComponents -notcontains $component) {
            Die "Unknown component: $component (one of: $($PfComponents -join ', '))"
        }
        $null = Invoke-PfFix $component -AssumeYes:($Options -contains '--yes' -or $Options -contains '-y')
        return
    }

    $problems = Show-PfReport
    if (-not $problems) { return }

    foreach ($c in $problems) {
        Write-Host "  $($c.label) - $($c.why)" -ForegroundColor DarkGray
    }
    Write-Host ""

    if ($Options -notcontains '--fix') {
        Write-Host "  Offer to install the missing pieces:  .\engineshelf.ps1 doctor --fix" -ForegroundColor DarkGray
        Write-Host ""
        return
    }
    foreach ($c in $problems) {
        $null = Invoke-PfFix $c.id -AssumeYes:($Options -contains '--yes' -or $Options -contains '-y')
    }
}

function Show-Usage {
    Write-Host ""
    Write-Host "EngineShelf - run an old Chromium engine on a modern machine" -ForegroundColor White
    Write-Host ""
    Write-Host "  .\engineshelf.ps1 <command> [args]"
    Write-Host ""
    Write-Host "  catalog                 List the Chromium versions available for this host"
    Write-Host "  list                    List what is installed, with disk usage"
    Write-Host "  run <version> [url]     Install if needed, then launch"
    Write-Host "  install <version>       Download without launching"
    Write-Host "  remove <version>        Delete a downloaded browser"
    Write-Host "        --with-profile    ...and its profile"
    Write-Host "  clean <version>         Reset a version's profile (cookies, logins)"
    Write-Host "  doctor                  Check that everything this needs is installed"
    Write-Host "        --fix             ...and offer to install what is missing"
    Write-Host "  gui                     Open the graphical manager"
    Write-Host ""
    Write-Host "  <version> is a milestone (74) or a snapshot revision (638880)."
    Write-Host ""
    Write-Host "  Options for run:  --size WxH   --gpu / --no-gpu   --no-restart"
    Write-Host ""
    Write-Host "  Each version keeps its own profile, so a newer build never upgrades a"
    Write-Host "  profile out from under an older one."
    Write-Host ""
    Write-Host "  Files live in $Root (override with ENGINESHELF_HOME)."
    Write-Host ""
}

Invoke-Migration

switch -Regex ($Command) {
    '^(catalog|versions)$' { Invoke-Catalog; break }
    '^(list|ls)$'          { Invoke-List; break }
    '^(run|launch)$'       { Invoke-Run (Resolve-Selector $Selector) $Rest; break }
    '^install$'            { Install-Build (Resolve-Selector $Selector); break }
    '^(remove|rm|uninstall)$' {
        $sel = Resolve-Selector $Selector
        $dir = Get-BuildDir $sel.Revision
        if (Test-Path $dir) {
            Remove-Item -Recurse -Force $dir
            Write-Ok "Removed Chromium $($sel.Version) (r$($sel.Revision))."
        } else {
            Write-Warn "Chromium $($sel.Version) (r$($sel.Revision)) was not installed."
        }
        if ($Rest -contains '--with-profile') {
            $p = Get-ProfileDir $sel.Revision
            if (Test-Path $p) { Remove-Item -Recurse -Force $p }
        }
        Remove-Item -Force (Get-LogFile $sel.Revision) -ErrorAction SilentlyContinue
        break
    }
    '^clean$' {
        $sel = Resolve-Selector $Selector
        $p = Get-ProfileDir $sel.Revision
        if (Test-Path $p) { Remove-Item -Recurse -Force $p }
        Write-Ok "Profile reset for Chromium $($sel.Version) (r$($sel.Revision))."
        break
    }
    '^(doctor|check)$'     { Invoke-Doctor (@($Selector) + $Rest | Where-Object { $_ }); break }
    '^resolve-for$'        { Invoke-ResolveFor $Selector $Rest[0]; break }
    '^probe$'              { Invoke-Probe $Selector; break }
    '^refresh-native$'     { Invoke-RefreshNative (@($Selector) + $Rest | Where-Object { $_ }); break }
    '^gui$'                { & (Join-Path $ScriptDir 'gui.ps1') @Rest; break }
    '^(|-h|--help|help)$'  { Show-Usage; break }
    default                { Die "Unknown command: $Command (try --help)" }
}
