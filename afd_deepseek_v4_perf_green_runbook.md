# AFD 与普通混步性能对比：绿区 Agent 执行手册

本文档用于 Ascend A5 环境中的 DeepSeek-V4-Flash 性能测试。蓝区负责确定实验口径和分析数据；绿区 Agent 负责检查现有环境、生成测试文件、执行测试并在绿区本机保存产物。

绿区不能直接向蓝区传文件。失败时只在绿区对话中打印摘要和必要日志，由用户手动复制给蓝区。

## 1. 本轮实验的唯一口径

### 1.1 测试对象

| mode | topology | Attention 卡 | FFN 卡 | 总卡数 | 对比对象 |
|---|---|---:|---:|---:|---|
| AFD | 2A2F | 2 | 2 | 4 | 4 卡普通混步 |
| AFD | 4A2F | 4 | 2 | 6 | 6 卡普通混步 |
| AFD | 6A2F | 6 | 2 | 8 | 8 卡普通混步 |
| 普通混步 | 4card | - | - | 4 | 2A2F |
| 普通混步 | 6card | - | - | 6 | 4A2F |
| 普通混步 | 8card | - | - | 8 | 6A2F |

只允许等总卡数比较：

- `2A2F vs 4card mix`
- `4A2F vs 6card mix`
- `6A2F vs 8card mix`

不得用 2A2F 与 6 卡或 8 卡混步比较。

### 1.2 固定参数

```text
MODEL_PATH=/mnt/weight/A5-weights/DeepSeek-V4-Flash
SERVED_MODEL_NAME=DeepSeek-V4-Flash
MAX_MODEL_LEN=32768
MAX_NUM_SEQS=256
BS_LIST=(32 64 128 256)
CUDAGRAPH_CAPTURE_SIZES=(32 64 128 256)
WARMUPS=1
```

必须使用图模式：

```text
--compilation-config '{"cudagraph_capture_sizes":[32,64,128,256],"cudagraph_mode":"FULL_DECODE_ONLY"}'
```

禁止添加：

```text
--enforce-eager
```

### 1.3 Batch Size 和数据量

本实验的 Batch Size 只指 AisBench benchmark config 中的 `batchsize`。

它不等于：

- `--max-num-batched-tokens`
- `--num-prompts`
- A/F rank 数
- DP 数量

每个测试点固定：

```text
dataset_size = batchsize × 4
```

| batchsize | dataset size |
|---:|---:|
| 32 | 128 |
| 64 | 256 |
| 128 | 512 |
| 256 | 1024 |

同时必须满足：

```text
batchsize <= --max-num-seqs
batchsize in cudagraph_capture_sizes
```

本轮主矩阵不包含 BS=512。只有完成全部 24 个测试点且蓝区确认后，才能扩展到 512；扩展时必须同步提高 `--max-num-seqs` 并把 512 加入 capture sizes。

### 1.4 32K 的含义

AFD 和普通混步服务统一使用：

```text
--max-model-len 32768
```

注意：`--max-model-len` 是服务容量上限，不会自动把请求变成 32K。绿区必须定位并复用已经跑通的 32K dataset 配置，记录其中实际 ISL、OSL 和生成参数，并保证：

```text
ISL + OSL <= 32768
```

不得在 OSL 大于 0 时把 synthetic Input 直接设置成 32768。若当前没有已经确认的 32K dataset 配置，停止在 Phase 0，打印找到的 dataset schema 和候选配置，由蓝区决定 ISL/OSL；不要自行发明长度。

## 2. 与旧执行手册的差异

本轮不得沿用以下旧口径：

- 不再测试 2K。
- 不把并发固定为 128，而是扫描 32、64、128、256。
- 不把请求数固定为 2048，而是严格使用 `4 × batchsize`。
- 不使用 `--num-prompts` 控制正式测试数据量。
- 不使用 `ais_bench --models ... --datasets ... --mode perf`。
- 不直接使用当前仓库中的 `aisbench_synthetic_gen.sh` 跑本轮实验；该脚本属于旧 CLI 流程。
- 不额外手写一轮 warmup 请求；使用 AisBench 的 `--num-warmups 1`。
- 不再使用 `MAX_MODEL_LEN=33792`。
- 不再使用只包含 `[8]` 的 `cudagraph_capture_sizes`。

## 3. 实验矩阵

必须完成 6 种运行配置 × 4 个 batchsize，共 24 个测试点：

