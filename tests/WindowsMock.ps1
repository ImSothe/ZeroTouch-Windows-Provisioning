# A fake Windows for the test suite.
#
# Every system command the provisioning code calls is replaced here by a function with the same
# name. PowerShell resolves functions before cmdlets, so while the tests run Get-BitLockerVolume,
# Set-NetFirewallProfile, Remove-AppxPackage... are these fakes. They read and change the in-memory
# $script:Fake state and record every call, so tests can assert what would have happened on a real
# PC. Security.Tests.ps1 proves that every command the source can run during the tests is either
# faked here or harmless.

# What a real recovery password looks like. Tests check it never reaches a log, report or console.
$script:FakeRecoveryPassword = '123456-234567-345678-456789-567890-678901-789012-890123'

function Reset-FakeWindows {
    $script:Fake = @{
        Calls          = New-Object -TypeName System.Collections.Generic.List[object]
        IsAdmin        = $true
        IsSystem       = $false
        Missing        = @()
        Join           = @{ EntraJoined = $false; DomainJoined = $false }
        EscrowFails    = $false
        Winget         = @{ Available = $true; Installed = @{}; Versions = @{}; Results = @{}; Export = $null }
        BitLocker      = @{
            ProtectionStatus     = 'On'
            VolumeStatus         = 'FullyEncrypted'
            EncryptionMethod     = 'XtsAes256'
            EncryptionPercentage = 100
            Protectors           = (New-Object -TypeName System.Collections.Generic.List[object])
        }
        Tpm            = @{ TpmPresent = $true; TpmReady = $true }
        Smb1           = @{ Server = $false; Feature = 'Disabled'; RestartNeeded = $false; Throw = $false }
        Firewall       = @{ Profiles = @(); Rules = (New-Object -TypeName System.Collections.Generic.List[string]); FailRules = @() }
        Appx           = (New-Object -TypeName System.Collections.Generic.List[object])
        Provisioned    = (New-Object -TypeName System.Collections.Generic.List[object])
        AppxFail       = @()
        SecureBoot     = 'On'
        WindowsVersion = [pscustomobject]@{ DisplayVersion = '24H2'; Ubr = '2314' }
        PdfResult      = $true
        Cim            = @{}
        Print          = @{
            Printers    = (New-Object -TypeName System.Collections.Generic.List[object])
            Ports       = (New-Object -TypeName System.Collections.Generic.List[object])
            Drivers     = (New-Object -TypeName System.Collections.Generic.List[string])
            Staged      = (New-Object -TypeName System.Collections.Generic.List[string])
            InfDrivers  = @()
            PnpExitCode = 0
            DriverInfs  = @{}
        }
        # Driver folders and shares that exist, pnputil exit codes per path, and the PC's third-party drivers.
        Drivers        = @{
            Available  = (New-Object -TypeName System.Collections.Generic.List[string])
            ExitCodes  = @{}
            ThirdParty = @(
                [pscustomobject]@{ Driver = 'oem3.inf'; ClassName = 'Net'; ProviderName = 'Intel' },
                [pscustomobject]@{ Driver = 'oem7.inf'; ClassName = 'Display'; ProviderName = 'Intel Corporation' },
                [pscustomobject]@{ Driver = 'oem9.inf'; ClassName = 'System'; ProviderName = 'INTEL' }
            )
        }
    }
    # A PC out of the box has the PDF printer, and the HP universal driver in its driver store.
    $script:Fake.Print.Ports.Add([pscustomobject]@{ Name = 'PORTPROMPT:' })
    $script:Fake.Print.Printers.Add([pscustomobject]@{ Name = 'Microsoft Print to PDF'; Type = 'Local'; PortName = 'PORTPROMPT:'; DriverName = 'Microsoft Print To PDF'; Location = '' })
    foreach ($driver in 'Microsoft Print To PDF', 'Microsoft IPP Class Driver') { $script:Fake.Print.Drivers.Add($driver) }
    foreach ($driver in 'HP Universal Printing PCL 6', 'Microsoft IPP Class Driver') { $script:Fake.Print.Staged.Add($driver) }
    foreach ($name in 'Domain', 'Private', 'Public') {
        $script:Fake.Firewall.Profiles += [pscustomobject]@{
            Name = $name; Enabled = 'True'; DefaultInboundAction = 'Block'; DefaultOutboundAction = 'Allow'; LogBlocked = 'True'
        }
    }
    $script:Fake.Cim = @{
        Win32_ComputerSystem              = @([pscustomobject]@{
                Name = 'PC-OFI-014'; Manufacturer = 'LENOVO'; Model = '11DT0040SP'; TotalPhysicalMemory = 17179869184
                PartOfDomain = $false; UserName = 'DEMO\lucia.martin'
            })
        Win32_ComputerSystemProduct       = @([pscustomobject]@{ Version = 'ThinkCentre M70q Gen 3' })
        Win32_BIOS                        = @([pscustomobject]@{ SerialNumber = 'PF3K7Q2M'; SMBIOSBIOSVersion = 'M4AKT3AA' })
        Win32_SystemEnclosure             = @([pscustomobject]@{ ChassisTypes = @(35) })
        Win32_Processor                   = @([pscustomobject]@{ Name = 'Intel(R) Core(TM) i5-12500T   ' })
        Win32_OperatingSystem             = @([pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '26100' })
        Win32_LogicalDisk                 = @([pscustomobject]@{ DeviceID = 'C:'; Size = 510770802688; FreeSpace = 431501070336 })
        Win32_NetworkAdapterConfiguration = @(
            [pscustomobject]@{ IPEnabled = $true; IPAddress = @('169.254.10.2'); MACAddress = '00:15:5D:00:00:01'; DefaultIPGateway = $null },
            [pscustomobject]@{ IPEnabled = $true; IPAddress = @('192.168.10.57', 'fe80::1c2d:3e4f'); MACAddress = '8C:16:45:2A:7B:91'; DefaultIPGateway = @('192.168.10.1') }
        )
        Win32_Tpm                         = @([pscustomobject]@{ SpecVersion = '2.0, 0, 1.59'; IsEnabled_InitialValue = $true; IsActivated_InitialValue = $true })
        AntiVirusProduct                  = @([pscustomobject]@{ displayName = 'Windows Defender' })
    }
}

