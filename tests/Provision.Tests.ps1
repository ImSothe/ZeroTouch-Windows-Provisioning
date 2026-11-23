# End-to-end provisioning against the fake Windows: profile, apps, baseline, inventory, form, marker.

function Invoke-TestProvisioning {
    param([string]$Department = 'oficina', [hashtable]$Extra = @{}, [switch]$WhatIf)
    $parameters = @{ Department = $Department; ProfilesPath = $RepoProfiles; OutputPath = (New-TestFolder); RetryDelaySeconds = 0; Technician = 'Tester' }
    foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
    Invoke-ZTProvisioning @parameters -WhatIf:$WhatIf
}

Test-Case 'Fresh office PC: apps installed, baseline applied, form written, restart requested' {
    Set-FakeFreshPc
    $run = Invoke-TestProvisioning -Extra @{ AssignedUser = 'Lucia Martin' }
    Assert-Equal 7 @($run.Applications).Count 'base 3 + oficina 4'
    Assert-Equal 7 @($run.Applications | Where-Object { $_.Status -eq 'Installed' }).Count 'all installed'
    Assert-Equal 1 @($run.Printers).Count 'office printer'
    Assert-Equal 'Installed' @($run.Printers)[0].Status 'office printer added'
    Assert-Equal 'NonCompliant' (Get-Result $run.Security 'BitLocker').Status 'office PCs only report BitLocker'
    Assert-Equal 'Remediated' (Get-Result $run.Security 'SMBv1').Status 'SMBv1'
    Assert-Equal 'Remediated' (Get-Result $run.Security 'Firewall').Status 'firewall profiles'
    Assert-Equal 'Remediated' (Get-Result $run.Security 'FirewallRules').Status 'firewall rules'
    Assert-Equal 'Remediated' (Get-Result $run.Security 'Bloatware').Status 'bloatware'
    Assert-Equal 'Warning' $run.Outcome.Status 'outcome (BitLocker needs attention)'
    Assert-Equal 3010 $run.ExitCode 'restart needed for SMBv1'
    Assert-Equal 'es' $run.Language 'language from the profile organization'
    Assert-Equal 'Demo Corp S.L.' $run.Organization.Name 'organization'
    Assert-Equal 'PC-OFI-014' $run.Device.ComputerName 'inventory'
    Assert-True (Test-Path -LiteralPath $run.ReportPaths.HtmlPath) 'HTML form'
    Assert-True (Test-Path -LiteralPath $run.ReportPaths.JsonPath) 'JSON twin'
    Assert-Like $run.ReportPaths.HtmlPath '*\Reports\ZT-*-PC-OFI-014.html' 'form location and name'
    $marker = @(Get-FakeCall -Name 'Set-ZTRegistryMarker')
    Assert-Equal 1 $marker.Count 'registry marker'
    Assert-Equal 'oficina' $marker[0].Parameters.Run.Profile.Name 'marker profile'
    $log = [System.IO.File]::ReadAllText($run.LogPath)
    Assert-Like $log '*Result: Warning (exit code 3010)*' 'log'
    Assert-Contains $script:Fake.Appx.Name 'Microsoft.DesktopAppInstaller' 'winget survived the debloat'
}

Test-Case 'Running it twice changes nothing the second time' {
    Set-FakeFreshPc
    Invoke-TestProvisioning | Out-Null
    $script:Fake.Calls.Clear()
    $run = Invoke-TestProvisioning
    Assert-Equal 7 @($run.Applications | Where-Object { $_.Status -eq 'AlreadyInstalled' }).Count 'nothing reinstalled'
    Assert-Equal 'AlreadyInstalled' @($run.Printers)[0].Status 'printer kept'
    foreach ($control in 'SMBv1', 'Firewall', 'FirewallRules', 'Bloatware') { Assert-Equal 'Compliant' (Get-Result $run.Security $control).Status $control }
    Assert-Equal 0 @(Get-FakeChange).Count 'system changes on the second run'
    Assert-Equal 0 $run.ExitCode 'no restart needed any more'
}

