#
# EngineShelf - dependency checks (Windows).
#
# Dot-sourced, never run directly:
#   . "$ScriptDir\lib\preflight.ps1"
#
# Mirrors lib/preflight.sh: same component ids, same status words, same JSON, so
# the manager renders Windows and macOS/Linux with one code path.
#
# Windows needs far less than the others. PowerShell 5.1 ships with the OS and
# runs both the launcher and the manager, downloads go through
# Invoke-WebRequest and archives through System.IO.Compression - so python3,
# curl, unzip and Rosetta are all reported "na" rather than pretended to matter.

function Test-Have { param([string]$Name) $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

# ---------- the Docker edition on Windows ----------
# Windows has no colima, and Docker Desktop is the thing this tool has always
# refused: over a gigabyte, admin rights, a reboot, and a licence that is only
# free for small companies. What is left is the same Linux machine everyone else
# already has - WSL 2 - with Docker Engine inside it, driven with `wsl -u root`,
# which needs no password because root inside the distro is not root out here.
#
# So the chain is four links, and each is its own row in the system check:
#
#   virtualisation   firmware. Nothing here can turn it on.
#   WSL 2            one admin prompt, usually one restart. Windows insists.
#   Docker Engine    inside the distro. Automatic, and asks nothing.
#   the daemon       inside the distro. Automatic.
#
# Every step only has to move the state on by one; the next check re-reads the
# machine rather than trusting what just ran. That is what makes the chain
# survive a restart in the middle of it, and what makes it safe for
# `wsl --install` to behave differently on different builds of Windows.

# Docker reachable from Windows itself. True when the user chose Docker Desktop,
# which is theirs to choose - nothing here installs it.
function Test-WindowsDocker {
    if (-not (Test-Have docker)) { return $false }
    docker info 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Every wsl call in this file goes through here, and for the reason
# Invoke-DockerHere spells out further down: Windows PowerShell turns a native
# command's stderr into an error record, and `$ErrorActionPreference = 'Stop'` -
# which gui.ps1, gui/server.ps1 and both launchers set - makes that record
# terminate the script. A `2>$null` on the call itself does not save it. The
# record is raised under whatever preference is in force where the command runs
# and only redirected afterwards, so the preference has to be lowered around the
# call, which is what this is.
#
# Not a hypothetical. `wsl -l -q` on a Windows with the feature switched off is
# answering the question, not failing:
#
#     wsl : The Windows Subsystem for Linux is not installed. You can install by
#     running 'wsl.exe --install'.
#
# and wsl.exe is in System32 on every Windows 10 and 11, so Test-Have finds it
# and that line always ran. gui/server.ps1 asks for the Docker route at startup
# (Set-InheritedContainers), before any request handler is there to catch
# anything, so double-clicking EngineShelf.bat printed that error and stopped -
# on every machine without WSL, which is most of them.
#
# No param block, deliberately, for the same reason as Invoke-DockerHere: one
# [Parameter()] makes this an advanced function, whose common parameters are
# prefix-matched, and `-u root` would bind to -Verbose's neighbours rather than
# reaching wsl. A plain function binds nothing and passes $args through as
# written.
function Invoke-WslHere {
    $was = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & wsl @args } finally { $ErrorActionPreference = $was }
}

# A distro that answers. `wsl -l -q` lists installed ones; the command exists on
# machines where the feature is not enabled at all, so the list is the question,
# not the executable.
function Test-WslReady {
    if (-not (Test-Have wsl)) { return $false }
    $found = Invoke-WslHere -l -q 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ((@($found) -join '').Trim().Length -gt 0)
}

# Inside the distro, as root - no sudo, so nothing to answer.
function Invoke-Wsl {
    param([string]$Command)
    $out = Invoke-WslHere -u root -e sh -lc $Command 2>&1
    return @{ code = $LASTEXITCODE; out = (@($out) -join "`n") }
}

function Test-WslDocker { return (Invoke-Wsl 'command -v docker >/dev/null 2>&1').code -eq 0 }
function Test-WslDockerRunning { return (Invoke-Wsl 'docker info >/dev/null 2>&1').code -eq 0 }

# ---------- where docker is, and how to reach it ----------
# Two answers on Windows and everything downstream has to agree on which: the
# launcher builds and runs containers, and the manager reads back what exists.
# One decision, made here, so a machine cannot have the launcher talking to a
# daemon the shelf is not looking at.
#
#   'windows'  docker.exe answers - the user installed Docker Desktop
#   'wsl'      docker lives inside the distro
#   ''         neither, and the doctor's chain says what to do about it
#
# Deciding costs a `docker info`, so it is remembered. Clear-DockerRoute exists
# because the manager outlives the answer: somebody can install Docker while it
# is running, and the same moment that drops the other caches drops this.
$script:PfDockerRoute = $null

function Clear-DockerRoute { $script:PfDockerRoute = $null }

function Get-DockerRoute {
    if ($null -ne $script:PfDockerRoute) { return $script:PfDockerRoute }
    if (Test-WindowsDocker) { $script:PfDockerRoute = 'windows' }
    elseif ((Test-WslReady) -and (Test-WslDocker)) { $script:PfDockerRoute = 'wsl' }
    else { $script:PfDockerRoute = '' }
    return $script:PfDockerRoute
}

# A Windows path as the distro sees it. Only the build needs this - a Dockerfile
# and its context are the only host paths any of this hands to docker; volumes
# are named, not mounted from disk.
function ConvertTo-WslPath {
    param([string]$Path)
    $converted = Invoke-WslHere -u root -e wslpath -u $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $converted) { return $Path }
    return ("$converted").Trim()
}

