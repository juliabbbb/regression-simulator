# src/render.jl - HTML, table, formula, and page generation (pure CSS tabs, no JS).

function html_escape(s::AbstractString)::String
    s = replace(s, '&' => "&amp;")
    s = replace(s, '<' => "&lt;")
    s = replace(s, '>' => "&gt;")
    s = replace(s, '"' => "&quot;")
    s = replace(s, '\'' => "&#39;")
    return s
end

function fmt(v::Union{Float64,Int,Nothing}, digits::Int = 4)::String
    v === nothing && return "&mdash;"
    if isnan(v) || isinf(v)
        return "N/A"
    end
    # Display rounding only; calculations always keep full Float64 precision.
    rounded = round(v, digits = digits)
    # Normalize negative zero (e.g. -8.88e-16 rounds to -0.0) so it prints "0".
    rounded == 0 && return "0"
    s = string(rounded)
    if occursin('.', s)
        while endswith(s, '0')
            s = s[1:end - 1]
        end
        if endswith(s, '.')
            s = s[1:end - 1]
        end
    end
    if isempty(s)
        s = "0"
    end
    if endswith(s, ".0")
        s = s[1:end - 2]
    end
    return s
end

function render_grid_panel(rows; token::String = "", decimals::Int = 4)::String
    t = IOBuffer()
    print(t, """
<section class="tab-panel" id="panel-data" role="tabpanel">
  <div class="panel-header">
    <h2>Data</h2>
  </div>
  <div class="panel-body">
    <p class="panel-intro">Enter X and Y per row. Blank rows are ignored. Press Enter to calculate.</p>
    <form method="post" action="/rows" class="grid-form">
      <input type="hidden" name="token" value="$(html_escape(token))" />
      <input type="submit" name="action" value="calculate" class="visually-hidden" tabindex="-1" aria-hidden="true" />
      <table class="grid">
        <thead>
          <tr>
            <th class="col-num">#</th>
            <th class="col-x">X</th>
            <th class="col-y">Y</th>
            <th class="col-actions"></th>
          </tr>
        </thead>
        <tbody>
""")
    for (i, row) in enumerate(rows)
        row_html = """
        <tr class="grid-row">
          <td class="col-num">$(i)</td>
          <td class="col-x"><input type="text" name="x_$(i)" id="x_$(i)" value="$(html_escape(row[1]))" placeholder="X" autocomplete="off" /></td>
          <td class="col-y"><input type="text" name="y_$(i)" id="y_$(i)" value="$(html_escape(row[2]))" placeholder="Y" autocomplete="off" /></td>
          <td class="col-actions"><input type="submit" name="rm_$(i)" value="$(i)" class="btn-remove" title="Remove row $(i)" /></td>
        </tr>
"""
        print(t, row_html)
    end
    decimals_options = IOBuffer()
    for d in 2:8
        print(decimals_options, "        <option value=\"", d, "\"", d == decimals ? " selected" : "", ">", d, "</option>\n")
    end
    print(t, """
      </tbody>
    </table>
    <div class="grid-actions">
      <input type="submit" name="action" value="add" class="btn-add" />
      <input type="submit" name="action" value="calculate" class="btn-add" />
      <label for="decimals" class="decimals-label">Decimals:</label>
      <select name="decimals" id="decimals" class="select-decimals">
$(String(take!(decimals_options)))      </select>
      <span class="grid-hint">Press Enter to run the calculation.</span>
    </div>
    </form>
</section>
""")
    return String(take!(t))
end

