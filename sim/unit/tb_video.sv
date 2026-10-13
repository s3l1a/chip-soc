`timescale 1ns/1ps

module tb_video;
    parameter integer CPU_HALF = 10;
    parameter integer PIXEL_HALF = 19;
    parameter integer PIXEL_PHASE = 3;
    reg cpu_clk = 0, pixel_clk = 0;
    always #CPU_HALF cpu_clk = ~cpu_clk;
    initial begin
        #PIXEL_PHASE;
        forever #PIXEL_HALF pixel_clk = ~pixel_clk;
    end
    reg cpu_rst_n = 0, pixel_rst_n = 0;
    reg req_valid = 0, req_write = 0, rsp_ready = 0;
    reg [31:0] req_addr = 0, req_wdata = 0;
    reg [3:0] req_wstrb = 0;
    wire req_ready, rsp_valid, rsp_error;
    wire [31:0] rsp_rdata;
    wire [7:0] vga_r, vga_g, vga_b;
    wire vga_hsync, vga_vsync, active_video;
    video_core dut (.*);

    integer accepted = 0, responded = 0, outstanding = 0;
    reg held = 0;
    reg [31:0] held_data;
    reg held_error;
    always @(posedge cpu_clk) begin
        if (!cpu_rst_n) begin
            outstanding = 0;
            held = 0;
        end else begin
            if (held && (!rsp_valid || rsp_rdata !== held_data || rsp_error !== held_error))
                $fatal(1, "video response changed while stalled");
            if (req_valid && req_ready) begin
                if (outstanding != 0) $fatal(1, "multiple video requests outstanding");
                outstanding = outstanding + 1;
                accepted = accepted + 1;
            end
            if (rsp_valid && rsp_ready) begin
                if (outstanding != 1) $fatal(1, "unsolicited video response");
                outstanding = outstanding - 1;
                responded = responded + 1;
            end
            held = rsp_valid && !rsp_ready;
            held_data = rsp_rdata;
            held_error = rsp_error;
        end
    end

    // Sample pre-edge source values so coincident clocks follow RTL NBA timing.
    reg ref_blank_meta = 0, ref_blank_sync = 0;
    reg ref_ack_meta = 0, ref_ack_sync = 0;
    reg old_blank_sync, old_ack_sync, status_read;
    reg [3:0] sampled_status;
    integer blank_rises = 0, blank_falls = 0, ack_transitions = 0, status_reads = 0;
    always @(posedge cpu_clk) begin
        if (!cpu_rst_n) begin
            ref_blank_meta = 0; ref_blank_sync = 0;
            ref_ack_meta = 0; ref_ack_sync = 0;
        end else begin
            status_read = req_valid && req_ready && !req_write && req_addr == 32'h10003000;
            sampled_status = {ref_blank_sync, dut.reported_page,
                              (dut.flip_toggle != ref_ack_sync), dut.enabled};
            old_blank_sync = ref_blank_sync;
            old_ack_sync = ref_ack_sync;
            ref_blank_sync = ref_blank_meta;
            ref_blank_meta = dut.pixel_vblank;
            ref_ack_sync = ref_ack_meta;
            ref_ack_meta = dut.flip_ack;
            #1;
            if (dut.blank_meta !== ref_blank_meta || dut.blank_sync !== ref_blank_sync)
                $fatal(1, "registered vblank CPU synchronizer latency mismatch");
            if (dut.ack_meta !== ref_ack_meta || dut.ack_sync !== ref_ack_sync)
                $fatal(1, "flip acknowledgment CPU synchronizer latency mismatch");
            if (!old_blank_sync && ref_blank_sync) blank_rises = blank_rises + 1;
            if (old_blank_sync && !ref_blank_sync) blank_falls = blank_falls + 1;
            if (old_ack_sync != ref_ack_sync) ack_transitions = ack_transitions + 1;
            if (!dut.flip_pending && dut.reported_page !== dut.active_page)
                $fatal(1, "displayed page incoherent after acknowledgment");
            if (status_read) begin
                if (!rsp_valid || rsp_error || rsp_rdata !== {28'b0, sampled_status})
                    $fatal(1, "status did not snapshot pre-acceptance synchronized flags");
                status_reads = status_reads + 1;
            end
        end
    end

    task automatic access_bus(
        input bit write_op, input [31:0] address, input [31:0] data,
        input [3:0] strobes, input bit error_expected, input integer stall,
        output [31:0] result
    );
        reg [31:0] snapshot;
        reg error_snapshot;
        begin
            @(negedge cpu_clk);
            req_valid = 1; req_write = write_op; req_addr = address;
            req_wdata = data; req_wstrb = strobes; rsp_ready = 0;
            do @(posedge cpu_clk); while (!req_ready);
            @(negedge cpu_clk);
            while (!rsp_valid) @(negedge cpu_clk);
            snapshot = rsp_rdata; error_snapshot = rsp_error;
            if (rsp_error !== error_expected)
                $fatal(1, "video error mismatch at %h", address);
            req_wdata = ~data;
            repeat (stall) begin
                @(negedge cpu_clk);
                if (!rsp_valid || req_ready || rsp_rdata !== snapshot || rsp_error !== error_snapshot)
                    $fatal(1, "video stalled response at %h", address);
            end
            result = snapshot;
            req_valid = 0; rsp_ready = 1;
            @(negedge cpu_clk);
            rsp_ready = 0;
            if (rsp_valid) $fatal(1, "video response did not drain");
        end
    endtask

    function automatic [7:0] index_at(input integer x, y, page);
        index_at = (x + 3*y + 71*page) % 256;
    endfunction
    function automatic [23:0] color_at(input [7:0] index);
        color_at = {index, (index ^ 8'h5a), (8'hff - index)};
    endfunction
    function automatic [31:0] word_at(input integer word_number, page);
        integer b, offset;
        begin
            for (b = 0; b < 4; b = b + 1) begin
                offset = word_number*4 + b;
                word_at[b*8 +: 8] = index_at(offset % 320, offset / 320, page);
            end
        end
    endfunction

    // Independent raster/pixel model. Every output pixel, including porches,
    // is checked against the coordinate entering BRAM one clock earlier.
    integer ref_h = 0, ref_v = 0;
    integer checked_pixels = 0, complete_frames = 0, page_changes = 0;
    integer visible_count = 0, hsync_count = 0, vsync_count = 0;
    integer last_h = 0, last_v = 0;
    reg expected_page = 0, show_image = 0;
    reg last_page = 0, model_valid = 0;
    reg exp_hs = 1, exp_vs = 1, exp_visible = 0;
    reg [23:0] exp_rgb = 0;
    reg next_hs, next_vs, next_visible, next_blank;
    reg [23:0] next_rgb;
    always @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            ref_h = 0; ref_v = 0;
            model_valid = 0; last_page = 0;
            visible_count = 0; hsync_count = 0; vsync_count = 0;
        end else begin
            if (dut.h_count !== ref_h[9:0] || dut.v_count !== ref_v[9:0])
                $fatal(1, "raster counter mismatch");
            next_hs = !(ref_h >= 656 && ref_h < 752);
            next_vs = !(ref_v >= 490 && ref_v < 492);
            next_visible = ref_h < 640 && ref_v < 480;
            next_blank = ref_v >= 480;
            next_rgb = 0;
            if (show_image && next_visible && ref_v >= 40 && ref_v < 440)
                next_rgb = color_at(index_at(ref_h/2, (ref_v-40)/2, expected_page));
            #1;
            if (dut.pixel_vblank !== next_blank)
                $fatal(1, "pixel vblank source register latency mismatch at %0d,%0d", ref_h, ref_v);
            if (dut.active_page != last_page) begin
                if (ref_v < 480) $fatal(1, "page changed outside vertical blank");
                page_changes = page_changes + 1;
                last_page = dut.active_page;
            end
            if (model_valid) begin
                if (vga_hsync !== exp_hs || vga_vsync !== exp_vs || active_video !== exp_visible)
                    $fatal(1, "sync/active pipeline mismatch at %0d,%0d", last_h, last_v);
                if ({vga_r, vga_g, vga_b} !== exp_rgb)
                    $fatal(1, "RGB mismatch at %0d,%0d page=%0d got=%h expected=%h",
                           last_h, last_v, expected_page, {vga_r, vga_g, vga_b}, exp_rgb);
                checked_pixels = checked_pixels + 1;
                if (exp_visible) visible_count = visible_count + 1;
                if (!exp_hs) hsync_count = hsync_count + 1;
                if (!exp_vs) vsync_count = vsync_count + 1;
                if (last_h == 799 && last_v == 524) begin
                    if (visible_count != 307200 || hsync_count != 50400 || vsync_count != 1600)
                        $fatal(1, "frame totals visible=%0d hsync=%0d vsync=%0d",
                               visible_count, hsync_count, vsync_count);
                    complete_frames = complete_frames + 1;
                    visible_count = 0; hsync_count = 0; vsync_count = 0;
                end
            end
            model_valid = 1;
            exp_hs = next_hs; exp_vs = next_vs; exp_visible = next_visible; exp_rgb = next_rgb;
            last_h = ref_h; last_v = ref_v;
            if (ref_h == 799) begin
                ref_h = 0;
                if (ref_v == 524) ref_v = 0;
                else ref_v = ref_v + 1;
            end else ref_h = ref_h + 1;
        end
    end

    reg [31:0] result, word_data;
    integer i, p;
    initial begin
        repeat (5) @(negedge cpu_clk);
        cpu_rst_n = 1;
        @(negedge pixel_clk); pixel_rst_n = 1;
        // Undefined BRAM must never leak to outputs while disabled.
        repeat (80000) @(negedge pixel_clk);
        pixel_rst_n = 0;
        access_bus(0, 32'h10003000, 0, 0, 0, 9, result);
        if (result[2:0] !== 0) $fatal(1, "display reset status");
        access_bus(1, 32'h10003004, 2, 1, 1, 7, result);
        access_bus(1, 32'h10003004, 32'hffffffff, 1, 1, 2, result);
        access_bus(1, 32'h10003004, 1, 0, 0, 2, result);
        access_bus(0, 32'h10003000, 0, 0, 0, 0, result);
        if (result[2:0] !== 0) $fatal(1, "invalid flip changed status");
        access_bus(0, 32'h10003010, 0, 0, 1, 2, result);
        access_bus(0, 32'h10003001, 0, 0, 1, 2, result);
        access_bus(0, 32'h10002000, 0, 0, 1, 2, result);

        access_bus(1, 32'h20000000, 32'h11223344, 15, 0, 9, result);
        access_bus(1, 32'h20000000, 32'haabbccdd, 5, 0, 7, result);
        access_bus(1, 32'h20000000, 0, 0, 0, 7, result);
        access_bus(0, 32'h20000000, 0, 0, 0, 20, result);
        if (result !== 32'h11bb33dd) $fatal(1, "framebuffer byte strobes");
        access_bus(1, 32'h20000001, 0, 15, 1, 3, result);
        access_bus(1, 32'h2000f9fc, 32'habcdef01, 15, 0, 2, result);
        access_bus(0, 32'h2000f9fc, 0, 0, 0, 8, result);
        if (result !== 32'habcdef01) $fatal(1, "page zero last word");
        access_bus(1, 32'h20010000, 32'h76543210, 15, 0, 2, result);
        access_bus(0, 32'h20010000, 0, 0, 0, 8, result);
        if (result !== 32'h76543210) $fatal(1, "page isolation");
        access_bus(1, 32'h2001f9fc, 32'hfedcba98, 15, 0, 2, result);
        access_bus(0, 32'h2001f9fc, 0, 0, 0, 8, result);
        if (result !== 32'hfedcba98) $fatal(1, "page one last word");
        access_bus(0, 32'h1ffffffc, 0, 0, 1, 3, result);
        access_bus(1, 32'h2000fa00, 0, 15, 1, 3, result);
        access_bus(0, 32'h2000fffc, 0, 0, 1, 3, result);
        access_bus(1, 32'h2001fa00, 0, 15, 1, 3, result);
        access_bus(0, 32'h2001fffc, 0, 0, 1, 3, result);
        access_bus(1, 32'h20020000, 0, 15, 1, 3, result);
        access_bus(0, 32'h40000000, 0, 0, 1, 3, result);

        access_bus(1, 32'h10003008, 255, 1, 0, 7, result);
        access_bus(1, 32'h1000300c, 32'h00123456, 15, 0, 7, result);
        access_bus(1, 32'h1000300c, 32'h00abcdef, 2, 0, 7, result);
        access_bus(1, 32'h1000300c, 0, 8, 0, 7, result);
        access_bus(0, 32'h1000300c, 0, 0, 0, 20, result);
        if (result !== 32'h0012cd56) $fatal(1, "palette byte strobes");
        access_bus(0, 32'h10003008, 0, 0, 0, 5, result);
        if (result !== 255) $fatal(1, "palette index unexpectedly advanced");
        for (i = 0; i < 256; i = i + 1) begin
            access_bus(1, 32'h10003008, i, 1, 0, 0, result);
            access_bus(1, 32'h1000300c, {8'b0, color_at(i[7:0])}, 7, 0, 0, result);
            access_bus(0, 32'h1000300c, 0, 0, 0, i % 3, result);
            if (result !== {8'b0, color_at(i[7:0])}) $fatal(1, "palette readback %0d", i);
        end
        for (p = 0; p < 2; p = p + 1)
            for (i = 0; i < 16000; i = i + 1)
                access_bus(1, 32'h20000000 + p*65536 + i*4, word_at(i, p), 15, 0, 0, result);
        for (p = 0; p < 2; p = p + 1)
            for (i = 0; i < 256; i = i + 1) begin
                access_bus(0, 32'h20000000 + p*65536 + ((i*61)%16000)*4, 0, 0, 0, i % 5, result);
                if (result !== word_at((i*61)%16000, p)) $fatal(1, "framebuffer readback");
            end

        @(negedge pixel_clk); pixel_rst_n = 1;
        repeat (1000) @(negedge pixel_clk);
        access_bus(1, 32'h10003000, 1, 0, 0, 5, result);
        if (dut.enabled) $fatal(1, "enable ignored strobes");
        access_bus(1, 32'h10003000, 1, 1, 0, 12, result);
        show_image = 1;
        wait (dut.v_count == 100 && dut.h_count == 37);
        access_bus(1, 32'h10003004, 1, 1, 0, 25, result);
        access_bus(0, 32'h10003000, 0, 0, 0, 5, result);
        if (result[2:0] !== 3'b011) $fatal(1, "visible flip not pending");
        access_bus(1, 32'h10003004, 0, 1, 1, 15, result);
        access_bus(1, 32'h10003004, 1, 1, 1, 15, result);
        access_bus(0, 32'h10003004, 0, 0, 0, 9, result);
        if (result !== 1) $fatal(1, "duplicate flip changed requested page");
        wait (dut.v_count == 480 && dut.h_count == 0);
        access_bus(0, 32'h10003000, 0, 0, 0, 4, result);
        wait (dut.active_page == 1);
        expected_page = 1;
        access_bus(0, 32'h10003000, 0, 0, 0, 1, result);
        repeat (8) @(negedge cpu_clk);
        access_bus(0, 32'h10003000, 0, 0, 0, 10, result);
        if (result[3:0] !== 4'b1101) $fatal(1, "flip acknowledgment status");

        // Let page one scan a whole frame, then request at the final blank
        // pixel. Synchronizer latency must defer the request to the next blank.
        wait (complete_frames == 1);
        access_bus(0, 32'h10003000, 0, 0, 0, 4, result);
        wait (dut.v_count == 524 && dut.h_count == 799);
        access_bus(1, 32'h10003004, 0, 1, 0, 13, result);
        repeat (8) @(negedge pixel_clk);
        if (dut.active_page != 1) $fatal(1, "late-blank flip tore next frame");
        access_bus(0, 32'h10003000, 0, 0, 0, 4, result);
        if (result[2:0] !== 3'b111) $fatal(1, "late-blank request not pending");
        wait (dut.active_page == 0);
        expected_page = 0;
        access_bus(0, 32'h10003000, 0, 0, 0, 1, result);
        repeat (8) @(negedge cpu_clk);
        access_bus(0, 32'h10003000, 0, 0, 0, 10, result);
        if (result[3:0] !== 4'b1001) $fatal(1, "return flip acknowledgment");
        wait (complete_frames == 4);
        access_bus(1, 32'h10003000, 0, 1, 0, 15, result);
        show_image = 0;
        wait (dut.v_count == 50 && dut.h_count == 0);
        @(negedge pixel_clk);
        if (page_changes != 2 || accepted != responded || outstanding != 0
            || blank_rises != 4 || blank_falls != 4 || ack_transitions != 2 || status_reads != 10)
            $fatal(1, "video final accounting mismatch");
        $display("PASS tb_video CPU_HALF=%0d PIXEL_HALF=%0d PIXEL_PHASE=%0d requests=%0d responses=%0d checked_pixels=%0d complete_frames=%0d page_changes=%0d blank_rises=%0d blank_falls=%0d ack_transitions=%0d status_reads=%0d",
                 CPU_HALF, PIXEL_HALF, PIXEL_PHASE, accepted, responded, checked_pixels, complete_frames, page_changes,
                 blank_rises, blank_falls, ack_transitions, status_reads);
        $finish;
    end
    initial begin
        #200000000;
        $fatal(1, "tb_video timeout");
    end
endmodule
