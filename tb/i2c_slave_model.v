// i2c_slave_model.v
// Behavioral I2C slave model — baseline (no clock stretching, single-byte only)
`timescale 1ns/1ps

module i2c_slave_model #(
    parameter [6:0] SLAVE_ADDR = 7'h50
)(
    inout wire scl,
    inout wire sda
);

    localparam ST_IDLE      = 3'd0,
               ST_ADDR      = 3'd1,
               ST_ADDR_ACK  = 3'd2,
               ST_WDATA     = 3'd3,
               ST_WACK      = 3'd4,
               ST_RDATA     = 3'd5,
               ST_RACK      = 3'd6;

    reg [2:0] state;
    reg [7:0] shift_in;
    reg [7:0] tx_data;      // byte driven back during a read
    reg [3:0] bit_cnt;
    reg       rw_bit;
    reg       addr_match;
    reg       force_nack;   // testbench control for negative-ACK tests

    reg sda_drive_low;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;
    wire sda_in = sda;
    wire scl_in = scl;

    reg sda_prev, scl_prev;

    // ---- Testbench control tasks ----
    task set_nack; begin force_nack = 1'b1; end endtask
    task set_ack;  begin force_nack = 1'b0; end endtask
    task set_read_data(input [7:0] d); begin tx_data = d; end endtask

    initial begin
        state         = ST_IDLE;
        sda_drive_low = 1'b0;
        bit_cnt       = 4'd0;
        force_nack    = 1'b0;
        tx_data       = 8'hA5;
        sda_prev      = 1'b1;
        scl_prev      = 1'b1;
    end

    // ---- START / STOP detection (level-sensitive) ----
    always @(sda_in or scl_in) begin
        if (scl_in && scl_prev && sda_prev && !sda_in) begin
            // START: SDA falls while SCL stays high
            state   <= ST_ADDR;
            bit_cnt <= 4'd0;
            sda_drive_low <= 1'b0;
        end
        else if (scl_in && scl_prev && !sda_prev && sda_in) begin
            // STOP: SDA rises while SCL stays high
            state <= ST_IDLE;
            sda_drive_low <= 1'b0;
        end
        sda_prev <= sda_in;
        scl_prev <= scl_in;
    end

    // ---- Shift-in on SCL rising edge (address + write-data phases) ----
    always @(posedge scl) begin
        if (state == ST_ADDR) begin
            shift_in <= {shift_in[6:0], sda_in};
            bit_cnt  <= bit_cnt + 1'b1;
        end
        else if (state == ST_WDATA) begin
            shift_in <= {shift_in[6:0], sda_in};
            bit_cnt  <= bit_cnt + 1'b1;
        end
        else if (state == ST_RACK) begin
            // sample master's ACK/NACK after the read byte
            // sda_in = 0 -> ACK, sda_in = 1 -> NACK (expected for single-byte read)
            state <= ST_IDLE; // wait for STOP (level-sensitive block handles it)
        end
    end

    // ---- Drive ACK / next-phase data on SCL falling edge ----
    always @(negedge scl) begin
        case (state)
            ST_ADDR: begin
                if (bit_cnt == 4'd8) begin
                    addr_match    <= (shift_in[7:1] == SLAVE_ADDR);
                    rw_bit        <= shift_in[0];
                    sda_drive_low <= ((shift_in[7:1] == SLAVE_ADDR) && !force_nack);
                    state         <= ST_ADDR_ACK;
                end
            end

            ST_ADDR_ACK: begin
                sda_drive_low <= 1'b0; // release ACK bit
                bit_cnt       <= 4'd0;
                if (addr_match && !force_nack) begin
                    if (rw_bit == 1'b0) begin
                        state <= ST_WDATA;
                    end else begin
                        state    <= ST_RDATA;
                        shift_in <= tx_data; // load for shifting out
                    end
                end else begin
                    state <= ST_IDLE; // NACKed, wait for STOP
                end
            end

            ST_WDATA: begin
                if (bit_cnt == 4'd8) begin
                    sda_drive_low <= !force_nack; // ACK the data byte
                    state         <= ST_WACK;
                end
            end

            ST_WACK: begin
                sda_drive_low <= 1'b0; // release
                state         <= ST_IDLE; // wait for STOP
            end

            ST_RDATA: begin
                if (bit_cnt < 4'd8) begin
                    sda_drive_low <= ~shift_in[7]; // drive MSB first (0=>low, 1=>release)
                    shift_in      <= {shift_in[6:0], 1'b0};
                    bit_cnt       <= bit_cnt + 1'b1;
                end
                if (bit_cnt == 4'd8) begin
                    sda_drive_low <= 1'b0; // release for master's ACK/NACK
                    state         <= ST_RACK;
                end
            end

            default: ; // ST_IDLE, ST_RACK: nothing to drive
        endcase
    end

endmodule
