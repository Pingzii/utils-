#!/usr/bin/env bash
#
# =============================================================================
# afd_build_all.sh
#
# A5 / Ascend950 AFD 推理栈一键构建脚本
#
# 前提：
#   1. 已经进入 Docker 容器
#   2. proxy 已经在进入容器时自动 source
#   3. pip / git proxy 已经配置完成
#   4. 基础镜像已经包含可用的 torch / torch_npu
#
#
# 仓库策略：
#
#   vLLM
#     repo:
#       https://github.com/vllm-project/vllm.git
#
#     ref:
#       v0.26.0
#
#     特殊处理：
#       只获取 v0.26.0
#       depth = 1
#
#
#   vLLM-Ascend
#     repo:
#       https://github.com/vllm-project/vllm-ascend.git
#
#     commit:
#       80d8c194f
#
#     处理：
#       正常 git clone 整个仓库
#       checkout 80d8c194f
#
#
#   afd-plugin
#     repo:
#       https://github.com/Pingzii/afd-plugin.git
#
#     branch:
#       main
#
#     处理：
#       正常 git clone 整个仓库
#       checkout main
#
#
# 编译顺序：
#
#   clone / checkout
#        ↓
#   vLLM empty
#        ↓
#   vLLM-Ascend
#        ↓
#   afd-plugin
#        ↓
#   完整验证
#
#
# 普通执行：
#
#   bash afd_build_all.sh
#
#
# 强制从零重新 clone + build：
#
#   bash afd_build_all.sh --force
#
#
# 本脚本不会：
#
#   - source proxy.sh
#   - 创建 Docker
#   - 修改 Docker 配置
#   - 应用 patch
#
# =============================================================================

set -euo pipefail


# =============================================================================
# 0. 参数
# =============================================================================

FORCE=0

for arg in "$@"; do
    case "$arg" in
        --force|-f)
            FORCE=1
            ;;

        *)
            echo "[ERROR] Unknown argument: $arg"
            echo
            echo "Usage:"
            echo "  bash $0"
            echo "  bash $0 --force"
            exit 2
            ;;
    esac
done


# =============================================================================
# 1. 全局配置
# =============================================================================

# -----------------------------------------------------------------------------
# AFD 根目录
#
# 最终目录结构：
#
# /home/s00988495/AFD/
#
# ├── vllm/
# ├── vllm-ascend/
# ├── afd-plugin/
#
# ├── logs/
# │   └── afd_build_all.log
#
# └── .build_stamps/
#     ├── vllm
#     ├── vllm-ascend
#     └── afd-plugin
#
# -----------------------------------------------------------------------------

ROOT="${AFD_ROOT:-/home/s00988495/AFD}"


# -----------------------------------------------------------------------------
# LOG
#
# 用于记录：
#
#   “整个构建过程中发生了什么”
#
# 包括：
#
#   git clone
#   git fetch
#   git checkout
#   pip install
#   编译输出
#   Python import
#   ERROR
#
# 所有输出：
#
#   1. 正常显示在终端
#   2. 同时写入：
#
#      /home/s00988495/AFD/logs/afd_build_all.log
#
# -----------------------------------------------------------------------------

LOG_DIR="${ROOT}/logs"

LOG="${LOG_DIR}/afd_build_all.log"


# -----------------------------------------------------------------------------
# Build Stamp
#
# .build_stamps 不是 Git 自带功能，
# 是这个脚本自己维护的“成功编译记录”。
#
# 例如：
#
#   .build_stamps/vllm-ascend
#
# 里面保存：
#
#   上一次成功 build 时对应仓库的 Git HEAD
#
#
# 下一次执行：
#
#   当前 HEAD == stamp
#
#       ↓
#
#   说明该源码版本已经成功 build
#
#       ↓
#
#   跳过 build
#
#
# 如果：
#
#   当前 HEAD != stamp
#
#       ↓
#
#   源码发生变化
#
#       ↓
#
#   重新 build
#
#
# 所以：
#
#   LOG
#     = 构建过程记录
#
#   STAMP_DIR
#     = 已成功编译版本记录
#
# -----------------------------------------------------------------------------

