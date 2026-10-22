`timescale 1ns / 1ps

module spi_top #(
    parameter bit MASTER_MODE    = 1,
    parameter int DATA_WIDTH     = 8,
    parameter int CLK_DIV_WIDTH  = 16
) (
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     cfg_wr_en,
    input  logic                     cfg_cpol,
    input  logic                     cfg_cpha,
    input  logic                     cfg_lsb_first,
    // verilator lint_off UNUSEDSIGNAL
    // Only wired to spi_master; unused when MASTER_MODE=0 elaborates the
    // slave branch, since spi_slave derives its timing from the external
    // sclk it receives rather than a clock divider.
    input  logic [CLK_DIV_WIDTH-1:0] cfg_clk_div,
    // verilator lint_on UNUSEDSIGNAL
    input  logic [$clog2(DATA_WIDTH+1)-1:0] cfg_data_width,

    input  logic [DATA_WIDTH-1:0]    tx_data,
    input  logic                     tx_valid,
    output logic                     tx_ready,

    output logic [DATA_WIDTH-1:0]    rx_data,
    output logic                     rx_valid,

    output logic                     busy,

    inout  wire                      ss_n,
    inout  wire                      sclk,
    inout  wire                      mosi,
    inout  wire                      miso
);

    // MASTER_MODE is a compile-time parameter, so only one branch below is
    // ever elaborated; the tri-state assigns exist purely to give spi_top
    // genuinely bidirectional-capable pins without introducing an inout
    // port inside spi_master/spi_slave themselves. Since only one core is
    // ever instantiated per instance, there is no real multi-driver
    // contention on these nets.
    generate
        if (MASTER_MODE) begin : g_master

            logic ss_n_o, sclk_o, mosi_o;
            logic miso_i;
            assign miso_i = miso;

            spi_master #(
                .DATA_WIDTH   (DATA_WIDTH),
                .CLK_DIV_WIDTH(CLK_DIV_WIDTH)
            ) u_core (
                .clk          (clk),
                .rst_n        (rst_n),
                .cfg_wr_en    (cfg_wr_en),
                .cfg_cpol     (cfg_cpol),
                .cfg_cpha     (cfg_cpha),
                .cfg_lsb_first(cfg_lsb_first),
                .cfg_clk_div  (cfg_clk_div),
                .cfg_data_width(cfg_data_width),
                .tx_data      (tx_data),
                .tx_valid     (tx_valid),
                .tx_ready     (tx_ready),
                .rx_data      (rx_data),
                .rx_valid     (rx_valid),
                .busy         (busy),
                .ss_n         (ss_n_o),
                .sclk         (sclk_o),
                .mosi         (mosi_o),
                .miso         (miso_i)
            );

            assign ss_n = ss_n_o;
            assign sclk = sclk_o;
            assign mosi = mosi_o;
            assign miso = 1'bz;

        end else begin : g_slave

            logic miso_o, miso_oe;
            logic ss_n_i, sclk_i, mosi_i;
            assign ss_n_i  = ss_n;
            assign sclk_i  = sclk;
            assign mosi_i  = mosi;

            spi_slave #(
                .DATA_WIDTH(DATA_WIDTH)
            ) u_core (
                .clk          (clk),
                .rst_n        (rst_n),
                .cfg_wr_en    (cfg_wr_en),
                .cfg_cpol     (cfg_cpol),
                .cfg_cpha     (cfg_cpha),
                .cfg_lsb_first(cfg_lsb_first),
                .cfg_data_width(cfg_data_width),
                .tx_data      (tx_data),
                .tx_valid     (tx_valid),
                .tx_ready     (tx_ready),
                .rx_data      (rx_data),
                .rx_valid     (rx_valid),
                .busy         (busy),
                .ss_n         (ss_n_i),
                .sclk         (sclk_i),
                .mosi         (mosi_i),
                .miso         (miso_o),
                .miso_oe      (miso_oe)
            );

            // Gated by miso_oe (== ~ss_n) rather than driven unconditionally,
            // so multiple spi_top slave instances can share one miso net (a
            // real multi-drop SPI bus: shared mosi/sclk/miso, one dedicated
            // ss_n per slave) without a deselected slave contending on the
            // bus -- see tb/tb_spi_multi_slave.sv, which exercises exactly
            // this and would show bus contention ('x') if this were wrong.
            assign miso = miso_oe ? miso_o : 1'bz;
            assign ss_n = 1'bz;
            assign sclk = 1'bz;
            assign mosi = 1'bz;

        end
    endgenerate

endmodule
