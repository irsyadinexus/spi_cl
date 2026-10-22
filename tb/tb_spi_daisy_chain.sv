`timescale 1ns / 1ps

// Exercises a daisy-chained SPI slave topology: several spi_slave cores
// sharing one ss_n and one sclk, with mosi/miso chained point-to-point
// (master -> slave[0].mosi, slave[i].miso -> slave[i+1].mosi, ...,
// slave[N-1].miso -> master), so the whole chain behaves as one long
// shift register spanning N*DATA_WIDTH bits. This is a different SPI
// topology from tb_spi_multi_slave.sv's multi-drop bus (shared mosi/
// miso, one ss_n per slave): here ss_n/sclk are shared and mosi/miso are
// per-link, the opposite split.
//
// spi_master only supports single-word-per-ss_n-assertion transfers (see
// docs/README.md), so it cannot drive the ss_n-held-low-for-many-words
// transaction a daisy chain needs. This testbench instead uses a
// bit-banged virtual master (driving ss_n/sclk/mosi directly and
// sampling miso, mode-aware per CPOL/CPHA) so the daisy-chain slave-side
// behavior can be tested without also having to add burst-mode support
// to spi_master. spi_slave instances are used directly (not spi_top):
// each miso here is a dedicated point-to-point link, not a shared bus,
// so there is no tri-state/miso_oe need the way tb_spi_multi_slave.sv has.
module tb_spi_daisy_chain #(
    parameter int DATA_WIDTH = 8,
    parameter int NUM_SLAVES = 3
) ();

`ifdef VERILATOR
    localparam string VCD_PATH = "../waves/verilator_daisy_chain.vcd";
