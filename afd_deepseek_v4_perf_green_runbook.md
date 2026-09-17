# AFD + DeepSeek-V4-Flash 性能测试：绿区执行手册

本文档给绿区 Agent 使用。蓝区负责制定方案、分析结果和处理代码问题；绿区只按本手册执行命令并在绿区本机保存原始数据。发生失败时，绿区 Agent 在绿区对话中输出错误摘要，由用户手动复制给蓝区 Agent；绿区不能直接向蓝区传文件。

## 1. 测试目标与固定口径

目标是比较不同 Attention/FFN 配比下，固定长度请求的吞吐量：

- 横坐标：`A/F = M/N`
- 纵坐标：吞吐量
- 两条曲线：输入上下文长度 `2K` 和 `32K`
- 测试模型：`/mnt/weight/A5-weights/DeepSeek-V4-Flash`
- 服务名：`DeepSeek-V4-Flash`
- 只向 Attention 服务端口 `18000` 发送请求

测试矩阵：

| topology | Attention ranks | FFN ranks | A/F | ISL | OSL | concurrency | request count | measured repeats |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2A2F | 2 | 2 | 1 | 2048 | 128 | 128 | 2048 | 3 |
| 2A2F | 2 | 2 | 1 | 32768 | 128 | 128 | 2048 | 3 |
| 4A2F | 4 | 2 | 2 | 2048 | 128 | 128 | 2048 | 3 |
| 4A2F | 4 | 2 | 2 | 32768 | 128 | 128 | 2048 | 3 |
| 6A2F | 6 | 2 | 3 | 2048 | 128 | 128 | 2048 | 3 |
| 6A2F | 6 | 2 | 3 | 32768 | 128 | 128 | 2048 | 3 |

这里的 `2K/32K` 明确定义为 `synthetic_config.py` 中的输入长度（ISL），不是输入加输出的总长度。所有组固定 `OSL=128`、并发 `128`、请求数 `2048`，否则各组数据不可直接比较。

AISBench 如果同时输出多种吞吐量，必须全部保留：

- Output token throughput，作为主图优先候选
- Total token throughput
- Request throughput
- Input token throughput（如果工具输出）
- TTFT、TPOT、ITL 等时延指标（如果工具输出）

不要在绿区自行猜测字段含义或手工换算。用户把所需日志文本手动提供给蓝区后，再由蓝区确定最终纵坐标。

## 2. 严格执行原则

1. 不修改 AFD、vLLM、vllm-ascend 源码，不切分支，不拉取新提交。
2. 不更换模型、编译参数、采样参数或并发数。
3. 不用 `pkill -f vllm` 等宽范围命令。只停止本次启动时记录的 PID。
4. 每个 topology 先启动 FFN，再启动 Attention；只向 Attention 端口压测。
5. 每个 topology 只启动一次服务，依次执行 2K 和 32K，保证两种上下文使用相同的服务参数。
6. 每个上下文先 warm-up，再执行 3 次正式测量；warm-up 不计入结果。
7. 任何一组失败都不得伪造、补齐或丢弃日志。停止当前阶段并按第 10 节在绿区对话中报告。
8. 禁止从绿区执行 `git push`、`scp`、`curl` 上传或其他向蓝区传输文件的操作。所有产物只保存在绿区本机，跨区传递由用户按允许的方式手动完成。

## 3. 当前方案中的硬停止条件

满足任意一项时停止压测，只在绿区对话中输出检查结果：

- `npu-smi info` 看不到至少 8 张可用 NPU。`6A2F` 单机需要 8 张卡。
- 模型不支持至少 `32768 + 128 = 32896` tokens 的输入加输出长度。
- `18000`、`18010` 或 `6239` 被无关进程占用。
- A/F 两个进程没有按预期绑定到互不重叠的设备。
- 服务日志出现 NPU 错误、OOM、connector 初始化失败或进程退出。
- API 健康检查未通过。

## 4. 结果目录

在绿区创建独立目录，不覆盖以前的结果：