STAMP_DIR="${ROOT}/.build_stamps"


# =============================================================================
# 2. 仓库版本
# =============================================================================

# -----------------------------------------------------------------------------
# vLLM
#
# 只获取 v0.26.0，depth=1。
# -----------------------------------------------------------------------------

VLLM_URL="https://github.com/vllm-project/vllm.git"

VLLM_REF="v0.26.0"


# -----------------------------------------------------------------------------
# vLLM-Ascend
#
# 正常完整 clone，然后 checkout 固定 commit。
# -----------------------------------------------------------------------------

VLLM_ASCEND_URL="https://github.com/vllm-project/vllm-ascend.git"

VLLM_ASCEND_COMMIT="80d8c194f"


# -----------------------------------------------------------------------------
# afd-plugin
#
# 正常完整 clone，使用 main。
# -----------------------------------------------------------------------------

AFD_PLUGIN_URL="https://github.com/Pingzii/afd-plugin.git"

AFD_PLUGIN_BRANCH="main"


# =============================================================================
# 3. 创建目录
# =============================================================================

mkdir -p \
    "$ROOT" \
    "$LOG_DIR" \
    "$STAMP_DIR"


# =============================================================================
# 4. 日志
#
# tee -a：
#
#   输出显示到终端
#       +
#   追加写入日志
#
# 2>&1：
#
#   stderr 合并到 stdout
#
# =============================================================================

exec > >(tee -a "$LOG") 2>&1


step()
{
    echo
    echo "==================================================================="
    echo ">>> $1"
    echo "==================================================================="
    echo
}


# =============================================================================
# 5. 基础环境检查
# =============================================================================

step "0/5 检查基础环境"


if ! command -v git >/dev/null 2>&1; then
    echo "[ERROR] git not found."
    exit 1
fi


if ! command -v python3 >/dev/null 2>&1; then
    echo "[ERROR] python3 not found."
    exit 1
fi


echo "[env] Python:"
python3 --version


echo
echo "[env] pip:"
python3 -m pip --version


echo
echo "[env] git:"
git --version


echo
echo "[env] pip index:"
python3 -m pip config get \
    global.index-url \
    2>/dev/null || true


echo
echo "[env] git http.proxy:"
git config --global \
    --get http.proxy \
    2>/dev/null || true


# =============================================================================
# 6. torch / torch_npu 检查
# =============================================================================

echo
echo "[env] Checking torch / torch_npu..."


python3 - <<'PY'
import torch
import torch_npu

print("torch     =", torch.__version__)
print("torch_npu =", torch_npu.__version__)

if not hasattr(torch, "npu"):
    raise RuntimeError("torch.npu is unavailable")

count = torch.npu.device_count()

print("NPU count =", count)

if count <= 0:
    raise RuntimeError("No NPU detected")

print("NPU 0     =", torch.npu.get_device_name(0))
PY


# =============================================================================
# 7. SOC_VERSION 探测
#
# 例如：
#
#   Ascend950PR_957d
#
# 转换为：
#
#   ascend950pr_957d
#
# =============================================================================

detect_soc()
{
    python3 - <<'PY'
import re
import torch
import torch_npu

name = torch.npu.get_device_name(0)

m = re.match(r"(Ascend\w+)_(\w+)", name)

if m:
    print((m.group(1) + "_" + m.group(2)).lower())
else:
    print("ascend950")
PY
}


SOC_VERSION="${SOC_VERSION:-$(detect_soc)}"


echo
echo "[env] SOC_VERSION=$SOC_VERSION"


# =============================================================================
# 8. Clone vLLM
#
# vLLM 仓库较大，所以特殊处理：
#
#   只获取：
#
#       v0.26.0
#
#   depth：
#
#       1
#
#
# 实际命令：
#
#   git clone
#       --branch v0.26.0
#       --single-branch
#       --depth 1
#
#
# 注意：
#
# v0.26.0 是 tag，
# 但 git clone --branch 同样支持指定 tag。
#
# =============================================================================

