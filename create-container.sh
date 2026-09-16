#!/usr/bin/env bash
#
# =============================================================================
# create-container.sh
#
# 用法：
#
#   bash create-container.sh <IMAGE> <CONTAINER_NAME>
#
# 示例：
#
#   bash create-container.sh \
#       vllm-ascend:dev-26.1.0.day20260817-A5-py311-openEuler24.03-lts-aarch64 \
#       my-vllm
#
#
# Host 侧：
#   1. 创建 /home/s00988495
#   2. 创建 /home/s00988495/proxy.sh
#   3. source proxy.sh
#   4. 创建 / 启动 Docker 容器
#   5. 调用本脚本的 container 模式
#
# Container 侧：
#   1. source /home/s00988495/proxy.sh
#   2. 配置 pip 阿里云源
#   3. 配置 git proxy
#   4. 关闭 git SSL verify
#   5. 配置 /root/.bashrc
#   6. 设置 alias:
#        glog='git log --oneline -5'
#   7. 自动 cd /home/s00988495
#   8. 进入交互式 bash
#
# 本脚本不负责：
#   - clone vLLM
#   - clone vLLM-Ascend
#   - clone afd-plugin
#   - 编译上述仓库
#
# =============================================================================

set -euo pipefail


# =============================================================================
# 全局配置
# =============================================================================

USER_HOME="/home/s00988495"
PROXY_FILE="${USER_HOME}/proxy.sh"
SCRIPT_PATH="${USER_HOME}/create-container.sh"


# =============================================================================
# Container 模式
# =============================================================================

if [[ "${1:-}" == "--inside-container" ]]; then

    echo
    echo "==================================================================="
    echo "[INFO] Running container-side initialization"
    echo "==================================================================="
    echo


    # =========================================================================
    # 1. 创建工作目录
    # =========================================================================

    mkdir -p "$USER_HOME"


    # =========================================================================
    # 2. 检查 proxy.sh
    # =========================================================================

    if [[ ! -f "$PROXY_FILE" ]]; then
        echo "[ERROR] Proxy file not found:"
        echo "        $PROXY_FILE"
        exit 1
    fi


    # =========================================================================
    # 3. 加载 proxy
    # =========================================================================

    echo "[INFO] Loading proxy..."

    # shellcheck disable=SC1090
    source "$PROXY_FILE"

    echo "[INFO] ip_addr=$ip_addr"


    # =========================================================================
    # 4. 配置 pip 代理
    # =========================================================================

    echo
    echo "[INFO] Configuring pip mirror..."

    pip3 config set \
        global.index-url \
        "http://mirrors.aliyun.com/pypi/simple/"

    pip3 config set \
        global.trusted-host \
        "mirrors.aliyun.com"


    # =========================================================================
    # 5. 配置 git 代理
    # =========================================================================

    echo
    echo "[INFO] Configuring git proxy..."

    git config --global \
        http.proxy \
        "http://p_atlas:proxy%40123@${ip_addr}:8080"

    git config --global \
        https.proxy \
        "http://p_atlas:proxy%40123@${ip_addr}:8080"

    git config --global \
        http.sslVerify \
        false

    export GIT_SSL_NO_VERIFY=1


    # =========================================================================
    # 6. 配置 /root/.bashrc
    # =========================================================================

    BASHRC="/root/.bashrc"

    START_MARKER="# >>> s00988495-env >>>"
    END_MARKER="# <<< s00988495-env <<<"


    # -------------------------------------------------------------------------
    # 删除旧配置块，防止重复追加
    # -------------------------------------------------------------------------

    if grep -Fq "$START_MARKER" "$BASHRC" 2>/dev/null; then

        echo
        echo "[INFO] Removing old shell configuration..."

        sed -i \
            '/^# >>> s00988495-env >>>$/,/^# <<< s00988495-env <<<$/{d;}' \
            "$BASHRC"

    fi


    # -------------------------------------------------------------------------
    # 写入新的 shell 配置
    # -------------------------------------------------------------------------

    echo "[INFO] Writing /root/.bashrc configuration..."

    cat >> "$BASHRC" <<'EOF'

# >>> s00988495-env >>>

# ============================================================================
# Proxy
# ============================================================================

if [[ -f /home/s00988495/proxy.sh ]]; then
    source /home/s00988495/proxy.sh
fi