function render_calculation_panel(result; decimals::Int = 4)::String
    if result === nothing
        return """
<section class="tab-panel" id="panel-calculation" role="tabpanel">
  <div class="panel-header">
    <h2>Calculation</h2>
  </div>
  <div class="panel-body">
    <p class="panel-intro">Run a calculation to see the step-by-step table, formulas and equation.</p>
  </div>
</section>
"""
    end
    t = IOBuffer()
    f = v -> fmt(v, decimals)
    print(t, "<section class=\"tab-panel\" id=\"panel-calculation\" role=\"tabpanel\">\n")
    print(t, "  <div class=\"panel-header\">\n")
    print(t, "    <h2>Calculation</h2>\n")
    print(t, "  </div>\n")
    print(t, "  <div class=\"panel-body\">\n")
    print(t, "    <p class=\"panel-note\">n = ", result.n, " &middot; x&#x0304; = ", f(result.xbar), " &middot; &#x0233; = ", f(result.ybar), "</p>\n")
    print(t, "    <table class=\"calc-table\">\n")
    print(t, "      <thead>\n")
    print(t, "        <tr>\n")
    print(t, "          <th>X</th>\n")
    print(t, "          <th>Y</th>\n")
    print(t, "          <th>x &#x2212; x&#x0304;</th>\n")
    print(t, "          <th>y &#x2212; &#x0233;</th>\n")
    print(t, "          <th>(x &#x2212; x&#x0304;)(y &#x2212; &#x0233;)</th>\n")
    print(t, "          <th>(x &#x2212; x&#x0304;)&#x00B2;</th>\n")
    print(t, "          <th>&#x0176;</th>\n")
    print(t, "        </tr>\n")
    print(t, "      </thead>\n")
    print(t, "      <tbody>\n")
    for i in eachindex(result.x)
        print(t, "        <tr>\n")
        print(t, "          <td>", f(result.x[i]), "</td>\n")
        print(t, "          <td>", f(result.y[i]), "</td>\n")
        print(t, "          <td>", f(result.dx[i]), "</td>\n")
        print(t, "          <td>", f(result.dy[i]), "</td>\n")
        print(t, "          <td>", f(result.dxdy[i]), "</td>\n")
        print(t, "          <td>", f(result.dx2[i]), "</td>\n")
        print(t, "          <td>", f(result.yhat[i]), "</td>\n")
        print(t, "        </tr>\n")
    end
    print(t, "      </tbody>\n")
    print(t, "      <tfoot>\n")
    print(t, "        <tr>\n")
    print(t, "          <td>&#x03A3;X = ", f(sum(result.x)), "</td>\n")
    print(t, "          <td>&#x03A3;Y = ", f(sum(result.y)), "</td>\n")
    print(t, "          <td>&#x03A3;(x &#x2212; x&#x0304;) = ", f(sum(result.dx)), "</td>\n")
    print(t, "          <td>&#x03A3;(y &#x2212; &#x0233;) = ", f(sum(result.dy)), "</td>\n")
    print(t, "          <td>&#x03A3;(x &#x2212; x&#x0304;)(y &#x2212; &#x0233;) = ", f(result.sxy), "</td>\n")
    print(t, "          <td>&#x03A3;(x &#x2212; x&#x0304;)&#x00B2; = ", f(result.sxx), "</td>\n")
    print(t, "          <td>&#x03A3;Predicted Y = ", f(sum(result.yhat)), "</td>\n")
    print(t, "        </tr>\n")
    print(t, "      </tfoot>\n")
    print(t, "    </table>\n")
    line_b = "b = &#x03A3;(x &#x2212; x&#x0304;)(y &#x2212; &#x0233;) / &#x03A3;(x &#x2212; x&#x0304;)&#x00B2; = " * f(result.sxy) * " / " * f(result.sxx) * " = " * f(result.b)
    line_a = "a = &#x0233; &#x2212; b&#183;x&#x0304; = " * f(result.ybar) * " &#x2212; (" * f(result.b) * ")(" * f(result.xbar) * ") = " * f(result.a)
    line_eq = "&#x0177; = " * f(result.a) * " + " * f(result.b) * "x"
    print(t, "    <div class=\"formula\">\n")
    print(t, "      <p><code>", line_b, "</code></p>\n")
    print(t, "      <p><code>", line_a, "</code></p>\n")
    print(t, "      <p class=\"equation\">", line_eq, "</p>\n")
    print(t, "    </div>\n")
    print(t, "    ", render_chart(result), "\n")
    print(t, "  </div>\n")
    print(t, "</section>\n")
    return String(take!(t))
