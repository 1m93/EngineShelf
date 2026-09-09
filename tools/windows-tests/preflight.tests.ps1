#
# The Windows dependency chain: WSL 2, then Docker Engine inside it.
#
# Every state a machine can be in, walked against the real lib/preflight.ps1 with
# `wsl`, `docker` and the filesystem stubbed - so the state machine is checked on
# a Mac, which is the only way it gets checked at all before somebody's Windows
# box runs it.
#
# What matters here is that no state is a dead end: each one either reports ok,
# or hands back a command that moves it to the next state.
#
$ErrorActionPreference = 'Stop'

$LiftFrom = './lib/preflight.ps1'
$LiftFunctions = @(
    'Get-PfStatus', 'Get-PfLabel', 'Get-PfNeed', 'Get-PfWhy', 'Get-PfFix',
    'Get-PfNote', 'Get-PfReport', 'Test-WindowsDocker', 'Test-WslReady',
    'Invoke-WslHere', 'Invoke-Wsl', 'Test-WslDocker', 'Test-WslDockerRunning',
    'ConvertTo-WslPath', 'Test-PfNeedsElevation', 'Get-DockerRoute',
    'Clear-DockerRoute', 'Invoke-DockerHere', 'Invoke-DockerAsk', 'Quote-Args',
    'Split-Lines', 'Get-PfAnswer', 'Start-PfMemo', 'Stop-PfMemo'
)
# Stubbed below rather than run: it starts a real child process, which is the
# whole point of it. Named here so a rename in the real file fails this suite
# instead of quietly leaving the stub answering for something nothing calls.
$LiftInspect = @('Invoke-Bounded')
$LiftVariables = @('PfComponents', 'PfDockerRoute', 'PfTimedOut', 'PfMemo',
                   'PfRouteAskedAt', 'PfRouteRetrySeconds',
                   'PfAskSeconds', 'PfWslSeconds', 'PfVolumeSeconds')
. "$PSScriptRoot/harness.ps1"

# Windows always has this; PowerShell on a Mac does not, and Join-Path throws on
# a null path - and on a Windows-shaped one too, because there is no C: drive
# here to validate it against. Any real directory does: what is under test is the
# branch, not the path.
if (-not $env:ProgramFiles) { $env:ProgramFiles = [IO.Path]::GetTempPath() }

# One machine, in whatever state the case under test wants.
$script:box = @{}
function Set-Box {
    param([hashtable]$State)
    $script:box = @{ wslExe = $false; distro = $false; dockerInWsl = $false
                     dockerUp = $false; winDocker = $false; desktop = $false }
    foreach ($k in $State.Keys) { $script:box[$k] = $State[$k] }
}

function Test-Have {
    param([string]$Name)
    switch ($Name) {
        'wsl'    { return $script:box.wslExe }
        'docker' { return $script:box.winDocker }
        default  { return $false }
    }
}
function Test-Path { param($Path) return $script:box.desktop }

# The two executables the chain leans on, answering as the box would - through
# Invoke-Bounded, which is where every probe goes now. A time limit means a child
# process, and a child process is not something a function stub can stand in
# front of, so this is the seam. Every call through it is kept, so the shape of
# what was asked - and the limit it was asked with - can be asserted too.
$script:asked = @()
function Invoke-Bounded {
    param([string]$File, [string[]]$Arguments = @(), [int]$Seconds = 8)
    $line = ($Arguments -join ' ')
    $script:asked += , @{ file = $File; line = $line; seconds = $Seconds }
    $answer = @{ code = 127; out = ''; timedOut = $false }
    if ($script:slow -and $script:slow -eq "$File $line") {
        $answer.code = 124
        $answer.timedOut = $true
        $script:PfTimedOut = $true
        return $answer
    }
    if ($File -eq 'docker') {
        $answer.code = $(if ($script:box.winDocker) { 0 } else { 1 })
        return $answer
    }
    if ($File -eq 'wsl') {
        $answer.code = 0
        if ($line -match '-l -q') {
            if (-not $script:box.distro) { $answer.code = 1 } else { $answer.out = "Ubuntu`n" }
        } elseif ($line -match 'command -v docker') {
            $answer.code = $(if ($script:box.dockerInWsl) { 0 } else { 1 })
        } elseif ($line -match 'docker info') {
            $answer.code = $(if ($script:box.dockerUp) { 0 } else { 1 })
        }
    }
    return $answer
}
$script:slow = $null