export GIT_SSL_NO_VERIFY=1


# ============================================================================
# Git aliases
# ============================================================================

alias glog='git log --oneline -5'


# ============================================================================
# Default working directory
# ============================================================================

if [[ -d /home/s00988495 ]]; then
    cd /home/s00988495
fi


# <<< s00988495-env <<<

EOF


    # =========================================================================
    # 7. 当前 shell 立即生效
    # =========================================================================

    alias glog='git log --oneline -5'

    export GIT_SSL_NO_VERIFY=1

    cd "$USER_HOME"


    # =========================================================================
    # 8. 打印当前环境
    # =========================================================================

    echo
    echo "==================================================================="
    echo "[INFO] Container environment initialized"
    echo "==================================================================="
    echo

    echo "Workdir:"
    echo "  $USER_HOME"

    echo
    echo "Proxy IP:"
    echo "  ip_addr=$ip_addr"

    echo
    echo "pip index:"
    pip3 config get global.index-url || true

    echo
    echo "pip trusted-host:"
    pip3 config get global.trusted-host || true

    echo
    echo "git http.proxy:"
    git config --global --get http.proxy || true

    echo
    echo "git https.proxy:"
    git config --global --get https.proxy || true

    echo
    echo "git http.sslVerify:"
    git config --global --get http.sslVerify || true

    echo
    echo "GIT_SSL_NO_VERIFY:"
    echo "  $GIT_SSL_NO_VERIFY"

    echo
    echo "Git alias:"
    echo "  glog='git log --oneline -5'"

    echo
    echo "Current directory:"
    pwd

    echo
    echo "==================================================================="
    echo


    # =========================================================================
    # 9. 进入交互式 bash
    # =========================================================================

    exec bash -i

fi


# =============================================================================
#
# Host 模式
#
# =============================================================================


# =============================================================================
# 1. 参数检查
# =============================================================================

