`timescale 1ns / 1ps

// Wraps spi_top with an AMBA APB (v2/v3-style, 2-phase SETUP/ACCESS)
// register interface instead of its plain cfg_*/tx_*/rx_*/busy signals,
// for a host CPU/APB bridge to talk to the controller as a standard
// memory-mapped peripheral. spi_top itself is untouched -- this is a pure
// additive wrapper, so tb_spi_loopback.sv/tb_spi_multi_slave.sv's
// existing coverage of the core transfer logic is unaffected by anything
// here.
//
// Register map (byte addresses, 32-bit registers, word-aligned):
//
// | Addr | Name       | Access | Description                              |
// |------|------------|--------|------------------------------------------|
// | 0x00 | SPI_CR     | R/W    | Control: start (bit0), soft_reset (bit1) |
// | 0x04 | SPI_SR     | R      | Status: busy, done, tx_ready, rx_valid,   |
// |      |            |        | rx_busy                                   |
// | 0x08 | SPI_DR     | R/W    | Data: write=TX, read=RX                   |
// | 0x0C | SPI_CKDIV  | R/W    | Clock divider (16-bit)                    |
// | 0x10 | SPI_CFG    | R/W    | Config: mode, cpol, cpha, bit_order,       |
// |      |            |        | data_bits                                 |
// | 0x14 | SPI_IER    | R/W    | Interrupt enable                          |
// | 0x18 | SPI_ISR    | R/WC   | Interrupt status (write-1-to-clear)       |
// | 0x1C | SPI_WDT    | R/W    | Watchdog timeout threshold, in clk cycles |
// |      |            |        | (32-bit); 0 = disabled (reset default)   |
//
// SPI_CR: bit0 START, bit1 SOFT_RESET. Both self-clear: a write is only
// ever visible on PRDATA for the one cycle immediately following the
// write (the pulse this register produces for the core/reset logic),
// and reads back 0 otherwise. Writing START while a transfer is already
// in flight (tx_ready low) has no effect beyond what spi_master itself
// already does with tx_valid while !tx_ready -- the write is simply not
// actionable until the core is ready, exactly as if software had polled
// SPI_SR.TX_READY first and it happened to still be 0.
//
// SPI_SR: bit0 BUSY, bit1 DONE, bit2 TX_READY, bit3 RX_VALID, bit4
// RX_BUSY, bit5 ERR. DONE and RX_VALID are the same underlying latch (this
// core's full-duplex transfers complete their TX and produce fresh RX data
// in the same cycle, so there is only one "new data is ready" event to
// track); likewise RX_BUSY is just BUSY (RX activity exactly tracks TX
// activity in this core, there is no independent receive-only busy
// state). DONE/RX_VALID is set when the core's rx_valid pulses and
// cleared by reading SPI_DR (the natural "collect the result" point) or
// by writing SPI_CR.START (starting a new transfer invalidates any
// stale unread result); a fresh rx_valid pulse takes priority over
// either clear condition landing on the same cycle. ERR is a live (not
// latched) OR of SPI_ISR's two error bits (OE, PERR -- see below), so
// polling-only software can check for a problem without decoding ISR or
// using interrupts at all.
//
// Error handling: four conditions are detected and reported without
// affecting normal operation --
//   - RX overrun (OE): SPI_CR.START is written while the previous
//     result was never read out (DONE/RX_VALID still set). Checked at
//     the START write itself, not at the new transfer's completion --
//     START unconditionally clears DONE/RX_VALID (a fresh transfer
//     invalidates any stale result), so by the time the new transfer's
//     rx_valid pulses, the "was there unread data" moment has already
//     passed. The new transfer still proceeds and overwrites SPI_DR's
//     RX value regardless (there is nowhere else to put it), matching
//     how a real UART/SPI peripheral's overrun flag works -- it reports
//     that data was lost, it does not preserve the lost data.
//   - Protocol error (PERR), any of:
//       * accessing (read or write) an address that isn't one of the
//         eight registers in this map;
//       * writing to SPI_SR (the map's only strictly read-only register);
//       * writing SPI_CR.START while the core is still busy from a
//         previous transfer (the write has no effect on the core, same
//         as any tx_valid arriving while !tx_ready, but the host asked
//         for something that didn't happen and should be told so);
//       * writing SPI_CFG with DATA_BITS greater than the DATA_WIDTH
//         elaboration parameter (there is no such thing as a transfer
//         wider than the core's own word register, so the write is
//         rejected in full rather than silently truncated).
//     Every PERR condition also drives PSLVERR high for that same ACCESS
//     cycle (see "Bus protocol" below), so a bus-level error monitor sees
//     it without decoding SPI_ISR.
//   - Timeout (TO): the core stays busy for at least SPI_WDT clock
//     cycles without completing (see SPI_WDT below). Diagnostic only --
//     it does not abort the transfer or touch core_rst_n; a host that
//     sees TO set can choose to recover via SPI_CR.soft_reset itself.
//     Fires exactly once per busy period even though "still busy and
//     still over threshold" remains true for the rest of that transfer,
//     so W1C-clearing it sticks until the next transfer's own busy
//     period (during which it can fire again if still applicable) --
//     otherwise a host clearing it mid-transfer would see it immediately
//     reassert from the same still-true condition on the very next cycle.
// None of these block or corrupt anything else in the register file --
// an invalid-address write already fails every register's own address
// comparison and is naturally a no-op, and SPI_SR has no backing storage
// for a write to corrupt regardless. Writing SPI_DR while busy is
// deliberately *not* flagged as an error: it is the normal, supported way
// to preload the next transfer's data while the current one is still in
// flight.
//
// SPI_DR: write loads the word to transmit on the next START; the
// controller does not auto-start on a DR write, matching SPI_CR having
// a dedicated START bit. Read returns the most recently received word,
// zero-extended to 32 bits, and clears SR/ISR's DONE/RX_VALID status.
//
// SPI_CKDIV: mirrors spi_master's cfg_clk_div directly; a no-op in slave
// mode (spi_slave has no clock divider, it derives timing from the
// external sclk it receives), same as spi_top's own cfg_clk_div port.
//
// SPI_CFG: bits [1:0] MODE = {CPOL,CPHA}, matching this core's own SPI
// mode table exactly (mode 0/1/2/3 <-> CPOL/CPHA 00/01/10/11) so MODE
// can be written directly as the standard SPI mode number; bit[2]
// BIT_ORDER (0=MSB first, 1=LSB first); bits [8:3] DATA_BITS, the number
// of bits exchanged per transfer. DATA_BITS follows the same
// shadow/latch protection as MODE/BIT_ORDER (see docs/README.md): a
// write takes effect starting with the next transfer, never corrupting
// one already in flight. A value of 0 (the reset default) means "use
// the full DATA_WIDTH elaboration parameter", so existing software that
// never touches DATA_BITS keeps its prior full-width behavior
// unchanged; 1..DATA_WIDTH select a narrower runtime word length.
// Writing DATA_BITS > DATA_WIDTH is rejected outright (see PERR below)
// rather than silently truncated or accepted with undefined behavior
// -- the whole SPI_CFG write is dropped, leaving MODE/BIT_ORDER/
// DATA_BITS all at their prior values.
//
// SPI_IER/SPI_ISR: bit0 DONE (mirrors SR.DONE's set condition), bit1
// TX_READY (set on tx_ready's 0->1 edge, i.e. the core becoming ready
// again after a transfer, not merely being ready at reset), bit2 OE (RX
// overrun, see above), bit3 PERR (protocol error, see above), bit4 TO
// (timeout, see above). irq is the OR of (ISR & IER). ISR bits are
// cleared by writing 1 to them (write-1-to-clear); writing 0 to a bit
// leaves it unchanged.
//
// SPI_WDT: a 32-bit threshold, in clk cycles, for how long the core may
// stay busy before TO fires; 0 (the reset default) disables the
// watchdog entirely, so it is silent unless a host explicitly opts in.
// The counter runs only while busy and resets to 0 the moment busy
// deasserts, so it measures one transfer's duration, not cumulative busy
// time. Deliberately not shadow-latched like cfg_cpol/cfg_cpha/etc: the
// watchdog is a monitoring function, not part of the SPI protocol
// itself, so there is no correctness reason to defer a threshold change
// until idle -- unlike changing the SPI mode mid-transfer, changing how
// long is "too long" mid-transfer can't corrupt any bits in flight.
// Sizing this as a fixed-width counter matching some particular
// DATA_WIDTH/CLK_DIV_WIDTH combination would be wrong in general: with
// CLK_DIV_WIDTH=16, a single legitimate transfer can already take
// roughly 16*(cfg_clk_div+1) cycles, i.e. beyond a 16-bit counter's own
// range at large cfg_clk_div values, which is why the threshold is a
// full 32-bit host-supplied value rather than a fixed internal constant.
//
// Bus protocol: standard APB 2-phase transfer. A transaction opens in the
// SETUP phase (PSEL asserted, PENABLE low, PADDR/PWDATA/PWRITE already
// valid) and moves to the ACCESS phase one PCLK later (PENABLE asserted,
// PADDR/PWDATA/PWRITE held stable). This slave is zero-wait-state --
// every register responds within the single ACCESS cycle -- so PREADY is
// tied permanently high; a master is not required to insert extra ACCESS
// cycles waiting for it, but must still drive the SETUP->ACCESS sequence
// exactly as any APB slave requires. PRDATA is a continuous combinational
// mux of whichever register PADDR currently selects, valid throughout
// both SETUP and ACCESS (not just once PENABLE asserts), which is more
// than APB requires but never hurts. PSLVERR mirrors this cycle's PERR
// condition (see "Error handling" below) so a bus-level error monitor
// can see a bad access without needing to decode SPI_ISR at all; it is
// only ever asserted during an ACCESS phase (PSEL && PENABLE), the only
// cycle APB defines it to be meaningful. Writes take effect synchronously
// on the PCLK edge that ends the ACCESS phase, as any register write
// would.
module spi_reg_top #(
    parameter bit MASTER_MODE    = 1,
    parameter int DATA_WIDTH     = 8,
    parameter int CLK_DIV_WIDTH  = 16
) (
    input  logic        PCLK,
    input  logic        PRESETn,

    input  logic        PSEL,
    input  logic        PENABLE,
    input  logic        PWRITE,
    input  logic [4:0]  PADDR,
    // verilator lint_off UNUSEDSIGNAL
    // No register in this map has meaningful content above bit 8
    // (SPI_CFG's DATA_BITS field, bits [8:3], is the widest field used),
    // so PWDATA's upper bits are genuinely never read -- conventional
    // for reserved/unimplemented bits of a 32-bit register write.
    input  logic [31:0] PWDATA,
    // verilator lint_on UNUSEDSIGNAL
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,

    output logic         irq,

    inout  wire          ss_n,
    inout  wire          sclk,
    inout  wire          mosi,
    inout  wire          miso
);

    // Asserted for exactly the one ACCESS-phase PCLK cycle a given
    // transfer occupies (PSEL && PENABLE, zero wait states), matching
    // this module's previous plain reg_write/reg_read strobe semantics
    // one-for-one -- every always_ff/assign below that used to key off
    // reg_write/reg_read now keys off apb_write/apb_read instead, with no
    // other change to when a register actually latches.
    logic apb_write;
    logic apb_read;
    assign apb_write = PSEL && PENABLE && PWRITE;
    assign apb_read  = PSEL && PENABLE && !PWRITE;

    // This register map's SPI_DR is a fixed 32-bit word; DATA_WIDTH must
    // fit within it for a whole transfer's worth of data to be
    // read/written through a single register access.
    // verilator lint_off INITIALDLY
    initial begin
        assert (DATA_WIDTH <= 32)
            else $fatal(1, "spi_reg_top: DATA_WIDTH=%0d exceeds the 32-bit SPI_DR register", DATA_WIDTH);
    end
    // verilator lint_on INITIALDLY

    localparam logic [4:0] ADDR_CR    = 5'h00;
    localparam logic [4:0] ADDR_SR    = 5'h04;
    localparam logic [4:0] ADDR_DR    = 5'h08;
    localparam logic [4:0] ADDR_CKDIV = 5'h0C;
    localparam logic [4:0] ADDR_CFG   = 5'h10;
    localparam logic [4:0] ADDR_IER   = 5'h14;
    localparam logic [4:0] ADDR_ISR   = 5'h18;
    localparam logic [4:0] ADDR_WDT   = 5'h1C;

    logic core_rst_n;

    logic [1:0]             cr_reg;
    logic [DATA_WIDTH-1:0]  tx_data_reg;
    logic [DATA_WIDTH-1:0]  rx_data_reg;
    logic                   done_latch;
    logic [CLK_DIV_WIDTH-1:0] ckdiv_reg;
    logic                   cpol_reg;
    logic                   cpha_reg;
    logic                   lsb_first_reg;
    logic [5:0]             data_bits_reg;
    logic [4:0]             ier_reg;
    logic [4:0]             isr_reg;
    logic [31:0]            wdt_threshold_reg;
    logic [31:0]            wdt_cnt;

    // addr_valid covers every register this map defines; any other
    // address reaching a read or write is a protocol error (see below).
    logic addr_valid;
    assign addr_valid = (PADDR == ADDR_CR)    || (PADDR == ADDR_SR) ||
                         (PADDR == ADDR_DR)    || (PADDR == ADDR_CKDIV) ||
                         (PADDR == ADDR_CFG)   || (PADDR == ADDR_IER) ||
                         (PADDR == ADDR_ISR)   || (PADDR == ADDR_WDT);

    logic invalid_addr_err;
    logic write_ro_err;
    logic start_while_busy_err;
    logic invalid_data_bits_err;
    logic perr_event;
    logic oe_event;
    assign invalid_addr_err    = (apb_read || apb_write) && !addr_valid;
    assign write_ro_err        = apb_write && (PADDR == ADDR_SR);
    assign start_while_busy_err = apb_write && (PADDR == ADDR_CR) &&
                                   PWDATA[0] && core_busy;
    // DATA_BITS=0 is the valid "use full DATA_WIDTH" sentinel (see SPI_CFG
    // doc above); only a value strictly greater than DATA_WIDTH is invalid.
    assign invalid_data_bits_err = apb_write && (PADDR == ADDR_CFG) &&
                                    (32'(PWDATA[8:3]) > 32'(DATA_WIDTH));
    assign perr_event = invalid_addr_err || write_ro_err ||
                         start_while_busy_err || invalid_data_bits_err;
    // Checked at the START write, not at the following rx_valid: START
    // itself clears done_latch (a fresh transfer invalidates any stale
    // result), so by the time the new transfer's rx_valid arrives,
    // done_latch has already been cleared by this same START and the
    // "was there unread data" moment has already passed. done_latch here
    // is its current (pre-this-edge) value -- was a previous result
    // still unread at the exact moment this new START discards it.
    assign oe_event = apb_write && (PADDR == ADDR_CR) && PWDATA[0] && done_latch;

    // wdt_threshold_reg == 0 means "disabled" (the reset default), never
    // firing regardless of how long busy stays asserted.
    //
    // timeout_raw is a level (true for the whole rest of the busy period
    // once crossed, not just the crossing cycle) so a threshold lowered
    // mid-transfer is still caught on whatever cycle newly qualifies,
    // rather than only at the original crossing point. timeout_event
    // itself is gated to fire only once per busy period (via
    // timeout_already_fired, cleared when busy deasserts): without that
    // gate, W1C-clearing SPI_ISR.TO while the transfer is still busy and
    // still over threshold would be immediately overridden by this same
    // level condition re-setting it the very next cycle, making the bit
    // un-clearable while the condition persists -- the same one-pulse-
    // per-event shape as oe_event/perr_event above, just derived from a
    // level condition instead of a single-cycle write.
    logic timeout_raw;
    assign timeout_raw = core_busy && (wdt_threshold_reg != 32'd0) &&
                          (wdt_cnt >= wdt_threshold_reg);

    logic timeout_already_fired;
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) timeout_already_fired <= 1'b0;
        else if (!core_busy) timeout_already_fired <= 1'b0;
        else if (timeout_raw) timeout_already_fired <= 1'b1;
    end

    logic timeout_event;
    assign timeout_event = timeout_raw && !timeout_already_fired;

    logic [DATA_WIDTH-1:0] core_rx_data;
    logic                  core_rx_valid;
    logic                  core_tx_ready;
    logic                  core_busy;

    // SPI_CR is self-clearing: a write is captured for exactly one cycle
    // (the pulse spi_master's tx_valid / the reset gate below consume),
    // then decays back to 0 unless a fresh write lands the very next
    // cycle. This is simpler than a separate one-shot pulse generator
    // and gives software the same observable behavior (read CR shortly
    // after writing it and see 0) as a real self-clearing control bit.
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) cr_reg <= 2'b00;
        else if (apb_write && PADDR == ADDR_CR) cr_reg <= PWDATA[1:0];
        else cr_reg <= 2'b00;
    end

    // Soft reset is ORed into the wrapped core's own reset rather than
    // handled as separate logic in this module: cr_reg[1]'s one-cycle
    // pulse is exactly a one-cycle-wide async-active-low reset event,
    // which spi_master/spi_slave's own `always_ff @(posedge clk or
    // negedge rst_n)` blocks (their ports, unrelated to this module's
    // PCLK/PRESETn) already handle correctly (proven by
    // tb_spi_loopback.sv's mid-transfer reset test).
    assign core_rst_n = PRESETn & ~cr_reg[1];

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            tx_data_reg <= '0;
        end else if (apb_write && PADDR == ADDR_DR) begin
            tx_data_reg <= PWDATA[DATA_WIDTH-1:0];
        end
    end

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            rx_data_reg <= '0;
        end else if (core_rx_valid) begin
            rx_data_reg <= core_rx_data;
        end
    end

    // A fresh rx_valid pulse always wins over either clear condition
    // landing on the same cycle, so a result is never silently dropped
    // in favor of a stale clear from an overlapping DR read or new START.
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            done_latch <= 1'b0;
        end else if (core_rx_valid) begin
            done_latch <= 1'b1;
        end else if ((apb_read && PADDR == ADDR_DR) ||
                     (apb_write && PADDR == ADDR_CR && PWDATA[0])) begin
            done_latch <= 1'b0;
        end
    end

    // cfg_wr_en is tied high permanently: the write gate visible to
    // software is this module's own register-write decode (host must
    // write SPI_CKDIV/SPI_CFG to change anything), and spi_master/
    // spi_slave's own shadow-register-plus-transfer-start-latch
    // mechanism (see docs/README.md) already correctly defers a write
    // landing mid-transfer until the core goes idle -- there is no need
    // to duplicate that write-gating/timing logic here.
    logic cfg_wr_en_tied;
    assign cfg_wr_en_tied = 1'b1;

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            ckdiv_reg         <= '0;
            cpol_reg          <= 1'b0;
            cpha_reg          <= 1'b0;
            lsb_first_reg     <= 1'b0;
            data_bits_reg     <= '0;
            wdt_threshold_reg <= 32'd0;
        end else begin
            if (apb_write && PADDR == ADDR_CKDIV)
                ckdiv_reg <= PWDATA[CLK_DIV_WIDTH-1:0];
            // Rejected in full (see invalid_data_bits_err above) rather
            // than applying MODE/BIT_ORDER while dropping only DATA_BITS:
            // a single write is either wholly valid or wholly a no-op.
            if (apb_write && PADDR == ADDR_CFG && 32'(PWDATA[8:3]) <= 32'(DATA_WIDTH)) begin
                cpha_reg      <= PWDATA[0];
                cpol_reg      <= PWDATA[1];
                lsb_first_reg <= PWDATA[2];
                data_bits_reg <= PWDATA[8:3];
            end
            if (apb_write && PADDR == ADDR_WDT)
                wdt_threshold_reg <= PWDATA;
        end
    end

    // Runs only while busy, resetting to 0 the instant busy deasserts, so
    // this measures a single transfer's duration rather than accumulating
    // across transfers or idle time. Saturates at all-1s rather than
    // wrapping, so an absurdly long busy period (which should never
    // legitimately happen) can't wrap back under threshold and silently
    // suppress the timeout it should have triggered.
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            wdt_cnt <= '0;
        end else if (!core_busy) begin
            wdt_cnt <= '0;
        end else if (wdt_cnt != 32'hFFFF_FFFF) begin
            wdt_cnt <= wdt_cnt + 1'b1;
        end
    end

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) ier_reg <= 5'b00000;
        else if (apb_write && PADDR == ADDR_IER) ier_reg <= PWDATA[4:0];
    end

    // Edge-detected (not level) so TX_READY only fires on the core
    // becoming ready again after a transfer, not merely on being ready
    // at reset / continuously while idle.
    logic core_tx_ready_d;
    logic tx_ready_rising;
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) core_tx_ready_d <= 1'b1;
        else core_tx_ready_d <= core_tx_ready;
    end
    assign tx_ready_rising = core_tx_ready & ~core_tx_ready_d;

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            isr_reg <= 5'b00000;
        end else begin
            if (core_rx_valid) isr_reg[0] <= 1'b1;
            else if (apb_write && PADDR == ADDR_ISR && PWDATA[0]) isr_reg[0] <= 1'b0;

            if (tx_ready_rising) isr_reg[1] <= 1'b1;
            else if (apb_write && PADDR == ADDR_ISR && PWDATA[1]) isr_reg[1] <= 1'b0;

            if (oe_event) isr_reg[2] <= 1'b1;
            else if (apb_write && PADDR == ADDR_ISR && PWDATA[2]) isr_reg[2] <= 1'b0;

            if (perr_event) isr_reg[3] <= 1'b1;
            else if (apb_write && PADDR == ADDR_ISR && PWDATA[3]) isr_reg[3] <= 1'b0;

            if (timeout_event) isr_reg[4] <= 1'b1;
            else if (apb_write && PADDR == ADDR_ISR && PWDATA[4]) isr_reg[4] <= 1'b0;
        end
    end

    assign irq = |(isr_reg & ier_reg);

    // data_bits_reg==0 is the "use full DATA_WIDTH" sentinel (reset
    // default, and the only value ever seen by software that never
    // touches SPI_CFG.DATA_BITS at all); otherwise it is a validated
    // (invalid_data_bits_err above rejects anything larger) 1..DATA_WIDTH
    // runtime word length passed straight through to the core.
    logic [$clog2(DATA_WIDTH+1)-1:0] cfg_data_width_eff;
    assign cfg_data_width_eff = (data_bits_reg == 6'd0) ?
                                 $clog2(DATA_WIDTH+1)'(DATA_WIDTH) :
                                 $clog2(DATA_WIDTH+1)'(data_bits_reg);

    // Computed outside the case's RHS expressions rather than inline
    // (e.g. `|isr_reg[4:2]`) since iverilog does not support a constant
    // part-select appearing directly inside an always_comb case item.
    logic err_bit;
    assign err_bit = isr_reg[2] | isr_reg[3] | isr_reg[4];

    always_comb begin
        case (PADDR)
            ADDR_CR:    PRDATA = {30'b0, cr_reg};
            ADDR_SR:    PRDATA = {26'b0, err_bit, core_busy, done_latch, core_tx_ready, done_latch, core_busy};
            ADDR_DR:    PRDATA = {{(32 - DATA_WIDTH){1'b0}}, rx_data_reg};
            ADDR_CKDIV: PRDATA = {{(32 - CLK_DIV_WIDTH){1'b0}}, ckdiv_reg};
            ADDR_CFG:   PRDATA = {23'b0, data_bits_reg, lsb_first_reg, cpol_reg, cpha_reg};
            ADDR_IER:   PRDATA = {27'b0, ier_reg};
            ADDR_ISR:   PRDATA = {27'b0, isr_reg};
            ADDR_WDT:   PRDATA = wdt_threshold_reg;
            default:    PRDATA = 32'h0;
        endcase
    end

    // Zero-wait-state slave: every register above responds within the
    // single ACCESS cycle it's addressed in, so PREADY is simply tied
    // high rather than computed. PSLVERR mirrors perr_event directly --
    // that signal is already 0 outside an actual apb_read/apb_write
    // access (every term feeding it requires one), so no extra gating on
    // PSEL/PENABLE is needed here.
    assign PREADY  = 1'b1;
    assign PSLVERR = perr_event;

    spi_top #(
        .MASTER_MODE   (MASTER_MODE),
        .DATA_WIDTH    (DATA_WIDTH),
        .CLK_DIV_WIDTH (CLK_DIV_WIDTH)
    ) u_core (
        .clk          (PCLK),
        .rst_n        (core_rst_n),
        .cfg_wr_en    (cfg_wr_en_tied),
        .cfg_cpol     (cpol_reg),
        .cfg_cpha     (cpha_reg),
        .cfg_lsb_first(lsb_first_reg),
        .cfg_clk_div  (ckdiv_reg),
        .cfg_data_width(cfg_data_width_eff),
        .tx_data      (tx_data_reg),
        .tx_valid     (cr_reg[0]),
        .tx_ready     (core_tx_ready),
        .rx_data      (core_rx_data),
        .rx_valid     (core_rx_valid),
        .busy         (core_busy),
        .ss_n         (ss_n),
        .sclk         (sclk),
        .mosi         (mosi),
        .miso         (miso)
    );

endmodule
