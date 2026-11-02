using HTTP
using UUIDs

include(joinpath(@__DIR__, "regression.jl"))
include(joinpath(@__DIR__, "importer.jl"))
include(joinpath(@__DIR__, "render.jl"))

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

function read_full_body(req)::String
    body = req.body
    buf = Vector{UInt8}(undef, 65536)
    parts = String[]
    while true
        n = HTTP.body_read!(body, buf)
        n == 0 && break
        push!(parts, String(buf[1:n]))
    end
    return join(parts, "")
end

const MAX_BODY_BYTES = 10 * 1024 * 1024

struct RequestBodyTooLargeError <: Exception
    size::Int
end

function Base.showerror(io::IO, e::RequestBodyTooLargeError)
    print(io, "Request body too large: ", e.size, " bytes (maximum allowed: ", MAX_BODY_BYTES, " bytes)")
end

function read_form(req)::Dict{String,String}
    body = read_full_body(req)
    if ncodeunits(body) > MAX_BODY_BYTES
        throw(RequestBodyTooLargeError(ncodeunits(body)))
    end
    return parse_form(body)
end

struct UploadData
    columns::Vector{String}
    values::Vector{Vector{String}}
    first_row_header::Bool
    timestamp::Float64
    x_col::Int
    y_col::Int
    rows::Vector{Tuple{String,String}}
end

const UPLOADS = Dict{String, UploadData}()
const UPLOAD_ORDER = String[]
const UPLOAD_LOCK = ReentrantLock()
const MAX_STORE_ENTRIES = 5
const TOKEN_TTL_SECONDS = 3600

function make_token()::String
    return "tok_" * lowercase(string(uuid4()))
end

function store_upload(tok::String, columns::Vector{String}, values::Vector{Vector{String}}, first_row_header::Bool, x_col::Int, y_col::Int, rows::Vector{Tuple{String,String}})::String
    lock(UPLOAD_LOCK) do
        if length(UPLOAD_ORDER) >= MAX_STORE_ENTRIES
            old = splice!(UPLOAD_ORDER, 1)
            delete!(UPLOAD_STORE, old)
        end
        UPLOADS[tok] = UploadData(columns, values, first_row_header, time(), x_col, y_col, rows)
        push!(UPLOAD_ORDER, tok)
    end
    return tok
end

function get_upload(tok::String)::Union{UploadData, Nothing}
    lock(UPLOAD_LOCK) do
        d = get(UPLOADS, tok, nothing)
        d === nothing && return nothing
        if (time() - d.timestamp) > TOKEN_TTL_SECONDS
            delete!(UPLOADS, tok)
            return nothing
        end
        return d
    end
end

function upload_rows(u::UploadData)::Vector{Tuple{String,String}}
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

function html_response(html)::HTTP.Response
    return HTTP.Response(200; body = html, headers = ["Content-Type" => "text/html; charset=utf-8"])
end

function css_response()::HTTP.Response
    css_path = joinpath(@__DIR__, "..", "static", "style.css")
    return HTTP.Response(200; body = read(css_path, String), headers = ["Content-Type" => "text/css; charset=utf-8"])
end

function grid_response(rows; token::String = "")::HTTP.Response
    status = string(length(rows)) * " &middot; press Calculate"
    return html_response(render_page(rows, nothing, nothing, status, "data", token))
end

function results_response(result, err, rows; token::String = "")::HTTP.Response
    if err !== nothing
        return html_response(render_page(rows, nothing, err, "Error: " * err, "result", token))
    end
    status = "n = " * string(result.n) * " &middot; b = " * fmt(result.b) * " &middot; a = " * fmt(result.a) * " &middot; R&#x00B2; = " * fmt(result.r2)
    return html_response(render_page(rows, result, nothing, status, "result", token))
end

function handle_rows(qs)::HTTP.Response
    action = get(qs, "action", "calculate")
    tok = get(qs, "token", "")
    u = valid_token(tok)
    rows = u === nothing ? get_rows(qs) : upload_rows(u)
    remove_idx = 0
    for key in keys(qs)
        startswith(key, "rm_") || continue
        v = tryparse(Int, key[4:end])
        v === nothing || (remove_idx = v)
    end
    if haskey(qs, "attr_show")
        if u === nothing
            return grid_response(get_rows(qs); token = tok)
        end
        x_col2 = 0
        y_col2 = 0
        for (k, v) in qs
            if startswith(k, "attr_x_")
                j = tryparse(Int, k[8:end])
                j === nothing || (x_col2 = j)
            elseif startswith(k, "attr_y_")
                j = tryparse(Int, k[8:end])
                j === nothing || (y_col2 = j)
            end
        end
        if x_col2 == 0 && y_col2 == 0
            x_col2 = u.x_col
            y_col2 = u.y_col
        end
        lock(UPLOAD_LOCK) do
            UPLOADS[tok] = UploadData(u.columns, u.values, u.first_row_header, u.timestamp, x_col2, y_col2, u.rows)
        end
        u2 = valid_token(tok)
        if u2 === nothing
            return grid_response(Tuple{String,String}[]; token = tok)
        end
        return html_response(render_page(upload_rows(u2), nothing, nothing, "Select an attribute to preview", "preprocess", tok, u2))
    end
    if remove_idx != 0
        kept = Tuple{String,String}[]
        for (i, row) in enumerate(rows)
            i == remove_idx && continue
            push!(kept, row)
        end
        if u !== nothing
            lock(UPLOAD_LOCK) do
                UPLOADS[tok] = UploadData(u.columns, u.values, u.first_row_header, u.timestamp, u.x_col, u.y_col, kept)
            end
        end
        return grid_response(kept; token = tok)
    elseif action == "add"
        new_rows = Tuple{String,String}[]
        for row in rows
            push!(new_rows, row)
        end
        push!(new_rows, ("", ""))
        if u !== nothing
            lock(UPLOAD_LOCK) do
                UPLOADS[tok] = UploadData(u.columns, u.values, u.first_row_header, u.timestamp, u.x_col, u.y_col, new_rows)
            end
        end
        return grid_response(new_rows; token = tok)
    elseif action == "calculate"
        result, err = run_regression(rows)
        return results_response(result, err, rows; token = tok)
    end
    return grid_response(rows; token = tok)
