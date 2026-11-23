# Application installs through winget (against the fake winget in WindowsMock.ps1).

function Get-WingetCalls {
    param([string]$Verb)
    @(Get-FakeCall -Name 'winget' | Where-Object { $_.Parameters.ArgumentList[0] -eq $Verb })
}

Test-Case 'Install-ZTApplication: an installed application is left alone and its version reported' {
    $script:Fake.Winget.Installed['7zip.7zip'] = '24.08'
    $r = Install-ZTApplication -Application '7zip.7zip' -RetryDelaySeconds 0
    Assert-Equal 'AlreadyInstalled' $r.Status 'status'
    Assert-Equal '24.08' $r.Version 'version'
    Assert-Equal 0 @(Get-WingetCalls 'install').Count 'install calls'
    Assert-Equal 'app.alreadyInstalled' $r.Message 'message key'
}

Test-Case 'Install-ZTApplication: silent install with the exact id, as an argument array' {
    $script:Fake.Winget.Versions['Google.Chrome'] = '131.0.6778.86'
    $app = @{ id = 'Google.Chrome'; name = 'Google Chrome'; scope = 'machine'; override = '/quiet ALLUSERS=1 "INSTALLDIR=C:\Program Files\X"' }
    $r = Install-ZTApplication -Application $app -RetryDelaySeconds 0
    Assert-Equal 'Installed' $r.Status 'status'
    Assert-Equal '131.0.6778.86' $r.Version 'version read back after install'
    $arguments = @((Get-WingetCalls 'install')[0].Parameters.ArgumentList)
    $expected = @('install', '--id', 'Google.Chrome', '--exact', '--source', 'winget', '--silent', '--accept-package-agreements',
        '--accept-source-agreements', '--disable-interactivity', '--scope', 'machine', '--override', '/quiet ALLUSERS=1 "INSTALLDIR=C:\Program Files\X"')
    Assert-Equal ($expected -join '|') ($arguments -join '|') 'winget arguments'
    Assert-Equal $expected.Count $arguments.Count 'override passed as one argument'
}

Test-Case 'Install-ZTApplication: pinned versions and msstore sources are passed through' {
    $r = Install-ZTApplication -Application @{ id = '9WZDNCRFJ3PZ'; source = 'msstore'; version = '1.2.3' } -RetryDelaySeconds 0
    Assert-Equal 'Installed' $r.Status 'status'
    $joined = (@((Get-WingetCalls 'install')[0].Parameters.ArgumentList)) -join ' '
    Assert-Like $joined '*--source msstore*' 'source'
    Assert-Like $joined '*--version 1.2.3*' 'version'
}

Test-Case 'Install-ZTApplication: transient failures are retried until they succeed' {
    Set-FakeInstallResult -Id 'WinSCP.WinSCP' -Codes @($script:ZTWingetCode.PackageInUse, $script:ZTWingetCode.InstallInProgress)
    $r = Install-ZTApplication -Application 'WinSCP.WinSCP' -MaxRetries 2 -RetryDelaySeconds 0
    Assert-Equal 'Installed' $r.Status 'status'
    Assert-Equal 3 $r.Attempts 'attempts'
    Assert-Equal 3 @(Get-WingetCalls 'install').Count 'install calls'
}

Test-Case 'Install-ZTApplication: gives up after MaxRetries with an explained error' {
    Set-FakeInstallResult -Id 'WinSCP.WinSCP' -Codes @($script:ZTWingetCode.PackageInUse, $script:ZTWingetCode.PackageInUse, $script:ZTWingetCode.PackageInUse)
    $r = Install-ZTApplication -Application 'WinSCP.WinSCP' -MaxRetries 1 -RetryDelaySeconds 0
    Assert-Equal 'Failed' $r.Status 'status'
    Assert-Equal 2 $r.Attempts 'attempts'
    Assert-Equal 'app.failed.PackageInUse' $r.Message 'message key'
    Assert-Like $r.Detail '*in use*0x8A150101*' 'detail'
}

Test-Case 'Install-ZTApplication: non-transient failures are not retried and keep the installer message' {
    Set-FakeInstallResult -Id 'Bad.Package' -Codes @(1603)
    $r = Install-ZTApplication -Application 'Bad.Package' -MaxRetries 3 -RetryDelaySeconds 0
    Assert-Equal 'Failed' $r.Status 'status'
    Assert-Equal 1 $r.Attempts 'attempts'
    Assert-Equal 'app.failed.other' $r.Message 'message key'
    Assert-Equal '0x00000643' $r.Arguments[0] 'hex code'
    Assert-Equal 'Installer failed with exit code: 1603' $r.Arguments[1] 'installer message'
    Assert-Equal 1603 $r.ExitCode 'exit code'
}

