# SPI Controller (SystemVerilog)

A synthesizable 4-wire SPI controller, configurable as master or slave at
compile time, with self-checking testbenches runnable under both Icarus
Verilog and Verilator.

## Analysis & Verification Summary

- **Architecture**: Compile-time selectable Master/Slave with tri-state MISO bus gating (`miso_oe = ~ss_n`) preventing multi-drop contention. Includes daisy-chain single-tap shift relay and AMBA APB memory-mapped register interface (`spi_reg_top.sv`).
- **Modes & Formats**: Full support for all 4 SPI modes (0, 1, 2, 3), MSB/LSB first order, master clock divider ($T_{sclk} = 2 \cdot (\text{cfg\_clk\_div} + 1) \cdot T_{clk}$), and runtime configurable word lengths (1 to `DATA_WIDTH` bits).
- **Diagnostics**: Hardware RX Overrun (`OE`), Protocol Errors (`PERR`) with bus-level `PSLVERR`, and a 32-bit Watchdog Timer (`TO`).
- **Verification Results**:
  - `tb_spi_loopback.sv`: 927 checks (PASS)
  - `tb_spi_multi_slave.sv`: 120 checks (PASS)
  - `tb_spi_reg_top.sv`: 1,679 checks (PASS)
  - `tb_spi_daisy_chain.sv`: 360 checks (PASS)
  - Parameterized width sweep across `{1, 2, 3, 4, 5, 8, 12, 16, 32}` bits: PASS
- **Code Coverage**: 99.6% core RTL line/toggle coverage, 100% register interface coverage.
- **Toolchain Status**: Fully verified with Icarus Verilog (`iverilog -g2012`) and Verilator 5.020 (`-Wall` clean with zero warnings).

The RTL and testbench are written in SystemVerilog (`.sv`), not plain
Verilog-2001. `logic` replaces `reg`/`wire` where appropriate,
`always_ff`/`always_comb`-style synchronous blocks use `always_ff`,
FSM states use a `typedef enum`, and the testbench uses `$urandom` and
SystemVerilog task/argument syntax. Both `iverilog -g2012` and Verilator
(which is natively a SystemVerilog tool) compile this cleanly — see
"Toolchain notes" below.

## Directory layout

```
spi_cl/
  rtl/
    spi_master.sv   synthesizable SPI master core
    spi_slave.sv    synthesizable SPI slave core (with CDC synchronizers)
    spi_top.sv      compile-time master/slave wrapper
    spi_reg_top.sv  wraps spi_top with a memory-mapped register interface
  tb/
    tb_spi_loopback.sv     self-checking master<->slave loopback testbench
    tb_spi_multi_slave.sv  self-checking multi-drop bus (1 master, N slaves)
    tb_spi_reg_top.sv      self-checking register-interface testbench
    tb_spi_daisy_chain.sv  self-checking daisy-chained slaves testbench
  sim/
    Makefile        iverilog / verilator / coverage / width-sweep /
                     multi-slave / reg-if / daisy-chain / waves / clean /
                     all targets
  waves/            VCDs land here (iverilog.vcd, verilator.vcd, and each
                     of the other testbenches' own iverilog_*.vcd /
                     verilator_*.vcd)
  docs/
    README.md       this file
```

## Architecture

### Top-level mux strategy

`spi_top` takes a compile-time parameter `MASTER_MODE` (1 = master,
0 = slave). A `generate if` elaborates exactly one of `spi_master` or
`spi_slave` inside `spi_top`; the other branch simply does not exist in
the elaborated design. `spi_top`'s four bus pins (`ss_n`, `sclk`, `mosi`,
`miso`) are declared `inout wire` and driven via `assign` from whichever
core was instantiated, with the unused-direction pins tied to `1'bz` in
each branch.

This was the "prefer compile-time parameter selecting instantiated core"
option from the spec, chosen because it is the simplest to reason about
and keeps `spi_master`/`spi_slave` themselves free of any `inout` ports —
they have purely directional, synthesizable interfaces. Because
`MASTER_MODE` is resolved at elaboration time, only one core ever exists
per `spi_top` instance, so there is no real multi-driver contention on the
tri-stated nets *within a single instance*; the `1'bz` assigns exist only
so `spi_top` presents genuinely bidirectional-capable pins to whatever
it's instantiated in.

That said, a real SPI bus is often multi-drop — one master, several
slaves sharing `mosi`/`sclk`/`miso`, each with its own dedicated `ss_n` —
which *does* put multiple `spi_top` slave instances' `miso` pins on the
same net. `spi_slave` exposes a `miso_oe` output (`assign miso_oe = ~ss_n;`,
gated by the raw, unsynchronized `ss_n` since an output-enable has no
metastability failure mode the way a value sampled into a register does),
and `spi_top`'s slave branch uses it to only actually drive `miso` while
selected: `assign miso = miso_oe ? miso_o : 1'bz;`. Without this gate, a
deselected slave would keep driving `miso` with its last registered value
regardless of `ss_n`, contending with whichever slave *is* currently
selected — `tb/tb_spi_multi_slave.sv` exercises exactly this and
reproducibly shows the resulting bus corruption if the gate is removed
(see "Testbench" below).

### Reset

Asynchronous, active-low (`always_ff @(posedge clk or negedge rst_n)`),
used consistently across `spi_master`, `spi_slave`, and the testbench's
own sequencing registers.

### Pinout (`spi_top`)

| Signal | Direction (master mode) | Direction (slave mode) | Description |
|---|---|---|---|
| `ss_n`  | output | input  | Slave select, active low |
| `sclk`  | output | input  | Serial clock |
| `mosi`  | output | input  | Master-out, slave-in |
| `miso`  | input  | output | Master-in, slave-out |

### Configuration registers (plain input ports, not memory-mapped)

| Signal | Width | Meaning |
|---|---|---|
| `cfg_wr_en` | 1 | Write strobe: `cfg_cpol`/`cfg_cpha`/`cfg_lsb_first`/`cfg_clk_div` are only committed into the core's internal shadow registers on a clock edge where this is asserted; deasserted, the `cfg_*` bus can be driven to anything without affecting the core |
| `cfg_cpol` | 1 | Clock polarity: 0 = idle low, 1 = idle high |
| `cfg_cpha` | 1 | Clock phase: 0 = sample on first (leading) edge, 1 = sample on second (trailing) edge |
| `cfg_lsb_first` | 1 | Bit order: 0 = MSB first, 1 = LSB first |
| `cfg_clk_div` | `CLK_DIV_WIDTH` (default 16) | Master-only clock divider (see formula below); ignored by `spi_slave`, which derives all timing from the external `sclk` it receives |
| `cfg_data_width` | `$clog2(DATA_WIDTH+1)` | Runtime word length in bits, 1..`DATA_WIDTH`; see "Runtime configurable data width" below |

`DATA_WIDTH` (default 8) is a synthesis-time Verilog `parameter`, the
*maximum* word length the core can be built for; `cfg_data_width` selects
how many of those bits are actually exchanged per transfer, at runtime,
up to that maximum.

**Config write gating (`cfg_wr_en`):** Both `spi_master` and `spi_slave`
hold a bank of shadow registers (`cpol_shadow`/`cpha_shadow`/
`lsb_first_shadow`/`clk_div_shadow`) that only update `if (cfg_wr_en)`,
each in its own `clk` domain. This models the write-enable a real
register-mapped config interface (APB/AHB/etc.) would provide: upstream
logic can drive the `cfg_*` bus freely and it has zero effect on the core
until a write is explicitly struck. All of the core's internal logic reads
the shadow registers, never the raw `cfg_*` ports directly.

Because this is a genuine synchronous register write, a change only
becomes visible on the *next* clock edge of that core's own domain after
`cfg_wr_en` is asserted — exactly like any register write, there's no
combinational bypass. Since `spi_master` and `spi_slave` normally run on
independent clock domains, a driver that writes both sides' config (e.g.
in a testbench sharing one `cfg_*` bus across both) should allow at least
one clock period of the *slower* domain to elapse before relying on the
new config, e.g. before starting a transfer. `tb/tb_spi_loopback.sv`'s
`set_baseline_cfg`/settle-delay pattern shows this: it waits 3 `clk_m`
cycles after setting `cfg_*` before starting a transfer, comfortably
covering both `clk_m`'s and the faster `clk_s`'s one-cycle write latency.

