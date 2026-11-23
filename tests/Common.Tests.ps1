# Shared helpers: JSON, merging, text and localized messages.

Test-Case 'ConvertTo-ZTHashtable: objects become ordered dictionaries and arrays stay arrays' {
    $parsed = ConvertFrom-Json -InputObject '{"a":{"b":[1],"c":[]},"d":"x","e":[{"id":"q"}]}'
    $h = ConvertTo-ZTHashtable -InputObject $parsed
    Assert-True ($h -is [System.Collections.Specialized.OrderedDictionary]) 'top level is an ordered dictionary'
    Assert-True ($h['a']['b'] -is [array]) 'single-element array kept as an array'
    Assert-Equal 1 @($h['a']['b']).Count 'b count'
    Assert-Equal 0 @($h['a']['c']).Count 'empty array'
    Assert-Equal 'q' $h['e'][0]['id'] 'object inside an array'
    Assert-Equal 'a,d,e' (@($h.Keys) -join ',') 'key order kept'
}

Test-Case 'Merge-ZTValue: child scalars win, dictionaries merge, lists add up without duplicates' {
    $base = [ordered]@{ a = 1; d = [ordered]@{ x = 1; y = 2 }; s = @('One', 'two'); o = @([ordered]@{ id = 'A'; v = 1 }, [ordered]@{ id = 'B'; v = 1 }) }
    $child = [ordered]@{ a = 2; d = [ordered]@{ y = 3 }; s = @('one', 'three'); o = @([ordered]@{ id = 'b'; v = 2 }, [ordered]@{ id = 'C'; v = 1 }) }
    $merged = Merge-ZTValue -Base $base -Override $child
    Assert-Equal 2 $merged['a'] 'scalar'
    Assert-Equal 1 $merged['d']['x'] 'parent key kept'
    Assert-Equal 3 $merged['d']['y'] 'child key wins'
    Assert-Equal 'one,two,three' (@($merged['s']) -join ',') 'strings: case-insensitive, parent order, child spelling'
    Assert-Equal 'A:1,b:2,C:1' ((@($merged['o']) | ForEach-Object { '{0}:{1}' -f $_['id'], $_['v'] }) -join ',') 'objects matched by id'
    Assert-Equal 1 $base['a'] 'base not modified'
    Assert-Equal 2 @($base['s']).Count 'base list not modified'
}

Test-Case 'Merge-ZTValue: firewall rules are matched by displayName' {
    $merged = Merge-ZTValue -Base @([ordered]@{ displayName = 'R1'; action = 'Block' }) -Override @([ordered]@{ displayName = 'r1'; action = 'Allow' }, [ordered]@{ displayName = 'R2' })
    Assert-Equal 2 @($merged).Count 'rules'
    Assert-Equal 'Allow' $merged[0]['action'] 'child rule replaced the parent rule'
}

Test-Case 'Format-ZTJson: two-space indentation, strings untouched' {
    $json = Format-ZTJson -Json '{"a":[],"b":{},"c":"x, {y}: [z] \"q\"","d":[1,2],"e":{"f":true}}'
    $expected = @('{', '  "a": [],', '  "b": {},', '  "c": "x, {y}: [z] \"q\"",', '  "d": [', '    1,', '    2', '  ],', '  "e": {', '    "f": true', '  }', '}') -join "`n"
    Assert-Equal $expected $json 'formatted JSON'
    Assert-Equal 'x, {y}: [z] "q"' (ConvertFrom-Json -InputObject $json).c 'round trip'
}

Test-Case 'ConvertTo-ZTJson: output of ConvertTo-Json on 5.1 and 7 is re-indented the same way' {
    $json = ConvertTo-ZTJson -InputObject ([ordered]@{ name = 'x'; list = @('a') })
    $expected = @('{', '  "name": "x",', '  "list": [', '    "a"', '  ]', '}') -join "`n"
    Assert-Equal $expected $json 'layout'
}

Test-Case 'ConvertTo-ZTSlug: accents and symbols become a safe file name' {
    $accented = 'Direcci' + [char]0x00F3 + 'n / Compras ' + [char]0x00D1 + 'u'
    Assert-Equal 'direccion-compras-nu' (ConvertTo-ZTSlug -Text $accented) 'slug'
    Assert-Equal '' (ConvertTo-ZTSlug -Text '***') 'only symbols'
}

Test-Case 'ConvertTo-ZTHtml: encodes the HTML special characters and keeps accents' {
    $text = '<a href="x">' + "O'Neil & co " + [char]0x00E9
    Assert-Equal ('&lt;a href=&quot;x&quot;&gt;O&#39;Neil &amp; co ' + [char]0x00E9) (ConvertTo-ZTHtml $text) 'encoded'
    Assert-Equal '' (ConvertTo-ZTHtml $null) 'null'
}