Test-Case 'Install-ZTApplication: reboot-required codes count as installed and flag the restart' {
    Set-FakeInstallResult -Id 'Microsoft.Office' -Codes @($script:ZTWingetCode.RebootRequiredToFinish)
    $r = Install-ZTApplication -Application 'Microsoft.Office' -RetryDelaySeconds 0
    Assert-Equal 'Installed' $r.Status 'status'
    Assert-True $r.RebootRequired 'reboot flag'
    Assert-Equal 'app.installedReboot' $r.Message 'message key'
}

Test-Case 'Install-ZTApplication: "already installed" returned by install is not a failure' {
    Set-FakeInstallResult -Id 'Zoom.Zoom' -Codes @($script:ZTWingetCode.InstallAlreadyInstalled)
    $r = Install-ZTApplication -Application 'Zoom.Zoom' -RetryDelaySeconds 0
    Assert-Equal 'AlreadyInstalled' $r.Status 'status'
}

Test-Case 'Install-ZTApplication: -WhatIf checks but does not install' {
    $r = Install-ZTApplication -Application 'Zoom.Zoom' -RetryDelaySeconds 0 -WhatIf
    Assert-Equal 'WhatIf' $r.Status 'status'
    Assert-Equal 1 @(Get-WingetCalls 'list').Count 'list calls'
    Assert-Equal 0 @(Get-WingetCalls 'install').Count 'install calls'
}

Test-Case 'Install-ZTApplication: an invalid id is refused before winget runs' {
    foreach ($id in '7zip.7zip; calc', '--source x', '7zip.7zip && calc', '$(calc)', '') {
        Assert-Throws { Install-ZTApplication -Application @{ id = $id } -RetryDelaySeconds 0 } -Like '*Invalid package id*' -What ('id "{0}"' -f $id)
    }
    Assert-Equal 0 @(Get-FakeCall -Name 'winget').Count 'winget calls'
}

Test-Case 'Get-ZTVersionFromList: reads the version column by token, not by position' {
    $lines = @('Name                    Id              Version   Source', '------------------------------------------------', '7zip.7zip launcher 24   7zip.7zip       24.08     winget')
    Assert-Equal '24.08' (Get-ZTVersionFromList -Lines $lines -Id '7zip.7zip') 'name containing the id'
    Assert-Equal '< 2.0' (Get-ZTVersionFromList -Lines @('Old App  Old.App  < 2.0  winget') -Id 'Old.App') 'version range'
    Assert-Equal '' (Get-ZTVersionFromList -Lines @('No installed package found.') -Id 'X.Y') 'not found'
}

Test-Case 'ConvertFrom-ZTWingetOutput: drops the spinner and progress bar' {
    $bar = ([string][char]0x2588) * 12 + ([string][char]0x2592) * 8
    $raw = @('   - ', '   \ ', ('  {0}  1.00 MB / 2.00 MB' -f $bar), "Downloading`r  $bar 50%`rSuccessfully verified installer hash", '  45%', '', 'Successfully installed')
    $clean = ConvertFrom-ZTWingetOutput -Lines $raw
    Assert-Equal 'Successfully verified installer hash|Successfully installed' ($clean -join '|') 'clean output'
}

Test-Case 'Get-ZTPackageFolderVersion: picks the newest App Installer folder by version, not by name' {
    Assert-Equal '1.24.25200.0' (Get-ZTPackageFolderVersion -Folder 'Microsoft.DesktopAppInstaller_1.24.25200.0_x64__8wekyb3d8bbwe').ToString() 'parsed'
    Assert-True ((Get-ZTPackageFolderVersion -Folder 'Microsoft.DesktopAppInstaller_1.9.0.0_x64__8wekyb3d8bbwe') -lt (Get-ZTPackageFolderVersion -Folder 'Microsoft.DesktopAppInstaller_1.24.0.0_x64__8wekyb3d8bbwe')) '1.9 < 1.24'
    Assert-Equal '0.0' (Get-ZTPackageFolderVersion -Folder 'garbage').ToString() 'unparseable'
}

Test-Case 'winget return codes are the signed values winget.exe reports' {
    Assert-Equal -1978335212 $script:ZTWingetCode.NoApplicationsFound 'NoApplicationsFound'
    Assert-Equal -1978334975 $script:ZTWingetCode.PackageInUse 'PackageInUse'
    Assert-Equal -1978334967 $script:ZTWingetCode.RebootRequiredToFinish 'RebootRequiredToFinish'
}