# A new PC out of the box: unencrypted, SMBv1 on, firewall defaults not set, consumer apps installed.
function Set-FakeFreshPc {
    $script:Fake.BitLocker.ProtectionStatus = 'Off'
    $script:Fake.BitLocker.VolumeStatus = 'FullyDecrypted'
    $script:Fake.BitLocker.EncryptionMethod = 'None'
    $script:Fake.BitLocker.EncryptionPercentage = 0
    $script:Fake.Smb1.Server = $true
    $script:Fake.Smb1.Feature = 'Enabled'
    $script:Fake.Smb1.RestartNeeded = $true
    foreach ($fwProfile in $script:Fake.Firewall.Profiles) {
        $fwProfile.DefaultInboundAction = 'NotConfigured'
        $fwProfile.DefaultOutboundAction = 'NotConfigured'
        $fwProfile.LogBlocked = 'False'
    }
    foreach ($name in 'Microsoft.BingNews', 'Microsoft.GamingApp', 'MicrosoftTeams', 'Clipchamp.Clipchamp', 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsStore') {
        Add-FakeAppx -Name $name
    }
    Add-FakeAppx -Name 'Microsoft.BingNews' -Provisioned
}

function Add-FakeAppx {
    param([Parameter(Mandatory)][string]$Name, [switch]$Provisioned)
    if ($Provisioned) {
        $script:Fake.Provisioned.Add([pscustomobject]@{ DisplayName = $Name; PackageName = ('{0}_1.0.0.0_neutral_~_8wekyb3d8bbwe' -f $Name) })
    }
    else {
        $script:Fake.Appx.Add([pscustomobject]@{ Name = $Name; PackageFullName = ('{0}_1.0.0.0_x64__8wekyb3d8bbwe' -f $Name) })
    }
}

# A network printer already set up on the fake PC (TCP/IP port, driver installed).
function Add-FakePrinter {
    param([Parameter(Mandatory)][string]$Name, [string]$Address = '192.168.10.30', [string]$Driver = 'HP Universal Printing PCL 6', [string]$Type = 'Local', [int]$PortNumber = 9100, [string]$Location = '')
    $portName = 'IP_' + $Address
    if ($Type -eq 'Connection') { $portName = 'USB001' }
    if (-not ($script:Fake.Print.Ports | Where-Object { $_.Name -eq $portName })) {
        if ($Type -eq 'Connection') { $script:Fake.Print.Ports.Add([pscustomobject]@{ Name = $portName }) }
        else { $script:Fake.Print.Ports.Add([pscustomobject]@{ Name = $portName; PrinterHostAddress = $Address; PortNumber = $PortNumber }) }
    }
    if ($script:Fake.Print.Drivers -notcontains $Driver) { $script:Fake.Print.Drivers.Add($Driver) }
    $script:Fake.Print.Printers.Add([pscustomobject]@{ Name = $Name; Type = $Type; PortName = $portName; DriverName = $Driver; Location = $Location })
}

