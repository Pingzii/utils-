#!/usr/bin/env bash
set -euo pipefail

# 华为绿区（Linux arm64）Claude Code + inference-toolkit 一键部署脚本。
#
# 最小用法：
#   bash deploy_green_zone_agent.sh
#
# 默认复用 create_container.sh 中的目录约定：
#   绿区持久化目录：/home/s00988495
#   proxy.sh：       /home/s00988495/proxy.sh
#   离线安装脚本：   /home/s00988495/claude-offline-aarch64.sh
#   AFD：            /home/s00988495/AFD
#   inference-toolkit：/home/s00988495/inference-toolkit
#
# 首次运行会静默读取 API Key，自动保存到持久化目录；不会打印 Key，
# 也不会让 Key 出现在命令历史或进程参数中。

SCRIPT_NAME="$(basename "$0")"
DEFAULT_REPO_URL="https://szv-open.codehub.huawei.com/innersource/inference-toolkit_G/inference-toolkit.git"
OFFLINE_INSTALLER_SOURCE="root@141.61.92.13:/home/w00984239/claude-offline-aarch64.sh"
DEFAULT_CLAUDE_MODEL="DeepSeek-V4-Flash"

API_KEY_FILE=""
BASE_URL=""
PROXY_SCRIPT=""
OFFLINE_INSTALLER=""
CODEHUB_IP="141.2.250.30"
GREEN_ZONE_HOME="${GREEN_ZONE_HOME:-/home/s00988495}"
AFD_ROOT="${AFD_ROOT:-}"
WORKSPACE_DIR=""
REPO_URL="$DEFAULT_REPO_URL"
REAL_ENV_FILE=""
SIMULATION_ENV_FILE=""
SETTINGS_PATH="${HOME}/.claude/settings.json"
SKIP_HOSTS=0
SKIP_TOOLKIT=0
SKIP_VALIDATION=0
UPDATE_TOOLKIT=0
REFRESH_API_KEY=0

usage() {
    cat <<EOF
用法：
  bash $SCRIPT_NAME [选项]

可选：
  --base-url URL            自定义 ANTHROPIC_BASE_URL；不传则保留已有配置
  --green-home PATH         Docker 挂载的绿区持久化目录
                            默认：/home/s00988495
  --afd-root PATH           AFD 根目录
                            默认：<green-home>/AFD
  --proxy-script PATH       绿区 proxy.sh 路径
                            默认：<green-home>/proxy.sh
  --workspace-dir PATH      inference-toolkit 目录
                            默认：<green-home>/inference-toolkit
  --repo-url URL            inference-toolkit Git 地址
  --real-env-file PATH      用指定 YAML 覆盖生成的真机 env.yaml
  --simulation-env-file PATH
                            用指定 YAML 覆盖生成的仿真 env.yaml
  --settings-path PATH      Claude settings.json 路径
                            默认：$SETTINGS_PATH
  --update-toolkit          已 clone 时执行 git pull --ff-only
  --refresh-api-key         重新输入并覆盖已保存的 API Key
  --skip-hosts              不修改 /etc/hosts
  --skip-toolkit            只装/配置 Claude，不部署 inference-toolkit
  --skip-validation         不运行 validate_context.py
  -h, --help                显示帮助

示例：
  bash $SCRIPT_NAME

  # 更换 API Key
  bash $SCRIPT_NAME --refresh-api-key

说明：
  1. 本地已有非空 claude-offline-aarch64.sh 时直接复用；缺失时通过
     scp 获取：
       $OFFLINE_INSTALLER_SOURCE
     scp 失败时立即停止，不继续安装。
  2. 首次运行会静默提示输入 API Key，并自动保存为：
       <green-home>/.secrets/claude.key
     后续运行默认复用；文件权限自动设置为 600。该 Key 会同时写入
     ANTHROPIC_AUTH_TOKEN 和 ANTHROPIC_API_KEY。
  3. 默认目录与 create_container.sh 的 /home/s00988495 约定一致。
  4. CodeHub hosts 地址固定为 141.2.250.30，部署日志会打印该地址。
  5. 只有灵枢明确提供自定义网关时，才需要传 --base-url。
  6. Claude 默认模型为 $DEFAULT_CLAUDE_MODEL；仅替换缺失、空值或原始
     GLM-5.2 默认值，
     已经改成其他模型的配置保持不变。
  7. 未提供 env 文件时，保留 init_workspace.py 生成的模板，之后按机器填写。
  8. 部署后运行 claude-green；需要跳过权限确认时显式运行：
       claude-green --dangerous
EOF
}

