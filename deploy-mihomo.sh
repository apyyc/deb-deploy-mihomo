#!/usr/bin/env bash
# ============================================================
# deploy-mihomo.sh — mihomo 代理一键部署与管理脚本
#
# 项目名：deploy-mihomo（由原 mihomo/ 目录改名而来）
# 功能概览：
#   1. 自动下载并安装指定版本（默认锁定 v1.19.30）的 mihomo 内核
#   2. 把项目里的 config.yaml 部署到 /etc/mihomo/config.yaml（守护进程实际读取位置）
#   3. 以 systemd 服务方式管理 mihomo 进程（开机自启、崩溃自动重启）
#   4. 一并管理系统级代理环境变量（/etc/environment 与 /etc/profile.d/proxy.sh）
#
# 子命令：
#   install [版本]   下载并安装 mihomo 到 /usr/local/bin/mihomo（默认锁定版本）
#   update  [版本]   强制重装（升级/修复），默认取锁定版本
#   config           把项目 config.yaml 部署到 /etc/mihomo 并校验
#   config pull      把 /etc/mihomo/config.yaml 回收进项目（改过线上配置想留档时用）
#   test             校验 /etc/mihomo/config.yaml 语法（mihomo -t）
#   on | start       开启：起服务 + 写系统代理环境变量（缺二进制/配置自动补装）
#   off | stop       关闭：停服务 + 清系统代理环境变量
#   enable           永久开启：systemctl enable + on（开机自启）
#   disable          永久关闭：systemctl disable + off
#   restart          重启 mihomo 服务（保留代理环境变量）
#   status           查看二进制/服务/端口/代理环境/连通性
#   logs [-f]        查看 mihomo 日志（journalctl，-f 跟随）
#   edit             编辑 /etc/mihomo/config.yaml（保存后可重载）
#   prune            清理历史残留：旧的 /usr/bin/mihomo 二进制、crontab @reboot
#
# 用法：
#   sudo ./deploy-mihomo.sh install
#   sudo ./deploy-mihomo.sh enable      # 装好并开机自启
#   ./deploy-mihomo.sh status
# ============================================================

set -euo pipefail

# ---------- 可配置参数 ----------
# 项目里这份 config.yaml 是源头；部署到 /etc/mihomo 供守护进程读取
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="${SCRIPT_DIR}/config.yaml"
DATA_DIR="/etc/mihomo"
CONFIG_PATH="${DATA_DIR}/config.yaml"

# 二进制安装目录 / 可执行文件
BIN_INSTALL_DIR="/usr/local/bin"
BIN_PATH="${BIN_INSTALL_DIR}/mihomo"

# 锁定版本（需要升级时改这里，或用参数 install <版本> 临时指定）
DEFAULT_VERSION="${DEFAULT_VERSION:-v1.19.30}"
GITHUB_REPO="MetaCubeX/mihomo"

# systemd 服务
SYSTEMD_SERVICE="mihomo.service"
SYSTEMD_UNIT="/etc/systemd/system/${SYSTEMD_SERVICE}"

# 代理地址（以 config.yaml 里 mixed-port / socks-port 为准）
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
MIXED_PORT="${MIXED_PORT:-7893}"
SOCKS_PORT="${SOCKS_PORT:-7891}"
NO_PROXY_VAL="${NO_PROXY_VAL:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.local}"
PROXY_HTTP="http://${PROXY_HOST}:${MIXED_PORT}"
PROXY_HTTPS="http://${PROXY_HOST}:${MIXED_PORT}"
PROXY_SOCKS="socks5://${PROXY_HOST}:${SOCKS_PORT}"

# 代理环境变量的持久化位置与块标记
ENV_FILE="/etc/environment"
PROFILE_D="/etc/profile.d/proxy.sh"
BLOCK_MARKER="deploy-mihomo"
BLOCK_START="# >>> ${BLOCK_MARKER} start >>>"
BLOCK_END="# <<< ${BLOCK_MARKER} end <<<"

NEED_ROOT_MSG="需要 root 权限（写 ${ENV_FILE}、/etc/systemd 等），请用 sudo ./$(basename "$0") 重试。"

