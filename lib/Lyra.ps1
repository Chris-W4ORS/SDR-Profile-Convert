# lib/Lyra.ps1 - Lyra adapter (N8SDR Lyra-SDR-cpp, Qt 6, schemaVersion 7 profiles)
#
# Settings: Qt QSettings NativeFormat = the registry, HKCU\Software\N8SDR\<app>.
#   <app> is "Lyra-cpp" (the ASIO build uses "Lyra-cpp-ASIO"). A Lyra backup /
#   snapshot file (*.lyra) holds the same keys in Qt INI format (src/backup.cpp).
# Profiles (src/profile/ProfileStore.cpp):
#   profiles/order        QStringList (REG_MULTI_SZ)  display order
#   profiles/active       QString                     last-loaded profile
#   profiles/item/<name>  QString                     compact JSON of the Profile
#   Qt keeps a key called "Default" in the registry key's (Default) value, so a
#   profile named Default is the (Default) value of profiles\item, and Qt's INI
#   export writes it as item\. .
# TX EQ (src/dsp/ParamEq.*): 10 RBJ-cookbook biquads at 48 kHz, run on the mic
#   ahead of WDSP's TXA chain (WDSP's own TX EQ stays off). type 0 Peak,
#   1 LowShelf, 2 HighShelf, 3 LowPass, 4 HighPass, 5 BandPass, 6 Notch; HP/LP are
#   12 dB/oct with Q. Ranges: 20-20000 Hz, gain +/-15 dB, Q 0.2-10. makeupDb is an
#   output trim after the cascade (+/-24 dB) and is included in the drawn curve.
# Leveler / ALC: levelerMaxGainLinear and alcMaxGainLinear are passed to WDSP
#   unconverted, the same numbers Thetis passes for Lev_MaxGain / ALC_MaximumGain,
#   so they map 1:1 (the "Linear" in the names is Lyra's own label).
# Rack stages carried: Speech (gate, AGC, de-esser) and Plate (reverb). The
#   5-band Combinator is only carried Lyra -> Lyra.

$script:Ly = $null
$script:LyraFile = $null              # set by Convert-SdrProfile.ps1 -LyraFile
$script:LyraSchemaKnown = 7
$script:LyraTypeId = @{ Peak = 0; LowShelf = 1; HighShelf = 2; LowPass = 3; HighPass = 4 }
$script:LyraTypeName = @{ 0 = 'Peak'; 1 = 'LowShelf'; 2 = 'HighShelf'; 3 = 'LowPass'; 4 = 'HighPass'; 5 = 'BandPass'; 6 = 'Notch' }

# Lyra's default EQ layout (ParamEq.cpp kDefaults) - used when no profile exists to clone.
$script:LyraTemplate = @'
{"schemaVersion":7,
 "eq":{"bands":[{"en":true,"f":60,"g":0,"q":0.707,"type":4},{"en":true,"f":150,"g":0,"q":0.707,"type":1},
  {"en":true,"f":300,"g":0,"q":1,"type":0},{"en":true,"f":500,"g":0,"q":1,"type":0},{"en":true,"f":850,"g":0,"q":1,"type":0},
  {"en":true,"f":1400,"g":0,"q":1,"type":0},{"en":true,"f":2300,"g":0,"q":1,"type":0},{"en":true,"f":3800,"g":0,"q":1,"type":0},
  {"en":true,"f":6000,"g":0,"q":0.707,"type":2},{"en":true,"f":10000,"g":0,"q":0.707,"type":3}],"bypass":false,"makeupDb":0}}
'@

function Test-IsWindowsHost { return ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) }

