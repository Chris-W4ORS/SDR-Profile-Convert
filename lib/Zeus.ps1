# lib/Zeus.ps1 - Zeus adapter
# Zeus has no profile file to edit: a TX Audio Profile is a SNAPSHOT of the
# live engine. Writing = push every setting live, then POST {name} to snapshot.
# Reading = POST /api/tx-audio-profiles/{id}/apply (returns the whole stored
# profile) - which also changes the live state, so the original active profile
# is re-applied when the run finishes. Don't transmit while this runs.
#
# Endpoints (Wireshark-confirmed 2026-08-16 unless marked):
#   StationEngine  POST /api/tx/cfc {config}, /api/tx/leveling {txLeveling},
#                  /api/tx/leveler-max-gain {gain}, /api/tx/phase-rotator
#                  {txPhaseRotator}, /api/mic-gain {db}, /api/tx-filter {lowHz,highHz}
#   ZeusProduct    GET/POST /api/tx-audio-profiles, DELETE .../{id},
#                  POST .../{id}/apply, PUT .../last-loaded {id},
#                  PUT /api/tx-audio-suite/processing-mode {mode},
#                  PUT /product/features/{unit} {enabled},
#                  PUT /product/features/eq/parameters {values},
#                  PUT /product/features/{compressor|noise-gate}/parameters  (INFERRED, not captured)

$script:Ze = $null
$script:ZeusCfcFreqs = [double[]]@(50, 100, 200, 500, 1000, 1500, 2000, 2500, 3000, 5000)
$script:ZeusEqFreqs  = [double[]]@(80, 150, 300, 500, 800, 1200, 1800, 2700, 4000, 6000)