clone_vllm()
{
    local dir="$ROOT/vllm"


    echo
    echo "-------------------------------------------------------------------"
    echo "[repo] vllm"
    echo "[repo] URL   : $VLLM_URL"
    echo "[repo] ref   : $VLLM_REF"
    echo "[repo] depth : 1"
    echo "-------------------------------------------------------------------"


    # -------------------------------------------------------------------------
    # --force
    # -------------------------------------------------------------------------

    if [[ "$FORCE" -eq 1 && -d "$dir" ]]; then

        echo "[clone] --force: removing old vllm"
        echo "        $dir"

        rm -rf "$dir"

    fi


    # -------------------------------------------------------------------------
    # 第一次 clone
    # -------------------------------------------------------------------------

    if [[ ! -d "$dir/.git" ]]; then

        echo
        echo "[clone] vLLM uses shallow clone."
        echo "[clone] Only downloading:"
        echo "        ref   = $VLLM_REF"
        echo "        depth = 1"
        echo
        echo "[clone] Full vLLM Git history will NOT be downloaded."
        echo


        git clone \
            --branch "$VLLM_REF" \
            --single-branch \
            --depth 1 \
            "$VLLM_URL" \
            "$dir"


    else

        echo
        echo "[clone] vLLM already exists."
        echo "[clone] Skip clone."


        # 如果之前已有仓库但 tag 不存在，
        # 只 fetch 需要的 tag。
        if ! git -C "$dir" \
            rev-parse \
            "$VLLM_REF^{commit}" \
            >/dev/null 2>&1; then

            echo
            echo "[git] $VLLM_REF not found locally."
            echo "[git] Fetching only specified ref with depth=1."


            git -C "$dir" fetch \
                --depth 1 \
                origin \
                "refs/tags/$VLLM_REF:refs/tags/$VLLM_REF"

        fi

    fi


    # -------------------------------------------------------------------------
    # 固定版本构建：
    #
    # detached HEAD 到指定 tag。
    # -------------------------------------------------------------------------

    git -C "$dir" checkout \
        --detach \
        "$VLLM_REF"


    echo
    echo "[git] vLLM HEAD:"

    git -C "$dir" log \
        --oneline \
        -1


    echo
    echo "[git] shallow repository:"

    git -C "$dir" rev-parse \
        --is-shallow-repository


    echo
}


# =============================================================================
# 9. Clone vLLM-Ascend
#
# vLLM-Ascend：
#
#   正常 git clone
#
# 不使用：
#
#   --depth
#   --single-branch
#
#
# 即下载正常完整 Git 仓库。
#
# clone 完以后：
#
#   checkout --detach 80d8c194f
#
# =============================================================================

