#Requires -Version 5.1
# Department network printers (Standard TCP/IP port), installed for the whole machine.
#
# Only network printers are handled. They work when ZeroTouch runs as SYSTEM (Intune) and every
# user of the PC sees them. Printers shared from a print server (\\server\queue) are per-user
# connections, and USB printers belong to one desk: both are left to Group Policy, Universal Print
# or the technician, and are skipped (with a message) when a reference PC is captured.

$script:ZTPrinterKeys = @('name', 'address', 'driver', 'driverInf', 'port', 'location', 'comment')
$script:ZTPrinterNamePattern = '^[^\[\]*?\\,"]{1,200}\z'
$script:ZTPrinterAddressPattern = '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z'
# A driver package on a local drive or a share: C:\Drivers\x\hpcu270u.inf or \\server\drivers\x\hpcu270u.inf
$script:ZTInfPathPattern = '^([A-Za-z]:\\|\\\\[A-Za-z0-9._-]+\\)[^"*?<>|\r\n]+\.inf\z'

function ConvertTo-ZTPrinterDefinition {
    param([AllowNull()]$InputObject)
    $source = ConvertTo-ZTHashtable -InputObject $InputObject
    if ($source -isnot [System.Collections.IDictionary]) { $source = @{} }
    $port = 9100
    if ($source.Contains('port') -and ([string]$source['port']).Trim()) {
        $parsed = 0
        if ([int]::TryParse([string]$source['port'], [ref]$parsed)) { $port = $parsed } else { $port = 0 }
    }
    [ordered]@{
        name      = ([string]$source['name']).Trim()
        address   = ([string]$source['address']).Trim()
        driver    = ([string]$source['driver']).Trim()
        driverInf = ([string]$source['driverInf']).Trim()
        port      = $port
        location  = [string]$source['location']
        comment   = [string]$source['comment']
    }
}

