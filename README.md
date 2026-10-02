# I2C Master Controller Project

RTL design and verification of a configurable I2C master controller (Verilog).

## Structure
- rtl/   — RTL source modules (P1–P5)
- tb/    — Testbench, slave model, drivers/monitor/scoreboard (P6)
- sim/   — Simulation run scripts/outputs
- waves/ — VCD waveform dumps
- docs/  — Interface contract and documentation

## Branch convention
- main — stable, integrated code only
- p<n>-<short-name> — individual work branches, e.g. p2-clock-gen, p6-verif-infra
- Compile/test your module standalone before opening a PR to main

## Build/sim flow
iverilog -> vvp -> GTKWave
