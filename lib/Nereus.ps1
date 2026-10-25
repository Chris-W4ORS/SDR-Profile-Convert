# lib/Nereus.ps1 - NereusSDR adapter (targets 2026.10.x settings schema)
# File:  %LOCALAPPDATA%\NereusSDR\NereusSDR.settings      (default)
#        %LOCALAPPDATA%\NereusSDR\profiles\<p>\NereusSDR.settings  (--profile)
# Format: flat XML, one element per key, key path escaped per AppSettings.cpp
#         encodeXmlKey() (30-token table). Keys may sit at the root or inside a
#         <Station type="station"> group - this adapter is position-agnostic.
# Profiles: hardware/<mac>/tx/profile/<name>/<Key>, manifest
#           hardware/<mac>/tx/profile/_names (comma-joined), active name in
#           hardware/<mac>/tx/profile/active (plain text).
# Blobs: TXParaEQData / CFCParaEQData use Thetis's own envelope and JSON; since
#        2026.10 NereusSDR reads Thetis curves directly (ParaEqCurve.cpp), so
#        the old 18-band 0-2700 Hz re-grid is no longer needed or done.

$script:Nr = $null

$script:NereusKeyEsc = [ordered]@{
    ':' = '__c__'; '/' = '__s__'; '[' = '__lb__'; ']' = '__rb__'; '+' = '__plus__'; ' ' = '__sp__'; '?' = '__qm__'; '&' = '__amp__'
    '#' = '__hash__'; '(' = '__lp__'; ')' = '__rp__'; ',' = '__cm__'; '@' = '__at__'; '!' = '__excl__'; '*' = '__ast__'; "'" = '__sq__'
    '"' = '__dq__'; '=' = '__eq__'; ';' = '__sc__'; '<' = '__lt__'; '>' = '__gt__'; '{' = '__lc__'; '}' = '__rc__'; '|' = '__pipe__'
    '$' = '__dlr__'; '%' = '__pct__'; '^' = '__caret__'; '~' = '__tilde__'; '`' = '__bt__'; '\' = '__bs__'
}
function ConvertTo-NereusTag {
    param([string]$Key)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Key.ToCharArray()) { $s = [string]$ch; if ($script:NereusKeyEsc.Contains($s)) { [void]$sb.Append($script:NereusKeyEsc[$s]) } else { [void]$sb.Append($ch) } }
    return $sb.ToString()
}
function ConvertFrom-NereusTag {
    param([string]$Tag)
    $out = $Tag
    foreach ($k in $script:NereusKeyEsc.Keys) { $out = $out.Replace($script:NereusKeyEsc[$k], $k) }
    return $out
}
function Get-NereusVal {
    param([string]$Key)
    $t = [regex]::Escape((ConvertTo-NereusTag $Key))
    $m = [regex]::Match($script:Nr.Text, "<$t>([^<]*)</$t>")
    if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    if ([regex]::IsMatch($script:Nr.Text, "<$t\s*/>")) { return '' }
    return $null
}
function Set-NereusVal {
    # Replace an existing element, or insert next to $AnchorKey's element. Returns $true if changed.
    param([string]$Key, [string]$Value, [string]$AnchorKey)
    $tag = ConvertTo-NereusTag $Key; $t = [regex]::Escape($tag)
    $esc = [Security.SecurityElement]::Escape($Value)
    $rx = New-Object regex ("<$t>[^<]*</$t>|<$t\s*/>")
    if ($rx.IsMatch($script:Nr.Text)) { $script:Nr.Text = $rx.Replace($script:Nr.Text, "<$tag>$esc</$tag>", 1); return $true }
    if (-not $AnchorKey) { return $false }
    $at = [regex]::Escape((ConvertTo-NereusTag $AnchorKey))
    $m = [regex]::Match($script:Nr.Text, "(?m)^([ \t]*)<$at>")
    if (-not $m.Success) { return $false }
    $line = "$($m.Groups[1].Value)<$tag>$esc</$tag>$($script:Nr.NL)"
    $script:Nr.Text = $script:Nr.Text.Insert($m.Index, $line)
    return $true
}

