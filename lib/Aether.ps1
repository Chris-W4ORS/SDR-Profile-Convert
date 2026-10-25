# lib/Aether.ps1 - AetherSDR adapter
#
# v26.9.4+ (AetherTX/AetherRX windows):  <configDir>\AetherTxProfiles.json and
#   AetherRxProfiles.json, each { version:1, profiles:{ "<name>":{...} } }.
#   Export/import files are one profile at top level plus name, kind
#   ("AetherTX profile"/"AetherRX profile") and version.  ChannelStripPreset v1
#   is RETIRED - AetherSDR splits old presets into TX/RX halves on first open.
# <= v26.9.3: ChannelStrip.settings { presets:{ name:{ ...tx..., rx:{...} } } },
#   import files are "AetherSDR ChannelStripPreset v1" (old converter output).
#
# configDir = QStandardPaths GenericConfigLocation + \AetherSDR; for the MSIX
# install that is ...\Packages\AetherSDR.*\LocalCache\Local\AetherSDR.
#
# TX stage fields (ChannelStripPresets.cpp captureTxJson, current main):
#   gate : enabled mode thresholdDb ratio releaseMs holdMs floorDb returnDb lookaheadMs   (NO attackMs)
#   comp : enabled thresholdDb ratio attackMs releaseMs kneeDb makeupDb limiterEnabled
#          limiterCeilingDb driveDb(0..18) phaseRotatorStages(0..6)
#   eq   : enabled masterGain(linear) filterFamily activeBandCount bands[{freqHz gainDb q type enabled slopeDbPerOct}]

$script:Ae = $null

$script:AeTxTemplate = @'
{"chain":["Gate","Eq","DeEss","Comp","Tube","Enh","Reverb"],
 "comp":{"attackMs":20,"enabled":false,"kneeDb":6,"limiterCeilingDb":-1,"limiterEnabled":true,"makeupDb":0,"ratio":3,"releaseMs":200,"thresholdDb":-18,"driveDb":0,"phaseRotatorStages":0},
 "deess":{"amountDb":-6,"attackMs":1,"enabled":false,"frequencyHz":6000,"q":2,"releaseMs":100,"thresholdDb":-30},
 "eq":{"activeBandCount":10,"enabled":true,"filterFamily":"Butterworth","masterGain":1,"bands":[
  {"enabled":true,"freqHz":63,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},{"enabled":true,"freqHz":125,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},
  {"enabled":true,"freqHz":250,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},{"enabled":true,"freqHz":500,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},
  {"enabled":true,"freqHz":1000,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},{"enabled":true,"freqHz":2000,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},
  {"enabled":true,"freqHz":4000,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},{"enabled":true,"freqHz":8000,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},
  {"enabled":false,"freqHz":8000,"gainDb":0,"q":0.707,"slopeDbPerOct":12,"type":"HighShelf"},{"enabled":false,"freqHz":12000,"gainDb":0,"q":0.707,"slopeDbPerOct":12,"type":"LowPass"}]},
 "finalLimiter":{"ceilingDb":-1,"dcBlock":true,"enabled":false,"outputTrimDb":0},
 "gate":{"enabled":true,"floorDb":-15,"holdMs":20,"lookaheadMs":0,"mode":"Expander","ratio":2,"releaseMs":100,"returnDb":2,"thresholdDb":-40},
 "pudu":{"dooHarmonicsDb":6,"dooMix":0.3,"dooTuneHz":5000,"enabled":false,"mode":"Aphex","pooDriveDb":6,"pooMix":0.3,"pooTuneHz":100},
 "reverb":{"damping":0.5,"decayS":1.2,"enabled":false,"mix":0.15,"preDelayMs":20,"size":0.5},
 "rn2":false,
 "tube":{"attackMs":5,"biasAmount":0,"driveDb":0,"dryWet":1,"enabled":false,"envelopeAmount":0,"model":"A","outputGainDb":0,"releaseMs":35,"tone":0}}
