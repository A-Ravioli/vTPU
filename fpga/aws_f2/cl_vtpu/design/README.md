# cl_vtpu Design Payload

This folder is copied into the AWS HDK-generated `cl_vtpu/design` directory.

The portable top for local validation is `vtpu_f2_smoke_top`. The HDK shell top
should instantiate this module from its OCL AXI-Lite and HBM channel-0 wiring.
The sync script keeps the RTL payload and source manifest together so the AWS
build scripts can import the same files used by local cocotb tests.

