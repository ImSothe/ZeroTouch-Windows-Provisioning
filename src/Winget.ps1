#Requires -Version 5.1
# winget: finding it (also as SYSTEM), running it, and installing applications idempotently.

$script:ZTWingetPath = $null

# winget return codes: https://learn.microsoft.com/windows/package-manager/winget/returncodes
# Convert.ToInt32(hex, 16) gives the signed value winget.exe really returns ($LASTEXITCODE).
$script:ZTWingetCode = @{
    NoApplicationsFound      = [Convert]::ToInt32('8A150014', 16)
    DownloadFailed           = [Convert]::ToInt32('8A150008', 16)
    PackageAlreadyInstalled  = [Convert]::ToInt32('8A150061', 16)
    PackageInUse             = [Convert]::ToInt32('8A150101', 16)
    InstallInProgress        = [Convert]::ToInt32('8A150102', 16)
    FileInUse                = [Convert]::ToInt32('8A150103', 16)
    NoNetwork                = [Convert]::ToInt32('8A150107', 16)
    RebootRequiredToFinish   = [Convert]::ToInt32('8A150109', 16)
    RebootRequiredForInstall = [Convert]::ToInt32('8A15010A', 16)
    RebootInitiated          = [Convert]::ToInt32('8A15010B', 16)
    InstallAlreadyInstalled  = [Convert]::ToInt32('8A15010D', 16)
    BlockedByPolicy          = [Convert]::ToInt32('8A15010F', 16)
}
$script:ZTRetryableCodes = @($script:ZTWingetCode.PackageInUse, $script:ZTWingetCode.InstallInProgress,
    $script:ZTWingetCode.FileInUse, $script:ZTWingetCode.NoNetwork, $script:ZTWingetCode.DownloadFailed)
$script:ZTRebootCodes = @($script:ZTWingetCode.RebootRequiredToFinish, $script:ZTWingetCode.RebootRequiredForInstall,
    $script:ZTWingetCode.RebootInitiated)
$script:ZTAlreadyInstalledCodes = @($script:ZTWingetCode.PackageAlreadyInstalled, $script:ZTWingetCode.InstallAlreadyInstalled)
# Codes with their own explanation in the handover form (message key app.failed.<Name>).
$script:ZTExplainedCodes = @('NoApplicationsFound', 'DownloadFailed', 'PackageInUse', 'InstallInProgress', 'FileInUse',
    'NoNetwork', 'BlockedByPolicy')

function Get-ZTPackageFolderVersion {
    param([Parameter(Mandatory)][string]$Folder)
    # Microsoft.DesktopAppInstaller_1.24.25200.0_x64__8wekyb3d8bbwe -> 1.24.25200.0
    $parts = $Folder -split '_'
    $parsed = $null
    if ($parts.Count -ge 2 -and [version]::TryParse($parts[1], [ref]$parsed)) { return $parsed }
    return [version]'0.0'
}

function Resolve-ZTWingetPath {
    if ($script:ZTWingetPath -and (Test-Path -LiteralPath $script:ZTWingetPath)) { return $script:ZTWingetPath }

    $command = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        $script:ZTWingetPath = $command.Source
        return $script:ZTWingetPath
    }

    # As SYSTEM (Intune, scheduled tasks) winget is not on the PATH: use the App Installer
    # package folder directly, newest version first.
    $pattern = Join-Path -Path $env:ProgramFiles -ChildPath 'WindowsApps\Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe'
    $folders = @(Resolve-Path -Path $pattern -ErrorAction SilentlyContinue |
        Sort-Object -Property @{ Expression = { Get-ZTPackageFolderVersion -Folder (Split-Path -Path $_.Path -Leaf) } } -Descending)
    foreach ($folder in $folders) {
        $candidate = Join-Path -Path $folder.Path -ChildPath 'winget.exe'
        if (Test-Path -LiteralPath $candidate) {
            $script:ZTWingetPath = $candidate
            return $script:ZTWingetPath
        }
    }
    throw ('winget (App Installer) was not found. Update "App Installer" from the Microsoft Store, ' +
        'or sign in once as a user so that Windows registers it.')
}

