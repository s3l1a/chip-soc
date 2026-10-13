# Formal Checks

The proof harnesses in `formal/` instantiate the actual divider, arbiter and
peripheral RTL rather than shadow models.

## Proof Jobs

Run from `F:\chip\formal` (or the corresponding directory on another platform):

```text
sby --sequential -f divider.sby prove cover
sby --sequential -f bus_arbiter.sby prove cover
```

Dependencies: SymbiYosys, Yosys with SystemVerilog/formal support, `yosys-smtbmc`,
and Z3 available as `z3` on PATH. The user-local pip distribution
`yowasp-yosys==0.69.0.0.post1233` includes `yowasp-yosys`, `yowasp-sby`, and
`yowasp-yosys-smtbmc`. The pinned user-local solver is `z3-solver==4.15.4.0`;
its Windows wheel supplies `z3.exe`. Install the dependencies with:

```text
python -m pip install --user yowasp-yosys==0.69.0.0.post1233 z3-solver==4.15.4.0
```

For the tested Windows Python 3.14 installation, configure PATH in the current
PowerShell session only (no global environment changes):

```powershell
$tools = "$env:APPDATA\Python\Python314\Scripts"
$z3bin = "$env:APPDATA\Python\bin"
$z3lib = "$env:APPDATA\Python\Python314\site-packages\z3\lib"
$env:PATH = "$tools;$z3bin;$z3lib;$env:PATH"
z3 -version
```

The executable is under the user Python `bin` directory, not its versioned
`Scripts` directory. The DLL directory is also included so `z3.exe` can load its
runtime dependencies. When using this distribution instead of native tools:

```text
yowasp-sby --yosys yowasp-yosys --smtbmc yowasp-yosys-smtbmc --witness yowasp-yosys-witness --sequential -f divider.sby prove cover
yowasp-sby --yosys yowasp-yosys --smtbmc yowasp-yosys-smtbmc --witness yowasp-yosys-witness --sequential -f bus_arbiter.sby prove cover
```

Its Scripts directory must be on PATH for these commands; the SMT solver is still
a separate dependency. `prove` uses bounded checking plus temporal induction,
not merely a finite simulation. `cover` requests witnesses and is not a proof.
SBY writes per-task directories under this directory. Do not interpret parser,
elaboration, SMT generation, or a failed engine launch as a passed proof.
Run tasks of the same job sequentially: separate concurrent invocations can race
on SBY's shared SQLite status database on Windows. Independent jobs may run in
parallel.

### Divider

`divider_formal.sv` instantiates the actual `rtl/core/divider.sv`. It assumes
reset low on the first sampled clock and high thereafter. Operands, modes, and
`start` are otherwise unconstrained, including changes or additional starts
while busy; there is no fairness assumption.

For every accepted nonzero-divisor operation, assertions require busy through
32 iterations and exactly the expected completion, with no concurrent busy/done,
unsolicited done, or premature completion. In sampled pre-edge terms, `age=0`
is the first busy sample after acceptance and `age=32` observes completion.
The RTL generates done just after the 32nd iteration edge. Divide-by-zero must
complete immediately after its acceptance edge with the RISC-V quotient or
remainder result. An in-progress operation must not change the result register.
Cover points exercise normal completion, an ignored busy start, and both
divide-by-zero modes.

This job verifies completion/control behavior and divide-by-zero results, not
the full arithmetic correctness of arbitrary nonzero division, signed overflow,
or the CPU instruction decoder.

### Arbiter

`bus_arbiter_formal.sv` instantiates the actual flattened `bus_arbiter` and the
protocol monitor. A synchronous harness assumes one initial sampled reset and
no subsequent reset. `async2sync` normalizes the DUT's asynchronous control reset
for the single-clock proof model; asynchronous reset-release timing is not proven.

Assumptions constrain only legal master requests and slave responses:

- Word alignment and legal request lengths (read 0/7, write 0).
- A stalled master retains request valid and the complete payload.
- Slave responses belong to an accepted outstanding request.
- Slave response payload/valid remain stable under backpressure.
- Response counts and last markers are legal, including early final errors.

