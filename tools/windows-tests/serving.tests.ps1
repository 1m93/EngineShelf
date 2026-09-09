#
# Nothing on the manager's one thread waits for ever: gui/server.ps1's accepting
# layer over real sockets, and lib/preflight.ps1's bounded probe over a real
# child process.
#
# The bug this covers: a connection is not a request. A browser opens sockets it
# has nothing to send on yet - one per parallel fetch, the spare for a first one
# that is slow, the preconnect for the next click - and reading from one of those
# blocks until it speaks. The manager is one thread, so a single silent socket
# stopped it answering anything at all: the page was served its HTML, its CSS and
# its script, and then sat on its skeleton for ever with /api/token unanswered.
# Nothing in the window said so, and the watchdog was frozen with it.
#
# Real TcpListener and real TcpClients, because what is being asserted is what
# the sockets do; only Read-Request's answer and the route are stubbed.
#
$ErrorActionPreference = 'Stop'

$LiftFrom = @('./gui/server.ps1', './lib/preflight.ps1')
$LiftFunctions = @('Add-Waiting', 'Invoke-Waiting', 'Invoke-Served', 'Test-Talking',
                   'Close-Client', 'Invoke-Bounded', 'Split-Lines', 'Quote-Args')
$LiftVariables = @('Waiting', 'ServedAny', 'WaitingSeconds', 'WaitingMost',
                   'PfTimedOut', 'PfAskSeconds', 'PfWslSeconds', 'PfVolumeSeconds',
                   'PfStopSeconds', 'PfRemoveSeconds')
. "$PSScriptRoot/harness.ps1"

# --- stubs ----------------------------------------------------------------- #
# The real Read-Request over a real socket, minus the parsing: what matters here
# is that it is only ever called on a socket with bytes waiting.
$script:served = @()
$script:reads = 0
function Read-Request {
    param($Stream)
    $script:reads++
    $buffer = New-Object byte[] 1024
    $read = $Stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) { return $null }
    return @{ method = 'GET'; path = [Text.Encoding]::ASCII.GetString($buffer, 0, $read).Trim() }
}
function Invoke-Route { param($Stream, $Request) $script:served += $Request.path }
function Send-Json { param($Stream, $Object, [int]$Status = 200) }

# --- a listener of our own ------------------------------------------------- #
$listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port

function Connect-Test {
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect('127.0.0.1', $port)
    return $client
}

function Say-Test {
    param($Client, [string]$Text)
    $bytes = [Text.Encoding]::ASCII.GetBytes($Text)
    $Client.GetStream().Write($bytes, 0, $bytes.Length)
    $Client.GetStream().Flush()
}

# The loop's own body, so what is under test is the pair the real one calls and
# in the order it calls them.
function Step-Test {
    $script:ServedAny = $false
    Add-Waiting $listener
    Invoke-Waiting | Out-Null
    # Poll is instant and a socket written to a moment ago may not have arrived
    # yet; the real loop sleeps 120ms for the same reason.
    Start-Sleep -Milliseconds 60
    Add-Waiting $listener
    Invoke-Waiting | Out-Null
}

Write-Host ''
Write-Host 'a silent socket is not a request'

# One socket, nothing on it. The manager took its whole shelf down here.
$silent = Connect-Test
Step-Test
Test-That 'nothing was read off it' $script:reads 0
Test-That 'it is being held, not served' $script:Waiting.Count 1
Test-That 'and the loop knows it did nothing' $script:ServedAny $false

# The whole of the bug: with that one still open, does the next request answer?
$talker = Connect-Test
Say-Test $talker '/api/token'
Step-Test
Test-That 'the next request is answered anyway' $script:served @('/api/token')
Test-That 'and the silent one is still waiting' $script:Waiting.Count 1

# And when it finally does speak, it is served like any other.
Say-Test $silent '/api/state'
Step-Test
Test-That 'a socket that speaks later is served' $script:served @('/api/token', '/api/state')
Test-That 'nothing is left waiting' $script:Waiting.Count 0

Write-Host ''
Write-Host 'sockets that will never speak'

# A browser that closed a spare without using it: readable, but with nothing to
# read - which is not a request and must not be answered as one.
$dropped = Connect-Test
Step-Test
$before = $script:reads
$dropped.Close()
Step-Test
Test-That 'a closed socket is dropped, not read' $script:reads $before
Test-That 'and it leaves the list' $script:Waiting.Count 0

# A browser that aborted a request resets the connection rather than closing it,
# and a reset socket answers Poll and then throws on Available. Out of the pass
# that would not be a dropped request: the loop's only try has Stop-Everything in
# its finally, so it would be the manager closing, with the browsers and
# containers it started.
$reset = Connect-Test
Step-Test
$reset.LingerState = New-Object System.Net.Sockets.LingerOption($true, 0)
$reset.Close()
Start-Sleep -Milliseconds 60
$outcome = 'served on'
try { Step-Test } catch { $outcome = "threw: $($_.Exception.Message)" }
Test-That 'a reset is not an error the loop sees' $outcome 'served on'
Test-That 'and the socket is gone' $script:Waiting.Count 0
$after = Connect-Test
Say-Test $after '/api/ping'
Step-Test
Test-That 'the manager is still answering' $script:served[-1] '/api/ping'