```bash
export PERF_RUN_ID="$(date +%Y%m%d_%H%M%S)"
export PERF_ROOT="/home/s00988495/outputs/afd_deepseek_v4_perf/${PERF_RUN_ID}"
mkdir -p "${PERF_ROOT}"/{env,serve_scripts,runs}
printf '%s\n' "${PERF_ROOT}" | tee "${PERF_ROOT}/RESULT_PATH.txt"
```

后续所有日志、PID、配置快照和结果都必须写入 `${PERF_ROOT}`。

## 5. Phase 0：只做环境检查

先执行以下检查，不启动压测：

```bash
set -o pipefail

date -Ins | tee "${PERF_ROOT}/env/date.txt"
uname -a | tee "${PERF_ROOT}/env/uname.txt"
npu-smi info | tee "${PERF_ROOT}/env/npu_smi_before.txt"
python3 --version 2>&1 | tee "${PERF_ROOT}/env/python_version.txt"
vllm --version 2>&1 | tee "${PERF_ROOT}/env/vllm_version.txt"
ais_bench --help >/dev/null 2>&1
printf 'ais_bench_rc=%s\n' "$?" | tee "${PERF_ROOT}/env/aisbench_check.txt"
ss -ltnp | grep -E ':(18000|18010|6239)\b' | tee "${PERF_ROOT}/env/ports_before.txt" || true
df -h /home/s00988495 /mnt/weight | tee "${PERF_ROOT}/env/disk.txt"
```

记录已安装 Python 包版本，不要执行升级：

```bash
python3 - <<'PY' | tee "${PERF_ROOT}/env/python_packages.txt"
from importlib.metadata import PackageNotFoundError, version

for name in ("vllm", "vllm-ascend", "afd-plugin", "ais-bench-benchmark"):
    try:
        print(f"{name}={version(name)}")
    except PackageNotFoundError:
        print(f"{name}=NOT_INSTALLED_AS_DISTRIBUTION")
PY
```

记录 AFD 仓库状态，不修改工作区：

```bash
git -C /home/s00988495/AFD rev-parse HEAD 2>&1 | tee "${PERF_ROOT}/env/afd_commit.txt"
git -C /home/s00988495/AFD status --short 2>&1 | tee "${PERF_ROOT}/env/afd_status.txt"
```

检查模型声明的最大长度：

```bash
python3 - <<'PY' | tee "${PERF_ROOT}/env/model_context.txt"
import json
from pathlib import Path

path = Path("/mnt/weight/A5-weights/DeepSeek-V4-Flash/config.json")
data = json.loads(path.read_text(encoding="utf-8"))
print(f"config={path}")
for key in (
    "max_position_embeddings",
    "model_max_length",
    "seq_length",
    "max_sequence_length",
):
    print(f"{key}={data.get(key)!r}")
PY
```

如果已知最大长度小于 `32896`，立即停止并在绿区对话中报告。不要为了让 32K 跑起来而擅自修改模型 `config.json`。

## 6. Phase 1：生成三组服务脚本

不要直接编辑原始 `/home/s00988495/afd_serve_A.sh` 和 `afd_serve_F.sh`。复制到 `${PERF_ROOT}/serve_scripts` 后制作三组脚本：

| topology | `ATTN_DEVICES` | `FFN_DEVICES` | Attention `--data-parallel-size` | FFN `--data-parallel-size` | `num_attention_ranks` | `num_ffn_ranks` |
|---|---|---|---:|---:|---:|---:|
| 2A2F | `0,1` | `2,3` | 2 | 2 | 2 | 2 |
| 4A2F | `0,1,2,3` | `4,5` | 4 | 2 | 4 | 2 |
| 6A2F | `0,1,2,3,4,5` | `6,7` | 6 | 2 | 6 | 2 |

三组脚本必须保持以下参数完全相同：

```text
MODEL_PATH=/mnt/weight/A5-weights/DeepSeek-V4-Flash
SERVED_MODEL_NAME=DeepSeek-V4-Flash
ATTN_PORT=18000
FFN_PORT=18010
AFD_HOST=127.0.0.1
AFD_PORT=6239
MAX_MODEL_LEN=33792
tensor-parallel-size=1
enable-expert-parallel=true
compilation-config={"cudagraph_capture_sizes":[8],"cudagraph_mode":"FULL_DECODE_ONLY"}
```

