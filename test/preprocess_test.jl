using Test
using CSV
using XLSX

include(joinpath(@__DIR__, "..", "src", "regression.jl"))
include(joinpath(@__DIR__, "..", "src", "importer.jl"))
include(joinpath(@__DIR__, "..", "src", "preprocess.jl"))

using .Regression
using .Preprocessing

@testset "Preprocess: parse_cell" begin
    # Numbers
    @test parse_cell(42) == (42.0, false)
    @test parse_cell(3.14) == (3.14, false)
    @test parse_cell("123.45") == (123.45, false)
    @test parse_cell("  7.8  ") == (7.8, false)
    # Decimal commas
    @test parse_cell("3,5") == (3.5, false)
    @test parse_cell("-12,75") == (-12.75, false)
    # Missing tokens
    for token in ["", "?", "na", "N/A", "nan", "null", "none", "-", "  ?  "]
        val, inv = parse_cell(token)
        @test ismissing(val)
        @test inv == false
    end
    @test isequal(parse_cell(missing), (missing, false))
    @test isequal(parse_cell(nothing), (missing, false))
    # Invalid entries
    for invalid in ["abc", "not_a_number", "12.3.4", Inf, -Inf, NaN]
        val, inv = parse_cell(invalid)
        @test ismissing(val)
        @test inv == true
    end
end

@testset "Preprocess: mean_of and quantile_inc" begin
    # mean_of
    @test mean_of([1.0, 2.0, 3.0, 4.0, 5.0]) ≈ 3.0
    @test mean_of([2.0, 4.0, 5.0, 4.0, 6.0]) ≈ 4.2
    @test_throws ArgumentError mean_of(Float64[])

    # Excel QUARTILE.INC verification
    # Excel QUARTILE.INC({1,2,4,7,8,9,10,12}, 1) = 3.5, QUARTILE.INC(..., 3) = 9.25
    v = [1.0, 2.0, 4.0, 7.0, 8.0, 9.0, 10.0, 12.0]
    @test quantile_inc(v, 0.0) ≈ 1.0
    @test quantile_inc(v, 0.25) ≈ 3.5
    @test quantile_inc(v, 0.50) ≈ 7.5
    @test quantile_inc(v, 0.75) ≈ 9.25
    @test quantile_inc(v, 1.0) ≈ 12.0

    # Clean sample quartiles: {1, 2, 3, 4, 5}
    # Q1 = 2.0, Q3 = 4.0, IQR = 2.0
    s5 = [1.0, 2.0, 3.0, 4.0, 5.0]
    @test quantile_inc(s5, 0.25) ≈ 2.0
    @test quantile_inc(s5, 0.75) ≈ 4.0
    @test isempty(iqr_outliers(s5))

    # Outlier detection
    with_outlier = [1.0, 2.0, 2.0, 3.0, 2.0, 20.0]
    outs = iqr_outliers(with_outlier)
    @test outs == [6]
end

@testset "Preprocess: Dirty sample (Section 12 verification)" begin
    # Read dirty_sample.csv
    dirty_path = joinpath(@__DIR__, "..", "examples", "dirty_sample.csv")
    names, cols = _csv_columns(read(dirty_path, String); first_row_header = true)
    @test names == ["X", "Y"]

    raw_x = cols[1]
    raw_y = cols[2]
    @test length(raw_x) == 8
    @test length(raw_y) == 8

    clean_x, clean_y, rep = preprocess(raw_x, raw_y)

    @test rep.rows_before == 8
    @test rep.rows_after == 7
    @test rep.duplicates_removed == 1
    @test rep.invalid_entries == 1
    @test rep.missing_x == 0
    @test rep.missing_y == 2
    @test rep.y_mean ≈ 4.2
    @test rep.imputed_x == 0
    @test rep.imputed_y == 2
    @test rep.all_passed == true
    @test all(c -> c.passed, rep.validation)

    # Imputed cells should be in rows corresponding to orig row 6 and row 8
    # Cleaned X: [1.0, 2.0, 3.0, 4.0, 5.0, 3.0, 6.0]
    # Cleaned Y: [2.0, 4.0, 5.0, 4.0, 6.0, 4.2, 4.2]
    @test clean_x ≈ [1.0, 2.0, 3.0, 4.0, 5.0, 3.0, 6.0]
    @test clean_y ≈ [2.0, 4.0, 5.0, 4.0, 6.0, 4.2, 4.2]
    @test (6, :y) in rep.imputed_cells
    @test (7, :y) in rep.imputed_cells