Test-Case 'Get-ZTSafeName: a computer name cannot carry a path into a file name' {
    Assert-Equal 'evil' (Get-ZTSafeName -Value '..\..\evil') 'traversal'
    Assert-Equal 'PC-01' (Get-ZTSafeName -Value 'PC-01') 'normal name'
    Assert-Equal 'PC' (Get-ZTSafeName -Value '') 'empty'
    Assert-Equal 40 (Get-ZTSafeName -Value ('x' * 100)).Length 'length limit'
}

Test-Case 'Format-ZTMessage: English, Spanish, fallback to the key, arguments' {
    Assert-Equal 'Installed.' (Format-ZTMessage -Key 'app.installed') 'en'
    Assert-Equal 'Instalada.' (Format-ZTMessage -Key 'app.installed' -Language 'es') 'es'
    Assert-Equal 'TPM 2.0, ready' (Format-ZTMessage -Key 'tpm.ready' -Arguments @('2.0')) 'argument'
    Assert-Equal 'no.such.key' (Format-ZTMessage -Key 'no.such.key' -Language 'es') 'unknown key'
    Assert-Throws { Format-ZTMessage -Key 'app.installed' -Language 'fr' } -Like '*Unsupported language*' -What 'fr'
}

Test-Case 'Format-ZTMessage: a translation with a broken placeholder does not throw' {
    $table = Get-ZTStrings -Language 'en'
    $table['test.broken'] = 'Value {3}'
    try {
        Assert-Equal 'Value {3} (a)' (Format-ZTMessage -Key 'test.broken' -Arguments @('a')) 'fallback text'
    }
    finally {
        $table.Remove('test.broken')
    }
}

Test-Case 'Language files: Spanish has exactly the English keys, with the same placeholders' {
    $en = Get-ZTStrings -Language 'en'
    $es = Get-ZTStrings -Language 'es'
    foreach ($key in $en.Keys) {
        Assert-True ($es.Contains($key)) ('missing in es: {0}' -f $key)
        $placeholdersEn = (@([regex]::Matches([string]$en[$key], '\{\d+\}') | ForEach-Object { $_.Value }) | Sort-Object -Unique) -join ','
        $placeholdersEs = (@([regex]::Matches([string]$es[$key], '\{\d+\}') | ForEach-Object { $_.Value }) | Sort-Object -Unique) -join ','
        Assert-Equal $placeholdersEn $placeholdersEs ('placeholders of {0}' -f $key)
    }
    foreach ($key in $es.Keys) { Assert-True ($en.Contains($key)) ('only in es: {0}' -f $key) }
    Assert-True ([string]$es['title']).Contains([string][char]0x00E1) 'Spanish file read as UTF-8 (accents intact)'
}

Test-Case 'Every message key used by the source and the template exists' {
    $en = Get-ZTStrings -Language 'en'
    $used = New-Object -TypeName System.Collections.Generic.List[string]
    # A key ends with a letter or digit: 'app.failed.' + $name is a family, checked below.
    $key = "([A-Za-z0-9_.]*[A-Za-z0-9_])'"
    $patterns = @("-Message\s+'$key", "\`$messageKey\s*=\s*'$key", "&\s*\`$t\s+'$key", "-Key\s+'$key")
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'src') -Filter '*.ps1') {
        $source = [System.IO.File]::ReadAllText($file.FullName)
        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches($source, $pattern)) { $used.Add($match.Groups[1].Value) }
        }
    }
    $template = [System.IO.File]::ReadAllText($script:ZTTemplatePath)
    foreach ($match in [regex]::Matches($template, '\{\{t:([A-Za-z0-9_.]+)\}\}')) { $used.Add($match.Groups[1].Value) }
    $families = @{
        'status.'     = @('Installed', 'AlreadyInstalled', 'Failed', 'WhatIf', 'Compliant', 'Remediated', 'NonCompliant', 'Skipped')
        'outcome.'    = @('Success', 'Warning', 'Failed', 'Simulation')
        'control.'    = @('BitLocker', 'SMBv1', 'Firewall', 'FirewallRules', 'Bloatware')
        'chassis.'    = @('Laptop', 'Desktop', 'VirtualMachine', 'Other')
        'join.'       = @('Hybrid', 'Entra', 'Domain', 'Workgroup')
        'secureBoot.' = @('On', 'Off', 'Unsupported', 'Unknown')
        'app.failed.' = $script:ZTExplainedCodes
        'driverKind.' = @('Model', 'Peripheral')
        'driverStatus.' = @('Installed', 'Failed', 'WhatIf', 'Skipped')
    }
    foreach ($prefix in $families.Keys) { foreach ($suffix in $families[$prefix]) { $used.Add($prefix + $suffix) } }
    Assert-True ($used.Count -gt 100) ('the scan found only {0} keys' -f $used.Count)
    foreach ($key in ($used | Sort-Object -Unique)) { Assert-True ($en.Contains($key)) ('missing message key: {0}' -f $key) }
}
