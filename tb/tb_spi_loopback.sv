`timescale 1ns / 1ps

// DATA_WIDTH is a module parameter (not a localparam) specifically so it
// can be overridden from the command line without editing this file --
// iverilog's `-P tb_spi_loopback.DATA_WIDTH=<N>` and Verilator's
// `-GDATA_WIDTH=<N>` both need a real parameter to target. See
// `make width-sweep` in sim/Makefile.
module tb_spi_loopback #(
    parameter int DATA_WIDTH = 8
) ();

    localparam int CLK_DIV_WIDTH = 16;

`ifdef VERILATOR
    localparam string VCD_PATH = "../waves/verilator.vcd";
`else
    localparam string VCD_PATH = "../waves/iverilog.vcd";
`endif

    // verilator lint_off BLKSEQ
    // Blocking assignment is the conventional, widely-used idiom for a
    // free-running testbench clock generator; using '<=' here would be
    // non-idiomatic without changing simulated behavior for this purpose.
    logic clk_m;
    logic clk_s;
    logic rst_n_m;
    logic rst_n_s;

    initial clk_m = 1'b0;
    always #5 clk_m = ~clk_m;

    // clk_s runs at an unrelated, much faster rate than clk_m so the
    // slave's CDC synchronizer is genuinely exercised against an
    // asynchronous sclk, while still giving the >=10x oversampling ratio
    // a real synthesizable SPI slave design assumes.
    initial clk_s = 1'b0;
    always #2 clk_s = ~clk_s;
    // verilator lint_on BLKSEQ

    logic                     cfg_cpol;
    logic                     cfg_cpha;
    logic                     cfg_lsb_first;
    logic [CLK_DIV_WIDTH-1:0] cfg_clk_div;
    logic [$clog2(DATA_WIDTH+1)-1:0] cfg_data_width;

    // Independent per-core write strobes, since the master and slave cores
    // sit in different clock domains (clk_m/clk_s) and a real system would
    // have each side's config register file written from its own clock
    // domain's bus. Tied high everywhere except in the dedicated write-gate
    // test below, so every other test's existing "set cfg_* and expect it
    // to take effect" behavior is unchanged.
    logic m_cfg_wr_en;
    logic s_cfg_wr_en;

    // verilator lint_off UNUSEDSIGNAL
    // tx_ready/busy are not read by the checker logic (transfers are paced
    // by fixed delays instead), but are wired up and dumped to the VCD
    // since they are useful signals to inspect when debugging waveforms.
    logic [DATA_WIDTH-1:0] m_tx_data;
    logic                  m_tx_valid;
    logic                  m_tx_ready;
    logic [DATA_WIDTH-1:0] m_rx_data;
    logic                  m_rx_valid;
    logic                  m_busy;

    logic [DATA_WIDTH-1:0] s_tx_data;
    logic                  s_tx_valid;
    logic                  s_tx_ready;
    logic [DATA_WIDTH-1:0] s_rx_data;
    logic                  s_rx_valid;
    logic                  s_busy;
    // verilator lint_on UNUSEDSIGNAL

    wire ss_n_w;
    wire sclk_w;
    wire mosi_w;
    wire miso_w;

    spi_top #(
        .MASTER_MODE   (1),
        .DATA_WIDTH    (DATA_WIDTH),
        .CLK_DIV_WIDTH (CLK_DIV_WIDTH)
    ) u_master (
        .clk          (clk_m),
        .rst_n        (rst_n_m),
        .cfg_wr_en    (m_cfg_wr_en),
        .cfg_cpol     (cfg_cpol),
        .cfg_cpha     (cfg_cpha),
        .cfg_lsb_first(cfg_lsb_first),
        .cfg_clk_div  (cfg_clk_div),
        .cfg_data_width(cfg_data_width),
        .tx_data      (m_tx_data),
        .tx_valid     (m_tx_valid),
        .tx_ready     (m_tx_ready),
        .rx_data      (m_rx_data),
        .rx_valid     (m_rx_valid),
        .busy         (m_busy),
        .ss_n         (ss_n_w),
        .sclk         (sclk_w),
        .mosi         (mosi_w),
        .miso         (miso_w)
    );

    spi_top #(
        .MASTER_MODE   (0),
        .DATA_WIDTH    (DATA_WIDTH),
        .CLK_DIV_WIDTH (CLK_DIV_WIDTH)
    ) u_slave (
        .clk          (clk_s),
        .rst_n        (rst_n_s),
        .cfg_wr_en    (s_cfg_wr_en),
        .cfg_cpol     (cfg_cpol),
        .cfg_cpha     (cfg_cpha),
        .cfg_lsb_first(cfg_lsb_first),
        .cfg_clk_div  ('0),
        .cfg_data_width(cfg_data_width),
        .tx_data      (s_tx_data),
        .tx_valid     (s_tx_valid),
        .tx_ready     (s_tx_ready),
        .rx_data      (s_rx_data),
        .rx_valid     (s_rx_valid),
        .busy         (s_busy),
        .ss_n         (ss_n_w),
        .sclk         (sclk_w),
        .mosi         (mosi_w),
        .miso         (miso_w)
    );

    // s_rx_valid pulses for a single clk_s cycle (2ns), shorter than the
    // clk_m sampling period (5ns) used by the checker below, so a plain
    // @(posedge clk_m) poll of s_rx_valid can miss the pulse entirely.
    // This sticky latch (set in the clk_s domain, cleared by an explicit
    // one-clk_m-cycle ack from the checker) makes the event observable
    // from clk_m without needing true multi-clock synchronization logic
    // in the testbench.
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

    int unsigned seed = 32'hC0FFEE;
    int errors;
    int checks;

    logic [DATA_WIDTH-1:0] expect_master_rx;
    logic [DATA_WIDTH-1:0] expect_slave_rx;
    logic                  master_rx_seen;
    logic                  slave_rx_seen;

    // verilator lint_off INITIALDLY
    // do_transfer is only ever called from the initial-block test sequence
    // below, but its non-blocking assignments are intentional: each write
    // is meant to land after the preceding @(posedge clk_m), matching
    // standard clocked-testbench-driver style rather than the immediate
    // (blocking) semantics verilator warns about for initial/final blocks.
    task automatic do_transfer(input logic [DATA_WIDTH-1:0] m_word,
                                input logic [DATA_WIDTH-1:0] s_word);
        int wait_cycles;
        begin
            @(posedge clk_m);
            m_tx_data  <= m_word;
            m_tx_valid <= 1'b1;
            s_tx_data  <= s_word;
            s_tx_valid <= 1'b1;
            expect_master_rx <= s_word;
            expect_slave_rx  <= m_word;
            master_rx_seen   = 1'b0;
            slave_rx_seen    = 1'b0;

            @(posedge clk_m);
            m_tx_valid <= 1'b0;
            s_tx_valid <= 1'b0;
            s_rx_ack   <= 1'b0;

            wait_cycles = 0;
            while (!(master_rx_seen && slave_rx_seen) && wait_cycles < 200000) begin
                @(posedge clk_m);
                if (m_rx_valid) begin
                    checks = checks + 1;
                    if (m_rx_data !== expect_master_rx) begin
                        errors = errors + 1;
                        $display("[%0t] FAIL master rx: expected=%0h got=%0h (cpol=%0d cpha=%0d lsb=%0d div=%0d)",
                                 $time, expect_master_rx, m_rx_data, cfg_cpol, cfg_cpha, cfg_lsb_first, cfg_clk_div);
                    end
                    master_rx_seen = 1'b1;
                end
                if (s_rx_valid_sticky && !slave_rx_seen) begin
                    checks = checks + 1;
                    if (s_rx_data_sticky !== expect_slave_rx) begin
                        errors = errors + 1;
                        $display("[%0t] FAIL slave rx: expected=%0h got=%0h (cpol=%0d cpha=%0d lsb=%0d div=%0d)",
                                 $time, expect_slave_rx, s_rx_data_sticky, cfg_cpol, cfg_cpha, cfg_lsb_first, cfg_clk_div);
                    end
                    slave_rx_seen = 1'b1;
                end
                wait_cycles = wait_cycles + 1;
            end

            s_rx_ack <= 1'b1;
            @(posedge clk_m);
            s_rx_ack <= 1'b0;
            @(posedge clk_m);

            if (!(master_rx_seen && slave_rx_seen)) begin
                errors = errors + 1;
                $display("[%0t] FAIL timeout waiting for transfer completion (cpol=%0d cpha=%0d lsb=%0d div=%0d)",
                          $time, cfg_cpol, cfg_cpha, cfg_lsb_first, cfg_clk_div);
            end

            @(posedge clk_m);
        end
    endtask
    // verilator lint_on INITIALDLY

    // verilator lint_off INITIALDLY
    // Mirrors do_transfer above but slams cfg_cpol/cfg_cpha/cfg_lsb_first/
    // cfg_clk_div to a different ("glitch") mode partway through the
    // transfer, while both cores are still busy. Both spi_master and
    // spi_slave latch mode config at transfer start (see docs/README.md),
    // so this glitch must have zero effect on the transfer already in
    // flight: the expected data is unchanged from a normal do_transfer,
    // and if the latch were missing/broken this would corrupt the
    // in-flight bits and fail the checks below.
    task automatic do_transfer_with_glitch(input logic [DATA_WIDTH-1:0] m_word,
                                            input logic [DATA_WIDTH-1:0] s_word,
                                            input int glitch_after_cycles,
                                            input logic glitch_cpol,
                                            input logic glitch_cpha,
                                            input logic glitch_lsb,
                                            input logic [CLK_DIV_WIDTH-1:0] glitch_div);
        int wait_cycles;
        begin
            @(posedge clk_m);
            m_tx_data  <= m_word;
            m_tx_valid <= 1'b1;
            s_tx_data  <= s_word;
            s_tx_valid <= 1'b1;
            expect_master_rx <= s_word;
            expect_slave_rx  <= m_word;
            master_rx_seen   = 1'b0;
            slave_rx_seen    = 1'b0;

            @(posedge clk_m);
            m_tx_valid <= 1'b0;
            s_tx_valid <= 1'b0;
            s_rx_ack   <= 1'b0;

            repeat (glitch_after_cycles) @(posedge clk_m);

            if (!(m_busy && s_busy)) begin
                errors = errors + 1;
                $display("[%0t] FAIL glitch test setup: transfer not busy at glitch point (glitch_after_cycles=%0d)",
                          $time, glitch_after_cycles);
            end

            cfg_cpol      = glitch_cpol;
            cfg_cpha      = glitch_cpha;
            cfg_lsb_first = glitch_lsb;
            cfg_clk_div   = glitch_div;

            wait_cycles = 0;
            while (!(master_rx_seen && slave_rx_seen) && wait_cycles < 200000) begin
                @(posedge clk_m);
                if (m_rx_valid) begin
                    checks = checks + 1;
                    if (m_rx_data !== expect_master_rx) begin
                        errors = errors + 1;
                        $display("[%0t] FAIL master rx (mid-xfer config glitch): expected=%0h got=%0h",
                                 $time, expect_master_rx, m_rx_data);
                    end
                    master_rx_seen = 1'b1;
                end
                if (s_rx_valid_sticky && !slave_rx_seen) begin
                    checks = checks + 1;
                    if (s_rx_data_sticky !== expect_slave_rx) begin
                        errors = errors + 1;
                        $display("[%0t] FAIL slave rx (mid-xfer config glitch): expected=%0h got=%0h",
                                 $time, expect_slave_rx, s_rx_data_sticky);
                    end
                    slave_rx_seen = 1'b1;
                end
                wait_cycles = wait_cycles + 1;
            end

            s_rx_ack <= 1'b1;
            @(posedge clk_m);
            s_rx_ack <= 1'b0;
            @(posedge clk_m);

            if (!(master_rx_seen && slave_rx_seen)) begin
                errors = errors + 1;
                $display("[%0t] FAIL timeout waiting for transfer completion (mid-xfer config glitch)", $time);
            end

            @(posedge clk_m);
        end
    endtask
    // verilator lint_on INITIALDLY

    // Baseline clk_div is chosen so the whole transfer's toggle count
    // (2*DATA_WIDTH-1 toggles: the last bit needs only its sample edge,
    // not a following shift edge, to complete) times the per-toggle
    // period (baseline_div+1 cycles) lands near a fixed target window
    // regardless of DATA_WIDTH -- e.g. a wide transfer uses a small
    // divider and a narrow one uses a large divider, so DATA_WIDTH=1
    // gets just as roomy a busy window as DATA_WIDTH=32 for the
    // mid-transfer-glitch/write-pulse tests to land their timing in,
    // rather than either overshooting the transfer (DATA_WIDTH=4/8's
    // original failure) or crowding out the slave's ~2-3 clk_s-cycle
    // CDC synchronizer latency for busy to reach this domain
    // (DATA_WIDTH=1's failure with a too-small fixed divider).
    localparam int unsigned TARGET_XFER_CYCLES = 60;
    localparam int unsigned TOGGLES_NEEDED     = 2 * DATA_WIDTH - 1;
    localparam int unsigned PER_TOGGLE_CYCLES  =
        (TARGET_XFER_CYCLES / TOGGLES_NEEDED > 1) ? TARGET_XFER_CYCLES / TOGGLES_NEEDED : 2;
    localparam int unsigned BASELINE_DIV       = PER_TOGGLE_CYCLES - 1;
    localparam int unsigned XFER_CYCLES        = TOGGLES_NEEDED * PER_TOGGLE_CYCLES;

    // Sets cfg_* and waits long enough for both cores' shadow registers
    // (see docs/README.md) to pick up the write in their own clock domain
    // before anything relies on it, matching how a real driver would wait
    // after a config register write.
    task automatic set_baseline_cfg;
        begin
            cfg_cpol      = 1'b0;
            cfg_cpha      = 1'b0;
            cfg_lsb_first = 1'b0;
            cfg_clk_div   = CLK_DIV_WIDTH'(BASELINE_DIV);
            cfg_data_width = $clog2(DATA_WIDTH+1)'(DATA_WIDTH);
            repeat (3) @(posedge clk_m);
        end
    endtask

    task automatic run_mid_transfer_glitch_test;
        int i;
        logic [DATA_WIDTH-1:0] rnd_m;
        logic [DATA_WIDTH-1:0] rnd_s;
        // Glitch offsets are derived from XFER_CYCLES rather than
        // hardcoded, since a fixed cycle count tuned for DATA_WIDTH=8
        // lands after the transfer already completed at other widths --
        // exactly the failure this parametrization surfaced at
        // DATA_WIDTH=4 (fixed offsets of 40/60). glitch_early also has an
        // absolute floor (not just a fraction of XFER_CYCLES) to clear
        // the slave's CDC synchronizer latency for busy, since that
        // latency doesn't shrink just because the transfer is short --
        // this was DATA_WIDTH=1's remaining failure even after fixing the
        // DATA_WIDTH=4 issue, and is why BASELINE_DIV above stretches
        // small-DATA_WIDTH transfers out rather than trying to land the
        // glitch inside an uncomfortably short window.
        localparam int unsigned CDC_MARGIN = 3;
        int unsigned glitch_early;
        int unsigned glitch_mid;
        int unsigned glitch_late;
        int unsigned rand_span;
        begin
            glitch_early = (XFER_CYCLES / 4 > CDC_MARGIN) ? XFER_CYCLES / 4 : CDC_MARGIN;
            glitch_mid   = XFER_CYCLES / 2;
            glitch_late  = (XFER_CYCLES * 3) / 4;
            if (glitch_late < glitch_early + 1) glitch_late = glitch_early + 1;
            if (glitch_mid <= glitch_early) glitch_mid = glitch_early + 1;
            if (glitch_mid >= glitch_late) glitch_mid = glitch_early;
            rand_span    = glitch_late - glitch_early;
            if (rand_span < 1) rand_span = 1;

            // Baseline mode 0 (cpol=0, cpha=0), MSB-first leaves
            // comfortable margin to land the glitch at early/mid/late
            // points within the transfer. Each glitch inverts every field
            // to the opposite mode/order plus a very different clk_div,
            // the most adversarial change possible.
            set_baseline_cfg();

            do_transfer_with_glitch('0, '1, glitch_early, 1'b1, 1'b1, 1'b1, 16'd0);
            set_baseline_cfg();
            do_transfer_with_glitch('1, '0, glitch_mid,   1'b1, 1'b1, 1'b1, 16'd0);
            set_baseline_cfg();
            do_transfer_with_glitch('0, '1, glitch_late,  1'b1, 1'b1, 1'b1, 16'd0);
            set_baseline_cfg();

            for (i = 0; i < 10; i = i + 1) begin
                // verilator lint_off WIDTHTRUNC
                rnd_m = $urandom(seed);
                rnd_s = $urandom(seed);
                // verilator lint_on WIDTHTRUNC
                do_transfer_with_glitch(rnd_m, rnd_s,
                                         glitch_early + (i * (rand_span / 10 + 1)) % (rand_span + 1),
                                         1'b1, 1'b1, 1'b1, 16'd9);
                // Restore the baseline for the next iteration's busy/glitch
                // margin assumptions; each do_transfer_with_glitch call
                // leaves cfg_* set to the glitch values from the previous
                // transfer.
                set_baseline_cfg();
            end

            $display("Mid-transfer config glitch test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask

    // Proves cfg_wr_en actually gates writes into the shadow config
    // registers, as distinct from the transfer-start latch tested above.
    // Both master and slave sit idle throughout (no transfer in flight),
    // so the mid-transfer latch plays no role here; only the shadow
    // register's cfg_wr_en gate can be responsible for the observed
    // behavior. sclk_w's idle level is used as the observation point
    // because it is the one config-derived signal directly visible on the
    // shared bus while idle (ST_IDLE continuously drives sclk <= cpol_shadow
    // in spi_master), so a change in cfg_cpol can be confirmed to have (or
    // not have) reached the shadow register without needing a transfer.
    task automatic run_cfg_wr_en_gate_test;
        begin
            cfg_cpol      = 1'b0;
            cfg_cpha      = 1'b0;
            cfg_lsb_first = 1'b0;
            cfg_clk_div   = 16'd1;
            m_cfg_wr_en   = 1'b1;
            s_cfg_wr_en   = 1'b1;
            repeat (3) @(posedge clk_m);

            if (sclk_w !== 1'b0) begin
                errors = errors + 1;
                $display("[%0t] FAIL wr_en gate test setup: sclk_w=%0b, expected idle-low baseline", $time, sclk_w);
            end

            m_cfg_wr_en = 1'b0;
            s_cfg_wr_en = 1'b0;
            @(posedge clk_m);
            cfg_cpol = 1'b1;
            repeat (5) @(posedge clk_m);

            if (sclk_w !== 1'b0) begin
                errors = errors + 1;
                $display("[%0t] FAIL cfg_wr_en=0 did not gate the write: sclk_w=%0b changed to reflect new cfg_cpol despite wr_en low",
                          $time, sclk_w);
            end
            checks = checks + 1;

            m_cfg_wr_en = 1'b1;
            @(posedge clk_m);
            m_cfg_wr_en = 1'b0;
            repeat (2) @(posedge clk_m);

            if (sclk_w !== 1'b1) begin
                errors = errors + 1;
                $display("[%0t] FAIL cfg_wr_en pulse did not commit the write: sclk_w=%0b, expected 1 after strobe",
                          $time, sclk_w);
            end
            checks = checks + 1;

            m_cfg_wr_en   = 1'b1;
            s_cfg_wr_en   = 1'b1;
            cfg_cpol      = 1'b0;
            cfg_cpha      = 1'b0;
            cfg_lsb_first = 1'b0;
            cfg_clk_div   = 16'd1;
            repeat (3) @(posedge clk_m);

            $display("cfg_wr_en gate test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask

    // Proves the host can strike a config write at any time, including
    // mid-transfer, and that write automatically becomes active the
    // moment the core goes idle again -- without the host needing to
    // re-strike anything once idle. do_transfer_with_glitch already
    // performs a mid-transfer write (the "glitch") and deliberately never
    // undoes it, leaving the shadow registers holding the glitched config
    // once the transfer completes; this task builds on that by checking,
    // with no further cfg_* writes, that (a) the idle sclk level already
    // reflects the new config and (b) a subsequent transfer run under it
    // completes correctly, which is only possible if both master and
    // slave actually adopted the same new mode/order/div.
    task automatic run_cfg_apply_after_idle_test;
        // Reuses the BASELINE_DIV/XFER_CYCLES sizing from
        // run_mid_transfer_glitch_test (see its comment) so the glitch
        // offset below clears the slave's CDC synchronizer latency for
        // busy at any DATA_WIDTH, rather than the fixed div=1/offset=6
        // this originally used, which was far too tight a window at
        // DATA_WIDTH=1 (a 1-bit transfer at div=1 completes in ~2 cycles).
        localparam int unsigned CDC_MARGIN = 3;
        int unsigned glitch_point;
        logic [DATA_WIDTH-1:0] pat_a;
        logic [DATA_WIDTH-1:0] pat_b;
        begin
            glitch_point = (XFER_CYCLES / 4 > CDC_MARGIN) ? XFER_CYCLES / 4 : CDC_MARGIN;
            cfg_cpol      = 1'b0;
            cfg_cpha      = 1'b0;
            cfg_lsb_first = 1'b0;
            cfg_clk_div   = CLK_DIV_WIDTH'(BASELINE_DIV);
            m_cfg_wr_en   = 1'b1;
            s_cfg_wr_en   = 1'b1;
            repeat (3) @(posedge clk_m);

            do_transfer_with_glitch('1, '0, glitch_point, 1'b1, 1'b1, 1'b1, 16'd4);

            repeat (2) @(posedge clk_m);
            if (sclk_w !== 1'b1) begin
                errors = errors + 1;
                $display("[%0t] FAIL busy-time write did not auto-apply once idle: sclk_w=%0b, expected 1 (new cpol) with no further cfg_* write",
                          $time, sclk_w);
            end
            checks = checks + 1;

            // verilator lint_off WIDTHTRUNC
            pat_a = $urandom(seed);
            pat_b = $urandom(seed);
            // verilator lint_on WIDTHTRUNC
            do_transfer(pat_a, pat_b);

            cfg_cpol      = 1'b0;
            cfg_cpha      = 1'b0;
            cfg_lsb_first = 1'b0;
            cfg_clk_div   = 16'd1;
            repeat (3) @(posedge clk_m);

            $display("cfg apply-after-idle test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask

    // Stronger version of the above: strikes a single-cycle cfg_wr_en
    // pulse mid-transfer, deasserts it immediately (long before the
    // transfer ends), and then scrambles cfg_* back to something else on
    // the wire while wr_en stays low. If the write only became "sticky"
    // because run_cfg_apply_after_idle_test happened to leave cfg_wr_en
    // held high across the busy->idle boundary, this test would fail; a
    // real "write captured the instant cfg_wr_en pulses, regardless of
    // busy" implementation still shows the new config once idle, because
    // the shadow registers already hold it well before the transfer ends.
    // verilator lint_off INITIALDLY
    task automatic run_cfg_write_pulse_during_busy_test;
        int wait_cycles;
        // Same XFER_CYCLES/BASELINE_DIV timing rationale as
        // run_mid_transfer_glitch_test above, including the CDC-latency
        // floor: a fixed wait tuned for DATA_WIDTH=8 both overshoots a
        // narrower width's shorter transfer and, at DATA_WIDTH=1
        // specifically, can land before the slave's synchronized busy
        // has even caught up to the master's.
        localparam int unsigned CDC_MARGIN = 3;
        int unsigned pulse_point;
        begin
            pulse_point = (XFER_CYCLES / 2 > CDC_MARGIN) ? XFER_CYCLES / 2 : CDC_MARGIN;
            cfg_cpol      = 1'b0;
            cfg_cpha      = 1'b0;
            cfg_lsb_first = 1'b0;
            cfg_clk_div   = CLK_DIV_WIDTH'(BASELINE_DIV);
            m_cfg_wr_en   = 1'b1;
            s_cfg_wr_en   = 1'b1;
            repeat (3) @(posedge clk_m);
            m_cfg_wr_en = 1'b0;
            s_cfg_wr_en = 1'b0;

            @(posedge clk_m);
            m_tx_data  <= '0;
            m_tx_valid <= 1'b1;
            s_tx_data  <= '1;
            s_tx_valid <= 1'b1;
            expect_master_rx <= '1;
            expect_slave_rx  <= '0;
            master_rx_seen   = 1'b0;
            slave_rx_seen    = 1'b0;

            @(posedge clk_m);
            m_tx_valid <= 1'b0;
            s_tx_valid <= 1'b0;
            s_rx_ack   <= 1'b0;

            repeat (pulse_point) @(posedge clk_m);
            if (!(m_busy && s_busy)) begin
                errors = errors + 1;
                $display("[%0t] FAIL write-pulse test setup: transfer not busy at pulse point", $time);
            end

            cfg_cpol      = 1'b1;
            cfg_cpha      = 1'b1;
            cfg_lsb_first = 1'b1;
            cfg_clk_div   = 16'd1;
            m_cfg_wr_en   = 1'b1;
            s_cfg_wr_en   = 1'b1;
            @(posedge clk_m);
            m_cfg_wr_en = 1'b0;
            s_cfg_wr_en = 1'b0;
            // Scramble cfg_* back to A on the wire with wr_en held low, so
            // a design that (incorrectly) kept sampling cfg_* live instead
            // of a captured shadow value would show the wrong config here.
            cfg_cpol      = 1'b0;
            cfg_cpha      = 1'b0;
            cfg_lsb_first = 1'b0;
            cfg_clk_div   = 16'd4;

            wait_cycles = 0;
            while (!(master_rx_seen && slave_rx_seen) && wait_cycles < 200000) begin
                @(posedge clk_m);
                if (m_rx_valid) begin
                    checks = checks + 1;
                    if (m_rx_data !== expect_master_rx) begin
                        errors = errors + 1;
                        $display("[%0t] FAIL master rx (write-pulse-during-busy test): expected=%0h got=%0h",
                                 $time, expect_master_rx, m_rx_data);
                    end
                    master_rx_seen = 1'b1;
                end
                if (s_rx_valid_sticky && !slave_rx_seen) begin
                    checks = checks + 1;
                    if (s_rx_data_sticky !== expect_slave_rx) begin
                        errors = errors + 1;
                        $display("[%0t] FAIL slave rx (write-pulse-during-busy test): expected=%0h got=%0h",
                                 $time, expect_slave_rx, s_rx_data_sticky);
                    end
                    slave_rx_seen = 1'b1;
                end
                wait_cycles = wait_cycles + 1;
            end

            s_rx_ack <= 1'b1;
            @(posedge clk_m);
            s_rx_ack <= 1'b0;
            @(posedge clk_m);

            if (!(master_rx_seen && slave_rx_seen)) begin
                errors = errors + 1;
                $display("[%0t] FAIL timeout waiting for transfer completion (write-pulse-during-busy test)", $time);
            end

            repeat (2) @(posedge clk_m);
            if (sclk_w !== 1'b1) begin
                errors = errors + 1;
                $display("[%0t] FAIL single wr_en pulse mid-transfer was not captured: sclk_w=%0b, expected 1 (new cpol) once idle",
                          $time, sclk_w);
            end
            checks = checks + 1;

            m_cfg_wr_en   = 1'b1;
            s_cfg_wr_en   = 1'b1;
            cfg_cpol      = 1'b0;
            cfg_cpha      = 1'b0;
            cfg_lsb_first = 1'b0;
            cfg_clk_div   = 16'd1;
            repeat (3) @(posedge clk_m);

            $display("cfg write-pulse-during-busy test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask
    // verilator lint_on INITIALDLY

    // Runtime data-width feature: proves a transfer configured for
    // NARROW_WIDTH bits (< DATA_WIDTH) exchanges exactly that many bits.
    // Garbage is deliberately placed in tx_data's upper (DATA_WIDTH -
    // NARROW_WIDTH) bits -- a design that (incorrectly) still shifted the
    // full DATA_WIDTH regardless of cfg_data_width would leak that garbage
    // into the peer's rx_data; a correct one exchanges only the low
    // NARROW_WIDTH bits and comes back zero-extended above that,
    // independent of whatever was sitting in tx_data's unused upper bits.
    //
    // At DATA_WIDTH=1 there is no narrower width to try at all, so this and
    // the mid-transfer variant below are wrapped in a generate/else stub:
    // NARROW_WIDTH's part-selects below (e.g. [DATA_WIDTH-1:NARROW_WIDTH])
    // are only ever valid ranges when DATA_WIDTH>=2, and Verilator
    // elaborates a task body's part-select ranges at compile time
    // regardless of a runtime `if` guard -- a plain `if (DATA_WIDTH < 2)`
    // branch around the body still trips SELRANGE at DATA_WIDTH=1, since
    // NARROW_WIDTH==DATA_WIDTH there makes [DATA_WIDTH-1:NARROW_WIDTH]
    // reduce to a 1-bit signal's nonsensical [0:1] slice. A generate block
    // avoids elaborating that code at all for DATA_WIDTH=1.
    generate
    if (DATA_WIDTH >= 2) begin : g_data_width_tests
    // verilator lint_off INITIALDLY
    task automatic run_data_width_test;
        localparam int unsigned NARROW_WIDTH = DATA_WIDTH - 1;
        int wait_cycles;
        int i;
        logic [DATA_WIDTH-1:0] m_word, s_word;
        logic [DATA_WIDTH-1:0] exp_m, exp_s;
        begin
            begin
                cfg_cpol       = 1'b0;
                cfg_cpha       = 1'b0;
                cfg_lsb_first  = 1'b0;
                cfg_clk_div    = CLK_DIV_WIDTH'(BASELINE_DIV);
                cfg_data_width = $clog2(DATA_WIDTH+1)'(NARROW_WIDTH);
                m_cfg_wr_en    = 1'b1;
                s_cfg_wr_en    = 1'b1;
                repeat (3) @(posedge clk_m);

                for (i = 0; i < 6; i = i + 1) begin
                    // verilator lint_off WIDTHTRUNC
                    m_word = $urandom(seed);
                    s_word = $urandom(seed);
                    // verilator lint_on WIDTHTRUNC
                    m_word[DATA_WIDTH-1:NARROW_WIDTH] = '1;
                    s_word[DATA_WIDTH-1:NARROW_WIDTH] = '1;
                    exp_m = {{(DATA_WIDTH-NARROW_WIDTH){1'b0}}, s_word[NARROW_WIDTH-1:0]};
                    exp_s = {{(DATA_WIDTH-NARROW_WIDTH){1'b0}}, m_word[NARROW_WIDTH-1:0]};

                    @(posedge clk_m);
                    m_tx_data  <= m_word;
                    m_tx_valid <= 1'b1;
                    s_tx_data  <= s_word;
                    s_tx_valid <= 1'b1;
                    expect_master_rx <= exp_m;
                    expect_slave_rx  <= exp_s;
                    master_rx_seen   = 1'b0;
                    slave_rx_seen    = 1'b0;

                    @(posedge clk_m);
                    m_tx_valid <= 1'b0;
                    s_tx_valid <= 1'b0;
                    s_rx_ack   <= 1'b0;

                    wait_cycles = 0;
                    while (!(master_rx_seen && slave_rx_seen) && wait_cycles < 200000) begin
                        @(posedge clk_m);
                        if (m_rx_valid) begin
                            checks = checks + 1;
                            if (m_rx_data !== exp_m) begin
                                errors = errors + 1;
                                $display("[%0t] FAIL master rx (data-width=%0d): expected=%0h got=%0h",
                                          $time, NARROW_WIDTH, exp_m, m_rx_data);
                            end
                            master_rx_seen = 1'b1;
                        end
                        if (s_rx_valid_sticky && !slave_rx_seen) begin
                            checks = checks + 1;
                            if (s_rx_data_sticky !== exp_s) begin
                                errors = errors + 1;
                                $display("[%0t] FAIL slave rx (data-width=%0d): expected=%0h got=%0h",
                                          $time, NARROW_WIDTH, exp_s, s_rx_data_sticky);
                            end
                            slave_rx_seen = 1'b1;
                        end
                        wait_cycles = wait_cycles + 1;
                    end

                    s_rx_ack <= 1'b1;
                    @(posedge clk_m);
                    s_rx_ack <= 1'b0;
                    @(posedge clk_m);

                    if (!(master_rx_seen && slave_rx_seen)) begin
                        errors = errors + 1;
                        $display("[%0t] FAIL timeout waiting for narrow-width transfer completion", $time);
                    end
                end

                cfg_data_width = $clog2(DATA_WIDTH+1)'(DATA_WIDTH);
                repeat (3) @(posedge clk_m);
            end

            $display("Runtime data-width test (NARROW_WIDTH=%0d) done. checks=%0d errors=%0d", NARROW_WIDTH, checks, errors);
        end
    endtask
    // verilator lint_on INITIALDLY

    // Mid-transfer protection for cfg_data_width, mirroring the shadow/
    // latch protection already proven for cfg_cpol/cfg_cpha/cfg_lsb_first/
    // cfg_clk_div above: a width change landing mid-transfer must not
    // affect the transfer already in flight (still exchanges the full,
    // OLD-width word), and must take effect automatically starting with
    // the very next transfer once idle, with no further cfg_* write.
    // verilator lint_off INITIALDLY
    task automatic run_data_width_mid_transfer_test;
        localparam int unsigned NARROW_WIDTH = DATA_WIDTH - 1;
        localparam int unsigned CDC_MARGIN = 3;
        int unsigned glitch_point;
        int wait_cycles;
        logic [DATA_WIDTH-1:0] m_word, s_word;
        begin
            begin
                glitch_point = (XFER_CYCLES / 2 > CDC_MARGIN) ? XFER_CYCLES / 2 : CDC_MARGIN;

                cfg_cpol       = 1'b0;
                cfg_cpha       = 1'b0;
                cfg_lsb_first  = 1'b0;
                cfg_clk_div    = CLK_DIV_WIDTH'(BASELINE_DIV);
                cfg_data_width = $clog2(DATA_WIDTH+1)'(DATA_WIDTH);
                m_cfg_wr_en    = 1'b1;
                s_cfg_wr_en    = 1'b1;
                repeat (3) @(posedge clk_m);

                m_word = '1;
                s_word = '0;

                @(posedge clk_m);
                m_tx_data  <= m_word;
                m_tx_valid <= 1'b1;
                s_tx_data  <= s_word;
                s_tx_valid <= 1'b1;
                expect_master_rx <= s_word;
                expect_slave_rx  <= m_word;
                master_rx_seen   = 1'b0;
                slave_rx_seen    = 1'b0;

                @(posedge clk_m);
                m_tx_valid <= 1'b0;
                s_tx_valid <= 1'b0;
                s_rx_ack   <= 1'b0;

                repeat (glitch_point) @(posedge clk_m);
                if (!(m_busy && s_busy)) begin
                    errors = errors + 1;
                    $display("[%0t] FAIL data-width mid-transfer test setup: not busy at glitch point", $time);
                end

                cfg_data_width = $clog2(DATA_WIDTH+1)'(NARROW_WIDTH);

                wait_cycles = 0;
                while (!(master_rx_seen && slave_rx_seen) && wait_cycles < 200000) begin
                    @(posedge clk_m);
                    if (m_rx_valid) begin
                        checks = checks + 1;
                        if (m_rx_data !== expect_master_rx) begin
                            errors = errors + 1;
                            $display("[%0t] FAIL master rx (data-width mid-xfer glitch): expected=%0h got=%0h",
                                      $time, expect_master_rx, m_rx_data);
                        end
                        master_rx_seen = 1'b1;
                    end
                    if (s_rx_valid_sticky && !slave_rx_seen) begin
                        checks = checks + 1;
                        if (s_rx_data_sticky !== expect_slave_rx) begin
                            errors = errors + 1;
                            $display("[%0t] FAIL slave rx (data-width mid-xfer glitch): expected=%0h got=%0h",
                                      $time, expect_slave_rx, s_rx_data_sticky);
                        end
                        slave_rx_seen = 1'b1;
                    end
                    wait_cycles = wait_cycles + 1;
                end

                s_rx_ack <= 1'b1;
                @(posedge clk_m);
                s_rx_ack <= 1'b0;
                @(posedge clk_m);

                if (!(master_rx_seen && slave_rx_seen)) begin
                    errors = errors + 1;
                    $display("[%0t] FAIL timeout waiting for data-width mid-xfer glitch transfer completion", $time);
                end

                // No dedicated cfg_wr_en pulse was struck above (wr_en stayed
                // high throughout, same as run_mid_transfer_glitch_test), so
                // the shadow register already holds NARROW_WIDTH; this next
                // transfer should adopt it with no further write, proving
                // the "auto-apply once idle" behavior extends to data width
                // exactly as it already does for cpol/cpha/lsb_first/clk_div.
                m_word = '1;
                s_word = '1;
                m_word[DATA_WIDTH-1:NARROW_WIDTH] = '0;
                s_word[DATA_WIDTH-1:NARROW_WIDTH] = '0;

                @(posedge clk_m);
                m_tx_data  <= m_word;
                m_tx_valid <= 1'b1;
                s_tx_data  <= s_word;
                s_tx_valid <= 1'b1;
                expect_master_rx <= s_word;
                expect_slave_rx  <= m_word;
                master_rx_seen   = 1'b0;
                slave_rx_seen    = 1'b0;

                @(posedge clk_m);
                m_tx_valid <= 1'b0;
                s_tx_valid <= 1'b0;
                s_rx_ack   <= 1'b0;

                wait_cycles = 0;
                while (!(master_rx_seen && slave_rx_seen) && wait_cycles < 200000) begin
                    @(posedge clk_m);
                    if (m_rx_valid) begin
                        checks = checks + 1;
                        if (m_rx_data !== expect_master_rx) begin
                            errors = errors + 1;
                            $display("[%0t] FAIL master rx (data-width auto-apply): expected=%0h got=%0h",
                                      $time, expect_master_rx, m_rx_data);
                        end
                        master_rx_seen = 1'b1;
                    end
                    if (s_rx_valid_sticky && !slave_rx_seen) begin
                        checks = checks + 1;
                        if (s_rx_data_sticky !== expect_slave_rx) begin
                            errors = errors + 1;
                            $display("[%0t] FAIL slave rx (data-width auto-apply): expected=%0h got=%0h",
                                      $time, expect_slave_rx, s_rx_data_sticky);
                        end
                        slave_rx_seen = 1'b1;
                    end
                    wait_cycles = wait_cycles + 1;
                end

                s_rx_ack <= 1'b1;
                @(posedge clk_m);
                s_rx_ack <= 1'b0;
                @(posedge clk_m);

                if (!(master_rx_seen && slave_rx_seen)) begin
                    errors = errors + 1;
                    $display("[%0t] FAIL timeout waiting for data-width auto-apply transfer completion", $time);
                end

                cfg_data_width = $clog2(DATA_WIDTH+1)'(DATA_WIDTH);
                repeat (3) @(posedge clk_m);
            end

            $display("Runtime data-width mid-transfer test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask
    // verilator lint_on INITIALDLY
    end else begin : g_data_width_tests
        task automatic run_data_width_test;
            $display("Runtime data-width test skipped (DATA_WIDTH=%0d has no narrower width to try)", DATA_WIDTH);
        endtask
        task automatic run_data_width_mid_transfer_test;
            $display("Runtime data-width mid-transfer test skipped (DATA_WIDTH=%0d)", DATA_WIDTH);
        endtask
    end
    endgenerate

    // Exercises rst_n asserted while busy=1, which none of the mode/width
    // sweeps or config-timing tests above ever touch (they only reset at
    // the very start of simulation). Reuses XFER_CYCLES/BASELINE_DIV so
    // the reset point scales with DATA_WIDTH the same way the glitch
    // tests do. Two scenarios:
    //   A) reset both master and slave mid-transfer -- the straightforward
    //      "whole-system reset" case.
    //   B) reset only the master -- the slave is never reset itself, so
    //      this proves the master's reset-forced ss_n deassertion alone
    //      (an async effect, visible even while rst_n is still held low)
    //      is enough to make the slave's own frame_end fire and return it
    //      to idle too, once that deassertion propagates through its CDC
    //      synchronizer.
    // Both scenarios end with a normal do_transfer to prove the core
    // isn't merely idle-*looking* after reset but genuinely usable again.
    // verilator lint_off INITIALDLY
    task automatic run_mid_transfer_reset_test;
        int unsigned reset_point;
        int wait_cycles;
        logic [DATA_WIDTH-1:0] pat_a;
        logic [DATA_WIDTH-1:0] pat_b;
        begin
            reset_point = (XFER_CYCLES / 2 > 3) ? XFER_CYCLES / 2 : 3;

            // --- Scenario A: reset both master and slave mid-transfer ---
            set_baseline_cfg();

            @(posedge clk_m);
            m_tx_data  <= '1;
            m_tx_valid <= 1'b1;
            s_tx_data  <= '0;
            s_tx_valid <= 1'b1;
            @(posedge clk_m);
            m_tx_valid <= 1'b0;
            s_tx_valid <= 1'b0;

            repeat (reset_point) @(posedge clk_m);
            if (!(m_busy && s_busy)) begin
                errors = errors + 1;
                $display("[%0t] FAIL reset test setup (both): transfer not busy before reset", $time);
            end

            rst_n_m = 1'b0;
            rst_n_s = 1'b0;
            repeat (3) @(posedge clk_m);

            // rst_n is asynchronous, so its effect must already be visible
            // while still held low, not merely after release.
            if (ss_n_w !== 1'b1) begin
                errors = errors + 1;
                $display("[%0t] FAIL mid-transfer reset (both): ss_n_w=%0b while held in reset, expected 1 (deasserted)",
                          $time, ss_n_w);
            end
            checks = checks + 1;
            if (m_busy !== 1'b0 || s_busy !== 1'b0) begin
                errors = errors + 1;
                $display("[%0t] FAIL mid-transfer reset (both): m_busy=%0b s_busy=%0b while held in reset, expected both 0",
                          $time, m_busy, s_busy);
            end
            checks = checks + 1;

            rst_n_m = 1'b1;
            rst_n_s = 1'b1;
            repeat (5) @(posedge clk_m);

            if (!(m_tx_ready && s_tx_ready && !m_busy && !s_busy && ss_n_w)) begin
                errors = errors + 1;
                $display("[%0t] FAIL mid-transfer reset (both): not cleanly idle after release (m_tx_ready=%0b s_tx_ready=%0b m_busy=%0b s_busy=%0b ss_n_w=%0b)",
                          $time, m_tx_ready, s_tx_ready, m_busy, s_busy, ss_n_w);
            end
            checks = checks + 1;

            // verilator lint_off WIDTHTRUNC
            pat_a = $urandom(seed);
            pat_b = $urandom(seed);
            // verilator lint_on WIDTHTRUNC
            do_transfer(pat_a, pat_b);

            // --- Scenario B: reset only the master; slave is never reset ---
            set_baseline_cfg();

            @(posedge clk_m);
            m_tx_data  <= '0;
            m_tx_valid <= 1'b1;
            s_tx_data  <= '1;
            s_tx_valid <= 1'b1;
            @(posedge clk_m);
            m_tx_valid <= 1'b0;
            s_tx_valid <= 1'b0;

            repeat (reset_point) @(posedge clk_m);
            if (!(m_busy && s_busy)) begin
                errors = errors + 1;
                $display("[%0t] FAIL reset test setup (master-only): transfer not busy before reset", $time);
            end

            rst_n_m = 1'b0;
            repeat (3) @(posedge clk_m);

            if (ss_n_w !== 1'b1) begin
                errors = errors + 1;
                $display("[%0t] FAIL mid-transfer reset (master-only): ss_n_w=%0b while master held in reset, expected 1 (deasserted)",
                          $time, ss_n_w);
            end
            checks = checks + 1;
            if (m_busy !== 1'b0) begin
                errors = errors + 1;
                $display("[%0t] FAIL mid-transfer reset (master-only): m_busy=%0b while held in reset, expected 0",
                          $time, m_busy);
            end
            checks = checks + 1;

            rst_n_m = 1'b1;

            // The slave was never reset -- it must instead notice the
            // master's forced ss_n deassertion through its own
            // synchronizer and frame_end logic. Poll rather than assume a
            // fixed cycle count, since that propagation delay is a fixed
            // number of clk_s cycles independent of DATA_WIDTH/BASELINE_DIV.
            wait_cycles = 0;
            while (s_busy && wait_cycles < 1000) begin
                @(posedge clk_m);
                wait_cycles = wait_cycles + 1;
            end
            if (s_busy) begin
                errors = errors + 1;
                $display("[%0t] FAIL mid-transfer reset (master-only): slave never saw ss_n deassert and remained busy",
                          $time);
            end
            checks = checks + 1;

            repeat (5) @(posedge clk_m);
            if (!(m_tx_ready && s_tx_ready)) begin
                errors = errors + 1;
                $display("[%0t] FAIL mid-transfer reset (master-only): not cleanly idle after release (m_tx_ready=%0b s_tx_ready=%0b)",
                          $time, m_tx_ready, s_tx_ready);
            end
            checks = checks + 1;

            // The slave was never reset, so its frame_end logic ran its
            // normal course when the master's forced ss_n deassertion
            // arrived mid-frame -- from the slave's perspective this is
            // indistinguishable from a legitimately short frame, so it
            // faithfully produces an rx_valid pulse (with whatever
            // garbage partial bits it had shifted in by that point). That
            // pulse is expected here and must be drained before trusting
            // the next do_transfer's checks, or the sticky latch below
            // would hand this stale garbage to the very next transfer's
            // checker instead of that transfer's real data.
            s_rx_ack <= 1'b1;
            @(posedge clk_m);
            s_rx_ack <= 1'b0;
            @(posedge clk_m);

            // verilator lint_off WIDTHTRUNC
            pat_a = $urandom(seed);
            pat_b = $urandom(seed);
            // verilator lint_on WIDTHTRUNC
            do_transfer(pat_a, pat_b);

            $display("Mid-transfer reset test done. checks=%0d errors=%0d", checks, errors);
        end
    endtask
    // verilator lint_on INITIALDLY

    task automatic run_config(input int cpol_i, input int cpha_i,
                               input int lsb_i, input logic [CLK_DIV_WIDTH-1:0] div_i);
        int i;
        logic [DATA_WIDTH-1:0] rnd_m;
        logic [DATA_WIDTH-1:0] rnd_s;
        begin
            cfg_cpol      = cpol_i[0];
            cfg_cpha      = cpha_i[0];
            cfg_lsb_first = lsb_i[0];
            cfg_clk_div   = div_i;

            // Shadow registers (see docs/README.md) only pick up a cfg_*
            // change on the next clk_m/clk_s edge of their own clock
            // domain; this settle delay mirrors the wait a real driver
            // would need after a register write before relying on it, and
            // is comfortably >1 clk_s period (the faster of the two clocks)
            // as well as >1 clk_m period.
            repeat (3) @(posedge clk_m);

            do_transfer('0, '1);
            do_transfer('1, '0);

            // verilator lint_off WIDTHTRUNC
            // $urandom returns a full 32-bit value; truncating to
            // DATA_WIDTH bits here is exactly how the 8-bit random test
            // words are generated, not an accidental narrowing.
            for (i = 0; i < 25; i = i + 1) begin
                rnd_m = $urandom(seed);
                rnd_s = $urandom(seed);
                do_transfer(rnd_m, rnd_s);
            end
            // verilator lint_on WIDTHTRUNC

            $display("Config cpol=%0d cpha=%0d lsb_first=%0d clk_div=%0d done. checks=%0d errors=%0d",
                      cpol_i, cpha_i, lsb_i, div_i, checks, errors);
        end
    endtask

    int cpol_v, cpha_v, lsb_v, div_idx;
    logic [CLK_DIV_WIDTH-1:0] div_values [0:1];

    initial begin
        div_values[0] = 16'd1;
        div_values[1] = 16'd4;

        errors     = 0;
        checks     = 0;
        m_tx_data  = 0;
        m_tx_valid = 0;
        s_tx_data  = 0;
        s_tx_valid = 0;
        s_rx_ack   = 0;
        cfg_cpol      = 0;
        cfg_cpha      = 0;
        cfg_lsb_first = 0;
        cfg_clk_div   = 1;
        cfg_data_width = $clog2(DATA_WIDTH+1)'(DATA_WIDTH);
        m_cfg_wr_en   = 1;
        s_cfg_wr_en   = 1;

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
                    for (div_idx = 0; div_idx < 2; div_idx = div_idx + 1) begin
                        run_config(cpol_v, cpha_v, lsb_v, div_values[div_idx]);
                    end
                end
            end
        end

        run_mid_transfer_glitch_test();
        run_cfg_wr_en_gate_test();
        run_cfg_apply_after_idle_test();
        run_cfg_write_pulse_during_busy_test();
        g_data_width_tests.run_data_width_test();
        g_data_width_tests.run_data_width_mid_transfer_test();
        run_mid_transfer_reset_test();

        $display("==============================================");
        $display("TOTAL CHECKS: %0d", checks);
        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("TESTS FAILED: %0d", errors);
        end
        $display("==============================================");

        if (errors != 0) begin
            $fatal(1, "SPI loopback test failed with %0d errors", errors);
        end

        $finish;
    end

    initial begin
        $dumpfile(VCD_PATH);
        $dumpvars(0, tb_spi_loopback);
    end

    initial begin
        #200000000;
        $display("WATCHDOG TIMEOUT");
        $fatal(1, "Global watchdog timeout");
    end

endmodule
