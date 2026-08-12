# Slide 2 — the answer to the question slide 1 poses: how do you receive something
# quieter than the environmental noise around it? Because you already know what it says.
#
# The navigation message and the PRN code are two layers four orders of magnitude apart
# in time, and a local replica has to be aligned to the incoming signal in *two* unknown
# dimensions at once — code phase and Doppler. Aligning it is what converts the known
# code into gain: 50 bit/s of information spread over 1.023 Mchip/s, so one code period
# of coherent summation lifts the signal from ~18 dB below the noise to ~15 dB above it.
# The correlation triangle deliberately does NOT appear here; it belongs on the tracking
# slide, where it is a real measurement rather than a diagram.
#
# The search-space figures in ④ are derived from the real `AcquisitionPlan` (published by
# whichever background task builds one first — see `_publish_acq_space!`), so the
# "computationally intensive" claim is checkable rather than merely plausible.

# Draw a ±1 code as a two-row bipolar square wave: +1 chips fill `toprow`, −1 chips fill
# `botrow`, `cpc` cells per chip. Chip `c0` (0-based) is placed at `x = xanchor +
# (c0−cp)·cpc`, clipped to [xlo, xhi]; `cp` shifts the whole pattern (used for the tracked
# code phase on slide 4 and for the sliding replica below). Shared with the tracking slide.
function _draw_code_wave!(buf, xlo::Int, xhi::Int, toprow::Int, botrow::Int, code, L::Int,
    cp::Float64, cpc::Int, xanchor::Int;
    plus = tstyle(:primary, bold = true), minus = tstyle(:primary, dim = true))
    c0min = floor(Int, cp - (xanchor - xlo) / cpc) - 1
    c0max = ceil(Int, cp + (xhi - xanchor) / cpc) + 1
    for c0 in c0min:c0max
        x0 = xanchor + round(Int, (c0 - cp) * cpc)
        val = code[mod1(c0 + 1, L)]
        row = val > 0 ? toprow : botrow
        st = val > 0 ? plus : minus
        for dx in 0:cpc-1
            x = x0 + dx
            (x < xlo || x > xhi) && continue
            set_char!(buf, x, row, '█', st)
        end
    end
    return
end

# A fixed stand-in for the navigation message. The real bits are decoded on slide 5; here
# they only have to show the *time scale* — one bit spanning 20 whole code repetitions.
const NAV_BIT_PATTERN = Int8[1, 1, -1, 1, -1, -1, -1, 1, 1, -1, 1, 1, 1, -1, -1, 1, -1, 1, -1, -1]

# "41 million", not "41.0 million"; "10 000", not "10000".
_trim1(x::Real) = (r = round(x; digits = 1); r == round(r) ? string(round(Int, r)) : string(r))
_fmt_count(n::Real) = n >= 1e9 ? "$(_trim1(n / 1e9)) billion" :
                      n >= 1e6 ? "$(_trim1(n / 1e6)) million" :
                      n >= 1e3 ? "$(_trim1(n / 1e3)) thousand" : string(round(Int, n))
_thousands(n::Integer) = replace(string(n), r"(?<=[0-9])(?=(?:[0-9]{3})+$)" => " ")

# "4.1·10¹¹" rather than 4.1e11 — reads aloud from the back of the room.
const SUPERSCRIPT_DIGITS = ('⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹')
_superscript(e::Integer) = join(SUPERSCRIPT_DIGITS[d-'0'+1] for d in string(e))

function _fmt_pow10(n::Real)
    n <= 0 && return "0"
    e = floor(Int, log10(n))
    "$(round(n / 10.0^e; digits = 1))·10$(_superscript(e))"
end

# How far off the replica starts, and how long the search takes once triggered. A few
# chips is enough to be unmistakably misaligned at 2 cells/chip while still resolving as
# the *same* code pattern, so the audience sees a shift rather than a different signal.
const CHASE_START_CHIPS = 7.0
const CHASE_DURATION = 3.5     # seconds