log() {
    printf '[GreenAgent] %s\n' "$*"
}

warn() {
    printf '[GreenAgent] 警告：%s\n' "$*" >&2
}

die() {
    printf '[GreenAgent] 错误：%s\n' "$*" >&2
    exit 1
}

need_value() {
    [[ $# -ge 2 && -n "${2:-}" ]] || die "参数 $1 缺少值"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-url)
            need_value "$@"
            BASE_URL="$2"
            shift 2
            ;;
        --proxy-script)
            need_value "$@"
            PROXY_SCRIPT="$2"
            shift 2
            ;;
        --green-home)
            need_value "$@"
            GREEN_ZONE_HOME="$2"
            shift 2
            ;;
        --afd-root)
            need_value "$@"
            AFD_ROOT="$2"
            shift 2
            ;;
        --workspace-dir)
            need_value "$@"
            WORKSPACE_DIR="$2"
            shift 2
            ;;
        --repo-url)
            need_value "$@"
            REPO_URL="$2"
            shift 2
            ;;
        --real-env-file)
            need_value "$@"
            REAL_ENV_FILE="$2"
            shift 2
            ;;
        --simulation-env-file)
            need_value "$@"
            SIMULATION_ENV_FILE="$2"
            shift 2
            ;;
        --settings-path)
            need_value "$@"
            SETTINGS_PATH="$2"
            shift 2
            ;;
        --update-toolkit)
            UPDATE_TOOLKIT=1
            shift
            ;;
        --refresh-api-key)
            REFRESH_API_KEY=1
            shift
            ;;
        --skip-hosts)
            SKIP_HOSTS=1
            shift
            ;;
        --skip-toolkit)
            SKIP_TOOLKIT=1
            shift
            ;;
        --skip-validation)
            SKIP_VALIDATION=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "未知参数：$1（运行 bash $SCRIPT_NAME --help 查看用法）"
            ;;
    esac
done

command -v python3 >/dev/null 2>&1 || die "未找到 python3，inference-toolkit 初始化需要 Python 3"

absolute_path() {
    python3 -c \
        'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' \
        "$1"
}

# 对齐 create_container.sh 和 afd_build_all_sym.sh 的目录约定。
GREEN_ZONE_HOME="$(absolute_path "$GREEN_ZONE_HOME")"
[[ -n "$AFD_ROOT" ]] || AFD_ROOT="$GREEN_ZONE_HOME/AFD"
[[ -n "$PROXY_SCRIPT" ]] || PROXY_SCRIPT="$GREEN_ZONE_HOME/proxy.sh"
OFFLINE_INSTALLER="$GREEN_ZONE_HOME/claude-offline-aarch64.sh"
[[ -n "$WORKSPACE_DIR" ]] || WORKSPACE_DIR="$GREEN_ZONE_HOME/inference-toolkit"

AFD_ROOT="$(absolute_path "$AFD_ROOT")"
WORKSPACE_DIR="$(absolute_path "$WORKSPACE_DIR")"
SETTINGS_PATH="$(absolute_path "$SETTINGS_PATH")"
OFFLINE_INSTALLER="$(absolute_path "$OFFLINE_INSTALLER")"
API_KEY_FILE="$GREEN_ZONE_HOME/.secrets/claude.key"
VLLM_REPO_DIR="$AFD_ROOT/vllm"
VLLM_ASCEND_REPO_DIR="$AFD_ROOT/vllm-ascend"
AFD_PLUGIN_REPO_DIR="$AFD_ROOT/afd-plugin"

