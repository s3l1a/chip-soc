`timescale 1ns/1ps
module tb_plusargs;
    string prefix;
    integer frame_limit;
    longint unsigned cycle_limit;
    initial begin
        if (!$value$plusargs("PREFIX=%s",prefix)) prefix="default";
        if (!$value$plusargs("FRAMES=%d",frame_limit)) frame_limit=3;
        if (!$value$plusargs("CYCLES=%d",cycle_limit)) cycle_limit=100000000;
        assert (prefix == "regression" && frame_limit == 1 && cycle_limit == 64'd12345678901)
            else $fatal(1,"plusargs ignored: prefix=%s frames=%0d cycles=%0d",
                        prefix,frame_limit,cycle_limit);
        $display("PASS tb_plusargs");
        $finish;
    end
endmodule
