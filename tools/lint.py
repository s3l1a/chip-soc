"""SystemVerilog parsing and elaboration with pinned pyslang."""
import pathlib
import sys
from pyslang import ast, syntax, DiagnosticEngine, TextDiagnosticClient

root = pathlib.Path(__file__).resolve().parents[1]
files = [root / 'rtl/soc/soc_pkg.sv']
files += sorted(p for p in (root / 'rtl').rglob('*.sv') if p not in files)
comp = ast.Compilation()
for file in files:
    comp.addSyntaxTree(syntax.SyntaxTree.fromFile(str(file)))
engine = DiagnosticEngine(comp.sourceManager)
client = TextDiagnosticClient()
engine.addClient(client)
errors = 0
for diagnostic in comp.getAllDiagnostics():
    engine.issue(diagnostic)
    errors += diagnostic.isError()
print(client.getString())
print(f'Elaborated {len(files)} SystemVerilog files; {errors} errors')
sys.exit(bool(errors))
