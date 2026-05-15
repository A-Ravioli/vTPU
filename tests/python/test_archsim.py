from virtual_tpu.archsim.network import Mesh3D, Torus3D, all_gather_cycles, ring_all_reduce_cycles


def test_mesh_and_torus_paths() -> None:
    mesh = Mesh3D((2, 2, 2), bandwidth_bytes_per_cycle=16, latency_cycles=2)
    torus = Torus3D((4, 4, 4), bandwidth_bytes_per_cycle=16, latency_cycles=2)
    assert mesh.size == 8
    assert mesh.dimension_order_path((0, 0, 0), (1, 1, 1))[-1] == (1, 1, 1)
    assert len(torus.neighbors((0, 0, 0))) == 6


def test_collective_cycle_estimates_are_positive() -> None:
    mesh = Mesh3D((2, 2, 2), bandwidth_bytes_per_cycle=32, latency_cycles=1)
    result = ring_all_reduce_cycles(mesh, tensor_bytes=8192)
    assert result.total_cycles > 0
    assert result.bottleneck_bytes > 0
    gather = all_gather_cycles(Mesh3D((2, 2, 2)), shard_bytes=1024)
    assert gather.bytes_per_chip == 1024 * 7
