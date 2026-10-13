`timescale 1ns/1ps

module tb_cache;
    logic clk = 0;
    always #5 clk = !clk;
    logic rst_n = 0;
    logic req_valid = 0, req_ready, req_write = 0;
    logic [31:0] req_addr = 0, req_wdata = 0;
    logic [3:0] req_wstrb = 0;
    logic rsp_valid, rsp_ready = 0, rsp_error, rsp_last;
    logic [31:0] rsp_rdata;
    logic fence_valid = 0, fence_ready, fence_done;
    logic mem_req_valid, mem_req_ready, mem_req_write;
    logic [31:0] mem_req_addr, mem_req_wdata;
    logic [3:0] mem_req_wstrb;
    logic [2:0] mem_req_len;
    logic mem_rsp_valid, mem_rsp_ready, mem_rsp_error, mem_rsp_last;
    logic [31:0] mem_rsp_rdata;
    logic ram_req_ready, ram_rsp_valid, ram_rsp_ready, ram_rsp_error;
    logic allow_request = 0, allow_response = 0;
    logic block_request = 0, block_response = 0, inject_error = 0, queue_fence = 0;
    integer error_beat = 3;
    logic [31:0] rng = 32'hac123456;
    integer memory_requests = 0, memory_reads = 0, memory_writes = 0;
    integer cpu_responses = 0;
    integer refill_beats = 0;
    logic [31:0] reference_words [0:8191];
    logic model_valid [0:511];
    logic [17:0] model_tag [0:511];

    direct_mapped_cache dut (.*);
    sim_ram #(.MAX_DELAY(9), .SEED(32'h76543210)) ram (
        .clk(clk), .rst_n(rst_n),
        .req_valid(mem_req_valid && allow_request), .req_ready(ram_req_ready),
        .req_addr(mem_req_addr), .req_write(mem_req_write),
        .req_wstrb(mem_req_wstrb), .req_wdata(mem_req_wdata), .req_len(mem_req_len),
        .rsp_valid(ram_rsp_valid), .rsp_ready(ram_rsp_ready),
        .rsp_rdata(mem_rsp_rdata), .rsp_error(ram_rsp_error), .rsp_last(mem_rsp_last)
    );
    assign mem_req_ready = ram_req_ready && allow_request;
    assign mem_rsp_valid = ram_rsp_valid && allow_response;
    assign ram_rsp_ready = mem_rsp_ready && allow_response;
    assign mem_rsp_error = ram_rsp_error ||
                          (inject_error && (mem_req_write || refill_beats == error_beat));

    function automatic logic [31:0] next_random(input logic [31:0] x);
        next_random = {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]};
    endfunction

    always @(negedge clk) begin
        rng = next_random(rng);
        allow_request = !block_request && (rng[2:0] != 0);
        allow_response = !block_response && rng[5:3] != 0;
    end

    logic request_stalled = 0, response_stalled = 0, ram_stalled = 0;
    logic [71:0] held_request;
    logic [33:0] held_response, held_ram;
    logic cpu_busy = 0, memory_busy = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            request_stalled <= 0;
            response_stalled <= 0;
            ram_stalled <= 0;
            cpu_busy <= 0;
            memory_busy <= 0;
            refill_beats <= 0;
        end else begin
            if (request_stalled)
                assert (mem_req_valid &&
                    {mem_req_addr, mem_req_write, mem_req_wstrb, mem_req_wdata, mem_req_len} === held_request)
                    else $fatal(1, "cache downstream request changed under backpressure");
            if (response_stalled)
                assert (rsp_valid && {rsp_rdata, rsp_error, rsp_last} === held_response)
                    else $fatal(1, "cache CPU response changed under backpressure");
            if (ram_stalled)
                assert (ram_rsp_valid && {mem_rsp_rdata, ram_rsp_error, mem_rsp_last} === held_ram)
                    else $fatal(1, "RAM response changed under backpressure");
            request_stalled <= mem_req_valid && !mem_req_ready;
            held_request <= {mem_req_addr, mem_req_write, mem_req_wstrb, mem_req_wdata, mem_req_len};
            response_stalled <= rsp_valid && !rsp_ready;
            held_response <= {rsp_rdata, rsp_error, rsp_last};
            ram_stalled <= ram_rsp_valid && !ram_rsp_ready;
            held_ram <= {mem_rsp_rdata, ram_rsp_error, mem_rsp_last};
            if (req_valid && req_ready) begin
                assert (!cpu_busy) else $fatal(1, "more than one CPU transaction");
                cpu_busy <= 1;
            end
            if (cpu_busy)
                assert (!req_ready && !fence_ready) else $fatal(1, "cache unlocked before CPU completion");
            if (rsp_valid && rsp_ready) begin
                assert (cpu_busy && rsp_last) else $fatal(1, "unexpected CPU response");
                cpu_busy <= 0;
                cpu_responses <= cpu_responses + 1;
            end
            if (mem_req_valid && mem_req_ready) begin
                assert (!memory_busy) else $fatal(1, "more than one downstream transaction");
                assert (mem_req_write ? mem_req_len == 0 :
                        (mem_req_len == 7 && mem_req_addr[4:0] == 0))
                    else $fatal(1, "incorrect cache burst request");
                memory_busy <= 1;
                refill_beats <= 0;
                memory_requests <= memory_requests + 1;
                if (mem_req_write) memory_writes <= memory_writes + 1;
                else memory_reads <= memory_reads + 1;
            end
            if (mem_rsp_valid && mem_rsp_ready) begin
                assert (memory_busy) else $fatal(1, "unsolicited downstream response");
                if (!mem_req_write) begin
                    assert ((mem_rsp_last && mem_rsp_error) || mem_rsp_last == (refill_beats == 7))
                        else $fatal(1, "bad RAM burst termination");
                    refill_beats <= refill_beats + 1;
                end
                if (mem_rsp_last) memory_busy <= 0;
            end
            if (fence_valid && !fence_ready && cpu_busy)
                assert (!fence_done) else $fatal(1, "fence completed during transaction");
        end
    end

    task automatic clear_model;
        for (integer i = 0; i < 512; i = i + 1) begin
            model_valid[i] = 0;
            model_tag[i] = 0;
        end
    endtask

    task automatic finish_fence;
        integer cycles;
        if (!fence_valid) begin
            @(negedge clk);
            fence_valid = 1;
        end
        do @(posedge clk); while (!fence_ready);
        @(negedge clk);
        fence_valid = 0;
        cycles = 0;
        while (!fence_done) begin
            assert (!req_ready && !fence_ready) else $fatal(1, "acceptance during fence sweep");
            @(negedge clk);
            cycles = cycles + 1;
        end
        assert (cycles == 512) else $fatal(1, "fence sweep duration %0d", cycles);
        for (integer i = 0; i < 512; i = i + 1)
            assert (dut.valid_ram[i] === 1'b0) else $fatal(1, "fence left valid line %0d", i);
        clear_model();
    endtask

    task automatic transaction(
        input logic wr, input logic [31:0] address,
        input logic [3:0] strobes, input logic [31:0] data,
        input logic error_expected
    );
        integer index, word_index, requests_before, expected_requests, hold_cycles;
        logic model_hit;
        logic [31:0] expected_data;
        index = int'(address[13:5]);
        word_index = int'((address - 32'h80000000) >> 2);
        model_hit = model_valid[index] && model_tag[index] == address[31:14];
        expected_requests = (wr || !model_hit) ? 1 : 0;
        expected_data = wr || error_expected ? 0 : reference_words[word_index];
        requests_before = memory_requests;
        @(negedge clk);
        inject_error = error_expected;
        req_valid = 1;
        req_addr = address;
        req_write = wr;
        req_wstrb = strobes;
        req_wdata = data;
        rsp_ready = 0;
        do @(posedge clk); while (!req_ready);
        @(negedge clk);
        req_valid = 0;
        // Scramble inactive inputs to expose accidental use of live request signals.
        req_addr = 32'hdeadbeec;
        req_write = !wr;
        req_wstrb = ~strobes;
        req_wdata = ~data;
        while (!rsp_valid) @(negedge clk);
        if (queue_fence) fence_valid = 1;
        hold_cycles = 3 + int'(rng[3:0]);
        repeat (hold_cycles) begin
            assert (!req_ready && !fence_ready) else $fatal(1, "ownership lost under response stall");
            @(negedge clk);
        end
        assert (rsp_error === error_expected && rsp_rdata === expected_data && rsp_last)
            else $fatal(1, "cache addr=%h write=%b got=%h error=%b expected=%h error=%b",
                        address, wr, rsp_rdata, rsp_error, expected_data, error_expected);
        assert (memory_requests - requests_before == expected_requests)
            else $fatal(1, "wrong hit/miss/write allocation behavior at %h", address);
        rsp_ready = 1;
        @(posedge clk);
        @(negedge clk);
        rsp_ready = 0;
        inject_error = 0;
        if (wr) begin
            // Error injection changes the acknowledgment, not RAM's committed write.
            for (integer lane = 0; lane < 4; lane = lane + 1)
                if (strobes[lane]) reference_words[word_index][lane*8 +: 8] = data[lane*8 +: 8];
            if (error_expected && model_hit) model_valid[index] = 0;
        end else if (!model_hit) begin
            model_valid[index] = !error_expected;
            model_tag[index] = address[31:14];
        end
        if (queue_fence) begin
            queue_fence = 0;
            finish_fence();
        end
    endtask

    task automatic reset_cache;
        @(negedge clk);
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (512) begin
            assert (!req_ready) else $fatal(1, "reset invalidation ended early");
            @(negedge clk);
        end
        assert (req_ready && !fence_done) else $fatal(1, "reset invalidation did not finish");
        for (integer i = 0; i < 512; i = i + 1)
            assert (dut.valid_ram[i] === 1'b0) else $fatal(1, "reset left valid line %0d", i);
        clear_model();
    endtask

    initial begin
        #1;
        for (integer i = 0; i < 8192; i = i + 1) begin
            reference_words[i] = 32'h12345678 ^ (32'h9e3779b9 * i[31:0]);
            ram.words[i] = reference_words[i];
        end
        clear_model();
        reset_cache();
        transaction(0, 32'h8000001c, 0, 0, 0);
        for (integer i = 0; i < 8; i = i + 1)
            transaction(0, 32'h80000000 + 32'd4*i[31:0], 0, 0, 0);
        for (integer mask = 0; mask < 16; mask = mask + 1) begin
            transaction(1, 32'h8000000c, mask[3:0], 32'hdeadbeef ^ mask[31:0], 0);
            transaction(0, 32'h8000000c, 0, 0, 0);
        end
        transaction(1, 32'h8000400c, 4'h5, 32'hcafefeed, 0);
        transaction(0, 32'h8000000c, 0, 0, 0); // A write miss must not evict the existing tag.
        transaction(0, 32'h8000400c, 0, 0, 0);
        transaction(0, 32'h8000000c, 0, 0, 0); // Same index, different tag.
        transaction(0, 32'h8000007c, 0, 0, 1); // Middle-beat error must survive a successful last beat.
        transaction(0, 32'h8000007c, 0, 0, 0);
        error_beat = 0;
        transaction(0, 32'h800000a0, 0, 0, 1);
        transaction(0, 32'h800000a0, 0, 0, 0);
        error_beat = 7;
        transaction(0, 32'h800000fc, 0, 0, 1);
        transaction(0, 32'h800000fc, 0, 0, 0);
        transaction(0, 32'h8100001c, 0, 0, 1); // RAM fault terminates the refill early.
        transaction(1, 32'h8000007c, 4'hf, 32'h01020304, 1);
        transaction(0, 32'h8000007c, 0, 0, 0); // Failed write invalidates the hit.
        queue_fence = 1;
        transaction(0, 32'h8000007c, 0, 0, 0);
        transaction(0, 32'h8000007c, 0, 0, 0);

        // The watchdog is test-only. No timeout may release accepted ownership.
        block_request = 1;
        fork
            transaction(0, 32'h80000104, 0, 0, 0);
            begin
                wait (mem_req_valid);
                repeat (100) @(negedge clk);
                assert (!rsp_valid && !req_ready) else $fatal(1, "fabricated response during request stall");
                block_request = 0;
            end
        join

        block_response = 1;
        fork
            transaction(0, 32'h80000218, 0, 0, 0);
            begin
                wait (memory_busy);
                repeat (100) @(negedge clk);
                assert (memory_busy && !rsp_valid && !req_ready && !fence_ready)
                    else $fatal(1, "accepted memory transaction abandoned during response delay");
                block_response = 0;
            end
        join

        for (integer i = 0; i < 512; i = i + 1)
            transaction(0, 32'h80000000 + i[31:0]*32'd32, 0, 0, 0);
        finish_fence();
        for (integer i = 0; i < 512; i = i + 1)
            transaction(0, 32'h80000000 + i[31:0]*32'd32 + 32'd28, 0, 0, 0);
        reset_cache();
        for (integer i = 0; i < 512; i = i + 1)
            transaction(0, 32'h80000000 + i[31:0]*32'd32 + 32'd12, 0, 0, 0);
        for (integer i = 0; i < 500; i = i + 1) begin
            rng = next_random(rng);
            transaction(rng[0], 32'h80000000 + {17'b0, rng[14:2], 2'b0},
                        rng[19:16], rng ^ 32'h55aa1234, 0);
            if (i % 83 == 0) finish_fence();
        end
        $display("PASS tb_cache: responses=%0d downstream_reads=%0d writes=%0d", cpu_responses, memory_reads, memory_writes);
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "tb_cache watchdog");
    end
endmodule
