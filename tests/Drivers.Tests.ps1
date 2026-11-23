# Drivers: per-model packs, department peripherals, export from a reference PC, validation.

$packRoot = '\\srv-files\drivers\Models'
$lenovoPack = '\\srv-files\drivers\Models\LENOVO\ThinkCentre M70q Gen 3'
$zebra = '\\srv-files\drivers\Perifericos\zebra-zd421'

Test-Case 'Model pack: applied only when there is a folder for this exact make and model' {
    $script:Fake.Drivers.Available.Add($packRoot)
    $script:Fake.Drivers.Available.Add($lenovoPack)
    $r = @(Invoke-ZTDrivers -Settings @{ packs = $packRoot } -Manufacturer 'LENOVO' -Model 'ThinkCentre M70q Gen 3')
    Assert-Equal 1 $r.Count 'one result'
    Assert-Equal 'Installed' $r[0].Status 'status'
    Assert-Equal 'Model' $r[0].Kind 'kind'
    Assert-Equal 'LENOVO ThinkCentre M70q Gen 3' $r[0].Name 'name'
    Assert-Equal $lenovoPack (Get-FakeCall -Name 'Invoke-ZTDriverInstall')[0].Parameters.Path 'pack path'
}

Test-Case 'Model pack: another model gets nothing, and the form says why' {
    $script:Fake.Drivers.Available.Add($packRoot)
    $script:Fake.Drivers.Available.Add($lenovoPack)
    $r = @(Invoke-ZTDrivers -Settings @{ packs = $packRoot } -Manufacturer 'HP' -Model 'EliteDesk 800 G9')
    Assert-Equal 'Skipped' $r[0].Status 'status'
    Assert-Equal 'driver.noPack' $r[0].Message 'message'
    Assert-Like $r[0].Detail '*\HP\EliteDesk 800 G9*Windows Update*' 'detail names the folder it looked for'
    Assert-Equal 0 @(Get-FakeCall -Name 'Invoke-ZTDriverInstall').Count 'nothing installed'
}

Test-Case 'Model pack: an unreachable share is a note, not a crash' {
    $r = @(Invoke-ZTDrivers -Settings @{ packs = $packRoot } -Manufacturer 'LENOVO' -Model 'ThinkCentre M70q Gen 3')
    Assert-Equal 'Failed' $r[0].Status 'status'
    Assert-Equal 'driver.unreachable' $r[0].Message 'message'
}

Test-Case 'Get-ZTDriverPackPath: makes and models become safe folder names' {
    Assert-Equal '\\s\d\HP_Compaq\Elite_ 800_' (Get-ZTDriverPackPath -Root '\\s\d' -Manufacturer 'HP/Compaq' -Model 'Elite: 800?') 'sanitised'
    Assert-Equal 'C:\Packs\Unknown\Unknown' (Get-ZTDriverPackPath -Root 'C:\Packs' -Manufacturer '' -Model '...') 'empty values'
}

Test-Case 'Peripherals: each package is added to the driver store; a restart request is kept' {
    $docks = '\\srv-files\drivers\Perifericos\displaylink'
    foreach ($path in $zebra, $docks) { $script:Fake.Drivers.Available.Add($path) }
    $script:Fake.Drivers.ExitCodes[$docks] = 3010
    $settings = @{ peripherals = @(@{ name = 'Zebra ZD421'; path = $zebra }, @{ name = 'DisplayLink'; path = $docks }, @{ name = 'Wacom STU-540'; path = '\\srv-files\drivers\Perifericos\wacom' }) }
    $r = @(Invoke-ZTDrivers -Settings $settings -Manufacturer 'LENOVO' -Model 'X')
    Assert-Equal 'Installed,Installed,Failed' (($r | ForEach-Object { $_.Status }) -join ',') 'statuses'
    Assert-Equal 'Peripheral' $r[0].Kind 'kind'
    Assert-True (-not $r[0].RebootRequired) 'no restart for the first'
    Assert-True $r[1].RebootRequired 'pnputil 3010 means restart'
    Assert-Equal 'driver.unreachable' $r[2].Message 'missing folder reported'
}

Test-Case 'Peripherals: a pnputil error is reported with its code' {
    $script:Fake.Drivers.Available.Add($zebra)
    $script:Fake.Drivers.ExitCodes[$zebra] = 5
    $r = @(Invoke-ZTDrivers -Settings @{ peripherals = @(@{ name = 'Zebra'; path = $zebra }) })
    Assert-Equal 'Failed' $r[0].Status 'status'
    Assert-Equal 'pnputil returned 5. Failed to add driver package: Access is denied.' $r[0].Detail 'detail'
}