# Run docker, wherever docker is. Same arguments either way.
#
# `wsl -e` and not `wsl sh -lc`: -e hands the argument vector straight to the
# distro, so a --format string full of braces and spaces arrives as one argument
# instead of being re-split by a shell.
#
# The preference dance is not decoration. Windows PowerShell turns a native
# command's stderr into an error record, and `$ErrorActionPreference = 'Stop'` -
# which engineshelf-docker.ps1 sets - makes that record terminate the script.
# Callers have always handled it by redirecting at the call site:
#
#     docker rm -f $container 2>&1 | Out-Null
#
# because clearing a container that is not there is an ordinary thing to do and
# "No such container" is an ordinary thing to hear. Moving the native call in
# here put a function boundary between the two: the record is now raised in this
# scope, where that redirection does not reach, and a routine `docker rm` ended a
# perfectly good `start` with a NativeCommandError. So the preference is lowered
# for exactly the length of the call, which leaves the record non-terminating and
# every caller's own 2>$null or 2>&1 working as it always did.
# No param block, deliberately. A single [Parameter()] attribute makes this an
# advanced function, and an advanced function gets PowerShell's common parameters
# - which are prefix-matched. `docker run -p 127.0.0.1:6080:6080` then binds -p to
# -PipelineVariable and dies on
#
#     Cannot validate argument '127.0.0.1:6080:6080' because it is not a valid
#     variable name
#
# and -d, -v and -f would have gone the same way against -Debug, -Verbose and
# -Force. A plain function does no binding at all: everything lands in $args
# exactly as written, which is the only correct thing for a passthrough.
function Invoke-DockerHere {
    $was = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        switch (Get-DockerRoute) {
            'windows' { & docker @args }
            'wsl'     { Invoke-WslHere -u root -e docker @args }
            default {
                # Nothing to run it with. Callers check $LASTEXITCODE the way they
                # do for a docker that answered badly, so this has to look the same.
                $global:LASTEXITCODE = 127
            }
        }
    } finally {
        $ErrorActionPreference = $was
    }
}

function Get-PfStatus {
    param([string]$Component)
    switch ($Component) {
        'wsl' {
            if (-not (Test-Have wsl)) { return 'missing' }
            # The command is there and no distro is: WSL is half-installed, which
            # is what a restart-pending machine looks like too.
            if (-not (Test-WslReady)) { return 'inactive' }
            return 'ok'
        }
        'docker' {
            # Desktop answering is a complete answer; the rest of this is about
            # the route for people who did not install it.
            if (Test-WindowsDocker) { return 'ok' }
            if (-not (Test-WslReady)) { return 'missing' }
            if (-not (Test-WslDocker)) { return 'missing' }
            if (Test-WslDockerRunning) { return 'ok' }
            return 'inactive'
        }
        default { return 'na' }
    }
}

function Get-PfLabel {
    param([string]$Component)
    switch ($Component) {
        'python3' { 'Python 3' }
        'curl'    { 'curl' }
        'unzip'   { 'unzip' }
        'docker'  { 'Docker' }
        'rosetta' { 'Rosetta 2' }
        'wsl'     { 'WSL 2' }
    }
}

