// ============================================================================
// i2c_byte_ctrl.v  --  P4: Byte command controller
// ----------------------------------------------------------------------------
// Sequences a whole I2C byte on top of P3's single-bit commands.
//
// Host side (from P5 register file) -- 1-cycle command pulses, may be combined:
//   cmd_start | cmd_write           -> START, then 8 data bits, then read ACK
//   cmd_read  [| cmd_nack][|stop]   -> 8 bits in, then drive ACK/NACK
//   cmd_stop                        -> STOP (alone, or after a write/read)
//   A START while the bus is already held acts as a repeated START.
//   Order of execution is always: START -> WRITE|READ -> STOP.
//
// Bit side (to P3 bit controller):
//   bit_vld  1-cycle pulse: "here is a new bit command"
//   bit_cmd  BC_START / BC_STOP / BC_WRITE / BC_READ
//   bit_din  bit value to drive for BC_WRITE (ACK bit: 0 = ACK, 1 = NACK)
//   bit_done (from P3) 1-cycle pulse when the bit command has finished
//   bit_dout (from P3) bit sampled on SDA, valid with bit_done (after BC_READ)
//   bit_al   (from P3) arbitration lost -> P4 aborts to IDLE
//   P3 must raise bit_done at least 1 cycle after bit_vld.
// ============================================================================
module i2c_byte_ctrl (
    input  wire       clk,
    input  wire       rst_n,

    // ---- host side (P5) ----
    input  wire       cmd_start,
    input  wire       cmd_stop,
    input  wire       cmd_read,
    input  wire       cmd_write,
    input  wire       cmd_nack,     // ACK bit to send after a read (1 = NACK)
    input  wire [7:0] tx_data,
    output reg        done,         // 1-cycle pulse, command finished
    output reg        ack_in,       // slave ACK/NACK after write (1 = NACK)
    output wire [7:0] rx_data,      // byte read from the bus
    output reg        arb_lost,     // 1-cycle pulse
    output reg        bus_busy,     // START issued, STOP not yet issued

    // ---- bit side (P3) ----
    output reg        bit_vld,
    output reg  [2:0] bit_cmd,
    output reg        bit_din,
    input  wire       bit_done,
    input  wire       bit_dout,
    input  wire       bit_al
);

    // bit command encoding (share this with P3)
    localparam [2:0] BC_NOP   = 3'd0,
                     BC_START = 3'd1,
                     BC_STOP  = 3'd2,
                     BC_WRITE = 3'd3,
                     BC_READ  = 3'd4;

    localparam [2:0] S_IDLE  = 3'd0,
                     S_START = 3'd1,
                     S_WRITE = 3'd2,
                     S_WACK  = 3'd3,   // read slave's ACK after a write
                     S_READ  = 3'd4,
                     S_RACK  = 3'd5,   // drive our ACK/NACK after a read
                     S_STOP  = 3'd6;

    reg [2:0] state;
    reg       issued;           // bit command already sent, waiting for bit_done
    reg [2:0] cnt;              // bit counter, 7 downto 0
    reg [7:0] tx_sr, rx_sr;
    reg       f_start, f_stop, f_read, f_write, f_nack;

    assign rx_data = rx_sr;

    wire any_cmd = cmd_start | cmd_stop | cmd_read | cmd_write;

    // Helper: send one bit command (call only when !issued)
    task launch(input [2:0] c, input d);
        begin bit_vld <= 1'b1; bit_cmd <= c; bit_din <= d; issued <= 1'b1; end
    endtask

    // Helper: finish the whole command
    task finish;
        begin done <= 1'b1; state <= S_IDLE; issued <= 1'b0; end
    endtask

    // Helper: go to the step after the current one
    task goto_stop_or_finish;
        begin
            issued <= 1'b0;
            if (f_stop) state <= S_STOP; else finish;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; issued <= 1'b0; cnt <= 3'd7;
            tx_sr <= 8'h00; rx_sr <= 8'h00;
            f_start <= 1'b0; f_stop <= 1'b0; f_read <= 1'b0;
            f_write <= 1'b0; f_nack <= 1'b0;
            done <= 1'b0; ack_in <= 1'b0; arb_lost <= 1'b0; bus_busy <= 1'b0;
            bit_vld <= 1'b0; bit_cmd <= BC_NOP; bit_din <= 1'b1;
        end else begin
            // pulse defaults
            done <= 1'b0; arb_lost <= 1'b0; bit_vld <= 1'b0;

            if (bit_al) begin
                // lost arbitration: abandon command, release everything
                state <= S_IDLE; issued <= 1'b0;
                arb_lost <= 1'b1; bus_busy <= 1'b0;
            end else begin
                case (state)
                // ------------------------------------------------------
                S_IDLE: begin
                    if (any_cmd) begin
                        f_start <= cmd_start; f_stop  <= cmd_stop;
                        f_read  <= cmd_read;  f_write <= cmd_write;
                        f_nack  <= cmd_nack;
                        tx_sr   <= tx_data;
                        cnt     <= 3'd7;
                        issued  <= 1'b0;
                        if      (cmd_start) state <= S_START;
                        else if (cmd_write) state <= S_WRITE;
                        else if (cmd_read)  state <= S_READ;
                        else                state <= S_STOP;
                    end
                end
                // ------------------------------------------------------
                S_START: begin
                    if (!issued) launch(BC_START, 1'b1);
                    else if (bit_done) begin
                        bus_busy <= 1'b1; issued <= 1'b0;
                        if      (f_write) state <= S_WRITE;
                        else if (f_read)  state <= S_READ;
                        else if (f_stop)  state <= S_STOP;
                        else              finish;
                    end
                end
                // ------------------------------------------------------
                S_WRITE: begin
                    if (!issued) launch(BC_WRITE, tx_sr[7]);
                    else if (bit_done) begin
                        issued <= 1'b0;
                        tx_sr  <= {tx_sr[6:0], 1'b0};
                        if (cnt == 3'd0) begin state <= S_WACK; cnt <= 3'd7; end
                        else cnt <= cnt - 3'd1;
                    end
                end
                // ------------------------------------------------------
                S_WACK: begin
                    if (!issued) launch(BC_READ, 1'b1);   // release SDA, sample ACK
                    else if (bit_done) begin
                        ack_in <= bit_dout;               // 0 = ACK, 1 = NACK
                        goto_stop_or_finish;
                    end
                end
                // ------------------------------------------------------
                S_READ: begin
                    if (!issued) launch(BC_READ, 1'b1);
                    else if (bit_done) begin
                        issued <= 1'b0;
                        rx_sr  <= {rx_sr[6:0], bit_dout}; // MSB first
                        if (cnt == 3'd0) begin state <= S_RACK; cnt <= 3'd7; end
                        else cnt <= cnt - 3'd1;
                    end
                end
                // ------------------------------------------------------
                S_RACK: begin
                    if (!issued) launch(BC_WRITE, f_nack);
                    else if (bit_done) goto_stop_or_finish;
                end
                // ------------------------------------------------------
                S_STOP: begin
                    if (!issued) launch(BC_STOP, 1'b1);
                    else if (bit_done) begin
                        bus_busy <= 1'b0; finish;
                    end
                end
                default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
