# Preprocessing & Cleaning Tab: Specification

Part of the Simple Linear Regression Calculator (Julia, HTML + CSS only, no JavaScript).
This document describes the **Preprocess** tab: what it does, what it shows, and how it connects to the rest of the app. It follows the Weka Preprocess workflow and the course requirement *III. Data Cleaning and Preprocessing*.

---

## 1. Purpose

Take the raw X/Y data (typed in the grid or imported from CSV/XLSX), **inspect it, find problems, fix them**, validate the result, and hand a clean, analysis-ready dataset to the Calculation and Result tabs.

Every action must be **visible**: the tab shows what was found, what was done, and the before/after numbers.

## 2. Constraints (same as the rest of the project)

| Item | Rule |
|---|---|
| Language | Julia for all logic, parsing, HTML, and charts |
| UI | HTML + CSS only. Tabs, toggles, and sections use CSS radio/checkbox and `<details>`. No JavaScript |
| Packages | HTTP.jl, CSV.jl, XLSX.jl only. Cleaning math (mean, quartiles) is handwritten |
| State | Stateless, server-rendered. Data travels in form fields; uploaded files use the small in-memory store |
| Accuracy | Mean and quartiles match Excel (`AVERAGE`, `QUARTILE.INC`) |
| Precision | Calculations use full `Float64`; display decimals are a UI setting only |

## 3. Pipeline

The steps run in this order. The order matters (for example, duplicates are removed before the mean is computed).

| # | Course requirement | What the simulator does | Weka equivalent | Report field |
|---|---|---|---|---|
| 1 | Load and inspect the original dataset | Show file name, sheet, number of rows, first rows preview | Open file, "Current relation" | `rows_before` |
| 2 | Examine structure, variables, data types | List every column with its detected type; show the selected X and Y | Attributes panel | `column_types` |
| 3 | Identify missing values | Count missing cells in X and Y (empty, `?`, `NA`, `N/A`, `NaN`, `null`, `none`, `-`) | Missing count in attribute panel | `missing_x`, `missing_y` |
| 4 | Identify duplicate records | Count rows where the (X, Y) pair repeats exactly | `RemoveDuplicates` | `duplicates_removed` |
| 5 | Detect inconsistent or invalid entries | Text in a numeric column, infinite values, unparseable numbers | `NumericCleaner` | `invalid_entries` |
| 6 | Remove unnecessary columns or records when justified | Drop rows where both X and Y are blank (no information) and exact duplicates. Unselected columns are ignored. Each removal has a stated reason | `Remove`, `RemoveWithValues` | `rows_dropped`, `reasons` |
| 7 | Correct data types and formats | Convert text to `Float64`; accept decimal commas (`3,5` becomes `3.5`); trim spaces | `NumericToNominal`, type fixes | `values_converted` |
| 8 | Handle missing values | **Mean imputation** (default) or drop rows (option) | `ReplaceMissingValues` | `imputed_x`, `imputed_y` |
| 9 | Identify potential outliers | IQR rule on X and Y: below Q1 − 1.5·IQR or above Q3 + 1.5·IQR. **Flag only, do not delete** | `InterquartileRange` | `outliers_x`, `outliers_y` |
| 10 | Standardize inconsistent values and formats | Unified missing tokens, trimmed text, one decimal format | `SwapValues`, `MergeTwoValues` | `values_standardized` |
| 11 | Transform variables when necessary | Optional: none (default), normalize, standardize, log | `Normalize`, `Standardize`, `MathExpression` | `transform` |
| 12 | Validate the cleaned dataset | Check: no missing, no NaN/Inf, no duplicates, at least 2 rows, X not constant | Re-inspect in Preprocess tab | `validation` |
| 13 | Generate and save the final clean dataset | Fill the grid with the cleaned pairs and offer **Download clean CSV** | Save | `clean_rows` |

## 4. Options (left sidebar)

