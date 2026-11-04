# src/preprocess.jl - Data Cleaning and Preprocessing module (13-step pipeline, Weka-style).
# Implements course requirement III: Data Cleaning and Preprocessing.

module Preprocessing

export parse_cell, mean_of, quantile_inc, iqr_outliers, impute_rolling_sequential,
       preprocess, ValidationCheck, PreprocessReport, MISSING_TOKENS

# Standard missing value tokens (case-insensitive, trimmed).
const MISSING_TOKENS = Set(["", "?", "na", "n/a", "nan", "null", "none", "-"])

"""
Step 5, 7, 10: Parse a single cell value.
Returns (value, was_invalid):
- Missing tokens -> (missing, false)
- Valid numbers -> (Float64, false)
- Decimal commas (e.g. "3,5") are normalized to "3.5" -> (3.5, false)
- Unparseable text, Inf, NaN -> (missing, true)
"""
function parse_cell(raw)::Tuple{Union{Float64, Missing}, Bool}
    raw === missing && return (missing, false)
    raw === nothing && return (missing, false)
    if raw isa Real
        return isfinite(raw) ? (Float64(raw), false) : (missing, true)
    end
    s = lowercase(strip(string(raw)))
    s in MISSING_TOKENS && return (missing, false)
    if occursin(',', s) && !occursin('.', s)
        s = replace(s, ',' => '.')
    end
    v = tryparse(Float64, s)
    (v === nothing || !isfinite(v)) && return (missing, true)
    return (v, false)
end

"""
Step 8: Arithmetic mean of a numeric vector (used for global column mean imputation).
"""
function mean_of(v::AbstractVector{<:Real})::Float64
    isempty(v) && throw(ArgumentError("Cannot compute mean of an empty vector"))
    return sum(v) / length(v)
end

"""
Step 8: Sequential / Rolling neighboring mean & linear interpolation for time-series / ordered data.
- Evaluates immediate neighboring valid rows (prior and subsequent) relative to missing index.
- Computes linear interpolation between valid neighbors.
- Handles edge cases (leading/trailing missing values) by falling back to boundary filling (backward/forward fill).
"""
function impute_rolling_sequential(vals::AbstractVector)::Vector{Float64}
    n = length(vals)
    n == 0 && return Float64[]

    valid_indices = [i for i in 1:n if !ismissing(vals[i])]
    if isempty(valid_indices)
        throw(ArgumentError("All values in column are missing; cannot interpolate"))
    end

    result = zeros(Float64, n)
    for i in 1:n
        if !ismissing(vals[i])
            result[i] = Float64(vals[i])
        else
            prev_idx = nothing
            for j in (i - 1):-1:1
                if !ismissing(vals[j])
                    prev_idx = j
                    break
                end
            end

            next_idx = nothing
            for j in (i + 1):n
                if !ismissing(vals[j])
                    next_idx = j
                    break
                end
            end

            if prev_idx !== nothing && next_idx !== nothing
                # Local linear interpolation between prior and subsequent valid neighbors
                y0 = Float64(vals[prev_idx])
                y1 = Float64(vals[next_idx])
                frac = (i - prev_idx) / (next_idx - prev_idx)
                result[i] = y0 + frac * (y1 - y0)
            elseif prev_idx !== nothing
                # Trailing edge: forward-fill from nearest prior neighbor
                result[i] = Float64(vals[prev_idx])
            elseif next_idx !== nothing
                # Leading edge: backward-fill from nearest subsequent neighbor
                result[i] = Float64(vals[next_idx])
            else
                throw(ArgumentError("Cannot interpolate missing value at index $i"))
            end
        end
    end
    return result
end

"""
Step 9: Excel-compatible QUARTILE.INC implementation.
h = (n - 1) * p + 1
Q = sorted[lo] + (h - lo) * (sorted[hi] - sorted[lo])
"""
function quantile_inc(sorted::AbstractVector{<:Real}, p::Real)::Float64
    n = length(sorted)
    n == 0 && throw(ArgumentError("Cannot compute quantile of an empty vector"))
    n == 1 && return Float64(sorted[1])
    h = (n - 1) * p + 1.0
    lo = floor(Int, h)
    hi = min(lo + 1, n)
    lo = max(1, min(lo, n))
    hi = max(1, min(hi, n))
    return sorted[lo] + (h - lo) * (sorted[hi] - sorted[lo])
end

"""
Step 9: Identify outlier indices using the IQR rule (Q1 - 1.5*IQR ... Q3 + 1.5*IQR).
Returns 1-based row indexes of values outside this range.
"""
function iqr_outliers(v::AbstractVector{<:Real})::Vector{Int}
    isempty(v) && return Int[]
    s = sort(Float64.(v))
    q1 = quantile_inc(s, 0.25)
    q3 = quantile_inc(s, 0.75)
    iqr = q3 - q1
    lower_bound = q1 - 1.5 * iqr
    upper_bound = q3 + 1.5 * iqr
    return [k for (k, x) in enumerate(v) if x < lower_bound || x > upper_bound]
