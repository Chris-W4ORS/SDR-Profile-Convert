<#
.SYNOPSIS
  Repair a Thetis database.xml that Thetis rejected ("There was an issue loading the
  database ... moved to DB\broken\<id>"), prove it loads, and optionally restore it.

.DESCRIPTION
  Thetis loads database.xml with .NET DataSet.ReadXml against the file's own inline
  schema, so every value must parse as its column type. This script:
    1. reads the column types from that schema,
    2. coerces TXProfile values to them (True/False -> true/false; decimals in
       whole-number columns rounded, each one listed),
    3. loads the result exactly the way Thetis does and refuses to save if it still fails,
    4. with -Restore: moves the repaired folder back into DB\ and points
       <radio>_dbman_settings.json at it (both backed up first).
  Thetis must be CLOSED.

.EXAMPLE
  .\Repair-ThetisDb.ps1              # find the newest DB\broken\* database, repair + verify only
.EXAMPLE
  .\Repair-ThetisDb.ps1 -Restore     # repair, verify, and make it Thetis's active database again
#>
[CmdletBinding()]
param([string]$Path, [switch]$Restore)
$ErrorActionPreference = 'Stop'
foreach ($f in 'Common', 'Thetis') { . (Join-Path $PSScriptRoot "lib\$f.ps1") }
Initialize-SdrLog 'RepairThetis'
Write-Head "Repair Thetis database"
if (Test-ProcRunning @('Thetis')) { Write-Log "Close Thetis first." Red; exit 1 }

# ---- locate ---------------------------------------------------------------------
if (-not $Path) {
    $broken = @(Get-ChildItem (Join-Path $env:APPDATA 'OpenHPSDR') -Directory -Filter 'Thetis*' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'DB\broken') -Recurse -Filter 'database.xml' -ErrorAction SilentlyContinue } |
        Sort-Object LastWriteTime -Descending)
    if (-not $broken) { Write-Log "No database.xml under %APPDATA%\OpenHPSDR\Thetis*\DB\broken. Pass -Path." Red; exit 1 }
    $Path = $broken[0].FullName
}
if (-not (Test-Path $Path)) { Write-Log "Not found: $Path" Red; exit 1 }
Write-Log "Database: $Path"

$t = Read-TextKeepEncoding $Path
$before = Test-ThetisXml $t.Text
Write-Log "As found: $(if ($before) { "REJECTED - $before" } else { 'loads OK' })" $(if ($before) { 'Yellow' } else { 'Green' })

# ---- repair ---------------------------------------------------------------------
$types = Get-ThetisColumnTypes $t.Text
if ($types.Count -eq 0) { Write-Log "No inline schema for TXProfile found - can't type-check. Send me the file." Red; exit 1 }
Write-Log "Schema: $($types.Count) TXProfile columns ($(@($types.Values | Where-Object { $_ -eq 'Boolean' }).Count) boolean, $(@($types.Values | Where-Object { $_ -like 'Int*' }).Count) integer)" DarkGray

$fixed = New-Object System.Collections.ArrayList
$text = [regex]::Replace($t.Text, '<TXProfile>([\s\S]*?)</TXProfile>', {
        param($m)
        $blk = $m.Groups[1].Value
        $name = ([regex]::Match($blk, '<Name>([^<]*)</Name>')).Groups[1].Value
        $blk = [regex]::Replace($blk, '<([A-Za-z0-9_]+)>([^<]*)</\1>', {
                param($e)
                $tag = $e.Groups[1].Value; $val = $e.Groups[2].Value
                if (-not $types.ContainsKey($tag) -or $val -eq '') { return $e.Value }
                $f = Format-ThetisValue $tag $val $val $types
                if ($f.Changed) { [void]$fixed.Add("[$name] $tag  $val -> $($f.Value)"); return "<$tag>$($f.Value)</$tag>" }
                return $e.Value
            })
        "<TXProfile>$blk</TXProfile>"
    })
Write-Log ""; Write-Log "$($fixed.Count) value(s) corrected:" Cyan
foreach ($x in $fixed) { Write-Log "  $x" White }

$after = Test-ThetisXml $text
if ($after) {
    Write-Log ""; Write-Log "Still does not load: $after" Red
    Write-Log "Nothing saved. Send me this log: $script:LogPath" Red; exit 1
}
Write-Log ""; Write-Log "Repaired database loads cleanly (same DataSet.ReadXml Thetis uses)." Green

Copy-Item -LiteralPath $Path -Destination "$Path.rejected_$(Get-Date -Format 'yyyyMMdd_HHmmss')" -Force
[IO.File]::WriteAllText($Path, $text, $t.Encoding)
Write-Log "Saved (original kept as $(Split-Path $Path -Leaf).rejected_*)." Green

# ---- restore --------------------------------------------------------------------
if (-not $Restore) { Write-Log ""; Write-Log "Re-run with -Restore to make it Thetis's active database again." Cyan; exit 0 }
$dbFolder = Split-Path $Path                      # ...\DB\broken\<id>
$id = Split-Path $dbFolder -Leaf
if ((Split-Path (Split-Path $dbFolder) -Leaf) -ne 'broken') { Write-Log "-Restore expects a database inside DB\broken\<id>\ - skipped." Yellow; exit 0 }
$dbRoot = Split-Path (Split-Path $dbFolder)        # ...\DB
$dest = Join-Path $dbRoot $id
if (Test-Path $dest) {
    $aside = "$dest.replaced_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Move-Item -LiteralPath $dest -Destination $aside
    Write-Log "Existing $id moved aside to $(Split-Path $aside -Leaf)" Yellow
}
Move-Item -LiteralPath $dbFolder -Destination $dest
Write-Log "Restored folder -> $dest" Green

$dbman = @(Get-ChildItem $dbRoot -Filter '*_dbman_settings.json')
foreach ($j in $dbman) {
    $raw = Get-Content $j.FullName -Raw
    $cur = ($raw | ConvertFrom-Json).ActiveDB_File
    $want = "$id\database.xml"
    if ($cur -eq $want -or $cur -eq "$id/database.xml") { Write-Log "$($j.Name) already points at $id." DarkGray; continue }
    Copy-Item $j.FullName "$($j.FullName).bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $enc = { param($s) ($s | ConvertTo-Json).Trim('"') }
    $new = $raw.Replace((& $enc $cur), (& $enc $want))
    if ($new -eq $raw) { Write-Log "Could not update ActiveDB_File in $($j.Name) (currently '$cur'). Set it to '$want' by hand." Red; continue }
    [IO.File]::WriteAllText($j.FullName, $new)
    Write-Log "$($j.Name): ActiveDB_File '$cur' -> '$want' (backup .bak_*)" Green
}
Write-Log ""; Write-Log "Done. Start Thetis." Cyan
Write-Log "Log: $script:LogPath" DarkGray
