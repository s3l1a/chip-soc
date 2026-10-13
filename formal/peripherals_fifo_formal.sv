`timescale 1ns/1ps

module peripherals_fifo_formal (
    input wire clk,
    input wire rst_n, req_valid, req_write, rsp_ready, uart_rx,
    input wire [31:0] req_addr, req_wdata, gpio_in,
    input wire [3:0] req_wstrb
);
    wire req_ready, rsp_valid, rsp_error, uart_tx, timer_irq, sim_tx_valid;
    wire [31:0] rsp_rdata, gpio_out;
    wire [7:0] sim_tx_data;
    peripherals #(.CLK_HZ(1843200), .BAUD(115200)) dut (.*);

    // Connected to real DUT state/events by peripherals_fifo_setup.ys.
    wire [4:0] observed_tx_count, observed_rx_count;
    wire [3:0] observed_tx_wr, observed_tx_rd, observed_rx_wr, observed_rx_rd;
    wire observed_tx_push, observed_tx_pop, observed_rx_push, observed_rx_pop;
    wire observed_tx_write;
    wire [3:0] tx_distance = observed_tx_wr - observed_tx_rd;
    wire [3:0] rx_distance = observed_rx_wr - observed_rx_rd;
    wire [68:0] request_payload = {req_addr, req_write, req_wstrb, req_wdata};
    reg past_valid = 1'b0;

    always @(posedge clk) begin
        past_valid <= 1'b1;
        if (!past_valid) assume (!rst_n);
        else assume (rst_n);

        if (past_valid && rst_n) begin
            if (req_valid) assume (req_addr[1:0] == 0);
            if ($past(rst_n) && $past(req_valid && !req_ready))
                assume (req_valid && request_payload == $past(request_payload));

            // Neither the receive waveform nor bus/response timing is restricted.
            assert (observed_tx_count <= 5'd16);
            assert (observed_rx_count <= 5'd16);
            assert (tx_distance == observed_tx_count[3:0]);
            assert (rx_distance == observed_rx_count[3:0]);
            assert (!observed_tx_pop || observed_tx_count != 0);
            assert (!observed_rx_pop || observed_rx_count != 0);
            assert (!observed_tx_push || observed_tx_count < 16 || observed_tx_pop);
            assert (!observed_rx_push || observed_rx_count < 16 || observed_rx_pop);

            if ($past(rst_n)) begin
                case ($past({observed_tx_push, observed_tx_pop}))
                    2'b10: assert (observed_tx_count == $past(observed_tx_count) + 5'd1);
                    2'b01: assert (observed_tx_count == $past(observed_tx_count) - 5'd1);
                    default: assert (observed_tx_count == $past(observed_tx_count));
                endcase
                case ($past({observed_rx_push, observed_rx_pop}))
                    2'b10: assert (observed_rx_count == $past(observed_rx_count) + 5'd1);
                    2'b01: assert (observed_rx_count == $past(observed_rx_count) - 5'd1);
                    default: assert (observed_rx_count == $past(observed_rx_count));
                endcase
                assert (observed_tx_wr == ($past(observed_tx_wr) + ($past(observed_tx_push) ? 4'd1 : 4'd0)));
                assert (observed_tx_rd == ($past(observed_tx_rd) + ($past(observed_tx_pop) ? 4'd1 : 4'd0)));
                assert (observed_rx_wr == ($past(observed_rx_wr) + ($past(observed_rx_push) ? 4'd1 : 4'd0)));
                assert (observed_rx_rd == ($past(observed_rx_rd) + ($past(observed_rx_pop) ? 4'd1 : 4'd0)));
            end

            cover (observed_tx_count == 16);
            cover (observed_tx_write && !observed_tx_push);
            cover (observed_tx_push && observed_tx_pop);
            cover (observed_rx_push);
            cover (observed_rx_pop);
        end
    end
endmodule
