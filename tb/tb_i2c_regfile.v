`timescale 1ns/1ps
// Standalone unit testbench for P5. A tiny behavioural stand-in plays P4.
module tb_i2c_regfile;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg psel=0, penable=0, pwrite=0; reg [7:0] paddr=0; reg [31:0] pwdata=0;
    wire [31:0] prdata; wire pready, pslverr;
    wire [15:0] prescale; wire fast_mode, core_en;
    wire cmd_start, cmd_stop, cmd_read, cmd_write, cmd_nack; wire [7:0] tx_data;
    reg done=0, ack_in=0, arb_lost=0, bus_busy=0; reg [7:0] rx_data=0;
    wire irq;

    i2c_regfile dut(.clk(clk),.rst_n(rst_n),.psel(psel),.penable(penable),.pwrite(pwrite),
        .paddr(paddr),.pwdata(pwdata),.prdata(prdata),.pready(pready),.pslverr(pslverr),
        .prescale(prescale),.fast_mode(fast_mode),.core_en(core_en),
        .cmd_start(cmd_start),.cmd_stop(cmd_stop),.cmd_read(cmd_read),.cmd_write(cmd_write),
        .cmd_nack(cmd_nack),.tx_data(tx_data),.done(done),.ack_in(ack_in),
        .rx_data(rx_data),.arb_lost(arb_lost),.bus_busy(bus_busy),.irq(irq));

    integer errors = 0;
    reg [31:0] rd;

    task apb_write(input [7:0] a, input [31:0] d); begin
        @(posedge clk); #1 psel=1; pwrite=1; paddr=a; pwdata=d; penable=0;
        @(posedge clk); #1 penable=1;
        @(posedge clk); #1 psel=0; penable=0; pwrite=0;
    end endtask
    task apb_read(input [7:0] a, output [31:0] d); begin
        @(posedge clk); #1 psel=1; pwrite=0; paddr=a; penable=0;
        @(posedge clk); #1 penable=1;
        #1 d = prdata;
        @(posedge clk); #1 psel=0; penable=0;
    end endtask
    task check(input [255:0] name, input [31:0] got, input [31:0] exp); begin
        if (got !== exp) begin errors=errors+1; $display("FAIL %0s: got %h exp %h", name, got, exp); end
        else $display("PASS %0s", name);
    end endtask

    initial begin
        $dumpfile("../waves/tb_i2c_regfile.vcd"); $dumpvars(0, tb_i2c_regfile);
        #22 rst_n = 1;

        // reset defaults
        apb_read(8'h08, rd); check("CTRL reset", rd, 0);
        // RW registers
        apb_write(8'h00, 32'h63); apb_write(8'h04, 32'h01);
        check("prescale out", prescale, 16'h0163);
        apb_read(8'h00, rd); check("PRESC_LO rb", rd, 32'h63);
        apb_write(8'h08, 32'h7);  // EN+IEN+FAST
        check("core_en", core_en, 1); check("fast", fast_mode, 1);
        apb_write(8'h0C, 32'hA0);
        check("tx_data", tx_data, 8'hA0);

        // START|WRITE -> one-cycle pulses, TIP set
        apb_write(8'h14, 32'h09);
        check("cmd_start pulse", {cmd_start,cmd_write}, 2'b11);
        @(posedge clk); #1;
        check("pulse cleared", {cmd_start,cmd_write}, 2'b00);
        apb_read(8'h18, rd); check("TIP set", rd[1], 1);

        // command ignored while TIP
        apb_write(8'h14, 32'h02); @(posedge clk); #1;
        check("cmd ignored in TIP", cmd_stop, 0);

        // P4 finishes with a NACK
        @(posedge clk); #1 done=1; ack_in=1; rx_data=8'h5A;
        @(posedge clk); #1 done=0;
        apb_read(8'h18, rd); check("status after done", rd[4:0], 5'b00101); // IRQ, NACK
        check("irq pin", irq, 1);
        apb_read(8'h10, rd); check("RXR", rd, 32'h5A);

        // IACK clears irq
        apb_write(8'h14, 32'h20);
        apb_read(8'h18, rd); check("irq cleared", rd[0], 0);
        check("irq pin low", irq, 0);

        // read with NACK
        apb_write(8'h14, 32'h14);  // READ + NACK
        check("cmd_read", cmd_read, 1); check("cmd_nack", cmd_nack, 1);
        @(posedge clk); #1 done=1; ack_in=0; rx_data=8'hC3;
        @(posedge clk); #1 done=0;

        // arbitration lost
        apb_write(8'h14, 32'h01);
        @(posedge clk); #1 arb_lost=1; @(posedge clk); #1 arb_lost=0;
        apb_read(8'h18, rd); check("AL set, TIP clr", {rd[4],rd[1]}, 2'b10);
        apb_write(8'h14, 32'h20);
        apb_read(8'h18, rd); check("AL cleared", rd[4], 0);

        // bus busy passthrough
        bus_busy=1; apb_read(8'h18, rd); check("BUSY", rd[3], 1); bus_busy=0;

        // pslverr cases
        @(posedge clk); #1 psel=1; pwrite=1; paddr=8'h18; penable=1; #1
        check("pslverr RO write", pslverr, 1);
        paddr=8'h40; #1 check("pslverr bad addr", pslverr, 1);
        psel=0; penable=0;

        // disable core blocks commands
        apb_write(8'h08, 32'h0);
        apb_write(8'h14, 32'h01); @(posedge clk); #1;
        check("cmd blocked when disabled", cmd_start, 0);

        if (errors==0) $display("ALL TESTS PASSED"); else $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
