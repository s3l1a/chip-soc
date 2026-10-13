`timescale 1ns/1ps
module tb_divider;
    logic clk = 0;
    always #5 clk = !clk;
    logic rst_n = 0, start = 0, signed_mode = 0, remainder_mode = 0;
    logic [31:0] dividend = 0, divisor = 0, result;
    logic busy, done;
    divider dut (.*);
    integer checked = 0, elapsed;
    logic [31:0] rng = 32'h1578abcd;
    logic [31:0] edges [0:10];

    function automatic logic [31:0] golden(input logic [31:0] a, b, input logic sm, rm);
        logic signed [63:0] aa, bb, q, r;
        begin
            aa = $signed(sm ? {{32{a[31]}}, a} : {32'b0, a});
            bb = $signed(sm ? {{32{b[31]}}, b} : {32'b0, b});
            if (b == 0) golden = rm ? a : 32'hffffffff;
            else begin
                q = aa / bb; r = aa - q * bb;
                golden = rm ? r[31:0] : q[31:0];
            end
        end
    endfunction

    task automatic run(input logic [31:0] a, b, input logic sm, rm);
        logic [31:0] expected;
        begin
            expected = golden(a, b, sm, rm);
            start = 1; dividend = a; divisor = b;
            signed_mode = sm; remainder_mode = rm;
            @(negedge clk);
            start = 0;
            elapsed = 0;
            if (b != 0 && (!busy || done)) $fatal(1, "divider did not accept start");
            if (b == 0 && (busy || !done)) $fatal(1, "zero divisor handshake");
            // Live operands/modes and an extra start must not corrupt in-flight work.
            dividend = ~a; divisor = ~b; signed_mode = !sm; remainder_mode = !rm;
            while (!done) begin
                start = elapsed == 7;
                @(negedge clk);
                elapsed = elapsed + 1;
                if (elapsed > 32) $fatal(1, "divider timeout");
                if (!done && !busy) $fatal(1, "divider lost busy");
            end
            start = 0;
            if (busy || result !== expected || elapsed != (b == 0 ? 0 : 32))
                $fatal(1, "divide a=%h b=%h signed=%b rem=%b got=%h want=%h cycles=%0d",
                       a, b, sm, rm, result, expected, elapsed);
            checked = checked + 1;
        end
    endtask

    initial begin
        edges[0] = 0; edges[1] = 1; edges[2] = 2; edges[3] = 3;
        edges[4] = 32'hffffffff; edges[5] = 32'hfffffffe;
        edges[6] = 32'h80000000; edges[7] = 32'h7fffffff;
        edges[8] = 32'h80000001; edges[9] = 32'h55555555; edges[10] = 32'haaaaaaaa;
        repeat (3) @(negedge clk);
        rst_n = 1;
        // Exhaustive 8-bit unsigned and sign-extended signed operands, both results.
        for (integer sm = 0; sm < 2; sm = sm + 1)
            for (integer a = 0; a < 256; a = a + 1)
                for (integer b = 0; b < 256; b = b + 1)
                    for (integer rm = 0; rm < 2; rm = rm + 1)
                        run(sm != 0 && a >= 128 ? 32'hffffff00 | a[31:0] : a[31:0],
                            sm != 0 && b >= 128 ? 32'hffffff00 | b[31:0] : b[31:0], sm != 0, rm != 0);
        for (integer a = 0; a < 11; a = a + 1)
            for (integer b = 0; b < 11; b = b + 1)
                for (integer mode = 0; mode < 4; mode = mode + 1)
                    run(edges[a], edges[b], mode[0], mode[1]);
        for (integer j = 0; j < 2000; j = j + 1) begin
            rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
            dividend = rng;
            rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
            run(dividend, rng, rng[7], rng[11]);
        end
        @(negedge clk);
        if (busy || done) $fatal(1, "done did not pulse for one cycle");
        // Reset cancels an unfinished divide; subsequent special cases stay clean.
        dividend = 32'h80000000; divisor = 3; signed_mode = 1; start = 1;
        @(negedge clk); start = 0;
        repeat (9) @(negedge clk);
        rst_n = 0;
        repeat (2) @(negedge clk);
        if (busy || done || result != 0) $fatal(1, "reset failed to cancel divide");
        rst_n = 1;
        run(32'h80000000, 0, 1, 0);
        run(32'h80000000, 32'hffffffff, 1, 0);
        run(32'h80000000, 32'hffffffff, 1, 1);
        run(17, 5, 0, 0);
        $display("PASS tb_divider: %0d operand/mode cases including exhaustive 8-bit domain", checked);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "divider watchdog");
    end
endmodule