# Still here, and still real: Invoke-DockerHere is the passthrough the launcher
# runs its builds through, and what it hands the machine is pinned further down.
function wsl {
    $line = ($args -join ' ')
    if ($line -match '^-l -q') {
        if (-not $script:box.distro) { $global:LASTEXITCODE = 1; return '' }
        $global:LASTEXITCODE = 0; return 'Ubuntu'
    }
    if ($line -match 'command -v docker') {
        $global:LASTEXITCODE = $(if ($script:box.dockerInWsl) { 0 } else { 1 }); return ''
    }
    if ($line -match 'docker info') {
        $global:LASTEXITCODE = $(if ($script:box.dockerUp) { 0 } else { 1 }); return ''
    }
    $global:LASTEXITCODE = 0; return ''
}
function docker {
    $global:LASTEXITCODE = $(if ($script:box.winDocker) { 0 } else { 1 }); return ''
}

# What the system check would draw for one component on this box.
function Read-Row {
    param([string]$Id)
    $status = Get-PfStatus $Id
    return @{ status = $status; fix = (Get-PfFix $Id $status); note = (Get-PfNote $Id $status) }
}

Write-Host ''
Write-Host 'the component list'
Test-That 'wsl is one of them' ($PfComponents -contains 'wsl') $true
Test-That 'and comes before docker' `
    ([array]::IndexOf($PfComponents, 'wsl') -lt [array]::IndexOf($PfComponents, 'docker')) $true
Test-That 'it is optional, like docker' (Get-PfNeed 'wsl') 'optional'
Test-That 'and it says what it is for' `
    ((Get-PfWhy 'wsl') -match 'Edge') $true

Write-Host ''
Write-Host 'a machine with nothing'
Set-Box @{}
$wsl = Read-Row 'wsl'
$dock = Read-Row 'docker'
Test-That 'WSL is missing' $wsl.status 'missing'
Test-That 'and offers to install itself' $wsl.fix 'wsl --install'
Test-That 'warning about the restart' ($wsl.note -match 'restart') $true
Test-That 'and about the firmware, which nothing can fix' ($wsl.note -match 'virtualisation') $true
Test-That 'that step needs administrator rights' (Test-PfNeedsElevation 'wsl') $true
Test-That 'Docker is missing too' $dock.status 'missing'
Test-That 'but offers nothing yet - WSL first' $dock.fix ''
Test-That 'and says so' ($dock.note -match 'Needs WSL 2 first') $true

Write-Host ''
Write-Host 'WSL enabled, no Linux in it yet (what a pending restart looks like)'
Set-Box @{ wslExe = $true }
$wsl = Read-Row 'wsl'
Test-That 'half-installed reads as not running' $wsl.status 'inactive'
Test-That 'and the next step is a distro' $wsl.fix 'wsl --install -d Ubuntu'
Test-That 'nothing to answer during it' ($wsl.note -match 'nothing to answer') $true
Test-That 'Docker still waits on it' (Read-Row 'docker').fix ''

