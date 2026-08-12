# The story

The narrative plan for *Real-Time GNSS Positioning with JuliaGNSS: From SDR Signals to
Your Location* — JuliaCon 2026, 12 minutes.
Abstract: <https://pretalx.com/juliacon-2026/talk/Z38XCK/>

This file is the script-level companion to the code. The slides implement it; this
explains *why* each slide exists and what it must leave the audience wanting.

## The frame: a whisper quieter than the environmental noise

The talk is a detection story. One sentence carries it, and it can be said from memory:

> **How do you receive a signal that is quieter than the environmental noise around it?
> You already know what it is going to say.**

Everything else is that sentence, in order. The problem is stated in three numbers on the
title slide, all of them derivable rather than decorative:

1. **20 200 km** — where the signal is sent from, by something moving at 3.9 km/s.
2. **10⁻¹⁶ W** — what actually reaches the antenna. IS-GPS-200 guarantees −158.5 dBW.
3. **50× weaker than its own noise** — thermal noise in the 2 MHz main lobe is
   kTB ≈ −141 dBW, so the signal sits ~17.5 dB *under* it. You cannot see it. There is
   nothing to point at.

The trick is deliberately withheld until slide 2. Slide 1 must be allowed to fail first.

### The arithmetic spine

Every stage of the talk is one step of the same sum, and the numbers hang together — this
is worth knowing cold, because it is the question the audience will ask:

| Quantity | Value | Where it comes from |
|---|---|---|
| C/N₀ | ~45 dBHz | −158.5 dBW against N₀ = −204 dBW/Hz |
| SNR in the raw 2 MHz band | **−18 dB** | 45 − 10log₁₀(2·10⁶) |
| chips per bit | **20 460** | 1.023 Mchip/s ÷ 50 bit/s |
| SNR after 1 ms of correlation | **+15 dB** | 45 − 10log₁₀(10³) |

So one code period of coherent summation swings the signal by 33 dB, from 18 dB below the
noise to 15 dB above it. That is the entire reason any of this works, and the acquisition
slide's CN0 bars (40–54 dBHz) are that same number, measured live, on stage.

### Why the receiver starts late

The receiver (tracking → decoding → PVT) does **not** run from startup. It starts the
moment the decoding slide is first shown, and the audience watches the ephemeris fill in
from zero and the fix converge in real time.

This is the single most important staging decision in the talk, because it answers the
skepticism that shadows every live demo: it cannot be canned. It also self-paces the
demo — the decode genuinely takes ~30 s, which is roughly the length of the decoding
slide.

The cost is that we are hostage to 50 bit/s. If the talk runs ahead of the satellites, we
stand and wait — so the progress bar has to make waiting *legible*. Under this frame the
line to say while it fills is **"we spent 33 dB getting to the point where we can read
fifty bits a second — and now we have to actually read them."** `--eager-receiver`
pre-warms the receiver if a rehearsal or the room's timing goes badly.

### Measured timings — verify these on the presentation machine

Against the real ION LimeSDR recording (50 s prefix, 420 kHz IF), measured from the
moment the decoding slide is entered, on a 24-core container:

| Event | t |
|---|---|
| first satellite tracked | 1.2 s |
| first time-of-week decoded | 11.6 s |
| first ephemeris value on screen | 17.7 s |
| ephemeris validated → **first PVT fix** | 41.9 s |

The fix lands at 52.177171° N, 4.490035° E with 10 satellites.

So the decoding and PVT slides together have to cover roughly 45 s. That fits the budget
below, but it is worth timing on the presentation machine — and if it runs long, the
receiver can be started a slide earlier (Tracking) for ~75 s of head start.

**The receiver is not the bottleneck.** It processes the stream at about **1.9× real
time** under full app load (measured with `--no-realtime`: 49.9 s of signal in 26.1 s of
wall clock, reaching a fix 15.9 s after the slide opens). The talk's "keeps up with the
antenna" claim holds with room to spare.

What *was* slow was the file replay's own pacing — see the pacing note in
`_spawn_file_reader!`. Two fixes took the paced reader from 0.63× to ~0.87× under load
(0.99× in isolation, with nothing consuming it). The residue is scheduler contention on a
busy thread pool, not DSP throughput, and a live SDR does not have the problem at all
because the hardware clocks the samples. **Expect the live demo to converge faster than
the file rehearsal, not slower.**

