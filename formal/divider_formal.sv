`timescale 1ns/1ps

module divider_formal (input wire clk);
    (* anyseq *) reg rst_n, start, signed_mode, remainder_mode;
    (* anyseq *) reg [31:0] dividend, divisor;
    wire busy, done;
    wire [31:0] result;
    divider dut (.*);

    reg past_valid = 1'b0;
    reg pending;
    reg [5:0] age;
    reg busy_start_seen;

    always @(posedge clk) begin
        past_valid <= 1'b1;
        // One sampled synchronous reset, then no cancellation by reset.
        if (!past_valid) assume (!rst_n);
        else assume (rst_n);

        if (!rst_n) begin
            pending <= 1'b0;
            age <= 6'b0;
            busy_start_seen <= 1'b0;
        end else if (past_valid) begin
            assert (!(busy && done));
            assert (busy == (pending && age < 6'd32));
            if (pending) begin
                assert (age <= 6'd32);
                if (age < 6'd32) assert (busy && !done);
                else assert (done && !busy);
                if (done) pending <= 1'b0;
                else age <= age + 1'b1;
                if (busy && start) busy_start_seen <= 1'b1;
            end
            if (start && !busy && divisor != 0) begin
                assert (!pending || done);
                pending <= 1'b1;
                age <= 6'b0;
                busy_start_seen <= 1'b0;
            end

            if ($past(rst_n)) begin
                if ($past(start && !busy && divisor == 0)) begin
                    assert (done && !busy);
                    assert (result == ($past(remainder_mode) ? $past(dividend) : 32'hffffffff));
                end else if (done) begin
                    assert (pending && age == 6'd32);
                end
                if ($past(busy) && busy) assert (result == $past(result));
                if ($past(start && !busy && divisor != 0)) assert (busy && !done);
            end

            cover (pending && age == 6'd32 && done);
            cover (pending && age == 6'd32 && done && busy_start_seen);
            cover (done && $past(start && !busy && divisor == 0 && !remainder_mode));
            cover (done && $past(start && !busy && divisor == 0 && remainder_mode));
        end
    end
endmodule
