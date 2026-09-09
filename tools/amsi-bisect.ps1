#
# Which lines of a .ps1 does the machine's antivirus object to?
#
#     powershell -NoProfile -File tools\amsi-bisect.ps1 -Path gui\server.ps1
#
# Windows Defender scans script text through AMSI before PowerShell compiles it.
# When it objects, nothing in the file has run: the whole script comes back as a
# parse error pointing at line 1, whatever the real cause was.
#
#     gui.ps1 : At ...\gui\server.ps1:1 char:1
#     + [CmdletBinding()]
#     This script contains malicious content and has been blocked by your
#     antivirus software.
#         + FullyQualifiedErrorId : ScriptContainedMaliciousContent,gui.ps1
#
# A local HTTP manager is built out of the same parts a backdoor is - a socket
# listening on a port, a hidden powershell.exe started with a command line - so
# the whole file can trip a signature that no one line of it deserves. This finds
# which lines those are, so the fix is measured rather than guessed at.
#
# [ScriptBlock]::Create parses text and hands it to AMSI exactly as loading a
# file does, but never runs it: nothing here executes any part of the script
# under test. A chunk that is merely bad syntax throws a different error and is
# read as "not objected to", which is what lets the file be cut at any line.
#
# Exit codes: 0 a window was found, 2 the file is not blocked on this machine,
# 3 blocked as a whole while no part of it is - which is a cloud or ML verdict
# on the file rather than a signature in it, and no edit can be aimed at it.
#
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    # How many lines either side of the window to print, for context.
    [int]$Context = 3,
    # Skip the per-line pruning pass. Much faster, much wider answer.
    [switch]$Rough
)

$ErrorActionPreference = 'Stop'

$script:Scans = 0
$script:Reason = ''

# $true when AMSI objects to this text, $false for anything else - including
# text that does not parse, which is most windows of a file cut at arbitrary
# lines.
#
# The verdict arrives as a ParseException carrying a ParseError whose ErrorId is
# ScriptContainedMaliciousContent, but a static .NET call throws it wrapped, so
# the id is not on the ErrorRecord: the inner exceptions are walked for it. The
# id stays English on a localised Windows; the message does not, so it is only
# the last resort.
function Test-Objected {
    param([string[]]$Lines)

    $text = ($Lines -join "`n")
    if (-not $text.Trim()) { return $false }
    $script:Scans++

    try {
        [void][ScriptBlock]::Create($text)
        return $false
    } catch {
        $ex = $_.Exception
        while ($ex) {
            $errors = $null
            try { $errors = $ex.Errors } catch { }
            foreach ($pe in @($errors)) {
                if ($pe -and ([string]$pe.ErrorId) -like '*MaliciousContent*') {
                    if (-not $script:Reason) { $script:Reason = [string]$pe.ErrorId }
                    return $true
                }
            }
            $ex = $ex.InnerException
        }
        if (([string]$_.FullyQualifiedErrorId) -like '*MaliciousContent*') {
            if (-not $script:Reason) { $script:Reason = [string]$_.FullyQualifiedErrorId }
            return $true
        }
        if ([string]$_.Exception.Message -match 'malicious|AMSI|antivirus') {
            if (-not $script:Reason) { $script:Reason = 'matched on message text' }
            return $true
        }
        return $false
    }
}

function Get-Window {
    param([string[]]$All, [int]$First, [int]$Last)
    return $All[($First - 1)..($Last - 1)]
}

$file = (Resolve-Path -LiteralPath $Path).Path
$all = @(Get-Content -LiteralPath $file)
$count = $all.Count
$rule = ([string][char]0x2500) * 68

Write-Host ""
Write-Host "  $file  ($count lines)"
Write-Host ""

if (-not (Test-Objected $all)) {
    Write-Host "  Not blocked on this machine. Nothing to bisect."
    Write-Host "  Real-time protection is off, an exclusion already covers this path,"
    Write-Host "  or the antivirus objects to the file rather than to its text."
    Write-Host ""
    exit 2
}

Write-Host "  Blocked ($script:Reason). Narrowing..."

# Smallest end E such that lines 1..E are still objected to. The invariant is
# that $hi always names a blocked prefix, so the search cannot end anywhere else.
$lo = 1
$hi = $count
while ($lo -lt $hi) {
    $mid = [int](($lo + $hi) / 2)
    if (Test-Objected (Get-Window $all 1 $mid)) { $hi = $mid } else { $lo = $mid + 1 }
}
$last = $hi

# Largest start S such that S..E is still objected to.
$lo = 1
$hi = $last
while ($lo -lt $hi) {
    $mid = [int](($lo + $hi + 1) / 2)
    if (Test-Objected (Get-Window $all $mid $last)) { $lo = $mid } else { $hi = $mid - 1 }
}
$first = $lo

if (-not (Test-Objected (Get-Window $all $first $last))) {
    Write-Host ""
    Write-Host "  The whole file is blocked but no part of it is."
    Write-Host "  That is a verdict on the file rather than a signature in it - a"
    Write-Host "  cloud or machine-learning detection, which reads the file whole and"
    Write-Host "  which no edit here can be aimed at. Take the detection name out of"
    Write-Host "  Get-MpThreatDetection and submit the file to Microsoft as a false"
    Write-Host "  positive; until it clears, an exclusion is the only local answer."
    Write-Host ""
    exit 3
}

# A signature is rarely every line of the window it was narrowed to. Drop one
# line at a time, keeping the drop whenever the rest is still objected to.
$keep = @($first..$last)
if (-not $Rough) {
    Write-Host "  Window is lines $first-$last ($($keep.Count) lines). Pruning..."
    $i = $keep.Count - 1
    while ($i -ge 0) {
        $drop = $keep[$i]
        $trial = @($keep | Where-Object { $_ -ne $drop })
        if ($trial.Count -gt 0) {
            $text = @($trial | ForEach-Object { $all[$_ - 1] })
            if (Test-Objected $text) { $keep = $trial }
        }
        $i--
    }
}

Write-Host ""
Write-Host "  $rule"
Write-Host "  What the antivirus objects to  ($($keep.Count) of $count lines, $script:Scans scans)"
Write-Host "  $rule"
Write-Host ""

$low = [Math]::Max(1, $keep[0] - $Context)
$high = [Math]::Min($count, $keep[$keep.Count - 1] + $Context)
foreach ($n in $low..$high) {
    $mark = if ($keep -contains $n) { '>>' } else { '  ' }
    Write-Host ("  {0} {1,5}  {2}" -f $mark, $n, $all[$n - 1])
}

Write-Host ""
Write-Host "  The lines marked >> are the smallest set that is still blocked on its"
Write-Host "  own. Rewrite those, then run this again."
Write-Host ""
exit 0