function Set-FakeInstallResult {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][int[]]$Codes)
    $queue = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($code in $Codes) { $queue.Add($code) }
    $script:Fake.Winget.Results[$Id] = $queue
}

function Register-FakeCall {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Parameters = @{})
    $script:Fake.Calls.Add([pscustomobject]@{ Name = $Name; Parameters = $Parameters })
}

function Get-FakeCall {
    param([Parameter(Mandatory)][string]$Name)
    @($script:Fake.Calls | Where-Object { $_.Name -eq $Name })
}

# Calls that would change the system (used to prove that -WhatIf and repeated runs change nothing).
# The registry marker is checked separately: it is written on every real run by design.
function Get-FakeChange {
    @($script:Fake.Calls | Where-Object {
            ($_.Name -match '^(Set|New|Remove|Enable|Disable|Add|Resume|Backup|BackupToAAD)-' -and $_.Name -ne 'Set-ZTRegistryMarker') -or
            ($_.Name -eq 'Invoke-ZTPnpUtil') -or ($_.Name -eq 'Invoke-ZTDriverInstall') -or
            ($_.Name -eq 'winget' -and @('install', 'uninstall', 'export') -contains $_.Parameters.ArgumentList[0])
        })
}

# ------------------------------------------------------------------ source probes

function Test-ZTIsAdmin { [bool]$script:Fake.IsAdmin }

function Test-ZTIsSystem { [bool]$script:Fake.IsSystem }

function Test-ZTCommand {
    param([Parameter(Mandatory)][string]$Name)
    @($script:Fake.Missing) -notcontains $Name
}

function Get-ZTJoinState {
    [pscustomobject]@{ EntraJoined = [bool]$script:Fake.Join.EntraJoined; DomainJoined = [bool]$script:Fake.Join.DomainJoined }
}

function Get-ZTWindowsVersion { $script:Fake.WindowsVersion }

function Set-ZTRegistryMarker {
    param([Parameter(Mandatory)]$Run, [string]$ReportPath)
    Register-FakeCall -Name 'Set-ZTRegistryMarker' -Parameters @{ Run = $Run; ReportPath = $ReportPath }
}

function ConvertTo-ZTPdf {
    param([Parameter(Mandatory)][string]$HtmlPath, [Parameter(Mandatory)][string]$PdfPath, [int]$TimeoutSeconds = 90)
    Register-FakeCall -Name 'ConvertTo-ZTPdf' -Parameters @{ HtmlPath = $HtmlPath; PdfPath = $PdfPath }
    if ($script:Fake.PdfResult) { [System.IO.File]::WriteAllText($PdfPath, '%PDF-1.7 fake') }
    [bool]$script:Fake.PdfResult
}

# ------------------------------------------------------------------ winget

function Resolve-ZTWingetPath {
    if (-not $script:Fake.Winget.Available) { throw 'winget (App Installer) was not found.' }
    'C:\Fake\winget.exe'
}

