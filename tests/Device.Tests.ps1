# Hardware inventory, against the fake CIM classes in WindowsMock.ps1.

Test-Case 'Get-ZTDeviceInfo: reads what the handover form needs' {
    $d = Get-ZTDeviceInfo
    Assert-Equal 'PC-OFI-014' $d.ComputerName 'computer name from CIM'
    Assert-Equal 'LENOVO' $d.Manufacturer 'manufacturer'
    Assert-Equal 'ThinkCentre M70q Gen 3' $d.Model 'Lenovo friendly model name'
    Assert-Equal 'PF3K7Q2M' $d.SerialNumber 'serial'
    Assert-Equal 'Desktop' $d.Chassis 'chassis 35 (mini PC)'
    Assert-Equal 'Intel(R) Core(TM) i5-12500T' $d.Processor 'processor, spaces trimmed'
    Assert-Equal 16 $d.MemoryGB 'memory'
    Assert-Equal 476 $d.DiskSizeGB 'disk size'
    Assert-Equal 402 $d.DiskFreeGB 'disk free'
    Assert-Equal 'Windows 11 Pro' $d.OperatingSystem 'OS name without "Microsoft"'
    Assert-Equal '24H2 (26100.2314)' $d.OsVersion 'release and build'
    Assert-Equal '192.168.10.57' $d.IPAddress 'IPv4 of the adapter with a gateway'
    Assert-Equal '8C:16:45:2A:7B:91' $d.MacAddress 'MAC'
    Assert-Equal 'Workgroup' $d.JoinType 'join'
    Assert-Equal '2.0' $d.TpmVersion 'TPM version'
    Assert-True $d.TpmReady 'TPM ready'
    Assert-Equal 'On' $d.SecureBoot 'Secure Boot'
    Assert-Equal 'Windows Defender' $d.Antivirus 'antivirus'
}

Test-Case 'Get-ZTDeviceInfo: laptops, virtual machines and other makers' {
    $script:Fake.Cim['Win32_SystemEnclosure'] = @([pscustomobject]@{ ChassisTypes = @(10) })
    $script:Fake.Cim['Win32_ComputerSystem'][0].Manufacturer = 'HP'
    $script:Fake.Cim['Win32_ComputerSystem'][0].Model = 'HP EliteBook 840 G10'
    $d = Get-ZTDeviceInfo
    Assert-Equal 'Laptop' $d.Chassis 'notebook'
    Assert-Equal 'HP EliteBook 840 G10' $d.Model 'non-Lenovo model kept'
    $script:Fake.Cim['Win32_ComputerSystem'][0].Manufacturer = 'Microsoft Corporation'
    $script:Fake.Cim['Win32_ComputerSystem'][0].Model = 'Virtual Machine'
    Assert-Equal 'VirtualMachine' (Get-ZTDeviceInfo).Chassis 'Hyper-V'
}

Test-Case 'Get-ZTDeviceInfo: join state, legacy BIOS and missing data do not break it' {
    $script:Fake.Join.EntraJoined = $true
    $script:Fake.Join.DomainJoined = $true
    $script:Fake.SecureBoot = 'Unsupported'
    $script:Fake.Cim.Remove('Win32_Tpm')
    $script:Fake.Cim.Remove('Win32_LogicalDisk')
    $script:Fake.Cim.Remove('AntiVirusProduct')
    $d = Get-ZTDeviceInfo
    Assert-Equal 'Hybrid' $d.JoinType 'hybrid join'
    Assert-Equal 'Unsupported' $d.SecureBoot 'legacy BIOS'
    Assert-Equal '' $d.TpmVersion 'no TPM'
    Assert-Equal 0 $d.DiskSizeGB 'no disk data'
    Assert-Equal '' $d.Antivirus 'no antivirus data'
}

Test-Case 'Get-ZTDeviceInfo: an empty CIM repository still returns an object' {
    $script:Fake.Cim = @{}
    $script:Fake.Missing = @('Confirm-SecureBootUEFI')
    $d = Get-ZTDeviceInfo
    Assert-Equal 'Other' $d.Chassis 'unknown chassis'
    Assert-Equal 'Unknown' $d.SecureBoot 'unknown secure boot'
    Assert-Equal ([string]$env:COMPUTERNAME) $d.ComputerName 'falls back to the environment'
}
