`timescale 1ns / 1ps

module spi_slave #(
    parameter int DATA_WIDTH = 8
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  cfg_wr_en,
    input  logic                  cfg_cpol,
    input  logic                  cfg_cpha,
    input  logic                  cfg_lsb_first,
    // Number of bits to exchange per transfer, 1..DATA_WIDTH, following the
    // same shadow/latch protection as the other cfg_* fields below. In a
    // daisy chain, every stage must be configured with the same word length
    // for the chain-relay logic (past_first_word below) to hand off between
    // stages at the right bit; 0 or > DATA_WIDTH is not supported.
    input  logic [$clog2(DATA_WIDTH+1)-1:0] cfg_data_width,

    input  logic [DATA_WIDTH-1:0] tx_data,
    // verilator lint_off UNUSEDSIGNAL
    // A slave cannot refuse a master-initiated transfer, so tx_valid is not
    // functionally required here: whatever tx_data is present at frame_start
    // is latched unconditionally. The port is kept for interface symmetry
    // with spi_master's tx_valid/tx_ready handshake.
    input  logic                  tx_valid,
    // verilator lint_on UNUSEDSIGNAL
    output logic                  tx_ready,

    output logic [DATA_WIDTH-1:0] rx_data,
    output logic                  rx_valid,

    output logic                  busy,

    input  logic                  ss_n,
    input  logic                  sclk,
    input  logic                  mosi,
    output logic                  miso,
    output logic                  miso_oe
);

    // Gated by the raw (unsynchronized) ss_n rather than the synchronized
    // ss_n_s used everywhere else in this module: an output-enable has no
    // metastability failure mode the way a value sampled into a register
    // does, and gating it off the synchronizer would add a multi-cycle
    // delay before a newly-selected slave starts driving miso at all,
    // which is unnecessary since the enable only needs to prevent bus
    // contention with a still-selected slave, not protect data integrity
    // (data integrity is already handled by the frame_start/frame_end
    // latch logic below, which does use the synchronized signal). This
    // lets spi_top tri-state a shared miso bus across multiple slave
    // instances so only the currently-selected one drives it.
    assign miso_oe = ~ss_n;

    // 2-stage synchronizers: sclk/ss_n/mosi are asynchronous to clk, and a
    // depth of 2 is the standard minimum to bring MTBF to an acceptable
    // level for a synthesizable design; edge detection below then runs on
    // the synchronized, glitch-free versions of these signals.
    logic [1:0] ss_n_sync;
    logic [1:0] sclk_sync;
    logic [1:0] mosi_sync;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ss_n_sync <= 2'b11;
            sclk_sync <= 2'b00;
            mosi_sync <= 2'b00;
        end else begin
            ss_n_sync <= {ss_n_sync[0], ss_n};
            sclk_sync <= {sclk_sync[0], sclk};
            mosi_sync <= {mosi_sync[0], mosi};
        end
    end

    logic ss_n_s, sclk_s, mosi_s;
    assign ss_n_s = ss_n_sync[1];
    assign sclk_s = sclk_sync[1];
    assign mosi_s = mosi_sync[1];

    logic sclk_s_d;
    logic ss_n_s_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_s_d <= 1'b0;
            ss_n_s_d <= 1'b1;
        end else begin
            sclk_s_d <= sclk_s;
            ss_n_s_d <= ss_n_s;
        end
    end

    logic sclk_rising, sclk_falling, frame_start, frame_end;
    assign sclk_rising  = sclk_s  & ~sclk_s_d;
    assign sclk_falling = ~sclk_s &  sclk_s_d;
    assign frame_start  = ss_n_s_d & ~ss_n_s;
    assign frame_end    = ~ss_n_s_d & ss_n_s;

    // Config shadow registers accept a write any time cfg_wr_en is
    // asserted, regardless of busy: the host can configure the controller
    // at any moment, including mid-frame. What's deferred is the *effect*,
    // not the write itself: the frame in flight runs off cpol_lat/
    // cpha_lat/lsb_first_lat below, which are only re-latched from the
    // shadow at the next frame_start — i.e. once the core is idle again.
    logic cpol_shadow;
    logic cpha_shadow;
    logic lsb_first_shadow;
    logic [$clog2(DATA_WIDTH+1)-1:0] data_width_shadow;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpol_shadow       <= 1'b0;
            cpha_shadow       <= 1'b0;
            lsb_first_shadow  <= 1'b0;
            data_width_shadow <= $clog2(DATA_WIDTH+1)'(DATA_WIDTH);
        end else if (cfg_wr_en) begin
            cpol_shadow       <= cfg_cpol;
            cpha_shadow       <= cfg_cpha;
            lsb_first_shadow  <= cfg_lsb_first;
            data_width_shadow <= cfg_data_width;
        end
    end

    // Mode config is further latched at frame_start and held until
    // frame_end, so a config write that lands mid-frame cannot corrupt bits
    // already in flight; latching happens at least one clk cycle before the
    // first real sclk edge of the frame thanks to the synchronizer latency
    // above.
    logic cpol_lat;
    logic cpha_lat;
    logic lsb_first_lat;
    logic [$clog2(DATA_WIDTH+1)-1:0] data_width_lat;

    // Leading edge is rising when CPOL=0, falling when CPOL=1; CPHA=0 means
    // sample-on-leading/shift-on-trailing, CPHA=1 means shift-on-leading/
    // sample-on-trailing. This mapping realizes SPI modes 0-3.
    logic leading_edge_is_rising;
    assign leading_edge_is_rising = ~cpol_lat;

    logic sample_edge, shift_edge;
    assign sample_edge = leading_edge_is_rising ?
                          (cpha_lat ? sclk_falling : sclk_rising) :
                          (cpha_lat ? sclk_rising  : sclk_falling);
    assign shift_edge  = leading_edge_is_rising ?
                          (cpha_lat ? sclk_rising  : sclk_falling) :
                          (cpha_lat ? sclk_falling : sclk_rising);

    // bit_cnt is sized to count through DATA_WIDTH inclusive, one bit wider
    // than strictly needed to index a DATA_WIDTH-entry array; msb_index
    // re-widths that difference explicitly instead of relying on implicit
    // truncation.
    // IDX_WIDTH is floored at 1 because $clog2(1) is 0: at DATA_WIDTH=1
    // there is only one bit to index (always index 0), but a genuinely
    // zero-width vector is illegal, so the extra bit here is simply unused.
    localparam int BIT_CNT_WIDTH = $clog2(DATA_WIDTH+1);
    localparam int IDX_WIDTH     = (DATA_WIDTH > 1) ? $clog2(DATA_WIDTH) : 1;

    logic [DATA_WIDTH-1:0] tx_shift;
    logic [DATA_WIDTH-1:0] rx_shift;
    logic [BIT_CNT_WIDTH-1:0] bit_cnt;
    logic [IDX_WIDTH-1:0]     msb_index;
    logic [IDX_WIDTH-1:0]     lsb_index;
    assign msb_index = IDX_WIDTH'(data_width_lat - 1'b1) - IDX_WIDTH'(bit_cnt);
    assign lsb_index = IDX_WIDTH'(bit_cnt);

    // Set once bit_cnt reaches data_width_lat (this slave's own word has
    // been fully shifted out) and held until the next frame_start. A daisy
    // chain shares one ss_n across several slaves, so a frame commonly
    // clocks far more than data_width_lat bits total; past_first_word gates
    // miso between this slave's own preloaded word (msb_index/lsb_index,
    // unchanged from before) and relaying its incoming mosi stream
    // through to the next slave in the chain (see the shift_edge block
    // below) once that word is exhausted. Deliberately a sticky latch
    // rather than comparing bit_cnt directly every cycle: bit_cnt is only
    // BIT_CNT_WIDTH bits wide (sized for exactly one DATA_WIDTH-bit word)
    // and free-running for as long as ss_n stays low, so it wraps around
    // well before a multi-slave chain's frame ends -- a live comparison
    // would flip back to "not past the first word" every time bit_cnt
    // wrapped through a small value again, incorrectly reverting to
    // this slave's own (already fully transmitted) word.
    logic past_first_word;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_ready <= 1'b1;
            rx_valid <= 1'b0;
            rx_data  <= '0;
            busy     <= 1'b0;
            tx_shift <= '0;
            rx_shift <= '0;
            bit_cnt  <= '0;
            miso     <= 1'b0;
            cpol_lat      <= 1'b0;
            cpha_lat      <= 1'b0;
            lsb_first_lat <= 1'b0;
            past_first_word <= 1'b0;
            data_width_lat  <= $clog2(DATA_WIDTH+1)'(DATA_WIDTH);
        end else begin
            rx_valid <= 1'b0;

            if (frame_start) begin
                tx_shift      <= tx_data;
                bit_cnt       <= '0;
                busy          <= 1'b1;
                tx_ready      <= 1'b0;
                cpol_lat      <= cpol_shadow;
                cpha_lat      <= cpha_shadow;
                lsb_first_lat <= lsb_first_shadow;
                data_width_lat  <= data_width_shadow;
                past_first_word <= 1'b0;
                rx_shift        <= '0;
                if (!cpha_shadow)
                    miso <= lsb_first_shadow ? tx_data[0] : tx_data[data_width_shadow-1];
            end else if (ss_n_s) begin
                busy     <= 1'b0;
                tx_ready <= 1'b1;
            end

            if (!ss_n_s) begin
                if (sample_edge) begin
                    // Shift-and-OR instead of {a[hi:1],x}/{x,a[hi-1:0]}
                    // part-selects: at DATA_WIDTH=1 those part-selects
                    // become out-of-order/negative-range (e.g. [-1:0]),
                    // which is illegal even though the branch is otherwise
                    // correct; shift operators stay valid at any
                    // DATA_WIDTH>=1.
                    if (lsb_first_lat)
                        rx_shift <= (rx_shift >> 1) | (DATA_WIDTH'(mosi_s) << (data_width_lat-1));
                    else
                        rx_shift <= (rx_shift << 1) | DATA_WIDTH'(mosi_s);
                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt == BIT_CNT_WIDTH'(data_width_lat - 1'b1))
                        past_first_word <= 1'b1;
                end

                if (shift_edge) begin
                    // Once this slave's own word has been fully shifted
                    // out, miso relays rx_shift's outgoing tail bit --
                    // the bit about to be overwritten by the next sample,
                    // i.e. whatever arrived on mosi data_width_lat sample
                    // edges ago -- instead of continuing to re-present
                    // tx_shift (which is never itself modified past this
                    // point). Fixed at position 0 (LSB-first) or
                    // data_width_lat-1 (MSB-first) rather than tracking
                    // bit_cnt: each sample continuously refreshes that one
                    // position from its neighbour, so it always holds the
                    // arrival from exactly data_width_lat sample edges ago
                    // regardless of how much further shifting has happened
                    // since -- a cascading single-tap delay line. This is
                    // what makes a chain of these slaves (mosi/miso
                    // daisy-chained, ss_n and sclk shared) behave as one
                    // long shift register spanning the whole chain: see
                    // tb_spi_daisy_chain.sv.
                    if (lsb_first_lat)
                        miso <= past_first_word ? rx_shift[0] : tx_shift[lsb_index];
                    else
                        miso <= past_first_word ? rx_shift[data_width_lat-1] : tx_shift[msb_index];
                end
            end

            if (frame_end) begin
                rx_data  <= rx_shift;
                rx_valid <= 1'b1;
                busy     <= 1'b0;
                tx_ready <= 1'b1;
            end
        end
    end

endmodule