[[ -f "$PROXY_SCRIPT" && -r "$PROXY_SCRIPT" ]] || die "代理脚本不可读：$PROXY_SCRIPT"
[[ -z "$REAL_ENV_FILE" || -f "$REAL_ENV_FILE" ]] || die "真机 env 文件不存在：$REAL_ENV_FILE"
[[ -z "$SIMULATION_ENV_FILE" || -f "$SIMULATION_ENV_FILE" ]] || die "仿真 env 文件不存在：$SIMULATION_ENV_FILE"
if [[ -n "$BASE_URL" ]] && [[ ! "$BASE_URL" =~ ^https?:// ]]; then
    die "--base-url 必须以 http:// 或 https:// 开头"
fi

ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64)
        ;;
    *)
        die "本脚本面向 Linux arm64，当前架构为：$ARCH"
        ;;
esac

# 先转成绝对路径，避免后续切换目录后相对路径失效。
PROXY_SCRIPT="$(readlink -f "$PROXY_SCRIPT")"
[[ -z "$REAL_ENV_FILE" ]] || REAL_ENV_FILE="$(readlink -f "$REAL_ENV_FILE")"
[[ -z "$SIMULATION_ENV_FILE" ]] || SIMULATION_ENV_FILE="$(readlink -f "$SIMULATION_ENV_FILE")"

export GREEN_ZONE_HOME AFD_ROOT
export VLLM_REPO_DIR VLLM_ASCEND_REPO_DIR AFD_PLUGIN_REPO_DIR
export INFERENCE_TOOLKIT_ROOT="$WORKSPACE_DIR"

log "目录约定：GREEN_ZONE_HOME=$GREEN_ZONE_HOME"
log "目录约定：AFD_ROOT=$AFD_ROOT"
log "目录约定：INFERENCE_TOOLKIT_ROOT=$WORKSPACE_DIR"
log "CodeHub 本地 IP：$CODEHUB_IP"

mkdir -p "$GREEN_ZONE_HOME"
if [[ -s "$OFFLINE_INSTALLER" && -r "$OFFLINE_INSTALLER" ]]; then
    log "Claude 离线安装包已存在，跳过 scp：$OFFLINE_INSTALLER"
else
    command -v scp >/dev/null 2>&1 || die "未找到 scp，无法获取 Claude 离线安装包"
    log "本地没有可用离线安装包，通过 scp 获取"
    log "离线安装包来源：$OFFLINE_INSTALLER_SOURCE"
    log "离线安装包目标：$OFFLINE_INSTALLER"
    if ! (
        cd "$GREEN_ZONE_HOME"
        scp -r "$OFFLINE_INSTALLER_SOURCE" ./
    ); then
        die "scp 离线安装包失败，停止安装"
    fi
    [[ -s "$OFFLINE_INSTALLER" && -r "$OFFLINE_INSTALLER" ]] \
        || die "scp 返回成功，但离线安装包不存在或为空：$OFFLINE_INSTALLER"
    log "Claude 离线安装包复制成功"
fi
chmod 700 "$OFFLINE_INSTALLER"

export PATH="/opt/node22/bin:${HOME}/.local/bin:${PATH}"
node_major=""
if command -v node >/dev/null 2>&1; then
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
fi

if [[ ! -s "$API_KEY_FILE" ]] || (( REFRESH_API_KEY )); then
    if [[ ! -t 0 ]]; then
        die "当前不是交互式终端，无法安全输入 API Key"
    fi
    mkdir -p "$(dirname "$API_KEY_FILE")"
    chmod 700 "$(dirname "$API_KEY_FILE")"
    API_KEY=""
    if ! IFS= read -r -s -p "请输入 API Key: " API_KEY; then
        printf '\n' >&2
        die "读取 API Key 失败"
    fi
    printf '\n'
    [[ -n "$API_KEY" ]] || die "API Key 不能为空"
    old_umask="$(umask)"
    umask 077
    printf '%s\n' "$API_KEY" > "$API_KEY_FILE"
    umask "$old_umask"
    unset API_KEY
    chmod 600 "$API_KEY_FILE"
    log "API Key 已安全保存：$API_KEY_FILE"
else
    chmod 600 "$API_KEY_FILE"
    log "API Key 文件已存在，直接复用：$API_KEY_FILE"
fi

KEY_MODE="$(stat -c '%a' "$API_KEY_FILE" 2>/dev/null || true)"
if [[ -n "$KEY_MODE" && "$KEY_MODE" != "600" && "$KEY_MODE" != "400" ]]; then
    warn "API Key 文件权限为 $KEY_MODE，建议执行：chmod 600 '$API_KEY_FILE'"
