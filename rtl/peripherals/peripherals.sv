`timescale 1ns/1ps

module peripherals #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 115200
) (
    input  wire        clk,
    input  wire        rst_n,
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
    output wire        uart_tx,
    input  wire        uart_rx,
    input  wire [31:0] gpio_in,
    output reg  [31:0] gpio_out,
    output wire        timer_irq,
    output reg         sim_tx_valid,
    output reg  [7:0]  sim_tx_data
);
    localparam integer BIT_CLKS = ((CLK_HZ + BAUD/2) / BAUD < 2)
                                 ? 2 : (CLK_HZ + BAUD/2) / BAUD;
    reg [63:0] mtime, mtimecmp;
    (* ASYNC_REG = "TRUE" *) reg [31:0] gpio_meta, gpio_sync;
    (* ASYNC_REG = "TRUE" *) reg rx_meta, rx_sync;
    reg [7:0] tx_fifo [0:15];
    reg [7:0] rx_fifo [0:15];
    reg [3:0] tx_wr, tx_rd, rx_wr, rx_rd;
    reg [4:0] tx_count, rx_count;
    reg [2:0] errors;
    reg [9:0] tx_shift;
    reg [3:0] tx_bits;
    integer tx_ticks, rx_ticks;
    reg [1:0] rx_state;
    reg [2:0] rx_bit;
    reg [7:0] rx_shift;

    assign req_ready = rst_n && !rsp_valid;
    wire accept = req_valid && req_ready;
    assign timer_irq = (mtime >= mtimecmp);
    assign uart_tx = (tx_bits != 0) ? tx_shift[0] : 1'b1;
    wire tx_pop = (tx_bits == 0) && (tx_count != 0);
    wire tx_write = accept && req_write && req_wstrb[0]
                    && req_addr == 32'h10000004;
    wire tx_push = tx_write && (tx_count < 16 || tx_pop);
    wire rx_pop = accept && !req_write && req_addr == 32'h10000008
                  && rx_count != 0;
    wire rx_done = (rx_state == 3) && (rx_ticks == 0);
    wire rx_push = rx_done && rx_sync && (rx_count < 16 || rx_pop);
    wire [2:0] errors_clear = (accept && req_write && req_wstrb[0]
                               && req_addr == 32'h1000000c)
                              ? req_wdata[2:0] : 3'b0;
    wire [2:0] errors_set = {rx_done && !rx_sync,
                             tx_write && !tx_push,
                             rx_done && rx_sync && !rx_push};

    function automatic [31:0] merge_bytes(
        input [31:0] old_data, input [31:0] new_data, input [3:0] strobes
    );
        integer lane;
        begin
            merge_bytes = old_data;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (strobes[lane])
                    merge_bytes[lane*8 +: 8] = new_data[lane*8 +: 8];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gpio_meta <= 0;
            gpio_sync <= 0;
            rx_meta <= 1;
            rx_sync <= 1;
        end else begin
            gpio_meta <= gpio_in;
            gpio_sync <= gpio_meta;
            rx_meta <= uart_rx;
            rx_sync <= rx_meta;
        end
    end

    // Counts include queued bytes, not the byte currently on the TX wire.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_wr <= 0; tx_rd <= 0; tx_count <= 0;
            rx_wr <= 0; rx_rd <= 0; rx_count <= 0;
            errors <= 0;
            sim_tx_valid <= 0;
            sim_tx_data <= 0;
        end else begin
            errors <= (errors & ~errors_clear) | errors_set;
            sim_tx_valid <= tx_push;
            if (tx_push) begin
                tx_fifo[tx_wr] <= req_wdata[7:0];
                tx_wr <= tx_wr + 1'b1;
                sim_tx_data <= req_wdata[7:0];
            end
            if (tx_pop) tx_rd <= tx_rd + 1'b1;
            case ({tx_push, tx_pop})
                2'b10: tx_count <= tx_count + 1'b1;
                2'b01: tx_count <= tx_count - 1'b1;
                default: ;
            endcase
            if (rx_push) begin
                rx_fifo[rx_wr] <= rx_shift;
                rx_wr <= rx_wr + 1'b1;
            end
            if (rx_pop) rx_rd <= rx_rd + 1'b1;
            case ({rx_push, rx_pop})
                2'b10: rx_count <= rx_count + 1'b1;
                2'b01: rx_count <= rx_count - 1'b1;
                default: ;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_shift <= 10'h3ff;
            tx_bits <= 0;
            tx_ticks <= 0;
        end else if (tx_pop) begin
            tx_shift <= {1'b1, tx_fifo[tx_rd], 1'b0};
            tx_bits <= 10;
            tx_ticks <= BIT_CLKS - 1;
        end else if (tx_bits != 0) begin
            if (tx_ticks == 0) begin
                tx_shift <= {1'b1, tx_shift[9:1]};
                tx_bits <= tx_bits - 1'b1;
                tx_ticks <= BIT_CLKS - 1;
            end else tx_ticks <= tx_ticks - 1;
        end
    end

    // Validate the start bit at its center, then sample every full bit period.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= 0;
            rx_ticks <= 0;
            rx_bit <= 0;
            rx_shift <= 0;
        end else begin
            case (rx_state)
                0: if (!rx_sync) begin
                    rx_state <= 1;
                    rx_ticks <= BIT_CLKS/2 - 1;
                end
                1: if (rx_ticks == 0) begin
                    if (!rx_sync) begin
                        rx_state <= 2;
                        rx_bit <= 0;
                        rx_ticks <= BIT_CLKS - 1;
                    end else rx_state <= 0;
                end else rx_ticks <= rx_ticks - 1;
                2: if (rx_ticks == 0) begin
                    rx_shift[rx_bit] <= rx_sync;
                    rx_ticks <= BIT_CLKS - 1;
                    if (rx_bit == 7) rx_state <= 3;
                    else rx_bit <= rx_bit + 1'b1;
                end else rx_ticks <= rx_ticks - 1;
                3: if (rx_ticks == 0) rx_state <= 0;
                   else rx_ticks <= rx_ticks - 1;
                default: rx_state <= 0;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_valid <= 0;
            rsp_rdata <= 0;
            rsp_error <= 0;
            mtime <= 0;
            mtimecmp <= 64'hffffffffffffffff;
            gpio_out <= 0;
        end else begin
            mtime <= mtime + 1'b1;
            if (rsp_valid && rsp_ready) rsp_valid <= 0;
            if (accept) begin
                rsp_valid <= 1;
                rsp_rdata <= 0;
                rsp_error <= 0;
                case (req_addr)
                    32'h10000000: begin
                        if (req_write) rsp_error <= 1;
                        else rsp_rdata <= {11'b0, tx_count, 3'b0, rx_count,
                            3'b0, (tx_count < 16), (tx_count == 16),
                            (rx_count == 16), (rx_count != 0),
                            (tx_bits != 0 || tx_count != 0)};
                    end
                    32'h10000004: begin
                        if (!req_write || (req_wstrb[0] && !tx_push)) rsp_error <= 1;
                    end
                    32'h10000008: begin
                        if (req_write || rx_count == 0) rsp_error <= 1;
                        else rsp_rdata <= {24'b0, rx_fifo[rx_rd]};
                    end
                    32'h1000000c: if (!req_write) rsp_rdata <= {29'b0, errors};
                    32'h10001000: begin
                        if (req_write && |req_wstrb)
                            mtime <= {mtime[63:32], merge_bytes(mtime[31:0], req_wdata, req_wstrb)};
                        else if (!req_write) rsp_rdata <= mtime[31:0];
                    end
                    32'h10001004: begin
                        if (req_write && |req_wstrb)
                            mtime <= {merge_bytes(mtime[63:32], req_wdata, req_wstrb), mtime[31:0]};
                        else if (!req_write) rsp_rdata <= mtime[63:32];
                    end
                    32'h10001008: begin
                        if (req_write) mtimecmp[31:0] <= merge_bytes(mtimecmp[31:0], req_wdata, req_wstrb);
                        else rsp_rdata <= mtimecmp[31:0];
                    end
                    32'h1000100c: begin
                        if (req_write) mtimecmp[63:32] <= merge_bytes(mtimecmp[63:32], req_wdata, req_wstrb);
                        else rsp_rdata <= mtimecmp[63:32];
                    end
                    32'h10002000: begin
                        if (req_write) rsp_error <= 1;
                        else rsp_rdata <= gpio_sync;
                    end
                    32'h10002004: begin
                        if (req_write) gpio_out <= merge_bytes(gpio_out, req_wdata, req_wstrb);
                        else rsp_rdata <= gpio_out;
                    end
                    32'h10004000: if (req_write) rsp_error <= 1;
                    default: rsp_error <= 1;
                endcase
            end
        end
    end
endmodule