clone_vllm_ascend()
{
    local dir="$ROOT/vllm-ascend"


    echo
    echo "-------------------------------------------------------------------"
    echo "[repo] vllm-ascend"
    echo "[repo] URL    : $VLLM_ASCEND_URL"
    echo "[repo] commit : $VLLM_ASCEND_COMMIT"
    echo "[repo] clone  : normal full git clone"
    echo "-------------------------------------------------------------------"


    # -------------------------------------------------------------------------
    # --force
    # -------------------------------------------------------------------------

    if [[ "$FORCE" -eq 1 && -d "$dir" ]]; then

        echo "[clone] --force: removing old vllm-ascend"
        echo "        $dir"

        rm -rf "$dir"

    fi


    # -------------------------------------------------------------------------
    # 第一次：
    #
    # 正常完整 clone。
    # -------------------------------------------------------------------------

    if [[ ! -d "$dir/.git" ]]; then

        echo
        echo "[clone] Normal cloning vLLM-Ascend."
        echo "[clone] Full repository/history will be downloaded."
        echo


        git clone \
            "$VLLM_ASCEND_URL" \
            "$dir"


    else

        echo
        echo "[clone] vLLM-Ascend already exists."
        echo "[clone] Skip clone."


        # ---------------------------------------------------------------------
        # 如果之前这个目录是旧脚本创建的 shallow repository，
        #
        # 这里恢复成完整 Git 历史。
        # ---------------------------------------------------------------------

        if [[ "$(
            git -C "$dir" rev-parse --is-shallow-repository
        )" == "true" ]]; then

            echo
            echo "[git] Existing vLLM-Ascend repository is shallow."
            echo "[git] Converting it to full repository..."


            git -C "$dir" fetch \
                --unshallow \
                origin

        else

            echo
            echo "[git] Fetching latest remote refs..."

            git -C "$dir" fetch \
                origin \
                --tags

        fi

    fi


    # -------------------------------------------------------------------------
    # 检查 commit
    # -------------------------------------------------------------------------

    if ! git -C "$dir" cat-file \
        -e "${VLLM_ASCEND_COMMIT}^{commit}" \
        2>/dev/null; then

        echo
        echo "[git] Commit not available locally."
        echo "[git] Fetching all remote refs..."


        git -C "$dir" fetch \
            origin \
            --tags


        if ! git -C "$dir" cat-file \
            -e "${VLLM_ASCEND_COMMIT}^{commit}" \
            2>/dev/null; then

            echo
            echo "[ERROR] Cannot find vLLM-Ascend commit:"
            echo "        $VLLM_ASCEND_COMMIT"

            exit 1

        fi

    fi


    # -------------------------------------------------------------------------
    # checkout commit
    # -------------------------------------------------------------------------

    echo
    echo "[git] Checkout vLLM-Ascend commit:"
    echo "      $VLLM_ASCEND_COMMIT"


    git -C "$dir" checkout \
        --detach \
        "$VLLM_ASCEND_COMMIT"


    echo
    echo "[git] vLLM-Ascend HEAD:"

    git -C "$dir" log \
        --oneline \
        -1


    echo
}


# =============================================================================
# 10. Clone afd-plugin
#
# afd-plugin：
#
#   正常 git clone
#
# 不使用：
#
#   --depth
#   --single-branch
#
#
# 即正常下载完整仓库。
#
#
# clone 完以后：
#
#   checkout main
#
# 仓库已存在：
#
#   fetch origin
#       ↓
#   checkout main
#       ↓
#   pull --ff-only origin main
#
# =============================================================================

clone_afd_plugin()
{
    local dir="$ROOT/afd-plugin"


    echo
    echo "-------------------------------------------------------------------"
    echo "[repo] afd-plugin"
    echo "[repo] URL    : $AFD_PLUGIN_URL"
    echo "[repo] branch : $AFD_PLUGIN_BRANCH"
    echo "[repo] clone  : normal full git clone"
    echo "-------------------------------------------------------------------"


    # -------------------------------------------------------------------------
    # --force
    # -------------------------------------------------------------------------

    if [[ "$FORCE" -eq 1 && -d "$dir" ]]; then

        echo "[clone] --force: removing old afd-plugin"
        echo "        $dir"

        rm -rf "$dir"

    fi


    # -------------------------------------------------------------------------
    # 第一次：
    #
    # 正常完整 clone。
    # -------------------------------------------------------------------------

    if [[ ! -d "$dir/.git" ]]; then

        echo
        echo "[clone] Normal cloning afd-plugin."
        echo "[clone] Full repository/history will be downloaded."
        echo


        git clone \
            "$AFD_PLUGIN_URL" \
            "$dir"


    else

        echo
        echo "[clone] afd-plugin already exists."
        echo "[clone] Skip clone."


        # ---------------------------------------------------------------------
        # 如果之前是 shallow clone，
        #
        # 转成完整仓库。
        # ---------------------------------------------------------------------

        if [[ "$(
            git -C "$dir" rev-parse --is-shallow-repository
        )" == "true" ]]; then

            echo
            echo "[git] Existing afd-plugin repository is shallow."
            echo "[git] Converting it to full repository..."


            git -C "$dir" fetch \
                --unshallow \
                origin

        else

            echo
            echo "[git] Fetching latest remote refs..."

            git -C "$dir" fetch \
                origin \
                --tags

        fi

    fi


    # -------------------------------------------------------------------------
    # checkout main
    # -------------------------------------------------------------------------

    echo
    echo "[git] Checkout afd-plugin branch:"
    echo "      $AFD_PLUGIN_BRANCH"


    # 本地没有 main 时，基于 origin/main 创建。
    if git -C "$dir" show-ref \
        --verify \
        --quiet \
        "refs/heads/$AFD_PLUGIN_BRANCH"; then


        git -C "$dir" checkout \
            "$AFD_PLUGIN_BRANCH"


    else

        git -C "$dir" checkout \
            -b "$AFD_PLUGIN_BRANCH" \
            "origin/$AFD_PLUGIN_BRANCH"

    fi


    # -------------------------------------------------------------------------
    # 只允许 fast-forward。
    #
    # 如果本地 main 出现自己额外的 commit，
    # 不允许脚本自动 merge。
    # -------------------------------------------------------------------------

    git -C "$dir" pull \
        --ff-only \
        origin \
        "$AFD_PLUGIN_BRANCH"


    echo
    echo "[git] afd-plugin HEAD:"

    git -C "$dir" log \
        --oneline \
        -1


    echo
}


# =============================================================================
# 11. Clone / Checkout
# =============================================================================

step "1/5 clone + checkout 三个仓库"


clone_vllm

clone_vllm_ascend

clone_afd_plugin


# =============================================================================
# 12. Repository Summary
# =============================================================================

echo
echo "==================================================================="
echo "Repository summary"
echo "==================================================================="


echo
echo "[vllm]"
git -C "$ROOT/vllm" log \
    --oneline \
    -1


echo
echo "[vllm-ascend]"
git -C "$ROOT/vllm-ascend" log \
    --oneline \
    -1


echo
echo "[afd-plugin]"
git -C "$ROOT/afd-plugin" log \
    --oneline \
    -1


echo


# =============================================================================
# 13. Build Stamp
#
# need_build：
#
#   return 0
#     → 需要 build
#
#   return 1
#     → 已经 build，可以 skip
#
#
# 判断：
#
#   当前 Git HEAD
#
#       VS
#
#   stamp 中保存的 HEAD
#
# =============================================================================

need_build()
{
    local repo="$1"
    local stamp="$2"

    local current_head


    current_head="$(
        git -C "$repo" rev-parse HEAD
    )"


    # --force 永远重新 build
    if [[ "$FORCE" -eq 1 ]]; then
        return 0
    fi


    # stamp 不存在：
    #
    # 说明还没成功 build 过。
    if [[ ! -f "$stamp" ]]; then
        return 0
    fi


    local built_head

    built_head="$(
        cat "$stamp"
    )"


    # Git HEAD 发生变化。
    if [[ "$current_head" != "$built_head" ]]; then
        return 0
    fi


    # HEAD 相同：
    #
    # 已经 build。
    return 1
}


