# I²C Master Controller — Interface Contract

**Project:** RTL Design of I²C Master in Verilog HDL  
**Role Owner:** P1 — Architect & Integration Lead  
**File:** `interface_contract.md`  
**Version:** 1.0  
**Status:** Working implementation contract

---

## 1. Purpose

This document defines the common **interface, timing, transaction, and integration contract** for the I²C Master Controller.

The goal is simple: everyone on the team should use the same signal names, widths, timing assumptions, transaction flow, and handshake behaviour so that individual RTL blocks can be integrated cleanly.

> **This file is the common reference for RTL integration.**

---

## 2. Project Scope

The project is an RTL implementation and verification of an **I²C Master Controller using Verilog HDL**.

### Baseline functionality

- 7-bit I²C slave addressing
- Single-byte write operation
- Single-byte read operation
- START condition generation
- STOP condition generation
- ACK/NACK detection
- `busy`, `done`, and `ack_error` status
- Open-drain style SDA/SCL behaviour
- Behavioural I²C slave model for simulation
- RTL simulation and waveform verification

### Outside the baseline

The following are not part of the current baseline:

- 10-bit addressing
- Multi-master arbitration
- Clock stretching
- Repeated START
- Multi-byte transfer protocol
- Runtime-programmable I²C frequency
- FPGA/hardware implementation
- Advanced SystemVerilog/UVM verification

---

## 3. Baseline Design Parameters

| Parameter | Value |
|---|---:|
| System clock | **50 MHz** |
| System clock period | **20 ns** |
| I²C SCL frequency | **100 kHz** |
| I²C mode | **Standard Mode** |
| Address width | **7 bits** |
| Data width | **8 bits** |
| Transfer size | **Single byte** |
| R/W encoding | `0 = Write`, `1 = Read` |
| Reset | **Active-high synchronous** |
| Clock stretching | Not supported |
| Repeated START | Not supported |
| 10-bit addressing | Not supported |

### Timing calculation

```text
System clock period = 1 / 50 MHz = 20 ns
I²C clock period     = 1 / 100 kHz = 10 µs

System-clock cycles per I²C period:
50 MHz / 100 kHz = 500 cycles

Using four timing phases per SCL period:
500 / 4 = 125 system-clock cycles per phase
```

Therefore:

```text
Quarter phase = 125 system-clock cycles = 2.5 µs
Half SCL      = 250 system-clock cycles = 5 µs
Full SCL      = 500 system-clock cycles = 10 µs
```

---

## 4. Top-Level Interface

The top-level module shall use the following interface:

```verilog
module i2c_master (
    input  wire       clk,
    input  wire       reset,
    input  wire       start,

    input  wire [6:0] slave_addr,
    input  wire       rw,
    input  wire [7:0] write_data,

    output wire [7:0] read_data,
    output wire       busy,
    output wire       done,
    output wire       ack_error,

    inout  wire       scl,
    inout  wire       sda
);
```

### Port definition

| Signal | Direction | Width | Description |
|---|---|---:|---|
| `clk` | Input | 1 | 50 MHz system clock |
| `reset` | Input | 1 | Active-high synchronous reset |
| `start` | Input | 1 | Requests a new transaction |
| `slave_addr` | Input | 7 | Target 7-bit slave address |
| `rw` | Input | 1 | `0` = Write, `1` = Read |
| `write_data` | Input | 8 | Byte transmitted during write |
| `read_data` | Output | 8 | Byte received during read |
| `busy` | Output | 1 | Indicates an active transaction |
| `done` | Output | 1 | One-clock completion pulse |
| `ack_error` | Output | 1 | Expected ACK was not received |
| `scl` | Inout | 1 | I²C clock line |
| `sda` | Inout | 1 | I²C data line |

---

## 5. Transaction Handshake

### `start`

Requests a new transaction.

A transaction is accepted only when:

```text
busy = 0
```

If `busy = 1`, the new `start` request is ignored in the baseline design.

### `busy`

```text
IDLE        → busy = 0
Transaction → busy = 1
Completed   → busy = 0
```

### `done`

`done` is a **one-system-clock-cycle pulse** after the transaction and STOP sequence have completed.

```text
done = 1  → one clk cycle
done = 0  → otherwise
```

### `ack_error`

```text
0 → normal operation
1 → NACK detected where ACK was expected
```

`ack_error` is cleared on reset or when a new transaction is accepted.

---

## 6. Reset Contract

Reset is **active-high synchronous**.

When `reset = 1` on the active system-clock edge, the controller returns to a known idle state.

| Signal / state | Reset value |
|---|---:|
| FSM state | `IDLE` |
| `busy` | `0` |
| `done` | `0` |
| `ack_error` | `0` |
| `read_data` | `8'b0` |
| Shift registers | Known reset value |
| Bit counters | Known reset value |
| SDA control | Released |
| SCL control | Inactive/released |

---

## 7. Address and Data Format

### Address frame

```text
A6 A5 A4 A3 A2 A1 A0 R/W
```

### R/W encoding

```text
R/W = 0  → Write
R/W = 1  → Read
```

### Data byte

