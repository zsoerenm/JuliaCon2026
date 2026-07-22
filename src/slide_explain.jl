# Slide 2 — explain the idea before acquisition: every satellite sends a unique ±1 code
# (drawn from `gen_code`), and correlating the signal with a replica of that code yields a
# triangular peak. Uses the same code-wave visual as the tracking slide's "code replica"
# strip (shared `_draw_code_wave!`) so the two slides look consistent.

# Draw a ±1 code as a two-row bipolar square wave: +1 chips fill `toprow`, −1 chips fill
# `botrow`, `cpc` cells per chip. Chip `c0` (0-based) is placed at `x = xanchor +
# (c0−cp)·cpc`, clipped to [xlo, xhi]; `cp` shifts the whole pattern (used for the tracked
# code phase on slide 4). Shared by the explanation and tracking slides.
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

function render_explain(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    c = render(Block(; title = "GNSS codes & correlation", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), area, buf)
    (c.width < 20 || c.height < 12) && return
    x = c.x + 2
    y = c.y

    # ── ① the code (same bipolar square-wave visual as the tracking slide) ────
    set_string!(buf, x, y, "① Each satellite sends a unique 1023-chip ±1 code (PRN 1):",
        tstyle(:text); max_x = right(c))
    y += 1
    cf = get_code_frequency(m.system)
    L = get_code_length(m.system)
    code = gen_code(L, m.system, 1, cf, cf, 0.0)               # 1 sample/chip → ±1
    wx = x + 3
    set_string!(buf, x, y, "+1", tstyle(:text_dim); max_x = wx - 1)
    set_string!(buf, x, y + 1, "-1", tstyle(:text_dim); max_x = wx - 1)
    _draw_code_wave!(buf, wx, right(c), y, y + 1, code, L, 0.0, 2, wx)
    set_string!(buf, wx, y + 2, "→ chips (each ~1 µs; the whole code repeats every 1 ms)",
        tstyle(:text_dim); max_x = right(c))
    y += 4

    # ── ② the correlation triangle (same braille technique as the tracking slide) ──
    set_string!(buf, x, y, "② Correlate the signal with a replica of that code:",
        tstyle(:text); max_x = right(c)); y += 1
    set_string!(buf, x, y,
        "aligned → strong peak; a rectangular chip → a triangular correlation (±1 chip):",
        tstyle(:text_dim); max_x = right(c)); y += 1

    plotx = x + 4
    plotw = right(c) - plotx
    ploth = bottom(c) - y - 1                                   # leave a row for the caption
    if plotw >= 8 && ploth >= 4
        canvas = BlockCanvas(plotw, ploth; style = tstyle(:accent, bold = true))
        dw, dh = plotw * 2, ploth * 2
        dotx(δ) = clamp(round(Int, (δ + 1.5) / 3.0 * (dw - 1)), 0, dw - 1)
        doty(v) = clamp(round(Int, (1 - v) * (dh - 1)), 0, dh - 1)
        verts = ((-1.5, 0.0), (-1.0, 0.0), (0.0, 1.0), (1.0, 0.0), (1.5, 0.0))
        for i in 2:length(verts)
            line!(canvas, dotx(verts[i-1][1]), doty(verts[i-1][2]),
                dotx(verts[i][1]), doty(verts[i][2]))
        end
        render(canvas, Rect(plotx, y, plotw, ploth), buf)
        # y-axis (the apex speaks for itself — no peak label)
        set_string!(buf, c.x, y, "1", tstyle(:text_dim); max_x = plotx - 1)
        set_string!(buf, c.x, y + ploth - 1, "0", tstyle(:text_dim); max_x = plotx - 1)
        # x-axis labels
        yb = y + ploth
        set_string!(buf, plotx, yb, "-1", tstyle(:text_dim); max_x = right(c))
        set_string!(buf, plotx + plotw ÷ 2 - 3, yb, "0  [chips]", tstyle(:text_dim); max_x = right(c))
        set_string!(buf, right(c) - 1, yb, "+1", tstyle(:text_dim); max_x = right(c))
    end
    set_string!(buf, x, bottom(c),
        "Peak position = code delay (acquisition); triangle slope steers tracking (Early/Late).",
        tstyle(:text_dim); max_x = right(c))
    return
end