end

function handle_calculate(qs)::HTTP.Response
    tok = get(qs, "token", "")
    u = valid_token(tok)
    rows = u === nothing ? get_rows(qs) : upload_rows(u)
    result, err = run_regression(rows)
    return results_response(result, err, rows; token = tok)
end

function handle_upload(req)::HTTP.Response
    ct = HTTP.header(req, "Content-Type")
    body_str = read_full_body(req)
    if ncodeunits(body_str) > MAX_BODY_BYTES
        return oversize_response("Request body too large: " * string(ncodeunits(body_str)) * " bytes (maximum allowed: " * string(MAX_BODY_BYTES) * " bytes)")
    end
    parts = HTTP.parse_multipart_form(ct, Vector{UInt8}(codeunits(body_str)))
    println("DEBUG ct=", ct, " size=", ncodeunits(body_str), " head=", repr(first(body_str, 60)))
    file_part_name = ""
    file_part_bytes = Vector{UInt8}()
    first_row_header = true
    if parts !== nothing
        for p in parts
            if p.name == "first_row_header"
                first_row_header = String(read(p.data)) == "1"
            end
            if p.filename !== nothing && endswith(lowercase(String(p.filename)), ".xlsx")
                file_part_name = String(p.filename)
                file_part_bytes = Vector{UInt8}(codeunits(String(read(p.data))))
            end
        end
    end
    if isempty(file_part_name)
        return HTTP.Response(400; body = "No file uploaded", headers = ["Content-Type" => "text/plain"])
    end
    names, cols = read_upload_columns(file_part_bytes, file_part_name; first_row_header = first_row_header)
    check_row_cap(count_rows(cols))
    tok = make_token()
    ycol = min(2, max(1, length(cols)))
    rows = upload_rows(UploadData(names, cols, first_row_header, time(), 1, ycol, Tuple{String,String}[]))
    store_upload(tok, names, cols, first_row_header, 1, ycol, rows)
    return grid_response(rows; token = tok)
end

function handle_select(qs)::HTTP.Response
    tok = get(qs, "token", "")
    u = valid_token(tok)
    if u === nothing
        return html_response("""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Linear Regression Calculator</title>
<link rel="stylesheet" href="/static/style.css">
</head>
<body>
<div class="window">
<div class="tab-panels">
<section class="tab-panel" id="panel-preprocess" role="tabpanel">
<div class="panel-header">
<h2>Preprocess</h2>
</div>
<div class="panel-body">
<p class="panel-intro">Your upload session has expired. Please re-upload your file.</p>
</div>
</section>
</div>
</body>
</html>
""")
    end
    x_val = get(qs, "x", "")
    y_val = get(qs, "y", "")
    x_col = 0
    y_col = 0
    for (i, n) in enumerate(u.columns)
        if String(n) == x_val
            x_col = i
        end
        if String(n) == y_val
            y_col = i
        end
    end
    if x_col == 0 || y_col == 0
        return html_response("""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Linear Regression Calculator</title>
<link rel="stylesheet" href="/static/style.css">
</head>
<body>
<div class="window">
<div class="tab-panels">
<section class="tab-panel" id="panel-preprocess" role="tabpanel">
<div class="panel-header">
<h2>Preprocess</h2>
</div>
<div class="panel-body">
<p class="error-text">Unknown column for X or Y.</p>
</div>
</section>
</div>
</body>
</html>
""")
    end
    lock(UPLOAD_LOCK) do
        newu = UploadData(u.columns, u.values, u.first_row_header, u.timestamp, x_col, y_col, Tuple{String,String}[])
        newu2 = UploadData(u.columns, u.values, u.first_row_header, u.timestamp, x_col, y_col, upload_rows(newu))
        UPLOADS[tok] = newu2
    end
    return grid_response(upload_rows(newu2); token = tok)
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
        qs = read_form(req)
        if req.target == "/rows"
            return handle_rows(qs)
        elseif req.target == "/calculate"
            return handle_calculate(qs)
        elseif req.target == "/upload"
            return handle_upload(req)
        elseif req.target == "/select"
            return handle_select(qs)
        end
    end
    return HTTP.Response(404; body = "Not Found")
end

HTTP.serve(handler, "127.0.0.1", 8080)
