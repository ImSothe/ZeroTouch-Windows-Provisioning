#Requires -Version 5.1
# Handover form ("acta de entrega"): one self-contained HTML page to print and sign, a JSON
# twin for inventory tools, and an optional PDF rendered by Microsoft Edge.

$script:ZTTemplatePath = Join-Path -Path $script:ZTResourcesPath -ChildPath 'handover-template.html'

function Get-ZTStatusClass {
    param([AllowEmptyString()][string]$Status)
    switch ($Status) {
        'Installed'        { 'ok' }
        'AlreadyInstalled' { 'ok' }
        'Compliant'        { 'ok' }
        'Remediated'       { 'ok' }
        'Success'          { 'ok' }
        'Failed'           { 'fail' }
        'WhatIf'           { 'sim' }
        'Simulation'       { 'sim' }
        default            { 'warn' }
    }
}

# A result's detail in the requested language (from its message key and arguments).
function Get-ZTResultText {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Language)
    if ($Result.Message) { return Format-ZTMessage -Key ([string]$Result.Message) -Arguments @($Result.Arguments) -Language $Language }
    [string]$Result.Detail
}

function Get-ZTValueOrDefault {
    param([AllowNull()]$Value, [Parameter(Mandatory)][string]$Language)
    $text = ([string]$Value).Trim()
    if ($text) { return $text }
    Format-ZTMessage -Key 'notAvailable' -Language $Language
}

<#
.SYNOPSIS
    Renders a provisioning run as the handover form (HTML string). Pure: no file or system access
    apart from reading the template and the language file.
