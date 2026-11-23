#Requires -Version 5.1
# Security baseline: BitLocker, SMBv1, Windows Firewall and preinstalled consumer apps.
# Every control reads the current state first, changes only what differs from the profile,
# honours -WhatIf, and returns result objects instead of throwing.

<#
.SYNOPSIS
    Applies the security section of a profile and returns one result per control.
#>
function Invoke-ZTSecurityBaseline {
    [CmdletBinding(SupportsShouldProcess)]
    param([AllowNull()]$Settings)
    $config = ConvertTo-ZTHashtable -InputObject $Settings
    if ($config -isnot [System.Collections.IDictionary]) { $config = @{} }

    if ($config.Contains('bitlocker')) {
        Invoke-ZTControl -Control 'BitLocker' -Value $config['bitlocker'] -Action { Invoke-ZTBitLockerControl -Settings $config['bitlocker'] }
    }
    if ($config.Contains('disableSmb1')) {
        Invoke-ZTControl -Control 'SMBv1' -Value $config['disableSmb1'] -Action { Invoke-ZTSmb1Control }
    }
    if ($config.Contains('firewall')) {
        Invoke-ZTControl -Control 'Firewall' -Value $config['firewall'] -Action { Invoke-ZTFirewallControl -Settings $config['firewall'] }
        $rules = @()
        if ($config['firewall'] -is [System.Collections.IDictionary]) { $rules = @($config['firewall']['rules'] | Where-Object { $null -ne $_ }) }
        if ($rules.Count -gt 0) {
            Invoke-ZTControl -Control 'FirewallRules' -Value $true -Action { Invoke-ZTFirewallRuleControl -Rules $rules }
        }
    }
    if ($config.Contains('removeBloatware')) {
        $patterns = @($config['removeBloatware'] | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($patterns.Count -gt 0) {
            Invoke-ZTControl -Control 'Bloatware' -Value $true -Action { Invoke-ZTBloatwareControl -Patterns $patterns }
        }
    }
}

# Runs one control; a control set to false in the profile is reported as Skipped, and an
# exception becomes a Failed result so that the other controls still run.
function Invoke-ZTControl {
    param(
        [Parameter(Mandatory)][string]$Control,
        [AllowNull()]$Value,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if ($Value -is [bool] -and -not $Value) {
        return New-ZTResult -Control $Control -Status 'Skipped' -Message 'control.disabled'
    }
    try {
        & $Action
    }
    catch {
        Write-ZTLog ('{0}: {1}' -f $Control, $_.Exception.Message) -Level Error
        New-ZTResult -Control $Control -Status 'Failed' -Message 'control.error' -Arguments @($_.Exception.Message)
    }
}

# ------------------------------------------------------------------ BitLocker

function Invoke-ZTBitLockerControl {
    [CmdletBinding(SupportsShouldProcess)]
    param([AllowNull()]$Settings)
    $control = 'BitLocker'
    $config = @{}
    if ($Settings -is [System.Collections.IDictionary]) { $config = $Settings }
    $action = 'Report'
    if ($config['action']) { $action = [string]$config['action'] }
    $method = 'XtsAes256'
    if ($config['encryptionMethod']) { $method = [string]$config['encryptionMethod'] }
    $usedSpaceOnly = $true
    if ($config.Contains('usedSpaceOnly')) { $usedSpaceOnly = [bool]$config['usedSpaceOnly'] }
    $requireEscrow = $true
    if ($config.Contains('requireKeyEscrow')) { $requireEscrow = [bool]$config['requireKeyEscrow'] }
    $drive = $env:SystemDrive
    if (-not $drive) { $drive = 'C:' }

    if (-not (Test-ZTCommand -Name 'Get-BitLockerVolume')) {
        return New-ZTResult -Control $control -Status 'NonCompliant' -Message 'bitlocker.unavailable'
    }
    $volume = Get-BitLockerVolume -MountPoint $drive -ErrorAction Stop
    $protection = [string]$volume.ProtectionStatus
    $volumeStatus = [string]$volume.VolumeStatus
    $percent = [int]$volume.EncryptionPercentage

    if ($protection -eq 'On') {
        return New-ZTResult -Control $control -Status 'Compliant' -Message 'bitlocker.on' -Arguments @($drive, [string]$volume.EncryptionMethod, $percent)
    }
    if ($volumeStatus -eq 'EncryptionInProgress') {
        return New-ZTResult -Control $control -Status 'Compliant' -Message 'bitlocker.inProgress' -Arguments @($drive, $percent)
    }
    if ($action -ne 'Enable') {
        return New-ZTResult -Control $control -Status 'NonCompliant' -Message 'bitlocker.reportOnly' -Arguments @($drive, $protection, $volumeStatus)
    }

    $tpmReady = $false
    if (Test-ZTCommand -Name 'Get-Tpm') {
        try {
            $tpm = Get-Tpm -ErrorAction Stop
            $tpmReady = [bool]($tpm.TpmPresent -and $tpm.TpmReady)
        }
        catch {
            Write-ZTLog ('BitLocker: could not read the TPM: {0}' -f $_.Exception.Message) -Level Warning
        }
    }
    if (-not $tpmReady) {
        return New-ZTResult -Control $control -Status 'NonCompliant' -Message 'bitlocker.noTpm' -Arguments @($drive, $protection)
    }
    if (-not $PSCmdlet.ShouldProcess($drive, 'Enable BitLocker (TPM + recovery password, key escrowed first)')) {
        return New-ZTResult -Control $control -Status 'WhatIf' -Message 'bitlocker.whatIf' -Arguments @($drive, $protection)
    }

    # 1. A recovery password protector. Warnings are silenced because Add-BitLockerKeyProtector
    #    prints the recovery password in its warning text, which would end up in transcripts.
    $recovery = @($volume.KeyProtector | Where-Object { [string]$_.KeyProtectorType -eq 'RecoveryPassword' }) | Select-Object -First 1
    $addedProtector = $false
    if (-not $recovery) {
        $volume = Add-BitLockerKeyProtector -MountPoint $drive -RecoveryPasswordProtector -ErrorAction Stop -WarningAction SilentlyContinue
        $recovery = @($volume.KeyProtector | Where-Object { [string]$_.KeyProtectorType -eq 'RecoveryPassword' }) | Select-Object -Last 1
        $addedProtector = $true
    }
    $protectorId = [string]$recovery.KeyProtectorId

    # 2. Escrow the key BEFORE encrypting. An encrypted disk whose key is stored nowhere is a
    #    lost disk the first time the TPM asks for recovery.
    $escrow = @(Backup-ZTBitLockerKey -MountPoint $drive -KeyProtectorId $protectorId)
    if ($escrow.Count -eq 0 -and $requireEscrow) {
        if ($addedProtector) {
            try {
                Remove-BitLockerKeyProtector -MountPoint $drive -KeyProtectorId $protectorId -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            }
            catch {
                Write-ZTLog ('BitLocker: could not remove the unused recovery protector: {0}' -f $_.Exception.Message) -Level Warning
            }
        }
        return New-ZTResult -Control $control -Status 'NonCompliant' -Message 'bitlocker.noEscrow' -Arguments @($drive)
    }

    # 3. Encrypt, or resume protection on a volume that is encrypted but suspended / waiting for activation.
    if ($volumeStatus -eq 'FullyDecrypted') {
        Enable-BitLocker -MountPoint $drive -EncryptionMethod $method -UsedSpaceOnly:$usedSpaceOnly -TpmProtector -SkipHardwareTest -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        $messageKey = 'bitlocker.enabled'
    }
    else {
        $hasTpmProtector = @($volume.KeyProtector | Where-Object { [string]$_.KeyProtectorType -like 'Tpm*' }).Count -gt 0
        if (-not $hasTpmProtector) {
            Add-BitLockerKeyProtector -MountPoint $drive -TpmProtector -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        }
        Resume-BitLocker -MountPoint $drive -ErrorAction Stop | Out-Null
        $messageKey = 'bitlocker.resumed'
        if ([string]$volume.EncryptionMethod -and [string]$volume.EncryptionMethod -ne 'None') { $method = [string]$volume.EncryptionMethod }
    }
    if ($escrow.Count -eq 0) {
        return New-ZTResult -Control $control -Status 'Remediated' -Message 'bitlocker.enabledNoEscrow' -Arguments @($drive, $method, $protectorId)
    }
    New-ZTResult -Control $control -Status 'Remediated' -Message $messageKey -Arguments @($drive, $method, ($escrow -join ' + '), $protectorId)
}

# Stores the recovery key in Entra ID and/or Active Directory. Returns where it was stored.
function Backup-ZTBitLockerKey {
    param([Parameter(Mandatory)][string]$MountPoint, [Parameter(Mandatory)][string]$KeyProtectorId)
    $stored = New-Object -TypeName System.Collections.Generic.List[string]
    $join = Get-ZTJoinState
    if ($join.EntraJoined -and (Test-ZTCommand -Name 'BackupToAAD-BitLockerKeyProtector')) {
        try {
            BackupToAAD-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $KeyProtectorId -ErrorAction Stop | Out-Null
            $stored.Add('Entra ID')
        }
        catch {
            Write-ZTLog ('BitLocker: escrow to Entra ID failed: {0}' -f $_.Exception.Message) -Level Warning
        }
    }
    if ($join.DomainJoined -and (Test-ZTCommand -Name 'Backup-BitLockerKeyProtector')) {
        try {
            Backup-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $KeyProtectorId -ErrorAction Stop | Out-Null
            $stored.Add('Active Directory')
        }
        catch {
            Write-ZTLog ('BitLocker: escrow to Active Directory failed: {0}' -f $_.Exception.Message) -Level Warning
        }
    }
    # Plain output (no unary comma): callers wrap the call in @() and count the locations.
    $stored.ToArray()
}

# ------------------------------------------------------------------ SMBv1

function Invoke-ZTSmb1Control {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $control = 'SMBv1'
    $serverEnabled = $false
    if (Test-ZTCommand -Name 'Get-SmbServerConfiguration') {
        $serverEnabled = [bool](Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol
    }
    $featureEnabled = $false
    if (Test-ZTCommand -Name 'Get-WindowsOptionalFeature') {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -ErrorAction SilentlyContinue
        if ($feature -and @('Enabled', 'EnablePending') -contains [string]$feature.State) { $featureEnabled = $true }
    }
    if (-not $serverEnabled -and -not $featureEnabled) {
        return New-ZTResult -Control $control -Status 'Compliant' -Message 'smb1.compliant'
    }
    if (-not $PSCmdlet.ShouldProcess('SMBv1', 'Turn off the SMB 1.0 protocol')) {
        return New-ZTResult -Control $control -Status 'WhatIf' -Message 'smb1.whatIf'
    }
    $reboot = $false
    if ($serverEnabled) {
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -Confirm:$false -ErrorAction Stop
    }
    if ($featureEnabled) {
        $change = Disable-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -NoRestart -ErrorAction Stop -WarningAction SilentlyContinue
        if ($change -and $change.RestartNeeded) { $reboot = $true }
    }
    New-ZTResult -Control $control -Status 'Remediated' -Message 'smb1.disabled' -RebootRequired:$reboot
}

# ------------------------------------------------------------------ Firewall

function Invoke-ZTFirewallControl {
    [CmdletBinding(SupportsShouldProcess)]
    param([AllowNull()]$Settings)
    $control = 'Firewall'
    $config = @{}
    if ($Settings -is [System.Collections.IDictionary]) { $config = $Settings }
    $enable = $true
    if ($config.Contains('enableAllProfiles')) { $enable = [bool]$config['enableAllProfiles'] }
    $inbound = 'Block'
    if ($config['defaultInboundAction']) { $inbound = [string]$config['defaultInboundAction'] }
    $outbound = 'Allow'
    if ($config['defaultOutboundAction']) { $outbound = [string]$config['defaultOutboundAction'] }
    $logBlocked = [bool]$config['logBlocked']

    $wrong = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($fwProfile in @(Get-NetFirewallProfile -ErrorAction Stop)) {
        $problems = @()
        if ($enable -and [string]$fwProfile.Enabled -ne 'True') { $problems += 'off' }
        if ([string]$fwProfile.DefaultInboundAction -ne $inbound) { $problems += ('inbound ' + $fwProfile.DefaultInboundAction) }
        if ([string]$fwProfile.DefaultOutboundAction -ne $outbound) { $problems += ('outbound ' + $fwProfile.DefaultOutboundAction) }
        if ($logBlocked -and [string]$fwProfile.LogBlocked -ne 'True') { $problems += 'not logging drops' }
        if ($problems.Count -gt 0) {
            $wrong.Add([string]$fwProfile.Name)
            Write-ZTLog ('Firewall profile {0}: {1}' -f $fwProfile.Name, ($problems -join ', '))
        }
    }
    if ($wrong.Count -eq 0) {
        return New-ZTResult -Control $control -Status 'Compliant' -Message 'firewall.compliant' -Arguments @($inbound, $outbound)
    }
    $names = $wrong -join ', '
    if (-not $PSCmdlet.ShouldProcess($names, 'Set Windows Firewall profile defaults')) {
        return New-ZTResult -Control $control -Status 'WhatIf' -Message 'firewall.whatIf' -Arguments @($names, $inbound, $outbound)
    }
    $parameters = @{
        Name                  = @('Domain', 'Private', 'Public')
        DefaultInboundAction  = $inbound
        DefaultOutboundAction = $outbound
        ErrorAction           = 'Stop'
    }
    if ($enable) { $parameters['Enabled'] = 'True' }
    if ($logBlocked) { $parameters['LogBlocked'] = 'True' }
    Set-NetFirewallProfile @parameters
    New-ZTResult -Control $control -Status 'Remediated' -Message 'firewall.fixed' -Arguments @($names, $inbound, $outbound)
}

# Creates the profile's rules that do not exist yet (matched by display name, in the ZeroTouch group).
function Invoke-ZTFirewallRuleControl {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object[]]$Rules)
    $control = 'FirewallRules'
    $created = New-Object -TypeName System.Collections.Generic.List[string]
    $pending = New-Object -TypeName System.Collections.Generic.List[string]
    $failed = New-Object -TypeName System.Collections.Generic.List[string]
    $present = 0
    foreach ($rule in $Rules) {
        $name = [string]$rule['displayName']
        if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) {
            $present++
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($name, 'Create firewall rule')) {
            $pending.Add($name)
            continue
        }
        $direction = 'Inbound'
        if ($rule['direction']) { $direction = [string]$rule['direction'] }
        $ruleAction = 'Block'
        if ($rule['action']) { $ruleAction = [string]$rule['action'] }
        $ruleProfile = 'Any'
        if ($rule['profile']) { $ruleProfile = (([string]$rule['profile'] -split ',') | ForEach-Object { $_.Trim() }) -join ',' }
        $parameters = @{
            DisplayName = $name
            Direction   = $direction
            Action      = $ruleAction
            Profile     = $ruleProfile
            Group       = 'ZeroTouch'
            Description = 'Created by ZeroTouch provisioning.'
            ErrorAction = 'Stop'
        }
        if ($rule['protocol'] -and [string]$rule['protocol'] -ne 'Any') { $parameters['Protocol'] = [string]$rule['protocol'] }
        foreach ($pair in @(@('localPort', 'LocalPort'), @('remotePort', 'RemotePort'), @('remoteAddress', 'RemoteAddress'))) {
            if ($rule[$pair[0]]) { $parameters[$pair[1]] = @(([string]$rule[$pair[0]] -split ',') | ForEach-Object { $_.Trim() }) }
        }
        try {
            New-NetFirewallRule @parameters | Out-Null
            $created.Add($name)
        }
        catch {
            $failed.Add($name)
            Write-ZTLog ('Firewall rule "{0}": {1}' -f $name, $_.Exception.Message) -Level Error
        }
    }
    if ($failed.Count -gt 0) {
        return New-ZTResult -Control $control -Status 'Failed' -Message 'firewallRules.failed' -Arguments @($failed.Count, ($failed -join '; '))
    }
    if ($created.Count -gt 0) {
        return New-ZTResult -Control $control -Status 'Remediated' -Message 'firewallRules.created' -Arguments @($created.Count, ($created -join '; '), $present)
    }
    if ($pending.Count -gt 0) {
        return New-ZTResult -Control $control -Status 'WhatIf' -Message 'firewallRules.whatIf' -Arguments @($pending.Count, ($pending -join '; '))
    }
    New-ZTResult -Control $control -Status 'Compliant' -Message 'firewallRules.compliant' -Arguments @($present)
}

