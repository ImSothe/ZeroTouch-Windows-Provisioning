# Department profiles: inheritance, normalisation, validation and the department list.

$baseProfile = @{
    name         = 'base'
    abstract     = $true
    organization = @{ name = 'Demo Corp'; itContact = 'ext. 200'; language = 'es' }
    applications = @('7zip.7zip', @{ id = 'Google.Chrome'; name = 'Chrome' }, @{ id = 'Adobe.Acrobat.Reader.64-bit' })
    security     = @{
        disableSmb1     = $true
        bitlocker       = @{ action = 'Report' }
        removeBloatware = @('Microsoft.BingNews')
        firewall        = @{ defaultInboundAction = 'Block'; rules = @(@{ displayName = 'R1'; direction = 'Inbound'; action = 'Block'; protocol = 'TCP'; localPort = '445' }) }
    }
}
$childProfile = @{
    name               = 'taller'
    extends            = 'base'
    applications       = @(@{ id = 'Notepad++.Notepad++' }, @{ id = 'google.chrome'; scope = 'machine' })
    removeApplications = @('Adobe.Acrobat.Reader.64-bit')
    security           = @{
        bitlocker       = @{ action = 'Enable' }
        removeBloatware = @('Microsoft.GamingApp')
        firewall        = @{ rules = @(@{ displayName = 'R2'; direction = 'Inbound'; action = 'Allow'; protocol = 'TCP'; localPort = '5001' }) }
    }
}

function Get-AppIds {
    param($ProfileData)
    (@($ProfileData['applications']) | ForEach-Object { $_['id'] }) -join ','
}

function Get-IssueText {
    param($ProfileData, [string]$Severity = 'Error')
    (@(Test-ZTProfile -ProfileData $ProfileData) | Where-Object { $_.Severity -eq $Severity } | ForEach-Object { $_.Message }) -join ' | '
}

# A minimal valid profile to break one setting at a time.
function New-ValidProfile {
    $data = [ordered]@{
        name         = 'test'
        applications = @(ConvertTo-ZTAppDefinition -InputObject '7zip.7zip')
        security     = [ordered]@{
            bitlocker       = [ordered]@{ action = 'Report' }
            disableSmb1     = $true
            firewall        = [ordered]@{ defaultInboundAction = 'Block'; rules = @([ordered]@{ displayName = 'R'; protocol = 'TCP'; localPort = '445' }) }
            removeBloatware = @('Microsoft.BingNews')
        }
    }
    $data
}

# ---------------------------------------------------------------- inheritance

Test-Case 'Get-ZTProfile: a department inherits applications and settings, and the child wins' {
    $folder = New-ProfileFolder @{ base = $baseProfile; taller = $childProfile }
    $p = Get-ZTProfile -Name 'taller' -ProfilesPath $folder
    Assert-Equal '7zip.7zip,google.chrome,Notepad++.Notepad++' (Get-AppIds $p) 'applications (removed, replaced in place, added)'
    Assert-Equal 'machine' (@($p['applications'])[1]['scope']) 'child entry replaced the parent entry'
    Assert-Equal 'Enable' $p['security']['bitlocker']['action'] 'child setting wins'
    Assert-True ($p['security']['disableSmb1'] -eq $true) 'inherited setting'
    Assert-Equal 'Microsoft.BingNews,Microsoft.GamingApp' (@($p['security']['removeBloatware']) -join ',') 'lists add up'
    Assert-Equal 'R1,R2' ((@($p['security']['firewall']['rules']) | ForEach-Object { $_['displayName'] }) -join ',') 'rules add up'
    Assert-Equal 'Block' $p['security']['firewall']['defaultInboundAction'] 'nested inherited value'
    Assert-Equal 'es' $p['organization']['language'] 'organization inherited'
    Assert-Equal 'taller' $p['name'] 'name'
    Assert-Equal 'taller' $p['displayName'] 'displayName defaults to the name'
    Assert-Equal '' $p['description'] 'parent description not inherited'
    Assert-True (-not $p['abstract']) 'abstract is not inherited'
    Assert-Equal 2 @($p['sourceFiles']).Count 'inheritance chain'
}

