## SDR-Profile-Convert v1.0.0

First public release. A PowerShell toolkit for moving TX audio profiles between **Thetis**, **NereusSDR**, **Zeus** and **AetherSDR**: pick a source app and profile, pick a destination, and it converts, with a backup before every write.

### What's included
- **Convert-SdrProfile.ps1**: converts profiles from any of the four apps (or a neutral JSON format) to any other. Interactive menus or unattended switches; `-WhatIf` to preview, `-Review` to approve each change.
- **Probe-SdrStores.ps1**: read-only check of each app's file formats and API. Run it after updating any app; it reports DRIFT if something changed.
- **Reset-SdrProfiles.ps1**: backs up, then clears Thetis / NereusSDR / AetherSDR down to one kept profile.
- **Reset-ZeusProfiles.ps1**: exports every Zeus profile, then removes all but the ones you keep.
- **Repair-ThetisDb.ps1**: recovers a Thetis database that Thetis moved to `DB\broken\`.
- **SdrConvert.rules.example.json**: optional per-destination overrides (all off by default).

### Safety
- Destination files are backed up before every write; reset scripts only preview unless you add `-Apply`.
- Thetis writes are type-checked against its own database schema and load-tested before saving.
- Zeus is restored to its previously active profile after every run; values are range-checked and read back.
- Every run logs the before/after state of each profile to `Documents\SdrConvert\Logs\`.

### Tested with
| App | Version |
|---|---|
| Thetis | 2.10.3.x |
| NereusSDR | 2026.10.x (settings schema v10) |
| Zeus | current release (local REST API) |
| AetherSDR | 26.9.4+ |

Windows 10/11, PowerShell 7, Hermes-Lite 2. Other radios are untested.

### Known limitations
- **Zeus's compressor and noise gate** have no equivalent in Thetis or NereusSDR, so they aren't carried over.
- **AetherSDR** has no CFC stage, and its phase rotator is capped at 6 stages.
- **Thetis's legacy EQ and CFC sliders** are whole-dB, so values are rounded to within ±0.5 dB.
- **Thetis writes are experimental.** Keep the backups.

Every gap is listed in each run's notes.

### Getting started
1. Download **SDR-Profile-Convert.zip** below and extract it, e.g. to `C:\Scripts\SDR-Profile-Convert`.
2. Unblock the files: `Get-ChildItem C:\Scripts\SDR-Profile-Convert -Recurse -File | Unblock-File`
3. Run `.\Probe-SdrStores.ps1`, then `.\Convert-SdrProfile.ps1`.

See the [README](https://github.com/Chris-W4ORS/SDR-Profile-Convert#readme) for full usage. Not affiliated with any of the four applications.
