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
        UPLOADS["tok_expired"] = UploadData(
            columns = ["x", "y"],
            values = [["1"], ["2"]],
            first_row_header = true,
            timestamp = time() - 3601,
            x_col = 1,
            y_col = 2,
        )
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

    # 4. Calculate regression on applied grid (POSTs carry the submitted rows only)
    grid_fields = "x_1=1&y_1=2&x_2=2&y_2=4&x_3=3&y_3=5&x_4=4&y_4=4&x_5=5&y_5=6"
    req_calc = HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded"], "token=$token&action=calculate&" * grid_fields)
    resp_calc = handler(req_calc)
    @test resp_calc.status == 200
    calc_html = String(resp_calc.body)
    @test occursin("id=\"tab-result\" value=\"result\" checked", calc_html)
    # Excel-parity verification: b = 0.8, a = 1.8, R² = 0.7273
    @test occursin("class=\"summary\"", calc_html)
    @test occursin("&#x0177; = 1.8 + 0.8x", calc_html)
    @test occursin("0.8528", calc_html)   # r
    @test occursin("0.7273", calc_html)   # R²
    @test occursin("0.8944", calc_html)   # standard error
    @test occursin("61.5385%", calc_html) # RAE
    @test occursin("52.2233%", calc_html) # RRSE

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
    @test !occursin("&#x0177; = 1.8 + 0.8x", edit_html) # Slope changed because row 1 was edited in grid
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

@testset "Fix pack A: UploadData keyword constructor" begin
    # Tests must not depend on the field count or field order.
    u = UploadData(columns = ["x", "y"], values = [["1"], ["2"]], x_col = 1, y_col = 2)
    @test u.columns == ["x", "y"]
    @test u.values == [["1"], ["2"]]
    @test u.x_col == 1
    @test u.y_col == 2
    @test u.first_row_header
    @test u.filename == ""
    @test u.raw_bytes == UInt8[]
    @test u.sheet_names == String[]
    @test u.selected_attr == 1
    @test u.skipped_count == 0
    @test time() - u.timestamp < 5

    expired = UploadData(timestamp = time() - 3601)
    @test time() - expired.timestamp >= 3600
end

@testset "Fix pack A: status text and names are HTML-escaped" begin
    lock(UPLOAD_LOCK) do
        empty!(UPLOADS)
        empty!(UPLOAD_ORDER)
    end

    boundary = "----EscapeBoundary12345"
    csv_content = "<script>alert(1)</script>,y\n1,2\n2,4\n"
    body = string(
        "--", boundary, "\r\n",
        "Content-Disposition: form-data; name=\"upload_submitted\"\r\n\r\n",
        "1\r\n",
        "--", boundary, "\r\n",
        "Content-Disposition: form-data; name=\"first_row_header\"\r\n\r\n",
        "1\r\n",
        "--", boundary, "\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"<b>evil.csv\"\r\n",
        "Content-Type: text/csv\r\n\r\n",
        csv_content, "\r\n",
        "--", boundary, "--\r\n"
    )
    resp = handler(HTTP.Request("POST", "/upload", ["Content-Type" => "multipart/form-data; boundary=" * boundary], Vector{UInt8}(codeunits(body))))
    @test resp.status == 200
    html = String(resp.body)

    # Nothing user-supplied may reach the page as raw markup, anywhere.
    @test !occursin("<script", html)
    @test !occursin("<b>", html)
    @test occursin("&lt;script&gt;alert(1)&lt;/script&gt;", html)
    @test occursin("&lt;b&gt;evil.csv", html)

    # The status bar built from column names is escaped too (Show button).
    m = match(r"name=\"token\" value=\"(tok_[^\"]+)\"", html)
    @test m !== nothing
    token = m.captures[1]
    resp_show = handler(HTTP.Request("POST", "/rows", ["Content-Type" => "application/x-www-form-urlencoded"], "token=$token&x_col=1&y_col=2&attr_show=1"))
    show_html = String(resp_show.body)
    @test resp_show.status == 200
    @test !occursin("<script", show_html)
    @test !occursin("<b>", show_html)
    @test occursin("Selected attribute: X = &lt;script&gt;alert(1)&lt;/script&gt;", show_html)

    # Token echoed back into the grid form is escaped as well.
    resp_token = handler(HTTP.Request("POST", "/rows", ["Content-Type" => "application/x-www-form-urlencoded"], "token=\"><script>alert(2)</script>&x_1=1&y_1=2"))
    token_html = String(resp_token.body)
    @test !occursin("<script", token_html)
    @test occursin("&quot;&gt;&lt;script&gt;", token_html)