Test-Case 'Get-ZTProfile: short and full application entries are normalised' {
    $folder = New-ProfileFolder @{ base = $baseProfile }
    $p = Get-ZTProfile -Name 'base' -ProfilesPath $folder
    $zip = @($p['applications'])[0]
    Assert-Equal '7zip.7zip' $zip['name'] 'name defaults to the id'
    Assert-Equal 'winget' $zip['source'] 'source defaults to winget'
    Assert-True ($zip['required'] -eq $true) 'required by default'
    Assert-Equal 'Chrome' (@($p['applications'])[1]['name']) 'explicit name kept'
}

Test-Case 'Get-ZTProfile: the repository profiles resolve three levels (comercial -> oficina -> base)' {
    $p = Get-ZTProfile -Name 'comercial' -ProfilesPath $RepoProfiles
    $ids = @($p['applications'] | ForEach-Object { $_['id'] })
    foreach ($id in '7zip.7zip', 'Google.Chrome', 'Microsoft.Office', 'Microsoft.Teams', 'Zoom.Zoom') { Assert-Contains $ids $id 'comercial applications' }
    Assert-Equal 'Enable' $p['security']['bitlocker']['action'] 'laptops encrypt'
    Assert-Equal 'XtsAes256' $p['security']['bitlocker']['encryptionMethod'] 'method inherited from base'
    Assert-Equal 3 @($p['security']['firewall']['rules']).Count 'two base rules plus one'
    Assert-Equal 3 @($p['sourceFiles']).Count 'chain'
    Assert-Equal 'Demo Corp S.L.' $p['organization']['name'] 'organization'
}

Test-Case 'Get-ZTProfile: taller drops the PDF reader it inherits and adds its machine-network rule' {
    $p = Get-ZTProfile -Name 'taller' -ProfilesPath $RepoProfiles
    $ids = @($p['applications'] | ForEach-Object { $_['id'] })
    Assert-NotContains $ids 'Adobe.Acrobat.Reader.64-bit' 'taller applications'
    Assert-Contains $ids 'SumatraPDF.SumatraPDF' 'taller applications'
    $rule = @($p['security']['firewall']['rules']) | Where-Object { $_['remoteAddress'] }
    Assert-Equal '192.168.50.0/24' $rule['remoteAddress'] 'rule limited to the machine network'
}

Test-Case 'Get-ZTProfile: circular inheritance and missing parents are reported' {
    $folder = New-ProfileFolder @{ a = @{ name = 'a'; extends = 'b' }; b = @{ name = 'b'; extends = 'a' }; c = @{ name = 'c'; extends = 'missing' } }
    Assert-Throws { Get-ZTProfile -Name 'a' -ProfilesPath $folder } -Like '*Circular inheritance*' -What 'a <-> b'
    Assert-Throws { Get-ZTProfile -Name 'c' -ProfilesPath $folder } -Like '*Profile not found*missing.json*' -What 'missing parent'
    Assert-Throws { Get-ZTProfile -Name 'nope' -ProfilesPath $folder } -Like '*Profile not found*' -What 'missing profile'
}

Test-Case 'Get-ZTProfile: names that could escape the profiles folder are refused' {
    foreach ($name in '..\..\Windows\win', '../base', 'C:\temp\x', 'name with spaces', '') {
        Assert-Throws { Get-ZTProfile -Name $name -ProfilesPath $RepoProfiles } -Like '*' -What ('name "{0}"' -f $name)
    }
    $folder = New-ProfileFolder @{ evil = @{ name = 'evil'; extends = '..\..\secret' } }
    Assert-Throws { Get-ZTProfile -Name 'evil' -ProfilesPath $folder } -Like "*invalid 'extends'*" -What 'extends traversal'
}

