# lib/ThetisFamily.ps1 - one mapping table for Thetis and NereusSDR
# NereusSDR is a port of Thetis and keeps Thetis's TXProfile column names for
# almost every per-profile key (MicProfileManager.cpp liveKeyList(), 2026.10.x).
# The exceptions are the DEXP keys, which NereusSDR renamed, and two Thetis
# columns NereusSDR does not keep per profile (CompanderOn - "cpdrOn is global
# console state"; VOX_On).
#
#   p = canonical path, t = Thetis TXProfile tag, n = NereusSDR per-profile key
#   (null = not stored per-profile in NereusSDR), k = num|bool
#
# Deliberately NOT mapped:
#   TX_AF_Level <-> MonitorVolume  (different units; was a known mismatch)
#   VOX_On -> VOX_GainScalar       (old Sync script did this; VOX_GainScalar is
#                                   a gain scalar, default 1 - writing a bool
#                                   into it was a bug)
#   Pure_Signal_Enabled            (radio-level, not a TX audio profile field)

$script:TfMap = @(
    @{ p = 'filter.lowHz';        t = 'FilterLow';              n = 'FilterLow';              k = 'num' }
    @{ p = 'filter.highHz';       t = 'FilterHigh';             n = 'FilterHigh';             k = 'num' }
    @{ p = 'mic.gainDb';          t = 'MicGain';                n = 'MicGain';                k = 'num' }
    @{ p = 'mic.boost';           t = 'Mic_Input_Boost';        n = 'Mic_Input_Boost';        k = 'bool' }
    @{ p = 'mic.lineInOn';        t = 'Line_Input_On';          n = 'Line_Input_On';          k = 'bool' }
    @{ p = 'mic.lineInLevel';     t = 'Line_Input_Level';       n = 'Line_Input_Level';       k = 'num' }
    @{ p = 'leveler.enabled';     t = 'Lev_On';                 n = 'Lev_On';                 k = 'bool' }
    @{ p = 'leveler.maxGainDb';   t = 'Lev_MaxGain';            n = 'Lev_MaxGain';            k = 'num' }
    @{ p = 'leveler.decayMs';     t = 'Lev_Decay';              n = 'Lev_Decay';              k = 'num' }
    @{ p = 'alc.maxGainDb';       t = 'ALC_MaximumGain';        n = 'ALC_MaximumGain';        k = 'num' }
    @{ p = 'alc.decayMs';         t = 'ALC_Decay';              n = 'ALC_Decay';              k = 'num' }
    @{ p = 'compander.enabled';   t = 'CompanderOn';            n = $null;                    k = 'bool' }
    @{ p = 'compander.level';     t = 'CompanderLevel';         n = 'CompanderLevel';         k = 'num' }
    @{ p = 'cessb.enabled';       t = 'CESSB_On';               n = 'CESSB_On';               k = 'bool' }
    @{ p = 'am.carrierLevel';     t = 'AM_Carrier_Level';       n = 'AM_Carrier_Level';       k = 'num' }
    @{ p = 'dexp.enabled';        t = 'Dexp_On';                n = 'DEXP_Enabled';           k = 'bool' }
    @{ p = 'dexp.thresholdDb';    t = 'Dexp_Threshold';         n = 'Dexp_Threshold';         k = 'num' }
    @{ p = 'dexp.expansionDb';    t = 'Dexp_Attenuate';         n = 'DEXP_ExpansionRatioDb';  k = 'num' }
    @{ p = 'dexp.hysteresisDb';   t = 'Dexp_Hysterisis';        n = 'DEXP_HysteresisRatioDb'; k = 'num' }
    @{ p = 'dexp.tauMs';          t = 'Dexp_Tau';               n = 'DEXP_DetectorTauMs';     k = 'num' }
    @{ p = 'dexp.attackMs';       t = 'Dexp_Attack';            n = 'DEXP_AttackTimeMs';      k = 'num' }
    @{ p = 'dexp.releaseMs';      t = 'Dexp_Release';           n = 'DEXP_ReleaseTimeMs';     k = 'num' }
    @{ p = 'dexp.lookAheadOn';    t = 'Dexp_LookAhead_On';      n = 'DEXP_LookAheadEnabled';  k = 'bool' }
    @{ p = 'dexp.lookAheadMs';    t = 'Dexp_LookAhead';         n = 'DEXP_LookAheadMs';       k = 'num' }
    @{ p = 'dexp.scfOn';          t = 'Dexp_SCF_On';            n = 'DEXP_SideChannelFilterEnabled'; k = 'bool' }
    @{ p = 'dexp.scfLowHz';       t = 'Dexp_SCF_Low';           n = 'DEXP_LowCutHz';          k = 'num' }
    @{ p = 'dexp.scfHighHz';      t = 'Dexp_SCF_High';          n = 'DEXP_HighCutHz';         k = 'num' }
    @{ p = 'vox.enabled';         t = 'VOX_On';                 n = $null;                    k = 'bool' }
    @{ p = 'vox.hangMs';          t = 'VOX_HangTime';           n = 'VOX_HangTime';           k = 'num' }
    @{ p = 'txEq.enabled';        t = 'TXEQEnabled';            n = 'TXEQEnabled';            k = 'bool' }
    @{ p = 'txEq.preampDb';       t = 'TXEQPreamp';             n = 'TXEQPreamp';             k = 'num' }
    @{ p = 'cfc.enabled';         t = 'CFCEnabled';             n = 'CFCEnabled';             k = 'bool' }
    @{ p = 'cfc.postEqEnabled';   t = 'CFCPostEqEnabled';       n = 'CFCPostEqEnabled';       k = 'bool' }
    @{ p = 'cfc.preCompDb';       t = 'CFCPreComp';             n = 'CFCPreComp';             k = 'num' }
    @{ p = 'cfc.postEqGainDb';    t = 'CFCPostEqGain';          n = 'CFCPostEqGain';          k = 'num' }
    @{ p = 'phaseRotator.enabled'; t = 'CFCPhaseRotatorEnabled'; n = 'CFCPhaseRotatorEnabled'; k = 'bool' }
    @{ p = 'phaseRotator.reverse'; t = 'CFCPhaseReverseEnabled'; n = 'CFCPhaseReverseEnabled'; k = 'bool' }
    @{ p = 'phaseRotator.cornerHz'; t = 'CFCPhaseRotatorFreq';  n = 'CFCPhaseRotatorFreq';    k = 'num' }
    @{ p = 'phaseRotator.stages'; t = 'CFCPhaseRotatorStages';  n = 'CFCPhaseRotatorStages';  k = 'num' }
)