end

@testset "Preprocess: Regression guard on clean sample" begin
    # X = 1, 2, 3, 4, 5 and Y = 2, 4, 5, 4, 6
    clean_path = joinpath(@__DIR__, "..", "examples", "sample.csv")
    names, cols = _csv_columns(read(clean_path, String); first_row_header = true)
    clean_x, clean_y, rep = preprocess(cols[1], cols[2])

    @test rep.rows_before == 5
    @test rep.rows_after == 5
    @test rep.duplicates_removed == 0
    @test rep.invalid_entries == 0
    @test rep.imputed_x == 0
    @test rep.imputed_y == 0
    @test rep.all_passed == true
    @test clean_x ≈ [1.0, 2.0, 3.0, 4.0, 5.0]
    @test clean_y ≈ [2.0, 4.0, 5.0, 4.0, 6.0]

    res = Regression.slr(clean_x, clean_y)
    @test round(res.b, digits = 4) ≈ 0.8
    @test round(res.a, digits = 4) ≈ 1.8
    @test round(res.r, digits = 4) ≈ 0.8528
    @test round(res.r2, digits = 4) ≈ 0.7273
end

@testset "Preprocess: :drop mode vs :mean mode" begin
    raw_x = ["1", "2", "3", "4", "5", "3", "2", "6"]
    raw_y = ["2", "4", "5", "4", "6", "", "4", "abc"]

    # In :drop mode, rows with missing Y (row 6 and row 8) are dropped, and duplicate row 7 is dropped
    clean_x, clean_y, rep = preprocess(raw_x, raw_y; missing_strategy = :drop)
    @test rep.rows_before == 8
    @test rep.rows_after == 5
    @test clean_x ≈ [1.0, 2.0, 3.0, 4.0, 5.0]
    @test clean_y ≈ [2.0, 4.0, 5.0, 4.0, 6.0]
    @test rep.imputed_x == 0
    @test rep.imputed_y == 0
    @test rep.all_passed == true
end

@testset "Preprocess: Transforms" begin
    x = [1.0, 2.0, 3.0, 4.0, 5.0]
    y = [2.0, 4.0, 5.0, 4.0, 6.0]

    # Normalize: (v - min) / (max - min)
    cx, cy, rep = preprocess(x, y; transform = :normalize)
    @test minimum(cx) ≈ 0.0 && maximum(cx) ≈ 1.0
    @test minimum(cy) ≈ 0.0 && maximum(cy) ≈ 1.0
    res_norm = Regression.slr(cx, cy)
    # Correlation and R2 should remain identical
    @test round(res_norm.r, digits = 4) ≈ 0.8528
    @test round(res_norm.r2, digits = 4) ≈ 0.7273

    # Standardize: (v - mean) / sd
    cx, cy, rep = preprocess(x, y; transform = :standardize)
    @test abs(mean_of(cx)) < 1e-12
    @test abs(mean_of(cy)) < 1e-12
    res_std = Regression.slr(cx, cy)
    @test round(res_std.r, digits = 4) ≈ 0.8528
    @test round(res_std.r2, digits = 4) ≈ 0.7273

    # Log: ln(v)
    cx, cy, rep = preprocess(x, y; transform = :log)
    @test cx ≈ log.([1.0, 2.0, 3.0, 4.0, 5.0])
    @test cy ≈ log.([2.0, 4.0, 5.0, 4.0, 6.0])

    # Log error if value <= 0
    @test_throws ArgumentError preprocess([0.0, 1.0, 2.0], [1.0, 2.0, 3.0]; transform = :log)
    @test_throws ArgumentError preprocess([1.0, 2.0, 3.0], [-1.0, 2.0, 3.0]; transform = :log)
end

