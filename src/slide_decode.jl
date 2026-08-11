# Slide 5 — decoding. The receiver is started the moment this slide is first shown
# (`_on_slide_enter!`), so everything here fills in live, from zero, in front of the
# audience: which subframe is arriving, the time-of-week the satellite reports every six
# seconds, and the ephemeris values.
#
# Values appear as soon as they are decoded — never held back. `GNSSDecoder` can only hand
# them over a subframe at a time (`decode_syncro_sequence` waits for all 300 bits, then
# decodes ten words in one call), so the grid fills in three jumps. The subframe indicator
# below carries the progress *between* those jumps, which is what makes the wait legible
# without delaying anything.

const SUBFRAME_BITS = 300         # 300 bits at 50 bit/s = 6 s
const NAV_BIT_RATE = 50
const EPH_FLASH = 1.2             # seconds a freshly decoded value stays highlighted

# All five subframes cycle every 30 s. Only 1–3 carry the ephemeris we need; 4 and 5 are
# almanac and ionospheric data. Showing them is the honest explanation of why a fix takes
# ~30 s rather than ~18: if you tune in during 4, you wait for the cycle to come round.
const SUBFRAME_NAMES = ("clock", "ephemeris 1", "ephemeris 2", "almanac", "almanac")
const NUM_SUBFRAMES = 5
# Named for this slide: every `slide_*.jl` is `include`d into the one `GNSSPresentation`
# module, so a bare `SPINNER` here silently redefined the acquisition slide's 10-frame
# braille spinner and made it index a 4-tuple out of bounds. Keep slide-local constants
# prefixed — there is a test that enforces it.
const DECODE_SPINNER = ('◐', '◓', '◑', '◒')

_eph_get(raw, sym) = raw === nothing ? nothing :
                     (hasproperty(raw, sym) ? getproperty(raw, sym) : nothing)

"""
    _eph_val(sd, sym)

The best value we hold for `sym`: the *validated* copy if there is one, otherwise the
provisional one still being accumulated.

Reading `raw` alone is wrong, and the failure is delayed and confusing. `raw_data` is not
a monotonically filling buffer: `GNSSDecoder.confirm_data` promotes it into `data` on a
successful validation and resets it to a blank `GPSL1CAData()` on several branches, so the
whole grid emptied itself the moment the ephemeris validated — while `complete` stayed
true and the time-of-week stayed on screen. That looked like a bug on revisiting the
slide, but it was simply whatever happened after ~40 s.
"""
_eph_val(sd, sym) =
    let v = _eph_get(sd.data, sym)
        v === nothing ? _eph_get(sd.raw, sym) : v
    end

"Is every field of ephemeris group `g` decoded?"
_group_done(sd, g) = all(f -> _eph_val(sd, first(f)) !== nothing, last(g))

"""
    _subframe_states(sd) -> (states, current)

`states[n]` is `:done`, `:receiving` or `:pending` for each of the five subframes, and
`current` is the subframe the decoder last saw (or `nothing` before the first sync).
Subframes 4 and 5 are never `:done` — we do not collect their fields — so they read as
pending traffic we have to sit through.
"""
function _subframe_states(sd)
    cur = _eph_get(sd.raw, :last_subframe_id)
    cur = (cur isa Integer && 1 <= cur <= NUM_SUBFRAMES) ? Int(cur) : nothing
    states = map(1:NUM_SUBFRAMES) do n
        if n <= length(EPHEMERIS_GROUPS) && _group_done(sd, EPHEMERIS_GROUPS[n])
            :done
        elseif n == cur
            :receiving
        else
            :pending
        end
    end
    (states, cur)
end

"""
    _decode_status(sd) -> (kind, subframe)

What to say about progress. `kind` is one of:

- `:complete` — all three ephemeris subframes decoded; there is nothing left to wait for
- `:receiving` / `:almanac` — `subframe` is on the air now
- `:between` — we have decoded values but no current subframe id
- `:nosync` — genuinely nothing yet

`:between` is the case that matters. `last_subframe_id` lives in `raw_data`, which
`confirm_data` blanks on validation, so once the ephemeris is in (or the recording has
run out) `cur` goes back to `nothing` while the grid is full. Deriving the caption from
`cur` alone therefore announced "no subframe sync yet" underneath a complete ephemeris.
"""
function _decode_status(sd)
    states, cur = _subframe_states(sd)
    if all(n -> states[n] == :done, 1:length(EPHEMERIS_GROUPS))
        return (:complete, cur)
    elseif cur !== nothing
        return (cur <= length(EPHEMERIS_GROUPS) ? :receiving : :almanac, cur)
    elseif any(sym -> _eph_val(sd, sym) !== nothing, EPHEMERIS_FIELDS)
        return (:between, nothing)
    end
    (:nosync, nothing)