Test-Case 'Drivers: -WhatIf checks the folders and installs nothing' {
    foreach ($path in $packRoot, $lenovoPack, $zebra) { $script:Fake.Drivers.Available.Add($path) }
    $settings = @{ packs = $packRoot; peripherals = @(@{ name = 'Zebra'; path = $zebra }) }
    $r = @(Invoke-ZTDrivers -Settings $settings -Manufacturer 'LENOVO' -Model 'ThinkCentre M70q Gen 3' -WhatIf)
    Assert-Equal 'WhatIf,WhatIf' (($r | ForEach-Object { $_.Status }) -join ',') 'statuses'
    Assert-Equal 0 @(Get-FakeChange).Count 'changes'
}

Test-Case 'Drivers: paths that are not plain full paths are refused before pnputil runs' {
    foreach ($path in 'drivers\zebra', '\\srv\d\x" & calc', '\\srv\d\*', 'C:\d|x') {
        Assert-Throws { Install-ZTDriverPackage -Name 'x' -Kind 'Peripheral' -Path $path } -Like '*Invalid driver path*' -What $path
    }
    $r = @(Invoke-ZTDrivers -Settings @{ peripherals = @(@{ name = 'Bad'; path = 'relative\path' }) })
    Assert-Equal 'driver.error' $r[0].Message 'invalid path inside a profile becomes a note'
    Assert-Equal 0 @(Get-FakeCall -Name 'Invoke-ZTDriverInstall').Count 'pnputil never ran'
}

Test-Case 'Profiles: drivers settings are validated and peripherals inherited by name' {
    $folder = New-ProfileFolder @{
        base  = @{ name = 'base'; drivers = @{ packs = '\\srv\drivers\Models'; peripherals = @(@{ name = 'Dock'; path = '\\srv\d\dock' }) } }
        child = @{ name = 'child'; extends = 'base'; drivers = @{ peripherals = @(@{ name = 'dock'; path = '\\srv\d\dock-v2' }, @{ name = 'Zebra'; path = '\\srv\d\zebra' }) } }
        bad   = @{ name = 'bad'; drivers = @{ packs = 'Models'; peripherals = @(@{ path = '\\srv\d\x' }, @{ name = 'X' }, @{ name = 'Y'; path = 'C:\d\y'; version = 2 }); auto = $true } }
    }
    $child = Get-ZTProfile -Name 'child' -ProfilesPath $folder
    Assert-Equal '\\srv\drivers\Models' $child['drivers']['packs'] 'packs inherited'
    Assert-Equal 'dock:\\srv\d\dock-v2,Zebra:\\srv\d\zebra' ((@($child['drivers']['peripherals']) | ForEach-Object { '{0}:{1}' -f $_['name'], $_['path'] }) -join ',') 'peripherals merged by name'
    $text = (@(Test-ZTProfile -ProfileData (Get-ZTProfile -Name 'bad' -ProfilesPath $folder -SkipValidation)) | ForEach-Object { $_.Message }) -join ' | '
    # In -like patterns [1] is a character class: ? stands for the brackets.
    foreach ($expected in '*drivers.packs must be a full path*', "*peripherals?1?: missing 'name'*", "*peripherals?2?: missing 'path'*", "*unknown key 'version'*", "*Unknown drivers setting 'auto'*") {
        Assert-Like $text $expected 'validation'
    }
}

Test-Case 'Export-ZTDriverPack: exports this PC''s drivers into a folder named after its make and model' {
    $root = New-TestFolder
    $pack = Export-ZTDriverPack -Root $root
    Assert-Equal (Join-Path $root 'LENOVO\ThinkCentre M70q Gen 3') $pack.Path 'folder by make and model'
    Assert-True (Test-Path -LiteralPath $pack.Path) 'folder created'
    Assert-Equal 3 $pack.Count 'drivers exported'
    Assert-Equal 'Display, Net, System' $pack.Classes 'classes'
    Assert-Equal $pack.Path (Get-FakeCall -Name 'Export-WindowsDriver')[0].Parameters.Destination 'destination'
}

