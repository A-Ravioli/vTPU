"""Terminal chat for the local Qwen3.5-0.8B checkpoint."""
from __future__ import annotations

import argparse
import time
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from virtual_tpu.qwen.real_infer import DEFAULT_QWEN35_0P8B_DIR


def _load(model_dir: Path, dtype: str):
    torch_dtype = {
        "float32": torch.float32,
        "bfloat16": torch.bfloat16,
        "float16": torch.float16,
    }[dtype]
    t0 = time.time()
    tokenizer = AutoTokenizer.from_pretrained(model_dir, local_files_only=True)
    model = AutoModelForCausalLM.from_pretrained(
        model_dir,
        local_files_only=True,
        dtype=torch_dtype,
        device_map=None,
        trust_remote_code=True,
    )
    model.eval()
    return tokenizer, model, time.time() - t0


def _prompt_text(tokenizer, messages: list[dict[str, str]]) -> str:
    try:
        return tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    except Exception:
        return "\n".join(f"{m['role']}: {m['content']}" for m in messages) + "\nassistant:"


def generate_reply(
    tokenizer,
    model,
    messages: list[dict[str, str]],
    *,
    max_new_tokens: int,
    temperature: float,
) -> tuple[str, float, int, int]:
    text = _prompt_text(tokenizer, messages)
    inputs = tokenizer(text, return_tensors="pt")
    input_tokens = int(inputs.input_ids.shape[-1])
    sample = temperature > 0.0
    t0 = time.time()
    with torch.no_grad():
        output = model.generate(
            **inputs,
            max_new_tokens=max_new_tokens,
            do_sample=sample,
            temperature=temperature if sample else None,
            pad_token_id=tokenizer.eos_token_id,
            eos_token_id=tokenizer.eos_token_id,
        )
    wall = time.time() - t0
    generated = output[0][input_tokens:]
    reply = tokenizer.decode(generated, skip_special_tokens=True).strip()
    return reply, wall, input_tokens, int(generated.shape[-1])


def run_once(args: argparse.Namespace) -> None:
    tokenizer, model, load_wall = _load(Path(args.model_dir), args.dtype)
    messages = [{"role": "user", "content": args.prompt}]
    reply, wall, input_tokens, output_tokens = generate_reply(
        tokenizer,
        model,
        messages,
        max_new_tokens=args.max_new_tokens,
        temperature=args.temperature,
    )
    print(f"loaded in {load_wall:.3f}s")
    print(f"input tokens: {input_tokens}")
    print(f"output tokens: {output_tokens}")
    print(f"generation wall: {wall:.3f}s")
    print(f"tokens/sec: {output_tokens / wall:.3f}" if wall > 0 else "tokens/sec: n/a")
    print()
    print(reply)


def run_chat(args: argparse.Namespace) -> None:
    tokenizer, model, load_wall = _load(Path(args.model_dir), args.dtype)
    messages: list[dict[str, str]] = []
    print(f"Loaded Qwen3.5-0.8B in {load_wall:.3f}s. Type /quit to exit, /reset to clear context.")
    while True:
        try:
            prompt = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not prompt:
            continue
        if prompt in {"/quit", "/exit"}:
            return
        if prompt == "/reset":
            messages.clear()
            print("context cleared")
            continue
        messages.append({"role": "user", "content": prompt})
        reply, wall, _input_tokens, output_tokens = generate_reply(
            tokenizer,
            model,
            messages,
            max_new_tokens=args.max_new_tokens,
            temperature=args.temperature,
        )
        messages.append({"role": "assistant", "content": reply})
        print(f"qwen> {reply}")
        print(f"[{output_tokens} tokens in {wall:.3f}s, {output_tokens / wall:.3f} tok/s]")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", default=str(DEFAULT_QWEN35_0P8B_DIR))
    parser.add_argument("--dtype", choices=["float32", "bfloat16", "float16"], default="float32")
    parser.add_argument("--max-new-tokens", type=int, default=96)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--prompt")
    args = parser.parse_args()
    if args.prompt is None:
        run_chat(args)
    else:
        run_once(args)


if __name__ == "__main__":
    main()