# Phone DSP buffer/filter settings. Read from the Thetis TXProfile; in NereusSDR
# they are root-level (global) keys, not per profile.
$script:TfDspMap = @(
    @{ p = 'dsp.phoneRxBuffer';     t = 'Phone_RX_DSP_Buffer';      n = 'DspOptionsBufferSizePhoneRx' }
    @{ p = 'dsp.phoneTxBuffer';     t = 'Phone_TX_DSP_Buffer';      n = 'DspOptionsBufferSizePhoneTx' }
    @{ p = 'dsp.phoneRxFilterSize'; t = 'Phone_RX_DSP_Filter_Size'; n = 'DspOptionsFilterSizePhoneRx' }
    @{ p = 'dsp.phoneTxFilterSize'; t = 'Phone_TX_DSP_Filter_Size'; n = 'DspOptionsFilterSizePhoneTx' }
    @{ p = 'dsp.phoneRxFilterType'; t = 'Phone_RX_DSP_Filter_Type'; n = 'DspOptionsFilterTypePhoneRx' }
    @{ p = 'dsp.phoneTxFilterType'; t = 'Phone_TX_DSP_Filter_Type'; n = 'DspOptionsFilterTypePhoneTx' }
)

# --- Read: tag getter scriptblock -> canonical --------------------------------
# $get = { param($tag) -> string or $null }   $nameCol = 't' (Thetis) or 'n' (Nereus)
function Read-TfCanon {
    param($canon, [scriptblock]$get, [string]$nameCol)
    foreach ($m in $script:TfMap) {
        $tag = $m[$nameCol]; if (-not $tag) { continue }
        $raw = & $get $tag
        if ($null -eq $raw) { continue }
        $val = if ($m.k -eq 'bool') { ConvertTo-BoolVal $raw } else { ConvertTo-Num $raw }
        if ($null -ne $val) { Set-HtPath $canon $m.p $val }
    }
    foreach ($m in $script:TfDspMap) {
        if ($nameCol -ne 't') { break }
        $raw = & $get $m.t
        if ($null -ne $raw) { $canon.dsp[$m.p.Split('.')[1]] = $raw }
    }

    # --- TX EQ: legacy 10-band + optional parametric blob ---
    $legacy = @()
    for ($i = 1; $i -le 10; $i++) {
        $g = ConvertTo-Num (& $get "TXEQ$i"); $f = ConvertTo-Num (& $get "TxEqFreq$i")
        if ($null -ne $g -and $null -ne $f) { $legacy += [ordered]@{ freqHz = $f; gainDb = $g } }
    }
    if ($legacy.Count -eq 10) { $canon.txEq.legacy = $legacy }
    $blobText = ConvertFrom-SdrBlob (& $get 'TXParaEQData')
    if ($blobText) { $canon.txEq.curve = ConvertFrom-CurveJson $blobText }
    $useLegacy = ConvertTo-BoolVal (& $get 'EQUseLegacy') $true
    if (-not $useLegacy -and $canon.txEq.curve) { $canon.txEq.mode = 'parametric' }
    elseif ($canon.txEq.legacy) { $canon.txEq.mode = 'legacy' }
    elseif ($canon.txEq.curve) { $canon.txEq.mode = 'parametric' }
    if (-not $useLegacy -and -not $canon.txEq.curve) { Add-Note $canon "EQUseLegacy=False but TXParaEQData is empty/undecodable - using the legacy 10-band EQ instead." }

    # --- CFC: legacy 10-band arrays + optional 18-band blob (comp<SEP>post) ---
    $cl = @()
    for ($i = 0; $i -le 9; $i++) {
        $f = ConvertTo-Num (& $get "CFCEqFreq$i"); $c = ConvertTo-Num (& $get "CFCPreComp$i"); $p = ConvertTo-Num (& $get "CFCPostEqGain$i")
        if ($null -ne $f) { $cl += [ordered]@{ freqHz = $f; compDb = (ConvertTo-Num $c 0.0); postDb = (ConvertTo-Num $p 0.0) } }
    }
    if ($cl.Count -eq 10) { $canon.cfc.legacy = $cl }
    $cfcText = ConvertFrom-SdrBlob (& $get 'CFCParaEQData')
    if ($cfcText) {
        $parts = $cfcText -split '<SEP>'
        if ($parts.Count -eq 2) {
            $canon.cfc.compCurve = ConvertFrom-CurveJson $parts[0]
            $canon.cfc.postCurve = ConvertFrom-CurveJson $parts[1]
        } else { Add-Note $canon "CFCParaEQData did not split into 2 curves (got $($parts.Count)) - ignored." }
    }
    # NereusSDR has no CFCUseLegacy key: there the legacy scalars stay authoritative.
    $cfcLegacyRaw = & $get 'CFCUseLegacy'
    $cfcUseLegacy = ConvertTo-BoolVal $cfcLegacyRaw $true
    if ($null -eq $cfcLegacyRaw -and $nameCol -eq 'n' -and $canon.cfc.compCurve -and -not (Test-CurveFlat $canon.cfc.postCurve)) { Add-Note $canon "NereusSDR has no CFCUseLegacy flag - its (active) 10-band CFC scalars are treated as authoritative; the stored 18-band CFC curve is carried along but not active." 'DarkGray' }
    if (-not $cfcUseLegacy -and $canon.cfc.compCurve -and $canon.cfc.postCurve) { $canon.cfc.mode = 'parametric' }
    elseif ($canon.cfc.legacy) { $canon.cfc.mode = 'legacy' }
    elseif ($canon.cfc.compCurve -and $canon.cfc.postCurve) { $canon.cfc.mode = 'parametric' }
    if ($canon.cfc.mode -eq 'parametric') {
        # 18-band engine: PRE-COMP / PRE-PEQ live in each curve's global_gain_db
        $canon.cfc.preCompDb = $canon.cfc.compCurve.globalGainDb
        $canon.cfc.prePeqDb  = $canon.cfc.postCurve.globalGainDb
    } else { $canon.cfc.prePeqDb = 0.0 }
}