@testset "Preprocess: Edge cases from Section 9" begin
    # 1. All values in a column missing
    all_missing = ["?", "NA", "null", ""]
    good_y = ["1", "2", "3", "4"]
    @test_throws ArgumentError preprocess(all_missing, good_y)
    @test_throws ArgumentError preprocess(good_y, all_missing)

    # 2. Both X and Y blank dropped
    both_blank_x = ["1", "", "2", "3"]
    both_blank_y = ["10", "", "20", "30"]
    cx, cy, rep = preprocess(both_blank_x, both_blank_y)
    @test rep.rows_before == 4
    @test rep.rows_after == 3
    @test cx ≈ [1.0, 2.0, 3.0]
    @test cy ≈ [10.0, 20.0, 30.0]

    # 3. Fewer than 2 rows after cleaning
    one_row_x = ["1"]
    one_row_y = ["2"]
    cx, cy, rep = preprocess(one_row_x, one_row_y)
    @test rep.all_passed == false
    @test any(c -> c.name == "At least 2 rows" && !c.passed, rep.validation)

    # 4. X becomes constant after cleaning
    const_x = ["3", "3", "3"]
    var_y = ["1", "2", "3"]
    cx, cy, rep = preprocess(const_x, var_y; remove_duplicates = false)
    @test rep.all_passed == false
    @test any(c -> c.name == "X is not constant" && !c.passed, rep.validation)
end

@testset "Preprocess: Rolling / Sequential imputation — impute_rolling_sequential" begin
    # Interior missing: linear interpolation between two valid neighbors
    # e.g. [1, missing, missing, 4] → indices 2 and 3 interpolated:
    #   index 2: 1 + (2-1)/(4-1) * (4-1) = 1 + 1/3*3 = 2.0
    #   index 3: 1 + (3-1)/(4-1) * (4-1) = 1 + 2/3*3 = 3.0
    v1 = Union{Float64,Missing}[1.0, missing, missing, 4.0]
    r1 = impute_rolling_sequential(v1)
    @test r1 ≈ [1.0, 2.0, 3.0, 4.0]

    # Single interior gap: average of neighbors
    # [2, missing, 4] → index 2: 2 + (2-1)/(3-1)*(4-2) = 2 + 1.0 = 3.0
    v2 = Union{Float64,Missing}[2.0, missing, 4.0]
    r2 = impute_rolling_sequential(v2)
    @test r2 ≈ [2.0, 3.0, 4.0]

    # Leading edge: backward-fill from first valid value
    v3 = Union{Float64,Missing}[missing, missing, 3.0, 6.0]
    r3 = impute_rolling_sequential(v3)
    @test r3[1] ≈ 3.0   # backward-fill
    @test r3[2] ≈ 3.0   # backward-fill
    @test r3[3] ≈ 3.0
    @test r3[4] ≈ 6.0

    # Trailing edge: forward-fill from last valid value
    v4 = Union{Float64,Missing}[1.0, 2.0, missing, missing]
    r4 = impute_rolling_sequential(v4)
    @test r4[1] ≈ 1.0
    @test r4[2] ≈ 2.0
    @test r4[3] ≈ 2.0   # forward-fill
    @test r4[4] ≈ 2.0   # forward-fill

    # Multi-gap: two separate missing runs each interpolated independently
    v5 = Union{Float64,Missing}[0.0, missing, 2.0, missing, missing, 5.0]
    r5 = impute_rolling_sequential(v5)
    @test r5[1] ≈ 0.0
    @test r5[2] ≈ 1.0   # interpolated between 0 and 2
    @test r5[3] ≈ 2.0
    @test r5[4] ≈ 3.0   # interpolated: 2 + 1/3*(5-2) = 3.0
    @test r5[5] ≈ 4.0   # interpolated: 2 + 2/3*(5-2) = 4.0
    @test r5[6] ≈ 5.0

    # No missing values: passthrough unchanged
    v6 = Union{Float64,Missing}[10.0, 20.0, 30.0]
    @test impute_rolling_sequential(v6) ≈ [10.0, 20.0, 30.0]

    # Single valid element: all missing except one → all filled to that value
    v7 = Union{Float64,Missing}[missing, 7.0, missing]
    r7 = impute_rolling_sequential(v7)
    @test r7 ≈ [7.0, 7.0, 7.0]

    # Empty input: returns empty
    @test impute_rolling_sequential(Union{Float64,Missing}[]) == Float64[]

    # All missing: throws ArgumentError
    @test_throws ArgumentError impute_rolling_sequential(Union{Float64,Missing}[missing, missing])
