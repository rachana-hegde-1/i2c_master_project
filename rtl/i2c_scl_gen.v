module i2c_scl_gen #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer I2C_FREQ_HZ = 100_000
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       enable,

    output reg        timing_tick,
    output reg [1:0]  phase
);

    // Four timing phases are used for one complete SCL period.
    //
    // 50 MHz / (100 kHz × 4) = 125 clocks per phase

    localparam integer PHASE_CYCLES =
                    CLK_FREQ_HZ / (I2C_FREQ_HZ * 4);

    reg [7:0] count;

    always @(posedge clk) begin

        // Active-high synchronous reset
        if (reset) begin
            count       <= 8'd0;
            phase       <= 2'd0;
            timing_tick <= 1'b0;
        end

        // Generator disabled
        else if (!enable) begin
            count       <= 8'd0;
            phase       <= 2'd0;
            timing_tick <= 1'b0;
        end

        else begin

            // Default: tick is LOW
            timing_tick <= 1'b0;

            // End of one 125-clock phase
            if (count == PHASE_CYCLES - 1) begin

                count       <= 8'd0;
                timing_tick <= 1'b1;

                // Move to next phase
                phase <= phase + 1'b1;

            end

            else begin
                count <= count + 1'b1;
            end

        end

    end

endmodule
