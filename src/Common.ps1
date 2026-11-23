#Requires -Version 5.1
# Shared helpers: paths, logging, JSON, merging, localized messages and small system probes.
#
# Source files are ASCII on purpose: Windows PowerShell 5.1 reads a UTF-8 file without a BOM
# as ANSI and mangles accented characters. Every text with accents lives in resources\*.json,
# which is always read explicitly as UTF-8.

$script:ZTVersion       = '1.0.0'
$script:ZTRoot          = Split-Path -Path $PSScriptRoot -Parent
$script:ZTProfilesPath  = Join-Path -Path $script:ZTRoot -ChildPath 'profiles'
$script:ZTResourcesPath = Join-Path -Path $script:ZTRoot -ChildPath 'resources'
$script:ZTLanguages     = @('en', 'es')
$script:ZTLogFile       = $null
$script:ZTQuiet         = $false
$script:ZTStringsCache  = @{}
$script:ZTUtf8NoBom     = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

# ------------------------------------------------------------------ paths and files

# Resolves a path against the PowerShell location (not the process working directory, which
# is what the .NET file APIs would use).
function Resolve-ZTPath {
    param([Parameter(Mandatory)][string]$Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Write-ZTTextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $folder = Split-Path -Path $Path -Parent
    if ($folder) { [void][System.IO.Directory]::CreateDirectory($folder) }
    [System.IO.File]::WriteAllText($Path, $Content, $script:ZTUtf8NoBom)
}

# A short, safe piece of a file name (computer names end up in report file names).
function Get-ZTSafeName {
    param([AllowEmptyString()][string]$Value, [string]$Default = 'PC', [ValidateRange(1, 200)][int]$MaxLength = 40)
    $safe = ([string]$Value -replace '[^A-Za-z0-9_-]', '_').Trim('_')
    if (-not $safe) { return $Default }
    $safe.Substring(0, [math]::Min($MaxLength, $safe.Length))
}

# ------------------------------------------------------------------ logging

function Start-ZTLog {
    param([Parameter(Mandatory)][string]$Path)
    $folder = Split-Path -Path $Path -Parent
    if ($folder) { [void][System.IO.Directory]::CreateDirectory($folder) }
    $script:ZTLogFile = $Path
}

# Console + log file. The file is written with .NET so that -WhatIf never suppresses logging.
function Write-ZTLog {
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Step', 'Success', 'Warning', 'Error')][string]$Level = 'Info'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    if ($script:ZTLogFile) {
        try {
            [System.IO.File]::AppendAllText($script:ZTLogFile, $line + [Environment]::NewLine, $script:ZTUtf8NoBom)
        }
        catch {
            Write-Verbose ('Could not write to the log file: {0}' -f $_.Exception.Message)
        }
    }
    if ($script:ZTQuiet) { return }
    $color = switch ($Level) {
        'Step'    { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        default   { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

# ------------------------------------------------------------------ JSON

# ConvertFrom-Json output (PSCustomObject) to ordered dictionaries, recursively.
# Windows PowerShell 5.1 has no ConvertFrom-Json -AsHashtable.
function ConvertTo-ZTHashtable {
    param([AllowNull()]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $copy[[string]$key] = ConvertTo-ZTHashtable -InputObject $InputObject[$key]
        }
        return $copy
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $copy[$property.Name] = ConvertTo-ZTHashtable -InputObject $property.Value
        }
        return $copy
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $items = New-Object -TypeName System.Collections.Generic.List[object]
        foreach ($item in $InputObject) { $items.Add((ConvertTo-ZTHashtable -InputObject $item)) }
        return , $items.ToArray()
    }
    return $InputObject
}

function Read-ZTJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = Resolve-ZTPath -Path $Path
    # ReadAllText detects and drops a UTF-8 BOM if there is one.
    $text = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
    try {
        $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        throw ("Invalid JSON in '{0}': {1}" -f $fullPath, $_.Exception.Message)
    }
    ConvertTo-ZTHashtable -InputObject $parsed
}

# Re-indents JSON with two spaces. Windows PowerShell 5.1's ConvertTo-Json output is valid but
# hard to read, and profiles are meant to be edited by hand.
function Format-ZTJson {
    param([Parameter(Mandatory)][string]$Json)
    $builder = New-Object -TypeName System.Text.StringBuilder
    $depth = 0
    $inString = $false
    $escaped = $false
    $length = $Json.Length
    for ($i = 0; $i -lt $length; $i++) {
        $c = $Json[$i]
        if ($inString) {
            [void]$builder.Append($c)
            if ($escaped) { $escaped = $false }
            elseif ($c -eq [char]'\') { $escaped = $true }
            elseif ($c -eq [char]'"') { $inString = $false }
            continue
        }
        if ($c -eq [char]'"') {
            $inString = $true
            [void]$builder.Append($c)
        }
        elseif ($c -eq [char]'{' -or $c -eq [char]'[') {
            $j = $i + 1
            while ($j -lt $length -and [char]::IsWhiteSpace($Json[$j])) { $j++ }
            if ($j -lt $length -and ($Json[$j] -eq [char]'}' -or $Json[$j] -eq [char]']')) {
                [void]$builder.Append($c).Append($Json[$j])
                $i = $j
                continue
            }
            $depth++
            [void]$builder.Append($c).Append("`n").Append(' ' * (2 * $depth))
        }
        elseif ($c -eq [char]'}' -or $c -eq [char]']') {
            $depth--
            [void]$builder.Append("`n").Append(' ' * (2 * $depth)).Append($c)
        }
        elseif ($c -eq [char]',') {
            [void]$builder.Append(",`n").Append(' ' * (2 * $depth))
        }
        elseif ($c -eq [char]':') {
            [void]$builder.Append(': ')
        }
        elseif (-not [char]::IsWhiteSpace($c)) {
            [void]$builder.Append($c)
        }
    }
    $builder.ToString()
}

function ConvertTo-ZTJson {
    param([AllowNull()]$InputObject, [int]$Depth = 10)
    Format-ZTJson -Json (ConvertTo-Json -InputObject $InputObject -Depth $Depth)
}

# ------------------------------------------------------------------ merging (profile inheritance)

# Key used to recognise "the same item" in two lists: plain strings by value, objects by
# 'id' (applications), 'displayName' (firewall rules) or 'name' (printers). Case-insensitive.
function Get-ZTItemKey {
    param([AllowNull()]$Item)
    if ($Item -is [string]) { return 's:' + $Item.ToLowerInvariant() }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains('id') -and $Item['id']) { return 'id:' + ([string]$Item['id']).ToLowerInvariant() }
        if ($Item.Contains('displayName') -and $Item['displayName']) { return 'dn:' + ([string]$Item['displayName']).ToLowerInvariant() }
        if ($Item.Contains('name') -and $Item['name']) { return 'nm:' + ([string]$Item['name']).ToLowerInvariant() }
    }
    return $null
}