Master response ready, slave request ready, and response arrival are otherwise
unconstrained and may stall forever. No fairness is needed or assumed for these
safety properties. There is no eventual-service assertion; proving bounded
arbitration latency would additionally require bounded slave progress and owner
response-consumption assumptions.

Assertions check exclusive request acceptance, correct payload selection,
round-robin priority, a held pre-acceptance grant, single outstanding ownership,
owner-only response routing, and lock retention through consumption of the final
response. Covers exercise both masters completing, a stalled final beat, a late
contender during request stall, and an eight-beat read.

Induction also needs reachable-state invariants that rule out a simultaneous
active transaction and pending unaccepted grant. `bus_arbiter_setup.ys` exposes
the actual DUT's five control registers as proof-only observation ports and
connects them to the harness. The harness **asserts**, rather than assumes,
their equality to its transaction/priority/grant model. The protocol monitor
also asserts that outstanding beat counts are 1 through 8, writes have exactly
one remaining beat, and idle counts are zero. These are strengthening lemmas,
not extra environment restrictions or replacement RTL. The shipped RTL ports
and source files are unchanged. Always use the setup script when elaborating
this harness, including standalone SAT checks.

### UART FIFO Bounds

`peripherals_fifo.sby` verifies the actual `rtl/peripherals/peripherals.sv`
instance with `CLK_HZ=1843200`, `BAUD=115200`, and therefore `BIT_CLKS=16`.
It requires the native Yosys `slang` plugin, tested with OSS CAD Suite snapshot
`20261011`, Yosys `0.69+274` (git `7513f8df8`); the pip Yowasp frontend alone is
not used for this job. Install the suite as described in [Tooling](../docs/tooling.md).
From the repository's `formal` directory, after the Python/Z3 PATH setup above,
select the suite installation (adjust its path if needed):

```powershell
$suite = Join-Path $env:TEMP 'chip-tools\oss-cad-suite'
$env:PATH = "$z3bin;$z3lib;$suite\bin;$suite\lib;$tools;$env:PATH"
yowasp-sby --yosys "$suite/bin/yosys.exe" --smtbmc "$suite/bin/yosys-smtbmc.exe" --witness "$suite/bin/yosys-witness.exe" --sequential -f peripherals_fifo.sby prove cover
```

On other systems with native SBY and Yosys/Slang configured:

```text
sby --sequential -f peripherals_fifo.sby prove cover
```

`peripherals_fifo_setup.ys` exposes the actual TX/RX counts, circular read/write
pointers, and push/pop events, then connects them to observational harness wires.
It flattens and optimizes the real DUT after making those connections; unrelated
timer/GPIO logic and unobserved FIFO payload state can be removed by the normal
cone-of-influence optimization. There is no replacement FIFO, stub UART receiver,
or assumption that the counts already satisfy the desired bounds.

The harness uses explicit top-level inputs for symbolic stimulus. It assumes
reset low on the first sampled clock and high thereafter, word alignment when
request valid, and stable valid/payload while a request is stalled. Addresses
are otherwise unrestricted, including invalid peripheral addresses; write
strobes and write data are arbitrary. There is no request length port on this
actual DUT. Response ready and request arrival may stall forever. `uart_rx` is
unconstrained on every sampled clock, including arbitrary noise or malformed
frames; the actual two-flop synchronizer and receiver state machine are retained.
No fairness or serial-input stability assumption is imposed.

Assertions prove TX and RX counts remain from zero through 16, pointer distance
equals count modulo 16, empty FIFOs cannot pop, full FIFOs cannot push without
a simultaneous pop, and each count/pointer changes exactly according to the
previous sampled push/pop events. `async2sync` provides the same single-clock,
sampled-reset model as the other jobs; analog metastability and asynchronous
reset-release timing are not covered.

Five covers exercise TX full, rejected full TX write, simultaneous TX push/pop,
an actual received-byte push, and a software RX pop. The cover bound is 256 steps
with queries starting at step 170: all transitions and assumptions from reset
through step 169 remain in the model. This skips expensive early unreachable
serial-event queries, not the reset or DUT execution. Witnesses are not claimed
to be shortest traces. The job allows 300 seconds; a recorded cover run took
165 seconds locally. Runtime depends on the host and tool versions.