Write-Host ''
Write-Host 'WSL working, no Docker inside'
Set-Box @{ wslExe = $true; distro = $true }
Test-That 'WSL is ready' (Read-Row 'wsl').status 'ok'
Test-That 'and asks for nothing more' (Read-Row 'wsl').fix ''
$dock = Read-Row 'docker'
Test-That 'Docker is missing' $dock.status 'missing'
Test-That 'installed inside the distro, as root' $dock.fix `
    'wsl -u root -e sh -lc "curl -fsSL https://get.docker.com | sh"'
Test-That 'so nothing asks for a password' ($dock.fix -notmatch 'sudo') $true
Test-That 'and it is not Docker Desktop' ($dock.note -match 'no admin rights, no restart') $true
Test-That 'this step needs no elevation' (Test-PfNeedsElevation 'docker') $false

Write-Host ''
Write-Host 'Docker inside, daemon down'
Set-Box @{ wslExe = $true; distro = $true; dockerInWsl = $true }
$dock = Read-Row 'docker'
Test-That 'reads as not running' $dock.status 'inactive'
Test-That 'started inside the distro' $dock.fix 'wsl -u root -e service docker start'
Test-That 'no sudo here either' ($dock.fix -notmatch 'sudo') $true
Test-That 'nothing is downloaded' ($dock.note -match 'Nothing is downloaded') $true

Write-Host ''
Write-Host 'everything up'
Set-Box @{ wslExe = $true; distro = $true; dockerInWsl = $true; dockerUp = $true }
Test-That 'Docker is ok' (Read-Row 'docker').status 'ok'
Test-That 'WSL is ok' (Read-Row 'wsl').status 'ok'

Write-Host ''
Write-Host 'somebody who chose Docker Desktop'
Set-Box @{ winDocker = $true }
Test-That 'the Windows CLI answering is enough' (Read-Row 'docker').status 'ok'
Test-That 'and WSL is not made their problem' (Read-Row 'wsl').status 'missing'
Set-Box @{ winDocker = $false; desktop = $true }
$dock = Read-Row 'docker'
Test-That 'Desktop installed but down: start it' ($dock.status) 'missing'
Set-Box @{ winDocker = $false; desktop = $true; wslExe = $true; distro = $true; dockerInWsl = $true }
Test-That 'Desktop present and WSL has docker: start the one already there' `
    ((Read-Row 'docker').fix -match 'Docker Desktop') $true

Write-Host ''
Write-Host 'no state is a dead end'
# Every state either is ok, or hands back something that moves it on. The one
# exception is Docker before WSL, which points at the row above instead.
foreach ($case in @(
    @{},
    @{ wslExe = $true },
    @{ wslExe = $true; distro = $true },
    @{ wslExe = $true; distro = $true; dockerInWsl = $true },
    @{ wslExe = $true; distro = $true; dockerInWsl = $true; dockerUp = $true }
)) {
    Set-Box $case
    foreach ($id in @('wsl', 'docker')) {
        $row = Read-Row $id
        $moves = ($row.status -eq 'ok') -or $row.fix -or ($row.note -match 'Needs WSL 2 first')
        if (-not $moves) {
            Test-That "$id has somewhere to go from $($case.Keys -join '+')" $false $true
        }
    }
}
Test-That 'every state has a next step' $true $true

Write-Host ''
Write-Host 'where docker actually is, and what gets run'
# Every docker call in the launcher and the manager goes through Invoke-DockerHere.
# What it produces is the whole contract with the machine, so it is pinned here.
$script:ran = @()
function docker { $script:ran += ,(@('docker') + $args); $global:LASTEXITCODE = 0 }
function wsl {
    $line = ($args -join ' ')
    if ($line -match '^-l -q') {
        if (-not $script:box.distro) { $global:LASTEXITCODE = 1; return '' }
        $global:LASTEXITCODE = 0; return 'Ubuntu'
    }
    if ($line -match 'command -v docker') {
        $global:LASTEXITCODE = $(if ($script:box.dockerInWsl) { 0 } else { 1 }); return ''
    }
    if ($line -match 'docker info') {
        $global:LASTEXITCODE = $(if ($script:box.dockerUp) { 0 } else { 1 }); return ''
    }
    $script:ran += ,(@('wsl') + $args); $global:LASTEXITCODE = 0; return ''
}
function Invoke-Here { param([string[]]$A) $script:ran = @(); Invoke-DockerHere @A; return $script:ran[-1] }

Clear-DockerRoute; Set-Box @{ winDocker = $true }
Test-That 'Docker Desktop: the route is windows' (Get-DockerRoute) 'windows'
Test-That 'and it runs docker.exe directly' `
    (Invoke-Here @('ps', '--format', '{{.Names}}')) @('docker', 'ps', '--format', '{{.Names}}')

Clear-DockerRoute; Set-Box @{ wslExe = $true; distro = $true; dockerInWsl = $true }
Test-That 'no docker.exe but WSL has one: the route is wsl' (Get-DockerRoute) 'wsl'
Test-That 'and it runs it inside the distro, as root' `
    (Invoke-Here @('ps', '--format', '{{.Names}}')) `
    @('wsl', '-u', 'root', '-e', 'docker', 'ps', '--format', '{{.Names}}')
Test-That 'a format string with spaces stays one argument' `
    (Invoke-Here @('images', '--format', '{{.Tag}} | {{.Size}}'))[-1] '{{.Tag}} | {{.Size}}'