end

"Percentage for the summary panel; NaN/Inf shows as N/A like the rest."
function _fmt_pct(v::Float64, decimals::Int)::String
    (isnan(v) || isinf(v)) && return "N/A"
    return fmt(v * 100.0, decimals) * "%"
end

function render_result_panel(
    result,
    error;
    decimals::Int = 4,
    predicted = nothing,
    predict_x::String = "",
    token::String = "",
    rows = Tuple{String,String}[],
)::String
    t = IOBuffer()
    print(t, "<section class=\"tab-panel\" id=\"panel-result\" role=\"tabpanel\">\n")
    print(t, "  <div class=\"panel-header\">\n")
    print(t, "    <h2>Result</h2>\n")
    print(t, "  </div>\n")
    print(t, "  <div class=\"panel-body\">\n")
    if error !== nothing
        print(t, "    <p class=\"error-text\">", html_escape(error), "</p>\n")
    end
    if result !== nothing
        equation = "&#x0177; = " * fmt(result.a, decimals) * " + " * fmt(result.b, decimals) * "x"
        print(t, "    <div class=\"summary\">\n")
        print(t, "      <div class=\"summary-title\">Summary</div>\n")
        print(t, "      <table class=\"summary-table\">\n")
        print(t, "        <tbody>\n")
        print(t, "          <tr><th>Equation</th><td class=\"num summary-eq\">", equation, "</td></tr>\n")
        print(t, "          <tr><th>Instances</th><td class=\"num\">", result.n, "</td></tr>\n")
        print(t, "          <tr><th>Correlation coefficient (r)</th><td class=\"num\">", fmt(result.r, decimals), "</td></tr>\n")
        print(t, "          <tr><th>Coefficient of determination (R&#x00B2;)</th><td class=\"num\">", fmt(result.r2, decimals), "</td></tr>\n")
        print(t, "          <tr><th>Standard error</th><td class=\"num\">", fmt(result.se, decimals), "</td></tr>\n")
        print(t, "          <tr><th>Mean absolute error (MAE)</th><td class=\"num\">", fmt(result.mae, decimals), "</td></tr>\n")
        print(t, "          <tr><th>Root mean squared error (RMSE)</th><td class=\"num\">", fmt(result.rmse, decimals), "</td></tr>\n")
        print(t, "          <tr><th>Relative absolute error (RAE)</th><td class=\"num\">", _fmt_pct(result.rae, decimals), "</td></tr>\n")
        print(t, "          <tr><th>Root relative squared error (RRSE)</th><td class=\"num\">", _fmt_pct(result.rrse, decimals), "</td></tr>\n")
        print(t, "        </tbody>\n")
        print(t, "      </table>\n")
        print(t, "    </div>\n")

        print(t, "    <form method=\"post\" action=\"/predict\" class=\"predict-form\">\n")
        print(t, "      <input type=\"hidden\" name=\"token\" value=\"", html_escape(token), "\" />\n")
        print(t, "      <input type=\"hidden\" name=\"decimals\" value=\"", decimals, "\" />\n")
        for (i, row) in enumerate(rows)
            print(t, "      <input type=\"hidden\" name=\"x_", i, "\" value=\"", html_escape(row[1]), "\" />\n")
            print(t, "      <input type=\"hidden\" name=\"y_", i, "\" value=\"", html_escape(row[2]), "\" />\n")
        end
        print(t, "      <label for=\"predict-x\" class=\"predict-label\">Predict Y for X:</label>\n")
        print(t, "      <input type=\"text\" id=\"predict-x\" name=\"predict_x\" class=\"predict-input\" value=\"", html_escape(predict_x), "\" autocomplete=\"off\" />\n")
        print(t, "      <input type=\"submit\" value=\"Predict\" class=\"btn btn-add\" />\n")
        print(t, "    </form>\n")
        if predicted !== nothing
            print(t, "    <p class=\"predict-answer\">&#x0177; = <strong>", fmt(predicted, decimals), "</strong></p>\n")
        end
    end
    print(t, "  </div>\n")
    print(t, "</section>\n")
    return String(take!(t))