`MAX_MODEL_LEN=33792` 必须对 2K 和 32K 都保持一致。它大于 `32768+128`，并避免因为两种上下文使用不同服务容量而引入额外变量。

用户提供的 2A2F 脚本只用于说明 MANF 的启动方法，其中关于旧机器设备能力的注释不适用于当前新机器。判断 topology 只看 `data-parallel-size`、实际设备数和 `num_*_ranks`，三者必须一致。

### 6.1 修正 additional-config 的 shell 引号

派生脚本不要继续使用下面这种不可靠的嵌套引号：

```bash
--additional-config "{"afd":{...}}"
```

在 Attention 脚本中先构造变量，再传给 vLLM：

```bash
AFD_CONFIG="$(printf '{\"afd\":{\"role\":\"attention\",\"connector\":\"CAMP2pAFDConnector\",\"host\":\"%s\",\"port\":%s,\"num_attention_ranks\":%s,\"num_ffn_ranks\":%s}}' \
    "$AFD_HOST" "$AFD_PORT" "$ATTN_RANKS" "$FFN_RANKS")"

# vllm serve 的最后一个参数：
--additional-config "$AFD_CONFIG"
```

FFN 脚本只把 role 改成 `ffn`：

```bash
AFD_CONFIG="$(printf '{\"afd\":{\"role\":\"ffn\",\"connector\":\"CAMP2pAFDConnector\",\"host\":\"%s\",\"port\":%s,\"num_attention_ranks\":%s,\"num_ffn_ranks\":%s}}' \
    "$AFD_HOST" "$AFD_PORT" "$ATTN_RANKS" "$FFN_RANKS")"
```

每个脚本必须显式定义 `ATTN_RANKS` 和 `FFN_RANKS`，数值取上表。生成后检查：

```bash
bash -n "${PERF_ROOT}"/serve_scripts/*.sh
grep -nE 'DEVICES|RANKS|data-parallel|max-model-len|additional-config' \
    "${PERF_ROOT}"/serve_scripts/*.sh \
    | tee "${PERF_ROOT}/env/generated_serve_parameters.txt"
```

如果 `bash -n` 失败，停止并在绿区对话中打印脚本路径和错误；由用户手动把信息复制给蓝区。

## 7. Phase 2：逐个 topology 启动服务

执行顺序固定为 `2A2F -> 4A2F -> 6A2F`。同一时刻只能运行一组。

以下用 `${TOPOLOGY}` 代表当前组，并假定脚本名为：

```text
${PERF_ROOT}/serve_scripts/afd_serve_F_${TOPOLOGY}.sh
${PERF_ROOT}/serve_scripts/afd_serve_A_${TOPOLOGY}.sh
```

为当前组创建目录并先启动 FFN：

```bash
export TOPOLOGY="2A2F"  # 后续依次改成 4A2F、6A2F
export TOPO_ROOT="${PERF_ROOT}/runs/${TOPOLOGY}"
mkdir -p "${TOPO_ROOT}"/{service,2K,32K}

nohup bash "${PERF_ROOT}/serve_scripts/afd_serve_F_${TOPOLOGY}.sh" \
    >"${TOPO_ROOT}/service/ffn.log" 2>&1 &
echo $! >"${TOPO_ROOT}/service/ffn.pid"
sleep 10
kill -0 "$(cat "${TOPO_ROOT}/service/ffn.pid")"
```

FFN 进程仍存活后，再启动 Attention：

```bash
nohup bash "${PERF_ROOT}/serve_scripts/afd_serve_A_${TOPOLOGY}.sh" \
    >"${TOPO_ROOT}/service/attention.log" 2>&1 &
echo $! >"${TOPO_ROOT}/service/attention.pid"
```

等待 API，最多等待 30 分钟：

