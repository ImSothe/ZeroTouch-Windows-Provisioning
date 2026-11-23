# Security baseline, against the fake Windows in WindowsMock.ps1.

function Set-FakeBitLockerOff {
    $script:Fake.BitLocker.ProtectionStatus = 'Off'
    $script:Fake.BitLocker.VolumeStatus = 'FullyDecrypted'
    $script:Fake.BitLocker.EncryptionMethod = 'None'
    $script:Fake.BitLocker.EncryptionPercentage = 0
}

function Get-CallIndex {
    param([string]$Name)
    for ($k = 0; $k -lt $script:Fake.Calls.Count; $k++) { if ($script:Fake.Calls[$k].Name -eq $Name) { return $k } }
    return -1
}

# ---------------------------------------------------------------- BitLocker

Test-Case 'BitLocker: a protected drive is compliant and nothing is changed' {
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Enable' } }) 'BitLocker'
    Assert-Equal 'Compliant' $r.Status 'status'
    Assert-Equal 'C: is protected (XtsAes256, 100% encrypted).' $r.Detail 'detail'
    Assert-Equal 0 (Get-FakeChange).Count 'changes'
}

Test-Case 'BitLocker: encryption in progress counts as compliant' {
    $script:Fake.BitLocker.ProtectionStatus = 'Off'
    $script:Fake.BitLocker.VolumeStatus = 'EncryptionInProgress'
    $script:Fake.BitLocker.EncryptionPercentage = 37
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Report' } }) 'BitLocker'
    Assert-Equal 'Compliant' $r.Status 'status'
    Assert-Like $r.Detail '*37%*' 'percentage'
}

Test-Case 'BitLocker: report mode only reports an unprotected drive' {
    Set-FakeBitLockerOff
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Report' } }) 'BitLocker'
    Assert-Equal 'NonCompliant' $r.Status 'status'
    Assert-Equal 'bitlocker.reportOnly' $r.Message 'message'
    Assert-Equal 0 (Get-FakeChange).Count 'changes'
}

Test-Case 'BitLocker: without a ready TPM nothing is enabled' {
    Set-FakeBitLockerOff
    $script:Fake.Tpm.TpmReady = $false
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Enable' } }) 'BitLocker'
    Assert-Equal 'NonCompliant' $r.Status 'status'
    Assert-Equal 'bitlocker.noTpm' $r.Message 'message'
    Assert-Equal 0 (Get-FakeChange).Count 'changes'
}

Test-Case 'BitLocker: never encrypts when the recovery key cannot be escrowed' {
    Set-FakeBitLockerOff
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Enable' } }) 'BitLocker'
    Assert-Equal 'NonCompliant' $r.Status 'status'
    Assert-Equal 'bitlocker.noEscrow' $r.Message 'message'
    Assert-Equal 0 (Get-FakeCall -Name 'Enable-BitLocker').Count 'Enable-BitLocker calls'
    Assert-Equal 1 (Get-FakeCall -Name 'Remove-BitLockerKeyProtector').Count 'unused recovery protector removed'
    Assert-Equal 0 $script:Fake.BitLocker.Protectors.Count 'protectors left'
    Assert-Equal 'FullyDecrypted' $script:Fake.BitLocker.VolumeStatus 'volume untouched'
}

Test-Case 'BitLocker: a failed escrow is treated like no escrow' {
    Set-FakeBitLockerOff
    $script:Fake.Join.EntraJoined = $true
    $script:Fake.EscrowFails = $true
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Enable' } }) 'BitLocker'
    Assert-Equal 'bitlocker.noEscrow' $r.Message 'message'
    Assert-Equal 0 (Get-FakeCall -Name 'Enable-BitLocker').Count 'Enable-BitLocker calls'
}

Test-Case 'BitLocker: on an Entra ID joined PC the key is escrowed first, then the drive is encrypted' {
    Set-FakeBitLockerOff
    $script:Fake.Join.EntraJoined = $true
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Enable' } }) 'BitLocker'
    Assert-Equal 'Remediated' $r.Status 'status'
    Assert-Equal 'bitlocker.enabled' $r.Message 'message'
    Assert-Equal 'Entra ID' $r.Arguments[2] 'escrow target'
    Assert-Equal '{8A2C9F41-3B7E-4D21-9C55-0E6F1A2B3C4D}' $r.Arguments[3] 'protector id'
    $escrow = Get-CallIndex 'BackupToAAD-BitLockerKeyProtector'
    $enable = Get-CallIndex 'Enable-BitLocker'
    Assert-True ($escrow -ge 0 -and $enable -gt $escrow) ('escrow ({0}) before encryption ({1})' -f $escrow, $enable)
    $parameters = (Get-FakeCall -Name 'Enable-BitLocker')[0].Parameters
    Assert-Equal 'XtsAes256' $parameters.EncryptionMethod 'default method'
    Assert-True $parameters.UsedSpaceOnly 'used space only'
    Assert-True $parameters.TpmProtector 'TPM protector'
}

