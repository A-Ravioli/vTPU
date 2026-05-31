# collective communication cycle models on 3d topologies
from __future__ import annotations

from dataclasses import dataclass

from virtual_tpu.archsim.network.topology import Coord, Topology3D


@dataclass(frozen=True)
class CollectiveResult:
    """estimated cycles and traffic for one collective operation."""

    total_cycles: float
    communication_cycles: float
    bytes_per_chip: int
    bottleneck_bytes: int  # max bytes on any single link


def ring_all_reduce_cycles(topology: Topology3D, tensor_bytes: int) -> CollectiveResult:
    """two-phase ring all-reduce: reduce-scatter then all-gather over a node ring."""

    nodes = list(topology.nodes())
    if len(nodes) <= 1:
        return CollectiveResult(0.0, 0.0, 0, 0)
    shard_bytes = max(1, tensor_bytes // len(nodes))
    cycle = 0.0
    ring = nodes + [nodes[0]]
    for _phase in range(2):  # reduce-scatter + all-gather
        for src, dst in zip(ring, ring[1:]):
            cycle = max(cycle, topology.send(src, dst, shard_bytes, cycle))
    bottleneck = max(topology.link_utilization().values(), default=0)
    return CollectiveResult(cycle, cycle, shard_bytes * 2 * (len(nodes) - 1), bottleneck)


def all_gather_cycles(topology: Topology3D, shard_bytes: int, root: Coord = (0, 0, 0)) -> CollectiveResult:
    """star gather: root sends its shard to every other node."""

    cycle = 0.0
    for node in topology.nodes():
        if node != root:
            cycle = max(cycle, topology.send(root, node, shard_bytes, 0.0))
    bottleneck = max(topology.link_utilization().values(), default=0)
    return CollectiveResult(cycle, cycle, shard_bytes * max(0, topology.size - 1), bottleneck)


def reduce_scatter_cycles(topology: Topology3D, tensor_bytes: int, root: Coord = (0, 0, 0)) -> CollectiveResult:
    """star reduce-scatter: each node sends its shard to root."""

    shard_bytes = max(1, tensor_bytes // topology.size)
    cycle = 0.0
    for node in topology.nodes():
        if node != root:
            cycle = max(cycle, topology.send(node, root, shard_bytes, 0.0))
    bottleneck = max(topology.link_utilization().values(), default=0)
    return CollectiveResult(cycle, cycle, shard_bytes * max(0, topology.size - 1), bottleneck)
