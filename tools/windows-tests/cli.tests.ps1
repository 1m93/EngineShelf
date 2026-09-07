#
# What engineshelf.ps1 grew: its own download meter, and the refresh that asks
# the vendors what they still serve.
#
# The meter is checked against the regex gui/app.js actually ships, read out of
# that file - the two are a contract, and a test that restated the pattern would
# keep passing after the page had changed.
#
param([string]$Port = '8899')

$ErrorActionPreference = 'Stop'

$work = Join-Path ([IO.Path]::GetTempPath()) ("es-cli-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Read before the harness runs: the lifted $NativeFile is built from it.
$Root = $work

$LiftFrom = './engineshelf.ps1'
$LiftFunctions = @(
    'Format-Bytes', 'Format-Left', 'Write-Meter', 'Save-Download',
    'Read-NativeRecord', 'Write-NativeRecord', 'Get-EpochSeconds',
    'Test-CanDownload', 'Get-WebKitFloor', 'Set-MilestoneNames',
    'Invoke-RefreshNative'
)
$LiftVariables = @('MeterDot', 'NativeFile')
. "$PSScriptRoot/harness.ps1"

function Write-Info { param($m) Write-Host $m }
function Die { param($m) throw $m }

# The shelf and catalog the real file fills in from disk.
$CatalogShelf = @()
$CatalogVersions = @{}
$script:probeAnswers = @{}
$script:resolveCalls = @()
function Resolve-Selector {
    param([string]$Sel)
    $script:resolveCalls += $Sel
    if ($script:probeAnswers[$Sel]) { return @{ ok = $true } }
    throw "nothing serves $Sel"
}
$script:cacheRows = @()
function Add-CacheRows { param($rows) $script:cacheRows += @($rows) }
$script:milestoneInfo = @{}
function Get-MilestoneInfo { param($m) return $script:milestoneInfo["$m"] }

# ---- the page's half of the meter contract ------------------------------- #
$appJs = Get-Content './gui/app.js' -Raw
$found = [regex]::Match($appJs, '(?s)const OWN_METER\s*=\s*\r?\n?\s*/(.+?)/;')
if (-not $found.Success) { throw 'gui/app.js has no OWN_METER pattern' }
$OwnMeter = [regex]::new($found.Groups[1].Value)

Write-Host ''
Write-Host 'the pattern the page ships'
Test-That 'found in gui/app.js' ($OwnMeter.ToString().Length -gt 20) $true

Write-Host ''
Write-Host 'byte counts a human reads'
# Under a culture whose decimal separator is a comma - this machine is en-VN -
# which is what the page's pattern would not match.
[Threading.Thread]::CurrentThread.CurrentCulture = 'de-DE'
Test-That 'bytes' (Format-Bytes 512) '512 B'
Test-That 'kilobytes' (Format-Bytes 2048) '2 KB'
Test-That 'megabytes, whole' (Format-Bytes (232 * 1MB)) '232 MB'
Test-That 'gigabytes keep one place' (Format-Bytes ([long](1.25 * 1GB))) '1.3 GB'

Write-Host ''
Write-Host 'the words the page already uses for what is left'
Test-That 'seconds' (Format-Left 16) '16s left'
Test-That 'minutes and seconds' (Format-Left 125) '2m 5s left'
Test-That 'whole minutes' (Format-Left 300) '5m left'
Test-That 'hours' (Format-Left 3900) '1h 5m left'
Test-That 'nothing to say' (Format-Left 0) ''

Write-Host ''
Write-Host 'a meter frame'
$started = (Get-Date).AddSeconds(-8)
$line = (Write-Meter (100 * 1MB) (232 * 1MB) $started (Get-Date) 6>&1 | Out-String).Trim("`r", "`n")
Write-Host "       $line"
$m = $OwnMeter.Match($line)
Test-That 'the page can read it' $m.Success $true
Test-That 'bytes come out whole' $m.Groups[1].Value '100 MB / 232 MB'
# 100 MB in 8 seconds is 12.5 MB/s, so the remaining 132 MB is eleven seconds.
Test-That 'and the estimate with them' $m.Groups[2].Value.Trim() '11s left'
Test-That 'and the percentage' $m.Groups[3].Value '43'
Test-That 'the rate is in the line for a human' ($line -match 'MB/s') $true

# The page falls back to any line ending in a percentage, so that has to hold too.
Test-That 'percentage is last on the line' ($line -match '43%$') $true

Write-Host ''
Write-Host 'a meter frame with nothing to estimate from'
$line = (Write-Meter 1024 (232 * 1MB) (Get-Date) (Get-Date) 6>&1 | Out-String).Trim("`r", "`n")
Write-Host "       $line"
$m = $OwnMeter.Match($line)
Test-That 'still readable' $m.Success $true
Test-That 'bytes still there' $m.Groups[1].Value '1 KB / 232 MB'
Test-That 'no estimate claimed' $m.Groups[2].Value ''
Test-That 'zero percent' $m.Groups[3].Value '0'

Write-Host ''
Write-Host 'a server that will not say how big the file is'
$line = (Write-Meter (104 * 1MB) -1 $started (Get-Date) 6>&1 | Out-String).Trim("`r", "`n")
Write-Host "       $line"
Test-That 'says what arrived' ($line -match '^\s*104 MB fetched') $true
Test-That 'and claims no percentage' ($line -match '%') $false
Test-That 'the manager still folds it as a frame' ($line -match '^\s*\d[\d.]* [KMGT]?B (/|fetched)') $true

Write-Host ''
Write-Host 'a real download'
# Served locally, because what is being checked is the copying and the meter, not
# a vendor's CDN. Windows ships no python3; the launcher's own downloads need
# nothing but PowerShell, so this one block is skipped where there is none.
$python = $null
foreach ($name in @('python3', 'python')) {
    if (Get-Command $name -ErrorAction SilentlyContinue) { $python = $name; break }
}
if (-not $python) { Write-Host '  skip  no python here to serve a file from' }
else {
$payload = Join-Path $work 'payload.bin'
$bytes = New-Object byte[] (6 * 1MB)
(New-Object Random 7).NextBytes($bytes)
[IO.File]::WriteAllBytes($payload, $bytes)

$server = Start-Process -FilePath $python -PassThru `
    -ArgumentList @('-m', 'http.server', $Port, '--bind', '127.0.0.1', '--directory', $work) `
    -RedirectStandardOutput (Join-Path $work 'httpd.out') `
    -RedirectStandardError (Join-Path $work 'httpd.err')
Start-Sleep -Seconds 2
try {
    $target = Join-Path $work 'fetched.bin'
    $out = (Save-Download "http://127.0.0.1:$Port/payload.bin" $target 6>&1 | Out-String)
    $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() })
    Test-That 'the file arrived whole' (Get-Item $target).Length $bytes.Length
    $sameBytes = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($target)))
    $wantBytes = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash($bytes))
    Test-That 'byte for byte' $sameBytes $wantBytes
    Test-That 'it said something on the way' ($lines.Count -ge 1) $true
    $last = $lines[-1]
    Write-Host "       $last"
    Test-That 'the last frame is 100%' ($last -match '100%$') $true
    Test-That 'and the page can read it' $OwnMeter.IsMatch($last) $true
    foreach ($frame in $lines) {
        if (-not $OwnMeter.IsMatch($frame)) {
            Test-That "every frame is readable ($frame)" $false $true
        }
    }
    Test-That 'every frame is readable' $true $true

    Write-Host ''
    Write-Host 'a download that is not there'
    $threw = $false
    try { Save-Download "http://127.0.0.1:$Port/nope.bin" (Join-Path $work 'nope.bin') 6>&1 | Out-Null }
    catch { $threw = $true }
    Test-That 'fails loudly, for the caller to clean up after' $threw $true
} finally {
    if ($server -and -not $server.HasExited) { $server.Kill() }
}
}

Write-Host ''
Write-Host 'the native record'
Test-That 'nothing on file reads as nothing' (Read-NativeRecord).Count 0
Write-NativeRecord @{ webkit = @{ floor = '1446'; at = 12345 } }
$record = Read-NativeRecord
Test-That 'what was written comes back' $record['webkit'].floor '1446'
Test-That 'with its stamp' $record['webkit'].at 12345
Test-That 'and the file is where the manager looks' (Test-Path (Join-Path $work 'native.json')) $true
$broken = Join-Path $work 'native.json'
[IO.File]::WriteAllText($broken, 'not json')
Test-That 'a corrupt record reads as nothing' (Read-NativeRecord).Count 0

Write-Host ''
Write-Host 'where the WebKit archive stops'
# Playwright deletes from the old end, so a floor of 1516 means 1446 and 1472 are
# gone and everything from 1516 up is still there.
$ids = @('1446', '1472', '1516', '1530', '2287', '2311', '2336')
$CatalogShelf = @($ids | ForEach-Object { @{ Engine = 'webkit'; Id = $_; Label = "r$_" } })
$script:probeAnswers = @{}
foreach ($id in @('1516', '1530', '2287', '2311', '2336')) { $script:probeAnswers["webkit:$id"] = $true }
$script:resolveCalls = @()
Test-That 'found by halving' (Get-WebKitFloor) '1516'
Test-That 'in six probes, not seven rows' ($script:resolveCalls.Count -le 4) $true
Test-That 'asked through the launch resolver' ($script:resolveCalls[0] -match '^webkit:') $true

$script:probeAnswers = @{}
Test-That 'nothing downloadable at all is null' (Get-WebKitFloor) $null
$script:probeAnswers = @{}
foreach ($id in $ids) { $script:probeAnswers["webkit:$id"] = $true }
Test-That 'everything still served is the oldest row' (Get-WebKitFloor) '1446'
$CatalogShelf = @()
Test-That 'no rows, no floor' (Get-WebKitFloor) $null

Write-Host ''
Write-Host 'naming the uncatalogued milestones'
$CatalogShelf = @(
    @{ Engine = 'chromium'; Id = '60'; Label = '60' }
    @{ Engine = 'chromium'; Id = '61'; Label = '61' }
    @{ Engine = 'chromium'; Id = '62'; Label = '62' }
    @{ Engine = 'firefox';  Id = '115'; Label = '115.0' }
)
$CatalogVersions = @{ 60 = @{ Version = '60.0.3112.113'; Note = '2017' } }
$script:milestoneInfo = @{ '61' = @{ Branch = '3163' }; '62' = @{ Branch = '3202' } }
$script:cacheRows = @()
Test-That 'two to name' (Set-MilestoneNames) 2
Test-That 'written as V rows' @($script:cacheRows) @("V`t61`t61.0.3163.0`t", "V`t62`t62.0.3202.0`t")
Test-That 'the one already named was left alone' ($script:cacheRows -join '' -notmatch '`t60`t') $true

$script:milestoneInfo = @{}
$script:cacheRows = @()
Test-That 'a dashboard that says nothing writes nothing' (Set-MilestoneNames) 0
Test-That 'and no rows' @($script:cacheRows).Count 0

Write-Host ''
Write-Host 'the whole refresh'
Remove-Item (Join-Path $work 'native.json') -Force -ErrorAction SilentlyContinue
$CatalogShelf = @(
    @{ Engine = 'webkit'; Id = '1446'; Label = 'r1446' }
    @{ Engine = 'webkit'; Id = '2336'; Label = 'r2336' }
    @{ Engine = 'chromium'; Id = '61'; Label = '61' }
)
$CatalogVersions = @{}
$script:probeAnswers = @{ 'webkit:2336' = $true }
$script:milestoneInfo = @{ '61' = @{ Branch = '3163' } }
$script:cacheRows = @()
Invoke-RefreshNative @('webkit', 'versions') 6>&1 | Out-Null
$record = Read-NativeRecord
Test-That 'the floor is stored' $record['webkit'].floor '2336'
Test-That 'stamped' ($record['webkit'].at -gt 1700000000) $true
Test-That 'the versions pass is stamped too' ($record['versions'].at -gt 1700000000) $true
Test-That 'and its rows went to the catalog cache' @($script:cacheRows).Count 1

# One entry at a time must not lose the other: read once, write once.
$script:probeAnswers = @{}
Invoke-RefreshNative @('webkit') 6>&1 | Out-Null
$record = Read-NativeRecord
Test-That 'a second pass rewrites its own entry' $record['webkit'].floor $null
Test-That 'and keeps the other one' ($record['versions'].at -gt 1700000000) $true

$threw = $false
try { Invoke-RefreshNative @('nonsense') 6>&1 | Out-Null } catch { $threw = $true }
Test-That 'an unknown thing to refresh is refused' $threw $true

Remove-Item -Recurse -Force $work
Exit-WithTally