'@
$script:AeRxTemplate = @'
{"chain":["Gate","Eq","Comp","DeEss","Tube","Pudu"],
 "comp":{"attackMs":20,"enabled":false,"kneeDb":6,"limiterCeilingDb":-1,"limiterEnabled":true,"makeupDb":0,"ratio":3,"releaseMs":200,"thresholdDb":-18},
 "eq":{"activeBandCount":10,"enabled":true,"filterFamily":"Butterworth","masterGain":1,"bands":[
  {"enabled":true,"freqHz":63,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},{"enabled":true,"freqHz":125,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},
  {"enabled":true,"freqHz":250,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},{"enabled":true,"freqHz":500,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},
  {"enabled":true,"freqHz":1000,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},{"enabled":true,"freqHz":2000,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},
  {"enabled":true,"freqHz":4000,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},{"enabled":true,"freqHz":8000,"gainDb":0,"q":1.4,"slopeDbPerOct":12,"type":"Peak"},
  {"enabled":false,"freqHz":8000,"gainDb":0,"q":0.707,"slopeDbPerOct":12,"type":"HighShelf"},{"enabled":false,"freqHz":12000,"gainDb":0,"q":0.707,"slopeDbPerOct":12,"type":"LowPass"}]},
 "gate":{"enabled":false,"floorDb":-15,"holdMs":20,"lookaheadMs":0,"mode":"Expander","ratio":2,"releaseMs":100,"returnDb":2,"thresholdDb":-40},
 "pudu":{"dooHarmonicsDb":6,"dooMix":0.3,"dooTuneHz":5000,"enabled":false,"mode":"Aphex","pooDriveDb":6,"pooMix":0.3,"pooTuneHz":100},
 "rn2":false,
 "tube":{"attackMs":5,"biasAmount":0,"driveDb":0,"dryWet":1,"enabled":false,"envelopeAmount":0,"model":"A","outputGainDb":0,"releaseMs":35,"tone":0}}
'@

function Aether_Open {
    if ($script:Ae) { return $true }
    $cands = @()
    $cands += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'AetherSDR*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'LocalCache\Local\AetherSDR' })
    $cands += (Join-Path $env:LOCALAPPDATA 'AetherSDR'), (Join-Path $env:APPDATA 'AetherSDR')
    $dirs = @($cands | Where-Object { (Test-Path (Join-Path $_ 'AetherTxProfiles.json')) -or (Test-Path (Join-Path $_ 'ChannelStrip.settings')) -or (Test-Path (Join-Path $_ 'AetherSDR.db')) } | Select-Object -Unique)
    if ($dirs.Count -eq 0) { return $false }
    $dir = if ($dirs.Count -eq 1) { $dirs[0] } else { Select-Item "AetherSDR config folder:" $dirs }
    $tx = Join-Path $dir 'AetherTxProfiles.json'; $rx = Join-Path $dir 'AetherRxProfiles.json'; $cs = Join-Path $dir 'ChannelStrip.settings'
    $script:Ae = @{ Dir = $dir; TxPath = $tx; RxPath = $rx; CsPath = $cs; Dirty = @{ tx = $false; rx = $false } }
    if (Test-Path $tx) {
        $script:Ae.Mode = 'library'
        $script:Ae.Tx = Read-JsonFile $tx
        $script:Ae.Rx = if (Test-Path $rx) { Read-JsonFile $rx } else { [ordered]@{ version = 1; profiles = [ordered]@{} } }
        foreach ($lib in @($script:Ae.Tx, $script:Ae.Rx)) { if (-not $lib.Contains('profiles') -or $null -eq $lib.profiles) { $lib.profiles = [ordered]@{} } }
        if ([int](ConvertTo-Num $script:Ae.Tx.version 1) -ne 1) { Write-Log "Aether: AetherTxProfiles.json version $($script:Ae.Tx.version) (adapter knows v1) - review output; run Probe-SdrStores.ps1." Yellow }
    } elseif (Test-Path $cs) {
        $script:Ae.Mode = 'channelstrip'
        $script:Ae.Cs = Read-JsonFile $cs
        if (-not $script:Ae.Cs.Contains('presets')) { $script:Ae.Cs.presets = [ordered]@{} }
    } else { $script:Ae.Mode = 'none' }
    return $true
}