```bash
ready=0
for i in $(seq 1 180); do
    if ! kill -0 "$(cat "${TOPO_ROOT}/service/ffn.pid")" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$(cat "${TOPO_ROOT}/service/attention.pid")" 2>/dev/null; then
        break
    fi
    if curl -fsS http://127.0.0.1:18000/v1/models \
        >"${TOPO_ROOT}/service/models.json" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 10
done

if [[ "$ready" != 1 ]]; then
    echo "SERVICE_NOT_READY"
    tail -n 200 "${TOPO_ROOT}/service/ffn.log"
    tail -n 200 "${TOPO_ROOT}/service/attention.log"
    exit 1
fi
```

服务就绪后保存状态：

```bash
npu-smi info | tee "${TOPO_ROOT}/service/npu_smi_ready.txt"
ss -ltnp | grep -E ':(18000|18010|6239)\b' \
    | tee "${TOPO_ROOT}/service/ports_ready.txt" || true
```

任一 topology 如果实际启动失败，直接执行第 10 节的失败报告，不进入 AISBench。

## 8. Phase 3：AISBench warm-up 和正式测量

使用仓库中已有的脚本：

```text
/home/s00988495/tools/utils-/aisbench_synthetic_gen.sh
```

其参数顺序是：

```text
模型路径 模型名 API端口 输入长度 输出长度 并发数 请求数
```

### 8.1 每种上下文先 warm-up

2K warm-up：

```bash
bash /home/s00988495/tools/utils-/aisbench_synthetic_gen.sh \
    /mnt/weight/A5-weights/DeepSeek-V4-Flash \
    DeepSeek-V4-Flash 18000 2048 128 8 32 \
    2>&1 | tee "${TOPO_ROOT}/2K/warmup.log"
```

32K warm-up：

```bash
bash /home/s00988495/tools/utils-/aisbench_synthetic_gen.sh \
    /mnt/weight/A5-weights/DeepSeek-V4-Flash \
    DeepSeek-V4-Flash 18000 32768 128 8 32 \
    2>&1 | tee "${TOPO_ROOT}/32K/warmup.log"
```

必须先执行 `set -o pipefail`，这样 AISBench 失败时不会被 `tee` 掩盖。warm-up 失败即停止，不进行正式测试。

### 8.2 每种上下文正式执行 3 次

2K：

```bash
for repeat in 1 2 3; do
    bash /home/s00988495/tools/utils-/aisbench_synthetic_gen.sh \
        /mnt/weight/A5-weights/DeepSeek-V4-Flash \
        DeepSeek-V4-Flash 18000 2048 128 128 2048 \
        2>&1 | tee "${TOPO_ROOT}/2K/repeat_${repeat}.log"
done
```

32K：

```bash
for repeat in 1 2 3; do
    bash /home/s00988495/tools/utils-/aisbench_synthetic_gen.sh \
        /mnt/weight/A5-weights/DeepSeek-V4-Flash \
        DeepSeek-V4-Flash 18000 32768 128 128 2048 \
        2>&1 | tee "${TOPO_ROOT}/32K/repeat_${repeat}.log"
done
```

每次运行后检查命令返回码、A/F 进程是否还活着，以及日志中是否有 `ERROR`、`Traceback` 或 `OOM`。任意异常都停止当前 topology。

### 8.3 保存 AISBench 实际生成的配置

`aisbench_synthetic_gen.sh` 每次会重写已安装包中的配置，因此每种上下文结束后都要复制快照：

```bash
PACKAGE_DIR="$(python3 -c 'import pathlib, ais_bench; print(pathlib.Path(ais_bench.__file__).resolve().parent)')"

cp -a "${PACKAGE_DIR}/datasets/synthetic/synthetic_config.py" \
    "${TOPO_ROOT}/32K/synthetic_config.py"
cp -a "${PACKAGE_DIR}/benchmark/configs/models/vllm_api/vllm_api_stream_chat.py" \
    "${TOPO_ROOT}/32K/vllm_api_stream_chat.py"
```

2K 测试结束时同样复制到 `${TOPO_ROOT}/2K/`，不要等 32K 执行后再复制，否则 2K 配置会被覆盖。

## 9. Phase 4：安全停止当前 topology

完成当前 topology 后，只停止记录在 PID 文件中的两个进程：

