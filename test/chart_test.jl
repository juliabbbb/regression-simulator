using Test
include(joinpath(@__DIR__, "..", "src", "regression.jl"))
include(joinpath(@__DIR__, "..", "src", "chart.jl"))
using .Regression

@testset "chart: one circle per point" begin
    r = slr([1, 2, 3, 4, 5], [2, 4, 5, 4, 6])
    svg = render_chart(r)

    @test length(collect(eachmatch(r"<circle\b", svg))) == r.n
    @test length(collect(eachmatch(r"<circle\b", svg))) == 5

    # Points are drawn at the mapped (x, y) pairs, one each, no additions.
    for i in eachindex(r.x)
        px, py = chart_point(r, r.x[i], r.y[i])
        @test occursin("cx=\"" * _chart_num(px) * "\" cy=\"" * _chart_num(py) * "\"", svg)
    end
    cxs = [m.captures[1] for m in eachmatch(r"cx=\"([-0-9.]+)\"", svg)]
    @test length(unique(cxs)) == 5
end

@testset "chart: regression line passes through (xbar, ybar)" begin
    r = slr([1, 2, 3, 4, 5], [2, 4, 5, 4, 6])
    svg = render_chart(r)

    m = match(r"<line class=\"regline\" x1=\"([-0-9.]+)\" y1=\"([-0-9.]+)\" x2=\"([-0-9.]+)\" y2=\"([-0-9.]+)\"", svg)
    @test m !== nothing
    x1, y1, x2, y2 = parse.(Float64, m.captures)

    bx, by = chart_point(r, r.xbar, r.ybar)

    # Collinear with the drawn segment (coordinates are rounded to 2 decimals).
    cross = (x2 - x1) * (by - y1) - (y2 - y1) * (bx - x1)
    @test abs(cross) < 5.0

    # And the mean point actually lies between the endpoints.
    @test min(x1, x2) - 1e-6 <= bx <= max(x1, x2) + 1e-6
    @test min(y1, y2) - 1e-6 <= by <= max(y1, y2) + 1e-6

    # The line is drawn from a + b*x, which equals ybar at xbar.
    @test r.a + r.b * r.xbar ≈ r.ybar
    @test by ≈ chart_point(r, r.xbar, r.a + r.b * r.xbar)[2]
    # SVG coordinates are rounded to 2 decimals, so allow half a unit-last-place.
    view = chart_view(r)
    @test isapprox(x1, chart_x(view, minimum(r.x)); atol = 0.01)
    @test isapprox(y1, chart_y(view, r.a + r.b * minimum(r.x)); atol = 0.01)
    @test isapprox(x2, chart_x(view, maximum(r.x)); atol = 0.01)
    @test isapprox(y2, chart_y(view, r.a + r.b * maximum(r.x)); atol = 0.01)
end

@testset "chart: residual toggle is pure CSS" begin
    r = slr([1, 2, 3, 4, 5], [2, 4, 5, 4, 6])
    svg = render_chart(r)

    # One residual line per point.
    @test length(collect(eachmatch(r"<line class=\"resid\"", svg))) == r.n

    # The checkbox is a sibling placed before the <svg>.
    toggle = findfirst("id=\"show-resid\"", svg)
    svg_open = findfirst("<svg class=\"chart\"", svg)
    @test toggle !== nothing && svg_open !== nothing
    @test first(toggle) < first(svg_open)
    @test occursin("<label for=\"show-resid\"", svg)

    css = read(joinpath(@__DIR__, "..", "static", "style.css"), String)
    @test occursin(".resid {", css)
    @test occursin("display: none", css)
    @test occursin("#show-resid:checked ~ svg .resid", css)
    @test occursin("display: inline", css)
end

@testset "chart: ticks are nice and compact" begin
    for (lo, hi) in ((-3.7, 9.2), (0.0, 1.0), (1.0e9, 5.0e9), (1.0e-9, 5.0e-9))
        step = nice_step(lo, hi)
        mantissa = step / 10.0^floor(log10(step))
        @test mantissa ≈ 1.0 || mantissa ≈ 2.0 || mantissa ≈ 5.0

        ticks = nice_ticks(lo, hi)
        @test !isempty(ticks)
        @test length(ticks) <= 12
        @test all(lo - step * 1e-6 <= tc <= hi + step * 1e-6 for tc in ticks)
    end

    @test fmt_tick(0.0) == "0"
    @test fmt_tick(2.0) == "2"
    @test fmt_tick(-0.5) == "-0.5"
    @test fmt_tick(1.0e9) == "1e9"
    @test fmt_tick(2.5e8) == "2.5e8"
    @test fmt_tick(-1.0e9) == "-1e9"
    @test fmt_tick(1.0e-9) == "1e-9"
    @test fmt_tick(1.5e-9) == "1.5e-9"
    @test fmt_tick(1234567.0) == "1.234567e6"