fi

source_proxy() {
    # 某些历史 proxy.sh 在 nounset 模式下会失败，加载时暂时关闭。
    set +u
    # shellcheck disable=SC1090
    source "$PROXY_SCRIPT"
    set -u
}

if [[ "$node_major" =~ ^[0-9]+$ ]] && (( node_major >= 22 )) \
    && command -v claude >/dev/null 2>&1; then
    log "Node.js v${node_major} 和 Claude Code 已安装，跳过离线安装"
else
    [[ -s "$OFFLINE_INSTALLER" && -r "$OFFLINE_INSTALLER" ]] \
        || die "离线安装脚本不可读：$OFFLINE_INSTALLER"
    log "执行 Node.js + Claude Code 离线安装"
    bash "$OFFLINE_INSTALLER" -y
    export PATH="/opt/node22/bin:${PATH}"
fi

command -v node >/dev/null 2>&1 || die "安装后仍找不到 node"
command -v claude >/dev/null 2>&1 || die "安装后仍找不到 claude"
node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
[[ "$node_major" =~ ^[0-9]+$ ]] && (( node_major >= 22 )) \
    || die "Node.js 版本必须 >= 22，当前为：$(node --version 2>/dev/null || echo unknown)"
claude_version="$(claude --version 2>&1)"
log "版本检查通过：Node $(node --version)，Claude ${claude_version%%$'\n'*}"

expose_command() {
    local command_name="$1"
    local source_path="$2"
    local target_path="/usr/local/bin/$command_name"

    [[ -x "$source_path" ]] || die "命令不可执行：$source_path"
    mkdir -p /usr/local/bin
    if [[ "$source_path" == "$target_path" ]]; then
        return
    elif [[ -L "$target_path" ]]; then
        ln -sfn "$source_path" "$target_path"
    elif [[ -e "$target_path" ]]; then
        warn "保留已有命令，不覆盖：$target_path"
        return
    else
        ln -s "$source_path" "$target_path"
    fi
    log "命令已加入当前 Shell 可见路径：$target_path -> $source_path"
}

expose_command node "$(command -v node)"
expose_command claude "$(command -v claude)"

if [[ -n "$BASE_URL" ]]; then
    log "合并 Claude settings，并配置自定义 ANTHROPIC_BASE_URL（不会输出 API Key）"
else
    log "合并 Claude settings；未传 --base-url，保留已有 Base URL 配置（不会输出 API Key）"
fi
log "API Key 将同时写入 ANTHROPIC_AUTH_TOKEN 和 ANTHROPIC_API_KEY"
python3 - \
    "$SETTINGS_PATH" \
    "$API_KEY_FILE" \
    "$BASE_URL" \
    "$DEFAULT_CLAUDE_MODEL" <<'PY'
import json
import os
import pathlib
import shutil
import sys
import tempfile
import time

settings_path = pathlib.Path(sys.argv[1])
key_path = pathlib.Path(sys.argv[2])
base_url = sys.argv[3].strip()
default_model = sys.argv[4]
token = key_path.read_text(encoding="utf-8").strip()
if not token:
    raise SystemExit(f"API Key 文件为空：{key_path}")
if "\n" in token or "\r" in token:
    raise SystemExit("API Key 文件必须只包含一行 Key")

settings_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)

if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"现有 settings.json 不是有效 JSON，已停止以免覆盖：{exc}")
    if not isinstance(settings, dict):
        raise SystemExit("现有 settings.json 顶层必须是 JSON object，已停止以免覆盖")
    backup = settings_path.with_name(
        f"{settings_path.name}.bak.{time.strftime('%Y%m%d%H%M%S')}.{os.getpid()}"
    )
    shutil.copy2(settings_path, backup)
    os.chmod(backup, 0o600)
else:
    settings = {}

env = settings.setdefault("env", {})
if not isinstance(env, dict):
    raise SystemExit('现有 settings.json 的 "env" 必须是 JSON object，已停止以免覆盖')
if base_url:
    env["ANTHROPIC_BASE_URL"] = base_url
env["ANTHROPIC_AUTH_TOKEN"] = token
env["ANTHROPIC_API_KEY"] = token

