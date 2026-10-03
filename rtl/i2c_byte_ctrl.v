// ============================================================================
// i2c_byte_ctrl.v  --  P4: Byte command controller / transaction sequencer
// ----------------------------------------------------------------------------
// Host side follows docs/interface_contract.md (top-level handshake):
//   start        request a transaction (accepted only while busy = 0)
//   slave_addr   7-bit target address
//   rw           0 = write, 1 = read
//   write_data   byte sent during a write
//   read_data    byte received during a read (held until the next read)
//   busy         1 for the whole transaction, 0 when idle
//   done         1-clock pulse after STOP has completed
//   ack_error    1 = NACK seen where an ACK was expected; cleared when a new
//                transaction is accepted
//   reset        active-high, synchronous
//
// Baseline transactions (single byte, no repeated START):
//   write: START, {addr,0}, ACK, write_data, ACK, STOP, done
//   read : START, {addr,1}, ACK, 8 bits in, master NACK, STOP, done
//   NACK on address or write data: ack_error = 1, STOP is still sent, done.
//
// Bit side (P3, i2c_bit_ctrl) -- command codes come from include/i2c_defs.vh:
//   bit_vld    1-cycle pulse: new bit command (only issued while bit_ready=1)
//   bit_cmd    I2C_BCMD_START / STOP / WRITE / READ / ACK
//   bit_din    value to drive for WRITE (ACK cmd: 0 = ACK, 1 = NACK)
//   bit_ready  P3 is idle and can take a command
//   bit_done   P3 finished the command (1-cycle pulse)
//   bit_dout   SDA sampled by a READ, valid with bit_done
//   bit_al     P3 lost arbitration (level, checked when bit_done pulses)
// Multi-master is outside the baseline; if P3 ever reports bit_al the
// transaction is aborted safely (see S_* handling below).
// ============================================================================
`include "i2c_defs.vh"

module i2c_byte_ctrl (
    input  wire       clk,
    input  wire       reset,          // active-high, synchronous

    // ---- host side (system contract) ----
    input  wire       start,
    input  wire [6:0] slave_addr,
    input  wire       rw,
    input  wire [7:0] write_data,
    output reg  [7:0] read_data,
    output reg        busy,
    output reg        done,
    output reg        ack_error,

    // ---- extra status (not part of the top-level contract; top may ignore) ----
    output reg        arb_lost,       // 1-cycle pulse when a transaction is aborted

    // ---- bit side (P3) ----
    output reg        bit_vld,
    output reg  [2:0] bit_cmd,
    output reg        bit_din,
    input  wire       bit_ready,
    input  wire       bit_done,
    input  wire       bit_dout,
    input  wire       bit_al
);

    localparam [3:0] S_IDLE  = 4'd0,
                     S_START = 4'd1,
                     S_ADDR  = 4'd2,   // 8 bits: {slave_addr, rw}
                     S_AACK  = 4'd3,   // slave ACK after address
                     S_WDATA = 4'd4,   // 8 write-data bits
                     S_DACK  = 4'd5,   // slave ACK after write data
                     S_RDATA = 4'd6,   // 8 read-data bits
                     S_MNACK = 4'd7,   // master NACK after read byte
                     S_STOP  = 4'd8;

    reg [3:0] state;
    reg       issued;          // bit command sent, waiting for bit_done
    reg [2:0] cnt;             // bit counter, 7 downto 0
    reg [7:0] tx_sr;           // shift register for address / write data
    reg [7:0] rx_sr;           // shift register for read data
    reg       rw_q;
    reg [7:0] wdata_q;

    // Send one bit command (only when P3 is ready)
    task launch(input [2:0] c, input d);
        begin
            if (bit_ready) begin
                bit_vld <= 1'b1; bit_cmd <= c; bit_din <= d; issued <= 1'b1;
            end
        end
    endtask

    // Terminate the transaction
    task finish;
        begin
            done  <= 1'b1; busy <= 1'b0;
            state <= S_IDLE; issued <= 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            issued    <= 1'b0;
            cnt       <= 3'd7;
            tx_sr     <= 8'h00;
            rx_sr     <= 8'h00;
            rw_q      <= 1'b0;
            wdata_q   <= 8'h00;
            read_data <= 8'h00;
            busy      <= 1'b0;
            done      <= 1'b0;
            ack_error <= 1'b0;
            arb_lost  <= 1'b0;
            bit_vld   <= 1'b0;
            bit_cmd   <= `I2C_BCMD_NOP;
            bit_din   <= 1'b1;
        end else begin
            // pulse defaults
            done <= 1'b0; arb_lost <= 1'b0; bit_vld <= 1'b0;

            if (state != S_IDLE && issued && bit_done && bit_al) begin
                // Arbitration lost: abort, no further bus activity.
                // ack_error is raised so a failed transaction can never look
                // like a successful one.
                arb_lost  <= 1'b1;
                ack_error <= 1'b1;
                finish;
            end else begin
                case (state)
                // --------------------------------------------------------
                S_IDLE: begin
                    if (start && !busy) begin
                        rw_q      <= rw;
                        wdata_q   <= write_data;
                        tx_sr     <= {slave_addr, rw};
                        cnt       <= 3'd7;
                        issued    <= 1'b0;
                        busy      <= 1'b1;
                        ack_error <= 1'b0;     // cleared on acceptance
                        state     <= S_START;
                    end
                end
                // --------------------------------------------------------
                S_START: begin
                    if (!issued) launch(`I2C_BCMD_START, 1'b1);
                    else if (bit_done) begin
                        issued <= 1'b0; state <= S_ADDR;
                    end
                end
                // --------------------------------------------------------
                S_ADDR: begin
                    if (!issued) launch(`I2C_BCMD_WRITE, tx_sr[7]);
                    else if (bit_done) begin
                        issued <= 1'b0;
                        tx_sr  <= {tx_sr[6:0], 1'b0};
                        if (cnt == 3'd0) begin state <= S_AACK; cnt <= 3'd7; end
                        else cnt <= cnt - 3'd1;
                    end
                end
                // --------------------------------------------------------
                S_AACK: begin
                    if (!issued) launch(`I2C_BCMD_READ, 1'b1);  // release SDA
                    else if (bit_done) begin
                        issued <= 1'b0;
                        if (bit_dout) begin                      // NACK
                            ack_error <= 1'b1; state <= S_STOP;
                        end else if (rw_q) begin
                            state <= S_RDATA;
                        end else begin
                            tx_sr <= wdata_q; state <= S_WDATA;
                        end
                    end
                end
                // --------------------------------------------------------
                S_WDATA: begin
                    if (!issued) launch(`I2C_BCMD_WRITE, tx_sr[7]);
                    else if (bit_done) begin
                        issued <= 1'b0;
                        tx_sr  <= {tx_sr[6:0], 1'b0};
                        if (cnt == 3'd0) begin state <= S_DACK; cnt <= 3'd7; end
                        else cnt <= cnt - 3'd1;
                    end
                end
                // --------------------------------------------------------
                S_DACK: begin
                    if (!issued) launch(`I2C_BCMD_READ, 1'b1);
                    else if (bit_done) begin
                        issued <= 1'b0;
                        if (bit_dout) ack_error <= 1'b1;         // NACK
                        state <= S_STOP;
                    end
                end
                // --------------------------------------------------------
                S_RDATA: begin
                    if (!issued) launch(`I2C_BCMD_READ, 1'b1);
                    else if (bit_done) begin
                        issued <= 1'b0;
                        rx_sr  <= {rx_sr[6:0], bit_dout};        // MSB first
                        if (cnt == 3'd0) begin
                            state     <= S_MNACK;
                            read_data <= {rx_sr[6:0], bit_dout};
                        end else cnt <= cnt - 3'd1;
                    end
                end
                // --------------------------------------------------------
                S_MNACK: begin                                   // single byte: NACK
                    if (!issued) launch(`I2C_BCMD_ACK, 1'b1);
                    else if (bit_done) begin
                        issued <= 1'b0; state <= S_STOP;
                    end
                end
                // --------------------------------------------------------
                S_STOP: begin
                    if (!issued) launch(`I2C_BCMD_STOP, 1'b1);
                    else if (bit_done) finish;
                end
                default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
