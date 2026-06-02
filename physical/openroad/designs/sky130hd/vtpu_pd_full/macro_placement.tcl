# Deterministic SRAM macro placement for default-scale vtpu_pd_full.
# Macro size: sky130_sram_1rw1r_80x64_8 = 758.67um x 239.855um.
# Default macro counts:
#   instruction memory: 2 halves * 16 tiles = 32 macros
#   CMEM: 16 banks * 128 tiles = 2048 macros
#   VMEM: 2 TensorCores * 16 banks * 64 tiles = 2048 macros

proc vtpu_place_macro {name x y orient} {
  place_macro -macro_name $name -location [list $x $y] -orientation $orient -exact
}

proc vtpu_grid_location {index cols x0 y0 x_step y_step} {
  set col [expr {$index % $cols}]
  set row [expr {$index / $cols}]
  return [list [expr {$x0 + ($col * $x_step)}] [expr {$y0 + ($row * $y_step)}]]
}

set x0 500
set x_step 850
set y_step 300
set cols 32

# Instruction memory is close to the lower-left host/control edge.
for {set tile 0} {$tile < 16} {incr tile} {
  set loc [vtpu_grid_location $tile $cols $x0 400 $x_step $y_step]
  set name [format {u_vtpu/gen_physical_instr_mem.u_instr_mem/u_instr_lower/gen_macro_tiles\[%d\].u_macro} $tile]
  vtpu_place_macro $name [lindex $loc 0] [lindex $loc 1] R0
}
for {set tile 0} {$tile < 16} {incr tile} {
  set loc [vtpu_grid_location [expr {$tile + 16}] $cols $x0 400 $x_step $y_step]
  set name [format {u_vtpu/gen_physical_instr_mem.u_instr_mem/u_instr_upper/gen_macro_tiles\[%d\].u_macro} $tile]
  vtpu_place_macro $name [lindex $loc 0] [lindex $loc 1] R0
}

# TC0 VMEM region: 16 banks, 64 macro tiles per bank.
for {set bank 0} {$bank < 16} {incr bank} {
  for {set tile 0} {$tile < 64} {incr tile} {
    set idx [expr {($bank * 64) + $tile}]
    set loc [vtpu_grid_location $idx $cols $x0 1200 $x_step $y_step]
    set name [format {u_vtpu/u_tensor_core0/gen_physical_vmem.u_vmem/gen_vmem_banks\[%d\].u_bank/gen_macro_tiles\[%d\].u_macro} $bank $tile]
    vtpu_place_macro $name [lindex $loc 0] [lindex $loc 1] R0
  }
}

# Shared CMEM region: 16 banks, 128 macro tiles per bank.
for {set bank 0} {$bank < 16} {incr bank} {
  for {set tile 0} {$tile < 128} {incr tile} {
    set idx [expr {($bank * 128) + $tile}]
    set loc [vtpu_grid_location $idx $cols $x0 11200 $x_step $y_step]
    set name [format {u_vtpu/gen_physical_cmem.u_cmem/gen_cmem_banks\[%d\].u_bank/gen_macro_tiles\[%d\].u_macro} $bank $tile]
    vtpu_place_macro $name [lindex $loc 0] [lindex $loc 1] R0
  }
}

# TC1 VMEM region: mirrored at the top of the core to leave routing channels.
for {set bank 0} {$bank < 16} {incr bank} {
  for {set tile 0} {$tile < 64} {incr tile} {
    set idx [expr {($bank * 64) + $tile}]
    set loc [vtpu_grid_location $idx $cols $x0 30600 $x_step $y_step]
    set name [format {u_vtpu/u_tensor_core1/gen_physical_vmem.u_vmem/gen_vmem_banks\[%d\].u_bank/gen_macro_tiles\[%d\].u_macro} $bank $tile]
    vtpu_place_macro $name [lindex $loc 0] [lindex $loc 1] R0
  }
}
