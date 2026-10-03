// ============================================================================
// i2c_regfile.v  --  P5: Register file + APB slave interface
// ----------------------------------------------------------------------------
// Register map (32-bit APB, word aligned, only low bits used):
//   0x00 PRESC_LO  RW  [7:0]  prescaler divider, low byte
//   0x04 PRESC_HI  RW  [7:0]  prescaler divider, high byte
//   0x08 CTRL      RW  [0] EN     core enable
//                      [1] IEN    interrupt enable
//                      [2] FAST   0 = standard (100k), 1 = fast (400k)
//   0x0C TXR       RW  [7:0] transmit data / {addr[6:0], R/W}
//   0x10 RXR       RO  [7:0] last received byte
//   0x14 CMD       WO  [0] START  [1] STOP  [2] READ  [3] WRITE
//                      [4] NACK (1 = send NACK on read)  [5] IACK (clear irq)
//                      START/STOP/READ/WRITE are self-clearing pulses
//   0x18 STATUS    RO  [0] IRQ_FLAG  [1] TIP (transfer in progress)
//                      [2] RX_NACK (1 = slave NACKed)  [3] BUSY (bus busy)
//                      [4] ARB_LOST
// ============================================================================
module i2c_regfile (
    input  wire        clk,
    input  wire        rst_n,

    // ---- APB slave ----
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [7:0]  paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // ---- to P2 (prescaler / timing) ----
    output wire [15:0] prescale,
    output wire        fast_mode,
    output wire        core_en,

    // ---- to P4 (byte controller) ----
    output reg         cmd_start,
    output reg         cmd_stop,
    output reg         cmd_read,
    output reg         cmd_write,
    output reg         cmd_nack,      // ACK bit to drive after a read (1 = NACK)
    output wire [7:0]  tx_data,

    // ---- from P4 ----
    input  wire        done,          // 1-cycle pulse: command finished
    input  wire        ack_in,        // slave ACK/NACK sampled (1 = NACK)
    input  wire [7:0]  rx_data,       // byte read from bus
    input  wire        arb_lost,      // arbitration-lost pulse/level
    input  wire        bus_busy,      // START seen, STOP not yet seen

    // ---- interrupt ----
    output wire        irq
);

    // ---------------- address decode ----------------
    localparam A_PRESC_LO = 8'h00,
               A_PRESC_HI = 8'h04,
               A_CTRL     = 8'h08,
               A_TXR      = 8'h0C,
               A_RXR      = 8'h10,
               A_CMD      = 8'h14,
               A_STATUS   = 8'h18;

    // APB with zero wait states: access phase = psel & penable
    wire wr_en = psel & penable &  pwrite;
    wire rd_en = psel & penable & ~pwrite;
    assign pready  = 1'b1;

    wire addr_ok = (paddr == A_PRESC_LO) | (paddr == A_PRESC_HI) |
                   (paddr == A_CTRL)     | (paddr == A_TXR)      |
                   (paddr == A_RXR)      | (paddr == A_CMD)      |
                   (paddr == A_STATUS);
    // error on unmapped address, or write to RO register
    wire ro_write = (paddr == A_RXR) | (paddr == A_STATUS);
    assign pslverr = psel & penable & (~addr_ok | (pwrite & ro_write));

    // ---------------- storage ----------------
    reg [7:0] presc_lo, presc_hi;
    reg [2:0] ctrl;           // {FAST, IEN, EN}
    reg [7:0] txr;
    reg [7:0] rxr;
    reg       rx_nack;
    reg       al_flag;
    reg       irq_flag;
    reg       tip;

    assign prescale  = {presc_hi, presc_lo};
    assign core_en   = ctrl[0];
    assign fast_mode = ctrl[2];
    assign tx_data   = txr;
    assign irq       = irq_flag & ctrl[1];

    // ---------------- writes ----------------
    wire cmd_wr = wr_en & (paddr == A_CMD);
    wire iack   = cmd_wr & pwdata[5];
    // Commands only accepted when core enabled and no transfer pending
    wire cmd_accept = cmd_wr & ctrl[0] & ~tip &
                      (pwdata[0] | pwdata[1] | pwdata[2] | pwdata[3]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            presc_lo <= 8'hFF;      // safe slow default
            presc_hi <= 8'h00;
            ctrl     <= 3'b000;
            txr      <= 8'h00;
        end else if (wr_en) begin
            case (paddr)
                A_PRESC_LO: presc_lo <= pwdata[7:0];
                A_PRESC_HI: presc_hi <= pwdata[7:0];
                A_CTRL:     ctrl     <= pwdata[2:0];
                A_TXR:      txr      <= pwdata[7:0];
                default: ;
            endcase
        end
    end

    // ---------------- command pulses ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_start <= 1'b0; cmd_stop <= 1'b0;
            cmd_read  <= 1'b0; cmd_write <= 1'b0;
            cmd_nack  <= 1'b0;
        end else begin
            // pulses last exactly one clock
            cmd_start <= cmd_accept & pwdata[0];
            cmd_stop  <= cmd_accept & pwdata[1];
            cmd_read  <= cmd_accept & pwdata[2];
            cmd_write <= cmd_accept & pwdata[3];
            if (cmd_accept) cmd_nack <= pwdata[4];   // held until next command
        end
    end

    // ---------------- status / interrupt ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tip <= 1'b0; irq_flag <= 1'b0; rx_nack <= 1'b0;
            al_flag <= 1'b0; rxr <= 8'h00;
        end else begin
            // TIP: set on accepted command, cleared on done or arb loss
            if (cmd_accept)              tip <= 1'b1;
            else if (done | arb_lost)    tip <= 1'b0;
            // IRQ flag: set on done or arb loss, cleared by IACK
            if (done | arb_lost)         irq_flag <= 1'b1;
            else if (iack)               irq_flag <= 1'b0;
            // capture results on completion
            if (done) begin
                rx_nack <= ack_in;
                rxr     <= rx_data;
            end
            // arbitration-lost sticky, cleared by IACK
            if (arb_lost)                al_flag <= 1'b1;
            else if (iack)               al_flag <= 1'b0;
            // core disabled -> clear transfer state
            if (!ctrl[0])                tip <= 1'b0;
        end
    end

    // ---------------- reads ----------------
    always @(*) begin
        prdata = 32'h0;
        case (paddr)
            A_PRESC_LO: prdata = {24'b0, presc_lo};
            A_PRESC_HI: prdata = {24'b0, presc_hi};
            A_CTRL:     prdata = {29'b0, ctrl};
            A_TXR:      prdata = {24'b0, txr};
            A_RXR:      prdata = {24'b0, rxr};
            A_STATUS:   prdata = {27'b0, al_flag, bus_busy, rx_nack, tip, irq_flag};
            default:    prdata = 32'h0;
        endcase
    end
endmodule
