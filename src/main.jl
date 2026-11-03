using HTTP
using UUIDs

include(joinpath(@__DIR__, "regression.jl"))
include(joinpath(@__DIR__, "importer.jl"))
include(joinpath(@__DIR__, "render.jl"))
include(joinpath(@__DIR__, "chart.jl"))

const SAMPLE_ROWS = Tuple{String,String}[
    ("1", "2"),
    ("2", "4"),
    ("3", "5"),
    ("4", "4"),
    ("5", "6"),
]

function unescape_form(s::String)::String
    b = codeunits(s)
    n = length(b)
    out = UInt8[]
    i = 1
    while i <= n
        c = b[i]
        if c == UInt8('+')
            push!(out, UInt8(' '))
            i += 1
        elseif c == UInt8('%') && i + 2 <= n
            hexstr = String([Char(b[i + 1]), Char(b[i + 2])])
            val = tryparse(Int, hexstr, base = 16)
            if val === nothing
                push!(out, UInt8('%'))
                i += 1
            else
                push!(out, UInt8(val))
                i += 3
            end
        else
            push!(out, c)
            i += 1
        end
    end
    return String(out)
end

function parse_form(body::String)::Dict{String,String}
    d = Dict{String,String}()
    for pair in split(body, '&')
        isempty(pair) && continue
        eq = findfirst('=', pair)
        if eq === nothing
            continue
        end
        k = unescape_form(String(pair[1:prevind(pair, eq)]))
        v = unescape_form(String(pair[nextind(pair, eq):end]))
        d[k] = v
    end
    return d
end

const MAX_BODY_BYTES = 10 * 1024 * 1024

struct RequestBodyTooLargeError <: Exception
    size::Int
end

function Base.showerror(io::IO, e::RequestBodyTooLargeError)
    print(io, "Request body too large: ", e.size, " bytes (maximum allowed: ", MAX_BODY_BYTES, " bytes)")
end

"Declared Content-Length, or nothing when the header is absent or malformed."
function content_length(req)::Union{Int, Nothing}
    raw = strip(HTTP.header(req, "Content-Length", ""))
    isempty(raw) && return nothing
    n = tryparse(Int, raw)
    (n === nothing || n < 0) && return nothing
    return n
end

"""
Read the request body, refusing it as soon as it can exceed `max_bytes`.
The declared Content-Length is checked before reading anything, and the
running total is checked after every chunk, so a body that lies about its
length is still rejected without being fully buffered.
"""
function read_full_body_bytes(req; max_bytes::Int = MAX_BODY_BYTES)::Vector{UInt8}
    declared = content_length(req)
    declared !== nothing && declared > max_bytes && throw(RequestBodyTooLargeError(declared))

    body = req.body
    buf = Vector{UInt8}(undef, 65536)
    out = IOBuffer()
    total = 0
    while true
        n = HTTP.body_read!(body, buf)
        n == 0 && break
        total += n
        total > max_bytes && throw(RequestBodyTooLargeError(total))
        write(out, @view buf[1:n])
    end
    return take!(out)
end

function read_full_body(req)::String
    return String(read_full_body_bytes(req))
end

function read_form(req)::Dict{String,String}
    return parse_form(String(read_full_body_bytes(req)))
end

struct UploadData
    columns::Vector{String}
    values::Vector{Vector{String}}
    first_row_header::Bool
    timestamp::Float64
    x_col::Int
    y_col::Int
    rows::Vector{Tuple{String,String}}
    filename::String
    raw_bytes::Vector{UInt8}
    sheet_names::Vector{String}
    current_sheet::String
    selected_attr::Int
    skipped_count::Int
end