"""
    _chase_phase!(m) -> (offset_chips, state)

Current replica offset and search state, advancing `:sliding → :locked` when the offset
reaches zero. Called from the renderer (the only place that knows the slide is visible),
so the animation runs only while slide 2 is on screen.
"""
function _chase_phase!(m::PresentationModel)
    @lock m.lk begin
        m.chase_state == :waiting && return (CHASE_START_CHIPS, :waiting)
        m.chase_state == :locked && return (0.0, :locked)
        frac = (time() - m.chase_t0) / CHASE_DURATION
        if frac >= 1.0
            m.chase_state = :locked
            return (0.0, :locked)
        end
        return (CHASE_START_CHIPS * (1 - frac), :sliding)
    end
end

function render_explain(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    c = render(Block(; title = "The trick: I already know what it is going to say",
            border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), area, buf)
    (c.width < 40 || c.height < 14) && return
    x = c.x + 2
    y = c.y
    wx = x + 11                       # wave column (leaves room for row labels)

    L = get_code_length(m.system)
    cf = get_code_frequency(m.system)
    code = gen_code(L, m.system, 1, cf, cf, 0.0)               # 1 sample/chip → ±1

    # ── ① the navigation message ──────────────────────────────────────────────
    set_string!(buf, x, y, "① The navigation message — 50 bit/s, one bit lasts 20 ms. All the information there is.",
        tstyle(:text); max_x = right(c)); y += 1
    navcpc = 9                        # cells per navigation bit
    set_string!(buf, x, y, "bits", tstyle(:text_dim); max_x = wx - 1)
    _draw_code_wave!(buf, wx, right(c), y, y + 1, NAV_BIT_PATTERN, length(NAV_BIT_PATTERN),
        0.0, navcpc, wx; plus = tstyle(:secondary, bold = true),
        minus = tstyle(:secondary, dim = true))
    y += 2
    # The bracket must span exactly ONE bit, or it silently mis-states the time scale.
    set_string!(buf, wx, y, "└" * "─"^max(0, navcpc - 2) * "┘", tstyle(:text_dim); max_x = right(c))
    set_string!(buf, wx + navcpc + 1, y, "one bit = 20 ms = 20 whole repetitions of the code below",
        tstyle(:text_dim); max_x = right(c)); y += 1
    set_string!(buf, wx + 12, y, "╲   zoom in ×20 000   ╱", tstyle(:accent); max_x = right(c))
    y += 2

    # ── ② the code ────────────────────────────────────────────────────────────
    set_string!(buf, x, y, "② The PRN code — 1023 chips at 1.023 Mchip/s, repeating every 1 ms",
        tstyle(:text); max_x = right(c)); y += 1
    set_string!(buf, x, y, "PRN 1", tstyle(:text_dim); max_x = wx - 1)
    _draw_code_wave!(buf, wx, right(c), y, y + 1, code, L, 0.0, 2, wx)
    y += 2
    # The whole talk turns on this line: the code is known, so it can be correlated for.
    set_string!(buf, wx, y, "every bit smeared over $(_thousands(20L)) chips — and we know all 32 sequences exactly. That is the trick.",
        tstyle(:text_dim); max_x = right(c))
    y += 2

    # ── ③ the chase: a replica that has to be aligned ─────────────────────────
    y > bottom(c) - 6 && return
    set_string!(buf, x, y, "③ What arrives = code × nav bit, on a carrier of unknown Doppler — and 18 dB under the noise",
        tstyle(:text); max_x = right(c)); y += 1
    set_string!(buf, x, y, "received", tstyle(:text_dim); max_x = wx - 1)
    _draw_code_wave!(buf, wx, right(c), y, y + 1, code, L, 0.0, 2, wx)
    y += 2

    # The replica sits misaligned until the presenter starts the search (space), so this
    # can be talked over before anything moves; then it slides in and locks green. Driven
    # by wall time, not frame count, so `--fps` doesn't change how long the beat takes.
    cp, state = _chase_phase!(m)
    rstyle = state == :locked ? (tstyle(:success, bold = true), tstyle(:success, dim = true)) :
             (tstyle(:warning, bold = true), tstyle(:warning, dim = true))
    set_string!(buf, x, y, "my replica", tstyle(:text_dim); max_x = wx - 1)
    _draw_code_wave!(buf, wx, right(c), y, y + 1, code, L, cp, 2, wx;
        plus = rstyle[1], minus = rstyle[2])
    y += 2
    msg, mstyle = state == :waiting ?
                  ("off by $(round(cp; digits = 1)) chips — press [space] to start searching",
        tstyle(:text_dim)) :
                  state == :sliding ?
                  ("searching… off by $(round(cp; digits = 1)) chips", tstyle(:warning)) :
                  ("● aligned — and 1 ms of adding up turns −18 dB into +15 dB. That is a satellite, found.",
        tstyle(:success, bold = true))
    set_string!(buf, wx, y, msg, mstyle; max_x = right(c))
    y += 2

    # ── ④ the size of the search ──────────────────────────────────────────────
    #
    # The code-phase count is `samples_per_code` (10 000 at 10 MSPS), NOT the 1023 chips —
    # the search resolves phase at sample spacing, ~9.8 samples per chip. Spelled out on
    # screen because bare "10 000" next to "1023 chips" two lines above reads as a typo.
    y > bottom(c) - 4 && return
    set_string!(buf, x, y, "④ Two unknowns, searched together:",
        tstyle(:text); max_x = right(c)); y += 1
    sp = s.acq_space
    if sp === nothing
        set_string!(buf, x + 3, y, "code phase (where the code starts)  ×  Doppler (how fast it is moving)",
            tstyle(:secondary); max_x = right(c)); y += 1
    else
        # Where 10 000 comes from, spelled out: fs × one code period. Without the sample
        # rate on screen the number looks like it should have been 1023.
        fs_msps = _trim1(Float64(ustrip(Hz, m.fs)) / 1e6)
        period_ms = _trim1(1000 * L / Float64(ustrip(Hz, cf)))
        set_string!(buf, x + 3, y,
            "code phase  $(_thousands(sp.code_phases)) offsets — one per sample: $(fs_msps) MSPS × $(period_ms) ms code period = $(sp.chips) chips at $(round(sp.samples_per_chip; digits = 1)) samples/chip",
            tstyle(:secondary); max_x = right(c)); y += 1
        y > bottom(c) && return
        set_string!(buf, x + 3, y,
            "Doppler  $(sp.doppler_bins) bins, $(round(Int, sp.doppler_spacing_hz)) Hz apart, covering ±$(_thousands(round(Int, sp.doppler_span_hz / 2))) Hz   ×   $(sp.prns) satellites",
            tstyle(:secondary); max_x = right(c)); y += 1
        y > bottom(c) && return
        set_string!(buf, x + 3, y,
            "= $(_fmt_count(sp.hypotheses)) alignments to test, each a $(_thousands(sp.code_phases))-sample correlation ≈ $(_fmt_pow10(sp.operations)) operations",
            tstyle(:primary, bold = true); max_x = right(c)); y += 1
        y > bottom(c) && return
        # The question this always gets. Integrating longer does NOT add code phases —
        # the code repeats every 1 ms, so phase is ambiguous modulo one period.
        set_string!(buf, x + 3, y,
            "Integrating $(sp.coh_periods) code periods coherently buys $(round(Int, 10log10(sp.coh_periods))) dB more and divides the Doppler spacing by $(sp.coh_periods) — the code-phase axis stays $(_thousands(sp.code_phases)).",
            tstyle(:text_dim); max_x = right(c)); y += 1
    end
    y > bottom(c) && return
    set_string!(buf, x + 3, y,
        "…every few seconds, because they never stop moving. Nobody does this by brute force.",
        tstyle(:text_dim); max_x = right(c))
    return
end