require_root() {
  [ "$(id -u)" = "0" ] || { echo "[失败] ${NEED_ROOT_MSG}" >&2; exit 1; }
}

# ---------- 代理环境变量块 ----------
ENV_BLOCK="$(cat <<EOF
http_proxy=${PROXY_HTTP}
https_proxy=${PROXY_HTTPS}
HTTP_PROXY=${PROXY_HTTP}
HTTPS_PROXY=${PROXY_HTTPS}
all_proxy=${PROXY_SOCKS}
ALL_PROXY=${PROXY_SOCKS}
no_proxy=${NO_PROXY_VAL}
NO_PROXY=${NO_PROXY_VAL}
EOF
)"

PROFILE_BLOCK="$(cat <<EOF
export http_proxy='${PROXY_HTTP}'
export https_proxy='${PROXY_HTTPS}'
export HTTP_PROXY='${PROXY_HTTP}'
export HTTPS_PROXY='${PROXY_HTTPS}'
export all_proxy='${PROXY_SOCKS}'
export ALL_PROXY='${PROXY_SOCKS}'
export no_proxy='${NO_PROXY_VAL}'
export NO_PROXY='${NO_PROXY_VAL}'
EOF
)"

# ---------- 工具：写 / 清“标记块”（幂等）----------
# 兼容旧脚本 proxyctl 留下的块，一并清除
clear_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  local tmp; tmp="$(mktemp)"
  awk '
    BEGIN { skip = 0 }
    /^# >>> .* start >>>$/ { skip = 1; next }
    /^# <<< .* end <<<$/   { skip = 0; next }
    !skip && NF { print }
  ' "$file" > "$tmp"
  mv -f "$tmp" "$file"
  rm -f "$tmp"
}

write_block() {
  local file="$1" block="$2"
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"
  clear_block "$file"
  local tmp; tmp="$(mktemp)"
  awk '
    BEGIN { skip = 0 }
    /^# >>> .* start >>>$/ { skip = 1; next }
    /^# <<< .* end <<<$/   { skip = 0; next }
    !skip && NF { print }
  ' "$file" > "$tmp"
  printf '\n%s\n%s\n%s\n' "$BLOCK_START" "$block" "$BLOCK_END" >> "$tmp"
  mv -f "$tmp" "$file"
  rm -f "$tmp"
}

# ---------- 二进制版本 / 架构 ----------
installed_version() {
  "$BIN_PATH" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

arch_of() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armhf)  echo armv7 ;;
    i386|i686|x86) echo 386 ;;
    *) return 1 ;;
  esac
}

install_binary() {
  local version="${1:-${DEFAULT_VERSION}}"
  require_root
  local arch; arch="$(arch_of)" || { echo "[失败] 不支持的架构: $(uname -m)"; exit 1; }

  local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/mihomo-linux-${arch}-${version}.gz"
  echo "[开始] 下载 mihomo ${version}（linux-${arch}）..."
  echo "  ${url}"
  local tmpdir; tmpdir="$(mktemp -d)"
  # -C - 断点续传；--retry-all-errors 把 SSL 中断等也纳入重试
  if ! curl -fL --retry 6 --retry-all-errors --retry-delay 2 -C - -o "${tmpdir}/mihomo.gz" "$url" 2>/dev/null; then
    echo "[提示] 经代理下载失败，尝试直连 ..."
    if ! curl -fL --retry 3 --retry-all-errors --retry-delay 2 --noproxy '*' -o "${tmpdir}/mihomo.gz" "$url" 2>/dev/null; then
      echo "[失败] 下载失败: ${url}"
      rm -rf "$tmpdir"
      exit 1
    fi
  fi

  echo "[提示] GitHub 未发布该文件的 sha256 资产，改用安装后版本号校验完整性"
  gunzip -f "${tmpdir}/mihomo.gz"
  chmod 0755 "${tmpdir}/mihomo"
  install -m 0755 "${tmpdir}/mihomo" "$BIN_PATH"
  rm -rf "$tmpdir"

  local got; got="$(installed_version)"
  if [ -z "$got" ]; then
    echo "[失败] 安装后无法运行 ${BIN_PATH}，请检查是否缺动态库"
    exit 1
  fi
  if [ "$got" != "$version" ]; then
    echo "[警告] 安装后版本 ${got} 与请求版本 ${version} 不一致"
  else
    echo "[OK] 已安装 mihomo ${got} → ${BIN_PATH}"
  fi
}

