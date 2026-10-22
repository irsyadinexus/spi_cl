`timescale 1ns / 1ps

module spi_master #(
    parameter int DATA_WIDTH    = 8,
    parameter int CLK_DIV_WIDTH = 16
) (
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     cfg_wr_en,
    input  logic                     cfg_cpol,
    input  logic                     cfg_cpha,
    input  logic                     cfg_lsb_first,
    input  logic [CLK_DIV_WIDTH-1:0] cfg_clk_div,
    // Number of bits to exchange per transfer, 1..DATA_WIDTH. Follows the
    // same shadow/latch protection as the other cfg_* fields below; a
    // value of 0 or > DATA_WIDTH is not a supported configuration (callers
    // that need to enforce this at runtime, e.g. spi_reg_top, validate and
    // reject it before it ever reaches this port).
    input  logic [$clog2(DATA_WIDTH+1)-1:0] cfg_data_width,

    input  logic [DATA_WIDTH-1:0]    tx_data,
    input  logic                     tx_valid,
    output logic                     tx_ready,

    output logic [DATA_WIDTH-1:0]    rx_data,
    output logic                     rx_valid,

    output logic                     busy,

    output logic                     ss_n,
    output logic                     sclk,
    output logic                     mosi,
    input  logic                     miso
);

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_XFER,
        ST_DONE
    } state_t;

    state_t state;

    logic [CLK_DIV_WIDTH-1:0] div_cnt;
    logic                     div_tick;
    assign div_tick = (div_cnt == clk_div_lat);

    // Config shadow registers accept a write any time cfg_wr_en is
    // asserted, regardless of busy: the host can configure the controller
    // at any moment, including mid-transfer. What's deferred is the
    // *effect*, not the write itself. ST_IDLE continuously drives
    // sclk <= cpol_shadow, so a write while idle is visible immediately;
    // a write that lands while busy is captured into the shadow right
    // away too, but has no effect on the transfer already in flight,
    // because that transfer runs off cpol_lat/cpha_lat/lsb_first_lat/
    // clk_div_lat below, which are only re-latched from the shadow the
    // next time a transfer starts from ST_IDLE — i.e. once the core is
    // idle again.
    logic                     cpol_shadow;
    logic                     cpha_shadow;
    logic                     lsb_first_shadow;
    logic [CLK_DIV_WIDTH-1:0] clk_div_shadow;
    logic [$clog2(DATA_WIDTH+1)-1:0] data_width_shadow;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpol_shadow       <= 1'b0;
            cpha_shadow       <= 1'b0;
            lsb_first_shadow  <= 1'b0;
            clk_div_shadow    <= '0;
            data_width_shadow <= $clog2(DATA_WIDTH+1)'(DATA_WIDTH);
        end else if (cfg_wr_en) begin
            cpol_shadow       <= cfg_cpol;
            cpha_shadow       <= cfg_cpha;
            lsb_first_shadow  <= cfg_lsb_first;
            clk_div_shadow    <= cfg_clk_div;
            data_width_shadow <= cfg_data_width;
        end
    end

    // Mode config is further latched at transfer start and held for the
    // duration of the transfer, so a config write that lands mid-transfer
    // cannot corrupt bits already in flight; ST_IDLE tracks the live
    // shadow registers for the idle sclk level so a new mode is visible
    // before the next transfer.
    logic                     cpol_lat;
    logic                     cpha_lat;
    logic                     lsb_first_lat;
    logic [CLK_DIV_WIDTH-1:0] clk_div_lat;
    logic [$clog2(DATA_WIDTH+1)-1:0] data_width_lat;

    // bit_cnt is sized to count through DATA_WIDTH inclusive (its completion
    // check compares against data_width_lat-1, the runtime-configured word
    // length), one bit wider than strictly needed to index a DATA_WIDTH-entry
    // array; msb_index below re-widths that difference explicitly instead of
    // relying on implicit truncation.
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

    logic next_edge_is_leading;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= ST_IDLE;
            ss_n                 <= 1'b1;
            sclk                 <= 1'b0;
            mosi                 <= 1'b0;
            tx_ready             <= 1'b1;
            rx_valid             <= 1'b0;
            rx_data              <= '0;
            busy                 <= 1'b0;
            div_cnt              <= '0;
            tx_shift             <= '0;
            rx_shift             <= '0;
            bit_cnt              <= '0;
            next_edge_is_leading <= 1'b1;
            cpol_lat              <= 1'b0;
            cpha_lat              <= 1'b0;
            lsb_first_lat         <= 1'b0;
            clk_div_lat           <= '0;
            data_width_lat        <= $clog2(DATA_WIDTH+1)'(DATA_WIDTH);
        end else begin
            rx_valid <= 1'b0;
            div_cnt  <= div_cnt + 1'b1;

            case (state)
                ST_IDLE: begin
                    sclk     <= cpol_shadow;
                    ss_n     <= 1'b1;
                    tx_ready <= 1'b1;
                    busy     <= 1'b0;
                    div_cnt  <= '0;

                    if (tx_valid && tx_ready) begin
                        tx_shift             <= tx_data;
                        bit_cnt              <= '0;
                        ss_n                 <= 1'b0;
                        tx_ready             <= 1'b0;
                        busy                 <= 1'b1;
                        sclk                 <= cpol_shadow;
                        next_edge_is_leading <= 1'b1;
                        div_cnt              <= '0;
                        cpol_lat             <= cpol_shadow;
                        cpha_lat             <= cpha_shadow;
                        lsb_first_lat        <= lsb_first_shadow;
                        clk_div_lat          <= clk_div_shadow;
                        data_width_lat       <= data_width_shadow;
                        rx_shift             <= '0;

                        if (!cpha_shadow)
                            mosi <= lsb_first_shadow ? tx_data[0] : tx_data[data_width_shadow-1];

                        state <= ST_XFER;
                    end
                end

                ST_XFER: begin
                    if (div_tick) begin
                        div_cnt <= '0;
                        sclk    <= ~sclk;

                        if (next_edge_is_leading) begin
                            if (!cpha_lat) begin
                                // Shift-and-OR instead of {a[hi:1],x}/{x,a[hi-1:0]}
                                // part-selects: at DATA_WIDTH=1 those part-
                                // selects become out-of-order/negative-range
                                // (e.g. [-1:0]), which is illegal even though
                                // the branch is otherwise correct; shift
                                // operators stay valid at any DATA_WIDTH>=1.
                                if (lsb_first_lat)
                                    rx_shift <= (rx_shift >> 1) | (DATA_WIDTH'(miso) << (data_width_lat-1));
                                else
                                    rx_shift <= (rx_shift << 1) | DATA_WIDTH'(miso);
                                bit_cnt <= bit_cnt + 1'b1;
                                if (bit_cnt == BIT_CNT_WIDTH'(data_width_lat - 1'b1))
                                    state <= ST_DONE;
                            end else begin
                                if (lsb_first_lat)
                                    mosi <= tx_shift[lsb_index];
                                else
                                    mosi <= tx_shift[msb_index];
                            end
                        end else begin
                            if (!cpha_lat) begin
                                if (lsb_first_lat)
                                    mosi <= tx_shift[lsb_index];
                                else
                                    mosi <= tx_shift[msb_index];
                            end else begin
                                // Shift-and-OR instead of {a[hi:1],x}/{x,a[hi-1:0]}
                                // part-selects: at DATA_WIDTH=1 those part-
                                // selects become out-of-order/negative-range
                                // (e.g. [-1:0]), which is illegal even though
                                // the branch is otherwise correct; shift
                                // operators stay valid at any DATA_WIDTH>=1.
                                if (lsb_first_lat)
                                    rx_shift <= (rx_shift >> 1) | (DATA_WIDTH'(miso) << (data_width_lat-1));
                                else
                                    rx_shift <= (rx_shift << 1) | DATA_WIDTH'(miso);
                                bit_cnt <= bit_cnt + 1'b1;
                                if (bit_cnt == BIT_CNT_WIDTH'(data_width_lat - 1'b1))
                                    state <= ST_DONE;
                            end
                        end

                        next_edge_is_leading <= ~next_edge_is_leading;
                    end
                end

                ST_DONE: begin
                    rx_data  <= rx_shift;
                    rx_valid <= 1'b1;
                    ss_n     <= 1'b1;
                    sclk     <= cpol_lat;
                    busy     <= 1'b0;
                    tx_ready <= 1'b1;
                    state    <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
