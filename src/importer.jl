# src/importer.jl - CSV / XLSX -> column names + value columns (Preprocess tab).

using CSV
using XLSX

const MAX_IMPORT_ROWS = 10_000

_to_str(v) = (v === nothing || v === missing) ? "" : string(v)

function _csv_columns(body::String; first_row_header::Bool=true)::Tuple{Vector{String},Vector{Vector{String}}}
    f = CSV.File(IOBuffer(body); header=first_row_header)
    rows = CSV.FileRow[]
    for r in f
        push!(rows, r)
    end
    isempty(rows) && return String[], Vector{Vector{String}}()
    ks = collect(keys(rows[1]))
    cols = [String[] for _ in ks]
    for r in rows
        for (i, k) in enumerate(ks)
            push!(cols[i], _to_str(get(r, k, nothing)))
        end
    end
    return [String(k) for k in ks], cols
end

function _xlsx_columns(bytes::Vector{UInt8}; first_row_header::Bool=true, sheet_name::String="Data")::Tuple{Vector{String},Vector{Vector{String}}}
    xf = XLSX.readxlsx(IOBuffer(bytes))
    ws = XLSX.getsheet(xf, sheet_name)
    dim = XLSX.get_dimension(ws)
    last_row = dim === nothing ? 0 : Int(XLSX.row_number(dim.stop))
    rows = Vector{Vector{String}}()
    for r in 1:last_row
        rowvals = [_to_str(x) for x in vec(XLSX.getdata(ws, r, :))]
        push!(rows, rowvals)
    end
    header_vals = isempty(rows) ? String[] : rows[1]
    if !first_row_header && !isempty(rows)
        header_vals = [string(i) for i in 1:length(header_vals)]
    end
    data_rows = isempty(rows) ? Vector{Vector{String}}[] : rows[2:end]
    names = String[]
    cols = Vector{Vector{String}}()
    ncols = length(header_vals)
    names = [String(x) for x in header_vals]
    cols = [String[] for _ in 1:ncols]
    for rowvals in data_rows
        for (i, n) in enumerate(names)
            i <= length(rowvals) || break
            push!(cols[i], String(rowvals[i]))
        end
    end
    return names, cols
end

function read_upload_columns(data, filename::String; first_row_header::Bool=true, sheet_name::String="Data")
    name_l = lowercase(String(filename))
    if endswith(name_l, ".xlsx")
        return _xlsx_columns(Vector{UInt8}(codeunits(String(data))); first_row_header = first_row_header, sheet_name = sheet_name)
    elseif endswith(name_l, ".csv")
        return _csv_columns(String(data); first_row_header = first_row_header)
    end
    throw(ErrorException("Unsupported file type: " * String(filename)))
end

function count_rows(cols::Vector{Vector{String}})::Int
    isempty(cols) && return 0
    return length(cols[1])
end

function check_row_cap(n::Int)::Nothing
    if n > MAX_IMPORT_ROWS
        throw(ErrorException("Import blocked: file has " * string(n) * " rows (maximum allowed: " * string(MAX_IMPORT_ROWS) * ")"))
    end
    return nothing
end
