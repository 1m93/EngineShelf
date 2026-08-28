#
# The caches gui/server.ps1 grew so that a state poll stops walking every
# installed browser and running `docker info`, and the one place that notices a
# job has ended and drops them.
#
$ErrorActionPreference = 'Stop'

$LiftFrom = './gui/server.ps1'
$LiftFunctions = @(
    'Get-DirSize', 'Clear-SizeCache', 'Get-DoctorReport', 'Clear-DoctorCache',
    'Get-JobState', 'Get-JobBrief', 'Test-NativeStale', 'Start-NativeRefresh',
    'Test-MeterLine', 'Split-JobText', 'Get-JobLines', 'Read-JobFile'
)
$LiftVariables = @(
    'SizeCache', 'SizeTtlSeconds', 'DoctorCache', 'DoctorTtlSeconds',
    'DockerCache', 'VolumeCache', 'NativeTtl', 'NativeRetrySeconds',
    'NativeAsked', 'StreamRule', 'StreamDot'
)
. "$PSScriptRoot/harness.ps1"

$script:Cli = 'engineshelf.ps1'
$script:pfCalls = 0
$script:pfThrows = $false
function Get-PfReport {
    $script:pfCalls++
    if ($script:pfThrows) { throw 'no docker here' }
    return [ordered]@{ os = 'windows'; arch = 'AMD64'
                       components = @(@{ id = 'docker'; status = 'missing' }) }
}
$script:spawned = @()
function Start-Process { $script:spawned += ,@($args) }

