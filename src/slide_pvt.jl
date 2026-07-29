# Slide 4 — PVT: CN0 bars, a direction-of-arrival sky plot, and the computed position.
# Mirrors the GNSSReceiver terminal GUI with Tachikoma widgets. Fed by the continuous
# receiver running in the background, so it is warm whenever this slide is shown.

# CN0 stored as a dBHz log-quantity; strip to a plain number defensively.
function _cn0_db(c)
    try
        return Float64(ustrip(u"dBHz", c))
    catch
    end
    try
        return 10 * log10(Float64(ustrip(Hz, c)))
    catch
    end
    return NaN
end

function render_pvt(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    gui = s.gui
    # 2×2: CN0 | sky (top),  position | map (bottom)
    rows = split_layout(Layout(Vertical, [Percent(50), Fill()]), area)
    topcols = split_layout(Layout(Horizontal, [Percent(50), Fill()]), rows[1])
    botcols = split_layout(Layout(Horizontal, [Percent(42), Fill()]), rows[2])
    cn0area, skyarea = topcols[1], topcols[2]
    posarea, maparea = botcols[1], botcols[2]

    # ── CN0 bars ──
    cc = render(Block(; title = "CN0 [dBHz]", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), cn0area, buf)
    if gui === nothing || isempty(gui.sat_data)
        set_string!(buf, cc.x + 2, cc.y + 1, "Searching for satellites…",
            tstyle(:text_dim); max_x = right(cc))
    else
        # UnicodePlots barplot, sorted by PRN, coloured green (healthy) / red (unhealthy),
        # painted into the panel as ANSI spans — same look as the GNSSReceiver GUI.
        prns = sort(collect(keys(gui.sat_data)))
        labels = ["PRN $(k)" for k in prns]
        cn0s = [(d = _cn0_db(gui.sat_data[k].cn0); isnan(d) ? 0.0 : round(d; digits = 1)) for k in prns]
        colors = [gui.sat_data[k].is_healthy ? :green : :red for k in prns]
        labelw = maximum(length, labels)
        # barplot's own chrome (label col + " ┤" + trailing " NN.N") plus panel padding.
        barwidth = clamp(cc.width - labelw - 9, 5, 60)
        plot = UP.barplot(labels, cn0s; color = colors, border = :none,
            width = barwidth, maximum = 55)
        _paint_plot!(buf, cc, string(plot; color = true))
    end

    # ── Sky plot (direction of arrival) ──
    sc = render(Block(; title = "Direction of arrival", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), skyarea, buf)
    _render_skyplot(buf, sc, gui)

    # ── Position ──
    pc = render(Block(; title = "Position / time", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), posarea, buf)
    _render_position(buf, pc, gui, s.last_fix)

    # ── Map (UnicodeMaps, rendered in the background once a fix exists) ──
    mc = render(Block(; title = "Map", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), maparea, buf)
    _render_map(m, buf, mc, s)
    return
end

function _render_map(m::PresentationModel, buf, area::Rect, s)
    (area.width < 8 || area.height < 4) && return
    fix = s.last_fix
    if fix === nothing
        set_string!(buf, area.x + 2, area.y + 1, "map: awaiting fix",
            tstyle(:text_dim); max_x = right(area))
        return
    end
    # Request a map for this position + panel size (the background task renders it).
    lla = try
        get_LLA(fix.pvt)
    catch
        nothing
    end
    lla === nothing && return
    zoom, dlon, dlat = @lock m.lk (m.map_zoom, m.map_dlon, m.map_dlat)
    clon = lla.lon + dlon
    clat = lla.lat + dlat
    marker = dlon == 0.0 && dlat == 0.0          # the pin marks the map center = the fix
    want = (round(clat; digits = 5), round(clon; digits = 5), area.width, area.height, zoom, marker)
    @lock m.lk (m.map_want = want)

    lines = s.map_lines
    if lines === nothing
        set_string!(buf, area.x + 2, area.y + 1, "loading map…", tstyle(:text_dim); max_x = right(area))
        return
    end
    for (i, spans) in enumerate(lines)
        y = area.y + i - 1
        y > bottom(area) && break
        x = area.x
        for sp in spans
            x > right(area) && break
            set_string!(buf, x, y, sp.content, sp.style; max_x = right(area))
            x += max(1, textwidth(sp.content))
        end
    end
    return
end

# Paint a UnicodePlots colour string (`string(plot; color=true)`) or any ANSI text into
# `area`: split into lines, parse each line's ANSI into spans, lay them out left-to-right,
# clipping at the panel edges. `set_string!`'s return value is the only reliable column
# advance (it strips ANSI/control chars and segments graphemes), so we never recompute width.
function _paint_plot!(buf, area::Rect, str::AbstractString)
    for (i, line) in enumerate(split(str, '\n'))
        y = area.y + i - 1
        y > bottom(area) && break
        x = area.x
        for sp in parse_ansi(String(line))
            x > right(area) && break
            x = set_string!(buf, x, y, sp.content, sp.style; max_x = right(area))
        end
    end
    return
end

# Direction-of-arrival sky plot via UnicodePlots `polarplot` (round braille circle with
# elevation rings and azimuth axis), painted as ANSI spans — same look as GNSSReceiver.
function _render_skyplot(buf, area::Rect, gui)
    (area.width < 12 || area.height < 6) && return
    if gui === nothing || gui.pvt === nothing || gui.pvt.time === nothing
        nsat = gui === nothing ? 0 : length(gui.sat_data)
        set_string!(buf, area.x + 1, area.y,
            nsat < 4 ? "Not enough satellites for a fix." : "Decoding satellites…",
            tstyle(:text_dim); max_x = right(area))
        return
    end
    pvt = gui.pvt
    # One point per physical satellite (dedupe by PRN), az/el from the fix geometry.
    seen = Set{Int}()
    azs, zenith, prns = Float64[], Float64[], Int[]
    try
        for (key, sat) in pairs(pvt.sats)
            prn = key isa Tuple ? last(key) : key
            prn in seen && continue
            push!(seen, prn)
            enu = get_sat_enu(pvt.position, sat.position)
            push!(azs, enu.θ)                                # azimuth, radians from North
            push!(zenith, 90 - enu.ϕ * 180 / π)             # zenith distance = 90° − elevation
            push!(prns, prn)
        end
    catch
    end
    isempty(azs) && return
    # Size the canvas ~2:1 (cols:rows) so braille cells render a round circle; leave margin
    # for the axis labels UnicodePlots draws around it.
    wcanvas = clamp(min(area.width - 13, 2 * (area.height - 4)), 8, 60)
    hcanvas = max(4, wcanvas ÷ 2)
    grid = UP.BORDER_COLOR[]
    doa = UP.polarplot(azs, zenith; rlim = (0, 90), scatter = true, marker = :circle,
        color = :green, border = :none, num_rad_lab = 0, width = wcanvas, height = hcanvas)
    # PRN label on each point (polarplot places θ CCW from +x at radius r → (r·cosθ, r·sinθ)).
    for (az, r, prn) in zip(azs, zenith, prns)
        UP.annotate!(doa, r * cos(az), r * sin(az), string(prn); color = :green)
    end
    # Elevation rings labelled along the π/4 diagonal as bare numbers (° is for azimuth).
    for el in (0, 30, 60)
        r = 90 - el
        UP.annotate!(doa, r * cos(π / 4), r * sin(π / 4), string(el); color = grid)
    end
    # GNSS azimuth convention: 0°=North top, clockwise (90°=E right, 180°=S bottom, 270°=W left).
    mid = ceil(Int, UP.nrows(doa.graphics) / 2)
    UP.label!(doa, :t, "0°"; color = grid)
    UP.label!(doa, :r, mid, "90°"; color = grid)
    UP.label!(doa, :b, "180°"; color = grid)
    UP.label!(doa, :l, mid, "270°"; color = grid)
    _paint_plot!(buf, area, string(doa; color = true))
    return
end

# `gui` is the current (possibly unfixed) snapshot; `last_fix` is the most recent GUIData
# that had a real fix. We show the last fix persistently (the file loops every 40 s and
# lock drops at the seam, but the receiver hasn't moved), marking it "held" when the
# current epoch has no fix.
function _render_position(buf, area::Rect, gui, last_fix)
    x, y = area.x + 1, area.y
    live = gui !== nothing && gui.pvt !== nothing && gui.pvt.time !== nothing
    fix = live ? gui : last_fix
    if fix === nothing
        nsat = gui === nothing ? 0 : length(gui.sat_data)
        set_string!(buf, x, y, nsat < 4 ? "Need ≥4 satellites for a fix." :
            "Decoding navigation data…", tstyle(:text_dim); max_x = right(area))
        set_string!(buf, x, y + 1, "$(nsat) satellites tracked", tstyle(:text_dim); max_x = right(area))
        return
    end
    try
        lla = get_LLA(fix.pvt)
        label, lstyle = live ? ("● fix", tstyle(:success, bold = true)) :
            ("◦ last fix (re-acquiring)", tstyle(:warning))
        set_string!(buf, x, y, label, lstyle; max_x = right(area)); y += 1
        set_string!(buf, x, y, "Latitude:  $(round(lla.lat; digits=6))°", tstyle(:text); max_x = right(area)); y += 1
        set_string!(buf, x, y, "Longitude: $(round(lla.lon; digits=6))°", tstyle(:text); max_x = right(area)); y += 1
        set_string!(buf, x, y, "Altitude:  $(round(lla.alt; digits=1)) m", tstyle(:text); max_x = right(area)); y += 2
        set_string!(buf, x, y, "$(round(lla.lat; digits=5)), $(round(lla.lon; digits=5))",
            tstyle(:success, bold = true); max_x = right(area)); y += 1
        set_string!(buf, x, y, "maps.google.com/?q=$(round(lla.lat;digits=5)),$(round(lla.lon;digits=5))",
            tstyle(:text_dim); max_x = right(area)); y += 2
    catch e
        set_string!(buf, x, y, "PVT: $(sprint(showerror, e)[1:min(end,40)])",
            tstyle(:warning); max_x = right(area)); y += 1
    end
    nsat = gui === nothing ? 0 : length(gui.sat_data)
    rt = gui === nothing ? 0.0 : ustrip(s, gui.runtime)
    set_string!(buf, x, y, "runtime $(round(rt; digits=1)) s   sats $(nsat)",
        tstyle(:text_dim); max_x = right(area))
    return
end
