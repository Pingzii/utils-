#!/usr/bin/env bash
set -euo pipefail

# 精度测试：
# bash aisbench_gsm8k.sh accuracy /data/weights/Qwen3-32B Qwen 8000
#
# 性能测试：
# bash aisbench_gsm8k.sh perf /data/weights/Qwen3-32B Qwen 8000

MODE="${1:-}"
MODEL_PATH="${2:-}"
MODEL_NAME="${3:-}"
HOST_PORT="${4:-}"
PYTHON="${PYTHON:-python3}"
BENCHMARK_DIR="${BENCHMARK_DIR:-$PWD/benchmark}"

if [[ "$MODE" != "accuracy" && "$MODE" != "perf" ]] \
    || [[ -z "$MODEL_PATH" || -z "$MODEL_NAME" || -z "$HOST_PORT" ]]; then
    echo "用法：bash $0 accuracy|perf 模型路径 模型名 端口" >&2
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
CONFIG_PATH="$PACKAGE_DIR/benchmark/configs/models/vllm_api/vllm_api_stream_chat.py"
GSM8K_DIR="$PACKAGE_DIR/datasets/gsm8k"

# GSM8K 已存在就跳过下载。
if [[ ! -s "$GSM8K_DIR/test.jsonl" ]]; then
    echo "[AISBench] 下载 GSM8K"
    "$PYTHON" - "$GSM8K_DIR" <<'PY'
import pathlib
import sys
import tempfile
import urllib.request
import zipfile

target = pathlib.Path(sys.argv[1])
target.parent.mkdir(parents=True, exist_ok=True)
url = "http://opencompass.oss-cn-shanghai.aliyuncs.com/datasets/data/gsm8k.zip"

with tempfile.TemporaryDirectory() as temp_dir:
    archive = pathlib.Path(temp_dir) / "gsm8k.zip"
    urllib.request.urlretrieve(url, archive)
    with zipfile.ZipFile(archive) as bundle:
        bundle.extractall(target.parent)

if not (target / "test.jsonl").is_file():
    raise SystemExit(f"GSM8K 解压失败：{target}")
PY
else
    echo "[AISBench] GSM8K 已存在，跳过下载"
fi

# 只把模型路径、模型名和端口写入配置；其余参数固定。
"$PYTHON" - "$CONFIG_PATH" "$MODEL_PATH" "$MODEL_NAME" "$HOST_PORT" <<'PY'
import pathlib
import sys

config_path, model_path, model_name, host_port = sys.argv[1:]
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
        max_out_len=32768,
        batch_size=128,
        trust_remote_code=False,
        generation_kwargs=dict(
            temperature=0.6,
            top_p=0.95,
        ),
        pred_postprocessor=dict(type=extract_non_reasoning_content),
    )
]
'''

pathlib.Path(config_path).write_text(content, encoding="utf-8")
PY

COMMAND=(
    ais_bench
    --models vllm_api_stream_chat
    --datasets gsm8k_gen_0_shot_cot_chat_prompt
    --debug
)

if [[ "$MODE" == "perf" ]]; then
    echo "[AISBench] 性能测试：添加 --mode perf"
    COMMAND+=(--mode perf)
else
    echo "[AISBench] 精度测试：不添加 --mode perf"
fi

"${COMMAND[@]}"
