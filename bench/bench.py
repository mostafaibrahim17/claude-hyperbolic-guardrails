#!/usr/bin/env python3
"""GPU benchmark: bf16 matmul throughput and device memory bandwidth.
Timed with CUDA events, 5 repeats, median reported. Takes under a minute.
Usage: python3 bench.py <price_per_hour>"""
import json, statistics, sys, time
import torch

price = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0
assert torch.cuda.is_available(), "no CUDA device visible"
dev = torch.device("cuda"); name = torch.cuda.get_device_name(0)
t_start = time.time()

def timed(fn, iters):
    s, e = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
    torch.cuda.synchronize(); s.record()
    for _ in range(iters): fn()
    e.record(); torch.cuda.synchronize()
    return s.elapsed_time(e) / 1000.0  # seconds

n = 8192
a = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
b = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
for _ in range(20): a @ b                      # warm-up
tf = []
for _ in range(5):
    dt = timed(lambda: a @ b, 200)             # ~1.1 TFLOP per matmul, ~0.5 s per repeat
    tf.append(2 * n**3 * 200 / dt / 1e12)

x = torch.empty(1024**3, device=dev, dtype=torch.float32)   # 4 GB
y = torch.empty_like(x)
for _ in range(5): y.copy_(x)
bw = []
for _ in range(5):
    dt = timed(lambda: y.copy_(x), 20)
    bw.append(20 * 2 * x.numel() * 4 / dt / 1e9)             # read + write, GB/s

elapsed = time.time() - t_start
print(json.dumps({
    "gpu": name, "torch": torch.__version__, "cuda": torch.version.cuda,
    "bf16_matmul_tflops_median": round(statistics.median(tf), 1),
    "bf16_matmul_tflops_min_max": [round(min(tf), 1), round(max(tf), 1)],
    "memory_bandwidth_gbps_median": round(statistics.median(bw)),
    "memory_bandwidth_gbps_min_max": [round(min(bw)), round(max(bw))],
    "benchmark_seconds": round(elapsed, 1),
    "benchmark_cost_usd": round(elapsed / 3600 * price, 4),
}))