function Invoke-ZTWinget {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $null = Resolve-ZTWingetPath
    Register-FakeCall -Name 'winget' -Parameters @{ ArgumentList = $ArgumentList }
    $state = $script:Fake.Winget
    $id = $null
    $position = [array]::IndexOf($ArgumentList, '--id')
    if ($position -ge 0 -and $position + 1 -lt $ArgumentList.Count) { $id = $ArgumentList[$position + 1] }

    switch ($ArgumentList[0]) {
        '--version' {
            return [pscustomobject]@{ ExitCode = 0; Output = @('v1.9.25200') }
        }
        'list' {
            if ($id -and $state.Installed.ContainsKey($id)) {
                $row = '{0} App  {1}  {2}  winget' -f ($id.Split('.')[-1]), $id, $state.Installed[$id]
                return [pscustomobject]@{ ExitCode = 0; Output = @('Name  Id  Version  Source', '------------------------------', $row) }
            }
            return [pscustomobject]@{ ExitCode = $script:ZTWingetCode.NoApplicationsFound; Output = @('No installed package found matching input criteria.') }
        }
        'install' {
            $code = 0
            if ($state.Results.ContainsKey($id) -and $state.Results[$id].Count -gt 0) {
                $code = [int]$state.Results[$id][0]
                $state.Results[$id].RemoveAt(0)
            }
            $installed = $code -eq 0 -or $script:ZTRebootCodes -contains $code -or $script:ZTAlreadyInstalledCodes -contains $code
            if ($installed) {
                $version = '1.0.0'
                if ($state.Versions.ContainsKey($id)) { $version = $state.Versions[$id] }
                $state.Installed[$id] = $version
                return [pscustomobject]@{ ExitCode = $code; Output = @(('Found {0} [{0}]' -f $id), 'Successfully installed') }
            }
            return [pscustomobject]@{ ExitCode = $code; Output = @(('Found {0} [{0}]' -f $id), 'Installer failed with exit code: 1603') }
        }
        'export' {
            $target = $ArgumentList[[array]::IndexOf($ArgumentList, '-o') + 1]
            if ($state.Export -is [string]) { [System.IO.File]::WriteAllText($target, $state.Export) }
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
    }
    [pscustomobject]@{ ExitCode = 1; Output = @('Unsupported fake winget command.') }
}

# ------------------------------------------------------------------ BitLocker and TPM

function Get-FakeBitLockerVolume {
    $state = $script:Fake.BitLocker
    [pscustomobject]@{
        MountPoint           = 'C:'
        ProtectionStatus     = $state.ProtectionStatus
        VolumeStatus         = $state.VolumeStatus
        EncryptionMethod     = $state.EncryptionMethod
        EncryptionPercentage = $state.EncryptionPercentage
        KeyProtector         = $state.Protectors.ToArray()
    }
}

function Get-BitLockerVolume {
    [CmdletBinding()]
    param([string]$MountPoint)
    Register-FakeCall -Name 'Get-BitLockerVolume' -Parameters @{ MountPoint = $MountPoint }
    Get-FakeBitLockerVolume
}

function Add-BitLockerKeyProtector {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$MountPoint, [switch]$RecoveryPasswordProtector, [switch]$TpmProtector)
    Register-FakeCall -Name 'Add-BitLockerKeyProtector' -Parameters @{ MountPoint = $MountPoint; Recovery = [bool]$RecoveryPasswordProtector; Tpm = [bool]$TpmProtector }
    if ($RecoveryPasswordProtector) {
        $script:Fake.BitLocker.Protectors.Add([pscustomobject]@{
                KeyProtectorType = 'RecoveryPassword'; KeyProtectorId = '{8A2C9F41-3B7E-4D21-9C55-0E6F1A2B3C4D}'; RecoveryPassword = $script:FakeRecoveryPassword
            })
        # Like the real cmdlet, which prints the new recovery password in a warning.
        Write-Warning ('ACTIONS REQUIRED: save this numerical recovery password in a secure location: {0}' -f $script:FakeRecoveryPassword)
    }
    if ($TpmProtector) {
        $script:Fake.BitLocker.Protectors.Add([pscustomobject]@{ KeyProtectorType = 'Tpm'; KeyProtectorId = '{0D4C3B2A-1F6E-4C55-9D21-B7E3F41C9A28}'; RecoveryPassword = '' })
    }
    Get-FakeBitLockerVolume
}

function Remove-BitLockerKeyProtector {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$MountPoint, [string]$KeyProtectorId)
    Register-FakeCall -Name 'Remove-BitLockerKeyProtector' -Parameters @{ MountPoint = $MountPoint; KeyProtectorId = $KeyProtectorId }
    $keep = @($script:Fake.BitLocker.Protectors | Where-Object { $_.KeyProtectorId -ne $KeyProtectorId })
    $script:Fake.BitLocker.Protectors.Clear()
    foreach ($protector in $keep) { $script:Fake.BitLocker.Protectors.Add($protector) }
    Get-FakeBitLockerVolume
}