Data is transmitted MSB first:

```text
D7 D6 D5 D4 D3 D2 D1 D0
```

---

## 8. Transaction Flow

The baseline sequence is:

```text
IDLE
  ↓
START
  ↓
SEND_ADDR
  ↓
ADDR_ACK
  ↓
READ / WRITE
  ↓
DATA_ACK / MASTER_NACK
  ↓
STOP
  ↓
DONE
  ↓
IDLE
```

If an expected ACK is not received:

```text
NACK
 ↓
ack_error = 1
 ↓
STOP
 ↓
DONE
 ↓
IDLE
```

---

## 9. Write Transaction

```text
START
  ↓
7-bit Slave Address + Write
  ↓
Slave ACK
  ↓
8-bit Write Data
  ↓
Slave ACK
  ↓
STOP
  ↓
DONE
```

Waveform expectation:

```text
START → Address + W → ACK → Data → ACK → STOP → DONE
```

---

## 10. Read Transaction

```text
START
  ↓
7-bit Slave Address + Read
  ↓
Slave ACK
  ↓
Slave sends 8-bit Data
  ↓
Master sends NACK
  ↓
STOP
  ↓
DONE
```

Waveform expectation:

```text
START → Address + R → ACK → Slave Data → Master NACK → STOP → DONE
```

The received byte is stored in:

```text
read_data[7:0]
```

---

## 11. ACK/NACK Contract

During the ACK bit:

```text
SDA = 0 → ACK
SDA = 1 → NACK
```

### Address phase

```text
ACK  → continue
NACK → ack_error = 1 → terminate safely
```

### Write-data phase

```text
Data transmitted
      ↓
Release SDA
      ↓
Sample ACK/NACK
```

### Read completion

For the baseline single-byte read:

```text
Slave sends data
      ↓
Master sends NACK
      ↓
STOP
```

---

## 12. SDA / SCL Behaviour

SDA and SCL use an **open-drain style** implementation.

The master:

- Drives LOW to transmit logic `0`
- Releases the line to represent logic `1`
- Releases SDA when the slave must drive the bus
- Samples the actual bus value for received data and ACK/NACK

### SDA

```verilog
assign sda = sda_drive_low ? 1'b0 : 1'bz;
wire   sda_in = sda;
```

### SCL

```verilog
assign scl = scl_drive_low ? 1'b0 : 1'bz;
wire   scl_in = scl;
```

The simulation testbench should provide pull-up behaviour so released lines resolve HIGH.

---

## 13. START and STOP

### START condition

```text
SDA: HIGH → LOW
SCL: HIGH
```

### STOP condition

```text
SDA: LOW → HIGH
SCL: HIGH
```

Both conditions must be clearly visible in simulation waveforms.

---

## 14. Internal Architecture

```text
                 ┌─────────────────────────┐
                 │     I²C MASTER TOP      │
                 │                         │
                 │  ┌───────────────────┐  │
                 │  │   FSM / Control   │  │
                 │  └─────────┬─────────┘  │
                 │            │            │
                 │  ┌─────────▼─────────┐  │
                 │  │ Timing / SCL Gen │  │
                 │  └─────────┬─────────┘  │
                 │            │            │
                 │  ┌─────────▼─────────┐  │
                 │  │  Data Shift Reg   │  │
                 │  └─────────┬─────────┘  │
                 │            │            │
                 │  ┌─────────▼─────────┐  │
                 │  │   ACK/NACK Detect │  │
                 │  └─────────┬─────────┘  │
                 │            │            │
                 │  ┌─────────▼─────────┐  │
                 │  │   SDA/SCL Control │  │
                 │  └─────────┬─────────┘  │
                 └────────────┼────────────┘
                              │
                         SDA / SCL
```

### Functional blocks

| Block | Responsibility |
|---|---|
| Clock & Timing Unit | Generates internal timing references and SCL cadence |
| FSM / Control Unit | Controls the transaction sequence |
| Data Shift Register | Transmits address/data and captures received data |
| ACK/NACK Detector | Detects slave ACK/NACK |
| SDA Control | Controls SDA drive/release |
| SCL Generation/Control | Controls SCL timing |
| Top-level Integration | Connects all RTL blocks |
| Behavioural Slave | Simulates the I²C slave |
| Testbench | Generates transactions and checks results |

---

## 15. Internal Module Contracts

### 15.1 SCL / Timing Generator

**Inputs**

```text
clk
reset
enable
```

**Outputs**

```text
timing_tick
SCL control
```

**Parameters**

```text
CLK_FREQ_HZ = 50_000_000
I2C_FREQ_HZ = 100_000
```

The timing generator provides the timing reference required by the FSM and SCL control logic.

---

### 15.2 FSM / Control Unit

**Inputs**

```text
clk
reset
start
rw
timing_tick
ACK/NACK status
shift status
```

**Outputs**

```text
State/control enables
SDA drive control
SCL drive control
busy
done
ack_error
```

The FSM owns the transaction sequence.

---

### 15.3 Data Shift Register

Responsibilities:

