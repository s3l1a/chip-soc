`timescale 1ns/1ps
// SPDX-License-Identifier: MIT
module tb_isa;
    import soc_pkg::*;
    localparam logic [31:0] BASE = 32'h80000000;
    localparam integer RAM_BYTES = 4194304;
    localparam logic [31:0] RAM_END = BASE + RAM_BYTES[31:0];
    logic clk = 0;
    always #5 clk = !clk;
    logic rst_n = 0, timer_irq = 0;
    logic i_valid, i_ready = 0, i_rsp_valid = 0, i_rsp_ready;
    logic d_valid, d_ready = 0, d_rsp_valid = 0, d_rsp_ready;
    req_t i_req, d_req;
    rsp_t i_rsp = '0, d_rsp = '0;
    logic fence_i, fence_done = 0, trace_valid;
    trace_t trace;
    rv32im_cpu #(.RESET_PC(BASE)) dut (.*);

    logic [31:0] memory [0:RAM_BYTES/4-1];
    logic [31:0] rng = 32'h19780503, seed;
    integer max_delay = 11, limit = 2000000, cycles = 0;
    integer i_delay = 0, d_delay = 0, f_delay = 0;
    integer i_count = 0, d_count = 0, i_stalls = 0, d_stalls = 0, traps = 0;
    logic [63:0] retired = 0;
    logic i_busy = 0, d_busy = 0, f_busy = 0;
    logic is_stalled = 0, ds_stalled = 0, ir_stalled = 0, dr_stalled = 0;
    req_t i_pending, d_pending, held_i, held_d;
    rsp_t held_ir, held_dr;
    logic [31:0] fetched_pc, data_pc, last_pc = BASE;
    logic [31:0] tohost, sig_begin = 0, sig_end = 0, host_pc, host_value;
    logic host_pending = 0;
    integer allow_traps = 0, trace_file = 0, signature_file;
    string image, signature, trace_path, name = "unnamed";

    function automatic logic mapped(input logic [31:0] address);
        mapped = address >= BASE && address < RAM_END;
    endfunction

    initial begin
        if (!$value$plusargs("MEM=%s", image) || !$value$plusargs("TOHOST=%h", tohost))
            $fatal(1, "MEM and TOHOST are required");
        if ($value$plusargs("NAME=%s", name)) begin end
        if ($value$plusargs("SEED=%d", seed)) rng = seed;
        else seed = rng;
        if ($value$plusargs("MAX_DELAY=%d", max_delay)) begin end
        if ($value$plusargs("LIMIT=%d", limit)) begin end
        if ($value$plusargs("ALLOW_TRAPS=%d", allow_traps)) begin end
        if ($value$plusargs("SIG_BEGIN=%h", sig_begin)) begin end
        if ($value$plusargs("SIG_END=%h", sig_end)) begin end
        if ($value$plusargs("SIGNATURE=%s", signature)) begin end
        if ($value$plusargs("TRACE=%s", trace_path)) begin
            trace_file = $fopen(trace_path, "w");
            if (!trace_file) $fatal(1, "cannot open trace");
        end
        if (!mapped(tohost) || tohost[1:0] != 0 || rng == 0 || max_delay < 1 || max_delay > 1000 || limit < 1)
            $fatal(1, "invalid ISA run parameters");
        if (signature != "" && (!mapped(sig_begin) || sig_end <= sig_begin || sig_end > RAM_END ||
                                sig_begin[1:0] != 0 || sig_end[1:0] != 0))
            $fatal(1, "invalid signature bounds");
        for (integer j = 0; j < RAM_BYTES/4; j = j + 1) memory[j] = 0;
        $readmemh(image, memory);
        repeat (4) @(negedge clk);
        rst_n = 1;
    end

    always @(negedge clk) begin
        rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
        i_ready = rst_n && !i_busy && rng[1:0] == 0;
        d_ready = rst_n && !d_busy && rng[3:2] == 0;
    end

    always @(posedge clk) if (rst_n) begin
        cycles = cycles + 1;
        if (cycles > limit) $fatal(1, "ISA timeout %s pc=%h retired=%0d traps=%0d", name, last_pc, retired, traps);
        if (is_stalled && (!i_valid || i_req !== held_i)) $fatal(1, "I request changed under stall");
        if (ds_stalled && (!d_valid || d_req !== held_d)) $fatal(1, "D request changed under stall");
        if (ir_stalled && (!i_rsp_valid || i_rsp !== held_ir)) $fatal(1, "I response changed under stall");
        if (dr_stalled && (!d_rsp_valid || d_rsp !== held_dr)) $fatal(1, "D response changed under stall");
        is_stalled = i_valid && !i_ready; held_i = i_req;
        ds_stalled = d_valid && !d_ready; held_d = d_req;
        ir_stalled = i_rsp_valid && !i_rsp_ready; held_ir = i_rsp;
        dr_stalled = d_rsp_valid && !d_rsp_ready; held_dr = d_rsp;
        if (is_stalled) i_stalls = i_stalls + 1;
        if (ds_stalled) d_stalls = d_stalls + 1;
        if (i_valid && i_ready) begin
            if (i_busy || d_busy || fence_i || i_req.write !== 1'b0 || i_req.len !== 3'b0 ||
                i_req.strb !== 4'b0 || i_req.data !== 32'b0 || i_req.addr[1:0] !== 2'b0)
                $fatal(1, "invalid I request");
            i_pending = i_req; fetched_pc = i_req.addr;
            i_busy = 1; i_delay = 1 + int'(rng[31:16]) % max_delay;
            i_count = i_count + 1;
        end else if (i_busy && !i_rsp_valid) begin
            if (i_delay > 0) i_delay = i_delay - 1;
            else begin
                i_rsp_valid <= 1; i_rsp.last <= 1;
                i_rsp.error <= !mapped(i_pending.addr);
                i_rsp.data <= mapped(i_pending.addr) ? memory[(i_pending.addr - BASE) >> 2] : 0;
            end
        end
        if (i_rsp_valid && i_rsp_ready) begin
            if (!i_busy || !i_rsp.last) $fatal(1, "unsolicited I response");
            i_busy = 0; i_rsp_valid <= 0; i_rsp <= 'x;
        end
        if (d_valid && d_ready) begin
            if (d_busy || i_busy || fence_i || d_req.len !== 3'b0 || d_req.addr[1:0] !== 2'b0)
                $fatal(1, "invalid D request");
            d_pending = d_req; data_pc = fetched_pc;
            d_busy = 1; d_delay = 1 + int'(rng[15:0]) % max_delay;
            d_count = d_count + 1;
        end else if (d_busy && !d_rsp_valid) begin
            if (d_delay > 0) d_delay = d_delay - 1;
            else begin
                d_rsp_valid <= 1; d_rsp.last <= 1;
                d_rsp.error <= !mapped(d_pending.addr);
                d_rsp.data <= mapped(d_pending.addr) ? memory[(d_pending.addr - BASE) >> 2] : 0;
                if (d_pending.write && mapped(d_pending.addr)) begin
                    for (integer lane = 0; lane < 4; lane = lane + 1)
                        if ((d_pending.strb >> lane) & 1)
                            memory[(d_pending.addr - BASE) >> 2][8*lane +: 8] <= 8'(d_pending.data >> (8*lane));
                    if (d_pending.addr == tohost) begin
                        if (d_pending.strb !== 4'hf || d_pending.data == 0 || host_pending)
                            $fatal(1, "invalid tohost write");
                        host_pending = 1; host_pc = data_pc; host_value = d_pending.data;
                    end
                end
            end
        end
        if (d_rsp_valid && d_rsp_ready) begin
            if (!d_busy || !d_rsp.last) $fatal(1, "unsolicited D response");
            d_busy = 0; d_rsp_valid <= 0; d_rsp <= 'x;
        end
        if (fence_i) begin
            if (i_busy || d_busy || i_valid || d_valid) $fatal(1, "fence overlaps requests");
            if (!f_busy) begin
                f_busy = 1; f_delay = 2 + int'(rng[23:8]) % max_delay;
            end else if (f_delay > 0) f_delay = f_delay - 1;
            else fence_done <= 1;
        end else begin
            if (f_busy && !fence_done) $fatal(1, "fence abandoned");
            f_busy = 0; fence_done <= 0;
        end
    end

    always @(negedge clk) if (rst_n && trace_valid) begin
        if (trace_file != 0) $fdisplay(trace_file, "%h %h %h %h %h %h %h %h %h", trace.order, trace.pc,
                                 trace.insn, trace.next_pc, trace.rd, trace.result, trace.trap, trace.cause, trace.tval);
        if (trace.order !== retired || i_busy || d_busy || (fence_i && !fence_done))
            $fatal(1, "invalid retirement ownership/order");
        retired = retired + 1; last_pc = trace.pc;
        if (trace.trap) begin
            traps = traps + 1;
            if (!allow_traps) $fatal(1, "unexpected ISA trap pc=%h insn=%h cause=%h tval=%h", trace.pc, trace.insn, trace.cause, trace.tval);
        end
        if (trace.insn[6:0] == 7'h0f && trace.insn[14:12] == 1 && !trace.trap && fence_done !== 1'b1)
            $fatal(1, "FENCE.I retired without completion");
        if (host_pending) begin
            if (trace.pc !== host_pc || trace.trap || trace.insn[6:0] != 7'h23)
                $fatal(1, "tohost store did not retire");
            if (host_value !== 32'd1)
                $fatal(1, "ISA FAIL %s tohost=%h test_number=%0d pc=%h", name, host_value, host_value >> 1, trace.pc);
            if (signature != "") begin
                signature_file = $fopen(signature, "w");
                if (!signature_file) $fatal(1, "cannot open signature");
                for (logic [31:0] address = sig_begin; address < sig_end; address = address + 4)
                    $fdisplay(signature_file, "%08h", memory[(address - BASE) >> 2]);
                $fclose(signature_file);
            end
            if (trace_file != 0) $fclose(trace_file);
            $display("DONE ISA %s tohost=1 cycles=%0d retirements=%0d traps=%0d requests(i/d)=%0d/%0d stalls(i/d)=%0d/%0d seed=%h",
                     name, cycles, retired, traps, i_count, d_count, i_stalls, d_stalls, seed);
            $finish;
        end
    end
endmodule
