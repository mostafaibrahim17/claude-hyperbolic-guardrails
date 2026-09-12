# bench

`bench.py` measures bf16 matmul throughput (8192x8192, 30 timed iterations) and
device memory bandwidth (4 GB copy), then prints one JSON line including the
cost of the run at the hourly price you pass as the first argument.

On the instance:

```bash
python3 -c "import torch" 2>/dev/null || python3 -m pip install -q torch --index-url https://download.pytorch.org/whl/cu121
curl -sO https://raw.githubusercontent.com/mostafaibrahim17/claude-hyperbolic-guardrails/main/bench/bench.py
python3 bench.py 2.75
```
