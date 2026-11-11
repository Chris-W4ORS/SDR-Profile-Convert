# Changelog

## v1.2.0 - 2026-11-11

### Added
- **`fitPoints` and `fitQ` options** for Zeus/AetherSDR → Thetis/NereusSDR EQ fits (`options.Nereus` / `options.Thetis`). `fitPoints` sets how many points are written, for example `10` or `18` to match the NereusSDR band presets, instead of the 19–21 points the fit chose on its own. `fitQ` puts one Q on every point instead of a Q that narrows toward the low end. Both default to `auto`, which gives the same result as v1.1.1.
- The fit line in the run log now shows the Q range alongside the point count and fit error.
- **`eqGain` option** (`options.Nereus` / `options.Thetis`): `keep` (default, as before), `zero`, or a number to cap the EQ gain written into the curve preamp. An AetherSDR profile with +12 dB EQ gain used to land in NereusSDR as a +12 dB preamp.
- **Zeus backup before every write.** Before the converter changes anything in Zeus, it exports every Zeus profile (raw JSON, canonical copy, data folder) to `Documents\SdrConvert\Backups\Zeus_<timestamp>\` with a `RESTORE.txt`. If any profile can't be exported, nothing is written.
- `-WhatIf` to Thetis or NereusSDR now previews the TX EQ: the fit line (point count, Q range, fit error) for converted curves, or that the EQ is copied as-is. Before, `-WhatIf` stopped before the EQ was built, so there was no way to check a fit without writing.

### Fixed
- AetherSDR → Thetis/NereusSDR fitted the EQ across a default 80–4000 Hz, because AetherSDR keeps its bandwidth in High-Pass/Low-Pass EQ bands, not a TX filter. The fit range now comes from those bands.
- Overwriting the Zeus profile that was active left Zeus with no active profile at the end of the run ("could not restore Zeus live state"). The restore now follows the replaced profile.

## v1.1.1 - 2026-11-11

### Fixed
- Converting **from** NereusSDR or Thetis failed with "Get-NereusVal / Get-ThetisTag is not recognized" when `Convert-SdrProfile.ps1` was run from a PowerShell prompt (it worked from `Run-SdrConvert.bat`).
- `Export-ProfileReference.ps1` now exports every profile by default. It used to default to `-Match "Chris*"`, so for other users it found no profiles.

## v1.1.0 - 2026-10-25

### Added
- **Zeus TX Audio Suite → AetherTX.** Input strip (trim, low/high cut), de-esser, multiband makeup tone, saturation → Tube, exciter and bass enhancer → Exciter, reverb, limiter → Final Output, and the Zeus chain order. Gate and de-esser thresholds are trim-compensated.
- **Fitted EQ for Thetis and NereusSDR.** Conventional Zeus/Aether EQ curves (with shelves, multiband tone and input cuts) are least-squares fitted to WDSP's Gaussian points across the TX filter passband; the fit error is logged. Copied 1:1, the same curve was up to 5 dB off.
- **Zeus noise gate → DEXP** for Thetis and NereusSDR.
- **`destSet` in rules** for raw destination fields (AetherTX JSON paths, NereusSDR/Thetis keys).
- **`Export-ProfileReference.ps1`**: read-only snapshot of NereusSDR, Thetis and AetherTX profiles.

### Fixed
- Zeus EQ **shelf bands** were written to AetherTX as peaks; band types are now read and kept.
- Zeus **EQ output gain** was dropped; it now goes into the Aether EQ gain and the Thetis/NereusSDR parametric preamp.
- Thetis/NereusSDR: the EQ gain went into `TXEQPreamp`, which parametric mode ignores; it now goes into the curve preamp.
- AetherTX compressor **drive** no longer inherits a leftover template value.

### Known limitations
- Thetis/NereusSDR → Zeus/AetherSDR still copies EQ points 1:1 (reverse fit planned).
- AetherSDR as a source still drops non-peak EQ bands and the newer stages.

## v1.0.0

First public release: converter for Thetis, NereusSDR, Zeus and AetherSDR (and a neutral JSON format), probe, reset and repair scripts, and a rules file for per-destination overrides.
