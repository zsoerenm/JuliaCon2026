# Slide 3 — the correlation triangle from a real multi-tap correlator tracked live.
# The full triangle is a faint braille line; the Early (+½ chip), Prompt, and Late
# (−½ chip) taps the DLL uses are drawn as big colored bars (green / accent / red) with
# bold labels so they read from the back of the room.

function render_tracking(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    tr = s.triangle
    rows = split_layout(Layout(Vertical, [Fixed(1), Fixed(5), Fill()]), area)
    info, codearea, plotarea = rows[1], rows[2], rows[3]

    if tr === nothing
        content = render(Block(; title = "Tracking", border_style = tstyle(:border),
                title_style = tstyle(:accent, bold = true)), area, buf)
        set_string!(buf, content.x + 2, content.y + 1,
            s.selected_prn === nothing ?
            "Select a PRN on the acquisition slide first (←)." :
            "Seeding tracking for PRN $(s.selected_prn)…",
            tstyle(:text_dim); max_x = right(content))
        return
    end

    mags = Vector{Float64}(tr.mags)
    off = Vector{Float64}(tr.offsets)
    peak = maximum(mags)
    peak <= 0 && (peak = 1.0)
    yn = mags ./ peak
    E = yn[tr.early_idx]
    L = yn[tr.late_idx]

    dop = round(Int, ustrip(Hz, tr.doppler))
    spc = samples_per_code(m.system, m.fs)
    set_string!(buf, info.x + 1, info.y,
        "PRN $(tr.prn)   Doppler $(dop) Hz   ~$(round(spc/1000; digits=1)) samples/chip   " *
        "E=$(round(E; digits=2)) L=$(round(L; digits=2))   DLL disc $(round(tr.disc; digits=3)) chips",
        tstyle(:text); max_x = right(info))

    _render_code_strip(buf, codearea, m, tr)

    c = render(Block(; title = "Correlation triangle (live)", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), plotarea, buf)
    gut = 4
    plotx = c.x + gut
    plotw = c.width - gut
    ploty = c.y
    ploth = c.height - 1                         # last row = x-axis labels
    (plotw < 8 || ploth < 4) && return
    baseline = ploty + ploth - 1
    xmin, xmax = extrema(off)
    ymax = 1.08
    xcell(x) = plotx + clamp(round(Int, (x - xmin) / (xmax - xmin) * (plotw - 1)), 0, plotw - 1)
    ycell(v) = ploty + clamp(round(Int, (1 - v / ymax) * (ploth - 1)), 0, ploth - 1)

    # Faint full triangle line (smooth braille via BlockCanvas)
    canvas = BlockCanvas(plotw, ploth; style = tstyle(:primary, dim = true))
    dotx(x) = clamp(round(Int, (x - xmin) / (xmax - xmin) * (plotw * 2 - 1)), 0, plotw * 2 - 1)
    doty(v) = clamp(round(Int, (1 - v / ymax) * (ploth * 2 - 1)), 0, ploth * 2 - 1)
    for i in 2:length(off)
        line!(canvas, dotx(off[i-1]), doty(yn[i-1]), dotx(off[i]), doty(yn[i]))
    end
    render(canvas, Rect(plotx, ploty, plotw, ploth), buf)

    # y-axis + x-axis labels
    set_string!(buf, c.x, ploty, "1.0", tstyle(:text_dim); max_x = plotx - 1)
    set_string!(buf, c.x, ploty + ploth ÷ 2, "0.5", tstyle(:text_dim); max_x = plotx - 1)
    set_string!(buf, c.x, baseline, "0.0", tstyle(:text_dim); max_x = plotx - 1)
    yb = ploty + ploth
    set_string!(buf, plotx, yb, string(round(xmin; digits = 1)), tstyle(:text_dim); max_x = right(c))
    xmid = "code offset [chips]"
    set_string!(buf, plotx + max(0, (plotw - length(xmid)) ÷ 2), yb, xmid, tstyle(:text_dim); max_x = right(c))
    rlbl = string(round(xmax; digits = 1))
    set_string!(buf, right(c) - length(rlbl) + 1, yb, rlbl, tstyle(:text_dim); max_x = right(c))

    # Big Early / Prompt / Late bars with bold labels
    for (idx, st, lbl) in ((tr.late_idx, tstyle(:error, bold = true), "L"),
                           (tr.early_idx, tstyle(:success, bold = true), "E"),
                           (tr.prompt_idx, tstyle(:accent, bold = true), "P"))
        cx = xcell(off[idx])
        top = ycell(yn[idx])
        for dx in -1:1                           # 3-cell-wide bar → visible from afar
            x = clamp(cx + dx, plotx, right(c))
            for y in top:baseline
                set_char!(buf, x, y, '█', st)
            end
        end
        set_string!(buf, clamp(cx, plotx, right(c)), max(ploty, top - 1), lbl, st; max_x = right(c))
    end
    return
end

# Top panel: a window of the selected PRN's ±1 code, positioned by the code phase the
# tracking loop estimates. A fixed "prompt" marker sits at panel centre; as the estimated
# code phase changes, the whole code slides left/right underneath it — you literally see
# the code drift while the DLL keeps it aligned.
function _render_code_strip(buf, area::Rect, m::PresentationModel, tr)
    cp = Float64(tr.code_phase)
    c = render(Block(; title = "Code replica — phase $(round(cp; digits = 1)) chips " *
            "(drifts as tracking updates)", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), area, buf)
    (c.width < 12 || c.height < 3) && return
    cf = get_code_frequency(m.system)
    L = get_code_length(m.system)
    code = gen_code(L, m.system, tr.prn, cf, cf, 0.0)          # 1 sample/chip → ±1
    cpc = 2                                                    # cells per chip
    cx = c.x + c.width ÷ 2                                     # prompt marker column
    toprow, botrow, markrow = c.y, c.y + 1, c.y + 2
    # same code-wave visual as the explanation slide; `cp` slides it under the marker
    _draw_code_wave!(buf, c.x, right(c), toprow, botrow, code, L, cp, cpc, cx)
    # fixed prompt marker + labels
    set_char!(buf, cx, markrow, '▲', tstyle(:accent, bold = true))
    set_string!(buf, c.x, markrow, "PRN $(tr.prn)", tstyle(:text_dim); max_x = cx - 1)
    set_string!(buf, min(cx + 2, right(c)), markrow, "prompt", tstyle(:accent, bold = true); max_x = right(c))
    return
end
