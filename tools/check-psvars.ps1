#
# Every variable the shipped PowerShell reads, checked against the ones anything
# it can see defines.
#
#     pwsh -NoProfile -File tools/check-psvars.ps1
#
# PowerShell has no such thing as an undefined variable: a name nothing assigned
# is $null, and $null goes on to behave. `$null -notcontains 'webkit'` is true, so
# a check written against the wrong list waves nothing through and refuses
# everything. `$null['webkit']` throws, but only when that line is finally
# reached. Neither shows up at parse time, and both survived into a release.
#
# Four did exactly that - twice in engineshelf-docker.ps1, twice in
# engineshelf.ps1 - all from one slip: the code was written against the shell
# twin's names rather than the PowerShell library's API.
#
#   $Engines      the shell calls the engine list that; here it is $EngineList,
#                 behind Test-EngineKnown. Every Docker command died on
#                 "Unknown engine: <engine>. Known: " with an empty list, and
#                 `engineshelf.ps1 catalog` walked $null and listed Chromium
#                 alone under a footer advertising `run firefox:115`.
#   $EngineNames  a lookup that lives on the manager's side of the house. Eight
#                 ordinary Write-Ok lines threw "Cannot index into a null array"
#                 instead of printing - after doing the work.
#
# What counts as defined: assigned anywhere in the file, a parameter, a loop
# variable, or defined in a file this one dot-sources.
#
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# Everything PowerShell provides. Not a style list - a name here is one nothing
# has to assign.
$AUTOMATIC = @(
    '_', 'PSItem', 'args', 'input', 'this', 'true', 'false', 'null', 'error',
    'matches', 'foreach', 'switch', 'lastexitcode', 'pid', 'host', 'pwd', 'home',
    'psscriptroot', 'pscommandpath', 'myinvocation', 'psboundparameters',
    'psversiontable', 'pshome', 'profile', 'executioncontext', 'stacktrace',
    'outputencoding', 'nestedpromptlevel', 'shellid', 'enabledexperimentalfeatures',
    'erroractionpreference', 'progresspreference', 'warningpreference',
    'verbosepreference', 'debugpreference', 'informationpreference',
    'confirmpreference', 'whatifpreference', 'psdefaultparametervalues',
    'psnativecommandusearguementlist', 'iscoreclr', 'iswindows', 'ismacos', 'islinux'
) | ForEach-Object { $_.ToLower() }

function Get-Ast { param([string]$Path)
    return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
}

# Names anything in this file assigns, takes as a parameter, or walks a loop with.
function Get-Defined {
    param($Ast)
    $names = New-Object System.Collections.Generic.HashSet[string]
    $add = {
        param($n)
        if ($n) { [void]$names.Add(($n -replace '^(script|global|local|private|using):', '').ToLower()) }
    }
    foreach ($node in $Ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true)) {
        $left = $node.Left
        if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
        if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            & $add $left.VariablePath.UserPath
        }
    }
    foreach ($node in $Ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.ParameterAst]
    }, $true)) { & $add $node.Name.VariablePath.UserPath }
    foreach ($node in $Ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.ForEachStatementAst]
    }, $true)) { & $add $node.Variable.VariablePath.UserPath }
    # `catch { $_ }` and data/trap blocks bind their own; both are automatic.
    # The comma keeps it a set: PowerShell unrolls a collection on the way out,
    # and the caller needs something it can still Add to.
    return ,$names
}

# Names it reads. An assignment's own target is not a read.
function Get-Read {
    param($Ast)
    $targets = New-Object System.Collections.Generic.HashSet[string]
    foreach ($node in $Ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true)) {
        $left = $node.Left
        if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
        if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            [void]$targets.Add($left.Extent.Text)
        }
    }
    $found = @{}
    foreach ($node in $Ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.VariableExpressionAst]
    }, $true)) {
        if ($targets.Contains($node.Extent.Text) -and
            $node.Parent -is [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
        $path = $node.VariablePath
        # $env:FOO and friends are drives, not variables.
        if ($path.IsDriveQualified) { continue }
        $name = ($path.UserPath -replace '^(script|global|local|private|using):', '').ToLower()
        if ($AUTOMATIC -contains $name) { continue }
        if (-not $found.ContainsKey($name)) { $found[$name] = $node.Extent.StartLineNumber }
    }
    return $found
}

# Which libraries a file dot-sources, by the name it names them with.
function Get-Sourced {
    param([string]$Text)
    $out = @()
    foreach ($m in [regex]::Matches($Text, "\.\s*\(Join-Path[^)]*['""]([^'""]+\.ps1)['""]")) {
        $out += ($m.Groups[1].Value -replace '\\', '/')
    }
    return $out
}

$files = @(
    'gui/server.ps1', 'engineshelf.ps1', 'engineshelf-docker.ps1', 'gui.ps1',
    'lib/preflight.ps1', 'lib/engines.ps1'
)

$bad = 0
foreach ($rel in $files) {
    $path = Join-Path $root $rel
    if (-not (Test-Path $path)) { Write-Host "FAIL $rel is not there"; $bad++; continue }
    $text = Get-Content $path -Raw
    $ast = Get-Ast $path

    $defined = Get-Defined $ast
    foreach ($lib in (Get-Sourced $text)) {
        $libPath = Join-Path $root $lib
        if (-not (Test-Path $libPath)) { continue }
        foreach ($name in (Get-Defined (Get-Ast $libPath))) { [void]$defined.Add($name) }
    }
    # A function's own name is not a variable, but `${function:x}` and splatting
    # read like one; nothing here does either.
    $loose = @()
    foreach ($entry in (Get-Read $ast).GetEnumerator()) {
        if (-not $defined.Contains($entry.Key)) { $loose += "line $($entry.Value): `$$($entry.Key)" }
    }
    if ($loose.Count) {
        $bad += $loose.Count
        Write-Host "FAIL $rel" -ForegroundColor Red
        foreach ($line in ($loose | Sort-Object)) { Write-Host "       $line" }
        Write-Host "       Nothing assigns these. PowerShell reads them as `$null and carries on."
    } else {
        Write-Host ("ok   {0,-24} {1} names, all defined" -f $rel, $defined.Count)
    }
}

Write-Host ''
if ($bad) { Write-Host "$bad undefined read$(if ($bad -eq 1) { '' } else { 's' })" -ForegroundColor Red; exit 1 }
Write-Host 'every variable the shipped PowerShell reads is defined somewhere it can see' -ForegroundColor Green
# Said out loud: a script that just stops leaves $LASTEXITCODE at whatever the
# last command set, and a runner reading it calls a pass a failure.
exit 0
