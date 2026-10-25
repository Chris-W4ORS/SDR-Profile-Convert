# lib/Thetis.ps1 - Thetis adapter
# Source of truth for TX profiles: %APPDATA%\OpenHPSDR\Thetis*\DB\<radio>_dbman_settings.json
# -> ActiveDB_File -> database.xml, one <TXProfile> block per profile (<Name> tag).
# Thetis only writes TXParaEQData on exit, and must be CLOSED for writes.

$script:Th = $null

function Read-TextKeepEncoding {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object System.Text.UTF8Encoding($bom)
    $text = $enc.GetString($bytes); if ($bom) { $text = $text.Substring(1) }
    return @{ Text = $text; Encoding = $enc }
}

# Thetis loads database.xml with .NET DataSet.ReadXml against the inline schema,
# so every value must parse as its column's type: booleans lowercase
# true/false, Int32 columns whole numbers. (2026-10-24: "True" and "13.5"
# written by the converter made Thetis quarantine the DB to DB\broken\.)
function Get-ThetisColumnTypes {
    param([string]$XmlText)
    $h = @{}
    try {
        $ds = New-Object System.Data.DataSet
        [void]$ds.ReadXmlSchema((New-Object IO.StringReader($XmlText)))
        $t = $ds.Tables['TXProfile']
        if ($t) { foreach ($c in $t.Columns) { $h[$c.ColumnName] = $c.DataType.Name } }
    } catch { }
    return $h
}
function Format-ThetisValue {
    # Returns @{ Value; Changed(bool); Why } - coerces a value to the column's type
    param([string]$Tag, [string]$Value, [string]$Old, $Types)
    $type = if ($Types -and $Types.ContainsKey($Tag)) { $Types[$Tag] } else { $null }
    if ($type -eq 'Boolean' -or (-not $type -and $Old -cmatch '^(true|false)$')) {
        $b = ConvertTo-BoolVal $Value; if ($null -eq $b) { return @{ Value = $Value; Changed = $false } }
        $v = if ($b) { 'true' } else { 'false' }; return @{ Value = $v; Changed = ($v -cne $Value); Why = 'bool' }
    }
    if ($type -in @('Int16', 'Int32', 'Int64', 'Byte', 'SByte', 'UInt16', 'UInt32', 'UInt64')) {
        $n = ConvertTo-Num $Value; if ($null -eq $n) { return @{ Value = $Value; Changed = $false } }
        $r = [math]::Round($n, 0, [MidpointRounding]::AwayFromZero)
        $v = ([long]$r).ToString($script:Inv); return @{ Value = $v; Changed = ($v -ne $Value); Why = 'int' }
    }
    return @{ Value = $Value; Changed = $false }
}
function Test-ThetisXml {
    # $null if Thetis (DataSet.ReadXml) would load it, otherwise the error text
    param([string]$XmlText)
    try { $ds = New-Object System.Data.DataSet; [void]$ds.ReadXml((New-Object IO.StringReader($XmlText))); return $null }
    catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; return $e.Message }
}

