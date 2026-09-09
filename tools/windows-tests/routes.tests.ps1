#
# gui/server.ps1's routing, without a socket or a child process: the real
# Invoke-Route and Get-State are lifted out of the file and everything they reach
# that needs Windows - Start-Process, taskkill, docker, the shelf on disk - is
# stubbed.
#
# The bug this covers: a POST that starts a job has to answer with the stream key
# the page then polls. Without it the page opens no log at all.
#
$ErrorActionPreference = 'Stop'

$LiftFrom = @('./gui/server.ps1', './lib/preflight.ps1')
$LiftFunctions = @(
    'Invoke-Route', 'Get-State', 'Build-State', 'Get-Body', 'Get-Field', 'Read-JobFile',
    'Get-StreamKey', 'Get-StreamLabel', 'Resolve-Stream', 'Get-StreamUpdated',
    'Remove-IdleStreams', 'Get-JobState', 'Get-JobBrief', 'Get-JobSummary',
    'Split-JobText', 'Test-MeterLine', 'Get-JobLines', 'Get-StreamJobs',
    'Get-StreamRunning', 'Get-StreamLatest', 'Get-StreamLog', 'Get-StreamList',
    'Get-JobRecord', 'Clear-SizeCache', 'Clear-DoctorCache', 'Get-DirSize',
    'Test-NativeStale', 'Start-NativeRefresh', 'Quote-Args',
    'Clear-DockerRoute', 'Get-DockerRoute', 'Start-PfMemo', 'Stop-PfMemo',
    'Start-Child'
)
$LiftInspect = @('Start-Job2')
$LiftVariables = @(
    'StreamLines', 'StreamMax', 'StreamRule', 'StreamDot', 'StreamPattern',
    'Streams', 'SizeCache', 'SizeTtlSeconds', 'DoctorCache', 'DockerCache',
    'VolumeCache', 'NativeTtl', 'NativeRetrySeconds', 'NativeAsked',
    'PfDockerRoute', 'PfMemo'
)
. "$PSScriptRoot/harness.ps1"

$SelectorPattern = '^(?:(?:chromium|firefox|edge|webkit):)?[0-9A-Za-z][0-9A-Za-z.]{0,31}$'
$Engines = @('chromium', 'firefox', 'edge', 'webkit')
$EngineNames = @{ chromium = 'Chromium'; firefox = 'Firefox'; edge = 'Edge'; webkit = 'WebKit' }
$HostPlatform = 'Win_x64'
$Root = '/tmp/es-root'
$Port = 7411
$Token = 'test-token'
$GraceSeconds = 12
$DockerCli = 'engineshelf-docker.ps1'
$script:Cli = 'engineshelf.ps1'
$script:AutoQuit = $true
$script:Jobs = @{}
$script:next = 1

