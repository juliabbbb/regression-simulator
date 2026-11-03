# src/chart.jl - pure-Julia SVG scatter plot builder (no plotting packages, no client-side scripting).
#
# The chart is built from the same SLRResult the table uses, so n, the points and
# the regression line always agree with the calculation panel. Styling lives
# entirely in static/style.css: this file only emits classes.

const CHART_WIDTH = 640.0
const CHART_HEIGHT = 400.0
const CHART_PAD_LEFT = 68.0
const CHART_PAD_RIGHT = 20.0
const CHART_PAD_TOP = 20.0
const CHART_PAD_BOTTOM = 54.0
const CHART_PLOT_W = CHART_WIDTH - CHART_PAD_LEFT - CHART_PAD_RIGHT
const CHART_PLOT_H = CHART_HEIGHT - CHART_PAD_TOP - CHART_PAD_BOTTOM

function _chart_escape(s::AbstractString)::String
    s = replace(s, '&' => "&amp;")
    s = replace(s, '<' => "&lt;")
    s = replace(s, '>' => "&gt;")
    s = replace(s, '"' => "&quot;")
    return replace(s, '\'' => "&#39;")
end

"Trim a fixed-point string: 2.50 -> 2.5, 3.0 -> 3."
function _trim_decimal(s::String)::String
    occursin('.', s) || return s
    s = rstrip(s, '0')
    endswith(s, '.') && (s = s[1:end - 1])
    (isempty(s) || s == "-0") && return "0"
    return s
end

"SVG coordinate: 2 decimals is plenty for a 640px viewBox."
function _chart_num(v::Float64)::String
    v == 0 && return "0"
    return _trim_decimal(string(round(v, digits = 2)))
end

"""
Compact tick label. Fixed point for everyday magnitudes, Julia's shortest
scientific form for extremes (< 1e-4 or >= 1e6), e.g. 1e9 -> "1e9".
"""
function fmt_tick(v::Float64)::String
    v == 0 && return "0"
    if abs(v) >= 1.0e6 || abs(v) < 1.0e-4
        return replace(string(v), ".0e" => "e")
    end
    rounded = round(v, digits = 6)
    rounded == 0 && return "0"
    return _trim_decimal(string(rounded))
end

"Nice axis step: 1, 2 or 5 times a power of ten."
function nice_step(lo::Float64, hi::Float64, target::Int = 6)::Float64
    span = hi - lo
    (span <= 0 || !isfinite(span)) && return 1.0
    raw = span / target
    mag = 10.0^floor(log10(raw))
    for m in (1.0, 2.0, 5.0, 10.0)
        m * mag >= raw && return m * mag
    end
    return 10.0 * mag
end

"Tick values inside [lo, hi] using a 1/2/5 x 10^k step (~`target` ticks)."
function nice_ticks(lo::Float64, hi::Float64, target::Int = 6)::Vector{Float64}
    step = nice_step(lo, hi, target)
    ticks = Float64[]
    v = ceil(lo / step - 1e-9) * step
    while v <= hi + step * 1e-6 && length(ticks) < 100
        push!(ticks, abs(v) < step * 1e-9 ? 0.0 : v)
        v += step
    end
    isempty(ticks) && push!(ticks, (lo + hi) / 2)
    return ticks
end

"""
Axis window with ~5% padding. Degenerate ranges (all values identical, or all
zero) still get a positive span so the SVG never divides by zero.
"""
function _axis_bounds(lo::Float64, hi::Float64)::Tuple{Float64, Float64}
    if hi > lo
        pad = (hi - lo) * 0.05
        return lo - pad, hi + pad
    end
    pad = abs(hi) > 0 ? abs(hi) * 0.05 : 1.0
    return lo - pad, hi + pad
end

"Data window (padded) shared by the renderer and the tests."
function chart_view(result)
    xlo, xhi = _axis_bounds(minimum(result.x), maximum(result.x))
    ylo, yhi = _axis_bounds(minimum(result.y), maximum(result.y))
    return (xlo = xlo, xhi = xhi, ylo = ylo, yhi = yhi)
end

"Data x -> SVG x."
function chart_x(view, xv::Real)::Float64
    return CHART_PAD_LEFT + (Float64(xv) - view.xlo) / (view.xhi - view.xlo) * CHART_PLOT_W
end

"Data y -> SVG y (SVG y grows downwards)."
function chart_y(view, yv::Real)::Float64
    return CHART_PAD_TOP + (view.yhi - Float64(yv)) / (view.yhi - view.ylo) * CHART_PLOT_H
end

"Data point in SVG coordinates; used by the renderer and the tests."
function chart_point(result, xv::Real, yv::Real)::Tuple{Float64, Float64}
    view = chart_view(result)
    return (chart_x(view, xv), chart_y(view, yv))
end

