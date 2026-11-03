using Test
using HTTP

include(joinpath(@__DIR__, "..", "src", "regression.jl"))
include(joinpath(@__DIR__, "..", "src", "importer.jl"))
include(joinpath(@__DIR__, "..", "src", "render.jl"))
include(joinpath(@__DIR__, "..", "src", "main.jl"))

@testset "Phase 3: Importer CSV & XLSX unit tests" begin
    # 1. CSV with header
    csv_data = "feat_a,feat_b\n10,20\n30,40\n"
    names, cols = read_upload_columns(csv_data, "test.csv"; first_row_header = true)
    @test names == ["feat_a", "feat_b"]
    @test cols == [["10", "30"], ["20", "40"]]

    # 2. CSV without header
    names_no_hdr, cols_no_hdr = read_upload_columns(csv_data, "test.csv"; first_row_header = false)
    @test names_no_hdr == ["Column 1", "Column 2"]
    @test cols_no_hdr == [["feat_a", "10", "30"], ["feat_b", "20", "40"]]

    # 3. XLSX with and without header using examples/sample.xlsx
    xlsx_bytes = read(joinpath(@__DIR__, "..", "examples", "sample.xlsx"))
    xnames, xcols = read_upload_columns(xlsx_bytes, "sample.xlsx"; first_row_header = true)
    @test xnames == ["x", "y"]
    @test count_rows(xcols) == 5
    @test xcols[1] == ["1.0", "2.0", "3.0", "4.0", "5.0"]
    @test xcols[2] == ["2.0", "4.0", "5.0", "4.0", "6.0"]

    xnames_no_hdr, xcols_no_hdr = read_upload_columns(xlsx_bytes, "sample.xlsx"; first_row_header = false)
    @test xnames_no_hdr == ["Column 1", "Column 2"]
    @test count_rows(xcols_no_hdr) == 6
    @test xcols_no_hdr[1] == ["x", "1.0", "2.0", "3.0", "4.0", "5.0"]

    # 4. Skipping empty/missing cells and counting them
    cols_with_empty = [["1", "", "3", "4"], ["2", "20", "", "40"]]
    cleaned, skipped = extract_selected_columns(cols_with_empty, ["A", "B"], 1, 2, true)
    @test skipped == 2
    @test cleaned == [("1", "2"), ("4", "40")]

    # 5. Non-numeric validation error naming exact row and column
    cols_bad = [["1", "foo", "3"], ["2", "20", "30"]]
    err = try
        extract_selected_columns(cols_bad, ["ColA", "ColB"], 1, 2, true)
        nothing
    catch e
        e
    end
    @test err isa NonNumericInputError
    @test sprint(showerror, err) == "Row 3: non-numeric value 'foo' in column 'ColA'"

    # Non-numeric with first_row_header=false
    err2 = try
        extract_selected_columns(cols_bad, ["Column 1", "Column 2"], 1, 2, false)
        nothing
    catch e
        e
    end
    @test err2 isa NonNumericInputError
    @test sprint(showerror, err2) == "Row 2: non-numeric value 'foo' in column 'Column 1'"
end

@testset "Phase 3: 10,000-row cap and 10 MB payload cap" begin
    # 10,000-row cap rejection
    @test_throws ErrorException check_row_cap(10_001)
    @test check_row_cap(10_000) === nothing

    # Generate 10,001-row CSV string
    big_csv_buf = IOBuffer()
    println(big_csv_buf, "x,y")
    for i in 1:10001
        println(big_csv_buf, "$i,$i")
    end
    big_csv = String(take!(big_csv_buf))
    b_names, b_cols = _csv_columns(big_csv; first_row_header = true)
    @test count_rows(b_cols) == 10001
    @test_throws ErrorException check_row_cap(count_rows(b_cols))

    # 10 MB request body cap rejection (HTTP 413)
    oversized_body = repeat("x=1&", 3_000_000) # 12 MB > 10 MB
    req_oversized = HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded"], Vector{UInt8}(codeunits(oversized_body)))
    resp_oversized = handler(req_oversized)
    @test resp_oversized.status == 413
    @test occursin("Request body too large", String(resp_oversized.body))
end

