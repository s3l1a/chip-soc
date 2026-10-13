`timescale 1ns/1ps

module video_core (
    input  wire        cpu_clk,
    input  wire        cpu_rst_n,
    input  wire        pixel_clk,
    input  wire        pixel_rst_n,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] req_addr,
    input  wire        req_write,
    input  wire [3:0]  req_wstrb,
    input  wire [31:0] req_wdata,
    output reg         rsp_valid,
    input  wire        rsp_ready,
    output reg  [31:0] rsp_rdata,
    output reg         rsp_error,
    output wire [7:0]  vga_r,
    output wire [7:0]  vga_g,
    output wire [7:0]  vga_b,
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire        active_video
);
    // Neither memory has a reset port. Contents are software-initialized.
    (* ram_style = "block" *) reg [31:0] framebuffer [0:32767];
    (* ram_style = "block" *) reg [23:0] palette [0:255];
    reg [31:0] fb_cpu_data;
    reg [23:0] palette_cpu_data;
    reg [7:0] palette_index;
    reg enabled;
    reg read_pending, read_palette;
    reg flip_toggle, requested_page, acknowledged_page;
    reg flip_ack, active_page;
    reg [9:0] h_count, v_count;
    reg pixel_vblank;
    (* ASYNC_REG = "TRUE" *) reg ack_meta, ack_sync;
    (* ASYNC_REG = "TRUE" *) reg flip_meta, flip_sync;
    reg flip_seen;
    (* ASYNC_REG = "TRUE" *) reg page_meta, page_sync;
    (* ASYNC_REG = "TRUE" *) reg enable_meta, enable_sync;
    (* ASYNC_REG = "TRUE" *) reg blank_meta, blank_sync;
    wire flip_pending = flip_toggle != ack_sync;
    wire reported_page = flip_pending ? acknowledged_page : requested_page;
    wire fb_address = req_addr[31:17] == 15'h1000
                      && req_addr[15:0] < 16'hfa00
                      && req_addr[1:0] == 0;
    assign req_ready = cpu_rst_n && !rsp_valid && !read_pending;
    wire accept = req_valid && req_ready;
    wire palette_address = req_addr == 32'h1000300c;
    integer lane;

    // CPU BRAM port: synchronous reads and byte-lane writes on acceptance only.
    always @(posedge cpu_clk) begin
        if (accept && fb_address) begin
            if (req_write) begin
                for (lane = 0; lane < 4; lane = lane + 1)
                    if (req_wstrb[lane])
                        framebuffer[req_addr[16:2]][lane*8 +: 8] <= req_wdata[lane*8 +: 8];
            end else fb_cpu_data <= framebuffer[req_addr[16:2]];
        end
        if (accept && palette_address) begin
            if (req_write) begin
                for (lane = 0; lane < 3; lane = lane + 1)
                    if (req_wstrb[lane])
                        palette[palette_index][lane*8 +: 8] <= req_wdata[lane*8 +: 8];
            end else palette_cpu_data <= palette[palette_index];
        end
    end

    always @(posedge cpu_clk or negedge cpu_rst_n) begin
        if (!cpu_rst_n) begin
            ack_meta <= 0; ack_sync <= 0;
            blank_meta <= 0; blank_sync <= 0;
        end else begin
            ack_meta <= flip_ack;
            ack_sync <= ack_meta;
            blank_meta <= pixel_vblank;
            blank_sync <= blank_meta;
        end
    end

    always @(posedge cpu_clk or negedge cpu_rst_n) begin
        if (!cpu_rst_n) begin
            rsp_valid <= 0; rsp_rdata <= 0; rsp_error <= 0;
            read_pending <= 0; read_palette <= 0;
            palette_index <= 0; enabled <= 0;
            flip_toggle <= 0; requested_page <= 0; acknowledged_page <= 0;
        end else begin
            if (!flip_pending) acknowledged_page <= requested_page;
            if (rsp_valid && rsp_ready) rsp_valid <= 0;
            if (read_pending) begin
                read_pending <= 0;
                rsp_valid <= 1;
                rsp_rdata <= read_palette ? {8'b0, palette_cpu_data} : fb_cpu_data;
                rsp_error <= 0;
            end
            if (accept) begin
                rsp_valid <= 1;
                rsp_rdata <= 0;
                rsp_error <= 0;
                if (fb_address || palette_address) begin
                    if (!req_write) begin
                        rsp_valid <= 0;
                        read_pending <= 1;
                        read_palette <= palette_address;
                    end
                end else begin
                    case (req_addr)
                        32'h10003000: begin
                            if (req_write) begin
                                if (req_wstrb[0]) enabled <= req_wdata[0];
                            end else rsp_rdata <= {28'b0, blank_sync,
                                                   reported_page, flip_pending, enabled};
                        end
                        32'h10003004: begin
                            if (req_write) begin
                                if (req_wstrb[0]) begin
                                    if (flip_pending || req_wdata > 1) rsp_error <= 1;
                                    else begin
                                        requested_page <= req_wdata[0];
                                        flip_toggle <= ~flip_toggle;
                                    end
                                end
                            end else rsp_rdata <= {31'b0, requested_page};
                        end
                        32'h10003008: begin
                            if (req_write) begin
                                if (req_wstrb[0]) palette_index <= req_wdata[7:0];
                            end else rsp_rdata <= {24'b0, palette_index};
                        end
                        default: rsp_error <= 1;
                    endcase
                end
            end
        end
    end

    wire visible = h_count < 640 && v_count < 480;
    wire image = visible && v_count >= 40 && v_count < 440;
    wire [9:0] image_y = v_count - 10'd40;
    wire [15:0] byte_offset = image_y[9:1] * 16'd320 + {7'b0, h_count[9:1]};
    wire [14:0] pixel_address = {active_page, byte_offset[15:2]};
    reg [31:0] pixel_word;
    reg [1:0] pixel_lane;
    reg [23:0] pixel_color;
    reg [1:0] hs_pipe, vs_pipe, visible_pipe, image_pipe;
    wire [7:0] color_index = pixel_word[{pixel_lane, 3'b000} +: 8];

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            flip_meta <= 0; flip_sync <= 0; flip_seen <= 0;
            page_meta <= 0; page_sync <= 0;
            enable_meta <= 0; enable_sync <= 0;
            active_page <= 0; flip_ack <= 0;
            h_count <= 0; v_count <= 0;
            pixel_vblank <= 0;
            hs_pipe <= 2'b11; vs_pipe <= 2'b11;
            visible_pipe <= 0; image_pipe <= 0;
            pixel_lane <= 0;
        end else begin
            flip_meta <= flip_toggle;
            flip_sync <= flip_meta;
            flip_seen <= flip_sync;
            page_meta <= requested_page;
            page_sync <= page_meta;
            enable_meta <= enabled;
            enable_sync <= enable_meta;
            // Register the counter decode before crossing to the CPU clock.
            pixel_vblank <= v_count >= 480;
            // The extra toggle stage lets synchronized bundled data settle.
            // The page stays stable until the toggle is acknowledged.
            if (v_count >= 480 && flip_seen != flip_ack) begin
                active_page <= page_sync;
                flip_ack <= flip_seen;
            end
            if (h_count == 799) begin
                h_count <= 0;
                if (v_count == 524) v_count <= 0;
                else v_count <= v_count + 1'b1;
            end else h_count <= h_count + 1'b1;
            pixel_lane <= byte_offset[1:0];
            hs_pipe <= {hs_pipe[0], !(h_count >= 656 && h_count < 752)};
            vs_pipe <= {vs_pipe[0], !(v_count >= 490 && v_count < 492)};
            visible_pipe <= {visible_pipe[0], visible};
            image_pipe <= {image_pipe[0], image && enable_sync};
        end
    end

    // Two synchronous memory stages; syncs and masks follow the same latency.
    always @(posedge pixel_clk) begin
        if (image) pixel_word <= framebuffer[pixel_address];
        pixel_color <= palette[color_index];
    end
    assign vga_r = image_pipe[1] ? pixel_color[23:16] : 8'b0;
    assign vga_g = image_pipe[1] ? pixel_color[15:8] : 8'b0;
    assign vga_b = image_pipe[1] ? pixel_color[7:0] : 8'b0;
    assign vga_hsync = hs_pipe[1];
    assign vga_vsync = vs_pipe[1];
    assign active_video = visible_pipe[1];
endmodule
