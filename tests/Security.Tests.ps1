# Security guarantees: no script injection in the form, no secrets in any output, no command
# injection through profiles, no path traversal, and a test suite that never touches the real system.

$payload = '"><img src=x onerror=alert(1)><script>alert(2)</script>{{SERIAL}}'''

# Real attributes only: quoted values are removed first, so encoded text inside an attribute is not
# mistaken for an event handler.
function Test-HasEventHandler {
    param([string]$Html)
    foreach ($tag in [regex]::Matches($Html, '<[A-Za-z][^>]*>')) {
        if (($tag.Value -replace '"[^"]*"', '""') -match '\son[a-z]+\s*=') { return $true }
    }
    return $false
}

function Get-InvokedCommand {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
    @($Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Select-Object -Unique)
}

$sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File)

# ---------------------------------------------------------------- the handover form

Test-Case 'XSS: hostile text in every field of the run is shown as text' {
    $run = New-ZTSampleRun
    $run.AssignedUser = $payload
    $run.Technician = $payload
    $run.Notes = $payload
    $run.Organization.Name = $payload
    $run.Organization.ItContact = $payload
    $run.Profile.DisplayName = $payload
    $run.Profile.Description = $payload
    foreach ($property in @($run.Device.PSObject.Properties | Where-Object { $_.Value -is [string] })) {
        $run.Device.($property.Name) = $payload
    }
    foreach ($app in $run.Applications) {
        $app.Name = $payload
        $app.Id = $payload
        $app.Version = $payload
        $app.Arguments = @($payload, $payload, $payload)
    }
    foreach ($result in $run.Security) { $result.Arguments = @($payload, $payload, $payload, $payload) }
    foreach ($printer in $run.Printers) {
        $printer.Name = $payload
        $printer.Address = $payload
        $printer.Driver = $payload
        $printer.Arguments = @($payload, $payload)
    }
    foreach ($language in 'en', 'es') {
        $html = ConvertTo-ZTHandoverHtml -Run $run -Language $language
        Assert-True ($html -notmatch '<img') 'raw <img> rendered'
        Assert-True ($html -notmatch '<script') 'raw <script> rendered'
        Assert-True (-not (Test-HasEventHandler $html)) 'event handler attribute present'
        Assert-True ($html.Contains('&lt;script&gt;alert(2)&lt;/script&gt;')) 'payload shown as text'
        Assert-True ($html.Contains("default-src 'none'")) 'Content Security Policy'
    }
}

Test-Case 'Placeholders inside data are never expanded' {
    $run = New-ZTSampleRun
    $run.AssignedUser = '{{SERIAL}} {{t:title}} {{APPLICATION_ROWS}}'
    $html = ConvertTo-ZTHandoverHtml -Run $run
    Assert-True ($html.Contains('<dd class="fill">{{SERIAL}} {{t:title}} {{APPLICATION_ROWS}}</dd>')) 'data kept literally'
    Assert-Equal 1 ([regex]::Matches($html, '<td class="mono">7zip\.7zip</td>')).Count 'rows inserted once'
}

# ---------------------------------------------------------------- secrets

Test-Case 'The BitLocker recovery password never reaches the console, the log, the form or the JSON' {
    Set-FakeFreshPc
    $script:Fake.Join.EntraJoined = $true
    $output = New-TestFolder
    $console = Invoke-ZTProvisioning -Department 'comercial' -ProfilesPath $RepoProfiles -OutputPath $output -RetryDelaySeconds 0 *>&1 | Out-String
    Assert-Equal 1 @(Get-FakeCall -Name 'Enable-BitLocker').Count 'the laptop was encrypted'
    Assert-True ($console -notlike ('*{0}*' -f $script:FakeRecoveryPassword)) 'console and warnings'
    foreach ($file in Get-ChildItem -LiteralPath $output -Recurse -File) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        Assert-True ($text -notlike ('*{0}*' -f $script:FakeRecoveryPassword)) ('recovery password in {0}' -f $file.Name)
    }
}

