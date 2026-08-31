#!/usr/bin/env python3
"""Smoke-test MiniCPM-o 4.5 (MLX) audio dictation + cleanup, with timing.

Usage:
  .venv/bin/python scripts/smoke_test.py test_audio/zh_dictation_18s.wav
"""
import sys
import time
from pathlib import Path

import mlx.core as mx
from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template

MODEL = "models/MiniCPM-o-4_5-4bit"

SYSTEM = (
    "你是语音听写助手。把用户的口述音频转写为整洁、可直接使用的文字。"
    "规则：去掉口头禅和填充词（嗯、呃、那个、就是、然后那个）；"
    "去掉重复和中途自我纠正，只保留最终意思；补全标点；"
    "保持原语言（中文保持中文）；不要新增信息、不要总结、不要解释。"
    "只输出清洗后的文字本身。"
)
PROMPT = "请把这段语音听写成文字。"


def main():
    wav = sys.argv[1] if len(sys.argv) > 1 else "test_audio/zh_dictation_18s.wav"
    max_tokens = int(sys.argv[2]) if len(sys.argv) > 2 else 512

    print(f"== loading {MODEL} ==", flush=True)
    t0 = time.time()
    model, processor = load(MODEL, trust_remote_code=True)
    load_s = time.time() - t0
    print(f"loaded in {load_s:.1f}s", flush=True)

    config = model.config
    formatted = apply_chat_template(
        processor, config, PROMPT, num_audios=1, system=SYSTEM
    )

    print(f"== generating from {wav} ==", flush=True)
    t1 = time.time()
    result = generate(
        model,
        processor,
        formatted,
        audio=[wav],
        max_tokens=max_tokens,
        temperature=0.2,
        verbose=False,
    )
    gen_s = time.time() - t1

    text = result.text if hasattr(result, "text") else str(result)
    print("\n========== OUTPUT ==========")
    print(text)
    print("============================\n")

    # timing / usage
    pt = getattr(result, "prompt_tokens", None)
    gt = getattr(result, "generation_tokens", None)
    pps = getattr(result, "prompt_tps", None)
    gps = getattr(result, "generation_tps", None)
    peak = getattr(result, "peak_memory", None)
    print(f"load:        {load_s:.1f}s (one-time, warm server avoids this)")
    print(f"generate:    {gen_s:.1f}s")
    if pt is not None:
        print(f"prompt tok:  {pt}  @ {pps:.1f} tok/s" if pps else f"prompt tok: {pt}")
    if gt is not None:
        print(f"gen tok:     {gt}  @ {gps:.1f} tok/s" if gps else f"gen tok: {gt}")
    if peak is not None:
        print(f"peak mem:    {peak:.2f} GB")


if __name__ == "__main__":
    main()
