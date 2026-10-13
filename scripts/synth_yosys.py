"""XC7 resource assessment of the generic SoC, not board implementation/timing."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--yosys', help='Yosys executable (requires the Slang plugin)')
    parser.add_argument('--out', type=Path, default=root / 'build' / 'synth')
    rom = parser.add_mutually_exclusive_group()
    rom.add_argument('--rom-file', type=Path, help='Override soc_top.ROM_FILE')
    rom.add_argument('--rom-budget', action='store_true',
                     help='Generate a dense 16 KiB ROM image for storage budgeting only')
    args = parser.parse_args()

    portable = Path(os.environ.get('CHIP_TOOL_DIR', str(Path(os.environ.get('TEMP', '/tmp')) / 'chip-tools'))) / 'oss-cad-suite'
    executable = args.yosys or shutil.which('yosys')
    if not executable and (portable / 'bin' / 'yosys.exe').is_file():
        executable = str(portable / 'bin' / 'yosys.exe')
    if not executable:
        parser.error('Yosys not found; use --yosys or the portable suite described in docs/tooling.md')
    resolved = shutil.which(executable) or executable
    yosys = Path(resolved).resolve()
    if not yosys.is_file():
        parser.error(f'Yosys executable does not exist: {yosys}')
    env = os.environ.copy()
    env['PATH'] = os.pathsep.join((str(yosys.parent), str(yosys.parent.parent / 'lib'), env.get('PATH', '')))
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)

    package = root / 'rtl' / 'soc' / 'soc_pkg.sv'
    sources = [package] + sorted(path for path in (root / 'rtl').rglob('*.sv')
                                 if path != package and path != root / 'rtl' / 'memory' / 'sim_ram.sv')
    inputs = {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in sources}
    rom_file = args.rom_file.resolve() if args.rom_file else None
    if args.rom_budget:
        rom_file = out / 'rom_budget.mem'
        state = 0x13579BDF
        words = []
        for _ in range(4096):
            state ^= (state << 13) & 0xFFFFFFFF
            state ^= state >> 17
            state ^= (state << 5) & 0xFFFFFFFF
            words.append(f'{state:08x}')
        rom_file.write_text('@00000000\n' + '\n'.join(words) + '\n', encoding='ascii')
    if rom_file and not rom_file.is_file():
        parser.error(f'ROM image does not exist: {rom_file}')
    rom_hash = hashlib.sha256(rom_file.read_bytes()).hexdigest() if rom_file else None
    version = subprocess.check_output([str(yosys), '-V'], env=env, text=True).strip()

    def yosys_path(path):
        # read_slang receives literal Yosys tokens, including any surrounding quotes.
        value = path.as_posix()
        if any(char.isspace() or char in '";#' for char in value):
            parser.error('Use source, output, and ROM paths without whitespace, quotes, semicolons, or #')
        return value

    frontend = 'read_slang --top soc_top --unroll-limit 65536 --ignore-assertions'
    if rom_file:
        frontend += ' -G ROM_FILE="' + yosys_path(rom_file) + '"'
    frontend += ' ' + ' '.join(yosys_path(path) for path in sources)
    commands = [
        'plugin -i slang',
        frontend,
        'hierarchy -check -top soc_top',
        'proc',
        'opt_clean',
        'memory_collect',
        'write_json ' + yosys_path(out / 'elaborated.json'),
        'synth_xilinx -family xc7 -top soc_top -flatten -noiopad',
        'check -assert -mapped',
        'tee -o ' + yosys_path(out / 'utilization.rpt') + ' stat -tech xilinx -top soc_top',
        'tee -o ' + yosys_path(out / 'stat.json') + ' stat -json -top soc_top',
        'write_json ' + yosys_path(out / 'soc_top.json'),
        'write_edif ' + yosys_path(out / 'soc_top.edif'),
    ]
    script = out / 'synth.ys'
    script.write_text('\n'.join(commands) + '\n', encoding='utf-8')
    invocation = [str(yosys), '-Q', '-T', '-q', '-l', str(out / 'yosys.log'), '-s', str(script)]
    manifest = {
        'started_utc': datetime.now(timezone.utc).isoformat(),
        'target_part_for_capacity_comparison': 'xc7s50csga324-1',
        'mapping_family': 'xc7', 'top': 'soc_top', 'yosys_version': version,
        'command': invocation, 'sources_sha256': inputs,
        'rom_mode': 'dense_storage_budget_only' if args.rom_budget else 'file' if rom_file else 'default_boot_stub',
        'rom_file': str(rom_file) if rom_file else None, 'rom_sha256': rom_hash,
        'io_pads': False, 'timing_closed': False, 'returncode': None,
    }
    # Remove stale success artifacts before a new attempt; preserve the current log on failure.
    for name in ('resources.json', 'utilization.rpt', 'stat.json', 'soc_top.json', 'soc_top.edif', 'elaborated.json'):
        (out / name).unlink(missing_ok=True)
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(version, flush=True)
    print(f'Synthesizing soc_top for xc7, ROM mode {manifest["rom_mode"]}; log: {out / "yosys.log"}', flush=True)
    result = subprocess.run(invocation, cwd=root, env=env)
    manifest['returncode'] = result.returncode
    manifest['inputs_unchanged'] = all(hashlib.sha256(path.read_bytes()).hexdigest() == inputs[path.relative_to(root).as_posix()]
                                       for path in sources)
    if rom_file:
        manifest['inputs_unchanged'] &= hashlib.sha256(rom_file.read_bytes()).hexdigest() == rom_hash
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    if result.returncode:
        print(f'Synthesis failed; inspect {out / "yosys.log"}', file=sys.stderr)
        return 1
    if not manifest['inputs_unchanged']:
        print('RTL/ROM inputs changed during synthesis; rerun before using the resource report.', file=sys.stderr)
        return 1

    mapped = json.loads((out / 'soc_top.json').read_text(encoding='utf-8'))
    mapped_cells = mapped['modules']['soc_top']['cells']
    counts = Counter(cell['type'] for cell in mapped_cells.values())
    elaborated = json.loads((out / 'elaborated.json').read_text(encoding='utf-8'))
    memories = []
    for module_name, module in elaborated['modules'].items():
        for name, cell in module.get('cells', {}).items():
            if cell['type'] == '$mem_v2':
                params = cell['parameters']
                primitives = Counter(mapped_cell['type'] for mapped_name, mapped_cell in mapped_cells.items()
                                     if mapped_name.startswith(name + '.') and mapped_cell['type'].startswith('RAM'))
                memories.append({'module': module_name, 'name': name,
                                 'width': int(params['WIDTH'], 2), 'depth': int(params['SIZE'], 2),
                                 'read_ports': int(params['RD_PORTS'], 2),
                                 'write_ports': int(params['WR_PORTS'], 2),
                                 'attributes': cell.get('attributes', {}),
                                 'mapped_ram_primitives': dict(sorted(primitives.items()))})
    bram_resets = []
    dsps = []
    for name, cell in mapped_cells.items():
        if cell['type'] in ('RAMB18E1', 'RAMB36E1'):
            inactive = all(cell['connections'].get(pin) == ['0'] and
                           int(cell['parameters'].get('IS_' + pin + '_INVERTED', '0'), 2) == 0
                           for pin in ('RSTRAMARSTRAM', 'RSTRAMB'))
            bram_resets.append({'name': name, 'ram_output_resets_tied_inactive': inactive})
        if cell['type'] == 'DSP48E1':
            dsps.append({'name': name, 'source': cell.get('attributes', {}).get('src'),
                         'registers': {param: int(cell['parameters'][param], 2)
                                       for param in ('AREG', 'BREG', 'MREG', 'PREG')}})
    report = {
        'target_part_for_capacity_comparison': 'xc7s50csga324-1',
        'logic_luts': sum(counts[f'LUT{i}'] for i in range(1, 7)) + counts['LUT6_2'],
        'flip_flops': sum(count for name, count in counts.items() if name.startswith('FD')),
        'ramb18': counts['RAMB18E1'], 'ramb36': counts['RAMB36E1'],
        'bram36_equivalents': counts['RAMB36E1'] + counts['RAMB18E1'] / 2,
        'dsp48e1': counts['DSP48E1'],
        'clock_buffers': {name: count for name, count in sorted(counts.items()) if name.startswith(('BUFG', 'BUFH', 'BUFR', 'BUFIO'))},
        'lutram_primitives': {name: count for name, count in sorted(counts.items()) if name.startswith('RAM') and not name.startswith('RAMB')},
        'cells_by_type': dict(sorted(counts.items())), 'logical_memories_before_optimization': memories,
        'bram_output_reset_audit': bram_resets, 'dsp_register_audit': dsps,
        'timing_closed': False,
    }
    (out / 'resources.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: value for key, value in report.items()
                      if key not in ('cells_by_type', 'logical_memories_before_optimization',
                                     'bram_output_reset_audit', 'dsp_register_audit')}, indent=2))
    print(f'Artifacts: {out}. Capacity assessment only; no package fit, placement, routing, or timing closure.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