```bash
for role in attention ffn; do
    pid_file="${TOPO_ROOT}/service/${role}.pid"
    if [[ -s "$pid_file" ]]; then
        pid="$(cat "$pid_file")"
        kill "$pid" 2>/dev/null || true
    fi
done

for i in $(seq 1 30); do
    alive=0
    for role in attention ffn; do
        pid_file="${TOPO_ROOT}/service/${role}.pid"
        if [[ -s "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
            alive=1
        fi
    done
    [[ "$alive" == 0 ]] && break
    sleep 1
done

npu-smi info | tee "${TOPO_ROOT}/service/npu_smi_after_stop.txt"
```

如果 30 秒后进程仍未退出，记录 PID 和日志并在绿区对话中报告，不要执行宽范围 `pkill`。

## 10. 失败时如何在绿区报告

失败后不要尝试修改源码，也不要尝试向蓝区 push 或传文件。绿区 Agent 应在当前绿区对话中直接输出以下信息，用户再手动复制给蓝区 Agent：

1. 失败阶段：环境检查、服务生成、FFN 启动、Attention 启动、2K warm-up、2K repeat N、32K warm-up 或 32K repeat N。
2. topology、ISL、OSL、并发和请求数。
3. 失败命令原文和退出码。
4. `${PERF_ROOT}` 完整路径。
5. A/F 日志最后 200 行。
6. AISBench 日志最后 200 行（如果已经进入压测）。
7. `npu-smi info` 和端口占用。

如果用户后续需要完整文件，可以在绿区本机生成压缩包。这个命令只生成本地文件，不上传、不 push，也不会自动进入蓝区：

```bash
tar -C "$(dirname "${PERF_ROOT}")" \
    -czf "${PERF_ROOT}.tar.gz" \
    "$(basename "${PERF_ROOT}")"
printf 'RESULT_ARCHIVE=%s.tar.gz\n' "${PERF_ROOT}"
```

蓝区无法直接访问这里打印的绿区路径。路径只是方便用户在绿区查找文件；是否以及如何跨区取走文件，由用户按公司允许的流程手动处理。

不得把 API Key、Claude settings、环境变量全集或其他凭据放进日志和压缩包。不得执行 `git add`、`git commit` 或 `git push` 提交测试产物。

## 11. 成功时交付内容

绿区不负责画最终曲线，只交付可复现原始数据。成功后应包含：

- 环境与版本信息
- 三组实际使用的 A/F 启动脚本
- 每个 topology 的 A/F 完整日志
- 每个 ISL 的 warm-up 日志和 3 份正式日志
- 每个 ISL 实际生成的 `synthetic_config.py`
- 实际生成的 `vllm_api_stream_chat.py`
- 开始前、服务就绪后、停止后的 `npu-smi` 信息

最终图由蓝区制作：

- x 轴数值：`1, 2, 3`
- x 轴标签：`2A2F, 4A2F, 6A2F`
- 2K 和 32K 各一条曲线
- 每个点取 3 次正式测量的中位数
- 同时保留 3 个原始点，用于判断抖动和异常值

## 12. 发给绿区 Agent 的提示词

把本文件同步到绿区后，将下面内容直接发给绿区 Agent：

```text
阅读 afd_deepseek_v4_perf_green_runbook.md，并严格按文档执行。

你的职责只是执行、在绿区本机完整保存日志，并在当前绿区对话中报告结果。不要修改 AFD、vLLM、vllm-ascend 源码，不要切换版本，不要自行调整测试参数，也不要隐瞒失败。

先执行 Phase 0 环境检查。若命中任何硬停止条件，立即停止并按第 10 节在当前对话中输出报告。检查通过后，按 2A2F、4A2F、6A2F 顺序执行。每个 topology 先 F 后 A，只向 Attention 的 18000 端口压测。每种上下文先 warm-up，再执行 3 次正式测量。

如果出现 NPU 错误、OOM、connector 错误、服务进程退出、API 不可用或 AISBench 非零退出，停止当前阶段，在绿区保留原始文件，并在当前对话中打印错误摘要、日志最后 200 行和 PERF_ROOT。不要擅自修复，不要执行 git push、scp、curl 上传或其他跨区传输操作；用户会手动把必要文本提供给蓝区。
```
