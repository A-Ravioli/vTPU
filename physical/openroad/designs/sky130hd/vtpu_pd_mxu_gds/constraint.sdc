current_design vtpu_pd_mxu_gds_top

create_clock -name core_clk -period 50.000 [get_ports clk]

set_input_delay 1.000 -clock core_clk [get_ports {
  rst_n
  cmd_valid
  dst_addr[*]
  src_a_addr[*]
  src_b_addr[*]
  m[*]
  n[*]
  k[*]
  accumulate
  vmem_ready
  vmem_valid
  vmem_rdata[*]
  vmem_error
}]
set_output_delay 1.000 -clock core_clk [all_outputs]
set_false_path -from [get_ports rst_n]