"""
Keyword constructor so callers (and tests) never depend on the field order or
field count: `UploadData(columns = ["x"], values = [["1"]], x_col = 1)`.
"""
function UploadData(;
    columns::Vector{String} = String[],
    values::Vector{Vector{String}} = Vector{Vector{String}}(),
    first_row_header::Bool = true,
    timestamp::Float64 = time(),
    x_col::Int = 1,
    y_col::Int = 1,
    rows::Vector{Tuple{String,String}} = Tuple{String,String}[],
    filename::String = "",
    raw_bytes::Vector{UInt8} = UInt8[],
    sheet_names::Vector{String} = String[],
    current_sheet::String = "",
    selected_attr::Int = 1,
    skipped_count::Int = 0,
)
    return UploadData(columns, values, first_row_header, timestamp, x_col, y_col,
                      rows, filename, raw_bytes, sheet_names, current_sheet,
                      selected_attr, skipped_count)
end

const UPLOADS = Dict{String, UploadData}()
const UPLOAD_ORDER = String[]
const UPLOAD_LOCK = ReentrantLock()
const MAX_STORE_ENTRIES = 5
const TOKEN_TTL_SECONDS = 3600

# Display-only precision; calculations always use full Float64.
const DEFAULT_DECIMALS = 4
const MIN_DECIMALS = 2
const MAX_DECIMALS = 8

function read_decimals(qs::Dict{String,String})::Int
    d = tryparse(Int, get(qs, "decimals", ""))
    (d === nothing || d < MIN_DECIMALS || d > MAX_DECIMALS) && return DEFAULT_DECIMALS
    return d
end

function make_token()::String
    return "tok_" * lowercase(string(uuid4()))
end

"""
The single write path for the upload store. Every create and every update goes
through here so `UPLOADS` and `UPLOAD_ORDER` can never drift: re-storing a token
moves it to the newest position, the store is capped at `MAX_STORE_ENTRIES`, and
oldest-first eviction removes the matching order entries.
"""
function save_upload(tok::String, u::UploadData)::String
    lock(UPLOAD_LOCK) do
        if haskey(UPLOADS, tok)
            delete!(UPLOADS, tok)
            i = findfirst(==(tok), UPLOAD_ORDER)
            i === nothing || deleteat!(UPLOAD_ORDER, i)
        end
        while length(UPLOADS) >= MAX_STORE_ENTRIES && !isempty(UPLOAD_ORDER)
            delete!(UPLOADS, popfirst!(UPLOAD_ORDER))
        end
        UPLOADS[tok] = u
        push!(UPLOAD_ORDER, tok)
    end
    return tok
end

function store_upload(
    tok::String,
    columns::Vector{String},
    values::Vector{Vector{String}},
    first_row_header::Bool,
    x_col::Int,
    y_col::Int,
    rows::Vector{Tuple{String,String}};
    timestamp::Float64 = time(),
    filename::String = "",
    raw_bytes::Vector{UInt8} = UInt8[],
    sheet_names::Vector{String} = String[],
    current_sheet::String = "",
    selected_attr::Int = 1,
    skipped_count::Int = 0,
)::String
    return save_upload(tok, UploadData(
        columns = columns,
        values = values,
        first_row_header = first_row_header,
        timestamp = timestamp,
        x_col = x_col,
        y_col = y_col,
        rows = rows,
        filename = filename,
        raw_bytes = raw_bytes,
        sheet_names = sheet_names,
        current_sheet = current_sheet,
        selected_attr = selected_attr,
        skipped_count = skipped_count,
    ))
end

"Re-store an existing upload with selected fields replaced (refreshes the TTL)."
function update_upload(
    tok::String,
    u::UploadData;
    columns::Vector{String} = u.columns,
    values::Vector{Vector{String}} = u.values,
    first_row_header::Bool = u.first_row_header,
    x_col::Int = u.x_col,
    y_col::Int = u.y_col,
    rows::Vector{Tuple{String,String}} = u.rows,
    filename::String = u.filename,
    raw_bytes::Vector{UInt8} = u.raw_bytes,
    sheet_names::Vector{String} = u.sheet_names,
    current_sheet::String = u.current_sheet,
    selected_attr::Int = u.selected_attr,
    skipped_count::Int = u.skipped_count,
)::UploadData
    new_u = UploadData(
        columns = columns,
        values = values,
        first_row_header = first_row_header,
        x_col = x_col,
        y_col = y_col,
        rows = rows,
        filename = filename,
        raw_bytes = raw_bytes,
        sheet_names = sheet_names,
        current_sheet = current_sheet,
        selected_attr = selected_attr,
        skipped_count = skipped_count,
    )
    save_upload(tok, new_u)
    return new_u
