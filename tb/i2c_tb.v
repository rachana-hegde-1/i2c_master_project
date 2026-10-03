// i2c_master_tb.v
// P7: Test cases, checking, regression and basic monitoring
`timescale 1ns/1ps

module i2c_master_tb;

    // =========================================================
    // CLOCK / RESET
    // =========================================================

    reg clk;
    reg reset;

    always #10 clk = ~clk;       // 50 MHz clock

    // =========================================================
    // DUT INPUTS
    // =========================================================

    reg        start;
    reg [6:0]  slave_addr;
    reg        rw;
    reg [7:0]  write_data;

    // DUT OUTPUTS

    wire [7:0] read_data;
    wire       busy;
    wire       done;
    wire       ack_error;

    // I2C BUS

    tri scl;
    tri sda;

    pullup(scl);
    pullup(sda);

    // =========================================================
    // DUT
    // =========================================================

    i2c_master dut (
        .clk        (clk),
        .reset      (reset),
        .start      (start),
        .slave_addr (slave_addr),
        .rw         (rw),
        .write_data (write_data),
        .read_data  (read_data),
        .busy       (busy),
        .done        (done),
        .ack_error  (ack_error),
        .scl        (scl),
        .sda        (sda)
    );

    // =========================================================
    // P6 BEHAVIORAL SLAVE
    // =========================================================

    i2c_slave_model slave (
        .scl (scl),
        .sda (sda)
    );

    // =========================================================
    // TEST COUNTERS
    // =========================================================

    integer pass_count;
    integer fail_count;

    // =========================================================
    // CHECK BUSY
    // =========================================================

    task check_busy;
        begin
            if (busy !== 1'b1) begin
                $display("[%0t] FAIL: BUSY should be HIGH",
                         $time);
                fail_count = fail_count + 1;
            end
            else begin
                $display("[%0t] PASS: BUSY asserted",
                         $time);
                pass_count = pass_count + 1;
            end
        end
    endtask

    // =========================================================
    // WRITE TEST
    // =========================================================

    task i2c_write;

        input [6:0] addr;
        input [7:0] data;
        input       expect_nack;

        integer timeout;

        begin

            $display("");
            $display("======================================");
            $display("WRITE TEST");
            $display("Address = %h", addr);
            $display("Data    = %h", data);
            $display("Expected NACK = %b", expect_nack);
            $display("======================================");

            // Configure slave response
            if (expect_nack)
                slave.set_nack();
            else
                slave.set_ack();

            // Drive transaction inputs
            @(posedge clk);

            slave_addr = addr;
            rw         = 1'b0;
            write_data = data;

            start = 1'b1;

            @(posedge clk);

            start = 1'b0;

            // BUSY should become active
            #1;
            check_busy();

            // Wait for DONE, but don't allow infinite hang
            timeout = 0;

            while (!done && timeout < 2000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if (timeout >= 2000) begin

                $display("[%0t] FAIL: WRITE TIMEOUT",
                         $time);

                fail_count = fail_count + 1;

            end
            else begin

                // Check ACK/NACK result
                if (ack_error === expect_nack) begin

                    $display("[%0t] PASS: WRITE addr=%h data=%h ack_error=%b",
                             $time,
                             addr,
                             data,
                             ack_error);

                    pass_count = pass_count + 1;

                end
                else begin

                    $display("[%0t] FAIL: WRITE addr=%h data=%h",
                             $time,
                             addr,
                             data);

                    $display("Expected ack_error = %b",
                             expect_nack);

                    $display("Actual ack_error   = %b",
                             ack_error);

                    fail_count = fail_count + 1;

                end

            end

        end

    endtask

    // =========================================================
    // READ TEST
    // =========================================================

    task i2c_read;

        input [6:0] addr;
        input [7:0] expected_data;
        input       expect_nack;

        integer timeout;

        begin

            $display("");
            $display("======================================");
            $display("READ TEST");
            $display("Address = %h", addr);
            $display("Expected Data = %h", expected_data);
            $display("Expected NACK = %b", expect_nack);
            $display("======================================");

            // Configure slave
            slave.set_read_data(expected_data);

            if (expect_nack)
                slave.set_nack();
            else
                slave.set_ack();

            // Drive transaction
            @(posedge clk);

            slave_addr = addr;
            rw         = 1'b1;
            start      = 1'b1;

            @(posedge clk);

            start = 1'b0;

            // BUSY should become active
            #1;
            check_busy();

            // Wait for DONE
            timeout = 0;

            while (!done && timeout < 2000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if (timeout >= 2000) begin

                $display("[%0t] FAIL: READ TIMEOUT",
                         $time);

                fail_count = fail_count + 1;

            end
            else begin

                // Check ACK/NACK
                if (ack_error === expect_nack) begin

                    $display("[%0t] PASS: READ ack_error=%b",
                             $time,
                             ack_error);

                    pass_count = pass_count + 1;

                end
                else begin

                    $display("[%0t] FAIL: READ ACK/NACK mismatch",
                             $time);

                    fail_count = fail_count + 1;

                end

                // Check returned data only if ACK expected
                if (!expect_nack) begin

                    if (read_data === expected_data) begin

                        $display("[%0t] PASS: READ DATA = %h",
                                 $time,
                                 read_data);

                        pass_count = pass_count + 1;

                    end
                    else begin

                        $display("[%0t] FAIL: READ DATA = %h, expected = %h",
                                 $time,
                                 read_data,
                                 expected_data);

                        fail_count = fail_count + 1;

                    end

                end

            end

        end

    endtask

    // =========================================================
    // RESET TEST
    // =========================================================

    task reset_test;

        begin

            $display("");
            $display("======================================");
            $display("RESET TEST");
            $display("======================================");

            reset = 1'b1;

            @(posedge clk);
            @(posedge clk);

            #1;

            if (busy === 1'b0 &&
                done === 1'b0 &&
                ack_error === 1'b0 &&
                read_data === 8'h00) begin

                $display("[%0t] PASS: RESET",
                         $time);

                pass_count = pass_count + 1;

            end
            else begin

                $display("[%0t] FAIL: RESET",
                         $time);

                $display("busy      = %b", busy);
                $display("done      = %b", done);
                $display("ack_error = %b", ack_error);
                $display("read_data = %h", read_data);

                fail_count = fail_count + 1;

            end

            reset = 1'b0;

            @(posedge clk);

        end

    endtask

    // =========================================================
    // PASSIVE BUS MONITOR
    // =========================================================

    reg previous_sda;
    reg previous_scl;

    initial begin
        previous_sda = 1'b1;
        previous_scl = 1'b1;
    end

    always @(sda or scl) begin

        // START: SDA falling while SCL HIGH
        if ((previous_sda === 1'b1) &&
            (sda === 1'b0) &&
            (scl === 1'b1)) begin

            $display("[%0t] MONITOR: START detected",
                     $time);

        end

        // STOP: SDA rising while SCL HIGH
        if ((previous_sda === 1'b0) &&
            (sda === 1'b1) &&
            (scl === 1'b1)) begin

            $display("[%0t] MONITOR: STOP detected",
                     $time);

        end

        previous_sda = sda;
        previous_scl = scl;

    end

    // =========================================================
    // MAIN TEST SEQUENCE
    // =========================================================

    initial begin

        // Waveform dump
        $dumpfile("waves/wave.vcd");
        $dumpvars(0, i2c_master_tb);

        // Initialize
        clk        = 1'b0;
        reset      = 1'b1;
        start      = 1'b0;
        slave_addr = 7'h00;
        rw         = 1'b0;
        write_data = 8'h00;

        pass_count = 0;
        fail_count = 0;

        // -----------------------------------------------------
        // RESET
        // -----------------------------------------------------

        reset_test();

        // -----------------------------------------------------
        // WRITE - ACK
        // -----------------------------------------------------

        i2c_write(
            7'h50,
            8'hAA,
            1'b0
        );

        // -----------------------------------------------------
        // READ - ACK
        // -----------------------------------------------------

        i2c_read(
            7'h50,
            8'h5A,
            1'b0
        );

        // -----------------------------------------------------
        // MULTIPLE WRITE DATA
        // -----------------------------------------------------

        i2c_write(
            7'h50,
            8'h33,
            1'b0
        );

        i2c_write(
            7'h50,
            8'h55,
            1'b0
        );

        i2c_write(
            7'h50,
            8'hF0,
            1'b0
        );

        // -----------------------------------------------------
        // ADDRESS NACK
        // -----------------------------------------------------

        i2c_write(
            7'h60,
            8'h11,
            1'b1
        );

        // -----------------------------------------------------
        // SUMMARY
        // -----------------------------------------------------

        #200;

        $display("");
        $display("======================================");
        $display("          TEST SUMMARY");
        $display("======================================");
        $display("PASS = %0d", pass_count);
        $display("FAIL = %0d", fail_count);
        $display("======================================");

        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        $finish;

    end

endmodule
