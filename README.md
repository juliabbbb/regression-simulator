# Simple Linear Regression Calculator

A Weka/Orange-style simple linear regression calculator written entirely in **Julia**. The interface is plain server-rendered HTML and CSS with **no JavaScript**. Enter or import X/Y data and the app shows the full calculation table, the slope and intercept with their formulas, an SVG scatter plot with the regression line, a summary of error metrics, a Predict box, and CSV downloads.

> Screenshot placeholder: save an image as `docs/screenshot.png`, then replace this line with `![Screenshot](docs/screenshot.png)`.

## Features

- Manual X/Y grid with add/remove rows and a display precision setting (2-8 decimals). Calculations always use full `Float64`.
- CSV and XLSX import with a sheet picker, X/Y attribute selection, and a histogram of the selected attribute.
- **Data Cleaning and Preprocessing tab (13-step Weka-style pipeline):**
  - Detect and standardize missing value tokens (`?`, `NA`, `null`, empty, `-`, etc.) and decimal commas (`3,5` -> `3.5`).
  - Drop blank rows (where both X and Y carry no information).
  - Remove exact duplicate (X, Y) records, keeping the first occurrence.
  - Mean imputation computed from known values only, after duplicates are removed (default) or drop missing rows.
  - Outlier detection via Excel-compatible IQR rule (`QUARTILE.INC`): flagged by default, with option to remove.
  - Optional variable transforms: Normalize (0–1), Standardize (z-score), and Log (ln).
  - Pre-calculation validation (finite values, uniqueness, minimum 2 rows, non-constant X).
  - Issues found counts, Actions applied with stated reasons, Before/After summary table, and Cleaned data preview with imputed/outlier badges.
  - **Download clean CSV** button.
- Step-by-step table: X, Y, x − x̄, y − ȳ, (x − x̄)(y − ȳ), (x − x̄)², Predicted Y, with totals.
- Slope and intercept formulas with the substituted values, and the equation ŷ = a + bx.
- SVG scatter plot with the regression line and optional residual lines.
- Summary: r, R², standard error, MAE, RMSE, RAE, RRSE.
- Predict ŷ for a new X value.
- **Download CSV** with the calculation table and summary at full precision.

## Requirements

- **Git**
- **Julia 1.13** (the committed `Manifest.toml` was resolved with Julia 1.13.3)
- An internet connection for the first setup, to download packages

The Julia packages (HTTP.jl, CSV.jl, XLSX.jl) are installed automatically in the setup step below.

## 1. Install Julia

