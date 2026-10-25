<#
.SYNOPSIS
  All-in-one TX audio profile converter: Thetis <-> NereusSDR <-> Zeus <-> AetherSDR <-> canonical JSON.

.DESCRIPTION
  Pick a source app and profile(s), pick a destination app and profile name(s).
  Every profile is read into one canonical model, the rules file
  (SdrConvert.rules.json) applies destination-specific overrides, and the
  destination adapter writes it. File-based destinations are backed up first;
  every run leaves a log plus before/after canonical JSON in
  Documents\SdrConvert\Logs\Convert_<timestamp>\.

  Close Thetis / NereusSDR / AetherSDR before writing to them.
  Zeus must be RUNNING (it is driven over its local REST API) - don't transmit.

.EXAMPLE
  .\Convert-SdrProfile.ps1
  Fully interactive.
.EXAMPLE
  .\Convert-SdrProfile.ps1 -From Thetis -All -To Zeus -SetActive "VMP 3k Voodoo" -Yes
.EXAMPLE
  .\Convert-SdrProfile.ps1 -From Zeus -FromProfile "Ray 3k New" -To Nereus -ToProfile "Ray 3k (from Zeus)" -Review
.EXAMPLE
  .\Convert-SdrProfile.ps1 -From Thetis -All -To Aether -WhatIf
#>
[CmdletBinding()]
param(
    [ValidateSet('Thetis', 'Nereus', 'Zeus', 'Aether', 'File')][string]$From,
    [string[]]$FromProfile,
    [switch]$All,
    [ValidateSet('Thetis', 'Nereus', 'Zeus', 'Aether', 'File')][string]$To,
    [string[]]$ToProfile,
    [string]$SetActive,
    [switch]$NoActive,
    [switch]$Review,        # challenge each change (W/C/S) before it is applied
    [switch]$WhatIf,        # read + rules + preview only; nothing written
    [switch]$Yes,           # skip the final "write N profiles?" confirmation
    [switch]$AetherExport,  # write Aether import files even if the library is editable
    [string]$CloneFrom,     # Thetis/Nereus: existing profile new ones are cloned from (default: the active profile)
    [string]$RulesPath = (Join-Path $PSScriptRoot 'SdrConvert.rules.json'),
    [switch]$NoRules
)

$ErrorActionPreference = 'Stop'
foreach ($f in 'Common', 'ThetisFamily', 'Thetis', 'Nereus', 'Zeus', 'Aether') { . (Join-Path $PSScriptRoot "lib\$f.ps1") }

# ---------------------------------------------------------------------------
# "File" adapter - canonical JSON, useful as an archive / hand-edit / hand-off
# ---------------------------------------------------------------------------
$script:FileDir = Join-Path $env:USERPROFILE 'Documents\SdrConvert\Canonical'
function File_Status { return @{ Available = $true; CanWrite = $true; Reason = $script:FileDir } }
function File_List { return @(Get-ChildItem $script:FileDir -Filter '*.canon.json' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { @{ Name = ($_.Name -replace '\.canon\.json$', ''); Active = $false } }) }
function File_Read {
    param([string]$Name)
    $c = Read-JsonFile (Join-Path $script:FileDir "$Name.canon.json")
    $notes = New-Object System.Collections.ArrayList; if ($c.notes) { foreach ($n in $c.notes) { [void]$notes.Add($n) } }; $c.notes = $notes
    $orig = if ($c.source -and $c.source.app) { $c.source.app } else { $null }
    $c.source = [ordered]@{ app = 'File'; origin = $orig; profile = $Name; readAt = (Get-Date).ToUniversalTime().ToString('o') }
    return $c
}
function File_BeginWrite { New-Item -ItemType Directory -Path $script:FileDir -Force | Out-Null }
function File_Write { param($canon, [string]$DestName, $rules, [switch]$Review) $p = Join-Path $script:FileDir (($DestName -replace '[\\/:*?"<>|]', '_') + '.canon.json'); Write-JsonFile $canon $p; Write-Log "    -> $p" Green; return @{ Changed = 1; Total = 1; New = $true } }
function File_EndWrite { param([string]$ActiveName, $rules) }