`else
    localparam string VCD_PATH = "../waves/iverilog_daisy_chain.vcd";
`endif

    // verilator lint_off BLKSEQ
    logic clk_s;
    logic rst_n_s;

    initial clk_s = 1'b0;
    always #2 clk_s = ~clk_s;
    // verilator lint_on BLKSEQ

    logic cfg_wr_en;
    logic cfg_cpol;
    logic cfg_cpha;
    logic cfg_lsb_first;

    // Bit-banged virtual master's own SPI pins, driven/sampled entirely
    // by the tasks below rather than by any spi_master instance.
    logic v_ss_n;
    logic v_sclk;
    logic v_mosi;
    wire  v_miso;

    logic [DATA_WIDTH-1:0] slave_tx_data  [NUM_SLAVES];
    logic [DATA_WIDTH-1:0] slave_rx_data  [NUM_SLAVES];
    logic                  slave_busy     [NUM_SLAVES];
    // verilator lint_off UNUSEDSIGNAL
    // Not read by the checker (busy is what's checked for a clean
    // frame_end below), but wired up and dumped to the VCD for waveform
    // inspection.
    logic                  slave_rx_valid [NUM_SLAVES];
    logic                  slave_tx_ready [NUM_SLAVES];
    // verilator lint_on UNUSEDSIGNAL

    // mosi_link[0] is the virtual master's own mosi; mosi_link[i] for
    // i>0 is slave[i-1]'s miso, chaining the slaves point-to-point.
    // v_miso (the virtual master's miso input) is the last slave's miso.
    wire mosi_link [NUM_SLAVES];
    wire miso_link [NUM_SLAVES];
    // verilator lint_off UNUSEDSIGNAL
    // Point-to-point miso links here don't need the tri-state output
    // enable spi_top uses for a shared multi-drop bus (see
    // tb_spi_multi_slave.sv); wired up only because miso_oe is a real
    // output port that must be connected to something.
    wire slave_miso_oe [NUM_SLAVES];
    // verilator lint_on UNUSEDSIGNAL
    assign mosi_link[0] = v_mosi;
    assign v_miso = miso_link[NUM_SLAVES - 1];

    genvar gi;
    generate
        for (gi = 1; gi < NUM_SLAVES; gi = gi + 1) begin : g_link
            assign mosi_link[gi] = miso_link[gi - 1];
        end
    endgenerate

    generate
        for (gi = 0; gi < NUM_SLAVES; gi = gi + 1) begin : g_slave
            spi_slave #(
                .DATA_WIDTH(DATA_WIDTH)
            ) u_slave (
                .clk          (clk_s),
                .rst_n        (rst_n_s),
                .cfg_wr_en    (cfg_wr_en),
                .cfg_cpol     (cfg_cpol),
                .cfg_cpha     (cfg_cpha),
                .cfg_lsb_first(cfg_lsb_first),
                .cfg_data_width($clog2(DATA_WIDTH+1)'(DATA_WIDTH)),
                .tx_data      (slave_tx_data[gi]),
                .tx_valid     (1'b1),
                .tx_ready     (slave_tx_ready[gi]),
                .rx_data      (slave_rx_data[gi]),
                .rx_valid     (slave_rx_valid[gi]),
                .busy         (slave_busy[gi]),
                .ss_n         (v_ss_n),
                .sclk         (v_sclk),
                .mosi         (mosi_link[gi]),
                .miso         (miso_link[gi]),
                .miso_oe      (slave_miso_oe[gi])
            );
        end
    endgenerate

    int unsigned seed = 32'hDA15EC;
    int errors;
    int checks;

    // Generous margin between edges/setup points: clk_s's period is 4ns,
    // so a 20ns quantum gives each spi_slave's 2-stage synchronizer plus
    // edge-detect plus registered-output pipeline (a handful of clk_s
    // cycles of latency) comfortable room to settle before the next
    // transition, matching the oversampling margin philosophy
    // tb_spi_loopback.sv/tb_spi_multi_slave.sv use with a real clk_m-
    // driven sclk.
    localparam time V_QUANTUM = 20;

    // verilator lint_off INITIALDLY
    // One SPI bit period, mode-aware: presents mosi_bit ahead of the
    // leading edge (valid setup time for either CPHA, since leading
    // always precedes trailing), and samples miso_bit on whichever edge
    // this mode's master would sample on (leading for CPHA=0, trailing
    // for CPHA=1) -- mirroring spi_master's own sample_edge convention
    // exactly, so "what the virtual master receives" means the same
    // thing here as it does for the real master core.
    task automatic v_clock_one_bit(input logic mosi_bit, output logic miso_bit);
        begin
            v_mosi = mosi_bit;
            #V_QUANTUM;

            v_sclk = ~cfg_cpol;
            #V_QUANTUM;
            if (!cfg_cpha) miso_bit = v_miso;

            v_sclk = cfg_cpol;
            #V_QUANTUM;
            if (cfg_cpha) miso_bit = v_miso;
        end
    endtask

    // Module-level (not task-port) arrays: iverilog does not support
    // unpacked-array subroutine ports, so v_chain_transfer/run_chain_round
    // below read/write these shared arrays directly instead of passing
    // arrays through task arguments.
    logic [DATA_WIDTH-1:0] g_words_out [NUM_SLAVES];
    logic [DATA_WIDTH-1:0] g_words_in  [NUM_SLAVES];
    logic [DATA_WIDTH-1:0] g_slave_sig [NUM_SLAVES];

    // Drives one whole chain transaction from g_words_out (g_words_out[i]
    // is the word intended for slave[i]). Internally sends them
    // farthest-slave-first (g_words_out[NUM_SLAVES-1] first,
    // g_words_out[0] last), matching how a chain of N DATA_WIDTH-bit
    // shift-register stages naturally ends up holding the *last*
    // DATA_WIDTH bits shifted in at the nearest stage (slave[0]) and the
    // *first* DATA_WIDTH bits shifted in at the farthest stage
    // (slave[NUM_SLAVES-1]). g_words_in[i] collects what the virtual
    // master received during the i-th DATA_WIDTH-bit window (i=0 first),
    // which -- per the same shift-register argument applied to the miso
    // direction -- should equal slave[NUM_SLAVES-1-i]'s own preloaded
    // tx_data, each slave's signature arriving in the reverse of the
    // order its rx word was sent.
    task automatic v_chain_transfer;
        int i, b;
        logic [DATA_WIDTH-1:0] word;
        logic mosi_bit, miso_bit;
        begin
            v_ss_n = 1'b0;
            repeat (5) @(posedge clk_s);

            for (i = NUM_SLAVES - 1; i >= 0; i = i - 1) begin
                word = g_words_out[i];
                for (b = 0; b < DATA_WIDTH; b = b + 1) begin
                    mosi_bit = cfg_lsb_first ? word[b] : word[DATA_WIDTH - 1 - b];
                    v_clock_one_bit(mosi_bit, miso_bit);
                    if (cfg_lsb_first)
                        g_words_in[NUM_SLAVES - 1 - i][b] = miso_bit;
                    else
                        g_words_in[NUM_SLAVES - 1 - i][DATA_WIDTH - 1 - b] = miso_bit;
                end
            end

            repeat (5) @(posedge clk_s);
            v_ss_n = 1'b1;
            repeat (10) @(posedge clk_s);
        end
    endtask
    // verilator lint_on INITIALDLY

    task automatic check_word(input logic [DATA_WIDTH-1:0] got, input logic [DATA_WIDTH-1:0] expected,
                               input string what);
        begin
            checks = checks + 1;
            if (got !== expected) begin
                errors = errors + 1;
                $display("[%0t] FAIL %s: expected=%0h got=%0h", $time, what, expected, got);
            end
        end
    endtask

    // g_words_out[i] is the word the virtual master intends for slave[i]
    // (checked against slave[i].rx_data, set by the caller before this
    // task runs). g_slave_sig[i] is an *independent* random word
    // preloaded as slave[i]'s own tx_data, deliberately not derived from
    // g_words_out: predicting what the virtual master receives back
    // (g_words_in) from g_slave_sig alone, with no algebraic relationship
    // to g_words_out, means a bug that reverses or mixes up both the RX
    // and TX chain directions the same way cannot cancel out and slip
    // past both checks at once.
    task automatic run_chain_round(input int cpol_i, input int cpha_i, input int lsb_i);
        int i;
        begin
            cfg_cpol      = cpol_i[0];
            cfg_cpha      = cpha_i[0];
            cfg_lsb_first = lsb_i[0];
            for (i = 0; i < NUM_SLAVES; i = i + 1) begin
                // verilator lint_off WIDTHTRUNC
                g_slave_sig[i] = $urandom(seed);
                // verilator lint_on WIDTHTRUNC
                slave_tx_data[i] = g_slave_sig[i];
            end
            v_sclk = cfg_cpol;
            repeat (5) @(posedge clk_s);

            v_chain_transfer();

            for (i = 0; i < NUM_SLAVES; i = i + 1) begin
                checks = checks + 1;
                if (slave_busy[i]) begin
                    errors = errors + 1;
                    $display("[%0t] FAIL slave[%0d] still busy after frame_end", $time, i);
                end
            end

            for (i = 0; i < NUM_SLAVES; i = i + 1)
                check_word(slave_rx_data[i], g_words_out[i], $sformatf("slave[%0d] rx_data", i));

            for (i = 0; i < NUM_SLAVES; i = i + 1)
                check_word(g_words_in[i], g_slave_sig[NUM_SLAVES - 1 - i],
                            $sformatf("virtual-master rx chunk %0d (slave[%0d]'s signature)", i, NUM_SLAVES - 1 - i));

            $display("Daisy chain cpol=%0d cpha=%0d lsb=%0d done. checks=%0d errors=%0d",
                      cpol_i, cpha_i, lsb_i, checks, errors);
        end
    endtask

    int cpol_v, cpha_v, lsb_v, round_idx, i;

    initial begin
        errors = 0;
        checks = 0;
        v_ss_n = 1'b1;
        v_mosi = 1'b0;
        cfg_wr_en     = 1'b1;
        cfg_cpol      = 1'b0;
        cfg_cpha      = 1'b0;
        cfg_lsb_first = 1'b0;
        v_sclk = cfg_cpol;

        rst_n_s = 1'b0;
        repeat (5) @(posedge clk_s);
        rst_n_s = 1'b1;
        repeat (5) @(posedge clk_s);

        for (cpol_v = 0; cpol_v < 2; cpol_v = cpol_v + 1) begin
            for (cpha_v = 0; cpha_v < 2; cpha_v = cpha_v + 1) begin
                for (lsb_v = 0; lsb_v < 2; lsb_v = lsb_v + 1) begin
                    for (i = 0; i < NUM_SLAVES; i = i + 1) g_words_out[i] = '0;
                    run_chain_round(cpol_v, cpha_v, lsb_v);

                    for (i = 0; i < NUM_SLAVES; i = i + 1) g_words_out[i] = '1;
                    run_chain_round(cpol_v, cpha_v, lsb_v);

                    for (round_idx = 0; round_idx < 3; round_idx = round_idx + 1) begin
                        for (i = 0; i < NUM_SLAVES; i = i + 1) begin
                            // verilator lint_off WIDTHTRUNC
                            g_words_out[i] = $urandom(seed);
                            // verilator lint_on WIDTHTRUNC
                        end
                        run_chain_round(cpol_v, cpha_v, lsb_v);
                    end
                end
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
            $fatal(1, "SPI daisy-chain test failed with %0d errors", errors);
        end

        $finish;
    end

    initial begin
        $dumpfile(VCD_PATH);
        $dumpvars(0, tb_spi_daisy_chain);
    end

    initial begin
        #200000000;
        $display("WATCHDOG TIMEOUT");
        $fatal(1, "Global watchdog timeout");
    end

endmodule
