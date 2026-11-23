#Requires -Version 5.1
# A fixed, fictional provisioning run (Demo Corp, a shop floor PC) used for the sample handover
# forms in docs\ and by the tests. Needs the source files to be loaded first (Format-ZTMessage).

function New-ZTSampleResult {
    param([string]$Control, [string]$Status, [string]$Message, [string[]]$Arguments = @(), [switch]$RebootRequired)
    [pscustomobject]@{
        Control        = $Control
        Status         = $Status
        Message        = $Message
        Arguments      = @($Arguments)
        Detail         = Format-ZTMessage -Key $Message -Arguments $Arguments
        RebootRequired = [bool]$RebootRequired
    }
}

function New-ZTSampleApp {
    param([string]$Id, [string]$Name, [string]$Status, [string]$Version, [string]$Message, [string[]]$Arguments = @(), [switch]$Optional)
    $exitCode = 0
    if ($Status -eq 'Failed') { $exitCode = [Convert]::ToInt32('8A150008', 16) }
    [pscustomobject]@{
        Id             = $Id
        Name           = $Name
        Required       = -not $Optional
        Status         = $Status
        Version        = $Version
        ExitCode       = $exitCode
        Attempts       = 1
        RebootRequired = $false
        Message        = $Message
        Arguments      = @($Arguments)
        Detail         = Format-ZTMessage -Key $Message -Arguments $Arguments
    }
}

function New-ZTSamplePrinter {
    param([string]$Name, [string]$Address, [string]$Driver, [string]$Status, [string]$Message)
    [pscustomobject]@{
        Name           = $Name
        Address        = $Address
        Driver         = $Driver
        Status         = $Status
        RebootRequired = $false
        Message        = $Message
        Arguments      = @($Address, $Driver)
        Detail         = Format-ZTMessage -Key $Message -Arguments @($Address, $Driver)
    }
}

function New-ZTSampleRun {
    param([ValidateSet('en', 'es')][string]$Language = 'en')
    # Accented characters are built from code points: source files stay ASCII (see src\Common.ps1).
    $a = [char]0x00E1
    $i = [char]0x00ED
    if ($Language -eq 'es') {
        $displayName = 'Taller'
        $description = 'Puesto de planta: planos, programas CNC y transferencia de ficheros a las m{0}quinas.' -f $a
        $contact = 'Soporte TI (ext. 200)'
        $notes = 'Se entrega con teclado, monitor de 24 pulgadas y cable de red.'
    }
    else {
        $displayName = 'Shop floor'
        $description = 'Shop floor PC: drawings, CNC programs and file transfer to the machines.'
        $contact = 'IT helpdesk (ext. 200)'
        $notes = 'Delivered with keyboard, 24-inch monitor and network cable.'
    }
    $rules = 'ZT - Block inbound SMB on public networks; ZT - Block inbound RDP on public networks; ZT - Allow DNC from the machine network'
    $removed = 'Microsoft.BingNews, Microsoft.GamingApp, Microsoft.XboxGamingOverlay, MicrosoftTeams, Clipchamp.Clipchamp, Microsoft.549981C3F5F10'

    [pscustomobject]@{
        SchemaVersion = 1
        Tool          = 'ZeroTouch'
        ToolVersion   = $script:ZTVersion
        FormId        = 'ZT-20261123-093015-PC-TALLER-07'
        GeneratedAt   = '2026-11-23T09:30:15'
        Simulation    = $false
        Language      = $Language
        Profile       = [pscustomobject]@{ Name = 'taller'; DisplayName = $displayName; Description = $description }
        Organization  = [pscustomobject]@{ Name = 'Demo Corp S.L.'; ItContact = $contact }
        AssignedUser  = 'Luc{0}a Mart{0}n' -f $i
        Technician    = 'Sothe'
        Notes         = $notes
        Device        = [pscustomobject]@{
            ComputerName    = 'PC-TALLER-07'
            Manufacturer    = 'LENOVO'
            Model           = 'ThinkCentre M70q Gen 3'
            SerialNumber    = 'PF3K7Q2M'
            Chassis         = 'Desktop'
            BiosVersion     = 'M4AKT3AA'
            Processor       = 'Intel(R) Core(TM) i5-12500T'
            MemoryGB        = 16
            SystemDrive     = 'C:'
            DiskSizeGB      = 476
            DiskFreeGB      = 431
            OperatingSystem = 'Windows 11 Pro'
            OsVersion       = '24H2 (26100.2314)'
            IPAddress       = '192.168.20.41'
            MacAddress      = '8C:16:45:2A:7B:91'
            JoinType        = 'Hybrid'
            TpmVersion      = '2.0'
            TpmReady        = $true
            SecureBoot      = 'On'
            Antivirus       = 'Windows Defender'
            LoggedOnUser    = ''
            CollectedAt     = '2026-11-23T09:41:52'
        }
        Applications  = @(
            (New-ZTSampleApp -Id '7zip.7zip' -Name '7-Zip' -Status 'AlreadyInstalled' -Version '24.08' -Message 'app.alreadyInstalled'),
            (New-ZTSampleApp -Id 'Google.Chrome' -Name 'Google Chrome' -Status 'Installed' -Version '131.0.6778.86' -Message 'app.installed'),
            (New-ZTSampleApp -Id 'SumatraPDF.SumatraPDF' -Name 'SumatraPDF' -Status 'Installed' -Version '3.5.2' -Message 'app.installed'),
            (New-ZTSampleApp -Id 'Notepad++.Notepad++' -Name 'Notepad++' -Status 'Installed' -Version '8.7.1' -Message 'app.installed'),
            (New-ZTSampleApp -Id 'WinSCP.WinSCP' -Name 'WinSCP' -Status 'Installed' -Version '6.3.5' -Message 'app.installed'),
            (New-ZTSampleApp -Id 'TheDocumentFoundation.LibreOffice' -Name 'LibreOffice' -Status 'Installed' -Version '24.8.3.2' -Message 'app.installed'),
            (New-ZTSampleApp -Id 'LibreCAD.LibreCAD' -Name 'LibreCAD' -Status 'Failed' -Version '' -Message 'app.failed.DownloadFailed' -Arguments @('0x8A150008', 'Download failed.') -Optional)
        )
        Printers      = @(
            (New-ZTSamplePrinter -Name 'Taller - Impresora de planta' -Address '192.168.50.20' -Driver 'HP Universal Printing PCL 6' -Status 'Installed' -Message 'printer.installed')
        )
        Security      = @(
            (New-ZTSampleResult -Control 'BitLocker' -Status 'Compliant' -Message 'bitlocker.on' -Arguments @('C:', 'XtsAes256', '100')),
            (New-ZTSampleResult -Control 'SMBv1' -Status 'Remediated' -Message 'smb1.disabled' -RebootRequired),
            (New-ZTSampleResult -Control 'Firewall' -Status 'Remediated' -Message 'firewall.fixed' -Arguments @('Domain, Private, Public', 'Block', 'Allow')),
            (New-ZTSampleResult -Control 'FirewallRules' -Status 'Remediated' -Message 'firewallRules.created' -Arguments @('3', $rules, '0')),
            (New-ZTSampleResult -Control 'Bloatware' -Status 'Remediated' -Message 'bloatware.removed' -Arguments @('6', $removed))
        )
        Outcome       = [pscustomobject]@{ Status = 'Warning'; ExitCode = 3010; RebootRequired = $true }
    }
}