# ------------------------------------------------------------------ Bloatware

# Removes consumer apps for every user and from the provisioned image (so new users do not get
# them back). Protected system packages are never touched, whatever the pattern says.
function Invoke-ZTBloatwareControl {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string[]]$Patterns)
    $control = 'Bloatware'
    $appx = Get-Command -Name 'Get-AppxPackage' -ErrorAction SilentlyContinue
    if ($appx -and $appx.CommandType -eq 'Cmdlet' -and $PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7 loads the Appx module through Windows PowerShell compatibility.
        try {
            Import-Module -Name Appx -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue
        }
        catch {
            Write-ZTLog ('Appx compatibility import failed: {0}' -f $_.Exception.Message) -Level Warning
        }
    }
    if (-not (Test-ZTCommand -Name 'Get-AppxPackage')) {
        return New-ZTResult -Control $control -Status 'NonCompliant' -Message 'bloatware.unavailable'
    }
    $provisioned = @()
    if (Test-ZTCommand -Name 'Get-AppxProvisionedPackage') {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    }

    $removed = New-Object -TypeName System.Collections.Generic.List[string]
    $pending = New-Object -TypeName System.Collections.Generic.List[string]
    $failed = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($pattern in $Patterns) {
        $installed = @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue)
        $staged = @($provisioned | Where-Object { [string]$_.DisplayName -like $pattern })
        foreach ($blocked in @($installed | Where-Object { Test-ZTProtectedAppx -Name ([string]$_.Name) })) {
            Write-ZTLog ('Bloatware: {0} is a protected system package and was left alone.' -f $blocked.Name) -Level Warning
        }
        $installed = @($installed | Where-Object { -not (Test-ZTProtectedAppx -Name ([string]$_.Name)) })
        $staged = @($staged | Where-Object { -not (Test-ZTProtectedAppx -Name ([string]$_.DisplayName)) })
        if ($installed.Count -eq 0 -and $staged.Count -eq 0) { continue }

        if (-not $PSCmdlet.ShouldProcess($pattern, 'Remove preinstalled app (all users and provisioned image)')) {
            $pending.Add($pattern)
            continue
        }
        $ok = $true
        foreach ($package in $installed) {
            try {
                Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
            }
            catch {
                $ok = $false
                Write-ZTLog ('Bloatware: could not remove {0}: {1}' -f $package.Name, $_.Exception.Message) -Level Error
            }
        }
        foreach ($package in $staged) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
            }
            catch {
                $ok = $false
                Write-ZTLog ('Bloatware: could not deprovision {0}: {1}' -f $package.DisplayName, $_.Exception.Message) -Level Error
            }
        }
        if ($ok) { $removed.Add($pattern) } else { $failed.Add($pattern) }
    }

    if ($failed.Count -gt 0) {
        return New-ZTResult -Control $control -Status 'Failed' -Message 'bloatware.failed' -Arguments @(($failed -join ', '), $removed.Count)
    }
    if ($removed.Count -gt 0) {
        return New-ZTResult -Control $control -Status 'Remediated' -Message 'bloatware.removed' -Arguments @($removed.Count, ($removed -join ', '))
    }
    if ($pending.Count -gt 0) {
        return New-ZTResult -Control $control -Status 'WhatIf' -Message 'bloatware.whatIf' -Arguments @($pending.Count, ($pending -join ', '))
    }
    New-ZTResult -Control $control -Status 'Compliant' -Message 'bloatware.compliant' -Arguments @($Patterns.Count)
}