if [[ $# -ne 2 ]]; then

    echo
    echo "Usage:"
    echo
    echo "  bash $0 <IMAGE> <CONTAINER_NAME>"
    echo

    echo "Example:"
    echo
    echo "  bash $0 \\"
    echo "      vllm-ascend:dev-26.1.0.day20260817-A5-py311-openEuler24.03-lts-aarch64 \\"
    echo "      my-vllm"
    echo

    exit 2
fi


IMAGE="$1"
CONTAINER_NAME="$2"


echo
echo "==================================================================="
echo "[INFO] Running host-side initialization"
echo "==================================================================="
echo

echo "Image:"
echo "  $IMAGE"

echo
echo "Container:"
echo "  $CONTAINER_NAME"

echo


# =============================================================================
# 2. 创建 /home/s00988495
# =============================================================================

if [[ ! -d "$USER_HOME" ]]; then

    echo "[INFO] Creating directory:"
    echo "       $USER_HOME"

    mkdir -p "$USER_HOME"

else

    echo "[INFO] Directory already exists:"
    echo "       $USER_HOME"

fi


# =============================================================================
# 3. 创建 proxy.sh
# =============================================================================
#
# 已存在则不覆盖。
#
# proxy.sh 内容：
#
#   ip_addr
#   http_proxy
#   https_proxy
#   no_proxy
#   GIT_SSL_NO_VERIFY
#
# =============================================================================

if [[ ! -f "$PROXY_FILE" ]]; then

    echo
    echo "[INFO] Creating proxy file:"
    echo "       $PROXY_FILE"

    cat > "$PROXY_FILE" <<'EOF'
#!/usr/bin/env bash

export ip_addr=141.2.250.30

export http_proxy="http://p_atlas:proxy%40123@$ip_addr:8080"
export https_proxy="$http_proxy"

export no_proxy="127.0.0.1,localhost,local,.local"

export GIT_SSL_NO_VERIFY=1
EOF

    chmod 600 "$PROXY_FILE"

    echo "[INFO] Proxy file created."

else

    echo
    echo "[INFO] Proxy file already exists:"
    echo "       $PROXY_FILE"

    echo "[INFO] Skip creation."

fi


# =============================================================================
# 4. Host 当前脚本加载 proxy
# =============================================================================

echo
echo "[INFO] Loading proxy on host..."

# shellcheck disable=SC1090
source "$PROXY_FILE"

export GIT_SSL_NO_VERIFY=1

echo "[INFO] ip_addr=$ip_addr"


# =============================================================================
# 5. 将当前脚本复制到 /home/s00988495
# =============================================================================
#
# 后面通过：
#
#   --volume=/home:/home
#
# 所以：
#
# Host:
#   /home/s00988495/create-container.sh
#
# Container:
#   /home/s00988495/create-container.sh
#
# 对应同一个文件。
#
# =============================================================================

CURRENT_SCRIPT="$(readlink -f "$0")"


if [[ "$CURRENT_SCRIPT" != "$SCRIPT_PATH" ]]; then

    echo
    echo "[INFO] Copying script to:"
    echo "       $SCRIPT_PATH"

    cp "$CURRENT_SCRIPT" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

else

    chmod +x "$SCRIPT_PATH"

fi


# =============================================================================
# 6. 检查 Docker
# =============================================================================

if ! command -v docker >/dev/null 2>&1; then

    echo
    echo "[ERROR] docker is not installed or not in PATH."

    exit 1

fi


# =============================================================================
# 7. 检查镜像
# =============================================================================

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then

    echo
    echo "[ERROR] Docker image does not exist:"
    echo "        $IMAGE"

    echo
    echo "Please pull or load the image first."

    exit 1

fi


# =============================================================================
# 8. 创建 / 启动容器
# =============================================================================

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then

    echo
    echo "[INFO] Container already exists:"
    echo "       $CONTAINER_NAME"


    RUNNING="$(
        docker inspect \
            -f '{{.State.Running}}' \
            "$CONTAINER_NAME"
    )"


    if [[ "$RUNNING" == "true" ]]; then

        echo "[INFO] Container is already running."
        echo "[INFO] Skip docker run."

    else

        echo "[INFO] Container is stopped."
        echo "[INFO] Starting container..."

        docker start "$CONTAINER_NAME" >/dev/null

        echo "[INFO] Container started."

    fi

else

    echo
    echo "[INFO] Creating container:"
    echo "       $CONTAINER_NAME"
    echo


    docker run \
        --name "$CONTAINER_NAME" \
        --runtime=runc \
        --user root \
        --interactive \
        --tty \
        --detach \
        --net=host \
        --pid=host \
        --privileged=true \
        --shm-size=2g \
        \
        --device=/dev/davinci_manager \
        --device=/dev/hisi_hdc \
        --device=/dev/ummu \
        --device=/dev/uburma \
        \
        --device=/dev/davinci0 \
        --device=/dev/davinci1 \
        --device=/dev/davinci2 \
        --device=/dev/davinci3 \
        --device=/dev/davinci4 \
        --device=/dev/davinci5 \
        --device=/dev/davinci6 \
        --device=/dev/davinci7 \
        \
        --volume=/usr/local/Ascend/driver:/usr/local/Ascend/driver \
        --volume=/usr/local/Ascend/firmware:/usr/local/Ascend/firmware \
        \
        --volume=/root/host:/root/host \
        \
        --volume=/usr/local/sbin/npu-smi:/usr/local/sbin/npu-smi \
        --volume=/usr/local/sbin:/usr/local/sbin \
        --volume=/usr/local/dcmi:/usr/local/dcmi \
        \
        --volume=/var/log/npu:/usr/slog \
        \
        --volume=/mnt:/mnt \
        --volume=/data:/data \
        --volume=/home:/home \
        \
        --volume=/etc/hccl_rootinfo.json:/etc/hccl_rootinfo.json \
        --volume=/etc/hccl_topo.json:/etc/hccl_topo.json \
        \
        --volume=/etc/hixlep:/etc/hixlep \
        \
        --volume=/usr/lib64:/usr/lib64 \
        \
        "$IMAGE" \
        bash


    echo
    echo "[INFO] Container created successfully."

fi


# =============================================================================
# 9. 打印容器状态
# =============================================================================

echo
echo "[INFO] Container status:"

docker ps \
    --filter "name=^/${CONTAINER_NAME}$" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"


# =============================================================================
# 10. 进入 Container 模式
# =============================================================================

echo
echo "==================================================================="
echo "[INFO] Entering container: $CONTAINER_NAME"
echo "[INFO] Proxy IP: ip_addr=$ip_addr"
echo "==================================================================="
echo


exec docker exec \
    --user root \
    -it \
    "$CONTAINER_NAME" \
    bash "$SCRIPT_PATH" --inside-container