end

"Numeric values of a column, ignoring blanks and non-numeric cells (for the histogram)."
function _numeric_values(values::Vector{String})::Vector{Float64}
    nums = Float64[]
    for s in values
        t = strip(s)
        isempty(t) && continue
        v = tryparse(Float64, t)
        v === nothing || push!(nums, v)
    end
    return nums
end

function render_preprocess_panel(u, tok::String; error::Union{Nothing,String} = nothing, skipped::Int = 0, decimals::Int = 4)::String
    t = IOBuffer()
    print(t, """<section class="tab-panel" id="panel-preprocess" role="tabpanel">
  <div class="panel-header">
    <h2>Preprocess</h2>
  </div>
  <div class="panel-body">
    <p class="panel-intro">Upload a .csv or .xlsx file, pick X and Y attributes, then apply to the grid.</p>
    <form method="post" action="/upload" enctype="multipart/form-data" class="upload-form">
      <input type="hidden" name="token" value="$(html_escape(tok))" />
      <input type="hidden" name="decimals" value="$(decimals)" />
      <input type="hidden" name="upload_submitted" value="1" />
      <div class="upload-controls">
        <div class="upload-field">
          <label for="upload-file" class="upload-label">Choose file (.csv, .xlsx):</label>
          <input type="file" id="upload-file" name="file" accept=".csv,.xlsx" required class="input-file" />
        </div>
        <div class="upload-checkbox">
          <label>
            <input type="checkbox" name="first_row_header" value="1" checked />
            First row is header
          </label>
        </div>
        <div class="upload-actions">
          <input type="submit" value="Upload File" class="btn btn-add" />
        </div>
      </div>
    </form>
""")
    if error !== nothing
        print(t, "    <p class=\"error-text\">", html_escape(error), "</p>\n")
    end
    if skipped > 0
        print(t, "    <div class=\"panel-note\">Skipped ", skipped, " row", (skipped == 1 ? "" : "s"), " with missing or empty cells.</div>\n")
    end

    if u === nothing
        print(t, """    <div class="panel-note">No file loaded. Upload a .csv or .xlsx file to pick attributes.</div>
""")
    else
        rel_name = isempty(u.current_sheet) ? u.filename : (u.filename * " (" * u.current_sheet * ")")
        n_inst = count_rows(u.values)
        n_attr = length(u.columns)

        print(t, """    <div class="relation-panel">
      <div class="relation-title">Current relation</div>
      <div class="relation-details">
        <span class="relation-item"><strong>Relation:</strong> <span class="relation-val">$(html_escape(rel_name))</span></span>
        <span class="relation-item"><strong>Instances:</strong> <span class="relation-val num">$(n_inst)</span></span>
        <span class="relation-item"><strong>Attributes:</strong> <span class="relation-val num">$(n_attr)</span></span>
      </div>
""")
        if !isempty(u.sheet_names) && length(u.sheet_names) > 0
            print(t, """      <form method="post" action="/rows" class="sheet-form">
        <input type="hidden" name="token" value="$(html_escape(tok))" />
        <input type="hidden" name="decimals" value="$(decimals)" />
        <label for="sheet-select" class="sheet-label">Sheet:</label>
        <select name="sheet" id="sheet-select" class="select-sheet">
""")
            for s in u.sheet_names
                sel = (s == u.current_sheet) ? " selected" : ""
                print(t, """          <option value="$(html_escape(s))"$(sel)>$(html_escape(s))</option>\n""")
            end
            print(t, """        </select>
        <button type="submit" name="action" value="change_sheet" class="btn btn-secondary">Load Sheet</button>
      </form>
""")
        end
        print(t, "    </div>\n\n")

        cur_attr = (1 <= u.selected_attr <= length(u.columns)) ? u.selected_attr : 1
        st = compute_attribute_stats(u.values[cur_attr], u.columns[cur_attr])
        print(t, """    <div class="selected-attribute-panel">
      <div class="relation-title">Selected attribute</div>
      <table class="attr-stats-table">
        <tbody>
          <tr>
            <td class="stat-label">Name:</td>
            <td class="stat-val"><strong>$(html_escape(st.name))</strong></td>
            <td class="stat-label">Type:</td>
            <td class="stat-val">$(st.is_numeric ? "Numeric" : "Nominal")</td>
          </tr>
          <tr>
            <td class="stat-label">Missing:</td>
            <td class="stat-val">$(st.missing_count) ($(round(st.missing_pct, digits=1))%)</td>
            <td class="stat-label">Distinct:</td>
            <td class="stat-val num">$(st.distinct_count)</td>
          </tr>
""")
        if st.is_numeric
            print(t, """          <tr>
            <td class="stat-label">Min:</td>
            <td class="stat-val num">$(fmt(st.min_val, decimals))</td>
            <td class="stat-label">Max:</td>
            <td class="stat-val num">$(fmt(st.max_val, decimals))</td>
          </tr>
          <tr>
            <td class="stat-label">Mean:</td>
            <td class="stat-val num">$(fmt(st.mean_val, decimals))</td>
            <td class="stat-label">StdDev (n-1):</td>
            <td class="stat-val num">$(fmt(st.stddev_val, decimals))</td>
          </tr>
""")
        else
            print(t, """          <tr>
            <td class="stat-label">Min:</td>
            <td class="stat-val">&mdash;</td>
            <td class="stat-label">Max:</td>
            <td class="stat-val">&mdash;</td>
          </tr>
          <tr>
            <td class="stat-label">Mean:</td>
            <td class="stat-val">&mdash;</td>
            <td class="stat-label">StdDev (n-1):</td>
            <td class="stat-val">&mdash;</td>
          </tr>
""")
        end
        print(t, """        </tbody>
      </table>
""")
        if st.is_numeric
            print(t, "      ", render_histogram(_numeric_values(u.values[cur_attr])), "\n")
        end
        print(t, "    </div>\n\n")

        xname = (1 <= u.x_col <= length(u.columns)) ? html_escape(u.columns[u.x_col]) : "?"
        yname = (1 <= u.y_col <= length(u.columns)) ? html_escape(u.columns[u.y_col]) : "?"
        print(t, "    <div class=\"panel-note\">Selected attribute: X = " * xname * " &middot; Y = " * yname * "</div>\n")
        print(t, """    <form method="post" action="/select" class="attr-form">
      <input type="hidden" name="token" value="$(html_escape(tok))" />
      <input type="hidden" name="decimals" value="$(decimals)" />
      <table class="calc-table attr-table">
        <thead>
          <tr>
            <th style="width: 40px;">#</th>
            <th style="width: 50px;">X</th>
            <th style="width: 50px;">Y</th>
            <th>Attribute / Column</th>
            <th style="width: 80px;">Action</th>
          </tr>
        </thead>
        <tbody>
""")
        for i in 1:length(u.columns)
            col_esc = html_escape(u.columns[i])
            x_checked = (i == u.x_col) ? " checked" : ""
            y_checked = (i == u.y_col) ? " checked" : ""
            highlight_cls = (i == cur_attr) ? " attr-row-active" : ""
            print(t, """          <tr class="$(highlight_cls)">
            <td class="col-num">$(i)</td>
            <td style="text-align: center;">
              <input type="radio" name="x_col" value="$(i)" id="x_col_$(i)"$(x_checked) />
            </td>
            <td style="text-align: center;">
              <input type="radio" name="y_col" value="$(i)" id="y_col_$(i)"$(y_checked) />
            </td>
            <td>
              <label for="x_col_$(i)" class="attr-name">$(col_esc)</label>
            </td>
            <td style="text-align: center;">
              <button type="submit" formaction="/rows" name="attr_show" value="$(i)" class="btn btn-secondary">Show</button>
            </td>
          </tr>
""")
        end
        print(t, """        </tbody>
      </table>
      <div class="grid-actions attr-actions">
        <button type="submit" formaction="/rows" name="action" value="show" class="btn btn-secondary">Show Selection</button>
        <button type="submit" name="action" value="apply" class="btn btn-add">Apply to grid</button>
      </div>
    </form>
""")
    end
    print(t, """  </div>
</section>
""")
    return String(take!(t))
