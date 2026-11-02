# src/render.jl - HTML builders for the Simple Linear Regression Calculator UI.
# Pure string builders. No client-side scripting.

function html_escape(s::AbstractString)::String
    out = IOBuffer()
    for c in s
        if c == '&'
            print(out, "&amp;")
        elseif c == '<'
            print(out, "&lt;")
        elseif c == '>'
            print(out, "&gt;")
        elseif c == '"'
            print(out, "&quot;")
        elseif c == '\''
            print(out, "&#39;")
        else
            print(out, c)
        end
    end
    return String(take!(out))
end

function fmt(v::Float64)::String
    r = round(v; digits = 4)
    if r == 0
        r = 0.0
    end
    s = string(r)
    if endswith(s, ".0")
        s = s[1:end - 2]
    end
    return s
end

function render_grid_panel(rows)::String
    t = IOBuffer()
    print(t, """
<section class="tab-panel" id="panel-data" role="tabpanel">
  <div class="panel-header">
    <h2>Data</h2>
  </div>
  <div class="panel-body">
    <p class="panel-intro">Enter X and Y per row. Blank rows are ignored. Press Enter to calculate.</p>
    <form method="post" action="/rows" class="grid-form">
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
    print(t, """
      </tbody>
    </table>
    <div class="grid-actions">
      <input type="submit" name="action" value="add" class="btn-add" />
      <input type="submit" name="action" value="calculate" class="btn-add" />
      <span class="grid-hint">Press Enter to run the calculation.</span>
    </div>
    </form>
</section>
""")
    return String(take!(t))
end

function render_calculation_panel(result)::String
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
    print(t, "<section class=\"tab-panel\" id=\"panel-calculation\" role=\"tabpanel\">\n")
    print(t, "  <div class=\"panel-header\">\n")
    print(t, "    <h2>Calculation</h2>\n")
    print(t, "  </div>\n")
    print(t, "  <div class=\"panel-body\">\n")
    print(t, "    <p class=\"panel-note\">n = ", result.n, " &middot; x&#x0304; = ", fmt(result.xbar), " &middot; &#x0233; = ", fmt(result.ybar), "</p>\n")
    print(t, "    <table class=\"calc-table\">\n")
    print(t, "      <thead>\n")
    print(t, "        <tr>\n")
    print(t, "          <th>X</th>\n")
    print(t, "          <th>Y</th>\n")
    print(t, "          <th>x &#x2212; x&#x0304;</th>\n")
    print(t, "          <th>y &#x2212; &#x0233;</th>\n")
    print(t, "          <th>(x &#x2212; x&#x0304;)(&#x2212; &#x0233;)</th>\n")
    print(t, "          <th>(x &#x2212; x&#x0304;)&#x00B2;</th>\n")
    print(t, "          <th>&#x0176;</th>\n")
    print(t, "        </tr>\n")
    print(t, "      </thead>\n")
    print(t, "      <tbody>\n")
    for i in eachindex(result.x)
        print(t, "        <tr>\n")
        print(t, "          <td>", fmt(result.x[i]), "</td>\n")
        print(t, "          <td>", fmt(result.y[i]), "</td>\n")
        print(t, "          <td>", fmt(result.dx[i]), "</td>\n")
        print(t, "          <td>", fmt(result.dy[i]), "</td>\n")
        print(t, "          <td>", fmt(result.dxdy[i]), "</td>\n")
        print(t, "          <td>", fmt(result.dx2[i]), "</td>\n")
        print(t, "          <td>", fmt(result.yhat[i]), "</td>\n")
        print(t, "        </tr>\n")
    end
    print(t, "      </tbody>\n")
    print(t, "      <tfoot>\n")
    print(t, "        <tr>\n")
    print(t, "          <td>&#x03A3;X = ", fmt(sum(result.x)), "</td>\n")
    print(t, "          <td>&#x03A3;Y = ", fmt(sum(result.y)), "</td>\n")
    print(t, "          <td>&#x03A3;(x&#x0304;) = ", fmt(sum(result.dx)), "</td>\n")
    print(t, "          <td>&#x03A3;(y&#x0304;) = ", fmt(sum(result.dy)), "</td>\n")
    print(t, "          <td>&#x03A3;(x&#x0304;)(&#x0233;) = ", fmt(result.sxy), "</td>\n")
    print(t, "          <td>&#x03A3;(x&#x0304;)&#x00B2; = ", fmt(result.sxx), "</td>\n")
    print(t, "          <td>&#x03A3;Predicted Y = ", fmt(sum(result.yhat)), "</td>\n")
    print(t, "        </tr>\n")
    print(t, "      </tfoot>\n")
    print(t, "    </table>\n")
    line_b = "b = &#x03A3;(x &#x2212; x&#x0304;)(&#x2212; &#x0233;) / &#x03A3;(x &#x2212; x&#x0304;)&#x00B2; = " * fmt(result.sxy) * " / " * fmt(result.sxx) * " = " * fmt(result.b)
    line_a = "a = &#x0233; &#x2212; b&#183;x&#x0304; = " * fmt(result.ybar) * " &#x2212; (" * fmt(result.b) * ")(" * fmt(result.xbar) * ") = " * fmt(result.a)
    line_eq = "&#x0177; = " * fmt(result.a) * " + " * fmt(result.b) * "x"
    print(t, "    <div class=\"formula\">\n")
    print(t, "      <p><code>", line_b, "</code></p>\n")
    print(t, "      <p><code>", line_a, "</code></p>\n")
    print(t, "      <p class=\"equation\">", line_eq, "</p>\n")
    print(t, "    </div>\n")
    print(t, "  </div>\n")
    print(t, "</section>\n")
    return String(take!(t))
end

function render_result_panel(result, error, status)::String
    t = IOBuffer()
    print(t, "<section class=\"tab-panel\" id=\"panel-result\" role=\"tabpanel\">\n")
    print(t, "  <div class=\"panel-header\">\n")
    print(t, "    <h2>Result</h2>\n")
    print(t, "  </div>\n")
    print(t, "  <div class=\"panel-body\">\n")
    if error !== nothing
        print(t, "    <p class=\"error-text\">", html_escape(error), "</p>\n")
    elseif result !== nothing
        lines = Vector{String}()
        push!(lines, "&#x0177; = " * fmt(result.a) * " + " * fmt(result.b) * "x")
        push!(lines, "n    = " * string(result.n))
        push!(lines, "b    = " * fmt(result.b))
        push!(lines, "a    = " * fmt(result.a))
        push!(lines, "r    = " * fmt(result.r))
        push!(lines, "R&#x00B2;   = " * fmt(result.r2))
        push!(lines, "SE   = " * fmt(result.se))
        push!(lines, "MAE   = " * fmt(result.mae))
        push!(lines, "RMSE  = " * fmt(result.rmse))
        print(t, "    <pre class=\"mono\">\n")
        print(t, join(lines, "\n"))
        print(t, "\n    </pre>\n")
    end
    print(t, "  </div>\n")
    print(t, "</section>\n")
    return String(take!(t))
end

function render_page(
    rows,
    result,
    error,
    status::String,
    tab::String,
)::String
    grid_panel = render_grid_panel(rows)
    calc_panel = render_calculation_panel(result)
    result_panel = render_result_panel(result, error, status)

    checked_data = tab == "data" ? " checked" : ""
    checked_calculation = tab == "calculation" ? " checked" : ""
    checked_result = tab == "result" ? " checked" : ""

    status_html = replace(status, r"(\d+(?:\.\d+)?)" => m -> "<span class=\"status-num\">" * String(m) * "</span>")
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

<nav class="tabs" role="tablist">
  <input type="radio" name="tab" id="tab-data" value="data"$(checked_data)>
  <label class="tab-label" for="tab-data">Data</label>
  <input type="radio" name="tab" id="tab-calculation" value="calculation"$(checked_calculation)>
  <label class="tab-label" for="tab-calculation">Calculation</label>
  <input type="radio" name="tab" id="tab-result" value="result"$(checked_result)>
  <label class="tab-label" for="tab-result">Result</label>
</nav>

<div class="tab-panels">
""" * grid_panel * """
""" * calc_panel * """
""" * result_panel * """
</div>

<div class="toolbar">
  <span class="tool-btn">A</span>
  <span class="tool-btn">&#x1F5BC;</span>
  <span class="tool-btn">&#x2665;</span>
  <span class="tool-btn">&#x2605;</span>
  <span class="tool-credit">Simple Linear Regression Calculator</span>
</div>

<footer class="statusbar">
  <span class="status-badge"></span>
""" * status_html * """</footer>
</div>

</body>
</html>
"""
    return html
end
