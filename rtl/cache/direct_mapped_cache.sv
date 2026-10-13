`timescale 1ns/1ps

module direct_mapped_cache (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        req_valid,
    output logic        req_ready,
    input  logic [31:0] req_addr,
    input  logic        req_write,
    input  logic [3:0]  req_wstrb,
    input  logic [31:0] req_wdata,
    output logic        rsp_valid,
    input  logic        rsp_ready,
    output logic [31:0] rsp_rdata,
    output logic        rsp_error,
    output logic        rsp_last,
    input  logic        fence_valid,
    output logic        fence_ready,
    output logic        fence_done,
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [31:0] mem_req_addr,
    output logic        mem_req_write,
    output logic [3:0]  mem_req_wstrb,
    output logic [31:0] mem_req_wdata,
    output logic [2:0]  mem_req_len,
    input  logic        mem_rsp_valid,
    output logic        mem_rsp_ready,
    input  logic [31:0] mem_rsp_rdata,
    input  logic        mem_rsp_error,
    input  logic        mem_rsp_last
);
    typedef enum logic [2:0] {
        INVALIDATE, IDLE, LOOKUP, SEND, REFILL, WRITE_WAIT, RESPOND
    } state_t;
    state_t state;
    logic [31:0] data_ram [0:4095];
    logic [17:0] tag_ram [0:511];
    logic valid_ram [0:511];
    logic [31:0] data_q;
    logic [17:0] tag_q;
    logic valid_q;
    logic [31:0] addr_q, wdata_q;
    logic [3:0] wstrb_q;
    logic write_q;
    logic [8:0] invalidate_index;
    logic fencing;
    logic [2:0] beat;
    logic refill_bad;
    logic [31:0] requested_word;
    wire hit = valid_q && tag_q == addr_q[31:14];
    wire refill_write = rst_n && state == REFILL && mem_rsp_valid;
    wire hit_write = rst_n && state == WRITE_WAIT && mem_rsp_valid && mem_rsp_last &&
                     !mem_rsp_error && !refill_bad && hit;
    wire [11:0] ram_write_addr = refill_write ? {addr_q[13:5], beat} : addr_q[13:2];
    wire [31:0] ram_write_data = refill_write ? mem_rsp_rdata : wdata_q;
    wire [3:0] ram_write_strobes = refill_write ? 4'hf : wstrb_q;

    assign req_ready = rst_n && state == IDLE && !fence_valid;
    assign fence_ready = rst_n && state == IDLE;
    assign rsp_valid = rst_n && state == RESPOND;
    assign rsp_last = 1'b1;
    assign mem_req_valid = rst_n && state == SEND;
    assign mem_req_addr = write_q ? addr_q : {addr_q[31:5], 5'b0};
    assign mem_req_write = write_q;
    assign mem_req_wstrb = write_q ? wstrb_q : 4'b0;
    assign mem_req_wdata = write_q ? wdata_q : 32'b0;
    assign mem_req_len = write_q ? 3'd0 : 3'd7;
    assign mem_rsp_ready = rst_n && (state == REFILL || state == WRITE_WAIT);

    // No reset on the data/tag RAMs: registered reads and byte writes infer RAM.
    always_ff @(posedge clk) begin
        if (req_valid && req_ready) begin
            data_q <= data_ram[req_addr[13:2]];
            tag_q <= tag_ram[req_addr[13:5]];
            valid_q <= valid_ram[req_addr[13:5]];
        end
        if (refill_write || hit_write) begin
            for (integer lane = 0; lane < 4; lane = lane + 1)
                if (ram_write_strobes[lane])
                    data_ram[ram_write_addr][lane*8 +: 8] <= ram_write_data[lane*8 +: 8];
        end
        if (refill_write && mem_rsp_last && beat == 3'd7 && !refill_bad && !mem_rsp_error)
            tag_ram[addr_q[13:5]] <= addr_q[31:14];
    end

    // Invalidate one entry per clock instead of resetting a memory array.
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (state == INVALIDATE)
                valid_ram[invalidate_index] <= 1'b0;
            else if (state == LOOKUP && !write_q && !hit)
                valid_ram[addr_q[13:5]] <= 1'b0;
            else if (state == REFILL && mem_rsp_valid && mem_rsp_last)
                valid_ram[addr_q[13:5]] <= beat == 3'd7 && !refill_bad && !mem_rsp_error;
            else if (state == WRITE_WAIT && mem_rsp_valid &&
                     (mem_rsp_error || !mem_rsp_last || refill_bad) && hit)
                valid_ram[addr_q[13:5]] <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= INVALIDATE;
            invalidate_index <= 9'b0;
            fencing <= 1'b0;
            fence_done <= 1'b0;
            addr_q <= 32'b0;
            write_q <= 1'b0;
            wstrb_q <= 4'b0;
            wdata_q <= 32'b0;
            beat <= 3'b0;
            refill_bad <= 1'b0;
            requested_word <= 32'b0;
            rsp_rdata <= 32'b0;
            rsp_error <= 1'b0;
        end else begin
            fence_done <= 1'b0;
            case (state)
                INVALIDATE: begin
                    if (invalidate_index == 9'd511) begin
                        state <= IDLE;
                        fence_done <= fencing;
                        fencing <= 1'b0;
                    end else invalidate_index <= invalidate_index + 1'b1;
                end
                IDLE: begin
                    if (fence_valid) begin
                        state <= INVALIDATE;
                        invalidate_index <= 9'b0;
                        fencing <= 1'b1;
                    end else if (req_valid) begin
                        addr_q <= req_addr;
                        write_q <= req_write;
                        wstrb_q <= req_wstrb;
                        wdata_q <= req_wdata;
                        state <= LOOKUP;
                    end
                end
                LOOKUP: begin
                    refill_bad <= 1'b0;
                    beat <= 3'b0;
                    requested_word <= 32'b0;
                    if (!write_q && hit) begin
                        rsp_rdata <= data_q;
                        rsp_error <= 1'b0;
                        state <= RESPOND;
                    end else state <= SEND;
                end
                SEND: if (mem_req_ready) begin
                    if (write_q) state <= WRITE_WAIT;
                    else state <= REFILL;
                end
                REFILL: if (mem_rsp_valid) begin
                    if (beat == addr_q[4:2]) requested_word <= mem_rsp_rdata;
                    refill_bad <= refill_bad || mem_rsp_error || (beat == 3'd7 && !mem_rsp_last);
                    if (mem_rsp_last) begin
                        rsp_error <= refill_bad || mem_rsp_error || beat != 3'd7;
                        rsp_rdata <= (refill_bad || mem_rsp_error || beat != 3'd7) ? 32'b0 :
                                     (beat == addr_q[4:2] ? mem_rsp_rdata : requested_word);
                        state <= RESPOND;
                    end else if (beat != 3'd7) beat <= beat + 1'b1;
                end
                WRITE_WAIT: if (mem_rsp_valid) begin
                    refill_bad <= refill_bad || mem_rsp_error || !mem_rsp_last;
                    if (mem_rsp_last) begin
                        rsp_rdata <= 32'b0;
                        rsp_error <= refill_bad || mem_rsp_error;
                        state <= RESPOND;
                    end
                end
                RESPOND: if (rsp_ready) state <= IDLE;
                default: state <= INVALIDATE;
            endcase
        end
    end
endmodule