function Aether_Status {
    if (-not (Aether_Open)) { return @{ Available = $false; Reason = 'No AetherSDR config folder found' } }
    $running = Test-ProcRunning @('AetherSDR')
    $why = switch ($script:Ae.Mode) {
        'library'      { "AetherTX library, $($script:Ae.Tx.profiles.Count) TX / $($script:Ae.Rx.profiles.Count) RX profiles" }
        'channelstrip' { "pre-26.9.4 Channel Strip ($($script:Ae.Cs.presets.Count) presets) - writes import files" }
        default        { 'no profile library yet - writes import files' }
    }
    if ($running) { $why += '; AetherSDR running -> writes import files instead of editing the library' }
    return @{ Available = $true; CanWrite = $true; Reason = $why }
}

function Aether_List {
    $names = switch ($script:Ae.Mode) { 'library' { @($script:Ae.Tx.profiles.Keys) } 'channelstrip' { @($script:Ae.Cs.presets.Keys) } default { @() } }
    return @(foreach ($n in ($names | Sort-Object)) { @{ Name = $n; Active = $false } })
}

function ConvertFrom-AetherEq {
    param($eq, $canonEq, $canon, [string]$side)
    $pts = @(foreach ($b in $eq.bands) { if ($b.enabled -and $b.type -eq 'Peak') { @{ freqHz = [double]$b.freqHz; gainDb = [double]$b.gainDb; q = [double]$b.q } } })
    $other = @($eq.bands | Where-Object { $_.enabled -and $_.type -ne 'Peak' })
    if ($other.Count) { Add-Note $canon "$side EQ has $($other.Count) enabled non-Peak band(s) ($((@($other | ForEach-Object { $_.type }) | Select-Object -Unique) -join ',')) - not representable, dropped." }
    $mg = ConvertTo-Num $eq.masterGain 1.0; if ($mg -le 0) { $mg = 1.0 }
    return @{ points = $pts; enabled = [bool]$eq.enabled; gainDb = 20 * [math]::Log10($mg) }
}

function Aether_Read {
    param([string]$Name)
    $p = if ($script:Ae.Mode -eq 'library') { $script:Ae.Tx.profiles[$Name] } else { $script:Ae.Cs.presets[$Name] }
    if (-not $p) { throw "Aether profile '$Name' not found" }
    $c = New-Canon $Name 'Aether'
    if ($p.eq) {
        $e = ConvertFrom-AetherEq $p.eq $c.txEq $c 'TX'
        $c.txEq.enabled = $e.enabled; $c.txEq.preampDb = [math]::Round($e.gainDb, 2); $c.txEq.mode = 'parametric'
        $c.txEq.curve = [ordered]@{ parametric = $true; globalGainDb = 0.0; useQ = $true; points = $e.points; freqMinHz = $null; freqMaxHz = $null }
    }
    if ($p.comp) {
        foreach ($k in @('thresholdDb', 'ratio', 'attackMs', 'releaseMs', 'kneeDb', 'makeupDb')) { $c.compressor[$k] = ConvertTo-Num $p.comp[$k] }
        $c.compressor.enabled = [bool]$p.comp.enabled
        if ($p.comp.Contains('phaseRotatorStages')) { $st = ConvertTo-Num $p.comp.phaseRotatorStages 0; $c.phaseRotator.enabled = ($st -gt 0); if ($st -gt 0) { $c.phaseRotator.stages = $st } }
    }
    if ($p.gate) {
        $c.noiseGate.enabled = [bool]$p.gate.enabled
        foreach ($k in @('thresholdDb', 'holdMs', 'releaseMs')) { $c.noiseGate[$k] = ConvertTo-Num $p.gate[$k] }
        if ($p.gate.mode -and $p.gate.mode -ne 'Gate') { Add-Note $c "Aether gate is in '$($p.gate.mode)' mode (ratio $($p.gate.ratio), floor $($p.gate.floorDb) dB) - only threshold/hold/release carried." 'DarkGray' }
    }
    $rxSrc = if ($script:Ae.Mode -eq 'library') { $script:Ae.Rx.profiles[$Name] } else { $p.rx }
    if ($rxSrc -and $rxSrc.eq) { $r = ConvertFrom-AetherEq $rxSrc.eq $null $c 'RX'; $c.rxEq = [ordered]@{ enabled = $r.enabled; masterGainDb = [math]::Round($r.gainDb, 2); points = $r.points } }
    if ($p.deess -and $p.deess.enabled) { Add-Note $c 'De-esser is on in the source - no equivalent elsewhere.' 'DarkGray' }
    if ($p.tube -and $p.tube.enabled) { Add-Note $c 'Tube stage is on in the source - no equivalent elsewhere.' 'DarkGray' }
    return $c
}