function Get-PfNeed {
    param([string]$Component)
    switch ($Component) {
        'docker' { 'optional' }
        'wsl'    { 'optional' }
        'curl'   { 'required' }
        'unzip'  { 'required' }
        default  { 'recommended' }
    }
}

function Get-PfWhy {
    param([string]$Component)
    switch ($Component) {
        'python3' { 'Not needed on Windows - the manager runs on PowerShell.' }
        'curl'    { 'Not needed on Windows - downloads use Invoke-WebRequest.' }
        'unzip'   { 'Not needed on Windows - archives are extracted by .NET.' }
        'rosetta' { 'Apple Silicon only.' }
        # Named, because the cost is worth knowing before paying it: three of the
        # four engines have a Windows build and need none of this.
        'wsl'     { 'The Linux machine the Docker edition runs in. On Windows that means Edge, which Microsoft ships only as an installer.' }
        'docker'  { 'Only for the Docker edition. On Windows it runs inside WSL 2, which is the row above.' }
    }
}

function Get-PfFix {
    param([string]$Component, [string]$Status)

    if ($Component -eq 'wsl') {
        # The one step Windows will not let anything do quietly: enabling the
        # feature needs administrator rights, and on most machines a restart
        # after it. Asked for through the system's own elevation prompt, which is
        # the same bargain lib/preflight.sh strikes for Rosetta on macOS.
        #
        # Bare `wsl --install` on purpose. What it does differs by build - some
        # enable the feature and stop, some go on and fetch a distro - and that is
        # survivable here because the next check reads the machine again rather
        # than believing this. A flag that only exists on newer builds would not
        # be.
        if ($Status -eq 'missing') { return 'wsl --install' }
        # Two machines read as this one status and one command has to suit both:
        # the feature is on with no distro to run anything in, or the feature is
        # off and `wsl.exe` is the stub Windows ships regardless. Nothing tells
        # them apart that can be trusted - the message wsl prints is localised,
        # and `wsl --status` is not on every build - so neither is guessed at.
        # `wsl --install -d Ubuntu` covers both: it enables whatever is missing
        # and then fetches the distro. Ubuntu because that is what bare
        # `wsl --install` picks unprompted, so a half-done install and a fresh
        # one end in the same place.
        if ($Status -eq 'inactive') { return 'wsl --install -d Ubuntu' }
        return ''
    }

    if ($Component -ne 'docker') { return '' }

    # Docker Desktop, if the user chose it: starting what is already installed
    # pulls nothing in, so it stays the first answer.
    $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if ($Status -eq 'inactive' -and (Test-Path $desktop)) { return "Start `"$desktop`"" }

    # Everything else happens inside the distro, as root, which is why none of it
    # asks for anything. `wsl -e sudo service docker start` used to be offered
    # here and could not work twice over: sudo wants a password nobody can type,
    # and even when it succeeded the daemon it started was one the Windows docker
    # CLI cannot see - that named pipe is Docker Desktop's, and nothing here sets
    # DOCKER_HOST.
    if (-not (Test-WslReady)) { return '' }
    if ($Status -eq 'inactive') { return 'wsl -u root -e service docker start' }
    # Docker's own convenience script, the same one lib/preflight.sh offers on
    # Linux - because inside the distro this *is* Linux.
    return 'wsl -u root -e sh -lc "curl -fsSL https://get.docker.com | sh"'
}

function Get-PfNote {
    param([string]$Component, [string]$Status)

    if ($Component -eq 'wsl') {
        if ($Status -eq 'missing') {
            return 'Asks for administrator rights, and Windows usually wants a restart afterwards. Come back to this panel after it and carry on where you left off. If it fails outright, virtualisation is off in the firmware and only the BIOS can turn it on.'
        }
        if ($Status -eq 'inactive') {
            # Says both halves of what this state can be, because the fix runs
            # the same command either way and only one of the two wants a
            # restart. Promising "no restart" to the machine that needs one is
            # the worse mistake of the two.
            return 'Installs whatever is missing - the Linux, or the Windows feature underneath it, or both. About 500 MB and nothing to answer, but it asks for administrator rights and Windows may want a restart afterwards. Come back to this panel after it and carry on where you left off.'
        }
        return ''
    }

    if ($Component -ne 'docker') { return '' }
    $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if ($Status -eq 'inactive' -and (Test-Path $desktop)) {
        return 'Starts what is already installed. Nothing is downloaded.'
    }
    if (-not (Test-WslReady)) {
        return 'Needs WSL 2 first - the row above. Docker runs inside it, not on Windows.'
    }
    if ($Status -eq 'inactive') { return 'Starts the daemon inside WSL. Nothing is downloaded.' }
    return 'Docker Engine inside WSL, about 100 MB. Not Docker Desktop: no licence, no admin rights, no restart.'
}

# wsl before docker: it is what docker needs, and the system check is read top
# to bottom.
$PfComponents = @('curl', 'unzip', 'python3', 'rosetta', 'wsl', 'docker')

function Get-PfReport {
    $components = foreach ($id in $PfComponents) {
        $status = Get-PfStatus $id
        [ordered]@{
            id = $id; label = (Get-PfLabel $id); status = $status
            need = (Get-PfNeed $id); why = (Get-PfWhy $id)
            fix = (Get-PfFix $id $status); note = (Get-PfNote $id $status)
        }
    }
    return [ordered]@{
        os = 'windows'
        arch = $env:PROCESSOR_ARCHITECTURE
        components = @($components)
    }
}

function Show-PfReport {
    $report = Get-PfReport
    Write-Host ""
    Write-Host "System check (Windows $($report.arch))" -ForegroundColor White
    Write-Host ""
    $problems = @()
    foreach ($c in $report.components) {
        switch ($c.status) {
            'ok'       { $word = 'ok';          $colour = 'Green' }
            'missing'  { $word = 'missing';     $colour = 'Red';    $problems += $c }
            'inactive' { $word = 'not running'; $colour = 'Yellow'; $problems += $c }
            default    { $word = 'not needed';  $colour = 'DarkGray' }
        }
        Write-Host ("  {0,-11} " -f $c.label) -NoNewline
        Write-Host ("{0,-13}" -f $word) -ForegroundColor $colour -NoNewline
        Write-Host " $($c.need)" -ForegroundColor DarkGray
    }
    Write-Host ""
    if (-not $problems) {
        Write-Host "  Everything EngineShelf needs is present." -ForegroundColor Green
        Write-Host ""
    }
    return $problems
}

# ---------- starting other programs ----------
# Start-Process joins -ArgumentList with plain spaces and quotes nothing, so any
# argument holding one arrives split in pieces. A path is the usual casualty:
# "C:\Users\Some Name\...", a Downloads folder holding a second copy as
# "EngineShelf-1.1.5-Windows (1)", or plain "C:\Program Files".
#
#     powershell -File C:\...\EngineShelf-1.1.5-Windows (1)\app\x.ps1
#     -> Processing -File 'C:\...\EngineShelf-1.1.5-Windows' failed because the
#        file does not have a '.ps1' extension.
#
# gui/server.py has no such problem: it hands subprocess a list, and the list is
# the argument vector. Every Start-Process in this tool goes through here instead.
#
# It lived in engineshelf.ps1, quoting the browser's own arguments and nothing
# else, while five other call sites - every background job the manager starts
# among them - passed paths raw.
function Quote-Args {
    param($items)
    return @($items | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    })
}

# Which fixes Windows will not let a normal process do. Only one so far, and it
# is the only one this tool is willing to ask for: turning WSL on. Everything
# else either runs as the user or runs as root inside the distro, where root
# costs nothing.
function Test-PfNeedsElevation {
    param([string]$Component)
    return ($Component -eq 'wsl')
}

# The counterpart of the osascript block in lib/preflight.sh: where a fix genuinely
# needs administrator rights, ask the system for them rather than failing halfway
# through. The user sees Windows' own prompt and can say no.
#
# -Wait, because the caller checks what changed the moment this returns; without
# it the check would race the installer. Output does not come back through the
# job log - an elevated process cannot inherit these handles - so the state
# afterwards is what the manager reports, not the transcript.
function Invoke-Elevated {
    param([string]$Command)
    Write-Host "  Asking Windows for administrator rights. This runs in a window of its own."
    $quoted = $Command -replace '"', '`"'
    $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
        -ArgumentList (Quote-Args @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $quoted))
    if ($proc.ExitCode -ne 0) { throw "it exited with $($proc.ExitCode)" }
}

