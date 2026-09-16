#!/usr/bin/env bash
#
# =============================================================================
# detect_soc.sh
#
# 功能：
#   1. 通过 torch_npu 探测当前 NPU SOC
#   2. 将结果转换为构建脚本需要的格式
#   3. 写入环境变量：
#
#        SOC_VERSION
#
#
# 示例：
#
#   Ascend950PR_957d
#
# 转换为：
#
#   ascend950pr_957d
#
#
# 使用方式：
#
#   source detect_soc.sh
#
# 或：
#
#   . detect_soc.sh
#
#
# 然后：
#
#   echo $SOC_VERSION
#
#
# 注意：
#
#   不建议：
#
#       bash detect_soc.sh
#
#   因为子 shell 中 export 的环境变量不会回写到当前 shell。
#
# =============================================================================


# -----------------------------------------------------------------------------
# 检查 python3
# -----------------------------------------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then
    echo "[ERROR] python3 not found." >&2
    return 1 2>/dev/null || exit 1
fi


# -----------------------------------------------------------------------------
# 探测 SOC
# -----------------------------------------------------------------------------

DETECTED_SOC="$(
python3 - <<'PY'
import re
import sys

try:
    import torch
    import torch_npu
except Exception as e:
    print(f"ERROR_IMPORT:{e}")
    sys.exit(0)

try:
    count = torch.npu.device_count()

    if count <= 0:
        print("ERROR_NO_NPU")
        sys.exit(0)

    name = torch.npu.get_device_name(0)

    # 示例：
    #
    # Ascend950PR_957d
    #
    # ->
    #
    # ascend950pr_957d

    m = re.match(r"(Ascend\w+)_(\w+)", name)

    if m:
        soc = (m.group(1) + "_" + m.group(2)).lower()
    else:
        # 如果设备名称格式发生变化，
        # 至少保留原始 device name 的小写形式。
        soc = name.lower()

    print(soc)

except Exception as e:
    print(f"ERROR_DETECT:{e}")
PY
)"


# -----------------------------------------------------------------------------
# 错误处理
# -----------------------------------------------------------------------------

case "$DETECTED_SOC" in

    ERROR_IMPORT:*)
        echo "[ERROR] Failed to import torch / torch_npu." >&2
        echo "${DETECTED_SOC#ERROR_IMPORT:}" >&2
        return 1 2>/dev/null || exit 1
        ;;

    ERROR_NO_NPU)
        echo "[ERROR] No NPU detected." >&2
        return 1 2>/dev/null || exit 1
        ;;

    ERROR_DETECT:*)
        echo "[ERROR] Failed to detect SOC." >&2
        echo "${DETECTED_SOC#ERROR_DETECT:}" >&2
        return 1 2>/dev/null || exit 1
        ;;

    "")
        echo "[ERROR] SOC detection returned empty result." >&2
        return 1 2>/dev/null || exit 1
        ;;

esac


# -----------------------------------------------------------------------------
# 写入当前 shell 环境变量
# -----------------------------------------------------------------------------

export SOC_VERSION="$DETECTED_SOC"


# -----------------------------------------------------------------------------
# 打印结果
# -----------------------------------------------------------------------------

echo "============================================================"
echo "[INFO] SOC detection completed"
echo "============================================================"
echo
echo "SOC_VERSION=$SOC_VERSION"
echo
echo "Environment variable exported:"
echo "  SOC_VERSION"
echo
echo "============================================================"