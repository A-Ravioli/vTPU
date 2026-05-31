# single directed link with bandwidth/latency transfer model
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Link:
    """point-to-point channel between two 3d mesh/torus nodes."""

    source: tuple[int, int, int]
    dest: tuple[int, int, int]
    bandwidth_bytes_per_cycle: float
    latency_cycles: int
    busy_until: float = 0.0  # cycle when link becomes free
    bytes_transferred: int = 0  # cumulative traffic (for bottleneck analysis)

    def transfer(self, earliest_cycle: float, num_bytes: int) -> float:
        """schedule num_bytes on this link; return cycle when transfer completes."""

        start = max(earliest_cycle, self.busy_until)
        duration = self.latency_cycles + (num_bytes / self.bandwidth_bytes_per_cycle)
        self.busy_until = start + duration
        self.bytes_transferred += num_bytes
        return self.busy_until
