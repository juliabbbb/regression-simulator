using HTTP

include(joinpath(@__DIR__, "regression.jl"))
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

const MAX_BODY_BYTES = 12 * 1024 * 1024

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

function grid_response(rows)::HTTP.Response
    status = string(length(rows)) * " &middot; press Calculate"
    return html_response(render_page(rows, nothing, nothing, status, "data"))
end

function results_response(result, err, rows)::HTTP.Response
    if err !== nothing
        return html_response(render_page(rows, nothing, err, "Error: " * err, "result"))
    end
    status = "n = " * string(result.n) * " &middot; b = " * fmt(result.b) * " &middot; a = " * fmt(result.a) * " &middot; R&#x00B2; = " * fmt(result.r2)
    return html_response(render_page(rows, result, nothing, status, "result"))
end

function handle_rows(qs)::HTTP.Response
    action = get(qs, "action", "calculate")
    rows = get_rows(qs)
    remove_idx = 0
    for key in keys(qs)
        startswith(key, "rm_") || continue
        v = tryparse(Int, key[4:end])
        v === nothing || (remove_idx = v)
    end
    if remove_idx != 0
        kept = Tuple{String,String}[]
        for (i, row) in enumerate(rows)
            i == remove_idx && continue
            push!(kept, row)
        end
        return grid_response(kept)
    elseif action == "add"
        new_rows = Tuple{String,String}[]
        for row in rows
            push!(new_rows, row)
        end
        push!(new_rows, ("", ""))
        return grid_response(new_rows)
    elseif action == "calculate"
        result, err = run_regression(rows)
        return results_response(result, err, rows)
    end
    return grid_response(rows)
end

function handle_calculate(rows)::HTTP.Response
    result, err = run_regression(rows)
    return results_response(result, err, rows)
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
            return handle_calculate(get_rows(qs))
        end
    end
    return HTTP.Response(404; body = "Not Found")
end

HTTP.serve(handler, "127.0.0.1", 8080)