The recommended way is [juliaup](https://github.com/JuliaLang/juliaup), the official Julia version manager.

**macOS / Linux**

```sh
curl -fsSL https://install.julialang.org | sh
```

**Windows**

```powershell
winget install --name Julia --id 9NJNWW8PVKMN -e -s msstore
```

Open a new terminal, then make sure you are on Julia 1.13:

```sh
juliaup add 1.13
juliaup default 1.13
julia --version
```

`julia --version` should print `julia version 1.13.x`. You can also download Julia directly from <https://julialang.org/downloads/>.

## 2. Clone the repository

```sh
git clone https://github.com/juliabbbb/regression-simulator.git
cd regression-simulator
```

## 3. Set up the Julia environment

This project has its own environment, defined by `Project.toml` (dependencies) and `Manifest.toml` (exact versions). Install it once:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

What this does:

- `--project=.` tells Julia to use the environment in the current folder instead of your global one.
- `Pkg.instantiate()` downloads and precompiles the exact package versions listed in `Manifest.toml`.

The first run can take a few minutes. Later runs start much faster.

> If you prefer the Julia REPL: run `julia --project=.`, press `]` to enter the package prompt, then type `instantiate`.

## 4. Run the app

```sh
julia --project=. src/main.jl
```

Wait until the server is up, then open <http://localhost:8080> in your browser. Stop it with `Ctrl+C`.

### Optional settings

| Variable | Default | Purpose |
|---|---|---|
| `HOST` | `127.0.0.1` | Address to listen on (`0.0.0.0` to allow other machines) |
| `PORT` | `8080` | Port to listen on |

macOS / Linux:

```sh
PORT=3000 julia --project=. src/main.jl
```

Windows (PowerShell):

```powershell
$env:PORT = 3000
julia --project=. src/main.jl
```

## How to use it

1. **Data tab:** type X and Y values (a sample is preloaded), then press **Calculate**.
2. **Preprocess tab:** upload a `.csv` or `.xlsx` file, inspect structure and issues, configure cleaning options (missing value strategy, duplicate handling, IQR outlier treatment, and optional transforms), and apply the cleaned data to the grid or download the cleaned CSV. `examples/sample.csv`, `examples/sample.xlsx`, and `examples/dirty_sample.csv` are included.
3. **Calculation tab:** see every step, the formulas, and the chart.
4. **Result tab:** see the summary, predict ŷ for a new X, and **Download CSV**.

Sample data (X = 1, 2, 3, 4, 5 and Y = 2, 4, 5, 4, 6) gives b = 0.8, a = 1.8, r = 0.8528, R² = 0.7273.

## Run the tests

Run each test file with the project environment:

```sh
julia --project=. test/excel_match.jl
julia --project=. test/phase3_test.jl
julia --project=. test/chart_test.jl
julia --project=. test/preprocess_test.jl
```

All tests should report only passes.

## Verify results in Excel or Google Sheets

The regression math is handwritten in `src/regression.jl` and cross-checked against these spreadsheet functions:

| Result | Excel / Sheets |
|---|---|
| Slope b | `=SLOPE(Y, X)` |
| Intercept a | `=INTERCEPT(Y, X)` |
| Correlation r | `=CORREL(Y, X)` |
| R² | `=RSQ(Y, X)` |
| Standard error | `=STEYX(Y, X)` |
| Predicted ŷ | `=FORECAST.LINEAR(x, Y, X)` |

## No JavaScript

The app is stateless and server-rendered. Every action is an HTML form POST and Julia returns a full page. Tabs are CSS radio buttons, the residual toggle is a CSS checkbox, and the charts are SVG generated by Julia. The only server-side state is a small in-memory store (5 entries, 1-hour expiry) for uploaded files.

## Project structure

```
src/
  main.jl         HTTP server, routing, request handlers
  regression.jl   Simple linear regression math
  importer.jl     CSV / XLSX reading and column selection
  preprocess.jl   13-step Weka-style data cleaning and preprocessing pipeline
  render.jl       HTML pages and panels
  chart.jl        SVG scatter plot and histogram
  export.jl       CSV downloads (results and clean dataset)
static/style.css  All styling (self-contained, no external fonts)
test/             Test files (excel_match.jl, phase3_test.jl, chart_test.jl, preprocess_test.jl)
examples/         Sample data (sample.csv, sample.xlsx, dirty_sample.csv)
Dockerfile        Container image used for deployment
render.yaml       Render Blueprint
DESIGN.md         Visual design spec
PLAN.md           Project plan and phase status
PREPROCESSING.md  Preprocessing specification
```

## Deploy on Render

The repo includes a `Dockerfile` and a `render.yaml` Blueprint.

1. Push the repo to GitHub.
2. In [Render](https://render.com), choose **New +**, then **Blueprint**, and select this repository.
3. Click **Deploy Blueprint** and wait for the build to finish.

Render supplies `PORT`, and the image sets `HOST=0.0.0.0`. On the free plan the service sleeps when idle, so the first visit after a pause is slow and uploaded files are lost.

## Troubleshooting

- **`julia: command not found`:** open a new terminal after installing, or add Julia's `bin` folder to your `PATH`.
- **Wrong Julia version warning:** run `juliaup default 1.13`, or start with `julia +1.13 --project=. src/main.jl`.
- **Package errors on first run:** re-run `julia --project=. -e 'using Pkg; Pkg.instantiate()'`.
- **`address already in use`:** another program is using port 8080. Start the app with a different `PORT`.
- **Slow first start:** Julia compiles on the first run. Later starts are faster.