# Which links of a chain have already been walked in this run.
$script:PfChained = @{}

# Prints exactly what it would run, asks, then runs it. Never installs silently.
function Invoke-PfFix {
    param([string]$Component, [switch]$AssumeYes)

    $status = Get-PfStatus $Component
    if ($status -eq 'ok') { Write-Host "  $(Get-PfLabel $Component) is already there." -ForegroundColor Green; return $true }
    if ($status -eq 'na') { Write-Host "  $(Get-PfLabel $Component) is not needed on this machine."; return $true }

    $command = Get-PfFix $Component $status
    if (-not $command) {
        Write-Host "X  $(Get-PfLabel $Component) cannot be installed automatically here." -ForegroundColor Red
        if ($Component -eq 'docker') {
            Write-Host "   Docker runs inside WSL 2 here, and WSL is not usable yet."
            Write-Host "   Install that first - it is the row above this one in the system check."
            Write-Host "   Only the Docker edition needs it. The native launcher does not:"
            Write-Host "     .\engineshelf.ps1 run 74"
        }
        return $false
    }

    Write-Host ""
    Write-Host "  $(Get-PfLabel $Component) - $(Get-PfWhy $Component)" -ForegroundColor White
    Write-Host "  This will run:"
    Write-Host "    $command" -ForegroundColor DarkGray
    $note = Get-PfNote $Component $status
    if ($note) { Write-Host "  $note" -ForegroundColor DarkGray }
    Write-Host ""

    if (-not $AssumeYes) {
        # The manager runs this with no console attached, so there is nobody to
        # answer; say so instead of blocking on a prompt nobody will see.
        if ([Environment]::UserInteractive -eq $false) {
            Write-Host "!  Cannot ask for confirmation without a console." -ForegroundColor Yellow
            Write-Host "   Run it yourself, or: .\engineshelf.ps1 doctor --fix"
            return $false
        }
        $answer = Read-Host "  Run it now? [y/N]"
        if ($answer -notmatch '^[yY]') { Write-Host "  Nothing was installed."; return $false }
    }

    try {
        if (Test-PfNeedsElevation $Component) { Invoke-Elevated $command }
        else { Invoke-Expression $command }
    } catch {
        Write-Host "X  That command did not complete: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    # Only worth waiting for a daemon that something just started; installing
    # Docker on its own leaves nothing to wait for.
    if ($Component -eq 'docker' -and $status -eq 'inactive') {
        Write-Host "  Waiting for the Docker daemon" -NoNewline
        for ($i = 0; $i -lt 90; $i++) {
            # Both bracketed: bare `Test-WslDockerRunning -or ...` would hand the
            # function a parameter called -or rather than testing anything.
            if ((Test-WslDockerRunning) -or (Test-WindowsDocker)) { break }
            Write-Host "." -NoNewline
            Start-Sleep -Seconds 1
        }
        Write-Host ""
    }

    # One press, as far as one press can get. Each link re-reads the machine
    # rather than assuming the last one worked, so a step that half-succeeded
    # stops the chain honestly instead of running the next one against nothing.
    # Once per link, so a component that refuses to come up cannot loop.
    $after = Get-PfStatus $Component
    if ($after -ne 'ok' -and $after -ne $status -and -not $script:PfChained[$Component]) {
        $script:PfChained[$Component] = $true
        if (Get-PfFix $Component $after) {
            return (Invoke-PfFix -Component $Component -AssumeYes:$AssumeYes)
        }
    }
    # WSL coming up is what Docker was waiting for. Carry straight on rather than
    # making somebody find the other button.
    if ($Component -eq 'wsl' -and $after -eq 'ok' -and -not $script:PfChained['wsl->docker']) {
        $script:PfChained['wsl->docker'] = $true
        Write-Host "  WSL 2 is ready. Docker Engine goes inside it - carrying on."
        return (Invoke-PfFix -Component docker -AssumeYes:$AssumeYes)
    }

    if ($after -eq 'ok') {
        Write-Host "  $(Get-PfLabel $Component) is ready." -ForegroundColor Green
        return $true
    }
    if ($Component -eq 'wsl') {
        # Not a failure. Windows enables the feature and then wants the machine
        # back, and there is no way to finish from this side of the restart.
        Write-Host "!  WSL 2 is installed but not answering yet." -ForegroundColor Yellow
        Write-Host "   Restart Windows, then press this again - it will pick up from here."
        return $false
    }
    Write-Host "!  $(Get-PfLabel $Component) still is not usable." -ForegroundColor Yellow
    return $false
}