# Child values win over parent values; dictionaries merge key by key; lists are added
# together without duplicates (a child item replaces the parent item with the same key).
function Merge-ZTValue {
    param([AllowNull()]$Base, [AllowNull()]$Override)
    if ($null -eq $Base) { return $Override }
    if ($null -eq $Override) { return $Base }
    if ($Base -is [System.Collections.IDictionary] -and $Override -is [System.Collections.IDictionary]) {
        $merged = [ordered]@{}
        foreach ($key in $Base.Keys) { $merged[$key] = $Base[$key] }
        foreach ($key in $Override.Keys) {
            if ($merged.Contains($key)) {
                $merged[$key] = Merge-ZTValue -Base $merged[$key] -Override $Override[$key]
            }
            else {
                $merged[$key] = $Override[$key]
            }
        }
        return $merged
    }
    if ($Base -is [System.Collections.IList] -and $Override -is [System.Collections.IList]) {
        $items = New-Object -TypeName System.Collections.Generic.List[object]
        $positions = @{}
        foreach ($item in @($Base) + @($Override)) {
            $key = Get-ZTItemKey -Item $item
            if ($null -ne $key -and $positions.ContainsKey($key)) {
                $items[$positions[$key]] = $item
                continue
            }
            if ($null -ne $key) { $positions[$key] = $items.Count }
            $items.Add($item)
        }
        return , $items.ToArray()
    }
    return $Override
}

