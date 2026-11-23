#Requires -Version 5.1
# Department profiles: loading, inheritance ("extends"), normalisation and validation.

$script:ZTProfileKeys = @('$schema', 'name', 'displayName', 'description', 'extends', 'abstract', 'organization',
    'applications', 'removeApplications', 'printers', 'security', 'sourceFiles')
$script:ZTApplicationKeys = @('id', 'name', 'source', 'scope', 'version', 'override', 'custom', 'required')
$script:ZTSecurityKeys = @('bitlocker', 'disableSmb1', 'firewall', 'removeBloatware')

# winget identifiers: Publisher.Package with letters, digits and . + _ -  (Notepad++.Notepad++,
# Mozilla.Firefox.es-ES, 9NBLGGH4NNS1 for msstore). Anything else is rejected before it gets near
# a command line. \z (not $) so that a trailing newline cannot slip through.
$script:ZTPackageIdPattern = '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}\z'
# Profile names double as file names: no dots, slashes or spaces, so no path traversal.
$script:ZTProfileNamePattern = '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z'
$script:ZTPortPattern = '^(Any|\d{1,5}(-\d{1,5})?(,\d{1,5}(-\d{1,5})?)*)\z'
$script:ZTAddressPattern = '^[A-Za-z0-9.:/,_-]+\z'

# Appx packages that must never be removed, whatever a profile says: winget itself, the Store,
# Windows Security, Entra ID sign-in, Intune's Company Portal, OOBE/Autopilot and the shell.
$script:ZTProtectedAppx = @(
    'Microsoft.DesktopAppInstaller',
    'Microsoft.WindowsStore',
    'Microsoft.StorePurchaseApp',
    'Microsoft.SecHealthUI',
    'Microsoft.AAD.BrokerPlugin',
    'Microsoft.AccountsControl',
    'Microsoft.CompanyPortal',
    'Microsoft.Windows.CloudExperienceHost',
    'Microsoft.Windows.ShellExperienceHost',
    'Microsoft.Windows.StartMenuExperienceHost',
    'Microsoft.LockApp',
    'windows.immersivecontrolpanel',
    'MicrosoftWindows.Client.*',
    'Microsoft.VCLibs.*',
    'Microsoft.UI.Xaml.*',
    'Microsoft.NET.Native.*',
    'Microsoft.WindowsAppRuntime.*'
)

