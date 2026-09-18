#!/usr/bin/env bash
set -euo pipefail

echo "========== Init SSH Service =========="

if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] Please run this script as root." >&2
    exit 1
fi

# =========================
# 1. Install packages
# =========================

echo "[INFO] Installing required packages..."

PACKAGES=(openssh-server openssh-clients iproute)

if ! command -v yum >/dev/null 2>&1; then
    echo "[ERROR] yum command not found." >&2
    exit 1
fi

yum install -y "${PACKAGES[@]}"

# =========================
# 2. Set root password
# =========================

ROOT_PASSWORD="${ROOT_PASSWORD:-}"

if [[ -z "${ROOT_PASSWORD}" ]]; then
    if [[ ! -t 0 ]]; then
        echo "[ERROR] Set ROOT_PASSWORD when running non-interactively." >&2
        exit 1
    fi

    read -rsp "Enter root password: " ROOT_PASSWORD
    echo
fi

if [[ -z "${ROOT_PASSWORD}" ]]; then
    echo "[ERROR] Root password cannot be empty." >&2
    exit 1
fi

echo "[INFO] Setting root password..."
printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
unset ROOT_PASSWORD

# =========================
# 3. Configure sshd
# =========================

SSHD_CONFIG="/etc/ssh/sshd_config"

echo "[INFO] Configuring sshd..."

set_sshd_option() {
    local key="$1"
    local value="$2"

    if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "${SSHD_CONFIG}"; then
        sed -ri \
            "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${value}|" \
            "${SSHD_CONFIG}"
    else
        printf '%s %s\n' "${key}" "${value}" >>"${SSHD_CONFIG}"
    fi
}

set_sshd_option "PermitRootLogin" "yes"
set_sshd_option "PasswordAuthentication" "yes"

# =========================
# 4. Generate SSH keys
# =========================

echo "[INFO] Generating SSH host keys..."
ssh-keygen -A

echo "[INFO] Validating sshd configuration..."
/usr/sbin/sshd -t

# =========================
# 5. Start sshd
# =========================

echo "[INFO] Starting sshd..."

if pgrep -x sshd >/dev/null; then
    echo "[INFO] sshd already running"
else
    /usr/sbin/sshd
fi

sleep 2

# =========================
# 6. Check status
# =========================

echo
echo "========== SSH Process =========="
ps -ef | grep '[s]shd' || true

echo
echo "========== Container Listening Ports =========="

if command -v ss >/dev/null 2>&1; then
    ss -lntp
else
    echo "[WARN] ss command not found"
fi

echo
echo "========== SSH Ready =========="
echo "User: root"
echo "Password: configured (not printed)"
echo
echo "Login example:"
echo "ssh root@<host-ip> -p <mapped-port>"
