"""Build with an installed newlib toolchain; never install or download tools."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser()
p.add_argument('targets',nargs='*',default=['all'])
p.add_argument('--cross',default=os.environ.get('CROSS'))
args=p.parse_args()
cross=args.cross or next((x for x in ['riscv-none-elf-','riscv32-unknown-elf-','riscv64-unknown-elf-'] if shutil.which(x+'gcc')),None)
make=shutil.which('make')
if os.name=='nt':
    packs=Path(os.environ['APPDATA'])/'xPacks/@xpack-dev-tools'
    if cross is None:
        gcc=packs/'riscv-none-elf-gcc/15.2.0-1.1/.content/bin/riscv-none-elf-gcc.exe'
        if gcc.exists(): cross=str(gcc).replace('\\','/').removesuffix('gcc.exe')
    tools=packs/'windows-build-tools/4.4.1-3.1/.content/bin'
    if not make and (tools/'make.exe').exists():
        make=str(tools/'make.exe')
        os.environ['PATH']=str(tools)+';'+os.environ['PATH']
if not cross or not make:
    raise SystemExit('MISSING newlib RISC-V GCC or Make. See docs/software.md. Build NOT EXECUTED.')
python=(shutil.which('python') or 'python3').replace('\\','/')
cmd=[make,'-C','firmware',*args.targets,f'CROSS={cross}',f'PYTHON={python}']
print('+',' '.join(cmd),flush=True)
subprocess.run(cmd,cwd=root,check=True)
