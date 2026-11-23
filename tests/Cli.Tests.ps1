# The command-line scripts, run in a child process exactly as a technician or Intune would run them.
# Only paths that cannot change the machine are exercised here (listing, a typo in the department,
# building a profile into a temporary folder).

$powershell = (Get-Process -Id $PID).Path
$provisionScript = Join-Path $root 'Invoke-ZeroTouch.ps1'
$profileScript = Join-Path $root 'New-DepartmentProfile.ps1'

function Invoke-Script {
    param([string]$Path, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $output = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

Test-Case 'CLI: -ListDepartments shows the departments and hides base' {
    $r = Invoke-Script -Path $provisionScript -Arguments @('-ListDepartments')
    Assert-Equal 0 $r.ExitCode ('exit code. Output: {0}' -f $r.Output)
    foreach ($name in 'oficina', 'taller', 'comercial') { Assert-True ($r.Output -match "\b$name\b") ('{0} listed' -f $name) }
    Assert-True ($r.Output -notmatch 'Base corporativa') 'base (abstract) hidden'
}

Test-Case 'CLI: an unknown department exits with 1 before touching anything' {
    $output = New-TestFolder
    $r = Invoke-Script -Path $provisionScript -Arguments @('-Department', 'contabilidad', '-OutputPath', $output)
    Assert-Equal 1 $r.ExitCode 'exit code'
    Assert-True ($r.Output -match 'Profile not found') ('message. Output: {0}' -f $r.Output)
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $output -Recurse).Count 'nothing written'
}

Test-Case 'CLI: invalid parameters are rejected' {
    $r = Invoke-Script -Path $provisionScript -Arguments @('-Department', 'oficina', '-Language', 'fr')
    Assert-True ($r.ExitCode -ne 0) 'language fr'
}

Test-Case 'CLI: New-DepartmentProfile.ps1 builds a profile from package ids' {
    $output = New-TestFolder
    $r = Invoke-Script -Path $profileScript -Arguments @('-PackageId', 'Zoom.Zoom,SumatraPDF.SumatraPDF', '-Name', 'formacion', '-OutputDirectory', $output)
    Assert-Equal 0 $r.ExitCode ('exit code. Output: {0}' -f $r.Output)
    $saved = [System.IO.File]::ReadAllText((Join-Path $output 'formacion.json')) | ConvertFrom-Json
    Assert-Equal 'Zoom.Zoom,SumatraPDF.SumatraPDF' ((@($saved.applications) | ForEach-Object { $_.id }) -join ',') 'applications'
}

Test-Case 'CLI: help is complete for both scripts' {
    foreach ($script in $provisionScript, $profileScript) {
        $help = Get-Help $script -Full
        Assert-True ([bool]$help.Synopsis -and $help.Synopsis -notlike '*.ps1*') ('synopsis of {0}' -f $script)
        $parameters = (Get-Command $script).Parameters.Keys | Where-Object { [System.Management.Automation.PSCmdlet]::CommonParameters -notcontains $_ -and [System.Management.Automation.PSCmdlet]::OptionalCommonParameters -notcontains $_ }
        foreach ($name in $parameters) {
            $entry = $help.parameters.parameter | Where-Object { $_.name -eq $name }
            Assert-True ([bool](($entry.description | Out-String).Trim())) ('no help for -{0} in {1}' -f $name, (Split-Path $script -Leaf))
        }
        Assert-True (@($help.examples.example).Count -ge 3) ('examples in {0}' -f $script)
    }
}

Test-Case 'CLI: every script parses cleanly' {
    # -Include is ignored together with -LiteralPath on Windows PowerShell 5.1: filter by extension.
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -eq '.ps1' })) {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        Assert-Equal 0 @($errors).Count ('{0}: {1}' -f $file.Name, (@($errors) -join ' | '))
    }
}

Test-Case 'CLI: scripts are ASCII so Windows PowerShell 5.1 reads them correctly' {
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { @('.ps1', '.cmd') -contains $_.Extension })) {
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $offending = @($bytes | Where-Object { $_ -gt 127 }).Count
        Assert-Equal 0 $offending ('non-ASCII bytes in {0}' -f $file.Name)
    }
}

Test-Case 'CLI: the double-click launcher uses CRLF and starts the provisioning script' {
    $text = [System.IO.File]::ReadAllText((Join-Path $root 'Start-ZeroTouch.cmd'))
    Assert-True ($text -notmatch "[^`r]`n") 'only CRLF line endings (cmd.exe misreads LF files)'
    Assert-True ($text.Contains('Invoke-ZeroTouch.ps1')) 'runs Invoke-ZeroTouch.ps1'
    Assert-True ($text.Contains('-Verb RunAs')) 'asks for elevation'
}
