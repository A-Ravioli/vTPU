from virtual_tpu.tiling import matmul_tiles, tiles


def test_tiles_cover_non_multiple_length() -> None:
    assert list(tiles(35, 16))[-1].size == 3


def test_matmul_tiles_order_is_serial_m_n_k() -> None:
    generated = list(matmul_tiles(32, 16, 32, 16, 16, 16))
    assert len(generated) == 4
    assert generated[0].m.start == 0
    assert generated[0].n.start == 0
    assert generated[0].k.start == 0
    assert generated[1].k.start == 16