# ---------- systemd 单元 ----------
write_systemd_unit() {
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Mihomo Daemon (Clash Meta kernel) - managed by deploy-mihomo
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -f ${CONFIG_PATH}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}

# ---------- crontab 兼容：移除旧 @reboot ----------
remove_cron_boot_entry() {
  command -v crontab >/dev/null 2>&1 || return 0
  local cur
  cur="$(crontab -l 2>/dev/null || true)"
  if printf '%s\n' "$cur" | grep -qE '@reboot .*(mihomo|deploy-mihomo)'; then
    printf '%s\n' "$cur" | grep -vE '@reboot .*(mihomo|deploy-mihomo)' | crontab - 2>/dev/null || true
    echo "[提示] 已移除 crontab @reboot 旧条目（改由 systemd 开机自启）"
  fi
}

# ---------- 配置 ----------
cmd_config() {
  require_root
  [ -f "$CONFIG_SRC" ] || { echo "[失败] 项目里没有 config.yaml: ${CONFIG_SRC}"; exit 1; }
  mkdir -p "$DATA_DIR"
  cp -f "$CONFIG_SRC" "$CONFIG_PATH"
  chmod 0644 "$CONFIG_PATH"
  echo "[OK] 已部署配置: ${CONFIG_SRC} → ${CONFIG_PATH}"
  cmd_test
}

cmd_config_pull() {
  [ -f "$CONFIG_PATH" ] || { echo "[失败] ${CONFIG_PATH} 不存在"; exit 1; }
  cp -f "$CONFIG_PATH" "$CONFIG_SRC"
  echo "[OK] 已回收: ${CONFIG_PATH} → ${CONFIG_SRC}"
}

cmd_test() {
  [ -x "$BIN_PATH" ] || { echo "[失败] mihomo 未安装，先运行: $(basename "$0") install"; exit 1; }
  [ -f "$CONFIG_PATH" ] || { echo "[失败] ${CONFIG_PATH} 不存在，先运行: $(basename "$0") config"; exit 1; }
  local out
  out="$("$BIN_PATH" -t -f "$CONFIG_PATH" 2>&1)" && { echo "[OK] 配置校验通过: ${CONFIG_PATH}"; return 0; }
  echo "[失败] 配置校验未通过："
  printf '%s\n' "$out" | tail -20
  return 1
}

# ---------- 开关 ----------
stop_foreign_mihomo() {
  # 停掉非本 systemd 服务管理的旧 mihomo 进程（如 cron/nohup 遗留），避免端口冲突
  local pids pid cg
  pids="$(pgrep -x mihomo 2>/dev/null || true)"
  [ -n "$pids" ] || return 0
  for pid in $pids; do
    cg="$(cat "/proc/${pid}/cgroup" 2>/dev/null || true)"
    if ! printf '%s' "$cg" | grep -q 'mihomo.service'; then
      echo "[提示] 发现旧方式启动的 mihomo 进程 (PID ${pid})，停止它并交由 systemd 接管"
      kill "$pid" 2>/dev/null || true
    fi
  done
}

