#!/usr/bin/env bash
set -euo pipefail

############################################################
# 一键安装：安全清理 + 自更新 + 定时任务 (cron 04:00)
# - 所有文件部署到 /root/clear/
# - 每次运行自动拉取最新清理脚本并覆盖
# - 清理后输出：清理前后对比 + 节省多少空间（中文）
# - 自动安装依赖：cron / curl or wget
############################################################

#############################
# 你只需要改这一项：仓库清理脚本 RAW 地址
#############################
# 建议你仓库里放一个：clean.sh（清理脚本本体）
# 如果你希望直接用当前 install.sh 里面内置清理脚本，则不需要改这个
RAW_CLEAN_URL_DEFAULT=""

#############################
# 部署目录（强制 root 下）
#############################
BASE_DIR="/root/clear"
LOCAL_CLEAN_SCRIPT="${BASE_DIR}/clean.sh"
UPDATER_SCRIPT="${BASE_DIR}/update_and_run.sh"
LOG_FILE="${BASE_DIR}/run.log"
REPORT_DIR="${BASE_DIR}/reports"
CRON_SCHEDULE="0 4 * * *"

#############################
# 清理策略（默认：日志只保留1天）
#############################
JOURNAL_KEEP_DAYS="1"
JOURNAL_MAX_SIZE="200M"
LOGROTATE_DELETE_DAYS="3"
TMP_DELETE_DAYS="7"
OLD_CACHE_DAYS="30"

#############################
# 美化输出（中文）
#############################
C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_CYAN="\033[1;36m"
C_BLUE="\033[1;34m"
C_GRAY="\033[0;37m"
C_BOLD="\033[1m"

ok(){ echo -e "${C_GREEN}[信息]${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}[警告]${C_RESET} $*"; }
err(){ echo -e "${C_RED}[错误]${C_RESET} $*"; }
title(){
  echo -e "\n${C_CYAN}${C_BOLD}=====================================================${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}$*${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}=====================================================${C_RESET}\n"
}
line(){ echo -e "${C_GRAY}-----------------------------------------------------${C_RESET}"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请用 root 执行：sudo bash $0"
    exit 1
  fi
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then echo "zypper"
  else echo "unknown"
  fi
}

install_pkg() {
  local pkg="$1"
  local pm
  pm="$(detect_pm)"

  ok "正在安装依赖：${C_BLUE}${pkg}${C_RESET}（包管理器：${C_BLUE}${pm}${C_RESET}）"

  case "$pm" in
    apt)
      apt-get update -y
      apt-get install -y "$pkg"
      ;;
    dnf)
      dnf install -y "$pkg"
      ;;
    yum)
      yum install -y "$pkg"
      ;;
    pacman)
      pacman -Sy --noconfirm "$pkg"
      ;;
    zypper)
      zypper --non-interactive install "$pkg"
      ;;
    *)
      err "无法识别包管理器，请手动安装：$pkg"
      exit 1
      ;;
  esac
}

ensure_tools() {
  title "1/6 检查并安装必要依赖（cron / curl 或 wget）"

  # curl/wget 至少存在一个
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "系统缺少 curl/wget，准备安装 curl..."
    install_pkg curl
  else
    ok "curl/wget 已存在 ✅"
  fi

  # cron/cronie
  if ! command -v crontab >/dev/null 2>&1; then
    warn "系统缺少 cron（crontab），准备安装..."
    # Debian/Ubuntu: cron；其他多为 cronie
    if command -v apt-get >/dev/null 2>&1; then
      install_pkg cron
      systemctl enable --now cron 2>/dev/null || true
    else
      install_pkg cronie || install_pkg cron
      systemctl enable --now crond 2>/dev/null || true
      systemctl enable --now cron 2>/dev/null || true
    fi
  else
    ok "cron 已存在 ✅"
  fi
}

mkdir_layout() {
  title "2/6 创建目录（部署到 /root）"
  mkdir -p "$BASE_DIR" "$REPORT_DIR"
  ok "部署目录：${C_BLUE}${BASE_DIR}${C_RESET}"
  ok "报告目录：${C_BLUE}${REPORT_DIR}${C_RESET}"
  ok "日志文件：${C_BLUE}${LOG_FILE}${C_RESET}"
}

