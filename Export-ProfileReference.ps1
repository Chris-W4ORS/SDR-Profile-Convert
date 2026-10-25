<#
.SYNOPSIS
  Read-only reference export of TX profiles from NereusSDR, Thetis and AetherSDR.
.DESCRIPTION
  For every NereusSDR and Thetis TX profile and AetherTX profile whose name matches -Match,
  writes a readable Reference.md summary plus the raw settings of each profile
  (NereusSDR keys with the EQ/CFC curves decoded; AetherTX/RX profile JSON).
  Changes nothing in either app; safe to run with both apps open.
.EXAMPLE
  .\Export-ProfileReference.ps1
  .\Export-ProfileReference.ps1 -Match "Chris 3k*"
#>
[CmdletBinding()]
param(
    [string]$Match = 'Chris*',
    [string]$OutDir = (Join-Path $PSScriptRoot ("Reference_" + (Get-Date -Format 'yyyyMMdd_HHmmss')))
)
$ErrorActionPreference = 'Stop'
foreach ($f in 'Common', 'ThetisFamily', 'Thetis', 'Nereus', 'Aether') { . (Join-Path $PSScriptRoot "lib\$f.ps1") }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$md = New-Object System.Collections.Generic.List[string]
function Add-Md { param([string]$s = '') $md.Add(([regex]::Replace($s, '(\d+\.\d{2})\d{3,}', '$1'))) }   # trim float noise like 69.9000015
function Safe { param([string]$n) $n -replace '[\\/:*?"<>|]', '_' }
function Db { param($lin) if ($null -eq $lin -or [double]$lin -le 0) { return 'n/a' }; '{0:+0.0;-0.0} dB' -f (20 * [math]::Log10([double]$lin)) }
function OnOff { param($v) if ($null -eq $v -or "$v" -eq '') { '-' } elseif ("$v" -match '^(?i:true|1)$') { 'on' } elseif ("$v" -match '^(?i:false|0)$') { 'off' } else { "$v" } }

Add-Md "# TX profile reference"
Add-Md ""
Add-Md "Exported $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME, profiles matching '$Match'. Read-only snapshot."

