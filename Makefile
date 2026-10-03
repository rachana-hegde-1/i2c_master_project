SIM     = vvp
COMPILE = iverilog
TOP     = tb.vvp

RTL_SRC = $(wildcard rtl/*.v)
TB_SRC  = tb/i2c_master_tb.v tb/i2c_slave_model.v

all: sim

sim: $(TOP)
	$(SIM) $(TOP)

$(TOP): $(TB_SRC) $(RTL_SRC)
	$(COMPILE) -o $(TOP) $(TB_SRC) $(RTL_SRC)

wave: sim
	gtkwave waves/wave.vcd

clean:
	rm -f $(TOP)
	rm -f waves/*.vcd