write_stamp()
{
    local repo="$1"
    local stamp="$2"


    # build 成功以后调用。
    #
    # 保存当前 Git HEAD。
    git -C "$repo" \
        rev-parse HEAD \
        > "$stamp"
}


# =============================================================================
# 14. Build dependencies
# =============================================================================

echo
echo "[pip] Installing build dependencies..."


python3 -m pip install \
    setuptools-rust


# =============================================================================
# 15. Build vLLM
# =============================================================================

step "2/5 编译安装 vLLM empty"


VLLM_DIR="$ROOT/vllm"

VLLM_STAMP="$STAMP_DIR/vllm"


cd "$VLLM_DIR"


# -----------------------------------------------------------------------------
# 使用基础镜像已有的 torch。
#
# 防止构建 vLLM 时重新拉取 stock torch。
# -----------------------------------------------------------------------------

if [[ -f use_existing_torch.py ]]; then

    echo "[vllm] Reusing existing torch stack..."

    python3 use_existing_torch.py

else

    echo "[ERROR] use_existing_torch.py not found:"
    echo "        $VLLM_DIR/use_existing_torch.py"

    exit 1

fi


# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

if need_build \
    "$VLLM_DIR" \
    "$VLLM_STAMP"; then


    echo
    echo "[vllm] Building..."
    echo "[vllm] ref=$VLLM_REF"
    echo "[vllm] VLLM_TARGET_DEVICE=empty"
    echo


    VLLM_TARGET_DEVICE=empty \
    SETUPTOOLS_SCM_PRETEND_VERSION=0.26.0 \
    python3 -m pip install \
        -e . \
        --no-build-isolation


    write_stamp \
        "$VLLM_DIR" \
        "$VLLM_STAMP"


