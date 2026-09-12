#!/usr/bin/env python3
"""Short GPU benchmark: bf16 matmul throughput and memory bandwidth.
Runs in about a minute. Prints a JSON line with the numbers and the cost
of the run at the hourly price you pass in."""
import json, sys, time
import torch

price_per_hour = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0
assert torch.cuda.is_available(), "no CUDA device visible"
dev = torch.device("cuda")
name = torch.cuda.get_device_name(0)
t_start = time.time()

# Matmul throughput, bf16, 8192 x 8192
n = 8192
a = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
b = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
for _ in range(5):
    (a @ b)
torch.cuda.synchronize()
iters = 30
t0 = time.time()
for _ in range(iters):
    c = a @ b
torch.cuda.synchronize()
dt = time.time() - t0
tflops = 2 * n**3 * iters / dt / 1e12

# Memory bandwidth: copy a 4 GB tensor
x = torch.empty(1024**3, device=dev, dtype=torch.float32)  # 4 GB
torch.cuda.synchronize()
t0 = time.time()
for _ in range(10):
    y = x.clone()
torch.cuda.synchronize()
gbps = 10 * 2 * x.numel() * 4 / (time.time() - t0) / 1e9  # read + write

elapsed = time.time() - t_start
print(json.dumps({
    "gpu": name,
    "torch": torch.__version__,
    "cuda": torch.version.cuda,
    "bf16_matmul_tflops": round(tflops, 1),
    "memory_bandwidth_gbps": round(gbps, 0),
    "benchmark_seconds": round(elapsed, 1),
    "benchmark_cost_usd": round(elapsed / 3600 * price_per_hour, 4),
}))
