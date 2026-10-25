# lib/Common.ps1 - shared plumbing for SdrConvert
# Logging, invariant number handling, PCHIP / natural-spline resampling, the
# Thetis/Nereus gzip+base64url blob envelope, the canonical profile model,
# the rules engine and console menus. Dot-sourced by Convert-SdrProfile.ps1.
# PowerShell 5.1 compatible (no ?., ??, ternary, -AsHashtable).

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Initialize-SdrLog {
    param([string]$Name)
    $root = Join-Path $env:USERPROFILE "Documents\SdrConvert\Logs"
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:RunDir  = Join-Path $root "${Name}_$stamp"
    New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
    $script:LogPath = Join-Path $script:RunDir "$Name.log"
}
function Write-Log {
    param([string]$m = "", [string]$c = "White")
    if ($script:LogPath) { Add-Content -Path $script:LogPath -Value "[$(Get-Date -Format 'HH:mm:ss')] $m" -Encoding UTF8 }
    Write-Host $m -ForegroundColor $c
}
function Write-Head { param([string]$t) Write-Log ""; Write-Log ("=" * 56) Cyan; Write-Log " $t" Cyan; Write-Log ("=" * 56) Cyan }

# ---------------------------------------------------------------------------
# Numbers (always invariant culture - Thetis/Nereus files use '.')
# ---------------------------------------------------------------------------
function ConvertTo-Num {
    param($s, $default = $null)
    if ($null -eq $s) { return $default }
    if ($s -is [double] -or $s -is [int] -or $s -is [long] -or $s -is [decimal] -or $s -is [single]) { return [double]$s }
    $v = 0.0
    if ([double]::TryParse([string]$s, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$v)) { return $v }
    return $default
}
function ConvertTo-BoolVal {
    param($s, $default = $null)
    if ($null -eq $s) { return $default }
    if ($s -is [bool]) { return $s }
    $t = ([string]$s).Trim()
    if ($t -match '^(true|1)$') { return $true }
    if ($t -match '^(false|0)$') { return $false }
    return $default
}
function Format-Num {
    param([double]$v, [int]$digits = 4)
    $r = [math]::Round($v, $digits)
    if ($r -eq [math]::Truncate($r)) { return ([long]$r).ToString($script:Inv) }
    return $r.ToString("0.####", $script:Inv)
}
function Format-Bool { param([bool]$b) if ($b) { "True" } else { "False" } }
function Clamp { param([double]$v, [double]$lo, [double]$hi) [math]::Max($lo, [math]::Min($hi, $v)) }