# 只替换离线包的 GLM-5.2 默认值。用户已经设置成其他模型时，不覆盖。
model_keys = (
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
)
updated_model_keys = []
preserved_model_keys = []
legacy_default_models = {"GLM-5.2", "GLM-5.2[1M]"}
for key in model_keys:
    current = env.get(key)
    replace = current is None
    if isinstance(current, str):
        normalized = current.strip().upper()
        replace = not normalized or normalized in legacy_default_models
    if replace:
        env[key] = default_model
        updated_model_keys.append(key)
    else:
        preserved_model_keys.append(key)

fd, temp_name = tempfile.mkstemp(prefix=".settings.", suffix=".json", dir=settings_path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(settings, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(temp_name, 0o600)
    os.replace(temp_name, settings_path)
finally:
    if os.path.exists(temp_name):
        os.unlink(temp_name)

if updated_model_keys:
    print(
        f"[GreenAgent] Claude 默认模型已设为 {default_model}："
        + ", ".join(updated_model_keys)
    )
if preserved_model_keys:
    print(
        "[GreenAgent] 以下模型项已有非默认配置，保持不变："
        + ", ".join(preserved_model_keys)
    )
PY

log "写入持久化 PATH 配置"
python3 - \
    "${HOME}/.bashrc" \
    "$GREEN_ZONE_HOME" \
    "$AFD_ROOT" \
    "$VLLM_REPO_DIR" \
    "$VLLM_ASCEND_REPO_DIR" \
    "$AFD_PLUGIN_REPO_DIR" \
    "$WORKSPACE_DIR" <<'PY'
import pathlib
import shlex
import sys

path = pathlib.Path(sys.argv[1])
green_home, afd_root, vllm_repo, vllm_ascend_repo, afd_plugin_repo, toolkit_root = (
    shlex.quote(value) for value in sys.argv[2:]
)
begin = "# >>> green-zone-agent >>>"
end = "# <<< green-zone-agent <<<"
block = f'''{begin}
export PATH="/opt/node22/bin:$HOME/.local/bin:$PATH"
export GREEN_ZONE_HOME={green_home}
export AFD_ROOT={afd_root}
export VLLM_REPO_DIR={vllm_repo}
export VLLM_ASCEND_REPO_DIR={vllm_ascend_repo}
export AFD_PLUGIN_REPO_DIR={afd_plugin_repo}
export INFERENCE_TOOLKIT_ROOT={toolkit_root}
{end}'''
text = path.read_text(encoding="utf-8") if path.exists() else ""
if begin in text and end in text:
    before, rest = text.split(begin, 1)
    _, after = rest.split(end, 1)
    text = before.rstrip("\n") + "\n\n" + block + after
else:
    text = text.rstrip("\n") + "\n\n" + block + "\n"
path.write_text(text, encoding="utf-8")
PY

if (( SKIP_HOSTS )); then
    log "按参数跳过 /etc/hosts 配置"
else
    log "配置 /etc/hosts：$CODEHUB_IP szv-open.codehub.huawei.com（需要 root/sudo）"
    HOSTS_RUNNER=(python3)
    if [[ "${EUID}" -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || die "修改 /etc/hosts 需要 root 或 sudo"
        HOSTS_RUNNER=(sudo python3)
    fi
    "${HOSTS_RUNNER[@]}" - "$CODEHUB_IP" <<'PY'
import os
import pathlib
import shutil
import sys
import time

hosts_path = pathlib.Path("/etc/hosts")
mapping = {
    "computing.huawei.com": "141.3.1.75",
    "szv-open.codehub.huawei.com": sys.argv[1],
}
original = hosts_path.read_text(encoding="utf-8")
result = []
managed_comment = "# Managed by deploy_green_zone_agent.sh"

for raw_line in original.splitlines():
    stripped = raw_line.strip()
    if stripped == managed_comment:
        continue
    if not stripped or stripped.startswith("#"):
        result.append(raw_line)
        continue
    data, marker, comment = raw_line.partition("#")
    fields = data.split()
    if len(fields) < 2:
        result.append(raw_line)
        continue
    ip, aliases = fields[0], fields[1:]
    kept = [name for name in aliases if name not in mapping]
    if kept:
        rebuilt = f"{ip} {' '.join(kept)}"
        if marker:
            rebuilt += f"  # {comment.strip()}"
        result.append(rebuilt)

result.append(managed_comment)
for hostname, ip in mapping.items():
    result.append(f"{ip} {hostname}")

backup = hosts_path.with_name(
    f"hosts.bak.green-agent.{time.strftime('%Y%m%d%H%M%S')}.{os.getpid()}"
)
shutil.copy2(hosts_path, backup)
hosts_path.write_text("\n".join(result) + "\n", encoding="utf-8")
print(f"[GreenAgent] /etc/hosts 备份：{backup}")
PY
fi

log "生成安全启动入口：${HOME}/.local/bin/claude-green"
mkdir -p "${HOME}/.local/bin"
python3 - \
    "${HOME}/.local/bin/claude-green" \
    "$PROXY_SCRIPT" \
    "$GREEN_ZONE_HOME" \
    "$AFD_ROOT" \
    "$VLLM_REPO_DIR" \
    "$VLLM_ASCEND_REPO_DIR" \
    "$AFD_PLUGIN_REPO_DIR" \
    "$WORKSPACE_DIR" <<'PY'
import os
import pathlib
import shlex
import sys

target = pathlib.Path(sys.argv[1])
proxy_script = shlex.quote(sys.argv[2])
green_home, afd_root, vllm_repo, vllm_ascend_repo, afd_plugin_repo, toolkit_root = (
    shlex.quote(value) for value in sys.argv[3:]
)
content = f'''#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/node22/bin:$PATH"
export GREEN_ZONE_HOME={green_home}
export AFD_ROOT={afd_root}
export VLLM_REPO_DIR={vllm_repo}
export VLLM_ASCEND_REPO_DIR={vllm_ascend_repo}
export AFD_PLUGIN_REPO_DIR={afd_plugin_repo}
export INFERENCE_TOOLKIT_ROOT={toolkit_root}
set +u
# shellcheck disable=SC1090
source {proxy_script}
set -u

if [[ "${{1:-}}" == "--dangerous" ]]; then
    shift
    exec env NODE_TLS_REJECT_UNAUTHORIZED=0 IS_SANDBOX=1 \\
        claude --dangerously-skip-permissions "$@"
fi

exec env NODE_TLS_REJECT_UNAUTHORIZED=0 IS_SANDBOX=1 claude "$@"
'''
target.write_text(content, encoding="utf-8")
os.chmod(target, 0o755)
PY
expose_command claude-green "${HOME}/.local/bin/claude-green"

if (( SKIP_TOOLKIT )); then
    log "按参数跳过 inference-toolkit 部署"
else
    source_proxy
    if [[ -d "$WORKSPACE_DIR/.git" ]]; then
        log "inference-toolkit 已存在：$WORKSPACE_DIR"
        if (( UPDATE_TOOLKIT )); then
            log "更新 inference-toolkit（git pull --ff-only）"
            git -C "$WORKSPACE_DIR" pull --ff-only
        fi
    elif [[ -e "$WORKSPACE_DIR" || -L "$WORKSPACE_DIR" ]]; then
        TOOLKIT_TIMESTAMP="$(date +%Y%m%d%H%M%S).$$"
        TOOLKIT_BACKUP="${WORKSPACE_DIR}.bak.${TOOLKIT_TIMESTAMP}"
        TOOLKIT_CLONE="${WORKSPACE_DIR}.clone.${TOOLKIT_TIMESTAMP}"
        warn "工作目录已存在但不是 Git 仓库，将先 clone 新仓库并备份旧目录"
        log "临时 clone 目录：$TOOLKIT_CLONE"
        git clone "$REPO_URL" "$TOOLKIT_CLONE"
        mv "$WORKSPACE_DIR" "$TOOLKIT_BACKUP"
        mv "$TOOLKIT_CLONE" "$WORKSPACE_DIR"
        log "旧 inference-toolkit 已完整备份：$TOOLKIT_BACKUP"
        log "新 inference-toolkit 已就绪：$WORKSPACE_DIR"
    else
        log "clone inference-toolkit"
        git clone "$REPO_URL" "$WORKSPACE_DIR"
    fi

    INIT_SCRIPT="$WORKSPACE_DIR/engineering-context/scripts/init_workspace.py"
    VALIDATE_SCRIPT="$WORKSPACE_DIR/engineering-context/scripts/validate_context.py"
    [[ -f "$INIT_SCRIPT" ]] || die "找不到 init_workspace.py：$INIT_SCRIPT"

    REAL_ENV_TARGET="$WORKSPACE_DIR/validation/real-machine/env/env.yaml"
    SIMULATION_ENV_TARGET="$WORKSPACE_DIR/validation/simulation/env/env.yaml"
    if [[ ! -f "$REAL_ENV_TARGET" || ! -f "$SIMULATION_ENV_TARGET" ]]; then
        log "初始化 inference-toolkit 工作区"
        (
            cd "$WORKSPACE_DIR"
            python3 engineering-context/scripts/init_workspace.py --workspace .
        )
    else
        log "工作区 env.yaml 已存在，跳过 init_workspace.py，避免覆盖本机配置"
    fi

    install_env_file() {
        local source_file="$1"
        local target_file="$2"
        local label="$3"
        local backup_file=""
        mkdir -p "$(dirname "$target_file")"
        if [[ -f "$target_file" ]]; then
            backup_file="${target_file}.bak.$(date +%Y%m%d%H%M%S)"
            cp -p "$target_file" "$backup_file"
            log "$label env 原文件已备份：$backup_file"
        fi
        cp "$source_file" "$target_file"
        log "$label env 已写入：$target_file"
    }

    if [[ -n "$REAL_ENV_FILE" ]]; then
        install_env_file "$REAL_ENV_FILE" "$REAL_ENV_TARGET" "真机"
    else
        log "真机 env 请按本机填写：$REAL_ENV_TARGET"
    fi
    if [[ -n "$SIMULATION_ENV_FILE" ]]; then
        install_env_file "$SIMULATION_ENV_FILE" "$SIMULATION_ENV_TARGET" "仿真"
    else
        log "仿真 env 请按本机填写：$SIMULATION_ENV_TARGET"
    fi

    log "链接 inference-toolkit skills 到 ~/.claude/skills"
    mkdir -p "${HOME}/.claude/skills"
    shopt -s nullglob
    for skill_path in "$WORKSPACE_DIR"/skills/*; do
        skill_name="$(basename "$skill_path")"
        link_path="${HOME}/.claude/skills/${skill_name}"
        if [[ -L "$link_path" || ! -e "$link_path" ]]; then
            ln -sfn "$skill_path" "$link_path"
        else
            warn "skill 目标已存在且不是软链，保留原目录：$link_path"
        fi
    done
    shopt -u nullglob

    if (( SKIP_VALIDATION )); then
        log "按参数跳过 validate_context.py"
    else
        [[ -f "$VALIDATE_SCRIPT" ]] || die "找不到 validate_context.py：$VALIDATE_SCRIPT"
        log "运行 inference-toolkit 自检"
        (
            cd "$WORKSPACE_DIR"
            python3 engineering-context/scripts/validate_context.py
        )
    fi
fi

cat <<EOF

[GreenAgent] 部署完成。
[GreenAgent] Claude settings：$SETTINGS_PATH
[GreenAgent] API Key 文件：$API_KEY_FILE
[GreenAgent] Claude 默认模型：$DEFAULT_CLAUDE_MODEL（已有非默认配置不会覆盖）
[GreenAgent] 绿区持久化目录：$GREEN_ZONE_HOME
[GreenAgent] AFD 根目录：$AFD_ROOT
[GreenAgent] vLLM：$VLLM_REPO_DIR
[GreenAgent] vLLM-Ascend：$VLLM_ASCEND_REPO_DIR
[GreenAgent] AFD plugin：$AFD_PLUGIN_REPO_DIR
[GreenAgent] CodeHub 本地 IP：$CODEHUB_IP
[GreenAgent] 普通启动：claude-green
[GreenAgent] 自动执行模式：claude-green --dangerous
[GreenAgent] 注意：--dangerous 会跳过工具权限确认，只在可信目录中使用。
EOF

if (( ! SKIP_TOOLKIT )); then
    printf '[GreenAgent] inference-toolkit：%s\n' "$WORKSPACE_DIR"
fi
