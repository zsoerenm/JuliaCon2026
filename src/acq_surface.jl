# Build and draw the acquisition correlation surface (power over Doppler × code-phase).
#
# We deliberately do NOT use sixel/PixelImage here: Tachikoma re-emits every graphics
# region on every frame (no diffing), so a persistent sixel panel floods the terminal
# (~fps×/s full-image writes) and can block the event loop — especially on terminals
# whose sixel path is slow. Instead we draw an isometric, viridis-colored ridge surface
# straight into the text buffer with block glyphs: terminal-independent, cheap, no flood.
#
# `power_bins` is in FM-DBZP column order; columns are permuted into monotone code-phase
# (chip) order — the same mapping as Acquisition's plot recipe.

using Tachikoma: Style, set_char!, set_string!, right, bottom, Rect, tstyle
using Unitful: Hz, ustrip
using GNSSSignals: get_code_frequency

# 0-indexed FM-DBZP scrambled column → delay in samples (port of Acquisition's helper).
function _column_to_tau(scrambled_col_idx::Int, num_blocks::Int, block_size::Int)
    block_row = scrambled_col_idx ÷ block_size
    within_block_idx = scrambled_col_idx % block_size
    mod(num_blocks - block_row, num_blocks) * block_size + within_block_idx
end

"Permute `power_bins` columns into ascending code-phase order; return (chip_axis, P)."
function chip_sorted_power(result)
    pb = result.power_bins
    pb === nothing && error("power_bins is nothing; acquire with store_power_bins=true")
    _, spc = size(pb)
    code_freq = Float64(ustrip(Hz, get_code_frequency(result.system)))
    fs = Float64(ustrip(Hz, result.sampling_frequency))
    code_length = spc * code_freq / fs
    chip = Vector{Float64}(undef, spc)
    for c in 0:spc-1
        tau = _column_to_tau(c, result.num_blocks, result.block_size)
        chip[c+1] = mod(-tau * code_freq / fs, code_length)
    end
    order = sortperm(chip)
    chip[order], pb[:, order]
end

# Downsample the (D × C) chip-sorted surface to at most (maxD × maxC) by max-binning,
# keeping the sharp acquisition peak, in a ±chip_window window around it. Returns a
# normalized [0,1] matrix (Doppler × code-phase).
function _downsample_around_peak(chip_axis, P; maxD = 32, maxC = 120, chip_window = 1.5)
    D, C = size(P)
    peak = argmax(P)
    peak_chip = chip_axis[peak[2]]
    code_length = maximum(chip_axis)
    dist(x) = begin
        d = x - peak_chip
        d > code_length / 2 && (d -= code_length)
        d < -code_length / 2 && (d += code_length)
        d
    end
    keep = findall(c -> abs(dist(chip_axis[c])) <= chip_window, 1:C)
    isempty(keep) && (keep = collect(1:C))
    sort!(keep, by = c -> dist(chip_axis[c]))
    Csub = length(keep)
    nc = min(maxC, Csub)
    nd = min(maxD, D)
    Z = fill(-Inf, nd, nc)
    for (jj, c) in enumerate(keep)
        jb = clamp(ceil(Int, jj / Csub * nc), 1, nc)
        for i in 1:D
            ib = clamp(ceil(Int, i / D * nd), 1, nd)
            v = P[i, c]
            v > Z[ib, jb] && (Z[ib, jb] = v)
        end
    end
    replace!(Z, -Inf => 0.0)
    lo, hi = minimum(Z), maximum(Z)
    hi > lo ? (Z .- lo) ./ (hi - lo) : zero(Z)
end

