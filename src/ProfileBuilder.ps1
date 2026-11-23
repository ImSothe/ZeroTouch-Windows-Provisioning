#Requires -Version 5.1
# Building department profiles: from a reference PC ('winget export'), from an export file,
# from a CSV/Excel list of departments, or from a list of package ids.

# Left out of captured profiles by default: runtimes and frameworks (dependencies, installed
# automatically), apps that ship with Windows, and hardware vendor tools/drivers, which belong to
# the reference PC's hardware rather than to the department.
$script:ZTDefaultCaptureExclusions = @(
    'Microsoft.VCRedist.*', 'Microsoft.VCLibs.*', 'Microsoft.UI.Xaml.*', 'Microsoft.DotNet.*',
    'Microsoft.WindowsAppRuntime.*', 'Microsoft.AppInstaller', 'Microsoft.DesktopAppInstaller',
    'Microsoft.Edge', 'Microsoft.EdgeWebView2Runtime', 'Microsoft.OneDrive', 'Microsoft.Teams.Free',
    'Intel.*', 'Realtek.*', 'Nvidia.*', 'AMD.*', 'Dell.*', 'Lenovo.*', 'HP.*'
)

$script:ZTCsvColumns = @{
    Department = @('departamento', 'department', 'dept', 'dpto')
    Id         = @('id', 'app-id', 'appid', 'package-id', 'packageid', 'packageidentifier', 'winget-id', 'wingetid')
    Name       = @('nombre', 'name', 'aplicacion', 'application', 'app')
    Version    = @('version')
    Required   = @('obligatoria', 'obligatorio', 'required', 'mandatory')
}

# Reads a text file exported by Excel: UTF-8 (with or without BOM) or, failing that, Windows-1252,
# which is what "CSV (delimited)" produces on Spanish/Western European Windows.
function Read-ZTTextFile {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-ZTPath -Path $Path))
    $strict = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false, $true
    try {
        $text = $strict.GetString($bytes)
    }
    catch {
        try { $ansi = [System.Text.Encoding]::GetEncoding(1252) } catch { $ansi = [System.Text.Encoding]::Default }
        $text = $ansi.GetString($bytes)
    }
    $text.TrimStart([char]0xFEFF)
}

function Find-ZTColumn {
    param([string[]]$Headers, [Parameter(Mandatory)][string[]]$Candidates)
    foreach ($header in $Headers) {
        if ($Candidates -contains (ConvertTo-ZTSlug -Text $header)) { return $header }
    }
    return $null
}

function ConvertTo-ZTRequired {
    param([AllowNull()]$Value)
    $slug = ConvertTo-ZTSlug -Text ([string]$Value)
    if (-not $slug) { return $true }
    return (@('no', 'n', 'false', '0', 'opcional', 'optional') -notcontains $slug)
}

# Package entries from a 'winget export' file. Microsoft Store apps are skipped unless asked for,
# because they cannot be installed as SYSTEM (Intune).
function Read-ZTWingetExport {
    param([Parameter(Mandatory)][string]$Path, [switch]$IncludeMsStore, [switch]$PinVersions)
    $data = Read-ZTJsonFile -Path $Path
    if ($data -isnot [System.Collections.IDictionary] -or -not $data.Contains('Sources')) {
        throw ("'{0}' is not a winget export file (no 'Sources')." -f $Path)
    }
    foreach ($source in @($data['Sources'])) {
        $sourceName = [string]$source['SourceDetails']['Name']
        if ($sourceName -eq 'msstore' -and -not $IncludeMsStore) {
            Write-ZTLog ('Skipping {0} Microsoft Store package(s); use -IncludeMsStore to keep them.' -f @($source['Packages']).Count) -Level Warning
            continue
        }
        if (@('winget', 'msstore') -notcontains $sourceName) {
            Write-ZTLog ("Skipping packages from source '{0}' (only winget and msstore are supported)." -f $sourceName) -Level Warning
            continue
        }
        foreach ($package in @($source['Packages'])) {
            if ($null -eq $package) { continue }
            $entry = [ordered]@{ id = [string]$package['PackageIdentifier'] }
            if ($sourceName -ne 'winget') { $entry['source'] = $sourceName }
            if ($PinVersions -and $package['Version']) { $entry['version'] = [string]$package['Version'] }
            $entry
        }
    }
}

