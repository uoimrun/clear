#!/usr/bin/env bash
set -euo pipefail

############################################
# 一键执行=立刻清理（极简输出）
# - journald 仅保留1天
# - 清理 /var/log rotate 旧日志
# - 清空活跃日志（按大小阈值，避免无限增长）
# - SSH 登录相关日志：auth.log / secure / wtmp / btmp / lastlog
# - 清理 tmp / cache / 包管理器缓存
# - 输出：清理前 -> 清理后 -> 节省多少空间
############################################

# ====== 你可以改的参数（默认很狠，但尽量不破坏结构） ======
JOURNAL_KEEP_DAYS="1"        # journal 保留天数
JOURNAL_MAX_SIZE="150M"      # journal 最大占用
ROTATE_DELETE_DAYS="2"       # /var/log rotate 文件保留天数
TMP_DELETE_DAYS="3"          # /tmp /var/tmp 保留天数
CACHE_OLD_DAYS="30"          # /var/cache 删除超过多少天的旧文件
TRUNCATE_IF_BIGGER_MB="20"   # 活跃日志超过多少 MB 就清空（不是删除文件）

# ====== 极简美化输出 ======
C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_BOLD="\033[1m"

msg(){ echo -e "${C_GREEN}>>${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}!!${C_RESET} $*"; }

need_root(){
  [[ $EUID -eq 0 ]] || { echo -e "${C_RED}需要 root：sudo bash <(curl ...)${C_RESET}"; exit 1; }
}

bytes_to_human() {
  local bytes="$1"
  awk -v B="$bytes" 'function human(x){
    s="B KB MB GB TB PB"; split(s,a," ");
    for(i=1; x>=1024 && i<6; i++) x/=1024;
    return sprintf("%.2f %s", x, a[i]);
  } BEGIN{print human(B)}'
}

get_used_bytes() {
  df -B1 --output=source,used | awk '
    NR>1 && $1 !~ /tmpfs|devtmpfs/ {sum += $2}
    END{print sum+0}
  '
}

hot_snapshot(){
  echo -e "${C_BOLD}磁盘：${C_RESET}"
  df -hT | sed -n '1p;/^\/dev/p'
  echo -e "${C_BOLD}热点：${C_RESET}"
  du -sh /var/log /var/cache /tmp /var/tmp 2>/dev/null || true
}

# 清空日志（不删文件不删结构）
truncate_if_big(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  local size_mb
  size_mb=$(du -m "$f" 2>/dev/null | awk '{print $1}' || echo 0)
  if [[ "${size_mb:-0}" -ge "$TRUNCATE_IF_BIGGER_MB" ]]; then
    : > "$f" || true
  fi
}

clean_journal(){
  command -v journalctl >/dev/null 2>&1 || return 0
  # 只保留1天 + 限制最大占用
  journalctl --vacuum-time="${JOURNAL_KEEP_DAYS}d" >/dev/null 2>&1 || true
  journalctl --vacuum-size="${JOURNAL_MAX_SIZE}" >/dev/null 2>&1 || true
}

clean_rotate_logs(){
  # 删 rotate 旧日志/压缩包（不会动正在写的log）
  find /var/log -type f \( \
    -name "*.gz" -o -name "*.xz" -o -name "*.old" -o -name "*.1" -o -name "*.2" -o -name "*.3" \
  \) -mtime +"${ROTATE_DELETE_DAYS}" -delete 2>/dev/null || true
}

clean_active_logs(){
  # 重点：SSH相关（auth.log / secure）
  truncate_if_big /var/log/auth.log
  truncate_if_big /var/log/secure
  truncate_if_big /var/log/syslog
  truncate_if_big /var/log/messages
  truncate_if_big /var/log/kern.log
  truncate_if_big /var/log/daemon.log
  truncate_if_big /var/log/dpkg.log
  truncate_if_big /var/log/apt/history.log
  truncate_if_big /var/log/apt/term.log

  # nginx/apache（如果有）
  truncate_if_big /var/log/nginx/access.log
  truncate_if_big /var/log/nginx/error.log
  truncate_if_big /var/log/apache2/access.log
  truncate_if_big /var/log/apache2/error.log
}

clean_ssh_login_db(){
  # 这些是登录记录数据库文件，很多机器会膨胀
  # 清空（不删文件）
  for f in /var/log/wtmp /var/log/btmp /var/log/lastlog; do
    [[ -f "$f" ]] && : > "$f" || true
  done
}

clean_tmp(){
  find /tmp -mindepth 1 -mtime +"${TMP_DELETE_DAYS}" -delete 2>/dev/null || true
  find /var/tmp -mindepth 1 -mtime +"${TMP_DELETE_DAYS}" -delete 2>/dev/null || true
}

clean_pkg_cache(){
  if command -v apt-get >/dev/null 2>&1; then
    apt-get clean >/dev/null 2>&1 || true
    apt-get autoclean >/dev/null 2>&1 || true
  fi
  if command -v dnf >/dev/null 2>&1; then dnf clean all -y >/dev/null 2>&1 || true; fi
  if command -v yum >/dev/null 2>&1; then yum clean all -y >/dev/null 2>&1 || true; fi
  if command -v pacman >/dev/null 2>&1; then pacman -Sc --noconfirm >/dev/null 2>&1 || true; fi
  if command -v zypper >/dev/null 2>&1; then zypper clean --all >/dev/null 2>&1 || true; fi
}

clean_system_cache(){
  [[ -d /var/cache ]] || return 0
  find /var/cache -type f -mtime +"${CACHE_OLD_DAYS}" -delete 2>/dev/null || true
}

main(){
  need_root

  USED_BEFORE="$(get_used_bytes)"

  echo -e "${C_BOLD}清理前：${C_RESET}"
  hot_snapshot
  echo ""

  # ===== 开始清理（不输出过程）=====
  clean_journal
  clean_rotate_logs
  clean_active_logs
  clean_ssh_login_db
  clean_tmp
  clean_pkg_cache
  clean_system_cache

  sync || true

  USED_AFTER="$(get_used_bytes)"
  SAVED=$(( USED_BEFORE - USED_AFTER ))

  echo ""
  echo -e "${C_BOLD}清理后：${C_RESET}"
  hot_snapshot
  echo ""

  echo -e "${C_BOLD}节省空间：${C_RESET} $(bytes_to_human "$SAVED")"
}

main "$@"
