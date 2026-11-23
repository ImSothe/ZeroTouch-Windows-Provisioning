#Requires -Version 5.1
# End-to-end provisioning: profile -> applications -> printers -> security baseline -> inventory -> handover form.

$script:ZTRegistryKey = 'HKLM:\SOFTWARE\ZeroTouch'

# Overall result and process exit code, using the codes Intune understands for Win32 apps:
#   0     success
#   3010  success, restart required (soft reboot)
#   1     failure (a required application or a security control failed)
# A printer that could not be added is a note on the form, not a failure: retrying would not fix a
# missing driver.
function Get-ZTOutcome {
    param([object[]]$Applications = @(), [object[]]$Security = @(), [object[]]$Printers = @(), [switch]$Simulation)
    $apps = @($Applications | Where-Object { $null -ne $_ })
    $controls = @($Security | Where-Object { $null -ne $_ })
    $queues = @($Printers | Where-Object { $null -ne $_ })
    $reboot = @(@($apps) + @($controls) | Where-Object { $_.RebootRequired }).Count -gt 0
    $failedRequired = @($apps | Where-Object { $_.Status -eq 'Failed' -and $_.Required }).Count
    $failedOptional = @($apps | Where-Object { $_.Status -eq 'Failed' -and -not $_.Required }).Count
    $failedControls = @($controls | Where-Object { $_.Status -eq 'Failed' }).Count
    $attention = @($controls | Where-Object { $_.Status -eq 'NonCompliant' }).Count + @($queues | Where-Object { $_.Status -eq 'Failed' }).Count

    if ($Simulation) { $status = 'Simulation'; $exitCode = 0 }
    elseif ($failedRequired -gt 0 -or $failedControls -gt 0) { $status = 'Failed'; $exitCode = 1 }
    elseif ($failedOptional -gt 0 -or $attention -gt 0) { $status = 'Warning'; $exitCode = 0 }
    else { $status = 'Success'; $exitCode = 0 }
    if ($exitCode -eq 0 -and $reboot -and -not $Simulation) { $exitCode = 3010 }
    [pscustomobject]@{ Status = $status; ExitCode = $exitCode; RebootRequired = [bool]$reboot }
}

# Detection marker for Intune (Win32 app detection rule) and for support staff.
function Set-ZTRegistryMarker {
    param([Parameter(Mandatory)]$Run, [string]$ReportPath)
    if (-not (Test-Path -LiteralPath $script:ZTRegistryKey)) { New-Item -Path $script:ZTRegistryKey -Force | Out-Null }
    $values = [ordered]@{
        Profile     = [string]$Run.Profile.Name
        Status      = [string]$Run.Outcome.Status
        ExitCode    = [string]$Run.Outcome.ExitCode
        LastRun     = [string]$Run.GeneratedAt
        ToolVersion = [string]$Run.ToolVersion
        FormId      = [string]$Run.FormId
        ReportPath  = [string]$ReportPath
    }
    foreach ($name in $values.Keys) {
        New-ItemProperty -Path $script:ZTRegistryKey -Name $name -Value $values[$name] -PropertyType String -Force | Out-Null
    }
}

<#
.SYNOPSIS
    Provisions this computer for a department and writes its handover form.
.OUTPUTS
    The run object (also saved as the JSON twin of the form) plus ReportPaths, LogPath and ExitCode.
