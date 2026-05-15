import numpy as np

from virtual_tpu.golden import GoldenExecutor, HaltReason
from virtual_tpu.isa import AddressSpace
from virtual_tpu.lowering import pack_int8_tiles, unpack_int32_tiles
from virtual_tpu.memory import MemorySystem
from virtual_tpu.programs import TiledMatmulLayout, matmul_tiled_packed_program, mlp_single_tile_program


def test_64x64_packed_tiled_matmul_program() -> None:
    rng = np.random.default_rng(99)
    layout = TiledMatmulLayout()
    memory = MemorySystem()
    a = rng.integers(-8, 8, size=(64, 64), dtype=np.int8)
    b = rng.integers(-8, 8, size=(64, 64), dtype=np.int8)
    memory.write(AddressSpace.HBM, layout.hbm_a, pack_int8_tiles(a))
    memory.write(AddressSpace.HBM, layout.hbm_b, pack_int8_tiles(b))

    result = GoldenExecutor(matmul_tiled_packed_program(layout), memory).run(max_steps=10_000)
    assert result.reason is HaltReason.HALT
    payload = memory.read(AddressSpace.HBM, layout.hbm_c, 64 * 64 * 4)
    np.testing.assert_array_equal(unpack_int32_tiles(payload, 64, 64), a.astype(np.int32) @ b.astype(np.int32))


def test_single_tile_mlp_program() -> None:
    rng = np.random.default_rng(101)
    memory = MemorySystem()
    x = rng.integers(-8, 8, size=(16, 16), dtype=np.int8)
    w = rng.integers(-8, 8, size=(16, 16), dtype=np.int8)
    bias = rng.integers(-10, 10, size=(16, 16), dtype=np.int32)
    memory.write_i8_matrix(AddressSpace.HBM, 0x0000, x)
    memory.write_i8_matrix(AddressSpace.HBM, 0x0100, w)
    memory.write_i32_matrix(AddressSpace.HBM, 0x0200, bias)

    result = GoldenExecutor(mlp_single_tile_program(), memory).run()
    assert result.reason is HaltReason.HALT
    expected = np.maximum(x.astype(np.int32) @ w.astype(np.int32) + bias, 0)
    np.testing.assert_array_equal(memory.read_i32_matrix(AddressSpace.HBM, 0x0600, 16, 16), expected)
