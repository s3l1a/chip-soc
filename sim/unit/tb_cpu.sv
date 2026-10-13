`timescale 1ns/1ps
module tb_cpu;
    import soc_pkg::*;
    logic clk = 0;
    always #5 clk = !clk;
    logic rst_n = 0, timer_irq = 0;
    logic i_valid, i_ready = 0, i_rsp_valid = 0, i_rsp_ready;
    logic d_valid, d_ready = 0, d_rsp_valid = 0, d_rsp_ready;
    logic fence_i, fence_done = 0, trace_valid;
    req_t i_req, d_req;
    rsp_t i_rsp = '0, d_rsp = '0;
    trace_t trace;
    rv32im_cpu dut (.*);

    logic [31:0] memory [0:33791];
    logic [31:0] rng = 32'h1205abcd;
    logic [31:0] seed;
    integer max_delay = 17, cycles = 0, checked = 0, requests = 0;
    integer i_delay = 0, d_delay = 0, fence_delay = 0;
    integer i_stalls = 0, d_stalls = 0, fence_stalls = 0;
    logic i_busy = 0, d_busy = 0, fence_busy = 0;
    req_t i_pending, d_pending;
    logic [31:0] fetched_pc;
    logic [63:0] reference_cycle = 0, cycle_before;
    logic [31:0] reference_regs [0:31];
    logic [31:0] cycle_csr_old, cycle_csr_source, cycle_csr_new;
    logic [11:0] cycle_csr_address;
    logic [2:0] cycle_csr_f3;
    logic cycle_csr_write;
    logic i_stalled = 0, d_stalled = 0, ir_stalled = 0, dr_stalled = 0;
    req_t held_i, held_d;
    rsp_t held_ir, held_dr;
    integer golden_file, bus_file, event_file, trace_file, scanned;
    logic [63:0] expected_order;
    logic [31:0] expected_pc, expected_insn, expected_next, expected_result;
    logic [31:0] expected_cause, expected_tval, result_mask;
    integer expected_rd, expected_trap;
    logic [31:0] bus_addr, bus_data, bus_data_mask;
    integer bus_write, bus_strb, bus_len, bus_strb_mask;
    integer event_kind, event_level, events = 0;
    logic [31:0] event_address;
    logic have_event = 0;
    string directory = "sim/generated", actual = "sim/generated/cpu.trace";

    task automatic next_event;
        scanned = $fscanf(event_file, "%h %h %h\n", event_kind, event_address, event_level);
        have_event = scanned == 3;
        if (scanned != 3 && !$feof(event_file)) $fatal(1, "malformed IRQ event file");
    endtask

    task automatic check_end;
        if (have_event) $fatal(1, "unconsumed IRQ event kind=%0d addr=%h", event_kind, event_address);
        scanned = $fscanf(bus_file, "%h %h %h %h %h %h %h\n", bus_addr, bus_write, bus_strb, bus_data, bus_len, bus_strb_mask, bus_data_mask);
        if (scanned == 7) $fatal(1, "missing data request at end");
        if (i_busy || d_busy || fence_i) $fatal(1, "outstanding transaction at end");
        // A one-request CSR regression may legitimately see ready immediately.
        if (!i_stalls || (requests > 1 && !d_stalls)) $fatal(1, "latency/backpressure coverage missing");
        $fclose(trace_file);
        $display("PASS tb_cpu: trace=%0d data=%0d irq_events=%0d cycles=%0d seed=%h stalls(i/d/f)=%0d/%0d/%0d",
                 checked, requests, events, cycles, seed, i_stalls, d_stalls, fence_stalls);
        $finish;
    endtask

    initial begin
        if ($value$plusargs("DIR=%s", directory)) begin end
        if ($value$plusargs("TRACE=%s", actual)) begin end
        if ($value$plusargs("SEED=%d", seed)) rng = seed;
        else seed = rng;
        if ($value$plusargs("MAX_DELAY=%d", max_delay)) begin end
        if (max_delay < 1 || max_delay > 1000 || rng == 0) $fatal(1, "invalid latency or seed");
        for (integer j = 0; j < 33792; j = j + 1) memory[j] = 0;
        for (integer j = 0; j < 32; j = j + 1) reference_regs[j] = 0;
        $readmemh({directory, "/cpu.hex"}, memory);
        golden_file = $fopen({directory, "/cpu.golden"}, "r");
        bus_file = $fopen({directory, "/cpu.bus"}, "r");
        event_file = $fopen({directory, "/cpu.events"}, "r");
        trace_file = $fopen(actual, "w");
        if (!golden_file || !bus_file || !event_file || !trace_file) $fatal(1, "cannot open vector/trace files");
        next_event();
        repeat (4) @(negedge clk);
        rst_n = 1;
    end

    // Ready changes only on the falling edge; responses hold until accepted.
    always @(negedge clk) begin
        rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
        i_ready = rst_n && !i_busy && rng[2:0] == 0;
        d_ready = rst_n && !d_busy && rng[5:3] == 0;
    end

    always @(posedge clk) if (!rst_n) reference_cycle = 0;
    else begin
        reference_cycle = reference_cycle + 1;
        cycles = cycles + 1;
        if (cycles > 3000000 + max_delay * 50000) $fatal(1, "CPU watchdog entry=%0d", checked);
        if (i_stalled && (!i_valid || i_req !== held_i)) $fatal(1, "instruction request changed under stall");
        if (d_stalled && (!d_valid || d_req !== held_d)) $fatal(1, "data request changed under stall");
        if (ir_stalled && (!i_rsp_valid || i_rsp !== held_ir)) $fatal(1, "instruction response changed under stall");
        if (dr_stalled && (!d_rsp_valid || d_rsp !== held_dr)) $fatal(1, "data response changed under stall");
        i_stalled = i_valid && !i_ready; held_i = i_req;
        d_stalled = d_valid && !d_ready; held_d = d_req;
        ir_stalled = i_rsp_valid && !i_rsp_ready; held_ir = i_rsp;
        dr_stalled = d_rsp_valid && !d_rsp_ready; held_dr = d_rsp;
        if (i_stalled) i_stalls = i_stalls + 1;
        if (d_stalled) d_stalls = d_stalls + 1;
        if (i_valid && i_ready) begin
            if (i_busy || d_busy || fence_i || i_req.write !== 1'b0 || i_req.len !== 3'b0 || i_req.strb !== 4'b0 ||
                i_req.data !== 32'b0 || i_req.addr[1:0] !== 2'b0)
                $fatal(1, "invalid instruction request");
            i_pending = i_req; fetched_pc = i_req.addr;
            i_busy = 1; i_delay = 1 + (int'(rng[31:16]) % max_delay);
        end else if (i_busy && !i_rsp_valid) begin
            if (i_delay > 0) i_delay = i_delay - 1;
            else begin
                i_rsp_valid <= 1;
                i_rsp.error <= i_pending.addr >= 32'h00030000;
                i_rsp.last <= 1;
                i_rsp.data <= i_pending.addr < 32'h00021000 ? memory[i_pending.addr >> 2] : 0;
            end
        end
        if (i_rsp_valid && i_rsp_ready) begin
            if (!i_busy || !i_rsp.last) $fatal(1, "unsolicited instruction response");
            i_rsp_valid <= 0; i_busy = 0; i_rsp <= 'x;
        end
        if (d_valid && d_ready) begin
            if (d_busy || i_busy || d_req.len !== 3'b0 || d_req.addr[1:0] !== 2'b0) $fatal(1, "invalid data request");
            scanned = $fscanf(bus_file, "%h %h %h %h %h %h %h\n", bus_addr, bus_write, bus_strb, bus_data, bus_len, bus_strb_mask, bus_data_mask);
            if (scanned != 7) $fatal(1, "unexpected data request");
            if (d_req.addr !== bus_addr || d_req.write !== (bus_write != 0) || d_req.len !== bus_len[2:0] ||
                ((d_req.strb ^ bus_strb[3:0]) & bus_strb_mask[3:0]) !== 0 || ((d_req.data ^ bus_data) & bus_data_mask) !== 0)
                $fatal(1, "data request %0d pc=%h addr=%h/%h write=%b/%b strb=%h/%h data=%h/%h", requests,
                       fetched_pc, d_req.addr, bus_addr, d_req.write, bus_write, d_req.strb, bus_strb, d_req.data, bus_data);
            requests = requests + 1;
            d_pending = d_req; d_busy = 1; d_delay = 1 + (int'(rng[15:0]) % max_delay);
        end else if (d_busy && !d_rsp_valid) begin
            if (d_delay > 0) d_delay = d_delay - 1;
            else begin
                d_rsp_valid <= 1; d_rsp.last <= 1;
                d_rsp.error <= d_pending.addr >= 32'h00030000;
                d_rsp.data <= d_pending.addr < 32'h00021000 ? memory[d_pending.addr >> 2] : 0;
                if (d_pending.write && d_pending.addr < 32'h00021000)
                    for (integer lane = 0; lane < 4; lane = lane + 1)
                        if ((d_pending.strb >> lane) & 1)
                            memory[d_pending.addr >> 2][8*lane +: 8] <= 8'(d_pending.data >> (8*lane));
            end
        end
        if (d_rsp_valid && d_rsp_ready) begin
            if (!d_busy || !d_rsp.last) $fatal(1, "unsolicited data response");
            d_rsp_valid <= 0; d_busy = 0; d_rsp <= 'x;
        end
        if (fence_i) begin
            fence_stalls = fence_stalls + 1;
            if (i_busy || d_busy || i_valid || d_valid) $fatal(1, "fence overlaps bus transaction");
            if (!fence_busy) begin
                fence_busy = 1; fence_delay = 2 + (int'(rng[23:8]) % max_delay);
            end else if (fence_delay > 0) fence_delay = fence_delay - 1;
            else fence_done <= 1;
        end else begin
            if (fence_busy && !fence_done) $fatal(1, "fence abandoned before done");
            fence_busy = 0; fence_done <= 0;
        end
        if (have_event && ((event_kind == 0 && i_valid && i_ready && i_req.addr == event_address) ||
                          (event_kind == 1 && d_valid && d_ready && d_req.addr == event_address) ||
                          (event_kind == 2 && fence_i && fetched_pc == event_address) ||
                          (event_kind == 3 && dut.div_busy && fetched_pc == event_address))) begin
            timer_irq <= event_level != 0;
            events = events + 1;
            next_event();
        end
    end

    // Sample after NBA updates so the trace belongs to the just-completed edge.
    always @(negedge clk) if (rst_n && trace_valid) begin
        scanned = $fscanf(golden_file, "%h %h %h %h %h %h %h %h %h %h\n", expected_order,
                          expected_pc, expected_insn, expected_next, expected_rd, expected_result,
                          expected_trap, expected_cause, expected_tval, result_mask);
        $fdisplay(trace_file, "%h %h %h %h %h %h %h %h %h", trace.order, trace.pc, trace.insn,
                  trace.next_pc, trace.rd, trace.result, trace.trap, trace.cause, trace.tval);
        if (scanned != 10) $fatal(1, "unexpected retirement entry %0d", checked);
        cycle_before = reference_cycle - 1;
        cycle_csr_address = expected_insn[31:20];
        cycle_csr_f3 = expected_insn[14:12];
        if (!expected_trap && expected_insn[6:0] == 7'h73 && cycle_csr_f3 != 0 &&
            (cycle_csr_address == 12'hb00 || cycle_csr_address == 12'hb80 ||
             cycle_csr_address == 12'hc00 || cycle_csr_address == 12'hc80)) begin
            cycle_csr_old = cycle_csr_address[7] ? cycle_before[63:32] : cycle_before[31:0];
            cycle_csr_source = cycle_csr_f3[2] ? {27'b0, expected_insn[19:15]} : reference_regs[expected_insn[19:15]];
            cycle_csr_write = cycle_csr_f3[1:0] == 1 || expected_insn[19:15] != 0;
            case (cycle_csr_f3[1:0])
                1: cycle_csr_new = cycle_csr_source;
                2: cycle_csr_new = cycle_csr_old | cycle_csr_source;
                default: cycle_csr_new = cycle_csr_old & ~cycle_csr_source;
            endcase
            expected_result = expected_rd == 0 ? 0 : cycle_csr_old;
            result_mask = 32'hffffffff;
            if (cycle_csr_write && cycle_csr_address[11:8] == 4'hb) begin
                // An explicit counter-half write overrides that edge's increment.
                reference_cycle = cycle_csr_address[7] ? {cycle_csr_new, cycle_before[31:0]} :
                                                        {cycle_before[63:32], cycle_csr_new};
            end
        end
        if (trace.order !== expected_order || trace.pc !== expected_pc || trace.insn !== expected_insn ||
            trace.next_pc !== expected_next || trace.rd !== expected_rd[4:0] ||
            ((trace.result ^ expected_result) & result_mask) !== 0 || trace.trap !== (expected_trap != 0) ||
            trace.cause !== expected_cause || trace.tval !== expected_tval)
            $fatal(1, "trace %0d pc=%h/%h insn=%h/%h next=%h/%h rd=%0d/%0d result=%h/%h trap=%b/%b cause=%h/%h tval=%h/%h",
                   checked, trace.pc, expected_pc, trace.insn, expected_insn, trace.next_pc, expected_next,
                   trace.rd, expected_rd, trace.result, expected_result, trace.trap, expected_trap,
                   trace.cause, expected_cause, trace.tval, expected_tval);
        if (i_busy || d_busy || dut.div_busy || (fence_i && !fence_done))
            $fatal(1, "retirement while a delayed operation is outstanding");
        if (!expected_trap && expected_insn[6:0] == 7'h0f && expected_insn[14:12] == 1 && fence_done !== 1'b1)
            $fatal(1, "FENCE.I retired without delayed completion");
        if (expected_rd != 0) reference_regs[expected_rd] = expected_result;
        checked = checked + 1;
        if ($feof(golden_file) != 0) check_end();
    end
endmodule