function Set-AetherPeakBands {
    # Writes gains (and optionally Q) into the first 8 enabled Peak bands, evaluated at THOSE bands' freqs.
    param($eq, $points, [string]$method, [bool]$useQ)
    $idx = @(); for ($i = 0; $i -lt $eq.bands.Count -and $idx.Count -lt 8; $i++) { if ($eq.bands[$i].type -eq 'Peak') { $idx += $i } }
    if ($idx.Count -eq 0 -or @($points).Count -eq 0) { return }
    $freqs = [double[]]@($idx | ForEach-Object { [double]$eq.bands[$_].freqHz })
    $g = Resample-Curve $points $freqs $method
    $q = if ($useQ) { Resample-Curve $points $freqs 'pchip' 'q' } else { $null }
    for ($k = 0; $k -lt $idx.Count; $k++) {
        $b = $eq.bands[$idx[$k]]; $b.gainDb = [math]::Round($g[$k], 2); $b.enabled = $true
        if ($useQ) { $b.q = [math]::Round((Clamp $q[$k] 0.1 20), 3) }
    }
}

function Set-AetherBandsExact {
    # Write a short parametric curve (<= 16 points, e.g. Zeus's 10 bands) 1:1 into
    # Aether's first N EQ slots - each band keeps its own frequency, gain and Q.
    # Slots after N inside activeBandCount are switched off.
    param($eq, $points)
    $s = Get-SortedCurve $points
    $n = $s.x.Count
    $list = New-Object System.Collections.ArrayList; foreach ($b in @($eq.bands)) { [void]$list.Add($b) }
    while ($list.Count -lt $n) { [void]$list.Add((Copy-Deep $list[0])) }
    for ($i = 0; $i -lt $n; $i++) {
        $b = $list[$i]; $b.type = 'Peak'; $b.enabled = $true
        $b.freqHz = [math]::Round($s.x[$i], 1); $b.gainDb = [math]::Round($s.y[$i], 2); $b.q = [math]::Round((Clamp $s.q[$i] 0.1 20), 3)
    }
    $active = [math]::Max([int](ConvertTo-Num $eq.activeBandCount $n), $n)
    for ($i = $n; $i -lt [math]::Min($active, $list.Count); $i++) { $list[$i].enabled = $false }
    $eq.bands = $list.ToArray(); $eq.activeBandCount = $active
}