# ---------------------------------------------------------------------------
function Show-CanonSummary {
    param($c)
    $f = { param($v) if ($null -eq $v) { '-' } elseif ($v -is [bool]) { if ($v) { 'on' } else { 'off' } } else { "$v" } }
    $eqPts = Get-TxEqPoints $c
    $eqTxt = if ($eqPts.Count) { "$($eqPts.Count)pt " + (($eqPts | Select-Object -First 10 | ForEach-Object { "{0}:{1}" -f [int]$_.freqHz, [math]::Round([double]$_.gainDb, 1) }) -join ' ') } else { '-' }
    Write-Log ("    filter {0}-{1} Hz | mic {2} dB | lev {3} {4} dB | alc {5} dB" -f (& $f $c.filter.lowHz), (& $f $c.filter.highHz), (& $f $c.mic.gainDb), (& $f $c.leveler.enabled), (& $f $c.leveler.maxGainDb), (& $f $c.alc.maxGainDb)) DarkGray
    Write-Log ("    txEq {0} [{1}] pre {2} dB : {3}" -f (& $f $c.txEq.enabled), (& $f $c.txEq.mode), (& $f $c.txEq.preampDb), $eqTxt) DarkGray
    Write-Log ("    cfc {0} [{1}] postEq {2} preComp {3} | phRot {4} ({5} st) | comp {6} | gate {7} | rxEq {8} | extraEq {9}" -f (& $f $c.cfc.enabled), (& $f $c.cfc.mode), (& $f $c.cfc.postEqEnabled), (& $f $c.cfc.preCompDb), (& $f $c.phaseRotator.enabled), (& $f $c.phaseRotator.stages), (& $f $c.compressor.enabled), (& $f $c.noiseGate.enabled), $(if ($c.rxEq) { 'yes' } else { '-' }), $(if ($c.extraEq) { $c.extraEq.label } else { '-' })) DarkGray
}

$apps = @('Thetis', 'Nereus', 'Zeus', 'Aether', 'File')
$labels = @{ Thetis = 'Thetis'; Nereus = 'NereusSDR'; Zeus = 'Zeus'; Aether = 'AetherSDR'; File = 'Canonical JSON file' }

Initialize-SdrLog 'Convert'
Write-Head "SdrConvert - TX profile converter"
$rules = if ($NoRules) { Import-SdrRules $null } else { Import-SdrRules $RulesPath }
Write-Log "Rules: $(if ($NoRules) { 'disabled' } else { "$RulesPath ($(@($rules.rules).Count) rules)" })" DarkGray
Write-Log "Log:   $script:LogPath" DarkGray