end

function render_page(
    rows,
    result,
    error,
    status::String,
    tab::String,
    token::String = "",
    upload = nothing;
    preprocess_error::Union{Nothing,String} = nothing,
    skipped_count::Int = 0,
    decimals::Int = 4,
    predicted = nothing,
    predict_x::String = "",
)::String
    grid_panel = render_grid_panel(rows; token = token, decimals = decimals)
    calc_panel = render_calculation_panel(result; decimals = decimals)
    result_panel = render_result_panel(result, error; decimals = decimals, predicted = predicted,
                                       predict_x = predict_x, token = token, rows = rows)
    preprocess_panel = render_preprocess_panel(upload, token; error = preprocess_error,
                                               skipped = skipped_count, decimals = decimals)

    checked_data = tab == "data" ? " checked" : ""
    checked_preprocess = tab == "preprocess" ? " checked" : ""
    checked_calculation = tab == "calculation" ? " checked" : ""
    checked_result = tab == "result" ? " checked" : ""

    status_html = replace(status, r"&#?[0-9A-Za-z]+;|\d+(?:\.\d+)?" => m -> startswith(m, "&") ? String(m) : "<span class=\"status-num\">" * String(m) * "</span>")
    status_bar_html = "<footer class=\"statusbar\">\n  <span class=\"status-badge\"></span>\n" * status_html * "</footer>\n</div>\n\n</body>\n</html>\n"

    return """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Simple Linear Regression Calculator</title>
<link rel="stylesheet" href="/static/style.css">
</head>
<body>
<div class="window">
<div class="titlebar">
  <span class="badge">&#x25A3;</span>
  <span class="title-text">Linear Regression Calculator</span>
  <span class="winbtn">_</span>
  <span class="winbtn">x</span>
</div>
<div class="menubar">
  <span class="menu-item">File</span>
  <span class="menu-item">Edit</span>
  <span class="menu-item">View</span>
  <span class="menu-item">Help</span>
</div>
<header class="app-header">
  <h1>Simple Linear Regression Calculator</h1>
  <p class="tagline">Weka-style &middot; b = SLOPE &middot; a = INTERCEPT &middot; r = CORREL &middot; R&#x00B2; = RSQ &middot; &#x0177; = FORECAST.LINEAR</p>
</header>

<input type="radio" name="tab" id="tab-data" value="data"$(checked_data)>
<input type="radio" name="tab" id="tab-preprocess" value="preprocess"$(checked_preprocess)>
<input type="radio" name="tab" id="tab-calculation" value="calculation"$(checked_calculation)>
<input type="radio" name="tab" id="tab-result" value="result"$(checked_result)>

<nav class="tabs" role="tablist">
  <label class="tab-label" for="tab-data">Data</label>
  <label class="tab-label" for="tab-preprocess">Preprocess</label>
  <label class="tab-label" for="tab-calculation">Calculation</label>
  <label class="tab-label" for="tab-result">Result</label>
</nav>

<div class="tab-panels">
$(grid_panel)
$(preprocess_panel)
$(calc_panel)
$(result_panel)
</div>

<div class="toolbar">
  <span class="tool-btn">A</span>
  <span class="tool-btn">&#x1F5BC;</span>
  <span class="tool-btn">&#x2665;</span>
  <span class="tool-btn">&#x2605;</span>
  <span class="tool-credit">Simple Linear Regression Calculator</span>
</div>

$(status_bar_html)
"""
end