end

function get_upload(tok::String)::Union{UploadData, Nothing}
    lock(UPLOAD_LOCK) do
        d = get(UPLOADS, tok, nothing)
        d === nothing && return nothing
        if (time() - d.timestamp) > TOKEN_TTL_SECONDS
            delete!(UPLOADS, tok)
            i = findfirst(==(tok), UPLOAD_ORDER)
            i === nothing || deleteat!(UPLOAD_ORDER, i)
            return nothing
        end
        return d
    end
end

function upload_rows(u::UploadData)::Vector{Tuple{String,String}}
    if !isempty(u.rows)
        return u.rows
    end
    rows = Tuple{String,String}[]
    isempty(u.values) && return rows
    ncol = length(u.values)
    ic = min(max(u.x_col, 1), ncol)
    jc = min(max(u.y_col, 1), ncol)
    for i in 1:length(u.values[ic])
        push!(rows, (u.values[ic][i], i <= length(u.values[jc]) ? u.values[jc][i] : ""))
    end
    return rows
end

function valid_token(tok::String)::Union{UploadData, Nothing}
    isempty(tok) && return nothing
    return get_upload(tok)
end

function get_rows(qs::Dict{String,String})::Vector{Tuple{String,String}}
    max_i = 0
    for k in keys(qs)
        startswith(k, "x_") || continue
        i = tryparse(Int, k[3:end])
        i === nothing || (max_i = max(max_i, i))
    end
    rows = Tuple{String,String}[]
    for i in 1:max_i
        push!(rows, (get(qs, "x_" * string(i), ""), get(qs, "y_" * string(i), "")))
    end
    return rows
end

function run_regression(rows)::Tuple{Union{Nothing,Regression.SLRResult}, Union{Nothing,String}}
    xs = Float64[]
    ys = Float64[]
    for (i, row) in enumerate(rows)
        xs_str = strip(row[1])
        ys_str = strip(row[2])
        if xs_str == "" && ys_str == ""
            continue
        end
        x = tryparse(Float64, xs_str)
        y = tryparse(Float64, ys_str)
        if x === nothing || y === nothing
            return nothing, "Row " * string(i) * ": non-numeric value '" * row[1] * "' for X / '" * row[2] * "' for Y"
        end
        push!(xs, x)
        push!(ys, y)
    end
    result = try
        Regression.slr(xs, ys)
    catch e
        return nothing, sprint(showerror, e)
    end
    return result, nothing
end

function html_response(html; status::Int = 200)::HTTP.Response
    return HTTP.Response(status; body = html, headers = ["Content-Type" => "text/html; charset=utf-8"])
end

function css_response()::HTTP.Response
    css_path = joinpath(@__DIR__, "..", "static", "style.css")
    return HTTP.Response(200; body = read(css_path, String), headers = ["Content-Type" => "text/css; charset=utf-8"])
end

function grid_response(rows; token::String = "", skipped::Int = 0, decimals::Int = DEFAULT_DECIMALS)::HTTP.Response
    status = if skipped > 0
        string(length(rows)) * " (" * string(skipped) * " skipped for missing values) &middot; press Calculate"
    else
        string(length(rows)) * " &middot; press Calculate"
    end
    return html_response(render_page(rows, nothing, nothing, status, "data", token; skipped_count = skipped, decimals = decimals))
end