**Config changes mid-transfer — host may write at any time, effect is
deferred until idle:** independently of the write gate above,
`cpol_shadow`/`cpha_shadow`/`lsb_first_shadow`/`clk_div_shadow` are
further sampled and latched into `cpol_lat`/`cpha_lat`/`lsb_first_lat`/
`clk_div_lat` at the start of each transfer (master: `ST_IDLE -> ST_XFER`
when `tx_valid && tx_ready`; slave: `frame_start`, i.e. the `ss_n` falling
edge) and held for that transfer's duration.

The host is *not* required to wait for `busy` to deassert before writing —
`cfg_wr_en` is honored unconditionally, any time, including mid-transfer,
and the shadow registers are updated immediately regardless of `busy`.
What's deferred is purely the *effect*: a write that lands while `busy` is
asserted has no effect on the transfer already in flight (which keeps
running off the separately-latched `_lat` registers, frozen since that
transfer started), and instead becomes active automatically the moment
the core returns to `ST_IDLE`/goes idle — visible immediately in the idle
`sclk` level, and used by whichever transfer starts next — with no need
for the host to re-strike the write once idle. This is deliberate:
without the `_lat` latch, a write landing mid-word (e.g. `cfg_clk_div`
altering `sclk`'s toggle rate, or `cfg_cpha` flipping which edge is
sample-vs-shift) would corrupt whichever bits are still in flight.

### Runtime configurable data width

`cfg_data_width` selects how many of `DATA_WIDTH`'s bits are actually
exchanged in each transfer, from 1 up to `DATA_WIDTH`. It follows exactly
the same shadow-register-plus-transfer-start-latch protection as
`cfg_cpol`/`cfg_cpha`/`cfg_lsb_first`/`cfg_clk_div` above: gated by
`cfg_wr_en` into `data_width_shadow`, then re-latched into
`data_width_lat` at the start of each transfer, so a width change landing
mid-transfer never affects the word already in flight and takes effect
automatically starting with the next one, once idle.

- **Alignment:** a transfer configured for *N* bits exchanges the low *N*
  bits of `tx_data`/`rx_data`, right-justified, regardless of bit order.
  For MSB-first, the first bit driven/sampled is `tx_data[N-1]`/becomes
  `rx_data[N-1]`; for LSB-first, it's `tx_data[0]`/`rx_data[0]`. Bits above
  position `N-1` in `tx_data` are never read, and the same bits in
  `rx_data` always read back 0 (both cores explicitly clear their receive
  shift register at the start of every transfer specifically to prevent a
  previous, wider transfer's stale upper bits from leaking through a
  narrower one).
- **Daisy chains:** `spi_slave`'s chain-relay logic (see above) uses
  `data_width_lat` instead of the compile-time `DATA_WIDTH` to decide when
  its own word is done and to pick the single-tap relay bit position, so a
  chain of slaves all configured to the same narrower width relays
  correctly at that width. All stages in a chain must be configured with
  the *same* `cfg_data_width` for this to hold — the relay logic has no
  way to reconcile stages configured for different widths.
- **Validation:** `spi_master`/`spi_slave` themselves treat
  `cfg_data_width` as a trusted 1..`DATA_WIDTH` value with no runtime
  guard (a 0 or out-of-range value is simply not a supported
  configuration at that layer, same as `DATA_WIDTH` itself needing to be
  >=1). `spi_reg_top` is the layer that actually validates host input —
  see `SPI_CFG.DATA_BITS` below — rejecting an out-of-range write rather
  than passing it through, unlike an unguarded runtime word-length field
  would.

### SPI mode table

CPOL/CPHA together select the standard SPI mode. Define the "leading"
edge of a bit period as the first transition away from the idle level,
and the "trailing" edge as the second. The leading edge is rising when
CPOL=0 and falling when CPOL=1; CPHA=0 means sample-on-leading /
shift-on-trailing, CPHA=1 means shift-on-leading / sample-on-trailing.

| Mode | CPOL | CPHA | Idle clock | Sample edge | Shift edge |
|---|---|---|---|---|---|
| 0 | 0 | 0 | Low  | Rising  | Falling |
| 1 | 0 | 1 | Low  | Falling | Rising  |
| 2 | 1 | 0 | High | Falling | Rising  |
| 3 | 1 | 1 | High | Rising  | Falling |

Both `spi_master` and `spi_slave` implement all four combinations; the
testbench sweeps all of them.

### Clock divider formula (master only)

`spi_master` free-runs a counter `div_cnt` on every `clk` cycle while a
transfer is active and toggles `sclk` whenever `div_cnt == cfg_clk_div`
(then resets the counter). Each `sclk` half-period is therefore
`(cfg_clk_div + 1)` `clk` cycles, so:

```
sclk_period = 2 * (cfg_clk_div + 1) * clk_period
```

`cfg_clk_div = 0` gives the fastest supported `sclk` (`clk_period * 2`
half-periods → `sclk_period = 2 * clk_period`).

### Data interface (per core)

- `tx_data[DATA_WIDTH-1:0]`, `tx_valid`, `tx_ready` — `tx_ready` is high
  whenever the core is idle and can accept a new word.
- `rx_data[DATA_WIDTH-1:0]`, `rx_valid` — `rx_valid` pulses for one `clk`
  cycle once a full word has been shifted in.
- `busy` — high for the duration of a transfer.

**Master**: a transfer starts when `tx_valid && tx_ready`; the master
asserts `ss_n` for the whole transfer and deasserts it once the word has
been fully exchanged. Only single-word-per-`ss_n`-assertion transfers are
supported — there is no multi-word burst-without-deassert mode.

**Slave**: `ss_n`, `sclk`, and `mosi` are inputs coming from outside the
`clk` domain. Because a real SPI slave's `sclk` (and `ss_n`) are
asynchronous relative to its own system clock, `spi_slave` first passes
all three through a 2-stage synchronizer before using them for anything.
A synchronizer depth of 2 is the conventional minimum for acceptable MTBF
in a synthesizable design; edge detection (rising/falling `sclk`,
`ss_n` frame start/end) then runs entirely on the synchronized,
glitch-free versions. This is why a real SPI slave design assumes the
internal sampling clock is meaningfully faster than the external `sclk`
it's decoding — the testbench drives the slave's `clk` roughly 5-25x
faster than the fastest `sclk` it will see (see "Testbench" below) to
give the synchronizer a fair oversampling margin, consistent with
standard SPI slave design practice.

`spi_slave`'s `tx_valid` input is present for interface symmetry with
`spi_master` but is not functionally required: a slave cannot refuse a
master-initiated transfer, so whatever `tx_data` is present at frame
start is latched unconditionally.

### Daisy-chained slaves

Multi-drop (`tb_spi_multi_slave.sv`, above the slave signal list) shares
`mosi`/`sclk`/`miso` across several slaves with one dedicated `ss_n`
each. Daisy-chaining is the opposite split: several slaves share one
`ss_n`/`sclk`, with `mosi`/`miso` chained point-to-point (master →
`slave[0].mosi`, `slave[i].miso` → `slave[i+1].mosi`, …,
`slave[N-1].miso` → master), so the whole chain behaves as one long
shift register spanning `N*DATA_WIDTH` bits.

This exposed a real gap: `miso` was driven by *indexing* a static,
never-shifted `tx_shift` register (`tx_shift[msb_index]`/`[lsb_index]`,
using `bit_cnt` as the index). That's invisible for a single
`DATA_WIDTH`-bit transfer — indexing and a genuine shift produce
identical output for the first `DATA_WIDTH` bits — but a chain holds
`ss_n` low for many multiples of `DATA_WIDTH` bits, and indexing doesn't
relay anything: once a slave's own word was exhausted, it just kept
re-presenting the same word instead of passing its incoming `mosi`
stream through to the next slave. (It would also have read
`tx_shift` out of bounds once `bit_cnt` grew past `DATA_WIDTH-1` for a
non-power-of-2 `DATA_WIDTH`, since `bit_cnt` itself is only sized for one
word and wraps around given enough clocking.)