Test-Case 'BitLocker: on a domain PC the key goes to Active Directory, with the profile method' {
    Set-FakeBitLockerOff
    $script:Fake.Join.DomainJoined = $true
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Enable'; encryptionMethod = 'XtsAes128'; usedSpaceOnly = $false } }) 'BitLocker'
    Assert-Equal 'Active Directory' $r.Arguments[2] 'escrow target'
    $parameters = (Get-FakeCall -Name 'Enable-BitLocker')[0].Parameters
    Assert-Equal 'XtsAes128' $parameters.EncryptionMethod 'method'
    Assert-True (-not $parameters.UsedSpaceOnly) 'full disk'
}

Test-Case 'BitLocker: suspended protection is resumed instead of re-encrypting' {
    $script:Fake.BitLocker.ProtectionStatus = 'Off'
    $script:Fake.BitLocker.VolumeStatus = 'FullyEncrypted'
    $script:Fake.BitLocker.Protectors.Add([pscustomobject]@{ KeyProtectorType = 'Tpm'; KeyProtectorId = '{TPM}'; RecoveryPassword = '' })
    $script:Fake.BitLocker.Protectors.Add([pscustomobject]@{ KeyProtectorType = 'RecoveryPassword'; KeyProtectorId = '{RP}'; RecoveryPassword = $script:FakeRecoveryPassword })
    $script:Fake.Join.EntraJoined = $true
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Enable' } }) 'BitLocker'
    Assert-Equal 'bitlocker.resumed' $r.Message 'message'
    Assert-Equal 1 (Get-FakeCall -Name 'Resume-BitLocker').Count 'resumed'
    Assert-Equal 0 (Get-FakeCall -Name 'Enable-BitLocker').Count 'not re-encrypted'
    Assert-Equal 0 (Get-FakeCall -Name 'Add-BitLockerKeyProtector').Count 'existing protectors reused'
    Assert-Equal '{RP}' (Get-FakeCall -Name 'BackupToAAD-BitLockerKeyProtector')[0].Parameters.KeyProtectorId 'existing recovery key escrowed'
}

Test-Case 'BitLocker: requireKeyEscrow false encrypts anyway and says so' {
    Set-FakeBitLockerOff
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Enable'; requireKeyEscrow = $false } }) 'BitLocker'
    Assert-Equal 'Remediated' $r.Status 'status'
    Assert-Equal 'bitlocker.enabledNoEscrow' $r.Message 'message'
    Assert-Like $r.Detail '*WITHOUT escrowing*' 'detail'
}

Test-Case 'BitLocker: Windows editions without BitLocker are reported, not failed' {
    $script:Fake.Missing = @('Get-BitLockerVolume')
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Enable' } }) 'BitLocker'
    Assert-Equal 'NonCompliant' $r.Status 'status'
    Assert-Equal 'bitlocker.unavailable' $r.Message 'message'
}

Test-Case 'BitLocker: -WhatIf changes nothing' {
    Set-FakeBitLockerOff
    $script:Fake.Join.EntraJoined = $true
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ bitlocker = @{ action = 'Enable' } } -WhatIf) 'BitLocker'
    Assert-Equal 'WhatIf' $r.Status 'status'
    Assert-Equal 0 (Get-FakeChange).Count 'changes'
}

# ---------------------------------------------------------------- SMBv1

Test-Case 'SMBv1: server setting and optional feature are both turned off' {
    $script:Fake.Smb1.Server = $true
    $script:Fake.Smb1.Feature = 'Enabled'
    $script:Fake.Smb1.RestartNeeded = $true
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ disableSmb1 = $true }) 'SMBv1'
    Assert-Equal 'Remediated' $r.Status 'status'
    Assert-True $r.RebootRequired 'reboot flagged'
    Assert-True (-not (Get-FakeCall -Name 'Set-SmbServerConfiguration')[0].Parameters.EnableSMB1Protocol) 'server setting off'
    Assert-True (Get-FakeCall -Name 'Disable-WindowsOptionalFeature')[0].Parameters.NoRestart 'no forced restart'
    Assert-True (-not $script:Fake.Smb1.Server) 'state'
}