write_builtin_clean_script() {
  # 如果你不想依赖仓库 clean.sh，就用内置这份
  cat > "$LOCAL_CLEAN_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

###############################
# 清理脚本（中文美化 + 节省空间报告）
# 默认策略：
# - journald 日志只保留 1 天
# - /var/log rotate 旧日志保留 3 天
# - tmp 文件超过 7 天删
# - cache 旧文件超过 30 天删
###############################

# 参数（可选）
DRY_RUN=false
INTERACTIVE=false
BACKUP=false
CLEAN_ALL=false
BACKUP_DIR="/root/clear/backup_$(date +%F_%H%M%S)"

# 策略（安装脚本会替换）
JOURNAL_KEEP_DAYS="__JOURNAL_KEEP_DAYS__"
JOURNAL_MAX_SIZE="__JOURNAL_MAX_SIZE__"
LOGROTATE_DELETE_DAYS="__LOGROTATE_DELETE_DAYS__"
TMP_DELETE_DAYS="__TMP_DELETE_DAYS__"
OLD_CACHE_DAYS="__OLD_CACHE_DAYS__"

# 美化输出
C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_CYAN="\033[1;36m"
C_BLUE="\033[1;34m"
C_GRAY="\033[0;37m"
C_BOLD="\033[1m"

ok(){ echo -e "${C_GREEN}[信息]${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}[警告]${C_RESET} $*"; }
err(){ echo -e "${C_RED}[错误]${C_RESET} $*"; }
sec(){ echo -e "\n${C_CYAN}${C_BOLD}==> $*${C_RESET}"; }
line(){ echo -e "${C_GRAY}-----------------------------------------------------${C_RESET}"; }

run_cmd() {
  local cmd="$*"
  if $DRY_RUN; then
    echo "[预览模式] $cmd"
  else
    eval "$cmd"
  fi
}

confirm() {
  if ! $INTERACTIVE; then return 0; fi
  read -rp ">>> 是否执行本模块？[y/N] " ans
  [[ "$ans" =~ ^[yY]$ ]]
}

usage() {
  cat <<EOFUSAGE
用法：sudo bash $0 [选项]

选项：
  --dry-run        预览模式（不实际删除）
  --interactive    交互模式（每段确认）
  --backup         清理前备份关键日志
  --clean-all      更激进清理（含 docker/pip/npm 等）

示例：
  sudo $0 --dry-run --interactive
  sudo $0 --backup
EOFUSAGE
}

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --interactive) INTERACTIVE=true; shift ;;
    --backup) BACKUP=true; shift ;;
    --clean-all) CLEAN_ALL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数：$1"; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  err "请使用 root 执行（sudo）"
  exit 1
fi

# 报告用：字节转可读
bytes_to_human() {
  local bytes="$1"
  awk -v B="$bytes" 'function human(x){
    s="B KB MB GB TB PB"; split(s,a," ");
    for(i=1; x>=1024 && i<6; i++) x/=1024;
    return sprintf("%.2f %s", x, a[i]);
  } BEGIN{print human(B)}'
}

# 获取系统总 used（忽略 tmpfs/devtmpfs）
get_used_bytes() {
  df -B1 --output=source,used | awk '
    NR>1 && $1 !~ /tmpfs|devtmpfs/ {sum += $2}
    END{print sum+0}
  '
}

get_dir_bytes() {
  local path="$1"
  if [[ -d "$path" ]]; then
    du -sb "$path" 2>/dev/null | awk "{print \$1}" || echo 0
  else
    echo 0
  fi
}

snapshot() {
  echo -e "${C_BOLD}磁盘概况：${C_RESET}"
  df -hT | sed -n '1p;/^\/dev/p'
  echo ""
  echo -e "${C_BOLD}热点目录：${C_RESET}"
  du -sh /var/log /var/cache /tmp /var/tmp 2>/dev/null || true
}

do_backup() {
  $BACKUP || { warn "备份未启用（可加 --backup）"; return 0; }
  confirm || { warn "跳过备份"; return 0; }

  sec "备份关键日志"
  ok "备份目录：${C_BLUE}${BACKUP_DIR}${C_RESET}"
  run_cmd "mkdir -p '$BACKUP_DIR'"

  run_cmd "tar -czf '$BACKUP_DIR/var_log_important.tgz' \
      /var/log/syslog /var/log/messages /var/log/auth.log /var/log/secure \
      /var/log/kern.log /var/log/dmesg 2>/dev/null || true"

  run_cmd "tar -czf '$BACKUP_DIR/journal.tgz' /var/log/journal 2>/dev/null || true"
  ok "备份完成 ✅"
}

clean_journal() {
  command -v journalctl >/dev/null 2>&1 || { warn "未找到 journalctl，跳过 journald 清理"; return 0; }
  confirm || { warn "跳过 journald 清理"; return 0; }

  sec "清理 journald 日志（只保留 ${JOURNAL_KEEP_DAYS} 天，最大 ${JOURNAL_MAX_SIZE}）"
  run_cmd "journalctl --vacuum-time=${JOURNAL_KEEP_DAYS}d"
  run_cmd "journalctl --vacuum-size=${JOURNAL_MAX_SIZE}"
  ok "journald 清理完成 ✅"
}

