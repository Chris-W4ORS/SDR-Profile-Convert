<#
.SYNOPSIS
  READ-ONLY inventory of Thetis / NereusSDR / Zeus / AetherSDR profile storage on this PC.
  Writes probe.txt + probe.json (+ decoded samples) to Documents\SdrConvert\Probe_<ts>\ and
  flags DRIFT wherever what's on disk no longer matches what Convert-SdrProfile.ps1 expects.
  Changes nothing: Zeus is only sent GET requests; no file is written outside the probe folder.
  Run it after every app update, and send the probe folder back when something drifts.
#>
[CmdletBinding()] param([switch]$NoZeusScrape)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\ThetisFamily.ps1')

$out = Join-Path $env:USERPROFILE "Documents\SdrConvert\Probe_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path (Join-Path $out 'samples') -Force | Out-Null
$script:LogPath = Join-Path $out 'probe.txt'; $script:RunDir = $out
$Report = [ordered]@{ probedAt = (Get-Date).ToString('o'); machine = $env:COMPUTERNAME; drift = New-Object System.Collections.ArrayList }
function Drift { param([string]$app, [string]$msg) [void]$Report.drift.Add("[$app] $msg"); Write-Log "  DRIFT: $msg" Red }
function Get-KeyPaths {
    # Flattened key paths of a JSON object: eq.bands[].gainDb
    param($o, [string]$pre = '')
    $acc = New-Object System.Collections.Generic.SortedSet[string]
    if ($o -is [System.Collections.IDictionary]) { foreach ($k in $o.Keys) { $p = if ($pre) { "$pre.$k" } else { $k }; [void]$acc.Add($p); foreach ($x in (Get-KeyPaths $o[$k] $p)) { [void]$acc.Add($x) } } }
    elseif ($o -is [array]) { foreach ($i in $o) { foreach ($x in (Get-KeyPaths $i "$pre[]")) { [void]$acc.Add($x) } } }
    return @($acc)
}
function Get-ExeVersion { param([string[]]$Globs) foreach ($g in $Globs) { foreach ($f in @(Get-ChildItem $g -ErrorAction SilentlyContinue)) { return @{ path = $f.FullName; version = $f.VersionInfo.ProductVersion; file = $f.VersionInfo.FileVersion } } }; return $null }
function Describe-Blob {
    param([string]$blob, [string]$label, [string]$app)
    $t = ConvertFrom-SdrBlob $blob; if (-not $t) { return $null }
    $parts = @($t -split '<SEP>'); $d = @()
    foreach ($p in $parts) { try { $o = ConvertTo-HT ($p | ConvertFrom-Json); $d += [ordered]@{ keys = @($o.Keys); band_count = $o.band_count; points = @($o.points).Count; pointKeys = @(@($o.points)[0].Keys); min = $o.frequency_min_hz; max = $o.frequency_max_hz; parametric = $o.parametric_eq } } catch { $d += 'unparseable JSON' } }
    Set-Content -Path (Join-Path $out "samples\$app-$label.json") -Value $t -Encoding UTF8
    return $d
}

Write-Head "SdrConvert store probe (read-only)"
Write-Log "Output: $out" DarkGray