The proof scope is FIFO control/bounds at the stated parameterization, not FIFO
payload ordering, complete bus side-effect correctness, all parameter values,
UART electrical/timing correctness, or video CDC. The bounded cover task has no
RX-full cover point; the RX count bound is nevertheless proved for all future
sampled cycles under the assumptions above. No video proof is provided.

Video's CPU vblank status now crosses from a registered pixel-domain decode through
two CPU synchronizer stages. `sim/unit/tb_video.sv` checks that digital latency and
flip-acknowledgment/status timing at two clock ratios; see [Video](../docs/video.md). This is
simulation coverage, not an extension of the FIFO proof or analog CDC signoff.
Palette reads remain continuous while RGB is disabled, so same-entry dual-clock
read/write collision behavior is still target-dependent and unproven by this job.

An initial development harness used attribute-only `anyseq` registers. In the
tested Slang frontend they remained undriven nets and optimization lost shared
input/reset coherence, producing invalid step-2 failures and cover witnesses.
Those runs are superseded by the explicit-input harness and its passing jobs;
they are not RTL counterexamples.

## Integration Monitors

These are observational modules; they never drive the protocol or repair errors.
They work in simulation with immediate assertions and `$fatal`. Under `FORMAL`
they use plain immediate assertions accepted by Yosys. Both require a sampled
reset before checks are meaningful.

### `protocol_monitor`

All ports are flattened. Inputs: `clk`, `rst_n`, `req_valid`, `req_ready`,
`req_addr[31:0]`, `req_write`, `req_wstrb[3:0]`, `req_wdata[31:0]`, `req_len[2:0]`,
`rsp_valid`, `rsp_ready`, `rsp_rdata[31:0]`, `rsp_error`, and `rsp_last`.
Outputs: `outstanding` and `remaining_beats[3:0]`, reflecting accepted state.
Unused status outputs may be left unconnected. A single-beat CPU-facing port
without a length signal should connect `req_len` to `3'd0`.

The checker verifies request and response stability under backpressure, legal
alignment/length, at most one accepted outstanding request, no unsolicited or
extra responses, and exact burst termination unless an error ends it early.
Ownership remains active until a final response handshake, not merely assertion
of final response valid. Accepting a new request on that same edge is rejected;
the checked contract is the non-overlapping protocol used by these RTL blocks.
It does not check memory data values or eventual response arrival. It cannot
distinguish replay of an identical payload during a later, otherwise legal
transaction without transaction IDs or a data scoreboard.

Packed `soc_pkg` interfaces can connect their fields at the instantiation site;
this monitor has no package dependency. For an arbiter, instantiate per master
and on the downstream port to check each flattened channel independently.

### `x0_monitor`

Inputs: `clk`, `rst_n`, `x0_value[31:0]`, `rs1_index[4:0]`, `rs1_value[31:0]`,
`rs2_index[4:0]`, `rs2_value[31:0]`, `retire_valid`, `retire_rd[4:0]`, and
`retire_result[31:0]`. There are no outputs or parameters.

Connect these to the actual CPU `rf[0]`, `rs1`, `a`, `rs2`, `b`, `trace_valid`,
`trace.rd`, and `trace.result`, respectively, from a testbench or
wrapper. It checks x0 storage, zero-valued x0 operand reads, and zero-valued
retirement results for destination x0. It does not prove x0 behavior on its own.
No CPU x0 SBY job is provided: the current CPU uses package-qualified struct
ports unsupported by the selected `read_verilog -sv` frontend. A stand-in register
file would not constitute a proof of the real CPU, so none is substituted.

## Local Validation

All six divider, arbiter and FIFO prove/cover tasks were rerun and passed for the
release RTL. The tables below describe their unchanged assertions and bounds,
not full CPU/SoC or video CDC proofs.

The four divider/arbiter SBY tasks completed with `PASS` and exit code zero using
`yowasp-yosys==0.69.0.0.post1233` and `z3-solver==4.15.4.0`:

