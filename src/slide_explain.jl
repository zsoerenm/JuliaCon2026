# Slide 2 — what the signal actually looks like, and why finding it is expensive.
#
# This slide sets up acquisition by posing the problem, not by showing its answer: the
# navigation message and the PRN code are two layers four orders of magnitude apart in
# time, and a local replica has to be aligned to the incoming signal in *two* unknown
# dimensions at once — code phase and Doppler. The correlation triangle deliberately does
# NOT appear here; it belongs on the tracking slide, where it is a real measurement
# rather than a diagram.
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

function render_explain(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    c = render(Block(; title = "The signal I have to chase", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), area, buf)
    (c.width < 40 || c.height < 14) && return
    x = c.x + 2
    y = c.y
    wx = x + 11                       # wave column (leaves room for row labels)

    L = get_code_length(m.system)
    cf = get_code_frequency(m.system)
    code = gen_code(L, m.system, 1, cf, cf, 0.0)               # 1 sample/chip → ±1

    # ── ① the navigation message ──────────────────────────────────────────────
    set_string!(buf, x, y, "① The navigation message — 50 bit/s, one bit lasts 20 ms",
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
    set_string!(buf, wx, y, "each chip ~1 µs — a unique sequence per satellite, and we know all of them",
        tstyle(:text_dim); max_x = right(c))
    y += 2

    # ── ③ the chase: a replica that has to be aligned ─────────────────────────
    y > bottom(c) - 6 && return
    set_string!(buf, x, y, "③ What arrives = code × nav bit, on a carrier of unknown Doppler",
        tstyle(:text); max_x = right(c)); y += 1
    set_string!(buf, x, y, "received", tstyle(:text_dim); max_x = wx - 1)
    _draw_code_wave!(buf, wx, right(c), y, y + 1, code, L, 0.0, 2, wx)
    y += 2
    # The replica slides continuously: this is the chase, and it never lines up by luck.
    # The offset starts well away from zero so the very first frame already shows a
    # mismatch rather than a suspiciously perfect alignment.
    cp = mod(m.tick * 0.17 + 7.3, Float64(L))
    set_string!(buf, x, y, "my replica", tstyle(:text_dim); max_x = wx - 1)
    _draw_code_wave!(buf, wx, right(c), y, y + 1, code, L, cp, 2, wx;
        plus = tstyle(:warning, bold = true), minus = tstyle(:warning, dim = true))
    y += 2
    set_string!(buf, wx, y, "…which is off by $(round(cp; digits = 1)) chips right now. Slide it until it matches.",
        tstyle(:text_dim); max_x = right(c))
    y += 2

    # ── ④ the size of the search ──────────────────────────────────────────────
    y > bottom(c) - 3 && return
    set_string!(buf, x, y, "④ Two unknowns, searched together:",
        tstyle(:text); max_x = right(c)); y += 1
    sp = s.acq_space
    if sp === nothing
        set_string!(buf, x + 3, y, "code phase (where the code starts)  ×  Doppler (how fast it is moving)",
            tstyle(:secondary); max_x = right(c)); y += 1
    else
        set_string!(buf, x + 3, y,
            "code phase  $(_thousands(sp.code_phases)) offsets   ×   Doppler  $(sp.doppler_bins) bins over ±$(_thousands(round(Int, sp.doppler_span_hz / 2))) Hz   ×   $(sp.prns) satellites",
            tstyle(:secondary); max_x = right(c)); y += 1
        set_string!(buf, x + 3, y,
            "= $(_fmt_count(sp.hypotheses)) alignments to test, each a $(_thousands(sp.code_phases))-sample correlation ≈ $(_fmt_pow10(sp.operations)) operations",
            tstyle(:primary, bold = true); max_x = right(c)); y += 1
    end
    y > bottom(c) && return
    set_string!(buf, x + 3, y,
        "…every few seconds, because they never stop moving. Nobody does this by brute force.",
        tstyle(:text_dim); max_x = right(c))
    return
end
