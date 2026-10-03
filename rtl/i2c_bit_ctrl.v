`timescale 1ns/1ps
`include "i2c_defs.vh"

module i2c_bit_ctrl (
    input  wire       clk,
    input  wire       rst_n,

    // Timing tick from P2
    input  wire       tick,

    // Control to/from P2
    output wire       running,
    output wire       stall,

    // Command interface from P4/P5
    input  wire       cmd_valid,
    input  wire [2:0] cmd,
    input  wire       din,

    output wire       ready,
    output reg        done,
    output reg        dout,
    output reg        arb_lost,

    // Bus status
    output reg        bus_busy,

    // Physical I2C bus inputs
    input  wire       scl_i,
    input  wire       sda_i,

    // Open-drain outputs
    output reg        scl_oe,
    output reg        sda_oe
);

    // ------------------------------------------------------------
    // Synchronize SCL and SDA
    // ------------------------------------------------------------

    reg scl_meta, scl_sync;
    reg sda_meta, sda_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_meta <= 1'b1;
            scl_sync <= 1'b1;
            sda_meta <= 1'b1;
            sda_sync <= 1'b1;
        end
        else begin
            scl_meta <= scl_i;
            scl_sync <= scl_meta;

            sda_meta <= sda_i;
            sda_sync <= sda_meta;
        end
    end

    // ------------------------------------------------------------
    // Internal registers
    // ------------------------------------------------------------

    reg        run;
    reg [1:0]  phase;
    reg [2:0]  current_cmd;
    reg        current_din;

    assign running = run;
    assign ready   = ~run;

    // ------------------------------------------------------------
    // Clock stretching
    // ------------------------------------------------------------

    assign stall = run && !scl_oe && !scl_sync;

    // ------------------------------------------------------------
    // Line control
    //
    // oe = 1 -> pull line LOW
    // oe = 0 -> release line
    //
    // lines[1] = SCL OE
    // lines[0] = SDA OE
    // ------------------------------------------------------------

    function [1:0] lines;
        input [2:0] c;
        input [1:0] ph;
        input       d;

        begin
            case (c)

                // START
                `I2C_BCMD_START:
                    case (ph)
                        2'd0:    lines = 2'b10;
                        2'd1:    lines = 2'b00;
                        2'd2:    lines = 2'b01;
                        default: lines = 2'b11;
                    endcase

                // STOP
                `I2C_BCMD_STOP:
                    case (ph)
                        2'd0:    lines = 2'b11;
                        2'd1:    lines = 2'b01;
                        default: lines = 2'b00;
                    endcase

                // WRITE / ACK
                `I2C_BCMD_WRITE,
                `I2C_BCMD_ACK:
                    case (ph)
                        2'd0:    lines = {1'b1, ~d};
                        2'd3:    lines = {1'b1, ~d};
                        default: lines = {1'b0, ~d};
                    endcase

                // READ
                `I2C_BCMD_READ:
                    case (ph)
                        2'd0:    lines = 2'b10;
                        2'd3:    lines = 2'b10;
                        default: lines = 2'b00;
                    endcase

                default:
                    lines = 2'b00;

            endcase
        end
    endfunction

    // ------------------------------------------------------------
    // Generate SDA/SCL outputs
    // ------------------------------------------------------------

    always @(*) begin

        scl_oe = 1'b0;
        sda_oe = 1'b0;

        if (run) begin
            {scl_oe, sda_oe} =
                lines(current_cmd, phase, current_din);
        end

    end

    // ------------------------------------------------------------
    // Main command controller
    // ------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            run         <= 1'b0;
            phase       <= 2'd0;
            current_cmd <= `I2C_BCMD_NOP;
            current_din <= 1'b0;

            done        <= 1'b0;
            dout        <= 1'b0;
            arb_lost    <= 1'b0;
            bus_busy    <= 1'b0;

        end
        else begin

            // done is one clock pulse
            done <= 1'b0;

            // ----------------------------------------------------
            // Accept new command
            // ----------------------------------------------------

            if (!run) begin

                if (cmd_valid) begin

                    run         <= 1'b1;
                    phase       <= 2'd0;
                    current_cmd <= cmd;
                    current_din <= din;

                    arb_lost    <= 1'b0;

                end

            end

            // ----------------------------------------------------
            // Execute command
            // ----------------------------------------------------

            else begin

                if (tick && !stall) begin

                    // READ: sample SDA during high phase
                    if ((current_cmd == `I2C_BCMD_READ) &&
                        (phase == 2'd2)) begin

                        dout <= sda_sync;

                    end

                    // Arbitration detection
                    if ((current_cmd == `I2C_BCMD_WRITE) &&
                        (current_din == 1'b1) &&
                        (phase == 2'd2) &&
                        (sda_sync == 1'b0)) begin

                        arb_lost <= 1'b1;

                    end

                    // Last phase
                    if (phase == 2'd3) begin

                        run  <= 1'b0;
                        done <= 1'b1;

                        if (current_cmd == `I2C_BCMD_START)
                            bus_busy <= 1'b1;

                        if (current_cmd == `I2C_BCMD_STOP)
                            bus_busy <= 1'b0;

                    end
                    else begin

                        phase <= phase + 1'b1;

                    end

                end
            end
        end
    end

endmodule