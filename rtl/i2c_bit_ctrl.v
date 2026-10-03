`timescale 1ns/1ps

`include "i2c_defs.vh"

module i2c_bit_ctrl (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick,

    // Command interface from P4
    input  wire       bit_vld,
    input  wire [2:0] bit_cmd,
    input  wire       bit_din,

    // Status/data back to P4
    output wire       ready,
    output reg        bit_done,
    output reg        bit_dout,
    output reg        bit_al,

    // Bus status
    output reg        bus_busy,

    // Clock stretching
    output wire       stall,
    output wire       running,

    // I2C bus inputs
    input  wire       scl_i,
    input  wire       sda_i,

    // Open-drain outputs
    output reg        scl_oe,
    output reg        sda_oe
);

    // ------------------------------------------------------------
    // Synchronize SCL and SDA
    // ------------------------------------------------------------

    reg scl_meta;
    reg scl_sync;

    reg sda_meta;
    reg sda_sync;

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
    // Internal state
    // ------------------------------------------------------------

    reg        run;
    reg [2:0]  current_cmd;
    reg        current_din;

    reg [1:0]  phase;

    localparam PH0 = 2'd0;
    localparam PH1 = 2'd1;
    localparam PH2 = 2'd2;
    localparam PH3 = 2'd3;


    assign running = run;
    assign ready   = ~run;


    // ------------------------------------------------------------
    // Clock stretching
    // ------------------------------------------------------------
    // If we release SCL but the external bus keeps it LOW,
    // wait until SCL actually becomes HIGH.

    assign stall = run && !scl_oe && !scl_sync;


    // ------------------------------------------------------------
    // Generate SCL/SDA control
    // ------------------------------------------------------------

    always @(*) begin

        // Default: drive both lines LOW
        scl_oe = 1'b1;
        sda_oe = 1'b1;

        case (current_cmd)

            // ----------------------------------------------------
            // START
            // ----------------------------------------------------
            `I2C_BCMD_START: begin

                case (phase)

                    PH0: begin
                        // SCL LOW, SDA LOW
                        scl_oe = 1'b1;
                        sda_oe = 1'b1;
                    end

                    PH1: begin
                        // Release both
                        scl_oe = 1'b0;
                        sda_oe = 1'b0;
                    end

                    PH2: begin
                        // SCL HIGH, SDA LOW
                        scl_oe = 1'b0;
                        sda_oe = 1'b1;
                    end

                    default: begin
                        // SCL LOW, SDA LOW
                        scl_oe = 1'b1;
                        sda_oe = 1'b1;
                    end

                endcase

            end


            // ----------------------------------------------------
            // STOP
            // ----------------------------------------------------
            `I2C_BCMD_STOP: begin

                case (phase)

                    PH0: begin
                        // SCL LOW, SDA LOW
                        scl_oe = 1'b1;
                        sda_oe = 1'b1;
                    end

                    PH1: begin
                        // SCL HIGH, SDA LOW
                        scl_oe = 1'b0;
                        sda_oe = 1'b1;
                    end

                    default: begin
                        // Release both -> STOP condition
                        scl_oe = 1'b0;
                        sda_oe = 1'b0;
                    end

                endcase

            end


            // ----------------------------------------------------
            // WRITE BIT
            // ----------------------------------------------------
            `I2C_BCMD_WRITE: begin

                case (phase)

                    PH0: begin
                        // SCL LOW
                        scl_oe = 1'b1;

                        // Drive 0, release for 1
                        sda_oe = ~current_din;
                    end

                    PH1: begin
                        // SCL HIGH
                        scl_oe = 1'b0;
                        sda_oe = ~current_din;
                    end

                    PH2: begin
                        // SCL HIGH
                        scl_oe = 1'b0;
                        sda_oe = ~current_din;
                    end

                    default: begin
                        // SCL LOW
                        scl_oe = 1'b1;
                        sda_oe = ~current_din;
                    end

                endcase

            end


            // ----------------------------------------------------
            // READ BIT
            // ----------------------------------------------------
            `I2C_BCMD_READ: begin

                // Release SDA so slave can drive it

                case (phase)

                    PH0: begin
                        scl_oe = 1'b1;
                        sda_oe = 1'b0;
                    end

                    PH1: begin
                        scl_oe = 1'b0;
                        sda_oe = 1'b0;
                    end

                    PH2: begin
                        scl_oe = 1'b0;
                        sda_oe = 1'b0;
                    end

                    default: begin
                        scl_oe = 1'b1;
                        sda_oe = 1'b0;
                    end

                endcase

            end


            // ----------------------------------------------------
            // ACK
            // ----------------------------------------------------
            `I2C_BCMD_ACK: begin

                case (phase)

                    PH0: begin
                        scl_oe = 1'b1;

                        // bit_din = 0 -> ACK
                        // bit_din = 1 -> NACK
                        sda_oe = ~current_din;
                    end

                    PH1: begin
                        scl_oe = 1'b0;
                        sda_oe = ~current_din;
                    end

                    PH2: begin
                        scl_oe = 1'b0;
                        sda_oe = ~current_din;
                    end

                    default: begin
                        scl_oe = 1'b1;
                        sda_oe = ~current_din;
                    end

                endcase

            end


            default: begin
                scl_oe = 1'b1;
                sda_oe = 1'b1;
            end

        endcase

    end


    // ------------------------------------------------------------
    // Command execution FSM
    // ------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            run         <= 1'b0;

            current_cmd <= `I2C_BCMD_NOP;
            current_din <= 1'b0;

            phase       <= PH0;

            bit_done    <= 1'b0;
            bit_dout    <= 1'b1;
            bit_al      <= 1'b0;

            bus_busy    <= 1'b0;

        end
        else begin

            // done is a one-clock pulse
            bit_done <= 1'b0;

            // ----------------------------------------------------
            // Start a new command
            // ----------------------------------------------------

            if (!run) begin

                if (bit_vld) begin

                    current_cmd <= bit_cmd;
                    current_din <= bit_din;

                    phase <= PH0;
                    run   <= 1'b1;

                    bit_al <= 1'b0;

                    // Bus becomes busy after START
                    if (bit_cmd == `I2C_BCMD_START)
                        bus_busy <= 1'b1;

                end

            end


            // ----------------------------------------------------
            // Command currently running
            // ----------------------------------------------------

            else begin

                // Wait for P2 timing tick
                if (tick && !stall) begin

                    // ------------------------------------------------
                    // READ: sample SDA while SCL is HIGH
                    // ------------------------------------------------

                    if ((current_cmd == `I2C_BCMD_READ) &&
                        (phase == PH2)) begin

                        bit_dout <= sda_sync;

                    end


                    // ------------------------------------------------
                    // Arbitration check during WRITE of '1'
                    // ------------------------------------------------

                    if ((current_cmd == `I2C_BCMD_WRITE) &&
                        (phase == PH2) &&
                        (current_din == 1'b1) &&
                        (sda_sync == 1'b0)) begin

                        bit_al <= 1'b1;

                    end


                    // ------------------------------------------------
                    // Move to next phase
                    // ------------------------------------------------

                    if (phase == PH3) begin

                        phase <= PH0;
                        run   <= 1'b0;

                        bit_done <= 1'b1;

                        // STOP releases bus
                        if (current_cmd == `I2C_BCMD_STOP)
                            bus_busy <= 1'b0;
                            current_cmd <= `I2C_BCMD_NOP;

                    end
                    else begin

                        phase <= phase + 1'b1;

                    end

                end

            end

        end

    end

endmodule