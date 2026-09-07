#
# The stream layer in gui/server.ps1 - one log per target, rendered from the job
# files - exercised without starting a server.
#
$ErrorActionPreference = 'Stop'

$LiftFrom = @('./gui/server.ps1', './lib/preflight.ps1')
$LiftFunctions = @(
    'Get-StreamKey', 'Get-StreamLabel', 'Resolve-Stream', 'Get-StreamUpdated',
    'Remove-IdleStreams', 'Get-JobState', 'Get-JobBrief', 'Split-JobText',
    'Test-MeterLine', 'Get-JobLines', 'Get-StreamJobs', 'Get-StreamRunning',
    'Get-StreamLatest', 'Get-StreamLog', 'Get-StreamList', 'Read-JobFile',
    'Get-Field', 'Clear-SizeCache', 'Clear-DoctorCache', 'Quote-Args',
    'Clear-DockerRoute', 'Get-DockerRoute'
)
$LiftVariables = @(
    'StreamLines', 'StreamMax', 'StreamRule', 'StreamDot', 'StreamPattern',
    'Streams', 'SizeCache', 'DoctorCache', 'DockerCache', 'VolumeCache',
    'PfDockerRoute'
)
. "$PSScriptRoot/harness.ps1"

$script:Jobs = @{}
$script:next = 1



