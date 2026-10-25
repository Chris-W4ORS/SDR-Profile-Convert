# Changelog

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
