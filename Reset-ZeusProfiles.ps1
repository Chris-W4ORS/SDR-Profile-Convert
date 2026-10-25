<#
.SYNOPSIS
  Back up ALL Zeus TX audio profiles, then delete every profile except the ones you keep.

.DESCRIPTION
  PREVIEW BY DEFAULT - nothing is backed up or deleted unless you add -Apply.
  With -Apply (Zeus must be RUNNING; don't transmit - each profile is applied live
  for a moment to read it, and the original active profile is restored at the end):

    1. API export - every profile, as Zeus returns it:
         Backups\Zeus_<ts>\api\<name>.json          raw Zeus profile JSON
         Backups\Zeus_<ts>\canonical\<name>.canon.json  re-creatable with the converter
    2. Disk copy - finds the folder(s) where Zeus keeps its profile data (searches
       %APPDATA%, %LOCALAPPDATA%, %ProgramData% and the Zeus install folder for files
       that contain your profiles) and copies them whole: Backups\Zeus_<ts>\disk\
    3. Stops if the export didn't capture every profile.
    4. Deletes every profile not in -Keep (DELETE /api/tx-audio-profiles/{id}),
       then confirms the remaining list matches -Keep.

.EXAMPLE
  .\Reset-ZeusProfiles.ps1 -Keep "Profile A","Profile B"          # preview
.EXAMPLE
  .\Reset-ZeusProfiles.ps1 -Keep "Profile A","Profile B" -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Keep,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$Keep = @($Keep | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })   # accept "A","B" or "A,B"
foreach ($f in 'Common', 'Zeus') { . (Join-Path $PSScriptRoot "lib\$f.ps1") }
if ($env:SDRCONVERT_ZEUS_MOCK) { . $env:SDRCONVERT_ZEUS_MOCK }   # test hook only
Initialize-SdrLog 'ZeusReset'
Write-Head "Zeus profiles: back up, keep $($Keep.Count), delete the rest - $(if ($Apply) { 'APPLY' } else { 'PREVIEW' })"

if (-not (Zeus_Open)) { Write-Log "Zeus isn't running (needs ZeusProduct + StationEngine). Start it and re-run." Red; exit 1 }
$names = @($script:Ze.Ids.Keys | Sort-Object)
$missing = @($Keep | Where-Object { $names -notcontains $_ })
if ($missing) { Write-Log "Not Zeus profiles: $($missing -join ', '). Names must match exactly. Nothing done." Red; exit 1 }
$del = @($names | Where-Object { $Keep -notcontains $_ })
$activeName = ($script:Ze.Ids.GetEnumerator() | Where-Object { $_.Value -eq $script:Ze.RestoreId } | Select-Object -First 1).Key

Write-Log "Zeus:    $($script:Ze.Prod)   ($($names.Count) profiles, active: $(if ($activeName) { "'$activeName'" } else { 'unknown' }))"
Write-Log "Back up: all $($names.Count) profiles" Cyan
Write-Log "Keep:    $($Keep -join ', ')" Green
Write-Log "Delete:  $($del.Count): $($del -join ', ')" Yellow
if ($activeName -and $del -contains $activeName) { Write-Log "Active profile '$activeName' will be deleted; '$($Keep[0])' becomes active." Yellow }

if (-not $Apply) { Write-Log ""; Write-Log "Preview only. Re-run with -Apply to back up and delete." Cyan; exit 0 }
if (-not (Confirm-Yes "`nBack up all $($names.Count) profiles, then delete the $($del.Count) listed above?")) { Write-Log "Cancelled." Yellow; exit 0 }

$bk = Join-Path $env:USERPROFILE "Documents\SdrConvert\Backups\Zeus_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$apiDir = Join-Path $bk 'api'; $canDir = Join-Path $bk 'canonical'; $diskDir = Join-Path $bk 'disk'
New-Item -ItemType Directory -Path $apiDir, $canDir -Force | Out-Null
$safe = { param($n) $n -replace '[\\/:*?"<>|]', '_' }

# ---- 1. API export ----------------------------------------------------------------
Write-Log ""; Write-Log "1/4  Exporting $($names.Count) profiles (each applied live briefly - don't transmit)..." Cyan
$ok = 0; $bad = @()
foreach ($n in $names) {
    try {
        $canon = Zeus_Read $n
        ($script:Ze.LastRaw | ConvertTo-Json -Depth 30) | Set-Content (Join-Path $apiDir ((& $safe $n) + '.json')) -Encoding UTF8
        Write-JsonFile $canon (Join-Path $canDir ((& $safe $n) + '.canon.json'))
        $ok++
    } catch { $bad += $n; Write-Log "  [FAIL] $n : $($_.Exception.Message)" Red }
}
Write-Log "  exported $ok / $($names.Count)" $(if ($bad) { 'Red' } else { 'Green' })