- Load the address and R/W bit
- Shift transmitted bits MSB first
- Load write data
- Capture eight received bits
- Provide the completed received byte to `read_data`

---

### 15.4 ACK/NACK Detector

Responsibilities:

- Release SDA during the ACK bit
- Sample SDA at the required timing point
- Report ACK or NACK to the FSM

```text
SDA = 0 → ACK
SDA = 1 → NACK
```

---

### 15.5 SDA Controller

Responsibilities:

```text
Drive LOW → transmit 0
Release   → allow bus HIGH / slave drive
Sample    → receive data or ACK/NACK
```

---

## 16. RTL Repository Structure

```text
i2c_master_project/
│
├── rtl/
│   ├── i2c_master_top.v
│   ├── i2c_fsm.v
│   ├── i2c_scl_gen.v
│   ├── i2c_shift_reg.v
│   ├── i2c_ack_detect.v
│   └── i2c_sda_ctrl.v
│
├── tb/
│   ├── i2c_master_tb.v
│   └── i2c_slave_model.v
│
├── sim/
├── waves/
└── docs/
    └── interface_contract.md
```

---

## 17. Verification Contract

The integrated design should demonstrate:

| Test | Expected result |
|---|---|
| Reset | Controller enters `IDLE` |
| Write | Correct address and data are transmitted |
| Read | Correct byte is captured in `read_data` |
| Address ACK | Transaction continues |
| Address NACK | `ack_error = 1` and transaction terminates |
| Data ACK | Write transaction completes |
| Busy | `busy = 1` during active transaction |
| Completion | `done` pulses after completion |
| Idle | `busy = 0` when no transaction is active |
| Multiple write-data cases | Different data values are transmitted correctly |

---

## 18. Waveform Checklist

The following should be visible during simulation:

- `clk`
- `reset`
- `start`
- `busy`
- `done`
- `ack_error`
- `slave_addr`
- `rw`
- `write_data`
- `read_data`
- `scl`
- `sda`
- START condition
- Address bits
- R/W bit
- ACK/NACK bit
- Data bits
- STOP condition

### Successful write

```text
START → Address + W → ACK → Data → ACK → STOP → DONE
```

### Successful read

```text
START → Address + R → ACK → Slave Data → Master NACK → STOP → DONE
```

---

## 19. Integration Rules

To avoid integration problems:

1. Use the exact top-level signal names defined here.
2. Do not change signal widths independently.
3. Use the 50 MHz system-clock assumption.
4. Use the 100 kHz SCL baseline.
5. Follow the same reset behaviour.
6. Follow the same transaction sequence.
7. Use MSB-first transmission.
8. Use the same ACK/NACK interpretation.
9. Keep SDA/SCL open-drain behaviour consistent.
10. Compile individual modules before integration.
11. Keep internal interfaces clearly documented.
12. Any interface change must be reflected in this document and the affected RTL.

---

## 20. P1 — Architect & Integration Lead

P1 owns the common integration layer.

Responsibilities:

- Maintain this interface contract
- Maintain the top-level port list
- Maintain signal widths and handshake definitions
- Maintain the transaction/FSM sequence
- Maintain timing assumptions
- Connect the individual RTL blocks
- Maintain the top-level `i2c_master` module
- Resolve module-to-module interface mismatches
- Maintain the repository structure
- Integrate the behavioural slave model
- Integrate the testbench
- Coordinate simulation and waveform debugging
- Coordinate final integration checks

P1 does **not** replace the work of individual module owners. The purpose is to make sure all modules fit together into one working design.

---

## 21. Baseline Boundary

The current implementation should focus first on making the **core single-byte I²C Master work correctly and verify cleanly**.

Future extensions may include:

- Multi-byte transactions
- Repeated START
- 10-bit addressing
- Clock stretching
- Multi-master arbitration
- Runtime-programmable SCL frequency
- Advanced SystemVerilog/UVM verification
- FPGA implementation

These should not be added to the baseline unless the team intentionally expands the project scope.

---

## 22. Quick Reference

### System

```text
CLK       = 50 MHz
I²C SCL   = 100 kHz
Address   = 7-bit
Data      = 8-bit
Reset     = Active-high synchronous
```

### R/W

```text
0 = Write
1 = Read
```

### ACK

```text
SDA = 0 → ACK
SDA = 1 → NACK
```

### Handshake

```text
start      → request transaction
busy       → transaction active
done       → transaction completed
ack_error  → expected ACK was not received
```

### Transaction

```text
IDLE
 ↓
START
 ↓
ADDRESS + R/W
 ↓
ACK
 ↓
DATA
 ↓
ACK / NACK
 ↓
STOP
 ↓
DONE
 ↓
IDLE
```

---

## 23. Final Team Reference

**Everyone should use this document as the common interface reference while implementing their respective blocks.**

The intended flow is:

```text
Individual RTL Blocks
        ↓
Common Interfaces
        ↓
Top-Level Integration
        ↓
Behavioural Slave + Testbench
        ↓
Simulation
        ↓
Waveform Verification
        ↓
Final Integrated Design
```

**Document owner:** P1 — Architect & Integration Lead  
**File:** `interface_contract.md`