end

@testset "chart: edge cases still produce valid SVG" begin
    cases = [
        ("flat line (all Y identical)", slr([1, 2, 3, 4], [5, 5, 5, 5])),
        ("everything zero", slr([0, 1, 2], [0, 0, 0])),
        ("very large values", slr([1.0e9, 2.0e9, 3.0e9], [2.0e9, 4.0e9, 6.0e9])),
        ("very small values", slr([1.0e-9, 2.0e-9, 3.0e-9], [2.0e-9, 4.0e-9, 6.0e-9])),
        ("negative values", slr([-5, -2, 0, 3], [-8, -1, 2, 9])),
        ("two points", slr([1, 2], [10, 20])),
    ]

    for (name, r) in cases
        svg = render_chart(r)
        @test occursin("<svg class=\"chart\"", svg)
        @test occursin("</svg>", svg)
        @test length(collect(eachmatch(r"<circle\b", svg))) == r.n
        @test occursin("class=\"regline\"", svg)
        @test occursin("class=\"axis\"", svg)
        @test occursin("class=\"tick-label\"", svg)
        @test occursin(">X</text>", svg)
        @test occursin(">Y</text>", svg)
        @test !occursin("NaN", svg)
        @test !occursin("Inf", svg)
        # Every coordinate attribute must be a finite number.
        @test all(isfinite.(parse.(Float64, m.captures[1] for m in eachmatch(r"(?:cx|cy|x[12]|y[12])=\"([-0-9.eE]+)\"", svg))))
    end

    # Flat Y: both regression endpoints share one y coordinate.
    flat = render_chart(slr([1, 2, 3, 4], [5, 5, 5, 5]))
    m = match(r"<line class=\"regline\" x1=\"[-0-9.]+\" y1=\"([-0-9.]+)\" x2=\"[-0-9.]+\" y2=\"([-0-9.]+)\"", flat)
    @test m !== nothing
    @test parse(Float64, m.captures[1]) == parse(Float64, m.captures[2])
end

@testset "histogram: 10 equal-width bins, single bar for identical values" begin
    varied = [1, 2, 2, 3, 4, 4, 4, 5, 6, 7, 8, 9, 10]
    svg = render_histogram(varied)

    @test occursin("<svg class=\"histogram\"", svg)
    @test occursin("class=\"histogram-caption\"", svg)
    @test occursin("class=\"hist-axis\"", svg)
    @test occursin("class=\"hist-label\"", svg)
    bars = length(collect(eachmatch(r"<rect class=\"bar\"", svg)))
    @test 1 <= bars <= 10
    @test bars == 10 # every bin is populated for this dataset
    @test !occursin("NaN", svg)
    @test !occursin("Inf", svg)

    # All values identical: exactly one full-width bar.
    flat = render_histogram(fill(7.0, 5))
    @test length(collect(eachmatch(r"<rect class=\"bar\"", flat))) == 1
    @test occursin(">7</text>", flat)

    # Negative and huge/tiny values still render, never NaN.
    for vals in ([-5.0, -2.0, 0.0, 3.0], [1.0e9, 2.0e9], [1.0e-9, 2.0e-9, 3.0e-9])
        out = render_histogram(vals)
        @test occursin("class=\"histogram\"", out)
        @test length(collect(eachmatch(r"<rect class=\"bar\"", out))) >= 1
        @test !occursin("NaN", out)
    end

    # Empty / non-finite input renders nothing at all.
    @test render_histogram(Float64[]) == ""
    @test render_histogram([NaN, Inf]) == ""

    css = read(joinpath(@__DIR__, "..", "static", "style.css"), String)
    for cls in (".histogram {", ".bar {", ".hist-axis {", ".hist-grid {", ".hist-label {")
        @test occursin(cls, css)
    end
end

@testset "chart: axis titles default to X and Y" begin
    r = slr([1, 2, 3], [2, 4, 5])
    svg = render_chart(r)
    @test occursin("class=\"axis-title\" x=", svg)
    @test occursin(">X</text>", svg)
    @test occursin(">Y</text>", svg)

    named = render_chart(r; x_title = "Height <cm>", y_title = "Weight & kg")
    @test occursin("Height &lt;cm&gt;", named)
    @test occursin("Weight &amp; kg", named)
end
