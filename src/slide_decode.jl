# Slide 5 — decoding. The receiver is started the moment this slide is first shown
# (`_on_slide_enter!`), so everything here fills in live, from zero, in front of the
# audience: the subframe progress bar, the time-of-week the satellite reports every six
# seconds, and the ephemeris values popping in one 30-bit word at a time.
#
# All of it is read from the decoder's `raw_data` accumulator (see nav_snapshot.jl) —
# nothing here is replayed or faked. At 50 bit/s a subframe takes 6 s and the three
# ephemeris subframes take ~18 s, which is the slide's natural length.

const SUBFRAME_BITS = 300         # 300 bits at 50 bit/s = 6 s
const NAV_BIT_RATE = 50

_eph_get(raw, sym) = raw === nothing ? nothing :
                     (hasproperty(raw, sym) ? getproperty(raw, sym) : nothing)

"Is every field of ephemeris group `g` present in `raw`?"
_group_done(raw, g) = all(f -> _eph_get(raw, first(f)) !== nothing, last(g))

# The satellite whose values we show in full. Prefer the one selected on the acquisition
# slide (so the story follows one satellite across slides); otherwise the satellite that
# is furthest along, so the grid is as alive as possible.
function _hero_prn(sats, selected)
    isempty(sats) && return nothing
    selected !== nothing && haskey(sats, selected) && return selected
    best, bestscore = nothing, -1
    for (prn, sd) in pairs(sats)
        score = count(sym -> _eph_get(sd.raw, sym) !== nothing, EPHEMERIS_FIELDS)
        if score > bestscore
            best, bestscore = prn, score
        end
    end
    best
end

