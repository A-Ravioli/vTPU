# floorplan cost function: wirelength, congestion, memory distance, timing proxy
from __future__ import annotations

from dataclasses import dataclass

from virtual_tpu.golden import PerformanceCounters
from virtual_tpu.layout.model import Floorplan, half_perimeter_wirelength


@dataclass(frozen=True)
class CostWeights:
    """scalar weights for each term in the layout objective."""

    wirelength: float = 1.0
    congestion: float = 650.0
    memory_distance: float = 4.0
    area: float = 0.0001
    timing: float = 120.0
    illegal: float = 1_000_000.0  # huge penalty for overlaps / out-of-bounds
    counters: float = 0.05  # tie-in to golden-model perf counters when provided


@dataclass(frozen=True)
class LayoutScore:
    """breakdown of the weighted floorplan objective."""

    total: float
    wirelength: float
    congestion: float
    memory_distance: float
    area: int
    timing_proxy: float
    illegal_penalty: float
    counter_cost: float

    def to_dict(self) -> dict[str, float | int]:
        return self.__dict__.copy()


def score_floorplan(
    floorplan: Floorplan,
    *,
    counters: PerformanceCounters | None = None,
    weights: CostWeights | None = None,
) -> LayoutScore:
    """compute a single scalar cost (lower is better) for a candidate floorplan."""

    weights = weights or CostWeights()
    wirelength = _weighted_wirelength(floorplan)
    congestion = _congestion_proxy(floorplan)
    memory_distance = _memory_distance(floorplan)
    area = sum(block.rect.area for block in floorplan.blocks)
    timing_proxy = _timing_proxy(floorplan)
    illegal_penalty = weights.illegal * (len(floorplan.overlaps()) + len(floorplan.out_of_bounds()))
    counter_cost = _counter_cost(counters)
    total = (
        (weights.wirelength * wirelength)
        + (weights.congestion * congestion)
        + (weights.memory_distance * memory_distance)
        + (weights.area * area)
        + (weights.timing * timing_proxy)
        + illegal_penalty
        + (weights.counters * counter_cost)
    )
    return LayoutScore(
        total=total,
        wirelength=wirelength,
        congestion=congestion,
        memory_distance=memory_distance,
        area=area,
        timing_proxy=timing_proxy,
        illegal_penalty=illegal_penalty,
        counter_cost=counter_cost,
    )


def _weighted_wirelength(floorplan: Floorplan) -> float:
    by_name = {block.name: block for block in floorplan.blocks}
    total = 0.0
    for net in floorplan.nets:
        blocks = [by_name[name] for name in net.pins if name in by_name]
        total += net.weight * half_perimeter_wirelength(blocks)
    return total


def _congestion_proxy(floorplan: Floorplan) -> float:
    """quadratic penalty once core utilization exceeds ~35%."""

    core_area = floorplan.core.area
    if core_area == 0:
        return 1.0
    utilization = sum(block.rect.area for block in floorplan.blocks) / core_area
    overflow = max(0.0, utilization - 0.35)
    return overflow * overflow


def _memory_distance(floorplan: Floorplan) -> float:
    """manhattan distance for critical memory/compute and hbm/dma pairs."""

    pairs = (
        ("tc0_vmem", "tc0_compute"),
        ("tc1_vmem", "tc1_compute"),
        ("cmem", "tc0_vmem"),
        ("cmem", "tc1_vmem"),
        ("hbm_if", "dma"),
    )
    total = 0.0
    for left_name, right_name in pairs:
        left = floorplan.block(left_name).rect.center
        right = floorplan.block(right_name).rect.center
        total += abs(left[0] - right[0]) + abs(left[1] - right[1])
    return total


def _timing_proxy(floorplan: Floorplan) -> float:
    """normalize memory distance by clock period (rough critical-path proxy)."""

    period = max(floorplan.design.clock_period_ns, 1.0)
    return _memory_distance(floorplan) / (period * 1000.0)


def _counter_cost(counters: PerformanceCounters | None) -> float:
    if counters is None:
        return 0.0
    return (
        counters.mxu_active_cycles
        + counters.vector_active_cycles
        + counters.reduce_active_cycles
        + counters.hbm_stall_cycles
        + (8 * counters.vmem_bank_conflicts)  # bank conflicts weighted higher
    )
