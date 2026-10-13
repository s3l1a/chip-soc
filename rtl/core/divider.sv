`timescale 1ns/1ps
module divider (
    input logic clk, rst_n, start, signed_mode, remainder_mode,
    input logic [31:0] dividend, divisor,
    output logic busy, done,
    output logic [31:0] result
);
    logic [31:0] q, d;
    logic [32:0] r, shifted;
    logic [5:0] count;
    logic neg_q, neg_r, rem_mode;
    logic [31:0] next_q;
    logic [32:0] next_r;
    always_comb begin
        shifted = {r[31:0], q[31]};
        next_q = {q[30:0], 1'b0};
        next_r = shifted;
        if (shifted >= {1'b0,d}) begin
            next_r = shifted - {1'b0,d};
            next_q[0] = 1'b1;
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy <= 0; done <= 0; result <= 0; count <= 0;
            q <= 0; d <= 0; r <= 0; neg_q <= 0; neg_r <= 0; rem_mode <= 0;
        end else begin
            done <= 0;
            if (start && !busy) begin
                neg_q <= signed_mode && (dividend[31] ^ divisor[31]);
                neg_r <= signed_mode && dividend[31];
                rem_mode <= remainder_mode;
                count <= 0; r <= 0;
                q <= signed_mode && dividend[31] ? -dividend : dividend;
                d <= signed_mode && divisor[31] ? -divisor : divisor;
                if (divisor == 0) begin
                    result <= remainder_mode ? dividend : 32'hffffffff;
                    done <= 1;
                end else begin
                    busy <= 1;
                end
            end else if (busy) begin
                q <= next_q; r <= next_r; count <= count + 1'b1;
                if (count == 31) begin
                    busy <= 0; done <= 1;
                    result <= rem_mode ? (neg_r ? -next_r[31:0] : next_r[31:0]) :
                                          (neg_q ? -next_q : next_q);
                end
            end
        end
    end
endmodule