function ConvertTo-AetherTx {
    param($canon, $template, $rules)
    $p = Copy-Deep $template
    foreach ($k in @('name', 'kind', 'version', 'schema', 'rx')) { if ($p.Contains($k)) { $p.Remove($k) } }
    $src = Get-SdrOption $rules 'Aether' 'txEqSource' 'auto'
    if ($src -eq 'auto') {
        # Thetis/NereusSDR shape voice in the CFC post-EQ (validated 2026-08-11);
        # Zeus/Aether profiles carry it in their TX EQ.
        $origin = if ($canon.source.origin) { $canon.source.origin } else { $canon.source.app }
        $src = if ($origin -in @('Thetis', 'Nereus')) { 'cfcPost' } else { 'txEq' }
    }
    if ($src -eq 'cfcPost' -and (Get-CfcPoints $canon 'post').Count -gt 0) {
        $method = if ($canon.cfc.mode -eq 'parametric') { 'pchip' } else { Get-SdrOption $rules 'Aether' 'cfcLegacyMethod' 'spline' }
        Set-AetherPeakBands $p.eq (Get-CfcPoints $canon 'post') $method $false
        if ($canon.cfc.postEqEnabled -eq $false) { Add-Note $canon "Source has Post-CFC EQ DISABLED but its curve is still mapped to the Aether TX EQ (txEqSource=cfcPost)." }
        if ($canon.cfc.preCompDb) { Add-Note $canon "CFC pre-comp $($canon.cfc.preCompDb) dB / multiband compression has no Aether equivalent." 'DarkGray' }
    } else {
        if ($src -eq 'cfcPost') { Add-Note $canon "No CFC post-EQ data at source - used TX EQ instead." 'DarkGray' }
        $e = $canon.txEq; $useQ = ($e.mode -eq 'parametric' -and $e.curve -and $e.curve.useQ)
        $method = if ($e.curve -and $e.curve.interp) { $e.curve.interp } else { 'pchip' }
        $pts = @(Get-TxEqPoints $canon)
        if ($useQ -and $pts.Count -ge 2 -and $pts.Count -le 16 -and -not ($e.curve.interp)) { Set-AetherBandsExact $p.eq $pts }
        else { Set-AetherPeakBands $p.eq $pts $method $useQ }
        if ($null -ne $e.enabled) { $p.eq.enabled = [bool]$e.enabled }
        if ($null -ne $e.preampDb) { $p.eq.masterGain = [math]::Round([math]::Pow(10, $e.preampDb / 20), 4) }
    }
    if ($canon.extraEq) {
        # Cascade (sum in dB) a correction curve onto whatever was just set -
        # e.g. the retired VMP EQ-Pro-G6, now that VMP no longer shapes upstream.
        $idx = @(); for ($i = 0; $i -lt $p.eq.bands.Count -and $idx.Count -lt 8; $i++) { if ($p.eq.bands[$i].type -eq 'Peak') { $idx += $i } }
        $freqs = [double[]]@($idx | ForEach-Object { [double]$p.eq.bands[$_].freqHz })
        $add = Resample-Curve $canon.extraEq.points $freqs $canon.extraEq.method
        for ($k = 0; $k -lt $idx.Count; $k++) { $b = $p.eq.bands[$idx[$k]]; $b.gainDb = [math]::Round(([double]$b.gainDb + $add[$k]), 2); $b.enabled = $true }
        $p.eq.enabled = $true
        Write-Log "    + cascaded '$($canon.extraEq.label)' onto TX EQ: $((@($add | ForEach-Object { [math]::Round($_,1) })) -join '/') dB" DarkGray
    }
    $cp = $canon.compressor
    if ($null -ne $cp.enabled) { $p.comp.enabled = [bool]$cp.enabled }
    foreach ($k in @('thresholdDb', 'ratio', 'attackMs', 'releaseMs', 'kneeDb', 'makeupDb')) { if ($null -ne $cp[$k]) { $p.comp[$k] = [double]$cp[$k] } }
    if ($cp.enabled -and $cp.extra) {
        if ($cp.extra.Contains('auto-makeup') -and [double]$cp.extra['auto-makeup'] -ge 1) { Add-Note $canon "source compressor has Auto Makeup ON - Aether has no auto makeup; only the fixed makeup ($($cp.makeupDb) dB) is set." 'Yellow' }
        if ($cp.extra.Contains('mix-percent') -and [double]$cp.extra['mix-percent'] -lt 100) { Add-Note $canon "source compressor mix is $($cp.extra['mix-percent'])% (parallel) - Aether compressor is 100% wet." 'Yellow' }
    }
    if ($canon.cfc.enabled) { Add-Note $canon "CFC (multiband compression) is ON at the source - Aether has no CFC stage." 'Yellow' }
    if ([bool](Get-SdrOption $rules 'Aether' 'mapPhaseRotator' $true) -and $null -ne $canon.phaseRotator.enabled) {
        $st = if ($canon.phaseRotator.enabled) { [int](ConvertTo-Num $canon.phaseRotator.stages 6) } else { 0 }
        if ($st -gt 6) { Add-Note $canon "phase rotator $st stages clamped to Aether's max of 6 (comp.phaseRotatorStages); corner freq $($canon.phaseRotator.cornerHz) Hz not settable." 'DarkGray'; $st = 6 }
        $p.comp.phaseRotatorStages = $st
    }
    $g = $canon.noiseGate
    if ($null -ne $g.enabled) { $p.gate.enabled = [bool]$g.enabled }
    foreach ($k in @('thresholdDb', 'holdMs', 'releaseMs')) { if ($null -ne $g[$k]) { $p.gate[$k] = [double]$g[$k] } }
    if ($null -ne $g.attackMs -and $g.enabled) { Add-Note $canon "gate attack $($g.attackMs) ms dropped - Aether's TX gate has no attack parameter." 'DarkGray' }
    $p.createdBy = 'SdrConvert'; $p.createdAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    return $p
}