# ---- 2. Disk copy -------------------------------------------------------------------
Write-Log ""; Write-Log "2/4  Looking for Zeus's on-disk profile store..." Cyan
$needles = @($script:Ze.Ids[$Keep[0]], $Keep[0]) | Where-Object { $_ }
$roots = @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData) | Where-Object { $_ -and (Test-Path $_) }
$cand = @()
foreach ($r in $roots) { $cand += @(Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Zeus|StationEngine' } | ForEach-Object { $_.FullName }) }
foreach ($pn in 'ZeusProduct', 'StationEngine') { $pp = Get-Process $pn -ErrorAction SilentlyContinue | Select-Object -First 1; if ($pp -and $pp.Path) { $cand += (Split-Path $pp.Path) } }
$latin1 = [Text.Encoding]::GetEncoding(28591)
$hitDirs = New-Object System.Collections.Generic.HashSet[string]
foreach ($d in ($cand | Select-Object -Unique)) {
    foreach ($f in @(Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 50MB -and $_.Extension -match '^\.(json|db|sqlite|sqlite3|xml|dat|settings|config|bin|ldb|log)?$' })) {
        try { $txt = $latin1.GetString([IO.File]::ReadAllBytes($f.FullName)) } catch { continue }
        foreach ($nd in $needles) { if ($txt.Contains($nd)) { [void]$hitDirs.Add($f.DirectoryName); break } }
    }
}
if ($hitDirs.Count -eq 0) { Write-Log "  No on-disk profile store found - the API export (step 1) is the backup." Yellow }
foreach ($h in $hitDirs) {
    $dst = Join-Path $diskDir (($h -replace '^[A-Za-z]:\\', '') -replace '[\\/:]', '_')
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Copy-Item -Path (Join-Path $h '*') -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
    "$h" | Set-Content (Join-Path $dst '_ORIGINAL_PATH.txt')
    Write-Log "  copied $h" Green
}

# ---- 3. Gate --------------------------------------------------------------------------
Write-Log ""; Write-Log "3/4  Checking the backup..." Cyan
@(
    "Zeus backup $(Get-Date)  -  $($names.Count) profiles",
    "",
    "EXACT restore (everything): close Zeus, copy each folder in disk\ back to the path in its _ORIGINAL_PATH.txt, start Zeus.",
    "",
    "Per-profile restore (any profile, via the converter, Zeus running):",
    "  1. copy the wanted canonical\<name>.canon.json files to Documents\SdrConvert\Canonical\",
    "  2. .\Convert-SdrProfile.ps1 -From File -FromProfile ""<name>"" -To Zeus -NoRules -Yes",
    "     (-NoRules matters: without it the Zeus rules would change ALC/leveler/mic gain)",
    "",
    "api\ holds the raw JSON Zeus returned for each profile (reference).",
    "Profiles: $($names -join ', ')"
) | Set-Content (Join-Path $bk 'RESTORE.txt') -Encoding UTF8
if ($bad) {
    Write-Log "  $($bad.Count) profile(s) could not be exported: $($bad -join ', ')" Red
    Write-Log "  NOTHING DELETED. Backup so far: $bk" Red
    Zeus_Close; exit 1
}
Write-Log "  all $($names.Count) profiles exported$(if ($hitDirs.Count) { " + $($hitDirs.Count) data folder(s) copied" }) -> $bk" Green

# ---- 4. Delete ------------------------------------------------------------------------
Write-Log ""; Write-Log "4/4  Deleting $($del.Count) profile(s)..." Cyan
$gone = 0
foreach ($n in $del) {
    try { Invoke-Zeus Delete "$($script:Ze.Prod)/api/tx-audio-profiles/$($script:Ze.Ids[$n])" $null | Out-Null; $gone++ }
    catch { Write-Log "  [FAIL] $n : $($_.Exception.Message)" Red }
}
# restore / choose the live profile
$liveName = if ($activeName -and $Keep -contains $activeName) { $activeName } else { $Keep[0] }
$liveId = $script:Ze.Ids[$liveName]
Invoke-Zeus Post "$($script:Ze.Prod)/api/tx-audio-profiles/$liveId/apply" $null | Out-Null
try { Invoke-Zeus Put "$($script:Ze.Prod)/api/tx-audio-profiles/last-loaded" @{ id = $liveId } | Out-Null } catch { }
$script:Ze.LiveTouched = $false

$left = @((Invoke-Zeus Get "$($script:Ze.Prod)/api/tx-audio-profiles" $null).profiles | ForEach-Object { $_.name } | Sort-Object)
$extra = @($left | Where-Object { $Keep -notcontains $_ })
Write-Log ""
Write-Log "Deleted $gone / $($del.Count). Zeus now has: $($left -join ', ')" $(if ($extra) { 'Yellow' } else { 'Green' })
if ($extra) { Write-Log "Still present (delete failed): $($extra -join ', ')" Yellow }
Write-Log "Live profile: '$liveName'" Green
Write-Log "Backup: $bk  (see RESTORE.txt)" Cyan
Write-Log "Log: $script:LogPath" DarkGray
