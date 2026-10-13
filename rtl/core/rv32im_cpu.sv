`timescale 1ns/1ps
module rv32im_cpu #(
    parameter logic [31:0] RESET_PC = 32'h00000000
) (
    input logic clk, rst_n, timer_irq,
    output logic i_valid, input logic i_ready,
    output soc_pkg::req_t i_req,
    input logic i_rsp_valid, output logic i_rsp_ready,
    input soc_pkg::rsp_t i_rsp,
    output logic d_valid, input logic d_ready,
    output soc_pkg::req_t d_req,
    input logic d_rsp_valid, output logic d_rsp_ready,
    input soc_pkg::rsp_t d_rsp,
    output logic fence_i, input logic fence_done,
    output logic trace_valid, output soc_pkg::trace_t trace
);
    import soc_pkg::*;
    typedef enum logic [3:0] {FETCH, IF_REQ, IF_WAIT, EXEC, MEM_REQ, MEM_WAIT,
                             DIV_WAIT, FENCE_WAIT} state_t;
    state_t state;
    logic [31:0] rf [0:31];
    logic [31:0] pc, insn;
    logic [31:0] mstatus, mie, mtvec, mscratch, mepc, mcause, mtval;
    logic [63:0] cycle_count, instret_count, order;
    logic [31:0] mem_address;
    req_t mem_request;
    logic [4:0] mem_rd;
    logic [2:0] mem_f3;
    wire [6:0] op = insn[6:0];
    wire [2:0] f3 = insn[14:12];
    wire [6:0] f7 = insn[31:25];
    wire [4:0] rd = insn[11:7], rs1 = insn[19:15], rs2 = insn[24:20];
    wire [31:0] a = rs1 == 0 ? 32'b0 : rf[rs1];
    wire [31:0] b = rs2 == 0 ? 32'b0 : rf[rs2];
    wire [31:0] ii = {{20{insn[31]}},insn[31:20]};
    wire [31:0] si = {{20{insn[31]}},insn[31:25],insn[11:7]};
    wire [31:0] bi = {{19{insn[31]}},insn[31],insn[7],insn[30:25],insn[11:8],1'b0};
    wire [31:0] ji = {{11{insn[31]}},insn[31],insn[19:12],insn[20],insn[30:21],1'b0};
    logic [31:0] value, target, ea, shifted_load, csr_old, csr_source, csr_new;
    logic illegal, branch_taken, csr_known, csr_ro, csr_write;
    logic signed [32:0] mul_a, mul_b;
    logic signed [65:0] product;
    logic div_start, div_busy, div_done;
    logic [31:0] div_result;
    logic [31:0] operand2;
    always_comb begin
        i_req = '0; i_req.addr = pc;
        i_valid = state == IF_REQ;
        i_rsp_ready = state == IF_WAIT;
        d_req = mem_request; d_valid = state == MEM_REQ;
        d_rsp_ready = state == MEM_WAIT;
        fence_i = state == FENCE_WAIT;
        operand2 = op == 7'h13 ? ii : b;
        mul_a = $signed({(f3 == 1 || f3 == 2) && a[31], a});
        mul_b = $signed({f3 == 1 && b[31], b});
        product = mul_a * mul_b;
        value = 0; illegal = 0;
        case (f3)
            0: value = op == 7'h33 && f7 == 7'h20 ? a-b : a+operand2;
            1: value = a << operand2[4:0];
            2: value = {31'b0, $signed(a) < $signed(operand2)};
            3: value = {31'b0, a < operand2};
            4: value = a ^ operand2;
            5: value = insn[30] ? $unsigned($signed(a) >>> operand2[4:0]) : a >> operand2[4:0];
            6: value = a | operand2;
            7: value = a & operand2;
            default: value = 0;
        endcase
        if (op == 7'h33)
            illegal = !(f7 == 0 || f7 == 1 || (f7 == 7'h20 && (f3 == 0 || f3 == 5)));
        if (op == 7'h13 && (f3 == 1 || f3 == 5))
            illegal = !(f7 == 0 || (f3 == 5 && f7 == 7'h20));
        if (op == 7'h33 && f7 == 1) value = f3 == 0 ? product[31:0] : product[63:32];
        branch_taken = 0;
        case (f3)
            0: branch_taken = a == b;
            1: branch_taken = a != b;
            4: branch_taken = $signed(a) < $signed(b);
            5: branch_taken = $signed(a) >= $signed(b);
            6: branch_taken = a < b;
            7: branch_taken = a >= b;
            default: branch_taken = 0;
        endcase
        target = op == 7'h67 ? (a+ii) & 32'hfffffffe : pc + (op == 7'h6f ? ji : bi);
        ea = a + (op == 7'h03 ? ii : si);
        shifted_load = d_rsp.data >> {mem_address[1:0],3'b0};
        csr_old = 0; csr_known = 1; csr_ro = 0;
        case (insn[31:20])
            12'h300: csr_old = mstatus;
            12'h301: csr_old = 32'h40001100;
            12'h304: csr_old = mie;
            12'h305: csr_old = mtvec;
            12'h306,12'h310: csr_old = 0;
            12'h340: csr_old = mscratch;
            12'h341: csr_old = mepc;
            12'h342: csr_old = mcause;
            12'h343: csr_old = mtval;
            12'h344: csr_old = timer_irq ? 32'h80 : 0;
            12'hb00: csr_old = cycle_count[31:0];
            12'hb80: csr_old = cycle_count[63:32];
            12'hb02: csr_old = instret_count[31:0];
            12'hb82: csr_old = instret_count[63:32];
            12'hc00: begin csr_old = cycle_count[31:0]; csr_ro = 1; end
            12'hc80: begin csr_old = cycle_count[63:32]; csr_ro = 1; end
            12'hc02: begin csr_old = instret_count[31:0]; csr_ro = 1; end
            12'hc82: begin csr_old = instret_count[63:32]; csr_ro = 1; end
            12'hf11,12'hf12,12'hf13,12'hf14,12'hf15: begin csr_old = 0; csr_ro = 1; end
            default: csr_known = 0;
        endcase
        csr_source = f3[2] ? {27'b0,rs1} : a;
        csr_write = f3[1:0] == 1 || rs1 != 0;
        case (f3[1:0])
            1: csr_new = csr_source;
            2: csr_new = csr_old | csr_source;
            default: csr_new = csr_old & ~csr_source;
        endcase
        div_start = state == EXEC && op == 7'h33 && f7 == 1 && f3[2];
    end
    divider divide (.clk, .rst_n, .start(div_start), .signed_mode(!f3[0]),
        .remainder_mode(f3[1]), .dividend(a), .divisor(b), .busy(div_busy),
        .done(div_done), .result(div_result));

    task automatic retire(input logic [4:0] dest, input logic [31:0] result,
                           input logic [31:0] next_pc);
        begin
            if (dest != 0) rf[dest] <= result;
            trace_valid <= 1; trace.order <= order; trace.pc <= pc;
            trace.insn <= insn; trace.next_pc <= next_pc; trace.rd <= dest;
            trace.result <= dest == 0 ? 0 : result; trace.trap <= 0;
            trace.cause <= 0; trace.tval <= 0;
            order <= order+1'b1; instret_count <= instret_count+1'b1;
            pc <= next_pc; state <= FETCH;
        end
    endtask
    task automatic trap(input logic [31:0] cause, input logic [31:0] bad,
                        input logic [31:0] fault_insn);
        logic [31:0] handler;
        begin
            handler = {mtvec[31:2],2'b0};
            if (cause[31] && mtvec[1:0] == 1) handler = handler + ((cause & 32'h7fffffff)<<2);
            mepc <= pc; mcause <= cause; mtval <= bad;
            mstatus <= 32'h1800 | (mstatus[3] ? 32'h80 : 0);
            trace_valid <= 1; trace.order <= order; trace.pc <= pc;
            trace.insn <= fault_insn; trace.next_pc <= handler; trace.rd <= 0;
            trace.result <= 0; trace.trap <= 1; trace.cause <= cause; trace.tval <= bad;
            order <= order+1'b1; pc <= handler; state <= FETCH;
        end
    endtask
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= FETCH; pc <= RESET_PC; insn <= 0;
            for (int j=0;j<32;j++) rf[j] <= 0;
            mstatus <= 32'h1800; mie <= 0; mtvec <= 0; mscratch <= 0;
            mepc <= 0; mcause <= 0; mtval <= 0;
            cycle_count <= 0; instret_count <= 0; order <= 0;
            mem_request <= '0; mem_address <= 0; mem_rd <= 0; mem_f3 <= 0;
            trace <= '0; trace_valid <= 0;
        end else begin
            trace_valid <= 0; cycle_count <= cycle_count+1'b1; rf[0] <= 0;
            case (state)
                FETCH: begin
                    if (timer_irq && mstatus[3] && mie[7]) trap(32'h80000007,0,0);
                    else if (pc[1:0] != 0) trap(0,pc,0);
                    else state <= IF_REQ;
                end
                IF_REQ: if (i_ready) state <= IF_WAIT;
                IF_WAIT: if (i_rsp_valid) begin
                    if (i_rsp.error) trap(1,pc,0);
                    else begin insn <= i_rsp.data; state <= EXEC; end
                end
                EXEC: begin
                    case (op)
                        7'h37: retire(rd,{insn[31:12],12'b0},pc+4);
                        7'h17: retire(rd,pc+{insn[31:12],12'b0},pc+4);
                        7'h13,7'h33: begin
                            if (illegal) trap(2,insn,insn);
                            else if (div_start) state <= DIV_WAIT;
                            else retire(rd,value,pc+4);
                        end
                        7'h6f,7'h67: begin
                            if (op == 7'h67 && f3 != 0) trap(2,insn,insn);
                            else if (target[1:0] != 0) trap(0,target,insn);
                            else retire(rd,pc+4,target);
                        end
                        7'h63: begin
                            if (f3 == 2 || f3 == 3) trap(2,insn,insn);
                            else if (branch_taken && target[1:0] != 0) trap(0,target,insn);
                            else retire(0,0,branch_taken ? target : pc+4);
                        end
                        7'h03,7'h23: begin
                            if ((op == 7'h03 && !(f3 == 0 || f3 == 1 || f3 == 2 || f3 == 4 || f3 == 5)) ||
                                (op == 7'h23 && f3 > 2)) trap(2,insn,insn);
                            else if ((f3[1:0] == 1 && ea[0]) || (f3[1:0] == 2 && ea[1:0] != 0))
                                trap(op == 7'h03 ? 4 : 6,ea,insn);
                            else begin
                                mem_address <= ea; mem_rd <= rd; mem_f3 <= f3;
                                mem_request.addr <= {ea[31:2],2'b0}; mem_request.len <= 0;
                                mem_request.write <= op == 7'h23;
                                mem_request.strb <= (f3 == 0 ? 4'b0001 : f3 == 1 ? 4'b0011 : 4'b1111) << ea[1:0];
                                mem_request.data <= b << {ea[1:0],3'b0}; state <= MEM_REQ;
                            end
                        end
                        7'h0f: begin
                            if (f3 == 0) retire(0,0,pc+4);
                            else if (f3 == 1) state <= FENCE_WAIT;
                            else trap(2,insn,insn);
                        end
                        7'h73: begin
                            if (f3 != 0) begin
                                if (f3 == 4 || !csr_known || (csr_ro && csr_write)) trap(2,insn,insn);
                                else begin
                                    retire(rd,csr_old,pc+4);
                                    if (csr_write) case (insn[31:20])
                                        12'h300: mstatus <= 32'h1800 | (csr_new & 32'h88);
                                        12'h304: mie <= csr_new & 32'h80;
                                        12'h305: mtvec <= {csr_new[31:2],1'b0,csr_new[1:0] == 1};
                                        12'h340: mscratch <= csr_new;
                                        12'h341: mepc <= {csr_new[31:2],2'b0};
                                        12'h342: mcause <= csr_new;
                                        12'h343: mtval <= csr_new;
                                        12'hb00: cycle_count <= {cycle_count[63:32],csr_new};
                                        12'hb80: cycle_count <= {csr_new,cycle_count[31:0]};
                                        12'hb02: instret_count <= {instret_count[63:32],csr_new};
                                        12'hb82: instret_count <= {csr_new,instret_count[31:0]};
                                        default: begin end
                                    endcase
                                end
                            end else if (insn == 32'h00000073) trap(11,0,insn);
                            else if (insn == 32'h00100073) trap(3,pc,insn);
                            else if (insn == 32'h30200073) begin
                                mstatus <= 32'h1880 | (mstatus[7] ? 32'h8 : 0);
                                retire(0,0,mepc);
                            end else if (insn == 32'h10500073) retire(0,0,pc+4);
                            else trap(2,insn,insn);
                        end
                        default: trap(2,insn,insn);
                    endcase
                end
                MEM_REQ: if (d_ready) state <= MEM_WAIT;
                MEM_WAIT: if (d_rsp_valid) begin
                    if (d_rsp.error) trap(mem_request.write ? 7 : 5,mem_address,insn);
                    else if (mem_request.write) retire(0,0,pc+4);
                    else case (mem_f3)
                        0: retire(mem_rd,{{24{shifted_load[7]}},shifted_load[7:0]},pc+4);
                        1: retire(mem_rd,{{16{shifted_load[15]}},shifted_load[15:0]},pc+4);
                        4: retire(mem_rd,{24'b0,shifted_load[7:0]},pc+4);
                        5: retire(mem_rd,{16'b0,shifted_load[15:0]},pc+4);
                        default: retire(mem_rd,d_rsp.data,pc+4);
                    endcase
                end
                DIV_WAIT: if (div_done) retire(rd,div_result,pc+4);
                FENCE_WAIT: if (fence_done) retire(0,0,pc+4);
                default: state <= FETCH;
            endcase
        end
    end
endmodule
