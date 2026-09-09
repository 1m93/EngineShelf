#
# EngineShelf - open the graphical manager (Windows)
#
# Starts a small local web server and opens it in a window of its own. Nothing is
# installed and nothing listens outside this machine: the server binds to
# 127.0.0.1 and every request has to carry a token generated for this run.
#
# Closing the window quits the manager, the browsers it launched and any Docker
# containers it started.
#
#   .\gui.ps1              # open the manager
#   .\gui.ps1 -Port 8080   # use a specific port
#   .\gui.ps1 -Tab         # a tab in your default browser instead of a window
#   .\gui.ps1 -NoOpen      # start it but open nothing
#   .\gui.ps1 -New         # a second manager, even if one is already running
#
# Opening it while a manager is already running does not start a second one: it
# opens that manager's window again.
#
[CmdletBinding()]
param(
    [int]$Port = 7411,
    [switch]$NoOpen,
    [switch]$Tab,
    [switch]$New
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Did the antivirus refuse to let PowerShell load a file, rather than something
# in the file going wrong? Windows Defender scans a .ps1 through AMSI before
# PowerShell compiles it, and a refusal arrives as a ParseException carrying a
# ParseError whose ErrorId is ScriptContainedMaliciousContent. A .NET call would
# wrap it, so the inner exceptions are walked for it. The id stays English on a
# localised Windows; the message does not, so it is the last resort.
function Test-BlockedByAntivirus {
    param($Err)
    if (([string]$Err.FullyQualifiedErrorId) -like '*MaliciousContent*') { return $true }
    $ex = $Err.Exception
    while ($ex) {
        $errors = $null
        try { $errors = $ex.Errors } catch { }
        foreach ($one in @($errors)) {
            if ($one -and ([string]$one.ErrorId) -like '*MaliciousContent*') { return $true }
        }
        $ex = $ex.InnerException
    }
    return ([string]$Err.Exception.Message -match 'malicious|AMSI')
}

# Windows only, and stated here rather than mirrored: there is no AMSI on the
# other half, so gui.sh has nothing to catch. What it catches is a false
# positive this manager can genuinely collect - it listens on a loopback port
# and starts child processes, which is most of what a backdoor does - and left
# uncaught it reaches the user as a parse error pointing at line 1 of a file
# whose line 1 is [CmdletBinding()], with nothing of ours having run to say
# what happened or what to do about it.
try {
    & (Join-Path $ScriptDir 'gui\server.ps1') -Port $Port -NoOpen:$NoOpen -Tab:$Tab -New:$New
} catch {
    if (-not (Test-BlockedByAntivirus $_)) { throw }
    Write-Host ""
    Write-Host "  Your antivirus blocked EngineShelf before it could start." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Nothing is wrong with the download. Windows scans PowerShell files as"
    Write-Host "  they load, and this one opens a local port and starts child processes,"
    Write-Host "  which is enough to be mistaken for something else. It listens on"
    Write-Host "  127.0.0.1 only, and reaches the internet only to fetch a browser you"
    Write-Host "  have asked for."
    Write-Host ""
    Write-Host "  To allow it, in PowerShell as Administrator:"
    Write-Host ""
    Write-Host "      Add-MpPreference -ExclusionPath `"$ScriptDir`"" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  The command line does not go through the manager, and may run as it is:"
    Write-Host ""
    Write-Host "      .\engineshelf.ps1 run 74" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  If you would rather not add an exclusion, report it to Microsoft as a"
    Write-Host "  false positive: https://www.microsoft.com/wdsi/filesubmission"
    Write-Host ""
    exit 1
}