clean_rotated_logs() {
  confirm || { warn "跳过 /var/log rotate 旧日志清理"; return 0; }
  sec "清理 /var/log rotate 旧日志（超过 ${LOGROTATE_DELETE_DAYS} 天）"
  run_cmd "find /var/log -type f \\( -name '*.gz' -o -name '*.xz' -o -name '*.old' -o -name '*.1' -o -name '*.2' -o -name '*.3' \\) \
    -mtime +${LOGROTATE_DELETE_DAYS} -print -delete 2>/dev/null || true"
  ok "rotate 旧日志清理完成 ✅"
}

clean_tmp() {
  confirm || { warn "跳过 tmp 清理"; return 0; }
  sec "清理 /tmp 与 /var/tmp（超过 ${TMP_DELETE_DAYS} 天）"
  run_cmd "find /tmp -mindepth 1 -mtime +${TMP_DELETE_DAYS} -print -delete 2>/dev/null || true"
  run_cmd "find /var/tmp -mindepth 1 -mtime +${TMP_DELETE_DAYS} -print -delete 2>/dev/null || true"
  ok "tmp 清理完成 ✅"
}

clean_pkg_cache() {
  confirm || { warn "跳过包管理器缓存清理"; return 0; }
  sec "清理包管理器缓存（不会卸载系统包）"

  if command -v apt-get >/dev/null 2>&1; then
    run_cmd "apt-get clean"
    run_cmd "apt-get autoclean"
    $CLEAN_ALL && run_cmd "apt-get -y autoremove" || warn "默认不执行 autoremove（加 --clean-all 才执行）"
  fi
  if command -v dnf >/dev/null 2>&1; then run_cmd "dnf clean all"; fi
  if command -v yum >/dev/null 2>&1; then run_cmd "yum clean all"; fi
  if command -v pacman >/dev/null 2>&1; then run_cmd "pacman -Sc --noconfirm"; fi
  if command -v zypper >/dev/null 2>&1; then run_cmd "zypper clean --all"; fi

  ok "包管理器缓存清理完成 ✅"
}

clean_system_cache() {
  confirm || { warn "跳过系统 cache 清理"; return 0; }
  sec "清理 /var/cache 中超过 ${OLD_CACHE_DAYS} 天的旧文件（不删目录结构）"
  run_cmd "find /var/cache -type f -mtime +${OLD_CACHE_DAYS} -print -delete 2>/dev/null || true"
  ok "系统 cache 清理完成 ✅"
}

clean_user_cache() {
  confirm || { warn "跳过用户 cache 清理"; return 0; }
  sec "清理用户缓存（~/.cache 缩略图 + 超过 ${OLD_CACHE_DAYS} 天旧文件）"
  while IFS=: read -r _ _ uid _ _ home _; do
    [[ "$uid" -lt 1000 ]] && continue
    [[ ! -d "$home" ]] && continue
    run_cmd "rm -rf '$home/.cache/thumbnails' 2>/dev/null || true"
    if [[ -d "$home/.cache" ]]; then
      run_cmd "find '$home/.cache' -type f -mtime +${OLD_CACHE_DAYS} -print -delete 2>/dev/null || true"
    fi
  done < /etc/passwd
  ok "用户 cache 清理完成 ✅"
}

clean_extra() {
  $CLEAN_ALL || { warn "额外清理未启用（加 --clean-all）"; return 0; }
  confirm || { warn "跳过额外清理"; return 0; }

  sec "额外清理（pip/npm/gradle/docker）"
  if command -v pip >/dev/null 2>&1; then run_cmd "pip cache purge || true"; fi
  if command -v pip3 >/dev/null 2>&1; then run_cmd "pip3 cache purge || true"; fi
  if command -v npm >/dev/null 2>&1; then run_cmd "npm cache clean --force || true"; fi

  while IFS=: read -r _ _ uid _ _ home _; do
    [[ "$uid" -lt 1000 ]] && continue
    [[ ! -d "$home" ]] && continue
    [[ -d "$home/.gradle/caches" ]] && run_cmd "find '$home/.gradle/caches' -type f -mtime +30 -print -delete 2>/dev/null || true"
  done < /etc/passwd

  if command -v docker >/dev/null 2>&1; then
    warn "Docker 清理会移除未使用镜像/容器"
    run_cmd "docker system prune -af || true"
  fi

  ok "额外清理完成 ✅"
}