# ============================================================================ NereusSDR
Add-Md ""; Add-Md "## NereusSDR"
if (-not (Nereus_Open)) { Add-Md ""; Add-Md "_No usable NereusSDR.settings found._"; Write-Host "NereusSDR: not found" -ForegroundColor Yellow }
else {
    Add-Md ""; Add-Md "Settings file: ``$($script:Nr.Path)`` - radio $($script:Nr.Mac), schema v$($script:Nr.Schema), active TX profile: **$($script:Nr.Active)**"
    $names = @($script:Nr.Names | Where-Object { $_ -like $Match } | Sort-Object)
    if ($names.Count -eq 0) { Add-Md ""; Add-Md "_No NereusSDR profile matches '$Match'. Profiles: $($script:Nr.Names -join ', ')_" }
    foreach ($n in $names) {
        $pfxTag = ConvertTo-NereusTag ($script:Nr.ProfRoot + $n + '/')
        $raw = [ordered]@{}
        foreach ($m in [regex]::Matches($script:Nr.Text, "<($([regex]::Escape($pfxTag))([^>\s/]+))>([^<]*)</\1>")) {
            $raw[(ConvertFrom-NereusTag $m.Groups[2].Value)] = [System.Net.WebUtility]::HtmlDecode($m.Groups[3].Value)
        }
        $g = { param($k) if ($raw.Contains($k)) { $raw[$k] } else { $null } }
        $para = $null; $cfcPara = $null
        if ($raw.Contains('TXParaEQData')) { $t = ConvertFrom-SdrBlob $raw['TXParaEQData']; if ($t) { try { $para = $t | ConvertFrom-Json } catch { } } }
        if ($raw.Contains('CFCParaEQData')) { $cfcPara = ConvertFrom-SdrBlob $raw['CFCParaEQData'] }

        Add-Md ""; Add-Md "### $n$(if ($n -eq $script:Nr.Active) { ' (active)' })"
        Add-Md ""
        Add-Md "| Stage | Setting |"; Add-Md "|---|---|"
        Add-Md "| TX filter | $(& $g 'FilterLow') - $(& $g 'FilterHigh') Hz |"
        Add-Md "| Mic gain | $(& $g 'MicGain') dB |"
        $mode = if ((OnOff (& $g 'EQUseLegacy')) -eq 'off') { 'parametric' } else { 'legacy 10-band' }
        $eqLine = "$(OnOff (& $g 'TXEQEnabled')), $mode"
        if ($para -and $mode -eq 'parametric') { $eqLine += ", $(@($para.points).Count) points, Q factors $(OnOff $para.parametric_eq), preamp $($para.global_gain_db) dB, range $($para.frequency_min_hz)-$($para.frequency_max_hz) Hz" }
        else { $eqLine += ", preamp $(& $g 'TXEQPreamp') dB" }
        Add-Md "| TX EQ | $eqLine |"
        Add-Md "| Leveler | $(OnOff (& $g 'Lev_On')), max gain $(& $g 'Lev_MaxGain') dB, decay $(& $g 'Lev_Decay') ms |"
        Add-Md "| CFC | $(OnOff (& $g 'CFCEnabled')), pre-comp $(& $g 'CFCPreComp') dB, post-EQ $(OnOff (& $g 'CFCPostEqEnabled')) (gain $(& $g 'CFCPostEqGain') dB) |"
        $cb = @(for ($i = 0; $i -le 9; $i++) { if ($raw.Contains("CFCEqFreq$i")) { "$($raw["CFCEqFreq$i"]) Hz: comp $($raw["CFCPreComp$i"]) / post $($raw["CFCPostEqGain$i"])" } })
        if ($cb.Count) { Add-Md "| CFC bands | $($cb -join '; ') |" }
        Add-Md "| Compander (PROC level) | $(& $g 'CompanderLevel') dB (PROC on/off is global in NereusSDR) |"
        Add-Md "| Phase rotator | $(OnOff (& $g 'CFCPhaseRotatorEnabled')), $(& $g 'CFCPhaseRotatorStages') stages, $(& $g 'CFCPhaseRotatorFreq') Hz, reverse $(OnOff (& $g 'CFCPhaseReverseEnabled')) |"
        Add-Md "| CESSB | $(OnOff (& $g 'CESSB_On')) |"
        Add-Md "| ALC | max gain $(& $g 'ALC_MaximumGain') dB, decay $(& $g 'ALC_Decay') ms |"
        Add-Md "| DEXP | $(OnOff (& $g 'DEXP_Enabled')), threshold $(& $g 'Dexp_Threshold') dB, expansion $(& $g 'DEXP_ExpansionRatioDb') dB, attack $(& $g 'DEXP_AttackTimeMs') / release $(& $g 'DEXP_ReleaseTimeMs') ms |"
        if ($para -and $mode -eq 'parametric') {
            Add-Md ""; Add-Md ("EQ points (Hz / dB / Q): " + ((@($para.points) | ForEach-Object { "$([math]::Round([double]$_.frequency_hz)) / $($_.gain_db) / $($_.q)" }) -join ' | '))
        }

        $base = Join-Path $OutDir ("Nereus_" + (Safe $n))
        ($raw.GetEnumerator() | Where-Object { $_.Key -notin 'TXParaEQData', 'CFCParaEQData' } | ForEach-Object { "$($_.Key) = $($_.Value)" }) | Set-Content "$base.keys.txt" -Encoding UTF8
        if ($para) { $para | ConvertTo-Json -Depth 10 | Set-Content "$base.TXParaEQ.json" -Encoding UTF8 }
        if ($cfcPara) { $cfcPara | Set-Content "$base.CFCParaEQ.txt" -Encoding UTF8 }
        Write-Host "NereusSDR: $n ($($raw.Count) keys)" -ForegroundColor Green
    }
}