$exit = 0
try {
    # ---- status of every app -------------------------------------------------
    $status = @{}
    foreach ($a in $apps) {
        if (($From -and $To) -and $a -ne $From -and $a -ne $To) { continue }
        try { $status[$a] = & "${a}_Status" } catch { $status[$a] = @{ Available = $false; Reason = $_.Exception.Message } }
    }
    $fmt = { param($a) $s = $status[$a]; "{0,-20} {1}" -f $labels[$a], $(if ($s.Available) { $s.Reason } else { "UNAVAILABLE - $($s.Reason)" }) }

    # ---- source -----------------------------------------------------------------
    if (-not $From) { $From = Select-Item "SOURCE application:" @($apps | Where-Object { $status[$_].Available }) $fmt }
    if (-not $status[$From].Available) { throw "$($labels[$From]) is not available: $($status[$From].Reason)" }
    $srcList = @(& "${From}_List")
    if ($srcList.Count -eq 0) { throw "$($labels[$From]) has no profiles." }
    $srcNames = @(if ($All) { $srcList | ForEach-Object { $_.Name } }
                  elseif ($FromProfile) { $FromProfile }
                  else { Select-Item "Source profile(s) in $($labels[$From]):" $srcList { param($p) "$($p.Name)$(if ($p.Active) { '  [ACTIVE]' })" } -Multi | ForEach-Object { $_.Name } })
    foreach ($n in $srcNames) { if (-not ($srcList | Where-Object { $_.Name -eq $n })) { throw "Source profile '$n' not found in $($labels[$From])." } }

    # ---- destination ------------------------------------------------------------
    if (-not $To) { $To = Select-Item "DESTINATION application:" @($apps | Where-Object { $status[$_].Available }) $fmt }
    if (-not $status[$To]) { $status[$To] = & "${To}_Status" }
    if (-not $status[$To].Available) { throw "$($labels[$To]) is not available: $($status[$To].Reason)" }
    if (-not $WhatIf -and -not $status[$To].CanWrite) { throw "$($labels[$To]) can't be written right now: $($status[$To].Reason)" }
    $dstList = @(& "${To}_List")
    $dstNames = @()
    if ($ToProfile) {
        if ($ToProfile.Count -ne $srcNames.Count) { throw "-ToProfile must list one name per source profile ($($srcNames.Count))." }
        $dstNames = @($ToProfile)
    } elseif ($srcNames.Count -eq 1 -and -not $Yes) {
        Write-Log ""; Write-Log "Destination profile name in $($labels[$To]):" Cyan
        for ($i = 0; $i -lt $dstList.Count; $i++) { Write-Host ("  [{0,2}] overwrite '{1}'" -f ($i + 1), $dstList[$i].Name) }
        $ans = (Read-Host "Enter = '$($srcNames[0])', a number to overwrite, or type a new name").Trim()
        $n = 0
        $dstNames = @(if (-not $ans) { $srcNames[0] } elseif ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $dstList.Count) { $dstList[$n - 1].Name } else { $ans })
    } else { $dstNames = @($srcNames) }

    if ($CloneFrom) {
        if ($To -notin @('Thetis', 'Nereus')) { Write-Log "[WARN] -CloneFrom only applies to Thetis / NereusSDR - ignored." Yellow }
        elseif (-not ($dstList | Where-Object { $_.Name -eq $CloneFrom })) { throw "-CloneFrom '$CloneFrom' is not a $($labels[$To]) profile (copy it there first)." }
        else { $script:CloneFrom = $CloneFrom; Write-Log "New profiles will be cloned from '$CloneFrom'." DarkGray }
    }

    # ---- read + rules -------------------------------------------------------------
    Write-Head "Reading $($srcNames.Count) profile(s) from $($labels[$From]) -> $($labels[$To])"
    $jobs = @()
    for ($i = 0; $i -lt $srcNames.Count; $i++) {
        $s = $srcNames[$i]; $d = $dstNames[$i]
        Write-Log ""; Write-Log "  $s  ->  $d" White
        try {
            $canon = & "${From}_Read" $s
            Write-JsonFile $canon (Join-Path $script:RunDir (($s -replace '[\\/:*?"<>|]', '_') + '.1-source.canon.json'))
            $ruleSrc = if ($From -eq 'File' -and $canon.source.origin) { $canon.source.origin } else { $From }
            $applied = @(Invoke-SdrRules $canon $rules $To $ruleSrc $d)
            if ($applied.Count) { Write-Log "    rules: $($applied -join ', ')" DarkCyan }
            if ($canon.extraEq -and $To -ne 'Aether') { Add-Note $canon "extraEq '$($canon.extraEq.label)' only applies to Aether - ignored." 'DarkGray' }
            Show-CanonSummary $canon
            Write-JsonFile $canon (Join-Path $script:RunDir (($d -replace '[\\/:*?"<>|]', '_') + '.2-after-rules.canon.json'))
            $jobs += @{ Src = $s; Dst = $d; Canon = $canon }
        } catch { Write-Log "    READ FAILED: $($_.Exception.Message)" Red; $exit = 1 }
    }
    if ($jobs.Count -eq 0) { throw "Nothing could be read." }

    if ($WhatIf) { Write-Log ""; Write-Log "-WhatIf: nothing written. Canonical before/after JSON is in $script:RunDir" Yellow; return }
    if (-not $Yes -and -not (Confirm-Yes "`nWrite $($jobs.Count) profile(s) to $($labels[$To])?")) { Write-Log "Cancelled." Yellow; return }

    # ---- write --------------------------------------------------------------------
    Write-Head "Writing to $($labels[$To])"
    if ($To -eq 'Aether') { Aether_BeginWrite -ForceExport:$AetherExport } else { & "${To}_BeginWrite" }
    $ok = 0; $fail = 0
    foreach ($j in $jobs) {
        Write-Log ""; Write-Log "  $($j.Dst)" White
        try {
            $r = & "${To}_Write" $j.Canon $j.Dst $rules -Review:$Review
            Write-Log ("    {0}: {1}/{2} change(s) applied" -f $(if ($r.New) { 'NEW' } else { 'updated' }), $r.Changed, $r.Total) Green
            $ok++
        } catch { Write-Log "    WRITE FAILED: $($_.Exception.Message)" Red; $fail++; $exit = 1 }
    }

    # ---- active profile -------------------------------------------------------------
    $active = $null
    if (-not $NoActive -and $To -in @('Thetis', 'Nereus', 'Zeus')) {
        $written = @($jobs | ForEach-Object { $_.Dst })
        if ($SetActive) { if ($written -contains $SetActive) { $active = $SetActive } else { Write-Log "[WARN] -SetActive '$SetActive' was not written this run - ignored." Yellow } }
        elseif (-not $Yes) { $active = Select-Item "Make one of these the active profile in $($labels[$To])?" $written -AllowSkip -SkipText 'Skip (keep current active)' }
    }
    & "${To}_EndWrite" $active $rules

    Write-Head "Done.  OK: $ok   Failed: $fail"
    $noted = @($jobs | Where-Object { $_.Canon.notes.Count -gt 0 })
    if ($noted.Count) {
        Write-Log "Notes (things that didn't map 1:1):" Yellow
        foreach ($j in $noted) { foreach ($n in $j.Canon.notes) { Write-Log "  [$($j.Dst)] $n" Yellow } }
    }
    Write-Log "Run folder: $script:RunDir" DarkGray
} catch {
    Write-Log ""; Write-Log "ERROR: $($_.Exception.Message)" Red; $exit = 1
} finally {
    if (Get-Command Zeus_Close -ErrorAction SilentlyContinue) { Zeus_Close }
}
exit $exit
