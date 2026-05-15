import numpy as np

from virtual_tpu.golden import GoldenExecutor, HaltReason
from virtual_tpu.isa import AddressSpace, halt, matmul
from virtual_tpu.memory import MemorySystem
from virtual_tpu.numeric import bf16_matmul, float32_to_bf16


def test_bf16_matmul_reference_path() -> None:
    memory = MemorySystem(hbm_bytes=4096, cmem_bytes=4096, vmem_bytes=4096)
    a_f32 = np.array([[1.5, -2.0], [0.25, 4.0]], dtype=np.float32)
    b_f32 = np.array([[2.0, 3.0], [-1.0, 0.5]], dtype=np.float32)
    a = float32_to_bf16(a_f32)
    b = float32_to_bf16(b_f32)
    memory.write_u16_matrix(AddressSpace.VMEM0, 0, a)
    memory.write_u16_matrix(AddressSpace.VMEM0, 16, b)
    result = GoldenExecutor([matmul(dst_addr=64, src_a_addr=0, src_b_addr=16, m=2, n=2, k=2, bf16=True), halt()], memory).run()
    assert result.reason is HaltReason.HALT
    np.testing.assert_allclose(memory.read_f32_matrix(AddressSpace.VMEM0, 64, 2, 2), bf16_matmul(a, b), rtol=1e-6, atol=1e-6)
