# A custom, many-tap Early/Prompt/Late correlator for the tracking slide.
#
# The built-in `EarlyPromptLateCorrelator` / `VeryEarlyPromptLateCorrelator` hold a
# fixed 3 / 5 taps. To draw a high-resolution correlation *triangle* we track with a
# correlator that keeps one tap per integer sample shift across ±(N÷2) samples, while
# still exposing the ±½-chip Early/Late taps the DLL discriminator actually uses.
#
# Tracking shifts the code in whole samples only (see
# `Tracking.calc_preferred_code_shift_to_sample_shift`), so the tap grid is defined in
# integer samples. At 10 MHz there are ≈9.8 samples/chip, so ≈20 taps already span a
# full ±1-chip triangle; N≈31 (±15 samples ≈ ±1.5 chips) is comfortable.

using StaticArrays: SVector
using Unitful: Hz, ustrip
import Tracking:
    AbstractEarlyPromptLateCorrelator,
    NumAnts,
    get_correlator_sample_shifts,
    get_prompt_index,
    get_early_accumulator_index,
    get_late_accumulator_index,
    get_early,
    get_late,
    get_early_late_sample_spacing,
    update_accumulator,
    dll_disc,
    type_for_num_ants
import GNSSSignals: AbstractGNSSSignal, get_code_frequency

"""
    TriangleCorrelator{M,N,T}

Many-tap EPL correlator. `M` = number of antennas, `N` = number of taps (one per
integer sample shift, centered on Prompt), `T` = per-tap accumulator element
(`ComplexF64` for a single antenna). `shifts` holds the integer sample offsets; the
Prompt tap sits at the center (shift 0) and the Early/Late taps used by the DLL are at
`±round(½·fs/code_freq)` samples (≈ ±0.5 chip).
"""
struct TriangleCorrelator{M,N,T} <: AbstractEarlyPromptLateCorrelator{M}
    accumulators::SVector{N,T}
    shifts::SVector{N,Int}
    prompt_idx::Int
    early_idx::Int
    late_idx::Int
end

"""
    TriangleCorrelator(; sampling_freq, code_freq, num_ants=NumAnts(1),
                       num_taps=31, el_spacing_chips=0.5)

Build a zeroed triangle correlator. `num_taps` is forced odd so a Prompt tap sits
exactly at shift 0. The Early/Late taps are placed at the integer sample nearest
`el_spacing_chips` (default ±½ chip) — these are what the DLL tracks on and what the
tracking slide highlights.
"""
function TriangleCorrelator(;
    sampling_freq,
    code_freq,
    num_ants::NumAnts{M} = NumAnts(1),
    num_taps::Integer = 31,
    el_spacing_chips::Real = 0.5,
) where {M}
    N = isodd(num_taps) ? Int(num_taps) : Int(num_taps) + 1
    half = N ÷ 2
    shifts = SVector{N,Int}(ntuple(i -> i - 1 - half, N))
    prompt_idx = half + 1
    fs = Float64(ustrip(Hz, sampling_freq))
    fc = Float64(ustrip(Hz, code_freq))
    el = clamp(round(Int, el_spacing_chips * fs / fc), 1, half)
    early_idx = prompt_idx + el   # +shift → early (matches EPL convention)
    late_idx = prompt_idx - el    # -shift → late
    T = type_for_num_ants(num_ants)
    accs = zero(SVector{N,T})
    TriangleCorrelator{M,N,T}(accs, shifts, prompt_idx, early_idx, late_idx)
end

# ── Tracking correlator interface ────────────────────────────────────────────
# `get_accumulators` / `get_num_ants` / `get_num_accumulators` / `get_prompt` /
# `get_early` / `get_late` / `normalize` / `apply` / `zero` are inherited from
# Tracking's generic `AbstractCorrelator` methods (they only read `accumulators` and
# the index accessors below).

# Whole-sample shifts, fixed at construction (fs/code_freq already baked into the grid).
get_correlator_sample_shifts(c::TriangleCorrelator, sampling_frequency, code_frequency) =
    c.shifts

get_prompt_index(c::TriangleCorrelator) = c.prompt_idx
get_early_accumulator_index(c::TriangleCorrelator) = c.early_idx
get_late_accumulator_index(c::TriangleCorrelator) = c.late_idx

update_accumulator(c::TriangleCorrelator{M,N,T}, accumulators) where {M,N,T} =
    TriangleCorrelator{M,N,T}(
        SVector{N,T}(accumulators), c.shifts, c.prompt_idx, c.early_idx, c.late_idx)

# The code discriminator dispatches on the concrete correlator type; provide the same
# noncoherent early−late envelope discriminator the built-in EPL uses (our type has
# get_early/get_late/get_early_late_sample_spacing, so this is identical to
# `dll_disc(::AbstractGNSSSignal, ::EarlyPromptLateCorrelator, …)`).
function dll_disc(
    signal::AbstractGNSSSignal,
    correlator::TriangleCorrelator,
    code_doppler,
    sampling_frequency,
)
    code_frequency = code_doppler + get_code_frequency(signal)
    code_phase_delta = code_frequency / sampling_frequency
    E = abs(get_early(correlator))
    L = abs(get_late(correlator))
    distance_between_early_and_late =
        get_early_late_sample_spacing(correlator, sampling_frequency, code_frequency) *
        code_phase_delta
    (2 - distance_between_early_and_late) / 2 * (E - L) / (E + L)
end

"""
    tap_offsets_chips(c, sampling_freq, code_freq) -> Vector{Float64}

Code offset (in chips) of every tap — the x-axis for the correlation-triangle plot.
"""
function tap_offsets_chips(c::TriangleCorrelator, sampling_freq, code_freq)
    fs = Float64(ustrip(Hz, sampling_freq))
    fc = Float64(ustrip(Hz, code_freq))
    Float64.(c.shifts) .* (fc / fs)
end
