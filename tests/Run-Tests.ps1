#Requires -Version 5.1
<#
.SYNOPSIS
    Dependency-free test runner (Windows PowerShell 5.1 and PowerShell 7, no Pester needed).
.DESCRIPTION
    Loads the source files, replaces every system command they use with the fakes in
    WindowsMock.ps1, then dot-sources each tests\*.Tests.ps1 in this scope so that they share the
    helpers below. Nothing on the machine running the tests is read or changed by the code under
    test. Exit code = number of failed tests.
.EXAMPLE
    .\tests\Run-Tests.ps1
.EXAMPLE
    .\tests\Run-Tests.ps1 -Filter Hardening
#>
param([string]$Filter = '*')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
foreach ($file in 'Common', 'Profile', 'Drivers', 'Winget', 'Printers', 'Hardening', 'Device', 'Handover', 'ProfileBuilder', 'Provision') {
    . (Join-Path -Path $root -ChildPath ('src\{0}.ps1' -f $file))
}
. (Join-Path -Path $root -ChildPath 'tools\SampleRun.ps1')
# Loaded last: its functions replace the system cmdlets and the source's system probes.
. (Join-Path -Path $PSScriptRoot -ChildPath 'WindowsMock.ps1')
$script:ZTQuiet = $true

# ------------------------------------------------------------------ harness
$script:passed = 0
$script:failed = 0
$script:failures = New-Object -TypeName System.Collections.Generic.List[string]

function Test-Case {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    Reset-FakeWindows
    $script:ZTLogFile = $null
    try {
        & $Body
        $script:passed++
        Write-Host ('  [PASS] {0}' -f $Name) -ForegroundColor Green
    }
    catch {
        $script:failed++
        $script:failures.Add(('{0} :: {1}' -f $script:currentFile, $Name))
        Write-Host ('  [FAIL] {0}' -f $Name) -ForegroundColor Red
        Write-Host ('         {0}' -f $_.Exception.Message) -ForegroundColor Red
        foreach ($frame in @(([string]$_.ScriptStackTrace) -split "`n" | Select-Object -First 4)) {
            Write-Host ('         {0}' -f $frame.Trim()) -ForegroundColor DarkRed
        }
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$What = 'value')
    if ([string]$Expected -cne [string]$Actual) { throw ("{0}: expected '{1}', got '{2}'" -f $What, $Expected, $Actual) }
}

function Assert-True {
    param([bool]$Condition, [string]$Message = 'condition is false')
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Like = '*', [string]$What = 'call')
    try {
        & $Body
    }
    catch {
        if ($_.Exception.Message -notlike $Like) { throw ("{0} threw '{1}', expected like '{2}'" -f $What, $_.Exception.Message, $Like) }
        return
    }
    throw ('{0} did not throw' -f $What)
}

function Assert-Contains {
    param([AllowNull()][object[]]$Collection, $Item, [string]$What = 'collection')
    if (@($Collection) -notcontains $Item) { throw ("{0} does not contain '{1}' (has: {2})" -f $What, $Item, (@($Collection) -join ', ')) }
}

function Assert-NotContains {
    param([AllowNull()][object[]]$Collection, $Item, [string]$What = 'collection')
    if (@($Collection) -contains $Item) { throw ("{0} should not contain '{1}'" -f $What, $Item) }
}

function Assert-Like {
    param([AllowNull()][string]$Text, [string]$Pattern, [string]$What = 'text')
    if ($Text -notlike $Pattern) { throw ("{0}: '{1}' is not like '{2}'" -f $What, $Text, $Pattern) }
}

# ------------------------------------------------------------------ fixtures
$TempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('zt-tests-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($TempRoot)
$RepoProfiles = Join-Path -Path $root -ChildPath 'profiles'

function New-TestFolder {
    $path = Join-Path -Path $TempRoot -ChildPath ([guid]::NewGuid().ToString('N').Substring(0, 12))
    [void][System.IO.Directory]::CreateDirectory($path)
    $path
}

function Write-TestJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    Write-ZTTextFile -Path $Path -Content (ConvertTo-Json -InputObject $Object -Depth 10)
}

# A folder with the given profiles: @{ base = @{...}; taller = @{...} }
function New-ProfileFolder {
    param([Parameter(Mandatory)][hashtable]$Profiles)
    $folder = New-TestFolder
    foreach ($name in $Profiles.Keys) { Write-TestJson -Path (Join-Path -Path $folder -ChildPath ($name + '.json')) -Object $Profiles[$name] }
    $folder
}

# A copy of the repository's profiles, so that tests can write next to them.
function Copy-RepoProfiles {
    $folder = New-TestFolder
    foreach ($file in Get-ChildItem -LiteralPath $RepoProfiles -Filter '*.json' -File) {
        Copy-Item -LiteralPath $file.FullName -Destination $folder
    }
    $folder
}

function Get-Result {
    param([AllowNull()][object[]]$Results, [Parameter(Mandatory)][string]$Control)
    @($Results | Where-Object { $_.Control -eq $Control }) | Select-Object -First 1
}

# ------------------------------------------------------------------ run
$testFiles = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.Tests.ps1' | Where-Object { $_.BaseName -like "$Filter*" } | Sort-Object -Property Name)
try {
    foreach ($testFile in $testFiles) {
        $script:currentFile = $testFile.BaseName
        Write-Host ''
        Write-Host $testFile.BaseName -ForegroundColor Cyan
        . $testFile.FullName
    }
}
finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failed -gt 0) {
    Write-Host 'Failed:' -ForegroundColor Red
    foreach ($failure in $script:failures) { Write-Host ('  {0}' -f $failure) -ForegroundColor Red }
}
$color = 'Green'
if ($script:failed -gt 0) { $color = 'Red' }
Write-Host ('{0} passed, {1} failed' -f $script:passed, $script:failed) -ForegroundColor $color
exit $script:failed
