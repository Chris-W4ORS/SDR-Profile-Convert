<#
.SYNOPSIS
  Back up, then delete every TX profile in Thetis and/or NereusSDR except ONE seed profile each.

.DESCRIPTION
  The seed is kept because both apps need at least one profile, and because
  Convert-SdrProfile.ps1 creates new profiles by cloning an existing one (that's
  how they get each app's full, current key set).

  PREVIEW BY DEFAULT - nothing changes unless you add -Apply.
  With -Apply:
    1. Refuses to run while Thetis / NereusSDR / nereusd are open.
    2. Copies the whole Thetis DB folder and every NereusSDR *.settings file to
       Documents\SdrConvert\Backups\Reset_<timestamp>\ (with RESTORE.txt).
    3. Thetis: removes the other <TXProfile> blocks, points comboTXProfile and any
       other *TXProfile* setting that named a deleted profile at the seed.
    4. NereusSDR: removes every key of the other profiles, rewrites the _names
       manifest and the active profile, reports any other setting that still
       names a deleted profile.

.EXAMPLE
  .\Reset-SdrProfiles.ps1                                   # preview both apps
.EXAMPLE
  .\Reset-SdrProfiles.ps1 -KeepThetis "My Seed" -KeepNereus "My Seed" -Apply
#>
[CmdletBinding()]
param(
    [ValidateSet('Both', 'Thetis', 'Nereus', 'Aether', 'All')][string]$Target = 'Both',   # Both = Thetis + NereusSDR
    [string]$KeepThetis,   # default: Thetis's current active profile
    [string]$KeepNereus,   # default: the NereusSDR profile with the most keys (best clone template)
    [string]$KeepAether,   # required for Aether: the TX profile to keep (its same-named RX profile is kept too)
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
foreach ($f in 'Common', 'ThetisFamily', 'Thetis', 'Nereus', 'Aether') { . (Join-Path $PSScriptRoot "lib\$f.ps1") }
Initialize-SdrLog 'Reset'
Write-Head "Reset TX profiles - $(if ($Apply) { 'APPLY' } else { 'PREVIEW (add -Apply to make changes)' })"

$doT = $Target -in 'Both', 'Thetis', 'All'; $doN = $Target -in 'Both', 'Nereus', 'All'; $doA = $Target -in 'Aether', 'All'
if ($Apply) {
    $busy = @(); if ($doT -and (Test-ProcRunning @('Thetis'))) { $busy += 'Thetis' }; if ($doN -and (Test-ProcRunning @('NereusSDR', 'nereusd'))) { $busy += 'NereusSDR/nereusd' }
    if ($doA -and (Test-ProcRunning @('AetherSDR'))) { $busy += 'AetherSDR' }
    if ($busy) { Write-Log "Close $($busy -join ' and ') first - they rewrite their settings on exit." Red; exit 1 }
}

# ---------------------------------------------------------------- Thetis plan
$tPlan = $null
if ($doT) {
    Write-Log ""; Write-Log "Thetis" Cyan
    if (-not (Thetis_Open)) { Write-Log "  Thetis DB not found - skipped." Yellow }
    else {
        $names = @($script:Th.Profiles.Keys)
        $keep = if ($KeepThetis) { $KeepThetis } else { $script:Th.Active }
        if ($names -notcontains $keep) { Write-Log "  Seed '$keep' is not a Thetis profile. Pick one of: $($names -join ', ')" Red; exit 1 }
        $del = @($names | Where-Object { $_ -ne $keep })
        $tagCount = @{}; foreach ($n in $names) { $tagCount[$n] = ([regex]::Matches($script:Th.Profiles[$n], '<[A-Za-z0-9_]+>')).Count }
        $best = ($tagCount.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
        Write-Log "  DB:     $($script:Th.DbPath)"
        Write-Log "  Keep:   '$keep' ($($tagCount[$keep]) tags)$(if ($tagCount[$keep] -lt $best.Value) { "  - note: '$($best.Key)' has more tags ($($best.Value)); a fuller seed makes better clones" })" Green
        Write-Log "  Delete: $($del.Count) profile(s): $($del -join ', ')" Yellow
        $refs = @([regex]::Matches($script:Th.Text, '<Key>([^<]*TXProfile[^<]*)</Key>\s*<Value>([^<]*)</Value>') | Where-Object { $del -contains [System.Net.WebUtility]::HtmlDecode($_.Groups[2].Value) })
        foreach ($r in $refs) { Write-Log "  Repoint setting '$($r.Groups[1].Value)': '$($r.Groups[2].Value)' -> '$keep'" Yellow }
        $tPlan = @{ Keep = $keep; Del = $del }
    }
}

# ---------------------------------------------------------------- Nereus plan
$nPlan = $null
if ($doN) {
    Write-Log ""; Write-Log "NereusSDR" Cyan
    if (-not (Nereus_Open)) { Write-Log "  NereusSDR settings not found - skipped." Yellow }
    else {
        $names = @($script:Nr.Names)
        $keyCount = @{}
        foreach ($n in $names) { $pfx = [regex]::Escape((ConvertTo-NereusTag ($script:Nr.ProfRoot + $n + '/'))); $keyCount[$n] = ([regex]::Matches($script:Nr.Text, "<$pfx(?:(?!__s__)[^>/\s])+>")).Count }
        $keep = if ($KeepNereus) { $KeepNereus } else { ($keyCount.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key }
        if ($names -notcontains $keep) { Write-Log "  Seed '$keep' is not a NereusSDR profile. Pick one of: $($names -join ', ')" Red; exit 1 }
        $del = @($names | Where-Object { $_ -ne $keep })
        $delKeys = 0; foreach ($n in $del) { $delKeys += $keyCount[$n] }
        Write-Log "  File:   $($script:Nr.Path)  (MAC $($script:Nr.Mac))"
        Write-Log "  Keep:   '$keep' ($($keyCount[$keep]) keys)" Green
        Write-Log "  Delete: $($del.Count) profile(s), $delKeys keys: $($del -join ', ')" Yellow
        Write-Log "  Active: '$($script:Nr.Active)' -> '$keep'"
        $nPlan = @{ Keep = $keep; Del = $del }
    }
}

# ---------------------------------------------------------------- Aether plan
$aPlan = $null
if ($doA) {
    Write-Log ""; Write-Log "AetherSDR" Cyan
    if (-not (Aether_Open) -or $script:Ae.Mode -ne 'library') { Write-Log "  No AetherTX profile library (needs AetherSDR 26.9.4+, launched once) - skipped." Yellow }
    else {
        $tx = @($script:Ae.Tx.profiles.Keys); $rx = @($script:Ae.Rx.profiles.Keys)
        Write-Log "  TX library: $($script:Ae.TxPath)"
        if (-not $KeepAether) { Write-Log "  Pass -KeepAether ""<name>"" - TX profiles: $($tx -join ', ')" Red; exit 1 }
        if ($tx -notcontains $KeepAether) { Write-Log "  '$KeepAether' is not an AetherTX profile (convert it to Aether first). TX profiles: $($tx -join ', ')" Red; exit 1 }
        $aPlan = @{ Keep = $KeepAether; DelTx = @($tx | Where-Object { $_ -ne $KeepAether }); DelRx = @($rx | Where-Object { $_ -ne $KeepAether }) }
        Write-Log "  Keep:   '$KeepAether' (TX$(if ($rx -contains $KeepAether) { ' + RX' }))" Green
        Write-Log "  Delete: TX $($aPlan.DelTx.Count): $($aPlan.DelTx -join ', ')" Yellow
        Write-Log "          RX $($aPlan.DelRx.Count): $($aPlan.DelRx -join ', ')" Yellow
    }
}

if (-not $Apply) {
    Write-Log ""; Write-Log "Preview only. Re-run with -Apply to back up and delete (close the apps being reset first)." Cyan
    exit 0
}
if (-not (Confirm-Yes "`nBack up, then delete the profiles listed above?")) { Write-Log "Cancelled." Yellow; exit 0 }

# ---------------------------------------------------------------- backup
$bk = Join-Path $env:USERPROFILE "Documents\SdrConvert\Backups\Reset_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $bk -Force | Out-Null
$restore = @("Restore = close the app, then copy these back over the originals:")
if ($tPlan) {
    $dbDir = Split-Path $script:Th.DbPath
    Copy-Item -LiteralPath $dbDir -Destination (Join-Path $bk 'Thetis-DB') -Recurse -Force
    $restore += "  Thetis:    $bk\Thetis-DB\*   ->  $dbDir\"
}
if ($nPlan) {
    $nbk = Join-Path $bk 'NereusSDR'; New-Item -ItemType Directory -Path $nbk -Force | Out-Null
    $nroot = Join-Path $env:LOCALAPPDATA 'NereusSDR'
    foreach ($f in @(Get-ChildItem $nroot -Filter '*.settings' -Recurse)) {
        $rel = $f.FullName.Substring($nroot.Length).TrimStart('\', '/')
        $dst = Join-Path $nbk $rel; New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    }
    $restore += "  NereusSDR: $nbk\*   ->  $nroot\"
}
if ($aPlan) {
    $abk = Join-Path $bk 'AetherSDR'; New-Item -ItemType Directory -Path $abk -Force | Out-Null
    foreach ($f in @($script:Ae.TxPath, $script:Ae.RxPath)) { if (Test-Path $f) { Copy-Item -LiteralPath $f -Destination $abk -Force } }
    $restore += "  AetherSDR: $abk\*   ->  $($script:Ae.Dir)\"
}
$restore | Set-Content (Join-Path $bk 'RESTORE.txt') -Encoding UTF8
Write-Log ""; Write-Log "Backup: $bk" Green

# ---------------------------------------------------------------- Thetis apply
if ($tPlan) {
    $text = $script:Th.Text
    foreach ($n in $tPlan.Del) {
        $needle = "<TXProfile>$($script:Th.Original[$n])</TXProfile>"
        $idx = $text.IndexOf($needle)
        if ($idx -lt 0) { Write-Log "  [WARN] could not locate Thetis block '$n' - left in place" Yellow; continue }
        $start = $idx; while ($start -gt 0 -and " `t`r`n".Contains($text[$start - 1])) { $start-- }   # take its leading whitespace too
        $text = $text.Remove($start, ($idx - $start) + $needle.Length)
    }
    $keepEsc = [Security.SecurityElement]::Escape($tPlan.Keep); $del = $tPlan.Del
    $text = [regex]::Replace($text, '(<Key>[^<]*TXProfile[^<]*</Key>\s*<Value>)([^<]*)(</Value>)', {
            param($m) if ($del -contains [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)) { $m.Groups[1].Value + $keepEsc + $m.Groups[3].Value } else { $m.Value } }.GetNewClosure())
    $err = Test-ThetisXml $text
    if ($err) { Write-Log "Thetis NOT changed - the result would not load: $err" Red }
    else { [IO.File]::WriteAllText($script:Th.DbPath, $text, $script:Th.Encoding) }
    $left = ([regex]::Matches($text, '<TXProfile>')).Count
    Write-Log "Thetis: $($tPlan.Del.Count) profile(s) removed, $left left ('$($tPlan.Keep)')." Green
}

# ---------------------------------------------------------------- Nereus apply
if ($nPlan) {
    $removed = 0
    foreach ($n in $nPlan.Del) {
        $pfx = [regex]::Escape((ConvertTo-NereusTag ($script:Nr.ProfRoot + $n + '/')))
        # (?!__s__) guard: never touch keys of a profile whose name merely starts with "<n>/"
        $rx = New-Object regex ("[ \t]*<($pfx)((?:(?!__s__)[^>/\s])+)(?:>[^<]*</\1\2>|\s*/>)\r?\n?")
        $removed += $rx.Matches($script:Nr.Text).Count
        $script:Nr.Text = $rx.Replace($script:Nr.Text, '')
    }
    Set-NereusVal ($script:Nr.ProfRoot + '_names') $nPlan.Keep | Out-Null
    Set-NereusVal ($script:Nr.ProfRoot + 'active') $nPlan.Keep | Out-Null
    # report (don't guess at) any other setting that still names a deleted profile
    foreach ($m in [regex]::Matches($script:Nr.Text, '<([^>\s/]*[Pp]rofile[^>\s/]*)>([^<]+)</\1>')) {
        $v = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)
        if ($nPlan.Del -contains $v) { Write-Log "  [CHECK] $(ConvertFrom-NereusTag $m.Groups[1].Value) still = '$v'" Yellow }
    }
    [IO.File]::WriteAllText($script:Nr.Path, $script:Nr.Text, $script:Nr.Encoding)
    Write-Log "NereusSDR: $($nPlan.Del.Count) profile(s) / $removed keys removed; only '$($nPlan.Keep)' left and active." Green
}

# ---------------------------------------------------------------- Aether apply
if ($aPlan) {
    foreach ($n in $aPlan.DelTx) { $script:Ae.Tx.profiles.Remove($n) }
    foreach ($n in $aPlan.DelRx) { $script:Ae.Rx.profiles.Remove($n) }
    # AetherSDR re-imports the retired ChannelStrip presets unless this flag is set - make sure
    # the deleted profiles can't come back from ChannelStrip.settings on next launch
    $script:Ae.Tx.migratedFromChannelStrip = $true; $script:Ae.Rx.migratedFromChannelStrip = $true
    Write-JsonFile $script:Ae.Tx $script:Ae.TxPath; Write-JsonFile $script:Ae.Rx $script:Ae.RxPath
    Write-Log "AetherSDR: $($aPlan.DelTx.Count) TX / $($aPlan.DelRx.Count) RX profile(s) removed; only '$($aPlan.Keep)' left." Green
}

Write-Log ""
$seed = @($KeepNereus, $KeepThetis, $KeepAether) | Where-Object { $_ } | Select-Object -First 1
if (-not $seed) { $seed = '<seed>' }
Write-Log "Next - copy profiles in (source app running, destination apps closed), e.g.:" Cyan
Write-Log "  .\Convert-SdrProfile.ps1 -From Zeus -To Nereus -NoActive -CloneFrom ""$seed""" White
Write-Log "  .\Convert-SdrProfile.ps1 -From Zeus -To Thetis -NoActive -CloneFrom ""$seed""" White
Write-Log "  .\Convert-SdrProfile.ps1 -From Zeus -To Aether" White
Write-Log "The kept profile is the clone template for new Thetis/NereusSDR profiles - keep it." DarkGray
Write-Log "Log: $script:LogPath" DarkGray
