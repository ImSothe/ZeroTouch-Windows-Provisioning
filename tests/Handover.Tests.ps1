# Handover form: content, languages, states and the committed samples.

function Get-SampleHtml {
    param([string]$Language = 'en', [scriptblock]$Change)
    $run = New-ZTSampleRun -Language $Language
    if ($Change) { & $Change $run }
    ConvertTo-ZTHandoverHtml -Run $run
}

Test-Case 'Handover form (en): every placeholder is filled and the page is self-contained' {
    $html = Get-SampleHtml
    Assert-True ($html -notmatch '\{\{') 'no placeholder left'
    Assert-True ($html -like '*<html lang="en">*') 'lang attribute'
    Assert-True ($html -like "*Content-Security-Policy*default-src 'none'*") 'CSP'
    Assert-Equal 0 ([regex]::Matches($html, '<script', 'IgnoreCase')).Count 'no scripts'
    Assert-True ($html -notmatch '(src|href)\s*=') 'no external resources'
    foreach ($text in 'IT equipment handover form', 'Demo Corp S.L.', 'PC-TALLER-07', 'PF3K7Q2M', 'ThinkCentre M70q Gen 3', 'Hybrid (Active Directory + Entra ID)',
        'TPM 2.0, ready', 'C: 476 GB (431 GB free)', 'Windows 11 Pro 24H2 (26100.2314)', '192.168.20.41 / 8C:16:45:2A:7B:91', 'ZT-20261123-093015-PC-TALLER-07', '2026-11-23 09:30') {
        Assert-True ($html.Contains($text)) ('missing: {0}' -f $text)
    }
}

Test-Case 'Handover form (en): outcome, summary, optional tag, notes and restart notice' {
    $html = Get-SampleHtml
    Assert-True ($html.Contains('<div class="status warn"><strong>COMPLIANT WITH NOTES</strong>')) 'outcome banner'
    Assert-True ($html.Contains('Applications: 7 (installed: 5, already present: 1, failed: 1) &middot; Printers: 1 (added: 1, already present: 0, failed: 0) &middot; Security controls: 5 (compliant: 1, fixed: 4, need attention: 0)')) 'summary'
    Assert-True ($html.Contains('LibreCAD<span class="tag">optional</span>')) 'optional application tagged'
    Assert-True ($html.Contains('<li>LibreCAD: The download failed; check internet access or the proxy (0x8A150008).</li>')) 'failed application in the notes'
    Assert-True ($html.Contains('<li>Technician notes: Delivered with keyboard, 24-inch monitor and network cable.</li>')) 'technician notes'
    Assert-True ($html.Contains('<div class="notice">Restart the computer')) 'restart notice'
    Assert-True ($html.Contains('<span class="pill ok">Fixed</span>')) 'remediated badge'
    Assert-True ($html.Contains('<span class="pill fail">Error</span>')) 'failed badge'
    Assert-True ($html.Contains('<tr><td>Taller - Impresora de planta</td><td class="mono">192.168.50.20</td><td>HP Universal Printing PCL 6</td>')) 'printer row'
}

Test-Case 'Handover form: a printer that could not be added is a note' {
    $html = Get-SampleHtml -Change {
        param($run)
        $run.Printers[0].Status = 'Failed'
        $run.Printers[0].Message = 'printer.driverMissing'
        $run.Printers[0].Arguments = @('Vendor Driver')
    }
    Assert-True ($html.Contains('<li>Taller - Impresora de planta: The Vendor Driver driver is not in the Windows driver store.')) 'note'
}

Test-Case 'Handover form (es): Spanish labels, dates and result texts' {
    $html = Get-SampleHtml -Language 'es'
    $title = 'Acta de entrega de equipo inform' + [char]0x00E1 + 'tico'
    Assert-True ($html.Contains($title)) 'title with accent'
    Assert-True ($html.Contains('<html lang="es">')) 'lang'
    Assert-True ($html.Contains('23/11/2026 09:30')) 'Spanish date format'
    Assert-True ($html.Contains('CONFORME CON OBSERVACIONES')) 'outcome'
    Assert-True ($html.Contains('<span class="pill ok">Instalada</span>')) 'status label'
    Assert-True ($html.Contains('SMBv1 desactivado.')) 'result text rebuilt in Spanish from its message key'
    Assert-True ($html.Contains('Luc' + [char]0x00ED + 'a Mart' + [char]0x00ED + 'n')) 'accented name'
    Assert-True ($html.Contains('Sobremesa')) 'chassis'
}

Test-Case 'Handover form: simulation runs are clearly marked' {
    $html = Get-SampleHtml -Change { param($run) $run.Simulation = $true; $run.Outcome.Status = 'Simulation' }
    Assert-True ($html.Contains('<div class="banner">SIMULATION (-WhatIf)')) 'banner'
    Assert-True ($html.Contains('<div class="status sim"><strong>SIMULATION - NO CHANGES</strong>')) 'outcome'
    Assert-True ($html.Contains('would be installed')) 'simulation summary'
}