end

@testset "Preprocess: Rolling strategy via preprocess() — end-to-end" begin
    # Data with two interior missing Y values: [_, 3, _, _, 6]
    # After parse: Y = [missing, 3.0, missing, missing, 6.0]
    # Rolling interpolation for the gap at index 3 and 4 (between 3 and 6):
    #   index 3: 3 + (3-2)/(5-2) * (6-3) = 3 + 1/3*3 = 4.0
    #   index 4: 3 + (4-2)/(5-2) * (6-3) = 3 + 2/3*3 = 5.0
    # Leading edge at index 1: backward-fill from index 2 → 3.0
    raw_x = ["1", "2", "3", "4", "5"]
    raw_y = ["", "3", "", "", "6"]

    cx, cy, rep = preprocess(raw_x, raw_y; missing_strategy=:rolling)

    @test length(cx) == 5
    @test cy[1] ≈ 3.0   # leading backward-fill
    @test cy[2] ≈ 3.0
    @test cy[3] ≈ 4.0   # interior interpolation
    @test cy[4] ≈ 5.0   # interior interpolation
    @test cy[5] ≈ 6.0
    @test rep.missing_strategy == :rolling

    # The alias :sequential should produce identical results
    cx2, cy2, rep2 = preprocess(raw_x, raw_y; missing_strategy=:sequential)
    @test cy2 ≈ cy
    @test rep2.missing_strategy == :rolling  # normalized to :rolling

    # Compare rolling vs global: rolling gives different imputed values
    cx3, cy3, _ = preprocess(raw_x, raw_y; missing_strategy=:global)
    # global mean of known Y values [3.0, 6.0] = 4.5; so cy3[1]=4.5, cy3[3]=4.5, cy3[4]=4.5
    @test cy3[1] ≈ 4.5
    @test cy3[3] ≈ 4.5
    @test cy3[4] ≈ 4.5
    # Rolling values differ from global mean
    @test !(cy[1] ≈ cy3[1])
end

@testset "Preprocess: CSV and XLSX parity" begin
    csv_path = joinpath(@__DIR__, "..", "examples", "sample.csv")
    xlsx_path = joinpath(@__DIR__, "..", "examples", "sample.xlsx")

    names_csv, cols_csv = _csv_columns(read(csv_path, String); first_row_header = true)
    names_xlsx, cols_xlsx, _, _ = read_upload_columns_with_sheet(read(xlsx_path), "sample.xlsx"; first_row_header = true)

    cx_csv, cy_csv, rep_csv = preprocess(cols_csv[1], cols_csv[2])
    cx_xlsx, cy_xlsx, rep_xlsx = preprocess(cols_xlsx[1], cols_xlsx[2])

    @test cx_csv == cx_xlsx
    @test cy_csv == cy_xlsx
    @test rep_csv.rows_after == rep_xlsx.rows_after
    @test rep_csv.y_mean == rep_xlsx.y_mean
end