function Find-ZeusPort {
    param($proc, [string]$probePath)
    foreach ($c in (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -in $proc.Id -and $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::1', '::') })) {
        try { Invoke-WebRequest "http://127.0.0.1:$($c.LocalPort)$probePath" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null; return $c.LocalPort }
        catch { if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -ne 404) { return $c.LocalPort } }
    }
    return $null
}
function Invoke-Zeus {
    param([string]$Method, [string]$Url, $Body)
    $req = @{ Uri = $Url; Method = $Method; ErrorAction = 'Stop'; TimeoutSec = 15 }
    if ($null -ne $Body) { $req.Body = ($Body | ConvertTo-Json -Depth 10 -Compress); $req.ContentType = 'application/json' }
    try { return Invoke-RestMethod @req }
    catch {
        $eb = ''; try { $eb = (New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
        if (-not $eb) { $eb = $_.ErrorDetails.Message }
        throw "$Method $Url failed: $($_.Exception.Message) $eb"
    }
}

function Zeus_Open {
    if ($script:Ze) { return $true }
    $zp = Get-Process -Name ZeusProduct -ErrorAction SilentlyContinue
    $se = Get-Process -Name StationEngine -ErrorAction SilentlyContinue
    if (-not $zp -or -not $se) { return $false }
    $pp = Find-ZeusPort $zp '/api/tx-audio-profiles'; $ep = Find-ZeusPort $se '/api/tx/cfc/presets'
    if (-not $pp -or -not $ep) { Write-Log "Zeus: could not resolve ports (prod=$pp eng=$ep). Endpoints may have moved - run Probe-SdrStores.ps1." Red; return $false }
    $script:Ze = @{ Prod = "http://127.0.0.1:$pp"; Eng = "http://127.0.0.1:$ep"; Ids = @{}; LiveTouched = $false; RestoreId = $null; Written = @{} }
    $list = Invoke-Zeus Get "$($script:Ze.Prod)/api/tx-audio-profiles"
    if ($null -eq $list.profiles) { Write-Log "Zeus: /api/tx-audio-profiles has no 'profiles' array - API changed. Run Probe-SdrStores.ps1." Red; $script:Ze = $null; return $false }
    foreach ($p in $list.profiles) { $script:Ze.Ids[$p.name] = $p.id }
    foreach ($k in @('lastLoadedId', 'lastLoaded', 'activeId', 'active')) {
        $v = $list.$k; if ($v) { $script:Ze.RestoreId = if ($v -is [string]) { $v } else { $v.id }; break }
    }
    if (-not $script:Ze.RestoreId) {
        # The list doesn't say which profile is active; ask the last-loaded bookkeeping endpoint.
        try {
            $ll = Invoke-Zeus Get "$($script:Ze.Prod)/api/tx-audio-profiles/last-loaded" $null
            foreach ($k in @('id', 'profileId', 'lastLoadedId', 'lastLoaded')) { $v = $ll.$k; if ($v) { $script:Ze.RestoreId = if ($v -is [string]) { $v } elseif ($v.id) { [string]$v.id } else { [string]$v }; break } }
            if (-not $script:Ze.RestoreId -and $ll -is [string]) { $script:Ze.RestoreId = $ll }
            if (-not $script:Ze.RestoreId -and $ll.profile.id) { $script:Ze.RestoreId = [string]$ll.profile.id }
        } catch { }
    }
    if (-not $script:Ze.RestoreId) {
        # Last resort: the operator tells us, so a read (which applies profiles live) can be undone.
        $names = @($script:Ze.Ids.Keys | Sort-Object)
        $pick = Select-Item "Zeus doesn't report its active profile. Which one is live now? (restored after reading)" $names -AllowSkip -SkipText "Don't know / don't restore"
        if ($pick) { $script:Ze.RestoreId = $script:Ze.Ids[$pick]; $script:Ze.RestoreName = $pick }
    }
    return $true
}

function Zeus_Status {
    if (-not (Zeus_Open)) { return @{ Available = $false; Reason = 'Zeus not running (needs ZeusProduct + StationEngine)' } }
    return @{ Available = $true; CanWrite = $true; Reason = "$($script:Ze.Ids.Count) profiles at $($script:Ze.Prod)" }
}
function Zeus_List { return @(foreach ($n in ($script:Ze.Ids.Keys | Sort-Object)) { @{ Name = $n; Active = ($script:Ze.Ids[$n] -eq $script:Ze.RestoreId) } }) }

function Zeus_Read {
    param([string]$Name)
    $id = $script:Ze.Ids[$Name]; if (-not $id) { throw "Zeus profile '$Name' not found" }
    Write-Log "  (applying '$Name' live to read it back)" DarkGray
    $script:Ze.LiveTouched = $true
    $resp = Invoke-Zeus Post "$($script:Ze.Prod)/api/tx-audio-profiles/$id/apply" $null
    $script:Ze.LastRaw = $resp      # full stored profile as Zeus returned it (used by backups)
    $p = $resp.profile
    if (-not $p) { throw "apply response had no 'profile' - API changed? Run Probe-SdrStores.ps1." }
    $c = New-Canon $Name 'Zeus'
    if ($p.cfcConfig) {
        $cc = $p.cfcConfig
        $c.cfc.enabled = [bool]$cc.enabled; $c.cfc.postEqEnabled = [bool]$cc.postEqEnabled
        $c.cfc.preCompDb = ConvertTo-Num $cc.preCompDb 0; $c.cfc.prePeqDb = ConvertTo-Num $cc.prePeqDb 0
        $c.cfc.legacy = @(foreach ($b in $cc.bands) { [ordered]@{ freqHz = [double]$b.freqHz; compDb = [double]$b.compLevelDb; postDb = [double]$b.postGainDb } })
        $c.cfc.compCurve = [ordered]@{ parametric = $false; globalGainDb = $c.cfc.preCompDb; points = @(foreach ($b in $cc.bands) { @{ freqHz = [double]$b.freqHz; gainDb = [double]$b.compLevelDb; q = 4.0 } }) }
        $c.cfc.postCurve = [ordered]@{ parametric = $false; globalGainDb = $c.cfc.prePeqDb; points = @(foreach ($b in $cc.bands) { @{ freqHz = [double]$b.freqHz; gainDb = [double]$b.postGainDb; q = 4.0 } }) }
        $c.cfc.mode = if ($c.cfc.legacy.Count -eq 10) { 'legacy' } else { 'parametric' }
    }
    if ($p.txLeveling) {
        $c.alc.maxGainDb = ConvertTo-Num $p.txLeveling.alcMaxGainDb; $c.alc.decayMs = ConvertTo-Num $p.txLeveling.alcDecayMs
        $c.leveler.enabled = [bool]$p.txLeveling.levelerEnabled; $c.leveler.decayMs = ConvertTo-Num $p.txLeveling.levelerDecayMs
    }
    $c.leveler.maxGainDb = ConvertTo-Num $p.levelerMaxGainDb
    if ($p.txPhaseRotator) { $r = $p.txPhaseRotator; $c.phaseRotator.enabled = [bool]$r.enabled; $c.phaseRotator.cornerHz = ConvertTo-Num $r.cornerHz; $c.phaseRotator.stages = ConvertTo-Num $r.stages; $c.phaseRotator.reverse = [bool]$r.reverse }
    $c.mic.gainDb = ConvertTo-Num $p.micGainDb; $c.filter.lowHz = ConvertTo-Num $p.lowCutHz; $c.filter.highHz = ConvertTo-Num $p.highCutHz
    if ($p.processingMode -and $p.processingMode -ne 'native') { Add-Note $c "Zeus profile uses processingMode '$($p.processingMode)' (VST chain not converted)." }
    $ns = $p.nativePluginStates
    if ($ns -and $ns.eq) {
        $e = $ns.eq
        $c.txEq.enabled = ConvertTo-BoolVal $e.requestedEnabled $false
        $c.txEq.preampDb = ConvertTo-Num $e.'param:input-gain-db' 0
        $pts = @(for ($i = 1; $i -le 10; $i++) { @{ freqHz = [double](ConvertTo-Num $e."param:band-$i-freq-hz"); gainDb = [double](ConvertTo-Num $e."param:band-$i-gain-db" 0); q = [double](ConvertTo-Num $e."param:band-$i-q" 1) } })
        $c.txEq.curve = [ordered]@{ parametric = $true; globalGainDb = 0.0; useQ = $true; points = $pts; freqMinHz = $null; freqMaxHz = $null }
        $c.txEq.legacy = @(foreach ($q in $pts) { [ordered]@{ freqHz = $q.freqHz; gainDb = $q.gainDb } })
        $c.txEq.mode = 'parametric'
    }
    foreach ($u in @(@{ k = 'compressor'; s = $ns.compressor; f = @{ thresholdDb = 'threshold-db'; ratio = 'ratio'; attackMs = 'attack-ms'; releaseMs = 'release-ms'; kneeDb = 'knee-db'; makeupDb = 'makeup-db' } },
                     @{ k = 'noiseGate'; s = $ns.'noise-gate'; f = @{ thresholdDb = 'threshold-db'; attackMs = 'attack-ms'; holdMs = 'hold-ms'; releaseMs = 'release-ms'; rangeDb = 'range-db'; outputDb = 'output-db' } })) {
        if (-not $u.s) { continue }
        $c[$u.k].enabled = ConvertTo-BoolVal $u.s.requestedEnabled $false
        foreach ($fk in $u.f.Keys) { $c[$u.k][$fk] = ConvertTo-Num $u.s."param:$($u.f[$fk])" }
        # keep Zeus-only parameters so Zeus->Zeus copies are exact
        $mapped = @($u.f.Values); $extra = [ordered]@{}
        foreach ($pp in $u.s.PSObject.Properties) { if ($pp.Name -like 'param:*') { $id = $pp.Name.Substring(6); if ($mapped -notcontains $id) { $n = ConvertTo-Num $pp.Value; if ($null -ne $n) { $extra[$id] = $n } } } }
        if ($extra.Count) { $c[$u.k]['extra'] = $extra }
    }
    return $c
}

function ConvertTo-ZeusLive {
    param($canon, $rules)
    $legacyMethod = Get-SdrOption $rules 'Zeus' 'cfcLegacyMethod' 'spline'
    $cm = if ($canon.cfc.mode -eq 'parametric') { 'pchip' } else { $legacyMethod }
    $comp = Resample-Curve (Get-CfcPoints $canon 'comp') $script:ZeusCfcFreqs $cm
    $post = Resample-Curve (Get-CfcPoints $canon 'post') $script:ZeusCfcFreqs $cm
    $bands = @(for ($i = 0; $i -lt 10; $i++) { [ordered]@{ freqHz = [int]$script:ZeusCfcFreqs[$i]; compLevelDb = [math]::Max(0, [math]::Round($comp[$i], 2)); postGainDb = [math]::Round($post[$i], 2) } })

    # TX EQ: 10 points -> 1:1 (keeps the source's own band freqs); otherwise
    # PCHIP onto Zeus's default 10 band freqs. Q only carried when the curve
    # says it is meaningful (useQ: Zeus/Aether sources, VMP baseline rule).
    $e = $canon.txEq; $eqBands = $null
    $useQ = ($e.mode -eq 'parametric' -and $e.curve -and $e.curve.useQ)
    $pts = Get-TxEqPoints $canon
    if ($pts.Count -eq 10 -and -not ($e.curve -and $e.curve.interp)) {
        $s = Get-SortedCurve $pts
        if ($s.x.Count -eq 10) { $eqBands = @(for ($i = 0; $i -lt 10; $i++) { [ordered]@{ freqHz = [int]$s.x[$i]; gainDb = [math]::Round($s.y[$i], 2); q = $(if ($useQ) { [math]::Round($s.q[$i], 2) } else { 1.0 }) } }) }
    }
    if (-not $eqBands) {
        $method = if ($e.curve -and $e.curve.interp) { $e.curve.interp } else { 'pchip' }
        $g = Resample-Curve $pts $script:ZeusEqFreqs $method
        $q = if ($useQ) { Resample-Curve $pts $script:ZeusEqFreqs $method 'q' } else { $null }
        $eqBands = @(for ($i = 0; $i -lt 10; $i++) { [ordered]@{ freqHz = [int]$script:ZeusEqFreqs[$i]; gainDb = [math]::Round($g[$i], 2); q = $(if ($useQ) { [math]::Round($q[$i], 2) } else { 1.0 }) } })
    }
    $nz = { param($v, $d) if ($null -eq $v) { $d } else { $v } }
    return [ordered]@{
        cfc            = [ordered]@{ enabled = [bool](& $nz $canon.cfc.enabled $false); postEqEnabled = [bool](& $nz $canon.cfc.postEqEnabled $false); preCompDb = [int](& $nz $canon.cfc.preCompDb 0); prePeqDb = [int](& $nz $canon.cfc.prePeqDb 0); bands = $bands }
        leveling       = [ordered]@{ alcMaxGainDb = [int](& $nz $canon.alc.maxGainDb 3); alcDecayMs = [int](& $nz $canon.alc.decayMs 10); levelerEnabled = [bool](& $nz $canon.leveler.enabled $false); levelerDecayMs = [int](& $nz $canon.leveler.decayMs 100); compressorEnabled = $false; compressorGainDb = 0 }
        levelerMaxGain = [double](& $nz $canon.leveler.maxGainDb 10)
        phaseRotator   = [ordered]@{ enabled = [bool](& $nz $canon.phaseRotator.enabled $false); cornerHz = [int](& $nz $canon.phaseRotator.cornerHz 338); stages = [int](& $nz $canon.phaseRotator.stages 8); reverse = [bool](& $nz $canon.phaseRotator.reverse $false); autoMode = $false }
        micGain        = [double](& $nz $canon.mic.gainDb 0)
        filterLow      = [int](& $nz $canon.filter.lowHz 100); filterHigh = [int](& $nz $canon.filter.highHz 3000)
        eq             = [ordered]@{ enabled = [bool](& $nz $e.enabled $false); preampDb = [double](& $nz $e.preampDb 0); bands = $eqBands }
        compressor     = $canon.compressor
        noiseGate      = $canon.noiseGate
    }
}

# Each unit's GET /product/features/<unit>/parameters returns its full parameter
# list with id/min/max/step/default/value (confirmed 2026-10-24 for compressor
# and noise-gate). Used to clamp what we send, flag ids that no longer exist,
# reset parameters the converter doesn't map (so snapshots stop inheriting
# leftover live state - e.g. compressor auto-makeup, gate mode/ratio/range),
# and read back what Zeus actually stored.
function Get-ZeusSpec {
    param([string]$Unit)
    if (-not $script:Ze.Spec) { $script:Ze.Spec = @{} }
    if (-not $script:Ze.Spec.ContainsKey($Unit)) {
        $h = $null
        try { $r = Invoke-Zeus Get "$($script:Ze.Prod)/product/features/$Unit/parameters" $null; $h = [ordered]@{}; foreach ($p in $r.parameters) { $h[$p.id] = $p } } catch { }
        $script:Ze.Spec[$Unit] = $h
    }
    return $script:Ze.Spec[$Unit]
}
function Push-ZeusParams {
    param([string]$Unit, $Values, [bool]$ResetUnmapped)
    $spec = Get-ZeusSpec $Unit
    $out = [ordered]@{}
    if ($spec) {
        foreach ($k in @($Values.Keys)) {
            if (-not $spec.Contains($k)) { Write-Log "    [DRIFT] Zeus '$Unit' has no parameter '$k' any more - skipped (run the probe)" Yellow; continue }
            $p = $spec[$k]; $v = [double]$Values[$k]; $c = Clamp $v ([double]$p.min) ([double]$p.max)
            if ($c -ne $v) { Write-Log "    [WARN] $Unit $k=$v outside Zeus range $($p.min)..$($p.max), clamped to $c" Yellow }
            $out[$k] = $c
        }
        if ($ResetUnmapped) { foreach ($k in $spec.Keys) { if (-not $out.Contains($k)) { $out[$k] = [double]$spec[$k].default } } }
    } else { foreach ($k in $Values.Keys) { $out[$k] = [double]$Values[$k] } }
    Invoke-Zeus Put "$($script:Ze.Prod)/product/features/$Unit/parameters" @{ values = $out } | Out-Null
    if ($spec) {
        $bad = @()
        try {
            $r = Invoke-Zeus Get "$($script:Ze.Prod)/product/features/$Unit/parameters" $null
            foreach ($p in $r.parameters) {
                if (-not $out.Contains($p.id)) { continue }
                $tol = [math]::Max(0.01, [double]$p.step / 2)
                if ([math]::Abs([double]$p.value - [double]$out[$p.id]) -gt $tol) { $bad += "$($p.id) sent $($out[$p.id]) got $($p.value)" }
            }
        } catch { $bad += "read-back failed: $($_.Exception.Message)" }
        if ($bad) { Write-Log "    [VERIFY] $Unit mismatch: $($bad -join '; ')" Red } else { Write-Log "    [OK] ${Unit}: $($out.Count) parameters written and verified" DarkGray }
    }
}

function Push-ZeusLive {
    param($live)
    $E = $script:Ze.Eng; $P = $script:Ze.Prod
    Invoke-Zeus Post "$E/api/tx/cfc" @{ config = $live.cfc } | Out-Null
    Invoke-Zeus Post "$E/api/tx/leveling" @{ txLeveling = $live.leveling } | Out-Null
    Invoke-Zeus Post "$E/api/tx/leveler-max-gain" @{ gain = $live.levelerMaxGain } | Out-Null
    Invoke-Zeus Post "$E/api/tx/phase-rotator" @{ txPhaseRotator = $live.phaseRotator } | Out-Null
    Invoke-Zeus Post "$E/api/mic-gain" @{ db = $live.micGain } | Out-Null
    Invoke-Zeus Post "$E/api/tx-filter" @{ lowHz = $live.filterLow; highHz = $live.filterHigh } | Out-Null
    $vals = [ordered]@{ 'input-gain-db' = $live.eq.preampDb }
    for ($i = 1; $i -le 10; $i++) { $b = $live.eq.bands[$i - 1]; $vals["band-$i-freq-hz"] = $b.freqHz; $vals["band-$i-gain-db"] = $b.gainDb; $vals["band-$i-q"] = $b.q }
    $resetFor = @(Get-SdrOption $script:ZeRules 'Zeus' 'resetUnmappedParams' @('compressor', 'noise-gate'))
    Push-ZeusParams 'eq' $vals ($resetFor -contains 'eq')
    Invoke-Zeus Put "$P/product/features/eq" @{ enabled = $live.eq.enabled } | Out-Null
    foreach ($u in @(@{ id = 'compressor'; s = $live.compressor; f = [ordered]@{ 'threshold-db' = 'thresholdDb'; 'ratio' = 'ratio'; 'attack-ms' = 'attackMs'; 'release-ms' = 'releaseMs'; 'knee-db' = 'kneeDb'; 'makeup-db' = 'makeupDb' } },
                     @{ id = 'noise-gate'; s = $live.noiseGate; f = [ordered]@{ 'threshold-db' = 'thresholdDb'; 'attack-ms' = 'attackMs'; 'hold-ms' = 'holdMs'; 'release-ms' = 'releaseMs'; 'range-db' = 'rangeDb'; 'output-db' = 'outputDb' } })) {
        $on = [bool]$u.s.enabled
        Invoke-Zeus Put "$P/product/features/$($u.id)" @{ enabled = $on } | Out-Null
        if ($on) {
            # Zeus-only extras first (rules file or a Zeus source), then mapped fields,
            # then - per Zeus.resetUnmappedParams - defaults for everything else
            $v = [ordered]@{}
            if ($u.s.Contains('extra') -and $u.s.extra) { foreach ($k in $u.s.extra.Keys) { $v[$k] = [double]$u.s.extra[$k] } }
            foreach ($k in $u.f.Keys) { $x = $u.s[$u.f[$k]]; if ($null -ne $x) { $v[$k] = [double]$x } }
            try { Push-ZeusParams $u.id $v ($resetFor -contains $u.id) }
            catch { Write-Log "  [WARN] $($u.id) parameters push failed: $($_.Exception.Message)" Yellow }
        }
    }
    # Thetis has no exciter/bass/reverb; force off so stale live state isn't snapshotted.
    foreach ($u in @('exciter', 'bass', 'reverb')) { Invoke-Zeus Put "$P/product/features/$u" @{ enabled = $false } | Out-Null }
    # native route LAST so nothing above can flip it back before the snapshot
    Invoke-Zeus Put "$P/api/tx-audio-suite/processing-mode" @{ mode = 'native' } | Out-Null
}

function Zeus_BeginWrite { Write-Log "  Zeus: each profile is pushed LIVE then snapshotted. Do not transmit while this runs." Yellow }

function Zeus_Write {
    param($canon, [string]$DestName, $rules, [switch]$Review)
    $script:ZeRules = $rules
    $live = ConvertTo-ZeusLive $canon $rules
    Write-Log ("    eq[{0}] pre={1}  cfc[{2}] preComp={3}  lev={4}/{5}dB  alc={6}dB  comp={7} gate={8}" -f $live.eq.enabled, $live.eq.preampDb, $live.cfc.enabled, $live.cfc.preCompDb, $live.leveling.levelerEnabled, $live.levelerMaxGain, $live.leveling.alcMaxGainDb, [bool]$live.compressor.enabled, [bool]$live.noiseGate.enabled) DarkGray
    if ($Review -and -not (Confirm-Yes "  Push + snapshot '$DestName' to Zeus?")) { return @{ Changed = 0; Total = 1; New = $false } }
    $script:Ze.LiveTouched = $true
    Push-ZeusLive $live
    $isNew = -not $script:Ze.Ids.Contains($DestName)
    if (-not $isNew) { try { Invoke-Zeus Delete "$($script:Ze.Prod)/api/tx-audio-profiles/$($script:Ze.Ids[$DestName])" $null | Out-Null } catch { Write-Log "  [WARN] delete before re-snapshot failed: $($_.Exception.Message)" Yellow } }
    $r = Invoke-Zeus Post "$($script:Ze.Prod)/api/tx-audio-profiles" @{ name = $DestName }
    $script:Ze.Ids[$DestName] = $r.id; $script:Ze.Written[$DestName] = $live
    return @{ Changed = 1; Total = 1; New = $isNew }
}

function Zeus_EndWrite {
    param([string]$ActiveName, $rules)
    if ($ActiveName -and $script:Ze.Ids.Contains($ActiveName)) {
        $id = $script:Ze.Ids[$ActiveName]
        Invoke-Zeus Post "$($script:Ze.Prod)/api/tx-audio-profiles/$id/apply" $null | Out-Null
        Invoke-Zeus Put "$($script:Ze.Prod)/api/tx-audio-profiles/last-loaded" @{ id = $id } | Out-Null
        Write-Log "  Zeus active profile -> $ActiveName (applied live + last-loaded)" Green
        $script:Ze.LiveTouched = $false
    }
}

function Zeus_Close {
    if ($script:Ze -and $script:Ze.LiveTouched) {
        if ($script:Ze.RestoreId) {
            try { Invoke-Zeus Post "$($script:Ze.Prod)/api/tx-audio-profiles/$($script:Ze.RestoreId)/apply" $null | Out-Null; Write-Log "  Zeus live state restored to the previously active profile." DarkGray }
            catch { Write-Log "  [WARN] could not restore Zeus live state: $($_.Exception.Message)" Yellow }
        } else { Write-Log "  [WARN] Zeus live state was changed and the previously active profile is unknown - select one in Zeus before transmitting." Yellow }
    }
}
