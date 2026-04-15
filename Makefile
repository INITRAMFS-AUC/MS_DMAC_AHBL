# ============================================================
# Verilator simulation Makefile for MS_DMAC_AHBL
# Requires Verilator v5.x (for --timing support)
#
# NOTE: The testbench connects .PIRQ(PIRQ) to the DUV, but the
# current RTL (MS_DMAC_AHBL.pp.v) does not declare a PIRQ port.
# Add "input wire PIRQ," to the module port list in the RTL
# before running, or Verilator will error with an unknown port.
# ============================================================

RTL_DIR  := hdl/rtl
DV_DIR   := hdl/dv
SIM_DIR  := sim

TOP      := MS_DMAC_AHBL_tb
EXE      := V$(TOP)

# Use the pre-processed file to avoid needing ahbl_util.vh macros
RTL_SRC  := $(RTL_DIR)/MS_DMAC_AHBL.pp.v
TB_SRC   := $(DV_DIR)/MS_DMAC_AHBL_tb.v

VFLAGS := \
	--binary \
	--timing \
	--trace \
	--top-module $(TOP) \
	-I$(DV_DIR) \
	-Wno-TIMESCALEMOD \
	-Wno-STMTDLY \
	-Wno-MULTIDRIVEN \
	-Wno-UNDRIVEN \
	-Wno-WIDTH

.PHONY: all sim waves clean

all: sim

# Build the simulation executable
$(SIM_DIR)/$(EXE): $(RTL_SRC) $(TB_SRC)
	mkdir -p $(SIM_DIR)
	verilator $(VFLAGS) --Mdir $(SIM_DIR) -o $(EXE) $(RTL_SRC) $(TB_SRC)

# Run the simulation
sim: $(SIM_DIR)/$(EXE)
	cd $(SIM_DIR) && ./$(EXE)

# Open the VCD waveform (requires GTKWave)
waves:
	gtkwave $(SIM_DIR)/MS_DMAC_AHBL_tb.vcd &

clean:
	rm -rf $(SIM_DIR)
