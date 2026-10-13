`timescale 1ns/1ps

module bus_arbiter_formal (input wire clk);
    (* anyseq *) reg rst_n;
    (* anyseq *) reg m0_req_valid, m0_req_write, m0_rsp_ready;
    (* anyseq *) reg [31:0] m0_req_addr, m0_req_wdata;
    (* anyseq *) reg [3:0] m0_req_wstrb;
    (* anyseq *) reg [2:0] m0_req_len;
    wire m0_req_ready, m0_rsp_valid, m0_rsp_error, m0_rsp_last;
    wire [31:0] m0_rsp_rdata;
    (* anyseq *) reg m1_req_valid, m1_req_write, m1_rsp_ready;
    (* anyseq *) reg [31:0] m1_req_addr, m1_req_wdata;
    (* anyseq *) reg [3:0] m1_req_wstrb;
    (* anyseq *) reg [2:0] m1_req_len;
    wire m1_req_ready, m1_rsp_valid, m1_rsp_error, m1_rsp_last;
    wire [31:0] m1_rsp_rdata;
    wire s_req_valid, s_req_write, s_rsp_ready;
    wire [31:0] s_req_addr, s_req_wdata;
    wire [3:0] s_req_wstrb;
    wire [2:0] s_req_len;
    (* anyseq *) reg s_req_ready, s_rsp_valid, s_rsp_error, s_rsp_last;
    (* anyseq *) reg [31:0] s_rsp_rdata;

    bus_arbiter dut (.*);
    wire monitor_outstanding;
    wire [3:0] monitor_remaining;
    protocol_monitor downstream (
        .clk(clk), .rst_n(rst_n),
        .req_valid(s_req_valid), .req_ready(s_req_ready), .req_addr(s_req_addr),
        .req_write(s_req_write), .req_wstrb(s_req_wstrb), .req_wdata(s_req_wdata), .req_len(s_req_len),
        .rsp_valid(s_rsp_valid), .rsp_ready(s_rsp_ready), .rsp_rdata(s_rsp_rdata),
        .rsp_error(s_rsp_error), .rsp_last(s_rsp_last),
        .outstanding(monitor_outstanding), .remaining_beats(monitor_remaining)
    );

    reg past_valid = 1'b0;
    reg active, owner, turn, grant_pending, grant_owner;
    reg [3:0] beats_left;
    reg [1:0] completions;
    reg saw_final_stall, saw_late_contender;
    wire selected = grant_pending ? grant_owner :
                    (m0_req_valid && m1_req_valid ? turn : m1_req_valid);
    wire [71:0] m0_payload = {m0_req_addr, m0_req_write, m0_req_wstrb, m0_req_wdata, m0_req_len};
    wire [71:0] m1_payload = {m1_req_addr, m1_req_write, m1_req_wstrb, m1_req_wdata, m1_req_len};
    wire [71:0] s_payload = {s_req_addr, s_req_write, s_req_wstrb, s_req_wdata, s_req_len};
    // Driven from the real DUT registers by bus_arbiter_setup.ys, not assumed.
    wire dut_busy, dut_owner, dut_next_owner, dut_grant_held, dut_held_owner;

    always @(posedge clk) begin
        past_valid <= 1'b1;
        if (!past_valid) assume (!rst_n);
        else assume (rst_n);

        if (!rst_n) begin
            active <= 1'b0;
            owner <= 1'b0;
            turn <= 1'b0;
            grant_pending <= 1'b0;
            grant_owner <= 1'b0;
            beats_left <= 4'b0;
            completions <= 2'b0;
            saw_final_stall <= 1'b0;
            saw_late_contender <= 1'b0;
        end else if (past_valid) begin
            // Legal masters may offer the next request early, but must hold it.
            if (m0_req_valid) begin
                assume (m0_req_addr[1:0] == 0);
                assume (m0_req_write ? m0_req_len == 0 : (m0_req_len == 0 || m0_req_len == 7));
            end
            if (m1_req_valid) begin
                assume (m1_req_addr[1:0] == 0);
                assume (m1_req_write ? m1_req_len == 0 : (m1_req_len == 0 || m1_req_len == 7));
            end
            if ($past(rst_n)) begin
                if ($past(m0_req_valid && !m0_req_ready)) begin
                    assume (m0_req_valid && m0_payload == $past(m0_payload));
                end
                if ($past(m1_req_valid && !m1_req_ready)) begin
                    assume (m1_req_valid && m1_payload == $past(m1_payload));
                end
                if ($past(s_rsp_valid && !s_rsp_ready)) begin
                    assume (s_rsp_valid && {s_rsp_rdata, s_rsp_error, s_rsp_last} ==
                                          $past({s_rsp_rdata, s_rsp_error, s_rsp_last}));
                end
            end

            // Slave timing is unrestricted; only response legality is assumed.
            if (s_rsp_valid) begin
                assume (active && beats_left != 0);
                assume (s_rsp_last ? (beats_left == 1 || s_rsp_error) : beats_left > 1);
            end

            assert (active == monitor_outstanding);
            assert (beats_left == monitor_remaining);
            assert (dut_busy == active);
            assert (dut_owner == owner);
            assert (dut_next_owner == turn);
            assert (dut_grant_held == grant_pending);
            assert (dut_held_owner == grant_owner);
            assert (!(active && grant_pending));
            assert (!(m0_req_ready && m1_req_ready));
            assert ((s_req_valid && s_req_ready) ==
                    ((m0_req_valid && m0_req_ready) || (m1_req_valid && m1_req_ready)));
            assert (s_req_valid == (!active && (selected ? m1_req_valid : m0_req_valid)));
            assert (m0_req_ready == (s_req_valid && s_req_ready && !selected));
            assert (m1_req_ready == (s_req_valid && s_req_ready && selected));
            if (s_req_valid) assert (s_payload == (selected ? m1_payload : m0_payload));

            if (active) begin
                assert (!s_req_valid && !m0_req_ready && !m1_req_ready);
                assert (m0_rsp_valid == (!owner && s_rsp_valid));
                assert (m1_rsp_valid == (owner && s_rsp_valid));
                assert (s_rsp_ready == (owner ? m1_rsp_ready : m0_rsp_ready));
                if (s_rsp_valid) begin
                    if (owner) assert ({m1_rsp_rdata, m1_rsp_error, m1_rsp_last} ==
                                       {s_rsp_rdata, s_rsp_error, s_rsp_last});
                    else assert ({m0_rsp_rdata, m0_rsp_error, m0_rsp_last} ==
                                 {s_rsp_rdata, s_rsp_error, s_rsp_last});
                end
            end else assert (!m0_rsp_valid && !m1_rsp_valid && !s_rsp_ready);

            if (s_req_valid) begin
                if (s_req_ready) begin
                    active <= 1'b1;
                    owner <= selected;
                    grant_pending <= 1'b0;
                    beats_left <= s_req_write ? 4'd1 : {1'b0, s_req_len} + 4'd1;
                end else begin
                    grant_pending <= 1'b1;
                    grant_owner <= selected;
                end
            end
            if (s_rsp_valid && s_rsp_ready) begin
                if (s_rsp_last) begin
                    active <= 1'b0;
                    beats_left <= 4'b0;
                    turn <= !owner;
                    completions[owner] <= 1'b1;
                end else beats_left <= beats_left - 1'b1;
            end
            if (active && s_rsp_valid && s_rsp_last && !s_rsp_ready)
                saw_final_stall <= 1'b1;
            if (grant_pending && m0_req_valid && m1_req_valid &&
                $past(m0_req_valid ^ m1_req_valid))
                saw_late_contender <= 1'b1;

            cover (&completions);
            cover (saw_final_stall && s_rsp_valid && s_rsp_ready && s_rsp_last);
            cover (saw_late_contender && s_req_valid && s_req_ready);
            cover (active && beats_left == 8 && s_rsp_valid && !s_rsp_last);
        end
    end
endmodule
