#
# The Windows half, checked from any machine that has PowerShell.
#
#     pwsh -NoProfile -File tools/check-windows.ps1        # macOS / Linux
#     powershell -File tools\check-windows.ps1             # Windows
#
# gui/server.ps1 and engineshelf.ps1 are half the product and neither runs on the
# machine most of this is written on, so nothing exercised them: both drifted from
# the page until a feature was missing on Windows entirely. These suites lift the
# real functions out of those files by parse tree and run them against stubs for
# everything that needs Windows - Start-Process, taskkill, docker, the shelf on
# disk - so the code under test is the code that ships, not a copy of it.
#
# What each one covers:
#   streams  one log per target, rendered from the job files
#   routes   every endpoint, and the answers the page reads off them
#   caches   what a state poll costs, and what a finished job invalidates
#   cli      the download meter, and the refresh that asks the vendors
#   preflight the WSL 2 -> Docker chain, every state a machine can be in
#   webkit   which Ubuntu image a container is built from, per revision
#
[CmdletBinding()]
param(
    # The cli suite serves a file to itself to check the download meter.
    [string]$Port = '8899'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$suites = @('streams', 'routes', 'caches', 'cli', 'preflight', 'webkit')
$failed = @()

# First, and cheapest: a name nothing assigns is $null here rather than an error,
# and $null goes on to behave - wrongly, quietly, until some line finally indexes
# it. Four of those shipped.
Write-Host ""
Write-Host "=== variables ===" -ForegroundColor White
$global:LASTEXITCODE = 0
& (Join-Path $PSScriptRoot 'check-psvars.ps1')
if ($LASTEXITCODE -ne 0) { $failed += 'variables' }

foreach ($name in $suites) {
    $path = Join-Path $PSScriptRoot "windows-tests\$name.tests.ps1"
    if (-not (Test-Path $path)) { $path = Join-Path $PSScriptRoot "windows-tests/$name.tests.ps1" }
    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor White
    $global:LASTEXITCODE = 0
    if ($name -eq 'cli') { & $path -Port $Port } else { & $path }
    if ($LASTEXITCODE -ne 0) { $failed += $name }
}

Write-Host ""
if ($failed.Count) {
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "the Windows half holds up" -ForegroundColor Green