#>
function Invoke-ZTProvisioning {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Department,
        [string]$ProfilesPath = $script:ZTProfilesPath,
        [AllowEmptyString()][string]$AssignedUser = '',
        [AllowEmptyString()][string]$Technician = '',
        [string]$OutputPath = (Join-Path -Path ([string]$env:ProgramData) -ChildPath 'ZeroTouch'),
        [AllowEmptyString()][string]$Language = '',
        [AllowEmptyString()][string]$Notes = '',
        [switch]$SkipApplications,
        [switch]$SkipPrinters,
        [switch]$SkipSecurity,
        [switch]$Pdf,
        [ValidateRange(0, 600)][int]$RetryDelaySeconds = 20
    )
    $simulation = [bool]$WhatIfPreference
    $started = Get-Date
    $outputFolder = Resolve-ZTPath -Path $OutputPath

    # 1. Profile (first: a typo in the department name must fail before anything happens).
    if ($Department -match '[\\/]' -or $Department -match '\.json$') {
        $profileData = Get-ZTProfile -Path $Department
    }
    else {
        $profileData = Get-ZTProfile -Name $Department -ProfilesPath $ProfilesPath
    }

    $computer = Get-ZTSafeName -Value $env:COMPUTERNAME
    $stamp = $started.ToString('yyyyMMdd-HHmmss')
    Start-ZTLog -Path (Join-Path -Path $outputFolder -ChildPath ('Logs\ZeroTouch-{0}-{1}.log' -f $computer, $stamp))
    Write-ZTLog ('ZeroTouch {0} - computer {1} - department {2}' -f $script:ZTVersion, $env:COMPUTERNAME, $profileData['name']) -Level Step
    Write-ZTLog ('Profile chain: {0}' -f (($profileData['sourceFiles'] | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) }) -join ' <- '))
    if ($simulation) { Write-ZTLog 'SIMULATION (-WhatIf): nothing on this computer will be changed.' -Level Warning }

    if (-not (Test-ZTIsAdmin)) {
        if (-not $simulation) { throw 'Run ZeroTouch as administrator (or as SYSTEM, for example from Intune).' }
        Write-ZTLog 'Not running as administrator: some checks will fail in the simulation.' -Level Warning
    }

    $organization = $profileData['organization']
    if ($organization -isnot [System.Collections.IDictionary]) { $organization = @{} }
    if (-not $Language) { $Language = [string]$organization['language'] }
    if (-not $Language) { $Language = 'en' }
    if ($script:ZTLanguages -notcontains $Language) {
        Write-ZTLog ("Language '{0}' is not available; using English." -f $Language) -Level Warning
        $Language = 'en'
    }
    if (-not $Technician) {
        if (Test-ZTIsSystem) { $Technician = 'ZeroTouch (SYSTEM)' } else { $Technician = [string]$env:USERNAME }
    }

    # 2. Applications
    $appResults = New-Object -TypeName System.Collections.Generic.List[object]
    $apps = @($profileData['applications'])
    if ($SkipApplications) {
        Write-ZTLog 'Applications: skipped (-SkipApplications).' -Level Warning
    }
    elseif ($apps.Count -gt 0) {
        Write-ZTLog ('Applications: {0} in the profile.' -f $apps.Count) -Level Step
        $wingetReady = $true
        try {
            $wingetVersion = Invoke-ZTWinget -ArgumentList @('--version')
            Write-ZTLog ('winget {0}' -f (@($wingetVersion.Output) -join ' '))
        }
        catch {
            $wingetReady = $false
            Write-ZTLog $_.Exception.Message -Level Error
        }
        $index = 0
        foreach ($app in $apps) {
            $index++
            if (-not $wingetReady) {
                $appResults.Add((New-ZTAppResult -Application $app -Status 'Failed' -Message 'app.wingetMissing'))
                continue
            }
            try {
                $result = Install-ZTApplication -Application $app -RetryDelaySeconds $RetryDelaySeconds
            }
            catch {
                $result = New-ZTAppResult -Application $app -Status 'Failed' -Message 'app.failed.other' -Arguments @('-', $_.Exception.Message)
            }
            $level = 'Success'
            if ($result.Status -eq 'Failed') { $level = 'Error' } elseif ($result.Status -eq 'WhatIf') { $level = 'Info' }
            Write-ZTLog ('[{0}/{1}] {2} ({3}): {4} - {5}' -f $index, $apps.Count, $result.Name, $result.Id, $result.Status, $result.Detail) -Level $level
            $appResults.Add($result)
        }
    }

    # 3. Network printers
    $printerResults = New-Object -TypeName System.Collections.Generic.List[object]
    $printers = @($profileData['printers'] | Where-Object { $null -ne $_ })
    if ($SkipPrinters) {
        Write-ZTLog 'Printers: skipped (-SkipPrinters).' -Level Warning
    }
    elseif ($printers.Count -gt 0) {
        Write-ZTLog ('Printers: {0} in the profile.' -f $printers.Count) -Level Step
        foreach ($printer in $printers) {
            try {
                $result = Install-ZTPrinter -Printer $printer
            }
            catch {
                $result = New-ZTPrinterResult -Printer (ConvertTo-ZTPrinterDefinition -InputObject $printer) -Status 'Failed' -Message 'printer.error' -Arguments @($_.Exception.Message)
            }
            $level = 'Success'
            if ($result.Status -eq 'Failed') { $level = 'Warning' } elseif ($result.Status -eq 'WhatIf') { $level = 'Info' }
            Write-ZTLog ('Printer {0} ({1}): {2} - {3}' -f $result.Name, $result.Address, $result.Status, $result.Detail) -Level $level
            $printerResults.Add($result)
        }
    }

    # 4. Security baseline
    $securityResults = @()
    if ($SkipSecurity) {
        Write-ZTLog 'Security baseline: skipped (-SkipSecurity).' -Level Warning
    }
    else {
        Write-ZTLog 'Security baseline' -Level Step
        $securityResults = @(Invoke-ZTSecurityBaseline -Settings $profileData['security'])
        foreach ($result in $securityResults) {
            $level = 'Success'
            if ($result.Status -eq 'Failed') { $level = 'Error' } elseif ($result.Status -eq 'NonCompliant') { $level = 'Warning' } elseif ($result.Status -ne 'Compliant' -and $result.Status -ne 'Remediated') { $level = 'Info' }
            Write-ZTLog ('{0}: {1} - {2}' -f $result.Control, $result.Status, $result.Detail) -Level $level
        }
    }

    # 5. Inventory and outcome
    Write-ZTLog 'Inventory' -Level Step
    $device = Get-ZTDeviceInfo
    $outcome = Get-ZTOutcome -Applications $appResults.ToArray() -Security $securityResults -Printers $printerResults.ToArray() -Simulation:$simulation
    $run = [pscustomobject]@{
        SchemaVersion = 1
        Tool          = 'ZeroTouch'
        ToolVersion   = $script:ZTVersion
        FormId        = 'ZT-{0}-{1}' -f $stamp, (Get-ZTSafeName -Value $device.ComputerName)
        GeneratedAt   = $started.ToString('s')
        Simulation    = $simulation
        Language      = $Language
        Profile       = [pscustomobject]@{ Name = [string]$profileData['name']; DisplayName = [string]$profileData['displayName']; Description = [string]$profileData['description'] }
        Organization  = [pscustomobject]@{ Name = [string]$organization['name']; ItContact = [string]$organization['itContact'] }
        AssignedUser  = $AssignedUser
        Technician    = $Technician
        Notes         = $Notes
        Device        = $device
        Applications  = $appResults.ToArray()
        Printers      = $printerResults.ToArray()
        Security      = $securityResults
        Outcome       = $outcome
    }

    # 6. Handover form and detection marker
    $report = New-ZTHandoverReport -Run $run -OutputDirectory (Join-Path -Path $outputFolder -ChildPath 'Reports') -Pdf:$Pdf
    Write-ZTLog ('Handover form: {0}' -f $report.HtmlPath) -Level Step
    if ($report.PdfPath) { Write-ZTLog ('PDF: {0}' -f $report.PdfPath) }
    if ($PSCmdlet.ShouldProcess($script:ZTRegistryKey, 'Record the provisioning result')) {
        try {
            Set-ZTRegistryMarker -Run $run -ReportPath $report.HtmlPath
        }
        catch {
            Write-ZTLog ('Could not write the registry marker: {0}' -f $_.Exception.Message) -Level Warning
        }
    }

    $level = 'Success'
    if ($outcome.Status -eq 'Failed') { $level = 'Error' } elseif ($outcome.Status -ne 'Success') { $level = 'Warning' }
    Write-ZTLog ('Result: {0} (exit code {1}) in {2:N0} s.' -f $outcome.Status, $outcome.ExitCode, ((Get-Date) - $started).TotalSeconds) -Level $level
    if ($outcome.RebootRequired) { Write-ZTLog 'Restart the computer to finish.' -Level Warning }

    $run | Add-Member -NotePropertyName ReportPaths -NotePropertyValue $report
    $run | Add-Member -NotePropertyName LogPath -NotePropertyValue $script:ZTLogFile
    $run | Add-Member -NotePropertyName ExitCode -NotePropertyValue $outcome.ExitCode
    $run
}