# ============================================================================ Thetis
Add-Md ""; Add-Md "## Thetis"
if (-not (Thetis_Open)) { Add-Md ""; Add-Md "_No Thetis database found._"; Write-Host "Thetis: not found" -ForegroundColor Yellow }
else {
    if (Test-ProcRunning @('Thetis')) { Add-Md ""; Add-Md "_Thetis was running during the export: it writes its database on exit, so the newest edits may be missing._"; Write-Host "Thetis is running - close it for an up-to-date export." -ForegroundColor Yellow }
    Add-Md ""; Add-Md "Database: ``$($script:Th.DbPath)`` - active TX profile: **$($script:Th.Active)**"
    $names = @($script:Th.Profiles.Keys | Where-Object { $_ -like $Match } | Sort-Object)
    if ($names.Count -eq 0) { Add-Md ""; Add-Md "_No Thetis profile matches '$Match'. Profiles: $(@($script:Th.Profiles.Keys) -join ', ')_" }
    foreach ($n in $names) {
        $raw = [ordered]@{}
        foreach ($m in [regex]::Matches($script:Th.Profiles[$n], '<([A-Za-z_][\w]*)>([^<]*)</\1>')) { $raw[$m.Groups[1].Value] = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value) }
        $g = { param($k) if ($raw.Contains($k)) { $raw[$k] } else { $null } }
        $para = $null; $cfcPara = $null
        if ($raw.Contains('TXParaEQData')) { $t = ConvertFrom-SdrBlob $raw['TXParaEQData']; if ($t) { try { $para = $t | ConvertFrom-Json } catch { } } }
        if ($raw.Contains('CFCParaEQData')) { $cfcPara = ConvertFrom-SdrBlob $raw['CFCParaEQData'] }
        Add-Md ""; Add-Md "### $n$(if ($n -eq $script:Th.Active) { ' (active)' })"
        Add-Md ""
        Add-Md "| Stage | Setting |"; Add-Md "|---|---|"
        Add-Md "| TX filter | $(& $g 'FilterLow') - $(& $g 'FilterHigh') Hz |"
        Add-Md "| Mic gain | $(& $g 'MicGain') dB |"
        $mode = if ((OnOff (& $g 'EQUseLegacy')) -eq 'off') { 'parametric' } else { 'legacy 10-band' }
        $eqLine = "$(OnOff (& $g 'TXEQEnabled')), $mode"
        if ($para -and $mode -eq 'parametric') { $eqLine += ", $(@($para.points).Count) points, Q factors $(OnOff $para.parametric_eq), preamp $($para.global_gain_db) dB, range $($para.frequency_min_hz)-$($para.frequency_max_hz) Hz" }
        else { $eqLine += ", preamp $(& $g 'TXEQPreamp') dB" }
        Add-Md "| TX EQ | $eqLine |"
        Add-Md "| Leveler | $(OnOff (& $g 'Lev_On')), max gain $(& $g 'Lev_MaxGain') dB, decay $(& $g 'Lev_Decay') ms |"
        Add-Md "| CFC | $(OnOff (& $g 'CFCEnabled')), $(if ((OnOff (& $g 'CFCUseLegacy')) -eq 'off') { '18-band' } else { 'legacy 10-band' }), pre-comp $(& $g 'CFCPreComp') dB, post-EQ $(OnOff (& $g 'CFCPostEqEnabled')) (gain $(& $g 'CFCPostEqGain') dB) |"
        $cb = @(for ($i = 0; $i -le 9; $i++) { if ($raw.Contains("CFCEqFreq$i")) { "$($raw["CFCEqFreq$i"]) Hz: comp $($raw["CFCPreComp$i"]) / post $($raw["CFCPostEqGain$i"])" } })
        if ($cb.Count) { Add-Md "| CFC bands | $($cb -join '; ') |" }
        Add-Md "| Compander (COMP/CPDR) | $(OnOff (& $g 'CompanderOn')), $(& $g 'CompanderLevel') dB |"
        Add-Md "| Phase rotator | $(OnOff (& $g 'CFCPhaseRotatorEnabled')), $(& $g 'CFCPhaseRotatorStages') stages, $(& $g 'CFCPhaseRotatorFreq') Hz, reverse $(OnOff (& $g 'CFCPhaseReverseEnabled')) |"
        Add-Md "| CESSB | $(OnOff (& $g 'CESSB_On')) |"
        Add-Md "| ALC | max gain $(& $g 'ALC_MaximumGain') dB, decay $(& $g 'ALC_Decay') ms |"
        Add-Md "| DEXP | $(OnOff (& $g 'Dexp_On')), threshold $(& $g 'Dexp_Threshold') dB, attenuation $(& $g 'Dexp_Attenuate') dB, attack $(& $g 'Dexp_Attack') / release $(& $g 'Dexp_Release') ms |"
        if ($para -and $mode -eq 'parametric') {
            Add-Md ""; Add-Md ("EQ points (Hz / dB / Q): " + ((@($para.points) | ForEach-Object { "$([math]::Round([double]$_.frequency_hz)) / $($_.gain_db) / $($_.q)" }) -join ' | '))
        }
        $base = Join-Path $OutDir ("Thetis_" + (Safe $n))
        ($raw.GetEnumerator() | Where-Object { $_.Key -notin 'TXParaEQData', 'CFCParaEQData' } | ForEach-Object { "$($_.Key) = $($_.Value)" }) | Set-Content "$base.tags.txt" -Encoding UTF8
        if ($para) { $para | ConvertTo-Json -Depth 10 | Set-Content "$base.TXParaEQ.json" -Encoding UTF8 }
        if ($cfcPara) { $cfcPara | Set-Content "$base.CFCParaEQ.txt" -Encoding UTF8 }
        Write-Host "Thetis: $n ($($raw.Count) tags)" -ForegroundColor Green
    }
}