function render_decode(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    gui = s.gui
    sats = gui === nothing ? nothing : gui.sat_data

    rows = split_layout(Layout(Vertical, [Fill(), Fixed(2)]), area)
    cols = split_layout(Layout(Horizontal, [Fixed(38), Fill()]), rows[1])
    leftrows = split_layout(Layout(Vertical, [Fixed(9), Fill()]), cols[1])

    _render_bitstream(m, buf, leftrows[1], sats, s)
    _render_readiness(buf, leftrows[2], sats)
    _render_ephemeris(m, buf, cols[2], sats, s)

    # The takeaway line — what the numbers actually are.
    set_string!(buf, area.x + 1, rows[2].y,
        "These numbers are the satellite's orbit: with them we know exactly where it was when it sent this bit.",
        tstyle(:text_dim); max_x = right(area))
    set_string!(buf, area.x + 1, rows[2].y + 1,
        "50 bit/s — the slowest data link you use every day. Nothing can make it faster.",
        tstyle(:secondary); max_x = right(area))
    return
end

# ── The bit stream: progress through the current 300-bit subframe, plus the time ──
function _render_bitstream(m, buf, area::Rect, sats, s)
    c = render(Block(; title = "The bit stream — 50 bit/s", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), area, buf)
    (c.width < 12 || c.height < 5) && return
    x, y = c.x + 1, c.y

    if sats === nothing || isempty(sats)
        set_string!(buf, x, y, "receiver starting…", tstyle(:warning); max_x = right(c))
        set_string!(buf, x, y + 2, "tracking, then decoding,", tstyle(:text_dim); max_x = right(c))
        set_string!(buf, x, y + 3, "then a fix — all from here,", tstyle(:text_dim); max_x = right(c))
        set_string!(buf, x, y + 4, "live, starting now.", tstyle(:text_dim); max_x = right(c))
        return
    end
    hero = _hero_prn(sats, s.selected_prn)
    hero === nothing && return
    sd = sats[hero]

    # Progress is measured by how much of the orbit has actually arrived, NOT by
    # `bits_in_subframe`: that field stays `nothing` for a long time while words are
    # demonstrably being decoded, so driving the bar from it showed "searching for the
    # preamble… 0/300" on screen while values were already landing in the grid.
    got = count(sym -> _eph_get(sd.raw, sym) !== nothing, EPHEMERIS_FIELDS)
    total = length(EPHEMERIS_FIELDS)
    sub = _eph_get(sd.raw, :last_subframe_id)
    started = got > 0 || (sub isa Integer && sub > 0)

    if started
        set_string!(buf, x, y, "PRN $(hero) — decoding ●", tstyle(:success, bold = true); max_x = right(c))
    else
        set_string!(buf, x, y, "PRN $(hero) — waiting for subframe sync…",
            tstyle(:warning); max_x = right(c))
    end
    y += 2
    barw = max(4, c.width - 3)
    filled = round(Int, barw * got / total)
    set_string!(buf, x, y, "█"^filled, tstyle(:primary, bold = true); max_x = right(c))
    set_string!(buf, x + filled, y, "░"^max(0, barw - filled), tstyle(:text_dim); max_x = right(c))
    y += 1
    subtxt = (sub isa Integer && sub > 0) ? "   subframe $(sub)" : ""
    set_string!(buf, x, y, "$(got) / $(total) orbit numbers$(subtxt)",
        tstyle(:text_dim); max_x = right(c))
    y += 1
    # One subframe is 300 bits at 50 bit/s = 6 s; three of them carry the orbit.
    set_string!(buf, x, y, "300 bits per subframe · 6 s each · 3 needed",
        tstyle(:text_dim); max_x = right(c))
    y += 2

    # Time of week — the answer to the tracking slide's question, arriving every 6 s.
    # The decoder clears TOW again whenever the next one isn't exactly prev+1, so the raw
    # field flickers; we latch the last value actually decoded rather than blinking "——"
    # at the audience while every other field on the slide is filled in.
    tow = _eph_get(sd.raw, :TOW)
    tow isa Integer && (m.last_tow[hero] = tow)
    shown = get(m.last_tow, hero, nothing)
    if shown === nothing
        set_string!(buf, x, y, "time of week: ——", tstyle(:text_dim); max_x = right(c))
    else
        set_string!(buf, x, y, "time of week: $(shown) s", tstyle(:success, bold = true); max_x = right(c))
        set_string!(buf, x, y + 1, "the satellite just told us the time",
            tstyle(:text_dim); max_x = right(c))
    end
    return
end

# ── Per-satellite readiness: which subframes each satellite has, and the count ──
function _render_readiness(buf, area::Rect, sats)
    c = render(Block(; title = "Satellites", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), area, buf)
    (c.width < 12 || c.height < 3) && return
    x, y = c.x + 1, c.y
    if sats === nothing || isempty(sats)
        set_string!(buf, x, y, "none tracked yet", tstyle(:text_dim); max_x = right(c))
        return
    end
    ready = 0
    for prn in sort(collect(keys(sats)))
        y > bottom(c) - 2 && break
        sd = sats[prn]
        sd.complete && (ready += 1)
        set_string!(buf, x, y, "PRN " * lpad(prn, 2), tstyle(:text); max_x = right(c))
        cx = x + 7
        for g in EPHEMERIS_GROUPS
            done = _group_done(sd.raw, g)
            set_string!(buf, cx, y, done ? "●" : "·",
                done ? tstyle(:success, bold = true) : tstyle(:text_dim); max_x = right(c))
            cx += 2
        end
        # The dots show subframes *received*; the tick shows the ephemeris *validated*
        # for positioning (which additionally needs a consistent TOW and matching
        # IODC/IODE). All three dots can be lit while validation is still pending — so
        # the two indicators must read differently, or they look like a contradiction.
        if sd.complete
            set_string!(buf, cx + 1, y, "✓ validated", tstyle(:success); max_x = right(c))
        elseif _group_done(sd.raw, EPHEMERIS_GROUPS[3]) && _group_done(sd.raw, EPHEMERIS_GROUPS[1])
            set_string!(buf, cx + 1, y, "· checking", tstyle(:text_dim); max_x = right(c))
        end
        y += 1
    end
    # The suspense meter: this is what pays off on the next slide.
    n = length(sats)
    style = ready >= 4 ? tstyle(:success, bold = true) : tstyle(:warning, bold = true)
    msg = ready >= 4 ? "$(ready) of $(n) validated — enough for a fix" :
          "$(ready) of $(n) validated — 4 needed for a fix"
    set_string!(buf, x, bottom(c), msg, style; max_x = right(c))
    return
end

# ── The ephemeris grid: values pop in as their 30-bit word passes parity ──
function _render_ephemeris(m, buf, area::Rect, sats, s)
    hero = sats === nothing ? nothing : _hero_prn(sats, s.selected_prn)
    title = hero === nothing ? "Navigation message" : "Navigation message — PRN $(hero)"
    c = render(Block(; title = title, border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), area, buf)
    (c.width < 24 || c.height < 8) && return
    x, y = c.x + 2, c.y

    if hero === nothing
        set_string!(buf, x, y, "Waiting for the first satellite to lock…",
            tstyle(:text_dim); max_x = right(c))
        set_string!(buf, x, y + 2,
            "Each satellite broadcasts its own orbit — 900 bits, three subframes, 18 seconds.",
            tstyle(:text_dim); max_x = right(c))
        return
    end
    sd = sats[hero]
    colw = max(16, (c.width - 4) ÷ 3)

    for (gi, (gname, fields)) in enumerate(EPHEMERIS_GROUPS)
        gx = x + (gi - 1) * colw
        gy = y
        done = all(fp -> _eph_get(sd.raw, first(fp)) !== nothing, fields)
        set_string!(buf, gx, gy, gname,
            done ? tstyle(:success, bold = true) : tstyle(:secondary, bold = true);
            max_x = min(right(c), gx + colw - 2))
        gy += 1
        for (sym, label) in fields
            gy > bottom(c) && break
            v = _eph_get(sd.raw, sym)
            txt = fmt_eph(v)
            # Flash a value for ~1 s after it first appears, so the arrival is visible.
            fresh = false
            if txt !== nothing
                key = (hero, sym)
                seen = get!(m.eph_seen, key, m.tick)
                fresh = (m.tick - seen) < 14
            end
            set_string!(buf, gx, gy, rpad(label, 7), tstyle(:text_dim);
                max_x = min(right(c), gx + colw - 2))
            if txt === nothing
                set_string!(buf, gx + 7, gy, "····", tstyle(:text_dim);
                    max_x = min(right(c), gx + colw - 2))
            else
                # Dim while only provisional; bright once the validated copy agrees.
                confirmed = _eph_get(sd.data, sym) !== nothing
                st = fresh ? tstyle(:accent, bold = true) :
                     confirmed ? tstyle(:text) : tstyle(:primary)
                set_string!(buf, gx + 7, gy, txt, st; max_x = min(right(c), gx + colw - 2))
            end
            gy += 1
        end
    end
    return
end
