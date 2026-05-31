# Deterministic placement for the OpenRAM macros used by vtpu_pd_tiny.
# Macro size: sky130_sram_1rw1r_80x64_8 = 758.67um x 239.855um.

proc vtpu_place_macro {name x y orient} {
  place_macro -macro_name $name -location [list $x $y] -orientation $orient -exact
}

set x0 150
set x1 1100
set x2 2050
set x3 3000
set x4 3950
set y0 180
set y_step 360

# Instruction memory sits close to control/program-load logic.
vtpu_place_macro {u_vtpu/gen_physical_instr_mem.u_instr_mem/u_instr_lower/u_macro} $x0 $y0 R0
vtpu_place_macro {u_vtpu/gen_physical_instr_mem.u_instr_mem/u_instr_upper/u_macro} $x1 $y0 R0

# Shared CMEM is placed in the upper-middle of the core.
for {set i 0} {$i < 16} {incr i} {
  set col [expr {$i % 4}]
  set row [expr {$i / 4}]
  set x [lindex [list $x0 $x1 $x2 $x3] $col]
  set y [expr {$y0 + (1 + $row) * $y_step}]
  set name [format {u_vtpu/gen_physical_cmem.u_cmem/gen_cmem_banks\[%d\].u_bank/u_macro} $i]
  vtpu_place_macro $name $x $y R0
}

# TC0 VMEM banks sit below CMEM on the left/center side.
for {set i 0} {$i < 16} {incr i} {
  set col [expr {$i % 4}]
  set row [expr {$i / 4}]
  set x [lindex [list $x0 $x1 $x2 $x3] $col]
  set y [expr {$y0 + (5 + $row) * $y_step}]
  set name [format {u_vtpu/u_tensor_core0/gen_physical_vmem.u_vmem/gen_vmem_banks\[%d\].u_bank/u_macro} $i]
  vtpu_place_macro $name $x $y R0
}

# TC1 VMEM banks sit in the lower half, shifted right.
for {set i 0} {$i < 16} {incr i} {
  set col [expr {$i % 4}]
  set row [expr {$i / 4}]
  set x [lindex [list $x1 $x2 $x3 $x4] $col]
  set y [expr {$y0 + (9 + $row) * $y_step}]
  set name [format {u_vtpu/u_tensor_core1/gen_physical_vmem.u_vmem/gen_vmem_banks\[%d\].u_bank/u_macro} $i]
  vtpu_place_macro $name $x $y R0
}