function Test-ZTProtectedAppx {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($pattern in $script:ZTProtectedAppx) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

# True when a removal pattern from a profile could match a protected package, in either direction:
# 'Microsoft.Windows*' would hit Microsoft.WindowsStore, 'Microsoft.VCLibs.140.00' is covered by 'Microsoft.VCLibs.*'.
function Test-ZTPatternHitsProtected {
    param([Parameter(Mandatory)][string]$Pattern)
    foreach ($protected in $script:ZTProtectedAppx) {
        if ($Pattern -like $protected) { return $true }
        if ($protected.Replace('*', '') -like $Pattern) { return $true }
    }
    return $false
}

# One application entry, from either the short form ("7zip.7zip") or the object form.
function ConvertTo-ZTAppDefinition {
    param([AllowNull()]$InputObject)
    if ($InputObject -is [string]) {
        $source = @{ id = $InputObject }
    }
    elseif ($InputObject -is [System.Collections.IDictionary]) {
        $source = $InputObject
    }
    else {
        $source = ConvertTo-ZTHashtable -InputObject $InputObject
    }
    if ($source -isnot [System.Collections.IDictionary]) { $source = @{} }

    $definition = [ordered]@{
        id       = [string]$source['id']
        name     = [string]$source['name']
        source   = [string]$source['source']
        scope    = [string]$source['scope']
        version  = [string]$source['version']
        override = [string]$source['override']
        custom   = [string]$source['custom']
        required = $true
    }
    if (-not $definition['name']) { $definition['name'] = $definition['id'] }
    if (-not $definition['source']) { $definition['source'] = 'winget' }
    if ($source.Contains('required') -and $null -ne $source['required']) { $definition['required'] = [bool]$source['required'] }
    $definition
}

function Read-ZTProfileFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [System.Collections.Generic.List[string]]$Chain
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ("Profile not found: {0}" -f $Path) }
    foreach ($seen in $Chain) {
        if ($seen -eq $Path) { throw ('Circular inheritance: {0} -> {1}' -f ($Chain -join ' -> '), $Path) }
    }
    if ($Chain.Count -ge 5) { throw ('Too many inheritance levels (maximum 5): {0}' -f ($Chain -join ' -> ')) }
    $Chain.Add($Path)

    $data = Read-ZTJsonFile -Path $Path
    if ($data -isnot [System.Collections.IDictionary]) { throw ("Profile '{0}' must contain a JSON object." -f $Path) }

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if (-not $data.Contains('name') -or -not $data['name']) { $data['name'] = $fileName }
    elseif ([string]$data['name'] -ne $fileName) {
        Write-Warning ("Profile '{0}': name '{1}' differs from the file name; '{1}' will be used in reports." -f $Path, $data['name'])
    }
    if (-not $data.Contains('displayName') -or -not $data['displayName']) { $data['displayName'] = $data['name'] }
    if (-not $data.Contains('description')) { $data['description'] = '' }
    $data['abstract'] = [bool]$data['abstract']

    $applications = New-Object -TypeName System.Collections.Generic.List[object]
    if ($null -ne $data['applications']) {
        foreach ($app in @($data['applications'])) {
            if ($app -is [System.Collections.IDictionary]) {
                foreach ($key in $app.Keys) {
                    if ($script:ZTApplicationKeys -notcontains $key) {
                        Write-Warning ("Profile '{0}': unknown key '{1}' in application '{2}' (typo?). It is ignored." -f $data['name'], $key, $app['id'])
                    }
                }
            }
            $applications.Add((ConvertTo-ZTAppDefinition -InputObject $app))
        }
    }
    $data['applications'] = $applications.ToArray()

    $parentName = ([string]$data['extends']) -replace '\.json$', ''
    if (-not $parentName) { return $data }
    if ($parentName -notmatch $script:ZTProfileNamePattern) { throw ("Profile '{0}': invalid 'extends' value '{1}'." -f $data['name'], $parentName) }

    $parentPath = Join-Path -Path (Split-Path -Path $Path -Parent) -ChildPath ($parentName + '.json')
    $parent = Read-ZTProfileFile -Path $parentPath -Chain $Chain

    $remove = @(@($data['removeApplications']) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ($remove.Count -gt 0) {
        $parent['applications'] = @($parent['applications'] | Where-Object { $remove -notcontains ([string]$_['id']).ToLowerInvariant() })
    }
    foreach ($ownKey in @('abstract', 'removeApplications')) {
        if ($parent.Contains($ownKey)) { $parent.Remove($ownKey) }
    }
    Merge-ZTValue -Base $parent -Override $data
}

<#
.SYNOPSIS
    Loads a department profile, resolves its inheritance chain and validates the result.
#>
function Get-ZTProfile {
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByName', Position = 0)][string]$Name,
        [Parameter(ParameterSetName = 'ByName')][string]$ProfilesPath = $script:ZTProfilesPath,
        [Parameter(Mandatory, ParameterSetName = 'ByPath')][string]$Path,
        [switch]$SkipValidation
    )
    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        $Name = $Name -replace '\.json$', ''
        if ($Name -notmatch $script:ZTProfileNamePattern) {
            throw ("Invalid profile name '{0}': use letters, digits, '-' or '_'." -f $Name)
        }
        $Path = Join-Path -Path $ProfilesPath -ChildPath ($Name + '.json')
    }
    $chain = New-Object -TypeName System.Collections.Generic.List[string]
    $data = Read-ZTProfileFile -Path (Resolve-ZTPath -Path $Path) -Chain $chain
    $data['sourceFiles'] = $chain.ToArray()

    if (-not $SkipValidation) {
        $issues = @(Test-ZTProfile -ProfileData $data)
        foreach ($warning in @($issues | Where-Object { $_.Severity -eq 'Warning' })) { Write-Warning $warning.Message }
        $errors = @($issues | Where-Object { $_.Severity -eq 'Error' })
        if ($errors.Count -gt 0) {
            $list = ($errors | ForEach-Object { ' - ' + $_.Message }) -join [Environment]::NewLine
            throw ("Profile '{0}' is not valid:{1}{2}" -f $data['name'], [Environment]::NewLine, $list)
        }
    }
    $data
}

