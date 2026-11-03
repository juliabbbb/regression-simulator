"""
CSV download for POST /export.
Builds a file from the same SLRResult the page renders, so the download always
matches the table on screen. Display formatting is not applied: full Float64
values are written.
"""

function csv_num(v::Real)::String
    f = Float64(v)
    return isfinite(f) ? string(f) : ""
end

function csv_response(result)::HTTP.Response
    t = IOBuffer()
    print(t, "x,y,yhat,residual\r\n")
    for i in 1:result.n
        print(t, csv_num(result.x[i]), ",", csv_num(result.y[i]), ",",
              csv_num(result.yhat[i]), ",", csv_num(result.resid[i]), "\r\n")
    end
    print(t, "\r\nstatistic,value\r\n")
    for (k, v) in (("n", result.n), ("b", result.b), ("a", result.a),
                   ("r", result.r), ("r2", result.r2), ("se", result.se),
                   ("mae", result.mae), ("rmse", result.rmse))
        print(t, k, ",", csv_num(v), "\r\n")
    end
    return HTTP.Response(200; body = take!(t),
        headers = ["Content-Type" => "text/csv; charset=utf-8",
                   "Content-Disposition" => "attachment; filename=\"regression.csv\""])
end