end

@testset "Fix pack A: POSTs use exactly the submitted rows" begin
    lock(UPLOAD_LOCK) do
        empty!(UPLOADS)
        empty!(UPLOAD_ORDER)
    end

    # No grid fields at all: never fall back to the sample dataset.
    resp_empty = handler(HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded"], "token=&action=calculate"))
    empty_html = String(resp_empty.body)
    @test resp_empty.status == 200
    @test occursin("At least 2 data points are required", empty_html)
    @test !occursin("class=\"summary\"", empty_html)
    @test !occursin("Instances</th>", empty_html)

    # A live token whose stored rows exist but whose grid rows were not submitted.
    tok = store_upload("tok_rows", ["x", "y"], [["1"], ["2"], ["3"]], true, 1, 2, [("1", "2"), ("2", "4"), ("3", "5")])
    resp_stored = handler(HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded"], "token=$tok&action=calculate"))
    stored_html = String(resp_stored.body)
    @test occursin("At least 2 data points are required", stored_html)
    @test !occursin("class=\"summary\"", stored_html)

    # One usable row is also not enough.
    resp_one = handler(HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded"], "x_1=1&y_1=2"))
    @test occursin("At least 2 data points are required", String(resp_one.body))

    # Exactly the rows submitted are used.
    resp_two = handler(HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded"], "x_1=1&y_1=2&x_2=2&y_2=4"))
    two_html = String(resp_two.body)
    @test occursin("&#x0177; = 0 + 2x", two_html)
    @test occursin("Instances</th><td class=\"num\">2</td>", two_html)

    # Other POSTs no longer embed the sample dataset; GET / still shows it.
    resp_show = handler(HTTP.Request("POST", "/rows", ["Content-Type" => "application/x-www-form-urlencoded"], "action=show"))
    @test !occursin("id=\"x_1\" value=\"1\"", String(resp_show.body))
    @test occursin("id=\"x_1\" value=\"1\"", String(handler(HTTP.Request("GET", "/")).body))
end

@testset "Fix pack A: remove-row keys are validated and deterministic" begin
    five_rows = "x_1=1&y_1=2&x_2=2&y_2=4&x_3=3&y_3=5&x_4=4&y_4=4&x_5=5&y_5=6"

    # Two valid rm_ keys: only the smallest index (row 3) is removed.
    resp_two = handler(HTTP.Request("POST", "/rows", ["Content-Type" => "application/x-www-form-urlencoded"], five_rows * "&rm_3=3&rm_4=4"))
    two_html = String(resp_two.body)
    @test occursin("id=\"x_3\" value=\"4\"", two_html)   # old row 4 shifted up
    @test occursin("id=\"x_4\" value=\"5\"", two_html)
    @test !occursin("name=\"x_5\"", two_html)
    @test occursin("4</span> &middot; press Calculate", two_html)

    # Out-of-range index is ignored: all five rows survive.
    resp_bad = handler(HTTP.Request("POST", "/rows", ["Content-Type" => "application/x-www-form-urlencoded"], five_rows * "&rm_99=99"))
    bad_html = String(resp_bad.body)
    @test occursin("name=\"x_5\"", bad_html)
    @test occursin("id=\"x_1\" value=\"1\"", bad_html)
    @test occursin("id=\"x_5\" value=\"5\"", bad_html)

    # Non-integer index is ignored as well.
    resp_txt = handler(HTTP.Request("POST", "/rows", ["Content-Type" => "application/x-www-form-urlencoded"], five_rows * "&rm_abc=abc"))
    @test occursin("name=\"x_5\"", String(resp_txt.body))
end

@testset "Fix pack A: fmt normalizes negative zero" begin
    @test fmt(-8.88e-16) == "0"
    @test fmt(-4.44e-16) == "0"
    @test fmt(-0.0) == "0"
    @test fmt(0.0) == "0"
    @test fmt(-1.23456) == "-1.2346"
    @test fmt(1.23456) == "1.2346"

    # The rendered totals row must not show "-0".
    r = Regression.slr([1, 2, 3, 4, 5], [2, 4, 5, 4, 6])
    calc_html = render_calculation_panel(r)
    @test !occursin(">-0<", calc_html)
end

@testset "Fix pack B: size caps reject before buffering" begin
    # Streaming cap: one byte over the cap, with no Content-Length header at all.
    over = Vector{UInt8}(codeunits(repeat("a", MAX_BODY_BYTES + 1)))
    req = HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded"], over)
    @test content_length(req) === nothing
    resp = handler(req)
    @test resp.status == 413
    @test occursin("Request body too large", String(resp.body))

    # An oversized Content-Length is rejected before the (tiny) body is read.
    req_declared = HTTP.Request("POST", "/upload", ["Content-Type" => "multipart/form-data; boundary=x", "Content-Length" => string(MAX_BODY_BYTES + 1)], Vector{UInt8}(codeunits("x")))
    @test content_length(req_declared) == MAX_BODY_BYTES + 1
    resp_declared = handler(req_declared)
    @test resp_declared.status == 413
    @test occursin("Request body too large", String(resp_declared.body))

    # A false small Content-Length cannot smuggle an oversized body past the cap.
    req_liar_upload = HTTP.Request("POST", "/upload", ["Content-Type" => "multipart/form-data; boundary=x", "Content-Length" => "10"], over)
    @test content_length(req_liar_upload) == 10
    @test handler(req_liar_upload).status == 413

    req_liar_form = HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded", "Content-Length" => "10"], over)
    @test content_length(req_liar_form) == 10
    @test handler(req_liar_form).status == 413

    # Exactly at the cap is allowed (it then reads normally).
    at_cap = Vector{UInt8}(codeunits(repeat("a", MAX_BODY_BYTES)))
    @test handler(HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded"], at_cap)).status == 200
end

@testset "Fix pack B: one store write path" begin
    lock(UPLOAD_LOCK) do
        empty!(UPLOADS)
        empty!(UPLOAD_ORDER)
    end

    # Seven uploads: only the five newest survive, in insertion order.
    for i in 1:7
        store_upload("tok_$i", ["x", "y"], [["1"], ["2"]], true, 1, 2, Tuple{String,String}[])
    end
    @test length(UPLOADS) == MAX_STORE_ENTRIES
    @test length(UPLOAD_ORDER) == MAX_STORE_ENTRIES
    @test sort(collect(keys(UPLOADS))) == ["tok_3", "tok_4", "tok_5", "tok_6", "tok_7"]
    @test UPLOAD_ORDER == ["tok_3", "tok_4", "tok_5", "tok_6", "tok_7"]

    # Updating an existing token keeps a single entry and moves it to newest.
    update_upload("tok_3", UPLOADS["tok_3"]; selected_attr = 2)
    @test length(UPLOADS) == MAX_STORE_ENTRIES
    @test length(UPLOAD_ORDER) == MAX_STORE_ENTRIES
    @test length(unique(UPLOAD_ORDER)) == MAX_STORE_ENTRIES
    @test last(UPLOAD_ORDER) == "tok_3"
    @test UPLOADS["tok_3"].selected_attr == 2

    # Expiring a token removes it from both the store and the order list.
    expired = store_upload("tok_expired", ["x", "y"], [["1"], ["2"]], true, 1, 2, Tuple{String,String}[]; timestamp = time() - TOKEN_TTL_SECONDS - 1)
    @test haskey(UPLOADS, expired)
    @test expired in UPLOAD_ORDER
    @test valid_token(expired) === nothing
    @test !haskey(UPLOADS, expired)
    @test !(expired in UPLOAD_ORDER)

    # A forged skipped field cannot change the status text.
    lock(UPLOAD_LOCK) do
        empty!(UPLOADS)
        empty!(UPLOAD_ORDER)
    end
    tok = store_upload("tok_skip", ["x", "y"], [["1"], ["2"]], true, 1, 2, Tuple{String,String}[]; skipped_count = 1)

    resp_add = handler(HTTP.Request("POST", "/rows", ["Content-Type" => "application/x-www-form-urlencoded"], "token=$tok&x_1=1&y_1=2&x_2=2&y_2=4&skipped=999&action=add"))
    add_html = String(resp_add.body)
    @test occursin("1</span> skipped for missing values", add_html)
    @test !occursin("999", add_html)
    @test UPLOADS[tok].skipped_count == 1

    resp_calc = handler(HTTP.Request("POST", "/calculate", ["Content-Type" => "application/x-www-form-urlencoded"], "token=$tok&x_1=1&y_1=2&x_2=2&y_2=4&skipped=999"))
    calc_status = String(resp_calc.body)
    @test occursin("1</span> skipped for missing values", calc_status)
    @test !occursin("999", calc_status)

    # The hidden field is gone from the grid form entirely.
    @test !occursin("name=\"skipped\"", add_html)
end

@testset "Fix pack B: tab radios are siblings of nav and panels" begin
    html = String(handler(HTTP.Request("GET", "/")).body)
    radios = collect(eachmatch(r"<input type=\"radio\" name=\"tab\" id=\"tab-[a-z]+\" value=\"[a-z]+\"(?: checked)?>", html))
    @test length(radios) == 4
    @test radios[1].match == "<input type=\"radio\" name=\"tab\" id=\"tab-data\" value=\"data\" checked>"

    nav_pos = findfirst("<nav class=\"tabs\"", html)
    nav_end = findfirst("</nav>", html)
    panels_pos = findfirst("<div class=\"tab-panels\">", html)
    @test nav_pos !== nothing && nav_end !== nothing && panels_pos !== nothing

    last_radio_end = radios[end].offset + length(radios[end].match) - 1
    @test last_radio_end < first(nav_pos)          # radios before the nav
    @test first(nav_pos) < first(panels_pos)        # nav before the panels
    @test first(nav_end) < first(panels_pos)

    nav_html = html[first(nav_pos):first(nav_end) + length("</nav>") - 1]
    @test !occursin("<input", nav_html)             # labels only, no radios inside the nav
    for id in ("tab-data", "tab-preprocess", "tab-calculation", "tab-result")
        @test occursin("<label class=\"tab-label\" for=\"$id\">", nav_html)
        @test occursin("id=\"$id\"", html)
    end
    for id in ("panel-data", "panel-preprocess", "panel-calculation", "panel-result")
        @test occursin("id=\"$id\"", html)
    end

    # The stylesheet now works with plain sibling selectors and no :has().
    css = read(joinpath(@__DIR__, "..", "static", "style.css"), String)
    @test !occursin(":has(", css)
    @test !occursin(":checked + .tab-label", css)
    @test occursin("input[name=\"tab\"]", css)
    for name in ("data", "preprocess", "calculation", "result")
        @test occursin("#tab-$name:checked ~ .tab-panels #panel-$name", css)
        @test occursin("#tab-$name:checked ~ .tabs label[for=\"tab-$name\"]", css)
    end
end

const FORM_CT = ["Content-Type" => "application/x-www-form-urlencoded"]
const SAMPLE_GRID = "x_1=1&y_1=2&x_2=2&y_2=4&x_3=3&y_3=5&x_4=4&y_4=4&x_5=5&y_5=6"

@testset "Phase 4: Weka-style summary panel" begin
    html = String(handler(HTTP.Request("POST", "/calculate", FORM_CT, SAMPLE_GRID)).body)

    @test occursin("<tr><th>Equation</th><td class=\"num summary-eq\">&#x0177; = 1.8 + 0.8x</td></tr>", html)
    @test occursin("<tr><th>Instances</th><td class=\"num\">5</td></tr>", html)
    @test occursin("<tr><th>Correlation coefficient (r)</th><td class=\"num\">0.8528</td></tr>", html)
    @test occursin("<tr><th>Coefficient of determination (R&#x00B2;)</th><td class=\"num\">0.7273</td></tr>", html)
    @test occursin("<tr><th>Standard error</th><td class=\"num\">0.8944</td></tr>", html)
    @test occursin("<tr><th>Mean absolute error (MAE)</th><td class=\"num\">0.64</td></tr>", html)
    @test occursin("<tr><th>Root mean squared error (RMSE)</th><td class=\"num\">0.6928</td></tr>", html)
    @test occursin("<tr><th>Relative absolute error (RAE)</th><td class=\"num\">61.5385%</td></tr>", html)
    @test occursin("<tr><th>Root relative squared error (RRSE)</th><td class=\"num\">52.2233%</td></tr>", html)

    # All-identical Y: undefined statistics show N/A in the same rows.
    flat = String(handler(HTTP.Request("POST", "/calculate", FORM_CT, "x_1=1&y_1=5&x_2=2&y_2=5&x_3=3&y_3=5")).body)
    @test occursin("<tr><th>Correlation coefficient (r)</th><td class=\"num\">N/A</td></tr>", flat)
    @test occursin("<tr><th>Coefficient of determination (R&#x00B2;)</th><td class=\"num\">N/A</td></tr>", flat)
    @test occursin("<tr><th>Relative absolute error (RAE)</th><td class=\"num\">N/A</td></tr>", flat)
    @test occursin("<tr><th>Root relative squared error (RRSE)</th><td class=\"num\">N/A</td></tr>", flat)
end

@testset "Phase 4: POST /predict" begin
    page = String(handler(HTTP.Request("POST", "/calculate", FORM_CT, SAMPLE_GRID)).body)
    @test occursin("<form method=\"post\" action=\"/predict\" class=\"predict-form\">", page)
    @test occursin("name=\"predict_x\"", page)
    # The form carries the full grid state.
    for i in 1:5
        @test occursin("name=\"x_$i\"", page)
        @test occursin("name=\"y_$i\"", page)
    end

    pred = String(handler(HTTP.Request("POST", "/predict", FORM_CT, SAMPLE_GRID * "&predict_x=2")).body)
    @test occursin("class=\"predict-answer\">&#x0177; = <strong>3.4</strong>", pred)
    @test occursin("id=\"tab-result\" value=\"result\" checked", pred)
    @test occursin("class=\"summary\"", pred)

    # Prediction uses the submitted (edited) grid, not the original sample.
    edited = replace(SAMPLE_GRID, "x_1=1" => "x_1=10", "y_1=2" => "y_1=20")
    pred_edit = String(handler(HTTP.Request("POST", "/predict", FORM_CT, edited * "&predict_x=0")).body)
    @test occursin("class=\"predict-answer\"", pred_edit)
    m = match(r"class=\"predict-answer\">&#x0177; = <strong>([-0-9.]+)</strong>", pred_edit)
    @test m !== nothing
    r = Regression.slr([10, 2, 3, 4, 5], [20, 4, 5, 4, 6])
    @test isapprox(parse(Float64, m.captures[1]), r.a; atol = 1e-4)

    # Non-numeric X: styled error, summary still visible, input echoed.
    bad = String(handler(HTTP.Request("POST", "/predict", FORM_CT, SAMPLE_GRID * "&predict_x=abc")).body)
    @test occursin("class=\"error-text\"", bad)
    @test occursin("Non-numeric value &#39;abc&#39; for the new X.", bad)
    @test occursin("class=\"summary\"", bad)
    @test occursin("name=\"predict_x\" class=\"predict-input\" value=\"abc\"", bad)

    # Empty X: its own message.
    empty = String(handler(HTTP.Request("POST", "/predict", FORM_CT, SAMPLE_GRID * "&predict_x=")).body)
    @test occursin("Enter a value for X to predict.", empty)
end

@testset "Phase 4: decimal places are display-only" begin
    page = String(handler(HTTP.Request("GET", "/")).body)
    @test occursin("<select name=\"decimals\" id=\"decimals\" class=\"select-decimals\">", page)
    for d in 2:8
        @test occursin("<option value=\"$d\"", page)
    end
    @test occursin("value=\"4\" selected", page)
    @test occursin("name=\"decimals\" value=\"4\"", page) # hidden field in other forms

    six = String(handler(HTTP.Request("POST", "/calculate", FORM_CT, SAMPLE_GRID * "&decimals=6")).body)
    @test occursin("0.852803", six) # r at 6 dp
    @test occursin("0.727273", six)
    @test occursin("value=\"6\" selected", six)
    @test occursin("name=\"decimals\" value=\"6\"", six)
    # Calculations are unchanged by display precision.
    @test occursin("&#x0177; = 1.8 + 0.8x", six)

    pred6 = String(handler(HTTP.Request("POST", "/predict", FORM_CT, SAMPLE_GRID * "&decimals=6&predict_x=2")).body)
    @test occursin("name=\"decimals\" value=\"6\"", pred6)

    bad = String(handler(HTTP.Request("POST", "/calculate", FORM_CT, SAMPLE_GRID * "&decimals=99")).body)
    @test occursin("0.7273", bad)
    @test !occursin("value=\"99\"", bad)
end

@testset "Phase 4: histogram in the selected attribute panel" begin
    lock(UPLOAD_LOCK) do
        empty!(UPLOADS)
        empty!(UPLOAD_ORDER)
    end

    boundary = "----HistBoundary12345"
    csv_content = "x,y,label\n1,2,a\n2,4,b\n3,5,c\n4,4,d\n5,6,e\n"
    body = string(
        "--", boundary, "\r\n",
        "Content-Disposition: form-data; name=\"upload_submitted\"\r\n\r\n1\r\n",
        "--", boundary, "\r\n",
        "Content-Disposition: form-data; name=\"first_row_header\"\r\n\r\n1\r\n",
        "--", boundary, "\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"hist.csv\"\r\n",
        "Content-Type: text/csv\r\n\r\n",
        csv_content, "\r\n",
        "--", boundary, "--\r\n"
    )
    upload_html = String(handler(HTTP.Request("POST", "/upload", ["Content-Type" => "multipart/form-data; boundary=" * boundary], Vector{UInt8}(codeunits(body)))).body)
    @test occursin("class=\"histogram\"", upload_html)
    @test occursin("class=\"histogram-caption\"", upload_html)
    bars = length(collect(eachmatch(r"<rect class=\"bar\"", upload_html)))
    @test 1 <= bars <= 10

    m = match(r"name=\"token\" value=\"(tok_[^\"]+)\"", upload_html)
    @test m !== nothing
    token = m.captures[1]

    # A nominal column has no histogram.
    nominal = String(handler(HTTP.Request("POST", "/rows", FORM_CT, "token=$token&x_col=1&y_col=2&attr_show=3")).body)
    @test !occursin("class=\"histogram\"", nominal)
    @test occursin("<strong>label</strong>", nominal)

    # A numeric column shows one.
    numeric = String(handler(HTTP.Request("POST", "/rows", FORM_CT, "token=$token&x_col=1&y_col=2&attr_show=1")).body)
    @test occursin("class=\"histogram\"", numeric)
end

