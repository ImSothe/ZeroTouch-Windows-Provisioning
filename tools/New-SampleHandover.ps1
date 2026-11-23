<#
.SYNOPSIS
    Rebuilds the sample handover forms in docs\ from the fixed run in tools\SampleRun.ps1.
.DESCRIPTION
    Writes docs\sample-handover.html (English) and docs\sample-handover.es.html (Spanish). Touches
    nothing else. A test fails if the committed samples no longer match what this script produces.
.EXAMPLE
    .\tools\New-SampleHandover.ps1
#>
#Requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
foreach ($file in 'Common', 'Profile', 'Winget', 'Printers', 'Hardening', 'Device', 'Handover', 'ProfileBuilder', 'Provision') {
    . (Join-Path -Path $root -ChildPath ('src\{0}.ps1' -f $file))
}
. (Join-Path -Path $PSScriptRoot -ChildPath 'SampleRun.ps1')

foreach ($language in 'en', 'es') {
    $name = 'sample-handover.html'
    if ($language -ne 'en') { $name = 'sample-handover.{0}.html' -f $language }
    $path = Join-Path -Path $root -ChildPath ('docs\' + $name)
    $html = (ConvertTo-ZTHandoverHtml -Run (New-ZTSampleRun -Language $language)) -replace "`r`n", "`n"
    Write-ZTTextFile -Path $path -Content $html
    Write-Host ('Wrote {0}' -f $path)
}