# ===== 清理前统计（报告）=====
USED_BEFORE="$(get_used_bytes)"
VARLOG_BEFORE="$(get_dir_bytes /var/log)"
VARCACHE_BEFORE="$(get_dir_bytes /var/cache)"
TMP_BEFORE="$(get_dir_bytes /tmp)"

ok "${C_CYAN}${C_BOLD}开始执行清理（中文报告）${C_RESET}"
line
sec "清理前快照"
snapshot
line

do_backup
clean_journal
clean_rotated_logs
clean_tmp
clean_pkg_cache
clean_system_cache
clean_user_cache
clean_extra

# ===== 清理后统计（报告）=====
USED_AFTER="$(get_used_bytes)"
VARLOG_AFTER="$(get_dir_bytes /var/log)"
VARCACHE_AFTER="$(get_dir_bytes /var/cache)"
TMP_AFTER="$(get_dir_bytes /tmp)"

SAVED_USED=$(( USED_BEFORE - USED_AFTER ))
SAVED_VARLOG=$(( VARLOG_BEFORE - VARLOG_AFTER ))
SAVED_VARCACHE=$(( VARCACHE_BEFORE - VARCACHE_AFTER ))
SAVED_TMP=$(( TMP_BEFORE - TMP_AFTER ))

sec "清理后快照"
snapshot
line

sec "清理报告（节省空间统计）"
echo -e "${C_BOLD}总节省（系统使用量变化）：${C_RESET} $(bytes_to_human "$SAVED_USED")"
echo -e "${C_BOLD}/var/log 节省：${C_RESET}             $(bytes_to_human "$SAVED_VARLOG")"
echo -e "${C_BOLD}/var/cache 节省：${C_RESET}           $(bytes_to_human "$SAVED_VARCACHE")"
echo -e "${C_BOLD}/tmp 节省：${C_RESET}                $(bytes_to_human "$SAVED_TMP")"
line

if $DRY_RUN; then
  warn "预览模式：未实际删除任何文件。"
else
  ok "清理完成 ✅"
fi
EOF

  # 替换策略占位符
  sed -i \
    -e "s/__JOURNAL_KEEP_DAYS__/${JOURNAL_KEEP_DAYS}/g" \
    -e "s/__JOURNAL_MAX_SIZE__/${JOURNAL_MAX_SIZE}/g" \
    -e "s/__LOGROTATE_DELETE_DAYS__/${LOGROTATE_DELETE_DAYS}/g" \
    -e "s/__TMP_DELETE_DAYS__/${TMP_DELETE_DAYS}/g" \
    -e "s/__OLD_CACHE_DAYS__/${OLD_CACHE_DAYS}/g" \
    "$LOCAL_CLEAN_SCRIPT"

  chmod 755 "$LOCAL_CLEAN_SCRIPT"
}

configure_journald() {
  title "4/6 配置 journald：日志只保留 1 天（推荐）"
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "系统不是 systemd（缺少 systemctl），跳过 journald 配置"
    return 0
  fi

  local conf="/etc/systemd/journald.conf"
  ok "修改：${C_BLUE}${conf}${C_RESET}（自动备份 .bak_clear）"

  if [[ -f "$conf" ]] && [[ ! -f "${conf}.bak_clear" ]]; then
    cp -a "$conf" "${conf}.bak_clear"
    ok "已备份：${conf}.bak_clear"
  fi

  grep -q "^\[Journal\]" "$conf" 2>/dev/null || echo -e "\n[Journal]" >> "$conf"

  apply_kv() {
    local key="$1"
    local value="$2"
    if grep -qE "^[#]*\s*${key}=" "$conf"; then
      sed -i -E "s|^[#]*\s*${key}=.*|${key}=${value}|g" "$conf"
    else
      echo "${key}=${value}" >> "$conf"
    fi
  }

  apply_kv "MaxRetentionSec" "1day"
  apply_kv "SystemMaxUse" "$JOURNAL_MAX_SIZE"
  apply_kv "SystemMaxFileSize" "50M"

  systemctl restart systemd-journald || true
  ok "journald 已配置并重启 ✅"
}