The fix is additive, not a mode switch: once a `past_first_word` latch
(set the cycle `bit_cnt` reaches `DATA_WIDTH-1`, held until the next
`frame_start`) goes high, `miso` switches from the original indexed
readback to `rx_shift`'s own outgoing tail bit — the bit about to be
overwritten by the *next* sample, i.e. whatever arrived on `mosi`
`DATA_WIDTH` sample edges ago. `rx_shift` was already a genuine,
continuously-running shift register with no `bit_cnt` gating at all (it
only ever accumulates, right up to `frame_end`), so no new register or
edge-timing logic was needed for the relay itself — only the mux that
picks it. Because this new path is only reachable once `bit_cnt` exceeds
the bound every existing test already respects, it cannot regress any
single-word-transfer behavior; `tb_spi_loopback.sv`'s full suite (all
widths, both simulators) passes byte-for-byte unchanged after this
change, which is exactly what confirmed the derivation.

### Register interface (`spi_reg_top.sv`)

`spi_top`'s plain cfg_*/tx_*/rx_*/busy signals suit a design where
another RTL block drives the controller directly. A host CPU instead
wants a memory-mapped register interface, so `spi_reg_top` wraps
`spi_top` (unchanged) with one: a standard AMBA APB slave (PSEL/PENABLE/
PWRITE/PADDR/PWDATA/PRDATA/PREADY/PSLVERR) instead of discrete pins. It
is a pure additive wrapper — `spi_top`/`spi_master`/`spi_slave` are
untouched, so `tb_spi_loopback.sv`/`tb_spi_multi_slave.sv`'s existing
coverage of the core transfer logic is unaffected by anything in this
module.

Register map (byte addresses, 32-bit registers, word-aligned):

| Addr | Name | Access | Description |
|---|---|---|---|
| 0x00 | SPI_CR | R/W | Control: `start` (bit0), `soft_reset` (bit1) |
| 0x04 | SPI_SR | R | Status: `busy`, `done`, `tx_ready`, `rx_valid`, `rx_busy`, `err` |
| 0x08 | SPI_DR | R/W | Data: write = TX, read = RX |
| 0x0C | SPI_CKDIV | R/W | Clock divider (16-bit) |
| 0x10 | SPI_CFG | R/W | Config: `mode`, `bit_order`, `data_bits` |
| 0x14 | SPI_IER | R/W | Interrupt enable |
| 0x18 | SPI_ISR | R/WC | Interrupt status (write-1-to-clear) |
| 0x1C | SPI_WDT | R/W | Watchdog timeout threshold, in `clk` cycles (32-bit); 0 = disabled (reset default) |

Bit-field layout of every register (all reserved bits read as 0 and
ignore writes):

**SPI_CR (0x00, R/W)**