Test-Case 'SMBv1: already off is compliant and nothing is changed' {
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ disableSmb1 = $true }) 'SMBv1'
    Assert-Equal 'Compliant' $r.Status 'status'
    Assert-Equal 0 (Get-FakeChange).Count 'changes'
}

Test-Case 'SMBv1: only the server setting on, no restart needed' {
    $script:Fake.Smb1.Server = $true
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ disableSmb1 = $true }) 'SMBv1'
    Assert-Equal 'Remediated' $r.Status 'status'
    Assert-True (-not $r.RebootRequired) 'no reboot'
    Assert-Equal 0 (Get-FakeCall -Name 'Disable-WindowsOptionalFeature').Count 'feature untouched'
}

Test-Case 'SMBv1: false in the profile skips the control without reading anything' {
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ disableSmb1 = $false }) 'SMBv1'
    Assert-Equal 'Skipped' $r.Status 'status'
    Assert-Equal 0 (Get-FakeCall -Name 'Get-SmbServerConfiguration').Count 'not read'
}

# ---------------------------------------------------------------- Firewall

Test-Case 'Firewall: wrong profiles are fixed in one call' {
    $script:Fake.Firewall.Profiles[2].Enabled = 'False'
    $script:Fake.Firewall.Profiles[0].DefaultInboundAction = 'NotConfigured'
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ firewall = @{ defaultInboundAction = 'Block'; logBlocked = $true } }) 'Firewall'
    Assert-Equal 'Remediated' $r.Status 'status'
    Assert-Equal 'Domain, Public' $r.Arguments[0] 'profiles fixed'
    $call = (Get-FakeCall -Name 'Set-NetFirewallProfile')[0].Parameters
    Assert-Equal 'Domain,Private,Public' ($call.Name -join ',') 'all profiles set'
    Assert-Equal 'True' $call.Enabled 'enabled'
    Assert-Equal 'Block' $call.DefaultInboundAction 'inbound'
    Assert-Equal 'Allow' $call.DefaultOutboundAction 'outbound'
    Assert-Equal 'True' $call.LogBlocked 'log drops'
    Assert-Equal 'True' $script:Fake.Firewall.Profiles[2].Enabled 'state'
}

Test-Case 'Firewall: correct profiles are compliant' {
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ firewall = @{ defaultInboundAction = 'Block' } }) 'Firewall'
    Assert-Equal 'Compliant' $r.Status 'status'
    Assert-Equal 0 (Get-FakeChange).Count 'changes'
}

Test-Case 'Firewall rules: missing rules are created, existing ones are kept' {
    $script:Fake.Firewall.Rules.Add('Existing rule')
    $rules = @(
        @{ displayName = 'Existing rule'; protocol = 'TCP'; localPort = '3389' },
        @{ displayName = 'ZT - Block SMB'; direction = 'Inbound'; action = 'Block'; protocol = 'TCP'; localPort = '445, 139'; profile = 'Public, Private'; remoteAddress = '10.0.0.0/8' }
    )
    $results = Invoke-ZTSecurityBaseline -Settings @{ firewall = @{ rules = $rules } }
    $r = Get-Result $results 'FirewallRules'
    Assert-Equal 'Remediated' $r.Status 'status'
    Assert-Equal 'Rules created: 1 (ZT - Block SMB). Already present: 1.' $r.Detail 'detail'
    $calls = Get-FakeCall -Name 'New-NetFirewallRule'
    Assert-Equal 1 $calls.Count 'rules created'
    $p = $calls[0].Parameters
    Assert-Equal 'ZT - Block SMB' $p.DisplayName 'name'
    Assert-Equal 'Public,Private' $p.Profile 'profiles'
    Assert-Equal '445|139' ($p.LocalPort -join '|') 'ports split'
    Assert-Equal '10.0.0.0/8' ($p.RemoteAddress -join '|') 'remote address'
    Assert-Equal 'ZeroTouch' $p.Group 'group'
    Assert-Equal 'TCP' $p.Protocol 'protocol'
}