function Thetis_Open {
    if ($script:Th) { return $true }
    $roots = @(Get-ChildItem (Join-Path $env:APPDATA 'OpenHPSDR') -Directory -Filter 'Thetis*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'DB' } | Where-Object { Test-Path $_ })
    $dbman = @(foreach ($r in $roots) { Get-ChildItem $r -Filter '*_dbman_settings.json' -ErrorAction SilentlyContinue })
    if ($dbman.Count -eq 0) { return $false }
    $pick = if ($dbman.Count -eq 1) { $dbman[0] } else { Select-Item "Thetis radio database:" $dbman { param($f) "$($f.Directory.Parent.Name)\$($f.Name -replace '_dbman_settings.json','')" } }
    $j = Get-Content $pick.FullName -Raw | ConvertFrom-Json
    $dbPath = Join-Path $pick.DirectoryName $j.ActiveDB_File
    if (-not (Test-Path $dbPath)) { Write-Log "Thetis: ActiveDB_File '$($j.ActiveDB_File)' not found." Red; return $false }
    $t = Read-TextKeepEncoding $dbPath
    $profiles = [ordered]@{}
    foreach ($m in [regex]::Matches($t.Text, '<TXProfile>([\s\S]*?)</TXProfile>')) {
        if ($m.Groups[1].Value -match '<Name>([^<]+)</Name>') { $profiles[[System.Net.WebUtility]::HtmlDecode($matches[1].Trim())] = $m.Groups[1].Value }
    }
    $active = $null
    if ($t.Text -match '<Key>comboTXProfile</Key>\s*<Value>([^<]+)</Value>') { $active = [System.Net.WebUtility]::HtmlDecode($matches[1].Trim()) }
    $script:Th = @{ DbPath = $dbPath; Text = $t.Text; Encoding = $t.Encoding; Profiles = $profiles; Original = @{}; New = @(); Active = $active; Radio = ($pick.Name -replace '_dbman_settings.json', '') }
    foreach ($k in $profiles.Keys) { $script:Th.Original[$k] = $profiles[$k] }
    $script:Th.Types = Get-ThetisColumnTypes $t.Text
    return ($profiles.Count -gt 0)
}

function Thetis_Status {
    $ok = Thetis_Open
    if (-not $ok) { return @{ Available = $false; Reason = 'No Thetis DB / TXProfile blocks under %APPDATA%\OpenHPSDR\Thetis*\DB' } }
    $running = Test-ProcRunning @('Thetis')
    return @{ Available = $true; CanWrite = (-not $running); Reason = $(if ($running) { 'Thetis is running (read-only; close it to write)' } else { "$($script:Th.Radio), $($script:Th.Profiles.Count) profiles" }) }
}

function Thetis_List { Thetis_Open | Out-Null; return @(foreach ($n in ($script:Th.Profiles.Keys | Sort-Object)) { @{ Name = $n; Active = ($n -eq $script:Th.Active) } }) }

function Get-ThetisTag { param([string]$blk, [string]$tag) if ($blk -match ('<' + [regex]::Escape($tag) + '>([^<]*)</' + [regex]::Escape($tag) + '>')) { return $matches[1].Trim() }; if ($blk -match ('<' + [regex]::Escape($tag) + '\s*/>')) { return '' }; return $null }

function Thetis_Read {
    param([string]$Name)
    $blk = $script:Th.Profiles[$Name]
    if (-not $blk) { throw "Thetis profile '$Name' not found" }
    $canon = New-Canon $Name 'Thetis'
    $get = { param($tag) Get-ThetisTag $blk $tag }.GetNewClosure()
    Read-TfCanon $canon $get 't'
    return $canon
}

function Thetis_BeginWrite {
    if (Test-ProcRunning @('Thetis')) { throw "Thetis is running. Close it first (it rewrites database.xml on exit)." }
    Backup-File $script:Th.DbPath | Out-Null
    Write-Log "  Thetis write support is EXPERIMENTAL: only tags that already exist in the profile block are changed." Yellow
}

function Thetis_Write {
    param($canon, [string]$DestName, $rules, [switch]$Review)
    $isNew = -not $script:Th.Profiles.Contains($DestName)
    if ($isNew) {
        $tplName = if ($script:CloneFrom -and $script:Th.Profiles.Contains($script:CloneFrom)) { $script:CloneFrom } elseif ($script:Th.Active -and $script:Th.Profiles.Contains($script:Th.Active)) { $script:Th.Active } else { @($script:Th.Profiles.Keys)[0] }
        $blk = $script:Th.Profiles[$tplName] -replace '<Name>[^<]*</Name>', ('<Name>' + [Security.SecurityElement]::Escape($DestName) + '</Name>')
        Write-Log "  New Thetis profile '$DestName' cloned from '$tplName'." Yellow
        $script:Th.New += $DestName
    } else { $blk = $script:Th.Profiles[$DestName] }

    $writes = Get-TfWrites $canon 't' $rules 'Thetis'
    $changes = New-Object System.Collections.ArrayList
    $rounded = @()
    foreach ($w in $writes) {
        $old = Get-ThetisTag $blk $w.Key
        if ($null -eq $old) { Add-Note $canon "Thetis block has no <$($w.Key)> tag - skipped." 'DarkGray'; continue }
        $f = Format-ThetisValue $w.Key $w.Value $old $script:Th.Types
        if ($f.Changed -and $f.Why -eq 'int') { $rounded += "$($w.Key) $($w.Value)->$($f.Value)" }
        if ($old -cne $f.Value) { [void]$changes.Add(@{ Key = $w.Key; Old = $old; New = $f.Value }) }
    }
    if ($rounded) { Add-Note $canon "Thetis stores these as whole numbers, rounded: $($rounded -join ', ')" 'DarkGray' }
    $sel = Select-Changes $changes $DestName -Review:$Review
    foreach ($ch in $sel) {
        $pat = '<' + [regex]::Escape($ch.Key) + '>[^<]*</' + [regex]::Escape($ch.Key) + '>|<' + [regex]::Escape($ch.Key) + '\s*/>'
        $blk = [regex]::Replace($blk, $pat, ('<' + $ch.Key + '>' + $ch.New + '</' + $ch.Key + '>'), 1)
    }
    $script:Th.Profiles[$DestName] = $blk
    return @{ Changed = $sel.Count; Total = $changes.Count; New = $isNew }
}

function Thetis_EndWrite {
    param([string]$ActiveName, $rules)
    $text = $script:Th.Text
    foreach ($n in $script:Th.Profiles.Keys) {
        if ($script:Th.New -contains $n) { continue }
        $orig = $script:Th.Original[$n]; $cur = $script:Th.Profiles[$n]
        if ($orig -ne $cur) {
            $needle = "<TXProfile>$orig</TXProfile>"; $idx = $text.IndexOf($needle)
            if ($idx -lt 0) { throw "Could not relocate TXProfile '$n' in database.xml" }
            $text = $text.Substring(0, $idx) + "<TXProfile>$cur</TXProfile>" + $text.Substring($idx + $needle.Length)
        }
    }
    if ($script:Th.New.Count -gt 0) {
        $last = $text.LastIndexOf('</TXProfile>') + '</TXProfile>'.Length
        $ins = ($script:Th.New | ForEach-Object { "`r`n  <TXProfile>$($script:Th.Profiles[$_])</TXProfile>" }) -join ''
        $text = $text.Substring(0, $last) + $ins + $text.Substring($last)
    }
    if ($ActiveName) {
        $text = [regex]::Replace($text, '(<Key>comboTXProfile</Key>\s*<Value>)[^<]*(</Value>)', ('${1}' + [Security.SecurityElement]::Escape($ActiveName) + '${2}'), 1)
        Write-Log "  Thetis active profile -> $ActiveName" Green
    }
    if ($text -ne $script:Th.Text) {
        $err = Test-ThetisXml $text
        if ($err) { throw "NOT SAVED - Thetis would reject the result: $err  (database.xml left untouched)" }
        [IO.File]::WriteAllText($script:Th.DbPath, $text, $script:Th.Encoding)
        Write-Log "  Saved $($script:Th.DbPath)" Green
    } else { Write-Log "  Thetis: nothing to save." DarkGray }
}
