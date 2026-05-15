from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Link:
    source: tuple[int, int, int]
    dest: tuple[int, int, int]
    bandwidth_bytes_per_cycle: float
    latency_cycles: int
    busy_until: float = 0.0
    bytes_transferred: int = 0

    def transfer(self, earliest_cycle: float, num_bytes: int) -> float:
        start = max(earliest_cycle, self.busy_until)
        duration = self.latency_cycles + (num_bytes / self.bandwidth_bytes_per_cycle)
        self.busy_until = start + duration
        self.bytes_transferred += num_bytes
        return self.busy_until
