# SDR-Profile-Convert

PowerShell toolkit that converts TX audio profiles between **Thetis**, **NereusSDR**, **Zeus** and **AetherSDR**, with backups, previews and validation before every write.

Pick a source app and profile, pick a destination app and name. Any of the four apps, plus a neutral JSON format, can be the source or the destination.

> Not affiliated with Thetis, NereusSDR, Zeus or AetherSDR. These scripts edit other applications' settings. Read the Safety section, keep the backups, and use at your own risk (see [LICENSE](LICENSE)). Release history: [CHANGELOG](CHANGELOG.md).

## Supported versions

| App | Tested with | Profiles are stored in |
|---|---|---|
| Thetis | 2.10.3.x (Hermes-Lite 2) | `%APPDATA%\OpenHPSDR\Thetis-x64\DB\<id>\database.xml` |
| NereusSDR | 2026.10.x (settings schema v10) | `%LOCALAPPDATA%\NereusSDR\NereusSDR.settings` |
| Zeus | current release (local REST API) | live engine snapshots, via its API |
| AetherSDR | 26.9.4 - 26.10.3 (AetherTX / AetherRX windows) | `AetherTxProfiles.json` / `AetherRxProfiles.json` |

Requirements:
- Windows 10/11 with PowerShell 7 (`pwsh`).
- Each app must have connected to your radio at least once.
- Developed and tested on a Hermes-Lite 2 only. Other radios may work but are untested.

## Install

1. Download the release zip or clone the repo, e.g. to `C:\Scripts\SDR-Profile-Convert`.
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