# ---------------------------------------------------------------------------
# Hashtable helpers (JSON -> nested hashtables, dotted path get/set)
# ---------------------------------------------------------------------------
function ConvertTo-HT {
    param($o)
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}; foreach ($k in $o.Keys) { $h[$k] = ConvertTo-HT $o[$k] }; return $h
    }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-HT $p.Value }; return $h
    }
    if ($o -is [System.Collections.IEnumerable] -and -not ($o -is [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($i in $o) { [void]$list.Add((ConvertTo-HT $i)) }
        return ,($list.ToArray())
    }
    return $o
}
function Read-JsonFile {
    param([string]$Path)
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    return ConvertTo-HT ($raw | ConvertFrom-Json)
}
function Write-JsonFile {
    param($Object, [string]$Path)
    $json = $Object | ConvertTo-Json -Depth 20
    # Write UTF-8 without BOM (Qt's JSON reader is fine either way, but stay clean)
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-HtPath {
    param($ht, [string]$path)
    $cur = $ht
    foreach ($seg in $path.Split('.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) { if ($cur.Contains($seg)) { $cur = $cur[$seg] } else { return $null } }
        else { return $null }
    }
    return $cur
}
function Set-HtPath {
    param($ht, [string]$path, $value)
    $segs = $path.Split('.')
    $cur = $ht
    for ($i = 0; $i -lt $segs.Count - 1; $i++) {
        $s = $segs[$i]
        if (-not $cur.Contains($s) -or $null -eq $cur[$s] -or -not ($cur[$s] -is [System.Collections.IDictionary])) { $cur[$s] = [ordered]@{} }
        $cur = $cur[$s]
    }
    $cur[$segs[-1]] = $value
}
function Copy-Deep { param($o) if ($null -eq $o) { return $null }; return ConvertTo-HT (($o | ConvertTo-Json -Depth 20) | ConvertFrom-Json) }

# ---------------------------------------------------------------------------
# Interpolation
#   PCHIP (Fritsch-Carlson) never overshoots the source data - default for
#   sparse / uneven curves (fixes the +4.6 / +5 dB artefacts seen with the
#   natural spline on the VMP G6 curve).
#   Natural cubic spline kept for parity with the validated legacy CFC paths.
# ---------------------------------------------------------------------------
function Get-SortedCurve {
    # Returns @{x=[double[]]; y=[double[]]; q=[double[]]} sorted by freq, duplicate freqs collapsed (last wins)
    param($points, [string]$field = 'gainDb')
    $map = New-Object 'System.Collections.Generic.SortedDictionary[double,object]'
    foreach ($p in $points) {
        if ($null -eq $p) { continue }
        $f = ConvertTo-Num $p.freqHz; if ($null -eq $f) { continue }
        $map[$f] = $p
    }
    $x = @(); $y = @(); $q = @()
    foreach ($kv in $map.GetEnumerator()) {
        $x += [double]$kv.Key
        $y += [double](ConvertTo-Num $kv.Value[$field] 0.0)
        $q += [double](ConvertTo-Num $kv.Value['q'] 1.0)
    }
    return @{ x = [double[]]$x; y = [double[]]$y; q = [double[]]$q }
}
function Get-PchipSlopes {
    param([double[]]$x, [double[]]$y)
    $n = $x.Count
    $d = New-Object double[] $n
    if ($n -lt 2) { return $d }
    $h = New-Object double[] ($n - 1); $delta = New-Object double[] ($n - 1)
    for ($i = 0; $i -lt $n - 1; $i++) { $h[$i] = $x[$i + 1] - $x[$i]; $delta[$i] = ($y[$i + 1] - $y[$i]) / $h[$i] }
    if ($n -eq 2) { $d[0] = $delta[0]; $d[1] = $delta[0]; return $d }
    for ($i = 1; $i -lt $n - 1; $i++) {
        if ($delta[$i - 1] * $delta[$i] -le 0) { $d[$i] = 0 }
        else { $w1 = 2 * $h[$i] + $h[$i - 1]; $w2 = $h[$i] + 2 * $h[$i - 1]; $d[$i] = ($w1 + $w2) / ($w1 / $delta[$i - 1] + $w2 / $delta[$i]) }
    }
    $ends = @(@(0, 0, 1, 0, 1), @(($n - 1), ($n - 2), ($n - 3), ($n - 2), ($n - 3)))
    foreach ($e in $ends) {
        $h0 = $h[$e[1]]; $h1 = $h[$e[2]]; $d0 = $delta[$e[3]]; $d1 = $delta[$e[4]]
        $s = ((2 * $h0 + $h1) * $d0 - $h0 * $d1) / ($h0 + $h1)
        if ([math]::Sign($s) -ne [math]::Sign($d0)) { $s = 0 }
        elseif (([math]::Sign($d0) -ne [math]::Sign($d1)) -and ([math]::Abs($s) -gt [math]::Abs(3 * $d0))) { $s = 3 * $d0 }
        $d[$e[0]] = $s
    }
    return $d
}
function Get-PchipValue {
    param([double]$xq, [double[]]$x, [double[]]$y, [double[]]$d)
    $n = $x.Count
    if ($n -eq 0) { return 0.0 }
    if ($n -eq 1 -or $xq -le $x[0]) { return $y[0] }
    if ($xq -ge $x[$n - 1]) { return $y[$n - 1] }
    for ($i = 0; $i -lt $n - 1; $i++) {
        if ($xq -ge $x[$i] -and $xq -le $x[$i + 1]) {
            $h = $x[$i + 1] - $x[$i]; $t = ($xq - $x[$i]) / $h
            $t2 = $t * $t; $t3 = $t2 * $t
            return (2 * $t3 - 3 * $t2 + 1) * $y[$i] + ($t3 - 2 * $t2 + $t) * $h * $d[$i] + (-2 * $t3 + 3 * $t2) * $y[$i + 1] + ($t3 - $t2) * $h * $d[$i + 1]
        }
    }
    return $y[$n - 1]
}
function Get-SplineValue {
    # Natural cubic spline; clamps (holds end values) outside the data range
    param([double]$xq, [double[]]$x, [double[]]$y)
    $n = $x.Count
    if ($n -eq 0) { return 0.0 }
    if ($n -eq 1 -or $xq -le $x[0]) { return $y[0] }
    if ($xq -ge $x[$n - 1]) { return $y[$n - 1] }
    if ($n -eq 2) { return $y[0] + ($y[1] - $y[0]) * ($xq - $x[0]) / ($x[1] - $x[0]) }
    $h = New-Object double[] ($n - 1); for ($i = 0; $i -lt $n - 1; $i++) { $h[$i] = $x[$i + 1] - $x[$i] }
    $sz = $n - 2
    $diag = New-Object double[] $sz; $rhs = New-Object double[] $sz
    for ($i = 0; $i -lt $sz; $i++) { $diag[$i] = 2.0 * ($h[$i] + $h[$i + 1]); $rhs[$i] = 6.0 * (($y[$i + 2] - $y[$i + 1]) / $h[$i + 1] - ($y[$i + 1] - $y[$i]) / $h[$i]) }
    $c2 = New-Object double[] $sz; $d2 = New-Object double[] $sz
    $c2[0] = if ($sz -gt 1) { $h[1] / $diag[0] } else { 0 }; $d2[0] = $rhs[0] / $diag[0]
    for ($i = 1; $i -lt $sz; $i++) {
        $m = $diag[$i] - $h[$i] * $c2[$i - 1]
        $d2[$i] = ($rhs[$i] - $h[$i] * $d2[$i - 1]) / $m
        if ($i -lt $sz - 1) { $c2[$i] = $h[$i + 1] / $m }
    }
    $M = New-Object double[] $n
    $M[$sz] = $d2[$sz - 1]
    for ($i = $sz - 2; $i -ge 0; $i--) { $M[$i + 1] = $d2[$i] - $c2[$i] * $M[$i + 2] }
    for ($i = 0; $i -lt $n - 1; $i++) {
        if ($xq -ge $x[$i] -and $xq -le $x[$i + 1]) {
            $dx = $xq - $x[$i]
            $b = ($y[$i + 1] - $y[$i]) / $h[$i] - $h[$i] * (2.0 * $M[$i] + $M[$i + 1]) / 6.0
            return $y[$i] + $b * $dx + ($M[$i] / 2.0) * $dx * $dx + (($M[$i + 1] - $M[$i]) / (6.0 * $h[$i])) * $dx * $dx * $dx
        }
    }
    return $y[$n - 1]
}
function Resample-Curve {
    # Evaluate a canonical point list at target freqs. Returns [double[]].
    # -Method pchip|spline ; -Field gainDb|q|compDb|postDb
    param($Points, [double[]]$Freqs, [string]$Method = 'pchip', [string]$Field = 'gainDb')
    $c = Get-SortedCurve $Points $Field
    $vals = if ($Field -eq 'q') { $c.q } else { $c.y }
    $out = New-Object double[] $Freqs.Count
    if ($c.x.Count -eq 0) { return $out }
    $slopes = $null
    if ($Method -eq 'pchip') { $slopes = Get-PchipSlopes $c.x $vals }
    for ($i = 0; $i -lt $Freqs.Count; $i++) {
        if ($Method -eq 'pchip') { $out[$i] = Get-PchipValue $Freqs[$i] $c.x $vals $slopes }
        else { $out[$i] = Get-SplineValue $Freqs[$i] $c.x $vals }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Thetis / NereusSDR blob envelope: JSON -> gzip -> base64url (no padding).
# Confirmed identical in both apps (NereusSDR ParaEqEnvelope.cpp cites Thetis
# Common.cs:1747-1759). CFC blobs hold two curves joined by "<SEP>".
# ---------------------------------------------------------------------------
function ConvertFrom-SdrBlob {
    param([string]$blob)
    if ([string]::IsNullOrWhiteSpace($blob) -or $blob.Length -lt 8) { return $null }
    $b64 = ($blob -replace '\s', '').Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) { 2 { $b64 += '==' } 3 { $b64 += '=' } }
    try {
        $ms = New-Object System.IO.MemoryStream(, [Convert]::FromBase64String($b64))
        $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
        $sr = New-Object System.IO.StreamReader($gz)
        $t = $sr.ReadToEnd(); $sr.Close(); return $t
    } catch { return $null }
}
function ConvertTo-SdrBlob {
    param([string]$text)
    $ms = New-Object System.IO.MemoryStream
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
    $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
    return ([Convert]::ToBase64String($ms.ToArray())).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}
function Get-BiquadDb {
    # Magnitude (dB) of one conventional (RBJ-cookbook style) EQ band at f Hz,
    # as Zeus and AetherSDR define it: width scales with frequency, Q is relative.
    # Analog prototype; at voice frequencies (<5 kHz, 48 kHz rate) the digital
    # warp is negligible. HighPass/LowPass are Butterworth of order slope/6.
    param([string]$type, [double]$f0, [double]$gainDb, [double]$q, [int]$slope, [double]$f)
    if ($f0 -le 0 -or $f -le 0) { return 0.0 }
    $w = $f / $f0
    switch ($type) {
        'HighPass' { $n = [math]::Max(1, [int][math]::Round($slope / 6)); return -10 * [math]::Log10(1 + [math]::Pow(1 / $w, 2 * $n)) }
        'LowPass'  { $n = [math]::Max(1, [int][math]::Round($slope / 6)); return -10 * [math]::Log10(1 + [math]::Pow($w, 2 * $n)) }
    }
    if ($gainDb -eq 0) { return 0.0 }
    if ($q -le 0) { $q = 0.707 }
    $A = [math]::Pow(10, $gainDb / 40); $w2 = $w * $w
    switch ($type) {
        'LowShelf' {
            $k = [math]::Sqrt($A) / $q * $w
            $num = ($A - $w2) * ($A - $w2) + $k * $k; $den = (1 - $A * $w2) * (1 - $A * $w2) + $k * $k
            return 20 * [math]::Log10($A) + 10 * [math]::Log10($num / $den)
        }
        'HighShelf' {
            $k = [math]::Sqrt($A) / $q * $w
            $num = (1 - $A * $w2) * (1 - $A * $w2) + $k * $k; $den = ($A - $w2) * ($A - $w2) + $k * $k
            return 20 * [math]::Log10($A) + 10 * [math]::Log10($num / $den)
        }
        default {
            $num = (1 - $w2) * (1 - $w2) + [math]::Pow($w * $A / $q, 2); $den = (1 - $w2) * (1 - $w2) + [math]::Pow($w / ($A * $q), 2)
            return 10 * [math]::Log10($num / $den)
        }
    }
}

function Solve-LinearSystem {
    # Gaussian elimination with partial pivoting: returns x for M x = b.
    param([double[,]]$M, [double[]]$b)
    $n = $b.Length
    $a = New-Object 'double[,]' $n, ($n + 1)
    for ($i = 0; $i -lt $n; $i++) { for ($j = 0; $j -lt $n; $j++) { $a[$i, $j] = $M[$i, $j] }; $a[$i, $n] = $b[$i] }
    for ($col = 0; $col -lt $n; $col++) {
        $piv = $col; for ($r = $col + 1; $r -lt $n; $r++) { if ([math]::Abs($a[$r, $col]) -gt [math]::Abs($a[$piv, $col])) { $piv = $r } }
        if ($piv -ne $col) { for ($j = 0; $j -le $n; $j++) { $t = $a[$col, $j]; $a[$col, $j] = $a[$piv, $j]; $a[$piv, $j] = $t } }
        $d = $a[$col, $col]; if ([math]::Abs($d) -lt 1e-12) { continue }
        for ($r = 0; $r -lt $n; $r++) {
            if ($r -eq $col) { continue }
            $fct = $a[$r, $col] / $d
            if ($fct -ne 0) { for ($j = $col; $j -le $n; $j++) { $a[$r, $j] -= $fct * $a[$col, $j] } }
        }
    }
    return [double[]]@(for ($i = 0; $i -lt $n; $i++) { if ([math]::Abs($a[$i, $i]) -lt 1e-12) { 0.0 } else { $a[$i, $n] / $a[$i, $i] } })
}

function ConvertFrom-CurveJson {
    # Thetis ucParametricEq JSON -> canonical curve
    param([string]$json)
    try { $o = $json | ConvertFrom-Json } catch { return $null }
    if ($null -eq $o -or $null -eq $o.points) { return $null }
    $pts = @(foreach ($p in $o.points) { @{ freqHz = [double]$p.frequency_hz; gainDb = [double]$p.gain_db; q = [double](ConvertTo-Num $p.q 4.0) } })
    if ($pts.Count -lt 2) { return $null }
    return [ordered]@{
        parametric   = [bool]$o.parametric_eq
        globalGainDb = [double](ConvertTo-Num $o.global_gain_db 0.0)
        freqMinHz    = [double](ConvertTo-Num $o.frequency_min_hz 0.0)
        freqMaxHz    = [double](ConvertTo-Num $o.frequency_max_hz ($pts[-1].freqHz))
        points       = $pts
        useQ         = [bool]$o.parametric_eq
    }
}
function ConvertTo-CurveJson {
    # canonical curve -> Thetis/Nereus JSON. Enforces NereusSDR's reader rules
    # (ParaEqCurve.cpp readCurveJson): band_count == points, 2..256 points,
    # max > min; plus TX panel limits gain +/-24 dB, Q 0.2..20.
    param($curve)
    $c = Get-SortedCurve $curve.points 'gainDb'
    $n = $c.x.Count
    if ($n -lt 2) { return $null }
    if ($n -gt 256) { throw "curve has $n points (max 256)" }
    $minHz = ConvertTo-Num $curve.freqMinHz $c.x[0]; if ($minHz -gt $c.x[0]) { $minHz = $c.x[0] }
    $maxHz = ConvertTo-Num $curve.freqMaxHz $c.x[$n - 1]; if ($maxHz -lt $c.x[$n - 1]) { $maxHz = $c.x[$n - 1] }
    if ($maxHz -le $minHz) { $maxHz = $minHz + 1000 }
    $pts = for ($i = 0; $i -lt $n; $i++) {
        [ordered]@{ frequency_hz = [math]::Round($c.x[$i], 3); gain_db = [math]::Round((Clamp $c.y[$i] -24 24), 1); q = [math]::Round((Clamp $c.q[$i] 0.2 20), 2) }
    }
    $o = [ordered]@{
        band_count       = $n
        parametric_eq    = [bool]$curve.parametric
        global_gain_db   = [double](ConvertTo-Num $curve.globalGainDb 0.0)
        frequency_min_hz = [math]::Round($minHz, 3)
        frequency_max_hz = [math]::Round($maxHz, 3)
        points           = @($pts)
    }
    return ($o | ConvertTo-Json -Depth 5 -Compress)
}
function Test-CurveFlat { param($curve) if ($null -eq $curve) { return $true }; foreach ($p in $curve.points) { if ([math]::Abs([double]$p.gainDb) -gt 0.01) { return $false } }; return $true }

# ---------------------------------------------------------------------------
# Canonical profile model
#   Any field left $null means "source did not say" - writers leave the
#   destination's existing value alone (or use a documented default).
# ---------------------------------------------------------------------------
function New-Canon {
    param([string]$Name, [string]$App)
    return [ordered]@{
        schema       = 'SdrConvert.Canonical/1'
        name         = $Name
        source       = [ordered]@{ app = $App; profile = $Name; readAt = (Get-Date).ToUniversalTime().ToString('o') }
        filter       = [ordered]@{ lowHz = $null; highHz = $null }
        mic          = [ordered]@{ gainDb = $null; boost = $null; lineInOn = $null; lineInLevel = $null }
        leveler      = [ordered]@{ enabled = $null; maxGainDb = $null; decayMs = $null }
        alc          = [ordered]@{ maxGainDb = $null; decayMs = $null }
        compander    = [ordered]@{ enabled = $null; level = $null }
        cessb        = [ordered]@{ enabled = $null }
        am           = [ordered]@{ carrierLevel = $null }
        dexp         = [ordered]@{ enabled = $null; thresholdDb = $null; expansionDb = $null; hysteresisDb = $null; tauMs = $null; attackMs = $null; releaseMs = $null; lookAheadOn = $null; lookAheadMs = $null; scfOn = $null; scfLowHz = $null; scfHighHz = $null }
        vox          = [ordered]@{ enabled = $null; hangMs = $null }
        # txEq.mode: 'legacy' = 10-band graphic (legacy[] authoritative)
        #            'parametric' = curve authoritative (any number of points)
        txEq         = [ordered]@{ enabled = $null; preampDb = $null; outputDb = $null; mode = $null; legacy = $null; curve = $null }
        # cfc.legacy: 10 x @{freqHz; compDb; postDb}; compCurve/postCurve: canonical curves
        cfc          = [ordered]@{ enabled = $null; postEqEnabled = $null; mode = $null; preCompDb = $null; prePeqDb = $null; postEqGainDb = $null; legacy = $null; compCurve = $null; postCurve = $null }
        phaseRotator = [ordered]@{ enabled = $null; cornerHz = $null; stages = $null; reverse = $null }
        compressor   = [ordered]@{ enabled = $null; thresholdDb = $null; ratio = $null; attackMs = $null; releaseMs = $null; kneeDb = $null; makeupDb = $null }
        noiseGate    = [ordered]@{ enabled = $null; thresholdDb = $null; attackMs = $null; holdMs = $null; releaseMs = $null; rangeDb = $null; outputDb = $null }
        rxEq         = $null   # @{ enabled; masterGainDb; points=@(@{freqHz;gainDb;q}) }
        # Single-chain processing units (read from Zeus native units; written to AetherTX).
        # $null = source has no such unit. See lib/Zeus.ps1 Zeus_Read for the field lists.
        inputStrip   = $null
        deEsser      = $null
        agc          = $null
        multiband    = $null
        saturation   = $null
        exciter      = $null
        bassEnhancer = $null
        reverb       = $null
        limiter      = $null
        otherUnitsOn = @()
        chainOrder   = $null
        # extraEq: a correction curve to CASCADE on top of the destination's EQ
        # (summed in dB) - used for single-EQ destinations (Aether) where a
        # retired upstream EQ (VMP G6) must be folded into the one EQ stage.
        extraEq      = $null   # @{ points=@(...); method='pchip'; label }
        dsp          = [ordered]@{}
        notes        = New-Object System.Collections.ArrayList
    }
}
function Add-Note { param($canon, [string]$text, [string]$c = 'Yellow') [void]$canon.notes.Add($text); Write-Log "    [NOTE] $text" $c }

function Get-TxEqPoints {
    # Effective TX EQ shape as canonical points, honoring txEq.mode
    param($canon)
    $e = $canon.txEq
    if ($e.mode -eq 'parametric' -and $e.curve) { return @($e.curve.points) }
    if ($e.legacy) { return @(foreach ($b in $e.legacy) { @{ freqHz = $b.freqHz; gainDb = $b.gainDb; q = 1.0 } }) }
    if ($e.curve) { return @($e.curve.points) }
    return @()
}
function Get-CfcPoints {
    # half = 'comp' | 'post'
    param($canon, [string]$half)
    $c = $canon.cfc
    $curve = if ($half -eq 'comp') { $c.compCurve } else { $c.postCurve }
    if ($c.mode -eq 'parametric' -and $curve) { return @($curve.points) }
    if ($c.legacy) {
        $field = if ($half -eq 'comp') { 'compDb' } else { 'postDb' }
        return @(foreach ($b in $c.legacy) { @{ freqHz = $b.freqHz; gainDb = $b[$field]; q = 1.0 } })
    }
    if ($curve) { return @($curve.points) }
    return @()
}

# ---------------------------------------------------------------------------
# Rules engine (SdrConvert.rules.json)
# ---------------------------------------------------------------------------
function Import-SdrRules {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return [ordered]@{ rules = @(); options = [ordered]@{} } }
    $r = Read-JsonFile $Path
    if (-not $r.Contains('rules')) { $r['rules'] = @() }
    if (-not $r.Contains('options')) { $r['options'] = [ordered]@{} }
    return $r
}
function Get-SdrOption {
    param($rules, [string]$app, [string]$key, $default)
    $o = $rules.options
    if ($o -and $o.Contains($app) -and $o[$app].Contains($key)) { return $o[$app][$key] }
    return $default
}
function Invoke-SdrRules {
    # Applies every enabled rule matching (dest app, source app, profile name). Returns applied ids.
    param($canon, $rules, [string]$DestApp, [string]$SourceApp, [string]$ProfileName)
    $applied = @()
    foreach ($r in $rules.rules) {
        if ($r.Contains('enabled') -and -not $r.enabled) { continue }
        $dest = if ($r.Contains('dest')) { $r.dest } else { '*' }
        $src  = if ($r.Contains('source')) { $r.source } else { '*' }
        $match = if ($r.Contains('match')) { $r.match } else { '*' }
        $srcOk = @(@($src) | Where-Object { $SourceApp -like $_ }).Count -gt 0
        if ($DestApp -notlike $dest -or -not $srcOk -or $ProfileName -notlike $match) { continue }
        if ($r.Contains('exclude') -and $r.exclude -and $ProfileName -like $r.exclude) { continue }
        if ($r.Contains('eqBaseline') -and $r.eqBaseline) {
            $b = $r.eqBaseline
            $pts = @(foreach ($p in $b.points) { @{ freqHz = [double]$p.freqHz; gainDb = [double]$p.gainDb; q = [double](ConvertTo-Num $p.q 1.0) } })
            $target = if ($b.Contains('target')) { $b.target } else { 'replace' }
            if ($target -eq 'cascade') {
                $canon.extraEq = [ordered]@{ points = $pts; method = $(if ($b.Contains('method')) { $b.method } else { 'pchip' }); label = $r.id }
                $applied += $r.id
                if ($r.Contains('set') -and $r.set) { foreach ($k in $r.set.Keys) { Set-HtPath $canon $k (Copy-Deep $r.set[$k]) } }
                continue
            }
            $canon.txEq.mode = 'parametric'
            $canon.txEq.curve = [ordered]@{
                parametric = $true; globalGainDb = 0.0; useQ = [bool]$b.useQ
                interp = if ($b.Contains('method')) { $b.method } else { 'pchip' }
                points = $pts
                freqMinHz = $null; freqMaxHz = $null
            }
        }
        if ($r.Contains('set') -and $r.set) {
            foreach ($k in $r.set.Keys) { Set-HtPath $canon $k (Copy-Deep $r.set[$k]) }
        }
        if ($r.Contains('destSet') -and $r.destSet) {
            # Raw destination fields (e.g. Aether 'comp.driveDb', 'finalLimiter.outputTrimDb',
            # or a NereusSDR key name), written as-is after the conversion.
            if (-not $canon.Contains('destSet') -or $null -eq $canon.destSet) { $canon.destSet = [ordered]@{} }
            foreach ($k in $r.destSet.Keys) { $canon.destSet[$k] = Copy-Deep $r.destSet[$k] }
        }
        $applied += $r.id
    }
    return $applied
}

# ---------------------------------------------------------------------------
# Process / menu helpers
# ---------------------------------------------------------------------------
function Test-ProcRunning { param([string[]]$Names) foreach ($n in $Names) { if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true } }; return $false }

function Select-Item {
    # Returns selected item(s). -Multi allows comma list / A. -AllowSkip returns $null on S.
    param([string]$Title, [object[]]$Items, [scriptblock]$Label = { param($i) "$i" }, [switch]$Multi, [switch]$AllowSkip, [string]$SkipText = 'Skip')
    Write-Log ""; Write-Log $Title Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ("  [{0,2}] {1}" -f ($i + 1), (& $Label $Items[$i])) }
    if ($Multi) { Write-Host "  [ A] All" }
    if ($AllowSkip) { Write-Host "  [ S] $SkipText" }
    while ($true) {
        $ans = (Read-Host "Choice").Trim()
        if ($AllowSkip -and $ans -match '^[Ss]$') { return $null }
        if ($Multi -and $ans -match '^[Aa]$') { return , $Items }
        $picked = @()
        foreach ($tok in ($ans -split ',')) {
            $n = 0
            if ([int]::TryParse($tok.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { $picked += $Items[$n - 1] }
        }
        if ($picked.Count -gt 0 -and ($Multi -or $picked.Count -eq 1)) { if ($Multi) { return , $picked } else { return $picked[0] } }
        Write-Host "  Invalid choice." -ForegroundColor Yellow
    }
}
function Confirm-Yes { param([string]$Prompt) return ((Read-Host "$Prompt (Y/N)") -match '^[Yy]') }

function Backup-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $bak = "$Path.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    Copy-Item -LiteralPath $Path -Destination (Join-Path $script:RunDir ((Split-Path $Path -Leaf) + '.before')) -Force
    Write-Log "  Backup: $bak" DarkGray
    return $bak
}

# Diff report for key/value style destinations (Thetis, Nereus)
function Show-ChangeSet {
    param([System.Collections.ArrayList]$Changes)
    foreach ($ch in $Changes) {
        $o = if ($null -eq $ch.Old) { '<absent>' } elseif ($ch.Old.Length -gt 40) { "<blob $($ch.Old.Length)>" } else { $ch.Old }
        $n = if ($ch.New.Length -gt 40) { "<blob $($ch.New.Length)>" } else { $ch.New }
        Write-Log ("    {0,-34} {1,-18} -> {2}" -f $ch.Key, $o, $n) White
    }
}
function Select-Changes {
    # W = all, C = challenge each, S = skip. Returns filtered list.
    param([System.Collections.ArrayList]$Changes, [string]$Profile, [switch]$Review)
    if ($Changes.Count -eq 0) { return , (New-Object System.Collections.ArrayList) }
    if (-not $Review) { return , $Changes }
    Show-ChangeSet $Changes
    $mode = Read-Host "  '$Profile': [W]holesale / [C]hallenge each / [S]kip"
    $out = New-Object System.Collections.ArrayList
    if ($mode -match '^[Ww]') { return , $Changes }
    if ($mode -match '^[Cc]') {
        foreach ($ch in $Changes) { if ((Read-Host "    $($ch.Key): apply? (Y/N)") -match '^[Yy]') { [void]$out.Add($ch) } }
    }
    return , $out
}
