#!/bin/bash
set -e

echo "========== Init SSH Service =========="


# =========================
# 1. 安装 openssh-server
# =========================

if ! command -v sshd >/dev/null 2>&1; then
    echo "[INFO] Installing openssh-server..."

    yum install -y openssh-server openssh-clients

else
    echo "[INFO] sshd already installed"
fi


# =========================
# 2. 设置 root 密码
# =========================

echo "[INFO] Configuring root password..."

if [ -z "${ROOT_PASSWORD}" ]; then

    echo "[INFO] ROOT_PASSWORD environment variable not found"

    read -s -p "Enter root password: " ROOT_PASSWORD
    echo ""

    read -s -p "Confirm root password: " ROOT_PASSWORD_CONFIRM
    echo ""

    if [ "${ROOT_PASSWORD}" != "${ROOT_PASSWORD_CONFIRM}" ]; then
        echo "[ERROR] Passwords do not match!"
        exit 1
    fi

else

    echo "[INFO] Using password from ROOT_PASSWORD environment variable"

fi


echo "root:${ROOT_PASSWORD}" | chpasswd


# =========================
# 3. 配置 sshd
# =========================

SSHD_CONFIG="/etc/ssh/sshd_config"

echo "[INFO] Configuring sshd..."


# 允许 root 登录
if grep -q "^PermitRootLogin" ${SSHD_CONFIG}; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' ${SSHD_CONFIG}
else
    echo "PermitRootLogin yes" >> ${SSHD_CONFIG}
fi


# 开启密码认证
if grep -q "^PasswordAuthentication" ${SSHD_CONFIG}; then
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' ${SSHD_CONFIG}
else
    echo "PasswordAuthentication yes" >> ${SSHD_CONFIG}
fi


# 设置 SSH 端口
if grep -q "^Port" ${SSHD_CONFIG}; then
    sed -i 's/^Port.*/Port 22/' ${SSHD_CONFIG}
else
    echo "Port 22" >> ${SSHD_CONFIG}
fi


# =========================
# 4. 创建 ssh runtime 目录
# =========================

echo "[INFO] Preparing ssh runtime directory..."

mkdir -p /run/sshd
chmod 755 /run/sshd


# =========================
# 5. 生成 host key
# =========================

echo "[INFO] Generating ssh host keys..."

ssh-keygen -A


# =========================
# 6. 检查 sshd 配置
# =========================

echo "[INFO] Checking sshd configuration..."

sshd -t


# =========================
# 7. 启动 sshd
# =========================

echo "[INFO] Checking SSH listener..."

if ss -lnt | grep -q ":22"; then

    echo "[INFO] SSH already listening on port 22"

else

    echo "[INFO] Starting sshd..."

    # Docker环境不要使用systemctl
    # 不使用 sshd -D &
    /usr/sbin/sshd

fi


# =========================
# 8. 检查状态
# =========================

echo "========== SSH Status =========="

ss -lntp | grep ":22" || true


echo ""

echo "========== SSH Ready =========="

echo "User: root"
echo "Password: configured"

echo ""

echo "Login example:"
echo "ssh root@<host-ip> -p <mapped-port>"