end

# The satellite whose values we show in full. Prefer the one selected on the acquisition
# slide (so the story follows one satellite across slides); otherwise the satellite that
# is furthest along, so the grid is as alive as possible.
function _hero_prn(sats, selected)
    isempty(sats) && return nothing
    selected !== nothing && haskey(sats, selected) && return selected
    best, bestscore = nothing, -1
    for (prn, sd) in pairs(sats)
        score = count(sym -> _eph_val(sd, sym) !== nothing, EPHEMERIS_FIELDS)
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
    cols = split_layout(Layout(Horizontal, [Fixed(42), Fill()]), rows[1])
    leftrows = split_layout(Layout(Vertical, [Fixed(12), Fill()]), cols[1])

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

# ── Progress: overall orbit numbers, and which subframe is arriving right now ──
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

    # Progress is measured by how many orbit numbers we hold, NOT by `bits_in_subframe`:
    # that field stays `nothing` long after words are demonstrably decoding, so driving
    # the bar from it showed "searching for the preamble… 0/300" while values were
    # already landing in the grid.
    got = count(sym -> _eph_val(sd, sym) !== nothing, EPHEMERIS_FIELDS)
    total = length(EPHEMERIS_FIELDS)
    states, cur = _subframe_states(sd)
    kind, _ = _decode_status(sd)

    # "decoded", not "complete": the readiness strip reserves "validated" for the
    # decoder's own gate, and the two must not be confusable.
    hdr, hstyle = kind == :complete ? ("PRN $(hero) — ephemeris decoded ✓", tstyle(:success, bold = true)) :
                  kind == :nosync ? ("PRN $(hero) — waiting for subframe sync…", tstyle(:warning)) :
                  ("PRN $(hero) — decoding ●", tstyle(:success, bold = true))
    set_string!(buf, x, y, hdr, hstyle; max_x = right(c))
    y += 2

    barw = max(4, c.width - 3)
    filled = round(Int, barw * got / total)
    set_string!(buf, x, y, "█"^filled, tstyle(:primary, bold = true); max_x = right(c))
    set_string!(buf, x + filled, y, "░"^max(0, barw - filled), tstyle(:text_dim); max_x = right(c))
    y += 1
    set_string!(buf, x, y, "$(got) / $(total) orbit numbers", tstyle(:text_dim); max_x = right(c))
    y += 2

    # The subframe indicator: what is on the air right now. This is the loading status —
    # the grid can sit still for six seconds, but this never does.
    spin = DECODE_SPINNER[mod(m.tick ÷ 3, length(DECODE_SPINNER))+1]
    set_string!(buf, x, y, "subframes", tstyle(:text_dim); max_x = right(c))
    sx = x + 10
    for n in 1:NUM_SUBFRAMES
        st = states[n]
        mark, style = st == :done ? ('✓', tstyle(:success, bold = true)) :
                      st == :receiving ? (spin, tstyle(:accent, bold = true)) :
                      ('·', tstyle(:text_dim))
        set_string!(buf, sx, y, string(n), st == :pending ? tstyle(:text_dim) : tstyle(:text);
            max_x = right(c))
        set_string!(buf, sx + 1, y, string(mark), style; max_x = right(c))
        sx += 4
    end
    y += 1
    if kind == :complete
        # Nothing left to wait for: no spinner, or it looks like it is still working.
        set_string!(buf, x, y, "✓ all 3 ephemeris subframes decoded",
            tstyle(:success, bold = true); max_x = right(c))
    elseif kind == :receiving
        set_string!(buf, x, y, "$(spin) subframe $(cur) — $(SUBFRAME_NAMES[cur]) · 6 s",
            tstyle(:accent); max_x = right(c))
    elseif kind == :almanac
        # Waiting out traffic we do not need is most of why a fix takes ~30 s.
        set_string!(buf, x, y, "$(spin) subframe $(cur) — almanac, not needed",
            tstyle(:text_dim); max_x = right(c))
    elseif kind == :between
        set_string!(buf, x, y, "$(spin) waiting for the next subframe",
            tstyle(:accent); max_x = right(c))
    else
        set_string!(buf, x, y, "no subframe sync yet", tstyle(:text_dim); max_x = right(c))
    end
    y += 2

    # Time of week — the answer to the tracking slide's question, arriving every 6 s.
    # The decoder clears TOW again whenever the next one isn't exactly prev+1, so the raw
    # field flickers; we latch the last value actually decoded rather than blinking "——"
    # at the audience while every other field on the slide is filled in.
    tow = _eph_val(sd, :TOW)
    tow isa Integer && (m.last_tow[hero] = tow)
    shown = get(m.last_tow, hero, nothing)
    y > bottom(c) && return
    if shown === nothing
        set_string!(buf, x, y, "time of week: ——", tstyle(:text_dim); max_x = right(c))
    else
        set_string!(buf, x, y, "time of week: $(shown) s", tstyle(:success, bold = true); max_x = right(c))
        y + 1 <= bottom(c) && set_string!(buf, x, y + 1, "the satellite just told us the time",
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
    # Label the dots. Three unlabelled dots per PRN is a puzzle — they are ephemeris
    # subframes 1-3 for that satellite. They light up almost together for every satellite,
    # which looks wrong but is right: GPS subframe epochs are synchronised to GPS time
    # across the whole constellation, so all satellites transmit subframe 1 in the same
    # 6-second window, then subframe 2, and so on. What differs per satellite is the
    # *contents* — each broadcasts its own orbit.
    hx = x + 7
    for i in 1:length(EPHEMERIS_GROUPS)
        set_string!(buf, hx, y, string(i), tstyle(:text_dim); max_x = right(c))
        hx += 2
    end
    set_string!(buf, hx + 1, y, "subframes", tstyle(:text_dim); max_x = right(c))
    y += 1

    # Counted over every satellite, not just the rows that fit: on a short terminal the
    # loop below breaks early, and tallying inside it under-reported the count that the
    # whole slide builds towards.
    ready = count(sd -> sd.complete, sats)
    for prn in sort(collect(keys(sats)))
        y > bottom(c) - 2 && break
        sd = sats[prn]
        set_string!(buf, x, y, "PRN " * lpad(prn, 2), tstyle(:text); max_x = right(c))
        cx = x + 7
        for g in EPHEMERIS_GROUPS
            done = _group_done(sd, g)
            set_string!(buf, cx, y, done ? "●" : "·",
                done ? tstyle(:success, bold = true) : tstyle(:text_dim); max_x = right(c))
            cx += 2
        end
        # Two different things, deliberately worded differently. The dots mean subframes
        # *decoded* — we hold the numbers. The tick means the decoder has *validated* them
        # for positioning: `is_decoding_completed_for_positioning`, which additionally
        # needs TOW and the integrity/alert flags, requires IODC[3:10] == IODE_Sub_2 ==
        # IODE_Sub_3 (proving all three subframes belong to one ephemeris), and must pass
        # `confirm_data`'s vote. "checking" is the gap between the two, and it needs all
        # three subframes — testing only 1 and 3 claimed "checking" while 2 was missing,
        # i.e. while the satellite was still plainly transmitting.
        if sd.complete
            set_string!(buf, cx + 1, y, "✓ validated", tstyle(:success); max_x = right(c))
        elseif all(g -> _group_done(sd, g), EPHEMERIS_GROUPS)
            set_string!(buf, cx + 1, y, "· checking", tstyle(:text_dim); max_x = right(c))
        end
        y += 1
    end
    # The suspense meter: this is what pays off on the next slide.
    n = length(sats)
    style = ready >= 4 ? tstyle(:success, bold = true) : tstyle(:warning, bold = true)
    msg = ready >= 4 ? "$(ready)/$(n) validated — enough for a fix" :
          "$(ready)/$(n) validated — need 4 for a fix"
    set_string!(buf, x, bottom(c), msg, style; max_x = right(c))
    return
end

# ── The ephemeris grid: values appear as soon as their subframe is decoded ────
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
    now = time()

    for (gi, (gname, fields)) in enumerate(EPHEMERIS_GROUPS)
        gx = x + (gi - 1) * colw
        gy = y
        gmax = min(right(c), gx + colw - 2)
        done = _group_done(sd, (gname, fields))
        set_string!(buf, gx, gy, gname,
            done ? tstyle(:success, bold = true) : tstyle(:secondary, bold = true); max_x = gmax)
        gy += 1
        for (sym, label) in fields
            gy > bottom(c) && break
            txt = fmt_eph(_eph_val(sd, sym))
            set_string!(buf, gx, gy, rpad(label, 7), tstyle(:text_dim); max_x = gmax)
            if txt === nothing
                set_string!(buf, gx + 7, gy, "····", tstyle(:text_dim); max_x = gmax)
            else
                # Flash briefly on first sight, then settle: bright once the validated
                # copy agrees, dimmer while still provisional.
                seen = get!(m.eph_seen, (hero, sym), now)
                fresh = (now - seen) < EPH_FLASH
                confirmed = _eph_get(sd.data, sym) !== nothing
                st = fresh ? tstyle(:accent, bold = true) :
                     confirmed ? tstyle(:text) : tstyle(:primary)
                set_string!(buf, gx + 7, gy, txt, st; max_x = gmax)
            end
            gy += 1
        end
    end
    return
end