| Task | Result | Scope |
| --- | --- | --- |
| Divider prove | PASS | 40-step base check plus successful k-induction; unbounded proof of the listed assertions |
| Divider cover | PASS | All four covers reached within the 40-step bound; last witnesses at step 35 |
| Arbiter prove | PASS | 24-step base check plus successful k-induction; unbounded proof of the listed assertions |
| Arbiter cover | PASS | All four covers reached within the 32-step bound; last witness at step 6 |

The FIFO job used the native suite Yosys/Slang and SMTBMC tools with the same
pinned user-local Z3 4.15.4 solver. Both tasks completed with `PASS`, exit code zero:

| Task | Result | Scope |
| --- | --- | --- |
| FIFO prove | PASS | 20-step base check plus successful k-induction; unbounded proof of the listed count/pointer assertions |
| FIFO cover | PASS | All five covers reached at step 170 within the 256-step bound, with early query skip enabled |

Proof results are not limited to the 40-, 24-, or 20-step base checks: induction establishes the
assertions for all future sampled cycles under the documented assumptions.
Cover results are bounded reachability witnesses, not proofs. Generated VCD and
Yosys witnesses are under `divider_cover/engine_0/` and
`bus_arbiter_cover/engine_0/`; FIFO cover witnesses are under
`peripherals_fifo_cover/engine_0/`.

The initial arbiter run passed its base check but returned `UNKNOWN` on induction
because arbitrary inductive initial states admitted inconsistent held-grant and
write/beat-count state. The strengthening lemmas above resolved that harness
issue without changing RTL or assuming the properties being proved. No RTL
counterexample was found.

The formal sources plus their actual divider/arbiter dependencies also passed
pyslang 11 parsing/elaboration with zero diagnostics.

As a solver-independent fallback, Yosys's built-in SAT engine completed bounded
assertion checks for the divider through 40 steps and the arbiter through 24
steps, with the harness assumptions enabled. Both returned
`SAT proof finished - no model found: SUCCESS!`. These are bounded results only,
not temporal-induction proofs and not passed SBY jobs. The reproduction commands
are:

```text
yowasp-yosys -p "read_verilog -formal -sv ../rtl/core/divider.sv divider_formal.sv; prep -top divider_formal -flatten; async2sync; chformal -cover -remove; chformal -lower; opt_clean; sat -seq 40 -set-assumes -prove-asserts -verify -timeout 30"
yowasp-yosys -p "read_verilog -formal -sv ../rtl/interconnect/bus_arbiter.sv protocol_monitor.sv bus_arbiter_formal.sv; script bus_arbiter_setup.ys; flatten; async2sync; chformal -cover -remove; chformal -lower; opt_clean; sat -seq 24 -set-assumes -prove-asserts -verify -timeout 30"
```

For frontend-only checking with Yosys, run from this directory:

```text
yowasp-yosys -p "read_verilog -formal -sv ../rtl/core/divider.sv divider_formal.sv; prep -top divider_formal; async2sync; dffunmap; check"
yowasp-yosys -p "read_verilog -formal -sv ../rtl/interconnect/bus_arbiter.sv protocol_monitor.sv bus_arbiter_formal.sv; script bus_arbiter_setup.ys; async2sync; dffunmap; check"
```

These commands validate formal frontend/elaboration, not the asserted properties.

For the simulation-only monitor smoke test, also from this directory:

```text
iverilog -g2012 -Wall -s tb_monitors -o tb_monitors.vvp protocol_monitor.sv x0_monitor.sv tb_monitors.sv
vvp tb_monitors.vvp
```

`FAIL_CASE=0` must print `PASS tb_monitors`. To exercise checker rejection, run
`vvp tb_monitors.vvp +FAIL_CASE=N` for N from 1 through 8. A compile-time default
can also be selected with `-Ptb_monitors.FAIL_CASE=N`.
Each run must fail at the corresponding monitor assertion, not the bench's
`was not rejected` fallback. Cases are overlapping accepted requests (1), an
unsolicited response (2), a premature non-error last marker (3), a changed stalled
request (4), a changed stalled response (5), nonzero x0 storage (6), a nonzero x0
operand read (7), and a nonzero x0 retirement result (8). This tests the checkers,
not the CPU or the formal harnesses.

The legal monitor test passed with Icarus `-g2012 -Wall`. All eight negative
cases terminated at their intended checker assertion.
