####################################
# global connections
####################################
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {^VDD$} -power
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {^VDDPE$}
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {^VDDCE$}
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {VPWR}
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {VPB}
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {^vdd$} -power
add_global_connection -net {VSS} -inst_pattern {.*} -pin_pattern {^VSS$} -ground
add_global_connection -net {VSS} -inst_pattern {.*} -pin_pattern {^VSSE$}
add_global_connection -net {VSS} -inst_pattern {.*} -pin_pattern {VGND}
add_global_connection -net {VSS} -inst_pattern {.*} -pin_pattern {VNB}
add_global_connection -net {VSS} -inst_pattern {.*} -pin_pattern {^gnd$} -ground
global_connect

####################################
# voltage domain and grids
####################################
set_voltage_domain -name {CORE} -power {VDD} -ground {VSS}

define_pdn_grid -name {stdcell_grid} -voltage_domains {CORE}
add_pdn_stripe -grid {stdcell_grid} -layer {met1} -followpins
add_pdn_stripe -grid {stdcell_grid} -layer {met4} -width 1.600 -pitch 180.000 -offset 20.000
add_pdn_stripe -grid {stdcell_grid} -layer {met5} -width 1.600 -pitch 180.000 -offset 20.000
add_pdn_connect -grid {stdcell_grid} -layers {met1 met4}
add_pdn_connect -grid {stdcell_grid} -layers {met4 met5}

define_pdn_grid -macro -name {sram_grid} -voltage_domains {CORE} -orient {R0 R180 MX MY}
add_pdn_connect -grid {sram_grid} -layers {met4 met5}