| Option | Choices | Default |
|---|---|---|
| Missing values | Mean imputation / Drop rows with missing | Mean imputation |
| Duplicates | Remove / Keep | Remove |
| Outliers | Flag only / Remove flagged rows | Flag only |
| Transform | None / Normalize (0–1) / Standardize (z-score) / Log | None |
| Display decimals | 2–8 | Same setting as the rest of the app |

## 5. Screen layout

The tab is one scrollable page of panels, in this order:

1. **Upload and select**: file upload, sheet dropdown (XLSX), X and Y attribute dropdowns, header-row checkbox.
2. **Inspect**: structure table (column, type, missing count) and the histogram of the selected attribute.
3. **Issues found**: counts for missing, duplicates, invalid entries, potential outliers (steps 3, 4, 5, 9).
4. **Actions applied**: a list of what was done, each with its reason (steps 6, 7, 8, 10, 11).
5. **Before / After**: summary table (see section 7).
6. **Cleaned data preview**: first rows of the clean dataset; imputed cells are marked, outlier rows are flagged.
7. **Validation**: a pass/fail line for each check in step 12.
8. **Apply and download**: *Apply to grid* button and *Download clean CSV* button.

## 6. Routes

| Route | Purpose |
|---|---|
| `POST /upload` | Existing. Read the file, show column pickers |
| `POST /select` | Existing. Now passes the chosen X/Y through `preprocess` before filling the grid |
| `POST /preprocess` | Re-run cleaning when an option changes (stateless: raw values come back in form fields) |
| `POST /export_clean` | Download the clean dataset as CSV |

## 7. Before / After report

Example layout (numbers are illustrative):

| Check | Before | Action | After |
|---|---|---|---|
| Rows | 8 | | 7 |
| Missing values (X / Y) | 0 / 2 | Mean imputation | 0 / 0 |
| Duplicate rows | 1 | Removed | 0 |
| Invalid entries | 1 | Set to missing, then imputed | 0 |
| Potential outliers (X / Y) | n / n | Flagged, kept | n / n |
| Transform | | None | |

## 8. Rules in detail

**Parsing (steps 5, 7, 10).** A cell is *missing* if it is empty or one of the missing tokens (case-insensitive, after trimming). A cell is *invalid* if it is text that cannot be parsed, or an infinite value. Invalid cells are counted, then treated as missing.

**Blank rows (step 6).** A row where both X and Y are missing carries no information and is dropped before imputation.

**Duplicates (steps 4, 6).** A duplicate is a row whose (X, Y) pair equals an earlier row. The first occurrence is kept.

**Mean imputation (step 8).** The mean of X and the mean of Y are each computed from the known values only, after duplicates are removed:

```
x̄ = Σx / n_known        ȳ = Σy / n_known
```

Every missing X becomes x̄ and every missing Y becomes ȳ. If a column has no known values, show an error (no mean exists).

**Outliers (step 9).** Quartiles use the same method as Excel `QUARTILE.INC`:

```
h = (n − 1)·p + 1
Q = s[⌊h⌋] + (h − ⌊h⌋)·(s[⌊h⌋+1] − s[⌊h⌋])      (s = sorted values)
IQR = Q3 − Q1
outlier if value < Q1 − 1.5·IQR or value > Q3 + 1.5·IQR
```

Outliers are listed by row number. They are removed only if the user selects that option, and the report says so.

**Transforms (step 11).**

| Transform | Formula | Effect on results |
|---|---|---|
| Normalize | (v − min) / (max − min) | Slope and intercept change scale; r and R² unchanged |
| Standardize | (v − mean) / sd | Same as above |
| Log | ln(v), needs v > 0 | Changes the model shape; show an error if any v ≤ 0 |

Whenever a transform is on, the Result tab must say that the equation is in transformed units.

**Validation (step 12).** All of these must pass before the data is sent to the calculation:

- no missing, NaN, or infinite values
- no duplicate rows (if removal is on)
- at least 2 rows
- X is not constant (Σ(x − x̄)² ≠ 0)

## 9. Edge cases

| Case | Behavior |
|---|---|
| X or Y column has no numeric values | Error: choose another attribute |
| All values in a column missing | Error: no mean can be computed |
| Fewer than 2 rows after cleaning | Error message, calculation blocked |
| X becomes constant after cleaning | Error: slope undefined (same as the existing rule) |
| Log transform with value ≤ 0 | Error naming the row |
| Non-numeric text in X/Y | Counted as invalid, shown in Issues found |
| File has no header row | Use the header checkbox |

## 10. Notes on mean imputation in simple regression

Because the calculation uses `x − x̄` and `y − ȳ`:

- **Both X and Y missing:** the imputed point lies exactly on the regression line. The slope and intercept do not change, but R², standard error, MAE, and RMSE change because n is larger. This is why blank rows are dropped.
- **Only Y missing:** the point adds to the spread of X but not to the X–Y relationship, so the slope is pulled toward zero.
- **Weka's own linear regression** removes rows with a missing class value before fitting.

Mean imputation is the default because the course requires a complete dataset. The "Drop rows" option exists so the two results can be compared in the report.

## 11. Files to add or change

| File | Change |
|---|---|
| `src/preprocess.jl` | New. `parse_cell`, `mean_of`, `quantile_inc`, `iqr_outliers`, `preprocess` returning cleaned vectors and a report |
| `src/main.jl` | Include `preprocess.jl`; call it in `/select`; add `/preprocess` and `/export_clean` routes |
| `src/render.jl` | New panels for the Preprocess tab (sections 5 and 7) |
| `src/export.jl` | Add the clean-dataset CSV writer |
| `static/style.css` | Styles for the report tables, issue badges, and validation lines |
| `test/preprocess_test.jl` | New tests (section 12) |
| `examples/dirty_sample.csv` | New sample file with known problems |

## 12. Tests

**Dirty sample** (`examples/dirty_sample.csv`):

| Row | X | Y |
|---|---|---|
| 1 | 1 | 2 |
| 2 | 2 | 4 |
| 3 | 3 | 5 |
| 4 | 4 | 4 |
| 5 | 5 | 6 |
| 6 | 3 | *(empty)* |
| 7 | 2 | 4 |
| 8 | 6 | abc |

**Expected with default options:**

| Value | Expected |
|---|---|
| Rows before / after | 8 / 7 |
| Duplicates removed | 1 (row 7) |
| Invalid entries | 1 (`abc`) |
| Missing Y after parsing | 2 |
| ȳ used for imputation | 4.2 (from 2, 4, 5, 4, 6) |
| Imputed Y cells | 2 (rows 6 and 8) |
| Validation | All checks pass |

**Regression guard:** the clean sample X = 1, 2, 3, 4, 5 and Y = 2, 4, 5, 4, 6 must pass through preprocessing unchanged, so the existing results still hold (b = 0.8, a = 1.8, r = 0.8528, R² = 0.7273).

**Other tests:**
- The same data as `.csv` and `.xlsx` gives identical cleaned output.
- Quartiles match Excel `QUARTILE.INC` on an Excel-verified dataset.
- Each edge case in section 9 shows the expected error.

## 13. Acceptance checklist

- [ ] All 13 steps from the course requirement are implemented and visible in the tab
- [ ] Before/after counts are shown for missing values, duplicates, invalid entries, and outliers
- [ ] Every removal or imputation has a stated reason
- [ ] Mean imputation computes from known values only and leaves no incomplete data
- [ ] Outliers are flagged and reported; they are removed only on request
- [ ] Validation passes before the data reaches the Calculation tab
- [ ] Clean dataset can be downloaded as CSV
- [ ] No JavaScript is used
- [ ] Tests pass, and the original sample still gives the original results
- [ ] Source code is commented and submitted with the project