# winget redraws its spinner and progress bar with carriage returns. Keep the final text of
# each line and drop the progress noise.
function ConvertFrom-ZTWingetOutput {
    param([AllowNull()][object[]]$Lines)
    $clean = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($raw in @($Lines)) {
        if ($null -eq $raw) { continue }
        $text = @(([string]$raw -split "`r") | Where-Object { $_.Trim() }) | Select-Object -Last 1
        if (-not $text) { continue }
        if ($text -match '^\s*[-\\|/]\s*$') { continue }
        if ($text -match '[\u2580-\u259F]') { continue }
        if ($text -match '^\s*\d{1,3}\s*%\s*$') { continue }
        $clean.Add($text.Trim())
    }
    , $clean.ToArray()
}

function Invoke-ZTWinget {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $winget = Resolve-ZTWingetPath
    # On Windows PowerShell 5.1, native stderr redirected with 2>&1 would become a terminating
    # error under ErrorActionPreference = Stop.
    $ErrorActionPreference = 'Continue'
    $previousEncoding = $null
    try {
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
    catch {
        $previousEncoding = $null
    }
    # Running from the package folder lets winget find its own dependencies when started as SYSTEM.
    Push-Location -LiteralPath (Split-Path -Path $winget -Parent)
    try {
        $raw = @(& $winget @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
        if ($null -ne $previousEncoding) {
            try { [Console]::OutputEncoding = $previousEncoding }
            catch { Write-Verbose 'Could not restore the console encoding.' }
        }
    }
    [pscustomobject]@{ ExitCode = [int]$exitCode; Output = (ConvertFrom-ZTWingetOutput -Lines $raw) }
}

# Version column of a 'winget list' row: the token after the package id. The id is matched
# as a whole token, the last one on the line, so a name containing the id does not confuse it.
function Get-ZTVersionFromList {
    param([AllowNull()][object[]]$Lines, [Parameter(Mandatory)][string]$Id)
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        $tokens = @(([string]$line).Trim() -split '\s+')
        $position = -1
        for ($k = 0; $k -lt $tokens.Count; $k++) {
            if ($tokens[$k] -eq $Id) { $position = $k }
        }
        if ($position -ge 0 -and $position + 1 -lt $tokens.Count) {
            $version = $tokens[$position + 1]
            if (($version -eq '<' -or $version -eq '>') -and $position + 2 -lt $tokens.Count) {
                $version = $version + ' ' + $tokens[$position + 2]
            }
            return $version
        }
    }
    return ''
}

# Installed version, '' when installed but the version could not be read, $null when not installed.
function Get-ZTInstalledVersion {
    param([Parameter(Mandatory)][string]$Id, [string]$Source = 'winget')
    $arguments = @('list', '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ($Source) { $arguments += @('--source', $Source) }
    $result = Invoke-ZTWinget -ArgumentList $arguments
    if ($result.ExitCode -ne 0) { return $null }
    Get-ZTVersionFromList -Lines $result.Output -Id $Id
}

# The winget command line as an argument array: never a concatenated string, so a value from a
# profile cannot inject extra arguments or commands.
function Get-ZTInstallArgument {
    param([Parameter(Mandatory)]$Application)
    $arguments = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($item in @('install', '--id', $Application['id'], '--exact', '--source', $Application['source'], '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')) {
        $arguments.Add([string]$item)
    }
    foreach ($option in @('scope', 'version', 'override', 'custom')) {
        if ($Application[$option]) {
            $arguments.Add('--' + $option)
            $arguments.Add([string]$Application[$option])
        }
    }
    , $arguments.ToArray()
}

function New-ZTAppResult {
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)][ValidateSet('Installed', 'AlreadyInstalled', 'Failed', 'WhatIf')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [object[]]$Arguments = @(),
        [AllowEmptyString()][string]$Version = '',
        $ExitCode = $null,
        [int]$Attempts = 0,
        [switch]$RebootRequired
    )
    $text = @($Arguments | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        Id             = [string]$Application['id']
        Name           = [string]$Application['name']
        Required       = [bool]$Application['required']
        Status         = $Status
        Version        = $Version
        ExitCode       = $ExitCode
        Attempts       = $Attempts
        RebootRequired = [bool]$RebootRequired
        Message        = $Message
        Arguments      = $text
        Detail         = Format-ZTMessage -Key $Message -Arguments $text
    }
}

