# src/importer.jl - CSV / XLSX -> column names + value columns (Preprocess tab).

using CSV
using XLSX

const MAX_IMPORT_ROWS = 10_000

_to_str(v) = (v === nothing || v === missing) ? "" : string(v)

struct NonNumericInputError <: Exception
    row::Int
    col_name::String
    value::String
end

function Base.showerror(io::IO, e::NonNumericInputError)
    print(io, "Row ", e.row, ": non-numeric value '", e.value, "' in column '", e.col_name, "'")
end

struct AttributeStats
    name::String
    total_count::Int
    missing_count::Int
    missing_pct::Float64
    distinct_count::Int
    is_numeric::Bool
    min_val::Union{Float64, Nothing}
    max_val::Union{Float64, Nothing}
    mean_val::Union{Float64, Nothing}
    stddev_val::Union{Float64, Nothing}
end

function compute_attribute_stats(values::Vector{String}, col_name::String)::AttributeStats
    total = length(values)
    missing_count = count(v -> strip(v) == "", values)
    missing_pct = total > 0 ? (missing_count / total) * 100.0 : 0.0
    non_empty = [strip(v) for v in values if strip(v) != ""]
    distinct_count = length(unique(non_empty))

    nums = Float64[]
    all_num = !isempty(non_empty)
    for s in non_empty
        val = tryparse(Float64, s)
        if val !== nothing
            push!(nums, val)
        else
            all_num = false
        end
    end

    if all_num && !isempty(nums)
        n = length(nums)
        mn = minimum(nums)
        mx = maximum(nums)
        avg = sum(nums) / n
        sdev = n >= 2 ? sqrt(sum((x - avg)^2 for x in nums) / (n - 1)) : 0.0
        return AttributeStats(col_name, total, missing_count, missing_pct, distinct_count, true, mn, mx, avg, sdev)
    else
        return AttributeStats(col_name, total, missing_count, missing_pct, distinct_count, false, nothing, nothing, nothing, nothing)
    end
end

function _csv_columns(body::String; first_row_header::Bool=true)::Tuple{Vector{String},Vector{Vector{String}}}
    f = CSV.File(IOBuffer(body); header=first_row_header)
    ks = collect(propertynames(f))
    ncols = length(ks)
    names = first_row_header ? [String(k) for k in ks] : ["Column " * string(i) for i in 1:ncols]
    cols = [String[] for _ in 1:ncols]
    for r in f
        for (i, k) in enumerate(ks)
            val = getproperty(r, k)
            push!(cols[i], _to_str(val))
        end
    end
    return names, cols
end

function _xlsx_sheetnames(bytes::Vector{UInt8})::Vector{String}
    xf = XLSX.readxlsx(IOBuffer(bytes))
    return String[String(s) for s in XLSX.sheetnames(xf)]
end

function _xlsx_columns(bytes::Vector{UInt8}; first_row_header::Bool=true, sheet_name::String="")::Tuple{Vector{String},Vector{Vector{String}},String}
    xf = XLSX.readxlsx(IOBuffer(bytes))
    avail_sheets = XLSX.sheetnames(xf)
    isempty(avail_sheets) && return String[], Vector{Vector{String}}(), ""
    chosen_sheet = ""
    if !isempty(sheet_name) && (sheet_name in avail_sheets)
        chosen_sheet = sheet_name
    elseif "Data" in avail_sheets
        chosen_sheet = "Data"
    else
        chosen_sheet = String(first(avail_sheets))
    end
    ws = XLSX.getsheet(xf, chosen_sheet)
    dim = XLSX.get_dimension(ws)
    dim === nothing && return String[], Vector{Vector{String}}(), chosen_sheet
    last_row = Int(XLSX.row_number(dim.stop))
    last_row == 0 && return String[], Vector{Vector{String}}(), chosen_sheet

    rows = Vector{Vector{String}}()
    for r in 1:last_row
        rowvals = [_to_str(x) for x in vec(XLSX.getdata(ws, r, :))]
        push!(rows, rowvals)
    end
    isempty(rows) && return String[], Vector{Vector{String}}(), chosen_sheet

    ncols = maximum(length(r) for r in rows)
    for r in rows
        while length(r) < ncols
            push!(r, "")
        end
    end

    if first_row_header
        names = [String(x) for x in rows[1]]
        data_rows = length(rows) > 1 ? rows[2:end] : Vector{Vector{String}}()
    else
        names = ["Column " * string(i) for i in 1:ncols]
        data_rows = rows
    end

    cols = [String[] for _ in 1:ncols]
    for rowvals in data_rows
        for i in 1:ncols
            push!(cols[i], rowvals[i])
        end
    end
    return names, cols, chosen_sheet
end

function read_upload_columns(data, filename::String; first_row_header::Bool=true, sheet_name::String="")
    names, cols, _, _ = read_upload_columns_with_sheet(data, filename; first_row_header = first_row_header, sheet_name = sheet_name)
    return names, cols
end

function read_upload_columns_with_sheet(data, filename::String; first_row_header::Bool=true, sheet_name::String="")
    name_l = lowercase(String(filename))
    if endswith(name_l, ".xlsx")
        bytes = data isa Vector{UInt8} ? data : Vector{UInt8}(codeunits(String(data)))
        sheets = _xlsx_sheetnames(bytes)
        names, cols, chosen = _xlsx_columns(bytes; first_row_header = first_row_header, sheet_name = sheet_name)
        return names, cols, sheets, chosen
    elseif endswith(name_l, ".csv")
        str = data isa String ? data : String(copy(data))
        names, cols = _csv_columns(str; first_row_header = first_row_header)
        return names, cols, String[], ""
    end
    throw(ErrorException("Unsupported file type: " * String(filename)))
end

function count_rows(cols::Vector{Vector{String}})::Int
    isempty(cols) && return 0
    return minimum(length(c) for c in cols)
end

function check_row_cap(n::Int)::Nothing
    if n > MAX_IMPORT_ROWS
        throw(ErrorException("Import blocked: file has " * string(n) * " rows (maximum allowed: " * string(MAX_IMPORT_ROWS) * ")"))
    end
    return nothing
end

function extract_selected_columns(
    cols::Vector{Vector{String}},
    col_names::Vector{String},
    x_idx::Int,
    y_idx::Int,
    first_row_header::Bool=true
)::Tuple{Vector{Tuple{String,String}}, Int}
    n = count_rows(cols)
    (1 <= x_idx <= length(cols)) || throw(ArgumentError("Invalid X column index: $x_idx"))
    (1 <= y_idx <= length(cols)) || throw(ArgumentError("Invalid Y column index: $y_idx"))

    x_col_name = col_names[x_idx]
    y_col_name = col_names[y_idx]

    rows = Tuple{String,String}[]
    skipped_missing = 0

    for i in 1:n
        x_str = strip(cols[x_idx][i])
        y_str = strip(cols[y_idx][i])
        file_row_num = first_row_header ? (i + 1) : i

        if x_str == "" || y_str == ""
            skipped_missing += 1
            continue
        end

        if tryparse(Float64, x_str) === nothing
            throw(NonNumericInputError(file_row_num, x_col_name, x_str))
        end
        if tryparse(Float64, y_str) === nothing
            throw(NonNumericInputError(file_row_num, y_col_name, y_str))
        end

        push!(rows, (x_str, y_str))
    end

    return rows, skipped_missing
end
