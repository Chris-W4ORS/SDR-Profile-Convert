# SDR-Profile-Convert

PowerShell toolkit that converts TX audio profiles between **Thetis**, **NereusSDR**, **Zeus** and **AetherSDR**, with backups, previews and validation before every write.

Pick a source app and profile, pick a destination app and name. Any of the four apps, plus a neutral JSON format, can be the source or the destination.

> Not affiliated with Thetis, NereusSDR, Zeus or AetherSDR. These scripts edit other applications' settings. Read the Safety section, keep the backups, and use at your own risk (see [LICENSE](LICENSE)).

## Supported versions

| App | Tested with | Profiles are stored in |
|---|---|---|
| Thetis | 2.10.3.x (Hermes-Lite 2) | `%APPDATA%\OpenHPSDR\Thetis-x64\DB\<id>\database.xml` |
| NereusSDR | 2026.10.x (settings schema v10) | `%LOCALAPPDATA%\NereusSDR\NereusSDR.settings` |
| Zeus | current release (local REST API) | live engine snapshots, via its API |
| AetherSDR | 26.9.4+ (AetherTX / AetherRX windows) | `AetherTxProfiles.json` / `AetherRxProfiles.json` |

Requirements:
- Windows 10/11 with PowerShell 7 (`pwsh`).
- Each app must have connected to your radio at least once.
- Developed and tested on a Hermes-Lite 2 only. Other radios may work but are untested.

## Install

1. Download or clone the repo, e.g. to `C:\Scripts\SDR-Profile-Convert`.
2. Downloaded files are blocked by Windows, so unblock them once:
   ```powershell
   Get-ChildItem C:\Scripts\SDR-Profile-Convert -Recurse -File | Unblock-File
   ```
3. Optional: copy `SdrConvert.rules.example.json` to `SdrConvert.rules.json` and switch on the rules you want. With no rules file, profiles are converted as-is.

## Quick start

```powershell
# 1. After installing or updating any app: check that the file formats and API are still what the scripts expect (read-only)
.\Probe-SdrStores.ps1

# 2. Convert interactively (pick apps and profiles from menus)
.\Convert-SdrProfile.ps1

# 3. Or unattended, e.g. three Zeus profiles into NereusSDR
.\Convert-SdrProfile.ps1 -From Zeus -FromProfile "Profile A","Profile B","Profile C" -To Nereus -Yes -NoActive
```

Before converting:
- **Close the destination app** (Thetis, NereusSDR, AetherSDR). They rewrite their settings when they exit.
- **Keep Zeus running** when it is the source or destination, since it is driven over its local API. Don't transmit while it runs: each profile is applied live for a moment.

## Scripts

| Script | Purpose |
|---|---|
| `Convert-SdrProfile.ps1` | The converter. `-WhatIf` previews; `-Review` lets you approve each change. |
| `Probe-SdrStores.ps1` | Read-only inventory of every app's storage and API; prints DRIFT when something changed. |
| `Reset-SdrProfiles.ps1` | Backs up, then removes every Thetis / NereusSDR / AetherSDR profile except one kept "seed". Previews unless `-Apply`. |
| `Reset-ZeusProfiles.ps1` | Exports every Zeus profile (API + on-disk copy), then removes all but the ones you keep. Previews unless `-Apply`. |
| `Repair-ThetisDb.ps1` | Fixes a `database.xml` that Thetis moved to `DB\broken\`, proves it loads, and with `-Restore` puts it back. |

### Converter switches

| Switch | Effect |
|---|---|
| `-From` / `-To` | `Thetis`, `Nereus`, `Zeus`, `Aether`, `File` |
| `-FromProfile` / `-ToProfile` | Source names; optional new destination names, one per source |
| `-All` | Every source profile |
| `-CloneFrom <name>` | Thetis/NereusSDR: the existing profile new ones are cloned from (default: the active one) |
| `-SetActive <name>` / `-NoActive` | Set, or leave alone, the destination's active profile |
| `-WhatIf` / `-Review` / `-Yes` | Preview only / approve each change / no final prompt |
| `-NoRules` | Straight mapping, no overrides |

## Safety

Nothing is changed without a backup, and destructive scripts only preview unless you add `-Apply`.
- **Backups.** Every edited file gets a `.bak_<timestamp>` copy beside it. Reset scripts save everything to `Documents\SdrConvert\Backups\` with a `RESTORE.txt`.
- **Thetis load test.** Writes match the database's own column types and are loaded with .NET `DataSet.ReadXml`, the way Thetis loads them. If the result wouldn't load, it isn't saved.
- **Zeus checks.** The previously active profile is restored after every run. Values are clamped to Zeus's ranges and read back after writing.
- **Audit trail.** Each run writes a log and the before/after JSON of every profile to `Documents\SdrConvert\Logs\`.

## What doesn't carry over

Each gap is listed in the run's notes.
- **Zeus compressor and noise gate → Thetis / NereusSDR:** those apps have no equivalent stage, so the copies sound less compressed.
- **CFC (multiband compression) → AetherSDR:** Aether has no CFC stage.
- **Phase rotator → AetherSDR:** limited to 6 stages, with a fixed corner frequency.
- **Thetis legacy EQ and CFC sliders:** whole-dB only, so values are rounded to within ±0.5 dB. The parametric EQ curve keeps its decimals.
- **Non-audio fields** (mic input settings and the like): new Thetis/NereusSDR profiles inherit these from the clone seed.

## Rules

`SdrConvert.rules.json` (copied from the example) holds destination-specific overrides, matched by:
- destination app
- source app
- profile-name wildcard

For example: force the same ALC/leveler/mic gain on every Zeus profile, add a compressor when converting from Thetis to Aether, or replace or cascade an EQ curve on matching profiles. Every rule in the example file ships disabled.

## Updates to the apps

The formats these apps use change between releases. Run `Probe-SdrStores.ps1` after updating any of them. If it reports DRIFT, open an issue and attach the probe folder (`probe.json` and `samples\`).

## License

MIT, see [LICENSE](LICENSE).