## Slide beats

Every slide ends on the problem the next one solves. That is the difference between a
tour and a story: each stage exists because the previous stage left something broken.

| # | Slide | Beat | Leaves you with |
|---|-------|------|-----------------|
| 0 | Title | 10⁻¹⁶ W, 50× under its own noise; the receiver knows nothing | You cannot see it — so how? |
| 1 | Spectrum | **The cold open.** "Here is the signal." Flat line. Nothing | How do you receive what is quieter than the environmental noise? |
| 2 | The trick | Because you know what it says. Align the known code → −18 dB becomes +15 dB | Which satellite? What code phase? What Doppler? |
| 3 | Acquisition | The 2D search, live, and the peak erupting from a flat plane | Found them — but they move at 3.9 km/s and the peak slides away |
| 4 | Tracking | Early/Prompt/Late holds the whisper; delay now measurable to nanoseconds | We can hear it. What is it *saying*? |
| 5 | **Decoding** | **The receiver starts here.** Values pop in one 30-bit word at a time | 4 satellites ready — now we can solve |
| 6 | PVT | Ten whispers, all located. Four unknowns: x, y, z **and the clock** | From nothing, on stage |
| 7 | Why Julia | 10 MSPS of digging, live, in a dynamic language | — |
| 8 | Ecosystem | v1.0 milestone, next steps, how to join | — |

### Slide 1 in detail

The flatness *is* the content. Do not explain it away — say "I promised you a live GPS
receiver; here is the signal," and let the room sit with a flat line for a beat. The
caption states the fact (~18 dB under the floor) and then poses the question in accent
colour. It is the only slide whose job is to make the audience feel stuck.

### Slide 2 in detail

Nav bits (20 ms) and chips (1 µs) are four orders of magnitude apart and cannot share a
time axis, so the zoom between them is drawn explicitly rather than faked:

1. the navigation message at 50 bit/s — *all the information there is*;
2. the 1023-chip PRN code at 1.023 Mchip/s, so every bit is smeared over **20 460
   chips** — and we know all 32 sequences exactly. That is the trick, stated outright;
3. what actually arrives — code × nav bit, on a carrier of unknown Doppler, 18 dB under
   the noise — with a local replica *sliding* underneath it. On lock: **"1 ms of adding
   up turns −18 dB into +15 dB."** That is the talk's central claim, and it fires on a
   keypress;
4. the two unknowns, searched together, with the hypothesis count.

The numbers in (4) are computed at render time from the real `plan_acquire`
configuration, not hardcoded, so the claim is truthful rather than merely plausible.

**The code-phase count is `samples_per_code`, not 1023.** At 10 MSPS a 1 ms code period
is 10 000 samples, so the search tests 10 000 code-phase offsets — one per sample, about
9.8 samples per chip. The 1023 chips are the code's *length*; the sample rate sets the
*resolution*, and sub-chip resolution is what buys sub-300 m ranging. The slide states
`10 MSPS × 1 ms = 10 000 = 1023 chips at 9.8 samples/chip` explicitly, because bare
"10 000" two lines under "1023 chips" reads as a typo.

Coherent integration does **not** widen that axis. The code repeats every 1 ms, so code
phase is ambiguous modulo one code period no matter how long you integrate. What
integrating N code periods buys is 10log₁₀(N) dB of gain and an N× finer Doppler grid
(`spacing = fs / samples_per_code / N`); this plan uses N = 4, so 6 dB and 250 Hz bins.
The slide says so on its own line — it is the first question anyone with DSP background
will ask.

This slide deliberately has **no correlation triangle**. The triangle answers a question
nobody has asked yet at this point; it belongs on the tracking slide, where it is a real
measurement rather than a diagram.

The hinge into acquisition: a naive search is ~2·10¹¹ operations, so **nobody does it by
brute force** — which is exactly why `Acquisition.jl` uses an FFT-based parallel
code-phase search and the next slide finishes in milliseconds.

The nav-bit layer here also plants the 50 bit/s message four minutes before the decoding
slide needs it, so it arrives as an old friend rather than a new concept.

### Slide 5 in detail

