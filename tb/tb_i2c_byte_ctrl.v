`timescale 1ns/1ps
// Standalone unit testbench for P4 with a behavioural stand-in for P3.
module tb_i2c_byte_ctrl;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg cmd_start=0, cmd_stop=0, cmd_read=0, cmd_write=0, cmd_nack=0;
    reg [7:0] tx_data = 0;
    wire done, ack_in, arb_lost, bus_busy; wire [7:0] rx_data;
    wire bit_vld, bit_din; wire [2:0] bit_cmd;
    reg bit_done = 0, bit_dout = 0, bit_al = 0;

    i2c_byte_ctrl dut(.clk(clk),.rst_n(rst_n),
        .cmd_start(cmd_start),.cmd_stop(cmd_stop),.cmd_read(cmd_read),.cmd_write(cmd_write),
        .cmd_nack(cmd_nack),.tx_data(tx_data),.done(done),.ack_in(ack_in),.rx_data(rx_data),
        .arb_lost(arb_lost),.bus_busy(bus_busy),
        .bit_vld(bit_vld),.bit_cmd(bit_cmd),.bit_din(bit_din),
        .bit_done(bit_done),.bit_dout(bit_dout),.bit_al(bit_al));

    // ---------------- P3 stand-in ----------------
    reg        ack_val = 0;       // what the "slave" returns for ACK-slot reads
    reg        rd_mode = 0;       // 1: READ returns bits of rd_byte, 0: returns ack_val
    reg [7:0]  rd_byte = 0;
    integer    n_start, n_stop, n_wr, n_rd, rd_idx;
    reg [7:0]  wr_sr;  reg last_wdin;
    reg        m_busy = 0; reg [2:0] m_cmd; reg m_din; integer m_cnt;
    reg        order_ok;          // checks START came before data, STOP last
    reg        seen_data, seen_stop;

    task txn_reset; begin
        n_start=0; n_stop=0; n_wr=0; n_rd=0; rd_idx=0; wr_sr=0; last_wdin=0;
        order_ok=1; seen_data=0; seen_stop=0;
    end endtask

    always @(posedge clk) begin
        bit_done <= 1'b0;
        if (bit_vld) begin
            m_busy <= 1; m_cmd <= bit_cmd; m_din <= bit_din; m_cnt <= 3;
            case (bit_cmd)
                3'd1: begin n_start=n_start+1; if (seen_data) order_ok=0; end
                3'd2: begin n_stop =n_stop +1; seen_stop=1; end
                3'd3: begin n_wr=n_wr+1; wr_sr={wr_sr[6:0],bit_din}; last_wdin=bit_din;
                            seen_data=1; if (seen_stop) order_ok=0; end
                3'd4: begin n_rd=n_rd+1; seen_data=1; if (seen_stop) order_ok=0; end
            endcase
        end else if (m_busy) begin
            if (m_cnt == 0) begin
                m_busy <= 0; bit_done <= 1;
                if (m_cmd == 3'd4) begin
                    if (rd_mode && rd_idx < 8) begin bit_dout <= rd_byte[7-rd_idx]; rd_idx = rd_idx+1; end
                    else bit_dout <= ack_val;
                end
            end else m_cnt <= m_cnt - 1;
        end
    end

    // ---------------- helpers ----------------
    integer errors = 0;
    task check(input [255:0] name, input [31:0] got, input [31:0] exp); begin
        if (got !== exp) begin errors=errors+1; $display("FAIL %0s: got %h exp %h", name, got, exp); end
        else $display("PASS %0s", name);
    end endtask

    // issue a 1-cycle command pulse and wait for done (or timeout)
    task run(input s, input st, input rd, input wr, input nack, input [7:0] d);
        integer t; begin
        txn_reset;
        @(posedge clk); #1 cmd_start=s; cmd_stop=st; cmd_read=rd; cmd_write=wr; cmd_nack=nack; tx_data=d;
        @(posedge clk); #1 cmd_start=0; cmd_stop=0; cmd_read=0; cmd_write=0;
        t = 0;
        while (!done && t < 500) begin @(posedge clk); #1; t=t+1; end
        if (t >= 500) begin errors=errors+1; $display("FAIL timeout"); end
        @(posedge clk); #1;   // let done fall
    end endtask

    initial begin
        $dumpfile("../waves/tb_i2c_byte_ctrl.vcd"); $dumpvars(0, tb_i2c_byte_ctrl);
        txn_reset;
        #22 rst_n = 1;

        // T1: START+WRITE, slave ACKs
        ack_val = 0; rd_mode = 0;
        run(1,0,0,1,0, 8'hA6);
        check("T1 START count", n_start, 1);
        check("T1 8 data bits", n_wr, 8);
        check("T1 ACK slot read", n_rd, 1);
        check("T1 byte value", wr_sr, 8'hA6);
        check("T1 ack_in (ACK=0)", ack_in, 0);
        check("T1 bus_busy", bus_busy, 1);
        check("T1 no STOP", n_stop, 0);
        check("T1 order", order_ok, 1);

        // T2: plain WRITE (no start), slave NACKs
        ack_val = 1;
        run(0,0,0,1,0, 8'h5C);
        check("T2 no START", n_start, 0);
        check("T2 byte value", wr_sr, 8'h5C);
        check("T2 ack_in (NACK=1)", ack_in, 1);

        // T3: repeated START + WRITE
        ack_val = 0;
        run(1,0,0,1,0, 8'hA7);
        check("T3 rep START", n_start, 1);
        check("T3 byte value", wr_sr, 8'hA7);
        check("T3 bus_busy still 1", bus_busy, 1);

        // T4: READ, send NACK (last byte)
        rd_mode = 1; rd_byte = 8'h3C;
        run(0,0,1,0,1, 8'h00);
        check("T4 8 data bits read", n_rd, 8);
        check("T4 rx_data", rx_data, 8'h3C);
        check("T4 NACK driven", {n_wr[3:0], last_wdin}, {4'd1, 1'b1});

        // T5: READ with ACK (more bytes follow)
        rd_byte = 8'hC3;
        run(0,0,1,0,0, 8'h00);
        check("T5 rx_data", rx_data, 8'hC3);
        check("T5 ACK driven", {n_wr[3:0], last_wdin}, {4'd1, 1'b0});
        check("T5 bus_busy still 1", bus_busy, 1);

        // T6: READ + NACK + STOP
        rd_byte = 8'hE1;
        run(0,1,1,0,1, 8'h00);
        check("T6 rx_data", rx_data, 8'hE1);
        check("T6 STOP count", n_stop, 1);
        check("T6 order (STOP last)", order_ok, 1);
        check("T6 bus_busy cleared", bus_busy, 0);

        // T7: WRITE + STOP
        rd_mode = 0; ack_val = 0;
        run(1,1,0,1,0, 8'h12);
        check("T7 START", n_start, 1);
        check("T7 byte", wr_sr, 8'h12);
        check("T7 STOP", n_stop, 1);
        check("T7 order", order_ok, 1);
        check("T7 bus_busy cleared", bus_busy, 0);

        // T8: STOP only
        run(1,0,0,0,0, 0);            // bare START
        check("T8a bare START", {n_start[3:0], n_wr[3:0]}, {4'd1, 4'd0});
        check("T8a bus_busy", bus_busy, 1);
        run(0,1,0,0,0, 0);            // bare STOP
        check("T8b bare STOP", n_stop, 1);
        check("T8b bus_busy", bus_busy, 0);

        // T9: arbitration lost mid-write, then recover
        txn_reset;
        @(posedge clk); #1 cmd_start=1; cmd_write=1; tx_data=8'hFF;
        @(posedge clk); #1 cmd_start=0; cmd_write=0;
        while (n_wr < 3) @(posedge clk);
        #1 bit_al = 1; @(posedge clk); #1 bit_al = 0;
        check("T9 arb_lost pulse seen", arb_lost, 1);
        repeat (10) @(posedge clk);   // let stand-in drain
        #1 check("T9 no done after AL", done, 0);
        check("T9 bus_busy cleared", bus_busy, 0);
        run(1,1,0,1,0, 8'h81);        // new command works after recovery
        check("T9 recovered byte", wr_sr, 8'h81);

        if (errors==0) $display("ALL TESTS PASSED"); else $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
