# Building department profiles from a reference PC, an export file, a CSV or a list of ids.

$exportExample = Join-Path $root 'examples\winget-export-taller.json'
$csvExample = Join-Path $root 'examples\departments.csv'

function Read-ProfileFile {
    param([string]$Path)
    [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

Test-Case 'Export file: keeps the department apps, drops runtimes, vendor tools, Store apps and what base installs' {
    $folder = Copy-RepoProfiles
    $result = New-ZTDepartmentProfile -ExportFile $exportExample -Name 'taller2' -DisplayName 'Taller 2' -OutputDirectory $folder
    Assert-True $result.Written 'written'
    Assert-Equal 'Notepad++.Notepad++,WinSCP.WinSCP,SumatraPDF.SumatraPDF,TheDocumentFoundation.LibreOffice' ($result.Applications -join ',') 'applications'
    Assert-Equal '7zip.7zip,Google.Chrome' ($result.Inherited -join ',') 'left to base'
    foreach ($id in 'Microsoft.VCRedist.2015+.x64', 'Microsoft.Edge', 'Microsoft.EdgeWebView2Runtime', 'Lenovo.SystemUpdate', 'Intel.IntelDriverAndSupportAssistant') {
        Assert-Contains $result.Excluded $id 'excluded'
    }
    $saved = Read-ProfileFile $result.Path
    Assert-Equal 'taller2' $saved.name 'name'
    Assert-Equal 'Taller 2' $saved.displayName 'display name'
    Assert-Equal 'base' $saved.extends 'extends'
    Assert-Equal './schema/profile.schema.json' $saved.'$schema' 'schema reference for VS Code'
    Assert-True ($null -eq $saved.applications[0].version) 'no versions unless -PinVersions'
    $loaded = Get-ZTProfile -Path $result.Path
    Assert-Contains (@($loaded['applications']) | ForEach-Object { $_['id'] }) '7zip.7zip' 'the new profile inherits base'
}

Test-Case 'Export file: -PinVersions and -IncludeMsStore' {
    $folder = Copy-RepoProfiles
    $result = New-ZTDepartmentProfile -ExportFile $exportExample -Name 'pinned' -OutputDirectory $folder -PinVersions -IncludeMsStore
    $saved = Read-ProfileFile $result.Path
    $notepad = @($saved.applications) | Where-Object { $_.id -eq 'Notepad++.Notepad++' }
    Assert-Equal '8.7.1' $notepad.version 'pinned version'
    $store = @($saved.applications) | Where-Object { $_.id -eq '9WZDNCRFJ3PZ' }
    Assert-Equal 'msstore' $store.source 'Store app kept with its source'
}

Test-Case 'Export file: without a parent nothing is left out as inherited' {
    $result = New-ZTDepartmentProfile -ExportFile $exportExample -Name 'standalone' -Extends '' -OutputDirectory (New-TestFolder)
    Assert-Contains $result.Applications '7zip.7zip' 'standalone profile'
    Assert-True ($null -eq (Read-ProfileFile $result.Path).extends) 'no extends key'
}

Test-Case 'Existing profiles are not overwritten without -Force' {
    $folder = Copy-RepoProfiles
    $path = Join-Path $folder 'taller.json'
    $before = [System.IO.File]::ReadAllText($path)
    $result = New-ZTDepartmentProfile -ExportFile $exportExample -Name 'taller' -OutputDirectory $folder
    Assert-True (-not $result.Written) 'not written'
    Assert-Equal $before ([System.IO.File]::ReadAllText($path)) 'file unchanged'
    $result = New-ZTDepartmentProfile -ExportFile $exportExample -Name 'taller' -OutputDirectory $folder -Force
    Assert-True $result.Written 'written with -Force'
}

Test-Case '-WhatIf writes nothing' {
    $folder = Copy-RepoProfiles
    $result = New-ZTDepartmentProfile -PackageId 'Zoom.Zoom' -Name 'formacion' -OutputDirectory $folder -WhatIf
    Assert-True (-not $result.Written) 'not written'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $folder 'formacion.json'))) 'no file'
}