`GNSSDecoder.GPSL1CAData` is a `@kwdef` struct in which every field is
`Union{Nothing,T}` defaulting to `nothing`, rebuilt once per parity-checked 30-bit word.
So `decoder.raw_data` is already an incremental accumulator: fields flip `nothing →
value` roughly every 0.6 s and fill over ~18 s.

Read **`raw_data`, not `data`** — `data` is all-or-nothing and stays blank until
subframes 1–3 all validate.

Three decoder fields turned out to be traps, all found by running against the real
recording rather than synthetic signals:

- **`raw_data` is not a monotonically filling buffer.** `confirm_data` promotes it into
  `data` on a successful validation and blanks it on several branches, so a grid that
  reads `raw` alone empties itself the moment the ephemeris validates — while `complete`
  and the time-of-week stay on screen. Read the validated copy and fall back to the
  provisional one.
- **`num_bits_after_valid_syncro_sequence` stays `nothing`** long after words are
  demonstrably decoding, so a progress bar driven from it reads "searching for the
  preamble… 0/300" while values are landing. Count arrived orbit numbers instead.
- **`TOW` is cleared** whenever the next one isn't exactly previous+1, so it flickers and
  has to be latched.

Values are shown the instant they decode, never held back. `GNSSDecoder` can only hand
them over a subframe at a time (`decode_syncro_sequence` waits for all 300 bits, then
decodes ten words in one call), so the grid fills in three jumps of nine. What carries the
wait *between* jumps is the **subframe indicator**: `subframes 1✓ 2✓ 3· 4◐ 5·` plus a
caption naming what is on the air. It also earns its place as teaching — when it says
*"subframe 4 — almanac, not needed"* it is explaining out loud why a fix takes ~30 s and
not ~18: all five subframes cycle every 30 s, and if you tune in during 4 you wait for the
cycle to come round.

Four panels: a decode-progress bar counting orbit numbers received; one hero PRN's 26 ephemeris slots
grouped by subframe; one plain-language line on what the numbers *mean* (this is the
satellite's orbit — with it we know exactly where it was when it sent this bit); and a
per-PRN readiness strip carrying the suspense counter, **"N/M validated — need 4 for a
fix"**, which is what pays off into PVT. The strip's dots mean *subframes received* and
the tick means *validated for positioning*; they have to read differently, or all three
dots lit next to "0 validated" looks like a contradiction.

### Slide 7 in detail

Do not reach for a benchmark table. The stronger argument is sitting in this repo:

- `src/triangle_correlator.jl` is a **user-defined** `AbstractEarlyPromptLateCorrelator`
  that `Tracking.jl` accepts without ever having heard of it;
- `receive`'s `extract` hook let us reach into the receiver's internals with a closure
  and get a typed channel back — no plugin API, no fork;
- one stream at 10 MSPS fanned out to four consumers, no C in the hot loop;
- 3 s to first frame, because the compile workload is baked into the precompile cache.

The presentation *is* the composability proof.

## Time budget

Maps onto the abstract's promised 6 / 4 / 2 split.

| Time | Content |
|------|---------|
| 0:00–1:15 | Hook: 10⁻¹⁶ W, 50× under its own noise, and why an open receiver matters |
| 1:15–2:00 | Spectrum — the cold open. There is nothing there |
| 2:00–3:30 | The trick (the conceptual core; do not rush it) |
| 3:30–5:00 | Acquisition — live, the peak out of the flat plane |
| 5:00–6:15 | Tracking |
| 6:15–7:15 | Decoding — **receiver starts**; ephemeris fills live (~18 s to first value) |
| 7:15–8:30 | PVT — the fix lands (~42 s after the decoding slide opened) |
| 8:30–10:30 | Why Julia |
| 10:30–12:00 | Ecosystem, next steps, close |

## Devices

- **Persistent pipeline header.** The intro's `Samples → Acquisition → Tracking →
  Decoding → PVT` diagram rides along on every slide, current stage highlighted,
  completed stages turning green *when they actually succeed live*. The diagram becomes
  a progress bar for the story and keeps the audience oriented.
- **Questions, not summaries.** Each slide's closing caption poses the next slide's
  question rather than restating what was just shown.
- **Every number on screen is computed, not typed.** The search-space figures come from
  the live `AcquisitionPlan`, the package versions from `pkgversion`, the CN0 bars from
  the real detector. If someone in the audience checks the arithmetic, it holds.
