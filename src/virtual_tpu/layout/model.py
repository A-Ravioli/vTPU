from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Iterable


@dataclass(frozen=True)
class Rect:
    x: int
    y: int
    w: int
    h: int

    @property
    def right(self) -> int:
        return self.x + self.w

    @property
    def top(self) -> int:
        return self.y + self.h

    @property
    def area(self) -> int:
        return self.w * self.h

    @property
    def center(self) -> tuple[float, float]:
        return (self.x + (self.w / 2.0), self.y + (self.h / 2.0))

    def overlaps(self, other: Rect) -> bool:
        return self.x < other.right and self.right > other.x and self.y < other.top and self.top > other.y

    def inside(self, boundary: Rect) -> bool:
        return self.x >= boundary.x and self.y >= boundary.y and self.right <= boundary.right and self.top <= boundary.top

    def moved(self, dx: int, dy: int) -> Rect:
        return replace(self, x=self.x + dx, y=self.y + dy)

    def clamped(self, boundary: Rect, grid: int) -> Rect:
        max_x = max(boundary.x, boundary.right - self.w)
        max_y = max(boundary.y, boundary.top - self.h)
        return replace(
            self,
            x=_snap(min(max(self.x, boundary.x), max_x), grid),
            y=_snap(min(max(self.y, boundary.y), max_y), grid),
        )


@dataclass(frozen=True)
class Block:
    name: str
    kind: str
    rect: Rect
    fixed: bool = False


@dataclass(frozen=True)
class Net:
    name: str
    pins: tuple[str, ...]
    weight: float = 1.0


@dataclass(frozen=True)
class DesignPoint:
    name: str = "vtpu_pd_tiny"
    num_tensor_cores: int = 2
    mxus_per_tc: int = 4
    array_m: int = 2
    array_n: int = 2
    array_k: int = 2
    vmem_bytes: int = 256
    cmem_bytes: int = 256
    hbm_bytes: int = 256
    instr_depth: int = 16
    clock_period_ns: float = 20.0


@dataclass(frozen=True)
class Floorplan:
    design: DesignPoint
    die: Rect
    core: Rect
    blocks: tuple[Block, ...]
    nets: tuple[Net, ...]
    grid: int = 10

    def block(self, name: str) -> Block:
        for block in self.blocks:
            if block.name == name:
                return block
        raise KeyError(name)

    def replace_block(self, updated: Block) -> Floorplan:
        return replace(self, blocks=tuple(updated if block.name == updated.name else block for block in self.blocks))

    def movable_blocks(self) -> tuple[Block, ...]:
        return tuple(block for block in self.blocks if not block.fixed)

    def overlaps(self) -> list[tuple[str, str]]:
        collisions: list[tuple[str, str]] = []
        for index, left in enumerate(self.blocks):
            for right in self.blocks[index + 1 :]:
                if left.rect.overlaps(right.rect):
                    collisions.append((left.name, right.name))
        return collisions

    def out_of_bounds(self) -> list[str]:
        return [block.name for block in self.blocks if not block.rect.inside(self.core)]

    def to_dict(self) -> dict[str, object]:
        return {
            "design": self.design.__dict__,
            "die": self.die.__dict__,
            "core": self.core.__dict__,
            "grid": self.grid,
            "blocks": [
                {"name": block.name, "kind": block.kind, "fixed": block.fixed, "rect": block.rect.__dict__}
                for block in self.blocks
            ],
            "nets": [{"name": net.name, "pins": list(net.pins), "weight": net.weight} for net in self.nets],
        }


def tiny_floorplan(design: DesignPoint | None = None) -> Floorplan:
    design = design or DesignPoint()
    die = Rect(0, 0, 2200, 2200)
    core = Rect(100, 100, 2000, 2000)
    blocks = (
        Block("control", "logic", Rect(930, 1680, 340, 260)),
        Block("dma", "logic", Rect(930, 1260, 340, 260)),
        Block("cmem", "sram", Rect(880, 850, 440, 300)),
        Block("instr_mem", "sram", Rect(150, 1680, 360, 260)),
        Block("hbm_if", "io", Rect(1680, 850, 360, 420), fixed=True),
        Block("tc0_compute", "compute", Rect(360, 410, 360, 360)),
        Block("tc0_vmem", "sram", Rect(270, 850, 520, 300)),
        Block("tc1_compute", "compute", Rect(1440, 410, 360, 360)),
        Block("tc1_vmem", "sram", Rect(1360, 1360, 520, 300)),
    )
    nets = (
        Net("host_control", ("control", "instr_mem", "dma"), 1.0),
        Net("dma_hbm", ("dma", "hbm_if"), 2.0),
        Net("dma_cmem", ("dma", "cmem"), 1.5),
        Net("cmem_tc0", ("cmem", "tc0_vmem"), 2.0),
        Net("cmem_tc1", ("cmem", "tc1_vmem"), 2.0),
        Net("tc0_local", ("tc0_vmem", "tc0_compute"), 4.0),
        Net("tc1_local", ("tc1_vmem", "tc1_compute"), 4.0),
        Net("control_tc", ("control", "tc0_compute", "tc1_compute"), 1.0),
    )
    return Floorplan(design=design, die=die, core=core, blocks=blocks, nets=nets)


def half_perimeter_wirelength(blocks: Iterable[Block]) -> float:
    centers = [block.rect.center for block in blocks]
    if len(centers) <= 1:
        return 0.0
    xs = [center[0] for center in centers]
    ys = [center[1] for center in centers]
    return (max(xs) - min(xs)) + (max(ys) - min(ys))


def _snap(value: int, grid: int) -> int:
    if grid <= 1:
        return value
    return round(value / grid) * grid
