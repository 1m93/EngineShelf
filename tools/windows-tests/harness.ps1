#
# Lifts named functions and top-level variables out of a real script, by parse
# tree, into the caller's scope. Dot-source it:
#
#   $LiftFrom      = './gui/server.ps1'
#   $LiftFunctions = @('Get-StreamLog', ...)
#   $LiftVariables = @('StreamLines', ...)   # no sigil, no scope
#   . "$PSScriptRoot/harness.ps1"
#
# Lifting rather than copying is the point: a test that restated the constants or
# the parameter lists would keep passing after the file it is meant to guard had
# changed underneath it.
#
$ErrorActionPreference = 'Stop'

# One file or several. server.ps1 dot-sources lib/preflight.ps1 at runtime, so a
# test of server.ps1 has to reach into it too - with the real function, not a
# stand-in that can drift away from it.
$liftAsts = @()
foreach ($liftOne in @($LiftFrom)) {
    $liftAsts += [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path $liftOne).Path, [ref]$null, [ref]$null)
}

# $LiftInspect names functions whose parse tree is wanted without defining them:
# a stub stands in for the real one, and the test asserts the two still agree.
if (-not (Get-Variable -Name LiftInspect -Scope Local -ErrorAction SilentlyContinue)) {
    $LiftInspect = @()
}

$liftFound = @{}
$liftFns = @()
foreach ($one in $liftAsts) {
    $liftFns += @($one.FindAll({
        $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true))
}
foreach ($fn in $liftFns) {
    if ($LiftFunctions -contains $fn.Name) {
        $liftFound[$fn.Name] = $fn
        Invoke-Expression $fn.Extent.Text
    } elseif ($LiftInspect -contains $fn.Name) {
        $liftFound[$fn.Name] = $fn
    }
}
foreach ($name in $LiftInspect) {
    if (-not $liftFound[$name]) { throw "$LiftFrom has no function $name" }
}
foreach ($name in $LiftFunctions) {
    if (-not $liftFound[$name]) { throw "$LiftFrom has no function $name" }
}

# Top-level assignments only - the ones that are script state when the real file
# runs. Anything inside a function belongs to that function.
$liftSeen = @{}
$liftTop = @()
foreach ($one in $liftAsts) { $liftTop += @($one.EndBlock.Statements) }
foreach ($node in $liftTop) {
    if ($node -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
    $target = $node.Left
    if ($target -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
    $bare = $target.VariablePath.UserPath -replace '^(script|global|local):', ''
    if ($LiftVariables -notcontains $bare) { continue }
    $liftSeen[$bare] = $true
    Invoke-Expression $node.Extent.Text
}
foreach ($name in $LiftVariables) {
    if (-not $liftSeen[$name]) { throw "$LiftFrom has no top-level `$$name" }
}

# The parse tree of what was lifted, for tests that assert on shape rather than
# behaviour - a stub's parameter list against the real one, say.
$LiftedFunctions = $liftFound

function Get-LiftedParams {
    param([string]$Name)
    $fn = $LiftedFunctions[$Name]
    if (-not $fn -or -not $fn.Body.ParamBlock) { return @() }
    return @($fn.Body.ParamBlock.Parameters |
             ForEach-Object { $_.Name.VariablePath.UserPath })
}

$script:failures = 0
function Test-That {
    param([string]$What, $Got, $Want)
    $ok = if ($Want -is [array]) { (@($Got) -join ([char]1)) -eq (@($Want) -join ([char]1)) }
          else { $Got -eq $Want }
    if ($ok) { Write-Host "  ok   $What" }
    else {
        Write-Host "  FAIL $What"
        Write-Host "       got:  $($Got | ConvertTo-Json -Compress -Depth 4)"
        Write-Host "       want: $($Want | ConvertTo-Json -Compress -Depth 4)"
        $script:failures++
    }
}

function Exit-WithTally {
    Write-Host ''
    if ($script:failures) { Write-Host "$script:failures failed"; exit 1 }
    Write-Host 'all passed'
    exit 0
}
