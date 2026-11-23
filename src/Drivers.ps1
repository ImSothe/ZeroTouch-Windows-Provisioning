#Requires -Version 5.1
# Drivers: per-model driver packs and the department's peripheral drivers, added with pnputil.
#
# Hardware drivers (chipset, graphics, network) depend on the PC model, not on the department: a
# model pack is only applied to a PC whose make and model match its folder exactly.
# Peripheral drivers (label printers, touch screens, USB-C/DisplayLink docks, signature pads, card
# readers...) belong to the department: they are added to the Windows driver store, so the device
# installs on its own whenever someone plugs it in, even a user without administrator rights.
# Drivers run first: a PC without its network driver cannot download any application.

$script:ZTDriverKeys = @('packs', 'peripherals')
$script:ZTPeripheralKeys = @('name', 'path')
# A full local or UNC path, without wildcards, quotes or other shell characters.
$script:ZTDriverPathPattern = '^([A-Za-z]:\\|\\\\[A-Za-z0-9._-]+\\)[^"*?<>|\r\n]*\z'
# pnputil exit codes that mean success: 0 done, 259 nothing new to add, 3010 done and a restart is advisable.
$script:ZTPnpSuccessCodes = @(0, 259, 3010)

# A make or model as a folder name: "HP/Compaq" -> "HP_Compaq".
function Get-ZTSafePathPart {
    param([AllowEmptyString()][string]$Value)
    $safe = (([string]$Value) -replace '[\\/:*?"<>|]', '_').Trim().Trim('.')
    if (-not $safe) { $safe = 'Unknown' }
    $safe
}

# <root>\<make>\<model>, used both to export a pack and to find it again on a new PC.
function Get-ZTDriverPackPath {
    param([Parameter(Mandatory)][string]$Root, [AllowEmptyString()][string]$Manufacturer, [AllowEmptyString()][string]$Model)
    $makeFolder = Join-Path -Path $Root -ChildPath (Get-ZTSafePathPart -Value $Manufacturer)
    Join-Path -Path $makeFolder -ChildPath (Get-ZTSafePathPart -Value $Model)
}

# Make and model as the handover form shows them (Lenovo's friendly name, not its machine type).
function Get-ZTDeviceModel {
    $system = Get-ZTCim -ClassName 'Win32_ComputerSystem' | Select-Object -First 1
    $product = Get-ZTCim -ClassName 'Win32_ComputerSystemProduct' | Select-Object -First 1
    $manufacturer = ''
    $model = ''
    if ($system) {
        $manufacturer = ([string]$system.Manufacturer).Trim()
        $model = ([string]$system.Model).Trim()
    }
    # Lenovo reports the machine type (11DT0040SP) as the model; the friendly name is in Version.
    if ($manufacturer -match '^LENOVO' -and $product -and ([string]$product.Version).Trim()) { $model = ([string]$product.Version).Trim() }
    [pscustomobject]@{ Manufacturer = $manufacturer; Model = $model }
}

# Small wrappers so that the test suite can replace them with fakes.
function Test-ZTDriverSource {
    param([Parameter(Mandatory)][string]$Path)
    Test-Path -LiteralPath $Path
}

function Invoke-ZTDriverInstall {
    param([Parameter(Mandatory)][string]$Path)
    $ErrorActionPreference = 'Continue'
    if ($Path -like '*.inf') { $arguments = @('/add-driver', $Path, '/install') }
    else { $arguments = @('/add-driver', (Join-Path -Path $Path -ChildPath '*.inf'), '/subdirs', '/install') }
    $output = @(& pnputil.exe @arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Output = $output }
}

function New-ZTDriverResult {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Model', 'Peripheral')][string]$Kind,
        [AllowEmptyString()][string]$Source = '',
        [Parameter(Mandatory)][ValidateSet('Installed', 'Failed', 'WhatIf', 'Skipped')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [object[]]$Arguments = @(),
        [switch]$RebootRequired
    )
    $text = @($Arguments | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        Name           = $Name
        Kind           = $Kind
        Source         = $Source
        Status         = $Status
        RebootRequired = [bool]$RebootRequired
        Message        = $Message
        Arguments      = $text
        Detail         = Format-ZTMessage -Key $Message -Arguments $text
    }
}

<#
.SYNOPSIS
    Adds one driver package (an .inf file, or a folder searched recursively) to the driver store.
#>
function Install-ZTDriverPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Model', 'Peripheral')][string]$Kind,
        [Parameter(Mandatory)][string]$Path
    )
    if ($Path -notmatch $script:ZTDriverPathPattern) { throw ("Invalid driver path '{0}'." -f $Path) }
    if (-not (Test-ZTDriverSource -Path $Path)) {
        return New-ZTDriverResult -Name $Name -Kind $Kind -Source $Path -Status 'Failed' -Message 'driver.unreachable' -Arguments @($Path)
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Add drivers to the Windows driver store (pnputil)')) {
        return New-ZTDriverResult -Name $Name -Kind $Kind -Source $Path -Status 'WhatIf' -Message 'driver.whatIf' -Arguments @($Path)
    }
    $run = Invoke-ZTDriverInstall -Path $Path
    if ($script:ZTPnpSuccessCodes -notcontains $run.ExitCode) {
        $reason = [string](@($run.Output) | Select-Object -Last 1)
        return New-ZTDriverResult -Name $Name -Kind $Kind -Source $Path -Status 'Failed' -Message 'driver.failed' -Arguments @($run.ExitCode, $reason)
    }
    New-ZTDriverResult -Name $Name -Kind $Kind -Source $Path -Status 'Installed' -Message 'driver.installed' -Arguments @($Path) -RebootRequired:($run.ExitCode -eq 3010)
}