# Rows of a departments CSV, grouped: one entry per department with its applications.
function Read-ZTDepartmentCsv {
    param([Parameter(Mandatory)][string]$Path)
    $lines = @((Read-ZTTextFile -Path $Path) -split "\r?\n" | Where-Object { $_.Trim() })
    if ($lines.Count -lt 2) { throw ("'{0}' has no data rows." -f $Path) }
    $header = $lines[0]
    $delimiter = ','
    if ($header.Split(';').Count -gt $header.Split(',').Count) { $delimiter = ';' }
    $rows = @($lines | ConvertFrom-Csv -Delimiter $delimiter)
    $headers = @($rows[0].PSObject.Properties.Name)

    $columns = @{}
    foreach ($key in $script:ZTCsvColumns.Keys) { $columns[$key] = Find-ZTColumn -Headers $headers -Candidates $script:ZTCsvColumns[$key] }
    if (-not $columns['Department'] -or -not $columns['Id']) {
        throw ("'{0}' needs a department column (Departamento/Department) and a package id column (Id/PackageId). Found: {1}" -f $Path, ($headers -join ', '))
    }

    $order = New-Object -TypeName System.Collections.Generic.List[string]
    $names = @{}
    $apps = @{}
    $line = 1
    foreach ($row in $rows) {
        $line++
        $department = ([string]$row.($columns['Department'])).Trim()
        $id = ([string]$row.($columns['Id'])).Trim()
        if (-not $department -or -not $id) {
            Write-ZTLog ('CSV line {0}: department or id is empty; skipped.' -f $line) -Level Warning
            continue
        }
        if ($id -notmatch $script:ZTPackageIdPattern) {
            Write-ZTLog ("CSV line {0}: '{1}' is not a valid winget id; skipped." -f $line, $id) -Level Warning
            continue
        }
        $slug = ConvertTo-ZTSlug -Text $department
        if (-not $apps.ContainsKey($slug)) {
            $order.Add($slug)
            $names[$slug] = $department
            $apps[$slug] = New-Object -TypeName System.Collections.Generic.List[object]
        }
        $entry = [ordered]@{ id = $id }
        if ($columns['Name'] -and ([string]$row.($columns['Name'])).Trim()) { $entry['name'] = ([string]$row.($columns['Name'])).Trim() }
        if ($columns['Version'] -and ([string]$row.($columns['Version'])).Trim()) { $entry['version'] = ([string]$row.($columns['Version'])).Trim() }
        if ($columns['Required'] -and -not (ConvertTo-ZTRequired -Value $row.($columns['Required']))) { $entry['required'] = $false }
        $apps[$slug].Add($entry)
    }
    foreach ($slug in $order) {
        [pscustomobject]@{ Name = $slug; DisplayName = $names[$slug]; Applications = $apps[$slug].ToArray(); Printers = @() }
    }
}

# Drops excluded packages, packages the parent profile already installs, and duplicates.
function Select-ZTProfileApplication {
    param([object[]]$Applications, [string[]]$ExcludePattern, [hashtable]$InheritedIds)
    $kept = New-Object -TypeName System.Collections.Generic.List[object]
    $excluded = New-Object -TypeName System.Collections.Generic.List[string]
    $inherited = New-Object -TypeName System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($app in @($Applications | Where-Object { $null -ne $_ })) {
        $id = [string]$app['id']
        if ($id -notmatch $script:ZTPackageIdPattern) { throw ("'{0}' is not a valid winget package id." -f $id) }
        $key = $id.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $isExcluded = $false
        foreach ($pattern in @($ExcludePattern)) {
            if ($pattern -and $id -like $pattern) { $isExcluded = $true }
        }
        if ($isExcluded) { $excluded.Add($id); continue }
        if ($InheritedIds.ContainsKey($key)) { $inherited.Add($id); continue }
        $kept.Add($app)
    }
    [pscustomobject]@{ Applications = $kept.ToArray(); Excluded = $excluded.ToArray(); Inherited = $inherited.ToArray() }
}

