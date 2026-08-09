# Live navigation-decode state for the decoding slide.
#
# `receive`'s default payload (`ReceiverDataOfInterest`) carries only CN0, prompt, health
# and the PVT solution — nothing about the decoder. But `receive` takes an `extract`
# keyword, called once per processed chunk on the `ReceiverState`, whose return type
# becomes the channel's element type. So we pass our own, emitting the default fields
# *plus* a snapshot of each satellite's navigation decoder.
#
# The interesting field is `GNSSDecoderState.raw_data`: a `GPSL1CAData` in which every
# field is `Union{Nothing,T}` defaulting to `nothing`, rebuilt once per parity-checked
# 30-bit word. It is therefore already an incremental accumulator — fields flip
# `nothing → value` roughly every 0.6 s and fill over ~18 s, which is exactly the
# value-by-value reveal the slide wants. `data` (the *validated* ephemeris) is
# all-or-nothing and stays blank until subframes 1–3 all pass the IODC/IODE cross-check,
# so the slide reads `raw` for arrival and `data` only to mark values confirmed.
#
# `extract` must be read-only and return an immutable value: it runs inside the tracking
# loop on a `ReceiverState` that the next chunk mutates in place. `GPSL1CAData` is
# immutable and is replaced (not mutated) on each decoded word, so holding a reference is
# safe. The enclosing `GNSSDecoderState` is NOT — its `cache.soft_buffer` is a
# `CircularDeque` mutated in place — so we never keep one.

"Per-satellite snapshot: the default receiver fields plus live decoder state."
struct NavSatSnapshot{P,D}
    cn0::typeof(1.0u"dBHz")
    prompt::P
    is_healthy::Bool
    raw::D                  # incremental accumulator — fills word by word
    data::D                 # validated ephemeris — all-or-nothing
    bits_in_subframe::Int   # symbols since the last valid sync, or -1 if never synced
    complete::Bool          # ephemeris usable for positioning
end

"Per-chunk receiver snapshot. Field names match `GUIData` so the PVT slide is unchanged."
struct NavSnapshot{S<:NavSatSnapshot}
    sat_data::Dictionary{Int,S}
    pvt::PVTSolution
    runtime::typeof(1.0u"s")
end

"`extract` for `receive`: the default data of interest plus per-satellite decoder state."
function nav_data_of_interest(rs)
    # `map` over Tracking's PRN-keyed Dictionary keeps the keys and shares its `Indices`
    # with the payload — safe for the same reason the upstream default is (the receiver
    # only ever rebuilds the satellite set functionally).
    sat_data = map(get_sat_states(rs.track_state)) do sat_state
        decoder = rs.receiver_sat_states[1][sat_state.prn].decoder
        NavSatSnapshot(
            estimate_cn0(sat_state),
            get_prompt(get_last_fully_integrated_correlator(sat_state)),
            is_sat_healthy(decoder),
            decoder.raw_data,
            decoder.data,
            something(decoder.num_bits_after_valid_syncro_sequence, -1),
            is_decoding_completed_for_positioning(decoder),
        )
    end
    NavSnapshot(sat_data, rs.pvt, rs.runtime)
end

"""
    nav_gui_channel(data_channel, every = 100u"ms") -> Channel{NavSnapshot}

Downsample `receive`'s per-chunk output to a human refresh rate, the way GNSSReceiver's
own `get_gui_data_channel` does — but for our payload, since that one is typed to
`Channel{GUIData}` and would drop the decoder fields.

`every` is deliberately shorter than the upstream 500 ms default: values land at word
granularity (~0.6 s apart) and the slide flashes each one as it arrives, so a coarse
refresh would swallow the reveal.
"""
function nav_gui_channel(data_channel, every = 100u"ms")
    out = Channel{NavSnapshot}()
    last_out = 0.0u"ms"
    first = true
    Base.errormonitor(Threads.@spawn begin
        consume_channel(data_channel) do data
            if first || (data.runtime - last_out) > every
                push!(out, data)
                last_out = data.runtime
                first = false
            end
        end
        close(out)
    end)
    out
end

# ── Ephemeris field catalogue (drives the decoding slide's value grid) ────────
#
# The subset of `GPSL1CAData` worth showing: enough to fill the panel and tell the story
# (clock → orbit shape → orbit orientation), not the full 60-odd fields. Order within a
# group is roughly transmission order, so the grid fills top-to-bottom as words arrive.
# Names are the decoder's own — note the Unicode ones (Δn, Ω_0, Ω_dot, ω), and that IODC
# and IODE arrive as bit *strings*, not numbers.

const EPHEMERIS_GROUPS = (
    ("Subframe 1 — clock", (
        (:trans_week, "WN"), (:ura, "URA"), (:sv_health, "health"), (:IODC, "IODC"),
        (:T_GD, "T_GD"), (:t_0c, "t_oc"),
        (:a_f2, "a_f2"), (:a_f1, "a_f1"), (:a_f0, "a_f0"),
    )),
    ("Subframe 2 — orbit shape", (
        (:IODE_Sub_2, "IODE"), (:C_rs, "C_rs"), (:Δn, "Δn"), (:M_0, "M_0"),
        (:C_uc, "C_uc"), (:e, "e"), (:C_us, "C_us"), (:sqrt_A, "√A"), (:t_0e, "t_oe"),
    )),
    ("Subframe 3 — orbit orientation", (
        (:C_ic, "C_ic"), (:Ω_0, "Ω_0"), (:C_is, "C_is"), (:i_0, "i_0"),
        (:C_rc, "C_rc"), (:ω, "ω"), (:Ω_dot, "Ω̇"), (:i_dot, "i̇"),
    )),
)

"Every catalogued field, flat — used to rank how far along a satellite's decode is."
const EPHEMERIS_FIELDS = Tuple(first(f) for grp in EPHEMERIS_GROUPS for f in last(grp))

"Format a decoded ephemeris value compactly enough for a grid cell."
function fmt_eph(v)
    v === nothing && return nothing
    v isa AbstractString && return length(v) > 10 ? v[1:10] : String(v)
    v isa Integer && return string(v)
    if v isa Real
        a = abs(v)
        (a != 0 && (a < 1e-4 || a >= 1e6)) && return replace(string(round(v; sigdigits = 4)), "e" => "e")
        return string(round(v; sigdigits = 6))
    end
    string(v)
end
