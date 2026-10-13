`timescale 1ns/1ps

module bus_arbiter (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        m0_req_valid,
    output logic        m0_req_ready,
    input  logic [31:0] m0_req_addr,
    input  logic        m0_req_write,
    input  logic [3:0]  m0_req_wstrb,
    input  logic [31:0] m0_req_wdata,
    input  logic [2:0]  m0_req_len,
    output logic        m0_rsp_valid,
    input  logic        m0_rsp_ready,
    output logic [31:0] m0_rsp_rdata,
    output logic        m0_rsp_error,
    output logic        m0_rsp_last,
    input  logic        m1_req_valid,
    output logic        m1_req_ready,
    input  logic [31:0] m1_req_addr,
    input  logic        m1_req_write,
    input  logic [3:0]  m1_req_wstrb,
    input  logic [31:0] m1_req_wdata,
    input  logic [2:0]  m1_req_len,
    output logic        m1_rsp_valid,
    input  logic        m1_rsp_ready,
    output logic [31:0] m1_rsp_rdata,
    output logic        m1_rsp_error,
    output logic        m1_rsp_last,
    output logic        s_req_valid,
    input  logic        s_req_ready,
    output logic [31:0] s_req_addr,
    output logic        s_req_write,
    output logic [3:0]  s_req_wstrb,
    output logic [31:0] s_req_wdata,
    output logic [2:0]  s_req_len,
    input  logic        s_rsp_valid,
    output logic        s_rsp_ready,
    input  logic [31:0] s_rsp_rdata,
    input  logic        s_rsp_error,
    input  logic        s_rsp_last
);
    logic busy, owner, next_owner, grant_held, held_owner;
    logic selected;

    always_comb begin
        if (grant_held) selected = held_owner;
        else if (m0_req_valid && m1_req_valid) selected = next_owner;
        else selected = m1_req_valid;

        s_req_valid = rst_n && !busy && (selected ? m1_req_valid : m0_req_valid);
        s_req_addr = selected ? m1_req_addr : m0_req_addr;
        s_req_write = selected ? m1_req_write : m0_req_write;
        s_req_wstrb = selected ? m1_req_wstrb : m0_req_wstrb;
        s_req_wdata = selected ? m1_req_wdata : m0_req_wdata;
        s_req_len = selected ? m1_req_len : m0_req_len;
        m0_req_ready = s_req_valid && !selected && s_req_ready;
        m1_req_ready = s_req_valid && selected && s_req_ready;
        m0_rsp_valid = rst_n && busy && !owner && s_rsp_valid;
        m1_rsp_valid = rst_n && busy && owner && s_rsp_valid;
        m0_rsp_rdata = !owner ? s_rsp_rdata : 32'b0;
        m1_rsp_rdata = owner ? s_rsp_rdata : 32'b0;
        m0_rsp_error = !owner && s_rsp_error;
        m1_rsp_error = owner && s_rsp_error;
        m0_rsp_last = !owner && s_rsp_last;
        m1_rsp_last = owner && s_rsp_last;
        s_rsp_ready = rst_n && busy && (owner ? m1_rsp_ready : m0_rsp_ready);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            owner <= 1'b0;
            next_owner <= 1'b0;
            grant_held <= 1'b0;
            held_owner <= 1'b0;
        end else if (busy) begin
            if (s_rsp_valid && s_rsp_ready && s_rsp_last) begin
                busy <= 1'b0;
                next_owner <= !owner;
            end
        end else if (s_req_valid) begin
            if (s_req_ready) begin
                busy <= 1'b1;
                owner <= selected;
                grant_held <= 1'b0;
            end else begin
                // Selection must not change if a competitor arrives during a stall.
                grant_held <= 1'b1;
                held_owner <= selected;
            end
        end
    end
endmodule
