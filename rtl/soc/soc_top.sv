`timescale 1ns/1ps
module soc_top #(
    parameter ROM_FILE = "",
    parameter integer CLK_HZ = 50000000
) (
    input logic cpu_clk, rst_n, pixel_clk, pixel_rst_n,
    input logic uart_rx, output logic uart_tx,
    input logic [31:0] gpio_in, output logic [31:0] gpio_out,
    output logic [7:0] vga_r, vga_g, vga_b,
    output logic vga_hsync, vga_vsync, active_video,
    output logic ext_valid, input logic ext_ready, output soc_pkg::req_t ext_req,
    input logic ext_rsp_valid, output logic ext_rsp_ready, input soc_pkg::rsp_t ext_rsp,
    output logic trace_valid, output soc_pkg::trace_t trace,
    output logic sim_tx_valid, output logic [7:0] sim_tx_data
);
    import soc_pkg::*;
    logic iv, ir, irv, irr, dv, dr, drv, drr, fence_i, fence_done, irq;
    req_t iq, dq, imq, dmq, bus_req;
    rsp_t ip, dp, imp, dmp, bus_rsp;
    logic imv, imr, imrv, imrr, dmv, dmr, dmrv, dmrr;
    logic bus_valid, bus_ready, bus_rsp_valid, bus_rsp_ready;
    rv32im_cpu cpu (.clk(cpu_clk), .rst_n, .timer_irq(irq),
        .i_valid(iv), .i_ready(ir), .i_req(iq), .i_rsp_valid(irv), .i_rsp_ready(irr), .i_rsp(ip),
        .d_valid(dv), .d_ready(dr), .d_req(dq), .d_rsp_valid(drv), .d_rsp_ready(drr), .d_rsp(dp),
        .fence_i, .fence_done, .trace_valid, .trace);
    cache_port icache (.clk(cpu_clk), .rst_n, .req_valid(iv), .req_ready(ir), .req(iq),
        .rsp_valid(irv), .rsp_ready(irr), .rsp(ip), .invalidate(fence_i), .invalidate_done(fence_done),
        .mem_valid(imv), .mem_ready(imr), .mem_req(imq),
        .mem_rsp_valid(imrv), .mem_rsp_ready(imrr), .mem_rsp(imp));
    cache_port dcache (.clk(cpu_clk), .rst_n, .req_valid(dv), .req_ready(dr), .req(dq),
        .rsp_valid(drv), .rsp_ready(drr), .rsp(dp), .invalidate(1'b0), .invalidate_done(),
        .mem_valid(dmv), .mem_ready(dmr), .mem_req(dmq),
        .mem_rsp_valid(dmrv), .mem_rsp_ready(dmrr), .mem_rsp(dmp));
    bus_arbiter arbitration (.clk(cpu_clk), .rst_n,
        .m0_req_valid(imv), .m0_req_ready(imr), .m0_req_addr(imq.addr), .m0_req_write(imq.write),
        .m0_req_wstrb(imq.strb), .m0_req_wdata(imq.data), .m0_req_len(imq.len),
        .m0_rsp_valid(imrv), .m0_rsp_ready(imrr), .m0_rsp_rdata(imp.data),
        .m0_rsp_error(imp.error), .m0_rsp_last(imp.last),
        .m1_req_valid(dmv), .m1_req_ready(dmr), .m1_req_addr(dmq.addr), .m1_req_write(dmq.write),
        .m1_req_wstrb(dmq.strb), .m1_req_wdata(dmq.data), .m1_req_len(dmq.len),
        .m1_rsp_valid(dmrv), .m1_rsp_ready(dmrr), .m1_rsp_rdata(dmp.data),
        .m1_rsp_error(dmp.error), .m1_rsp_last(dmp.last),
        .s_req_valid(bus_valid), .s_req_ready(bus_ready), .s_req_addr(bus_req.addr),
        .s_req_write(bus_req.write), .s_req_wstrb(bus_req.strb), .s_req_wdata(bus_req.data),
        .s_req_len(bus_req.len), .s_rsp_valid(bus_rsp_valid), .s_rsp_ready(bus_rsp_ready),
        .s_rsp_rdata(bus_rsp.data), .s_rsp_error(bus_rsp.error), .s_rsp_last(bus_rsp.last));

    typedef enum logic [2:0] {ROM, RAM, IO, VIDEO, FAULT} slave_t;
    slave_t decoded, selected;
    logic bus_busy, local_valid;
    rsp_t local_rsp;
    logic io_ready, io_rv, video_ready, video_rv;
    rsp_t io_rsp, video_rsp;
    logic [31:0] rom [0:4095];
    logic [31:0] rom_data;
    initial begin
        for (int j=0;j<4096;j++) rom[j] = 32'h00000013;
        rom[0] = 32'h800002b7;
        rom[1] = 32'h0000100f;
        rom[2] = 32'h00028067;
        if (ROM_FILE != "") $readmemh(ROM_FILE,rom);
    end
    always_comb begin
        decoded = FAULT;
        if (bus_req.addr < 32'h00004000 && !bus_req.write && bus_req.len == 0) decoded = ROM;
        else if (bus_req.addr >= 32'h80000000 &&
                 {1'b0,bus_req.addr} + (({30'b0,bus_req.len}+33'd1)<<2) <= 33'h081000000 &&
                 (bus_req.write ? bus_req.len == 0 : bus_req.len == 0 || bus_req.len == 7)) decoded = RAM;
        else if (bus_req.addr >= 32'h60000000 && !bus_req.write &&
                 {1'b0,bus_req.addr} + (({30'b0,bus_req.len}+33'd1)<<2) <= 33'h064000000 &&
                 (bus_req.len == 0 || bus_req.len == 7)) decoded = RAM;
        else if (bus_req.len == 0) begin
            if ((bus_req.addr >= 32'h10003000 && bus_req.addr < 32'h10004000) ||
                (bus_req.addr >= 32'h20000000 && bus_req.addr < 32'h20020000)) decoded = VIDEO;
            else if (bus_req.addr >= 32'h10000000 && bus_req.addr < 32'h10005000) decoded = IO;
        end
        if (bus_req.addr[1:0] != 0) decoded = FAULT;
        bus_ready = 0;
        if (!bus_busy) case (decoded)
            RAM: bus_ready = ext_ready;
            IO: bus_ready = io_ready;
            VIDEO: bus_ready = video_ready;
            default: bus_ready = !local_valid;
        endcase
        ext_valid = bus_valid && !bus_busy && decoded == RAM;
        ext_req = bus_req;
        bus_rsp_valid = 0; bus_rsp = '0;
        if (bus_busy) case (selected)
            RAM: begin bus_rsp_valid = ext_rsp_valid; bus_rsp = ext_rsp; end
            IO: begin bus_rsp_valid = io_rv; bus_rsp = io_rsp; end
            VIDEO: begin bus_rsp_valid = video_rv; bus_rsp = video_rsp; end
            default: begin
                bus_rsp_valid = local_valid; bus_rsp = local_rsp;
                if (selected == ROM) bus_rsp.data = rom_data;
            end
        endcase
        ext_rsp_ready = bus_busy && selected == RAM && bus_rsp_ready;
    end
    assign io_rsp.last = 1;
    assign video_rsp.last = 1;
    // Keep the ROM read register reset-free for BRAM inference.
    always_ff @(posedge cpu_clk)
        if (bus_valid && bus_ready && decoded == ROM) rom_data <= rom[bus_req.addr[13:2]];
    always_ff @(posedge cpu_clk) begin
        if (!rst_n) begin bus_busy <= 0; local_valid <= 0; selected <= FAULT; local_rsp <= '0; end
        else begin
            if (bus_valid && bus_ready) begin
                bus_busy <= 1; selected <= decoded;
                if (decoded == ROM || decoded == FAULT) begin
                    local_valid <= 1; local_rsp.last <= 1;
                    local_rsp.error <= decoded == FAULT;
                    local_rsp.data <= 0;
                end
            end
            if (bus_rsp_valid && bus_rsp_ready && bus_rsp.last) begin
                bus_busy <= 0; local_valid <= 0;
            end
        end
    end
    peripherals #(.CLK_HZ(CLK_HZ)) io (.clk(cpu_clk), .rst_n,
        .req_valid(bus_valid && !bus_busy && decoded == IO), .req_ready(io_ready),
        .req_addr(bus_req.addr), .req_write(bus_req.write), .req_wstrb(bus_req.strb), .req_wdata(bus_req.data),
        .rsp_valid(io_rv), .rsp_ready(bus_busy && selected == IO && bus_rsp_ready),
        .rsp_rdata(io_rsp.data), .rsp_error(io_rsp.error),
        .uart_tx, .uart_rx, .gpio_in, .gpio_out, .timer_irq(irq), .sim_tx_valid, .sim_tx_data);
    video_core video (.cpu_clk, .cpu_rst_n(rst_n), .pixel_clk, .pixel_rst_n,
        .req_valid(bus_valid && !bus_busy && decoded == VIDEO), .req_ready(video_ready),
        .req_addr(bus_req.addr), .req_write(bus_req.write), .req_wstrb(bus_req.strb), .req_wdata(bus_req.data),
        .rsp_valid(video_rv), .rsp_ready(bus_busy && selected == VIDEO && bus_rsp_ready),
        .rsp_rdata(video_rsp.data), .rsp_error(video_rsp.error),
        .vga_r, .vga_g, .vga_b, .vga_hsync, .vga_vsync, .active_video);
endmodule