Test-Case '-WhatIf: checks everything, changes nothing, writes a simulation form' {
    Set-FakeFreshPc
    $script:Fake.IsAdmin = $false
    $run = Invoke-TestProvisioning -Department 'comercial' -WhatIf
    Assert-Equal 0 @(Get-FakeChange).Count ('changes: {0}' -f ((Get-FakeChange | ForEach-Object { $_.Name }) -join ', '))
    Assert-Equal 'Simulation' $run.Outcome.Status 'outcome'
    Assert-Equal 0 $run.ExitCode 'exit code'
    Assert-True $run.Simulation 'run flagged'
    Assert-Equal 8 @($run.Applications | Where-Object { $_.Status -eq 'WhatIf' }).Count 'would install every app'
    Assert-Equal 'WhatIf' (Get-Result $run.Security 'BitLocker').Status 'would encrypt the laptop'
    Assert-Equal 'WhatIf' @($run.Printers)[0].Status 'would add the office printer'
    $html = [System.IO.File]::ReadAllText($run.ReportPaths.HtmlPath, [System.Text.Encoding]::UTF8)
    Assert-True ($html.Contains('class="banner"')) 'simulation banner'
    Assert-Equal 0 @(Get-FakeCall -Name 'Set-ZTRegistryMarker').Count 'no registry marker'
}

Test-Case 'Without administrator rights a real run stops before changing anything' {
    $script:Fake.IsAdmin = $false
    Assert-Throws { Invoke-TestProvisioning } -Like '*as administrator*'
    Assert-Equal 0 @(Get-FakeChange).Count 'changes'
}

Test-Case 'A failed required app fails the run; a failed optional app is only a note' {
    Set-FakeInstallResult -Id 'Microsoft.Teams' -Codes @(1603)
    $run = Invoke-TestProvisioning
    Assert-Equal 'Failed' $run.Outcome.Status 'required app failed'
    Assert-Equal 1 $run.ExitCode 'exit code'
    Reset-FakeWindows
    Set-FakeInstallResult -Id 'Greenshot.Greenshot' -Codes @(1603)
    $run = Invoke-TestProvisioning
    Assert-Equal 'Warning' $run.Outcome.Status 'optional app failed'
    Assert-Equal 0 $run.ExitCode 'exit code'
}

Test-Case 'A healthy PC with everything installed is simply compliant' {
    foreach ($id in '7zip.7zip', 'Google.Chrome', 'Adobe.Acrobat.Reader.64-bit', 'Microsoft.Office', 'Microsoft.Teams', 'geeksoftwareGmbH.PDF24Creator', 'Greenshot.Greenshot') {
        $script:Fake.Winget.Installed[$id] = '1.0'
    }
    foreach ($rule in 'ZT - Block inbound SMB on public networks', 'ZT - Block inbound RDP on public networks') { $script:Fake.Firewall.Rules.Add($rule) }
    Add-FakePrinter -Name ([string]@((Get-ZTProfile -Name 'oficina' -ProfilesPath $RepoProfiles)['printers'])[0]['name'])
    $script:Fake.Drivers.Available.Add('\\srv-files\drivers\Models')
    $run = Invoke-TestProvisioning
    Assert-Equal 'Success' $run.Outcome.Status 'outcome'
    Assert-Equal 0 $run.ExitCode 'exit code'
    Assert-Equal 0 @(Get-FakeChange).Count 'changes'
    Assert-Equal 1 @(Get-FakeCall -Name 'Set-ZTRegistryMarker').Count 'marker written on a real run'
}

Test-Case 'No winget: every app is reported, nothing else is skipped' {
    $script:Fake.Winget.Available = $false
    $run = Invoke-TestProvisioning
    Assert-Equal 7 @($run.Applications | Where-Object { $_.Message -eq 'app.wingetMissing' }).Count 'apps reported'
    Assert-Equal 'Failed' $run.Outcome.Status 'outcome'
    Assert-True (@($run.Security).Count -gt 0) 'baseline still applied'
}

