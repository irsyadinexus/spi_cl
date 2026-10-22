`timescale 1ns / 1ps

// Self-checking testbench for spi_reg_top: drives the register bus the
// way a host CPU would (program SPI_CFG/SPI_CKDIV, load SPI_DR, strike
// SPI_CR.START, poll/interrupt-wait on SPI_SR/SPI_ISR, read SPI_DR back)
// against a plain spi_top slave, reusing the same sticky-latch pattern
// tb_spi_loopback.sv uses to observe the slave's clk_s-domain rx_valid
// pulse from this testbench's clk_m-domain checker.
module tb_spi_reg_top #(
    parameter int DATA_WIDTH = 8
) ();

    localparam int CLK_DIV_WIDTH = 16;

`ifdef VERILATOR
    localparam string VCD_PATH = "../waves/verilator_reg_top.vcd";
`else
    localparam string VCD_PATH = "../waves/iverilog_reg_top.vcd";
`endif

    localparam logic [4:0] ADDR_CR    = 5'h00;
    localparam logic [4:0] ADDR_SR    = 5'h04;
    localparam logic [4:0] ADDR_DR    = 5'h08;
    localparam logic [4:0] ADDR_CKDIV = 5'h0C;
    localparam logic [4:0] ADDR_CFG   = 5'h10;
    localparam logic [4:0] ADDR_IER   = 5'h14;
    localparam logic [4:0] ADDR_ISR   = 5'h18;
    localparam logic [4:0] ADDR_WDT   = 5'h1C;

    // verilator lint_off BLKSEQ
    logic clk_m;
    logic clk_s;
    logic rst_n_m;
    logic rst_n_s;

    initial clk_m = 1'b0;
    always #5 clk_m = ~clk_m;

    initial clk_s = 1'b0;
    always #2 clk_s = ~clk_s;
    // verilator lint_on BLKSEQ

    logic [4:0]  PADDR;
    logic [31:0] PWDATA;
    logic        PSEL;
    logic        PENABLE;
    logic        PWRITE;
    logic [31:0] PRDATA;
    logic        PREADY;
    logic        PSLVERR;
    logic        irq;

    wire ss_n_w;
    wire sclk_w;
    wire mosi_w;
    wire miso_w;

    spi_reg_top #(
        .MASTER_MODE   (1),
        .DATA_WIDTH    (DATA_WIDTH),
        .CLK_DIV_WIDTH (CLK_DIV_WIDTH)
    ) u_master (
        .PCLK      (clk_m),
        .PRESETn   (rst_n_m),
        .PSEL      (PSEL),
        .PENABLE   (PENABLE),
        .PWRITE    (PWRITE),
        .PADDR     (PADDR),
        .PWDATA    (PWDATA),
        .PRDATA    (PRDATA),
        .PREADY    (PREADY),
        .PSLVERR   (PSLVERR),
        .irq       (irq),
        .ss_n      (ss_n_w),
        .sclk      (sclk_w),
        .mosi      (mosi_w),
        .miso      (miso_w)
    );

    logic [DATA_WIDTH-1:0] s_tx_data;
    // verilator lint_off UNUSEDSIGNAL
    logic                  s_tx_ready;
    logic                  s_busy;
    // verilator lint_on UNUSEDSIGNAL
    logic [DATA_WIDTH-1:0] s_rx_data;
    logic                  s_rx_valid;

    spi_top #(
        .MASTER_MODE   (0),
        .DATA_WIDTH    (DATA_WIDTH),
        .CLK_DIV_WIDTH (CLK_DIV_WIDTH)
    ) u_slave (
        .clk          (clk_s),
        .rst_n        (rst_n_s),
        .cfg_wr_en    (1'b1),
        .cfg_cpol     (cfg_cpol_mirror),
        .cfg_cpha     (cfg_cpha_mirror),
        .cfg_lsb_first(cfg_lsb_mirror),
        .cfg_clk_div  ('0),
        .cfg_data_width(cfg_data_width_mirror),
        .tx_data      (s_tx_data),
        .tx_valid     (1'b1),
        .tx_ready     (s_tx_ready),
        .rx_data      (s_rx_data),
        .rx_valid     (s_rx_valid),
        .busy         (s_busy),
        .ss_n         (ss_n_w),
        .sclk         (sclk_w),
        .mosi         (mosi_w),
        .miso         (miso_w)
    );

    // The slave in this testbench is a plain spi_top, not a register-
    // interface instance, so its mode config is driven directly by the
    // testbench mirroring whatever was last programmed into the
    // master's SPI_CFG register -- there is no register bus on the
    // slave side to program independently.
    logic cfg_cpol_mirror, cfg_cpha_mirror, cfg_lsb_mirror;
    logic [$clog2(DATA_WIDTH+1)-1:0] cfg_data_width_mirror;

    logic                  s_rx_valid_sticky;
    logic [DATA_WIDTH-1:0] s_rx_data_sticky;
    logic                  s_rx_ack;

    always_ff @(posedge clk_s or negedge rst_n_s) begin
        if (!rst_n_s) begin
            s_rx_valid_sticky <= 1'b0;
            s_rx_data_sticky  <= '0;
        end else begin
            if (s_rx_valid) begin
                s_rx_valid_sticky <= 1'b1;
                s_rx_data_sticky  <= s_rx_data;
            end else if (s_rx_ack) begin
                s_rx_valid_sticky <= 1'b0;
            end
        end
    end

    int unsigned seed = 32'hFACADE;
    int errors;
    int checks;

    // Captured by reg_write_task/reg_read_task at the exact ACCESS-phase
    // cycle PREADY is sampled -- the only cycle PSLVERR is meaningful --
    // since PSEL/PENABLE (and so PSLVERR) fall back to 0 the moment
    // either task returns, too late for a caller to sample directly.
    logic last_pslverr;

    // verilator lint_off INITIALDLY
    // Standard APB 2-phase driver: SETUP (PSEL asserted, PENABLE low,
    // PADDR/PWDATA/PWRITE already valid) for one PCLK, then ACCESS
    // (PENABLE raised, address/data/write held stable) until PREADY is
    // sampled high at a clock edge -- a plain while-loop rather than a
    // fixed cycle count, so this driver stays correct even if
    // spi_reg_top ever stopped being zero-wait-state and actually held
    // PREADY low for a cycle or two.
    task automatic reg_write_task(input logic [4:0] addr, input logic [31:0] data);
        begin
            @(posedge clk_m);
            PADDR   <= addr;
            PWDATA  <= data;
            PWRITE  <= 1'b1;
            PSEL    <= 1'b1;
            PENABLE <= 1'b0;

            @(posedge clk_m);
            PENABLE <= 1'b1;

            @(posedge clk_m);
            // spi_reg_top is zero-wait-state, so this loop never actually
            // iterates -- PREADY is already 1 the first time it's
            // sampled -- but a plain while rather than a single check
            // keeps this driver correct even if that ever changes.
            while (PREADY !== 1'b1) @(posedge clk_m);
            checks = checks + 1;
            last_pslverr = PSLVERR;

            PSEL    <= 1'b0;
            PENABLE <= 1'b0;
            PWRITE  <= 1'b0;
        end
    endtask

    task automatic reg_read_task(input logic [4:0] addr, output logic [31:0] data);
        begin
            @(posedge clk_m);
            PADDR   <= addr;
            PWRITE  <= 1'b0;
            PSEL    <= 1'b1;
            PENABLE <= 1'b0;

            @(posedge clk_m);
            PENABLE <= 1'b1;

            @(posedge clk_m);
            while (PREADY !== 1'b1) @(posedge clk_m);
            checks = checks + 1;
            data = PRDATA;
            last_pslverr = PSLVERR;

            PSEL    <= 1'b0;
            PENABLE <= 1'b0;
        end
    endtask
    // verilator lint_on INITIALDLY

    task automatic check_eq(input logic [31:0] got, input logic [31:0] expected,
                             input string what);
        begin
            checks = checks + 1;
            if (got !== expected) begin
                errors = errors + 1;
                $display("[%0t] FAIL %s: expected=%0h got=%0h", $time, what, expected, got);
            end
        end
    endtask

    // verilator lint_off INITIALDLY
    // Drives one full transfer through the register interface: load
    // SPI_DR, strike SPI_CR.START, wait for SPI_SR.DONE, read SPI_DR
    // back. Checks both the master's received word (via the register
    // bus) and the slave's received word (via its own plain rx_data),
    // matching tb_spi_loopback.sv's full-duplex checking rigor but
    // driven entirely through registers on the master side.
    task automatic do_reg_transfer(input logic [DATA_WIDTH-1:0] m_word,
                                    input logic [DATA_WIDTH-1:0] s_word);
        logic [31:0] rdata;
        int wait_cycles;
        begin
            s_tx_data <= s_word;
            reg_write_task(ADDR_DR, {{(32 - DATA_WIDTH){1'b0}}, m_word});
            reg_write_task(ADDR_CR, 32'h1);

            wait_cycles = 0;
            reg_read_task(ADDR_SR, rdata);
            while (!rdata[1] && wait_cycles < 200000) begin
                reg_read_task(ADDR_SR, rdata);
                wait_cycles = wait_cycles + 1;
            end
            checks = checks + 1;
            if (wait_cycles >= 200000) begin
                errors = errors + 1;
                $display("[%0t] FAIL timeout waiting for SPI_SR.DONE", $time);
            end

            check_eq(32'(rdata[0]), 32'(1'b0), "SPI_SR.BUSY after DONE");
            check_eq(32'(rdata[2]), 32'(1'b1), "SPI_SR.TX_READY after DONE");
            check_eq(32'(rdata[3]), 32'(1'b1), "SPI_SR.RX_VALID after DONE");

            reg_read_task(ADDR_DR, rdata);
            check_eq(rdata, {{(32 - DATA_WIDTH){1'b0}}, s_word}, "SPI_DR (master rx)");

            reg_read_task(ADDR_SR, rdata);
            check_eq(32'(rdata[1]), 32'(1'b0), "SPI_SR.DONE cleared after SPI_DR read");
            check_eq(32'(rdata[3]), 32'(1'b0), "SPI_SR.RX_VALID cleared after SPI_DR read");

            wait_cycles = 0;
            while (!s_rx_valid_sticky && wait_cycles < 1000) begin
                @(posedge clk_m);
                wait_cycles = wait_cycles + 1;
            end
            checks = checks + 1;
            if (s_rx_valid_sticky) begin
                if (s_rx_data_sticky !== m_word) begin
                    errors = errors + 1;
                    $display("[%0t] FAIL slave rx: expected=%0h got=%0h", $time, m_word, s_rx_data_sticky);
                end
            end else begin
                errors = errors + 1;
                $display("[%0t] FAIL slave never reported rx_valid", $time);
            end
            s_rx_ack <= 1'b1;
            @(posedge clk_m);
            s_rx_ack <= 1'b0;
            @(posedge clk_m);
        end
    endtask
    // verilator lint_on INITIALDLY

    task automatic run_mode_config(input int cpol_i, input int cpha_i, input int lsb_i);
        int i;
        logic [DATA_WIDTH-1:0] rnd_m, rnd_s;
        begin
            cfg_cpol_mirror = cpol_i[0];
            cfg_cpha_mirror = cpha_i[0];
            cfg_lsb_mirror  = lsb_i[0];
            cfg_data_width_mirror = $clog2(DATA_WIDTH+1)'(DATA_WIDTH);

            reg_write_task(ADDR_CFG, {23'b0, 6'd8, lsb_i[0:0], cpol_i[0:0], cpha_i[0:0]});
            reg_write_task(ADDR_CKDIV, 32'd1);
            repeat (3) @(posedge clk_m);

            do_reg_transfer('0, '1);
            do_reg_transfer('1, '0);
            for (i = 0; i < 5; i = i + 1) begin
                // verilator lint_off WIDTHTRUNC
                rnd_m = $urandom(seed);
                rnd_s = $urandom(seed);
                // verilator lint_on WIDTHTRUNC
                do_reg_transfer(rnd_m, rnd_s);
            end

            $display("Reg-if mode cpol=%0d cpha=%0d lsb=%0d done. checks=%0d errors=%0d",
                      cpol_i, cpha_i, lsb_i, checks, errors);
        end
    endtask

    // verilator lint_off UNUSEDSIGNAL
    // Only specific bits of rdata are checked per read here (the ones
    // relevant to this test), not the whole register.
    task automatic run_isr_ier_test;
        logic [31:0] rdata;
        int wait_cycles;
        begin
            reg_write_task(ADDR_IER, 32'h0);
            reg_write_task(ADDR_ISR, 32'h3);
            // irq is a continuous assign off isr_reg/ier_reg, both of
            // which reg_write_task's own write only just updated via a
            // nonblocking assignment on the clock edge it returns on;
            // reading irq in the same active-region time slice (i.e.
            // before that edge's NBA region has settled) would see the
            // pre-write value, not a real RTL bug -- #1 lets it settle.
            #1;
            check_eq(32'(irq), 32'(1'b0), "irq low with IER=0 even if ISR set");

            reg_write_task(ADDR_IER, 32'h1);
            s_tx_data = '0;
            reg_write_task(ADDR_DR, '1);
            reg_write_task(ADDR_CR, 32'h1);

            wait_cycles = 0;
            while (!irq && wait_cycles < 200000) begin
                @(posedge clk_m);
                wait_cycles = wait_cycles + 1;
            end
            checks = checks + 1;
            if (wait_cycles >= 200000) begin
                errors = errors + 1;
                $display("[%0t] FAIL irq never asserted with IER.DONE_IE=1", $time);
            end

            reg_read_task(ADDR_ISR, rdata);
            check_eq(32'(rdata[0]), 32'(1'b1), "SPI_ISR.DONE set while irq asserted");

            reg_write_task(ADDR_ISR, 32'h1);
            #1;
            check_eq(32'(irq), 32'(1'b0), "irq deasserted after W1C of SPI_ISR.DONE");

            reg_read_task(ADDR_ISR, rdata);
            check_eq(32'(rdata[0]), 32'(1'b0), "SPI_ISR.DONE cleared after W1C");

            reg_write_task(ADDR_IER, 32'h0);
            reg_read_task(ADDR_DR, rdata);

            $display("ISR/IER test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask
    // verilator lint_on UNUSEDSIGNAL

    task automatic run_cr_self_clear_test;
        logic [31:0] rdata;
        begin
            reg_write_task(ADDR_CR, 32'h3);
            reg_read_task(ADDR_CR, rdata);
            check_eq(rdata, 32'h0, "SPI_CR reads back 0 the cycle after a write (self-clearing)");

            $display("CR self-clear test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask

    // verilator lint_off UNUSEDSIGNAL
    // Only specific bits of rdata are checked per read here.
    task automatic run_soft_reset_test;
        logic [31:0] rdata;
        begin
            s_tx_data = '0;
            reg_write_task(ADDR_DR, '1);
            reg_write_task(ADDR_CR, 32'h1);
            repeat (3) @(posedge clk_m);

            reg_read_task(ADDR_SR, rdata);
            checks = checks + 1;
            if (!rdata[0]) begin
                errors = errors + 1;
                $display("[%0t] FAIL soft-reset test setup: not busy before soft reset", $time);
            end

            reg_write_task(ADDR_CR, 32'h2);
            repeat (5) @(posedge clk_m);

            reg_read_task(ADDR_SR, rdata);
            check_eq(32'(rdata[0]), 32'(1'b0), "SPI_SR.BUSY 0 after soft_reset");
            check_eq(32'(rdata[2]), 32'(1'b1), "SPI_SR.TX_READY 1 after soft_reset");
            checks = checks + 1;
            if (ss_n_w !== 1'b1) begin
                errors = errors + 1;
                $display("[%0t] FAIL ss_n_w=%0b after soft_reset, expected 1 (deasserted)", $time, ss_n_w);
            end

            // Confirm the core is genuinely usable again, not merely
            // idle-looking, by running a normal transfer afterward.
            do_reg_transfer(DATA_WIDTH'(8'h5A), DATA_WIDTH'(8'hA5));

            $display("Soft-reset test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask
    // verilator lint_on UNUSEDSIGNAL

    // Covers the three PERR conditions (invalid address, write to the
    // read-only SPI_SR, START while busy), the OE (RX overrun) condition,
    // and SPI_SR.ERR mirroring ISR's error bits. None of these are
    // exercised by the mode sweep or the CR/ISR/soft-reset tests above,
    // since those only ever hit valid addresses, only write SPI_CR while
    // idle, and always read SPI_DR promptly after each transfer.
    // verilator lint_off UNUSEDSIGNAL
    task automatic run_error_handling_test;
        logic [31:0] rdata;
        int wait_cycles;
        localparam logic [4:0] ADDR_INVALID = 5'h1D;
        begin
            reg_write_task(ADDR_IER, 32'h0);
            check_eq(32'(last_pslverr), 32'(1'b0), "PSLVERR stays low on a normal, valid write");
            reg_write_task(ADDR_ISR, 32'hF);
            check_eq(32'(last_pslverr), 32'(1'b0), "PSLVERR stays low on a normal, valid write");

            reg_read_task(ADDR_INVALID, rdata);
            check_eq(rdata, 32'h0, "read from an unmapped address returns 0");
            check_eq(32'(last_pslverr), 32'(1'b1), "PSLVERR set during the unmapped-address read's own ACCESS cycle");
            reg_read_task(ADDR_ISR, rdata);
            check_eq(32'(rdata[3]), 32'(1'b1), "SPI_ISR.PERR set after an unmapped-address read");
            reg_write_task(ADDR_ISR, 32'h8);

            reg_write_task(ADDR_INVALID, 32'hDEAD_BEEF);
            check_eq(32'(last_pslverr), 32'(1'b1), "PSLVERR set during the unmapped-address write's own ACCESS cycle");
            reg_read_task(ADDR_ISR, rdata);
            check_eq(32'(rdata[3]), 32'(1'b1), "SPI_ISR.PERR set after an unmapped-address write");
            reg_write_task(ADDR_ISR, 32'h8);

            reg_write_task(ADDR_SR, 32'hFFFF_FFFF);
            check_eq(32'(last_pslverr), 32'(1'b1), "PSLVERR set during the read-only-SPI_SR write's own ACCESS cycle");
            reg_read_task(ADDR_ISR, rdata);
            check_eq(32'(rdata[3]), 32'(1'b1), "SPI_ISR.PERR set after a write to read-only SPI_SR");
            reg_read_task(ADDR_SR, rdata);
            check_eq(32'(rdata[2]), 32'(1'b1), "SPI_SR.TX_READY unaffected by the bogus write above");
            reg_write_task(ADDR_ISR, 32'h8);

            s_tx_data = '0;
            reg_write_task(ADDR_DR, '1);
            reg_write_task(ADDR_CR, 32'h1);
            reg_read_task(ADDR_SR, rdata);
            checks = checks + 1;
            if (!rdata[0]) begin
                errors = errors + 1;
                $display("[%0t] FAIL start-while-busy test setup: not busy right after START", $time);
            end
            reg_write_task(ADDR_CR, 32'h1);
            check_eq(32'(last_pslverr), 32'(1'b1), "PSLVERR set during the start-while-busy write's own ACCESS cycle");
            reg_read_task(ADDR_ISR, rdata);
            check_eq(32'(rdata[3]), 32'(1'b1), "SPI_ISR.PERR set after START while already busy");
            reg_write_task(ADDR_ISR, 32'h8);

            wait_cycles = 0;
            reg_read_task(ADDR_SR, rdata);
            while (!rdata[1] && wait_cycles < 200000) begin
                reg_read_task(ADDR_SR, rdata);
                wait_cycles = wait_cycles + 1;
            end
            reg_read_task(ADDR_DR, rdata);

            s_tx_data = '0;
            reg_write_task(ADDR_DR, '1);
            reg_write_task(ADDR_CR, 32'h1);
            wait_cycles = 0;
            reg_read_task(ADDR_SR, rdata);
            while (!rdata[1] && wait_cycles < 200000) begin
                reg_read_task(ADDR_SR, rdata);
                wait_cycles = wait_cycles + 1;
            end
            // Deliberately not reading SPI_DR here: the next START should
            // find DONE still set (from the transfer just completed
            // above) and flag an overrun right at that START write --
            // not at the new transfer's own completion, since START
            // itself clears DONE/RX_VALID before the new transfer can
            // finish and pulse rx_valid.
            s_tx_data = '0;
            reg_write_task(ADDR_DR, '1);
            reg_write_task(ADDR_CR, 32'h1);
            reg_read_task(ADDR_ISR, rdata);
            check_eq(32'(rdata[2]), 32'(1'b1), "SPI_ISR.OE set after START while the previous result was still unread");
            reg_write_task(ADDR_ISR, 32'h4);

            wait_cycles = 0;
            reg_read_task(ADDR_SR, rdata);
            while (!rdata[1] && wait_cycles < 200000) begin
                reg_read_task(ADDR_SR, rdata);
                wait_cycles = wait_cycles + 1;
            end
            reg_read_task(ADDR_DR, rdata);

            reg_write_task(ADDR_ISR, 32'hF);
            reg_read_task(ADDR_SR, rdata);
            check_eq(32'(rdata[5]), 32'(1'b0), "SPI_SR.ERR clear once every ISR error bit is cleared");
            reg_write_task(ADDR_INVALID, 32'h0);
            reg_read_task(ADDR_SR, rdata);
            check_eq(32'(rdata[5]), 32'(1'b1), "SPI_SR.ERR set while SPI_ISR.PERR is pending");
            reg_write_task(ADDR_ISR, 32'h8);

            $display("Error-handling test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask
    // verilator lint_on UNUSEDSIGNAL

    // Covers SPI_WDT/the TO error bit, none of which the tests above touch
    // (they all leave SPI_WDT at its reset-default 0/disabled). Runs at
    // the mode-0 config already active from run_error_handling_test, so
    // cfg_*_mirror needs no changes here.
    // verilator lint_off UNUSEDSIGNAL
    task automatic run_watchdog_test;
        logic [31:0] rdata;
        int wait_cycles;
        begin
            // Baseline: disabled (SPI_WDT=0, the reset default) must never
            // fire TO regardless of how long a legitimate transfer takes.
            reg_write_task(ADDR_WDT, 32'd0);
            reg_write_task(ADDR_IER, 32'h0);
            reg_write_task(ADDR_ISR, 32'h1F);
            reg_write_task(ADDR_CKDIV, 32'd4);
            s_tx_data = '0;
            reg_write_task(ADDR_DR, '1);
            reg_write_task(ADDR_CR, 32'h1);

            wait_cycles = 0;
            reg_read_task(ADDR_SR, rdata);
            while (!rdata[1] && wait_cycles < 200000) begin
                reg_read_task(ADDR_SR, rdata);
                wait_cycles = wait_cycles + 1;
            end
            reg_read_task(ADDR_ISR, rdata);
            check_eq(32'(rdata[4]), 32'(1'b0), "SPI_ISR.TO stays clear with SPI_WDT=0 (disabled)");
            reg_read_task(ADDR_DR, rdata);

            // Enable with a threshold well under this (deliberately slow,
            // clk_div=4) transfer's duration, and confirm TO fires -- and
            // SPI_SR.BUSY is still set when it does, i.e. it fires *during*
            // the transfer, not merely by its end.
            reg_write_task(ADDR_WDT, 32'd30);
            s_tx_data = '0;
            reg_write_task(ADDR_DR, '1);
            reg_write_task(ADDR_CR, 32'h1);

            wait_cycles = 0;
            reg_read_task(ADDR_ISR, rdata);
            while (!rdata[4] && wait_cycles < 200000) begin
                reg_read_task(ADDR_ISR, rdata);
                wait_cycles = wait_cycles + 1;
            end
            checks = checks + 1;
            if (wait_cycles >= 200000) begin
                errors = errors + 1;
                $display("[%0t] FAIL SPI_ISR.TO never set with a short watchdog threshold", $time);
            end

            reg_read_task(ADDR_SR, rdata);
            checks = checks + 1;
            if (!rdata[0]) begin
                errors = errors + 1;
                $display("[%0t] FAIL watchdog test: core no longer busy when TO fired", $time);
            end
            check_eq(32'(rdata[5]), 32'(1'b1), "SPI_SR.ERR set while SPI_ISR.TO is pending");

            // W1C clear while still busy and still over threshold: TO
            // fires only once per busy period, so it must *stay* cleared
            // for the remainder of this transfer even though "busy and
            // over threshold" is still continuously true -- otherwise the
            // same level condition would just reassert it the very next
            // cycle, making the bit un-clearable while a slow transfer is
            // in flight.
            reg_write_task(ADDR_ISR, 32'h10);
            reg_read_task(ADDR_ISR, rdata);
            check_eq(32'(rdata[4]), 32'(1'b0), "SPI_ISR.TO cleared by W1C");
            repeat (20) @(posedge clk_m);
            reg_read_task(ADDR_ISR, rdata);
            check_eq(32'(rdata[4]), 32'(1'b0),
                      "SPI_ISR.TO stays clear after W1C for the rest of this busy period");

            wait_cycles = 0;
            reg_read_task(ADDR_SR, rdata);
            while (!rdata[1] && wait_cycles < 200000) begin
                reg_read_task(ADDR_SR, rdata);
                wait_cycles = wait_cycles + 1;
            end
            reg_read_task(ADDR_DR, rdata);

            // A fresh busy period re-arms the once-per-period gate: the
            // same slow config (clk_div=4, unchanged threshold=30) must
            // fire TO again on this new transfer, proving the earlier W1C
            // didn't disable the watchdog permanently, only for the
            // transfer it was cleared during.
            s_tx_data = '0;
            reg_write_task(ADDR_DR, '1);
            reg_write_task(ADDR_CR, 32'h1);

            wait_cycles = 0;
            reg_read_task(ADDR_ISR, rdata);
            while (!rdata[4] && wait_cycles < 200000) begin
                reg_read_task(ADDR_ISR, rdata);
                wait_cycles = wait_cycles + 1;
            end
            check_eq(32'(rdata[4]), 32'(1'b1), "SPI_ISR.TO fires again on a new busy period after an earlier W1C clear");
            reg_write_task(ADDR_ISR, 32'h10);

            wait_cycles = 0;
            reg_read_task(ADDR_SR, rdata);
            while (!rdata[1] && wait_cycles < 200000) begin
                reg_read_task(ADDR_SR, rdata);
                wait_cycles = wait_cycles + 1;
            end
            reg_read_task(ADDR_DR, rdata);

            // Watchdog counter must reset between transfers: a much faster
            // transfer (clk_div=0) under the *same* threshold must not
            // trigger TO, proving wdt_cnt didn't carry over stale count
            // from the previous, deliberately slow transfer.
            reg_write_task(ADDR_ISR, 32'h10);
            reg_write_task(ADDR_CKDIV, 32'd0);
            s_tx_data = '0;
            reg_write_task(ADDR_DR, '1);
            reg_write_task(ADDR_CR, 32'h1);

            wait_cycles = 0;
            reg_read_task(ADDR_SR, rdata);
            while (!rdata[1] && wait_cycles < 200000) begin
                reg_read_task(ADDR_SR, rdata);
                wait_cycles = wait_cycles + 1;
            end
            reg_read_task(ADDR_ISR, rdata);
            check_eq(32'(rdata[4]), 32'(1'b0),
                      "SPI_ISR.TO stays clear for a fast transfer under the same threshold (counter resets between transfers)");
            reg_read_task(ADDR_DR, rdata);

            reg_write_task(ADDR_WDT, 32'd0);
            reg_write_task(ADDR_CKDIV, 32'd1);

            $display("Watchdog test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask

    // Covers SPI_CFG.DATA_BITS, the register-interface front end for the
    // runtime data-width feature: a narrower-than-DATA_WIDTH transfer
    // driven entirely through the register bus, and rejection of an
    // out-of-range DATA_BITS write. cfg_data_width_mirror stands in for
    // the raw slave side's register bus the same way cfg_cpol_mirror/etc.
    // already do, since this testbench's slave is a plain spi_top rather
    // than a second spi_reg_top instance.
    // verilator lint_off UNUSEDSIGNAL
    // verilator lint_off INITIALDLY
    task automatic run_data_width_reg_test;
        localparam int unsigned NARROW_WIDTH = (DATA_WIDTH >= 2) ? DATA_WIDTH - 1 : DATA_WIDTH;
        logic [31:0] rdata;
        logic [DATA_WIDTH-1:0] m_word, s_word;
        int wait_cycles;
        int i;
        begin
            if (DATA_WIDTH < 2) begin
                $display("Reg-if data-width test skipped (DATA_WIDTH=%0d has no narrower width to try)", DATA_WIDTH);
            end else begin
                cfg_cpol_mirror       = 1'b0;
                cfg_cpha_mirror       = 1'b0;
                cfg_lsb_mirror        = 1'b0;
                cfg_data_width_mirror = $clog2(DATA_WIDTH+1)'(NARROW_WIDTH);
                reg_write_task(ADDR_CFG, {23'b0, 6'(NARROW_WIDTH), 3'b000});
                reg_write_task(ADDR_CKDIV, 32'd1);
                repeat (3) @(posedge clk_m);

                reg_read_task(ADDR_CFG, rdata);
                check_eq(32'(rdata[8:3]), 32'(NARROW_WIDTH), "SPI_CFG.DATA_BITS reads back the narrower value just written");

                // Garbage in the untransferred upper bits: a design that
                // (incorrectly) still exchanged the full DATA_WIDTH
                // regardless of DATA_BITS would leak this into the peer's
                // received word instead of the zero-extended result a
                // correct NARROW_WIDTH-bit transfer produces.
                for (i = 0; i < 4; i = i + 1) begin
                    // verilator lint_off WIDTHTRUNC
                    m_word = $urandom(seed);
                    s_word = $urandom(seed);
                    // verilator lint_on WIDTHTRUNC
                    m_word[DATA_WIDTH-1:NARROW_WIDTH] = '1;
                    s_word[DATA_WIDTH-1:NARROW_WIDTH] = '1;

                    s_tx_data <= {{(DATA_WIDTH-NARROW_WIDTH){1'b0}}, s_word[NARROW_WIDTH-1:0]};
                    reg_write_task(ADDR_DR, {{(32 - DATA_WIDTH){1'b0}}, m_word});
                    reg_write_task(ADDR_CR, 32'h1);

                    wait_cycles = 0;
                    reg_read_task(ADDR_SR, rdata);
                    while (!rdata[1] && wait_cycles < 200000) begin
                        reg_read_task(ADDR_SR, rdata);
                        wait_cycles = wait_cycles + 1;
                    end
                    checks = checks + 1;
                    if (wait_cycles >= 200000) begin
                        errors = errors + 1;
                        $display("[%0t] FAIL timeout waiting for SPI_SR.DONE (data-width=%0d)", $time, NARROW_WIDTH);
                    end

                    reg_read_task(ADDR_DR, rdata);
                    check_eq(rdata, {{(32-NARROW_WIDTH){1'b0}}, s_word[NARROW_WIDTH-1:0]},
                             "SPI_DR (master rx, narrower DATA_BITS)");

                    wait_cycles = 0;
                    while (!s_rx_valid_sticky && wait_cycles < 1000) begin
                        @(posedge clk_m);
                        wait_cycles = wait_cycles + 1;
                    end
                    checks = checks + 1;
                    if (s_rx_valid_sticky) begin
                        if (s_rx_data_sticky !== {{(DATA_WIDTH-NARROW_WIDTH){1'b0}}, m_word[NARROW_WIDTH-1:0]}) begin
                            errors = errors + 1;
                            $display("[%0t] FAIL slave rx (data-width=%0d): expected=%0h got=%0h",
                                      $time, NARROW_WIDTH,
                                      {{(DATA_WIDTH-NARROW_WIDTH){1'b0}}, m_word[NARROW_WIDTH-1:0]}, s_rx_data_sticky);
                        end
                    end else begin
                        errors = errors + 1;
                        $display("[%0t] FAIL slave never reported rx_valid (data-width=%0d)", $time, NARROW_WIDTH);
                    end
                    s_rx_ack <= 1'b1;
                    @(posedge clk_m);
                    s_rx_ack <= 1'b0;
                    @(posedge clk_m);
                end

                // Out-of-range DATA_BITS: rejected outright (PERR set, the
                // whole SPI_CFG write dropped) rather than truncated or
                // silently accepted -- there is no such thing as a
                // transfer wider than the DATA_WIDTH elaboration parameter.
                reg_write_task(ADDR_ISR, 32'hF);
                reg_write_task(ADDR_CFG, {23'b0, 6'(DATA_WIDTH+1), 3'b010});
                reg_read_task(ADDR_ISR, rdata);
                check_eq(32'(rdata[3]), 32'(1'b1), "SPI_ISR.PERR set after DATA_BITS > DATA_WIDTH");
                reg_write_task(ADDR_ISR, 32'h8);
                reg_read_task(ADDR_CFG, rdata);
                check_eq(32'(rdata[8:3]), 32'(NARROW_WIDTH),
                          "SPI_CFG.DATA_BITS unchanged after a rejected out-of-range write");
                check_eq(32'(rdata[1]), 32'(1'b0), "SPI_CFG.CPOL unchanged after a rejected out-of-range write");

                cfg_cpol_mirror       = 1'b0;
                cfg_cpha_mirror       = 1'b0;
                cfg_lsb_mirror        = 1'b0;
                cfg_data_width_mirror = $clog2(DATA_WIDTH+1)'(DATA_WIDTH);
                reg_write_task(ADDR_CFG, {23'b0, 6'(DATA_WIDTH), 3'b000});
                repeat (3) @(posedge clk_m);
            end

            $display("Reg-if data-width test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask
    // verilator lint_on INITIALDLY
    // verilator lint_on UNUSEDSIGNAL
    // verilator lint_on UNUSEDSIGNAL

    int cpol_v, cpha_v, lsb_v;

    initial begin
        errors    = 0;
        checks    = 0;
        PADDR     = 0;
        PWDATA    = 0;
        PSEL      = 0;
        PENABLE   = 0;
        PWRITE    = 0;
        s_tx_data = 0;
        s_rx_ack  = 0;
        cfg_cpol_mirror = 0;
        cfg_cpha_mirror = 0;
        cfg_lsb_mirror  = 0;
        cfg_data_width_mirror = $clog2(DATA_WIDTH+1)'(DATA_WIDTH);

        rst_n_m = 1'b0;
        rst_n_s = 1'b0;
        repeat (5) @(posedge clk_m);
        repeat (5) @(posedge clk_s);
        rst_n_m = 1'b1;
        rst_n_s = 1'b1;
        repeat (5) @(posedge clk_m);

        for (cpol_v = 0; cpol_v < 2; cpol_v = cpol_v + 1) begin
            for (cpha_v = 0; cpha_v < 2; cpha_v = cpha_v + 1) begin
                for (lsb_v = 0; lsb_v < 2; lsb_v = lsb_v + 1) begin
                    run_mode_config(cpol_v, cpha_v, lsb_v);
                end
            end
        end

        cfg_cpol_mirror = 0;
        cfg_cpha_mirror = 0;
        cfg_lsb_mirror  = 0;
        cfg_data_width_mirror = $clog2(DATA_WIDTH+1)'(DATA_WIDTH);
        reg_write_task(ADDR_CFG, {23'b0, 6'd8, 3'b000});
        reg_write_task(ADDR_CKDIV, 32'd1);
        repeat (3) @(posedge clk_m);

        run_cr_self_clear_test();
        run_isr_ier_test();
        run_soft_reset_test();
        run_error_handling_test();
        run_watchdog_test();
        run_data_width_reg_test();

        $display("==============================================");
        $display("TOTAL CHECKS: %0d", checks);
        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("TESTS FAILED: %0d", errors);
        end
        $display("==============================================");

        if (errors != 0) begin
            $fatal(1, "SPI register interface test failed with %0d errors", errors);
        end

        $finish;
    end

    initial begin
        $dumpfile(VCD_PATH);
        $dumpvars(0, tb_spi_reg_top);
    end

    initial begin
        #200000000;
        $display("WATCHDOG TIMEOUT");
        $fatal(1, "Global watchdog timeout");
    end

endmodule