function New-ZTPrinterResult {
    param(
        [Parameter(Mandatory)]$Printer,
        [Parameter(Mandatory)][ValidateSet('Installed', 'AlreadyInstalled', 'Failed', 'WhatIf')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [object[]]$Arguments = @()
    )
    $text = @($Arguments | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        Name           = [string]$Printer['name']
        Address        = [string]$Printer['address']
        Driver         = [string]$Printer['driver']
        Status         = $Status
        RebootRequired = $false
        Message        = $Message
        Arguments      = $text
        Detail         = Format-ZTMessage -Key $Message -Arguments $text
    }
}

# Stages a driver package in the Windows driver store (needs administrator rights).
function Invoke-ZTPnpUtil {
    param([Parameter(Mandatory)][string]$InfPath)
    $ErrorActionPreference = 'Continue'
    $output = @(& pnputil.exe /add-driver $InfPath /install 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Output = $output }
}

<#
.SYNOPSIS
    Adds one network printer: driver (from the driver store, or staged from driverInf), TCP/IP port, queue.
    A printer that already exists with the same name is left alone.
#>
function Install-ZTPrinter {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Printer)
    $p = ConvertTo-ZTPrinterDefinition -InputObject $Printer
    if ($p['name'] -notmatch $script:ZTPrinterNamePattern -or $p['address'] -notmatch $script:ZTPrinterAddressPattern -or -not $p['driver']) {
        throw ("Invalid printer definition '{0}' ({1})." -f $p['name'], $p['address'])
    }
    if (-not (Test-ZTCommand -Name 'Get-Printer')) {
        return New-ZTPrinterResult -Printer $p -Status 'Failed' -Message 'printer.unavailable'
    }
    if (Get-Printer -Name $p['name'] -ErrorAction SilentlyContinue) {
        return New-ZTPrinterResult -Printer $p -Status 'AlreadyInstalled' -Message 'printer.present'
    }
    $driverReady = [bool](Get-PrinterDriver -Name $p['driver'] -ErrorAction SilentlyContinue)
    if (-not $PSCmdlet.ShouldProcess(('{0} ({1})' -f $p['name'], $p['address']), 'Add network printer')) {
        $messageKey = 'printer.whatIf'
        if (-not $driverReady) { $messageKey = 'printer.whatIfDriver' }
        return New-ZTPrinterResult -Printer $p -Status 'WhatIf' -Message $messageKey -Arguments @($p['address'], $p['driver'])
    }

    if (-not $driverReady) {
        if ($p['driverInf']) {
            $staged = Invoke-ZTPnpUtil -InfPath $p['driverInf']
            # pnputil: 0 = added, 3010 = added and a restart is advisable, 259 = already in the store.
            if (@(0, 259, 3010) -notcontains $staged.ExitCode) {
                Write-ZTLog ('Printer {0}: pnputil returned {1} for {2}.' -f $p['name'], $staged.ExitCode, $p['driverInf']) -Level Warning
            }
        }
        try {
            Add-PrinterDriver -Name $p['driver'] -ErrorAction Stop
        }
        catch {
            Write-ZTLog ('Printer {0}: {1}' -f $p['name'], $_.Exception.Message) -Level Warning
            return New-ZTPrinterResult -Printer $p -Status 'Failed' -Message 'printer.driverMissing' -Arguments @($p['driver'])
        }
    }

    $portName = 'IP_' + $p['address']
    if ($p['port'] -ne 9100) { $portName = '{0}_{1}' -f $portName, $p['port'] }
    if (-not (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {
        Add-PrinterPort -Name $portName -PrinterHostAddress $p['address'] -PortNumber $p['port'] -ErrorAction Stop
    }
    $parameters = @{ Name = $p['name']; DriverName = $p['driver']; PortName = $portName; ErrorAction = 'Stop' }
    if ($p['location']) { $parameters['Location'] = $p['location'] }
    if ($p['comment']) { $parameters['Comment'] = $p['comment'] }
    Add-Printer @parameters
    New-ZTPrinterResult -Printer $p -Status 'Installed' -Message 'printer.installed' -Arguments @($p['address'], $p['driver'])
}

<#
.SYNOPSIS
    The network printers of this computer, as profile entries (used to capture a reference PC).
    Print server connections, USB/WSD printers and virtual printers (PDF, XPS, OneNote) are skipped.
#>
function Get-ZTNetworkPrinter {
    if (-not (Test-ZTCommand -Name 'Get-Printer')) { return }
    $ports = @{}
    foreach ($port in @(Get-PrinterPort -ErrorAction SilentlyContinue)) { $ports[[string]$port.Name] = $port }
    foreach ($printer in @(Get-Printer -ErrorAction SilentlyContinue)) {
        $name = [string]$printer.Name
        if ([string]$printer.Type -eq 'Connection') {
            Write-ZTLog ("Printer '{0}' is a print server connection (per user): deploy it with Group Policy or Universal Print." -f $name) -Level Warning
            continue
        }
        $port = $ports[[string]$printer.PortName]
        $address = ''
        if ($port -and $port.PSObject.Properties.Name -contains 'PrinterHostAddress') { $address = ([string]$port.PrinterHostAddress).Trim() }
        if (-not $address) {
            Write-Verbose ("Printer '{0}' is not a TCP/IP network printer (port {1}); skipped." -f $name, $printer.PortName)
            continue
        }
        if ($name -notmatch $script:ZTPrinterNamePattern -or $address -notmatch $script:ZTPrinterAddressPattern) {
            Write-ZTLog ("Printer '{0}' has a name or address ZeroTouch cannot use; skipped." -f $name) -Level Warning
            continue
        }
        $entry = [ordered]@{ name = $name; address = $address; driver = [string]$printer.DriverName }
        if ($port.PSObject.Properties.Name -contains 'PortNumber' -and $port.PortNumber -and [int]$port.PortNumber -ne 9100) { $entry['port'] = [int]$port.PortNumber }
        if (([string]$printer.Location).Trim()) { $entry['location'] = ([string]$printer.Location).Trim() }
        $entry
    }
}