Test-Case '-SkipApplications, -SkipPrinters and -SkipSecurity' {
    $run = Invoke-TestProvisioning -Extra @{ SkipApplications = $true; SkipPrinters = $true }
    Assert-Equal 0 @($run.Applications).Count 'no apps'
    Assert-Equal 0 @(Get-FakeCall -Name 'winget').Count 'winget not called'
    Assert-Equal 0 @($run.Printers).Count 'no printers'
    Assert-Equal 0 @(Get-FakeCall -Name 'Get-Printer').Count 'printers not touched'
    $run = Invoke-TestProvisioning -Extra @{ SkipSecurity = $true }
    Assert-Equal 0 @($run.Security).Count 'no baseline'
    Assert-Equal 7 @($run.Applications).Count 'apps still installed'
}

Test-Case 'Department by path, language override, notes and PDF' {
    $run = Invoke-TestProvisioning -Department (Join-Path $RepoProfiles 'taller.json') -Extra @{ Language = 'en'; Notes = 'Monitor 24"'; Pdf = $true }
    Assert-Equal 'taller' $run.Profile.Name 'profile from a path'
    Assert-Equal 'en' $run.Language 'language override'
    Assert-Equal 'Monitor 24"' $run.Notes 'notes'
    Assert-True (Test-Path -LiteralPath $run.ReportPaths.PdfPath) 'PDF'
    Assert-Equal 'Installed' @($run.Printers)[0].Status 'workshop printer'
    Assert-Like (Get-FakeCall -Name 'Invoke-ZTPnpUtil')[0].Parameters.InfPath '\\srv-files\*.inf' 'driver package from the share'
    $html = [System.IO.File]::ReadAllText($run.ReportPaths.HtmlPath, [System.Text.Encoding]::UTF8)
    Assert-True ($html.Contains('Technician notes: Monitor 24&quot;')) 'notes encoded in the form'
}

Test-Case 'An unknown department fails before anything is touched' {
    $output = New-TestFolder
    Assert-Throws { Invoke-ZTProvisioning -Department 'contabilidad' -ProfilesPath $RepoProfiles -OutputPath $output } -Like '*Profile not found*'
    Assert-Equal 0 $script:Fake.Calls.Count 'no system calls'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $output -Recurse).Count 'no files'
}

Test-Case 'The JSON twin is plain data (no PowerShell type noise) and matches the run' {
    Set-FakeFreshPc
    $run = Invoke-TestProvisioning
    $text = [System.IO.File]::ReadAllText($run.ReportPaths.JsonPath, [System.Text.Encoding]::UTF8)
    Assert-True ($text -notmatch '"(value|Count)"\s*:') 'no {"value":...,"Count":...} wrappers'
    $json = $text | ConvertFrom-Json
    Assert-Equal $run.FormId $json.FormId 'form id'
    Assert-Equal 7 @($json.Applications).Count 'applications'
    Assert-Equal 5 @($json.Security).Count 'security results'
    Assert-Equal 1 @($json.Printers).Count 'printers'
    Assert-Equal 1 @($json.Drivers).Count 'drivers (base model packs)'
    Assert-Equal 'smb1.disabled' (@($json.Security) | Where-Object { $_.Control -eq 'SMBv1' }).Message 'message keys kept for re-rendering'
}

Test-Case 'Get-ZTOutcome: exit codes for Intune' {
    $ok = [pscustomobject]@{ Status = 'Installed'; Required = $true; RebootRequired = $false }
    $reboot = [pscustomobject]@{ Status = 'Remediated'; RebootRequired = $true }
    $failed = [pscustomobject]@{ Status = 'Failed'; Required = $true; RebootRequired = $false }
    Assert-Equal 0 (Get-ZTOutcome -Applications @($ok)).ExitCode 'success'
    Assert-Equal 3010 (Get-ZTOutcome -Applications @($ok) -Security @($reboot)).ExitCode 'restart'
    Assert-Equal 1 (Get-ZTOutcome -Applications @($failed) -Security @($reboot)).ExitCode 'failure wins over restart'
    Assert-Equal 0 (Get-ZTOutcome -Applications @($failed) -Simulation).ExitCode 'simulation'
    $printer = [pscustomobject]@{ Status = 'Failed'; RebootRequired = $false }
    Assert-Equal 'Warning' (Get-ZTOutcome -Applications @($ok) -Printers @($printer)).Status 'a missing printer is a note, not a failure'
}