| mode | topology | BS |
|---|---|---|
| AFD | 2A2F | 32 / 64 / 128 / 256 |
| mix | 4card | 32 / 64 / 128 / 256 |
| AFD | 4A2F | 32 / 64 / 128 / 256 |
| mix | 6card | 32 / 64 / 128 / 256 |
| AFD | 6A2F | 32 / 64 / 128 / 256 |
| mix | 8card | 32 / 64 / 128 / 256 |

正式全量测试前，必须先完成唯一的 smoke test：

```text
AFD 4A2F + BS=32 + dataset_size=128
```

smoke test 失败时不得进入其余 23 个测试点。

## 4. 执行边界

1. 不修改 vLLM、vLLM-Ascend 或 afd-plugin 源码。
2. 不切换 Git 分支或提交，不运行 `git pull`。
3. 先理解现有可运行的 4A2F 脚本，再生成其他服务脚本。
4. 不仅凭参数名猜测 DP、EP、TP、rank 和物理卡之间的关系。
5. AisBench schema、字段名和 CLI 以当前环境中的 `ais_bench -h` 与已跑通 config 为准。
6. 所有测试点必须保存独立 config、dataset、服务日志和 work directory。
7. 不使用宽范围 `pkill -f vllm`。只停止本次记录的 PID。
8. 不从绿区执行 Git push、scp、curl 外传或其他跨区传输。
9. 不在日志中输出 API Key、Claude settings 或环境变量全集。

## 5. 目录结构

在绿区建立独立测试目录：

```text
/home/s00988495/perf_test/
├── afd/
│   ├── 2A2F/
│   │   ├── serve_A.sh
│   │   └── serve_F.sh
│   ├── 4A2F/
│   │   ├── serve_A.sh
│   │   └── serve_F.sh
│   └── 6A2F/
│       ├── serve_A.sh
│       └── serve_F.sh
├── mix/
│   ├── serve_4card.sh
│   ├── serve_6card.sh
│   └── serve_8card.sh
├── aisbench/
│   ├── baseline/
│   ├── configs/
│   └── datasets/
├── scripts/
│   ├── run_one.sh
│   └── run_all.sh
├── env/
├── logs/
├── results/
├── summary/
└── README.md
```

不得覆盖旧测试结果。正式执行时再增加 run ID：

```bash
export PERF_ROOT=/home/s00988495/perf_test
export RUN_ID="$(date +%Y%m%d_%H%M%S)"
export RUN_ROOT="${PERF_ROOT}/results/${RUN_ID}"
mkdir -p "${RUN_ROOT}"
```

## 6. Phase 0：只扫描，不生成、不压测

### 6.1 保存环境信息

```bash
export PERF_ROOT=/home/s00988495/perf_test
mkdir -p "${PERF_ROOT}"/{env,afd,mix,aisbench/baseline,aisbench/configs,aisbench/datasets,scripts,logs,results,summary}

date -Ins | tee "${PERF_ROOT}/env/date.txt"
uname -a | tee "${PERF_ROOT}/env/uname.txt"
npu-smi info | tee "${PERF_ROOT}/env/npu_smi.txt"
python3 --version 2>&1 | tee "${PERF_ROOT}/env/python.txt"
python3 -m pip list | grep -E '^(vllm|vllm-ascend|afd-plugin|ais)' \
    | tee "${PERF_ROOT}/env/packages.txt" || true
```

保存三个源码仓库的 commit 和工作区状态：

```bash
for repo in vllm vllm-ascend afd-plugin; do
    git -C "/home/s00988495/AFD/${repo}" rev-parse HEAD \
        | tee "${PERF_ROOT}/env/${repo}_commit.txt"
    git -C "/home/s00988495/AFD/${repo}" status --short \
        | tee "${PERF_ROOT}/env/${repo}_status.txt"
done
```

### 6.2 确认 AisBench 当前 CLI

必须实际执行，不凭记忆：

```bash
command -v ais_bench | tee "${PERF_ROOT}/env/aisbench_path.txt"
ais_bench -h 2>&1 | tee "${PERF_ROOT}/env/aisbench_help.txt"
```

确认当前版本支持：

```text
ais_bench CONFIG
-m perf
-w WORK_DIR
--num-warmups 1
```

若任一参数不受当前版本支持，停止并把完整 `ais_bench -h` 输出打印给用户，不要换回旧 CLI。

### 6.3 定位已有 AisBench 配置

首先定位安装目录：

```bash
python3 - <<'PY' | tee "${PERF_ROOT}/env/aisbench_package_path.txt"
import pathlib
import ais_bench

print(pathlib.Path(ais_bench.__file__).resolve().parent)
PY
```

然后搜索当前已有的配置，重点找已经成功运行过的文件：