$JobsDir = Join-Path ([IO.Path]::GetTempPath()) ("es-stream-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $JobsDir | Out-Null

class FakeProc {
    [bool]$HasExited = $false
    [int]$ExitCode = 0
}

# What Start-Job2 does, minus Start-Process. Its parameter list is checked
# against the real one in routes.tests.ps1.
function New-TestJob {
    param([string]$Kind, [string]$Revision, [string]$Label, [string]$Stream,
          [string]$StreamLabel, [string]$Action = $null)
    $id = [string]$script:next
    $script:next++
    $out = Join-Path $JobsDir "$id.out"
    $err = Join-Path $JobsDir "$id.err"
    [IO.File]::WriteAllText($out, '')
    [IO.File]::WriteAllText($err, '')
    $key = if ($Stream) { $Stream } else { "sel:$Revision" }
    $script:Jobs[$id] = @{
        id = $id; kind = $Kind; revision = $Revision; label = $Label
        proc = [FakeProc]::new(); out = $out; err = $err; stopping = $false
        settled = $false; stream = $key; action = $Action
        startedAt = '03:37:56'; lineCache = $null; lineFinal = $false
    }
    $log = Resolve-Stream $key $StreamLabel
    [void]$log.jobs.Add($id)
    return $id
}

function Write-JobOut { param([string]$Id, [string]$Text) [IO.File]::AppendAllText($script:Jobs[$Id].out, $Text) }
function Stop-TestJob {
    param([string]$Id, [int]$Code = 0)
    $script:Jobs[$Id].proc.ExitCode = $Code
    $script:Jobs[$Id].proc.HasExited = $true
}

Write-Host ''
Write-Host 'stream keys and labels'
$body = '{"stream":"chromium:105","streamLabel":"Chromium 105"}' | ConvertFrom-Json
Test-That 'key off the body' (Get-StreamKey $body '1181205') 'chromium:105'
Test-That 'label off the body' (Get-StreamLabel $body) 'Chromium 105'
Test-That 'no stream falls back to the selector' (Get-StreamKey (@{} | ConvertTo-Json | ConvertFrom-Json) '74') 'sel:74'
$bad = '{"stream":"../etc/passwd"}' | ConvertFrom-Json
Test-That 'a malformed key is refused, not used' (Get-StreamKey $bad '74') 'sel:74'
$long = @{ streamLabel = ('x' * 200) } | ConvertTo-Json | ConvertFrom-Json
Test-That 'a long label is trimmed to 80' (Get-StreamLabel $long).Length 80

Write-Host ''
Write-Host 'one job, running'
$a = New-TestJob 'doctor' 'docker' 'Installing docker' 'doctor:docker' 'Docker'
Write-JobOut $a "  Docker - Only for the Docker edition.`r`n  This will run:`r`n"
$log = Get-StreamLog 'doctor:docker' 0
Test-That 'label is the page name, not the key' $log.label 'Docker'
Test-That 'divider then output' @($log.lines) @(
    '', "$StreamRule$StreamRule Installing docker $StreamDot 03:37:56 $StreamRule$StreamRule", '',
    '  Docker - Only for the Docker edition.', '  This will run:')
Test-That 'total counts every line' $log.total 5
Test-That 'first is 0 with nothing dropped' $log.first 0
Test-That 'the running job is listed' @($log.jobs).Count 1
Test-That 'and carries its stream' @($log.jobs)[0].stream 'doctor:docker'
Test-That 'and its kind' @($log.jobs)[0].kind 'doctor'
Test-That 'the latest job is it' $log.job.id $a

Write-Host ''
Write-Host 'a half-written line is held back'
Write-JobOut $a "    winget install -e --id Doc"
$log = Get-StreamLog 'doctor:docker' 0
Test-That 'partial line not sent' $log.total 5
Write-JobOut $a "ker.DockerCLI`r`n"
$log = Get-StreamLog 'doctor:docker' 0
Test-That 'sent whole, once it is whole' @($log.lines)[-1] '    winget install -e --id Docker.DockerCLI'
Test-That 'and counted once' $log.total 6

Write-Host ''
Write-Host 'polling from a line number'
$log = Get-StreamLog 'doctor:docker' 5
Test-That 'only what the page has not seen' @($log.lines) @('    winget install -e --id Docker.DockerCLI')
Test-That 'first is what was asked for' $log.first 5
$log = Get-StreamLog 'doctor:docker' 6
Test-That 'nothing new, no lines' @($log.lines).Count 0
Test-That 'and total unchanged' $log.total 6

Write-Host ''
Write-Host 'a finished job'
Stop-TestJob $a 0
$log = Get-StreamLog 'doctor:docker' 0
Test-That 'nothing running now' @($log.jobs).Count 0
Test-That 'the last job is still named' $log.job.id $a
Test-That 'with its status' $log.job.status 'done'
Test-That 'and its code' $log.job.code 0
Test-That 'lines are kept' $log.total 6
Remove-Item $script:Jobs[$a].out -Force
$log = Get-StreamLog 'doctor:docker' 0
Test-That 'a finished job is not re-read' $log.total 6

Write-Host ''
Write-Host 'a second run on the same target'
$b = New-TestJob 'doctor' 'docker' 'Installing docker' 'doctor:docker' 'Docker'
Write-JobOut $b "  Docker is ready.`r`n"
$log = Get-StreamLog 'doctor:docker' 0
Test-That 'both runs in one log' $log.total 10
Test-That 'divider between them' @($log.lines)[7] "$StreamRule$StreamRule Installing docker $StreamDot 03:37:56 $StreamRule$StreamRule"
Test-That 'the newest job is the one named' $log.job.id $b
Stop-TestJob $b 1
$log = Get-StreamLog 'doctor:docker' 0
Test-That 'a failure reads as one' $log.job.status 'error'
Test-That 'with the exit code' $log.job.code 1

Write-Host ''
Write-Host 'a stopped job'
$c = New-TestJob 'install' '1181205' 'Installing Chromium 105' 'chromium:105' 'Chromium 105'
$script:Jobs[$c].stopping = $true
Stop-TestJob $c 1
Test-That 'stopped, not failed' (Get-StreamLog 'chromium:105' 0).job.status 'stopped'

Write-Host ''
Write-Host 'a docker verb survives the round trip'
$d = New-TestJob 'docker' 'firefox:115' 'Docker stop firefox:115' 'firefox:115' 'Firefox 115' 'stop'
Test-That 'action is reported' (Get-StreamLog 'firefox:115' 0).job.action 'stop'

Write-Host ''
Write-Host 'more output than the buffer holds'
$e = New-TestJob 'install' '999' 'Installing r999' 'sel:999' 'r999'
$big = New-Object Text.StringBuilder
for ($i = 1; $i -le 2000; $i++) { [void]$big.Append("line $i`r`n") }
Write-JobOut $e $big.ToString()
Stop-TestJob $e 0
$log = Get-StreamLog 'sel:999' 0
Test-That 'total counts everything written' $log.total 2003
Test-That 'only the tail is kept' @($log.lines).Count 1500
Test-That 'first says where the tail starts' $log.first 503
Test-That 'and it is the newest lines' @($log.lines)[-1] 'line 2000'
$log = Get-StreamLog 'sel:999' 100
Test-That 'a page behind the buffer is told to redraw' $log.first 503

Write-Host ''
Write-Host 'the listing the page rebuilds its tabs from'
$list = @(Get-StreamList)
Test-That 'one entry per stream' $list.Count 4
$row = $list | Where-Object { $_.key -eq 'doctor:docker' }
Test-That 'carries the label' $row.label 'Docker'
Test-That 'and the line count' $row.lines 10
Test-That 'and the last job' $row.job.id $b
Test-That 'ordered by when each was last written' $list[-1].key 'sel:999'
Test-That 'a missing log is not a log' (Get-StreamLog 'no:such' 0) $null

Write-Host ''
Write-Host 'what the page actually receives'
$state = @{ jobs = @(); logs = @(Get-StreamList) } | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
Test-That 'logs is a list' ($state.logs -is [array]) $true
Test-That 'jobs is a list even when empty' ($null -ne $state.jobs -and $state.jobs -is [array]) $true
$one = @{ logs = @(Get-StreamList)[0..0] } | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
Test-That 'one log is still a list' ($one.logs -is [array]) $true
$body = Get-StreamLog 'doctor:docker' 0 | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
Test-That 'lines survives as a list' ($body.lines -is [array]) $true
Test-That 'the divider survives as text' ($body.lines[1] -match '── Installing docker ·') $true
$empty = Get-StreamLog 'doctor:docker' 10 | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
Test-That 'no new lines is an empty list, not null' ($null -ne $empty.lines -and @($empty.lines).Count -eq 0) $true

Write-Host ''
Write-Host 'eviction'
# Four streams held, two with a job still running (firefox:115 and the one this
# starts), and a ceiling of three.
$StreamMax = 3
$f = New-TestJob 'install' '1000' 'Installing r1000' 'sel:1000' 'r1000'
Test-That 'down to the ceiling' $script:Streams.Count 3
Test-That 'the new one is kept' ($script:Streams.ContainsKey('sel:1000')) $true
Test-That 'so is the one still running' ($script:Streams.ContainsKey('firefox:115')) $true
Test-That 'the least recently written idle one went' ($script:Streams.ContainsKey('doctor:docker')) $false
Test-That 'and the next oldest with it' ($script:Streams.ContainsKey('chromium:105')) $false
Test-That 'the newest idle one stayed' ($script:Streams.ContainsKey('sel:999')) $true

Remove-Item -Recurse -Force $JobsDir
Exit-WithTally
