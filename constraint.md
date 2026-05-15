# ===================================================================
# NEXYS 4 / A7-100T PIN CONSTRAINTS FOR CNN ACCELERATOR
# ===================================================================

# 1. Clock Signal (100 MHz oscillator on pin E3)
set_property -dict { PACKAGE_PIN E3    IOSTANDARD LVCMOS33 } [get_ports { clk }];
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { clk }];

# 2. Reset (Center Push Button - BTNC)
set_property -dict { PACKAGE_PIN N17   IOSTANDARD LVCMOS33 } [get_ports { rst }];

# 3. Status LEDs (LED 0 and LED 1)
set_property -dict { PACKAGE_PIN H17   IOSTANDARD LVCMOS33 } [get_ports { prog_led }];
set_property -dict { PACKAGE_PIN K15   IOSTANDARD LVCMOS33 } [get_ports { done_led }];

# 4. SPI Interface (Mapped to Pmod JA Header - Top Row)
# JA1 -> Chip Select (CS)
set_property -dict { PACKAGE_PIN C17   IOSTANDARD LVCMOS33 } [get_ports { cs }];
# JA2 -> Master Out Slave In (MOSI)
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { mosi }];
# JA3 -> Master In Slave Out (MISO)
set_property -dict { PACKAGE_PIN E18   IOSTANDARD LVCMOS33 } [get_ports { miso }];
# JA4 -> SPI Clock (SCLK)
set_property -dict { PACKAGE_PIN G17   IOSTANDARD LVCMOS33 } [get_ports { sclk }];