```bash
find /home/s00988495 /root -type f \
    \( -name '*.yaml' -o -name '*.yml' -o -name '*.py' \) \
    2>/dev/null \
    | grep -Ei 'ais|bench|synthetic|dataset|summar|vllm' \
    | tee "${PERF_ROOT}/env/aisbench_config_candidates.txt"
```

在候选文件中定位并记录：

- benchmark config 入口
- `batchsize` 字段
- model config 与服务地址
- dataset config 与实际请求数量字段
- 32K workload 的 ISL、OSL 和生成参数
- summarizer config
- 结果输出结构

将已跑通的原始 config 和 dataset 原样复制到 `${PERF_ROOT}/aisbench/baseline/`。不要修改安装包内的唯一原件。

### 6.4 定位当前可运行的 4A2F 脚本和日志

优先检查：

```text
/home/s00988495/afd_serve_A.sh
/home/s00988495/afd_serve_F.sh
```

复制到：

```text
/home/s00988495/perf_test/afd/4A2F/serve_A.sh
/home/s00988495/perf_test/afd/4A2F/serve_F.sh
```

同时定位最近一次成功启动日志。禁止在尚未理解 4A2F 时直接生成 2A2F/6A2F。

### 6.5 Phase 0 交付与闸门

生成 `${PERF_ROOT}/env/phase0_report.md`，至少写明：

- AisBench 真实命令和版本
- 已跑通 benchmark config 路径
- `batchsize` 的配置位置
- dataset 数量字段及配置路径
- 32K workload 的 ISL/OSL
- 当前 4A2F 两个脚本路径
- 当前 4A2F 的设备、DP、TP、EP、A/F rank 和端口
- 普通混步是否已有可运行基线脚本
- 所有未确认项

存在任何未确认项时停止。绿区 Agent 在当前对话中粘贴 `phase0_report.md`，由用户手动带给蓝区；不能自行猜测后继续。

## 7. Phase 1：确认 4A2F 架构并派生服务脚本

### 7.1 必须确认的关系

结合现有 4A2F 脚本、afd-plugin 源码、vllm-ascend 源码和成功启动日志，解释：

- `ASCEND_RT_VISIBLE_DEVICES`
- `--data-parallel-size`
- `--tensor-parallel-size`
- `--enable-expert-parallel`
- `num_attention_ranks`
- `num_ffn_ranks`
- A2E/E2A connector
- 每个 rank 与物理卡的映射

只有确认 4A2F 的实际映射后，才允许按相同规律派生其他拓扑。

### 7.2 AFD 目标设备布局

下表是待验证的目标布局，不是跳过源码/日志验证的依据：

| topology | Attention devices | FFN devices | A ranks | F ranks | total cards |
|---|---|---|---:|---:|---:|
| 2A2F | `0,1` | `2,3` | 2 | 2 | 4 |
| 4A2F | `0,1,2,3` | `4,5` | 4 | 2 | 6 |
| 6A2F | `0,1,2,3,4,5` | `6,7` | 6 | 2 | 8 |

AFD 约束必须成立：

```text
A >= F
A % F == 0
F = 2
```

4A2F 是已知基线，不重新设计；只在副本中补齐本轮统一的服务参数。

### 7.3 普通混步目标布局

| topology | visible devices | total cards |
|---|---|---:|
| 4card | `0,1,2,3` | 4 |
| 6card | `0,1,2,3,4,5` | 6 |
| 8card | `0,1,2,3,4,5,6,7` | 8 |

普通混步使用单个 vLLM 服务，不配置 AFD role、A2E/E2A connector 或 A/F rank。DP/EP/TP 必须根据当前 DeepSeek-V4-Flash 在 vLLM-Ascend 上已经验证的普通混步启动方式确定；若没有已跑通的混步基线，先生成候选配置并把依据返回蓝区，不得直接把候选数据当正式结果。

### 7.4 所有服务脚本的统一约束

AFD 与 mix 均必须包含：

```text
--max-model-len 32768
--max-num-seqs 256
--compilation-config {"cudagraph_capture_sizes":[32,64,128,256],"cudagraph_mode":"FULL_DECODE_ONLY"}
```

均不得包含：

```text
--enforce-eager
```

AFD 两个角色均保存独立日志；先启动 F，再启动 A；只向 Attention API 发送请求。普通混步只启动一个服务。

生成脚本后执行：

```bash
bash -n "${PERF_ROOT}"/afd/*/*.sh
bash -n "${PERF_ROOT}"/mix/*.sh

grep -RInE 'max-model-len|max-num-seqs|cudagraph_capture_sizes|enforce-eager|data-parallel|tensor-parallel|num_attention_ranks|num_ffn_ranks' \
    "${PERF_ROOT}/afd" "${PERF_ROOT}/mix" \
    | tee "${PERF_ROOT}/env/service_parameter_audit.txt"
```