# --- Write: canonical -> ordered list of @{Key; Value} for a Thetis-family dest
# Only non-null canonical values are emitted. $nameCol = 't' or 'n'.
function Get-TfWrites {
    param($canon, [string]$nameCol, $rules, [string]$app)
    $w = New-Object System.Collections.ArrayList
    foreach ($m in $script:TfMap) {
        $tag = $m[$nameCol]; $v = Get-HtPath $canon $m.p
        if (-not $tag) { if ($v -eq $true -and $m.p -in @('compander.enabled', 'vox.enabled')) { Add-Note $canon "$($m.p) is ON at the source but $app keeps it as global console state, not per profile - set it by hand." 'Yellow' }; continue }
        if ($null -eq $v) { continue }
        $s = if ($m.k -eq 'bool') { Format-Bool ([bool]$v) } else { Format-Num ([double]$v) }
        [void]$w.Add(@{ Key = $tag; Value = $s })
    }

    foreach ($u in @(@{ k = 'compressor'; d = 'single-band compressor' }, @{ k = 'noiseGate'; d = 'noise gate' })) {
        $s = $canon[$u.k]
        if ($s -and $s.enabled -eq $true) {
            $hint = if ($u.k -eq 'noiseGate') { ' (closest native control is DEXP - set by hand if wanted)' } else { ' (closest native controls are the Leveler / CFC / Compander)' }
            $parts = @(); if ($null -ne $s.thresholdDb) { $parts += "thr $([math]::Round([double]$s.thresholdDb, 1)) dB" }; if ($null -ne $s.ratio) { $parts += "ratio $([math]::Round([double]$s.ratio, 2))" }
            Add-Note $canon ("source $($u.d) is ON ($($parts -join ', ')) - $app has no equivalent stage, not carried over$hint.") 'Yellow'
        }
    }

    # --- TX EQ ---
    $e = $canon.txEq
    if ($e.mode) { [void]$w.Add(@{ Key = 'EQUseLegacy'; Value = (Format-Bool ($e.mode -eq 'legacy')) }) }
    $legacy = $e.legacy
    if (-not $legacy -and $e.curve) {
        # Parametric-only source (Zeus/Aether/rules): also fill the 10 legacy
        # sliders by sampling the curve at Thetis's default legacy freqs, so the
        # profile is sane if someone flips Legacy EQ back on.
        $lf = @(32.0, 63.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0)
        $g = Resample-Curve $e.curve.points $lf 'pchip'
        $legacy = for ($i = 0; $i -lt 10; $i++) { @{ freqHz = $lf[$i]; gainDb = [math]::Round((Clamp $g[$i] -12 15), 1) } }
    }
    if ($legacy) {
        for ($i = 1; $i -le 10; $i++) {
            [void]$w.Add(@{ Key = "TXEQ$i"; Value = (Format-Num $legacy[$i - 1].gainDb) })
            [void]$w.Add(@{ Key = "TxEqFreq$i"; Value = (Format-Num $legacy[$i - 1].freqHz) })
        }
    }
    if ($e.curve) {
        $json = ConvertTo-CurveJson $e.curve
        if ($json) { [void]$w.Add(@{ Key = 'TXParaEQData'; Value = (ConvertTo-SdrBlob $json); IsBlob = $true }) }
    }

    # --- CFC ---
    $c = $canon.cfc
    $zeroPost = ($app -eq 'Nereus') -and ($c.postEqEnabled -eq $false) -and [bool](Get-SdrOption $rules 'Nereus' 'zeroPostEqWhenDisabled' $false)
    if ($nameCol -eq 't' -and $c.mode) { [void]$w.Add(@{ Key = 'CFCUseLegacy'; Value = (Format-Bool ($c.mode -eq 'legacy')) }) }
    $cl = $c.legacy
    $sampleCurves = ($c.compCurve -and $c.postCurve) -and ((-not $cl) -or ($nameCol -eq 'n' -and $c.mode -eq 'parametric'))
    if ($sampleCurves) {
        # Either the source only has curves (Zeus/Aether), or the dest is NereusSDR,
        # which RUNS the legacy 10-band CFC scalars and only stores CFCParaEQData.
        # A Thetis profile on the 18-band CFC would otherwise hand NereusSDR its
        # stale, inactive legacy arrays. Sample the live curves at the legacy freqs.
        $cf = if ($cl) { @($cl | ForEach-Object { [double]$_.freqHz }) } else { @(0.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 3000.0, 4000.0, 5000.0, 10000.0) }
        if ($nameCol -eq 'n' -and $c.mode -eq 'parametric') { Add-Note $canon "18-band CFC sampled onto NereusSDR's 10 active CFC bands (NereusSDR stores but does not run CFCParaEQData)." 'DarkGray' }
        $cg = Resample-Curve $c.compCurve.points $cf 'pchip'; $pg = Resample-Curve $c.postCurve.points $cf 'pchip'
        $cl = for ($i = 0; $i -lt 10; $i++) { @{ freqHz = $cf[$i]; compDb = [math]::Round([math]::Max(0, $cg[$i]), 1); postDb = [math]::Round($pg[$i], 1) } }
    }
    if ($cl) {
        for ($i = 0; $i -le 9; $i++) {
            $post = if ($zeroPost) { 0.0 } else { $cl[$i].postDb }
            [void]$w.Add(@{ Key = "CFCEqFreq$i"; Value = (Format-Num $cl[$i].freqHz) })
            [void]$w.Add(@{ Key = "CFCPreComp$i"; Value = (Format-Num $cl[$i].compDb) })
            [void]$w.Add(@{ Key = "CFCPostEqGain$i"; Value = (Format-Num $post) })
        }
    }
    if ($c.compCurve -and $c.postCurve) {
        $pc = Copy-Deep $c.postCurve
        if ($zeroPost) { foreach ($p in $pc.points) { $p.gainDb = 0.0 } }
        if ($null -ne $c.prePeqDb -and $c.mode -eq 'parametric') { $pc.globalGainDb = $c.prePeqDb }
        $cc = Copy-Deep $c.compCurve
        if ($null -ne $c.preCompDb -and $c.mode -eq 'parametric') { $cc.globalGainDb = $c.preCompDb }
        $j1 = ConvertTo-CurveJson $cc; $j2 = ConvertTo-CurveJson $pc
        if ($j1 -and $j2) { [void]$w.Add(@{ Key = 'CFCParaEQData'; Value = (ConvertTo-SdrBlob ($j1 + '<SEP>' + $j2)); IsBlob = $true }) }
    }
    if ($zeroPost) { Add-Note $canon "Post-CFC EQ disabled at source: post-EQ gains zeroed (Nereus.zeroPostEqWhenDisabled)." 'DarkGray' }
    return , $w
}