end

struct ValidationCheck
    name::String
    passed::Bool
    detail::String
end

struct PreprocessReport
    rows_before::Int
    rows_after::Int
    column_types::Vector{String}
    missing_x::Int
    missing_y::Int
    imputed_x::Int
    imputed_y::Int
    duplicates_removed::Int
    invalid_entries::Int
    outliers_x::Vector{Int}
    outliers_y::Vector{Int}
    transform::Symbol
    reasons::Vector{String}
    validation::Vector{ValidationCheck}
    all_passed::Bool
    imputed_cells::Set{Tuple{Int, Symbol}} # (row_idx_in_cleaned, :x or :y)
    outlier_rows::Set{Int}                 # row indices in cleaned data that are outliers
    error_message::Union{Nothing, String}
    x_mean::Float64
    y_mean::Float64
    missing_strategy::Symbol
end

"""
Step 1 to 13: Full Data Cleaning and Preprocessing Pipeline.
Runs steps in exact order:
1. Parse and count types, detect invalid entries
2. Drop blank rows (where both X and Y are missing)
3. Count missing in X and Y
4. Remove exact duplicate (X, Y) pairs (keeping first)
5. Handle missing values: Global Average (default), Rolling / Sequential interpolation, or Drop rows
6. Identify potential outliers with IQR rule (flag only by default, remove if requested)
7. Optional transform: :none, :normalize, :standardize, :log
8. Validate dataset: no missing/NaN/Inf, no duplicates, at least 2 rows, X not constant
"""
function preprocess(
    rawx::AbstractVector,
    rawy::AbstractVector;
    missing_strategy::Symbol = :mean,       # :mean/:global, :rolling/:sequential, or :drop
    remove_duplicates::Bool = true,         # true or false
    outliers_strategy::Symbol = :flag,      # :flag or :remove
    transform::Symbol = :none,              # :none, :normalize, :standardize, :log
    column_names::Vector{String} = ["X", "Y"]
)::Tuple{Vector{Float64}, Vector{Float64}, PreprocessReport}
    n_orig = length(rawx)
    length(rawy) == n_orig || throw(ArgumentError("X and Y must have the same length"))
    rows_before = n_orig

    # Step 1, 2, 5, 7, 10: Parse each cell and track invalid entries
    parsed_x = Vector{Union{Float64, Missing}}(undef, n_orig)
    parsed_y = Vector{Union{Float64, Missing}}(undef, n_orig)
    invalid_x_count = 0
    invalid_y_count = 0
    reasons = String[]

    for i in 1:n_orig
        vx, inv_x = parse_cell(rawx[i])
        vy, inv_y = parse_cell(rawy[i])
        parsed_x[i] = vx
        parsed_y[i] = vy
        if inv_x
            invalid_x_count += 1
            push!(reasons, "Row $i: invalid non-numeric entry '$(rawx[i])' in X treated as missing")
        end
        if inv_y
            invalid_y_count += 1
            push!(reasons, "Row $i: invalid non-numeric entry '$(rawy[i])' in Y treated as missing")
        end
    end
    invalid_entries = invalid_x_count + invalid_y_count

    # Step 6: Drop rows where both X and Y are missing (no information)
    RowType = NamedTuple{(:orig_idx, :x, :y), Tuple{Int, Union{Float64, Missing}, Union{Float64, Missing}}}
    initial_rows = RowType[(orig_idx = i, x = parsed_x[i], y = parsed_y[i]) for i in 1:n_orig]
    active_rows = RowType[]
    for r in initial_rows
        if ismissing(r.x) && ismissing(r.y)
            push!(reasons, "Row $(r.orig_idx): dropped because both X and Y are missing (no information)")
        else
            push!(active_rows, r)
        end
    end

    # Step 3: Count missing values in X and Y
    missing_x = count(r -> ismissing(r.x), active_rows)
    missing_y = count(r -> ismissing(r.y), active_rows)

    # Step 4: Remove exact duplicate (X, Y) records (keeping the first occurrence)
    duplicates_removed = 0
    if remove_duplicates
        seen_pairs = Set{Tuple{Any, Any}}()
        dedup_rows = RowType[]
        for r in active_rows
            pair = (r.x, r.y)
            if pair in seen_pairs
                duplicates_removed += 1
                push!(reasons, "Row $(r.orig_idx): duplicate row removed")
            else
                push!(seen_pairs, pair)
                push!(dedup_rows, r)
            end
        end
        active_rows = dedup_rows
    end

    # Step 8: Handle missing values
    known_x = [r.x for r in active_rows if !ismissing(r.x)]
    known_y = [r.y for r in active_rows if !ismissing(r.y)]

    if isempty(known_x)
        throw(ArgumentError("All values in column X are missing; no imputation possible"))
    end
    if isempty(known_y)
        throw(ArgumentError("All values in column Y are missing; no imputation possible"))
    end

    xbar = mean_of(Float64.(known_x))
    ybar = mean_of(Float64.(known_y))

    imputed_x = 0
    imputed_y = 0
    imputed_cells = Set{Tuple{Int, Symbol}}()
    CleanRowType = NamedTuple{(:orig_idx, :x, :y), Tuple{Int, Float64, Float64}}
    cleaned_rows = CleanRowType[]

    norm_strategy = if missing_strategy in (:rolling, :sequential)
        :rolling
    elseif missing_strategy in (:drop, :remove)
        :drop
    else
        :global
    end

    if norm_strategy == :global
        # Method 1: Global Average (Column Mean)
        for r in active_rows
            cx = r.x
            cy = r.y
            was_imp_x = false
            was_imp_y = false
            if ismissing(cx)
                cx = xbar
                imputed_x += 1
                was_imp_x = true
                push!(reasons, "Row $(r.orig_idx): imputed missing X with global mean $(round(xbar, digits=4))")
            end
            if ismissing(cy)
                cy = ybar
                imputed_y += 1
                was_imp_y = true
                push!(reasons, "Row $(r.orig_idx): imputed missing Y with global mean $(round(ybar, digits=4))")
            end
            push!(cleaned_rows, (orig_idx = r.orig_idx, x = Float64(cx), y = Float64(cy)))
            idx_now = length(cleaned_rows)
            was_imp_x && push!(imputed_cells, (idx_now, :x))
            was_imp_y && push!(imputed_cells, (idx_now, :y))
        end
    elseif norm_strategy == :rolling
        # Method 2: Rolling / Sequential (Neighboring Mean / Linear Interpolation)
        rx = impute_rolling_sequential([r.x for r in active_rows])
        ry = impute_rolling_sequential([r.y for r in active_rows])
        for (i, r) in enumerate(active_rows)
            was_imp_x = ismissing(r.x)
            was_imp_y = ismissing(r.y)
            if was_imp_x
                imputed_x += 1
                push!(reasons, "Row $(r.orig_idx): imputed missing X using rolling sequential interpolation $(round(rx[i], digits=4))")
            end
            if was_imp_y
                imputed_y += 1
                push!(reasons, "Row $(r.orig_idx): imputed missing Y using rolling sequential interpolation $(round(ry[i], digits=4))")
            end
            push!(cleaned_rows, (orig_idx = r.orig_idx, x = rx[i], y = ry[i]))
            idx_now = length(cleaned_rows)
            was_imp_x && push!(imputed_cells, (idx_now, :x))
            was_imp_y && push!(imputed_cells, (idx_now, :y))
        end
    elseif norm_strategy == :drop
        for r in active_rows
            if ismissing(r.x) || ismissing(r.y)
                push!(reasons, "Row $(r.orig_idx): dropped row containing missing value")
            else
                push!(cleaned_rows, (orig_idx = r.orig_idx, x = Float64(r.x), y = Float64(r.y)))
            end
        end
    end

    clean_x = Float64[r.x for r in cleaned_rows]
    clean_y = Float64[r.y for r in cleaned_rows]

    # Step 9: Identify potential outliers (IQR rule)
    outliers_x = iqr_outliers(clean_x)
    outliers_y = iqr_outliers(clean_y)
    all_outliers = sort(unique(vcat(outliers_x, outliers_y)))
    outlier_rows = Set{Int}(all_outliers)

    if outliers_strategy == :remove && !isempty(all_outliers)
        kept_cleaned = typeof(cleaned_rows[1])[]
        new_imputed = Set{Tuple{Int, Symbol}}()
        for (i, r) in enumerate(cleaned_rows)
            if i in outlier_rows
                push!(reasons, "Row $(r.orig_idx): removed outlier (X=$(r.x), Y=$(r.y))")
            else
                push!(kept_cleaned, r)
                new_idx = length(kept_cleaned)
                (i, :x) in imputed_cells && push!(new_imputed, (new_idx, :x))
                (i, :y) in imputed_cells && push!(new_imputed, (new_idx, :y))
            end
        end
        cleaned_rows = kept_cleaned
        imputed_cells = new_imputed
        clean_x = Float64[r.x for r in cleaned_rows]
        clean_y = Float64[r.y for r in cleaned_rows]
        outliers_x = Int[]
        outliers_y = Int[]
        outlier_rows = Set{Int}()
    elseif outliers_strategy == :flag
        if !isempty(all_outliers)
            push!(reasons, "Potential outliers flagged: X rows $(outliers_x), Y rows $(outliers_y) (kept)")
        end
    else
        throw(ArgumentError("Unknown outliers_strategy: $outliers_strategy (expected :flag or :remove)"))
    end

    # Step 11: Transform variables when requested
    if transform == :normalize
        min_x, max_x = isempty(clean_x) ? (0.0, 0.0) : (minimum(clean_x), maximum(clean_x))
        span_x = max_x - min_x
        span_x > 0 && (clean_x = (clean_x .- min_x) ./ span_x)

        min_y, max_y = isempty(clean_y) ? (0.0, 0.0) : (minimum(clean_y), maximum(clean_y))
        span_y = max_y - min_y
        span_y > 0 && (clean_y = (clean_y .- min_y) ./ span_y)
        push!(reasons, "Normalized X and Y to [0, 1] range")
    elseif transform == :standardize
        if !isempty(clean_x)
            mx = mean_of(clean_x)
            sdx = length(clean_x) >= 2 ? sqrt(sum((x - mx)^2 for x in clean_x) / (length(clean_x) - 1)) : 0.0
            sdx > 0 && (clean_x = (clean_x .- mx) ./ sdx)
        end
        if !isempty(clean_y)
            my = mean_of(clean_y)
            sdy = length(clean_y) >= 2 ? sqrt(sum((y - my)^2 for y in clean_y) / (length(clean_y) - 1)) : 0.0
            sdy > 0 && (clean_y = (clean_y .- my) ./ sdy)
        end
        push!(reasons, "Standardized X and Y to z-scores")
    elseif transform == :log
        for (i, r) in enumerate(cleaned_rows)
            if clean_x[i] <= 0
                throw(ArgumentError("Row $(r.orig_idx): value $(clean_x[i]) in X <= 0 cannot be log-transformed"))
            end
            if clean_y[i] <= 0
                throw(ArgumentError("Row $(r.orig_idx): value $(clean_y[i]) in Y <= 0 cannot be log-transformed"))
            end
        end
        clean_x = log.(clean_x)
        clean_y = log.(clean_y)
        push!(reasons, "Applied natural log transform ln(v) to X and Y")
    elseif transform != :none
        throw(ArgumentError("Unknown transform: $transform (expected :none, :normalize, :standardize, or :log)"))
    end

    # Step 12: Validate the cleaned dataset
    validation = ValidationCheck[]

    # Check 1: No missing, NaN, or infinite values
    c1 = !isempty(clean_x) && all(isfinite, clean_x) && all(isfinite, clean_y)
    push!(validation, ValidationCheck(
        "No missing, NaN, or infinite values",
        c1,
        c1 ? "All $(length(clean_x)) values in X and Y are finite numbers" : "Missing, NaN, or infinite values found"
    ))

    # Check 2: No duplicate rows (if removal is on)
    if remove_duplicates
        pairs = [Tuple{Float64, Float64}((clean_x[i], clean_y[i])) for i in 1:length(clean_x)]
        c2 = length(unique(pairs)) == length(pairs)
        push!(validation, ValidationCheck(
            "No duplicate rows",
            c2,
            c2 ? "All $(length(clean_x)) rows are unique" : "Duplicate rows found in cleaned data"
        ))
    else
        push!(validation, ValidationCheck("No duplicate rows", true, "Duplicate removal disabled"))
    end

    # Check 3: At least 2 rows
    c3 = length(clean_x) >= 2
    push!(validation, ValidationCheck(
        "At least 2 rows",
        c3,
        c3 ? "Dataset has $(length(clean_x)) instances (minimum: 2)" : "Cleaned dataset has only $(length(clean_x)) row(s) (minimum required: 2)"
    ))

    # Check 4: X is not constant
    sxx = length(clean_x) >= 1 ? sum((x - mean_of(clean_x))^2 for x in clean_x) : 0.0
    c4 = sxx > 0.0
    push!(validation, ValidationCheck(
        "X is not constant",
        c4,
        c4 ? "X variance is positive (slope is defined)" : "All X values are identical; slope is undefined"
    ))

    all_passed = all(c -> c.passed, validation)
    rows_after = length(clean_x)
    col_types = ["Numeric", "Numeric"]

    report = PreprocessReport(
        rows_before,
        rows_after,
        col_types,
        missing_x,
        missing_y,
        imputed_x,
        imputed_y,
        duplicates_removed,
        invalid_entries,
        outliers_x,
        outliers_y,
        transform,
        reasons,
        validation,
        all_passed,
        imputed_cells,
        outlier_rows,
        nothing,
        xbar,
        ybar,
        norm_strategy,
    )

    return clean_x, clean_y, report
end

end # module