"""
Render the scatter plot for `result`: grid, axes, nice ticks, residual lines
(hidden by CSS until `#show-resid` is checked), the regression line and one
circle per data point.
"""
const HIST_WIDTH = 360.0
const HIST_HEIGHT = 150.0
const HIST_PAD_LEFT = 34.0
const HIST_PAD_RIGHT = 10.0
const HIST_PAD_TOP = 12.0
const HIST_PAD_BOTTOM = 28.0
const HIST_PLOT_W = HIST_WIDTH - HIST_PAD_LEFT - HIST_PAD_RIGHT
const HIST_PLOT_H = HIST_HEIGHT - HIST_PAD_TOP - HIST_PAD_BOTTOM

"""
SVG histogram of one numeric attribute: 10 equal-width bins between the min
and max, or a single full-width bar when every value is identical. Returns an
empty string when there are no finite values. Styling is CSS-only.
"""
function render_histogram(values; bins::Int = 10)::String
    nums = Float64[]
    for v in values
        x = Float64(v)
        isfinite(x) && push!(nums, x)
    end
    isempty(nums) && return ""

    lo, hi = extrema(nums)
    left = HIST_PAD_LEFT
    right = left + HIST_PLOT_W
    top = HIST_PAD_TOP
    bottom = top + HIST_PLOT_H
    t = IOBuffer()

    print(t, "<div class=\"histogram-wrap\">\n")
    print(t, "  <div class=\"histogram-caption\">Histogram</div>\n")
    print(t, "  <svg class=\"histogram\" viewBox=\"0 0 ", _chart_num(HIST_WIDTH), " ", _chart_num(HIST_HEIGHT),
          "\" role=\"img\" aria-label=\"Histogram of the selected attribute\">\n")

    if hi == lo
        # A single value has no width: draw one full-width bar.
        print(t, "    <rect class=\"bar\" x=\"", _chart_num(left + 1), "\" y=\"", _chart_num(top),
              "\" width=\"", _chart_num(HIST_PLOT_W - 2), "\" height=\"", _chart_num(HIST_PLOT_H), "\"/>\n")
        print(t, "    <text class=\"hist-label\" x=\"", _chart_num((left + right) / 2), "\" y=\"",
              _chart_num(top + 16), "\" text-anchor=\"middle\">", _chart_escape(fmt_tick(lo)), "</text>\n")
    else
        step = (hi - lo) / bins
        counts = zeros(Int, bins)
        for v in nums
            idx = min(max(floor(Int, (v - lo) / step) + 1, 1), bins)
            counts[idx] += 1
        end
        maxcount = maximum(counts)
        barw = HIST_PLOT_W / bins
        for b in 1:bins
            counts[b] == 0 && continue
            hgt = counts[b] / maxcount * HIST_PLOT_H
            print(t, "    <rect class=\"bar\" x=\"", _chart_num(left + (b - 1) * barw + 1.5),
                  "\" y=\"", _chart_num(bottom - hgt), "\" width=\"", _chart_num(barw - 3),
                  "\" height=\"", _chart_num(hgt), "\"/>\n")
        end
        print(t, "    <line class=\"hist-grid\" x1=\"", _chart_num(left), "\" y1=\"", _chart_num(top),
              "\" x2=\"", _chart_num(right), "\" y2=\"", _chart_num(top), "\"/>\n")
        print(t, "    <text class=\"hist-label\" x=\"", _chart_num(left - 6), "\" y=\"", _chart_num(top + 4),
              "\" text-anchor=\"end\">", maxcount, "</text>\n")
        print(t, "    <text class=\"hist-label\" x=\"", _chart_num(left - 6), "\" y=\"", _chart_num(bottom + 4),
              "\" text-anchor=\"end\">0</text>\n")
        print(t, "    <text class=\"hist-label\" x=\"", _chart_num(left), "\" y=\"", _chart_num(bottom + 20),
              "\" text-anchor=\"middle\">", _chart_escape(fmt_tick(lo)), "</text>\n")
        print(t, "    <text class=\"hist-label\" x=\"", _chart_num(right), "\" y=\"", _chart_num(bottom + 20),
              "\" text-anchor=\"middle\">", _chart_escape(fmt_tick(hi)), "</text>\n")
    end

    print(t, "    <line class=\"hist-axis\" x1=\"", _chart_num(left), "\" y1=\"", _chart_num(bottom),
          "\" x2=\"", _chart_num(right), "\" y2=\"", _chart_num(bottom), "\"/>\n")
    print(t, "    <line class=\"hist-axis\" x1=\"", _chart_num(left), "\" y1=\"", _chart_num(top),
          "\" x2=\"", _chart_num(left), "\" y2=\"", _chart_num(bottom), "\"/>\n")
    print(t, "  </svg>\n</div>\n")
    return String(take!(t))
end