Test-Case 'Get-ZTProfile: invalid JSON and invalid profiles are refused with the reason' {
    $folder = New-TestFolder
    Write-ZTTextFile -Path (Join-Path $folder 'broken.json') -Content '{ "name": "broken", '
    Assert-Throws { Get-ZTProfile -Name 'broken' -ProfilesPath $folder } -Like '*Invalid JSON*' -What 'broken JSON'
    $bad = New-ProfileFolder @{ bad = @{ name = 'bad'; applications = @('ok.app', 'not valid!') } }
    Assert-Throws { Get-ZTProfile -Name 'bad' -ProfilesPath $bad } -Like "*invalid package id 'not valid!'*" -What 'bad id'
}

Test-Case 'Get-ZTProfile: unknown keys are warned about, not silently accepted' {
    $folder = New-ProfileFolder @{ typo = @{ name = 'typo'; aplications = @('7zip.7zip'); applications = @(@{ id = '7zip.7zip'; verison = '1' }) } }
    $warnings = @(Get-ZTProfile -Name 'typo' -ProfilesPath $folder 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
    Assert-True (($warnings -join ' ') -like "*'aplications'*") 'unknown profile key'
    Assert-True (($warnings -join ' ') -like "*'verison'*") 'unknown application key'
}

# ---------------------------------------------------------------- validation rules

Test-Case 'Test-ZTProfile: a minimal profile is valid' {
    Assert-Equal '' (Get-IssueText (New-ValidProfile)) 'errors'
    Assert-Equal '' (Get-IssueText (New-ValidProfile) -Severity 'Warning') 'warnings'
}

Test-Case 'Test-ZTProfile: application fields are checked' {
    foreach ($case in @(
            @{ App = @{ id = '7zip.7zip; calc' }; Like = '*invalid package id*' },
            @{ App = @{ id = '7zip.7zip'; source = 'chocolatey' }; Like = "*source must be 'winget' or 'msstore'*" },
            @{ App = @{ id = '7zip.7zip'; scope = 'everyone' }; Like = "*scope must be 'machine' or 'user'*" },
            @{ App = @{ id = '7zip.7zip'; version = '1.0 --force' }; Like = '*invalid version*' },
            @{ App = @{ name = 'no id' }; Like = "*missing 'id'*" }
        )) {
        $data = New-ValidProfile
        $data['applications'] = @($case.App)
        Assert-Like (Get-IssueText $data) $case.Like ('app {0}' -f ($case.App | ConvertTo-Json -Compress))
    }
    $data = New-ValidProfile
    $data['applications'] = @(@{ id = '9WZDNCRFJ3PZ'; source = 'msstore' })
    Assert-Like (Get-IssueText $data -Severity 'Warning') '*cannot be installed as SYSTEM*' 'msstore warning'
    $data['removeApplications'] = @('x y')
    Assert-Like (Get-IssueText $data) '*removeApplications: invalid package id*' 'removeApplications'
}

Test-Case 'Test-ZTProfile: security settings are checked' {
    $cases = @(
        @{ Set = { param($s) $s['bitlocker']['action'] = 'Encrypt' }; Like = '*bitlocker.action*' },
        @{ Set = { param($s) $s['bitlocker']['encryptionMethod'] = 'Aes512' }; Like = '*bitlocker.encryptionMethod*' },
        @{ Set = { param($s) $s['bitlocker'] = 'yes' }; Like = "*'bitlocker' must be an object or false*" },
        @{ Set = { param($s) $s['disableSmb1'] = 'yes' }; Like = "*'disableSmb1' must be true or false*" },
        @{ Set = { param($s) $s['firewall']['defaultInboundAction'] = 'Drop' }; Like = '*firewall.defaultInboundAction*' },
        @{ Set = { param($s) $s['firewall']['rules'] = @(@{ protocol = 'TCP' }) }; Like = "*missing 'displayName'*" },
        @{ Set = { param($s) $s['firewall']['rules'] = @(@{ displayName = 'R*' }) }; Like = '*wildcard*' },
        @{ Set = { param($s) $s['firewall']['rules'] = @(@{ displayName = 'R'; protocol = 'Any'; localPort = '445' }) }; Like = '*needs protocol TCP or UDP*' },
        @{ Set = { param($s) $s['firewall']['rules'] = @(@{ displayName = 'R'; protocol = 'TCP'; localPort = '445;3389' }) }; Like = '*invalid localPort*' },
        @{ Set = { param($s) $s['firewall']['rules'] = @(@{ displayName = 'R'; profile = 'Work' }) }; Like = "*invalid profile 'Work'*" },
        @{ Set = { param($s) $s['firewall']['rules'] = @(@{ displayName = 'R'; remoteAddress = '10.0.0.0/8; calc' }) }; Like = '*invalid remoteAddress*' },
        @{ Set = { param($s) $s['removeBloatware'] = @('*') }; Like = '*too broad*' },
        @{ Set = { param($s) $s['removeBloatware'] = @('Microsoft.Desktop*') }; Like = '*protected system package*' },
        @{ Set = { param($s) $s['removeBloatware'] = @('Microsoft.WindowsStore') }; Like = '*protected system package*' },
        @{ Set = { param($s) $s['removeBloatware'] = @('Microsoft.VCLibs.140.00') }; Like = '*protected system package*' },
        @{ Set = { param($s) $s['removeBloatware'] = @('Bad pattern!') }; Like = '*invalid pattern*' }
    )
    foreach ($case in $cases) {
        $data = New-ValidProfile
        & $case.Set $data['security']
        Assert-Like (Get-IssueText $data) $case.Like ('case {0}' -f $case.Like)
    }
}

Test-Case 'Test-ZTProfile: risky but legal choices produce warnings' {
    $data = New-ValidProfile
    $data['security']['bitlocker']['requireKeyEscrow'] = $false
    $data['security']['firewall']['defaultInboundAction'] = 'Allow'
    $data['security']['ntlm'] = $true
    $data['organization'] = [ordered]@{ language = 'fr' }
    $warnings = Get-IssueText $data -Severity 'Warning'
    Assert-Like $warnings '*requireKeyEscrow is false*' 'escrow warning'
    Assert-Like $warnings '*every inbound connection is accepted*' 'inbound allow warning'
    Assert-Like $warnings "*Unknown security setting 'ntlm'*" 'unknown security key'
    Assert-Like (Get-IssueText $data) "*organization.language 'fr'*" 'unsupported language is an error'
}

Test-Case 'Test-ZTProtectedAppx: winget, the Store, Windows Security and runtimes are protected' {
    foreach ($name in 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsStore', 'Microsoft.SecHealthUI', 'Microsoft.AAD.BrokerPlugin', 'Microsoft.VCLibs.140.00.UWPDesktop', 'MicrosoftWindows.Client.CBS') {
        Assert-True (Test-ZTProtectedAppx -Name $name) ('{0} should be protected' -f $name)
    }
    Assert-True (-not (Test-ZTProtectedAppx -Name 'Microsoft.BingNews')) 'BingNews is not protected'
}

Test-Case 'Repository profiles: every profile loads without errors or warnings' {
    foreach ($file in Get-ChildItem -LiteralPath $RepoProfiles -Filter '*.json' -File) {
        $output = @(Get-ZTProfile -Path $file.FullName 3>&1)
        $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        Assert-Equal 0 $warnings.Count ('warnings in {0}: {1}' -f $file.Name, ($warnings -join ' | '))
        $profileData = $output | Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -First 1
        Assert-Equal $file.BaseName $profileData['name'] ('name of {0}' -f $file.Name)
    }
}

Test-Case 'Get-ZTDepartmentList: lists the departments and hides abstract profiles' {
    $list = @(Get-ZTDepartmentList -ProfilesPath $RepoProfiles)
    Assert-Equal 'comercial,oficina,taller' (($list | ForEach-Object { $_.Name }) -join ',') 'departments'
    Assert-Equal 'Taller' ($list | Where-Object { $_.Name -eq 'taller' }).DisplayName 'display name'
    $all = @(Get-ZTDepartmentList -ProfilesPath $RepoProfiles -IncludeAbstract)
    Assert-Contains ($all | ForEach-Object { $_.Name }) 'base' 'with -IncludeAbstract'
}