$JobsDir = Join-Path ([IO.Path]::GetTempPath()) ("es-route-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $JobsDir | Out-Null
$Project = $JobsDir

class FakeProc {
    [bool]$HasExited = $false
    [int]$ExitCode = 0
}

# --- stubs for everything that needs Windows or the network ----------------- #
function Test-Authorised { param($Request) return $true }
function Send-Json { param($Stream, $Object, [int]$Status = 200)
    $script:sent = @{ status = $Status; body = $Object }
}
function Send-Static { param($Stream, [string]$PathPart) $script:sent = @{ status = 200; body = "static:$PathPart" } }
function Get-DoctorReport { return @{ os = 'windows'; arch = 'AMD64'; components = @() } }
function Read-Catalog { return @{ versions = @(); builds = @{} } }
function Get-DockerStatus { return @{ cli = $false; imageBytes = 0; profileBytes = 0 } }
function Get-InstalledByKey { return @{} }
function Read-Shelf { return @{ chromium = @(); firefox = @(); edge = @(); webkit = @() } }
function Get-NativeRecord { return $script:nativeRecord }
function Get-Features { return @{} }
function Get-JobsRevision { return '' }
function Get-SelectorLabel { param([string]$s) return "Chromium $s" }
function Clear-CutOff { param($list) }
function Stop-Job2 { param([string]$Id) return $true }
function Raise-Window { param($job) return $null }
# Named parameters land in $args as -Name, value pairs and -ArgumentList's value
# is itself an array, so the pipeline is what flattens it into something readable.
function Start-Process { $script:spawned += ((@($args) | ForEach-Object { $_ }) -join ' ') }

$script:nativeRecord = $null


$script:spawned = @()

# Same parameter list as the real Start-Job2 - checked below, because a stub that
# has drifted from it would let a broken call site pass.
function Start-Job2 {
    param([string]$Kind, [string]$Revision, [string[]]$CliArgs, [string]$Label,
          [string]$Script = $null, [string]$Stream = $null,
          [string]$StreamLabel = $null, [string]$Action = $null)
    $id = [string]$script:next
    $script:next++
    $key = if ($Stream) { $Stream } else { "sel:$Revision" }
    $out = Join-Path $JobsDir "$id.out"
    $err = Join-Path $JobsDir "$id.err"
    [IO.File]::WriteAllText($out, '')
    [IO.File]::WriteAllText($err, '')
    $script:Jobs[$id] = @{
        id = $id; kind = $Kind; revision = $Revision; label = $Label
        proc = [FakeProc]::new(); out = $out; err = $err; stopping = $false
        settled = $false; stream = $key; action = $Action
        startedAt = '03:37:56'; lineCache = $null; lineFinal = $false
    }
    $log = Resolve-Stream $key $StreamLabel
    [void]$log.jobs.Add($id)
    $script:started = @{ kind = $Kind; revision = $Revision; argv = $CliArgs; label = $Label
                         script = $Script; stream = $Stream; streamLabel = $StreamLabel
                         action = $Action; id = $id }
    return $id
}

function Invoke-Post {
    param([string]$Path, $Body)
    $script:sent = $null
    $script:started = $null
    Invoke-Route $null @{ method = 'POST'; path = $Path; headers = @{}
                          body = ($Body | ConvertTo-Json -Compress) }
    return $script:sent
}

function Invoke-Get {
    param([string]$Path)
    $script:sent = $null
    Invoke-Route $null @{ method = 'GET'; path = $Path; headers = @{}; body = '' }
    return $script:sent
}

Write-Host ''
Write-Host 'the stub matches the real Start-Job2'
$stubParams = @((Get-Command Start-Job2).Parameters.Keys |
                Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
Test-That 'same parameters, same order' (Get-LiftedParams 'Start-Job2') $stubParams

Write-Host ''
Write-Host 'a dependency install'
$answer = Invoke-Post '/api/doctor-install' @{ component = 'docker'; streamLabel = 'Docker' }
Test-That 'answers 200' $answer.status 200
Test-That 'hands back the stream key' $answer.body.stream 'doctor:docker'
Test-That 'and the job' ($null -ne $answer.body.job) $true
Test-That 'files it under the component' $script:started.stream 'doctor:docker'
Test-That 'with the page name on the tab' $script:started.streamLabel 'Docker'
Test-That 'runs the right command' $script:started.argv @('doctor', '--install', 'docker', '--yes')
Test-That 'as a doctor job' $script:started.kind 'doctor'

$answer = Invoke-Post '/api/doctor-install' @{ component = 'rosetta' }
Test-That 'no label falls back to the component' $script:started.streamLabel 'rosetta'
$answer = Invoke-Post '/api/doctor-install' @{ component = 'not a component' }
Test-That 'a bad component is refused' $answer.status 400

Write-Host ''
Write-Host 'the jobs a shelf row starts'
foreach ($case in @(
    @{ path = '/api/install'; kind = 'install' }
    @{ path = '/api/launch';  kind = 'launch' }
    @{ path = '/api/remove';  kind = 'remove' }
    @{ path = '/api/clean';   kind = 'clean' }
)) {
    $answer = Invoke-Post $case.path @{ selector = '105'; stream = 'chromium:105'; streamLabel = 'Chromium 105' }
    Test-That "$($case.path) hands back the stream" $answer.body.stream 'chromium:105'
    Test-That "$($case.path) files output there" $script:started.stream 'chromium:105'
    Test-That "$($case.path) names the tab" $script:started.streamLabel 'Chromium 105'
    Test-That "$($case.path) is a $($case.kind) job" $script:started.kind $case.kind
}

$answer = Invoke-Post '/api/install' @{ selector = '105' }
Test-That 'an older page still gets a log' $answer.body.stream 'sel:105'
$answer = Invoke-Post '/api/install' @{ selector = '105'; stream = 'no spaces allowed' }
Test-That 'a malformed key is not trusted' $answer.body.stream 'sel:105'
$answer = Invoke-Post '/api/install' @{ selector = 'rm -rf /' }
Test-That 'a bad selector is still refused' $answer.status 400

Write-Host ''
Write-Host 'a container, which shares its row log'
# Every verb the page sends. 'clean' - resetting the container's profile volume -
# was missing from the allow-list, so that menu entry answered 400 on Windows
# while the launcher had implemented it all along.
foreach ($verb in @('start', 'build', 'stop', 'rebuild', 'clean', 'purge')) {
    $answer = Invoke-Post '/api/docker' @{ selector = 'firefox:115'; action = $verb
                                           stream = 'firefox:115'; streamLabel = 'Firefox 115' }
    Test-That "docker $verb is accepted" $answer.status 200
    Test-That "docker $verb shares the row's log" $answer.body.stream 'firefox:115'
    Test-That "docker $verb remembers the verb" $script:started.action $verb
    Test-That "docker $verb runs the docker launcher" $script:started.script 'engineshelf-docker.ps1'
}
$answer = Invoke-Post '/api/docker' @{ selector = 'firefox:115'; action = 'nonsense' }
Test-That 'an unknown verb is refused' $answer.status 400
$answer = Invoke-Post '/api/docker' @{ selector = 'lynx:1'; action = 'start' }
Test-That 'an unknown engine is refused' $answer.status 400

Write-Host ''
Write-Host 'reading a log back'
$docker = $script:Jobs.Keys | Where-Object { $script:Jobs[$_].stream -eq 'doctor:docker' } | Select-Object -First 1
[IO.File]::AppendAllText($script:Jobs[$docker].out, "  winget install -e --id Docker.DockerCLI`r`n  Docker is ready.`r`n")

$answer = Invoke-Get '/api/log/doctor%3Adocker'
Test-That 'the key is decoded' $answer.body.key 'doctor:docker'
Test-That 'and its lines are there' @($answer.body.lines)[-1] '  Docker is ready.'
Test-That 'with the divider above them' @($answer.body.lines)[1] "$StreamRule$StreamRule Installing docker $StreamDot 03:37:56 $StreamRule$StreamRule"
Test-That 'total is absolute' $answer.body.total 5

$answer = Invoke-Get '/api/log/doctor%3Adocker?since=4'
Test-That 'since= sends only what follows' @($answer.body.lines) @('  Docker is ready.')
Test-That 'and says where it starts' $answer.body.first 4

$answer = Invoke-Get '/api/log/doctor%3Adocker?since=notanumber'
Test-That 'a junk since= reads as 0' $answer.body.first 0

$answer = Invoke-Get '/api/log/nothing%3Ahere'
Test-That 'an unknown log is 404' $answer.status 404

$answer = Invoke-Get '/api/logs'
Test-That 'every log is listed' (@($answer.body.streams).Count -ge 4) $true

Write-Host ''
Write-Host 'what the state document carries'
$answer = Invoke-Get '/api/state'
$state = $answer.body | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
Test-That 'logs is a list, which is what says the manager keeps them' ($state.logs -is [array]) $true
Test-That 'jobs is a list' ($state.jobs -is [array]) $true
$job = @($state.jobs)[0]
Test-That 'a running job names its log' ($null -ne $job.stream) $true
Test-That 'a log entry has a key' ($null -ne @($state.logs)[0].key) $true
Test-That 'and a line count' ($null -ne @($state.logs)[0].lines) $true

Write-Host ''
Write-Host 'building the state asks the vendors, once'
$script:NativeAsked = [datetime]::MinValue
$script:spawned = @()
$null = Invoke-Get '/api/state'
Test-That 'a fresh install has nothing on file, so it asks' $script:spawned.Count 1
Test-That 'through the CLI, in no window' ($script:spawned[0] -match 'refresh-native webkit versions') $true
$null = Invoke-Get '/api/state'
$null = Invoke-Get '/api/state'
Test-That 'and not again on every poll' $script:spawned.Count 1

$now = [int64](([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds)
$script:nativeRecord = @{ webkit = @{ floor = '1446'; at = $now }; versions = @{ at = $now } } |
                       ConvertTo-Json | ConvertFrom-Json
$script:NativeAsked = [datetime]::MinValue
$script:spawned = @()
$null = Invoke-Get '/api/state'
Test-That 'with both answers on file it asks nothing' $script:spawned.Count 0

Remove-Item -Recurse -Force $JobsDir
Exit-WithTally
