"""Reproducible lint, unit, SoC simulation, and report entry point."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
TOOLS = Path(os.environ.get('CHIP_TOOL_DIR', str(Path(os.environ.get('TEMP', '/tmp')) / 'chip-tools')))

def command(args, **kwargs):
    print('+', ' '.join(map(str,args)), flush=True)
    subprocess.run(list(map(str,args)), cwd=ROOT, check=True, **kwargs)

def find(name):
    found = shutil.which(name)
    if not found and os.name == 'nt':
        candidates = [TOOLS/'iverilog-v14/bin'/f'{name}.exe', TOOLS/'oss-cad-suite/bin'/f'{name}.exe']
        found = next((str(p) for p in candidates if p.exists()), None)
    if not found:
        raise SystemExit(f'MISSING TOOL: {name}. See docs/tooling.md; test NOT EXECUTED.')
    return found

def sources():
    return ['rtl/soc/soc_pkg.sv'] + sorted(str(p.relative_to(ROOT)).replace('\\','/') for p in (ROOT/'rtl').rglob('*.sv') if p.name!='soc_pkg.sv')

def unit():
    command([sys.executable,'tools/cpu_vectors.py'])
    for top, files in {
        'tb_plusargs': [],
        'tb_cpu': ['rtl/soc/soc_pkg.sv','rtl/core/divider.sv','rtl/core/rv32im_cpu.sv'],
        'tb_divider': ['rtl/core/divider.sv'],
        'tb_cache': ['rtl/cache/direct_mapped_cache.sv','rtl/memory/sim_ram.sv'],
        'tb_bus': ['rtl/interconnect/bus_arbiter.sv','rtl/memory/sim_ram.sv'],
        'tb_peripherals': ['rtl/peripherals/peripherals.sv'],
        'tb_video': ['rtl/video/video_core.sv'],
    }.items():
        output=ROOT/'build/unit'/f'{top}.vvp'
        output.parent.mkdir(parents=True,exist_ok=True)
        command([find('iverilog'),'-g2012','-s',top,'-o',output,*files,f'sim/unit/{top}.sv'])
        extra = ['+PREFIX=regression','+FRAMES=1','+CYCLES=12345678901'] if top == 'tb_plusargs' else []
        command([find('vvp'),output,*extra])
    command([sys.executable,'tools/check_trace.py','sim/generated/cpu.golden','sim/generated/cpu.trace'])
    command([sys.executable,'software/test_tools.py'])

def verilator():
    if os.name=='nt' and (TOOLS/'oss-cad-suite/bin/verilator_bin.exe').exists():
        cad=TOOLS/'oss-cad-suite'; gcc=TOOLS/'winlibs-gcc15/mingw64/bin'
        os.environ['PATH']=f'{gcc};{cad}/bin;{cad}/lib;C:/Program Files/Git/usr/bin;'+os.environ['PATH']
        os.environ['VERILATOR_ROOT']=str(cad/'share/verilator').replace('\\','/')
        os.environ['MAKE']='mingw32-make'
        return str(cad/'bin/verilator_bin.exe')
    return find('verilator')

def soc(args):
    out=ROOT/'build/soc'; out.mkdir(parents=True,exist_ok=True)
    if args.engine=='verilator':
        tool=verilator()
        exe=out/('Vtb_soc.exe' if os.name=='nt' else 'Vtb_soc')
        if not args.no_build:
            flags=['-CFLAGS','-std=c++20','-MAKEFLAGS','SHELL=sh PYTHON3=python3'] if os.name=='nt' else []
            command([tool,'--binary','--timing','--assert','-Wno-fatal','--top-module','tb_soc','--Mdir',str(out).replace('\\','/'),'-j','4',*flags,*sources(),'formal/protocol_monitor.sv','sim/soc/tb_soc.sv'])
    else:
        exe=out/'tb_soc.vvp'
        if not args.no_build:
            command([find('iverilog'),'-g2012','-s','tb_soc','-o',exe,*sources(),'formal/protocol_monitor.sv','sim/soc/tb_soc.sv'])
    cmd=[exe] if args.engine=='verilator' else [find('vvp'),exe]
    cmd += [f'+FIRMWARE={args.firmware}',f'+FRAMES={args.frames}',f'+CYCLES={args.cycles}',f'+PREFIX=build/soc/{args.prefix}']
    if args.wad: cmd.append(f'+WAD={args.wad}')
    started=time.monotonic()
    print('+', ' '.join(map(str,cmd)),flush=True)
    result=subprocess.run(list(map(str,cmd)),cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    log=out/f'{args.prefix}.log'
    log.write_text(result.stdout,encoding='utf-8')
    print(result.stdout,flush=True)
    print(f'Wall seconds: {time.monotonic()-started:.3f}; log: {log}')
    result.check_returncode()
    for path in sorted(out.glob(f'{args.prefix}_*.ppm')):
        print(path.name,hashlib.sha256(path.read_bytes()).hexdigest())

def main():
    p=argparse.ArgumentParser(); p.add_argument('task',choices=['lint','unit','soc','report'])
    p.add_argument('--engine',choices=['iverilog','verilator'],default='verilator')
    p.add_argument('--no-build',action='store_true'); p.add_argument('--firmware',default='firmware/build/diagnostic.mem')
    p.add_argument('--wad'); p.add_argument('--frames',type=int,default=1)
    p.add_argument('--cycles',type=int,default=100000000); p.add_argument('--prefix',default='frame')
    args=p.parse_args()
    if args.task=='lint': command([sys.executable,'tools/lint.py'])
    elif args.task=='unit': unit()
    elif args.task=='soc': soc(args)
    else:
        for path in sorted((ROOT/'build/soc').glob('*.ppm')):
            print(path.name,hashlib.sha256(path.read_bytes()).hexdigest())

if __name__=='__main__': main()
