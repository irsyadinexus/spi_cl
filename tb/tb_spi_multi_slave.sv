`timescale 1ns / 1ps

// Exercises a real multi-drop SPI bus: one master, several slaves sharing
// mosi/sclk/miso, each slave with its own dedicated ss_n line decoded from
// the master's single ss_n by an external chip-select demux (modeled here
// in the testbench, since spi_master itself only has one ss_n output --
// real systems route it through GPIOs or an address decoder). This is a
// different scenario from tb_spi_loopback.sv's point-to-point pairing and
// specifically targets bus-sharing correctness: only the addressed slave
// should ever drive miso or advance its own state.
module tb_spi_multi_slave #(
    parameter int DATA_WIDTH = 8,
    parameter int NUM_SLAVES = 3
) ();

    localparam int CLK_DIV_WIDTH = 16;

`ifdef VERILATOR
    localparam string VCD_PATH = "../waves/verilator_multi_slave.vcd";
`else
    localparam string VCD_PATH = "../waves/iverilog_multi_slave.vcd";
`endif

    // verilator lint_off BLKSEQ
    logic clk_m;
    logic clk_s;
    logic rst_n_m;
    logic rst_n_s;

    initial clk_m = 1'b0;
    always #5 clk_m = ~clk_m;

    // All slaves share one clk_s domain here -- CDC correctness between
    // clk_m and clk_s is already covered per-slave by tb_spi_loopback.sv;
    // this testbench's job is bus-sharing/selection, not re-proving CDC.
    initial clk_s = 1'b0;
    always #2 clk_s = ~clk_s;
    // verilator lint_on BLKSEQ

    logic                     cfg_cpol;
    logic                     cfg_cpha;
    logic                     cfg_lsb_first;
    logic [CLK_DIV_WIDTH-1:0] cfg_clk_div;
    logic                     m_cfg_wr_en;
    logic                     s_cfg_wr_en;

    // verilator lint_off UNUSEDSIGNAL
    logic [DATA_WIDTH-1:0] m_tx_data;
    logic                  m_tx_valid;
    logic                  m_tx_ready;
    logic [DATA_WIDTH-1:0] m_rx_data;
    logic                  m_rx_valid;
    logic                  m_busy;
    // verilator lint_on UNUSEDSIGNAL

    wire ss_n_m_w;
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
        .cfg_data_width($clog2(DATA_WIDTH+1)'(DATA_WIDTH)),
        .tx_data      (m_tx_data),
        .tx_valid     (m_tx_valid),
        .tx_ready     (m_tx_ready),
        .rx_data      (m_rx_data),
        .rx_valid     (m_rx_valid),
        .busy         (m_busy),
        .ss_n         (ss_n_m_w),
        .sclk         (sclk_w),
        .mosi         (mosi_w),
        .miso         (miso_w)
    );

    // Each slave gets its own fixed tx_data "signature" byte instead of a
    // per-transfer value: since a slave unconditionally latches whatever
    // is on tx_data at its own frame_start, holding it constant lets the
    // checker identify which physical slave actually answered purely from
    // what the master received back, independent of tracking per-slave
    // expected values across transfers.
    function automatic logic [DATA_WIDTH-1:0] slave_sig(input int idx);
        slave_sig = DATA_WIDTH'(idx + 1);
    endfunction

    // int selected_slave chooses which slave's ss_n follows the master's
    // ss_n_m_w (an external chip-select demux would do this from an
    // address register); every other slave's ss_n is tied deasserted
    // regardless of what the master drives, so only one slave is ever
    // addressed at a time.
    int selected_slave;

    logic [DATA_WIDTH-1:0] s_rx_data   [NUM_SLAVES];
    logic                  s_rx_valid  [NUM_SLAVES];
    logic                  s_busy      [NUM_SLAVES];
    // verilator lint_off UNUSEDSIGNAL
    // Wired up and dumped to the VCD for waveform inspection but not read
    // by the checker logic, same rationale as tb_spi_loopback.sv's
    // tx_ready/busy.
    logic                  s_tx_ready  [NUM_SLAVES];
    // verilator lint_on UNUSEDSIGNAL
    // wire, not logic: each bit is continuously assigned below and also
    // connected to spi_top's inout ss_n port, which requires a net (not a
    // variable) on the connecting side. A packed vector rather than an
    // unpacked array specifically because Verilator does not support a
    // tristate inout port connected via an unpacked-array bit-select
    // (ARRAYSEL), only a packed-vector bit-select.
    // verilator lint_off UNUSEDSIGNAL
    // The unused-signal check doesn't trace usage through an inout port
    // connection, so it flags this as unread even though every bit is
    // both driven (below) and consumed as each spi_top slave instance's
    // ss_n.
    wire [NUM_SLAVES-1:0] ss_n_slave;
    // verilator lint_on UNUSEDSIGNAL

    logic                  s_rx_valid_sticky [NUM_SLAVES];
    logic [DATA_WIDTH-1:0] s_rx_data_sticky  [NUM_SLAVES];
    logic                  s_rx_ack          [NUM_SLAVES];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_SLAVES; gi = gi + 1) begin : g_slave

            assign ss_n_slave[gi] = (selected_slave == gi) ? ss_n_m_w : 1'b1;

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
                .cfg_data_width($clog2(DATA_WIDTH+1)'(DATA_WIDTH)),
                .tx_data      (slave_sig(gi)),
                .tx_valid     (1'b1),
                .tx_ready     (s_tx_ready[gi]),
                .rx_data      (s_rx_data[gi]),
                .rx_valid     (s_rx_valid[gi]),
                .busy         (s_busy[gi]),
                .ss_n         (ss_n_slave[gi]),
                .sclk         (sclk_w),
                .mosi         (mosi_w),
                .miso         (miso_w)
            );

            // Same sticky-latch rationale as tb_spi_loopback.sv: rx_valid
            // pulses for one clk_s cycle, shorter than the clk_m period the
            // checker below polls on.
            always_ff @(posedge clk_s or negedge rst_n_s) begin
                if (!rst_n_s) begin
                    s_rx_valid_sticky[gi] <= 1'b0;
                    s_rx_data_sticky[gi]  <= '0;
                end else begin
                    if (s_rx_valid[gi]) begin
                        s_rx_valid_sticky[gi] <= 1'b1;
                        s_rx_data_sticky[gi]  <= s_rx_data[gi];
                    end else if (s_rx_ack[gi]) begin
                        s_rx_valid_sticky[gi] <= 1'b0;
                    end
                end
            end

        end
    endgenerate

    int unsigned seed = 32'hBEEF5;
    int errors;
    int checks;

    logic [DATA_WIDTH-1:0] expect_master_rx;
    logic [DATA_WIDTH-1:0] expect_slave_rx;
    logic                  master_rx_seen;
    logic                  slave_rx_seen;

    // verilator lint_off INITIALDLY
    // Drives one transfer addressed at slave `idx` (selected_slave must be
    // set before this task's first @(posedge clk_m), since ss_n_slave[]'s
    // demux reads it combinationally the moment ss_n_m_w asserts). Checks:
    //  1. the addressed slave receives m_word correctly;
    //  2. the master receives that slave's fixed signature byte back,
    //     proving the *right* physical slave answered;
    //  3. every other slave's busy/rx_valid never fire (they never saw
    //     frame_start, since their ss_n stayed deasserted throughout);
    //  4. miso_w never resolves to 'x' during the transfer, which is
    //     exactly what would happen if a deselected slave were still
    //     driving the shared bus (the bug this testbench targets in
    //     rtl/spi_slave.sv's miso_oe / rtl/spi_top.sv's tri-state gating).
    task automatic do_transfer_to_slave(input int idx,
                                         input logic [DATA_WIDTH-1:0] m_word);
        int wait_cycles;
        int i;
        begin
            selected_slave = idx;
            @(posedge clk_m);
            m_tx_data  <= m_word;
            m_tx_valid <= 1'b1;
            expect_master_rx <= slave_sig(idx);
            expect_slave_rx  <= m_word;
            master_rx_seen   = 1'b0;
            slave_rx_seen    = 1'b0;

            @(posedge clk_m);
            m_tx_valid <= 1'b0;
            for (i = 0; i < NUM_SLAVES; i = i + 1)
                s_rx_ack[i] <= 1'b0;

            wait_cycles = 0;
            while (!(master_rx_seen && slave_rx_seen) && wait_cycles < 200000) begin
                @(posedge clk_m);

                if (miso_w === 1'bx) begin
                    errors = errors + 1;
                    $display("[%0t] FAIL bus contention: miso_w is X while slave %0d addressed",
                              $time, idx);
                end

                for (i = 0; i < NUM_SLAVES; i = i + 1) begin
                    if (i != idx && (s_busy[i] || s_rx_valid[i])) begin
                        errors = errors + 1;
                        $display("[%0t] FAIL deselected slave %0d advanced during a transfer addressed at slave %0d (s_busy=%0b s_rx_valid=%0b)",
                                  $time, i, idx, s_busy[i], s_rx_valid[i]);
                    end
                end

                if (m_rx_valid) begin
                    checks = checks + 1;
                    if (m_rx_data !== expect_master_rx) begin
                        errors = errors + 1;
                        $display("[%0t] FAIL master rx (slave %0d addressed): expected=%0h got=%0h",
                                 $time, idx, expect_master_rx, m_rx_data);
                    end
                    master_rx_seen = 1'b1;
                end
                if (s_rx_valid_sticky[idx] && !slave_rx_seen) begin
                    checks = checks + 1;
                    if (s_rx_data_sticky[idx] !== expect_slave_rx) begin
                        errors = errors + 1;
                        $display("[%0t] FAIL slave %0d rx: expected=%0h got=%0h",
                                 $time, idx, expect_slave_rx, s_rx_data_sticky[idx]);
                    end
                    slave_rx_seen = 1'b1;
                end
                wait_cycles = wait_cycles + 1;
            end

            s_rx_ack[idx] <= 1'b1;
            @(posedge clk_m);
            s_rx_ack[idx] <= 1'b0;
            @(posedge clk_m);

            if (!(master_rx_seen && slave_rx_seen)) begin
                errors = errors + 1;
                $display("[%0t] FAIL timeout waiting for transfer completion (slave %0d addressed)",
                          $time, idx);
            end

            @(posedge clk_m);
        end
    endtask
    // verilator lint_on INITIALDLY

    int cpol_v, cpha_v, i, round_idx;
    logic [DATA_WIDTH-1:0] rnd_word;

    initial begin
        errors        = 0;
        checks        = 0;
        m_tx_data     = 0;
        m_tx_valid    = 0;
        selected_slave = 0;
        cfg_cpol      = 0;
        cfg_cpha      = 0;
        cfg_lsb_first = 0;
        cfg_clk_div   = 1;
        m_cfg_wr_en   = 1;
        s_cfg_wr_en   = 1;
        for (i = 0; i < NUM_SLAVES; i = i + 1)
            s_rx_ack[i] = 0;

        rst_n_m = 1'b0;
        rst_n_s = 1'b0;
        repeat (5) @(posedge clk_m);
        repeat (5) @(posedge clk_s);
        rst_n_m = 1'b1;
        rst_n_s = 1'b1;
        repeat (5) @(posedge clk_m);

        // Sweep all 4 SPI modes (bus-sharing is mode-independent in
        // principle, but this confirms the tri-state fix holds under
        // every sample/shift-edge combination, not just mode 0) and, per
        // mode, both an exhaustive round-robin over every slave and a
        // randomized selection order with random data, so the addressed
        // slave changes unpredictably between back-to-back transfers.
        for (cpol_v = 0; cpol_v < 2; cpol_v = cpol_v + 1) begin
            for (cpha_v = 0; cpha_v < 2; cpha_v = cpha_v + 1) begin
                cfg_cpol = cpol_v[0];
                cfg_cpha = cpha_v[0];
                repeat (3) @(posedge clk_m);

                for (round_idx = 0; round_idx < NUM_SLAVES; round_idx = round_idx + 1) begin
                    // verilator lint_off WIDTHTRUNC
                    rnd_word = $urandom(seed);
                    // verilator lint_on WIDTHTRUNC
                    do_transfer_to_slave(round_idx, rnd_word);
                end

                for (i = 0; i < 12; i = i + 1) begin
                    // verilator lint_off WIDTHTRUNC
                    rnd_word = $urandom(seed);
                    // verilator lint_on WIDTHTRUNC
                    do_transfer_to_slave($urandom(seed) % NUM_SLAVES, rnd_word);
                end

                $display("Mode cpol=%0d cpha=%0d multi-slave sweep done. checks=%0d errors=%0d",
                          cpol_v, cpha_v, checks, errors);
            end
        end

        $display("==============================================");
        $display("TOTAL CHECKS: %0d", checks);
        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("TESTS FAILED: %0d", errors);
        end
        $display("==============================================");

        if (errors != 0) begin
            $fatal(1, "SPI multi-slave test failed with %0d errors", errors);
        end

        $finish;
    end

    initial begin
        $dumpfile(VCD_PATH);
        $dumpvars(0, tb_spi_multi_slave);
    end

    initial begin
        #200000000;
        $display("WATCHDOG TIMEOUT");
        $fatal(1, "Global watchdog timeout");
    end

endmodule
