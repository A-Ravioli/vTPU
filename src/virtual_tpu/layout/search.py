# simulated annealing / random search over movable floorplan blocks
from __future__ import annotations

import argparse
import json
import math
import random
from dataclasses import dataclass
from pathlib import Path

from virtual_tpu.golden import PerformanceCounters
from virtual_tpu.layout.cost import CostWeights, LayoutScore, score_floorplan
from virtual_tpu.layout.model import Block, Floorplan, Rect, full_floorplan, tiny_floorplan


@dataclass(frozen=True)
class SearchResult:
    """one scored floorplan candidate at a given iteration."""

    floorplan: Floorplan
    score: LayoutScore
    iteration: int

    def to_dict(self) -> dict[str, object]:
        return {
            "iteration": self.iteration,
            "score": self.score.to_dict(),
            "floorplan": self.floorplan.to_dict(),
        }


@dataclass
class SearchState:
    """running anneal state: current walk position and best-so-far."""

    current: SearchResult
    best: SearchResult
    accepted: int = 0


def random_search(
    *,
    seed: int = 1,
    iterations: int = 200,
    step: int = 120,
    base: Floorplan | None = None,
    counters: PerformanceCounters | None = None,
    weights: CostWeights | None = None,
) -> SearchResult:
    """greedy random walk: always move, keep the best score seen."""

    rng = random.Random(seed)
    floorplan = repair_floorplan(base or tiny_floorplan())
    best = SearchResult(floorplan, score_floorplan(floorplan, counters=counters, weights=weights), 0)
    for iteration in range(1, iterations + 1):
        candidate = mutate_floorplan(floorplan, rng=rng, step=step)
        score = score_floorplan(candidate, counters=counters, weights=weights)
        if score.total < best.score.total:
            best = SearchResult(candidate, score, iteration)
        floorplan = candidate
    return best


def anneal(
    *,
    seed: int = 1,
    iterations: int = 500,
    initial_temperature: float = 5000.0,
    cooling: float = 0.985,
    step: int = 120,
    base: Floorplan | None = None,
    counters: PerformanceCounters | None = None,
    weights: CostWeights | None = None,
    log_path: Path | None = None,
) -> SearchState:
    """simulated annealing over block positions; optionally log every candidate to jsonl."""

    rng = random.Random(seed)
    floorplan = repair_floorplan(base or tiny_floorplan())
    initial = SearchResult(floorplan, score_floorplan(floorplan, counters=counters, weights=weights), 0)
    state = SearchState(current=initial, best=initial)
    temperature = initial_temperature

    log_file = log_path.open("w", encoding="utf-8") if log_path is not None else None
    try:
        if log_file is not None:
            log_file.write(json.dumps(state.current.to_dict(), sort_keys=True) + "\n")
        for iteration in range(1, iterations + 1):
            candidate_floorplan = mutate_floorplan(state.current.floorplan, rng=rng, step=step)
            candidate = SearchResult(
                candidate_floorplan,
                score_floorplan(candidate_floorplan, counters=counters, weights=weights),
                iteration,
            )
            delta = candidate.score.total - state.current.score.total
            accept = delta <= 0 or rng.random() < math.exp(-delta / max(temperature, 1e-9))
            if accept:
                state.current = candidate
                state.accepted += 1
            if candidate.score.total < state.best.score.total:
                state.best = candidate
            if log_file is not None:
                log_file.write(json.dumps(candidate.to_dict(), sort_keys=True) + "\n")
            temperature *= cooling
    finally:
        if log_file is not None:
            log_file.close()
    return state


def mutate_floorplan(floorplan: Floorplan, *, rng: random.Random, step: int = 120) -> Floorplan:
    """pick a random movable block and nudge it by up to ±step on the placement grid."""

    movable = floorplan.movable_blocks()
    if not movable:
        return floorplan
    block = rng.choice(movable)
    dx = rng.randrange(-step, step + 1, floorplan.grid)
    dy = rng.randrange(-step, step + 1, floorplan.grid)
    moved = Block(block.name, block.kind, block.rect.moved(dx, dy).clamped(floorplan.core, floorplan.grid), block.fixed)
    return repair_floorplan(floorplan.replace_block(moved))


def repair_floorplan(floorplan: Floorplan, *, max_passes: int = 16) -> Floorplan:
    """clamp blocks to core and iteratively separate overlaps."""

    repaired = floorplan
    for block in repaired.blocks:
        clamped = Block(block.name, block.kind, block.rect.clamped(repaired.core, repaired.grid), block.fixed)
        repaired = repaired.replace_block(clamped)
    for _ in range(max_passes):
        collisions = repaired.overlaps()
        if not collisions:
            return repaired
        left_name, right_name = collisions[0]
        left = repaired.block(left_name)
        right = repaired.block(right_name)
        target = right if not right.fixed else left
        if target.fixed:
            return repaired
        dx, dy = _separation_delta(left.rect, right.rect, repaired.grid)
        moved = Block(target.name, target.kind, target.rect.moved(dx, dy).clamped(repaired.core, repaired.grid), target.fixed)
        repaired = repaired.replace_block(moved)
    return repaired


def emit_openroad_fragment(floorplan: Floorplan) -> str:
    """makefile fragment with die/core areas and macro placement hints for openroad."""

    lines = [
        "# Generated by virtual_tpu.layout.search",
        f"export DIE_AREA = {floorplan.die.x} {floorplan.die.y} {floorplan.die.right} {floorplan.die.top}",
        f"export CORE_AREA = {floorplan.core.x} {floorplan.core.y} {floorplan.core.right} {floorplan.core.top}",
        "# Candidate macro hints. Replace shell names with real SRAM macro instance names when available.",
    ]
    for block in floorplan.blocks:
        lines.append(f"# {block.name} {block.kind} {block.rect.x} {block.rect.y} {block.rect.w} {block.rect.h}")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Search tiny vTPU structured floorplans.")
    parser.add_argument("--iters", type=int, default=500)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--out-dir", type=Path, default=Path("results/layout_search"))
    parser.add_argument("--step", type=int, default=120)
    parser.add_argument("--target", choices=("tiny", "full"), default="tiny")
    args = parser.parse_args(argv)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    log_path = args.out_dir / f"run_seed{args.seed}.jsonl"
    base = full_floorplan() if args.target == "full" else tiny_floorplan()
    state = anneal(seed=args.seed, iterations=args.iters, step=args.step, base=base, log_path=log_path)
    best_path = args.out_dir / f"best_seed{args.seed}.json"
    fragment_path = args.out_dir / f"best_seed{args.seed}.mk"
    best_path.write_text(json.dumps(state.best.to_dict(), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    fragment_path.write_text(emit_openroad_fragment(state.best.floorplan), encoding="utf-8")
    print(f"best_score={state.best.score.total:.3f} iteration={state.best.iteration} accepted={state.accepted}")
    print(f"wrote {best_path}")
    print(f"wrote {fragment_path}")
    return 0


def _separation_delta(left: Rect, right: Rect, grid: int) -> tuple[int, int]:
    """minimum grid-aligned push to separate two overlapping rects."""

    move_right = left.right - right.x
    move_left = left.x - right.right
    move_up = left.top - right.y
    move_down = left.y - right.top
    options = ((abs(move_right), move_right, 0), (abs(move_left), move_left, 0), (abs(move_up), 0, move_up), (abs(move_down), 0, move_down))
    _, dx, dy = min(options, key=lambda item: item[0])
    if dx:
        dx += grid if dx > 0 else -grid
    if dy:
        dy += grid if dy > 0 else -grid
    return dx, dy
