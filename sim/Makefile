RTL_DIR   := ../rtl
TB_DIR    := ../tb
WAVE_DIR  := ../waves

RTL_SRCS  := $(RTL_DIR)/spi_master.sv $(RTL_DIR)/spi_slave.sv $(RTL_DIR)/spi_top.sv
REG_RTL_SRCS := $(RTL_SRCS) $(RTL_DIR)/spi_reg_top.sv
TB_SRC    := $(TB_DIR)/tb_spi_loopback.sv
MS_TB_SRC := $(TB_DIR)/tb_spi_multi_slave.sv
REG_TB_SRC := $(TB_DIR)/tb_spi_reg_top.sv
DAISY_TB_SRC := $(TB_DIR)/tb_spi_daisy_chain.sv

IV_OUT    := sim_iv.out
VL_TOP    := tb_spi_loopback
VL_DIR    := obj_dir
COV_DIR   := obj_dir_cov
COV_OUT_DIR := $(WAVE_DIR)/../coverage

MS_IV_OUT := sim_iv_multi_slave.out
MS_VL_TOP := tb_spi_multi_slave
MS_VL_DIR := obj_dir_multi_slave

REG_IV_OUT := sim_iv_reg_top.out
REG_VL_TOP := tb_spi_reg_top
REG_VL_DIR := obj_dir_reg_top
REG_COV_DIR := obj_dir_cov_reg_top
REG_COV_OUT_DIR := $(WAVE_DIR)/../coverage_reg_top

DAISY_IV_OUT := sim_iv_daisy_chain.out
DAISY_VL_TOP := tb_spi_daisy_chain
DAISY_VL_DIR := obj_dir_daisy_chain

IV_VCD    := $(WAVE_DIR)/iverilog.vcd
VL_VCD    := $(WAVE_DIR)/verilator.vcd

WAVE      ?= $(IV_VCD)

WIDTHS    := 1 2 3 4 5 8 12 16 32

.PHONY: all iverilog verilator coverage coverage-reg-if width-sweep multi-slave reg-if daisy-chain waves clean

all: iverilog verilator

iverilog:
	mkdir -p $(WAVE_DIR)
	iverilog -g2012 -o $(IV_OUT) $(RTL_SRCS) $(TB_SRC)
	vvp $(IV_OUT)

verilator:
	mkdir -p $(WAVE_DIR)
	verilator --binary --trace -Wall \
		--top-module $(VL_TOP) \
		-Mdir $(VL_DIR) \
		$(RTL_SRCS) $(TB_SRC)
	./$(VL_DIR)/V$(VL_TOP)

# Line + toggle coverage for the RTL only (--coverage-line --coverage-toggle),
# deliberately excluding --coverage-user/assertion coverage since the RTL
# has no SVA cover points yet; run separately from the plain `verilator`
# target (own -Mdir) so a coverage-instrumented build never masks a normal
# build's warnings/timing. verilator's auto-generated --binary main calls
# VerilatedCov::write() on exit whenever --coverage is set, landing
# coverage.dat in the CWD (sim/), which is why we cd there explicitly.
coverage:
	mkdir -p $(COV_OUT_DIR)
	verilator --binary --coverage-line --coverage-toggle -Wall \
		--top-module $(VL_TOP) \
		-Mdir $(COV_DIR) \
		$(RTL_SRCS) $(TB_SRC)
	./$(COV_DIR)/V$(VL_TOP)
	verilator_coverage --annotate $(COV_OUT_DIR)/annotated --annotate-min 1 coverage.dat
	verilator_coverage --write-info $(COV_OUT_DIR)/coverage.info coverage.dat
	mv coverage.dat $(COV_OUT_DIR)/coverage.dat
	@echo "Annotated per-line coverage: $(COV_OUT_DIR)/annotated/*.sv (lines prefixed"
	@echo "with a count of 0 next to '%' are uncovered; see docs/README.md)"

# Re-elaborates tb_spi_loopback.sv (and the RTL under it) at each width in
# WIDTHS via a parameter override, using both simulators. DATA_WIDTH is a
# real `parameter` on tb_spi_loopback specifically to make this possible
# (see the module header comment in tb/tb_spi_loopback.sv) -- iverilog's
# `-P tb_spi_loopback.DATA_WIDTH=<N>` and Verilator's `-GDATA_WIDTH=<N>`
# both target it directly, so no source edits are needed per width. Each
# width gets its own iverilog output binary and Verilator -Mdir so a
# failure at one width doesn't clobber another's build artifacts.
width-sweep:
	@set -e; \
	for w in $(WIDTHS); do \
		echo "=== iverilog DATA_WIDTH=$$w ==="; \
		iverilog -g2012 -o $(IV_OUT)_w$$w -P $(VL_TOP).DATA_WIDTH=$$w $(RTL_SRCS) $(TB_SRC); \
		vvp $(IV_OUT)_w$$w; \
		echo "=== verilator DATA_WIDTH=$$w ==="; \
		verilator --binary -Wall \
			--top-module $(VL_TOP) \
			-GDATA_WIDTH=$$w \
			-Mdir $(VL_DIR)_w$$w \
			$(RTL_SRCS) $(TB_SRC); \
		./$(VL_DIR)_w$$w/V$(VL_TOP); \
	done

