# 绿区 Claude Agent：运行 Serve 示例

本文档假设已经执行过：

```bash
bash deploy_green_zone_agent.sh
```

部署脚本只负责安装 Claude Code、准备 inference-toolkit、注册 skills 和运行自检，
不会自动编译或启动推理服务。真正的 serve 操作需要在 Claude 中下达命令。

## 1. 启动前检查

确认 serve skills 已注册：

```bash
ls -ld /root/.claude/skills/run-serve*
```

确认真机环境配置存在：

```bash
ls -l /home/s00988495/inference-toolkit/validation/real-machine/env/env.yaml
```

如果使用仿真环境，则检查：

```bash
ls -l /home/s00988495/inference-toolkit/validation/simulation/env/env.yaml
```

`env.yaml` 中的源码路径、模型路径、端口和设备配置必须与当前机器一致。

## 2. 启动 Claude

进入 inference-toolkit，并允许 Claude 访问 AFD 源码目录：

```bash
cd /home/s00988495/inference-toolkit
claude --add-dir /home/s00988495/AFD
```

建议先使用普通权限模式。确认环境和命令没有问题后，如确实需要无人值守执行，才使用：

```bash
claude --dangerous --add-dir /home/s00988495/AFD
```

## 3. 最简单的 Serve 指令

进入 Claude 后输入：

```text
跑 serve
```

Agent 会尝试加载 `run-serve` 或 `run-serve-real` skill，并自动判断当前是真机还是仿真环境。

## 4. 推荐的 Serve 指令

为了避免路径、模型或端口配错，推荐直接把下面整段发给 Claude：

```text
请使用 inference-toolkit 中的 run-serve skill 启动推理服务。

要求：
1. 先自动判断当前是真机还是仿真环境，并说明判断依据。
2. 读取对应的 validation 环境配置，不要凭空猜测路径、模型、端口或设备数量。
3. 启动前先列出本次将使用的模型路径、vLLM 路径、vLLM-Ascend 路径、端口和 NPU 设备。
4. 如果关键配置缺失或文件不存在，先停止并向我询问，不要直接启动。
5. 检查端口占用、NPU 状态和 Python 环境。
6. 按 skill 启动服务，把 stdout 和 stderr 保存到日志文件。
7. 服务就绪后执行一次 smoke test。
8. 最后告诉我服务 PID、监听端口、日志路径、smoke test 结果和停止服务的方法。
```

Claude 在真正执行命令前应先展示它识别出的关键配置。如果这些信息不正确，先让它修改配置，
不要直接确认执行。

## 5. AFD + DeepSeek-V4 Serve 示例

普通的 `run-serve` skill 不一定包含 AFD 启动参数。需要测试 AFD 时，使用下面的指令：

```text
我要启动 AFD + DeepSeek-V4 推理服务。

请先检查 /root/.claude/skills 中是否存在 AFD 专用的 serve skill：
1. 如果存在，使用 AFD 专用 skill，不要使用普通 run-serve 代替。
2. 如果不存在，停止执行并告诉我缺少哪个 skill 或 recipe，不要假装已经启用 AFD。
3. 启动前列出 A/F 实例数量、模型路径、设备分配、服务端口和实际启动命令。
4. 检查端口、NPU、vLLM、vLLM-Ascend 和 afd-plugin 是否可用。
5. 启动日志写入文件，服务就绪后执行 smoke test。
6. 最后报告 PID、端口、日志路径、健康检查结果，以及如何确认当前确实启用了 AFD。
```

如果 Agent 报告没有 AFD 专用 skill，应先补齐 inference-toolkit 中的 AFD 能力，不能仅凭服务能返回
HTTP 200 就认定 AFD 已经生效。

## 6. 查看服务状态

可以继续向 Claude 输入：

```text
检查刚才启动的 serve 是否仍在运行，并展示 PID、监听端口、最近 100 行日志和 NPU 使用情况。
```

也可以在另一个终端手动检查：

```bash
ss -lntp
npu-smi info
```

知道端口后，可检查 OpenAI 兼容接口：

```bash
curl http://127.0.0.1:<端口>/v1/models
```

## 7. 停止服务

推荐让 Agent 只停止它刚才记录的 PID：

```text
停止刚才由你启动的 serve。只停止你记录的服务 PID，不要使用 pkill -9 或杀掉其他 vLLM 进程。
停止后确认端口已经释放，并告诉我停止结果。
```

## 8. 常见问题

### 找不到 run-serve skill

```bash
ls -l /root/.claude/skills
```

重新执行部署脚本，让它重新链接 skills：

```bash
cd /home/s00988495/tools/utils-
bash deploy_green_zone_agent.sh
```

### env.yaml 不完整

真机配置位置：

```text
/home/s00988495/inference-toolkit/validation/real-machine/env/env.yaml
```

仿真配置位置：

```text
/home/s00988495/inference-toolkit/validation/simulation/env/env.yaml
```

只修改当前要使用的环境。机器相关路径、模型、端口和 SOC 不要写入 recipe，应放在对应的
`env.yaml` 中。

### Claude 启动后没有自动执行

普通模式会要求确认工具调用，这是正常行为。如果需要自动执行并且当前目录完全可信，可以退出后使用：

```bash
claude --dangerous --add-dir /home/s00988495/AFD
```

`--dangerous` 会跳过工具权限确认，只应在可信容器和可信项目目录中使用。