<#
.SYNOPSIS
    Installs one application with winget, silently and only if it is not installed yet.
.DESCRIPTION
    Checks 'winget list' first (idempotent: running the provisioning twice does not reinstall
    anything), retries transient failures (package in use, another install running, network),
    and maps winget's return codes to Installed / AlreadyInstalled / Failed, with reboot detection.
#>
function Install-ZTApplication {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Application,
        [ValidateRange(0, 10)][int]$MaxRetries = 2,
        [ValidateRange(0, 600)][int]$RetryDelaySeconds = 20
    )
    $app = ConvertTo-ZTAppDefinition -InputObject $Application
    if ([string]$app['id'] -notmatch $script:ZTPackageIdPattern) { throw ("Invalid package id '{0}'." -f $app['id']) }

    $installed = Get-ZTInstalledVersion -Id $app['id'] -Source $app['source']
    if ($null -ne $installed) {
        return New-ZTAppResult -Application $app -Status 'AlreadyInstalled' -Message 'app.alreadyInstalled' -Version $installed -ExitCode 0
    }
    if (-not $PSCmdlet.ShouldProcess(('{0} ({1})' -f $app['name'], $app['id']), 'Install with winget')) {
        return New-ZTAppResult -Application $app -Status 'WhatIf' -Message 'app.whatIf'
    }

    $arguments = Get-ZTInstallArgument -Application $app
    $attempt = 0
    while ($true) {
        $attempt++
        $run = Invoke-ZTWinget -ArgumentList $arguments
        $code = [int]$run.ExitCode
        if ($script:ZTRetryableCodes -contains $code -and $attempt -le $MaxRetries) {
            Write-ZTLog ('{0}: winget returned 0x{1:X8}, retrying in {2} s ({3}/{4}).' -f $app['id'], $code, $RetryDelaySeconds, $attempt, $MaxRetries) -Level Warning
            if ($RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $RetryDelaySeconds }
            continue
        }
        break
    }

    $hex = '0x{0:X8}' -f $code
    $succeeded = $code -eq 0 -or $script:ZTRebootCodes -contains $code -or $script:ZTAlreadyInstalledCodes -contains $code
    if ($succeeded) {
        $version = Get-ZTInstalledVersion -Id $app['id'] -Source $app['source']
        if (-not $version) { $version = [string]$app['version'] }
        if ($script:ZTRebootCodes -contains $code) {
            return New-ZTAppResult -Application $app -Status 'Installed' -Message 'app.installedReboot' -Version $version -ExitCode $code -Attempts $attempt -RebootRequired
        }
        if ($script:ZTAlreadyInstalledCodes -contains $code) {
            return New-ZTAppResult -Application $app -Status 'AlreadyInstalled' -Message 'app.alreadyInstalled' -Version $version -ExitCode $code -Attempts $attempt
        }
        return New-ZTAppResult -Application $app -Status 'Installed' -Message 'app.installed' -Version $version -ExitCode $code -Attempts $attempt
    }

    $messageKey = 'app.failed.other'
    foreach ($name in $script:ZTExplainedCodes) {
        if ($script:ZTWingetCode[$name] -eq $code) { $messageKey = 'app.failed.' + $name }
    }
    $reason = ''
    $lastLine = @($run.Output) | Select-Object -Last 1
    if ($lastLine) { $reason = ([string]$lastLine).Substring(0, [math]::Min(200, ([string]$lastLine).Length)) }
    New-ZTAppResult -Application $app -Status 'Failed' -Message $messageKey -Arguments @($hex, $reason) -ExitCode $code -Attempts $attempt
}