# One master, several spi_top slaves sharing mosi/sclk/miso with a
# testbench-modeled external chip-select demux giving each its own ss_n
# (see tb/tb_spi_multi_slave.sv header comment). Own -Mdir/output name so
# this never collides with the point-to-point loopback build, and its own
# VCDs (waves/iverilog_multi_slave.vcd, waves/verilator_multi_slave.vcd).
multi-slave:
	mkdir -p $(WAVE_DIR)
	iverilog -g2012 -o $(MS_IV_OUT) $(RTL_SRCS) $(MS_TB_SRC)
	vvp $(MS_IV_OUT)
	verilator --binary --trace -Wall \
		--top-module $(MS_VL_TOP) \
		-Mdir $(MS_VL_DIR) \
		$(RTL_SRCS) $(MS_TB_SRC)
	./$(MS_VL_DIR)/V$(MS_VL_TOP)

# spi_reg_top wraps spi_top with a memory-mapped register interface
# (SPI_CR/SPI_SR/SPI_DR/SPI_CKDIV/SPI_CFG/SPI_IER/SPI_ISR -- see
# rtl/spi_reg_top.sv header comment for the full map) instead of the
# plain cfg_*/tx_*/rx_*/busy signals; tb_spi_reg_top.sv drives it the way
# a host CPU would over the register bus, against a plain spi_top slave.
# Own -Mdir/output name and own VCDs (waves/iverilog_reg_top.vcd,
# waves/verilator_reg_top.vcd), kept separate from the other builds.
reg-if:
	mkdir -p $(WAVE_DIR)
	iverilog -g2012 -o $(REG_IV_OUT) $(REG_RTL_SRCS) $(REG_TB_SRC)
	vvp $(REG_IV_OUT)
	verilator --binary --trace -Wall \
		--top-module $(REG_VL_TOP) \
		-Mdir $(REG_VL_DIR) \
		$(REG_RTL_SRCS) $(REG_TB_SRC)
	./$(REG_VL_DIR)/V$(REG_VL_TOP)

# Same rationale as `coverage` above, but for spi_reg_top.sv/tb_spi_reg_top.sv
# -- own -Mdir/coverage.dat destination/annotated-output directory so this
# never collides with the core-only `coverage` target's artifacts, since
# both would otherwise write coverage.dat to the same CWD.
coverage-reg-if:
	mkdir -p $(REG_COV_OUT_DIR)
	verilator --binary --coverage-line --coverage-toggle -Wall \
		--top-module $(REG_VL_TOP) \
		-Mdir $(REG_COV_DIR) \
		$(REG_RTL_SRCS) $(REG_TB_SRC)
	./$(REG_COV_DIR)/V$(REG_VL_TOP)
	verilator_coverage --annotate $(REG_COV_OUT_DIR)/annotated --annotate-min 1 coverage.dat
	verilator_coverage --write-info $(REG_COV_OUT_DIR)/coverage.info coverage.dat
	mv coverage.dat $(REG_COV_OUT_DIR)/coverage.dat
	@echo "Annotated per-line coverage: $(REG_COV_OUT_DIR)/annotated/*.sv (lines prefixed"
	@echo "with a count of 0 next to '%' are uncovered; see docs/README.md)"

# Daisy-chain topology: several spi_slave cores sharing one ss_n/sclk
# with mosi/miso chained point-to-point (see tb/tb_spi_daisy_chain.sv
# header comment) -- the opposite pin-sharing split from tb_spi_multi_
# slave.sv's multi-drop bus. Driven by a bit-banged virtual master (the
# real spi_master core only supports single-word-per-ss_n transfers, not
# the ss_n-held-low-for-many-words transaction a chain needs), so this
# instantiates spi_slave directly rather than going through spi_top or a
# real spi_master. Own -Mdir/output name and own VCDs
# (waves/iverilog_daisy_chain.vcd, waves/verilator_daisy_chain.vcd).
daisy-chain:
	mkdir -p $(WAVE_DIR)
	iverilog -g2012 -o $(DAISY_IV_OUT) $(RTL_SRCS) $(DAISY_TB_SRC)
	vvp $(DAISY_IV_OUT)
	verilator --binary --trace -Wall \
		--top-module $(DAISY_VL_TOP) \
		-Mdir $(DAISY_VL_DIR) \
		$(RTL_SRCS) $(DAISY_TB_SRC)
	./$(DAISY_VL_DIR)/V$(DAISY_VL_TOP)

waves:
	@echo "To view waveforms, run:"
	@echo "  gtkwave $(WAVE)"
	@echo "(pass WAVE=../waves/verilator.vcd to pick the verilator trace)"
	-gtkwave $(WAVE) &

clean:
	rm -rf $(IV_OUT) $(IV_OUT)_w* $(VL_DIR) $(VL_DIR)_w* $(COV_DIR) $(COV_OUT_DIR) coverage.dat \
		$(MS_IV_OUT) $(MS_VL_DIR) $(REG_IV_OUT) $(REG_VL_DIR) $(REG_COV_DIR) $(REG_COV_OUT_DIR) \
		$(DAISY_IV_OUT) $(DAISY_VL_DIR) $(WAVE_DIR)/*.vcd
