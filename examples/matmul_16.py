from __future__ import annotations

import numpy as np

from virtual_tpu.golden import GoldenExecutor, HaltReason
from virtual_tpu.isa import AddressSpace
from virtual_tpu.memory import MemorySystem
from virtual_tpu.programs import Matmul16Layout, matmul_16_program


def main() -> None:
    rng = np.random.default_rng(1234)
    layout = Matmul16Layout()
    memory = MemorySystem()
    a = rng.integers(-8, 8, size=(16, 16), dtype=np.int8)
    b = rng.integers(-8, 8, size=(16, 16), dtype=np.int8)

    memory.write_i8_matrix(AddressSpace.HBM, layout.hbm_a, a)
    memory.write_i8_matrix(AddressSpace.HBM, layout.hbm_b, b)

    result = GoldenExecutor(matmul_16_program(layout), memory).run()
    if result.reason is not HaltReason.HALT:
        raise SystemExit(f"program failed: {result}")

    c = memory.read_i32_matrix(AddressSpace.HBM, layout.hbm_c, 16, 16)
    expected = a.astype(np.int32) @ b.astype(np.int32)
    np.testing.assert_array_equal(c, expected)
    print("16x16 int8 matmul passed")


if __name__ == "__main__":
    main()