<#
.SYNOPSIS
    Applies the drivers section of a profile: the pack for this exact make and model, if there is one,
    then the department's peripheral drivers. Returns one result per pack or peripheral.
#>
function Invoke-ZTDrivers {
    [CmdletBinding(SupportsShouldProcess)]
    param([AllowNull()]$Settings, [AllowEmptyString()][string]$Manufacturer, [AllowEmptyString()][string]$Model)
    $config = ConvertTo-ZTHashtable -InputObject $Settings
    if ($config -isnot [System.Collections.IDictionary]) { return }

    $root = [string]$config['packs']
    if ($root) {
        $name = ('{0} {1}' -f $Manufacturer, $Model).Trim()
        $packPath = Get-ZTDriverPackPath -Root $root -Manufacturer $Manufacturer -Model $Model
        if (-not (Test-ZTDriverSource -Path $root)) {
            New-ZTDriverResult -Name $name -Kind 'Model' -Source $root -Status 'Failed' -Message 'driver.unreachable' -Arguments @($root)
        }
        elseif (-not (Test-ZTDriverSource -Path $packPath)) {
            New-ZTDriverResult -Name $name -Kind 'Model' -Source $packPath -Status 'Skipped' -Message 'driver.noPack' -Arguments @($packPath)
        }
        else {
            try {
                Install-ZTDriverPackage -Name $name -Kind 'Model' -Path $packPath
            }
            catch {
                New-ZTDriverResult -Name $name -Kind 'Model' -Source $packPath -Status 'Failed' -Message 'driver.error' -Arguments @($_.Exception.Message)
            }
        }
    }

    foreach ($peripheral in @($config['peripherals'] | Where-Object { $null -ne $_ })) {
        $name = ([string]$peripheral['name']).Trim()
        $path = ([string]$peripheral['path']).Trim()
        try {
            Install-ZTDriverPackage -Name $name -Kind 'Peripheral' -Path $path
        }
        catch {
            New-ZTDriverResult -Name $name -Kind 'Peripheral' -Source $path -Status 'Failed' -Message 'driver.error' -Arguments @($_.Exception.Message)
        }
    }
}

<#
.SYNOPSIS
    Exports this PC's third-party drivers to <Root>\<make>\<model> (used on a reference PC).
#>
function Export-ZTDriverPack {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Root)
    $device = Get-ZTDeviceModel
    $target = Get-ZTDriverPackPath -Root $Root -Manufacturer $device.Manufacturer -Model $device.Model
    $result = [ordered]@{ Manufacturer = $device.Manufacturer; Model = $device.Model; Path = $target; Count = 0; Classes = ''; Exported = $false }
    if ($PSCmdlet.ShouldProcess($target, "Export this PC's third-party drivers")) {
        [void][System.IO.Directory]::CreateDirectory($target)
        $drivers = @(Export-WindowsDriver -Online -Destination $target -ErrorAction Stop)
        $result['Count'] = $drivers.Count
        $result['Classes'] = (@($drivers | ForEach-Object { [string]$_.ClassName } | Where-Object { $_ } | Sort-Object -Unique)) -join ', '
        $result['Exported'] = $true
    }
    [pscustomobject]$result
}

<#
.SYNOPSIS
    Copies the driver package of an installed printer driver to <Root>\Printers\<driver> and returns
    the path of its .inf, for the profile's driverInf. Drivers that ship with Windows return nothing.
#>
function Export-ZTPrinterDriver {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$DriverName, [Parameter(Mandatory)][string]$Root)
    $driver = @(Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $driver -or -not ([string]$driver.InfPath)) { return $null }
    $inf = [string]$driver.InfPath
    $leaf = Split-Path -Path $inf -Leaf
    if ($leaf -like 'ntprint*.inf' -or $leaf -like 'prnms*.inf') { return $null }
    $target = Join-Path -Path (Join-Path -Path $Root -ChildPath 'Printers') -ChildPath (Get-ZTSafePathPart -Value $DriverName)
    if ($PSCmdlet.ShouldProcess($target, 'Copy the printer driver package')) {
        [void][System.IO.Directory]::CreateDirectory($target)
        Copy-Item -Path (Join-Path -Path (Split-Path -Path $inf -Parent) -ChildPath '*') -Destination $target -Recurse -Force -ErrorAction Stop
    }
    Join-Path -Path $target -ChildPath $leaf
}
