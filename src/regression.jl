module Regression

export SLRResult, slr

"""
All intermediate values are kept so the UI can show every step of the table.
Excel equivalents: b=SLOPE, a=INTERCEPT, r=CORREL, r2=RSQ, se=STEYX
"""
struct SLRResult
    n::Int
    x::Vector{Float64}
    y::Vector{Float64}
    xbar::Float64
    ybar::Float64
    dx::Vector{Float64}      # x - xbar
    dy::Vector{Float64}      # y - ybar
    dxdy::Vector{Float64}    # (x - xbar)(y - ybar)
    dx2::Vector{Float64}     # (x - xbar)^2
    sxy::Float64             # sum of dxdy
    sxx::Float64             # sum of dx2
    b::Float64               # slope
    a::Float64               # intercept
    yhat::Vector{Float64}    # predicted y
    resid::Vector{Float64}   # y - yhat
    sse::Float64
    sst::Float64
    r::Float64
    r2::Float64
    se::Float64              # std. error of estimate (n-2), like STEYX
    mae::Float64
    rmse::Float64
end

function slr(xs::AbstractVector{<:Real}, ys::AbstractVector{<:Real})
    n = length(xs)
    n == length(ys) || throw(ArgumentError("X and Y must have the same number of values"))
    n >= 2 || throw(ArgumentError("At least 2 data points are required"))

    x = Float64.(xs)
    y = Float64.(ys)

    xbar = sum(x) / n
    ybar = sum(y) / n

    dx   = x .- xbar
    dy   = y .- ybar
    dxdy = dx .* dy
    dx2  = dx .^ 2

    sxy = sum(dxdy)
    sxx = sum(dx2)
    sxx == 0 && throw(ArgumentError("All X values are identical; slope is undefined"))

    b = sxy / sxx
    a = ybar - b * xbar

    yhat  = a .+ b .* x
    resid = y .- yhat
    sse   = sum(resid .^ 2)
    sst   = sum(dy .^ 2)

    r  = sxy / sqrt(sxx * sst)   # NaN when all Y identical (Excel gives #DIV/0!)
    r2 = r^2
    se = n > 2 ? sqrt(sse / (n - 2)) : NaN

    mae  = sum(abs.(resid)) / n
    rmse = sqrt(sse / n)

    return SLRResult(n, x, y, xbar, ybar, dx, dy, dxdy, dx2, sxy, sxx,
                     b, a, yhat, resid, sse, sst, r, r2, se, mae, rmse)
end

end # module