# =============================================================================
Write-Head "Thetis"
$T = [ordered]@{}
$T.exe = Get-ExeVersion @("$env:ProgramFiles\OpenHPSDR\Thetis*\Thetis.exe", "$env:ProgramFiles\Thetis*\Thetis.exe", "${env:ProgramFiles(x86)}\OpenHPSDR\Thetis*\Thetis.exe")
$T.running = Test-ProcRunning @('Thetis')
$dbDirs = @(Get-ChildItem (Join-Path $env:APPDATA 'OpenHPSDR') -Directory -Filter 'Thetis*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'DB' } | Where-Object { Test-Path $_ })
$T.dbDirs = $dbDirs
if (-not $dbDirs) { Drift 'Thetis' 'no %APPDATA%\OpenHPSDR\Thetis*\DB folder' }
$T.radios = @()
foreach ($dm in @(foreach ($d in $dbDirs) { Get-ChildItem $d -Filter '*_dbman_settings.json' -ErrorAction SilentlyContinue })) {
    $r = [ordered]@{ dbman = $dm.FullName }
    try { $j = Get-Content $dm.FullName -Raw | ConvertFrom-Json; $r.dbmanKeys = @($j.PSObject.Properties.Name); $r.activeDb = $j.ActiveDB_File } catch { Drift 'Thetis' "dbman unreadable: $($dm.Name)" }
    $db = Join-Path $dm.DirectoryName ([string]$r.activeDb)
    if ($r.activeDb -and (Test-Path $db)) {
        $x = [IO.File]::ReadAllText($db); $r.dbBytes = $x.Length
        $blocks = @([regex]::Matches($x, '<TXProfile>([\s\S]*?)</TXProfile>') | ForEach-Object { $_.Groups[1].Value })
        $r.txProfiles = $blocks.Count
        if ($blocks.Count -eq 0) { Drift 'Thetis' "no <TXProfile> blocks in $db" }
        $r.names = @($blocks | ForEach-Object { ([regex]::Match($_, '<Name>([^<]*)</Name>')).Groups[1].Value })
        if (@($r.names | Where-Object { $_ }).Count -lt $blocks.Count) { Drift 'Thetis' 'some TXProfile blocks have no <Name> tag' }
        if ($x -match '<Key>comboTXProfile</Key>\s*<Value>([^<]+)</Value>') { $r.active = $matches[1] } else { Drift 'Thetis' 'comboTXProfile (active profile) key not found' }
        $tags = @{}; foreach ($b in $blocks) { foreach ($m in [regex]::Matches($b, '<([A-Za-z0-9_]+)>')) { $tags[$m.Groups[1].Value] = 1 + [int]$tags[$m.Groups[1].Value] } }
        $r.tagCount = $tags.Count; $r.tags = @($tags.Keys | Sort-Object)
        $expect = @($script:TfMap | ForEach-Object { $_.t }) + @('EQUseLegacy', 'CFCUseLegacy', 'TXParaEQData', 'CFCParaEQData', 'TXEQ1', 'TxEqFreq1', 'CFCEqFreq0', 'CFCPreComp0', 'CFCPostEqGain0')
        $r.missingExpectedTags = @($expect | Where-Object { -not $tags.ContainsKey($_) })
        foreach ($m in $r.missingExpectedTags) { Drift 'Thetis' "expected TXProfile tag <$m> not present in any profile" }
        $r.EQUseLegacy = @($blocks | ForEach-Object { ([regex]::Match($_, '<EQUseLegacy>([^<]*)')).Groups[1].Value } | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" })
        $r.CFCUseLegacy = @($blocks | ForEach-Object { ([regex]::Match($_, '<CFCUseLegacy>([^<]*)')).Groups[1].Value } | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" })
        foreach ($tag in 'TXParaEQData', 'CFCParaEQData') {
            $b = $blocks | ForEach-Object { ([regex]::Match($_, "<$tag>([^<]+)</$tag>")).Groups[1].Value } | Where-Object { $_.Length -gt 10 } | Select-Object -First 1
            if ($b) { $r["$tag.sample"] = Describe-Blob $b $tag 'Thetis'; if (-not $r["$tag.sample"]) { Drift 'Thetis' "$tag blob does not decode with the gzip+base64url envelope" } }
        }
        Write-Log ("  {0}: {1} profiles, active '{2}', {3} distinct tags, EQUseLegacy {4}" -f $dm.Name, $r.txProfiles, $r.active, $r.tagCount, ($r.EQUseLegacy -join ' ')) Green
    }
    $T.radios += $r
}
$Report.thetis = $T

# =============================================================================
Write-Head "NereusSDR"
$N = [ordered]@{}
$N.exe = Get-ExeVersion @("$env:ProgramFiles\NereusSDR\NereusSDR.exe", "$env:LOCALAPPDATA\Programs\NereusSDR\NereusSDR.exe")
$N.running = Test-ProcRunning @('NereusSDR', 'nereusd')
$base = Join-Path $env:LOCALAPPDATA 'NereusSDR'
$N.dirListing = @(Get-ChildItem $base -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 80 | ForEach-Object { "{0}  {1}" -f $_.FullName.Replace($base, '.'), $(if ($_.PSIsContainer) { '<dir>' } else { $_.Length }) })
$files = @(Get-ChildItem $base -Filter '*.settings' -Recurse -ErrorAction SilentlyContinue)
if (-not $files) { Drift 'Nereus' "no *.settings under $base" }
$N.files = @()
foreach ($f in $files) {
    $x = [IO.File]::ReadAllText($f.FullName)
    $e = [ordered]@{ path = $f.FullName; bytes = $f.Length; head = $x.Substring(0, [math]::Min(160, $x.Length)) }
    $e.rootIsNereusSDR = ($x -match '<NereusSDR[\s>]')
    $e.stationGroups = @([regex]::Matches($x, '<([A-Za-z0-9_]+)\s+type="station"') | ForEach-Object { $_.Groups[1].Value })
    if ($x -match '<SettingsSchemaVersion>([^<]*)<') { $e.schema = $matches[1] }
    if ($x -match '<radios__s__lastConnected>([^<]*)<') { $e.lastConnected = $matches[1] }
    $e.macs = @([regex]::Matches($x, 'hardware__s__(.+?)__s__tx__s__profile__s___names') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    foreach ($mac in $e.macs) {
        $pre = "hardware__s__${mac}__s__tx__s__profile__s__"
        $names = ([regex]::Match($x, "<${pre}_names>([^<]*)<")).Groups[1].Value
        $act = ([regex]::Match($x, "<${pre}active>([^<]*)<")).Groups[1].Value
        $e["$mac.names"] = @($names -split ','); $e["$mac.active"] = $act
        $first = @($names -split ',')[0]
        $pt = $pre + (($first.ToCharArray() | ForEach-Object { switch ([string]$_) { ' ' { '__sp__' } '+' { '__plus__' } '/' { '__s__' } '(' { '__lp__' } ')' { '__rp__' } '&' { '__amp__' } ',' { '__cm__' } default { [string]$_ } } }) -join '') + '__s__'
        $sfx = @([regex]::Matches($x, "<$([regex]::Escape($pt))([A-Za-z0-9_]+)>") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Sort-Object)
        $e["$mac.profileKeys"] = $sfx
        $expect = @($script:TfMap | Where-Object { $_.n } | ForEach-Object { $_.n }) + @('EQUseLegacy', 'TXParaEQData', 'CFCParaEQData', 'TXEQ1', 'TxEqFreq1', 'CFCEqFreq0', 'CFCPreComp0', 'CFCPostEqGain0')
        $e["$mac.missingExpectedKeys"] = @($expect | Where-Object { $sfx -notcontains $_ })
        $nereusOnly = @('Mic_XLR', 'Mic_TipRing', 'Mic_Bias', 'Mic_PTT_Disabled', 'Mic_LineInGain', 'Mic_UserDigOut', 'Mic_Source', 'MonitorVolume', 'VOX_GainScalar', 'AntiVox_Gain')
        $e["$mac.unknownKeys"] = @($sfx | Where-Object { $_ -notin $expect -and $_ -notin $nereusOnly -and $_ -notmatch '^(TXEQ|TxEqFreq|CFCEqFreq|CFCPreComp|CFCPostEqGain)\d+$' })
        # Key presence across EVERY profile: missing from all = format drift; missing from some = older profiles
        $all = @{}; $profCount = @($names -split ',').Count
        foreach ($m in [regex]::Matches($x, "<$([regex]::Escape($pre))(?!_names>|active>)(.+?)__s__([A-Za-z0-9_]+)>")) { $k = $m.Groups[2].Value; if (-not $all.ContainsKey($k)) { $all[$k] = @{} }; $all[$k][$m.Groups[1].Value] = 1 }
        foreach ($k in $expect) {
            $have = if ($all.ContainsKey($k)) { $all[$k].Count } else { 0 }
            if ($have -eq 0) { Drift 'Nereus' "no profile has expected key $k (format change?)" }
            elseif ($have -lt $profCount) { Write-Log ("  info: {0} of {1} profiles lack {2} (saved by an older NereusSDR - re-save them, or convert onto them)" -f ($profCount - $have), $profCount, $k) DarkGray }
        }
        $tb = ([regex]::Match($x, "<$([regex]::Escape($pt))TXParaEQData>([^<]+)<")).Groups[1].Value
        if ($tb) { $e["$mac.TXParaEQData.sample"] = Describe-Blob $tb 'TXParaEQData' 'Nereus' }
        Write-Log ("  {0}: schema v{1}, MAC {2}, {3} profiles, active '{4}', {5} keys/profile, unknown keys: {6}" -f (Split-Path $f.FullName -Leaf), $e.schema, $mac, @($names -split ',').Count, $act, $sfx.Count, ($e["$mac.unknownKeys"] -join ',')) Green
    }
    if (-not $e.rootIsNereusSDR) { Drift 'Nereus' "$($f.Name): root element is not <NereusSDR>" }
    if (-not $e.macs) { Drift 'Nereus' "$($f.Name): no hardware/<mac>/tx/profile/_names manifest" }
    if ([int](ConvertTo-Num $e.schema 0) -gt 10) { Drift 'Nereus' "SettingsSchemaVersion $($e.schema) is newer than the v10 the adapter was written against - review the probe" }
    $N.files += $e
}
$Report.nereus = $N

# =============================================================================
Write-Head "Zeus"
$Z = [ordered]@{ processes = @() }
$zprocs = @(Get-Process | Where-Object { $_.Name -match 'Zeus|StationEngine' })
foreach ($p in $zprocs) { $Z.processes += [ordered]@{ name = $p.Name; id = $p.Id; path = $p.Path; version = $(try { $p.MainModule.FileVersionInfo.ProductVersion } catch { $null }) } }
if (-not ($zprocs | Where-Object { $_.Name -eq 'ZeusProduct' })) { Drift 'Zeus' 'ZeusProduct process not running (start Zeus and re-probe to check the API)' }
if (-not ($zprocs | Where-Object { $_.Name -eq 'StationEngine' })) { Drift 'Zeus' 'StationEngine process not running' }
if ($zprocs -and (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    $Z.listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -in $zprocs.Id } | ForEach-Object { "{0}:{1} pid {2}" -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess })
    $ports = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -in $zprocs.Id } | ForEach-Object { $_.LocalPort } | Select-Object -Unique)
    $gets = @('/api/tx-audio-profiles', '/api/tx-audio-profiles/last-loaded', '/product/features', '/product/features/eq', '/product/features/eq/parameters', '/product/features/compressor/parameters', '/product/features/noise-gate/parameters', '/api/tx-audio-suite/processing-mode', '/api/tx/cfc', '/api/tx/cfc/presets', '/api/tx/leveling', '/api/tx/phase-rotator', '/api/mic-gain', '/api/tx-filter')
    $Z.get = [ordered]@{}
    foreach ($port in $ports) {
        foreach ($g in $gets) {
            try {
                $resp = Invoke-WebRequest "http://127.0.0.1:$port$g" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
                $body = $resp.Content; $shape = $null
                try { $shape = Get-KeyPaths (ConvertTo-HT ($body | ConvertFrom-Json)) | Select-Object -First 120 } catch { $shape = "non-JSON ($($body.Length) chars)" }
                $Z.get["$port$g"] = [ordered]@{ status = [int]$resp.StatusCode; shape = $shape }
                Set-Content (Join-Path $out ("samples\Zeus-$port" + ($g -replace '[/\\]', '_') + '.json')) $body -Encoding UTF8
                Write-Log "  GET :$port$g -> $([int]$resp.StatusCode)" Green
            } catch {
                $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'no response' }
                if ($code -ne 404 -and $code -ne 'no response') { $Z.get["$port$g"] = [ordered]@{ status = $code } }
            }
        }
    }
    $prodHit = @($Z.get.Keys | Where-Object { $_ -like '*/api/tx-audio-profiles' -and $Z.get[$_].status -eq 200 })
    if (-not $prodHit) { Drift 'Zeus' 'GET /api/tx-audio-profiles answered on no port' }
    elseif ($Z.get[$prodHit[0]].shape -notcontains 'profiles') { Drift 'Zeus' '/api/tx-audio-profiles no longer returns a "profiles" array' }
    if (-not @($Z.get.Keys | Where-Object { $_ -like '*/api/tx/cfc/presets' })) { Drift 'Zeus' 'StationEngine no longer answers /api/tx/cfc/presets (the converter uses it to find the engine port)' }
}
if (-not $NoZeusScrape) {
    # Scrape the web UI bundle for every /api/ or /product/ route string - the cheapest way to spot moved endpoints.
    $dirs = @($zprocs | Where-Object { $_.Path } | ForEach-Object { Split-Path $_.Path } | Select-Object -Unique)
    $routes = New-Object System.Collections.Generic.SortedSet[string]
    foreach ($d in $dirs) {
        foreach ($js in @(Get-ChildItem $d -Recurse -Include *.js, *.mjs -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 20MB })) {
            $txt = [IO.File]::ReadAllText($js.FullName)
            foreach ($m in [regex]::Matches($txt, '["''`](/(?:api|product)/[A-Za-z0-9_\-/{}\$.:]+)')) { [void]$routes.Add($m.Groups[1].Value) }
        }
    }
    $Z.uiRoutes = @($routes)
    $need = @('/api/tx/cfc', '/api/tx/leveling', '/api/tx/leveler-max-gain', '/api/tx/phase-rotator', '/api/mic-gain', '/api/tx-filter', '/api/tx-audio-profiles', '/api/tx-audio-suite/processing-mode', '/product/features')
    if ($routes.Count) {
        foreach ($n in $need) { if (-not ($Z.uiRoutes | Where-Object { $_ -like "$n*" })) { Drift 'Zeus' "web UI no longer references $n" } }
        Write-Log "  $($routes.Count) route strings found in the Zeus web UI bundle." Green
    } elseif ($dirs) { Write-Log "  No .js route strings found under $($dirs -join '; ') (UI may be embedded)." Yellow }
}
$Report.zeus = $Z