write_updater() {
  title "3/6 写入自更新脚本（每次覆盖保持最新）"

  cat > "$UPDATER_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${BASE_DIR}"
LOCAL_CLEAN_SCRIPT="${LOCAL_CLEAN_SCRIPT}"
LOG_FILE="${LOG_FILE}"
REPORT_DIR="${REPORT_DIR}"

RAW_CLEAN_URL="${RAW_CLEAN_URL_DEFAULT}"

# 中文美化
C_RESET="\\033[0m"
C_GREEN="\\033[1;32m"
C_YELLOW="\\033[1;33m"
C_RED="\\033[1;31m"
C_CYAN="\\033[1;36m"
C_BOLD="\\033[1m"

ok(){ echo -e "\${C_GREEN}[信息]\${C_RESET} \$*"; }
warn(){ echo -e "\${C_YELLOW}[警告]\${C_RESET} \$*"; }
err(){ echo -e "\${C_RED}[错误]\${C_RESET} \$*"; }
title(){
  echo -e "\\n\${C_CYAN}\${C_BOLD}==================== \$* ====================\${C_RESET}"
}

download_latest() {
  # 如果设置了 RAW_CLEAN_URL，就从仓库拉最新 clean.sh 覆盖本地
  if [[ -n "\$RAW_CLEAN_URL" ]]; then
    ok "检测到远程地址，开始更新清理脚本（覆盖本地保持最新）..."
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "\$RAW_CLEAN_URL" -o "\$LOCAL_CLEAN_SCRIPT"
    else
      wget -qO "\$LOCAL_CLEAN_SCRIPT" "\$RAW_CLEAN_URL"
    fi
    chmod 755 "\$LOCAL_CLEAN_SCRIPT"
    ok "更新成功 ✅"
  else
    warn "未配置远程 RAW 地址，将使用本地内置清理脚本（不联网更新）"
  fi
}

run_clean() {
  mkdir -p "\$BASE_DIR" "\$REPORT_DIR"
  touch "\$LOG_FILE" || true

  local ts
  ts="\$(date +%F_%H%M%S)"
  local report_file="\$REPORT_DIR/report_\$ts.txt"

  title "开始执行清理（\$ts）"
  {
    echo "========== 执行时间：\$ts =========="
    "\$LOCAL_CLEAN_SCRIPT"
    echo "========== 执行结束：\$(date +%F_%H%M%S) =========="
  } | tee -a "\$LOG_FILE" | tee "\$report_file" >/dev/null

  ok "本次报告已保存：\$report_file"
  ok "总日志文件：\$LOG_FILE"
}

main(){
  download_latest
  run_clean
}

main "\$@"
EOF

  chmod 755 "$UPDATER_SCRIPT"
  ok "自更新脚本已写入：${C_BLUE}${UPDATER_SCRIPT}${C_RESET}"
}

setup_cron() {
  title "5/6 配置定时任务（每天凌晨 4 点自动更新并执行）"
  local cron_line="${CRON_SCHEDULE} ${UPDATER_SCRIPT}"

  local tmpfile
  tmpfile="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$UPDATER_SCRIPT" > "$tmpfile" || true
  echo "$cron_line" >> "$tmpfile"
  crontab "$tmpfile"
  rm -f "$tmpfile"

  ok "已写入 cron：${C_BLUE}${cron_line}${C_RESET}"
  ok "查看：sudo crontab -l"
}

final_tip() {
  title "6/6 安装完成 ✅"
  ok "部署目录：${C_BLUE}${BASE_DIR}${C_RESET}"
  ok "清理脚本：${C_BLUE}${LOCAL_CLEAN_SCRIPT}${C_RESET}"
  ok "更新执行器：${C_BLUE}${UPDATER_SCRIPT}${C_RESET}"
  ok "日志文件：${C_BLUE}${LOG_FILE}${C_RESET}"
  ok "报告目录：${C_BLUE}${REPORT_DIR}${C_RESET}"
  line
  ok "强烈建议你先手动测试一次："
  echo -e "  ${C_BLUE}sudo ${UPDATER_SCRIPT}${C_RESET}"
  line
  ok "查看最近日志："
  echo -e "  ${C_BLUE}tail -n 200 ${LOG_FILE}${C_RESET}"
  line
  ok "查看本次报告（每次执行都会生成）："
  echo -e "  ${C_BLUE}ls -lh ${REPORT_DIR}${C_RESET}"
  line
  warn "如果你要从仓库拉最新 clean.sh，请把 RAW_CLEAN_URL_DEFAULT 设置为你仓库的 raw 地址（见 install.sh 顶部）"
}

main() {
  require_root
  ensure_tools
  mkdir_layout

  # 写入内置 clean.sh（即便将来你用远程更新也会覆盖它）
  write_builtin_clean_script
  ok "已写入内置清理脚本：${C_BLUE}${LOCAL_CLEAN_SCRIPT}${C_RESET}"

  write_updater
  configure_journald
  setup_cron
  final_tip
}

main "$@"