function ConvertTo-AetherRx {
    param($canon, $template)
    $p = Copy-Deep $template
    foreach ($k in @('name', 'kind', 'version', 'schema')) { if ($p.Contains($k)) { $p.Remove($k) } }
    Set-AetherPeakBands $p.eq $canon.rxEq.points 'pchip' $false
    if ($null -ne $canon.rxEq.enabled) { $p.eq.enabled = [bool]$canon.rxEq.enabled }
    if ($null -ne $canon.rxEq.masterGainDb) { $p.eq.masterGain = [math]::Round([math]::Pow(10, $canon.rxEq.masterGainDb / 20), 4) }
    $p.createdBy = 'SdrConvert'; $p.createdAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    return $p
}

function Get-AetherTemplate {
    param($lib, [string]$name, [string]$fallbackJson)
    if ($lib -and $lib.profiles) {
        if ($lib.profiles.Contains($name)) { return $lib.profiles[$name] }
        foreach ($k in $lib.profiles.Keys) { if ($lib.profiles[$k].eq) { return $lib.profiles[$k] } }
    }
    return ConvertTo-HT ($fallbackJson | ConvertFrom-Json)
}

function Aether_BeginWrite {
    param([switch]$ForceExport)
    $script:Ae.Export = $ForceExport -or ($script:Ae.Mode -ne 'library') -or (Test-ProcRunning @('AetherSDR'))
    $script:Ae.OutDir = Join-Path $env:USERPROFILE 'Documents\SdrConvert\Aether'
    if ($script:Ae.Export) {
        New-Item -ItemType Directory -Path $script:Ae.OutDir -Force | Out-Null
        Write-Log "  Aether: writing import files to $($script:Ae.OutDir)" Yellow
    } else {
        Backup-File $script:Ae.TxPath | Out-Null; Backup-File $script:Ae.RxPath | Out-Null
    }
}