function render_chart(result; x_title::AbstractString = "X", y_title::AbstractString = "Y")::String
    view = chart_view(result)
    xticks = nice_ticks(view.xlo, view.xhi)
    yticks = nice_ticks(view.ylo, view.yhi)
    left = CHART_PAD_LEFT
    right = left + CHART_PLOT_W
    top = CHART_PAD_TOP
    bottom = top + CHART_PLOT_H
    t = IOBuffer()

    print(t, "<div class=\"chart-wrap\">\n")
    # The checkbox must be a sibling placed BEFORE the <svg> so the pure-CSS
    # rule `#show-resid:checked ~ svg .resid` can reveal the residual lines.
    print(t, "  <input type=\"checkbox\" id=\"show-resid\" class=\"chart-resid-toggle\">\n")
    print(t, "  <label for=\"show-resid\" class=\"chart-resid-label\">Show residuals</label>\n")
    print(t, "  <svg class=\"chart\" viewBox=\"0 0 ", _chart_num(CHART_WIDTH), " ", _chart_num(CHART_HEIGHT),
          "\" role=\"img\" aria-label=\"Scatter plot of the data with the regression line\">\n")

    # Grid first, so axes, line and points sit above it.
    for v in xticks
        px = chart_x(view, v)
        print(t, "    <line class=\"grid\" x1=\"", _chart_num(px), "\" y1=\"", _chart_num(top),
              "\" x2=\"", _chart_num(px), "\" y2=\"", _chart_num(bottom), "\"/>\n")
    end
    for v in yticks
        py = chart_y(view, v)
        print(t, "    <line class=\"grid\" x1=\"", _chart_num(left), "\" y1=\"", _chart_num(py),
              "\" x2=\"", _chart_num(right), "\" y2=\"", _chart_num(py), "\"/>\n")
    end

    for v in xticks
        print(t, "    <text class=\"tick-label\" x=\"", _chart_num(chart_x(view, v)), "\" y=\"",
              _chart_num(bottom + 20), "\" text-anchor=\"middle\">", _chart_escape(fmt_tick(v)), "</text>\n")
    end
    for v in yticks
        print(t, "    <text class=\"tick-label\" x=\"", _chart_num(left - 10), "\" y=\"",
              _chart_num(chart_y(view, v) + 5), "\" text-anchor=\"end\">", _chart_escape(fmt_tick(v)), "</text>\n")
    end

    print(t, "    <line class=\"axis\" x1=\"", _chart_num(left), "\" y1=\"", _chart_num(bottom),
          "\" x2=\"", _chart_num(right), "\" y2=\"", _chart_num(bottom), "\"/>\n")
    print(t, "    <line class=\"axis\" x1=\"", _chart_num(left), "\" y1=\"", _chart_num(top),
          "\" x2=\"", _chart_num(left), "\" y2=\"", _chart_num(bottom), "\"/>\n")

    # Residual lines: one per point, from the observation to its predicted Y.
    for i in eachindex(result.x)
        px = chart_x(view, result.x[i])
        print(t, "    <line class=\"resid\" x1=\"", _chart_num(px), "\" y1=\"", _chart_num(chart_y(view, result.y[i])),
              "\" x2=\"", _chart_num(px), "\" y2=\"", _chart_num(chart_y(view, result.yhat[i])), "\"/>\n")
    end

    # Regression line spans the data's x extent; it passes through (xbar, ybar).
    x_start = minimum(result.x)
    x_end = maximum(result.x)
    print(t, "    <line class=\"regline\" x1=\"", _chart_num(chart_x(view, x_start)), "\" y1=\"",
          _chart_num(chart_y(view, result.a + result.b * x_start)), "\" x2=\"",
          _chart_num(chart_x(view, x_end)), "\" y2=\"",
          _chart_num(chart_y(view, result.a + result.b * x_end)), "\"/>\n")

    for i in eachindex(result.x)
        print(t, "    <circle class=\"point\" cx=\"", _chart_num(chart_x(view, result.x[i])),
              "\" cy=\"", _chart_num(chart_y(view, result.y[i])), "\" r=\"4\"/>\n")
    end

    print(t, "    <text class=\"axis-title\" x=\"", _chart_num(left + CHART_PLOT_W / 2), "\" y=\"",
          _chart_num(CHART_HEIGHT - 8), "\" text-anchor=\"middle\">", _chart_escape(x_title), "</text>\n")
    print(t, "    <text class=\"axis-title\" x=\"16\" y=\"", _chart_num(top + CHART_PLOT_H / 2),
          "\" text-anchor=\"middle\" transform=\"rotate(-90 16 ", _chart_num(top + CHART_PLOT_H / 2),
          ")\">", _chart_escape(y_title), "</text>\n")

    print(t, "  </svg>\n</div>\n")
    return String(take!(t))
end