# ---------------------------------------------------------------------------
# Qt INI (*.lyra) read / write - only what the profiles group needs
# ---------------------------------------------------------------------------
function ConvertFrom-QtIniKey {
    param([string]$k)
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $k.Length; $i++) {
        $c = $k[$i]
        if ($c -eq '\') { [void]$sb.Append('/') }
        elseif ($c -eq '%' -and $i + 5 -lt $k.Length -and $k[$i + 1] -eq 'U') { [void]$sb.Append([char][Convert]::ToInt32($k.Substring($i + 2, 4), 16)); $i += 5 }
        elseif ($c -eq '%' -and $i + 2 -lt $k.Length) { [void]$sb.Append([char][Convert]::ToInt32($k.Substring($i + 1, 2), 16)); $i += 2 }
        else { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}
function ConvertTo-QtIniKey {
    # Qt iniEscapedKey: '/' -> '\', [A-Za-z0-9_.-] as is, other chars %XX or %UXXXX
    param([string]$k)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $k.ToCharArray()) {
        if ($c -eq '/') { [void]$sb.Append('\') }
        elseif ($c -match '[A-Za-z0-9_.\-]') { [void]$sb.Append($c) }
        elseif ([int]$c -lt 256) { [void]$sb.Append(('%{0:X2}' -f [int]$c)) }
        else { [void]$sb.Append(('%U{0:X4}' -f [int]$c)) }
    }
    return $sb.ToString()
}
function ConvertFrom-QtIniValue {
    # Qt iniUnescapedStringList. Returns a string, or string[] for a comma list.
    param([string]$v)
    $items = New-Object System.Collections.ArrayList
    $sb = New-Object System.Text.StringBuilder; $inQ = $false; $quoted = $false
    $push = { $t = $sb.ToString(); if (-not $quoted) { $t = $t.Trim() }; [void]$items.Add($t); [void]$sb.Clear() }
    for ($i = 0; $i -lt $v.Length; $i++) {
        $c = $v[$i]
        if ($c -eq '"') { $inQ = -not $inQ; $quoted = $true; continue }
        if ($c -eq '\' -and $i + 1 -lt $v.Length) {
            $i++; $e = $v[$i]
            switch -CaseSensitive ([string]$e) {
                'n' { [void]$sb.Append("`n") } 'r' { [void]$sb.Append("`r") } 't' { [void]$sb.Append("`t") }
                'a' { [void]$sb.Append([char]7) } 'b' { [void]$sb.Append([char]8) } 'f' { [void]$sb.Append([char]12) } 'v' { [void]$sb.Append([char]11) }
                'x' { $h = ''; while ($i + 1 -lt $v.Length -and $h.Length -lt 4 -and $v[$i + 1] -match '[0-9A-Fa-f]') { $i++; $h += $v[$i] }; if ($h) { [void]$sb.Append([char][Convert]::ToInt32($h, 16)) } }
                default { [void]$sb.Append($e) }
            }
            continue
        }
        if ($c -eq ',' -and -not $inQ) { & $push; $quoted = $false; continue }
        [void]$sb.Append($c)
    }
    & $push
    if ($items.Count -gt 1) { return , [string[]]$items.ToArray() }
    return [string]$items[0]
}
function ConvertTo-QtIniString {
    # Qt iniEscapedString for ASCII text (JSON written here is ASCII-only).
    param([string]$s)
    if ($s.StartsWith('@')) { $s = '@' + $s }
    $sb = New-Object System.Text.StringBuilder
    $needQ = ($s.Length -gt 0) -and ($s[0] -eq ' ' -or $s[$s.Length - 1] -eq ' ')
    foreach ($c in $s.ToCharArray()) {
        switch ([int]$c) {
            34 { [void]$sb.Append('\"') }          # "
            92 { [void]$sb.Append('\\') }          # \
            10 { [void]$sb.Append('\n') }
            13 { [void]$sb.Append('\r') }
            9  { [void]$sb.Append('\t') }
            default {
                if ([int]$c -lt 32 -or [int]$c -gt 126) { throw "can't write character U+$('{0:X4}' -f [int]$c) to a .lyra file (use ASCII profile names, or close Lyra so the registry can be written directly)" }
                if ($c -eq ';' -or $c -eq ',' -or $c -eq '=') { $needQ = $true }
                [void]$sb.Append($c)
            }
        }
    }
    if ($needQ) { return '"' + $sb.ToString() + '"' }
    return $sb.ToString()
}
function Read-QtIni {
    # Returns an ordered map of full key ("section/key", General = root) -> raw value text.
    param([string]$Path)
    $map = [ordered]@{}; $sect = ''
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        if ($line -match '^\s*[;#]' -or $line -match '^\s*$') { continue }
        if ($line -match '^\s*\[(.*)\]\s*$') { $s = ConvertFrom-QtIniKey $matches[1]; $sect = if ($s -eq 'General') { '' } else { $s }; continue }
        $eq = $line.IndexOf('='); if ($eq -lt 1) { continue }
        $k = ConvertFrom-QtIniKey ($line.Substring(0, $eq).Trim())
        $full = if ($sect) { "$sect/$k" } else { $k }
        $map[$full] = $line.Substring($eq + 1).Trim()
    }
    return $map
}

# ---------------------------------------------------------------------------
# Store: registry (live) or a .lyra file (read-only source)
# ---------------------------------------------------------------------------
function Find-LyraRegistryApps {
    if (-not (Test-IsWindowsHost)) { return @() }
    $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\N8SDR')
    if (-not $root) { return @() }
    try {
        return @($root.GetSubKeyNames() | Where-Object { $_ -like 'Lyra*' } | Where-Object {
            $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\N8SDR\$_\profiles\item")
            if ($k) { $k.Close(); $true } else { $false } })
    } finally { $root.Close() }
}

function Read-LyraRegistryProfiles {
    param([string]$Sub)
    $items = [ordered]@{}; $order = @(); $active = $null
    $ik = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$Sub\profiles\item")
    if ($ik) {
        try {
            foreach ($vn in $ik.GetValueNames()) {
                $v = $ik.GetValue($vn, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($v -is [string] -and $v.TrimStart().StartsWith('{')) { $items[$(if ($vn -eq '') { 'Default' } else { $vn })] = $v }
            }
        } finally { $ik.Close() }
    }
    $pk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$Sub\profiles")
    if ($pk) {
        try {
            $o = $pk.GetValue('order'); if ($o -is [array]) { $order = @($o) } elseif ($o -is [string] -and $o -and -not $o.StartsWith('@')) { $order = @($o) }
            $active = $pk.GetValue('active')
        } finally { $pk.Close() }
    }
    return @{ Items = $items; Order = $order; Active = $active }
}

function Read-LyraFileProfiles {
    param([string]$Path)
    $ini = Read-QtIni $Path
    $items = [ordered]@{}; $order = @(); $active = $null
    foreach ($k in $ini.Keys) {
        if ($k -like 'profiles/item/*') {
            $n = $k.Substring(14); if ($n -eq '.') { $n = 'Default' }
            $items[$n] = [string](ConvertFrom-QtIniValue $ini[$k])
        }
    }
    if ($ini.Contains('profiles/order')) { $order = @(ConvertFrom-QtIniValue $ini['profiles/order']) }
    if ($ini.Contains('profiles/active')) { $active = [string](ConvertFrom-QtIniValue $ini['profiles/active']) }
    return @{ Items = $items; Order = $order; Active = $active }
}

function Lyra_Open {
    if ($script:Ly) { return $true }
    if ($script:LyraFile) {
        if (-not (Test-Path -LiteralPath $script:LyraFile)) { return $false }
        $p = Read-LyraFileProfiles $script:LyraFile
        $script:Ly = @{ Mode = 'file'; Where = $script:LyraFile; Sub = $null }
    } else {
        $apps = @(Find-LyraRegistryApps)
        if ($apps.Count -eq 0) { return $false }
        $app = if ($apps.Count -eq 1) { $apps[0] } else { Select-Item "Lyra settings (registry):" $apps { param($a) "HKCU\Software\N8SDR\$a" } }
        $sub = "Software\N8SDR\$app"
        $p = Read-LyraRegistryProfiles $sub
        $script:Ly = @{ Mode = 'registry'; Where = "HKCU\$sub"; Sub = $sub }
    }
    $script:Ly.Items = $p.Items; $script:Ly.Order = @($p.Order); $script:Ly.Active = $p.Active
    $script:Ly.Dirty = New-Object System.Collections.ArrayList
    $schemas = @(foreach ($n in $p.Items.Keys) { try { [int](ConvertTo-Num (($p.Items[$n] | ConvertFrom-Json).schemaVersion) 0) } catch { 0 } })
    $script:Ly.MaxSchema = if ($schemas.Count) { ($schemas | Measure-Object -Maximum).Maximum } else { 0 }
    return $true
}

function Lyra_Status {
    if (-not (Lyra_Open)) {
        $why = if ($script:LyraFile) { "Lyra file not found: $script:LyraFile" } else { 'No Lyra profiles in HKCU\Software\N8SDR\Lyra-cpp* (run Lyra once and save a profile)' }
        return @{ Available = $false; Reason = $why }
    }
    $info = "$($script:Ly.Where), $($script:Ly.Items.Count) profiles$(if ($script:Ly.Active) { ", active '$($script:Ly.Active)'" })"
    if ($script:Ly.MaxSchema -gt $script:LyraSchemaKnown) { $info += " (profile schema v$($script:Ly.MaxSchema), adapter knows v$script:LyraSchemaKnown - run Probe-SdrStores.ps1)" }
    if ($script:Ly.Mode -eq 'file') { $info += '; writes a .lyra file to restore in Lyra' }
    elseif (Test-ProcRunning @('lyra')) { $info += '; Lyra running -> writes a .lyra file to restore instead of editing the registry' }
    return @{ Available = $true; CanWrite = $true; Reason = $info }
}

function Get-LyraNames {
    $names = New-Object System.Collections.ArrayList
    foreach ($n in $script:Ly.Order) { if ($script:Ly.Items.Contains($n) -and -not $names.Contains($n)) { [void]$names.Add($n) } }
    foreach ($n in $script:Ly.Items.Keys) { if (-not $names.Contains($n)) { [void]$names.Add($n) } }
    return @($names)
}
function Lyra_List { Lyra_Open | Out-Null; return @(foreach ($n in (Get-LyraNames)) { @{ Name = $n; Active = ($n -eq $script:Ly.Active) } }) }

function Get-LyraProfile { param([string]$Name) return ConvertTo-HT ($script:Ly.Items[$Name] | ConvertFrom-Json) }

# ---------------------------------------------------------------------------
# Read: Lyra profile -> canonical
# ---------------------------------------------------------------------------
function Lyra_Read {
    param([string]$Name)
    if (-not $script:Ly.Items.Contains($Name)) { throw "Lyra profile '$Name' not found" }
    $p = Get-LyraProfile $Name
    $c = New-Canon $Name 'Lyra'
    $n = { param($k) if ($p.Contains($k)) { ConvertTo-Num $p[$k] } else { $null } }
    $lo = & $n 'txFilterLow'; $hi = & $n 'txBandwidth'
    if ($lo -gt 0 -or $hi -gt 0) { $c.filter.lowHz = $lo; $c.filter.highHz = $hi }
    $c.mic.gainDb = & $n 'micGainDb'
    if ($p.Contains('micBoost')) { $c.mic.boost = [bool]$p.micBoost }
    if ($p.Contains('levelerOn')) { $c.leveler.enabled = [bool]$p.levelerOn }
    $c.leveler.maxGainDb = & $n 'levelerMaxGainLinear'; $c.leveler.decayMs = & $n 'levelerDecayMs'
    $c.alc.maxGainDb = & $n 'alcMaxGainLinear'
    if ($p.Contains('phrotEnabled')) { $c.phaseRotator.enabled = [bool]$p.phrotEnabled }

    $eq = $p.eq
    if ($eq -and $eq.bands) {
        $pts = New-Object System.Collections.ArrayList; $dropped = @(); $hp = $null; $lp = $null
        foreach ($b in @($eq.bands)) {
            if (-not $b.en) { continue }
            $t = $script:LyraTypeName[[int](ConvertTo-Num $b.type 0)]
            if ($t -in @('BandPass', 'Notch')) { $dropped += "$t $([math]::Round([double]$b.f)) Hz"; continue }
            [void]$pts.Add(@{ freqHz = [double]$b.f; gainDb = [double](ConvertTo-Num $b.g 0); q = [double](ConvertTo-Num $b.q 1); type = $t })
            if ($t -eq 'HighPass' -and ($null -eq $hp -or [double]$b.f -gt $hp)) { $hp = [double]$b.f }
            if ($t -eq 'LowPass' -and ($null -eq $lp -or [double]$b.f -lt $lp)) { $lp = [double]$b.f }
        }
        if ($dropped.Count) { Add-Note $c "Lyra EQ band(s) $($dropped -join ', ') have no equivalent in the other apps - dropped." }
        $c.txEq.enabled = -not [bool]$eq.bypass; $c.txEq.mode = 'parametric'; $c.txEq.preampDb = 0.0
        $c.txEq.outputDb = [double](ConvertTo-Num $eq.makeupDb 0)
        $c.txEq.curve = [ordered]@{ parametric = $true; globalGainDb = 0.0; useQ = $true; qModel = 'rbj'; points = @($pts); freqMinHz = $null; freqMaxHz = $null }
        $c.txEq.legacy = @(foreach ($q in $pts) { [ordered]@{ freqHz = $q.freqHz; gainDb = $q.gainDb } })
        if ($hp -or $lp) { $c.txEq.bandLimitHz = [ordered]@{ lowHz = $hp; highHz = $lp } }
    }
    $s = $p.speech
    if ($s) {
        $c.noiseGate.enabled = [bool]$s.gateOn; $c.noiseGate.thresholdDb = ConvertTo-Num $s.gateThreshDb; $c.noiseGate.holdMs = ConvertTo-Num $s.gateHoldMs
        if ($null -ne $s.gateRangeDb) { $c.noiseGate.rangeDb = 0 - [math]::Abs([double]$s.gateRangeDb) }
        $c.agc = [ordered]@{ enabled = [bool]$s.agcOn; targetDb = (ConvertTo-Num $s.agcTargetDb); maxGainDb = (ConvertTo-Num $s.agcMaxGainDb); maxCutDb = $null; speedMs = $null; gateDb = $null }
        $c.deEsser = [ordered]@{ enabled = [bool]$s.deessOn; frequencyHz = (ConvertTo-Num $s.deessFreqHz); thresholdDb = (ConvertTo-Num $s.deessThreshDb); ratio = $null; rangeDb = (ConvertTo-Num $s.deessRangeDb); attackMs = $null; releaseMs = $null; wide = $false }
    }
    $pl = $p.plate
    if ($pl) {
        $c.reverb = [ordered]@{ enabled = -not [bool]$pl.bypass; sizePercent = (ConvertTo-Num $pl.size); decayPercent = $null; dampPercent = (ConvertTo-Num $pl.damp); preDelayMs = (ConvertTo-Num $pl.preDelayMs); mixPercent = $(if ($null -ne $pl.mix) { [math]::Round([double]$pl.mix * 100, 1) } else { $null }) }
        if (-not $pl.bypass) { Add-Note $c "Lyra plate reverb: decay $($pl.decayS) s, density, diffusion and bass/treble trims are Lyra-only." 'DarkGray' }
    }
    if ($p.combinator -and -not $p.combinator.bypass) { Add-Note $c "Lyra Combinator (5-band compressor, $($p.combinator.ratio):1 at $($p.combinator.threshDb) dB) is ON - only carried Lyra -> Lyra." }
    $c.lyra = Copy-Deep $p   # raw profile: makes Lyra -> Lyra lossless
    return $c
}

# ---------------------------------------------------------------------------
# EQ: canonical -> Lyra's 10 RBJ bands
# ---------------------------------------------------------------------------
function Get-WdspCurveDb {
    # Thetis/NereusSDR parametric EQ response (lib/ThetisFamily.ps1 model): Gaussian
    # points summed in dB, acting only between the lowest and highest point.
    param($points, [double]$f)
    $pts = @($points | Where-Object { $null -ne $_ })
    if ($pts.Count -eq 0) { return 0.0 }
    $fs = @($pts | ForEach-Object { [double]$_.freqHz })
    $lo = ($fs | Measure-Object -Minimum).Minimum; $hi = ($fs | Measure-Object -Maximum).Maximum
    if ($f -lt $lo -or $f -gt $hi) { return 0.0 }
    $sum = 0.0
    foreach ($p in $pts) { $q = [double](ConvertTo-Num $p.q 1.0); if ($q -le 0) { $q = 1.0 }; $sum += [double](ConvertTo-Num $p.gainDb 0) * (Get-WdspPointWeight $f ([double]$p.freqHz) $q) }
    return $sum
}

function Fit-LyraPeaks {
    # Least-squares fit of N RBJ peak bands (fixed log-spaced centres, one Q matched to
    # the spacing) to a target response; Gauss-Newton with a light ridge. Gains are
    # clamped to Lyra's +/-15 dB and rounded to 0.1 dB.
    param([double[]]$Grid, [double[]]$Target, [double]$FLo, [double]$FHi, [int]$N = 10)
    $ctr = [double[]]@(for ($j = 0; $j -lt $N; $j++) { $FLo * [math]::Pow($FHi / $FLo, $j / ($N - 1)) })
    $oct = [math]::Log([math]::Pow($FHi / $FLo, 1.0 / ($N - 1))) / [math]::Log(2)
    $q = Clamp ([math]::Sqrt([math]::Pow(2, $oct)) / ([math]::Pow(2, $oct) - 1)) 0.2 10
    $m = $Grid.Count
    $g = New-Object double[] $N
    for ($it = 0; $it -lt 6; $it++) {
        $jac = New-Object 'double[,]' $m, $N; $res = New-Object double[] $m
        for ($i = 0; $i -lt $m; $i++) { $r = 0.0; for ($j = 0; $j -lt $N; $j++) { $r += Get-BiquadDb 'Peak' $ctr[$j] $g[$j] $q 12 $Grid[$i] }; $res[$i] = $Target[$i] - $r }
        for ($j = 0; $j -lt $N; $j++) {
            for ($i = 0; $i -lt $m; $i++) { $jac[$i, $j] = ((Get-BiquadDb 'Peak' $ctr[$j] ($g[$j] + 0.05) $q 12 $Grid[$i]) - (Get-BiquadDb 'Peak' $ctr[$j] ($g[$j] - 0.05) $q 12 $Grid[$i])) / 0.1 }
        }
        $ata = New-Object 'double[,]' $N, $N; $bv = New-Object double[] $N; $tr = 0.0
        for ($u = 0; $u -lt $N; $u++) {
            for ($v = 0; $v -lt $N; $v++) { $s = 0.0; for ($i = 0; $i -lt $m; $i++) { $s += $jac[$i, $u] * $jac[$i, $v] }; $ata[$u, $v] = $s }
            $s = 0.0; for ($i = 0; $i -lt $m; $i++) { $s += $jac[$i, $u] * $res[$i] }; $bv[$u] = $s; $tr += $ata[$u, $u]
        }
        $lambda = 1e-3 * $tr / $N; for ($u = 0; $u -lt $N; $u++) { $ata[$u, $u] += $lambda }
        $step = Solve-LinearSystem $ata $bv
        for ($j = 0; $j -lt $N; $j++) { $g[$j] = Clamp ($g[$j] + $step[$j]) -15 15 }
    }
    for ($j = 0; $j -lt $N; $j++) { $g[$j] = [math]::Round($g[$j], 1) }
    $maxErr = 0.0; $sq = 0.0
    for ($i = 0; $i -lt $m; $i++) { $r = 0.0; for ($j = 0; $j -lt $N; $j++) { $r += Get-BiquadDb 'Peak' $ctr[$j] $g[$j] $q 12 $Grid[$i] }; $d = [math]::Abs($r - $Target[$i]); if ($d -gt $maxErr) { $maxErr = $d }; $sq += $d * $d }
    $bands = @(for ($j = 0; $j -lt $N; $j++) { @{ type = 'Peak'; freqHz = [math]::Round($ctr[$j], 1); gainDb = $g[$j]; q = [math]::Round($q, 2) } })
    return @{ Bands = $bands; Q = $q; MaxErr = $maxErr; Rms = [math]::Sqrt($sq / $m) }
}

function Get-LyraFitRange {
    param($canon)
    $bl = $canon.txEq.bandLimitHz
    $lo = if ($null -ne (ConvertTo-Num $canon.filter.lowHz)) { $canon.filter.lowHz } elseif ($bl -and $null -ne (ConvertTo-Num $bl.lowHz)) { $bl.lowHz } else { 80 }
    $hi = if ($null -ne (ConvertTo-Num $canon.filter.highHz)) { $canon.filter.highHz } elseif ($bl -and $null -ne (ConvertTo-Num $bl.highHz)) { $bl.highHz } else { 4000 }
    $fLo = [math]::Max(50.0, [double](ConvertTo-Num $lo 80)); $fHi = [math]::Min(8000.0, [double](ConvertTo-Num $hi 4000))
    if ($fHi -le $fLo + 200) { $fHi = $fLo + 3000 }
    return @($fLo, $fHi)
}

function ConvertTo-LyraEq {
    # Returns the Lyra eq object, or $null when the source says nothing about its EQ.
    param($canon, $tplEq, $rules)
    $e = $canon.txEq
    if (-not $e -or (-not $e.curve -and -not $e.legacy)) { return $null }
    $origin = if ($canon.source.origin) { $canon.source.origin } else { $canon.source.app }
    if ($origin -eq 'Lyra' -and $canon.lyra -and $canon.lyra.eq -and $e.curve -and $e.curve.qModel -eq 'rbj' -and -not $e.curve.interp) {
        Write-Log "    EQ: copied as-is (Lyra source)" DarkGray
        return Copy-Deep $canon.lyra.eq
    }
    $out = Copy-Deep $tplEq
    if (-not $out -or -not $out.bands) { $out = (ConvertTo-HT ($script:LyraTemplate | ConvertFrom-Json)).eq }
    $slots = @($out.bands)
    $total = 0.0; $bands = $null; $fitInfo = $null
    $cutsInEq = ((Get-SdrOption $rules 'Lyra' 'inputCuts' 'eq') -eq 'eq')

    if ($e.curve -and $e.curve.qModel -eq 'rbj' -and -not $e.curve.interp) {
        # Conventional source (Zeus / AetherSDR / Lyra): same filter maths as Lyra.
        $list = New-Object System.Collections.ArrayList
        foreach ($p in @($e.curve.points)) { if ($null -ne $p) { [void]$list.Add(@{ type = $(if ($p.type) { "$($p.type)" } else { 'Peak' }); freqHz = [double]$p.freqHz; gainDb = [double](ConvertTo-Num $p.gainDb 0); q = [double](ConvertTo-Num $p.q 1) }) } }
        $is = $canon.inputStrip
        if ($cutsInEq -and $is -and $is.enabled) {
            if ([double](ConvertTo-Num $is.hpfSlopeDb 0) -gt 0 -and $is.hpfHz) {
                [void]$list.Add(@{ type = 'HighPass'; freqHz = [double]$is.hpfHz; gainDb = 0.0; q = 0.707 })
                if ([double]$is.hpfSlopeDb -ne 12) { Add-Note $canon "input low cut is $($is.hpfSlopeDb) dB/oct in the source; Lyra's High-Pass is 12 dB/oct." 'DarkGray' }
            }
            if ($is.lpfHz -and [double]$is.lpfHz -lt 20000) { [void]$list.Add(@{ type = 'LowPass'; freqHz = [double]$is.lpfHz; gainDb = 0.0; q = 0.707 }) }
        }
        $mb = $canon.multiband
        if ($mb -and $mb.enabled -and [bool](Get-SdrOption $rules 'Lyra' 'multibandToEq' $true)) {
            $x = @($mb.crossoversHz | ForEach-Object { [double]$_ }); $mg = @($mb.bands | ForEach-Object { if ($_.bypass) { 0.0 } else { [double](ConvertTo-Num $_.makeupDb 0) } })
            if ($x.Count -eq 3 -and $mg.Count -eq 4) {
                if ($mg[0] -ne 0) { [void]$list.Add(@{ type = 'LowShelf'; freqHz = $x[0]; gainDb = $mg[0]; q = 0.707 }) }
                for ($k = 1; $k -le 2; $k++) { if ($mg[$k] -ne 0) { $f0 = [math]::Sqrt($x[$k - 1] * $x[$k]); [void]$list.Add(@{ type = 'Peak'; freqHz = $f0; gainDb = $mg[$k]; q = ($f0 / ($x[$k] - $x[$k - 1])) }) } }
                if ($mg[3] -ne 0) { [void]$list.Add(@{ type = 'HighShelf'; freqHz = $x[2]; gainDb = $mg[3]; q = 0.707 }) }
            }
        }
        $trim = if ($is -and $is.enabled) { [double](ConvertTo-Num $is.trimDb 0) } else { 0.0 }
        $total = [double](ConvertTo-Num $e.preampDb 0) + [double](ConvertTo-Num $e.outputDb 0) + $trim
        # Flat gain bands carry nothing - drop them first if there are more bands than slots.
        if ($list.Count -gt $slots.Count) { $list = [System.Collections.ArrayList]@($list | Where-Object { $_.type -match 'Pass' -or [math]::Abs($_.gainDb) -gt 0.01 }) }
        if ($list.Count -le $slots.Count) {
            $bands = @($list | Sort-Object { $_.freqHz })
            Write-Log "    EQ: $($bands.Count) band(s) copied band for band (same RBJ filters as Lyra)" DarkGray
        } else {
            $r = Get-LyraFitRange $canon
            $grid = [double[]]@(for ($i = 0; $i -lt 120; $i++) { $r[0] * [math]::Pow($r[1] / $r[0], $i / 119) })
            $tgt = Get-ConventionalEqTargetDb $canon $grid $cutsInEq
            $fitInfo = Fit-LyraPeaks $grid $tgt $r[0] $r[1] $slots.Count; $bands = $fitInfo.Bands
        }
        $out.bypass = ($e.enabled -eq $false)
    } else {
        # Thetis / NereusSDR: WDSP curve (or legacy 10-band graphic) -> fitted RBJ peaks.
        $eqOn = ($e.enabled -ne $false)
        $r = Get-LyraFitRange $canon
        $grid = [double[]]@(for ($i = 0; $i -lt 120; $i++) { $r[0] * [math]::Pow($r[1] / $r[0], $i / 119) })
        $tgt = New-Object double[] $grid.Count
        $parts = @()
        if ($eqOn) {
            if ($e.mode -eq 'parametric' -and $e.curve -and -not $e.curve.interp) {
                for ($i = 0; $i -lt $grid.Count; $i++) { $tgt[$i] = Get-WdspCurveDb $e.curve.points $grid[$i] }
                $total = [double](ConvertTo-Num $e.curve.globalGainDb 0); $parts += 'TX EQ (parametric)'
            } elseif ($e.curve -and $e.curve.interp) {
                # A curve from a rules-file eqBaseline: plain points, interpolated.
                $lg = Resample-Curve $e.curve.points $grid $e.curve.interp
                for ($i = 0; $i -lt $grid.Count; $i++) { $tgt[$i] = $lg[$i] }
                $total = [double](ConvertTo-Num $e.curve.globalGainDb 0); $parts += 'rules eqBaseline curve'
            } else {
                $lg = Resample-Curve (Get-TxEqPoints $canon) $grid 'pchip'
                for ($i = 0; $i -lt $grid.Count; $i++) { $tgt[$i] = $lg[$i] }
                $total = [double](ConvertTo-Num $e.preampDb 0); $parts += 'TX EQ (10-band legacy)'
            }
        }
        $c = $canon.cfc
        $postPts = @(Get-CfcPoints $canon 'post')
        if ([bool](Get-SdrOption $rules 'Lyra' 'includeCfcPostEq' $true) -and $c.enabled -and $c.postEqEnabled -and $postPts.Count -and -not (Test-CurveFlat @{ points = $postPts })) {
            $pg = Resample-Curve $postPts $grid 'pchip'
            for ($i = 0; $i -lt $grid.Count; $i++) { $tgt[$i] += $pg[$i] }
            $parts += 'CFC post-EQ'
        }
        $fitInfo = Fit-LyraPeaks $grid $tgt $r[0] $r[1] $slots.Count; $bands = $fitInfo.Bands
        $out.bypass = ($parts.Count -eq 0)
        if ($parts.Count) { Write-Log "    EQ source: $($parts -join ' + ')" DarkGray }
    }

    for ($k = 0; $k -lt $slots.Count; $k++) {
        $sl = $slots[$k]
        if ($k -lt $bands.Count) {
            $b = $bands[$k]
            $g = [double]$b.gainDb
            if ([math]::Abs($g) -gt 15) { Add-Note $canon "EQ band $([math]::Round($b.freqHz)) Hz gain $([math]::Round($g,1)) dB clamped to Lyra's +/-15 dB."; $g = Clamp $g -15 15 }
            $sl.en = $true; $sl.f = [math]::Round((Clamp ([double]$b.freqHz) 20 20000), 1); $sl.g = [math]::Round($g, 2)
            $sl.q = [math]::Round((Clamp ([double]$b.q) 0.2 10), 3); $sl.type = $script:LyraTypeId["$($b.type)"]
        } else { $sl.en = $false }
    }
    $out.bands = $slots

    # EQ gain -> makeup (output trim ahead of WDSP's leveler), option eqGain keep | zero | number
    $egOpt = Get-SdrOption $rules 'Lyra' 'eqGain' 'keep'; $src = $total; $cap = 0.0
    if ("$egOpt" -eq 'zero') { $total = 0.0 }
    elseif ($egOpt -is [ValueType] -and $egOpt -isnot [bool]) { $total = [math]::Min($total, [double]$egOpt) }
    elseif ("$egOpt" -ne 'keep') {
        if ([double]::TryParse("$egOpt", [Globalization.NumberStyles]::Float, $script:Inv, [ref]$cap)) { $total = [math]::Min($total, $cap) }
        else { Add-Note $canon "option Lyra.eqGain '$egOpt' is not 'keep', 'zero' or a number - using keep." }
    }
    if ($total -ne $src) { Write-Log ("    EQ gain: {0:+0.0;-0.0;0.0} dB at the source -> {1:+0.0;-0.0;0.0} dB makeup (option Lyra.eqGain = {2})" -f $src, $total, $egOpt) DarkGray }
    $out.makeupDb = [math]::Round((Clamp $total -24 24), 1)
    if ($fitInfo) {
        Write-Log ("    EQ: fitted to {0} Lyra peaks (Q {1:0.##}), {2:0}-{3:0} Hz; fit error max {4:0.0} dB / rms {5:0.00} dB; makeup {6:+0.0;-0.0;0.0} dB" -f $bands.Count, $fitInfo.Q, (Get-LyraFitRange $canon)[0], (Get-LyraFitRange $canon)[1], $fitInfo.MaxErr, $fitInfo.Rms, $out.makeupDb) DarkGray
        if ($fitInfo.MaxErr -gt 1.5) { Add-Note $canon ("Lyra EQ fit is off by up to {0:0.0} dB somewhere in the passband (rms {1:0.00} dB) - check the TX EQ curve against the source." -f $fitInfo.MaxErr, $fitInfo.Rms) 'DarkGray' }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Write: canonical -> Lyra profile JSON
# ---------------------------------------------------------------------------
function Get-LyraTemplateFor {
    param([string]$DestName, $canon)
    $origin = if ($canon.source.origin) { $canon.source.origin } else { $canon.source.app }
    if ($origin -eq 'Lyra' -and $canon.lyra) { return @{ P = (Copy-Deep $canon.lyra); From = 'source profile' } }
    if ($script:Ly.Items.Contains($DestName)) { return @{ P = (Get-LyraProfile $DestName); From = 'existing profile' } }
    $seed = if ($script:CloneFrom -and $script:Ly.Items.Contains($script:CloneFrom)) { $script:CloneFrom } elseif ($script:Ly.Active -and $script:Ly.Items.Contains($script:Ly.Active)) { $script:Ly.Active } else { @(Get-LyraNames)[0] }
    if ($seed) { return @{ P = (Get-LyraProfile $seed); From = "cloned from '$seed'" } }
    return @{ P = (ConvertTo-HT ($script:LyraTemplate | ConvertFrom-Json)); From = 'built-in defaults' }
}

function ConvertTo-LyraProfile {
    param($canon, [string]$DestName, $rules)
    $t = Get-LyraTemplateFor $DestName $canon
    $p = $t.P
    Write-Log "    template: $($t.From)" DarkGray
    $origin = if ($canon.source.origin) { $canon.source.origin } else { $canon.source.app }
    $set = { param($k, $v) if ($null -ne $v) { $p[$k] = $v } }

    if ($null -ne (ConvertTo-Num $canon.filter.lowHz)) { & $set 'txFilterLow' ([int][math]::Round([double]$canon.filter.lowHz)) }
    if ($null -ne (ConvertTo-Num $canon.filter.highHz)) { & $set 'txBandwidth' ([int][math]::Round([double]$canon.filter.highHz)) }
    if ([bool](Get-SdrOption $rules 'Lyra' 'carryMicGain' $false)) {
        if ($null -ne $canon.mic.gainDb) { & $set 'micGainDb' ([double](Clamp ([double]$canon.mic.gainDb) -90 40)) }
        if ($null -ne $canon.mic.boost) { & $set 'micBoost' ([bool]$canon.mic.boost) }
    } elseif ($origin -ne 'Lyra' -and $null -ne $canon.mic.gainDb) { Add-Note $canon "mic gain left as it is in Lyra (option Lyra.carryMicGain = true to copy the source's $($canon.mic.gainDb) dB)." 'DarkGray' }
    if ($null -ne $canon.leveler.enabled) { & $set 'levelerOn' ([bool]$canon.leveler.enabled) }
    if ($null -ne $canon.leveler.maxGainDb) { & $set 'levelerMaxGainLinear' ([double](Clamp ([double]$canon.leveler.maxGainDb) 0 20)) }
    if ($null -ne $canon.leveler.decayMs) { & $set 'levelerDecayMs' ([int](Clamp ([double]$canon.leveler.decayMs) 1 5000)) }
    if ($null -ne $canon.alc.maxGainDb) { & $set 'alcMaxGainLinear' ([double](Clamp ([double]$canon.alc.maxGainDb) 0 120)) }
    if ($null -ne $canon.phaseRotator.enabled) { & $set 'phrotEnabled' ([bool]$canon.phaseRotator.enabled) }

    $eq = ConvertTo-LyraEq $canon $p.eq $rules
    if ($eq) { $p.eq = $eq }

    # --- Speech: gate / AGC / de-esser ---
    if (-not $p.Contains('speech') -or $null -eq $p.speech) { $p.speech = [ordered]@{} }
    $sp = $p.speech
    $g = $canon.noiseGate
    if ($origin -in @('Thetis', 'Nereus') -and [bool](Get-SdrOption $rules 'Lyra' 'gateFromDexp' $true) -and $null -ne $canon.dexp.enabled) {
        $sp.gateOn = [bool]$canon.dexp.enabled
        if ($null -ne $canon.dexp.thresholdDb) { $sp.gateThreshDb = [double]$canon.dexp.thresholdDb }
        if ($null -ne $canon.dexp.expansionDb) { $sp.gateRangeDb = [math]::Abs([double]$canon.dexp.expansionDb) }
        if ($canon.dexp.enabled) { Add-Note $canon "DEXP -> Lyra gate: threshold $($sp.gateThreshDb) dB, depth $($sp.gateRangeDb) dB; DEXP timing has no Lyra equivalent." 'DarkGray' }
    } elseif ($g -and $null -ne $g.enabled) {
        $sp.gateOn = [bool]$g.enabled
        if ($null -ne $g.thresholdDb) { $sp.gateThreshDb = [double]$g.thresholdDb }
        if ($null -ne $g.holdMs) { $sp.gateHoldMs = [double]$g.holdMs }
        if ($null -ne $g.rangeDb) { $sp.gateRangeDb = [math]::Abs([double]$g.rangeDb) }
    }
    $a = $canon.agc
    if ($a -and $null -ne $a.enabled) {
        $sp.agcOn = [bool]$a.enabled
        if ($null -ne $a.targetDb) { $sp.agcTargetDb = [double]$a.targetDb }
        if ($null -ne $a.maxGainDb) { $sp.agcMaxGainDb = [double]$a.maxGainDb }
    }
    $d = $canon.deEsser
    if ($d -and $null -ne $d.enabled) {
        $sp.deessOn = [bool]$d.enabled
        if ($null -ne $d.frequencyHz) { $sp.deessFreqHz = [double]$d.frequencyHz }
        if ($null -ne $d.thresholdDb) { $sp.deessThreshDb = [double]$d.thresholdDb }
        if ($null -ne $d.rangeDb) { $sp.deessRangeDb = [math]::Abs([double]$d.rangeDb) }
    }
    if ($sp.Count -eq 0) { $p.Remove('speech') }

    # --- Plate reverb ---
    $r = $canon.reverb
    if ($r -and $null -ne $r.enabled) {
        if (-not $p.Contains('plate') -or $null -eq $p.plate) { $p.plate = [ordered]@{} }
        $p.plate.bypass = -not [bool]$r.enabled
        if ($null -ne $r.sizePercent) { $p.plate.size = [double]$r.sizePercent }
        if ($null -ne $r.dampPercent) { $p.plate.damp = [double]$r.dampPercent }
        if ($null -ne $r.preDelayMs) { $p.plate.preDelayMs = [double]$r.preDelayMs }
        if ($null -ne $r.mixPercent) { $p.plate.mix = [math]::Round([double]$r.mixPercent / 100, 3) }
        if ($r.enabled -and $origin -ne 'Lyra') { Add-Note $canon 'reverb -> Lyra plate: size, damping, pre-delay and mix carried; decay set by ear.' 'DarkGray' }
    }

    # --- Single-band compressor -> Combinator (opt-in) ---
    $cp = $canon.compressor
    if ($origin -ne 'Lyra' -and $cp -and $cp.enabled) {
        if ([bool](Get-SdrOption $rules 'Lyra' 'compressorToCombinator' $false) -and $p.combinator) {
            $cb = $p.combinator; $cb.bypass = $false
            foreach ($m in @(@('thresholdDb', 'threshDb'), @('ratio', 'ratio'), @('attackMs', 'attackMs'), @('releaseMs', 'releaseMs'), @('makeupDb', 'makeupDb'))) { if ($null -ne $cp[$m[0]]) { $cb[$m[1]] = [double]$cp[$m[0]] } }
            foreach ($b in @($cb.bands)) { $b.en = $true; $b.thr = 0; $b.gain = 0 }
            Add-Note $canon "single-band compressor -> Lyra Combinator with every band at the same threshold (option Lyra.compressorToCombinator) - a multiband approximation." 'Yellow'
        } else { Add-Note $canon "source compressor is ON (thr $($cp.thresholdDb) dB, $($cp.ratio):1) - not carried; Lyra's closest stage is the Combinator (option Lyra.compressorToCombinator = true)." }
    }
    if ($origin -ne 'Lyra' -and $p.combinator -and -not $p.combinator.bypass -and -not ($cp -and $cp.enabled)) { Add-Note $canon "the Lyra Combinator in this profile's template is ON and was left as it is." 'Yellow' }

    # --- stages Lyra doesn't have ---
    $miss = @()
    if ($canon.cfc.enabled) { $miss += 'CFC (the Combinator is the closest)' }
    if ($canon.compander.enabled) { $miss += 'compander / PROC' }
    if ($canon.cessb.enabled) { $miss += 'CESSB' }
    if ($canon.multiband -and $canon.multiband.enabled) { $miss += 'multiband compression (its makeup tone is in the EQ)' }
    if ($canon.limiter -and $canon.limiter.enabled) { $miss += 'brickwall limiter (the ALC is the closest)' }
    foreach ($u in @('exciter', 'bassEnhancer', 'saturation')) { if ($canon[$u] -and $canon[$u].enabled) { $miss += $u } }
    if ($miss.Count) { Add-Note $canon ('Lyra has no stage for: ' + ($miss -join '; ') + '.') }

    if ($canon.destSet) { foreach ($k in $canon.destSet.Keys) { Set-HtPath $p $k (Copy-Deep $canon.destSet[$k]); Write-Log "    rules destSet: $k = $($canon.destSet[$k])" DarkGray } }
    return $p
}

function ConvertTo-LyraJson {
    param($p)
    $json = $p | ConvertTo-Json -Depth 20 -Compress
    # ASCII only (registry and .lyra are both fine with \u escapes; Qt's JSON reader decodes them)
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

function Show-LyraPreview {
    param($jobs, $rules)
    Write-Log ""; Write-Log "  Lyra preview (nothing written):" Cyan
    foreach ($j in $jobs) {
        Write-Log "  $($j.Dst)" White
        try { $p = ConvertTo-LyraProfile $j.Canon $j.Dst $rules; Write-JsonFile $p (Join-Path $script:RunDir (($j.Dst -replace '[\\/:*?"<>|]', '_') + '.3-lyra-preview.json')) }
        catch { Write-Log "    preview failed: $($_.Exception.Message)" Red }
    }
}

function Lyra_BeginWrite {
    param([switch]$ForceExport)
    $script:Ly.Export = $ForceExport -or ($script:Ly.Mode -ne 'registry') -or (Test-ProcRunning @('lyra'))
    $script:Ly.OutDir = Join-Path $env:USERPROFILE 'Documents\SdrConvert\Lyra'
    if ($script:Ly.Export) { Write-Log "  Lyra: writing a .lyra file to restore in Lyra ($($script:Ly.OutDir))" Yellow; return }
    # Registry backup: reg export of the whole Lyra key, beside the run log and in Backups\.
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bdir = Join-Path $env:USERPROFILE "Documents\SdrConvert\Backups\Lyra_$stamp"
    New-Item -ItemType Directory -Path $bdir -Force | Out-Null
    $reg = Join-Path $bdir "$(Split-Path $script:Ly.Sub -Leaf).reg"
    & reg.exe export ($script:Ly.Where) $reg /y | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $reg)) { throw "Could not back up $($script:Ly.Where) with reg export - nothing written." }
    Copy-Item $reg (Join-Path $script:RunDir 'Lyra.before.reg') -Force
    Set-Content (Join-Path $bdir 'RESTORE.txt') @"
Lyra registry backup taken by SdrConvert on $(Get-Date -Format 's').
To restore: close Lyra, then double-click $(Split-Path $reg -Leaf) (or run: reg import "$reg").
reg import puts every saved value back; profiles added after this backup stay until you delete them in Lyra.
"@ -Encoding UTF8
    Write-Log "  Backup: $reg" DarkGray
}

function Lyra_Write {
    param($canon, [string]$DestName, $rules, [switch]$Review)
    if ($DestName -match '[\\/]') { throw "Lyra profile names can't contain '/' or '\' (Qt reads them as key separators)." }
    if ($DestName -eq '.') { throw "'.' isn't a usable Lyra profile name." }
    $isNew = -not $script:Ly.Items.Contains($DestName)
    $new = ConvertTo-LyraProfile $canon $DestName $rules
    $old = if ($isNew) { $null } else { Get-LyraProfile $DestName }
    $changes = New-Object System.Collections.ArrayList
    foreach ($k in $new.Keys) {
        $nj = ($new[$k] | ConvertTo-Json -Depth 20 -Compress)
        $oj = if ($old -and $old.Contains($k)) { ($old[$k] | ConvertTo-Json -Depth 20 -Compress) } else { $null }
        if ($nj -ne $oj) { [void]$changes.Add(@{ Key = $k; Old = $oj; New = $nj }) }
    }
    $sel = Select-Changes $changes $DestName -Review:$Review
    $final = if ($old) { $old } else { Copy-Deep $new }
    if ($old) { foreach ($ch in $sel) { $final[$ch.Key] = $new[$ch.Key] } }
    if ($sel.Count -gt 0 -or $isNew) {
        $script:Ly.Items[$DestName] = ConvertTo-LyraJson $final
        if (-not $script:Ly.Dirty.Contains($DestName)) { [void]$script:Ly.Dirty.Add($DestName) }
        if ($script:Ly.Order -notcontains $DestName) { $script:Ly.Order = @($script:Ly.Order) + $DestName }
    }
    return @{ Changed = $sel.Count; Total = $changes.Count; New = $isNew }
}

function Write-LyraExportFile {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    New-Item -ItemType Directory -Path $script:Ly.OutDir -Force | Out-Null
    $path = Join-Path $script:Ly.OutDir "SdrConvert_$stamp.lyra"
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('[_backup]'); [void]$lines.Add("automatic=false")
    [void]$lines.Add("created=$((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'))"); [void]$lines.Add("name=SdrConvert $stamp")
    [void]$lines.Add(''); [void]$lines.Add('[profiles]')
    foreach ($n in $script:Ly.Dirty) {
        $kn = if ($n -eq 'Default') { '.' } else { $n }
        [void]$lines.Add("item\$(ConvertTo-QtIniKey $kn)=$(ConvertTo-QtIniString $script:Ly.Items[$n])")
    }
    $ord = @(Get-LyraNames)
    [void]$lines.Add("order=$((@($ord | ForEach-Object { ConvertTo-QtIniString $_ })) -join ', ')")
    [IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Lyra_EndWrite {
    param([string]$ActiveName, $rules)
    if ($script:Ly.Dirty.Count -eq 0) { Write-Log "  Lyra: nothing to save." DarkGray; return }
    if ($script:Ly.Export) {
        $f = Write-LyraExportFile
        Copy-Item $f (Join-Path $script:RunDir (Split-Path $f -Leaf)) -Force
        Write-Log "  Saved $f" Green
        Write-Log "  In Lyra: Settings -> Backup & Restore -> Restore from file... -> pick this file -> tick only 'TX / RX profiles' -> Restore." Cyan
    } else {
        $ik = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$($script:Ly.Sub)\profiles\item")
        $pk = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$($script:Ly.Sub)\profiles")
        try {
            foreach ($n in $script:Ly.Dirty) {
                $vn = if ($n -eq 'Default') { '' } else { $n }
                $ik.SetValue($vn, [string]$script:Ly.Items[$n], [Microsoft.Win32.RegistryValueKind]::String)
                if ([string]$ik.GetValue($vn) -ne [string]$script:Ly.Items[$n]) { throw "read-back of Lyra profile '$n' didn't match what was written" }
            }
            $pk.SetValue('order', [string[]]@(Get-LyraNames), [Microsoft.Win32.RegistryValueKind]::MultiString)
        } finally { $ik.Close(); $pk.Close() }
        Write-Log "  Saved $($script:Ly.Dirty.Count) profile(s) to $($script:Ly.Where)\profiles" Green
    }
    $act = @($script:Ly.Dirty | Where-Object { $_ -eq $script:Ly.Active })
    Write-Log "  Lyra applies a profile when you load it: open the profile list and Load '$(@($script:Ly.Dirty)[0])'$(if ($act.Count) { " (it is the active profile, so Lyra will show it as modified until you load it)" })." Cyan
}
