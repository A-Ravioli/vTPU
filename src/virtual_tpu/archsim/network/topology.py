from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

from virtual_tpu.archsim.network.link import Link


Coord = tuple[int, int, int]


@dataclass
class Topology3D:
    dims: Coord
    bandwidth_bytes_per_cycle: float = 32.0
    latency_cycles: int = 10
    wrap: bool = False

    def __post_init__(self) -> None:
        if any(d <= 0 for d in self.dims):
            raise ValueError("all topology dimensions must be positive")
        self.links: dict[tuple[Coord, Coord], Link] = {}
        for coord in self.nodes():
            for neighbor in self.neighbors(coord):
                self.links[(coord, neighbor)] = Link(coord, neighbor, self.bandwidth_bytes_per_cycle, self.latency_cycles)

    @property
    def size(self) -> int:
        x, y, z = self.dims
        return x * y * z

    def nodes(self) -> Iterable[Coord]:
        for x in range(self.dims[0]):
            for y in range(self.dims[1]):
                for z in range(self.dims[2]):
                    yield (x, y, z)

    def neighbors(self, coord: Coord) -> list[Coord]:
        result: list[Coord] = []
        for axis in range(3):
            for delta in (-1, 1):
                nxt = list(coord)
                nxt[axis] += delta
                if self.wrap:
                    nxt[axis] %= self.dims[axis]
                    candidate = tuple(nxt)
                    if candidate != coord and candidate not in result:
                        result.append(candidate)
                elif 0 <= nxt[axis] < self.dims[axis]:
                    result.append(tuple(nxt))
        return result

    def dimension_order_path(self, source: Coord, dest: Coord) -> list[Coord]:
        if source == dest:
            return [source]
        current = list(source)
        path = [source]
        for axis in range(3):
            while current[axis] != dest[axis]:
                if self.wrap:
                    dim = self.dims[axis]
                    forward = (dest[axis] - current[axis]) % dim
                    backward = (current[axis] - dest[axis]) % dim
                    current[axis] = (current[axis] + (1 if forward <= backward else -1)) % dim
                else:
                    current[axis] += 1 if dest[axis] > current[axis] else -1
                path.append(tuple(current))
        return path

    def send(self, source: Coord, dest: Coord, num_bytes: int, earliest_cycle: float = 0.0) -> float:
        path = self.dimension_order_path(source, dest)
        cycle = earliest_cycle
        for hop_source, hop_dest in zip(path, path[1:]):
            cycle = self.links[(hop_source, hop_dest)].transfer(cycle, num_bytes)
        return cycle

    def link_utilization(self) -> dict[tuple[Coord, Coord], int]:
        return {key: link.bytes_transferred for key, link in self.links.items()}


class Mesh3D(Topology3D):
    def __init__(self, dims: Coord, bandwidth_bytes_per_cycle: float = 32.0, latency_cycles: int = 10):
        super().__init__(dims=dims, bandwidth_bytes_per_cycle=bandwidth_bytes_per_cycle, latency_cycles=latency_cycles, wrap=False)


class Torus3D(Topology3D):
    def __init__(self, dims: Coord, bandwidth_bytes_per_cycle: float = 32.0, latency_cycles: int = 10):
        super().__init__(dims=dims, bandwidth_bytes_per_cycle=bandwidth_bytes_per_cycle, latency_cycles=latency_cycles, wrap=True)
