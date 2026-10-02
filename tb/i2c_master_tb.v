// i2c_master_tb.v
// Top-level testbench: clock/reset gen, bus wiring, DUT + slave instantiation,
// driver tasks, passive monitor, scoreboard.
`timescale 1ns/1ps

module i2c_master_tb;

    // ---- Clock / reset ----
    reg clk = 0;
    reg reset = 1;
    always #10 clk = ~clk; // 50 MHz -> 20 ns period -> 10 ns half period

    // ---- DUT I/O ----
    reg        start;
    reg  [6:0] slave_addr;
    reg        rw;
    reg  [7:0] write_data;
    wire [7:0] read_data;
    wire       busy, done, ack_error;
    wire       scl, sda;

    pullup(scl);
    pullup(sda);

    // ---- DUT instantiation (frozen port list) ----
    i2c_master dut (
        .clk        (clk),
        .reset      (reset),
        .start      (start),
        .slave_addr (slave_addr),
        .rw         (rw),
        .write_data (write_data),
        .read_data  (read_data),
        .busy       (busy),
        .done       (done),
        .ack_error  (ack_error),
        .scl        (scl),
        .sda        (sda)
    );

    // ---- Behavioral slave ----
    i2c_slave_model slave (
        .scl (scl),
        .sda (sda)
    );

    // ---- Scoreboard tracking ----
    reg [7:0] expected_wdata;
    reg [6:0] expected_addr;
    reg       expected_nack;
    integer   pass_count = 0;
    integer   fail_count = 0;

    // ---- Driver tasks ----
    task i2c_write(input [6:0] addr, input [7:0] data, input exp_nack);
        begin
            expected_addr  = addr;
            expected_wdata = data;
            expected_nack  = exp_nack;
            if (exp_nack) slave.set_nack(); else slave.set_ack();

            @(posedge clk); #1;
            slave_addr = addr;
            rw         = 1'b0;
            write_data = data;
            start      = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;
            wait (done);
            check_result("WRITE");
        end
    endtask

    task i2c_read(input [6:0] addr, input [7:0] slave_data, input exp_nack);
        begin
            expected_addr = addr;
            expected_nack = exp_nack;
            slave.set_read_data(slave_data);
            if (exp_nack) slave.set_nack(); else slave.set_ack();

            @(posedge clk); #1;
            slave_addr = addr;
            rw         = 1'b1;
            start      = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;
            wait (done);
            check_result("READ");
            if (!exp_nack && read_data !== slave_data) begin
                $display("[%0t] FAIL: read_data=%h expected=%h", $time, read_data, slave_data);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ---- Scoreboard check ----
    task check_result(input [63:0] label);
        begin
            if (ack_error == expected_nack) begin
                $display("[%0t] PASS %0s addr=%h ack_error=%b", $time, label, expected_addr, ack_error);
                pass_count = pass_count + 1;
            end else begin
                $display("[%0t] FAIL %0s addr=%h ack_error=%b expected=%b", $time, label, expected_addr, ack_error, expected_nack);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ---- Passive monitor: flags START/STOP on the bus ----
    reg mon_sda_prev = 1'b1, mon_scl_prev = 1'b1;
    always @(sda or scl) begin
        if (scl && mon_scl_prev && mon_sda_prev && !sda)
            $display("[%0t] MONITOR: START detected", $time);
        else if (scl && mon_scl_prev && !mon_sda_prev && sda)
            $display("[%0t] MONITOR: STOP detected", $time);
        mon_sda_prev = sda;
        mon_scl_prev = scl;
    end

    // ---- Stimulus ----
    initial begin
        $dumpfile("waves/wave.vcd");
        $dumpvars(0, i2c_master_tb);

        start      = 0;
        rw         = 0;
        slave_addr = 7'h00;
        write_data = 8'h00;

        reset = 1;
        #40 reset = 0;
        #20;

        // Directed tests (baseline set per synopsis section 12 / P7 plan)
        i2c_write(7'h50, 8'hAA, 1'b0); // write, expect ACK
        i2c_read (7'h50, 8'h5A, 1'b0); // read,  expect ACK, data=0x5A
        i2c_write(7'h50, 8'h33, 1'b0); // multiple-data test
        i2c_write(7'h60, 8'h11, 1'b1); // wrong address -> expect NACK

        #200;
        $display("---- SUMMARY: %0d PASS, %0d FAIL ----", pass_count, fail_count);
        $finish;
    end

endmodule
