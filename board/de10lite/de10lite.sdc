# Timing constraints for de10lite_top.

create_clock -name clk50 -period 20.000 [get_ports {MAX10_CLK1_50}]
derive_clock_uncertainty

# The push-button and the switches are synchronised by two flip-flops, the
# LEDs and the UART line are slow and asynchronous to any external clock.
set_false_path -from [get_ports {KEY[*] SW[*]}]
set_false_path -to [get_ports {LEDR[*] UART_TX}]
