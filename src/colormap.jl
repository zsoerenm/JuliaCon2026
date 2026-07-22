# Minimal viridis colormap → Tachikoma `ColorRGB` (0–255), for the acquisition 3D
# surface and heatmaps. Interpolated from a handful of viridis control points.

using Tachikoma: ColorRGB

# viridis control points (t = 0 … 1), sRGB 0–1
const _VIRIDIS = (
    (0.267, 0.005, 0.329),
    (0.283, 0.141, 0.458),
    (0.254, 0.265, 0.530),
    (0.207, 0.372, 0.553),
    (0.164, 0.471, 0.558),
    (0.128, 0.567, 0.551),
    (0.135, 0.659, 0.518),
    (0.267, 0.749, 0.441),
    (0.478, 0.821, 0.318),
    (0.741, 0.873, 0.150),
    (0.993, 0.906, 0.144),
)

"""
    viridis(t) -> ColorRGB

Map `t ∈ [0,1]` to a viridis `ColorRGB`. Values outside are clamped.
"""
function viridis(t::Real)
    t = clamp(Float64(t), 0.0, 1.0)
    n = length(_VIRIDIS)
    x = t * (n - 1)
    i = floor(Int, x)
    f = x - i
    a = _VIRIDIS[i+1]
    b = _VIRIDIS[min(i + 2, n)]
    r = a[1] + f * (b[1] - a[1])
    g = a[2] + f * (b[2] - a[2])
    bl = a[3] + f * (b[3] - a[3])
    ColorRGB(round(UInt8, r * 255), round(UInt8, g * 255), round(UInt8, bl * 255))
end