@testset "Preprocess: HTTP routes end-to-end (/upload, /select, /preprocess, /export_clean)" begin
    include(joinpath(@__DIR__, "..", "src", "main.jl"))

    # 1. Upload dirty_sample.csv
    dirty_bytes = read(joinpath(@__DIR__, "..", "examples", "dirty_sample.csv"))
    boundary = "----TestBoundaryPreprocess123"
    body_parts = IOBuffer()
    write(body_parts, "--", boundary, "\r\n")
    write(body_parts, "Content-Disposition: form-data; name=\"upload_submitted\"\r\n\r\n1\r\n")
    write(body_parts, "--", boundary, "\r\n")
    write(body_parts, "Content-Disposition: form-data; name=\"first_row_header\"\r\n\r\n1\r\n")
    write(body_parts, "--", boundary, "\r\n")
    write(body_parts, "Content-Disposition: form-data; name=\"file\"; filename=\"dirty_sample.csv\"\r\n")
    write(body_parts, "Content-Type: text/csv\r\n\r\n")
    write(body_parts, dirty_bytes)
    write(body_parts, "\r\n--", boundary, "--\r\n")

    req_upload = HTTP.Request("POST", "/upload", ["Content-Type" => "multipart/form-data; boundary=" * boundary], take!(body_parts))
    resp_upload = handler(req_upload)
    @test resp_upload.status == 200
    upload_html = String(resp_upload.body)
    @test occursin("Issues Found", upload_html)
    @test occursin("Actions Applied", upload_html)
    @test occursin("Before / After Summary", upload_html)
    @test occursin("Cleaned Data Preview", upload_html)
    @test occursin("Validation Checks", upload_html)
    @test occursin("PASS", upload_html)

    m = match(r"name=\"token\" value=\"(tok_[^\"]+)\"", upload_html)
    @test m !== nothing
    token = m.captures[1]

    # 2. Re-run preprocessing with :drop mode via POST /preprocess
    req_prep = HTTP.Request("POST", "/preprocess", ["Content-Type" => "application/x-www-form-urlencoded"],
                            "token=$token&x_col=1&y_col=2&missing_strategy=drop&remove_duplicates=1&outliers_strategy=flag&transform=none")
    resp_prep = handler(req_prep)
    @test resp_prep.status == 200
    prep_html = String(resp_prep.body)
    @test occursin("Cleaned data: <span class=\"status-num\">5</span> rows", prep_html)

    # 3. Apply default mean-imputed clean data to grid via POST /select
    req_select = HTTP.Request("POST", "/select", ["Content-Type" => "application/x-www-form-urlencoded"],
                              "token=$token&x_col=1&y_col=2&missing_strategy=mean&remove_duplicates=1&action=apply")
    resp_select = handler(req_select)
    @test resp_select.status == 200
    select_html = String(resp_select.body)
    @test occursin("Loaded <span class=\"status-num\">7</span> rows &middot; press Calculate", select_html)
    @test occursin("id=\"tab-data\" value=\"data\" checked", select_html)
    @test occursin("value=\"4.2\"", select_html) # imputed value appears in grid!

    # 4. Export clean CSV via POST /export_clean
    req_export_clean = HTTP.Request("POST", "/export_clean", ["Content-Type" => "application/x-www-form-urlencoded"],
                                    "token=$token")
    resp_export_clean = handler(req_export_clean)
    @test resp_export_clean.status == 200
    @test HTTP.header(resp_export_clean, "Content-Type") == "text/csv; charset=utf-8"
    @test occursin("clean_data.csv", HTTP.header(resp_export_clean, "Content-Disposition"))
    csv_str = String(resp_export_clean.body)
    @test startswith(csv_str, "X,Y\r\n")
    lines = split(strip(csv_str), "\r\n")
    @test length(lines) == 8 # 1 header + 7 rows
end

@testset "Preprocess: Rolling — HTTP badge text via POST /preprocess" begin
    # main.jl was already included in the previous testset; handler is already available.
    dirty_path = joinpath(@__DIR__, "..", "examples", "dirty_sample.csv")
    body_bytes  = read(dirty_path)
    boundary    = "testboundary_rolling"
    multipart   = "--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dirty_sample.csv\"\r\nContent-Type: text/csv\r\n\r\n" *
                  String(body_bytes) * "\r\n--$boundary--\r\n"
    upload_req  = HTTP.Request("POST", "/upload",
                               ["Content-Type" => "multipart/form-data; boundary=$boundary"],
                               multipart)
    upload_resp = handler(upload_req)
    @test upload_resp.status == 200
    m = match(r"name=\"token\" value=\"(tok_[^\"]+)\"", String(upload_resp.body))
    @test m !== nothing
    token = m.captures[1]

    # Re-run preprocessing with rolling strategy
    req = HTTP.Request("POST", "/preprocess",
                       ["Content-Type" => "application/x-www-form-urlencoded"],
                       "token=$token&x_col=1&y_col=2&missing_strategy=rolling&remove_duplicates=1&outliers_strategy=flag&transform=none")
    resp = handler(req)
    @test resp.status == 200
    html = String(resp.body)

    # The cleaned-data preview must contain rolling badge text
    @test occursin("IMPUTED (Rolling)", html)
    # Must NOT still say "(Global)" for these imputed cells
    @test !occursin("IMPUTED (Global)", html)
end
