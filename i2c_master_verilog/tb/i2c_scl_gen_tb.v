`timescale 1ns/1ps

module i2c_scl_gen_tb;

    reg clk;
    reg reset;
    reg enable;

    wire timing_tick;
    wire [1:0] phase;

    i2c_scl_gen #(
        .CLK_FREQ_HZ(50_000_000),
        .I2C_FREQ_HZ(100_000)
    ) uut (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .timing_tick(timing_tick),
        .phase(phase)
    );

    // 50 MHz clock
    // Period = 20 ns
    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    // Test sequence
    initial begin
        reset  = 1'b1;
        enable = 1'b0;

        #100;

        reset  = 1'b0;
        enable = 1'b1;

        #15000;

        enable = 1'b0;

        #100;

        $finish;
    end

    // Print every timing tick
    always @(posedge clk) begin
        if (timing_tick) begin
            $display(
                "Time = %0t ps | timing_tick = %b | phase = %d",
                $time,
                timing_tick,
                phase
            );
        end
    end

    // Generate waveform
    initial begin
        $dumpfile("i2c_scl_gen.vcd");
        $dumpvars(0, i2c_scl_gen_tb);
    end

endmodule