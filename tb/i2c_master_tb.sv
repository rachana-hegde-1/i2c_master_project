`timescale 1ns/1ps

module i2c_master_tb;

    // =========================================================
    // DUT INPUTS
    // =========================================================

    reg        clk;
    reg        reset;
    reg        start;
    reg [6:0]  slave_addr;
    reg        rw;
    reg [7:0]  write_data;


    // =========================================================
    // DUT OUTPUTS
    // =========================================================

    wire [7:0] read_data;
    wire       busy;
    wire       done;
    wire       ack_error;


    // =========================================================
    // I2C BUS
    // Open-drain bidirectional lines
    // =========================================================

    tri scl;
    tri sda;

    // Pull-ups for I2C bus
    pullup(scl);
    pullup(sda);


    // =========================================================
    // DEVICE UNDER TEST
    // P1-P5 I2C MASTER
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
    // P6 SLAVE MODEL
    // =========================================================
    //
    // Add P6's exact module here once they give you
    // their port/interface.
    //
    // Example:
    //
    // i2c_slave_model slave (
    //     .scl(scl),
    //     .sda(sda)
    // );
    //
    // =========================================================


    // =========================================================
    // 50 MHz SYSTEM CLOCK
    // Period = 20 ns
    // =========================================================

    always #10 clk = ~clk;


    // =========================================================
    // MAIN TEST SEQUENCE
    // =========================================================

    initial begin

        // Initial values
        clk        = 1'b0;
        reset      = 1'b0;
        start      = 1'b0;
        slave_addr = 7'h50;
        rw         = 1'b0;
        write_data = 8'h00;


        // =====================================================
        // TEST 1 : RESET
        // =====================================================

        $display("");
        $display("========================================");
        $display("TEST 1 : RESET");
        $display("========================================");

        reset = 1'b1;

        @(posedge clk);
        @(posedge clk);

        reset = 1'b0;

        @(posedge clk);

        if ((busy == 1'b0) &&
            (done == 1'b0) &&
            (ack_error == 1'b0) &&
            (read_data == 8'h00)) begin

            $display("RESET TEST : PASS");

        end
        else begin

            $display("RESET TEST : FAIL");

        end


        // =====================================================
        // TEST 2 : SINGLE BYTE WRITE
        // =====================================================

        $display("");
        $display("========================================");
        $display("TEST 2 : SINGLE BYTE WRITE");
        $display("========================================");

        write_test(7'h50, 8'hA5);


        // =====================================================
        // TEST 3 : SINGLE BYTE READ
        // =====================================================

        $display("");
        $display("========================================");
        $display("TEST 3 : SINGLE BYTE READ");
        $display("========================================");

        read_test(7'h50);


        // =====================================================
        // END
        // =====================================================

        $display("");
        $display("========================================");
        $display("ALL BASIC TESTS FINISHED");
        $display("========================================");

        #100;

        $finish;

    end


    // =========================================================
    // WRITE TEST
    // =========================================================

    task write_test;

        input [6:0] addr;
        input [7:0] data;

        begin

            // Apply transaction inputs
            slave_addr = addr;
            rw         = 1'b0;
            write_data = data;

            // Generate start request
            @(posedge clk);
            start = 1'b1;

            @(posedge clk);
            start = 1'b0;


            // Check that transaction became active
            #1;

            if (busy == 1'b1)
                $display("BUSY TEST : PASS");
            else
                $display("BUSY TEST : FAIL");


            // Wait until transaction completes
            wait(done == 1'b1);


            // Check result
            if (ack_error == 1'b0) begin

                $display("WRITE TEST : PASS");
                $display("Address = %h", addr);
                $display("Data    = %h", data);

            end
            else begin

                $display("WRITE TEST : FAIL");
                $display("ACK ERROR detected");

            end


            @(posedge clk);

        end

    endtask


    // =========================================================
    // READ TEST
    // =========================================================

    task read_test;

        input [6:0] addr;

        begin

            // Apply transaction inputs
            slave_addr = addr;
            rw         = 1'b1;
            write_data = 8'h00;


            // Generate start request
            @(posedge clk);
            start = 1'b1;

            @(posedge clk);
            start = 1'b0;


            // Wait for transaction completion
            wait(done == 1'b1);


            // Check result
            if (ack_error == 1'b0) begin

                $display("READ TEST : PASS");
                $display("Address   = %h", addr);
                $display("Read Data = %h", read_data);

            end
            else begin

                $display("READ TEST : FAIL");
                $display("ACK ERROR detected");

            end


            @(posedge clk);

        end

    endtask


    // =========================================================
    // CONTINUOUS MONITOR
    // =========================================================

    initial begin

        $monitor(
            "TIME=%0t | RESET=%b START=%b BUSY=%b DONE=%b ACK_ERR=%b RW=%b ADDR=%h WDATA=%h RDATA=%h SCL=%b SDA=%b",
            $time,
            reset,
            start,
            busy,
            done,
            ack_error,
            rw,
            slave_addr,
            write_data,
            read_data,
            scl,
            sda
        );

    end


    // =========================================================
    // WAVEFORM DUMP
    // =========================================================

    initial begin

        $dumpfile("i2c_master.vcd");
        $dumpvars(0, i2c_master_tb);

    end

endmodule