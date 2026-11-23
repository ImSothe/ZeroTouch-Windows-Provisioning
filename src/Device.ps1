#Requires -Version 5.1
# Hardware and operating system inventory for the handover form. Read-only.

# SMBIOS chassis types: https://www.dmtf.org/standards/smbios
$script:ZTLaptopChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
$script:ZTDesktopChassis = @(3, 4, 5, 6, 7, 13, 15, 16, 24, 34, 35, 36)

function Get-ZTCim {
    param([Parameter(Mandatory)][string]$ClassName, [string]$Namespace = 'root\cimv2')
    try {
        @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)
    }
    catch {
        Write-Verbose ('CIM {0}\{1}: {2}' -f $Namespace, $ClassName, $_.Exception.Message)
        @()
    }
}

# DisplayVersion (23H2, 24H2...) and update build revision live only in the registry.
function Get-ZTWindowsVersion {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $values = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    $display = ''
    if ($values) {
        if ($values.PSObject.Properties.Name -contains 'DisplayVersion') { $display = [string]$values.DisplayVersion }
        elseif ($values.PSObject.Properties.Name -contains 'ReleaseId') { $display = [string]$values.ReleaseId }
    }
    $ubr = ''
    if ($values -and $values.PSObject.Properties.Name -contains 'UBR') { $ubr = [string]$values.UBR }
    [pscustomobject]@{ DisplayVersion = $display; Ubr = $ubr }
}

function Get-ZTChassisType {
    param([int[]]$ChassisTypes, [string]$Manufacturer, [string]$Model)
    if (($Model -match 'Virtual|VMware|KVM|HVM domU') -or ($Manufacturer -match 'VMware|QEMU|innotek|Xen|Parallels')) { return 'VirtualMachine' }
    foreach ($type in @($ChassisTypes)) {
        if ($script:ZTLaptopChassis -contains $type) { return 'Laptop' }
        if ($script:ZTDesktopChassis -contains $type) { return 'Desktop' }
    }
    return 'Other'
}

<#
.SYNOPSIS
    Collects what the handover form needs to identify the computer: make, model, serial number,
    hardware, operating system, network, directory join and security hardware state.