"""
    acq_surface_grid(result; chip_window=1.5) -> NamedTuple

Compute the normalized (Doppler × code-phase) power grid for `result` plus the axis
extents for labelling. `Z[1,:]` is the highest-Doppler row (drawn at the top). Cheap and
small — safe to store in the model and redraw each frame.
"""
function acq_surface_grid(result; full = false, chip_window = 1.5, maxD = 40, maxC = 140)
    chip_axis, P = chip_sorted_power(result)               # ascending code-phase order
    D, spc = size(P)
    peak = argmax(P)
    peak_chip = chip_axis[peak[2]]
    code_length = maximum(chip_axis)
    if full
        keep = collect(1:spc)                              # whole code period
    else
        dist(x) = begin
            d = x - peak_chip
            d > code_length / 2 && (d -= code_length)
            d < -code_length / 2 && (d += code_length)
            d
        end
        keep = findall(c -> abs(dist(chip_axis[c])) <= chip_window, 1:spc)
        isempty(keep) && (keep = collect(1:spc))
        sort!(keep, by = c -> dist(chip_axis[c]))          # monotonic offset order
    end
    Csub = length(keep)
    nc = min(maxC, Csub)
    nd = min(maxD, D)
    Z = fill(-Inf, nd, nc)
    for (jj, c) in enumerate(keep)
        jb = clamp(cld(jj * nc, Csub), 1, nc)              # integer ceil-div: no float gap
        for i in 1:D
            ib = clamp(cld(i * nd, D), 1, nd)
            v = P[i, c]
            v > Z[ib, jb] && (Z[ib, jb] = v)
        end
    end
    replace!(Z, -Inf => 0.0)
    lo, hi = extrema(Z)
    Zn = hi > lo ? (Z .- lo) ./ (hi - lo) : zero(Z)
    Zn = reverse(Zn; dims = 1)                              # row 1 = highest Doppler (top)
    dops = Float64.(ustrip.(Hz, result.dopplers))
    (; Z = Zn, dop_top = maximum(dops), dop_bot = minimum(dops),
        chip_left = chip_axis[keep[1]], chip_right = chip_axis[keep[end]],
        peak_chip = peak_chip, full = full)
end

# Right-align a short numeric label into a gutter of `w` cells.
_gutlabel(v, w) = lpad(string(round(Int, v)), w)

"""
    draw_acq_surface!(buf, rect, S)

Draw the acquisition power surface `S` (from [`acq_surface_grid`](@ref)) as a
viridis-colored **heatmap** into `buf` within `rect`, with Doppler (vertical, Hz) and
code-phase (horizontal, chips) axis labels. The bright cell is the satellite.
"""
function draw_acq_surface!(buf, rect::Rect, S)
    Z = S.Z
    D, C = size(Z)
    gut = 7                                                 # left gutter for Doppler labels
    plotx = rect.x + gut
    plotw = rect.width - gut
    ploth = rect.height - 1                                 # last row for code-phase labels
    (plotw < 4 || ploth < 3) && return

    # Map grid → screen cells by MAX (never average) over the covered block, so the
    # acquisition peak can't be downsampled away when the panel is coarser than the grid.
    for cy in 1:ploth
        i0 = clamp(floor(Int, (cy - 1) / ploth * D) + 1, 1, D)   # top row = highest Doppler
        i1 = clamp(ceil(Int, cy / ploth * D), i0, D)
        y = rect.y + cy - 1
        for cx in 1:plotw
            j0 = clamp(floor(Int, (cx - 1) / plotw * C) + 1, 1, C)
            j1 = clamp(ceil(Int, cx / plotw * C), j0, C)
            z = maximum(@view Z[i0:i1, j0:j1])
            set_char!(buf, plotx + cx - 1, y, '█', Style(fg = viridis(z)))
        end
    end

    # Doppler (y) labels: top / middle / bottom
    dmid = (S.dop_top + S.dop_bot) / 2
    set_string!(buf, rect.x, rect.y, _gutlabel(S.dop_top, gut - 1), tstyle(:text_dim))
    set_string!(buf, rect.x, rect.y + ploth ÷ 2, _gutlabel(dmid, gut - 1), tstyle(:text_dim))
    set_string!(buf, rect.x, rect.y + ploth - 1, _gutlabel(S.dop_bot, gut - 1), tstyle(:text_dim))
    set_string!(buf, rect.x, rect.y + ploth, "Dopp", tstyle(:text_dim); max_x = plotx - 2)

    # Code-phase (x) labels along the bottom row
    yb = rect.y + ploth
    set_string!(buf, plotx, yb, string(round(S.chip_left; digits = 1)),
        tstyle(:text_dim); max_x = right(rect))
    mid = "code phase [chips]"
    set_string!(buf, plotx + max(0, (plotw - length(mid)) ÷ 2), yb, mid,
        tstyle(:text_dim); max_x = right(rect))
    rlbl = string(round(S.chip_right; digits = 1))
    set_string!(buf, right(rect) - length(rlbl) + 1, yb, rlbl, tstyle(:text_dim); max_x = right(rect))
    return
end
