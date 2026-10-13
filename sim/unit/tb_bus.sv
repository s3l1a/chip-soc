`timescale 1ns/1ps

module tb_bus;
    logic clk = 0;
    always #5 clk = !clk;
    logic rst_n = 0;
    logic [1:0] req_valid = 0, req_ready, req_write = 0;
    logic [31:0] req_addr [0:1], req_wdata [0:1];
    logic [3:0] req_wstrb [0:1];
    logic [2:0] req_len [0:1];
    logic [1:0] rsp_valid, rsp_ready = 0, rsp_error, rsp_last;
    logic [31:0] rsp_rdata [0:1];
    logic s_req_valid, s_req_ready, s_req_write;
    logic [31:0] s_req_addr, s_req_wdata;
    logic [3:0] s_req_wstrb;
    logic [2:0] s_req_len;
    logic s_rsp_valid, s_rsp_ready, s_rsp_error, s_rsp_last;
    logic [31:0] s_rsp_rdata;
    logic ram_req_ready;
    logic allow_request = 0, block_request = 0, block_response = 0;
    logic stall_last = 0;
    integer last_stall_cycles = 0;
    logic [31:0] latency_rng = 32'habcddcba;
    logic [31:0] reference_words [0:511];
    integer accepted [0:1], completed [0:1];
    integer contended = 0, stalled_cycles = 0;

    bus_arbiter dut (
        .clk(clk), .rst_n(rst_n),
        .m0_req_valid(req_valid[0]), .m0_req_ready(req_ready[0]),
        .m0_req_addr(req_addr[0]), .m0_req_write(req_write[0]),
        .m0_req_wstrb(req_wstrb[0]), .m0_req_wdata(req_wdata[0]), .m0_req_len(req_len[0]),
        .m0_rsp_valid(rsp_valid[0]), .m0_rsp_ready(rsp_ready[0]),
        .m0_rsp_rdata(rsp_rdata[0]), .m0_rsp_error(rsp_error[0]), .m0_rsp_last(rsp_last[0]),
        .m1_req_valid(req_valid[1]), .m1_req_ready(req_ready[1]),
        .m1_req_addr(req_addr[1]), .m1_req_write(req_write[1]),
        .m1_req_wstrb(req_wstrb[1]), .m1_req_wdata(req_wdata[1]), .m1_req_len(req_len[1]),
        .m1_rsp_valid(rsp_valid[1]), .m1_rsp_ready(rsp_ready[1]),
        .m1_rsp_rdata(rsp_rdata[1]), .m1_rsp_error(rsp_error[1]), .m1_rsp_last(rsp_last[1]),
        .s_req_valid(s_req_valid), .s_req_ready(s_req_ready),
        .s_req_addr(s_req_addr), .s_req_write(s_req_write),
        .s_req_wstrb(s_req_wstrb), .s_req_wdata(s_req_wdata), .s_req_len(s_req_len),
        .s_rsp_valid(s_rsp_valid), .s_rsp_ready(s_rsp_ready),
        .s_rsp_rdata(s_rsp_rdata), .s_rsp_error(s_rsp_error), .s_rsp_last(s_rsp_last)
    );
    sim_ram #(.MAX_DELAY(11), .SEED(32'h0f1e2d3c)) ram (
        .clk(clk), .rst_n(rst_n),
        .req_valid(s_req_valid && allow_request), .req_ready(ram_req_ready),
        .req_addr(s_req_addr), .req_write(s_req_write), .req_wstrb(s_req_wstrb),
        .req_wdata(s_req_wdata), .req_len(s_req_len),
        .rsp_valid(s_rsp_valid), .rsp_ready(s_rsp_ready),
        .rsp_rdata(s_rsp_rdata), .rsp_error(s_rsp_error), .rsp_last(s_rsp_last)
    );
    assign s_req_ready = ram_req_ready && allow_request;

    function automatic logic [31:0] next_random(input logic [31:0] x);
        next_random = {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]};
    endfunction

    always @(negedge clk) begin
        latency_rng = next_random(latency_rng);
        allow_request = !block_request && latency_rng[2:0] != 0;
        rsp_ready[0] = !block_response && latency_rng[5:3] != 0;
        rsp_ready[1] = !block_response && latency_rng[8:6] != 0;
        if (stall_last && s_rsp_valid && s_rsp_last) begin
            rsp_ready = 0;
            last_stall_cycles = last_stall_cycles + 1;
            if (last_stall_cycles == 20) stall_last = 0;
        end
    end

    logic outstanding = 0, expected_owner = 0, turn = 0;
    logic expected_write, expected_error;
    integer expected_beats, response_beat, expected_word;
    logic request_stalled = 0, response_stalled = 0;
    logic [71:0] held_request;
    logic [33:0] held_response;
    logic [1:0] held_route;
    always @(posedge clk) begin
        if (!rst_n) begin
            outstanding = 0;
            turn = 0;
            request_stalled = 0;
            response_stalled = 0;
        end else begin
            if (request_stalled)
                assert (s_req_valid &&
                    {s_req_addr, s_req_write, s_req_wstrb, s_req_wdata, s_req_len} === held_request)
                    else $fatal(1, "arbiter changed a stalled request grant");
            if (response_stalled) begin
                assert (s_rsp_valid && {s_rsp_rdata, s_rsp_error, s_rsp_last} === held_response && rsp_valid === held_route)
                    else $fatal(1, "arbiter changed a stalled response/owner");
            end
            if (outstanding) begin
                assert (!s_req_valid && req_ready == 0) else $fatal(1, "arbiter unlocked before final consumption");
                assert (!rsp_valid[!expected_owner]) else $fatal(1, "response delivered to non-owner");
            end else assert (rsp_valid == 0 && !s_rsp_ready) else $fatal(1, "response without ownership");
            if (s_req_valid && !request_stalled && req_valid == 2'b11) begin
                assert (s_req_addr == req_addr[turn]) else $fatal(1, "round-robin fairness violation");
                contended = contended + 1;
            end
            request_stalled = s_req_valid && !s_req_ready;
            held_request = {s_req_addr, s_req_write, s_req_wstrb, s_req_wdata, s_req_len};
            response_stalled = s_rsp_valid && !s_rsp_ready;
            held_response = {s_rsp_rdata, s_rsp_error, s_rsp_last};
            held_route = rsp_valid;
            if (response_stalled) stalled_cycles = stalled_cycles + 1;
            if (s_req_valid && s_req_ready) begin
                assert (!outstanding && (req_ready == 2'b01 || req_ready == 2'b10))
                    else $fatal(1, "invalid request handshake routing");
                expected_owner = req_ready[1];
                outstanding = 1;
                accepted[expected_owner] = accepted[expected_owner] + 1;
                expected_write = s_req_write;
                expected_error = s_req_addr < 32'h80000000 || s_req_addr >= 32'h81000000 ||
                    ({1'b0, s_req_addr} + (s_req_write ? 33'd4 : (({30'b0, s_req_len}+33'd1)<<2))) > 33'h081000000 ||
                    s_req_addr[1:0] != 0 ||
                    (s_req_write ? s_req_len != 0 : (s_req_len != 0 && s_req_len != 7));
                expected_word = int'((s_req_addr-32'h80000000)>>2);
                expected_beats = (expected_write || expected_error) ? 1 : int'(s_req_len)+1;
                response_beat = 0;
                if (expected_write && !expected_error)
                    for (integer lane = 0; lane < 4; lane = lane + 1)
                        if (s_req_wstrb[lane])
                            reference_words[expected_word][lane*8 +: 8] = s_req_wdata[lane*8 +: 8];
            end
            if (s_rsp_valid && s_rsp_ready) begin
                assert (outstanding && rsp_valid[expected_owner] && rsp_ready[expected_owner])
                    else $fatal(1, "response handshake route mismatch");
                assert (rsp_error[expected_owner] === expected_error &&
                        rsp_last[expected_owner] == (response_beat == expected_beats-1))
                    else $fatal(1, "response error/last mismatch");
                assert (rsp_rdata[expected_owner] === ((expected_error || expected_write) ? 32'b0 :
                        reference_words[expected_word+response_beat]))
                    else $fatal(1, "response data mismatch master=%0d beat=%0d", expected_owner, response_beat);
                response_beat = response_beat + 1;
                if (s_rsp_last) begin
                    outstanding = 0;
                    completed[expected_owner] = completed[expected_owner] + 1;
                    turn = !expected_owner;
                end
            end
        end
    end

    task automatic transfer(input integer master, input logic [31:0] address,
        input logic wr, input logic [2:0] length,
        input logic [3:0] strobes, input logic [31:0] data);
        @(negedge clk);
        req_addr[master] = address;
        req_write[master] = wr;
        req_len[master] = length;
        req_wstrb[master] = strobes;
        req_wdata[master] = data;
        req_valid[master] = 1;
        do @(posedge clk); while (!req_ready[master]);
        @(negedge clk);
        req_valid[master] = 0;
        req_addr[master] = 32'hf00df00c;
        req_wdata[master] = ~data;
        do @(posedge clk); while (!(rsp_valid[master] && rsp_ready[master] && rsp_last[master]));
    endtask

    task automatic traffic(input integer master);
        logic [31:0] random_state;
        logic wr;
        integer word_index;
        random_state = master == 0 ? 32'h1234abcd : 32'hdead1234;
        for (integer n = 0; n < 300; n = n + 1) begin
            random_state = next_random(random_state);
            wr = random_state[0];
            word_index = master*256 + int'(random_state[8:4])*8;
            transfer(master, 32'h80000000 + word_index[31:0]*32'd4, wr,
                     (!wr && random_state[1]) ? 3'd7 : 3'd0,
                     random_state[15:12], random_state ^ 32'h778899aa);
        end
    endtask

    initial begin
        for (integer m = 0; m < 2; m = m + 1) begin
            accepted[m] = 0;
            completed[m] = 0;
            req_addr[m] = 0;
            req_wdata[m] = 0;
            req_wstrb[m] = 0;
            req_len[m] = 0;
        end
        #1;
        for (integer i = 0; i < 512; i = i + 1) begin
            reference_words[i] = 32'h89abcdef ^ (32'h01020304 * i[31:0]);
            ram.words[i] = reference_words[i];
        end
        repeat (3) @(negedge clk);
        rst_n = 1;
        block_request = 1;
        block_response = 1;
        stall_last = 1;
        fork
            transfer(1, 32'h80000400, 0, 7, 0, 0);
            begin
                wait (s_req_valid);
                repeat (4) @(negedge clk);
                transfer(0, 32'h80000000, 0, 7, 0, 0);
            end
            begin
                wait (req_valid == 2'b11);
                repeat (100) @(negedge clk);
                assert (s_req_addr == 32'h80000400 && !s_rsp_valid && req_ready == 0)
                    else $fatal(1, "late contender stole stalled grant or timeout fabricated response");
                block_request = 0;
                wait (s_rsp_valid);
                repeat (30) @(negedge clk);
                assert (completed[0] == 0 && completed[1] == 0 && accepted[0] == 0)
                    else $fatal(1, "response stall did not retain ownership");
                block_response = 0;
            end
        join
        assert (last_stall_cycles == 20) else $fatal(1, "final beat stall not exercised");
        fork
            traffic(0);
            traffic(1);
        join
        transfer(0, 32'h7ffffffc, 0, 0, 0, 0);
        transfer(1, 32'h81000000, 1, 0, 4'hf, 32'hbad);
        transfer(0, 32'h80000002, 0, 0, 0, 0);
        transfer(1, 32'h80000400, 0, 3, 0, 0);
        transfer(0, 32'h80000000, 1, 7, 4'hf, 32'hbad);
        transfer(1, 32'h80fffffc, 0, 7, 0, 0);
        transfer(0, 32'hfffffffc, 0, 7, 0, 0);
        @(negedge clk);
        assert (!outstanding && accepted[0] == completed[0] && accepted[1] == completed[1] &&
                contended > 100 && stalled_cycles > 50)
            else $fatal(1, "incomplete transactions or insufficient contention/stall coverage");
        $display("PASS tb_bus: m0=%0d m1=%0d contention=%0d response_stalls=%0d",
                 completed[0], completed[1], contended, stalled_cycles);
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "tb_bus watchdog");
    end
endmodule