else

    echo
    echo "[vllm] Current Git HEAD has already been built."
    echo "[vllm] Skip build."

fi


# -----------------------------------------------------------------------------
# vLLM 安装过程可能修改 numpy / fastapi。
#
# 恢复 Ascend 环境版本。
# -----------------------------------------------------------------------------

echo
echo "[vllm] Restoring numpy / fastapi..."


python3 -m pip install \
    "numpy==1.26.4" \
    "fastapi<0.124.0"


# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------

python3 - <<'PY'
import vllm

print("[vllm] import OK")

print(
    "[vllm] version =",
    getattr(vllm, "__version__", "unknown")
)
PY


# =============================================================================
# 16. Build vLLM-Ascend
# =============================================================================

step "3/5 编译安装 vLLM-Ascend"


VLLM_ASCEND_DIR="$ROOT/vllm-ascend"

VLLM_ASCEND_STAMP="$STAMP_DIR/vllm-ascend"


cd "$VLLM_ASCEND_DIR"


# -----------------------------------------------------------------------------
# torch_npu 检查
# -----------------------------------------------------------------------------

python3 - <<'PY'
import torch
import torch_npu

print("[vllm-ascend] torch_npu OK")

print(
    "[vllm-ascend] device =",
    torch.npu.get_device_name(0)
)
PY


# 某些基础镜像设置的 LD_PRELOAD
# 可能影响源码编译。
unset LD_PRELOAD || true


# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

if need_build \
    "$VLLM_ASCEND_DIR" \
    "$VLLM_ASCEND_STAMP"; then


    echo
    echo "[vllm-ascend] Building..."
    echo "[vllm-ascend] commit=$VLLM_ASCEND_COMMIT"
    echo "[vllm-ascend] SOC_VERSION=$SOC_VERSION"
    echo


    SOC_VERSION="$SOC_VERSION" \
    python3 -m pip install \
        -e . \
        --no-build-isolation


    write_stamp \
        "$VLLM_ASCEND_DIR" \
        "$VLLM_ASCEND_STAMP"


else

    echo
    echo "[vllm-ascend] Current Git HEAD has already been built."
    echo "[vllm-ascend] Skip build."

fi


# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------

python3 - <<'PY'
import vllm_ascend

print("[vllm-ascend] import OK")

print(
    "[vllm-ascend] version =",
    getattr(vllm_ascend, "__version__", "unknown")
)
PY


# =============================================================================
# 17. Build afd-plugin
# =============================================================================

step "4/5 编译安装 afd-plugin"


AFD_PLUGIN_DIR="$ROOT/afd-plugin"

AFD_PLUGIN_STAMP="$STAMP_DIR/afd-plugin"


cd "$AFD_PLUGIN_DIR"


if need_build \
    "$AFD_PLUGIN_DIR" \
    "$AFD_PLUGIN_STAMP"; then


    echo
    echo "[afd-plugin] Building..."
    echo "[afd-plugin] branch=$AFD_PLUGIN_BRANCH"
    echo "[afd-plugin] SOC_VERSION=$SOC_VERSION"
    echo


    SOC_VERSION="$SOC_VERSION" \
    python3 -m pip install \
        -e . \
        --no-build-isolation


    write_stamp \
        "$AFD_PLUGIN_DIR" \
        "$AFD_PLUGIN_STAMP"


else

    echo
    echo "[afd-plugin] Current Git HEAD has already been built."
    echo "[afd-plugin] Skip build."

fi


# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------

python3 - <<'PY'
import afd_plugin

print("[afd-plugin] import OK")

print(
    "[afd-plugin] version =",
    getattr(afd_plugin, "__version__", "unknown")
)
PY


# =============================================================================
# 18. 最终验证
# =============================================================================