function Enable-BitLocker {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$MountPoint, [string]$EncryptionMethod, [switch]$UsedSpaceOnly, [switch]$TpmProtector, [switch]$SkipHardwareTest)
    Register-FakeCall -Name 'Enable-BitLocker' -Parameters @{
        MountPoint = $MountPoint; EncryptionMethod = $EncryptionMethod; UsedSpaceOnly = [bool]$UsedSpaceOnly
        TpmProtector = [bool]$TpmProtector; SkipHardwareTest = [bool]$SkipHardwareTest
    }
    $script:Fake.BitLocker.ProtectionStatus = 'On'
    $script:Fake.BitLocker.VolumeStatus = 'EncryptionInProgress'
    $script:Fake.BitLocker.EncryptionMethod = $EncryptionMethod
    if ($TpmProtector) {
        $script:Fake.BitLocker.Protectors.Add([pscustomobject]@{ KeyProtectorType = 'Tpm'; KeyProtectorId = '{0D4C3B2A-1F6E-4C55-9D21-B7E3F41C9A28}'; RecoveryPassword = '' })
    }
    Get-FakeBitLockerVolume
}

function Resume-BitLocker {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$MountPoint)
    Register-FakeCall -Name 'Resume-BitLocker' -Parameters @{ MountPoint = $MountPoint }
    $script:Fake.BitLocker.ProtectionStatus = 'On'
    Get-FakeBitLockerVolume
}

function BackupToAAD-BitLockerKeyProtector {
    [CmdletBinding()]
    param([string]$MountPoint, [string]$KeyProtectorId)
    Register-FakeCall -Name 'BackupToAAD-BitLockerKeyProtector' -Parameters @{ MountPoint = $MountPoint; KeyProtectorId = $KeyProtectorId }
    if ($script:Fake.EscrowFails) { throw 'The device is not connected to Entra ID (fake).' }
}

function Backup-BitLockerKeyProtector {
    [CmdletBinding()]
    param([string]$MountPoint, [string]$KeyProtectorId)
    Register-FakeCall -Name 'Backup-BitLockerKeyProtector' -Parameters @{ MountPoint = $MountPoint; KeyProtectorId = $KeyProtectorId }
    if ($script:Fake.EscrowFails) { throw 'The domain controller is not reachable (fake).' }
}

function Get-Tpm {
    [CmdletBinding()]
    param()
    Register-FakeCall -Name 'Get-Tpm'
    [pscustomobject]@{ TpmPresent = [bool]$script:Fake.Tpm.TpmPresent; TpmReady = [bool]$script:Fake.Tpm.TpmReady }
}

# ------------------------------------------------------------------ SMB

function Get-SmbServerConfiguration {
    [CmdletBinding()]
    param()
    Register-FakeCall -Name 'Get-SmbServerConfiguration'
    if ($script:Fake.Smb1.Throw) { throw 'The SMB server service is not running (fake).' }
    [pscustomobject]@{ EnableSMB1Protocol = [bool]$script:Fake.Smb1.Server }
}

function Set-SmbServerConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param([bool]$EnableSMB1Protocol, [switch]$Force)
    Register-FakeCall -Name 'Set-SmbServerConfiguration' -Parameters @{ EnableSMB1Protocol = $EnableSMB1Protocol; Force = [bool]$Force }
    $script:Fake.Smb1.Server = $EnableSMB1Protocol
}

function Get-WindowsOptionalFeature {
    [CmdletBinding()]
    param([switch]$Online, [string]$FeatureName)
    Register-FakeCall -Name 'Get-WindowsOptionalFeature' -Parameters @{ FeatureName = $FeatureName }
    [pscustomobject]@{ FeatureName = $FeatureName; State = $script:Fake.Smb1.Feature }
}

function Disable-WindowsOptionalFeature {
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Online, [string]$FeatureName, [switch]$NoRestart)
    Register-FakeCall -Name 'Disable-WindowsOptionalFeature' -Parameters @{ FeatureName = $FeatureName; NoRestart = [bool]$NoRestart }
    $script:Fake.Smb1.Feature = 'Disabled'
    [pscustomobject]@{ RestartNeeded = [bool]$script:Fake.Smb1.RestartNeeded }
}

# ------------------------------------------------------------------ Firewall

function Get-NetFirewallProfile {
    [CmdletBinding()]
    param()
    Register-FakeCall -Name 'Get-NetFirewallProfile'
    $script:Fake.Firewall.Profiles
}

