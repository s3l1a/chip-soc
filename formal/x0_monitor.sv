`timescale 1ns/1ps

// Connect to the actual CPU register/read/retirement signals, not a shadow RF.
module x0_monitor (
    input wire clk,
    input wire rst_n,
    input wire [31:0] x0_value,
    input wire [4:0] rs1_index,
    input wire [31:0] rs1_value,
    input wire [4:0] rs2_index,
    input wire [31:0] rs2_value,
    input wire retire_valid,
    input wire [4:0] retire_rd,
    input wire [31:0] retire_result
);
    reg reset_seen = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) reset_seen <= 1'b1;
        else if (reset_seen) begin
`ifdef FORMAL
            assert (x0_value == 0);
            if (rs1_index == 0) assert (rs1_value == 0);
            if (rs2_index == 0) assert (rs2_value == 0);
            if (retire_valid && retire_rd == 0) assert (retire_result == 0);
`else
            assert (x0_value === 32'b0) else $fatal(1, "%m: x0 storage changed");
            if (rs1_index == 0)
                assert (rs1_value === 32'b0) else $fatal(1, "%m: nonzero rs1 x0 read");
            if (rs2_index == 0)
                assert (rs2_value === 32'b0) else $fatal(1, "%m: nonzero rs2 x0 read");
            if (retire_valid && retire_rd == 0)
                assert (retire_result === 32'b0) else $fatal(1, "%m: nonzero x0 retirement result");
`endif
        end
    end
endmodule
