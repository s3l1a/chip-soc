`timescale 1ns/1ps

module tb_peripherals;
    parameter integer CLK_HZ = 1843200;
    parameter integer BAUD = 115200;
    localparam integer BIT_CLKS = (CLK_HZ + BAUD/2) / BAUD;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    reg req_valid = 0, req_write = 0, rsp_ready = 0;
    reg [31:0] req_addr = 0, req_wdata = 0;
    reg [3:0] req_wstrb = 0;
    wire req_ready, rsp_valid, rsp_error;
    wire [31:0] rsp_rdata;
    reg [31:0] gpio_in = 0;
    wire [31:0] gpio_out;
    wire uart_tx, timer_irq, sim_tx_valid;
    wire [7:0] sim_tx_data;
    reg loopback = 1, manual_rx = 1;
    wire uart_rx = loopback ? uart_tx : manual_rx;
    peripherals #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (.*);

    integer accepted = 0, responded = 0, outstanding = 0;
    integer tx_events = 0, serial_bytes = 0;
    reg [7:0] tx_expected [0:1023];
    reg held = 0;
    reg [31:0] held_data;
    reg held_error;
    reg [63:0] expected_time, next_time;
    integer lane;
    always @(posedge clk) begin
        if (!rst_n) begin
            outstanding = 0;
            held = 0;
            expected_time = 0;
        end else begin
            if (held && (!rsp_valid || rsp_rdata !== held_data || rsp_error !== held_error))
                $fatal(1, "response changed while stalled");
            if (req_valid && req_ready) begin
                if (outstanding != 0) $fatal(1, "more than one outstanding request");
                accepted = accepted + 1;
                outstanding = outstanding + 1;
            end
            if (rsp_valid && rsp_ready) begin
                if (outstanding != 1) $fatal(1, "unsolicited or duplicate response");
                responded = responded + 1;
                outstanding = outstanding - 1;
            end
            held = rsp_valid && !rsp_ready;
            held_data = rsp_rdata;
            held_error = rsp_error;
            next_time = expected_time + 1;
            if (req_valid && req_ready && req_write && |req_wstrb
                && (req_addr == 32'h10001000 || req_addr == 32'h10001004)) begin
                next_time = expected_time;
                for (lane = 0; lane < 4; lane = lane + 1)
                    if (req_wstrb[lane])
                        next_time[(req_addr[2] ? 32 : 0) + lane*8 +: 8] = req_wdata[lane*8 +: 8];
            end
            expected_time = next_time;
            #1;
            if (dut.mtime !== expected_time) $fatal(1, "mtime repeated write or bad increment");
            if (sim_tx_valid) begin
                tx_expected[tx_events] = sim_tx_data;
                tx_events = tx_events + 1;
            end
        end
    end

    // Independently decode physical 8N1 transmission, not internal TX state.
    reg [7:0] serial_data;
    integer bit_number;
    initial forever begin
        @(negedge uart_tx);
        if (rst_n) begin
            repeat (BIT_CLKS/2) @(posedge clk);
            #1;
            if (uart_tx !== 0) $fatal(1, "bad TX start bit");
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                repeat (BIT_CLKS) @(posedge clk);
                #1;
                serial_data[bit_number] = uart_tx;
            end
            repeat (BIT_CLKS) @(posedge clk);
            #1;
            if (uart_tx !== 1) $fatal(1, "bad TX stop bit");
            if (serial_bytes >= tx_events || serial_data !== tx_expected[serial_bytes])
                $fatal(1, "TX byte/order mismatch at byte %0d", serial_bytes);
            serial_bytes = serial_bytes + 1;
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
            @(negedge clk);
            req_valid = 1; req_write = write_op; req_addr = address;
            req_wdata = data; req_wstrb = strobes; rsp_ready = 0;
            do @(posedge clk); while (!req_ready);
            @(negedge clk);
            while (!rsp_valid) @(negedge clk);
            snapshot = rsp_rdata; error_snapshot = rsp_error;
            if (rsp_error !== error_expected)
                $fatal(1, "error mismatch at %h: got %b expected %b", address, rsp_error, error_expected);
            req_wdata = ~data;
            // Keep the original request asserted across stalls to catch repeats.
            repeat (stall) begin
                @(negedge clk);
                if (!rsp_valid || req_ready || rsp_rdata !== snapshot || rsp_error !== error_snapshot)
                    $fatal(1, "bad held response at %h", address);
            end
            result = snapshot;
            req_valid = 0; rsp_ready = 1;
            @(negedge clk);
            rsp_ready = 0;
            if (rsp_valid) $fatal(1, "response did not drain");
        end
    endtask

    task automatic send_rx(input [7:0] data, input bit good_stop);
        integer b;
        begin
            @(negedge clk); manual_rx = 0;
            repeat (BIT_CLKS) @(negedge clk);
            for (b = 0; b < 8; b = b + 1) begin
                manual_rx = data[b];
                repeat (BIT_CLKS) @(negedge clk);
            end
            manual_rx = good_stop;
            repeat (BIT_CLKS) @(negedge clk);
            manual_rx = 1;
            repeat (BIT_CLKS*2) @(negedge clk);
        end
    endtask

    reg [31:0] result, low_time, concurrent_result;
    integer i, event_base;
    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        access_bus(0, 32'h10004000, 0, 0, 0, 7, result);
        if (result !== 0) $fatal(1, "storage must report unavailable");
        access_bus(1, 32'h10004000, 1, 15, 1, 3, result);
        access_bus(0, 32'h10004004, 0, 0, 1, 3, result);
        access_bus(0, 32'h10003000, 0, 0, 1, 1, result);
        access_bus(0, 32'h10000010, 0, 0, 1, 1, result);
        access_bus(0, 32'h10000001, 0, 0, 1, 1, result);
        access_bus(1, 32'h10000000, 0, 15, 1, 1, result);
        access_bus(0, 32'h10000004, 0, 0, 1, 1, result);
        access_bus(1, 32'h10000008, 0, 15, 1, 1, result);
        access_bus(0, 32'h10000008, 0, 0, 1, 8, result);

        gpio_in = 32'h89abcdef;
        repeat (4) @(negedge clk);
        access_bus(0, 32'h10002000, 0, 0, 0, 9, result);
        if (result !== gpio_in) $fatal(1, "GPIO input synchronization");
        access_bus(1, 32'h10002000, 0, 15, 1, 0, result);
        access_bus(1, 32'h10002004, 32'h12345678, 15, 0, 13, result);
        access_bus(1, 32'h10002004, 32'haabbccdd, 5, 0, 8, result);
        access_bus(1, 32'h10002004, 0, 0, 0, 2, result);
        access_bus(0, 32'h10002004, 0, 0, 0, 2, result);
        if (result !== 32'h12bb56dd || gpio_out !== result) $fatal(1, "GPIO strobes");

        if (timer_irq) $fatal(1, "timer IRQ asserted after reset");
        access_bus(0, 32'h10001000, 0, 0, 0, 30, low_time);
        access_bus(0, 32'h10001000, 0, 0, 0, 0, result);
        if (result <= low_time + 30) $fatal(1, "timer stopped on response stall");
        access_bus(1, 32'h10001004, 0, 15, 0, 3, result);
        access_bus(1, 32'h10001000, 32'hfffffff0, 15, 0, 40, result);
        access_bus(0, 32'h10001004, 0, 0, 0, 0, result);
        if (result !== 1) $fatal(1, "64-bit timer carry");
        access_bus(1, 32'h10001000, 0, 0, 0, 5, result);
        access_bus(1, 32'h1000100c, 1, 15, 0, 1, result);
        access_bus(0, 32'h10001000, 0, 0, 0, 0, result);
        access_bus(1, 32'h10001008, result + 80, 15, 0, 2, result);
        if (timer_irq) $fatal(1, "early timer IRQ");
        repeat (100) @(negedge clk);
        if (!timer_irq) $fatal(1, "missing timer IRQ");
        access_bus(1, 32'h1000100c, 32'hffffffff, 15, 0, 5, result);
        if (timer_irq) $fatal(1, "timer IRQ did not clear");
        access_bus(1, 32'h10001008, 32'h11223344, 15, 0, 0, result);
        access_bus(1, 32'h10001008, 32'haabbccdd, 10, 0, 4, result);
        access_bus(0, 32'h10001008, 0, 0, 0, 0, result);
        if (result !== 32'haa22cc44) $fatal(1, "mtimecmp strobes");

        access_bus(1, 32'h10000004, 32'h5a, 1, 0, BIT_CLKS*12, result);
        if (tx_events != 1 || serial_bytes != 1) $fatal(1, "TX side effect repeated during stall");
        access_bus(0, 32'h10000008, 0, 0, 0, 25, result);
        if (result !== 32'h5a) $fatal(1, "UART loopback");
        access_bus(0, 32'h10000008, 0, 0, 1, 2, result);
        access_bus(1, 32'h10000004, 32'h55, 14, 0, 3, result);
        access_bus(1, 32'h10000004, 32'h55, 0, 0, 3, result);
        if (tx_events != 1) $fatal(1, "TX ignored strobes");
        access_bus(1, 32'h10000004, 32'h81, 1, 0, 0, result);
        access_bus(1, 32'h10000004, 32'hc3, 1, 0, 0, result);
        repeat (BIT_CLKS*24) @(negedge clk);
        access_bus(0, 32'h10000008, 0, 0, 0, 25, result);
        if (result !== 32'h81) $fatal(1, "RX first queued byte");
        access_bus(0, 32'h10000008, 0, 0, 0, 25, result);
        if (result !== 32'hc3) $fatal(1, "RX pop repeated on stall");

        event_base = tx_events;
        for (i = 0; i < 17; i = i + 1)
            access_bus(1, 32'h10000004, i, 1, 0, 0, result);
        access_bus(0, 32'h10000000, 0, 0, 0, 0, result);
        if (!result[3] || result[4] || result[20:16] != 16) $fatal(1, "TX FIFO not full");
        access_bus(1, 32'h10000004, 32'hff, 1, 1, 8, result);
        if (tx_events != event_base + 17) $fatal(1, "TX overflow accepted");
        repeat (BIT_CLKS*190) @(negedge clk);
        access_bus(0, 32'h10000000, 0, 0, 0, 7, result);
        if (!result[2] || result[12:8] != 16 || result[0]) $fatal(1, "RX FIFO/TX drain status");
        access_bus(0, 32'h1000000c, 0, 0, 0, 8, result);
        if (result !== 3) $fatal(1, "overflow sticky flags");
        for (i = 0; i < 16; i = i + 1) begin
            access_bus(0, 32'h10000008, 0, 0, 0, i % 4, result);
            if (result !== i) $fatal(1, "FIFO wrap/order at %0d", i);
        end
        access_bus(0, 32'h10000008, 0, 0, 1, 2, result);
        access_bus(1, 32'h1000000c, 1, 1, 0, 4, result);
        access_bus(0, 32'h1000000c, 0, 0, 0, 0, result);
        if (result !== 2) $fatal(1, "W1C must preserve uncleared flags");
        access_bus(1, 32'h1000000c, 2, 0, 0, 0, result);
        access_bus(0, 32'h1000000c, 0, 0, 0, 0, result);
        if (result !== 2) $fatal(1, "W1C ignored strobe");
        access_bus(1, 32'h1000000c, 2, 1, 0, 0, result);

        loopback = 0;
        send_rx(8'ha6, 1);
        access_bus(0, 32'h10000008, 0, 0, 0, 9, result);
        if (result !== 32'ha6) $fatal(1, "external RX input");
        send_rx(8'hff, 0);
        access_bus(0, 32'h1000000c, 0, 0, 0, 5, result);
        if (result !== 4) $fatal(1, "framing error flag");
        access_bus(0, 32'h10000008, 0, 0, 1, 2, result);
        access_bus(1, 32'h1000000c, 4, 1, 0, 0, result);
        access_bus(0, 32'h1000000c, 0, 0, 0, 0, result);
        if (result !== 0) $fatal(1, "framing W1C");

        // A full FIFO can replace its head when a pop and RX arrival coincide.
        for (i = 0; i < 16; i = i + 1) send_rx(8'h40 + i[7:0], 1);
        fork
            send_rx(8'h90, 1);
            begin
                wait (dut.rx_state == 3 && dut.rx_ticks == 0);
                access_bus(0, 32'h10000008, 0, 0, 0, 20, concurrent_result);
                if (concurrent_result !== 32'h40) $fatal(1, "simultaneous full FIFO pop");
            end
        join
        access_bus(0, 32'h1000000c, 0, 0, 0, 0, result);
        if (result !== 0) $fatal(1, "simultaneous pop falsely overflowed");
        for (i = 1; i < 16; i = i + 1) begin
            access_bus(0, 32'h10000008, 0, 0, 0, 2, result);
            if (result !== 32'h40 + i) $fatal(1, "simultaneous FIFO order");
        end
        access_bus(0, 32'h10000008, 0, 0, 0, 2, result);
        if (result !== 32'h90) $fatal(1, "replacement FIFO byte missing");
        access_bus(0, 32'h10000008, 0, 0, 1, 2, result);
        // A short low pulse must fail start-bit validation, not enqueue data.
        @(negedge clk); manual_rx = 0;
        @(negedge clk); manual_rx = 1;
        repeat (BIT_CLKS*12) @(negedge clk);
        access_bus(0, 32'h10000008, 0, 0, 1, 2, result);
        access_bus(0, 32'h1000000c, 0, 0, 0, 2, result);
        if (result !== 0) $fatal(1, "false start generated an error");
        repeat (5) @(negedge clk);
        if (accepted != responded || outstanding != 0 || tx_events != serial_bytes)
            $fatal(1, "final accounting mismatch");
        $display("PASS tb_peripherals CLK_HZ=%0d BAUD=%0d BIT_CLKS=%0d requests=%0d responses=%0d tx_events=%0d serial_bytes=%0d",
                 CLK_HZ, BAUD, BIT_CLKS, accepted, responded, tx_events, serial_bytes);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "tb_peripherals timeout");
    end
endmodule