<#
.SYNOPSIS
    Validates a loaded (merged) profile. Returns one object per issue: Severity (Error/Warning), Message.
#>
function Test-ZTProfile {
    param([Parameter(Mandatory)]$ProfileData)
    $issues = New-Object -TypeName System.Collections.Generic.List[object]
    function Add-Issue {
        param([string]$Severity, [string]$Message)
        $issues.Add([pscustomobject]@{ Severity = $Severity; Message = $Message })
    }

    if ($ProfileData -isnot [System.Collections.IDictionary]) {
        Add-Issue 'Error' 'The profile must be a JSON object.'
        return $issues.ToArray()
    }
    foreach ($key in $ProfileData.Keys) {
        if ($script:ZTProfileKeys -notcontains $key) { Add-Issue 'Warning' ("Unknown key '{0}' (typo?). It is ignored." -f $key) }
    }
    if (-not $ProfileData['name']) { Add-Issue 'Error' "Missing 'name'." }
    elseif ([string]$ProfileData['name'] -notmatch $script:ZTProfileNamePattern) {
        Add-Issue 'Error' ("Invalid name '{0}': use letters, digits, '-' or '_'." -f $ProfileData['name'])
    }

    $organization = $ProfileData['organization']
    if ($null -ne $organization) {
        if ($organization -isnot [System.Collections.IDictionary]) { Add-Issue 'Error' "'organization' must be an object." }
        elseif ($organization['language'] -and $script:ZTLanguages -notcontains [string]$organization['language']) {
            Add-Issue 'Error' ("organization.language '{0}' is not supported (use {1})." -f $organization['language'], ($script:ZTLanguages -join ', '))
        }
    }

    # ---- applications
    $seen = @{}
    $index = 0
    foreach ($entry in @($ProfileData['applications'])) {
        if ($null -eq $entry) { continue }
        $index++
        $app = ConvertTo-ZTAppDefinition -InputObject $entry
        $id = [string]$app['id']
        $label = 'applications[{0}]' -f $index
        if (-not $id) { Add-Issue 'Error' ("{0}: missing 'id'." -f $label); continue }
        if ($id -notmatch $script:ZTPackageIdPattern) { Add-Issue 'Error' ("{0}: invalid package id '{1}'." -f $label, $id) }
        $key = $id.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { Add-Issue 'Warning' ("{0}: '{1}' is listed twice." -f $label, $id) } else { $seen[$key] = $true }
        if (@('winget', 'msstore') -notcontains $app['source']) { Add-Issue 'Error' ("{0} ({1}): source must be 'winget' or 'msstore'." -f $label, $id) }
        if ($app['source'] -eq 'msstore') { Add-Issue 'Warning' ("{0} ({1}): Microsoft Store apps cannot be installed as SYSTEM (Intune)." -f $label, $id) }
        if ($app['scope'] -and @('machine', 'user') -notcontains $app['scope']) { Add-Issue 'Error' ("{0} ({1}): scope must be 'machine' or 'user'." -f $label, $id) }
        if ($app['version'] -and $app['version'] -notmatch '^[A-Za-z0-9.+_-]{1,64}\z') { Add-Issue 'Error' ("{0} ({1}): invalid version '{2}'." -f $label, $id, $app['version']) }
    }
    foreach ($removed in @($ProfileData['removeApplications'])) {
        if ($removed -and [string]$removed -notmatch $script:ZTPackageIdPattern) { Add-Issue 'Error' ("removeApplications: invalid package id '{0}'." -f $removed) }
    }

    # ---- printers
    $printerIndex = 0
    foreach ($entry in @($ProfileData['printers'])) {
        if ($null -eq $entry) { continue }
        $printerIndex++
        $label = 'printers[{0}]' -f $printerIndex
        if ($entry -isnot [System.Collections.IDictionary]) { Add-Issue 'Error' ("{0} must be an object." -f $label); continue }
        foreach ($key in $entry.Keys) {
            if ($script:ZTPrinterKeys -notcontains $key) { Add-Issue 'Warning' ("{0}: unknown key '{1}' (typo?). It is ignored." -f $label, $key) }
        }
        $printer = ConvertTo-ZTPrinterDefinition -InputObject $entry
        if (-not $printer['name']) { Add-Issue 'Error' ("{0}: missing 'name'." -f $label) }
        elseif ($printer['name'] -notmatch $script:ZTPrinterNamePattern) { Add-Issue 'Error' ("{0}: name '{1}' cannot contain [ ] * ? \ , or quotes." -f $label, $printer['name']) }
        if (-not $printer['address']) { Add-Issue 'Error' ("{0}: missing 'address' (IP address or host name)." -f $label) }
        elseif ($printer['address'] -notmatch $script:ZTPrinterAddressPattern) { Add-Issue 'Error' ("{0}: invalid address '{1}'." -f $label, $printer['address']) }
        if (-not $printer['driver']) { Add-Issue 'Error' ("{0}: missing 'driver' (exact driver name, as Get-PrinterDriver shows it)." -f $label) }
        elseif ($printer['driver'].Length -gt 200 -or $printer['driver'] -match '["\r\n]') { Add-Issue 'Error' ("{0}: invalid driver name." -f $label) }
        if ($printer['port'] -lt 1 -or $printer['port'] -gt 65535) { Add-Issue 'Error' ("{0}: port must be a number from 1 to 65535." -f $label) }
        if ($printer['driverInf'] -and $printer['driverInf'] -notmatch $script:ZTInfPathPattern) { Add-Issue 'Error' ("{0}: driverInf must be the full path of an .inf file (C:\... or \\server\...)." -f $label) }
    }

    # ---- security
    $security = $ProfileData['security']
    if ($null -eq $security) { return $issues.ToArray() }
    if ($security -isnot [System.Collections.IDictionary]) {
        Add-Issue 'Error' "'security' must be an object."
        return $issues.ToArray()
    }
    foreach ($key in $security.Keys) {
        if ($script:ZTSecurityKeys -notcontains $key) { Add-Issue 'Warning' ("Unknown security setting '{0}' (typo?). It is ignored." -f $key) }
    }

    $bitlocker = $security['bitlocker']
    if ($bitlocker -is [System.Collections.IDictionary]) {
        if ($bitlocker['action'] -and @('Report', 'Enable') -notcontains [string]$bitlocker['action']) {
            Add-Issue 'Error' ("bitlocker.action '{0}' is not valid (Report or Enable)." -f $bitlocker['action'])
        }
        if ($bitlocker['encryptionMethod'] -and @('XtsAes128', 'XtsAes256', 'Aes128', 'Aes256') -notcontains [string]$bitlocker['encryptionMethod']) {
            Add-Issue 'Error' ("bitlocker.encryptionMethod '{0}' is not valid (XtsAes128, XtsAes256, Aes128, Aes256)." -f $bitlocker['encryptionMethod'])
        }
        if ($bitlocker.Contains('requireKeyEscrow') -and $bitlocker['requireKeyEscrow'] -eq $false) {
            Add-Issue 'Warning' 'bitlocker.requireKeyEscrow is false: disks can be encrypted without a recovery key stored anywhere.'
        }
    }
    elseif ($null -ne $bitlocker -and $bitlocker -isnot [bool]) {
        Add-Issue 'Error' "'bitlocker' must be an object or false."
    }

    if ($security.Contains('disableSmb1') -and $security['disableSmb1'] -isnot [bool]) {
        Add-Issue 'Error' "'disableSmb1' must be true or false."
    }

    $firewall = $security['firewall']
    if ($firewall -is [System.Collections.IDictionary]) {
        foreach ($setting in @('defaultInboundAction', 'defaultOutboundAction')) {
            if ($firewall[$setting] -and @('Block', 'Allow') -notcontains [string]$firewall[$setting]) {
                Add-Issue 'Error' ("firewall.{0} must be 'Block' or 'Allow'." -f $setting)
            }
        }
        if ($firewall['defaultInboundAction'] -eq 'Allow') { Add-Issue 'Warning' 'firewall.defaultInboundAction is Allow: every inbound connection is accepted.' }
        $ruleIndex = 0
        foreach ($rule in @($firewall['rules'])) {
            if ($null -eq $rule) { continue }
            $ruleIndex++
            $label = 'firewall.rules[{0}]' -f $ruleIndex
            if ($rule -isnot [System.Collections.IDictionary]) { Add-Issue 'Error' ("{0} must be an object." -f $label); continue }
            if (-not $rule['displayName']) { Add-Issue 'Error' ("{0}: missing 'displayName'." -f $label) }
            elseif ([string]$rule['displayName'] -match '[\[\]\*\?]') { Add-Issue 'Error' ("{0}: displayName cannot contain wildcard characters." -f $label) }
            if ($rule['direction'] -and @('Inbound', 'Outbound') -notcontains [string]$rule['direction']) { Add-Issue 'Error' ("{0}: direction must be Inbound or Outbound." -f $label) }
            if ($rule['action'] -and @('Allow', 'Block') -notcontains [string]$rule['action']) { Add-Issue 'Error' ("{0}: action must be Allow or Block." -f $label) }
            $protocol = [string]$rule['protocol']
            if ($protocol -and @('TCP', 'UDP', 'ICMPv4', 'ICMPv6', 'Any') -notcontains $protocol) { Add-Issue 'Error' ("{0}: protocol must be TCP, UDP, ICMPv4, ICMPv6 or Any." -f $label) }
            foreach ($portKey in @('localPort', 'remotePort')) {
                if (-not $rule[$portKey]) { continue }
                if ([string]$rule[$portKey] -notmatch $script:ZTPortPattern) { Add-Issue 'Error' ("{0}: invalid {1} '{2}'." -f $label, $portKey, $rule[$portKey]) }
                if (@('TCP', 'UDP') -notcontains $protocol) { Add-Issue 'Error' ("{0}: {1} needs protocol TCP or UDP." -f $label, $portKey) }
            }
            if ($rule['remoteAddress'] -and [string]$rule['remoteAddress'] -notmatch $script:ZTAddressPattern) { Add-Issue 'Error' ("{0}: invalid remoteAddress." -f $label) }
            if ($rule['profile']) {
                foreach ($part in ([string]$rule['profile'] -split ',')) {
                    if (@('Any', 'Domain', 'Private', 'Public') -notcontains $part.Trim()) { Add-Issue 'Error' ("{0}: invalid profile '{1}' (Any, Domain, Private, Public)." -f $label, $part.Trim()) }
                }
            }
        }
    }
    elseif ($null -ne $firewall -and $firewall -isnot [bool]) {
        Add-Issue 'Error' "'firewall' must be an object or false."
    }

    foreach ($pattern in @($security['removeBloatware'])) {
        if ($null -eq $pattern) { continue }
        $text = [string]$pattern
        if ($text.Replace('*', '').Replace('?', '').Length -lt 4) { Add-Issue 'Error' ("removeBloatware: pattern '{0}' is too broad." -f $text); continue }
        if ($text -notmatch '^[A-Za-z0-9.*?_-]+\z') { Add-Issue 'Error' ("removeBloatware: invalid pattern '{0}'." -f $text); continue }
        if (Test-ZTPatternHitsProtected -Pattern $text) { Add-Issue 'Error' ("removeBloatware: '{0}' could remove a protected system package." -f $text) }
    }
    $issues.ToArray()
}

<#
.SYNOPSIS
    Lists the department profiles that can be applied (abstract profiles such as base.json are hidden).
#>
function Get-ZTDepartmentList {
    param([string]$ProfilesPath = $script:ZTProfilesPath, [switch]$IncludeAbstract)
    $folder = Resolve-ZTPath -Path $ProfilesPath
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw ("Profiles folder not found: {0}" -f $folder) }
    foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File | Sort-Object -Property Name)) {
        try {
            $data = Read-ZTJsonFile -Path $file.FullName
        }
        catch {
            Write-Warning $_.Exception.Message
            continue
        }
        if ($data -isnot [System.Collections.IDictionary]) { continue }
        if ([bool]$data['abstract'] -and -not $IncludeAbstract) { continue }
        $name = [string]$data['name']
        if (-not $name) { $name = $file.BaseName }
        $displayName = [string]$data['displayName']
        if (-not $displayName) { $displayName = $name }
        [pscustomobject]@{
            Name        = $name
            DisplayName = $displayName
            Description = [string]$data['description']
            Extends     = [string]$data['extends']
            Path        = $file.FullName
        }
    }
}