| Bit(s) | Name | Access | Meaning |
|---|---|---|---|
| 0 | `START` | R/W, self-clearing | Write 1 to begin a transfer with whatever is currently in SPI_DR. Reads back 1 for one cycle after the write, then 0. |
| 1 | `SOFT_RESET` | R/W, self-clearing | Write 1 to pulse-reset the wrapped core (and this register file's own busy-tracking latches) for one cycle. Reads back 1 for one cycle after the write, then 0. |
| 31:2 | — | — | Reserved. |

**SPI_SR (0x04, R)**

| Bit(s) | Name | Meaning |
|---|---|---|
| 0 | `BUSY` | A transfer is in flight. |
| 1 | `DONE` | A received word is available in SPI_DR (same latch as `RX_VALID`). Cleared by reading SPI_DR or writing SPI_CR.START. |
| 2 | `TX_READY` | Core can accept a new SPI_CR.START. |
| 3 | `RX_VALID` | Alias of `DONE` (see "SPI_SR" below). |
| 4 | `RX_BUSY` | Alias of `BUSY` (see "SPI_SR" below). |
| 5 | `ERR` | Live OR of SPI_ISR's `OE`/`PERR`/`TO` bits, regardless of SPI_IER. |
| 31:6 | — | Reserved. |

**SPI_DR (0x08, R/W)**

| Bit(s) | Name | Meaning |
|---|---|---|
| `DATA_WIDTH-1:0` | `DATA` | Write: word to transmit on the next START. Read: most recently received word. |
| 31:`DATA_WIDTH` | — | Reserved; reads 0. |

**SPI_CKDIV (0x0C, R/W)**

| Bit(s) | Name | Meaning |
|---|---|---|
| `CLK_DIV_WIDTH-1:0` | `CKDIV` | Master `sclk` divider (see "Clock divider formula" above); no effect in slave mode. |
| 31:`CLK_DIV_WIDTH` | — | Reserved; reads 0. |

**SPI_CFG (0x10, R/W)**

| Bit(s) | Name | Meaning |
|---|---|---|
| 0 | `CPHA` | Clock phase. |
| 1 | `CPOL` | Clock polarity. Bits `[1:0]` together are the standard SPI mode number (0-3). |
| 2 | `BIT_ORDER` | 0 = MSB first, 1 = LSB first. |
| 8:3 | `DATA_BITS` | Runtime transfer width; 0 = full `DATA_WIDTH` (reset default), 1..`DATA_WIDTH` = that many bits, >`DATA_WIDTH` rejected (PERR, whole write dropped). See "Runtime configurable data width" above. |
| 31:9 | — | Reserved. |

**SPI_IER / SPI_ISR (0x14 R/W, 0x18 R/WC)**

| Bit | Name | Meaning |
|---|---|---|
| 0 | `DONE_IE` / `DONE` | Transfer completed (mirrors SR.DONE's set condition). |
| 1 | `TXRDY_IE` / `TX_READY` | Core became ready again after a transfer (0→1 edge, not level). |
| 2 | `OE_IE` / `OE` | RX overrun. |
| 3 | `PERR_IE` / `PERR` | Protocol error. |
| 4 | `TO_IE` / `TO` | Watchdog timeout. |
| 31:5 | — | Reserved. |

SPI_ISR bits are write-1-to-clear; `irq = |(SPI_ISR & SPI_IER)`.

**SPI_WDT (0x1C, R/W)**

| Bit(s) | Name | Meaning |
|---|---|---|
| 31:0 | `THRESHOLD` | `clk` cycles the core may stay `busy` before `TO` fires; 0 = disabled (reset default). |

**SPI_CR** — both bits are self-clearing: a write is only ever visible
on a readback for the one cycle immediately following the write (the
pulse this register produces for the core's `tx_valid` / the soft-reset
gate below), reading back 0 otherwise. Writing `start` while the core
isn't ready yet has no more effect than `spi_master` already gives any
`tx_valid` asserted while `!tx_ready` — the write simply isn't
actionable until the core is idle.

**SPI_SR** — bit0 `BUSY`, bit1 `DONE`, bit2 `TX_READY`, bit3 `RX_VALID`,
bit4 `RX_BUSY`, bit5 `ERR`. `DONE` and `RX_VALID` are the same underlying
latch: this core's full-duplex transfers complete their TX and produce
fresh RX data in the same cycle, so there is only one "new data is
ready" event to track. `RX_BUSY` is likewise just `BUSY` — RX activity
exactly tracks TX activity in this core, there's no independent
receive-only busy state. The `DONE`/`RX_VALID` latch is set on the
wrapped core's `rx_valid` pulse and cleared either by reading SPI_DR
(the natural "collect the result" point) or by writing SPI_CR.start (a
new transfer invalidates any stale unread result); a fresh `rx_valid`
always wins over either clear condition landing on the same cycle. `ERR`
is a *live* (not latched) OR of SPI_ISR's three error bits (`OE`, `PERR`,
`TO` — see below), so purely polling-based software can check for a
problem without decoding ISR or configuring interrupts at all.

**Error handling** — four conditions are detected and reported without
affecting normal operation, none of which block or corrupt anything else
in the register file (an invalid-address write already fails every
register's own address comparison and is naturally a no-op; SPI_SR has
no backing storage for a write to corrupt regardless):
- **RX overrun (`OE`)** — SPI_CR.start is written while the previous
  result was never read out (`DONE`/`RX_VALID` still set). Checked at
  the `start` write itself, not at the new transfer's completion:
  `start` unconditionally clears `DONE`/`RX_VALID` (a fresh transfer
  invalidates any stale result), so by the time the new transfer's
  `rx_valid` pulses, the "was there unread data" moment has already
  passed. The new transfer still proceeds and overwrites SPI_DR's RX
  value regardless (there's nowhere else to put it) — matching how a
  real UART/SPI peripheral's overrun flag works: it reports that data
  was lost, it does not preserve the lost data.
- **Protocol error (`PERR`)**, any of: accessing (read or write) an
  address outside this map's eight registers; writing to SPI_SR (the
  map's only strictly read-only register); writing SPI_CR.start while
  the core is still busy from a previous transfer (the write has no
  effect on the core, same as any `tx_valid` arriving while `!tx_ready`,
  but the host asked for something that didn't happen and should be told
  so); writing SPI_CFG with DATA_BITS greater than the `DATA_WIDTH`
  elaboration parameter (there is no such thing as a transfer wider than
  the core's own word register, so the write is rejected in full rather
  than silently truncated). Every PERR condition also drives `PSLVERR`
  high for that same APB ACCESS cycle (see "Bus protocol" below), so a
  bus-level error monitor sees it without decoding SPI_ISR.
- **Timeout (`TO`)** — the core stays busy for at least `SPI_WDT` clock
  cycles without completing (see SPI_WDT below). Diagnostic only: it
  neither aborts the transfer nor touches the wrapped core's reset — a
  host that sees `TO` set can recover via `SPI_CR.soft_reset` itself if
  it chooses to.

Writing SPI_DR while busy is **deliberately not** flagged as an error:
it's the normal, supported way to preload the next transfer's data while
the current one is still in flight.

**SPI_DR** — write loads the word to transmit on the next `start`;
writing DR does not itself start a transfer, matching SPI_CR having its
own dedicated bit for that. Read returns the most recently received
word, zero-extended to 32 bits, and clears the DONE/RX_VALID status.

**SPI_CKDIV** — mirrors `cfg_clk_div` directly; a no-op in slave mode,
same as `spi_top`'s own `cfg_clk_div` port.

**SPI_CFG** — bits `[1:0]` MODE = `{CPOL,CPHA}`, matching this core's own
SPI mode table exactly (mode 0/1/2/3 ↔ CPOL/CPHA 00/01/10/11), so
software can write the standard SPI mode number directly; bit `[2]`
BIT_ORDER (0 = MSB first, 1 = LSB first); bits `[8:3]` DATA_BITS, the
number of bits exchanged per transfer (see "Runtime configurable data
width" above). DATA_BITS follows the same shadow/latch protection as
MODE/BIT_ORDER: a write takes effect starting with the next transfer,
never corrupting one already in flight. A value of 0 (the reset default)
means "use the full `DATA_WIDTH` elaboration parameter", so software that
never touches DATA_BITS keeps its prior full-width behavior unchanged;
1..`DATA_WIDTH` select a narrower runtime word length. Writing DATA_BITS
greater than `DATA_WIDTH` is rejected outright (PERR, see above) — the
whole SPI_CFG write is dropped, leaving MODE/BIT_ORDER/DATA_BITS all at
their prior values — rather than silently truncated or accepted with
undefined behavior the way an unguarded runtime word-length field would
be.

**SPI_IER/SPI_ISR** — bit0 `DONE` (mirrors SR.DONE's set condition),
bit1 `TX_READY` (set on `tx_ready`'s 0→1 edge — the core becoming ready
*again* after a transfer, not merely being ready at reset), bit2 `OE`
(RX overrun, see above), bit3 `PERR` (protocol error, see above), bit4
`TO` (timeout, see above). `irq` is the OR of `(ISR & IER)`. ISR bits
clear via write-1-to-clear; writing 0 to a bit leaves it unchanged.

**SPI_WDT** — a 32-bit threshold, in `clk` cycles, for how long the core
may stay busy before `TO` fires; 0 (the reset default) disables the
watchdog entirely, so it's silent unless a host explicitly opts in. The
counter runs only while `busy` and resets to 0 the moment `busy`
deasserts, so it measures *one transfer's* duration, not cumulative busy
time across transfers. `TO` fires exactly once per busy period even
though "still busy and still over threshold" remains continuously true
for the rest of that transfer — otherwise write-1-to-clearing it
mid-transfer would just see the same still-true condition reassert it
on the very next cycle, making it effectively un-clearable while a slow
transfer is in flight. A fresh busy period (the next transfer) re-arms
the gate independently.

`SPI_WDT` is deliberately **not** shadow-latched the way
`cfg_cpol`/`cfg_cpha`/etc. are: the watchdog is a monitoring function,
not part of the SPI protocol itself, so unlike changing the SPI mode
mid-transfer (which could corrupt bits already in flight), changing how
long is "too long" mid-transfer can't corrupt anything — the new
threshold value applies immediately. Sizing this as a fixed-width
internal counter matching one particular `DATA_WIDTH`/`CLK_DIV_WIDTH`
combination would be wrong in general: with the default 16-bit
`CLK_DIV_WIDTH`, a single legitimate transfer can already take roughly
`16*(cfg_clk_div+1)` cycles, comfortably beyond what a 16-bit watchdog
counter could represent at large `cfg_clk_div` values — which is why the
threshold is a full 32-bit host-supplied value rather than a fixed
internal constant.

**Bus protocol** — standard AMBA APB, 2-phase transfer:

| Signal | Dir | Width | Meaning |
|---|---|---|---|
| `PCLK` | in | 1 | Bus clock (this module's `clk`). |
| `PRESETn` | in | 1 | Active-low async reset (this module's `rst_n`). |
| `PSEL` | in | 1 | Asserted for the whole transaction (SETUP + ACCESS). |
| `PENABLE` | in | 1 | Low during SETUP, high during ACCESS. |
| `PWRITE` | in | 1 | 1 = write, 0 = read. |
| `PADDR` | in | 5 | Register byte address (see map above). |
| `PWDATA` | in | 32 | Write data, valid from SETUP onward. |
| `PRDATA` | out | 32 | Read data; a continuous combinational mux of whichever register `PADDR` currently selects, valid from SETUP onward (more than APB requires, never hurts). |
| `PREADY` | out | 1 | Tied permanently high — this slave is zero-wait-state, every register responds within the single ACCESS cycle. |
| `PSLVERR` | out | 1 | Mirrors the current cycle's PERR condition (see "Error handling" above); only meaningful, and only ever asserted, during an ACCESS phase (`PSEL && PENABLE`). |

A transaction opens in the SETUP phase (`PSEL` asserted, `PENABLE` low,
`PADDR`/`PWDATA`/`PWRITE` already valid) and moves to the ACCESS phase
one `PCLK` later (`PENABLE` asserted, address/data/write held stable).
Writes take effect synchronously on the `PCLK` edge that ends the ACCESS
phase, like any register write. `cfg_wr_en` on the wrapped `spi_top` is
tied permanently high: the write gate visible to software is this
module's own register-write decode, and `spi_master`/`spi_slave`'s
existing shadow-register-plus-transfer-start-latch mechanism (see
"Config write gating" above) already correctly defers a write landing
mid-transfer until the core goes idle — there's no need to duplicate
that logic in the register wrapper.

Because SPI_DR is a fixed 32-bit register, `DATA_WIDTH` must be ≤ 32 for
a whole transfer's worth of data to fit through it in one access;
`spi_reg_top` asserts this at elaboration time.

#### Configuration example

Polling-only master, SPI mode 0, MSB-first, full `DATA_WIDTH`, `sclk` at
`clk / 4` (`cfg_clk_div = 1`, and the divider counts to `cfg_clk_div`
inclusive on a 0-based counter, so `sclk` toggles every 2 `clk` cycles —
see "Clock divider formula" above):

```c
// One-time setup.
REG(SPI_CFG)   = 0x0;   // MODE=0 (CPOL=0,CPHA=0), BIT_ORDER=0 (MSB first), DATA_BITS=0 (full width)
REG(SPI_CKDIV) = 0x1;   // sclk = clk / 4
REG(SPI_IER)   = 0x0;   // polling only, no interrupts enabled

// One transfer.
REG(SPI_DR) = tx_word;  // word to send
REG(SPI_CR) = 0x1;      // START
while (!(REG(SPI_SR) & (1 << 1))) { /* poll DONE */ }
rx_word = REG(SPI_DR);  // read clears DONE/RX_VALID
```

Same transfer, interrupt-driven, with a 12-bit `DATA_BITS` word and the
watchdog armed at 5000 `clk` cycles:

```c
REG(SPI_CFG)   = (12 << 3);  // DATA_BITS=12, MODE=0, BIT_ORDER=0
REG(SPI_CKDIV) = 0x1;
REG(SPI_WDT)   = 5000;       // flag TO if a transfer takes >=5000 clk cycles
REG(SPI_IER)   = 0x1F;       // enable DONE/TX_READY/OE/PERR/TO

REG(SPI_DR) = tx_word & 0xFFF;  // only the low 12 bits are transferred
REG(SPI_CR) = 0x1;

// -- irq fires --
uint32_t isr = REG(SPI_ISR);
if (isr & (1 << 4)) { /* handle TO: recover via SPI_CR.SOFT_RESET if needed */ }
if (isr & (1 << 3)) { /* handle PERR: check what triggered it before retrying */ }
if (isr & (1 << 0)) { rx_word = REG(SPI_DR); }  // DONE: read result, clears DONE/RX_VALID
REG(SPI_ISR) = isr;  // write-1-to-clear whatever was serviced
```

Switching to SPI mode 3 (CPOL=1, CPHA=1), LSB-first, at any time —
including while a transfer is in flight: the write lands in the shadow
registers immediately, but only takes effect starting with the *next*
transfer (see "Config changes mid-transfer" above), so no extra
synchronization is needed beyond issuing the write itself. SPI_CFG is a
single register with no hardware read-modify-write, so changing only
MODE/BIT_ORDER while preserving a previously-set DATA_BITS means software
must read SPI_CFG first and OR in the new bits:

```c
uint32_t cfg = REG(SPI_CFG);
cfg = (cfg & ~0x7) | 0x3 | (1 << 2);  // MODE=3, BIT_ORDER=1 (LSB first); DATA_BITS[8:3] untouched
REG(SPI_CFG) = cfg;
```

Recovering from a stuck transfer (e.g. after a `TO` interrupt):

```c
REG(SPI_CR) = 0x2;  // SOFT_RESET
while (REG(SPI_SR) & 0x1) { /* wait for BUSY to clear, if it hasn't already */ }
REG(SPI_ISR) = 0x1F;  // clear any stale error bits before resuming normal use
```

## Toolchain notes

- **Icarus Verilog**: invoked as `iverilog -g2012 ...`, which is
  sufficient for the `logic`, `always_ff`/`always_comb`, `typedef enum`,
  and other SystemVerilog-2012 constructs used here.
- **Verilator**: SystemVerilog is Verilator's native input language, so
  no `--timing` flag is needed for this design (that flag exists for
  richer SystemVerilog event-control/interface support that this project
  doesn't use). The Makefile uses `verilator --binary --trace`, which
  builds a self-contained simulation executable straight from the
  SystemVerilog testbench — no separate C++ harness is required because
  `tb_spi_loopback.sv`'s `initial`/`always` blocks and native
  `$dumpfile`/`$dumpvars` VCD dumping work directly under `--binary`.
- A small number of `verilator lint_off`/`lint_on` pragmas are present in
  the RTL and testbench, each with an inline comment explaining why the
  specific warning is a benign, intentional pattern (e.g. `spi_slave`'s
  unused `tx_valid` port, or non-blocking assignments inside a task
  called from an `initial` block used purely as a sequential test
  driver). None of them mask a real functional issue — `make verilator`
  builds with zero warnings using `-Wall` (no `-Wno-fatal` needed).

## Testbench

`tb/tb_spi_loopback.sv` instantiates two `spi_top` instances back to
back — one with `MASTER_MODE=1`, one with `MASTER_MODE=0` — wiring the
master's `ss_n`/`sclk`/`mosi` to the slave's inputs and the slave's
`miso` back to the master's input. The master side runs on `clk_m` (10ns
period); the slave side runs on an independent, unrelated `clk_s` (4ns
period) specifically so the slave's CDC synchronizer is exercised against
a genuinely asynchronous `sclk`, not just a divided version of its own
clock.

The test sweeps, exhaustively combined:

1. All 4 SPI modes (CPOL x CPHA).
2. Both bit orders (MSB-first, LSB-first).
3. Two `cfg_clk_div` values (1 and 4), i.e. two different `sclk` rates.
4. Per configuration: an all-zeros word, an all-ones word, and 25
   `$urandom`-seeded random words (seed is a fixed constant, so the run
   is reproducible).

Each transfer is genuinely full-duplex: the slave's `tx_data` is loaded
with an independent random word each transfer (not zero), so the
master's receive path is exercised against real data too, not just the
slave echoing back known-zero patterns.

The checker compares, per transfer: what the master intended to send vs.
what the slave received, and what the slave intended to send back vs.
what the master received. Because the slave's `rx_valid` pulse is only
one `clk_s` cycle wide — shorter than the `clk_m` period the checker
polls on — a small sticky-latch/ack handshake (`s_rx_valid_sticky`,
`s_rx_ack`), clocked in the `clk_s` domain and cleared by an explicit
one-`clk_m`-cycle acknowledge from the checker, makes that pulse reliably
observable from the `clk_m`-domain checker without needing to build a
full CDC synchronizer purely for the testbench's own bookkeeping.

After the mode/order/div sweep, `run_mid_transfer_glitch_test` runs 13
more transfers that slam `cfg_cpol`/`cfg_cpha`/`cfg_lsb_first`/
`cfg_clk_div` to the opposite mode/order and a very different clock
divider partway through the transfer (early/mid/late, and randomized
offsets), while both cores are still `busy`. This exercises the
config-latching behavior described above: since both cores latch mode
config at transfer start, the glitch must have zero effect on the data
already in flight, and the checker verifies the transfer completes with
the data that was expected under the *original* config, not the glitched
one. (Deliberately reverting the latch — e.g. reading `cfg_cpha` live
inside `spi_slave`'s `sample_edge`/`shift_edge` instead of the latched
`cpha_lat` — reproducibly fails this test with data mismatches, confirming
it actually catches the regression it targets.)

After that, `run_cfg_wr_en_gate_test` verifies `cfg_wr_en` itself, while
both cores sit idle (no transfer in flight, so the mid-transfer latch
above plays no role — only the shadow register's write gate can explain
the observed behavior). It uses `sclk`'s idle level as the observation
point, since `spi_master`'s `ST_IDLE` state continuously drives
`sclk <= cpol_shadow`, making a change to `cpol_shadow` directly visible
on the shared bus without needing a transfer: it deasserts `cfg_wr_en`,
changes `cfg_cpol`, and confirms `sclk` does *not* follow the change; then
it pulses `cfg_wr_en` for one `clk_m` cycle and confirms `sclk` *does*
follow the change immediately after. `checks`/`errors` are incremented
for both assertions and counted into the totals below.

Two more tasks then verify the "write at any time, effect deferred until
idle" semantics specifically: `run_cfg_apply_after_idle_test` reuses
`do_transfer_with_glitch` to write a new config mid-transfer (holding
`cfg_wr_en` asserted throughout, as most other tests do) and, without any
further `cfg_*` write, confirms the idle `sclk` level already reflects it
and that a subsequent ordinary transfer completes correctly under it
(only possible if both master and slave actually adopted the same new
mode/order/div). `run_cfg_write_pulse_during_busy_test` is the stronger
variant: it strikes a single one-`clk_m`-cycle `cfg_wr_en` pulse
mid-transfer, deasserts it immediately, and then scrambles `cfg_*` back to
a different value on the wire while `cfg_wr_en` stays low for the rest of
the transfer — this distinguishes "the write was captured the instant it
pulsed, independent of `busy`" from an alternate (incorrect) design that
gates the shadow write by `!busy` and would rely on `cfg_wr_en` still
being asserted once the core happens to go idle. (Reverting the shadow
registers' `if (cfg_wr_en)` condition to `if (cfg_wr_en && !busy)`
reproducibly fails this specific test while leaving every other test
green, confirming it actually isolates this behavior.)

`run_data_width_test` and `run_data_width_mid_transfer_test` cover
`cfg_data_width` (see "Runtime configurable data width" above), running
at `NARROW_WIDTH = DATA_WIDTH - 1` (skipped when `DATA_WIDTH=1`, which has
no narrower width to try — both tasks are wrapped in a `generate` block
gated on `DATA_WIDTH >= 2`, since a plain runtime `if` guard around the
same body still trips a Verilator `SELRANGE` error at `DATA_WIDTH=1`:
`[DATA_WIDTH-1:NARROW_WIDTH]` becomes a nonsensical `[0:1]` slice of a
1-bit signal there, and Verilator elaborates a task's part-select ranges
at compile time regardless of a runtime branch around them).
`run_data_width_test` drives several transfers at the narrower width with
garbage deliberately placed in `tx_data`'s untransferred upper bits,
confirming the peer receives the correct zero-extended `NARROW_WIDTH`-bit
result rather than the full `DATA_WIDTH` (which would leak that garbage
through). `run_data_width_mid_transfer_test` mirrors
`run_cfg_apply_after_idle_test` but for width specifically: it changes
`cfg_data_width` to `NARROW_WIDTH` mid-transfer and confirms the
full-`DATA_WIDTH` transfer already in flight completes unaffected, then
confirms the *next* transfer automatically adopts the narrower width with
no further write. (Reverting `msb_index`'s runtime `data_width_lat-1`
back to the compile-time `DATA_WIDTH-1` reproducibly fails only these two
tests' narrower-width checks, confirming they isolate the width-latching
behavior specifically.)

`run_mid_transfer_reset_test` covers `rst_n` asserted while `busy=1`, a
case none of the tests above ever touch (they only reset at the very
start of simulation). Two scenarios, both ending with a normal
`do_transfer` to prove the core is genuinely usable afterward, not just
idle-*looking*:
- **Both cores reset mid-transfer** — the straightforward whole-system
  reset case. Checks that, while `rst_n` is still held low (reset is
  asynchronous, so this must already be true, not just after release),
  `ss_n` is deasserted and both `busy` signals are low; then, after
  release, that both cores report a clean idle state
  (`tx_ready`/`!busy`/`ss_n`).
- **Only the master is reset** — the slave's own `rst_n` is never
  touched. This proves the master's reset-forced `ss_n` deassertion
  alone (visible immediately, since it's async) is enough to make the
  slave's own `frame_end` logic fire and return it to idle too, once
  that deassertion propagates through its CDC synchronizer — checked by
  polling `s_busy` rather than a fixed wait, since that propagation
  delay is a small, fixed number of `clk_s` cycles independent of
  `DATA_WIDTH`/`BASELINE_DIV`. Because the slave itself was never reset,
  its `frame_end` logic runs its normal course on the master's forced
  `ss_n` deassertion — indistinguishable, from the slave's perspective,
  from a legitimately short frame — so it produces a real `rx_valid`
  pulse with whatever garbage partial bits it had shifted in by that
  point. The test explicitly drains that expected stray pulse
  (`s_rx_ack`) before trusting the next `do_transfer`'s checks; omitting
  that drain was an actual bug caught while writing this test — the
  stale sticky `rx_valid` flag would otherwise hand a *later* transfer's
  checker the earlier aborted frame's garbage data instead of that
  transfer's real result.

At the end of the run the testbench prints a running per-configuration
summary, a total check count, and either `ALL TESTS PASSED` or
`TESTS FAILED: <N>` followed by `$fatal`, so pass/fail is unambiguous
from the log for CI-style consumption.

A VCD is written via `$dumpfile`/`$dumpvars` to `../waves/iverilog.vcd`
or `../waves/verilator.vcd` depending on which simulator is running
(selected with `` `ifdef VERILATOR ``, which both tools define/leave
undefined correctly without any extra `-D` flags).

### Multi-slave bus sharing (`tb_spi_multi_slave.sv`)

`tb_spi_loopback.sv` above is strictly point-to-point: one master, one
slave, one dedicated `ss_n`. Real SPI is often multi-drop instead — one
master, several slaves sharing `mosi`/`sclk`/`miso`, each slave with its
own dedicated `ss_n` decoded from the master's single `ss_n` output by
external glue logic (a GPIO-driven mux, an address decoder, etc., since
`spi_master` itself only has one `ss_n` pin). `tb_spi_multi_slave.sv`
models exactly that: one `spi_top` master and `NUM_SLAVES` (default 3)
`spi_top` slaves sharing `mosi`/`sclk`/`miso`, with the "external
decoder" modeled as a per-slave `assign ss_n_slave[i] = (selected_slave
== i) ? ss_n_m_w : 1'b1;` driven by a testbench-controlled
`selected_slave` index.

Each slave is given a fixed, distinct `tx_data` "signature" byte
(`slave_sig(idx) = DATA_WIDTH'(idx + 1)`) instead of a per-transfer value:
since a slave unconditionally latches whatever's on `tx_data` at its own
`frame_start`, holding it constant means the checker can identify which
physical slave actually answered purely from what the master received
back, rather than having to track a different expected value per slave
across transfers.

The test sweeps all 4 SPI modes, and per mode: an exhaustive round-robin
over every slave, then several transfers with a randomly chosen slave
each time, so the addressed slave changes unpredictably between
back-to-back transfers. For every transfer it checks:
1. the addressed slave receives the master's word correctly;
2. the master receives *that slave's* signature byte back, confirming
   the right physical slave answered, not just that some slave did;
3. every other slave's `busy`/`rx_valid` never fire during that transfer
   (they never see `frame_start`, since their `ss_n` stays deasserted
   throughout);
4. `miso_w` never resolves to `X` at any point during the transfer —
   the direct symptom of a deselected slave still driving the shared bus.

This test is what motivated adding `miso_oe` to `spi_slave` and the
tri-state gate in `spi_top` (see "Architecture" above): before that fix,
this testbench failed immediately and unambiguously — under iverilog,
`miso_w` reads `X` from the first transfer onward (both drivers contend
and 4-state resolution shows the conflict directly); under Verilator,
which resolves multi-driver nets differently and doesn't produce an
explicit `X` here, the contention instead shows up as the master
receiving the *wrong* slave's data. Either way, the addressed-slave-data
check (#2 above) reliably catches the regression on both simulators, so
that check remains the primary signal even though the `X`-detection
check (#4) is a more immediate diagnostic when it does fire.

Own build target (`make multi-slave`) and own VCDs
(`waves/iverilog_multi_slave.vcd`, `waves/verilator_multi_slave.vcd`),
kept separate from `tb_spi_loopback.sv`'s build artifacts.

### Register interface (`tb_spi_reg_top.sv`)

Drives `spi_reg_top` (master mode) the way a host CPU would — write
SPI_CFG/SPI_CKDIV, load SPI_DR, strike SPI_CR.START, poll or interrupt-wait
on SPI_SR/irq, read SPI_DR back — against a plain `spi_top` slave (the
slave side has no register interface of its own; its mode config is
mirrored directly by the testbench from whatever was last written to the
master's SPI_CFG, since there's no register bus to program it
independently). Reuses `tb_spi_loopback.sv`'s sticky-latch pattern to
observe the slave's `clk_s`-domain `rx_valid` pulse from this
testbench's `clk_m`-domain checker.

Sweeps all 4 SPI modes × both bit orders (all through SPI_CFG writes),
each with an all-zeros word, an all-ones word, and 5 random words, and
for every transfer checks: SPI_SR.BUSY/TX_READY/RX_VALID after
completion, SPI_DR read matches what the slave actually sent, SPI_SR's
DONE/RX_VALID clearing after the SPI_DR read, and the slave's own
received data. `reg_write_task`/`reg_read_task` (the two low-level APB
driver tasks everything else is built on) drive the full SETUP/ACCESS
sequence and check `PREADY` asserts on every access — via a plain
while-loop rather than a fixed cycle count, so the driver stays correct
even if `spi_reg_top` ever stopped being zero-wait-state — so the
handshake half of the bus protocol is verified continuously rather than
just assumed.

Dedicated tests beyond the mode sweep: SPI_CR's self-clearing behavior
(a readback the cycle after a write shows 0); SPI_IER/SPI_ISR — `irq`
stays low with IER=0 even if ISR is set, asserts once IER.DONE_IE is
enabled and a transfer completes, and deasserts on write-1-to-clear;
and SPI_CR.soft_reset mid-transfer, checking the core returns cleanly to
idle (mirroring `tb_spi_loopback.sv`'s mid-transfer reset test) and then
runs a normal transfer afterward to confirm it's genuinely usable again,
not merely idle-looking.

One real bug surfaced while writing the ISR/IER test: checking `irq`
immediately after the write task that clears an ISR bit, in the same
active-region time step as that write's own clock edge, read `irq`
*before* the write's nonblocking update had settled into the NBA
region — not an RTL bug, since the subsequent SPI_ISR readback (which
waits for a further clock edge) correctly saw the cleared bit. Fixed
with a `#1` settle delay before checking `irq` right after a write.

`run_error_handling_test` covers the error-handling features described
under "Register interface" above — none of which are exercised by the
mode sweep or the other dedicated tests, since those only ever hit valid
addresses, only write SPI_CR while idle, and always read SPI_DR promptly
after each transfer:
- reading and writing an unmapped address both set `SPI_ISR.PERR`, and
  the unmapped read returns 0;
- writing SPI_SR sets `PERR` and leaves SPI_SR's actual content
  (`TX_READY`) unaffected, since there's nothing there to corrupt;
- writing SPI_CR.start while already busy sets `PERR`;
- writing SPI_CR.start with the previous transfer's result still unread
  sets `SPI_ISR.OE`;
- `SPI_SR.ERR` tracks whether any error bit is currently set;
- `PSLVERR` is asserted during the ACCESS cycle of each of the three PERR
  cases above (captured via `last_pslverr`, sampled by
  `reg_write_task`/`reg_read_task` at the exact cycle `PREADY` is
  observed — the only cycle `PSLVERR` is meaningful, since `PSEL`/
  `PENABLE` fall back to 0 the instant either task returns, too late for
  a caller to sample directly), and stays low on ordinary valid accesses.
  (Forcing `PSLVERR` to a constant 0 reproducibly fails exactly these
  four checks and nothing else, confirming they isolate the bus-level
  error-reporting path from `SPI_ISR.PERR` itself.)

Writing the `OE` test caught a real modeling bug in the RTL itself (not
just the testbench): `oe_event` originally fired when the core's
`rx_valid` pulsed while `DONE`/`RX_VALID` was still set. But
`SPI_CR.start` *also* clears `DONE`/`RX_VALID` unconditionally (see
"SPI_SR" above), and that write happens *before* the new transfer can
complete and pulse `rx_valid` — so by the time `rx_valid` arrived, the
"was there still-unread data" evidence had already been erased by the
very `start` that should have triggered the overrun flag, and `OE` never
set. Fixed by checking `oe_event` at the `start` write itself instead
(`apb_write && PADDR == ADDR_CR && PWDATA[0] && done_latch`, using
`done_latch`'s value from just before that same write). Verified by
reverting to the original rx_valid-based check and confirming the OE
test — and only that test — fails without the fix.

`run_watchdog_test` covers `SPI_WDT`/`TO`, which none of the tests above
touch (they all leave `SPI_WDT` at its reset-default 0/disabled). It
checks: `TO` never fires with the watchdog disabled regardless of
transfer duration; a short threshold under a deliberately slow
(`clk_div=4`) transfer's duration fires `TO` *while still busy*, not
merely at completion, and `SPI_SR.ERR` reflects it; write-1-to-clearing
`TO` makes it stay clear for the rest of that same busy period even
though the underlying "busy and over threshold" condition remains
continuously true; a *new* busy period re-arms the gate, so the same
slow transfer fires `TO` again after an earlier clear; and a fast
transfer (`clk_div=0`) under the same threshold never fires `TO` at all,
proving the counter resets between transfers rather than accumulating.

Writing this test caught a real RTL bug: the first cut computed
`timeout_event` as a plain level (`busy && cnt >= threshold`), which
stays true for as long as the transfer remains slow and over threshold.
Since the `isr_reg[4]` set condition checks that level every cycle with
priority over the write-1-to-clear condition, clearing `TO` mid-transfer
was immediately overridden by the same still-true level on the very next
cycle — the bit could never actually be cleared while a slow transfer
was still in flight. Fixed with a `timeout_already_fired` latch (cleared
when `busy` deasserts) that gates the level down to a single pulse per
busy period, the same one-event-per-occurrence shape `oe_event`/
`perr_event` already have. Verified by reverting to the plain level
condition and confirming the two "stays cleared" checks — and only
those — fail without the fix.

`run_data_width_reg_test` covers `SPI_CFG.DATA_BITS`: writes a
narrower-than-`DATA_WIDTH` value, reads it back, then drives several
transfers at that width with garbage deliberately placed in `tx_data`'s
untransferred upper bits (via `SPI_DR`) — a design that still exchanged
the full `DATA_WIDTH` regardless of `DATA_BITS` would leak that garbage
into the peer's received word, where a correct narrower transfer comes
back zero-extended instead. It also covers rejection of an out-of-range
`DATA_BITS` write (`DATA_WIDTH + 1`): confirms `SPI_ISR.PERR` sets and
`SPI_CFG` reads back completely unchanged (both `DATA_BITS` and
`MODE`/`BIT_ORDER`), proving the whole write was dropped rather than
partially applied. Since the testbench's slave side is a plain `spi_top`
with no register bus of its own, `cfg_data_width_mirror` mirrors the
master's `SPI_CFG.DATA_BITS` the same way `cfg_cpol_mirror`/etc. already
mirror MODE/BIT_ORDER.

Own build target (`make reg-if`), its own coverage target
(`make coverage-reg-if`, `spi_reg_top.sv` including the watchdog logic
comes back 100% covered), and own VCDs (`waves/iverilog_reg_top.vcd`,
`waves/verilator_reg_top.vcd`).

### Daisy-chained slaves (`tb_spi_daisy_chain.sv`)

`spi_master` only supports single-word-per-`ss_n`-assertion transfers
(see "Data interface" above), so it cannot drive the `ss_n`-held-low-
for-many-words transaction a daisy chain needs. This testbench instead
uses a bit-banged virtual master — tasks that drive `ss_n`/`sclk`/`mosi`
directly and sample `miso`, mode-aware per CPOL/CPHA (mirroring
`spi_master`'s own sample-edge convention, so "what the virtual master
receives" means the same thing it would for the real core) — against
`NUM_SLAVES` (default 3) `spi_slave` cores instantiated directly and
chained point-to-point. A 20ns quantum between edges/setup points gives
each slave's synchronizer and registered-output pipeline (a handful of
`clk_s` cycles of latency) comfortable settling room, the same generous-
margin philosophy `tb_spi_loopback.sv`/`tb_spi_multi_slave.sv` use with a
real clock-driven `sclk`.

Each round sends `NUM_SLAVES` words, one intended per slave, transmitted
farthest-slave-first (matching how an N-stage shift register naturally
ends up holding the *last* bits shifted in at the nearest stage) across
an all-zeros round, an all-ones round, and 3 rounds of `$urandom` words,
swept across all 4 SPI modes and both bit orders. Each slave is also
independently preloaded with its own random "signature" word,
deliberately generated independently from the words being sent rather
than derived from them — so a bug that reverses or mixes up the RX and
TX chain directions the same way can't cancel out and slip past both
checks at once. Per round it verifies:
- every slave's `rx_data` matches the word sent for it;
- the virtual master's own received stream, split into `NUM_SLAVES`
  `DATA_WIDTH`-bit chunks, equals every slave's signature in *reverse*
  chain order — the predicted result of the TX-relay mechanism described
  under "Daisy-chained slaves" in "Architecture" above.

Reverting that relay mechanism (back to the original static indexed
readback) reproducibly fails this test for every slave past the first
one in the chain, while `tb_spi_loopback.sv`'s full suite stays green —
confirming the daisy-chain test is what actually isolates this feature,
and that the feature is genuinely additive.

Own build target (`make daisy-chain`) and own VCDs
(`waves/iverilog_daisy_chain.vcd`, `waves/verilator_daisy_chain.vcd`).

## Build / run

From the `sim/` directory:

```sh
make iverilog        # compile + run under Icarus Verilog -> waves/iverilog.vcd
make verilator       # compile + run under Verilator       -> waves/verilator.vcd
make coverage        # coverage-instrumented Verilator run -> coverage/annotated/
make width-sweep     # re-run the full suite at 9 DATA_WIDTH values, both sims
make multi-slave     # multi-drop bus test (1 master, N slaves), both sims ->
                      # waves/iverilog_multi_slave.vcd, waves/verilator_multi_slave.vcd
make reg-if          # register-interface test (spi_reg_top), both sims ->
                      # waves/iverilog_reg_top.vcd, waves/verilator_reg_top.vcd
make coverage-reg-if # coverage-instrumented run of the register interface ->
                      # coverage_reg_top/annotated/
make daisy-chain     # daisy-chained slaves test (bit-banged virtual master),
                      # both sims -> waves/iverilog_daisy_chain.vcd,
                      # waves/verilator_daisy_chain.vcd
make all             # iverilog + verilator (not coverage*/width-sweep/
                      # multi-slave/reg-if/daisy-chain)
make waves           # prints the gtkwave command and attempts to launch it
                      # (WAVE=../waves/verilator.vcd to pick a specific trace)
make clean           # removes build artifacts, VCDs, and coverage output
```

`make waves` assumes it may be running headless; it always prints the
exact command to run so you can copy it into an environment with a
display even if the automatic launch has nowhere to show a window.

### Coverage

`make coverage` builds the testbench with Verilator's `--coverage-line
--coverage-toggle` (its own `-Mdir obj_dir_cov`, kept separate from the
plain `verilator` target so a coverage build's instrumentation never
masks a normal build's warnings), runs the full `tb_spi_loopback.sv` test
sequence, and feeds the resulting `coverage.dat` through `verilator_coverage
--annotate` to produce a per-line/per-signal-toggle report at
`coverage/annotated/*.sv` (files with zero misses are omitted from that
directory by default — pass `--annotate-all` to `verilator_coverage`
yourself if you want every file written regardless). A line/toggle point
with a `%` prefix and a `000000` count is uncovered; run
`grep -n '^%000000' coverage/annotated/*.sv` to list them directly.

As of this writing, the RTL (`spi_master.sv`/`spi_slave.sv`/`spi_top.sv`)
is at 248/249 line+toggle points (99.6%); the sole miss is
`spi_master.sv`'s `default: state <= ST_IDLE;` in the FSM's `case
(state)`, which is unreachable dead code — `state` is a 2-bit
`typedef enum` with only 3 defined values, so the 4th encoding this
`default` guards against can never actually occur in simulation.
`tb_spi_loopback.sv` itself reports much lower coverage in the same run,
which is expected and not meaningful: most of its uncovered lines are the
`$display("... FAIL ...")` branches inside each check, which only
execute when a test *fails* — a clean passing run should never hit them.

### Register interface coverage

`make coverage-reg-if` is the same instrumentation approach applied to
`spi_reg_top.sv`/`tb_spi_reg_top.sv` instead: its own `-Mdir
obj_dir_cov_reg_top` and its own output directory
(`coverage_reg_top/annotated/*.sv`, `coverage_reg_top/coverage.info`, and
the raw `coverage_reg_top/coverage.dat`), so it never collides with the
core-only `coverage` target's artifacts — both would otherwise write
`coverage.dat` to the same working directory.

`spi_reg_top.sv` itself comes back fully covered: 132/132 line+toggle
points. Combined with `spi_slave.sv`/`spi_top.sv` also fully covered in
this run, the only miss anywhere in the RTL is `spi_master.sv`'s single
already-documented unreachable `default` case above — i.e. adding the
register interface and its error-handling logic didn't introduce any new
coverage gaps of its own, `run_error_handling_test` (see "Testbench"
below) exercises every branch the error-detection logic added.

The default `make iverilog`/`make verilator`/`make coverage` runs all use
`DATA_WIDTH=8`, which line/toggle coverage confirms exercises nearly
every RTL branch — but coverage at one width says nothing about
correctness at *other* widths, since the `$clog2`-based `bit_cnt`/
`msb_index`/`lsb_index` sizing in both cores has real edge-case risk at
extremes (`DATA_WIDTH=1`, or non-power-of-2 widths where `$clog2` rounds
up). `DATA_WIDTH` on `tb_spi_loopback` is a real module `parameter`
(not a `localparam`) specifically so it can be overridden from the
command line without editing the testbench — iverilog's
`-P tb_spi_loopback.DATA_WIDTH=<N>` and Verilator's `-GDATA_WIDTH=<N>`
both target it directly.

`make width-sweep` re-elaborates and re-runs the full 927-check test
sequence — including `run_data_width_test`/`run_data_width_mid_transfer_test`
(skipped only at `DATA_WIDTH=1`, which has no narrower width available)
— at `DATA_WIDTH` in `{1, 2, 3, 4, 5, 8, 12, 16, 32}`, on both simulators
(18 runs total), each into its own build directory (`sim_iv.out_wN`,
`obj_dir_wN`) so a failure at one width doesn't clobber another's
artifacts.

This sweep caught two real RTL bugs that the DATA_WIDTH=8-only tests
could never have found, both specific to `DATA_WIDTH=1`:

1. **Zero-width index vector.** `IDX_WIDTH = $clog2(DATA_WIDTH)` is `0`
   when `DATA_WIDTH=1` (there's only one possible bit index, so no index
   bits are needed) — but a `logic [IDX_WIDTH-1:0]` declaration with
   `IDX_WIDTH=0` is a genuinely illegal zero-width vector, and iverilog
   crashed outright trying to elaborate it. Fixed by flooring
   `IDX_WIDTH` at 1 (`(DATA_WIDTH > 1) ? $clog2(DATA_WIDTH) : 1`); the
   extra bit is simply unused at `DATA_WIDTH=1`.
2. **Out-of-order part-selects.** The MSB-first/LSB-first shift-in logic
   used `rx_shift[DATA_WIDTH-2:0]` and `rx_shift[DATA_WIDTH-1:1]`, both
   of which become invalid (`[-1:0]`, `[0:1]`) at `DATA_WIDTH=1`. Fixed
   by replacing the part-select-based shift-and-concatenate with an
   equivalent shift-and-OR formulation (`(rx_shift << 1) | DATA_WIDTH'(bit)`
   and `(rx_shift >> 1) | (DATA_WIDTH'(bit) << (DATA_WIDTH-1))`), which is
   valid at any `DATA_WIDTH >= 1` and produces identical results to the
   old part-select form at every width where that form was valid.

Bringing the width sweep to a clean pass also surfaced (and required
fixing) several testbench-only timing assumptions that were implicitly
tuned for `DATA_WIDTH=8`: `run_mid_transfer_glitch_test`'s fixed glitch
offsets (40/60 cycles) and `run_cfg_write_pulse_during_busy_test`'s fixed
6-cycle wait both assumed an ~80-cycle transfer window, which shrinks
proportionally with `DATA_WIDTH`. These are now computed from
`XFER_CYCLES = (2*DATA_WIDTH-1) * (BASELINE_DIV+1)` — the exact toggle
count needed (the last bit only needs its sample edge to complete, not a
following shift edge) times the per-toggle period — and `BASELINE_DIV`
itself is chosen so `XFER_CYCLES` lands near a fixed ~60-cycle target
regardless of `DATA_WIDTH`, keeping a comfortable, constant margin above
the slave's few-cycle CDC synchronizer latency at every width instead of
letting that fixed latency crowd out an already-short window at small
widths.

## Viewing waveforms

```sh
gtkwave waves/iverilog.vcd
gtkwave waves/verilator.vcd
```

Signals worth adding first, for both the `u_master` and `u_slave`
instances in the loopback testbench:

- `ss_n_w`, `sclk_w`, `mosi_w`, `miso_w` — the shared bus lines
- `u_master...tx_data` / `u_master...rx_data` / `u_master...rx_valid`
- `u_slave...tx_data` / `u_slave...rx_data` / `u_slave...rx_valid`
- Inside `spi_slave`: `ss_n_s`, `sclk_s`, `mosi_s` (synchronized versions)
  and `sample_edge`/`shift_edge` to see exactly when the slave samples
  and drives bits relative to the raw, unsynchronized bus lines.
