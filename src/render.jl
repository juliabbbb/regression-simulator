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
          <td class="col-actions"><input type="submit" name="rm_$(i)" value="&times;" class="btn-remove" title="Remove row $(i)" aria-label="Remove row $(i)" /></td>
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
    </div>
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
    print(t, "    <p class=\"panel-note\">n = ", result.n, " &middot; Average (Mean) x&#x0304; = ", f(result.xbar), " &middot; Average (Mean) &#x0233; = ", f(result.ybar), "</p>\n")
    print(t, "    <table class=\"calc-table\">\n")
    print(t, "      <thead>\n")
    print(t, "        <tr>\n")
    print(t, "          <th>X</th>\n")
    print(t, "          <th>Y</th>\n")
    print(t, "          <th>x &#x2212; x&#x0304;</th>\n")
    print(t, "          <th>y &#x2212; &#x0233;</th>\n")
    print(t, "          <th>(x &#x2212; x&#x0304;)(y &#x2212; &#x0233;)</th>\n")
    print(t, "          <th>(x &#x2212; x&#x0304;)&#x00B2;</th>\n")
    print(t, "          <th>Predicted Y (&#x0177;)</th>\n")
    print(t, "        </tr>\n")
    print(t, "      </thead>\n")
    print(t, "      <tbody>\n")
    for i in 1:result.n
        print(t, "        <tr>\n")
        print(t, "          <td class=\"num\">", f(result.x[i]), "</td>\n")
        print(t, "          <td class=\"num\">", f(result.y[i]), "</td>\n")
        print(t, "          <td class=\"num\">", f(result.dx[i]), "</td>\n")
        print(t, "          <td class=\"num\">", f(result.dy[i]), "</td>\n")
        print(t, "          <td class=\"num\">", f(result.dxdy[i]), "</td>\n")
        print(t, "          <td class=\"num\">", f(result.dx2[i]), "</td>\n")
        print(t, "          <td class=\"num\">", f(result.yhat[i]), "</td>\n")
        print(t, "        </tr>\n")
    end
    print(t, "        <tr class=\"total-row\">\n")
    print(t, "          <td class=\"num\"><strong>Sum (&#x03A3;) = ", f(sum(result.x)), "</strong></td>\n")
    print(t, "          <td class=\"num\"><strong>Sum (&#x03A3;) = ", f(sum(result.y)), "</strong></td>\n")
    print(t, "          <td class=\"num\">Sum (&#x03A3;) = 0</td>\n")
    print(t, "          <td class=\"num\">Sum (&#x03A3;) = 0</td>\n")
    print(t, "          <td class=\"num\"><strong>Sum (&#x03A3;) = ", f(result.sxy), "</strong></td>\n")
    print(t, "          <td class=\"num\"><strong>Sum (&#x03A3;) = ", f(result.sxx), "</strong></td>\n")
    print(t, "          <td class=\"num\">&mdash;</td>\n")
    print(t, "        </tr>\n")
    print(t, "        <tr class=\"total-row average-row\">\n")
    print(t, "          <td class=\"num\"><strong>Average (x&#x0304;) = ", f(result.xbar), "</strong></td>\n")
    print(t, "          <td class=\"num\"><strong>Average (&#x0233;) = ", f(result.ybar), "</strong></td>\n")
    print(t, "          <td class=\"num\">Average = 0</td>\n")
    print(t, "          <td class=\"num\">Average = 0</td>\n")
    print(t, "          <td class=\"num\">&mdash;</td>\n")
    print(t, "          <td class=\"num\">&mdash;</td>\n")
    print(t, "          <td class=\"num\">&mdash;</td>\n")
    print(t, "        </tr>\n")
    print(t, "      </tbody>\n")
    print(t, "    </table>\n")

    b_num = f(result.sxy)
    b_den = f(result.sxx)
    b_val = f(result.b)
    a_val = f(result.a)
    ybar_str = f(result.ybar)
    xbar_str = f(result.xbar)
    equation = "&#x0177; = " * a_val * " + " * b_val * "x"

    print(t, "    <div class=\"formula-block\">\n")
    print(t, "      <div class=\"formula-title\">Formulas &amp; Equation</div>\n")
    print(t, "      <div class=\"formula-line\">b = &#x03A3;(x &#x2212; x&#x0304;)(y &#x2212; &#x0233;) / &#x03A3;(x &#x2212; x&#x0304;)&#x00B2; = ", b_num, " / ", b_den, " = <strong>", b_val, "</strong></div>\n")
    print(t, "      <div class=\"formula-line\">a = &#x0233; &#x2212; b &middot; x&#x0304; = ", ybar_str, " &#x2212; (", b_val, " &middot; ", xbar_str, ") = <strong>", a_val, "</strong></div>\n")
    print(t, "      <div class=\"equation\">", equation, "</div>\n")
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
    transform::Symbol = :none,
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
    if transform != :none
        trans_label = transform == :normalize ? "Normalize (0–1)" :
                      transform == :standardize ? "Standardize (z-score)" :
                      transform == :log ? "Log (ln)" : string(transform)
        print(t, "    <div class=\"panel-note transform-note\">\n")
        print(t, "      Notice: A <strong>", html_escape(trans_label), "</strong> transformation is active. The regression equation, error metrics, and predictions are in transformed units.\n")
        print(t, "    </div>\n")
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
        print(t, "      <input type=\"hidden\" name=\"transform\" value=\"", string(transform), "\" />\n")
        for (i, row) in enumerate(rows)
            print(t, "      <input type=\"hidden\" name=\"x_", i, "\" value=\"", html_escape(row[1]), "\" />\n")
            print(t, "      <input type=\"hidden\" name=\"y_", i, "\" value=\"", html_escape(row[2]), "\" />\n")
        end
        print(t, "      <label for=\"predict-x\" class=\"predict-label\">Predict Y for X:</label>\n")
        print(t, "      <input type=\"text\" id=\"predict-x\" name=\"predict_x\" class=\"predict-input\" value=\"", html_escape(predict_x), "\" autocomplete=\"off\" />\n")
        print(t, "      <input type=\"submit\" value=\"Predict\" class=\"btn btn-add\" />\n")
        print(t, "      <div class=\"export-actions\"><button type=\"submit\" formaction=\"/export\" class=\"btn btn-secondary\">Download CSV</button></div>\n")
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
    <p class="panel-intro">Upload a .csv or .xlsx file, inspect data problems, clean with Weka-style pipeline, and apply to the grid.</p>
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
        print(t, """    <div class="panel-note">No file loaded. Upload a .csv or .xlsx file to inspect and clean attributes.</div>
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

        # Step 2: Examine structure, variables, data types overview table
        print(t, """    <div class="preprocess-section">
      <div class="relation-title">Structure &amp; Attributes Overview</div>
      <table class="calc-table attr-stats-table">
        <thead>
          <tr>
            <th style="width: 40px;">#</th>
            <th>Attribute</th>
            <th>Type</th>
            <th>Missing</th>
            <th>Distinct</th>
          </tr>
        </thead>
        <tbody>
""")
        for i in 1:length(u.columns)
            st_col = compute_attribute_stats(u.values[i], u.columns[i])
            print(t, """          <tr>
            <td class="col-num">$(i)</td>
            <td><strong>$(html_escape(st_col.name))</strong></td>
            <td>$(st_col.is_numeric ? "Numeric" : "Nominal")</td>
            <td class="num">$(st_col.missing_count) ($(round(st_col.missing_pct, digits=1))%)</td>
            <td class="num">$(st_col.distinct_count)</td>
          </tr>
""")
        end
        print(t, """        </tbody>
      </table>
    </div>\n\n""")

        # Selected attribute stats + histogram
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

        # Main Preprocessing Form
        print(t, """    <form method="post" action="/select" class="attr-form">
      <input type="hidden" name="token" value="$(html_escape(tok))" />
      <input type="hidden" name="decimals" value="$(decimals)" />
      
      <div class="relation-title">Attribute Selection for Regression</div>
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
      </div>
""")

        # Section 4: Cleaning Options
        m_global  = (u.missing_strategy in (:mean, :global)) ? " selected" : ""
        m_rolling = (u.missing_strategy in (:rolling, :sequential)) ? " selected" : ""
        m_drop    = (u.missing_strategy in (:drop, :remove)) ? " selected" : ""
        d_rem     = u.remove_duplicates ? " selected" : ""
        d_keep    = !u.remove_duplicates ? " selected" : ""
        o_flag    = u.outliers_strategy == :flag ? " selected" : ""
        o_rem     = u.outliers_strategy == :remove ? " selected" : ""
        t_none    = u.transform == :none ? " selected" : ""
        t_norm    = u.transform == :normalize ? " selected" : ""
        t_std     = u.transform == :standardize ? " selected" : ""
        t_log     = u.transform == :log ? " selected" : ""

        print(t, """    <div class="preprocess-section options-panel">
      <div class="relation-title">Cleaning &amp; Preprocessing Options</div>
      <div class="options-grid">
        <div class="option-field">
          <label for="missing_strategy">Missing values:</label>
          <select name="missing_strategy" id="missing_strategy" class="select-option">
            <option value="global"$(m_global)>Global Average (Recommended for independent records)</option>
            <option value="rolling"$(m_rolling)>Rolling / Sequential (Recommended for time-series / ordered)</option>
            <option value="drop"$(m_drop)>Drop rows with missing</option>
          </select>
        </div>
        <div class="option-field">
          <label for="remove_duplicates">Duplicate records:</label>
          <select name="remove_duplicates" id="remove_duplicates" class="select-option">
            <option value="1"$(d_rem)>Remove duplicates (default)</option>
            <option value="0"$(d_keep)>Keep duplicates</option>
          </select>
        </div>
        <div class="option-field">
          <label for="outliers_strategy">Outlier handling (IQR rule):</label>
          <select name="outliers_strategy" id="outliers_strategy" class="select-option">
            <option value="flag"$(o_flag)>Flag only, do not delete (default)</option>
            <option value="remove"$(o_rem)>Remove flagged rows</option>
          </select>
        </div>
        <div class="option-field">
          <label for="transform">Transformation:</label>
          <select name="transform" id="transform" class="select-option">
            <option value="none"$(t_none)>None (default)</option>
            <option value="normalize"$(t_norm)>Normalize (0–1)</option>
            <option value="standardize"$(t_std)>Standardize (z-score)</option>
            <option value="log"$(t_log)>Log (ln)</option>
          </select>
        </div>
      </div>
      <div class="grid-actions preprocess-actions">
        <button type="submit" formaction="/preprocess" class="btn btn-secondary">Update Cleaning Options</button>
        <button type="submit" name="action" value="apply" class="btn btn-add">Apply to grid</button>
        <button type="submit" formaction="/export_clean" class="btn btn-secondary">Download clean CSV</button>
      </div>
    </div>
""")

        if u.report !== nothing
            rep = u.report

            # Section 3: Issues found
            print(t, """    <div class="preprocess-section">
      <div class="relation-title">Issues Found</div>
      <div class="issues-grid">
        <div class="issue-card">
          <span class="issue-label">Missing Values (X / Y)</span>
          <span class="issue-val num">$(rep.missing_x) / $(rep.missing_y)</span>
        </div>
        <div class="issue-card">
          <span class="issue-label">Duplicate Rows</span>
          <span class="issue-val num">$(rep.duplicates_removed)</span>
        </div>
        <div class="issue-card">
          <span class="issue-label">Invalid Non-Numeric</span>
          <span class="issue-val num">$(rep.invalid_entries)</span>
        </div>
        <div class="issue-card">
          <span class="issue-label">Potential Outliers (X / Y)</span>
          <span class="issue-val num">$(length(rep.outliers_x)) / $(length(rep.outliers_y))</span>
        </div>
      </div>
    </div>\n\n""")

            # Section 4: Actions applied
            print(t, """    <div class="preprocess-section">
      <div class="relation-title">Actions Applied</div>
""")
            if isempty(rep.reasons)
                print(t, "      <p class=\"panel-intro\">No cleaning actions were necessary; dataset is clean.</p>\n")
            else
                print(t, "      <ul class=\"actions-list\">\n")
                for r in rep.reasons
                    print(t, "        <li>", html_escape(r), "</li>\n")
                end
                print(t, "      </ul>\n")
            end
            print(t, "    </div>\n\n")

            # Section 5: Before / After summary table
            outlier_act = u.outliers_strategy == :remove ? "Removed" : "Flagged, kept"
            missing_act = if u.missing_strategy in (:rolling, :sequential)
                "Rolling / Sequential interpolation"
            elseif u.missing_strategy in (:mean, :global)
                "Global Average (Column Mean)"
            else
                "Dropped"
            end
            dup_act = u.remove_duplicates ? "Removed" : "Kept"
            inv_act = rep.invalid_entries > 0 ? "Set to missing, then imputed" : "None"
            print(t, """    <div class="preprocess-section">
      <div class="relation-title">Before / After Summary</div>
      <table class="calc-table before-after-table">
        <thead>
          <tr>
            <th>Check</th>
            <th>Before</th>
            <th>Action</th>
            <th>After</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Rows</td>
            <td class="num">$(rep.rows_before)</td>
            <td>$(rep.rows_before > rep.rows_after ? "Removed $(rep.rows_before - rep.rows_after) row(s)" : "All rows retained")</td>
            <td class="num">$(rep.rows_after)</td>
          </tr>
          <tr>
            <td>Missing values (X / Y)</td>
            <td class="num">$(rep.missing_x) / $(rep.missing_y)</td>
            <td>$(missing_act)</td>
            <td class="num">0 / 0</td>
          </tr>
          <tr>
            <td>Duplicate rows</td>
            <td class="num">$(rep.duplicates_removed)</td>
            <td>$(dup_act)</td>
            <td class="num">0</td>
          </tr>
          <tr>
            <td>Invalid entries</td>
            <td class="num">$(rep.invalid_entries)</td>
            <td>$(inv_act)</td>
            <td class="num">0</td>
          </tr>
          <tr>
            <td>Potential outliers (X / Y)</td>
            <td class="num">$(length(rep.outliers_x)) / $(length(rep.outliers_y))</td>
            <td>$(outlier_act)</td>
            <td class="num">$(length(rep.outliers_x)) / $(length(rep.outliers_y))</td>
          </tr>
          <tr>
            <td>Transform</td>
            <td>&mdash;</td>
            <td>$(string(rep.transform))</td>
            <td>&mdash;</td>
          </tr>
        </tbody>
      </table>
    </div>\n\n""")

            # Section 6: Cleaned data preview
            n_prev = min(10, length(u.clean_x))
            print(t, """    <div class="preprocess-section">
      <div class="relation-title">Cleaned Data Preview (first $(n_prev) of $(length(u.clean_x)) instances)</div>
      <table class="calc-table preview-table">
        <thead>
          <tr>
            <th style="width: 40px;">#</th>
            <th>Clean X</th>
            <th>Clean Y</th>
            <th>Status / Flags</th>
          </tr>
        </thead>
        <tbody>
""")
            is_rolling = rep.missing_strategy in (:rolling, :sequential)
            imp_x_text = is_rolling ? "X IMPUTED (Rolling)" : "X IMPUTED (Global)"
            imp_y_text = is_rolling ? "Y IMPUTED (Rolling)" : "Y IMPUTED (Global)"

            for i in 1:n_prev
                flags = String[]
                is_x_imp = (i, :x) in rep.imputed_cells
                is_y_imp = (i, :y) in rep.imputed_cells
                is_out = i in rep.outlier_rows

                is_x_imp && push!(flags, "<span class=\"badge-tag badge-imputed\">$(imp_x_text)</span>")
                is_y_imp && push!(flags, "<span class=\"badge-tag badge-imputed\">$(imp_y_text)</span>")
                is_out && push!(flags, "<span class=\"badge-tag badge-outlier\">outlier</span>")
                isempty(flags) && push!(flags, "<span class=\"badge-tag badge-clean\">clean</span>")

                cls_x = is_x_imp ? "cell-imputed" : ""
                cls_y = is_y_imp ? "cell-imputed" : ""
                cls_row = is_out ? "row-outlier" : ""

                print(t, """          <tr class="$(cls_row)">
            <td class="col-num">$(i)</td>
            <td class="num $(cls_x)">$(fmt(u.clean_x[i], decimals))</td>
            <td class="num $(cls_y)">$(fmt(u.clean_y[i], decimals))</td>
            <td>$(join(flags, " "))</td>
          </tr>
""")
            end
            print(t, """        </tbody>
      </table>
    </div>\n\n""")

            # Section 7: Validation
            print(t, """    <div class="preprocess-section">
      <div class="relation-title">Validation Checks (Step 12)</div>
      <table class="calc-table validation-table">
        <thead>
          <tr>
            <th style="width: 80px;">Status</th>
            <th>Check</th>
            <th>Detail</th>
          </tr>
        </thead>
        <tbody>
""")
            for c in rep.validation
                badge = c.passed ? "<span class=\"badge-tag badge-pass\">PASS</span>" : "<span class=\"badge-tag badge-fail\">FAIL</span>"
                print(t, """          <tr>
            <td style="text-align: center;">$(badge)</td>
            <td><strong>$(html_escape(c.name))</strong></td>
            <td>$(html_escape(c.detail))</td>
          </tr>
""")
            end
            print(t, """        </tbody>
      </table>
    </div>\n\n""")
        end

        print(t, """    </form>\n""")
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
    transform::Symbol = :none,
)::String
    grid_panel = render_grid_panel(rows; token = token, decimals = decimals)
    calc_panel = render_calculation_panel(result; decimals = decimals)
    result_panel = render_result_panel(result, error; decimals = decimals, predicted = predicted,
                                       predict_x = predict_x, token = token, rows = rows,
                                       transform = transform)
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
  <span class="title-text">Linear Regression Project</span>
  <span class="winbtn">_</span>
  <span class="winbtn">x</span>
</div>
<div class="menubar">
  <span class="menu-item">Dela Cruz</span>
  <span class="menu-item">Santiago</span>
  <span class="menu-item">Villanueva</span>
  <span class="menu-item">Professional Elective 3</span>
</div>
<header class="app-header">
  <h1>Julia Simple Linear Regression Calculator</h1>
  <p class="tagline">By Group 3 BSIT 3-1 &middot; b = SLOPE &middot; a = INTERCEPT &middot; r = CORREL &middot; R&#x00B2; = RSQ &middot; &#x0177; = FORECAST.LINEAR</p>
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
  <span class="tool-credit">Dela Cruz, Villanueva, Santiago</span>
</div>

$(status_bar_html)
"""
end
