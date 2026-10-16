#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""로컬 흐름 검증용 합성 safetensors 모델 fixture 생성 (실제 가중치 없이 model-size 단계를 돌려보기 위함).
config.json 은 Llama-3.1-8B-Instruct 와 같은 구조값을 담되, 텐서는 아주 작게 만든다 (SIMULATED 표기 대상)."""
import json
import os
import sys

import numpy as np
from safetensors.numpy import save_file

d = sys.argv[1]
os.makedirs(d, exist_ok=True)
save_file({"model.embed_tokens.weight": np.zeros((2048, 64), dtype=np.float16)}, os.path.join(d, "model-00001-of-00002.safetensors"))
save_file({"model.layers.0.self_attn.q_proj.weight": np.zeros((256, 256), dtype=np.float16),
           "lm_head.bias": np.zeros((10,), dtype=np.float16)}, os.path.join(d, "model-00002-of-00002.safetensors"))
total = 2048 * 64 + 256 * 256 + 10
json.dump({"metadata": {"total_size": total * 2, "note": "FIXTURE — synthetic, not a real model"}, "weight_map": {}},
          open(os.path.join(d, "model.safetensors.index.json"), "w"), indent=1)
json.dump({"architectures": ["LlamaForCausalLM"], "hidden_size": 4096, "num_hidden_layers": 32, "num_attention_heads": 32,
           "num_key_value_heads": 8, "intermediate_size": 14336, "vocab_size": 128256, "torch_dtype": "bfloat16",
           "_fixture": True}, open(os.path.join(d, "config.json"), "w"), indent=1)
print(f"fixture model written to {d} (total params {total:,})")
