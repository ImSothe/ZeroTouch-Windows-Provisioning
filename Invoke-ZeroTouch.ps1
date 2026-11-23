<#
.SYNOPSIS
    Provisions a new Windows PC for a department: silent apps with winget, a security baseline and a handover form.

.DESCRIPTION
    1. Loads the department profile (profiles\<department>.json), including what it inherits from base.json.
    2. Installs the profile's applications silently with winget. Already installed apps are left alone.
       Adds the department's network printers (driver, TCP/IP port and queue, for the whole machine).
    3. Applies the security baseline: BitLocker check (or enablement with the recovery key escrowed first),
       SMBv1 off, Windows Firewall defaults and rules, and removal of preinstalled consumer apps.
    4. Writes the handover form (HTML to print and sign, JSON for inventory tools, optional PDF) and a
       registry marker under HKLM:\SOFTWARE\ZeroTouch that Intune can use as a detection rule.

    Without -Department, and when someone is at the keyboard, it shows a menu of departments.
    Exit codes: 0 = success, 3010 = success but a restart is needed, 1 = failure.

.PARAMETER Department
    Department profile to apply: a name from the profiles folder (oficina, taller...) or the path to a profile file.

.PARAMETER AssignedUser
    Person who receives the computer. Leave empty to write the name by hand on the printed form.

.PARAMETER Technician
    Person who prepares the computer. Defaults to the current user name.

.PARAMETER OutputPath
    Folder for logs and handover forms. Default: C:\ProgramData\ZeroTouch.

.PARAMETER ProfilesPath
    Folder with the department profiles. Default: the profiles folder next to this script.

.PARAMETER Language
    Language of the handover form: en or es. Default: the profile's organization.language, else English.

.PARAMETER Notes
    Free text added to the "Notes" section of the handover form (accessories delivered, damage...).

.PARAMETER SkipApplications
    Do not install applications (security baseline and handover form only).

.PARAMETER SkipPrinters
    Do not add the profile's network printers.

.PARAMETER SkipSecurity
    Do not apply the security baseline (applications and handover form only).

.PARAMETER Pdf
    Also print the handover form to PDF with Microsoft Edge.

.PARAMETER ListDepartments
    List the departments that can be applied and exit.

.EXAMPLE
    .\Invoke-ZeroTouch.ps1
    Shows the department menu, asks who receives the computer, provisions it and offers to open the form.

.EXAMPLE
    .\Invoke-ZeroTouch.ps1 -Department taller -WhatIf
    Simulation: checks everything and writes a handover form marked SIMULATION without changing the computer.

.EXAMPLE
    .\Invoke-ZeroTouch.ps1 -Department oficina -AssignedUser 'Ana Lopez' -Pdf
    Provisions an office PC for Ana and saves the handover form as HTML, JSON and PDF.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Invoke-ZeroTouch.ps1 -Department comercial
    Install command for an Intune Win32 app (runs as SYSTEM; see docs\intune.md).

.EXAMPLE
    .\Invoke-ZeroTouch.ps1 -ListDepartments
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run', Position = 0)][string]$Department,
    [Parameter(ParameterSetName = 'Run')][string]$AssignedUser,
    [Parameter(ParameterSetName = 'Run')][string]$Technician,
    [Parameter(ParameterSetName = 'Run')][string]$OutputPath,
    [string]$ProfilesPath,
    [Parameter(ParameterSetName = 'Run')][ValidateSet('en', 'es')][string]$Language,
    [Parameter(ParameterSetName = 'Run')][string]$Notes,
    [Parameter(ParameterSetName = 'Run')][switch]$SkipApplications,
    [Parameter(ParameterSetName = 'Run')][switch]$SkipPrinters,
    [Parameter(ParameterSetName = 'Run')][switch]$SkipSecurity,
    [Parameter(ParameterSetName = 'Run')][switch]$Pdf,
    [Parameter(Mandatory, ParameterSetName = 'List')][switch]$ListDepartments
)

$ErrorActionPreference = 'Stop'