# Called the way the launcher calls it - written out, not splatted. That
# distinction is the whole bug: @splat hands the elements over as positional
# arguments and binds nothing, while a written-out `-p` is matched against the
# function's own parameters. A single [Parameter()] attribute makes this an
# advanced function, and then PowerShell prefix-matches its common parameters:
# -p to -PipelineVariable, -d to -Debug, -v to -Verbose. `docker run -d -p
# 127.0.0.1:6080:6080 -v vol:/data` lost three flags and died on "not a valid
# variable name" without ever reaching docker.
$script:ran = @()
$threw = $null
try { Invoke-DockerHere run -d --name c -p 127.0.0.1:6080:6080 -v vol:/data img }
catch { $threw = $_.Exception.Message }
Test-That 'a written-out docker flag does not bind to a PowerShell parameter' $threw $null
Test-That 'and every flag reaches docker intact' $script:ran[-1] `
    @('wsl', '-u', 'root', '-e', 'docker', 'run', '-d', '--name', 'c',
      '-p', '127.0.0.1:6080:6080', '-v', 'vol:/data', 'img')

Clear-DockerRoute; Set-Box @{}
Test-That 'nothing anywhere: no route' (Get-DockerRoute) ''
$script:ran = @()
Invoke-DockerHere ps
Test-That 'and nothing is run' $script:ran.Count 0
Test-That 'but it fails like a command that is not there' $global:LASTEXITCODE 127

Write-Host ''
Write-Host 'a path with a space in it survives being started'
# Start-Process joins -ArgumentList with spaces and quotes nothing. A second copy
# of the download sitting in "EngineShelf-1.1.5-Windows (1)" was enough to make
# every job die on:
#   Processing -File 'C:\...\EngineShelf-1.1.5-Windows' failed because the file
#   does not have a '.ps1' extension.
$job = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
         'C:\Users\a b\Downloads\EngineShelf-1.1.5-Windows (1)\app\engineshelf-docker.ps1',
         'start', 'firefox:51.0')
$line = (Quote-Args $job) -join ' '
Test-That 'the script path is quoted' `
    ($line -match '-File "C:\\Users\\a b\\Downloads\\EngineShelf-1\.1\.5-Windows \(1\)\\app\\engineshelf-docker\.ps1"') $true