@testset "Phase 3: Upload store LRU eviction and token expiration" begin
    # Clear UPLOADS and UPLOAD_ORDER for isolation
    lock(UPLOAD_LOCK) do
        empty!(UPLOADS)
        empty!(UPLOAD_ORDER)
    end

    # Store 5 entries (MAX_STORE_ENTRIES = 5)
    tokens = String[]
    for i in 1:5
        t = "tok_$i"
        store_upload(t, ["x", "y"], [["1"], ["2"]], true, 1, 2, Tuple{String,String}[])
        push!(tokens, t)
    end
    @test length(UPLOAD_ORDER) == 5
    @test haskey(UPLOADS, "tok_1")

    # Store 6th entry - verifies fix for delete!(UPLOAD_STORE, old)
    t6 = "tok_6"
    store_upload(t6, ["x", "y"], [["1"], ["2"]], true, 1, 2, Tuple{String,String}[])
    @test length(UPLOAD_ORDER) == 5
    @test !haskey(UPLOADS, "tok_1") # evicted oldest
    @test haskey(UPLOADS, "tok_6")

    # Expired token test
    lock(UPLOAD_LOCK) do
        UPLOADS["tok_expired"] = UploadData(["x", "y"], [["1"], ["2"]], true, time() - 3601, 1, 2, Tuple{String,String}[])
    end
    @test valid_token("tok_expired") === nothing
    @test !haskey(UPLOADS, "tok_expired")

    # Select on expired token produces graceful error
    resp_expired = handler(HTTP.Request("POST", "/select", ["Content-Type" => "application/x-www-form-urlencoded"], "token=tok_nonexistent&x_col=1&y_col=2"))
    @test resp_expired.status == 200
    @test occursin("Your upload session has expired. Please re-upload your file.", String(resp_expired.body))
end

@testset "Phase 3: End-to-end multipart upload, attribute selection, and calculation" begin
    # Clear store
    lock(UPLOAD_LOCK) do
        empty!(UPLOADS)
        empty!(UPLOAD_ORDER)
    end

    # 1. Upload CSV matching the verification dataset (1..5 / 2,4,5,4,6)
    boundary = "----TestBoundary12345"
    csv_content = "X_Val,Y_Val,Other\n1,2,100\n2,4,200\n3,5,300\n4,4,400\n5,6,500\n"
    body = string(
        "--", boundary, "\r\n",
        "Content-Disposition: form-data; name=\"upload_submitted\"\r\n\r\n",
        "1\r\n",
        "--", boundary, "\r\n",
        "Content-Disposition: form-data; name=\"first_row_header\"\r\n\r\n",
        "1\r\n",
        "--", boundary, "\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"dataset.csv\"\r\n",
        "Content-Type: text/csv\r\n\r\n",
        csv_content, "\r\n",
        "--", boundary, "--\r\n"
    )
    req_upload = HTTP.Request("POST", "/upload", ["Content-Type" => "multipart/form-data; boundary=" * boundary], Vector{UInt8}(codeunits(body)))
    resp_upload = handler(req_upload)
    @test resp_upload.status == 200
    upload_html = String(resp_upload.body)
    @test occursin("File uploaded: dataset.csv", upload_html)
    @test occursin("X_Val", upload_html)
    @test occursin("Y_Val", upload_html)
    @test occursin("Other", upload_html)
    @test occursin("id=\"tab-preprocess\" value=\"preprocess\" checked", upload_html)

    # Extract token from HTML
    m = match(r"name=\"token\" value=\"(tok_[^\"]+)\"", upload_html)
    @test m !== nothing
    token = m.captures[1]

    # 2. Show button action on Preprocess tab (change X to col 1, Y to col 2)
    req_show = HTTP.Request("POST", "/rows", ["Content-Type" => "application/x-www-form-urlencoded"], "token=$token&x_col=1&y_col=2&attr_show=2")
    resp_show = handler(req_show)
    @test resp_show.status == 200
    show_html = String(resp_show.body)
    @test occursin("Selected attribute: X = X_Val &middot; Y = Y_Val", show_html)
    @test occursin("id=\"tab-preprocess\" value=\"preprocess\" checked", show_html)

    # 3. Apply to grid (/select)
    req_select = HTTP.Request("POST", "/select", ["Content-Type" => "application/x-www-form-urlencoded"], "token=$token&x_col=1&y_col=2&action=apply")
    resp_select = handler(req_select)
    @test resp_select.status == 200
    select_html = String(resp_select.body)
    @test occursin("Loaded <span class=\"status-num\">5</span> rows &middot; press Calculate", select_html)
    @test occursin("id=\"tab-data\" value=\"data\" checked", select_html)
    @test occursin("value=\"1\"", select_html)
    @test occursin("value=\"2\"", select_html)

    # 4. Calculate regression on applied grid
    req_calc = HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded"], "token=$token&action=calculate")
    resp_calc = handler(req_calc)
    @test resp_calc.status == 200
    calc_html = String(resp_calc.body)
    @test occursin("id=\"tab-result\" value=\"result\" checked", calc_html)
    # Excel-parity verification: b = 0.8, a = 1.8, R² = 0.7273
    @test occursin("b    = 0.8", calc_html)
    @test occursin("a    = 1.8", calc_html)
    @test occursin("R&#x00B2;   = 0.7273", calc_html)
    @test occursin("SE   = 0.8944", calc_html)

    # 5. Verify formula notation fix in calculation panel
    @test occursin("(x &#x2212; x&#x0304;)(y &#x2212; &#x0233;)", calc_html)
    @test occursin("&#x03A3;(x &#x2212; x&#x0304;)(y &#x2212; &#x0233;)", calc_html)
    @test !occursin("(&#x2212; &#x0233;)", calc_html)

    # 6. Grid edit precedence test: edit row 1 on Data tab to X=10, Y=20 and calculate
    req_edit = HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded"],
        "token=$token&x_1=10&y_1=20&x_2=2&y_2=4&x_3=3&y_3=5&x_4=4&y_4=4&x_5=5&y_5=6")
    resp_edit = handler(req_edit)
    @test resp_edit.status == 200
    edit_html = String(resp_edit.body)
    # The calculation used x_1=10 instead of original x_1=1
    @test !occursin("b    = 0.8\n", edit_html) # Slope changed because row 1 was edited in grid
