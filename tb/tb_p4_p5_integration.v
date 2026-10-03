`timescale 1ns/1ps
// Integration check: P5 register file driving P4 byte controller (P3 stubbed).
module tb_p4_p5_integration;
    reg clk=0, rst_n=0; always #5 clk=~clk;
    reg psel=0, penable=0, pwrite=0; reg [7:0] paddr=0; reg [31:0] pwdata=0;
    wire [31:0] prdata; wire pready, pslverr, irq;
    wire [15:0] prescale; wire fast_mode, core_en;
    wire c_start,c_stop,c_read,c_write,c_nack; wire [7:0] tx_data, rx_data;
    wire done, ack_in, arb_lost, bus_busy;
    wire bit_vld, bit_din; wire [2:0] bit_cmd;
    reg bit_done=0, bit_dout=0; integer m_cnt=-1; reg [2:0] m_cmd; integer nrd=8; reg [7:0] wr_sr=0;

    i2c_regfile rf(.clk(clk),.rst_n(rst_n),.psel(psel),.penable(penable),.pwrite(pwrite),
        .paddr(paddr),.pwdata(pwdata),.prdata(prdata),.pready(pready),.pslverr(pslverr),
        .prescale(prescale),.fast_mode(fast_mode),.core_en(core_en),
        .cmd_start(c_start),.cmd_stop(c_stop),.cmd_read(c_read),.cmd_write(c_write),
        .cmd_nack(c_nack),.tx_data(tx_data),.done(done),.ack_in(ack_in),.rx_data(rx_data),
        .arb_lost(arb_lost),.bus_busy(bus_busy),.irq(irq));
    i2c_byte_ctrl bc(.clk(clk),.rst_n(rst_n),
        .cmd_start(c_start),.cmd_stop(c_stop),.cmd_read(c_read),.cmd_write(c_write),
        .cmd_nack(c_nack),.tx_data(tx_data),.done(done),.ack_in(ack_in),.rx_data(rx_data),
        .arb_lost(arb_lost),.bus_busy(bus_busy),
        .bit_vld(bit_vld),.bit_cmd(bit_cmd),.bit_din(bit_din),
        .bit_done(bit_done),.bit_dout(bit_dout),.bit_al(1'b0));

    // P3 stub: slave ACKs writes; returns 0x96 on reads
    always @(posedge clk) begin
        bit_done <= 0;
        if (bit_vld) begin m_cnt <= 2; m_cmd <= bit_cmd; if (bit_cmd==3) wr_sr <= {wr_sr[6:0],bit_din}; end
        else if (m_cnt == 0) begin
            m_cnt <= -1; bit_done <= 1;
            if (m_cmd==4) begin bit_dout <= (nrd<8) ? 8'h96 >> (7-nrd) & 1'b1 : 1'b0; nrd = nrd+1; end
        end else if (m_cnt > 0) m_cnt <= m_cnt - 1;
    end

    task apb_write(input [7:0] a, input [31:0] d); begin
        @(posedge clk); #1 psel=1; pwrite=1; paddr=a; pwdata=d; penable=0;
        @(posedge clk); #1 penable=1; @(posedge clk); #1 psel=0; penable=0; pwrite=0; end endtask
    task apb_read(input [7:0] a, output [31:0] d); begin
        @(posedge clk); #1 psel=1; pwrite=0; paddr=a; penable=0;
        @(posedge clk); #1 penable=1; #1 d=prdata; @(posedge clk); #1 psel=0; penable=0; end endtask
    task wait_tip_clear; reg [31:0] r; integer t; begin
        t=0; r=32'h2; while (r[1] && t<300) begin apb_read(8'h18, r); t=t+1; end end endtask

    integer errors=0; reg [31:0] rd;
    task check(input [255:0] n, input [31:0] g, input [31:0] e); begin
        if (g!==e) begin errors=errors+1; $display("FAIL %0s got %h exp %h", n,g,e); end
        else $display("PASS %0s", n); end endtask

    initial begin
        #22 rst_n=1;
        apb_write(8'h08, 32'h3);                 // EN + IEN
        apb_write(8'h0C, 32'hA0);                // address 0x50, write
        apb_write(8'h14, 32'h09);                // START|WRITE
        apb_read(8'h18, rd); check("TIP set after cmd", rd[1], 1);
        wait_tip_clear;
        apb_read(8'h18, rd); check("status: IRQ flag, ACK", rd[2:0] & 3'b101, 3'b001);
        check("irq pin", irq, 1);
        check("byte on bit side", wr_sr[7:0], 8'hA0);
        apb_write(8'h14, 32'h20);                // IACK
        nrd = 0;
        apb_write(8'h14, 32'h16);                // READ|NACK|STOP  (0x04|0x10|0x02)
        wait_tip_clear;
        apb_read(8'h10, rd); check("RXR via APB", rd, 32'h96);
        apb_read(8'h18, rd); check("BUSY cleared after STOP", rd[3], 0);
        if (errors==0) $display("INTEGRATION PASSED"); else $display("%0d FAILED", errors);
        $finish;
    end
endmodule