function Aether_Write {
    param($canon, [string]$DestName, $rules, [switch]$Review)
    $writeRx = ($null -ne $canon.rxEq) -and [bool](Get-SdrOption $rules 'Aether' 'writeRx' $true)
    $safe = $DestName -replace '[\\/:*?"<>|]', '_'
    if ($script:Ae.Mode -eq 'channelstrip') {
        # Pre-26.9.4: one combined ChannelStripPreset v1 import file
        $tplPreset = $null; foreach ($k in $script:Ae.Cs.presets.Keys) { $tplPreset = $script:Ae.Cs.presets[$k]; break }
        $tx = ConvertTo-AetherTx $canon (if2 $tplPreset $script:AeTxTemplate) $rules
        if ($writeRx) { $tx.rx = ConvertTo-AetherRx $canon $(if ($tplPreset -and $tplPreset.rx) { $tplPreset.rx } else { ConvertTo-HT ($script:AeRxTemplate | ConvertFrom-Json) }) }
        $tx.name = $DestName; $tx.schema = 'AetherSDR ChannelStripPreset v1'
        $path = Join-Path $script:Ae.OutDir "$safe.json"
        if ($Review -and -not (Confirm-Yes "  Write $path ?")) { return @{ Changed = 0; Total = 1; New = $true } }
        Write-JsonFile $tx $path; Write-Log "    -> $path" Green
        return @{ Changed = 1; Total = 1; New = $true }
    }
    $txT = Get-AetherTemplate $script:Ae.Tx $DestName $script:AeTxTemplate
    $tx = ConvertTo-AetherTx $canon $txT $rules
    $rx = $null
    if ($writeRx) { $rx = ConvertTo-AetherRx $canon (Get-AetherTemplate $script:Ae.Rx $DestName $script:AeRxTemplate) }
    if ($Review -and -not (Confirm-Yes "  Write AetherTX$(if ($rx) {'/RX'}) profile '$DestName'?")) { return @{ Changed = 0; Total = 1; New = $false } }
    $isNew = -not ($script:Ae.Mode -eq 'library' -and $script:Ae.Tx.profiles.Contains($DestName))
    if ($script:Ae.Export) {
        $o = Copy-Deep $tx; $o.name = $DestName; $o.kind = 'AetherTX profile'; $o.version = 1
        $f = Join-Path $script:Ae.OutDir "$safe.AetherTX.json"; Write-JsonFile $o $f; Write-Log "    -> $f" Green
        if ($rx) { $o = Copy-Deep $rx; $o.name = $DestName; $o.kind = 'AetherRX profile'; $o.version = 1; $f = Join-Path $script:Ae.OutDir "$safe.AetherRX.json"; Write-JsonFile $o $f; Write-Log "    -> $f" Green }
    } else {
        $script:Ae.Tx.profiles[$DestName] = $tx; $script:Ae.Dirty.tx = $true
        if ($rx) { $script:Ae.Rx.profiles[$DestName] = $rx; $script:Ae.Dirty.rx = $true }
    }
    return @{ Changed = 1; Total = 1; New = $isNew }
}
function if2 { param($a, $json) if ($a) { return $a } else { return ConvertTo-HT ($json | ConvertFrom-Json) } }

function Aether_EndWrite {
    param([string]$ActiveName, $rules)
    if ($script:Ae.Export) {
        Write-Log "  Import in AetherSDR: AetherTX (and AetherRX) window -> Settings -> Profiles -> Import..." Cyan
    } else {
        if ($script:Ae.Dirty.tx) { $script:Ae.Tx.version = 1; Write-JsonFile $script:Ae.Tx $script:Ae.TxPath; Write-Log "  Saved $($script:Ae.TxPath)" Green }
        if ($script:Ae.Dirty.rx) { $script:Ae.Rx.version = 1; Write-JsonFile $script:Ae.Rx $script:Ae.RxPath; Write-Log "  Saved $($script:Ae.RxPath)" Green }
    }
    if ($ActiveName) { Write-Log "  (AetherSDR has no stored 'active' TX profile - load '$ActiveName' from the AetherTX window.)" DarkGray }
}
