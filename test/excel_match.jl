using Test
include(joinpath(@__DIR__, "..", "src", "regression.jl"))
using .Regression

# Sample data from the handwritten table.
# In Excel/Sheets (A2:A6 = X, B2:B6 = Y) the same results come from:
#   =SLOPE(B2:B6,A2:A6)  =INTERCEPT(B2:B6,A2:A6)  =CORREL(B2:B6,A2:A6)
#   =RSQ(B2:B6,A2:A6)    =STEYX(B2:B6,A2:A6)
@testset "sample table (1..5 / 2,4,5,4,6)" begin
    r = slr([1, 2, 3, 4, 5], [2, 4, 5, 4, 6])

    @test r.xbar ≈ 3.0
    @test r.ybar ≈ 4.2
    @test r.dx ≈ [-2, -1, 0, 1, 2]
    @test r.dy ≈ [-2.2, -0.2, 0.8, -0.2, 1.8]
    @test r.sxy ≈ 8.0
    @test r.sxx ≈ 10.0
    @test r.b ≈ 0.8
    @test r.a ≈ 1.8
    @test r.yhat ≈ [2.6, 3.4, 4.2, 5.0, 5.8]
    @test r.r ≈ 0.8528028654224417
    @test r.r2 ≈ 0.7272727272727272
    @test r.se ≈ 0.8944271909999157
    @test r.mae ≈ 0.64
    @test r.rmse ≈ 0.6928203230275508
end

@testset "edge cases" begin
    @test_throws ArgumentError slr([1], [2])
    @test_throws ArgumentError slr([1, 2], [1, 2, 3])
    @test_throws ArgumentError slr([3, 3, 3], [1, 2, 3])
end
