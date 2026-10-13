`timescale 1ns/1ps

// Behavioral external memory, not a physical RAM controller.
module sim_ram #(
    parameter logic [31:0] BASE = 32'h80000000,
    parameter integer MEM_BYTES = 16*1024*1024,
    parameter integer MAX_DELAY = 7,
    parameter logic [31:0] SEED = 32'h1badf00d,
    parameter INIT_FILE = ""
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        req_valid,
    output logic        req_ready,
    input  logic [31:0] req_addr,
    input  logic        req_write,
    input  logic [3:0]  req_wstrb,
    input  logic [31:0] req_wdata,
    input  logic [2:0]  req_len,
    output logic        rsp_valid,
    input  logic        rsp_ready,
    output logic [31:0] rsp_rdata,
    output logic        rsp_error,
    output logic        rsp_last
);
    logic [31:0] words [0:MEM_BYTES/4-1];
    logic busy, write_q, fault_q;
    logic [31:0] addr_q, random_q;
    logic [2:0] beat, len_q;
    integer delay_count;
    wire [32:0] end_addr = {1'b0, req_addr} + (req_write ? 33'd4 :
                                          (({30'b0, req_len} + 33'd1) << 2));
    wire fault = req_addr[1:0] != 0 || req_addr < BASE ||
                 end_addr > ({1'b0, BASE} + $unsigned(33'(MEM_BYTES))) ||
                 (req_write ? req_len != 0 : (req_len != 0 && req_len != 7));
    wire [31:0] random_next = {random_q[30:0],
        random_q[31] ^ random_q[21] ^ random_q[1] ^ random_q[0]};

    initial begin
        if (MEM_BYTES <= 0 || MEM_BYTES % 4 != 0 || MAX_DELAY < 0 || SEED == 0)
            $fatal(1, "sim_ram: invalid parameters");
        for (integer i = 0; i < MEM_BYTES/4; i = i + 1) words[i] = 32'b0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, words);
    end

    assign req_ready = rst_n && !busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            rsp_valid <= 1'b0;
            rsp_rdata <= 32'b0;
            rsp_error <= 1'b0;
            rsp_last <= 1'b0;
            addr_q <= 32'b0;
            write_q <= 1'b0;
            fault_q <= 1'b0;
            len_q <= 3'b0;
            beat <= 3'b0;
            delay_count <= 0;
            random_q <= SEED;
        end else begin
            random_q <= random_next;
            if (req_valid && req_ready) begin
                busy <= 1'b1;
                addr_q <= req_addr;
                write_q <= req_write;
                fault_q <= fault;
                len_q <= (fault || req_write) ? 3'b0 : req_len;
                beat <= 3'b0;
                delay_count <= int'(random_next % ($unsigned(MAX_DELAY) + 32'd1));
                if (req_write && !fault)
                    for (integer lane = 0; lane < 4; lane = lane + 1)
                        if (req_wstrb[lane])
                            words[(req_addr-BASE)>>2][lane*8 +: 8] <= req_wdata[lane*8 +: 8];
            end else if (busy) begin
                if (rsp_valid) begin
                    if (rsp_ready) begin
                        rsp_valid <= 1'b0;
                        if (rsp_last) busy <= 1'b0;
                        else begin
                            beat <= beat + 1'b1;
                            delay_count <= int'(random_next % ($unsigned(MAX_DELAY) + 32'd1));
                        end
                    end
                end else if (delay_count != 0) delay_count <= delay_count - 1;
                else begin
                    rsp_valid <= 1'b1;
                    rsp_error <= fault_q;
                    rsp_last <= beat == len_q;
                    rsp_rdata <= (fault_q || write_q) ? 32'b0 : words[((addr_q-BASE)>>2)+{29'b0, beat}];
                end
            end
        end
    end
endmodule