function Nereus_Open {
    if ($script:Nr) { return $true }
    $base = Join-Path $env:LOCALAPPDATA 'NereusSDR'
    $files = @()
    if (Test-Path (Join-Path $base 'NereusSDR.settings')) { $files += Get-Item (Join-Path $base 'NereusSDR.settings') }
    $files += @(Get-ChildItem (Join-Path $base 'profiles') -Filter 'NereusSDR.settings' -Recurse -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return $false }
    $f = if ($files.Count -eq 1) { $files[0] } else { Select-Item "NereusSDR settings file:" $files { param($x) "$($x.FullName)  ($([math]::Round($x.Length/1KB)) KB, $($x.LastWriteTime))" } }
    $t = Read-TextKeepEncoding $f.FullName
    if ($t.Text -notmatch '<NereusSDR[\s>]') { Write-Log "NereusSDR: $($f.FullName) has no <NereusSDR> root - format changed? Run Probe-SdrStores.ps1." Red; return $false }
    $macs = @([regex]::Matches($t.Text, 'hardware__s__(.+?)__s__tx__s__profile__s___names') | ForEach-Object { ConvertFrom-NereusTag $_.Groups[1].Value } | Select-Object -Unique)
    if ($macs.Count -eq 0) { Write-Log "NereusSDR: no TX profile manifest (hardware/<mac>/tx/profile/_names) in $($f.FullName). Connect to the radio once, or run Probe-SdrStores.ps1." Red; return $false }
    $last = $null; if ($t.Text -match '<radios__s__lastConnected>([^<]+)</radios__s__lastConnected>') { $last = $matches[1].Trim() }
    $mac = if ($macs.Count -eq 1) { $macs[0] } elseif ($last -and ($macs -contains $last)) { $last } else { Select-Item "NereusSDR radio (MAC):" $macs }
    $nl = if ($t.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $script:Nr = @{ Path = $f.FullName; Text = $t.Text; Original = $t.Text; Encoding = $t.Encoding; Mac = $mac; NL = $nl; Written = @() }
    $script:Nr.ProfRoot = "hardware/$mac/tx/profile/"
    $script:Nr.Names = @(((Get-NereusVal ($script:Nr.ProfRoot + '_names')) -split ',') | Where-Object { $_ })
    $script:Nr.Active = Get-NereusVal ($script:Nr.ProfRoot + 'active')
    $script:Nr.Schema = Get-NereusVal 'SettingsSchemaVersion'
    return $true
}

function Nereus_Status {
    if (-not (Nereus_Open)) { return @{ Available = $false; Reason = 'No usable NereusSDR.settings under %LOCALAPPDATA%\NereusSDR' } }
    $running = Test-ProcRunning @('NereusSDR', 'nereusd')
    $info = "MAC $($script:Nr.Mac), $($script:Nr.Names.Count) profiles, schema v$($script:Nr.Schema)"
    if ([int](ConvertTo-Num $script:Nr.Schema 0) -lt 10) { $info += ' (pre-2026.10 schema: update NereusSDR first)' }
    return @{ Available = $true; CanWrite = (-not $running); Reason = $(if ($running) { "NereusSDR is running (read-only). $info" } else { $info }) }
}

function Nereus_List { Nereus_Open | Out-Null; return @(foreach ($n in ($script:Nr.Names | Sort-Object)) { @{ Name = $n; Active = ($n -eq $script:Nr.Active) } }) }

function Nereus_Read {
    param([string]$Name)
    if ($script:Nr.Names -notcontains $Name) { throw "NereusSDR profile '$Name' not in manifest" }
    $canon = New-Canon $Name 'Nereus'
    $pre = $script:Nr.ProfRoot + $Name + '/'
    $txRoot = "hardware/$($script:Nr.Mac)/tx/"
    # Per-profile first; fall back to the tx-level live key (older builds kept DEXP there)
    $get = { param($k) $v = Get-NereusVal ($pre + $k); if ($null -eq $v) { $v = Get-NereusVal ($txRoot + $k) }; $v }.GetNewClosure()
    Read-TfCanon $canon $get 'n'
    return $canon
}

function Nereus_BeginWrite {
    if (Test-ProcRunning @('NereusSDR', 'nereusd')) { throw "NereusSDR (or nereusd) is running. Close it first - it holds the settings in memory and rewrites the file on exit." }
    Backup-File $script:Nr.Path | Out-Null
}

function Nereus_Write {
    param($canon, [string]$DestName, $rules, [switch]$Review)
    if ($DestName.Contains(',')) { throw "NereusSDR profile names cannot contain ',' (the manifest is comma-joined)." }
    $root = $script:Nr.ProfRoot; $pre = $root + $DestName + '/'
    $namesKey = $root + '_names'
    $isNew = $script:Nr.Names -notcontains $DestName
    if ($isNew) {
        # Clone every key of an existing profile so the new one carries the full,
        # CURRENT key set of this NereusSDR build (no hard-coded default list).
        $tpl = if ($script:CloneFrom -and ($script:Nr.Names -contains $script:CloneFrom)) { $script:CloneFrom } elseif ($script:Nr.Active -and ($script:Nr.Names -contains $script:Nr.Active)) { $script:Nr.Active } else { $script:Nr.Names[0] }
        $tplTag = [regex]::Escape((ConvertTo-NereusTag ($root + $tpl + '/')))
        $cloned = 0
        foreach ($m in [regex]::Matches($script:Nr.Text, "<($tplTag)([^>/\s]+)>([^<]*)</\1\2>")) {
            $suffix = ConvertFrom-NereusTag $m.Groups[2].Value
            if ($suffix.Contains('/')) { continue }   # belongs to a profile whose name starts with '$tpl/'
            if (Set-NereusVal ($pre + $suffix) ([System.Net.WebUtility]::HtmlDecode($m.Groups[3].Value)) $namesKey) { $cloned++ }
        }
        $script:Nr.Names += $DestName
        Set-NereusVal $namesKey ($script:Nr.Names -join ',') | Out-Null
        Write-Log "  New NereusSDR profile '$DestName' ($cloned keys cloned from '$tpl')." Yellow
    }

    $writes = Get-TfWrites $canon 'n' $rules 'Nereus'
    $changes = New-Object System.Collections.ArrayList
    foreach ($w in $writes) {
        $old = Get-NereusVal ($pre + $w.Key)
        if ($old -ne $w.Value) { [void]$changes.Add(@{ Key = $w.Key; Old = $old; New = $w.Value; Full = ($pre + $w.Key) }) }
    }
    if ([bool](Get-SdrOption $rules 'Nereus' 'writeDspGlobals' $true)) {
        foreach ($m in $script:TfDspMap) {
            $v = $canon.dsp[$m.p.Split('.')[1]]; if ($null -eq $v) { continue }
            $old = Get-NereusVal $m.n
            if ($null -ne $old -and $old -ne $v) { [void]$changes.Add(@{ Key = "(global) $($m.n)"; Old = $old; New = [string]$v; Full = $m.n }) }
        }
    }
    $sel = Select-Changes $changes $DestName -Review:$Review
    $added = @($sel | Where-Object { $null -eq $_.Old } | ForEach-Object { $_.Key })
    if ($added.Count) { Add-Note $canon "$($added.Count) key(s) absent from the profile were added: $(($added | Select-Object -First 8) -join ', ')$(if ($added.Count -gt 8) { ', ...' })" 'DarkGray' }
    foreach ($ch in $sel) {
        if (-not (Set-NereusVal $ch.Full $ch.New $namesKey)) { Add-Note $canon "could not write $($ch.Key)." Red }
    }
    $script:Nr.Written += $DestName
    return @{ Changed = $sel.Count; Total = $changes.Count; New = $isNew }
}

function Nereus_EndWrite {
    param([string]$ActiveName, $rules)
    $root = $script:Nr.ProfRoot
    if ($ActiveName) { Set-NereusVal ($root + 'active') $ActiveName | Out-Null; $script:Nr.Active = $ActiveName; Write-Log "  NereusSDR active profile -> $ActiveName" Green }
    # NereusSDR keeps a live working copy of the TX chain at hardware/<mac>/tx/<Key>.
    # If the active profile was (re)written, copy it into whatever live keys exist
    # so the next launch shows it even before the profile is re-selected.
    $act = $script:Nr.Active
    if ($act -and ($script:Nr.Written -contains $act -or $ActiveName) -and [bool](Get-SdrOption $rules 'Nereus' 'mirrorActiveToLive' $true)) {
        $pre = ConvertTo-NereusTag ($root + $act + '/'); $live = "hardware/$($script:Nr.Mac)/tx/"; $n = 0
        foreach ($m in [regex]::Matches($script:Nr.Text, "<($([regex]::Escape($pre)))([^>/\s]+)>([^<]*)</\1\2>")) {
            $k = ConvertFrom-NereusTag $m.Groups[2].Value
            if ($k.Contains('/')) { continue }
            if ($null -ne (Get-NereusVal ($live + $k))) { if (Set-NereusVal ($live + $k) ([System.Net.WebUtility]::HtmlDecode($m.Groups[3].Value))) { $n++ } }
        }
        $legacy = Get-NereusVal ($root + $act + '/EQUseLegacy')
        if ($null -ne $legacy -and $null -ne (Get-NereusVal 'TxEqDialog/UsingLegacyEQ')) { Set-NereusVal 'TxEqDialog/UsingLegacyEQ' $legacy | Out-Null }
        Write-Log "  Mirrored '$act' into $n live tx-level keys." DarkGray
    }
    if ($script:Nr.Text -ne $script:Nr.Original) {
        [IO.File]::WriteAllText($script:Nr.Path, $script:Nr.Text, $script:Nr.Encoding)
        Write-Log "  Saved $($script:Nr.Path)" Green
    } else { Write-Log "  NereusSDR: nothing to save." DarkGray }
}