class FakeProc {
    [bool]$HasExited = $false
    [int]$ExitCode = 0
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("es-cache-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

Write-Host ''
Write-Host 'the size cache'
$tree = Join-Path $work 'builds'
New-Item -ItemType Directory -Force -Path $tree | Out-Null
[IO.File]::WriteAllBytes((Join-Path $tree 'a.bin'), (New-Object byte[] 1000))
Test-That 'measures what is there' (Get-DirSize $tree) 1000
[IO.File]::WriteAllBytes((Join-Path $tree 'b.bin'), (New-Object byte[] 500))
Test-That 'answers from the cache within the ttl' (Get-DirSize $tree) 1000
Clear-SizeCache
Test-That 'and measures again once dropped' (Get-DirSize $tree) 1500
Test-That 'ttl matches server.py' $SizeTtlSeconds 15
Test-That 'a directory that is not there is 0' (Get-DirSize (Join-Path $work 'nope')) 0

Write-Host ''
Write-Host 'the doctor cache'
$script:pfCalls = 0
$first = Get-DoctorReport
$null = Get-DoctorReport
$null = Get-DoctorReport
Test-That 'the report is built once' $script:pfCalls 1
Test-That 'and it is the report' $first.components[0].id 'docker'
Clear-DoctorCache
$null = Get-DoctorReport
Test-That 'built again once dropped' $script:pfCalls 2
Test-That 'ttl matches server.py' $DoctorTtlSeconds 12

$script:pfThrows = $true
Clear-DoctorCache
$script:pfCalls = 0
$blank = Get-DoctorReport
Test-That 'a check that threw still answers' @($blank.components).Count 0
$null = Get-DoctorReport
Test-That 'and is not cached as the answer' $script:pfCalls 2
$script:pfThrows = $false

Write-Host ''
Write-Host 'a job ending drops all of it'
$out = Join-Path $work '1.out'
$err = Join-Path $work '1.err'
[IO.File]::WriteAllText($out, '')
[IO.File]::WriteAllText($err, '')
$job = @{ id = '1'; kind = 'doctor'; revision = 'docker'; label = 'Installing docker'
          proc = [FakeProc]::new(); out = $out; err = $err; stopping = $false
          settled = $false; stream = 'doctor:docker'; action = $null
          startedAt = '03:37:56'; lineCache = $null; lineFinal = $false }

$null = Get-DirSize $tree                     # warm
$null = Get-DoctorReport
$script:DockerCache = @{ At = (Get-Date); Value = 'held' }
$script:VolumeCache = @{ At = (Get-Date); Value = 'held' }
Test-That 'still running, nothing dropped' (Get-JobState $job).status 'running'
Test-That 'docker answer still held' $script:DockerCache.Value 'held'

$job.proc.HasExited = $true
$script:pfCalls = 0
Test-That 'reads as finished' (Get-JobState $job).status 'done'
Test-That 'docker answer dropped' $script:DockerCache.Value $null
Test-That 'volume answer dropped' $script:VolumeCache.Value $null
Test-That 'doctor answer dropped' $script:DoctorCache.Value $null
[IO.File]::WriteAllBytes((Join-Path $tree 'c.bin'), (New-Object byte[] 200))
Test-That 'sizes measured afresh' (Get-DirSize $tree) 1700

# Once per job: this runs several times a second.
$script:DockerCache = @{ At = (Get-Date); Value = 'held again' }
$null = Get-JobState $job
$null = Get-JobState $job
Test-That 'and only the first time' $script:DockerCache.Value 'held again'

Write-Host ''
Write-Host 'the states a job can end in'
$stopped = $job.Clone(); $stopped.stopping = $true; $stopped.settled = $true
Test-That 'stopped' (Get-JobState $stopped).status 'stopped'
$failed = $job.Clone(); $failed.settled = $true
$failed.proc = [FakeProc]::new(); $failed.proc.HasExited = $true; $failed.proc.ExitCode = 3
Test-That 'failed' (Get-JobState $failed).status 'error'
Test-That 'with the code' (Get-JobState $failed).code 3

Write-Host ''
Write-Host 'meter frames collapse'
Test-That 'a frame with a total is one' (Test-MeterLine '  100 MB / 232 MB 16s left  43%') $true
Test-That 'a frame without one is too' (Test-MeterLine '  104 MB fetched') $true
Test-That 'ordinary output is not' (Test-MeterLine '  Extracting...') $false
Test-That 'nor is a line that merely holds bytes' (Test-MeterLine '  -> 232 MB total') $false

$job2 = $job.Clone()
$job2.lineCache = $null; $job2.lineFinal = $false
$job2.proc = [FakeProc]::new()
$frames = @()
for ($i = 1; $i -le 40; $i++) { $frames += "  $i MB / 40 MB  $($i * 2)%" }
[IO.File]::WriteAllText($out, (($frames + @('  Extracting...', '')) -join "`r`n"))
$lines = @(Get-JobLines $job2)
# blank, divider, blank, one collapsed meter, "Extracting..."
Test-That 'forty frames become one line' $lines.Count 5
Test-That 'and it is the newest frame' $lines[3] '  40 MB / 40 MB  80%'
Test-That 'what came after survives' $lines[4] '  Extracting...'

Write-Host ''
Write-Host 'when to ask a vendor again'
$now = [int64](([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds)
Test-That 'ttls match server.py' @($NativeTtl['webkit'], $NativeTtl['versions']) @(259200, 604800)
Test-That 'no record at all is stale' (Test-NativeStale $null 'webkit') $true
$fresh = @{ webkit = @{ floor = '1446'; at = $now } } | ConvertTo-Json | ConvertFrom-Json
Test-That 'a fresh answer is not' (Test-NativeStale $fresh 'webkit') $false
Test-That 'and says nothing about the other' (Test-NativeStale $fresh 'versions') $true
$old = @{ webkit = @{ floor = '1446'; at = ($now - 300000) } } | ConvertTo-Json | ConvertFrom-Json
Test-That 'past the ttl it is stale again' (Test-NativeStale $old 'webkit') $true
$noStamp = @{ webkit = @{ floor = '1446' } } | ConvertTo-Json | ConvertFrom-Json
Test-That 'an answer with no stamp is stale' (Test-NativeStale $noStamp 'webkit') $true
# floor = null is an answer - "nothing here is downloadable" - not a missing one.
$none = @{ webkit = @{ floor = $null; at = $now } } | ConvertTo-Json | ConvertFrom-Json
Test-That 'a negative answer is still an answer' (Test-NativeStale $none 'webkit') $false

Write-Host ''
Write-Host 'firing the refresh'
$script:NativeAsked = [datetime]::MinValue
$script:spawned = @()
Start-NativeRefresh $null
Test-That 'one child, not one per answer' $script:spawned.Count 1
$argv = @($script:spawned[0] | ForEach-Object { $_ }) -join ' '
Test-That 'runs the CLI command' ($argv -match 'refresh-native webkit versions') $true
Test-That 'hidden' ($argv -match 'Hidden') $true

Start-NativeRefresh $null
Test-That 'not again inside the retry window' $script:spawned.Count 1
Test-That 'window is ten minutes' $NativeRetrySeconds 600

$script:NativeAsked = [datetime]::MinValue
$script:spawned = @()
Start-NativeRefresh $fresh
$argv = @($script:spawned[0] | ForEach-Object { $_ }) -join ' '
Test-That 'only what is stale is asked for' ($argv -match 'refresh-native versions$') $true

$script:NativeAsked = [datetime]::MinValue
$script:spawned = @()
$both = @{ webkit = @{ floor = '1446'; at = $now }; versions = @{ at = $now } } |
        ConvertTo-Json | ConvertFrom-Json
Start-NativeRefresh $both
Test-That 'nothing stale, no child' $script:spawned.Count 0

Remove-Item -Recurse -Force $work
Exit-WithTally