# 4. Snapshot what every app currently holds (read-only)
.\Export-ProfileReference.ps1
```

Before converting:
- **Close the destination app** (Thetis, NereusSDR and nereusd, AetherSDR). They rewrite their settings when they exit.
- **Keep Zeus running** when it is the source or destination, since it is driven over its local API. Don't transmit while it runs: each profile is applied live for a moment.

## Scripts

| Script | Purpose |
|---|---|
| `Convert-SdrProfile.ps1` | The converter. `-WhatIf` previews; `-Review` lets you approve each change. |
| `Probe-SdrStores.ps1` | Read-only inventory of every app's storage and API; prints DRIFT when something changed. |
| `Export-ProfileReference.ps1` | Read-only snapshot of NereusSDR, Thetis and AetherTX profiles (`-Match "Chris*"` by name): a readable `Reference.md` plus the raw settings of each profile. Close Thetis and NereusSDR first so their latest saves are on disk. |
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

## How the EQ is converted

The apps don't define EQ bands the same way, so curves are converted by **response**, not copied band for band.

- **Zeus and AetherSDR** use conventional bands: peaks, low/high shelves and high/low-pass, with Q relative to frequency. Zeus band types (`band-N-type`: 0 peak, 1 low shelf, 2 high shelf) and its EQ output gain are read and carried to AetherTX band for band.
- **Thetis and NereusSDR** (WDSP `eq_impulse_q`) use a different model: each point is a Gaussian bump on a linear Hz axis, 1000 Hz / Q wide at half height, with no shelf or pass types, acting only between the first and last point. A Q 1.1 band is about 900 Hz wide at any frequency, so a curve copied 1:1 can be several dB off.
- **Zeus/Aether → Thetis/NereusSDR:** the converter computes the source's real response (EQ bands with shelves, the Zeus multiband makeup tone, input-strip cuts) and least-squares fits about 20 WDSP points across the TX filter passband. The run log prints the fit error (typically under 1 dB). The total EQ gain goes into the parametric preamp (`global_gain_db`), which is what WDSP uses in parametric mode; `TXEQPreamp` only feeds the legacy EQ.
- Options (`options.Nereus` / `options.Thetis`): `fitConventionalEq` (true), `inputCuts` (`eq` | `filter` | `none`), `gateToDexp` (true).

## Zeus TX Audio Suite → AetherTX

| Zeus unit | AetherTX |
|---|---|
| native-chain order | `chain` (Gate / DeEss / Eq / Comp / Tube / Enh / Reverb in Zeus order) |
| input strip | trim → EQ gain; low cut → HighPass band; high cut → LowPass band (12 dB/oct); rotator → comp phase rotator if the main rotator is off |
| noise gate | threshold, hold, release, ratio, range → floor, lookahead, mode 1 → Expander |
| de-esser | frequency, threshold, range → amount, attack, release (no ratio) |
| multiband | per-band makeup gains → EQ shelves/peaks; output → compressor makeup (compression itself not carried) |
| saturation | Tube: drive, mix, output |
| exciter / bass enhancer | Exciter (Enh): Clarity = exciter, Body = bass |
| reverb | size, damping, mix, pre-delay (decay not mapped) |
| limiter | Final Output limiter: on + ceiling; drive only with `options.Aether.limiterDrive = compMakeup` |
| broadcast AGC, punch, denoise | not mapped (noted) |

Gate and de-esser thresholds ahead of the EQ are lowered by the input trim so they trigger at the same level as in Zeus (`compensateTrim`). The Aether compressor's drive is set to 0 for sources that have no drive control.

For Thetis/NereusSDR, the Zeus noise gate maps to DEXP (threshold trim-compensated); the other suite units have no stage there and are listed in the run notes.

## Safety

Nothing is changed without a backup, and destructive scripts only preview unless you add `-Apply`.
- **Backups.** Every edited file gets a `.bak_<timestamp>` copy beside it. Reset scripts save everything to `Documents\SdrConvert\Backups\` with a `RESTORE.txt`.
- **Thetis load test.** Writes match the database's own column types and are loaded with .NET `DataSet.ReadXml`, the way Thetis loads them. If the result wouldn't load, it isn't saved.
- **Zeus checks.** The previously active profile is restored after every run. Values are clamped to Zeus's ranges and read back after writing.
- **Audit trail.** Each run writes a log and the before/after JSON of every profile to `Documents\SdrConvert\Logs\`.

## What doesn't carry over

Each gap is listed in the run's notes.
- **Zeus compressor, AGC, multiband compression, de-esser, exciter, limiter → Thetis / NereusSDR:** no equivalent stages. Use the Leveler, CFC pre-comp and CPDR/PROC by ear.
- **Broadcast AGC and multiband compression → AetherSDR:** only the multiband's tone carries; Aether has no AGC or multiband stage. Compressor auto-makeup and the limiter's drive, look-ahead and true-peak have no Aether controls.
- **CFC → AetherSDR:** Aether has no CFC stage.
- **Phase rotator → AetherSDR:** limited to 6 stages, with a fixed corner frequency.
- **Thetis legacy EQ and CFC sliders:** whole-dB only, so values are rounded to within ±0.5 dB. The parametric EQ curve keeps its decimals.
- **Radio-side settings** (RF/Tune power, mic level, PROC on/off, Aether's TX filter): not part of the profiles these scripts edit.
- **Non-audio fields** (mic input settings and the like): new Thetis/NereusSDR profiles inherit these from the clone seed.
- **Thetis/NereusSDR → Zeus/AetherSDR** still copies EQ points 1:1; the reverse fit is planned.

## Rules

`SdrConvert.rules.json` (copied from the example) holds destination-specific overrides, matched by:
- destination app
- source app
- **destination** profile-name wildcard

A rule can `set` canonical fields (for example `compressor.thresholdDb`, `filter.highHz`, `cfc.preCompDb`), replace or cascade an EQ curve (`eqBaseline`), or write raw destination fields with `destSet`: AetherTX JSON paths such as `"comp.driveDb": 0` or `"finalLimiter.outputTrimDb": -1`, or NereusSDR/Thetis key names. Every rule in the example file ships disabled. For Zeus sources, the multiband output gain is added to `compressor.makeupDb` after rules run.

## Updates to the apps

The formats these apps use change between releases. Run `Probe-SdrStores.ps1` after updating any of them. If it reports DRIFT, open an issue and attach the probe folder (`probe.json` and `samples\`).

## License

MIT, see [LICENSE](LICENSE).