Test-Case 'Firewall rules: a rule that cannot be created fails the control' {
    $script:Fake.Firewall.FailRules = @('Broken')
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ firewall = @{ rules = @(@{ displayName = 'Broken' }, @{ displayName = 'Fine' }) } }) 'FirewallRules'
    Assert-Equal 'Failed' $r.Status 'status'
    Assert-Like $r.Detail '*Broken*' 'detail'
    Assert-Contains $script:Fake.Firewall.Rules 'Fine' 'other rules still created'
}

Test-Case 'Firewall: false skips the profiles and the rules' {
    $results = @(Invoke-ZTSecurityBaseline -Settings @{ firewall = $false })
    Assert-Equal 1 $results.Count 'one result'
    Assert-Equal 'Skipped' $results[0].Status 'status'
}

# ---------------------------------------------------------------- Bloatware

Test-Case 'Bloatware: removed for all users and from the provisioned image' {
    Add-FakeAppx -Name 'Microsoft.BingNews'
    Add-FakeAppx -Name 'Microsoft.BingNews' -Provisioned
    Add-FakeAppx -Name 'king.com.CandyCrushSaga'
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ removeBloatware = @('Microsoft.BingNews', 'king.com.*', 'Microsoft.ZuneVideo') }) 'Bloatware'
    Assert-Equal 'Remediated' $r.Status 'status'
    Assert-Equal 'Microsoft.BingNews, king.com.*' $r.Arguments[1] 'removed patterns'
    Assert-True (Get-FakeCall -Name 'Remove-AppxPackage')[0].Parameters.AllUsers 'all users'
    Assert-Equal 1 (Get-FakeCall -Name 'Remove-AppxProvisionedPackage').Count 'deprovisioned'
    Assert-Equal 0 $script:Fake.Appx.Count 'nothing left'
}

Test-Case 'Bloatware: protected packages survive even a pattern that matches them' {
    Add-FakeAppx -Name 'Microsoft.DesktopAppInstaller'
    Add-FakeAppx -Name 'Microsoft.WindowsStore'
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ removeBloatware = @('Microsoft.Desktop*', 'Microsoft.Windows*') }) 'Bloatware'
    Assert-Equal 'Compliant' $r.Status 'status'
    Assert-Equal 0 (Get-FakeCall -Name 'Remove-AppxPackage').Count 'nothing removed'
    Assert-Equal 2 $script:Fake.Appx.Count 'winget and the Store still installed'
}

Test-Case 'Bloatware: a removal error fails the control and the rest still runs' {
    Add-FakeAppx -Name 'Microsoft.BingNews'
    Add-FakeAppx -Name 'Microsoft.GamingApp'
    $script:Fake.AppxFail = @('Microsoft.GamingApp')
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ removeBloatware = @('Microsoft.GamingApp', 'Microsoft.BingNews') }) 'Bloatware'
    Assert-Equal 'Failed' $r.Status 'status'
    Assert-Equal 'Microsoft.GamingApp' $r.Arguments[0] 'failed pattern'
    Assert-Equal '1' $r.Arguments[1] 'others removed'
}

Test-Case 'Bloatware: -WhatIf lists what would go and removes nothing' {
    Add-FakeAppx -Name 'Microsoft.BingNews'
    $r = Get-Result (Invoke-ZTSecurityBaseline -Settings @{ removeBloatware = @('Microsoft.BingNews') } -WhatIf) 'Bloatware'
    Assert-Equal 'WhatIf' $r.Status 'status'
    Assert-Equal 1 $script:Fake.Appx.Count 'still installed'
}

# ---------------------------------------------------------------- isolation and order

Test-Case 'A control that throws is reported as Failed and the others still run, in a fixed order' {
    $script:Fake.Smb1.Throw = $true
    $results = @(Invoke-ZTSecurityBaseline -Settings @{
            removeBloatware = @('Microsoft.BingNews'); firewall = @{ rules = @(@{ displayName = 'R' }) }; disableSmb1 = $true; bitlocker = @{ action = 'Report' }
        })
    Assert-Equal 'BitLocker,SMBv1,Firewall,FirewallRules,Bloatware' (($results | ForEach-Object { $_.Control }) -join ',') 'order'
    $smb = Get-Result $results 'SMBv1'
    Assert-Equal 'Failed' $smb.Status 'status'
    Assert-Like $smb.Detail '*SMB server service is not running*' 'error message kept'
}

Test-Case 'Settings missing from the profile produce no result at all' {
    Assert-Equal 0 @(Invoke-ZTSecurityBaseline -Settings @{}).Count 'empty settings'
    Assert-Equal 0 @(Invoke-ZTSecurityBaseline -Settings $null).Count 'no security section'
}
