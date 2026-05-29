current_design vtpu_pd_smoke_top

create_clock -name core_clk -period 100.000 [get_ports clk]

set_input_delay 2.000 -clock core_clk [get_ports {
  rst_n
  host_req_valid
  host_req_write
  host_req_addr[*]
  host_req_wdata[*]
}]
set_output_delay 2.000 -clock core_clk [all_outputs]

set_false_path -from [get_ports rst_n]
