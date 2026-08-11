# Slide 7 — why Julia, told as ONE story: a correlator this repo defines, which
# Tracking.jl accepts without ever having heard of it.
#
# The argument is made visually rather than in bullet points. Both panels show the same
# correlation triangle; the only difference is how many taps sample it. Tracking.jl's
# default `EarlyPromptLateCorrelator` holds exactly three accumulators (`SVector{3,T}`) —
# all a DLL needs to steer, but three points cannot draw a shape. This talk needed the
# shape, so it ships a 31-tap correlator and hands it to the same `track!`.
#
# Tap positions are derived from the real correlators (the same rounding
# `calc_preferred_code_shift_to_sample_shift` does), not drawn by hand.

# The correlation triangle: 1 at perfect alignment, falling linearly to 0 at ±1 chip.
_tri(δ) = max(0.0, 1.0 - abs(δ))

const TAP_X_RANGE = 1.75          # chips shown either side of alignment

# Draw one correlator: the true triangle as a dim line, its taps as bright markers.
function _draw_tap_panel!(buf, area::Rect, offsets, title, subtitle, verdict, vstyle)
    (area.width < 24 || area.height < 10) && return
    set_string!(buf, area.x, area.y, title, tstyle(:primary, bold = true); max_x = right(area))
    set_string!(buf, area.x, area.y + 1, subtitle, tstyle(:text_dim); max_x = right(area))

    ploty = area.y + 3
    plotx = area.x + 4
    plotw = right(area) - plotx
    ploth = area.height - 7
    (plotw < 10 || ploth < 4) && return

    # Dim triangle outline underneath, so both panels are sampling the *same* curve.
    canvas = BlockCanvas(plotw, ploth; style = tstyle(:border))
    dw, dh = plotw * 2, ploth * 2
    dx(δ) = clamp(round(Int, (δ + TAP_X_RANGE) / (2TAP_X_RANGE) * (dw - 1)), 0, dw - 1)
    dy(v) = clamp(round(Int, (1 - v) * (dh - 1)), 0, dh - 1)
    verts = ((-TAP_X_RANGE, 0.0), (-1.0, 0.0), (0.0, 1.0), (1.0, 0.0), (TAP_X_RANGE, 0.0))
    for i in 2:length(verts)
        line!(canvas, dx(verts[i-1][1]), dy(verts[i-1][2]), dx(verts[i][1]), dy(verts[i][2]))
    end
    render(canvas, Rect(plotx, ploty, plotw, ploth), buf)

    # The taps, as stems rising from the baseline to the curve. Stems rather than bare
    # markers so the 3-vs-31 contrast survives without colour: three lonely sticks on the
    # left, a filled silhouette on the right.
    cx(δ) = plotx + clamp(round(Int, (δ + TAP_X_RANGE) / (2TAP_X_RANGE) * (plotw - 1)), 0, plotw - 1)
    cy(v) = ploty + clamp(round(Int, (1 - v) * (ploth - 1)), 0, ploth - 1)
    base = ploty + ploth - 1
    for δ in offsets
        x = cx(δ)
        top = cy(_tri(δ))
        for yy in (top+1):base
            set_char!(buf, x, yy, '│', tstyle(:primary, dim = true))
        end
        set_char!(buf, x, top, '●', tstyle(:accent, bold = true))
    end

    set_string!(buf, area.x, ploty, "1", tstyle(:text_dim); max_x = plotx - 1)
    set_string!(buf, area.x, ploty + ploth - 1, "0", tstyle(:text_dim); max_x = plotx - 1)
    # Ticks at their true positions — the axis spans ±TAP_X_RANGE, not ±1, and the outer
    # taps really do sit beyond one chip.
    yb = ploty + ploth
    set_string!(buf, cx(-1.0) - 1, yb, "-1", tstyle(:text_dim); max_x = right(area))
    set_string!(buf, cx(0.0), yb, "0", tstyle(:text_dim); max_x = right(area))
    set_string!(buf, cx(1.0), yb, "+1", tstyle(:text_dim); max_x = right(area))
    set_string!(buf, right(area) - 5, yb, "chips", tstyle(:text_dim); max_x = right(area))
    set_string!(buf, area.x, yb + 2, verdict, vstyle; max_x = right(area))
    return
end

function render_julia(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    c = render(Block(; title = "Why Julia — someone else's package, my correlator",
            border_style = tstyle(:border), title_style = tstyle(:accent, bold = true)),
        area, buf)
    (c.width < 60 || c.height < 16) && return

    cf = get_code_frequency(m.system)
    fs = Float64(ustrip(Hz, m.fs))
    fc = Float64(ustrip(Hz, cf))

    # Tracking.jl's default: 3 accumulators, Early/Late at the integer sample nearest
    # ±½ chip — the same rounding `calc_preferred_code_shift_to_sample_shift` applies.
    el = max(1, round(Int, 0.5 * fs / fc))
    epl_offsets = (-el, 0, el) .* (fc / fs)

    # Ours: one tap per integer sample across ±(N÷2), read off a real instance.
    tri = TriangleCorrelator(; sampling_freq = m.fs, code_freq = cf)
    tri_offsets = tap_offsets_chips(tri, m.fs, cf)

    cols = split_layout(Layout(Horizontal, [Percent(50), Fill()]), c)
    left = Rect(cols[1].x + 2, cols[1].y, cols[1].width - 4, cols[1].height)
    right_ = Rect(cols[2].x + 2, cols[2].y, cols[2].width - 4, cols[2].height)
    panelh = min(left.height - 8, 16)

    _draw_tap_panel!(buf, Rect(left.x, left.y, left.width, panelh),
        epl_offsets,
        "Tracking.jl's default",
        "EarlyPromptLateCorrelator — $(length(epl_offsets)) taps",
        "Enough to steer the loop. Not enough to see.", tstyle(:text_dim))

    _draw_tap_panel!(buf, Rect(right_.x, right_.y, right_.width, panelh),
        tri_offsets,
        "…and mine, defined in this repo",
        "TriangleCorrelator — $(length(tri_offsets)) taps, 120 lines",
        "Same interface. Now the shape is visible.", tstyle(:success, bold = true))

    # The code that buys it.
    y = c.y + panelh + 1
    y > bottom(c) - 3 && return
    set_string!(buf, c.x + 2, y, "struct TriangleCorrelator{M,N,T} <: AbstractEarlyPromptLateCorrelator{M}",
        tstyle(:secondary); max_x = right(c)); y += 1
    set_string!(buf, c.x + 2, y, "get_correlator_sample_shifts(c, fs, fc) = c.shifts        # …and four more one-liners",
        tstyle(:secondary); max_x = right(c)); y += 2
    y > bottom(c) && return
    set_string!(buf, c.x + 2, y,
        "No fork. No plugin registry. No config flag. Implement the interface and `track!` dispatches to it —",
        tstyle(:text); max_x = right(c)); y += 1
    y > bottom(c) && return
    set_string!(buf, c.x + 2, y,
        "the correlation triangle two slides back was tracked with this, at full speed.",
        tstyle(:success, bold = true); max_x = right(c))
    return
end