end

@testset "Phase 3: Multipart XLSX upload and select" begin
    # Clear store
    lock(UPLOAD_LOCK) do
        empty!(UPLOADS)
        empty!(UPLOAD_ORDER)
    end

    xlsx_bytes = read(joinpath(@__DIR__, "..", "examples", "sample.xlsx"))
    boundary = "----XLSXBoundary98765"
    body_parts = IOBuffer()
    write(body_parts, "--", boundary, "\r\n")
    write(body_parts, "Content-Disposition: form-data; name=\"upload_submitted\"\r\n\r\n1\r\n")
    write(body_parts, "--", boundary, "\r\n")
    write(body_parts, "Content-Disposition: form-data; name=\"first_row_header\"\r\n\r\n1\r\n")
    write(body_parts, "--", boundary, "\r\n")
    write(body_parts, "Content-Disposition: form-data; name=\"file\"; filename=\"sample.xlsx\"\r\n")
    write(body_parts, "Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\r\n\r\n")
    write(body_parts, xlsx_bytes)
    write(body_parts, "\r\n--", boundary, "--\r\n")

    req_upload = HTTP.Request("POST", "/upload", ["Content-Type" => "multipart/form-data; boundary=" * boundary], take!(body_parts))
    resp_upload = handler(req_upload)
    @test resp_upload.status == 200
    upload_html = String(resp_upload.body)
    @test occursin("File uploaded: sample.xlsx", upload_html)
    @test occursin("Selected attribute: X = x &middot; Y = y", upload_html)

    m = match(r"name=\"token\" value=\"(tok_[^\"]+)\"", upload_html)
    @test m !== nothing
    token = m.captures[1]

    # Apply XLSX to grid
    req_select = HTTP.Request("POST", "/select", ["Content-Type" => "application/x-www-form-urlencoded"], "token=$token&x_col=1&y_col=2")
    resp_select = handler(req_select)
    @test resp_select.status == 200
    @test occursin("Loaded <span class=\"status-num\">5</span> rows &middot; press Calculate", String(resp_select.body))
end
