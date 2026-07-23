# JuliaCon 2026 — Real-Time GNSS Positioning with JuliaGNSS

An interactive **terminal presentation** that drives a live software-defined GNSS
receiver ([JuliaGNSS](https://github.com/JuliaGNSS)) from one continuous stream of SDR
samples, built on [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl). Each
slide visualizes one stage of the receiver pipeline, live, from the same warm stream.

```
samples → spectrum → acquisition → tracking → PVT
```

## Slides

| # | Slide | What it shows (live) |
|---|-------|----------------------|
| 0 | **Title** | Pipeline diagram + a "● streaming" heartbeat (the SDR is already warm) |
| 1 | **Spectrum** | Live periodogram — a flat noise floor; the GPS signals are *below* it |
| 2 | **Codes & correlation** | A real PRN code (`gen_code`) as a ±1 square wave, and why correlation yields a **triangle** — the idea behind acquisition & tracking |
| 3 | **Acquisition** | 32-PRN search bar; pick a detected PRN → its **3D correlation surface** |
| 4 | **Tracking** | The **correlation triangle** from a real many-tap correlator; Early/Prompt/Late colored |
| 5 | **PVT** | CN0 bars, a **direction-of-arrival sky plot**, the computed position, and an **OpenStreetMap** view of it (UnicodeMaps.jl) |
| 6 | **Ecosystem** | The six JuliaGNSS packages + closing |

Navigate with **← / →** (or PgUp/PgDn). On the acquisition slide, **↑ / ↓** select the
previous/next detected PRN (shown on the acquisition and tracking slides), and **z**
toggles the correlation heatmap between the default full code-phase (0–1023
chips) view — where the peak moves over time — and a zoomed (±1.5 chips around the peak)
view. On the PVT slide, **+ / −** zoom the map, **h j k l** pan it (west/south/north/
east), and **0** recenters on the fix. **q** / **Esc** quits.

## Requirements

- **Julia ≥ 1.12**, started with **worker threads plus one interactive thread**:
  `julia -t auto,1` (or a modest `-t 6,1`). The `,1` gives the GUI its own interactive
  thread so it stays smooth while the receiver/DSP run on the worker pool.
- Any ANSI/truecolor terminal (Konsole, kitty, iTerm2, WezTerm, foot, …). All
  visuals — including the 3D acquisition surface and the map — are drawn with colored
  Unicode/braille characters, so **no sixel or kitty graphics protocol is required**.
  (An early sixel version of the surface was dropped: Tachikoma re-emits graphics every
  frame, which floods and can freeze some terminals.)
- Network access to download a slice of the sample recording, and (for the PVT slide's
  map) to fetch OpenStreetMap vector tiles via UnicodeMaps.jl. Without network the map
  panel stays blank; the numeric position + Google Maps link are still shown.

> **CPU note.** SignalChannels' lock-free channels busy-wait for microsecond latency;
> this app instead polls-with-sleep, so idle CPU stays low. Two knobs reduce it further:
> use fewer worker threads (idle-thread scheduler spin scales with the count — `-t 6,1`
> is plenty), and set `JULIA_THREAD_SLEEP_THRESHOLD=0` to make idle threads park
> immediately. Together these keep it to a couple of busy cores instead of maxing out.

## Setup

```bash
julia --project -e 'using Pkg; Pkg.instantiate()'
```

## Get the sample data

Downloads a bounded prefix of the public ION **LimeSDR** GPS L1 recording (10 MSPS,
int16 I/Q) via an HTTP range request:

```bash
julia --project scripts/download_data.jl --short   # ~4 s  (~160 MB) — spectrum/acq/tracking
julia --project scripts/download_data.jl           # ~40 s (~1.6 GB) — enough for a PVT fix
julia --project scripts/download_data.jl --full     # the entire file
```

A PVT position fix needs enough signal to decode the ephemeris (~30 s), so use the
default (or `--full`) for the PVT slide; the earlier slides work with `--short`.

> **Intermediate frequency.** The ION LimeSDR recording is **not at baseband** — its
> `.sdrx` metadata gives `translatedfreq = 420 kHz`, so GPS L1 sits at a 420 kHz IF in
> the file. The app defaults `interm_freq` to **420 kHz** for file replay (0 for a live
> SDR tuned to L1); override with `--if-khz`. For a different recording, read its IF from
> the `.sdrx` `<translatedfreq>` tag, and use `scripts/check_signal.jl` to verify it
> acquires (it prints per-PRN peak/noise and reveals a carrier offset).

> **PVT on file replay.** The recording is ~61.5 s. The receiver processes it **once**
> (a clean pass), converging to a healthy fix ~35 s in, and that fix is then **held** on
> screen. Looping a finite recording would jump GPS time backward at the seam and break
> the receiver's nav decode, so only the stateless front slides loop; the receiver plays
> through once. A longer recording or a live SDR gives continuously updating PVT.

## Run

```bash
julia --project -t auto,1 run.jl                 # real-time replay of the recording
julia --project -t auto,1 run.jl --no-realtime   # replay as fast as possible
julia --project -t auto,1 run.jl --path FILE     # a different int16 I/Q recording
julia --project -t auto,1 run.jl --sdr           # live from a SoapySDR device
```

Diagnostic switches (isolate CPU/behavior): `--no-acq` skips the acquisition slide +
task, `--no-receiver` skips the continuous receiver (no PVT). The app runs its GUI loop
on the interactive thread when you start Julia with `,1`.

**Startup is fast** (~3 s to the first frame): the expensive first-call compilation of
the acquisition, tracking, and receiver code paths is baked into the package's
**precompile cache** via a `PrecompileTools.@compile_workload`, so it is paid **once**
(during `Pkg.instantiate`/precompile, ~30 s) and reused by every `run.jl` afterwards —
no per-launch "warming up". Editing the source triggers one automatic recompile on the
next launch; unchanged code always starts from the cache.

### Live SDR

`run.jl --sdr` opens the first SoapySDR device at the GPS L1 frequency (1.57542 GHz,
10 MSPS) via SignalChannels.jl. You need SoapySDR plus a driver JLL for your hardware
(e.g. `SoapyLMS7_jll` for a LimeSDR). `--gain <dB>` sets the RX gain (default 60, which
reliably acquires GPS on an active antenna; drop it if you see clipping). The RX
frequency lives in `run.jl`'s `live_hub`.

**LiteX-M2SDR** (tested on an NVIDIA Jetson Orin): its SoapySDR plugin isn't a
registered JLL you can just `Pkg.add`, so build it from
[`enjoy-digital/litex_m2sdr`](https://github.com/enjoy-digital/litex_m2sdr)
(`software/build.py` — installs the kernel driver, `libm2sdr`, and the SoapySDR module),
then point Julia's SoapySDR at the system plugin:

```bash
export SOAPY_SDR_PLUGIN_PATH=/usr/lib/aarch64-linux-gnu/SoapySDR/modules0.8
julia --project -t auto,1 run.jl --sdr --gain 60
```

Two gotchas found on the Orin: (1) on IOMMU hosts the kernel driver needs the
zero-copy-mmap fix from [PR #150](https://github.com/enjoy-digital/litex_m2sdr/pull/150)
(without it SoapySDR RX streams mostly-zero buffers — see issue #149); and (2) the host
software (kernel + user + SoapySDR module) must be built from the **same commit as the
flashed FPGA gateware**, or CSR reads fail.

## How it streams (architecture)

One source (real-time-paced file replay, or a live SDR) is opened **once** and fanned
out to four always-drained branches — **receiver, periodogram, acquisition, tracking**.
The fan-out drains the source at full cadence and **drops-on-full per branch**, so a
slow or bursty consumer (the receiver during its periodic acquisition) never stalls the
source (which would overflow a real SDR) nor freeze the light slides. Slides only change
which branch's latest result is rendered — the stream and the receiver stay warm across
all of them. File replay is paced to `num_samples / fs` so it exercises this
backpressure exactly like a live SDR.

Key modules under `src/`:

- `source.jl` — persistent source + drop-on-full fan-out hub
- `triangle_correlator.jl` — a many-tap `AbstractEarlyPromptLateCorrelator` (integer-sample taps)
- `acq_surface.jl` — rasterizes the acquisition power surface into a sixel `PixelImage`
- `GNSSPresentation.jl` — the Tachikoma `Model`, background tasks, slide dispatch, entry point
- `slide_*.jl` — the seven slide renderers

## Tests

Headless (no TTY), using synthetic GPS signals and Tachikoma's `record_app`/buffers:

```bash
julia --project -t auto test/runtests.jl
```

Covers acquisition detection, the tracked correlation triangle, surface rasterization,
the flat periodogram, the full persistent-stream pipeline, and rendering every slide.
