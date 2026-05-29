import json

from virtual_tpu.layout import anneal, score_floorplan, tiny_floorplan
from virtual_tpu.layout.search import emit_openroad_fragment, random_search


def test_tiny_floorplan_is_legal_and_scored() -> None:
    floorplan = tiny_floorplan()
    score = score_floorplan(floorplan)
    assert floorplan.overlaps() == []
    assert floorplan.out_of_bounds() == []
    assert score.total > 0
    assert score.illegal_penalty == 0


def test_random_search_returns_serializable_candidate() -> None:
    result = random_search(seed=7, iterations=25)
    payload = result.to_dict()
    assert result.score.illegal_penalty == 0
    assert payload["floorplan"]["design"]["name"] == "vtpu_pd_tiny"
    assert json.dumps(payload)


def test_anneal_writes_jsonl_log(tmp_path) -> None:
    log_path = tmp_path / "search.jsonl"
    state = anneal(seed=3, iterations=10, log_path=log_path)
    lines = log_path.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 11
    assert state.best.score.total <= max(json.loads(line)["score"]["total"] for line in lines)


def test_openroad_fragment_contains_physical_knobs() -> None:
    fragment = emit_openroad_fragment(tiny_floorplan())
    assert "export DIE_AREA = 0 0 2200 2200" in fragment
    assert "export CORE_AREA = 100 100 2100 2100" in fragment
    assert "# tc0_vmem sram" in fragment
