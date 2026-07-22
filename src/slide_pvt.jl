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
        prns = collect(keys(gui.sat_data))
        vals = collect(values(gui.sat_data))
        entries = BarEntry[]
        for (prn, sat) in zip(prns, vals)
            db = _cn0_db(sat.cn0)
            style = sat.is_healthy ? tstyle(:success) : tstyle(:error)
            push!(entries, BarEntry("PRN$(lpad(prn,2))", isnan(db) ? 0.0 : round(db; digits = 1), style))
        end
        render(BarChart(entries; max_val = 55.0, label_width = 6), cc, buf)
    end

    # ── Sky plot (direction of arrival) ──
    sc = render(Block(; title = "Direction of arrival", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), skyarea, buf)
    _render_skyplot(buf, sc, gui, m)

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

# Terminal cells are about twice as tall as wide, so a "circle" drawn with equal
# horizontal/vertical extent looks stretched vertically. Compress the vertical axis by
# this factor to render a round sky plot.
const CELL_ASPECT = 0.5   # cell width / height

function _render_skyplot(buf, area::Rect, gui, m)
    w, h = area.width, area.height
    (w < 6 || h < 4) && return
    cx = area.x + w ÷ 2
    cy = area.y + h ÷ 2
    Rx = min(w ÷ 2 - 1, floor(Int, (h ÷ 2 - 1) / CELL_ASPECT))   # horizontal radius (cells)
    Rx < 2 && return
    Ry = Rx * CELL_ASPECT                                        # vertical radius (cells)
    gridstyle = tstyle(:border, dim = true)

    plot!(px, py, ch, st) = set_char!(buf, clamp(px, area.x, right(area)),
        clamp(py, area.y, bottom(area)), ch, st)

    # elevation rings 0°/30°/60° as aspect-corrected ellipses
    for e in (0, 30, 60)
        f = 1 - e / 90
        rx, ry = f * Rx, f * Ry
        n = max(24, round(Int, 2π * rx))
        for k in 0:n-1
            θ = 2π * k / n
            plot!(round(Int, cx + rx * cos(θ)), round(Int, cy + ry * sin(θ)), '·', gridstyle)
        end
    end
    # cardinal spokes
    for dx in -Rx:Rx
        plot!(cx + dx, cy, '·', gridstyle)
    end
    for dy in -round(Int, Ry):round(Int, Ry)
        plot!(cx, cy + dy, '·', gridstyle)
    end
    plot!(cx, cy, '+', gridstyle)
    plot!(cx, cy - round(Int, Ry), 'N', tstyle(:text_dim))

    gui === nothing && return
    pvt = gui.pvt
    (pvt === nothing || pvt.time === nothing) && return
    try
        for (key, sat) in pairs(pvt.sats)
            enu = get_sat_enu(pvt.position, sat.position)
            az, el = enu.θ, enu.ϕ                            # radians (az from N, el up)
            f = clamp(1 - el / (π / 2), 0.0, 1.0)            # 0 at zenith, 1 at horizon
            px = clamp(round(Int, cx + f * Rx * sin(az)), area.x, right(area))
            py = clamp(round(Int, cy - f * Ry * cos(az)), area.y, bottom(area))
            prn = key isa Tuple ? last(key) : key
            set_char!(buf, px, py, '●', tstyle(:success, bold = true))
            set_string!(buf, min(px + 1, right(area)), py, string(prn),
                tstyle(:text_bright); max_x = right(area))
        end
    catch
    end
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