Test-Case 'Handover form: a clean run has no notes and no restart notice' {
    $html = Get-SampleHtml -Change {
        param($run)
        $run.Applications = @($run.Applications | Where-Object { $_.Status -ne 'Failed' })
        $run.Notes = ''
        $run.Outcome = [pscustomobject]@{ Status = 'Success'; ExitCode = 0; RebootRequired = $false }
    }
    Assert-True ($html.Contains('<p class="detail">No issues.</p>')) 'no issues'
    Assert-True (-not $html.Contains('class="notice"')) 'no restart notice'
    Assert-True ($html.Contains('<div class="status ok"><strong>COMPLIANT</strong>')) 'outcome'
}

Test-Case 'Handover form: empty names leave room to write by hand, skipped sections say so' {
    $html = Get-SampleHtml -Change { param($run) $run.AssignedUser = ''; $run.Applications = @(); $run.Security = @(); $run.Printers = @() }
    Assert-True ($html.Contains('<dt>Received by</dt><dd class="fill"></dd>')) 'blank line for the receiver'
    Assert-Equal 2 ([regex]::Matches($html, 'Not run in this provisioning')).Count 'both tables'
    Assert-True ($html.Contains('<td colspan="5" class="detail">No printers were set up.</td>')) 'printers table'
    Assert-True ($html.Contains('Nothing was provisioned.')) 'summary'
}

Test-Case 'Handover form: missing device data shows "Not available"' {
    $html = Get-SampleHtml -Change { param($run) $run.Device.SerialNumber = ''; $run.Device.DiskSizeGB = 0; $run.Device.TpmVersion = '' }
    Assert-True ($html.Contains('<dd class="mono">Not available</dd>')) 'serial'
    Assert-True ($html.Contains('<dd>Not detected</dd>')) 'TPM'
}

Test-Case 'New-ZTHandoverReport: writes HTML and JSON without BOM; the JSON is the run' {
    $folder = New-TestFolder
    $run = New-ZTSampleRun
    $report = New-ZTHandoverReport -Run $run -OutputDirectory $folder
    Assert-Equal (Join-Path $folder 'ZT-20261123-093015-PC-TALLER-07.html') $report.HtmlPath 'html path'
    foreach ($path in $report.HtmlPath, $report.JsonPath) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) ('BOM in {0}' -f $path)
    }
    $json = [System.IO.File]::ReadAllText($report.JsonPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-Equal 'PF3K7Q2M' $json.Device.SerialNumber 'device'
    Assert-Equal 7 @($json.Applications).Count 'applications'
    Assert-Equal 'smb1.disabled' (@($json.Security) | Where-Object { $_.Control -eq 'SMBv1' }).Message 'message key kept'
    Assert-Equal $null $report.PdfPath 'no PDF unless asked'
}

Test-Case 'New-ZTHandoverReport: -Pdf asks Edge for a PDF, never for a simulation' {
    $folder = New-TestFolder
    $report = New-ZTHandoverReport -Run (New-ZTSampleRun) -OutputDirectory $folder -Pdf
    Assert-True (Test-Path -LiteralPath $report.PdfPath) 'PDF written'
    $simulation = New-ZTSampleRun
    $simulation.Simulation = $true
    $report = New-ZTHandoverReport -Run $simulation -OutputDirectory (New-TestFolder) -Pdf
    Assert-Equal $null $report.PdfPath 'no PDF for a simulation'
    Assert-Equal 1 @(Get-FakeCall -Name 'ConvertTo-ZTPdf').Count 'Edge called once'
}

Test-Case 'Samples in docs\ match what tools\New-SampleHandover.ps1 generates' {
    foreach ($language in 'en', 'es') {
        $name = 'sample-handover.html'
        if ($language -ne 'en') { $name = 'sample-handover.{0}.html' -f $language }
        $committed = ([System.IO.File]::ReadAllText((Join-Path $root ('docs\' + $name)), [System.Text.Encoding]::UTF8)) -replace "`r`n", "`n"
        $generated = (ConvertTo-ZTHandoverHtml -Run (New-ZTSampleRun -Language $language)) -replace "`r`n", "`n"
        if ($committed -ne $generated) {
            $a = $committed -split "`n"
            $b = $generated -split "`n"
            $line = 0
            while ($line -lt [math]::Min($a.Count, $b.Count) -and $a[$line] -ceq $b[$line]) { $line++ }
            $was = ''
            if ($line -lt $a.Count) { $was = $a[$line] }
            $now = ''
            if ($line -lt $b.Count) { $now = $b[$line] }
            throw ('{0} differs at line {1}. Committed: [{2}] Generated: [{3}]. Run tools\New-SampleHandover.ps1.' -f $name, ($line + 1), $was, $now)
        }
    }
}