#>
function Get-ZTDeviceInfo {
    $system = Get-ZTCim -ClassName 'Win32_ComputerSystem' | Select-Object -First 1
    $product = Get-ZTCim -ClassName 'Win32_ComputerSystemProduct' | Select-Object -First 1
    $bios = Get-ZTCim -ClassName 'Win32_BIOS' | Select-Object -First 1
    $enclosure = Get-ZTCim -ClassName 'Win32_SystemEnclosure' | Select-Object -First 1
    $cpu = Get-ZTCim -ClassName 'Win32_Processor' | Select-Object -First 1
    $os = Get-ZTCim -ClassName 'Win32_OperatingSystem' | Select-Object -First 1
    $drive = $env:SystemDrive
    if (-not $drive) { $drive = 'C:' }
    $disk = Get-ZTCim -ClassName 'Win32_LogicalDisk' | Where-Object { $_.DeviceID -eq $drive } | Select-Object -First 1
    $adapters = Get-ZTCim -ClassName 'Win32_NetworkAdapterConfiguration' | Where-Object { $_.IPEnabled }
    $adapter = @($adapters | Where-Object { $_.DefaultIPGateway }) + @($adapters) | Select-Object -First 1

    $manufacturer = ''
    $model = ''
    if ($system) {
        $manufacturer = ([string]$system.Manufacturer).Trim()
        $model = ([string]$system.Model).Trim()
    }
    # Lenovo reports the machine type (11DT0040SP) as the model; the friendly name is in Version.
    if ($manufacturer -match '^LENOVO' -and $product -and ([string]$product.Version).Trim()) { $model = ([string]$product.Version).Trim() }

    $computerName = ''
    if ($system -and $system.Name) { $computerName = [string]$system.Name } else { $computerName = [string]$env:COMPUTERNAME }

    $memoryGB = 0
    if ($system -and $system.TotalPhysicalMemory) { $memoryGB = [int][math]::Round([double]$system.TotalPhysicalMemory / 1GB) }
    $diskSize = 0
    $diskFree = 0
    if ($disk) {
        $diskSize = [int][math]::Round([double]$disk.Size / 1GB)
        $diskFree = [int][math]::Round([double]$disk.FreeSpace / 1GB)
    }

    $version = Get-ZTWindowsVersion
    $osName = ''
    $osVersion = ''
    if ($os) {
        $osName = ([string]$os.Caption) -replace '^Microsoft\s+', ''
        $build = [string]$os.BuildNumber
        if ($version.Ubr) { $build = '{0}.{1}' -f $build, $version.Ubr }
        if ($version.DisplayVersion) { $osVersion = '{0} ({1})' -f $version.DisplayVersion, $build } else { $osVersion = $build }
    }

    $ipAddress = ''
    $macAddress = ''
    if ($adapter) {
        $ipAddress = [string](@($adapter.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }) | Select-Object -First 1)
        $macAddress = [string]$adapter.MACAddress
    }

    $join = Get-ZTJoinState
    $joinType = 'Workgroup'
    if ($join.EntraJoined -and $join.DomainJoined) { $joinType = 'Hybrid' }
    elseif ($join.EntraJoined) { $joinType = 'Entra' }
    elseif ($join.DomainJoined) { $joinType = 'Domain' }

    $tpmVersion = ''
    $tpmReady = $false
    $tpm = Get-ZTCim -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName 'Win32_Tpm' | Select-Object -First 1
    if ($tpm) {
        $tpmVersion = (([string]$tpm.SpecVersion) -split ',')[0].Trim()
        $tpmReady = [bool]($tpm.IsEnabled_InitialValue -and $tpm.IsActivated_InitialValue)
    }

    $secureBoot = 'Unknown'
    if (Test-ZTCommand -Name 'Confirm-SecureBootUEFI') {
        try {
            if (Confirm-SecureBootUEFI -ErrorAction Stop) { $secureBoot = 'On' } else { $secureBoot = 'Off' }
        }
        catch [System.PlatformNotSupportedException] {
            $secureBoot = 'Unsupported'
        }
        catch {
            $secureBoot = 'Unknown'
        }
    }

    # SecurityCenter2 lists third-party products too (workstations only).
    $antivirus = @(Get-ZTCim -Namespace 'root\SecurityCenter2' -ClassName 'AntiVirusProduct' |
        ForEach-Object { [string]$_.displayName } | Where-Object { $_ } | Select-Object -Unique) -join ', '

    $loggedOn = ''
    if ($system) { $loggedOn = [string]$system.UserName }
    $serial = ''
    if ($bios) { $serial = ([string]$bios.SerialNumber).Trim() }
    $biosVersion = ''
    if ($bios) { $biosVersion = ([string]$bios.SMBIOSBIOSVersion).Trim() }
    $chassisTypes = @()
    if ($enclosure) { $chassisTypes = @($enclosure.ChassisTypes | ForEach-Object { [int]$_ }) }
    $cpuName = ''
    if ($cpu) { $cpuName = (([string]$cpu.Name) -replace '\s+', ' ').Trim() }

    [pscustomobject]@{
        ComputerName    = $computerName
        Manufacturer    = $manufacturer
        Model           = $model
        SerialNumber    = $serial
        Chassis         = Get-ZTChassisType -ChassisTypes $chassisTypes -Manufacturer $manufacturer -Model $model
        BiosVersion     = $biosVersion
        Processor       = $cpuName
        MemoryGB        = $memoryGB
        SystemDrive     = $drive
        DiskSizeGB      = $diskSize
        DiskFreeGB      = $diskFree
        OperatingSystem = $osName
        OsVersion       = $osVersion
        IPAddress       = $ipAddress
        MacAddress      = $macAddress
        JoinType        = $joinType
        TpmVersion      = $tpmVersion
        TpmReady        = $tpmReady
        SecureBoot      = $secureBoot
        Antivirus       = $antivirus
        LoggedOnUser    = $loggedOn
        CollectedAt     = (Get-Date).ToString('s')
    }
}
