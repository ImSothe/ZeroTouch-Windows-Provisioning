# Network printers: install, idempotency, drivers, simulation, capture from a reference PC, validation.

$plantPrinter = @{ name = 'Taller - Impresora de planta'; address = '192.168.50.20'; driver = 'HP Universal Printing PCL 6'; location = 'Nave 2' }

Test-Case 'Install-ZTPrinter: driver from the driver store, TCP/IP port, then the queue' {
    $r = Install-ZTPrinter -Printer $plantPrinter
    Assert-Equal 'Installed' $r.Status 'status'
    Assert-Equal 'Added at 192.168.50.20 with the HP Universal Printing PCL 6 driver.' $r.Detail 'detail'
    Assert-Equal 'HP Universal Printing PCL 6' (Get-FakeCall -Name 'Add-PrinterDriver')[0].Parameters.Name 'driver added'
    $port = (Get-FakeCall -Name 'Add-PrinterPort')[0].Parameters
    Assert-Equal 'IP_192.168.50.20' $port.Name 'port name'
    Assert-Equal '192.168.50.20' $port.PrinterHostAddress 'port address'
    Assert-Equal 9100 $port.PortNumber 'raw port'
    $queue = (Get-FakeCall -Name 'Add-Printer')[0].Parameters
    Assert-Equal 'IP_192.168.50.20' $queue.PortName 'queue on the port'
    Assert-Equal 'Nave 2' $queue.Location 'location'
    Assert-Equal 0 @(Get-FakeCall -Name 'Invoke-ZTPnpUtil').Count 'no driver package needed'
}

Test-Case 'Install-ZTPrinter: an existing printer is left alone' {
    Add-FakePrinter -Name 'Taller - Impresora de planta' -Address '192.168.50.20'
    $r = Install-ZTPrinter -Printer $plantPrinter
    Assert-Equal 'AlreadyInstalled' $r.Status 'status'
    Assert-Equal 0 @(Get-FakeChange).Count 'changes'
}

Test-Case 'Install-ZTPrinter: an existing port and an installed driver are reused; custom ports get their own name' {
    Add-FakePrinter -Name 'Other printer' -Address '192.168.50.20'
    Install-ZTPrinter -Printer $plantPrinter | Out-Null
    Assert-Equal 0 @(Get-FakeCall -Name 'Add-PrinterPort').Count 'port reused'
    Assert-Equal 0 @(Get-FakeCall -Name 'Add-PrinterDriver').Count 'driver already installed'
    Install-ZTPrinter -Printer @{ name = 'Label printer'; address = 'zebra-01.demo.lab'; driver = 'HP Universal Printing PCL 6'; port = 9101 } | Out-Null
    Assert-Equal 'IP_zebra-01.demo.lab_9101' (Get-FakeCall -Name 'Add-PrinterPort')[0].Parameters.Name 'port with number'
}

Test-Case 'Install-ZTPrinter: a missing driver without a package fails clearly and adds nothing' {
    $r = Install-ZTPrinter -Printer @{ name = 'Plotter'; address = '192.168.50.21'; driver = 'Vendor Plotter Driver' }
    Assert-Equal 'Failed' $r.Status 'status'
    Assert-Equal 'printer.driverMissing' $r.Message 'message'
    Assert-Like $r.Detail '*Vendor Plotter Driver*driverInf*' 'detail tells what to do'
    Assert-Equal 0 @(Get-FakeCall -Name 'Add-PrinterPort').Count 'no port'
    Assert-Equal 0 @(Get-FakeCall -Name 'Add-Printer').Count 'no queue'
}

Test-Case 'Install-ZTPrinter: driverInf stages the driver package with pnputil first' {
    $script:Fake.Print.InfDrivers = @('Vendor Plotter Driver')
    $inf = '\\srv-files\drivers\plotter\plotter.inf'
    $r = Install-ZTPrinter -Printer @{ name = 'Plotter'; address = '192.168.50.21'; driver = 'Vendor Plotter Driver'; driverInf = $inf }
    Assert-Equal 'Installed' $r.Status 'status'
    Assert-Equal $inf (Get-FakeCall -Name 'Invoke-ZTPnpUtil')[0].Parameters.InfPath 'inf staged'
}