# Spares do not collect for ever, in either direction.
Test-That 'a silent socket has a limit' ($WaitingSeconds -gt 0) $true
Test-That 'and so does the list' ($WaitingMost -gt 0) $true

$flood = @()
for ($i = 0; $i -lt $WaitingMost + 8; $i++) { $flood += Connect-Test }
Step-Test
Test-That 'a flood of them is capped' $script:Waiting.Count $WaitingMost
foreach ($client in $flood) { try { $client.Close() } catch { } }

Write-Host ''
Write-Host 'the timeouts a socket is accepted with'

# Both are what stops a half-sent request, or a client that stops reading
# mid-answer, from being another wait with no end to it.
$body = $LiftedFunctions['Add-Waiting'].Extent.Text
Test-That 'a read cannot wait for ever' ($body -match 'ReceiveTimeout\s*=\s*\d+') $true
Test-That 'nor can a write' ($body -match 'SendTimeout\s*=\s*\d+') $true

$listener.Stop()

Write-Host ''
Write-Host 'a question the machine never answers'
# The other half of the same rule, and the one that took the manager down
# before it had a window: every docker and wsl call used to be `& docker info`
# with nothing around it, on this same thread. A real child process here, because
# what is under test is the killing of one.
#
# Whatever is hosting this suite: powershell.exe on Windows, pwsh anywhere else,
# and it is the one binary certain to be on both.
$host_exe = (Get-Process -Id $PID).Path

$took = [Diagnostics.Stopwatch]::StartNew()
$slow = Invoke-Bounded $host_exe @('-NoProfile', '-Command', 'Start-Sleep -Seconds 45') 2
$took.Stop()
Test-That 'it does not wait for the answer' ($took.Elapsed.TotalSeconds -lt 20) $true
Test-That 'it says it ran out of time' $slow.timedOut $true
Test-That 'and fails the way `timeout` does' $slow.code 124
Test-That 'and leaves the shrug where a caller can read it' $script:PfTimedOut $true

$script:PfTimedOut = $false
$fine = Invoke-Bounded $host_exe @('-NoProfile', '-Command', 'Write-Output ready; exit 3') 30
Test-That 'a command that answers is not touched' $fine.timedOut $false
Test-That 'its exit code comes back' $fine.code 3
Test-That 'so does what it printed' ($fine.out.Trim()) 'ready'
Test-That 'and nothing is marked as having timed out' $script:PfTimedOut $false

# stderr is a pipe to read, not an error record raised in this scope - which is
# what made `wsl -l -q` on a machine without WSL take the whole manager down in
# 1.1.6. Under 'Stop', where every one of these scripts runs.
$ErrorActionPreference = 'Stop'
$threw = $false
$noisy = $null
try {
    $noisy = Invoke-Bounded $host_exe @('-NoProfile', '-Command',
        '[Console]::Error.WriteLine("not installed"); exit 1') 30
} catch { $threw = $true }
Test-That 'a complaint on stderr does not end the run' $threw $false
Test-That 'it is just output' ($noisy.out -match 'not installed') $true
Test-That 'with the failure kept' $noisy.code 1
$ErrorActionPreference = 'Continue'

$gone = Invoke-Bounded 'engineshelf-no-such-command' @('info') 5
Test-That 'a command that is not there answers 127' $gone.code 127
Test-That 'without claiming it timed out' $gone.timedOut $false

# A job gets nothing on stdin - rule 4, and the reason winget waiting on its
# source agreements is a log that stops dead. A probe is no different: it is
# started with a pipe that is closed at once, so anything that asks a question
# reads end-of-file instead of waiting.
$asked = Invoke-Bounded $host_exe @('-NoProfile', '-Command',
    '$line = [Console]::In.ReadLine(); Write-Output ("saw:" + $line)') 15
Test-That 'a probe that reads stdin gets end of file' ($asked.out.Trim()) 'saw:'
Test-That 'rather than waiting for an answer' $asked.timedOut $false

Write-Host ''
Write-Host 'the limits are the ones server.py uses'
Test-That 'a docker question: docker_out(timeout=8)' $PfAskSeconds 8
Test-That 'the volume read: 20' $PfVolumeSeconds 20
Test-That 'stopping containers: 90' $PfStopSeconds 90
Test-That 'and removing them: 30' $PfRemoveSeconds 30
Test-That 'a wsl call may have to boot the distro first' ($PfWslSeconds -ge $PfAskSeconds) $true

Exit-WithTally