Test-That 'and the plain arguments are left alone' ($line -match ' start firefox:51\.0$') $true
Test-That 'nothing without a space gains quotes' ((Quote-Args @('-NoProfile')) -join '') '-NoProfile'
Test-That 'an embedded quote is escaped, not dropped' `
    ((Quote-Args @('a "b" c')) -join '') '"a \"b\" c"'
Test-That 'an empty list stays empty' (@(Quote-Args @()).Count) 0

Write-Host ''
Write-Host 'docker complaining does not end the run'
# Windows PowerShell turns a native command's stderr into an error record, and
# engineshelf-docker.ps1 runs with $ErrorActionPreference = 'Stop'. Clearing a
# container that is not there is routine - `docker rm -f` says "No such
# container" and means nothing by it - and every caller has always redirected
# that away at the call site. With the native call moved behind this helper, the
# record is raised where their redirection cannot reach it, and a routine rm
# ended the whole `start`. Write-Error stands in for what 5.1 does with stderr:
# it is the same record, and it obeys the same preference.
function wsl {
    Write-Error 'Error response from daemon: No such container: engineshelf-firefox-51.0'
    $global:LASTEXITCODE = 1
}
Clear-DockerRoute
$script:box.wslExe = $true; $script:box.distro = $true; $script:box.dockerInWsl = $true
$script:PfDockerRoute = 'wsl'
$threw = $false
$ErrorActionPreference = 'Stop'
try { Invoke-DockerHere rm -f engineshelf-firefox-51.0 2>&1 | Out-Null } catch { $threw = $true }
Test-That 'a complaint from the daemon is not a terminating error' $threw $false
Test-That 'and the caller still sees it failed' $global:LASTEXITCODE 1
Test-That 'the preference is put back' $ErrorActionPreference 'Stop'
$ErrorActionPreference = 'Continue'

Clear-DockerRoute; Set-Box @{ winDocker = $true }
$null = Get-DockerRoute
Set-Box @{}
Test-That 'the route is remembered' (Get-DockerRoute) 'windows'
Clear-DockerRoute
Test-That 'until something says it may have changed' (Get-DockerRoute) ''

Write-Host ''
Write-Host 'a Windows with no WSL is an answer, not a crash'
# The machine most people have. wsl.exe is in System32 on every Windows 10 and
# 11, so Test-Have finds it and `wsl -l -q` runs - and with the feature switched
# off it says so on stderr:
#
#     wsl : The Windows Subsystem for Linux is not installed. You can install by
#     running 'wsl.exe --install'.
#
# Windows PowerShell turns that into an error record, `$ErrorActionPreference =
# 'Stop'` makes it terminate, and the `2>$null` written on that line does not
# reach it. gui/server.ps1 asks for the Docker route at startup, before any
# handler is there to catch anything, so the manager printed that and quit:
# EngineShelf.bat, double-clicked, on a machine that only ever wanted the native
# launcher. Write-Error stands in for what 5.1 does with stderr - the same
# record, obeying the same preference - because a stub cannot write to a stream
# it does not have.
function wsl {
    Write-Error "The Windows Subsystem for Linux is not installed. You can install by running 'wsl.exe --install'."
    $global:LASTEXITCODE = 1
    return ''
}
Clear-DockerRoute
Set-Box @{ wslExe = $true }
$ErrorActionPreference = 'Stop'

$threw = $false; $ready = $null
try { $ready = Test-WslReady } catch { $threw = $true }
Test-That 'asking for the distro list does not end the run' $threw $false
Test-That 'and WSL reads as not ready' $ready $false

$threw = $false
try { $null = Get-DockerRoute } catch { $threw = $true }
Test-That 'the docker route survives being asked' $threw $false
Test-That 'and there is no route to docker' (Get-DockerRoute) ''

$threw = $false
try { $null = Get-PfReport } catch { $threw = $true }
Test-That 'the whole system check survives it' $threw $false

$threw = $false; $converted = $null
try { $converted = ConvertTo-WslPath 'C:\Users\a b\x' } catch { $threw = $true }
Test-That 'so does converting a path' $threw $false
Test-That 'which falls back to the path it was given' $converted 'C:\Users\a b\x'
Test-That 'the preference is put back' $ErrorActionPreference 'Stop'
$ErrorActionPreference = 'Continue'

