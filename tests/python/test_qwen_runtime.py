import numpy as np

from virtual_tpu.qwen.runtime import (
    Caches,
    Model,
    forward_token,
    generate,
    per_token_cost,
    qwen35_0p8b,
    tiny,
)


def test_tiny_model_forward_shapes_and_finiteness():
    cfg = tiny()
    model = Model.random(cfg, seed=1)
    cache = Caches()
    logits = forward_token(model, token=3, cache=cache)
    assert logits.shape == (cfg.vocab,)
    assert np.all(np.isfinite(logits))


def test_generation_is_deterministic_and_uses_caches():
    cfg = tiny()
    model = Model.random(cfg, seed=2)
    prompt = [1, 5, 2]
    a = generate(model, prompt, n_new=6)
    b = generate(model, prompt, n_new=6)
    assert a == b                      # greedy + caches -> deterministic
    assert len(a) == len(prompt) + 6
    assert all(0 <= t < cfg.vocab for t in a)


def test_deltanet_state_evolves_across_steps():
    cfg = tiny()
    model = Model.random(cfg, seed=3)
    cache = Caches()
    forward_token(model, 4, cache); cache.pos += 1
    # a DeltaNet layer (layer 0) should have non-zero recurrent state after a step
    s0 = cache.state[0][0].copy()
    forward_token(model, 7, cache); cache.pos += 1
    s1 = cache.state[0][0]
    assert np.any(s0 != 0) and np.any(s1 != s0)
    # attention layer (layer 3) accumulates KV cache entries
    assert len(cache.kv[3]["k"]) == 2


def test_cost_model_sane():
    c = per_token_cost(tiny())
    assert c["total_instr"] > 0 and c["macs"] > 0
    big = per_token_cost(qwen35_0p8b())
    # 0.8B params -> ~1.6 GMAC/token order of magnitude
    assert 5e8 < big["macs"] < 5e9
    assert big["matmul_instr"] > big["vector_instr"]  # matmul-dominated