cmd_on() {
  require_root
  [ -x "$BIN_PATH" ] || { echo "[提示] 未检测到 ${BIN_PATH}，自动安装 ${DEFAULT_VERSION} ..."; install_binary "$DEFAULT_VERSION"; }
  [ -f "$CONFIG_PATH" ] || { echo "[提示] 未检测到 ${CONFIG_PATH}，自动部署配置 ..."; cmd_config; }
  write_systemd_unit
  systemctl daemon-reload
  cmd_test >/dev/null || { echo "[失败] 配置校验未通过，已取消启动"; exit 1; }
  stop_foreign_mihomo
  if systemctl is-active --quiet "$SYSTEMD_SERVICE"; then
    systemctl restart "$SYSTEMD_SERVICE"
  else
    systemctl enable --now "$SYSTEMD_SERVICE" >/dev/null
  fi
  remove_cron_boot_entry
  write_block "$ENV_FILE" "$ENV_BLOCK"
  write_block "$PROFILE_D" "$PROFILE_BLOCK"
  echo ""
  echo "[OK] mihomo 服务已开启（systemctl ${SYSTEMD_SERVICE}）"
  echo "  二进制: ${BIN_PATH} ($(installed_version))"
  echo "  配置:   ${CONFIG_PATH}"
  echo "  混合口: ${PROXY_HTTP}  /  SOCKS: ${PROXY_SOCKS}"
  echo "  代理环境变量已写入 ${ENV_FILE} 与 ${PROFILE_D}"
  echo "  当前 shell 立即生效可执行: export http_proxy='${PROXY_HTTP}' https_proxy='${PROXY_HTTPS}' all_proxy='${PROXY_SOCKS}' no_proxy='${NO_PROXY_VAL}'"
}

cmd_off() {
  require_root
  if systemctl list-unit-files --type=service --all 2>/dev/null | grep -q "^${SYSTEMD_SERVICE}"; then
    systemctl stop "$SYSTEMD_SERVICE" 2>/dev/null || true
  fi
  clear_block "$ENV_FILE"
  rm -f "$PROFILE_D"
  echo "[OK] mihomo 服务已停止，代理环境变量已清除"
  echo "  当前 shell 立即清除可执行: unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY"
}

cmd_enable() {
  require_root
  cmd_on
  systemctl enable "$SYSTEMD_SERVICE" >/dev/null 2>&1 || true
  echo "[OK] 已设为开机自启（systemctl enable ${SYSTEMD_SERVICE}）"
}

cmd_disable() {
  require_root
  systemctl disable "$SYSTEMD_SERVICE" >/dev/null 2>&1 || true
  cmd_off
  echo "[OK] 已关闭开机自启（systemctl disable ${SYSTEMD_SERVICE}）"
}

cmd_restart() {
  require_root
  systemctl restart "$SYSTEMD_SERVICE"
  echo "[OK] 已重启 ${SYSTEMD_SERVICE}"
}

cmd_logs() {
  if [ "${1:-}" = "-f" ]; then
    journalctl -u "$SYSTEMD_SERVICE" -f
  else
    journalctl -u "$SYSTEMD_SERVICE" -n 60 --no-pager
  fi
}

cmd_edit() {
  [ -f "$CONFIG_PATH" ] || { echo "[失败] ${CONFIG_PATH} 不存在，先运行: $(basename "$0") config"; exit 1; }
  local editor="${EDITOR:-vi}"
  echo "[提示] 编辑 ${CONFIG_PATH}（保存后询问是否重载）"
  "$editor" "$CONFIG_PATH"
  local ans
  read -r -p "是否重启 mihomo 使配置生效？[y/N] " ans
  case "${ans:-n}" in
    y|Y) require_root; systemctl restart "$SYSTEMD_SERVICE"; echo "[OK] 已重启 ${SYSTEMD_SERVICE}" ;;
    *) echo "[提示] 未重启，配置将在下次 on/restart 时生效" ;;
  esac
}

cmd_prune() {
  require_root
  if [ -x /usr/bin/mihomo ] && [ "$(readlink -f /usr/bin/mihomo)" != "$BIN_PATH" ]; then
    rm -f /usr/bin/mihomo
    echo "[OK] 已移除旧二进制 /usr/bin/mihomo"
  fi
  remove_cron_boot_entry
  echo "[提示] 历史残留：/root/clashctl 为更早的独立部署，本脚本不管理，可自行删除"
}

