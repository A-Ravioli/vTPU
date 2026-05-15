import pytest

from virtual_tpu.isa import AddressSpace
from virtual_tpu.memory import MemoryError, MemorySystem


def test_memory_read_write_roundtrip() -> None:
    memory = MemorySystem(hbm_bytes=1024, cmem_bytes=1024, vmem_bytes=1024)
    memory.write(AddressSpace.HBM, 16, b"abcd")
    assert memory.read(AddressSpace.HBM, 16, 4) == b"abcd"


def test_memory_rejects_out_of_bounds_access() -> None:
    memory = MemorySystem(hbm_bytes=32, cmem_bytes=32, vmem_bytes=32)
    with pytest.raises(MemoryError):
        memory.write(AddressSpace.VMEM0, 31, b"xx")