# ============================================================================ AetherSDR
Add-Md ""; Add-Md "## AetherSDR (AetherTX / AetherRX profile library)"
if (-not (Aether_Open) -or $script:Ae.Mode -ne 'library') { Add-Md ""; Add-Md "_No AetherTxProfiles.json library found._"; Write-Host "AetherSDR: library not found" -ForegroundColor Yellow }
else {
    Add-Md ""; Add-Md "Library: ``$($script:Ae.TxPath)``"
    Add-Md ""; Add-Md "Radio-side settings (RF/Tune power, mic level, PROC, TX filter) are not part of these profiles - note them from the Phone/CW and TX panels."
    $names = @($script:Ae.Tx.profiles.Keys | Where-Object { $_ -like $Match } | Sort-Object)
    if ($names.Count -eq 0) { Add-Md ""; Add-Md "_No AetherTX profile matches '$Match'. Profiles: $(@($script:Ae.Tx.profiles.Keys) -join ', ')_" }
    foreach ($n in $names) {
        $p = $script:Ae.Tx.profiles[$n]
        Add-Md ""; Add-Md "### $n"
        Add-Md ""
        Add-Md "| Stage | Setting |"; Add-Md "|---|---|"
        if ($p.chain) { Add-Md "| Chain | $(@($p.chain) -join ' > ') |" }
        if ($p.gate) { $x = $p.gate; Add-Md "| Gate | $(OnOff $x.enabled), $($x.mode), threshold $($x.thresholdDb) dB, ratio $($x.ratio), floor $($x.floorDb) dB, hold $($x.holdMs) / release $($x.releaseMs) ms |" }
        if ($p.deess) { $x = $p.deess; Add-Md "| De-esser | $(OnOff $x.enabled), $($x.frequencyHz) Hz, Q $($x.q), threshold $($x.thresholdDb) dB, amount $($x.amountDb) dB, attack $($x.attackMs) / release $($x.releaseMs) ms |" }
        if ($p.eq) {
            $x = $p.eq; $na = [int](ConvertTo-Num $x.activeBandCount 0)
            Add-Md "| EQ | $(OnOff $x.enabled), gain $(Db $x.masterGain), $na active bands, $($x.filterFamily) |"
            $bl = @(for ($i = 0; $i -lt [math]::Min($na, @($x.bands).Count); $i++) { $b = $x.bands[$i]; if ($b.enabled) { "$($b.type) $([math]::Round([double]$b.freqHz)) Hz $(if ($b.type -match 'Pass') { "$($b.slopeDbPerOct) dB/oct" } else { "$($b.gainDb) dB Q $($b.q)" })" } })
            Add-Md "| EQ bands | $($bl -join '; ') |"
        }
        if ($p.comp) { $x = $p.comp; Add-Md "| Compressor | $(OnOff $x.enabled), threshold $($x.thresholdDb) dB, ratio $([math]::Round([double]$x.ratio,2)), attack $([math]::Round([double]$x.attackMs,1)) / release $($x.releaseMs) ms, knee $($x.kneeDb) dB, makeup $($x.makeupDb) dB, drive $($x.driveDb) dB, phase rotator $($x.phaseRotatorStages) stages, limiter $(OnOff $x.limiterEnabled) @ $($x.limiterCeilingDb) dB |" }
        if ($p.tube) { $x = $p.tube; Add-Md "| Tube | $(OnOff $x.enabled), model $($x.model), drive $($x.driveDb) dB, dry/wet $($x.dryWet), output $($x.outputGainDb) dB |" }
        if ($p.pudu) { $x = $p.pudu; Add-Md "| Exciter | $(OnOff $x.enabled), $($x.mode); Body (poo) drive $($x.pooDriveDb) dB / $($x.pooTuneHz) Hz / mix $($x.pooMix); Clarity (doo) $($x.dooHarmonicsDb) dB / $($x.dooTuneHz) Hz / mix $($x.dooMix) |" }
        if ($p.reverb) { $x = $p.reverb; Add-Md "| Reverb | $(OnOff $x.enabled), size $($x.size), decay $($x.decayS) s, mix $($x.mix) |" }
        if ($p.finalLimiter) { $x = $p.finalLimiter; Add-Md "| Final output | limiter $(OnOff $x.enabled) @ $($x.ceilingDb) dB, trim $($x.outputTrimDb) dB, DC block $(OnOff $x.dcBlock) |" }
        if ($p.createdBy) { Add-Md "| Last written by | $($p.createdBy) $($p.createdAt) |" }
        $base = Join-Path $OutDir ("Aether_" + (Safe $n))
        $p | ConvertTo-Json -Depth 20 | Set-Content "$base.AetherTX.json" -Encoding UTF8
        if ($script:Ae.Rx.profiles.Contains($n)) {
            $r = $script:Ae.Rx.profiles[$n]
            if ($r.eq) { Add-Md "| RX EQ (same name) | $(OnOff $r.eq.enabled), gain $(Db $r.eq.masterGain) |" }
            $r | ConvertTo-Json -Depth 20 | Set-Content "$base.AetherRX.json" -Encoding UTF8
        }
        Write-Host "AetherSDR: $n" -ForegroundColor Green
    }
}

$mdPath = Join-Path $OutDir 'Reference.md'
$md | Set-Content $mdPath -Encoding UTF8
Write-Host ""; Write-Host "Reference written to $OutDir" -ForegroundColor Cyan
Write-Host "  $mdPath" -ForegroundColor Cyan