Test-Case 'From this computer: apps from winget export, network printers, temporary export deleted' {
    $script:Fake.Winget.Export = [System.IO.File]::ReadAllText($exportExample)
    Add-FakePrinter -Name 'Taller - Plotter' -Address '192.168.50.21' -Driver 'HP DesignJet Universal Print Driver PS3' -Location 'Nave 2'
    Add-FakePrinter -Name '\\srv-print\Taller' -Type 'Connection'
    $folder = Copy-RepoProfiles
    $result = New-ZTDepartmentProfile -FromThisComputer -Name 'captured' -OutputDirectory $folder
    Assert-Equal 4 $result.Applications.Count 'applications'
    $call = @(Get-FakeCall -Name 'winget' | Where-Object { $_.Parameters.ArgumentList[0] -eq 'export' })
    Assert-Equal 1 $call.Count 'winget export called'
    $exportPath = $call[0].Parameters.ArgumentList[2]
    Assert-True (-not (Test-Path -LiteralPath $exportPath)) 'temporary export deleted'
    Assert-Equal 'Taller - Plotter' ($result.Printers -join ',') 'network printer captured, server connection left out'
    $saved = Read-ProfileFile $result.Path
    Assert-Equal 'HP DesignJet Universal Print Driver PS3' $saved.printers[0].driver 'driver name saved'
    Assert-Equal '192.168.50.21' $saved.printers[0].address 'address saved'
}

Test-Case 'Package ids: commas and spaces are accepted, invalid ids are refused' {
    $result = New-ZTDepartmentProfile -PackageId 'Zoom.Zoom, SumatraPDF.SumatraPDF', 'WinSCP.WinSCP' -Name 'formacion' -OutputDirectory (Copy-RepoProfiles)
    Assert-Equal 'Zoom.Zoom,SumatraPDF.SumatraPDF,WinSCP.WinSCP' ($result.Applications -join ',') 'applications'
    Assert-Throws { New-ZTDepartmentProfile -PackageId 'Zoom.Zoom;calc&' -Name 'bad' -OutputDirectory (New-TestFolder) } -Like '*not a valid winget package id*'
    Assert-Throws { New-ZTDepartmentProfile -PackageId 'Zoom.Zoom' -Name 'base' -OutputDirectory (Copy-RepoProfiles) } -Like '*like its parent*'
}

Test-Case 'CSV from Excel (semicolons, UTF-8, Spanish headers): one profile per department' {
    $folder = Copy-RepoProfiles
    $results = @(New-ZTDepartmentProfile -CsvPath $csvExample -OutputDirectory $folder)
    Assert-Equal 'oficina,taller,direccion,recepcion' (($results | ForEach-Object { $_.Name }) -join ',') 'departments'
    Assert-True (-not ($results | Where-Object { $_.Name -eq 'oficina' }).Written) 'existing oficina.json kept'
    $direccion = Read-ProfileFile (Join-Path $folder 'direccion.json')
    Assert-Equal ('Direcci' + [char]0x00F3 + 'n') $direccion.displayName 'display name with accent'
    $zoom = @($direccion.applications) | Where-Object { $_.id -eq 'Zoom.Zoom' }
    Assert-True ($zoom.required -eq $false) 'Obligatoria = No'
    Assert-Equal 'Zoom' $zoom.name 'name column'
    $recepcion = $results | Where-Object { $_.Name -eq 'recepcion' }
    Assert-Equal 'Microsoft.Teams' ($recepcion.Applications -join ',') '7-Zip is already in base'
    Assert-True ($null -ne (Get-ZTProfile -Path (Join-Path $folder 'recepcion.json'))) 'generated profile loads'
}

Test-Case 'CSV saved as ANSI with commas and English headers' {
    $folder = Copy-RepoProfiles
    $csv = Join-Path (New-TestFolder) 'apps.csv'
    $content = "Department,PackageId,Name,Required`r`nAlmac" + [char]0x00E9 + "n,Zoom.Zoom,Zoom,no`r`n"
    $ansi = [System.Text.Encoding]::GetEncoding(1252)
    [System.IO.File]::WriteAllBytes($csv, $ansi.GetBytes($content))
    $result = @(New-ZTDepartmentProfile -CsvPath $csv -OutputDirectory $folder)[0]
    Assert-Equal 'almacen' $result.Name 'slug'
    Assert-Equal ('Almac' + [char]0x00E9 + 'n') (Read-ProfileFile $result.Path).displayName 'accent decoded from Windows-1252'
}

Test-Case 'CSV without the required columns explains what is missing' {
    $csv = Join-Path (New-TestFolder) 'bad.csv'
    Write-ZTTextFile -Path $csv -Content "Team;Program`nOffice;Zoom.Zoom`n"
    Assert-Throws { New-ZTDepartmentProfile -CsvPath $csv -OutputDirectory (New-TestFolder) } -Like '*needs a department column*'
}

Test-Case 'CSV rows with an invalid id are skipped, the rest is kept' {
    $csv = Join-Path (New-TestFolder) 'mixed.csv'
    Write-ZTTextFile -Path $csv -Content "Departamento;Id`nVentas;Zoom.Zoom`nVentas;rm -rf`nVentas;`n"
    $result = @(New-ZTDepartmentProfile -CsvPath $csv -OutputDirectory (Copy-RepoProfiles))[0]
    Assert-Equal 'Zoom.Zoom' ($result.Applications -join ',') 'applications'
}