# The Intune Management Extension can start installs in a 32-bit process. There, BitLocker, DISM and
# Appx cmdlets are missing and HKLM writes go to WOW6432Node, so restart in 64-bit PowerShell.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $native = Join-Path -Path $env:SystemRoot -ChildPath 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $native) {
        $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        foreach ($name in $PSBoundParameters.Keys) {
            $value = $PSBoundParameters[$name]
            if ($value -is [System.Management.Automation.SwitchParameter]) {
                if ($value.IsPresent) { $relaunch += '-' + $name }
            }
            else {
                $relaunch += @('-' + $name, [string]$value)
            }
        }
        if ($WhatIfPreference -and -not $PSBoundParameters.ContainsKey('WhatIf')) { $relaunch += '-WhatIf' }
        & $native @relaunch
        exit $LASTEXITCODE
    }
}

foreach ($file in 'Common', 'Profile', 'Winget', 'Printers', 'Hardening', 'Device', 'Handover', 'ProfileBuilder', 'Provision') {
    . (Join-Path -Path $PSScriptRoot -ChildPath ('src\{0}.ps1' -f $file))
}

$listArguments = @{}
if ($ProfilesPath) { $listArguments['ProfilesPath'] = $ProfilesPath }

if ($ListDepartments) {
    Get-ZTDepartmentList @listArguments | Format-Table -AutoSize -Property Name, DisplayName, Extends, Description | Out-String -Width 200 | Write-Host
    exit 0
}

# The menu and the prompts only appear when nobody passed -Department and someone is at the keyboard:
# scripted runs (Intune, CI, a technician's own script) never wait for input.
$menuMode = -not $Department
if ($menuMode) {
    $interactive = [Environment]::UserInteractive -and -not (Test-ZTIsSystem)
    if (-not $interactive) {
        Write-Error 'Specify -Department (no one is at the keyboard to choose it).' -ErrorAction Continue
        exit 1
    }
    $departments = @(Get-ZTDepartmentList @listArguments)
    if ($departments.Count -eq 0) {
        Write-Error 'There are no department profiles to apply.' -ErrorAction Continue
        exit 1
    }
    Write-Host ''
    Write-Host '  ZeroTouch - Windows PC provisioning' -ForegroundColor Cyan
    Write-Host '  -----------------------------------' -ForegroundColor Cyan
    for ($i = 0; $i -lt $departments.Count; $i++) {
        Write-Host ('  [{0}] {1,-24} {2}' -f ($i + 1), $departments[$i].DisplayName, $departments[$i].Description)
    }
    Write-Host ''
    $choice = 0
    do {
        $answer = Read-Host ('  Department (1-{0})' -f $departments.Count)
        $valid = [int]::TryParse($answer, [ref]$choice) -and $choice -ge 1 -and $choice -le $departments.Count
    } until ($valid)
    $Department = $departments[$choice - 1].Path
    if (-not $PSBoundParameters.ContainsKey('AssignedUser')) {
        $AssignedUser = Read-Host '  Who receives the computer? (Enter = leave blank and write it by hand)'
    }
}

$parameters = @{ Department = $Department }
foreach ($name in 'AssignedUser', 'Technician', 'OutputPath', 'ProfilesPath', 'Language', 'Notes') {
    $value = Get-Variable -Name $name -ValueOnly
    if ($value) { $parameters[$name] = $value }
}
foreach ($name in 'SkipApplications', 'SkipPrinters', 'SkipSecurity', 'Pdf') {
    if ((Get-Variable -Name $name -ValueOnly).IsPresent) { $parameters[$name] = $true }
}

try {
    $run = Invoke-ZTProvisioning @parameters -WhatIf:$WhatIfPreference
}
catch {
    Write-ZTLog $_.Exception.Message -Level Error
    exit 1
}

if ($menuMode -and $run.ReportPaths.HtmlPath -and (Test-Path -LiteralPath $run.ReportPaths.HtmlPath)) {
    $open = Read-Host '  Open the handover form now? (Y/n)'
    if ($open -notmatch '^[nN]') { Invoke-Item -LiteralPath $run.ReportPaths.HtmlPath -WhatIf:$false }
}
exit $run.ExitCode
