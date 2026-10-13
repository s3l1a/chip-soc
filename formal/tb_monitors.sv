`timescale 1ns/1ps

module tb_monitors #(
    parameter integer FAIL_CASE = 0
);
    integer fail_case;
    reg clk = 1'b0;
    always #5 clk = !clk;
    reg rst_n = 1'b0;
    reg req_valid = 0, req_ready = 0, req_write = 0;
    reg [31:0] req_addr = 32'h80000000, req_wdata = 0;
    reg [3:0] req_wstrb = 0;
    reg [2:0] req_len = 0;
    reg rsp_valid = 0, rsp_ready = 0, rsp_error = 0, rsp_last = 0;
    reg [31:0] rsp_rdata = 0;
    wire outstanding;
    wire [3:0] remaining_beats;
    protocol_monitor bus_check (.*);

    reg [31:0] x0_value = 0, rs1_value = 0, rs2_value = 0, retire_result = 0;
    reg [4:0] rs1_index = 0, rs2_index = 0, retire_rd = 0;
    reg retire_valid = 0;
    x0_monitor x0_check (.*);

    task automatic request(input reg wr, input reg [2:0] length);
        @(negedge clk);
        req_valid = 1;
        req_write = wr;
        req_len = length;
        req_wstrb = wr ? 4'h5 : 4'h0;
        req_wdata = 32'h01234567;
        repeat (3) @(negedge clk);
        req_ready = 1;
        @(posedge clk);
        @(negedge clk);
        req_valid = 0;
        req_ready = 0;
        assert (outstanding && remaining_beats == (wr ? 4'd1 : {1'b0, length}+4'd1))
            else $fatal(1, "monitor did not capture request");
    endtask

    task automatic response(input reg last, input reg error, input reg [31:0] data);
        @(negedge clk);
        rsp_valid = 1;
        rsp_last = last;
        rsp_error = error;
        rsp_rdata = data;
        repeat (3) @(negedge clk);
        assert (outstanding) else $fatal(1, "monitor unlocked on stalled response");
        rsp_ready = 1;
        @(posedge clk);
        @(negedge clk);
        rsp_valid = 0;
        rsp_ready = 0;
    endtask

    initial begin
        if (!$value$plusargs("FAIL_CASE=%d", fail_case)) fail_case = FAIL_CASE;
        repeat (3) @(negedge clk);
        rst_n = 1;
        request(0, 7);
        for (integer i = 0; i < 8; i = i + 1) begin
            response(i == 7, i == 3, i[31:0]);
            assert (remaining_beats == 4'd7-i[3:0]) else $fatal(1, "wrong remaining beat count");
        end
        assert (!outstanding) else $fatal(1, "burst did not complete");
        request(1, 0);
        response(1, 0, 0);
        request(0, 7);
        response(0, 0, 32'hfeedface);
        response(1, 1, 0); // A fault may terminate the outstanding burst early.
        assert (!outstanding && remaining_beats == 0) else $fatal(1, "early fault did not complete");
        retire_valid = 1;
        repeat (2) @(negedge clk);
        case (fail_case)
            0: begin
                $display("PASS tb_monitors: legal burst/write/early-error traffic and stalls");
                $finish;
            end
            1: begin
                request(0, 0);
                req_valid = 1;
                req_ready = 1;
            end
            2: begin
                rsp_valid = 1;
                rsp_last = 1;
            end
            3: begin
                request(0, 7);
                rsp_valid = 1;
                rsp_last = 1;
                rsp_error = 0;
            end
            4: begin
                req_valid = 1;
                req_ready = 0;
                @(posedge clk);
                @(negedge clk);
                req_addr = req_addr + 32'd4;
            end
            5: begin
                request(0, 0);
                rsp_valid = 1;
                rsp_last = 1;
                rsp_error = 0;
                @(posedge clk);
                @(negedge clk);
                rsp_rdata = 32'hbad;
            end
            6: x0_value = 1;
            7: rs1_value = 1;
            8: retire_result = 1;
            default: $fatal(1, "unsupported FAIL_CASE");
        endcase
        repeat (3) @(negedge clk);
        $fatal(1, "FAIL_CASE %0d was not rejected", fail_case);
    end

    initial begin
        #10000;
        $fatal(1, "tb_monitors watchdog");
    end
endmodule