function results_response(result, err, rows; token::String = "", skipped::Int = 0,
                          decimals::Int = DEFAULT_DECIMALS, predicted = nothing,
                          predict_x::String = "")::HTTP.Response
    if err !== nothing
        return html_response(render_page(rows, result, err, "Error: " * html_escape(err), "result", token;
                                         skipped_count = skipped, decimals = decimals,
                                         predicted = predicted, predict_x = predict_x))
    end
    status = if skipped > 0
        "n = " * string(result.n) * " (" * string(skipped) * " skipped for missing values) &middot; b = " * fmt(result.b, decimals) * " &middot; a = " * fmt(result.a, decimals) * " &middot; R² = " * fmt(result.r2, decimals)
    else
        "n = " * string(result.n) * " &middot; b = " * fmt(result.b, decimals) * " &middot; a = " * fmt(result.a, decimals) * " &middot; R² = " * fmt(result.r2, decimals)
    end
    return html_response(render_page(rows, result, nothing, status, "result", token;
                                     skipped_count = skipped, decimals = decimals,
                                     predicted = predicted, predict_x = predict_x))
end

function handle_rows(qs)::HTTP.Response
    action = get(qs, "action", "calculate")
    tok = get(qs, "token", "")
    u = valid_token(tok)
    decimals = read_decimals(qs)

    if action == "change_sheet"
        if u === nothing
            msg = !isempty(tok) ? "Your upload session has expired. Please re-upload your file." : "No file loaded. Please upload a file first."
            return html_response(render_page(Tuple{String,String}[], nothing, nothing, msg, "preprocess", ""; preprocess_error = msg, decimals = decimals))
        end
        new_sheet = get(qs, "sheet", "")
        new_names, new_cols, new_sheets, chosen = try
            read_upload_columns_with_sheet(u.raw_bytes, u.filename; first_row_header = u.first_row_header, sheet_name = new_sheet)
        catch e
            return html_response(render_page(Tuple{String,String}[], nothing, nothing, html_escape(sprint(showerror, e)), "preprocess", tok, u; preprocess_error = sprint(showerror, e), decimals = decimals))
        end
        new_x = 1
        new_y = min(2, length(new_cols))
        new_u = update_upload(
            tok,
            u;
            columns = new_names,
            values = new_cols,
            x_col = new_x,
            y_col = new_y,
            rows = Tuple{String,String}[],
            sheet_names = new_sheets,
            current_sheet = chosen,
            selected_attr = 1,
            skipped_count = 0,
        )
        status = "Loaded sheet '" * html_escape(chosen) * "' (" * string(count_rows(new_cols)) * " instances, " * string(length(new_names)) * " attributes)"
        return html_response(render_page(Tuple{String,String}[], nothing, nothing, status, "preprocess", tok, new_u; decimals = decimals))
    end

    if haskey(qs, "attr_show") || action == "show"
        if u === nothing
            msg = !isempty(tok) ? "Your upload session has expired. Please re-upload your file." : "No file loaded. Please upload a file first."
            return html_response(render_page(Tuple{String,String}[], nothing, nothing, msg, "preprocess", ""; preprocess_error = msg, decimals = decimals))
        end
        new_x = u.x_col
        new_y = u.y_col
        if haskey(qs, "x_col")
            xi = tryparse(Int, qs["x_col"])
            (xi !== nothing && 1 <= xi <= length(u.columns)) && (new_x = xi)
        end
        if haskey(qs, "y_col")
            yi = tryparse(Int, qs["y_col"])
            (yi !== nothing && 1 <= yi <= length(u.columns)) && (new_y = yi)
        end
        sel_attr = u.selected_attr
        if haskey(qs, "attr_show")
            ai = tryparse(Int, qs["attr_show"])
            (ai !== nothing && 1 <= ai <= length(u.columns)) && (sel_attr = ai)
        end
        new_u = update_upload(tok, u; x_col = new_x, y_col = new_y, selected_attr = sel_attr)
        status = "Selected attribute: X = " * html_escape(new_u.columns[new_u.x_col]) * " &middot; Y = " * html_escape(new_u.columns[new_u.y_col])
        return html_response(render_page(Tuple{String,String}[], nothing, nothing, status, "preprocess", tok, new_u; decimals = decimals))
    end

    # POSTs use exactly the rows that were submitted; SAMPLE_ROWS is only for GET /.
    rows = get_rows(qs)
    # The skipped-row count is server-side state in the upload record, never a form field.
    skipped = u === nothing ? 0 : u.skipped_count

    # Collect every submitted rm_* key, ignore out-of-range values, and remove
    # only the smallest valid index so the result never depends on Dict order.
    rm_indices = Int[]
    for key in keys(qs)
        startswith(key, "rm_") || continue
        v = tryparse(Int, key[4:end])
        (v !== nothing && 1 <= v <= length(rows)) && push!(rm_indices, v)
    end
    remove_idx = isempty(rm_indices) ? 0 : minimum(rm_indices)

    if remove_idx != 0
        kept = Tuple{String,String}[]
        for (i, row) in enumerate(rows)
            i == remove_idx && continue
            push!(kept, row)
        end
        if u !== nothing
            update_upload(tok, u; rows = kept)
        end
        return grid_response(kept; token = tok, skipped = skipped, decimals = decimals)
    elseif action == "add"
        new_rows = copy(rows)
        push!(new_rows, ("", ""))
        if u !== nothing
            update_upload(tok, u; rows = new_rows)
        end
        return grid_response(new_rows; token = tok, skipped = skipped, decimals = decimals)
    elseif action == "calculate"
        result, err = run_regression(rows)
        return results_response(result, err, rows; token = tok, skipped = skipped, decimals = decimals)
    end
    return grid_response(rows; token = tok, skipped = skipped, decimals = decimals)
