`timescale 1ns/1ps
module cache_port (
    input logic clk, rst_n,
    input logic req_valid, output logic req_ready, input soc_pkg::req_t req,
    output logic rsp_valid, input logic rsp_ready, output soc_pkg::rsp_t rsp,
    input logic invalidate, output logic invalidate_done,
    output logic mem_valid, input logic mem_ready, output soc_pkg::req_t mem_req,
    input logic mem_rsp_valid, output logic mem_rsp_ready, input soc_pkg::rsp_t mem_rsp
);
    import soc_pkg::*;
    logic busy, cached_q, fence_sent;
    wire cacheable = (req.addr >= 32'h80000000 && req.addr < 32'h81000000) ||
                     (!req.write && req.addr >= 32'h60000000 && req.addr < 32'h64000000);
    logic c_ready, c_rsp_valid, c_valid, c_mem_ready, c_mem_rsp_valid, c_mem_rsp_ready;
    logic f_ready, c_mem_valid;
    req_t c_mem_req;
    rsp_t c_rsp;
    assign c_valid = req_valid && !busy && cacheable && !invalidate;
    assign req_ready = !busy && !invalidate && (cacheable ? c_ready : mem_ready);
    assign mem_valid = c_mem_valid || (req_valid && !busy && !cacheable && !invalidate);
    assign mem_req = c_mem_valid ? c_mem_req : req;
    assign c_mem_ready = mem_ready && c_mem_valid;
    assign c_mem_rsp_valid = mem_rsp_valid && busy && cached_q;
    assign mem_rsp_ready = busy && (cached_q ? c_mem_rsp_ready : rsp_ready);
    assign rsp_valid = busy && (cached_q ? c_rsp_valid : mem_rsp_valid);
    assign rsp = cached_q ? c_rsp : mem_rsp;
    always_ff @(posedge clk) begin
        if (!rst_n) begin busy <= 0; cached_q <= 0; fence_sent <= 0; end
        else begin
            if (!invalidate) fence_sent <= 0;
            else if (f_ready && !fence_sent) fence_sent <= 1;
            if (req_valid && req_ready) begin busy <= 1; cached_q <= cacheable; end
            if (rsp_valid && rsp_ready && rsp.last) busy <= 0;
        end
    end
    direct_mapped_cache cache (
        .clk, .rst_n, .req_valid(c_valid), .req_ready(c_ready),
        .req_addr(req.addr), .req_write(req.write), .req_wstrb(req.strb), .req_wdata(req.data),
        .rsp_valid(c_rsp_valid), .rsp_ready(rsp_ready && busy && cached_q),
        .rsp_rdata(c_rsp.data), .rsp_error(c_rsp.error), .rsp_last(c_rsp.last),
        .fence_valid(invalidate && !fence_sent), .fence_ready(f_ready), .fence_done(invalidate_done),
        .mem_req_valid(c_mem_valid), .mem_req_ready(c_mem_ready),
        .mem_req_addr(c_mem_req.addr), .mem_req_write(c_mem_req.write),
        .mem_req_wstrb(c_mem_req.strb), .mem_req_wdata(c_mem_req.data), .mem_req_len(c_mem_req.len),
        .mem_rsp_valid(c_mem_rsp_valid), .mem_rsp_ready(c_mem_rsp_ready),
        .mem_rsp_rdata(mem_rsp.data), .mem_rsp_error(mem_rsp.error), .mem_rsp_last(mem_rsp.last));
endmodule
