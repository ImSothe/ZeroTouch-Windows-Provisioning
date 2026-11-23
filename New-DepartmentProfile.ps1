<#
.SYNOPSIS
    Creates department profiles (profiles\<department>.json) from a reference PC, a winget export, a CSV or a list of ids.

.DESCRIPTION
    Writing a profile by hand means looking up every winget id. This script builds it for you:

    -FromThisComputer  Run it on a reference PC that is already set up the way the department works.
                       It runs 'winget export' and turns the result into a profile, together with the
                       PC's network (TCP/IP) printers. Print server connections and USB printers are
                       per user or per desk, so they are not taken.
    -ExportFile        Convert an export taken earlier on the reference PC with: winget export -o taller.json
    -CsvPath           Build one profile per department from a list kept in Excel
                       (columns Departamento;Id;Nombre;Obligatoria - English headers work too).
    -PackageId         Build a profile from winget ids you already know.

    Runtimes, frameworks, apps that ship with Windows and hardware vendor tools are left out
    (see -ExcludePattern), and so is everything the parent profile (-Extends, default base) already
    installs, so the new file only holds what is specific to the department. Existing files are
    never overwritten without -Force. Review the result and test it with Invoke-ZeroTouch.ps1 -WhatIf.

.PARAMETER FromThisComputer
    Capture the applications installed on this computer with 'winget export', and its network printers.

.PARAMETER ExportFile
    Path to a file created with 'winget export -o <file>' on the reference PC.

.PARAMETER CsvPath
    Path to a CSV with one row per department and application. Separator ; or , (detected). UTF-8 or ANSI.

.PARAMETER PackageId
    One or more winget package ids (comma or space separated also works).

.PARAMETER Name
    Department name, used as the file name (lower case letters, digits and dashes). Not used with -CsvPath.

.PARAMETER DisplayName
    Name shown in the menu and on the handover form. Default: the department name.

.PARAMETER Description
    Short description of the department's computers.

.PARAMETER Extends
    Parent profile whose applications and security settings are inherited. Default: base. Use '' for none.

.PARAMETER OutputDirectory
    Where profiles are written. Default: the profiles folder next to this script.

.PARAMETER ExcludePattern
    Wildcard patterns of package ids to leave out. Default: runtimes, built-in apps and hardware vendor tools.

.PARAMETER IncludeMsStore
    Keep Microsoft Store apps from the export (they cannot be installed as SYSTEM through Intune).

.PARAMETER PinVersions
    Record the exact versions found, so that every computer gets the same version.

.PARAMETER Force
    Overwrite existing profile files.

.EXAMPLE
    .\New-DepartmentProfile.ps1 -FromThisComputer -Name taller -DisplayName 'Taller'
    On the reference workshop PC: captures its applications into profiles\taller.json.

.EXAMPLE
    winget export -o D:\taller-export.json
    .\New-DepartmentProfile.ps1 -ExportFile D:\taller-export.json -Name taller
    Export on the reference PC (from a USB stick, say), convert on the technician's PC.

.EXAMPLE
    .\New-DepartmentProfile.ps1 -CsvPath .\examples\departments.csv
    One profile per department listed in the CSV.

.EXAMPLE
    .\New-DepartmentProfile.ps1 -PackageId Zoom.Zoom, SumatraPDF.SumatraPDF -Name formacion -WhatIf
    Shows what would be written without creating the file.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ExportFile')]
param(
    [Parameter(Mandatory, ParameterSetName = 'FromThisComputer')][switch]$FromThisComputer,
    [Parameter(Mandatory, ParameterSetName = 'ExportFile')][string]$ExportFile,
    [Parameter(Mandatory, ParameterSetName = 'Csv')][string]$CsvPath,
    [Parameter(Mandatory, ParameterSetName = 'PackageId')][string[]]$PackageId,
    [Parameter(Mandatory, ParameterSetName = 'FromThisComputer')]
    [Parameter(Mandatory, ParameterSetName = 'ExportFile')]
    [Parameter(Mandatory, ParameterSetName = 'PackageId')]
    [string]$Name,
    [string]$DisplayName,
    [string]$Description,
    [AllowEmptyString()][string]$Extends = 'base',
    [string]$OutputDirectory,
    [string[]]$ExcludePattern,
    [switch]$IncludeMsStore,
    [switch]$PinVersions,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
foreach ($file in 'Common', 'Profile', 'Winget', 'Printers', 'Hardening', 'Device', 'Handover', 'ProfileBuilder', 'Provision') {
    . (Join-Path -Path $PSScriptRoot -ChildPath ('src\{0}.ps1' -f $file))
}

$parameters = @{}
foreach ($key in $PSBoundParameters.Keys) {
    if (@('WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction') -notcontains $key) {
        $parameters[$key] = $PSBoundParameters[$key]
    }
}

try {
    $results = @(New-ZTDepartmentProfile @parameters -WhatIf:$WhatIfPreference)
}
catch {
    Write-ZTLog $_.Exception.Message -Level Error
    exit 1
}

foreach ($result in $results) {
    $state = 'written'
    if (-not $result.Written) { $state = 'NOT written' }
    Write-ZTLog ('{0}: {1} ({2})' -f $result.Name, $result.Path, $state) -Level Step
    Write-ZTLog ('  {0} application(s): {1}' -f $result.Applications.Count, ($result.Applications -join ', '))
    if ($result.Printers.Count -gt 0) { Write-ZTLog ('  {0} network printer(s): {1}' -f $result.Printers.Count, ($result.Printers -join ', ')) }
    if ($result.Inherited.Count -gt 0) { Write-ZTLog ('  already in {0}: {1}' -f $Extends, ($result.Inherited -join ', ')) }
    if ($result.Excluded.Count -gt 0) { Write-ZTLog ('  left out by -ExcludePattern: {0}' -f ($result.Excluded -join ', ')) }
}
Write-ZTLog 'Next: review the file, then test it with .\Invoke-ZeroTouch.ps1 -Department <name> -WhatIf' -Level Step
exit 0