# =============================================================================
Write-Head "AetherSDR"
$A = [ordered]@{}
if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) { $A.appx = @(Get-AppxPackage -Name 'AetherSDR*' -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; version = "$($_.Version)"; family = $_.PackageFamilyName; install = $_.InstallLocation } }) }
$A.exe = Get-ExeVersion @("$env:ProgramFiles\AetherSDR\AetherSDR.exe", "$env:LOCALAPPDATA\Programs\AetherSDR\AetherSDR.exe")
$A.running = Test-ProcRunning @('AetherSDR')
$cands = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'AetherSDR*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'LocalCache\Local\AetherSDR' }) + @((Join-Path $env:LOCALAPPDATA 'AetherSDR'), (Join-Path $env:APPDATA 'AetherSDR'))
$A.dirs = @()
foreach ($d in ($cands | Where-Object { Test-Path $_ })) {
    $e = [ordered]@{ dir = $d; files = @(Get-ChildItem $d -File -ErrorAction SilentlyContinue | ForEach-Object { "{0}  {1}" -f $_.Name, $_.Length }) }
    foreach ($lib in 'AetherTxProfiles.json', 'AetherRxProfiles.json') {
        $p = Join-Path $d $lib
        if (Test-Path $p) {
            try {
                $j = Read-JsonFile $p
                $e[$lib] = [ordered]@{ rootKeys = @($j.Keys); version = $j.version; profiles = @($j.profiles.Keys) }
                $firstName = @($j.profiles.Keys)[0]
                if ($firstName) { $e[$lib].profileKeyPaths = Get-KeyPaths $j.profiles[$firstName]; Write-JsonFile $j.profiles[$firstName] (Join-Path $out "samples\Aether-$lib-first-profile.json") }
                if ([int](ConvertTo-Num $j.version 1) -ne 1) { Drift 'Aether' "$lib version $($j.version) (adapter written for v1)" }
                if ($lib -eq 'AetherTxProfiles.json' -and $firstName) {
                    foreach ($k in 'eq.bands[].gainDb', 'eq.bands[].freqHz', 'eq.bands[].type', 'eq.masterGain', 'comp.thresholdDb', 'comp.ratio', 'comp.phaseRotatorStages', 'gate.thresholdDb', 'gate.holdMs', 'gate.releaseMs') {
                        if ($e[$lib].profileKeyPaths -notcontains $k) { Drift 'Aether' "TX profile field '$k' missing (schema changed?)" }
                    }
                }
                Write-Log "  $lib v$($j.version): $(@($j.profiles.Keys).Count) profiles" Green
            } catch { Drift 'Aether' "$lib unreadable: $($_.Exception.Message)" }
        }
    }
    $cs = Join-Path $d 'ChannelStrip.settings'
    if (Test-Path $cs) { try { $j = Read-JsonFile $cs; $e.channelStrip = [ordered]@{ rootKeys = @($j.Keys); presets = @($j.presets.Keys) } } catch { } }
    if (-not (Test-Path (Join-Path $d 'AetherTxProfiles.json')) -and (Test-Path $cs)) { Write-Log "  Only ChannelStrip.settings present - AetherSDR is pre-26.9.4 or hasn't been launched since updating." Yellow }
    $A.dirs += $e
}
if (-not $A.dirs) { Drift 'Aether' 'no AetherSDR config folder found' }
$Report.aether = $A

# =============================================================================
Write-Head "Summary"
$Report | ConvertTo-Json -Depth 25 | Set-Content (Join-Path $out 'probe.json') -Encoding UTF8
if ($Report.drift.Count) { Write-Log "$($Report.drift.Count) drift item(s):" Yellow; foreach ($d in $Report.drift) { Write-Log "  $d" Yellow } }
else { Write-Log "No drift - everything matches what the converter expects." Green }
Write-Log ""
Write-Log "Probe folder: $out" Cyan
Write-Log "(probe.json + samples\ are what to send back if anything above says DRIFT)" DarkGray