function Write-ZTProfileFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$DisplayName,
        [string]$Description,
        [string]$Extends,
        [object[]]$Applications = @(),
        [object[]]$Printers = @(),
        [AllowNull()]$Drivers,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [switch]$Force
    )
    $path = Join-Path -Path (Resolve-ZTPath -Path $OutputDirectory) -ChildPath ($Name + '.json')
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        Write-ZTLog ("'{0}' already exists; use -Force to overwrite it." -f $path) -Level Warning
        return [pscustomobject]@{ Path = $path; Written = $false }
    }
    $document = [ordered]@{ '$schema' = './schema/profile.schema.json'; name = $Name }
    if ($DisplayName -and $DisplayName -ne $Name) { $document['displayName'] = $DisplayName }
    $document['description'] = [string]$Description
    if ($Extends) { $document['extends'] = $Extends }
    $document['applications'] = @($Applications)
    if (@($Printers).Count -gt 0) { $document['printers'] = @($Printers) }
    if ($null -ne $Drivers) { $document['drivers'] = $Drivers }
    if (-not $PSCmdlet.ShouldProcess($path, 'Write department profile')) {
        return [pscustomobject]@{ Path = $path; Written = $false }
    }
    Write-ZTTextFile -Path $path -Content ((ConvertTo-ZTJson -InputObject $document) + "`n")
    [pscustomobject]@{ Path = $path; Written = $true }
}

<#
.SYNOPSIS
    Creates department profiles (profiles\<name>.json) without writing JSON by hand.
.DESCRIPTION
    FromThisComputer  runs 'winget export' on a reference PC that is already set up the way the department works,
                      and also takes its network (TCP/IP) printers. With -ExportDrivers it also exports
                      the PC's driver pack (by make and model) and its printers' driver packages.
    ExportFile        converts an export taken earlier on the reference PC ('winget export -o file.json').
    Csv               builds one profile per department from a list (Departamento;Id;Nombre;Obligatoria).
    PackageId         builds a profile from a list of winget ids.
    Packages the parent profile (-Extends, default 'base') already installs are left out, so the new
    file only holds what is specific to the department.
