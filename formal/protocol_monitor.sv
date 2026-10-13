`timescale 1ns/1ps

// Observational checker: never drives ready, valid, or response payloads.
module protocol_monitor (
    input wire clk,
    input wire rst_n,
    input wire req_valid,
    input wire req_ready,
    input wire [31:0] req_addr,
    input wire req_write,
    input wire [3:0] req_wstrb,
    input wire [31:0] req_wdata,
    input wire [2:0] req_len,
    input wire rsp_valid,
    input wire rsp_ready,
    input wire [31:0] rsp_rdata,
    input wire rsp_error,
    input wire rsp_last,
    output reg outstanding,
    output reg [3:0] remaining_beats
);
    reg request_stalled, response_stalled, write_q;
    reg [71:0] held_request;
    reg [33:0] held_response;
    wire [71:0] request_payload = {req_addr, req_write, req_wstrb, req_wdata, req_len};
    wire [33:0] response_payload = {rsp_rdata, rsp_error, rsp_last};

    always @(posedge clk) begin
        if (!rst_n) begin
            outstanding <= 1'b0;
            remaining_beats <= 4'b0;
            request_stalled <= 1'b0;
            response_stalled <= 1'b0;
            write_q <= 1'b0;
            held_request <= 72'b0;
            held_response <= 34'b0;
        end else begin
`ifdef FORMAL
            assert (outstanding ? (remaining_beats > 0 && remaining_beats <= 8 &&
                                   (!write_q || remaining_beats == 1)) : remaining_beats == 0);
`else
            assert (outstanding ? (remaining_beats > 0 && remaining_beats <= 8 &&
                                   (!write_q || remaining_beats == 1)) : remaining_beats == 0)
                else $fatal(1, "%m: invalid outstanding/beat-count state");
`endif
            if (request_stalled) begin
`ifdef FORMAL
                assert (req_valid && request_payload == held_request);
`else
                assert (req_valid && request_payload === held_request)
                    else $fatal(1, "%m: request changed under backpressure");
`endif
            end
            if (response_stalled) begin
`ifdef FORMAL
                assert (rsp_valid && response_payload == held_response);
`else
                assert (rsp_valid && response_payload === held_response)
                    else $fatal(1, "%m: response changed under backpressure");
`endif
            end
            request_stalled <= req_valid && !req_ready;
            response_stalled <= rsp_valid && !rsp_ready;
            held_request <= request_payload;
            held_response <= response_payload;

            if (req_valid) begin
`ifdef FORMAL
                assert (req_addr[1:0] == 0);
                assert (req_write ? req_len == 0 : (req_len == 0 || req_len == 7));
`else
                assert (req_addr[1:0] == 0)
                    else $fatal(1, "%m: unaligned request");
                assert (req_write ? req_len == 0 : (req_len == 0 || req_len == 7))
                    else $fatal(1, "%m: illegal request length");
`endif
            end
            if (req_valid && req_ready) begin
`ifdef FORMAL
                assert (!outstanding);
`else
                assert (!outstanding)
                    else $fatal(1, "%m: duplicate/overlapping accepted request");
`endif
                outstanding <= 1'b1;
                remaining_beats <= req_write ? 4'd1 : {1'b0, req_len} + 4'd1;
                write_q <= req_write;
            end

            if (rsp_valid) begin
`ifdef FORMAL
                assert (outstanding && remaining_beats != 0);
                assert (rsp_last ? (remaining_beats == 1 || rsp_error) :
                                   (remaining_beats > 1 && !write_q));
`else
                assert (outstanding && remaining_beats != 0)
                    else $fatal(1, "%m: unsolicited/duplicate response");
                assert (rsp_last ? (remaining_beats == 1 || rsp_error) :
                                   (remaining_beats > 1 && !write_q))
                    else $fatal(1, "%m: incorrect response beat count/last");
`endif
            end
            if (rsp_valid && rsp_ready) begin
                if (rsp_last) begin
                    outstanding <= 1'b0;
                    remaining_beats <= 4'b0;
                end else remaining_beats <= remaining_beats - 1'b1;
            end
        end
    end
endmodule
