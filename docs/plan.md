# Implementation Gates

The canonical HDL is SystemVerilog. The eight original prototype files used
ambiguous ready-as-completion signaling and were removed rather than retained
as an alternate build. The design uses explicit accepted
requests, held responses, single outstanding transactions, and read bursts.

1. Specify bus, map, licenses and reproducible tooling.
2. Implement and simulate non-overlapped custom CPU, iterative divider, traps.
3. Implement locked arbitration, RAM model and synchronous 16 KiB caches.
4. Implement transaction-safe peripherals and dual-clock BRAM video.
5. Integrate SoC reset-vector boot and bare-metal graphical diagnostic.
6. Add pinned Doom software dependency and platform bindings.
7. Execute available tests; document unavailable acceptance tests honestly.
8. Add CI and local FPGA feasibility commands without producing a bitstream.

Missing tools are not successful gates. Directed simulation is not ISA
certification, formal proof, Verilator Doom acceptance, or hardware validation.