#>
function ConvertTo-ZTHandoverHtml {
    param([Parameter(Mandatory)]$Run, [string]$Language)
    if (-not $Language) { $Language = [string]$Run.Language }
    if (-not $Language) { $Language = 'en' }
    $t = { param($Key, $Arguments = @()) Format-ZTMessage -Key $Key -Arguments $Arguments -Language $Language }
    $html = [System.IO.File]::ReadAllText($script:ZTTemplatePath, [System.Text.Encoding]::UTF8)

    $device = $Run.Device
    $applications = @($Run.Applications | Where-Object { $null -ne $_ })
    $security = @($Run.Security | Where-Object { $null -ne $_ })
    $printers = @($Run.Printers | Where-Object { $null -ne $_ })
    $simulation = [bool]$Run.Simulation
    $outcome = $Run.Outcome

    # ---- summary line
    $parts = New-Object -TypeName System.Collections.Generic.List[string]
    if ($applications.Count -gt 0) {
        $installed = @($applications | Where-Object { $_.Status -eq 'Installed' }).Count
        $present = @($applications | Where-Object { $_.Status -eq 'AlreadyInstalled' }).Count
        $failed = @($applications | Where-Object { $_.Status -eq 'Failed' }).Count
        $pending = @($applications | Where-Object { $_.Status -eq 'WhatIf' }).Count
        if ($simulation) { $parts.Add((& $t 'summary.appsSimulation' @($applications.Count, $pending, $present))) }
        else { $parts.Add((& $t 'summary.apps' @($applications.Count, $installed, $present, $failed))) }
    }
    if ($printers.Count -gt 0) {
        $added = @($printers | Where-Object { $_.Status -eq 'Installed' }).Count
        $present = @($printers | Where-Object { $_.Status -eq 'AlreadyInstalled' }).Count
        $failed = @($printers | Where-Object { $_.Status -eq 'Failed' }).Count
        $pending = @($printers | Where-Object { $_.Status -eq 'WhatIf' }).Count
        if ($simulation) { $parts.Add((& $t 'summary.printersSimulation' @($printers.Count, $pending, $present))) }
        else { $parts.Add((& $t 'summary.printers' @($printers.Count, $added, $present, $failed))) }
    }
    if ($security.Count -gt 0) {
        $compliant = @($security | Where-Object { $_.Status -eq 'Compliant' }).Count
        $fixed = @($security | Where-Object { $_.Status -eq 'Remediated' }).Count
        $pending = @($security | Where-Object { $_.Status -eq 'WhatIf' }).Count
        $attention = @($security | Where-Object { $_.Status -eq 'NonCompliant' -or $_.Status -eq 'Failed' }).Count
        if ($simulation) { $parts.Add((& $t 'summary.securitySimulation' @($security.Count, $compliant, $pending, $attention))) }
        else { $parts.Add((& $t 'summary.security' @($security.Count, $compliant, $fixed, $attention))) }
    }
    if ($parts.Count -eq 0) { $parts.Add((& $t 'summary.empty')) }
    $summary = ($parts | ForEach-Object { ConvertTo-ZTHtml $_ }) -join ' &middot; '

    # ---- tables
    $appRows = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($app in $applications) {
        $optional = ''
        if (-not [bool]$app.Required) { $optional = '<span class="tag">{0}</span>' -f (ConvertTo-ZTHtml (& $t 'optional')) }
        $badge = '<span class="pill {0}">{1}</span>' -f (Get-ZTStatusClass $app.Status), (ConvertTo-ZTHtml (& $t ('status.' + $app.Status)))
        $appRows.Add(('    <tr><td>{0}{1}</td><td class="mono">{2}</td><td>{3}</td><td>{4}</td><td class="detail">{5}</td></tr>' -f
                (ConvertTo-ZTHtml $app.Name), $optional, (ConvertTo-ZTHtml $app.Id), (ConvertTo-ZTHtml $app.Version), $badge,
                (ConvertTo-ZTHtml (Get-ZTResultText -Result $app -Language $Language))))
    }
    if ($appRows.Count -eq 0) { $appRows.Add(('    <tr><td colspan="5" class="detail">{0}</td></tr>' -f (ConvertTo-ZTHtml (& $t 'section.notRun')))) }

    $printerRows = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($printer in $printers) {
        $badge = '<span class="pill {0}">{1}</span>' -f (Get-ZTStatusClass $printer.Status), (ConvertTo-ZTHtml (& $t ('status.' + $printer.Status)))
        $printerRows.Add(('    <tr><td>{0}</td><td class="mono">{1}</td><td>{2}</td><td>{3}</td><td class="detail">{4}</td></tr>' -f
                (ConvertTo-ZTHtml $printer.Name), (ConvertTo-ZTHtml $printer.Address), (ConvertTo-ZTHtml $printer.Driver), $badge,
                (ConvertTo-ZTHtml (Get-ZTResultText -Result $printer -Language $Language))))
    }
    if ($printerRows.Count -eq 0) { $printerRows.Add(('    <tr><td colspan="5" class="detail">{0}</td></tr>' -f (ConvertTo-ZTHtml (& $t 'printers.none')))) }

    $securityRows = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($result in $security) {
        $badge = '<span class="pill {0}">{1}</span>' -f (Get-ZTStatusClass $result.Status), (ConvertTo-ZTHtml (& $t ('status.' + $result.Status)))
        $securityRows.Add(('    <tr><td>{0}</td><td>{1}</td><td class="detail">{2}</td></tr>' -f
                (ConvertTo-ZTHtml (& $t ('control.' + $result.Control))), $badge,
                (ConvertTo-ZTHtml (Get-ZTResultText -Result $result -Language $Language))))
    }
    if ($securityRows.Count -eq 0) { $securityRows.Add(('    <tr><td colspan="3" class="detail">{0}</td></tr>' -f (ConvertTo-ZTHtml (& $t 'section.notRun')))) }

    # ---- notes: failed applications and printers, controls that need attention, technician notes
    $notes = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($app in @($applications | Where-Object { $_.Status -eq 'Failed' })) {
        $notes.Add((& $t 'note.item' @([string]$app.Name, (Get-ZTResultText -Result $app -Language $Language))))
    }
    foreach ($printer in @($printers | Where-Object { $_.Status -eq 'Failed' })) {
        $notes.Add((& $t 'note.item' @([string]$printer.Name, (Get-ZTResultText -Result $printer -Language $Language))))
    }
    foreach ($result in @($security | Where-Object { $_.Status -eq 'NonCompliant' -or $_.Status -eq 'Failed' })) {
        $notes.Add((& $t 'note.item' @((& $t ('control.' + $result.Control)), (Get-ZTResultText -Result $result -Language $Language))))
    }
    if (([string]$Run.Notes).Trim()) { $notes.Add((& $t 'note.technician' @(([string]$Run.Notes).Trim()))) }
    if ($notes.Count -gt 0) {
        $notesHtml = '<ul class="notes">' + "`n" + (($notes | ForEach-Object { '  <li>' + (ConvertTo-ZTHtml $_) + '</li>' }) -join "`n") + "`n" + '</ul>'
    }
    else {
        $notesHtml = '<p class="detail">{0}</p>' -f (ConvertTo-ZTHtml (& $t 'noIssues'))
    }

    # ---- device values
    $memory = ''
    if ([int]$device.MemoryGB -gt 0) { $memory = & $t 'device.memoryFormat' @([int]$device.MemoryGB) }
    $disk = ''
    if ([int]$device.DiskSizeGB -gt 0) { $disk = & $t 'device.diskFormat' @([string]$device.SystemDrive, [int]$device.DiskSizeGB, [int]$device.DiskFreeGB) }
    $tpm = & $t 'tpm.none'
    if ($device.TpmVersion) {
        if ([bool]$device.TpmReady) { $tpm = & $t 'tpm.ready' @([string]$device.TpmVersion) } else { $tpm = & $t 'tpm.notReady' @([string]$device.TpmVersion) }
    }
    $network = (@([string]$device.IPAddress, [string]$device.MacAddress) | Where-Object { $_ }) -join ' / '
    $date = [datetime]::Parse([string]$Run.GeneratedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    $organization = [string]$Run.Organization.Name
    $contact = [string]$Run.Organization.ItContact
    $termsOrganization = $organization
    if (-not $termsOrganization) { $termsOrganization = & $t 'org.fallback' }
    if (-not $contact) { $contact = & $t 'contact.fallback' }
    $description = ''
    if (([string]$Run.Profile.Description).Trim()) { $description = ' &middot; ' + (ConvertTo-ZTHtml ([string]$Run.Profile.Description).Trim()) }

    $simulationBanner = ''
    if ($simulation) { $simulationBanner = '<div class="banner">{0}</div>' -f (ConvertTo-ZTHtml (& $t 'simulationBanner')) }
    $rebootNotice = ''
    if ([bool]$outcome.RebootRequired) { $rebootNotice = '<div class="notice">{0}</div>' -f (ConvertTo-ZTHtml (& $t 'rebootNotice')) }

    # Text values are HTML-encoded here; raw values are markup built above from encoded parts.
    $text = [ordered]@{
        LANG           = $Language
        ORGANIZATION   = $organization
        DEPARTMENT     = [string]$Run.Profile.DisplayName
        FORM_ID        = [string]$Run.FormId
        DATE           = $date.ToString((& $t 'dateFormat'), [System.Globalization.CultureInfo]::InvariantCulture)
        OUTCOME_CLASS  = Get-ZTStatusClass ([string]$outcome.Status)
        OUTCOME_LABEL  = & $t ('outcome.' + $outcome.Status)
        ASSIGNED_USER  = ([string]$Run.AssignedUser).Trim()
        TECHNICIAN     = ([string]$Run.Technician).Trim()
        PROFILE        = '{0} ({1})' -f $Run.Profile.DisplayName, $Run.Profile.Name
        COMPUTER_NAME  = Get-ZTValueOrDefault $device.ComputerName $Language
        MANUFACTURER   = Get-ZTValueOrDefault $device.Manufacturer $Language
        MODEL          = Get-ZTValueOrDefault $device.Model $Language
        SERIAL         = Get-ZTValueOrDefault $device.SerialNumber $Language
        CHASSIS        = & $t ('chassis.' + $device.Chassis)
        BIOS           = Get-ZTValueOrDefault $device.BiosVersion $Language
        CPU            = Get-ZTValueOrDefault $device.Processor $Language
        MEMORY         = Get-ZTValueOrDefault $memory $Language
        DISK           = Get-ZTValueOrDefault $disk $Language
        OS             = Get-ZTValueOrDefault ('{0} {1}' -f $device.OperatingSystem, $device.OsVersion) $Language
        JOIN           = & $t ('join.' + $device.JoinType)
        NETWORK        = Get-ZTValueOrDefault $network $Language
        TPM            = $tpm
        SECURE_BOOT    = & $t ('secureBoot.' + $device.SecureBoot)
        ANTIVIRUS      = Get-ZTValueOrDefault $device.Antivirus $Language
        TERMS          = & $t 'terms' @($termsOrganization, $contact)
        GENERATED_BY   = & $t 'generatedBy' @([string]$Run.ToolVersion)
    }
    $raw = [ordered]@{
        SIMULATION_BANNER      = $simulationBanner
        REBOOT_NOTICE          = $rebootNotice
        DEPARTMENT_DESCRIPTION = $description
        SUMMARY                = $summary
        SECURITY_ROWS          = $securityRows -join "`n"
        APPLICATION_ROWS       = $appRows -join "`n"
        PRINTER_ROWS           = $printerRows -join "`n"
        NOTES                  = $notesHtml
    }

    # Template labels first ({{t:key}}), then values. Values are inserted last so that text
    # coming from the computer or the profile can never be mistaken for a placeholder.
    $labels = @([regex]::Matches($html, '\{\{t:([A-Za-z0-9_.]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    foreach ($key in $labels) { $html = $html.Replace('{{t:' + $key + '}}', (ConvertTo-ZTHtml (& $t $key))) }
    $tokens = @([regex]::Matches($html, '\{\{([A-Z_]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $builder = New-Object -TypeName System.Text.StringBuilder
    $position = 0
    foreach ($match in [regex]::Matches($html, '\{\{([A-Z_]+)\}\}')) {
        [void]$builder.Append($html, $position, $match.Index - $position)
        $name = $match.Groups[1].Value
        if ($raw.Contains($name)) { [void]$builder.Append([string]$raw[$name]) }
        elseif ($text.Contains($name)) { [void]$builder.Append((ConvertTo-ZTHtml $text[$name])) }
        else { throw ("Unknown placeholder {{{{{0}}}}} in the handover template." -f $name) }
        $position = $match.Index + $match.Length
    }
    [void]$builder.Append($html, $position, $html.Length - $position)
    Write-Verbose ('Handover form: {0} placeholders filled.' -f $tokens.Count)
    $builder.ToString()
}

# Microsoft Edge (present on every Windows 10/11) prints the HTML to PDF headlessly.
function ConvertTo-ZTPdf {
    param([Parameter(Mandatory)][string]$HtmlPath, [Parameter(Mandatory)][string]$PdfPath, [int]$TimeoutSeconds = 90)
    $candidates = @()
    foreach ($programFiles in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($programFiles) { $candidates += Join-Path -Path $programFiles -ChildPath 'Microsoft\Edge\Application\msedge.exe' }
    }
    $edge = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $edge) {
        Write-ZTLog 'PDF: Microsoft Edge was not found; only the HTML form was written.' -Level Warning
        return $false
    }
    $profileFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('zt-edge-' + [guid]::NewGuid().ToString('N'))
    $uri = ([System.Uri]$HtmlPath).AbsoluteUri
    $arguments = @('--headless', '--disable-gpu', '--no-first-run', '--no-pdf-header-footer', '--print-to-pdf-no-header',
        ('--user-data-dir="{0}"' -f $profileFolder), ('--print-to-pdf="{0}"' -f $PdfPath), ('"{0}"' -f $uri))
    try {
        $process = Start-Process -FilePath $edge -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { Write-Verbose 'Edge had already exited.' }
            Write-ZTLog 'PDF: Edge did not finish in time.' -Level Warning
            return $false
        }
    }
    catch {
        Write-ZTLog ('PDF: {0}' -f $_.Exception.Message) -Level Warning
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $profileFolder) { Remove-Item -LiteralPath $profileFolder -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Test-Path -LiteralPath $PdfPath
}

<#
.SYNOPSIS
    Writes the handover form of a provisioning run: <FormId>.html, <FormId>.json and optionally <FormId>.pdf.
#>
function New-ZTHandoverReport {
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$OutputDirectory, [switch]$Pdf)
    $folder = Resolve-ZTPath -Path $OutputDirectory
    $baseName = Get-ZTSafeName -Value ([string]$Run.FormId) -Default 'handover' -MaxLength 80
    $htmlPath = Join-Path -Path $folder -ChildPath ($baseName + '.html')
    $jsonPath = Join-Path -Path $folder -ChildPath ($baseName + '.json')
    Write-ZTTextFile -Path $jsonPath -Content (ConvertTo-ZTJson -InputObject $Run)
    Write-ZTTextFile -Path $htmlPath -Content (ConvertTo-ZTHandoverHtml -Run $Run)
    $pdfPath = $null
    if ($Pdf -and -not [bool]$Run.Simulation) {
        $candidate = Join-Path -Path $folder -ChildPath ($baseName + '.pdf')
        if (ConvertTo-ZTPdf -HtmlPath $htmlPath -PdfPath $candidate) { $pdfPath = $candidate }
    }
    [pscustomobject]@{ HtmlPath = $htmlPath; JsonPath = $jsonPath; PdfPath = $pdfPath }
}