# ------------------------------------------------------------------ text helpers

function ConvertTo-ZTHtml {
    param([AllowNull()]$Text)
    if ($null -eq $Text) { return '' }
    ([string]$Text).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

# "Direccion General" -> "direccion-general" (accents removed, safe as a file name).
function ConvertTo-ZTSlug {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $decomposed = $Text.Trim().ToLowerInvariant().Normalize([System.Text.NormalizationForm]::FormD)
    $builder = New-Object -TypeName System.Text.StringBuilder
    foreach ($ch in $decomposed.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($ch)
        }
    }
    ($builder.ToString() -replace '[^a-z0-9]+', '-').Trim('-')
}

# ------------------------------------------------------------------ localized messages

function Get-ZTStrings {
    param([string]$Language = 'en')
    if ($script:ZTLanguages -notcontains $Language) { throw ("Unsupported language '{0}'. Use: {1}." -f $Language, ($script:ZTLanguages -join ', ')) }
    if (-not $script:ZTStringsCache.ContainsKey($Language)) {
        $path = Join-Path -Path $script:ZTResourcesPath -ChildPath ('strings.{0}.json' -f $Language)
        $script:ZTStringsCache[$Language] = Read-ZTJsonFile -Path $path
    }
    $script:ZTStringsCache[$Language]
}

# Results carry a message key and its arguments; the text is built in the report's language
# when the handover form is rendered, and in English for the log and the JSON.
function Format-ZTMessage {
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Arguments = @(),
        [string]$Language = 'en'
    )
    $template = $null
    foreach ($candidate in @($Language, 'en')) {
        $table = Get-ZTStrings -Language $candidate
        if ($table.Contains($Key)) {
            $template = [string]$table[$Key]
            break
        }
    }
    if ($null -eq $template) { $template = $Key }
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return $template }
    try {
        [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $template, [object[]]$Arguments)
    }
    catch {
        # A translation with a wrong placeholder (FormatException) must not break a report.
        '{0} ({1})' -f $template, ($Arguments -join '; ')
    }
}

# One security control outcome. Status values:
#   Compliant     already as the profile wants it
#   Remediated    changed by this run
#   NonCompliant  not as wanted and deliberately left alone (report mode, no TPM, ...)
#   Failed        the check itself failed
#   Skipped       turned off in the profile
#   WhatIf        would change (simulation)
function New-ZTResult {
    param(
        [Parameter(Mandatory)][string]$Control,
        [Parameter(Mandatory)][ValidateSet('Compliant', 'Remediated', 'NonCompliant', 'Failed', 'Skipped', 'WhatIf')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [object[]]$Arguments = @(),
        [switch]$RebootRequired
    )
    $text = @($Arguments | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        Control        = $Control
        Status         = $Status
        Message        = $Message
        Arguments      = $text
        Detail         = Format-ZTMessage -Key $Message -Arguments $text
        RebootRequired = [bool]$RebootRequired
    }
}

# ------------------------------------------------------------------ system probes
# Small wrappers so that the test suite can replace them with fakes.

function Test-ZTIsAdmin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ZTIsSystem {
    [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
}

function Test-ZTCommand {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

# Entra ID join (from dsregcmd) and Active Directory domain membership.
function Get-ZTJoinState {
    $entra = $false
    $domain = $false
    try {
        $status = (& dsregcmd.exe /status 2>$null) -join "`n"
        $entra = $status -match 'AzureAdJoined\s*:\s*YES'
    }
    catch {
        Write-Verbose ('dsregcmd is not available: {0}' -f $_.Exception.Message)
    }
    try {
        $domain = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain
    }
    catch {
        Write-Verbose ('Could not read the domain membership: {0}' -f $_.Exception.Message)
    }
    [pscustomobject]@{ EntraJoined = [bool]$entra; DomainJoined = $domain }
}
