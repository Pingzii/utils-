#!/usr/bin/env bash
set -euo pipefail

# 固定输入长度、输出长度和并发数的性能测试：
# bash aisbench_synthetic_gen.sh \
#   /data/weights/Qwen3-32B Qwen 8000 4096 128 128 2048

MODEL_PATH="${1:-}"
MODEL_NAME="${2:-}"
HOST_PORT="${3:-}"
INPUT_LEN="${4:-}"
OUTPUT_LEN="${5:-}"
CONCURRENCY="${6:-}"
REQUEST_COUNT="${7:-}"
PYTHON="${PYTHON:-python3}"
BENCHMARK_DIR="${BENCHMARK_DIR:-$PWD/benchmark}"

for value in \
    "$HOST_PORT" "$INPUT_LEN" "$OUTPUT_LEN" "$CONCURRENCY" "$REQUEST_COUNT"; do
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "用法：bash $0 模型路径 模型名 端口 输入长度 输出长度 并发数 请求数" >&2
        exit 2
    fi
done

if [[ -z "$MODEL_PATH" || -z "$MODEL_NAME" ]]; then
    echo "用法：bash $0 模型路径 模型名 端口 输入长度 输出长度 并发数 请求数" >&2
    exit 2
fi

# 已经安装就跳过 clone 和编译安装。
if command -v ais_bench >/dev/null 2>&1 \
    && "$PYTHON" -c "import ais_bench" >/dev/null 2>&1; then
    echo "[AISBench] 已安装，跳过 clone 和 pip install"
else
    if [[ ! -d "$BENCHMARK_DIR/.git" ]]; then
        git clone https://gitee.com/aisbench/benchmark.git "$BENCHMARK_DIR"
    fi

    "$PYTHON" -m pip install -e "$BENCHMARK_DIR" --use-pep517
    "$PYTHON" -m pip install -r "$BENCHMARK_DIR/requirements/api.txt"
    "$PYTHON" -m pip install -r "$BENCHMARK_DIR/requirements/extra.txt"
fi

PACKAGE_DIR="$($PYTHON -c \
    'import pathlib, ais_bench; print(pathlib.Path(ais_bench.__file__).resolve().parent)')"
MODEL_CONFIG="$PACKAGE_DIR/benchmark/configs/models/vllm_api/vllm_api_stream_chat.py"
SYNTHETIC_CONFIG="$PACKAGE_DIR/datasets/synthetic/synthetic_config.py"

# 生成固定长度的合成数据：MinValue 等于 MaxValue。
mkdir -p "$(dirname "$SYNTHETIC_CONFIG")"
"$PYTHON" - \
    "$SYNTHETIC_CONFIG" "$INPUT_LEN" "$OUTPUT_LEN" "$REQUEST_COUNT" <<'PY'
import pathlib
import sys

config_path, input_len, output_len, request_count = sys.argv[1:]
content = f'''synthetic_config = {{
    "Type": "string",
    "RequestCount": {int(request_count)},
    "StringConfig": {{
        "Input": {{
            "Method": "uniform",
            "Params": {{"MinValue": {int(input_len)}, "MaxValue": {int(input_len)}}},
        }},
        "Output": {{
            "Method": "uniform",
            "Params": {{"MinValue": {int(output_len)}, "MaxValue": {int(output_len)}}},
        }},
    }},
}}
'''
pathlib.Path(config_path).write_text(content, encoding="utf-8")
PY

# 生成 vLLM API 配置，ignore_eos 保证输出尽量达到指定长度。
"$PYTHON" - \
    "$MODEL_CONFIG" "$MODEL_PATH" "$MODEL_NAME" "$HOST_PORT" \
    "$OUTPUT_LEN" "$CONCURRENCY" <<'PY'
import pathlib
import sys

(
    config_path,
    model_path,
    model_name,
    host_port,
    output_len,
    concurrency,
) = sys.argv[1:]
content = f'''from ais_bench.benchmark.models import VLLMCustomAPIChatStream
from ais_bench.benchmark.utils.model_postprocessors import extract_non_reasoning_content

models = [
    dict(
        attr="service",
        type=VLLMCustomAPIChatStream,
        abbr="vllm-api-stream-chat",
        path={model_path!r},
        model={model_name!r},
        request_rate=0,
        retry=2,
        host_ip="localhost",
        host_port={int(host_port)},
        max_out_len={int(output_len)},
        batch_size={int(concurrency)},
        trust_remote_code=False,
        generation_kwargs=dict(
            temperature=0.6,
            top_p=0.95,
            ignore_eos=True,
        ),
        pred_postprocessor=dict(type=extract_non_reasoning_content),
    )
]
'''
pathlib.Path(config_path).write_text(content, encoding="utf-8")
PY

echo "[AISBench] synthetic_gen 性能测试"
echo "[AISBench] ISL=$INPUT_LEN OSL=$OUTPUT_LEN 并发=$CONCURRENCY 请求数=$REQUEST_COUNT"

ais_bench \
    --models vllm_api_stream_chat \
    --datasets synthetic_gen \
    --mode perf \
    --debug
