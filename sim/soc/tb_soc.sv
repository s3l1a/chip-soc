`timescale 1ns/1ps
module tb_soc;
    import soc_pkg::*;
    logic cpu_clk=0, pixel_clk=0, rst_n=0;
    always #10 cpu_clk = !cpu_clk;
    always #20 pixel_clk = !pixel_clk;
    logic ext_valid, ext_ready, ext_rv, ext_rr, trace_valid, tx_valid;
    req_t ext_req;
    rsp_t ext_rsp;
    trace_t trace;
    logic [7:0] red, green, blue, tx_data;
    logic hs, vs, active, uart_tx;
    logic [31:0] gpio_out;
    soc_top dut (.cpu_clk, .rst_n, .pixel_clk, .pixel_rst_n(rst_n),
        .uart_rx(1'b1), .uart_tx, .gpio_in(32'b0), .gpio_out,
        .vga_r(red), .vga_g(green), .vga_b(blue), .vga_hsync(hs), .vga_vsync(vs),
        .active_video(active), .ext_valid, .ext_ready, .ext_req,
        .ext_rsp_valid(ext_rv), .ext_rsp_ready(ext_rr), .ext_rsp,
        .trace_valid, .trace, .sim_tx_valid(tx_valid), .sim_tx_data(tx_data));
    logic ram_ready, ram_rv, ram_rr, asset_ready, asset_rv, asset_rr, asset_q;
    rsp_t ram_rsp, asset_rsp;
    wire asset_select = ext_req.addr[31:28] == 6;
    assign ext_ready = asset_select ? asset_ready : ram_ready;
    assign ext_rv = asset_q ? asset_rv : ram_rv;
    assign ext_rsp = asset_q ? asset_rsp : ram_rsp;
    assign ram_rr = ext_rr && !asset_q;
    assign asset_rr = ext_rr && asset_q;
    always @(posedge cpu_clk) begin
        if (!rst_n) asset_q <= 0;
        else if (ext_valid && ext_ready) asset_q <= asset_select;
    end
    sim_ram #(.MAX_DELAY(3)) ram (.clk(cpu_clk), .rst_n,
        .req_valid(ext_valid && !asset_select), .req_ready(ram_ready),
        .req_addr(ext_req.addr), .req_write(ext_req.write), .req_wstrb(ext_req.strb),
        .req_wdata(ext_req.data), .req_len(ext_req.len), .rsp_valid(ram_rv), .rsp_ready(ram_rr),
        .rsp_rdata(ram_rsp.data), .rsp_error(ram_rsp.error), .rsp_last(ram_rsp.last));
    sim_ram #(.BASE(32'h60000000), .MEM_BYTES(64*1024*1024), .MAX_DELAY(3)) assets (
        .clk(cpu_clk), .rst_n, .req_valid(ext_valid && asset_select), .req_ready(asset_ready),
        .req_addr(ext_req.addr), .req_write(ext_req.write), .req_wstrb(ext_req.strb),
        .req_wdata(ext_req.data), .req_len(ext_req.len), .rsp_valid(asset_rv), .rsp_ready(asset_rr),
        .rsp_rdata(asset_rsp.data), .rsp_error(asset_rsp.error), .rsp_last(asset_rsp.last));
    protocol_monitor bus_check (.clk(cpu_clk), .rst_n, .req_valid(ext_valid), .req_ready(ext_ready),
        .req_addr(ext_req.addr), .req_write(ext_req.write), .req_wstrb(ext_req.strb),
        .req_wdata(ext_req.data), .req_len(ext_req.len), .rsp_valid(ext_rv), .rsp_ready(ext_rr),
        .rsp_rdata(ext_rsp.data), .rsp_error(ext_rsp.error), .rsp_last(ext_rsp.last),
        .outstanding(), .remaining_beats());
    protocol_monitor instruction_check (.clk(cpu_clk), .rst_n, .req_valid(dut.iv), .req_ready(dut.ir),
        .req_addr(dut.iq.addr), .req_write(dut.iq.write), .req_wstrb(dut.iq.strb),
        .req_wdata(dut.iq.data), .req_len(dut.iq.len), .rsp_valid(dut.irv), .rsp_ready(dut.irr),
        .rsp_rdata(dut.ip.data), .rsp_error(dut.ip.error), .rsp_last(dut.ip.last),
        .outstanding(), .remaining_beats());
    protocol_monitor data_check (.clk(cpu_clk), .rst_n, .req_valid(dut.dv), .req_ready(dut.dr),
        .req_addr(dut.dq.addr), .req_write(dut.dq.write), .req_wstrb(dut.dq.strb),
        .req_wdata(dut.dq.data), .req_len(dut.dq.len), .rsp_valid(dut.drv), .rsp_ready(dut.drr),
        .rsp_rdata(dut.dp.data), .rsp_error(dut.dp.error), .rsp_last(dut.dp.last),
        .outstanding(), .remaining_beats());
    protocol_monitor icache_check (.clk(cpu_clk), .rst_n, .req_valid(dut.imv), .req_ready(dut.imr),
        .req_addr(dut.imq.addr), .req_write(dut.imq.write), .req_wstrb(dut.imq.strb),
        .req_wdata(dut.imq.data), .req_len(dut.imq.len), .rsp_valid(dut.imrv), .rsp_ready(dut.imrr),
        .rsp_rdata(dut.imp.data), .rsp_error(dut.imp.error), .rsp_last(dut.imp.last),
        .outstanding(), .remaining_beats());
    protocol_monitor dcache_check (.clk(cpu_clk), .rst_n, .req_valid(dut.dmv), .req_ready(dut.dmr),
        .req_addr(dut.dmq.addr), .req_write(dut.dmq.write), .req_wstrb(dut.dmq.strb),
        .req_wdata(dut.dmq.data), .req_len(dut.dmq.len), .rsp_valid(dut.dmrv), .rsp_ready(dut.dmrr),
        .rsp_rdata(dut.dmp.data), .rsp_error(dut.dmp.error), .rsp_last(dut.dmp.last),
        .outstanding(), .remaining_beats());
    longint unsigned cycles=0, retired=0, memory_beats=0, writes=0;
    longint unsigned max_cycles=100000000, last_flip_cycle=0;
    integer frame_limit=3, flips=0, captured=0, frame_file=0;
    logic previous_page=0;
    string firmware, wad, prefix="build/soc/frame", frame_name;
    initial begin
        if (!$value$plusargs("FIRMWARE=%s",firmware)) firmware="firmware/build/diagnostic.mem";
        if (!$value$plusargs("WAD=%s",wad)) wad="";
        if (!$value$plusargs("PREFIX=%s",prefix)) prefix="build/soc/frame";
        if (!$value$plusargs("CYCLES=%d",max_cycles)) max_cycles=100000000;
        if (!$value$plusargs("FRAMES=%d",frame_limit)) frame_limit=3;
        assert (frame_limit > 0 && max_cycles > 0) else $fatal(1,"invalid run limits");
        $display("SOC_CONFIG firmware=%s wad=%s prefix=%s frames=%0d cycles=%0d",
                 firmware,wad,prefix,frame_limit,max_cycles);
        #1;
        $readmemh(firmware,ram.words);
        if (wad != "") $readmemh(wad,assets.words);
        repeat(8) @(negedge cpu_clk);
        rst_n=1;
    end
    always @(posedge cpu_clk) if (rst_n) begin
        cycles <= cycles+1;
        if (cycles >= max_cycles) $fatal(1,"SoC watchdog cycles=%0d flips=%0d retired=%0d",cycles,flips,retired);
        if (trace_valid) begin
            retired <= retired+1;
            assert (!trace.trap) else $fatal(1,"trap pc=%h cause=%h tval=%h",trace.pc,trace.cause,trace.tval);
            assert (dut.cpu.rf[0] == 0) else $fatal(1,"x0 changed");
        end
        if (tx_valid) $write("%c",tx_data);
        if (ext_rv && ext_rr) memory_beats <= memory_beats+1;
        if (dut.dv && dut.dr && dut.dq.write && dut.dq.addr[31:17] == 15'h1000) begin
            assert (dut.dq.addr[15:0] < 16'hfa00) else $fatal(1,"framebuffer out of bounds");
            writes <= writes+1;
        end
        if (ext_valid && ext_ready && asset_select)
            assert (!ext_req.write) else $fatal(1,"asset flash write");
    end
    integer raster, x, y;
    always @(negedge pixel_clk) if (rst_n) begin
        if (dut.video.active_page != previous_page) begin
            previous_page = dut.video.active_page;
            flips = flips+1;
            $display("\nSOC_FLIP frame=%0d cycle=%0d cycles_per_frame=%0d memory_beats=%0d",flips,cycles,cycles-last_flip_cycle,memory_beats);
            last_flip_cycle = cycles;
        end
        // Output metadata follows the two synchronous memory stages.
        raster = int'(dut.video.v_count)*800 + int'(dut.video.h_count) - 2;
        if (raster < 0) raster = raster+420000;
        x = raster%800; y = raster/800;
        assert (active == (x<640 && y<480)) else $fatal(1,"video alignment");
        if (x==0 && y==0 && flips>captured && frame_file==0) begin
            frame_name = $sformatf("%s_%0d.ppm",prefix,flips);
            frame_file = $fopen(frame_name,"wb");
            assert (frame_file!=0) else $fatal(1,"cannot open capture %s",frame_name);
            $fwrite(frame_file,"P6\n640 480\n255\n");
        end
        if (frame_file!=0 && x<640 && y<480) begin
            $fwrite(frame_file,"%c%c%c",red,green,blue);
            if (x==639 && y==479) begin
                $fclose(frame_file); frame_file=0; captured=flips;
                $display("\nSOC_CAPTURE frame=%0d path=%s",captured,frame_name);
                if (captured>=frame_limit) begin
                    $display("PASS tb_soc cycles=%0d retired=%0d memory_bytes=%0d framebuffer_writes=%0d frames=%0d",cycles,retired,memory_beats*4,writes,captured);
                    $finish;
                end
            end
        end
    end
endmodule