Test-Case 'Install-ZTPrinter: -WhatIf says what would happen and changes nothing' {
    $r = Install-ZTPrinter -Printer @{ name = 'Plotter'; address = '192.168.50.21'; driver = 'Vendor Plotter Driver' } -WhatIf
    Assert-Equal 'WhatIf' $r.Status 'status'
    Assert-Equal 'printer.whatIfDriver' $r.Message 'mentions the driver'
    $script:Fake.Print.Drivers.Add('HP Universal Printing PCL 6')
    Assert-Equal 'printer.whatIf' (Install-ZTPrinter -Printer $plantPrinter -WhatIf).Message 'driver already installed'
    Assert-Equal 0 @(Get-FakeChange).Count 'changes'
}

Test-Case 'Install-ZTPrinter: invalid definitions are refused before anything runs' {
    foreach ($printer in @(
            @{ name = 'P'; address = '192.168.1.1; calc'; driver = 'D' },
            @{ name = 'P*'; address = '192.168.1.1'; driver = 'D' },
            @{ name = '\\server\queue'; address = '192.168.1.1'; driver = 'D' },
            @{ name = 'P'; address = '192.168.1.1' }
        )) {
        Assert-Throws { Install-ZTPrinter -Printer $printer } -Like '*Invalid printer definition*' -What ($printer | ConvertTo-Json -Compress)
    }
    Assert-Equal 0 $script:Fake.Calls.Count 'no calls'
}

Test-Case 'Install-ZTPrinter: without the PrintManagement module it reports instead of failing hard' {
    $script:Fake.Missing = @('Get-Printer')
    Assert-Equal 'printer.unavailable' (Install-ZTPrinter -Printer $plantPrinter).Message 'message'
}

Test-Case 'Get-ZTNetworkPrinter: takes TCP/IP printers only' {
    Add-FakePrinter -Name 'Oficina - Planta 1' -Address '192.168.10.30' -Location 'Planta 1'
    Add-FakePrinter -Name 'Etiquetas' -Address '192.168.10.31' -Driver 'ZDesigner ZD421-203dpi ZPL' -PortNumber 9101
    Add-FakePrinter -Name '\\srv-print\Direccion' -Type 'Connection'
    $captured = @(Get-ZTNetworkPrinter)
    Assert-Equal 'Oficina - Planta 1,Etiquetas' (($captured | ForEach-Object { $_['name'] }) -join ',') 'printers (PDF printer and server connection skipped)'
    Assert-Equal 'Planta 1' $captured[0]['location'] 'location'
    Assert-True (-not $captured[0].Contains('port')) 'default port not written'
    Assert-Equal 9101 $captured[1]['port'] 'custom port kept'
    Assert-Equal 'ZDesigner ZD421-203dpi ZPL' $captured[1]['driver'] 'driver name'
}

Test-Case 'Profiles: printers are validated and inherited by name' {
    $folder = New-ProfileFolder @{
        base  = @{ name = 'base'; printers = @(@{ name = 'Shared'; address = '10.0.0.5'; driver = 'D1' }, @{ name = 'Old'; address = '10.0.0.6'; driver = 'D1' }) }
        child = @{ name = 'child'; extends = 'base'; printers = @(@{ name = 'shared'; address = '10.0.0.7'; driver = 'D2' }) }
        bad   = @{ name = 'bad'; printers = @(@{ name = 'P?'; address = 'printer 1'; driver = ''; port = 70000; driverInf = 'drivers\x.inf'; color = $true }) }
    }
    $child = Get-ZTProfile -Name 'child' -ProfilesPath $folder
    Assert-Equal 'shared:10.0.0.7,Old:10.0.0.6' ((@($child['printers']) | ForEach-Object { '{0}:{1}' -f $_['name'], $_['address'] }) -join ',') 'child replaced the parent printer with the same name'
    $issues = @(Test-ZTProfile -ProfileData (Get-ZTProfile -Name 'bad' -ProfilesPath $folder -SkipValidation))
    $text = ($issues | ForEach-Object { $_.Message }) -join ' | '
    foreach ($expected in "*name 'P?' cannot contain*", "*invalid address 'printer 1'*", "*missing 'driver'*", '*port must be a number*', '*driverInf must be the full path*', "*unknown key 'color'*") {
        Assert-Like $text $expected 'validation'
    }
}

Test-Case 'Repository profiles: the workshop printer stages its driver from the share' {
    $p = Get-ZTProfile -Name 'taller' -ProfilesPath $RepoProfiles
    $printer = @($p['printers'])[0]
    Assert-Like $printer['driverInf'] '\\*.inf' 'UNC driver package'
    Assert-Equal 1 @((Get-ZTProfile -Name 'comercial' -ProfilesPath $RepoProfiles)['printers']).Count 'sales laptops inherit the office printer'
}