Test-Case 'Export-ZTPrinterDriver: copies the vendor driver package, skips drivers that ship with Windows' {
    $store = Join-Path (New-TestFolder) 'hpcu270u.inf_amd64_1a2b3c'
    [void][System.IO.Directory]::CreateDirectory($store)
    foreach ($file in 'hpcu270u.inf', 'hpcu270u.cat', 'hpcu270u.gpd') { [System.IO.File]::WriteAllText((Join-Path $store $file), 'x') }
    $script:Fake.Print.Drivers.Add('HP Universal Printing PCL 6')
    $script:Fake.Print.DriverInfs['HP Universal Printing PCL 6'] = Join-Path $store 'hpcu270u.inf'
    $script:Fake.Print.DriverInfs['Microsoft Print To PDF'] = 'C:\Windows\System32\DriverStore\FileRepository\ntprint.inf_amd64_x\ntprint.inf'
    $root = New-TestFolder
    $inf = Export-ZTPrinterDriver -DriverName 'HP Universal Printing PCL 6' -Root $root
    Assert-Equal (Join-Path $root 'Printers\HP Universal Printing PCL 6\hpcu270u.inf') $inf 'driverInf'
    Assert-Equal 3 @(Get-ChildItem -LiteralPath (Split-Path $inf -Parent) -File).Count 'whole package copied'
    Assert-Equal $null (Export-ZTPrinterDriver -DriverName 'Microsoft Print To PDF' -Root $root) 'inbox driver skipped'
    Assert-Equal $null (Export-ZTPrinterDriver -DriverName 'Not Installed' -Root $root) 'unknown driver'
}

Test-Case 'Capture with -ExportDrivers: the profile points at the exported pack and printer drivers' {
    $store = Join-Path (New-TestFolder) 'plotter.inf_amd64_9f'
    [void][System.IO.Directory]::CreateDirectory($store)
    [System.IO.File]::WriteAllText((Join-Path $store 'plotter.inf'), 'x')
    Add-FakePrinter -Name 'Taller - Plotter' -Address '192.168.50.21' -Driver 'Vendor Plotter Driver'
    $script:Fake.Print.DriverInfs['Vendor Plotter Driver'] = Join-Path $store 'plotter.inf'
    $script:Fake.Winget.Export = [System.IO.File]::ReadAllText((Join-Path $root 'examples\winget-export-taller.json'))
    $driversRoot = New-TestFolder
    $folder = Copy-RepoProfiles
    $result = New-ZTDepartmentProfile -FromThisComputer -Name 'nave3' -OutputDirectory $folder -ExportDrivers $driversRoot
    Assert-Equal 3 $result.DriverPack.Count 'pack exported'
    $saved = [System.IO.File]::ReadAllText($result.Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-Equal (Join-Path $driversRoot 'Models') $saved.drivers.packs 'packs root in the profile'
    Assert-Equal (Join-Path $driversRoot 'Printers\Vendor Plotter Driver\plotter.inf') $saved.printers[0].driverInf 'printer driverInf filled in'
    Assert-True (Test-Path -LiteralPath $saved.printers[0].driverInf) 'driver package copied'
    Assert-True ($null -ne (Get-ZTProfile -Path $result.Path)) 'the generated profile is valid'
    Assert-Throws { New-ZTDepartmentProfile -FromThisComputer -Name 'x' -OutputDirectory $folder -ExportDrivers 'relative\path' -Force } -Like '*-ExportDrivers must be a full path*'
}

Test-Case 'Provisioning: drivers go first, before any application is installed' {
    foreach ($path in $packRoot, $lenovoPack) { $script:Fake.Drivers.Available.Add($path) }
    $run = Invoke-ZTProvisioning -Department 'taller' -ProfilesPath $RepoProfiles -OutputPath (New-TestFolder) -RetryDelaySeconds 0
    Assert-Equal 'Model:Installed,Peripheral:Failed' ((@($run.Drivers) | ForEach-Object { '{0}:{1}' -f $_.Kind, $_.Status }) -join ',') 'model pack added, Zebra share missing'
    $calls = @($script:Fake.Calls | ForEach-Object { $_.Name })
    $driverCall = [array]::IndexOf($calls, 'Invoke-ZTDriverInstall')
    $firstWinget = [array]::IndexOf($calls, 'winget')
    Assert-True ($driverCall -ge 0 -and $driverCall -lt $firstWinget) ('driver install ({0}) before winget ({1})' -f $driverCall, $firstWinget)
    $html = [System.IO.File]::ReadAllText($run.ReportPaths.HtmlPath, [System.Text.Encoding]::UTF8)
    Assert-True ($html.Contains('<td>Zebra ZD421 (etiquetas)</td>')) 'peripheral on the form'
    $skipped = Invoke-ZTProvisioning -Department 'taller' -ProfilesPath $RepoProfiles -OutputPath (New-TestFolder) -RetryDelaySeconds 0 -SkipDrivers
    Assert-Equal 0 @($skipped.Drivers).Count '-SkipDrivers'
}
