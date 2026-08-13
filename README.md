# JuliaCon 2026 — Real-Time GNSS Positioning with JuliaGNSS

An interactive **terminal presentation** that drives a live software-defined GNSS
receiver ([JuliaGNSS](https://github.com/JuliaGNSS)) from one continuous stream of SDR
samples, built on [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl). Each
slide visualizes one stage of the receiver pipeline, live, from the same warm stream.

```
samples → spectrum → acquisition → tracking → decoding → PVT
```

The narrative the slides are built to tell — *how do you receive a signal quieter than
the environmental noise around it?* — along with why each stage exists and the timing
plan, is written down in **[STORY.md](STORY.md)**.

## Slides

| # | Slide | What it shows (live) |
|---|-------|----------------------|
| 0 | **Title** | The problem in three numbers (20 200 km · 10⁻¹⁶ W · 50× weaker than its own noise), a "● streaming" heartbeat, and a **QR code** to GNSSReceiver.jl |
| 1 | **Spectrum** | Live periodogram — a flat noise floor. The cold open: *here is the signal, and there is no signal* |
| 2 | **The trick** | The PRN code we already know, a replica you **slide into alignment on a keypress** (it locks green, and −18 dB becomes +15 dB), and the true size of the code-phase × Doppler search |
| 3 | **Acquisition** | 32-PRN search bar; pick a detected PRN → its **3D correlation surface**, one spike out of a flat plane |
| 4 | **Tracking** | The **correlation triangle** from a real many-tap correlator; Early/Prompt/Late colored |
| 5 | **Decoding** | **Starts the receiver.** A live subframe indicator (`1✓ 2✓ 3· 4◐ 5·`, naming what is on the air), the time-of-week, ephemeris values as they decode, and "N/M validated — need 4 for a fix" |
| 6 | **PVT** | CN0 bars, a **direction-of-arrival sky plot**, the computed position, and an **OpenStreetMap** view of it (UnicodeMaps.jl) |
| 7 | **Why Julia** | Tracking.jl's 3-tap default and this repo's 31-tap `TriangleCorrelator` **side by side**, sampling the same triangle — the multiple-dispatch story in one picture |
| 8 | **Ecosystem** | The JuliaGNSS packages, next steps + closing |

A pipeline strip rides along under the title on every slide. The current stage is
highlighted, and a stage turns **green only once it has actually succeeded on this run**
(satellites detected, ephemeris decoded, fix computed) — so it doubles as a progress bar
for the talk and as evidence that nothing on screen is canned.

Navigate with **← / →** (or PgUp/PgDn). On the "trick" slide, the local
replica starts deliberately misaligned and stays put until you press **space** (or `a`) —
so the slide can be talked over before anything moves; it then slides in over ~3.5 s and
**locks green** on alignment. **r** re-arms it to replay the beat. On the acquisition slide, **↑ / ↓** select the
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

> **Why the map used to be slow.** A cold first `worldmap` call cost ~3.5 s, of which only
> ~0.4 s was the network — the rest was first-call compilation, now paid at precompile time
> (`_warmup` renders a map against a deliberately unreachable `TileSource`, so the workload
> stays offline). On top of that, `worldmap`'s `source` keyword defaults to `TileSource()`,
> and a default argument is evaluated *per call*: every render re-fetched OpenFreeMap's
> TileJSON and threw away the decoded-tile cache, so each pan and zoom re-downloaded
> everything. The app now builds one `TileSource` and reuses it — a repeat render drops
> from ~0.35 s to ~0.02 s — and warms it with the tiles around the first fix as soon as
> that fix exists, before the PVT slide is ever shown.

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

> **The receiver starts late, on purpose.** It is *not* running during the intro: it
> starts the first time you reach the **Decoding** slide, on its own reader from the start
> of the recording. The audience then watches the ephemeris fill in from zero and the fix
> converge live — which is what makes the demo visibly not canned, and what paces it (the
> decode genuinely takes ~30 s, roughly the length of that slide). Revisiting the slide
> never starts a second receiver. If a rehearsal or the room's timing goes badly, pass
> `--eager-receiver` to warm it from startup instead.

## Run

```bash
julia --project -t auto,1 run.jl                 # real-time replay of the recording
julia --project -t auto,1 run.jl --no-realtime   # replay as fast as possible
julia --project -t auto,1 run.jl --path FILE     # a different int16 I/Q recording
julia --project -t auto,1 run.jl --sdr           # live from a SoapySDR device
```

Diagnostic switches (isolate CPU/behavior): `--no-acq` skips the acquisition slide +
task, `--no-receiver` skips the receiver entirely (no decoding, no PVT),
`--eager-receiver` starts the receiver at startup rather than on the decoding slide. The
app runs its GUI loop on the interactive thread when you start Julia with `,1`.

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

Gotcha found on the Orin: on IOMMU hosts the kernel driver needs the zero-copy-mmap fix
from [PR #150](https://github.com/enjoy-digital/litex_m2sdr/pull/150) (without it SoapySDR
RX streams mostly-zero buffers — see issue #149). Host software from a *newer* commit than
the flashed gateware is fine as long as the core CSR map (identifier / AD9361 / DMA /
crossbar) hasn't moved — it's been stable across recent releases, and verified: current
`main` software drives the 2026-05-15 gateware and acquires satellites. If CSR reads come
back all-`0xff` after repeated `rmmod`/`insmod`, the PCIe link is wedged — **reboot** to
reset it (the installed module auto-loads on boot).

## How it streams (architecture)

One source (real-time-paced file replay, or a live SDR) is opened **once** and fanned
out to four always-drained branches — **receiver, periodogram, acquisition, tracking**.
The fan-out drains the source at full cadence and **drops-on-full per branch**, so a
slow or bursty consumer (the receiver during its periodic acquisition) never stalls the
source (which would overflow a real SDR) nor freeze the light slides. Slides only change
which branch's latest result is rendered — the stream and the receiver stay warm across
all of them. File replay is paced to `num_samples / fs` so it exercises this
backpressure like a live SDR.

> **Pacing is easy to get wrong.** `sleep` cannot hit a 10 ms target exactly, and an
> earlier version of `_spawn_file_reader!` reset its deadline to `now` after every
> overshoot — forgiving the debt instead of repaying it, so "real-time" replay actually
> ran at **0.63×**, stretching the whole demo by ~1.6×. The reader now keeps an absolute
> schedule and only resyncs past `MAX_PACING_LAG`; there is a regression test for it. For
> reference, the receiver itself runs at ~1.9× real time, so it is never the limit here.

Key modules under `src/`:

- `source.jl` — persistent source + drop-on-full fan-out hub
- `triangle_correlator.jl` — a many-tap `AbstractEarlyPromptLateCorrelator` (integer-sample taps)
- `acq_surface.jl` — rasterizes the acquisition power surface into a sixel `PixelImage`
- `nav_snapshot.jl` — the custom `extract` payload that carries live decoder state
- `GNSSPresentation.jl` — the Tachikoma `Model`, background tasks, slide dispatch, entry point
- `slide_*.jl` — the nine slide renderers

**One reader per channel.** `SignalChannels` allows a single consumer per channel, and
nothing here violates that. The fan-out task in `source.jl` is the *only* consumer of the
source; it `put!`s into four branch channels, each drained by exactly one task. Decoding
and PVT are **not** separate consumers — there is one receiver, and one `extract` closure
lifts the decoder state *and* the PVT solution out of the same `ReceiverState` into a
single `NavSnapshot`, which both slides read. On file replay the receiver does not use its
hub branch at all: it gets its own private channel fed by a second, independent file
reader, so the two readers share only the path on disk.

## Tests

Headless (no TTY), using synthetic GPS signals and Tachikoma's `record_app`/buffers:

```bash
julia --project -t auto test/runtests.jl
```

Covers acquisition detection, the tracked correlation triangle, surface rasterization,
the flat periodogram, the full persistent-stream pipeline, the lazy receiver start (both
that it does *not* run before the decoding slide and that revisiting the slide never
starts a second one), the live nav-decode payload, and rendering every slide.
