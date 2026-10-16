#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TC3 모델 크기(파라미터 수) 산출 스크립트
- safetensors 가중치 파일의 모든 텐서 shape를 합산해 파라미터 수를 구한다 (dtype 무관).
- model.safetensors.index.json 의 metadata.total_size(바이트)와 교차 확인한다 (bf16/fp16 = 2 B/param).
- 의존성: safetensors, numpy  (pip install safetensors numpy)

사용 예:
  python3 tc3_count_params.py /models/Llama-3.1-8B-Instruct
기대 출력(Llama-3.1-8B-Instruct): total parameters = 8,030,261,248 (8.03 B)
"""
import glob
import json
import math
import os
import sys

try:
    from safetensors import safe_open
except ImportError:
    sys.exit("safetensors 모듈이 필요합니다: pip install safetensors")


def main():
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <model_dir>")
    d = sys.argv[1]
    files = sorted(glob.glob(os.path.join(d, "*.safetensors")))
    if not files:
        sys.exit(f"no *.safetensors in {d}")

    total, n_tensors = 0, 0
    for f in files:
        with safe_open(f, framework="np") as s:  # numpy만 필요 (torch 불필요)
            for k in s.keys():
                total += math.prod(s.get_slice(k).get_shape())
                n_tensors += 1
        print(f"  {os.path.basename(f)}  ({os.path.getsize(f) / 2**30:.2f} GiB)")

    print(f"\nmodel dir        = {d}")
    print(f"safetensors files= {len(files)}, tensors = {n_tensors}")
    print(f"total parameters = {total:,}  ({total / 1e9:.2f} B)")

    cfg = os.path.join(d, "config.json")
    if os.path.exists(cfg):
        c = json.load(open(cfg, encoding="utf-8"))
        keys = ["architectures", "hidden_size", "num_hidden_layers", "num_attention_heads",
                "num_key_value_heads", "intermediate_size", "vocab_size", "torch_dtype"]
        print("config.json      = " + ", ".join(f"{k}={c.get(k)}" for k in keys if k in c))

    idx = os.path.join(d, "model.safetensors.index.json")
    if os.path.exists(idx):
        ts = json.load(open(idx, encoding="utf-8")).get("metadata", {}).get("total_size")
        if ts:
            print(f"index total_size = {ts:,} bytes  -> /2 = {ts // 2:,} params (bf16 기준 교차확인)")


if __name__ == "__main__":
    main()
