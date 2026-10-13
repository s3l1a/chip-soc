`timescale 1ns/1ps
package soc_pkg;
    typedef struct packed {
        logic [31:0] addr;
        logic write;
        logic [3:0] strb;
        logic [31:0] data;
        logic [2:0] len;
    } req_t;
    typedef struct packed {
        logic [31:0] data;
        logic error;
        logic last;
    } rsp_t;
    typedef struct packed {
        logic [63:0] order;
        logic [31:0] pc;
        logic [31:0] insn;
        logic [31:0] next_pc;
        logic [4:0] rd;
        logic [31:0] result;
        logic trap;
        logic [31:0] cause;
        logic [31:0] tval;
    } trace_t;
endpackage