Test-Case 'The registry marker holds no personal data or secrets' {
    $source = [System.IO.File]::ReadAllText((Join-Path $root 'src\Provision.ps1'))
    $block = [regex]::Match($source, '(?s)function Set-ZTRegistryMarker.*?\n\}').Value
    foreach ($forbidden in 'AssignedUser', 'Technician', 'Notes', 'Recovery', 'Serial', 'Device') {
        Assert-True ($block -notmatch $forbidden) ('marker writes {0}' -f $forbidden)
    }
}

# ---------------------------------------------------------------- injection and traversal

Test-Case 'Package ids that could inject arguments or commands are refused everywhere' {
    foreach ($id in '7zip.7zip; calc.exe', '7zip.7zip & calc', '7zip.7zip | calc', '$(calc)', '`calc`', '--override', '7zip.7zip --scope user', "7zip.7zip`ncalc", "7zip.7zip`n") {
        Assert-Throws { Install-ZTApplication -Application @{ id = $id } -RetryDelaySeconds 0 } -Like '*Invalid package id*' -What ('install {0}' -f $id)
        $data = [ordered]@{ name = 'x'; applications = @(ConvertTo-ZTAppDefinition -InputObject $id) }
        Assert-True (@(Test-ZTProfile -ProfileData $data | Where-Object { $_.Severity -eq 'Error' }).Count -gt 0) ('profile accepted {0}' -f $id)
    }
    Assert-Equal 0 @(Get-FakeCall -Name 'winget').Count 'winget never ran'
}

Test-Case 'Installer arguments from a profile stay single arguments' {
    $override = '/S" & calc & "'
    Install-ZTApplication -Application @{ id = 'Some.App'; override = $override; custom = '--x "y z"' } -RetryDelaySeconds 0 | Out-Null
    $arguments = @(@(Get-FakeCall -Name 'winget' | Where-Object { $_.Parameters.ArgumentList[0] -eq 'install' })[0].Parameters.ArgumentList)
    $index = [array]::IndexOf($arguments, '--override')
    Assert-Equal $override $arguments[$index + 1] 'override passed verbatim as one argument'
    Assert-Equal '--custom' $arguments[$index + 2] 'next argument'
}

Test-Case 'Path traversal: profile names, parents and computer names cannot leave their folders' {
    foreach ($name in '..\base', '..', 'a/b', 'C:\Windows\x') {
        Assert-Throws { Get-ZTProfile -Name $name -ProfilesPath $RepoProfiles } -What ('profile {0}' -f $name)
    }
    $run = New-ZTSampleRun
    $run.FormId = '..\..\..\Windows\System32\evil'
    $folder = New-TestFolder
    $report = New-ZTHandoverReport -Run $run -OutputDirectory $folder
    Assert-Equal $folder (Split-Path -Path $report.HtmlPath -Parent) 'form written inside the output folder'
    Assert-Equal 'Windows_System32_evil.html' (Split-Path -Path $report.HtmlPath -Leaf) 'sanitised name'
}

Test-Case 'Protected system apps cannot be removed: refused in the profile and skipped at run time' {
    foreach ($pattern in 'Microsoft.DesktopAppInstaller', 'Microsoft.Windows*', 'Microsoft.SecHealth*', 'Microsoft.AAD.BrokerPlugin', 'Microsoft.CompanyPortal', '*Store*') {
        Assert-True (Test-ZTPatternHitsProtected -Pattern $pattern) ('pattern {0} accepted' -f $pattern)
    }
    Add-FakeAppx -Name 'Microsoft.SecHealthUI'
    Invoke-ZTSecurityBaseline -Settings @{ removeBloatware = @('Microsoft.SecHealth*') } | Out-Null
    Assert-Equal 0 @(Get-FakeCall -Name 'Remove-AppxPackage').Count 'Windows Security kept'
}

