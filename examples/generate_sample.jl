# One-off script: generate examples/sample.xlsx (not part of src/).
using XLSX

xf = XLSX.newxlsx()
wb = XLSX.get_workbook(xf)
ws = XLSX.addsheet!(wb, "Data")
XLSX.setdata!(ws, XLSX.CellRef("A1"), "x")
XLSX.setdata!(ws, XLSX.CellRef("B1"), "y")
for (i, (x, y)) in enumerate([(1.0, 2.0), (2.0, 4.0), (3.0, 5.0), (4.0, 4.0), (5.0, 6.0)])
    XLSX.setdata!(ws, XLSX.CellRef("A" * string(i + 1)), x)
    XLSX.setdata!(ws, XLSX.CellRef("B" * string(i + 1)), y)
end
XLSX.writexlsx("examples/sample.xlsx", xf; overwrite = true)
println("wrote examples/sample.xlsx")
