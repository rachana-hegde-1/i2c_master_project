`timescale 1ns/1ps
`include "i2c_defs.vh"
// P4 unit testbench: contract host interface + behavioural stand-in for P3.
// Compile from tb/:  iverilog -I../include -o ../sim/p4 ../rtl/i2c_byte_ctrl.v tb_i2c_byte_ctrl.v
module tb_i2c_byte_ctrl;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;                       // 50 MHz

    // host side
    reg        start = 0; reg [6:0] slave_addr = 0; reg rw = 0; reg [7:0] write_data = 0;
    wire [7:0] read_data; wire busy, done, ack_error, arb_lost;
    // bit side
    wire       bit_vld, bit_din; wire [2:0] bit_cmd;
    reg        bit_ready = 1, bit_done = 0, bit_dout = 1, bit_al = 0;

    i2c_byte_ctrl dut(.clk(clk),.reset(reset),
        .start(start),.slave_addr(slave_addr),.rw(rw),.write_data(write_data),
        .read_data(read_data),.busy(busy),.done(done),.ack_error(ack_error),.arb_lost(arb_lost),
        .bit_vld(bit_vld),.bit_cmd(bit_cmd),.bit_din(bit_din),
        .bit_ready(bit_ready),.bit_done(bit_done),.bit_dout(bit_dout),.bit_al(bit_al));

    // ---------------- P3 stand-in ----------------
    reg        addr_nack = 0, data_nack = 0;     // what the "slave" does
    reg        m_rw = 0; reg [7:0] rd_byte = 0;
    reg        al_after3 = 0;                    // inject arbitration loss on 3rd addr bit
    integer    n_log, n_rd, m_cnt; reg m_busy = 0; reg [2:0] m_cmd;
    reg [2:0]  log_cmd [0:63]; reg log_din [0:63];

    task txn_reset; begin n_log = 0; n_rd = 0; end endtask
    initial txn_reset;

    always @(posedge clk) begin
        bit_done <= 1'b0;
        if (reset) begin m_busy <= 0; bit_ready <= 1; bit_al <= 0; end
        else if (bit_vld) begin
            log_cmd[n_log] = bit_cmd; log_din[n_log] = bit_din; n_log = n_log + 1;
            m_busy <= 1; bit_ready <= 0; m_cmd <= bit_cmd; m_cnt <= 3;
            bit_al <= 0;                                  // P3 clears AL on a new command
        end else if (m_busy) begin
            if (m_cnt == 0) begin
                m_busy <= 0; bit_ready <= 1; bit_done <= 1;
                if (m_cmd == `I2C_BCMD_READ) begin
                    if (n_rd == 0)             bit_dout <= addr_nack;           // address ACK slot
                    else if (!m_rw)            bit_dout <= data_nack;           // write-data ACK slot
                    else                       bit_dout <= rd_byte[8-n_rd];     // read bits 1..8
                    n_rd = n_rd + 1;
                end
                if (al_after3 && m_cmd == `I2C_BCMD_WRITE && n_log == 4) bit_al <= 1;
            end else m_cnt <= m_cnt - 1;
        end
    end

    // ---------------- protocol monitors ----------------
    integer done_cnt = 0, errors = 0, busy_drop_bad = 0; reg done_q = 0;
    always @(posedge clk) begin
        done_q <= done;
        if (done) begin done_cnt = done_cnt + 1; if (busy) busy_drop_bad = busy_drop_bad + 1; end
        if (done && done_q) begin errors = errors + 1; $display("FAIL done wider than 1 clock"); end
    end

    task check(input [255:0] name, input [31:0] got, input [31:0] exp); begin
        if (got !== exp) begin errors = errors + 1; $display("FAIL %0s: got %h exp %h", name, got, exp); end
        else $display("PASS %0s", name);
    end endtask

    // compare logged bit commands against what the contract says must happen
    // kind: 0=write ok/data NACK (20 cmds), 1=read (20 cmds), 2=addr NACK (11 cmds)
    task check_seq(input [255:0] tag, input integer kind, input [6:0] a, input [7:0] d);
        integer i; reg [7:0] ab; reg bad; begin
        bad = 0; ab = {a, (kind == 1)};
        if (log_cmd[0] !== `I2C_BCMD_START) bad = 1;
        for (i = 0; i < 8; i = i + 1)
            if (log_cmd[1+i] !== `I2C_BCMD_WRITE || log_din[1+i] !== ab[7-i]) bad = 1;
        if (log_cmd[9] !== `I2C_BCMD_READ) bad = 1;
        if (kind == 0) begin
            for (i = 0; i < 8; i = i + 1)
                if (log_cmd[10+i] !== `I2C_BCMD_WRITE || log_din[10+i] !== d[7-i]) bad = 1;
            if (log_cmd[18] !== `I2C_BCMD_READ) bad = 1;
            if (log_cmd[19] !== `I2C_BCMD_STOP) bad = 1;
            if (n_log != 20) bad = 1;
        end else if (kind == 1) begin
            for (i = 0; i < 8; i = i + 1) if (log_cmd[10+i] !== `I2C_BCMD_READ) bad = 1;
            if (log_cmd[18] !== `I2C_BCMD_ACK || log_din[18] !== 1'b1) bad = 1;   // master NACK
            if (log_cmd[19] !== `I2C_BCMD_STOP) bad = 1;
            if (n_log != 20) bad = 1;
        end else begin
            if (log_cmd[10] !== `I2C_BCMD_STOP) bad = 1;
            if (n_log != 11) bad = 1;
        end
        if (bad) begin errors = errors + 1; $display("FAIL %0s bit sequence (n_log=%0d)", tag, n_log); end
        else $display("PASS %0s bit sequence", tag);
    end endtask

    // run one transaction through the host interface, like P6's driver does
    reg busy_seen;
    task run(input [6:0] a, input r, input [7:0] d); integer t; begin
        txn_reset; m_rw = r; busy_seen = 0; done_cnt = 0; busy_drop_bad = 0;
        @(posedge clk); #1 slave_addr = a; rw = r; write_data = d; start = 1;
        @(posedge clk); #1 start = 0;
        t = 0;
        while (done_cnt == 0 && t < 2000) begin
            @(posedge clk); #1; t = t + 1; if (busy) busy_seen = 1;
        end
        if (t >= 2000) begin errors = errors + 1; $display("FAIL timeout"); end
        repeat (4) @(posedge clk); #1;
    end endtask

    initial begin
        $dumpfile("../waves/tb_i2c_byte_ctrl.vcd"); $dumpvars(0, tb_i2c_byte_ctrl);
        repeat (3) @(posedge clk); #1 reset = 0;

        // reset values
        check("reset: busy",      busy, 0);  check("reset: done", done, 0);
        check("reset: ack_error", ack_error, 0); check("reset: read_data", read_data, 8'h00);

        // T1: write, slave ACKs
        addr_nack = 0; data_nack = 0;
        run(7'h50, 0, 8'hA5);
        check_seq("T1 write", 0, 7'h50, 8'hA5);
        check("T1 ack_error", ack_error, 0);  check("T1 busy seen", busy_seen, 1);
        check("T1 one done pulse", done_cnt, 1); check("T1 busy low at done", busy_drop_bad, 0);
        check("T1 idle afterwards", busy, 0);

        // T2: another write value / address
        run(7'h2A, 0, 8'h3C);
        check_seq("T2 write", 0, 7'h2A, 8'h3C);
        check("T2 ack_error", ack_error, 0);

        // T3: write, address NACK -> ack_error, STOP, no data sent
        addr_nack = 1;
        run(7'h51, 0, 8'hFF);
        check_seq("T3 addr NACK", 2, 7'h51, 8'hFF);
        check("T3 ack_error", ack_error, 1); check("T3 one done", done_cnt, 1);
        check("T3 idle afterwards", busy, 0);

        // T4: ack_error clears on a new accepted transaction
        addr_nack = 0; data_nack = 0;
        run(7'h50, 0, 8'h11);
        check("T4 ack_error cleared", ack_error, 0);

        // T5: write, data NACK -> ack_error after full byte
        data_nack = 1;
        run(7'h50, 0, 8'h22);
        check_seq("T5 data NACK", 0, 7'h50, 8'h22);
        check("T5 ack_error", ack_error, 1);
        data_nack = 0;

        // T6: read, master NACKs at end, read_data captured
        rd_byte = 8'h96;
        run(7'h50, 1, 8'h00);
        check_seq("T6 read", 1, 7'h50, 8'h00);
        check("T6 read_data", read_data, 8'h96); check("T6 ack_error", ack_error, 0);

        // T7: different read value; read_data holds across a write
        rd_byte = 8'h3C; run(7'h50, 1, 8'h00);
        check("T7 read_data", read_data, 8'h3C);
        run(7'h50, 0, 8'h77);
        check("T7 read_data held after write", read_data, 8'h3C);

        // T8: start while busy is ignored
        txn_reset; m_rw = 0;
        @(posedge clk); #1 slave_addr = 7'h50; rw = 0; write_data = 8'hC3; start = 1;
        @(posedge clk); #1 start = 0;
        repeat (40) @(posedge clk);
        #1 slave_addr = 7'h11; rw = 1; write_data = 8'h00; start = 1;
        @(posedge clk); #1 start = 0;
        while (!done) @(posedge clk);
        repeat (4) @(posedge clk); #1;
        check_seq("T8 busy start ignored", 0, 7'h50, 8'hC3);

        // T9: P3 not ready delays but does not break the sequence
        bit_ready = 0; txn_reset; m_rw = 0;
        @(posedge clk); #1 slave_addr = 7'h50; rw = 0; write_data = 8'h5A; start = 1;
        @(posedge clk); #1 start = 0;
        repeat (20) @(posedge clk);
        check("T9 nothing issued while not ready", n_log, 0);
        bit_ready = 1;
        while (!done) @(posedge clk);
        repeat (4) @(posedge clk); #1;
        check_seq("T9 write after ready", 0, 7'h50, 8'h5A);

        // T10: arbitration lost during address -> safe abort, then recover
        al_after3 = 1;
        run(7'h50, 0, 8'h99);
        check("T10 aborted: ack_error", ack_error, 1);
        check("T10 aborted: idle", busy, 0);
        check("T10 aborted: no STOP issued", log_cmd[n_log-1] != `I2C_BCMD_STOP, 1);
        al_after3 = 0;
        run(7'h50, 0, 8'h42);
        check_seq("T10 recovered", 0, 7'h50, 8'h42);
        check("T10 ack_error cleared", ack_error, 0);

        // T11: reset in the middle of a transaction
        txn_reset;
        @(posedge clk); #1 slave_addr = 7'h50; rw = 0; write_data = 8'hFF; start = 1;
        @(posedge clk); #1 start = 0;
        repeat (30) @(posedge clk);
        #1 reset = 1; @(posedge clk); #1 reset = 0; @(posedge clk); #1;
        check("T11 busy cleared by reset", busy, 0);
        check("T11 read_data reset", read_data, 8'h00);
        repeat (20) @(posedge clk);
        run(7'h50, 0, 8'h18);
        check_seq("T11 works after reset", 0, 7'h50, 8'h18);

        if (errors == 0) $display("ALL TESTS PASSED"); else $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