cmd_status() {
  echo "===== 二进制 ====="
  if [ -x "$BIN_PATH" ]; then
    echo "  ${BIN_PATH}  ($(installed_version))"
  else
    echo "  ${BIN_PATH}  （未安装，运行 install 安装）"
  fi
  if [ -x /usr/bin/mihomo ] && [ "$(readlink -f /usr/bin/mihomo)" != "$BIN_PATH" ]; then
    echo "  [残留] /usr/bin/mihomo 旧二进制（可用 prune 清理）"
  fi

  echo ""
  echo "===== systemd 服务 ====="
  if systemctl list-unit-files --type=service --all 2>/dev/null | grep -q "^${SYSTEMD_SERVICE}"; then
    local en ac
    en="$(systemctl is-enabled "$SYSTEMD_SERVICE" 2>/dev/null)" || en="${en:-未知}"
    ac="$(systemctl is-active "$SYSTEMD_SERVICE" 2>/dev/null)" || ac="${ac:-未知}"
    echo "  开机自启: ${en}"
    echo "  运行状态: ${ac}"
  else
    echo "  未安装服务单元（运行 on/enable 创建）"
  fi

  echo ""
  echo "===== 监听端口 ====="
  ss -tln 2>/dev/null | grep -E "[:.](${MIXED_PORT}|${SOCKS_PORT}|9090)\b" || echo "  （无相关端口监听，服务未在运行）"

  echo ""
  echo "===== 代理环境变量 ====="
  if [ -f "$ENV_FILE" ] && grep -q "${BLOCK_MARKER}" "$ENV_FILE" 2>/dev/null; then
    echo "  ${ENV_FILE}     : 已启用"
  else
    echo "  ${ENV_FILE}     : 未启用"
  fi
  if [ -f "$PROFILE_D" ]; then
    echo "  ${PROFILE_D} : 已启用（登录 shell）"
  else
    echo "  ${PROFILE_D} : 未启用"
  fi
  echo "  当前 shell http_proxy = ${http_proxy:-未设置}"

  echo ""
  echo "===== 连通性 ====="
  curl -s -o /dev/null -w "  google -> HTTP:%{http_code} (%{time_total}s)\n" --max-time 8 https://www.google.com 2>/dev/null || echo "  google -> 失败"
  curl -s -o /dev/null -w "  baidu  -> HTTP:%{http_code} (%{time_total}s)\n" --max-time 8 https://www.baidu.com 2>/dev/null || echo "  baidu  -> 失败"
}

# ---------- 子命令分发 ----------
main() {
  case "${1:-}" in
    install|update)
      local version="${2:-${DEFAULT_VERSION}}"
      if [ "$1" = "update" ]; then
        install_binary "$version"
      elif [ -x "$BIN_PATH" ] && [ "$(installed_version)" = "$version" ]; then
        echo "[提示] 已安装 ${version}，跳过（强制重装用 update）"
      else
        install_binary "$version"
      fi
      ;;
    config)       cmd_config ;;
    "config pull") cmd_config_pull ;;
    test)         cmd_test ;;
    on|start)     cmd_on ;;
    off|stop)     cmd_off ;;
    enable)       cmd_enable ;;
    disable)      cmd_disable ;;
    restart)      cmd_restart ;;
    logs)         cmd_logs "${2:-}" ;;
    edit)         cmd_edit ;;
    prune)        cmd_prune ;;
    status)       cmd_status ;;
    -h|--help|help)
      sed -n '2,46p' "$0" | sed -E 's/^# ?//' | grep -v '^$'
      ;;
    *)
      echo "用法: $(basename "$0") {install|update|config|test|on|off|enable|disable|restart|status|logs|edit|prune}"
      echo "  install [版本]   下载安装 mihomo（默认 ${DEFAULT_VERSION}，装到 ${BIN_PATH}）"
      echo "  update  [版本]   强制重装（升级/修复）"
      echo "  config           部署项目 config.yaml 到 ${CONFIG_PATH} 并校验"
      echo "  config pull      把 ${CONFIG_PATH} 回收进项目"
      echo "  test             校验 ${CONFIG_PATH} 语法"
      echo "  on | start       开启服务 + 写系统代理环境变量"
      echo "  off | stop       关闭服务 + 清系统代理环境变量"
      echo "  enable           永久开启（开机自启）"
      echo "  disable          永久关闭"
      echo "  restart          重启服务"
      echo "  status           查看状态"
      echo "  logs [-f]        查看日志"
      echo "  edit             编辑 ${CONFIG_PATH}"
      echo "  prune            清理旧残留（/usr/bin/mihomo、crontab @reboot）"
      exit 1
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
else
  echo "[警告] 不要 source 本脚本，请直接运行: ./$(basename "$0") <子命令>" >&2
fi