end

function handle_calculate(qs)::HTTP.Response
    tok = get(qs, "token", "")
    u = valid_token(tok)
    decimals = read_decimals(qs)
    # POSTs use exactly the rows that were submitted; SAMPLE_ROWS is only for GET /.
    rows = get_rows(qs)
    # The skipped-row count is server-side state in the upload record, never a form field.
    skipped = u === nothing ? 0 : u.skipped_count
    result, err = run_regression(rows)
    return results_response(result, err, rows; token = tok, skipped = skipped, decimals = decimals)
end

function handle_predict(qs)::HTTP.Response
    tok = get(qs, "token", "")
    u = valid_token(tok)
    decimals = read_decimals(qs)
    rows = get_rows(qs)
    skipped = u === nothing ? 0 : u.skipped_count
    predict_x = String(strip(get(qs, "predict_x", "")))

    result, err = run_regression(rows)
    if err !== nothing
        return results_response(nothing, err, rows; token = tok, skipped = skipped,
                                decimals = decimals, predict_x = predict_x)
    end

    xv = tryparse(Float64, predict_x)
    if xv === nothing
        msg = isempty(predict_x) ? "Enter a value for X to predict." :
              "Non-numeric value '" * predict_x * "' for the new X."
        return results_response(result, msg, rows; token = tok, skipped = skipped,
                                decimals = decimals, predict_x = predict_x)
    end

    predicted = result.a + result.b * xv
    status = "ŷ = " * fmt(predicted, decimals) * " for X = " * fmt(xv, decimals)
    return html_response(render_page(rows, result, nothing, status, "result", tok;
                                     skipped_count = skipped, decimals = decimals,
                                     predicted = predicted, predict_x = predict_x))
end