# ---------------------------------------------------------------- the code itself

Test-Case 'No dynamic code, downloads or remoting in the shipped scripts' {
    $shipped = @($sourceFiles) + @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File)
    foreach ($file in $shipped) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        foreach ($command in Get-InvokedCommand -Ast $ast) {
            Assert-True ($command -notin @('Invoke-Expression', 'iex', 'Add-Type', 'Invoke-WebRequest', 'Invoke-RestMethod', 'iwr', 'irm', 'Invoke-Command', 'Enter-PSSession', 'New-PSSession', 'Start-BitsTransfer')) ('{0} uses {1}' -f $file.Name, $command)
        }
        $text = [System.IO.File]::ReadAllText($file.FullName)
        Assert-True ($text -notmatch 'Net\.WebClient|DownloadString|DownloadFile|FromBase64String|EncodedCommand') ('{0} downloads or decodes code' -f $file.Name)
    }
}

Test-Case 'The tests never run a real system command: everything the source calls is faked or harmless' {
    $mockAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'WindowsMock.ps1'), [ref]$null, [ref]$null)
    $faked = @($mockAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Name })
    $harmless = @('ForEach-Object', 'Where-Object', 'Select-Object', 'Sort-Object', 'Join-Path', 'Split-Path', 'Test-Path', 'Get-Date',
        'Write-Host', 'Write-Verbose', 'Write-Warning', 'ConvertFrom-Json', 'ConvertTo-Json', 'ConvertFrom-Csv', 'Out-Null', 'Add-Member',
        'Get-ChildItem', 'Get-Command', 'Start-Sleep', 'New-Object', 'Import-Module')
    $defined = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($file in $sourceFiles) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defined.Add($function) }
    }
    $definedNames = @($defined | ForEach-Object { $_.Name })
    $checked = 0
    foreach ($function in $defined) {
        if ($faked -contains $function.Name) { continue }
        $checked++
        foreach ($command in Get-InvokedCommand -Ast $function.Body) {
            $ok = ($definedNames -contains $command) -or ($faked -contains $command) -or ($harmless -contains $command)
            Assert-True $ok ('{0} calls {1}, which is neither faked in WindowsMock.ps1 nor known to be harmless' -f $function.Name, $command)
        }
    }
    Assert-True ($checked -gt 40) ('only {0} functions checked' -f $checked)
    foreach ($probe in 'Invoke-ZTWinget', 'Resolve-ZTWingetPath', 'Set-ZTRegistryMarker', 'Get-ZTJoinState', 'ConvertTo-ZTPdf', 'Test-ZTIsAdmin', 'Invoke-ZTPnpUtil') {
        Assert-Contains $faked $probe 'system probes faked'
    }
}

Test-Case 'Repository hygiene: no e-mail addresses, private keys or real output committed' {
    $textExtensions = @('.ps1', '.cmd', '.json', '.html', '.md', '.yml', '.csv', '.txt')
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
            $_.FullName -notmatch '[\\/]\.git[\\/]' -and $textExtensions -contains $_.Extension.ToLowerInvariant()
        })
    Assert-True ($files.Count -gt 20) 'files scanned'
    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        Assert-True ($text -notmatch '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]*[A-Za-z]{2,}') ('e-mail address in {0}' -f $file.Name)
        Assert-True ($text -notmatch '-----BEGIN [A-Z ]*PRIVATE KEY-----') ('private key in {0}' -f $file.Name)
        Assert-True ($text -notmatch 'C:\\Users\\[A-Za-z]') ('user profile path in {0}' -f $file.Name)
    }
    $ignore = [System.IO.File]::ReadAllText((Join-Path $root '.gitignore'))
    foreach ($entry in 'out/', 'Reports/', 'Logs/', '*.intunewin') { Assert-True ($ignore.Contains($entry)) ('.gitignore misses {0}' -f $entry) }
}