function Set-NetFirewallProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Name, [string]$Enabled, [string]$DefaultInboundAction, [string]$DefaultOutboundAction, [string]$LogBlocked)
    Register-FakeCall -Name 'Set-NetFirewallProfile' -Parameters @{
        Name = $Name; Enabled = $Enabled; DefaultInboundAction = $DefaultInboundAction; DefaultOutboundAction = $DefaultOutboundAction; LogBlocked = $LogBlocked
    }
    foreach ($fwProfile in @($script:Fake.Firewall.Profiles | Where-Object { $Name -contains $_.Name })) {
        foreach ($setting in 'Enabled', 'DefaultInboundAction', 'DefaultOutboundAction', 'LogBlocked') {
            if ($PSBoundParameters.ContainsKey($setting)) { $fwProfile.$setting = $PSBoundParameters[$setting] }
        }
    }
}

function Get-NetFirewallRule {
    [CmdletBinding()]
    param([string]$DisplayName)
    Register-FakeCall -Name 'Get-NetFirewallRule' -Parameters @{ DisplayName = $DisplayName }
    if ($script:Fake.Firewall.Rules -contains $DisplayName) { [pscustomobject]@{ DisplayName = $DisplayName } }
}

function New-NetFirewallRule {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$DisplayName, [string]$Direction, [string]$Action, [Alias('Profile')][string]$RuleProfile, [string]$Group,
        [string]$Description, [string]$Protocol, [string[]]$LocalPort, [string[]]$RemotePort, [string[]]$RemoteAddress
    )
    Register-FakeCall -Name 'New-NetFirewallRule' -Parameters @{
        DisplayName = $DisplayName; Direction = $Direction; Action = $Action; Profile = $RuleProfile; Group = $Group
        Protocol = $Protocol; LocalPort = $LocalPort; RemotePort = $RemotePort; RemoteAddress = $RemoteAddress
    }
    if (@($script:Fake.Firewall.FailRules) -contains $DisplayName) { throw 'The parameter is incorrect (fake).' }
    $script:Fake.Firewall.Rules.Add($DisplayName)
}

# ------------------------------------------------------------------ Appx

function Get-AppxPackage {
    [CmdletBinding()]
    param([switch]$AllUsers, [string]$Name = '*')
    Register-FakeCall -Name 'Get-AppxPackage' -Parameters @{ Name = $Name; AllUsers = [bool]$AllUsers }
    @($script:Fake.Appx | Where-Object { $_.Name -like $Name })
}

function Remove-AppxPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Package, [switch]$AllUsers)
    Register-FakeCall -Name 'Remove-AppxPackage' -Parameters @{ Package = $Package; AllUsers = [bool]$AllUsers }
    $target = @($script:Fake.Appx | Where-Object { $_.PackageFullName -eq $Package }) | Select-Object -First 1
    if ($target -and @($script:Fake.AppxFail) -contains $target.Name) { throw 'Deployment failed with HRESULT: 0x80073CFA (fake).' }
    if ($target) { [void]$script:Fake.Appx.Remove($target) }
}

function Get-AppxProvisionedPackage {
    [CmdletBinding()]
    param([switch]$Online)
    Register-FakeCall -Name 'Get-AppxProvisionedPackage'
    $script:Fake.Provisioned.ToArray()
}

function Remove-AppxProvisionedPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Online, [string]$PackageName)
    Register-FakeCall -Name 'Remove-AppxProvisionedPackage' -Parameters @{ PackageName = $PackageName }
    $target = @($script:Fake.Provisioned | Where-Object { $_.PackageName -eq $PackageName }) | Select-Object -First 1
    if ($target) { [void]$script:Fake.Provisioned.Remove($target) }
}

# ------------------------------------------------------------------ printers

function Get-Printer {
    [CmdletBinding()]
    param([string]$Name)
    Register-FakeCall -Name 'Get-Printer' -Parameters @{ Name = $Name }
    @($script:Fake.Print.Printers | Where-Object { -not $Name -or $_.Name -eq $Name })
}

function Get-PrinterPort {
    [CmdletBinding()]
    param([string]$Name)
    Register-FakeCall -Name 'Get-PrinterPort' -Parameters @{ Name = $Name }
    @($script:Fake.Print.Ports | Where-Object { -not $Name -or $_.Name -eq $Name })
}