function handle_upload(req)::HTTP.Response
    ct = HTTP.header(req, "Content-Type", "")
    # Reject on the declared length before touching the body, then keep the
    # streaming cap in read_full_body_bytes for lying/missing Content-Length.
    declared = content_length(req)
    if declared !== nothing && declared > MAX_BODY_BYTES
        return oversize_response("Request body too large: " * string(declared) * " bytes (maximum allowed: " * string(MAX_BODY_BYTES) * " bytes)")
    end
    body_bytes = read_full_body_bytes(req)

    parts = HTTP.parse_multipart_form(ct, body_bytes)
    if parts === nothing
        return html_response(render_page(Tuple{String,String}[], nothing, nothing, "Invalid upload format", "preprocess", ""; preprocess_error = "Could not parse multipart form data.", decimals = decimals))
    end

    file_part_name = ""
    file_part_bytes = UInt8[]
    has_header_field = false
    first_row_header = false
    has_submit_marker = false
    decimals_raw = ""

    for p in parts
        if p.name == "first_row_header"
            has_header_field = true
            val = lowercase(strip(String(read(p.data))))
            first_row_header = (val in ("1", "true", "on", "yes"))
        elseif p.name == "upload_submitted"
            has_submit_marker = true
        elseif p.name == "decimals"
            decimals_raw = strip(String(read(p.data)))
        end
        if p.filename !== nothing && !isempty(p.filename)
            name_l = lowercase(String(p.filename))
            if endswith(name_l, ".csv") || endswith(name_l, ".xlsx")
                file_part_name = String(p.filename)
                file_part_bytes = read(p.data)
            end
        end
    end

    if !has_header_field && !has_submit_marker
        first_row_header = true
    end

    decimals = read_decimals(Dict{String,String}("decimals" => decimals_raw))

    if isempty(file_part_name) || isempty(file_part_bytes)
        return html_response(render_page(Tuple{String,String}[], nothing, nothing, "No file uploaded", "preprocess", ""; preprocess_error = "No valid .csv or .xlsx file uploaded.", decimals = decimals))
    end

    names, cols, sheets, chosen_sheet = try
        read_upload_columns_with_sheet(file_part_bytes, file_part_name; first_row_header = first_row_header)
    catch e
        return html_response(render_page(Tuple{String,String}[], nothing, nothing, sprint(showerror, e), "preprocess", ""; preprocess_error = sprint(showerror, e), decimals = decimals))
    end

    try
        check_row_cap(count_rows(cols))
    catch e
        return html_response(render_page(Tuple{String,String}[], nothing, nothing, sprint(showerror, e), "preprocess", ""; preprocess_error = sprint(showerror, e), decimals = decimals))
    end

    if isempty(cols) || count_rows(cols) == 0
        return html_response(render_page(Tuple{String,String}[], nothing, nothing, "Uploaded file contains no data rows", "preprocess", ""; preprocess_error = "Uploaded file contains no data rows.", decimals = decimals))
    end

    tok = make_token()
    x_col = 1
    y_col = min(2, length(cols))
    u = UploadData(
        columns = names,
        values = cols,
        first_row_header = first_row_header,
        x_col = x_col,
        y_col = y_col,
        rows = Tuple{String,String}[],
        filename = file_part_name,
        raw_bytes = file_part_bytes,
        sheet_names = sheets,
        current_sheet = chosen_sheet,
        selected_attr = 1,
        skipped_count = 0,
    )
    save_upload(tok, u)

    status = "File uploaded: " * html_escape(file_part_name) * " &middot; " * string(count_rows(cols)) * " rows &middot; pick X and Y attributes"
    return html_response(render_page(Tuple{String,String}[], nothing, nothing, status, "preprocess", tok, u; decimals = decimals))
end