#>
function New-ZTDepartmentProfile {
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
        [Parameter(ParameterSetName = 'FromThisComputer')][string]$ExportDrivers,
        [string]$DisplayName,
        [string]$Description,
        [AllowEmptyString()][string]$Extends = 'base',
        [string]$OutputDirectory = $script:ZTProfilesPath,
        [string[]]$ExcludePattern = $script:ZTDefaultCaptureExclusions,
        [switch]$IncludeMsStore,
        [switch]$PinVersions,
        [switch]$Force
    )
    $Extends = ([string]$Extends) -replace '\.json$', ''
    $inheritedIds = @{}
    $inheritedPrinters = @{}
    if ($Extends) {
        $parentPath = Join-Path -Path (Resolve-ZTPath -Path $OutputDirectory) -ChildPath ($Extends + '.json')
        if (Test-Path -LiteralPath $parentPath) {
            $parent = Get-ZTProfile -Path $parentPath -SkipValidation
            foreach ($app in @($parent['applications'])) { $inheritedIds[([string]$app['id']).ToLowerInvariant()] = $true }
            foreach ($printer in @($parent['printers'] | Where-Object { $_ })) { $inheritedPrinters[([string]$printer['name']).ToLowerInvariant()] = $true }
        }
        else {
            Write-ZTLog ("Parent profile '{0}' not found in {1}; nothing is left out as inherited." -f $Extends, $OutputDirectory) -Level Warning
        }
    }
    if (-not $Description) {
        $Description = 'Generated by New-DepartmentProfile.ps1 on {0} ({1}). Review before use.' -f (Get-Date -Format 'yyyy-MM-dd'), $PSCmdlet.ParameterSetName
    }

    $sets = New-Object -TypeName System.Collections.Generic.List[object]
    $driverPack = $null
    switch ($PSCmdlet.ParameterSetName) {
        'Csv' {
            foreach ($department in @(Read-ZTDepartmentCsv -Path $CsvPath)) { $sets.Add($department) }
        }
        'PackageId' {
            $apps = @($PackageId | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ } | ForEach-Object { [ordered]@{ id = $_ } })
            $sets.Add([pscustomobject]@{ Name = $Name; DisplayName = $DisplayName; Applications = $apps; Printers = @() })
        }
        'ExportFile' {
            $apps = @(Read-ZTWingetExport -Path $ExportFile -IncludeMsStore:$IncludeMsStore -PinVersions:$PinVersions)
            $sets.Add([pscustomobject]@{ Name = $Name; DisplayName = $DisplayName; Applications = $apps; Printers = @() })
        }
        'FromThisComputer' {
            $exportPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('zt-export-{0}.json' -f [guid]::NewGuid().ToString('N'))
            $arguments = @('export', '-o', $exportPath, '--accept-source-agreements', '--disable-interactivity')
            if ($PinVersions) { $arguments += '--include-versions' }
            try {
                $result = Invoke-ZTWinget -ArgumentList $arguments
                if (-not (Test-Path -LiteralPath $exportPath)) { throw ('winget export failed (exit code 0x{0:X8}).' -f $result.ExitCode) }
                $apps = @(Read-ZTWingetExport -Path $exportPath -IncludeMsStore:$IncludeMsStore -PinVersions:$PinVersions)
            }
            finally {
                if (Test-Path -LiteralPath $exportPath) { [System.IO.File]::Delete($exportPath) }
            }
            $printers = @(Get-ZTNetworkPrinter)
            $driverSettings = $null
            if ($ExportDrivers) {
                if ($ExportDrivers -notmatch $script:ZTDriverPathPattern) { throw ("-ExportDrivers must be a full path (C:\... or \\server\share\...): '{0}'." -f $ExportDrivers) }
                $packRoot = Join-Path -Path $ExportDrivers -ChildPath 'Models'
                $driverPack = Export-ZTDriverPack -Root $packRoot
                Write-ZTLog ('Driver pack for {0} {1}: {2} driver(s) in {3}' -f $driverPack.Manufacturer, $driverPack.Model, $driverPack.Count, $driverPack.Path)
                $withDrivers = New-Object -TypeName System.Collections.Generic.List[object]
                foreach ($printer in $printers) {
                    $copy = [ordered]@{}
                    foreach ($key in @($printer.Keys)) { $copy[$key] = $printer[$key] }
                    $inf = Export-ZTPrinterDriver -DriverName ([string]$copy['driver']) -Root $ExportDrivers
                    if ($inf) { $copy['driverInf'] = $inf }
                    $withDrivers.Add($copy)
                }
                $printers = $withDrivers.ToArray()
                $driverSettings = [ordered]@{ packs = $packRoot }
            }
            $sets.Add([pscustomobject]@{ Name = $Name; DisplayName = $DisplayName; Applications = $apps; Printers = $printers; Drivers = $driverSettings })
        }
    }

    foreach ($set in $sets) {
        $profileName = ConvertTo-ZTSlug -Text ([string]$set.Name)
        if ($profileName -notmatch $script:ZTProfileNamePattern) { throw ("'{0}' cannot be used as a profile name." -f $set.Name) }
        if ($Extends -and $profileName -eq $Extends) { throw ("A department cannot be called like its parent profile ('{0}')." -f $Extends) }
        $selection = Select-ZTProfileApplication -Applications @($set.Applications) -ExcludePattern $ExcludePattern -InheritedIds $inheritedIds
        $printers = @(@($set.Printers) | Where-Object { $_ -and -not $inheritedPrinters.ContainsKey(([string]$_['name']).ToLowerInvariant()) })
        $display = [string]$set.DisplayName
        if (-not $display) { $display = [string]$set.Name }
        $driverSettings = $null
        if ($set.PSObject.Properties.Name -contains 'Drivers') { $driverSettings = $set.Drivers }
        $written = Write-ZTProfileFile -Name $profileName -DisplayName $display -Description $Description -Extends $Extends `
            -Applications $selection.Applications -Printers $printers -Drivers $driverSettings -OutputDirectory $OutputDirectory -Force:$Force
        [pscustomobject]@{
            Name         = $profileName
            Path         = $written.Path
            Written      = $written.Written
            Applications = @($selection.Applications | ForEach-Object { [string]$_['id'] })
            Printers     = @($printers | ForEach-Object { [string]$_['name'] })
            DriverPack   = $driverPack
            Inherited    = $selection.Inherited
            Excluded     = $selection.Excluded
        }
    }
}
