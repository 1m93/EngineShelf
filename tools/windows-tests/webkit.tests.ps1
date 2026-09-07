#
# Which Ubuntu image a WebKit container is built from.
#
# The base and the archive are one decision: a webkit-ubuntu-20.04.zip unpacked
# into a jammy image builds cleanly and then dies at exec on libvpx.so.6, which
# reaches the user as "WebKit keeps failing to start (status 127)" a gigabyte and
# ten minutes after the button. Nothing about that failure points back here.
#
# It was decided by a boundary - below r1724 focal, above it jammy - and measured
# against the CDN, availability is neither a boundary nor monotonic: r1908 is
# focal-only in the middle of the jammy range, r1668 and r1715 were published for
# nothing at all. So the launcher asks, and these are the answers it has to give.
#
$ErrorActionPreference = 'Stop'

$LiftFrom = './engineshelf-docker.ps1'
$LiftFunctions = @('Get-WebKitUbuntu', 'Invoke-Build')
$LiftVariables = @('WebKitBases')
. "$PSScriptRoot/harness.ps1"

# What the CDN has, for the revision under test, and every request it was asked.
$script:published = @()
$script:asked = @()
$WebKitCdn = 'https://cdn.example/webkit'

function Test-UrlExists {
    param([string]$Url)
    $script:asked += $Url
    foreach ($release in $script:published) {
        if ($Url -like "*webkit-ubuntu-$release.zip") { return $true }
    }
    return $false
}

# Invoke-Build's surroundings. The docker call is recorded rather than made.
$DockerDir = '/tmp/es-docker'
$script:built = @()
$script:died = ''
function Invoke-DockerHere { $script:built = @($args) }
function Get-DockerRoute { return 'windows' }
function ConvertTo-WslPath { param([string]$Path) return $Path }
function Join-Path { param($Path, $ChildPath) return "$Path/$ChildPath" }
# The real one exits; here it records and stops the build, which is what the
# caller sees either way.
function Die { param($m) $script:died = $m; throw 'died' }

function Invoke-BuildFor {
    param([string]$Revision)
    $script:built = @(); $script:died = ''; $script:asked = @()
    $target = @{ Engine = 'webkit'; Revision = $Revision
                 Dockerfile = 'Dockerfile.webkit'
                 BuildArgs = @("REVISION=$Revision") }
    try { Invoke-Build $target 'engineshelf:webkit-x' @() } catch { }
}

function Get-BuildArg {
    param([string]$Name)
    for ($i = 0; $i -lt $script:built.Count; $i++) {
        if ($script:built[$i] -eq '--build-arg' -and
            $script:built[$i + 1] -like "$Name=*") {
            return ($script:built[$i + 1] -split '=', 2)[1]
        }
    }
    return ''
}

Write-Host ''
Write-Host 'the preference order is the decision'
# Two releases carry the same revision often enough that which one is tried
# first is not a detail: it is which image gets built for half the shelf.
Test-That 'jammy first, where both exist' `
    ($WebKitBases[0]) '22.04'
$script:published = @('20.04', '22.04')
Test-That 'and the pair resolves to it' (Get-WebKitUbuntu '1860') '22.04'
Test-That 'without asking about anything after it' $script:asked.Count 1

Write-Host ''
Write-Host 'a revision published for one release only'
$script:published = @('20.04')
$script:asked = @()
# r1908: focal-only, and above the boundary the old rule used - so the rule
# picked jammy, the download 404d, and the build failed a minute in.
Test-That 'focal-only, above where the boundary was' (Get-WebKitUbuntu '1908') '20.04'
Test-That 'found by asking, not by its number' $script:asked.Count 2
$script:published = @('22.04')
Test-That 'jammy-only, below where the boundary was' (Get-WebKitUbuntu '1751') '22.04'

Write-Host ''
Write-Host 'a revision published for nothing'
$script:published = @()
$script:asked = @()
Test-That 'answers empty rather than a release' (Get-WebKitUbuntu '1668') ''
Test-That 'having tried all of them' $script:asked.Count $WebKitBases.Count

Write-Host ''
Write-Host '24.04 is a fallback, not a preference'
# It is last on purpose: 22.04 and 20.04 are the two this image has been built
# and run against. A revision with no other option still gets a container.
$script:published = @('22.04', '24.04')
Test-That 'not chosen while 22.04 is there' (Get-WebKitUbuntu '2336') '22.04'
$script:published = @('24.04')
Test-That 'chosen when it is the only one' (Get-WebKitUbuntu '9999') '24.04'

Write-Host ''
Write-Host 'the build carries the base it resolved'
$script:published = @('20.04')
Invoke-BuildFor '1683'
Test-That 'UBUNTU is passed to docker' (Get-BuildArg 'UBUNTU') '20.04'
Test-That 'REVISION still is too' (Get-BuildArg 'REVISION') '1683'
Test-That 'and the build ran' ($script:built.Count -gt 0) $true

Write-Host ''
Write-Host 'a revision with no Linux build never reaches docker'
$script:published = @()
Invoke-BuildFor '1668'
Test-That 'nothing was built' $script:built.Count 0
Test-That 'and it said which revision' ($script:died -like '*r1668*') $true
Test-That 'and what it tried' ($script:died -like '*ubuntu-22.04*') $true

Write-Host ''
Write-Host 'resolving the base is not on the path of every command'
# Get-WebKitUbuntu costs three requests. Resolve-DockerOther runs on `stop` and
# `status` as well, so the base is appended here instead - a stop that waits on
# a CDN is a stop that hangs when the CDN is down.
$resolve = $LiftedFunctions['Get-WebKitUbuntu']
$other = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path './engineshelf-docker.ps1').Path, [ref]$null, [ref]$null)
$resolveOther = @($other.FindAll({
    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $args[0].Name -eq 'Resolve-DockerOther'
}, $true))[0]
Test-That 'Resolve-DockerOther does not call it' `
    ($resolveOther.Extent.Text -like '*Get-WebKitUbuntu*') $false
Test-That 'Invoke-Build does' `
    ($LiftedFunctions['Invoke-Build'].Extent.Text -like '*Get-WebKitUbuntu*') $true
Test-That 'and the lifted resolver is the real one' ($null -ne $resolve) $true

Exit-WithTally