# All four of those now hold for a second reason as well, and the stronger one:
# a probe is a child process, where a line on stderr is a pipe to read rather
# than an error record raised in this scope. The preference dance is still there
# for Invoke-WslHere and Invoke-DockerHere, which is where the launcher's real
# work goes, but nothing on the way to an answer runs a native command inline
# any more. Asserted off the parse tree, so putting `& wsl` back in one of these
# fails here rather than on somebody's machine.
function Get-CallsIn {
    param([string]$Name)
    return @($LiftedFunctions[$Name].FindAll({
        $args[0] -is [System.Management.Automation.Language.CommandAst]
    }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
}
foreach ($probe in @('Test-WslReady', 'Test-WindowsDocker', 'Invoke-Wsl')) {
    $calls = Get-CallsIn $probe
    Test-That "$probe runs nothing inline" `
        ((@($calls) -contains 'wsl') -or (@($calls) -contains 'docker')) $false
    Test-That "$probe asks through Invoke-Bounded" (@($calls) -contains 'Invoke-Bounded') $true
}

Write-Host ''
Write-Host 'every question put to the machine has an end to it'
Clear-DockerRoute
Set-Box @{ wslExe = $true; distro = $true; dockerInWsl = $true; dockerUp = $true }
$script:asked = @()
$null = Get-PfReport
Test-That 'the report did ask it something' ($script:asked.Count -gt 0) $true
Test-That 'and every one of them carried a limit' `
    (@($script:asked | Where-Object { $_.seconds -le 0 }).Count) 0
# The two limits are not the same question: listing the distros does not start
# one, and running a command inside it does.
Test-That 'the one that may boot the distro gets the longer limit' `
    (@($script:asked | Where-Object { $_.line -match 'sh -lc' -and $_.seconds -ne $PfWslSeconds }).Count) 0
Test-That 'the listing gets the cheap one' `
    (@($script:asked | Where-Object { $_.line -match '-l -q' -and $_.seconds -ne $PfAskSeconds }).Count) 0

Write-Host ''
Write-Host 'a probe that ran out of time is not an answer'
# The difference that matters: '' cached for the life of the manager because
# Docker Desktop was slow to start would shut the Docker half of every row until
# a job happened to end, and nobody could see why.
Clear-DockerRoute; Set-Box @{ winDocker = $true }
$script:slow = 'docker info'
Test-That 'no route to docker, for now' (Get-DockerRoute) ''
Test-That 'and nothing was written down' $script:PfDockerRoute $null

# Not written down, and not asked again by the next caller either: one state
# build asks for the route half a dozen times over, and a probe chain each time
# is what made a wedged Docker Desktop into a forty-second /api/state.
$script:asked = @()
Test-That 'the caller behind it gets the same answer' (Get-DockerRoute) ''
Test-That 'without asking the machine again' $script:asked.Count 0

# And once the window is up - which is all Clear-DockerRoute does to it - the
# question is put again rather than being settled for the run.
$script:slow = $null
Clear-DockerRoute
$script:asked = @()
Test-That 'later, it asks again' (Get-DockerRoute) 'windows'
Test-That 'and did ask' ($script:asked.Count -gt 0) $true
Test-That 'an answer is remembered, being one' $script:PfDockerRoute 'windows'

Write-Host ''
Write-Host 'what the manager reads back from docker'
# Every one of these is on the path of a state poll, which the page makes every
# second while anything is running. Invoke-DockerAsk is the bounded half of the
# pair; Invoke-DockerHere, unbounded, stays for `docker build`.
Clear-DockerRoute; Set-Box @{ winDocker = $true }
$script:asked = @()
$answer = Invoke-DockerAsk @('ps', '-a')
Test-That 'it goes the way the route says' $script:asked[-1].file 'docker'
Test-That 'with the arguments it was given' $script:asked[-1].line 'ps -a'
Test-That 'and a limit of its own' $script:asked[-1].seconds $PfAskSeconds
$null = Invoke-DockerAsk @('system', 'df', '-v') $PfVolumeSeconds
Test-That 'the volume read gets the longer one' $script:asked[-1].seconds $PfVolumeSeconds
Clear-DockerRoute; Set-Box @{ wslExe = $true; distro = $true; dockerInWsl = $true }
$null = Invoke-DockerAsk @('images')
Test-That 'inside the distro, as root, when that is where docker is' `
    $script:asked[-1].line '-u root -e docker images'
Clear-DockerRoute; Set-Box @{}
$answer = Invoke-DockerAsk @('ps')
Test-That 'and with no docker anywhere it answers like a missing command' $answer.code 127

Write-Host ''
Write-Host 'output comes back as the lines a caller wanted'
Test-That 'both endings' (Split-Lines "a`r`nb`nc") @('a', 'b', 'c')
Test-That 'blank lines are not rows' (@(Split-Lines "a`n`n`nb")).Count 2
Test-That 'nothing at all is no rows' (@(Split-Lines '')).Count 0
Test-That 'and neither is nothing' (@(Split-Lines $null)).Count 0

# One command for both machines that read as 'inactive' - no distro, or no
# feature at all - because nothing here can tell them apart.
Clear-DockerRoute; Set-Box @{ wslExe = $true }
$wsl = Read-Row 'wsl'
Test-That 'the row offers the one command that covers both' $wsl.fix 'wsl --install -d Ubuntu'
Test-That 'and warns about the administrator prompt' ($wsl.note -match 'administrator') $true
Test-That 'and about the restart it may want' ($wsl.note -match 'restart') $true
Test-That 'while still promising nothing to answer during it' ($wsl.note -match 'nothing to answer') $true

Exit-WithTally