step "5/5 验证完整 AFD 环境"


# -----------------------------------------------------------------------------
# Git HEAD
# -----------------------------------------------------------------------------

echo "---------------- Git HEAD ----------------"
echo


printf "%-18s " "vllm:"

git -C "$ROOT/vllm" \
    rev-parse \
    --short HEAD


printf "%-18s " "vllm-ascend:"

git -C "$ROOT/vllm-ascend" \
    rev-parse \
    --short HEAD


printf "%-18s " "afd-plugin:"

git -C "$ROOT/afd-plugin" \
    rev-parse \
    --short HEAD


# -----------------------------------------------------------------------------
# Python packages
# -----------------------------------------------------------------------------

echo
echo "---------------- Python packages ----------------"
echo


python3 -m pip show \
    vllm \
    vllm-ascend \
    afd-plugin \
    torch \
    torch-npu \
    triton-ascend \
    2>/dev/null \
    | grep -E \
        "^(Name|Version|Editable project location):" \
    || true


# -----------------------------------------------------------------------------
# Import check
# -----------------------------------------------------------------------------

echo
echo "---------------- Import check ----------------"
echo


python3 - <<'PY'
import torch
import torch_npu
import vllm
import vllm_ascend
import afd_plugin

print(
    "torch       :",
    torch.__version__
)

print(
    "torch_npu   :",
    torch_npu.__version__
)

print(
    "vllm        :",
    getattr(vllm, "__version__", "unknown")
)

print(
    "vllm_ascend :",
    getattr(vllm_ascend, "__version__", "unknown")
)

print(
    "afd_plugin  :",
    getattr(afd_plugin, "__version__", "unknown")
)

print()

print(
    "NPU         :",
    torch.npu.get_device_name(0)
)
PY


# -----------------------------------------------------------------------------
# AFD custom ops
# -----------------------------------------------------------------------------

echo
echo "---------------- AFD ops ----------------"
echo


cd "$AFD_PLUGIN_DIR"


python3 - <<'PY'
import torch
import torch_npu

from afd_plugin.compat.npu import ensure_afd_ascend_ops_loaded

ensure_afd_ascend_ops_loaded()

print("AFD_OPS_OK")
PY


# -----------------------------------------------------------------------------
# a2e / e2a 编译产物
# -----------------------------------------------------------------------------

echo
echo "---------------- AFD custom-op artifacts ----------------"
echo


AFD_OP_ROOT="afd_plugin/_cann_ops_custom/vendors/afd-plugin"


if [[ -f "$AFD_OP_ROOT/op_api/lib/libcust_opapi.so" ]]; then

    echo "[OK] libcust_opapi.so"

else

    echo "[WARN] libcust_opapi.so not found"

fi


for op in a2e e2a; do

    OP_DIR="$AFD_OP_ROOT/op_impl/ai_core/tbe/kernel/ascend950/$op"


    if [[ -d "$OP_DIR" ]] && \
       find "$OP_DIR" \
           -mindepth 1 \
           -print \
           -quit \
           2>/dev/null \
       | grep -q .; then

        echo "[OK] ascend950/$op"

    else

        echo "[WARN] ascend950/$op kernel not found"

    fi

done


# =============================================================================
# 19. 完成
# =============================================================================

echo
echo "==================================================================="
echo "AFD build completed"
echo "==================================================================="


echo
echo "Source root:"
echo "  $ROOT"


echo
echo "SOC_VERSION:"
echo "  $SOC_VERSION"


echo
echo "Clone strategy:"


echo
echo "  vllm:"
echo "    ref   = $VLLM_REF"
echo "    depth = 1"
echo "    only v0.26.0 is downloaded"


echo
echo "  vllm-ascend:"
echo "    clone  = normal full git clone"
echo "    commit = $VLLM_ASCEND_COMMIT"


echo
echo "  afd-plugin:"
echo "    clone  = normal full git clone"
echo "    branch = $AFD_PLUGIN_BRANCH"


echo
echo "Build log:"
echo "  $LOG"


echo
echo "Build stamps:"
echo "  $STAMP_DIR"


echo
echo "==================================================================="