若出现 `--enforce-eager`、缺少 256、capture sizes 不完整或卡数不匹配，停止。

## 8. Phase 2：生成每个测试点的 AisBench 配置

### 8.1 唯一正式命令形式

正式测试必须使用：

```bash
ais_bench "${BENCHMARK_CONFIG}" \
    -m perf \
    --num-warmups 1 \
    -w "${WORK_DIR}"
```

不要使用：

```text
--models
--datasets
--mode perf
--num-prompts
```

### 8.2 配置生成原则

每个测试点从 Phase 0 找到的“已跑通 config”复制生成，不能从空文件猜 schema。

例如：

```text
perf_test/aisbench/configs/afd_4a2f_bs128.yaml
perf_test/aisbench/datasets/afd_4a2f_bs128.*
```

每个点只按当前 config 的真实 schema 修改：

1. `batchsize=BS`
2. dataset 请求数量设置为 `BS × 4`
3. 服务地址指向当前服务端口
4. model 名称保持 `DeepSeek-V4-Flash`
5. 复用同一个已确认的 32K workload 参数
6. 复用相同采样参数和 summarizer

如果 config 中找不到明确的 `batchsize` 字段，停止并返回 config 内容；不要用 `batch_size`、`--num-prompts` 或其他字段替代。

### 8.3 生成后检查

`run_one.sh` 必须在调用 AisBench 前输出并保存：

```text
mode
topology
batchsize
dataset_size
benchmark_config
dataset_config
service endpoint
max_model_len
max_num_seqs
cudagraph_capture_sizes
```

并验证：

```text
dataset_size == batchsize × 4
batchsize <= 256
batchsize ∈ [32,64,128,256]
```

还必须从当前服务脚本中确认：

```text
--max-num-seqs >= batchsize
cudagraph_capture_sizes 包含 batchsize
```

任何检查失败都禁止启动正式测试。

## 9. Phase 3：自动化脚本契约

### 9.1 run_one.sh

接口：

```bash
bash run_one.sh afd 4A2F 128
bash run_one.sh mix 6card 128
```

`run_one.sh` 必须按顺序完成：

1. 校验 mode、topology、总卡数和 batchsize。
2. 计算 `dataset_size=$((batchsize * 4))`。
3. 复制基线 AisBench config/dataset，生成当前测试点专用副本。
4. 修改 config 中的 `batchsize`。
5. 修改 dataset 配置中的请求数量。
6. 校验 `max-num-seqs` 和 capture sizes。
7. 创建独立的 log/result/work 目录。
8. AFD 模式先启动 F，再启动 A；mix 模式启动单服务。
9. 记录服务 PID，不使用宽范围 pkill。
10. 轮询 `/v1/models`，等待服务 ready。
11. 保存启动后的 `npu-smi info`。
12. 执行一次 AisBench 正式命令，显式指定 `--num-warmups 1`。
13. 保存 AisBench stdout/stderr、work directory 和服务日志。
14. 检查服务日志中的 graph capture 与 graph replay 状态。
15. 停止本次记录的 PID，确认端口释放。
16. 写入当前测试点的 `manifest.txt` 和 `status.txt`。

结果目录名称：

```text
results/RUN_ID/afd_2A2F_bs32/
results/RUN_ID/afd_4A2F_bs128/
results/RUN_ID/mix_8card_bs256/
```

每个目录至少包含：

```text
benchmark_config.yaml
dataset config/data
manifest.txt
status.txt
aisbench.log
server_A.log / server_F.log
或 mix_server.log
npu_smi_before.txt
npu_smi_after.txt
AisBench work directory
```

### 9.2 run_all.sh

固定：

```bash
BS_LIST=(32 64 128 256)
```

第一步只执行：

```bash
bash run_one.sh afd 4A2F 32
```

确认 smoke test 成功、dataset size 为 128、graph capture/replay 正常后，才遍历完整矩阵。

建议完整顺序：

```text
2A2F → 4card mix
4A2F → 6card mix
6A2F → 8card mix
```

每种配置内部按：

```text
32 → 64 → 128 → 256
```

任一测试点失败时停止 `run_all.sh`，不要跳过后继续，也不要产生伪造的空结果。

## 10. 服务就绪、图模式和清理检查

### 10.1 服务就绪

最多等待 30 分钟，必须同时满足：