function handle_select(qs)::HTTP.Response
    tok = get(qs, "token", "")
    u = valid_token(tok)
    decimals = read_decimals(qs)
    if u === nothing
        msg = !isempty(tok) ? "Your upload session has expired. Please re-upload your file." : "No file loaded. Please upload a file first."
        return html_response(render_page(Tuple{String,String}[], nothing, nothing, msg, "preprocess", ""; preprocess_error = msg, decimals = decimals))
    end

    x_idx = 0
    y_idx = 0
    if haskey(qs, "x_col")
        x_idx = something(tryparse(Int, qs["x_col"]), 0)
    end
    if haskey(qs, "y_col")
        y_idx = something(tryparse(Int, qs["y_col"]), 0)
    end
    if x_idx == 0 && haskey(qs, "x")
        fx = findfirst(==(qs["x"]), u.columns)
        x_idx = fx === nothing ? 0 : fx
    end
    if y_idx == 0 && haskey(qs, "y")
        fy = findfirst(==(qs["y"]), u.columns)
        y_idx = fy === nothing ? 0 : fy
    end
    if x_idx == 0
        x_idx = u.x_col
    end
    if y_idx == 0
        y_idx = u.y_col
    end

    if !(1 <= x_idx <= length(u.columns)) || !(1 <= y_idx <= length(u.columns))
        return html_response(render_page(Tuple{String,String}[], nothing, nothing, "Unknown column for X or Y", "preprocess", tok, u; preprocess_error = "Unknown column for X or Y.", decimals = decimals))
    end

    cleaned_rows, skipped = try
        extract_selected_columns(u.values, u.columns, x_idx, y_idx, u.first_row_header)
    catch e
        if e isa NonNumericInputError
            err_msg = sprint(showerror, e)
            return html_response(render_page(Tuple{String,String}[], nothing, nothing, html_escape(err_msg), "preprocess", tok, u; preprocess_error = err_msg, decimals = decimals))
        end
        rethrow()
    end

    new_u = update_upload(tok, u; x_col = x_idx, y_col = y_idx, rows = cleaned_rows, skipped_count = skipped)

    status = skipped > 0 ?
        "Loaded " * string(length(cleaned_rows)) * " rows (" * string(skipped) * " skipped for missing values) &middot; press Calculate" :
        "Loaded " * string(length(cleaned_rows)) * " rows &middot; press Calculate"

    return html_response(render_page(cleaned_rows, nothing, nothing, status, "data", tok, new_u; skipped_count = skipped, decimals = decimals))
end

function handler(req)::HTTP.Response
    try
        return _handler(req)
    catch e
        if e isa RequestBodyTooLargeError
            return oversize_response(sprint(showerror, e))
        end
        return HTTP.Response(500; body = "ERROR: " * sprint(showerror, e), headers = ["Content-Type" => "text/plain"])
    end
end

function oversize_response(msg)::HTTP.Response
    html = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Linear Regression Calculator</title>
<link rel="stylesheet" href="/static/style.css">
</head>
<body>
<div class="window">
<div class="tab-panels">
<section class="tab-panel" id="panel-result" role="tabpanel">
<div class="panel-header">
<h2>Result</h2>
</div>
<div class="panel-body">
<p class="error-text">$(msg)</p>
</div>
</section>
</div>
</div>
</body>
</html>
"""
    return HTTP.Response(413; body = html, headers = ["Content-Type" => "text/html; charset=utf-8"])
end

function _handler(req)::HTTP.Response
    if req.method == "GET"
        if req.target == "/"
            status = string(length(SAMPLE_ROWS)) * " &middot; press Calculate"
            return html_response(render_page(SAMPLE_ROWS, nothing, nothing, status, "data"))
        elseif req.target == "/static/style.css"
            return css_response()
        end
    elseif req.method == "POST"
        if req.target == "/upload"
            return handle_upload(req)
        end
        qs = read_form(req)
        if req.target == "/rows"
            return handle_rows(qs)
        elseif req.target == "/calculate"
            return handle_calculate(qs)
        elseif req.target == "/select"
            return handle_select(qs)
        elseif req.target == "/predict"
            return handle_predict(qs)
        end
    end
    return HTTP.Response(404; body = "Not Found")
end

if abspath(PROGRAM_FILE) == @__FILE__
    HTTP.serve(handler, "127.0.0.1", 8080)
end