function Get-PrinterDriver {
    [CmdletBinding()]
    param([string]$Name)
    Register-FakeCall -Name 'Get-PrinterDriver' -Parameters @{ Name = $Name }
    $infPath = ''
    if ($script:Fake.Print.DriverInfs.ContainsKey($Name)) { $infPath = $script:Fake.Print.DriverInfs[$Name] }
    if ($script:Fake.Print.Drivers -contains $Name) { [pscustomobject]@{ Name = $Name; InfPath = $infPath } }
}

function Add-PrinterDriver {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name)
    Register-FakeCall -Name 'Add-PrinterDriver' -Parameters @{ Name = $Name }
    if ($script:Fake.Print.Staged -notcontains $Name) { throw 'The specified driver does not exist in the driver store (fake).' }
    $script:Fake.Print.Drivers.Add($Name)
}

function Add-PrinterPort {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$PrinterHostAddress, [int]$PortNumber)
    Register-FakeCall -Name 'Add-PrinterPort' -Parameters @{ Name = $Name; PrinterHostAddress = $PrinterHostAddress; PortNumber = $PortNumber }
    $script:Fake.Print.Ports.Add([pscustomobject]@{ Name = $Name; PrinterHostAddress = $PrinterHostAddress; PortNumber = $PortNumber })
}

function Add-Printer {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$DriverName, [string]$PortName, [string]$Location, [string]$Comment)
    Register-FakeCall -Name 'Add-Printer' -Parameters @{ Name = $Name; DriverName = $DriverName; PortName = $PortName; Location = $Location; Comment = $Comment }
    if ($script:Fake.Print.Drivers -notcontains $DriverName) { throw 'The printer driver is not installed (fake).' }
    $script:Fake.Print.Printers.Add([pscustomobject]@{ Name = $Name; Type = 'Local'; PortName = $PortName; DriverName = $DriverName; Location = $Location })
}

function Invoke-ZTPnpUtil {
    param([Parameter(Mandatory)][string]$InfPath)
    Register-FakeCall -Name 'Invoke-ZTPnpUtil' -Parameters @{ InfPath = $InfPath }
    if ($script:Fake.Print.PnpExitCode -eq 0) {
        foreach ($driver in @($script:Fake.Print.InfDrivers)) { $script:Fake.Print.Staged.Add($driver) }
    }
    [pscustomobject]@{ ExitCode = $script:Fake.Print.PnpExitCode; Output = @('Driver package added (fake).') }
}

# ------------------------------------------------------------------ drivers

function Test-ZTDriverSource {
    param([Parameter(Mandatory)][string]$Path)
    Register-FakeCall -Name 'Test-ZTDriverSource' -Parameters @{ Path = $Path }
    $script:Fake.Drivers.Available -contains $Path
}

function Invoke-ZTDriverInstall {
    param([Parameter(Mandatory)][string]$Path)
    Register-FakeCall -Name 'Invoke-ZTDriverInstall' -Parameters @{ Path = $Path }
    $code = 0
    if ($script:Fake.Drivers.ExitCodes.ContainsKey($Path)) { $code = [int]$script:Fake.Drivers.ExitCodes[$Path] }
    $output = @('Microsoft PnP Utility', 'Driver package added successfully.')
    if (@(0, 259, 3010) -notcontains $code) { $output = @('Microsoft PnP Utility', 'Failed to add driver package: Access is denied.') }
    [pscustomobject]@{ ExitCode = $code; Output = $output }
}

function Export-WindowsDriver {
    [CmdletBinding()]
    param([switch]$Online, [string]$Destination)
    Register-FakeCall -Name 'Export-WindowsDriver' -Parameters @{ Destination = $Destination; Online = [bool]$Online }
    $script:Fake.Drivers.ThirdParty
}

# ------------------------------------------------------------------ inventory

function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Namespace, [string]$Filter)
    Register-FakeCall -Name 'Get-CimInstance' -Parameters @{ ClassName = $ClassName; Namespace = $Namespace }
    if ($script:Fake.Cim.ContainsKey($ClassName)) { $script:Fake.Cim[$ClassName] }
}

function Confirm-SecureBootUEFI {
    [CmdletBinding()]
    param()
    Register-FakeCall -Name 'Confirm-SecureBootUEFI'
    if ($script:Fake.SecureBoot -eq 'Unsupported') { throw (New-Object -TypeName System.PlatformNotSupportedException -ArgumentList 'Cmdlet not supported on this platform.') }
    $script:Fake.SecureBoot -eq 'On'
}