- 本次记录的服务 PID 存活
- API `/v1/models` 返回成功
- 日志没有 OOM、Traceback、NPU error 或 connector error

AFD 的请求只发送到 Attention 服务。

### 10.2 图模式

每个测试点必须从日志确认：

- 当前 BS 在 capture sizes 中
- graph capture 成功
- decode 实际进入 graph replay
- 没有回退到 eager 的警告

如果当前日志无法证明 graph replay，结果标记为 `INVALID_GRAPH_STATUS`，不得进入最终比较。

### 10.3 清理

只允许对 PID 文件记录的进程发送 `TERM`，等待退出并确认端口释放。若 30 秒后仍未退出，停止自动化并报告；不要执行 `pkill -f vllm`。

## 11. 结果汇总

每个测试点至少记录：

```text
mode
topology
A cards
F cards
total cards
batchsize
dataset size
max-model-len
max-num-seqs
cudagraph_capture_sizes
DP
EP
TP
QPS
throughput
TTFT mean/P50/P90/P99
TPOT mean/P50/P90/P99
E2E latency
peak NPU memory（若可得）
NPU utilization（若可得）
graph replay status
OOM status
result path
```

将数据写入绿区本机：

```text
perf_test/summary/raw_results.csv
perf_test/summary/failures.csv
```

不得猜测或手工补齐 AisBench 未输出的指标；缺失值写 `NA`，并保留原始日志字段名。

## 12. 甜点区与最终分析

绿区先整理数据，不负责作最终结论。蓝区基于原始数据分别寻找：

- 2A2F、4A2F、6A2F 的最佳 BS
- 4card、6card、8card mix 的最佳 BS

甜点区不能只看最大吞吐，还要观察 BS 增大后：

- Throughput/QPS 收益是否变小
- TTFT 是否明显恶化
- TPOT 是否明显恶化
- E2E latency 是否明显恶化
- 是否出现 OOM、调度拥塞或 graph 回退

最终至少生成以下比较：

1. 每种运行配置的吞吐量 vs batchsize。
2. 每种运行配置的时延 vs batchsize。
3. AFD 与等卡 mix 在相同 BS 下的比较。
4. AFD 与等卡 mix 各自甜点区的比较。
5. A/F ratio `1 → 2 → 3` 的性能变化。
6. Attention、FFN、A2E/E2A 通信、bubble 与 rank 负载不均的瓶颈分析。

## 13. 失败时在绿区报告

发生失败后停止当前自动化，不修改源码，不向蓝区传文件。绿区 Agent 在当前对话中打印：

1. phase、mode、topology、batchsize、dataset size
2. 失败命令和退出码
3. 本地结果目录
4. 服务日志最后 200 行
5. AisBench 日志最后 200 行
6. 当前 PID、端口和 `npu-smi info`
7. 生成的 benchmark config 与 dataset 数量字段片段
8. `status.txt` 内容

可以在绿区本机生成压缩包供用户按允许的方式手动处理，但不得自动上传：

```bash
tar -C /home/s00988495 \
    -czf "/home/s00988495/perf_test_${RUN_ID}.tar.gz" \
    perf_test
```

## 14. 发给绿区 Agent 的提示词

将本文件同步到绿区后，直接发送：

```text
阅读 afd_deepseek_v4_perf_green_runbook.md，并严格按文档分阶段执行。

先只执行 Phase 0：扫描当前 vLLM、vLLM-Ascend、afd-plugin、AisBench、已跑通的 AisBench config/dataset、当前可运行的 4A2F A/F 脚本及成功日志。生成 phase0_report.md 后停止，并在当前绿区对话中粘贴报告。不要在 Phase 0 直接生成拓扑或开始压测。

蓝区确认 Phase 0 后，再分析 4A2F 的 device、DP、EP、TP、A/F rank 和 connector 映射，并以它为基线生成 2A2F、6A2F 以及等卡 4/6/8card 普通混步脚本。

本轮固定 max-model-len=32768、max-num-seqs=256、cudagraph_capture_sizes=[32,64,128,256]，禁止 enforce-eager。Batch Size 只使用 AisBench config 中的 batchsize；dataset size 永远等于 batchsize×4。正式命令只能使用 ais_bench CONFIG -m perf --num-warmups 1 -w WORK_DIR，不使用 --num-prompts，也不使用旧的 --models/--datasets/--mode perf 流程。

先执行 4A2F+BS32 smoke test，成功后再执行 24 个测试点。任何失败立即停止，在绿区保存原始文件，并在当前对话中打印错误摘要与日志尾部。不要修改源码，不要执行 git push、scp、curl 上传或其他跨区传输操作。
```
