#!/usr/bin/env bash
set -euo pipefail

############################################################
# 一键执行 = 立刻清理 + 过程输出 + 前后对比 + 节省空间
# journald 全清空、/var/log 全清空、SSH日志全清空
# 同时：tmp/cache/包缓存/网站备份/内存缓存
# 保存脚本到 /root/clear/clean.sh
# 配置 cron：每天凌晨 04:00 自动执行
############################################################

BASE_DIR="/root/clear"
LOCAL_SCRIPT="${BASE_DIR}/clean.sh"
CRON_TIME="04:00"
CRON_SCHEDULE="0 4 * * *"

# 网站目录（按需增删）
WWW_DIRS=(
  "/www"
  "/www/wwwroot"
  "/var/www"
  "/home/www"
)

BACKUP_DIR_KEYWORDS=("backup" "backups" "bak" "dump" "dumps" "archive" "archives")
BACKUP_EXTS=("tar" "tar.gz" "tgz" "zip" "7z" "rar" "gz" "bz2" "xz" "sql" "sql.gz" "dump" "bak")

# ===== 全部改成 1 =====
DELETE_BACKUP_MIN_SIZE_MB="1"  # >=1MB 的备份文件就删
TMP_DELETE_DAYS="1"            # /tmp /var/tmp 删除超过 1 天的
CACHE_OLD_DAYS="1"             # /var/cache 删除超过 1 天的
DROP_CACHES_LEVEL="3"          # 内存清理（狠）

SHOW_DELETED_LIST="false" 

# ===== 输出 =====
C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_CYAN="\033[1;36m"
C_GRAY="\033[0;37m"
C_BOLD="\033[1m"

ok(){ echo -e "${C_GREEN}[信息]${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}[警告]${C_RESET} $*"; }
err(){ echo -e "${C_RED}[错误]${C_RESET} $*"; }
sec(){ echo -e "\n${C_CYAN}${C_BOLD}==> $*${C_RESET}"; }
line(){ echo -e "${C_GRAY}-----------------------------------------------------${C_RESET}"; }

need_root(){
  [[ $EUID -eq 0 ]] || { err "需要 root 权限：sudo bash <(curl ...)"; exit 1; }
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

install_pkg(){
  local pkg="$1"
  local pm
  pm="$(detect_pm)"
  case "$pm" in
    apt) apt-get update -y && apt-get install -y "$pkg" ;;
    dnf) dnf install -y "$pkg" ;;
    yum) yum install -y "$pkg" ;;
    pacman) pacman -Sy --noconfirm "$pkg" ;;
    zypper) zypper --non-interactive install "$pkg" ;;
    *) err "无法识别包管理器，请手动安装：$pkg"; exit 1 ;;
  esac
}

ensure_deps(){
  # curl/wget
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "缺少 curl/wget，安装 curl..."
    install_pkg curl
  fi

  # cron
  if ! command -v crontab >/dev/null 2>&1; then
    warn "缺少 cron（crontab），安装..."
    if command -v apt-get >/dev/null 2>&1; then
      install_pkg cron
      systemctl enable --now cron 2>/dev/null || true
    else
      install_pkg cronie || install_pkg cron
      systemctl enable --now crond 2>/dev/null || true
      systemctl enable --now cron 2>/dev/null || true
    fi
  fi
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

get_dir_size() {
  local p="$1"
  [[ -d "$p" ]] && du -sb "$p" 2>/dev/null | awk "{print \$1}" || echo 0
}

snapshot_disk(){
  echo -e "${C_BOLD}磁盘：${C_RESET}"
  df -hT | sed -n '1p;/^\/dev/p'
  echo -e "${C_BOLD}热点：${C_RESET}"
  du -sh /var/log /var/cache /tmp /var/tmp 2>/dev/null || true
}

snapshot_mem(){
  echo -e "${C_BOLD}内存：${C_RESET}"
  free -h || true
}

write_local_clean_script(){
  mkdir -p "$BASE_DIR"
  local dirs keywords exts
  dirs=$(printf '"%s" ' "${WWW_DIRS[@]}")
  keywords=$(printf '"%s" ' "${BACKUP_DIR_KEYWORDS[@]}")
  exts=$(printf '"%s" ' "${BACKUP_EXTS[@]}")

  cat > "$LOCAL_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TMP_DELETE_DAYS="${TMP_DELETE_DAYS}"
CACHE_OLD_DAYS="${CACHE_OLD_DAYS}"
DELETE_BACKUP_MIN_SIZE_MB="${DELETE_BACKUP_MIN_SIZE_MB}"
DROP_CACHES_LEVEL="${DROP_CACHES_LEVEL}"
SHOW_DELETED_LIST="${SHOW_DELETED_LIST}"

declare -a WWW_DIRS=(${dirs})
declare -a BACKUP_DIR_KEYWORDS=(${keywords})
declare -a BACKUP_EXTS=(${exts})

C_RESET="\\033[0m"
C_GREEN="\\033[1;32m"
C_YELLOW="\\033[1;33m"
C_RED="\\033[1;31m"
C_CYAN="\\033[1;36m"
C_GRAY="\\033[0;37m"
C_BOLD="\\033[1m"

ok(){ echo -e "\${C_GREEN}[信息]\${C_RESET} \$*"; }
warn(){ echo -e "\${C_YELLOW}[警告]\${C_RESET} \$*"; }
sec(){ echo -e "\\n\${C_CYAN}\${C_BOLD}==> \$*\${C_RESET}"; }
line(){ echo -e "\${C_GRAY}-----------------------------------------------------\${C_RESET}"; }

bytes_to_human() {
  local bytes="\$1"
  awk -v B="\$bytes" 'function human(x){
    s="B KB MB GB TB PB"; split(s,a," ");
    for(i=1; x>=1024 && i<6; i++) x/=1024;
    return sprintf("%.2f %s", x, a[i]);
  } BEGIN{print human(B)}'
}

get_used_bytes() {
  df -B1 --output=source,used | awk '
    NR>1 && \$1 !~ /tmpfs|devtmpfs/ {sum += \$2}
    END{print sum+0}
  '
}

get_dir_size() {
  local p="\$1"
  [[ -d "\$p" ]] && du -sb "\$p" 2>/dev/null | awk "{print \\\$1}" || echo 0
}

snapshot_disk(){
  echo -e "\${C_BOLD}磁盘：\${C_RESET}"
  df -hT | sed -n '1p;/^\\/dev/p'
  echo -e "\${C_BOLD}热点：\${C_RESET}"
  du -sh /var/log /var/cache /tmp /var/tmp 2>/dev/null || true
}

snapshot_mem(){
  echo -e "\${C_BOLD}内存：\${C_RESET}"
  free -h || true
}

clean_journald_all(){
  sec "清理 journald"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=1s >/dev/null 2>&1 || true
    journalctl --vacuum-size=1B >/dev/null 2>&1 || true
    ok "journald：已清空"
  else
    ok "journald：跳过"
  fi
}

delete_rotated_logs(){
  sec "删除 rotate 历史日志"
  local del
  if [[ "\$SHOW_DELETED_LIST" == "true" ]]; then
    del=\$(find /var/log -type f \\( -name "*.gz" -o -name "*.xz" -o -name "*.old" -o -name "*.1" -o -name "*.2" -o -name "*.3" \\) \
      -print -delete 2>/dev/null | wc -l || true)
  else
    del=\$(find /var/log -type f \\( -name "*.gz" -o -name "*.xz" -o -name "*.old" -o -name "*.1" -o -name "*.2" -o -name "*.3" \\) \
      -delete 2>/dev/null | wc -l || true)
  fi
  ok "rotate 删除：\${del:-0}"
}

truncate_all_var_log(){
  sec "清空 /var/log 全部日志"
  local count
  count=0
  while IFS= read -r f; do
    : > "\$f" 2>/dev/null || true
    count=\$((count+1))
  done < <(find /var/log -type f 2>/dev/null || true)
  ok "日志清空文件数：\$count"
}

clean_ssh_login_records(){
  sec "清空 SSH/登录记录"
  for f in /var/log/auth.log /var/log/secure /var/log/wtmp /var/log/btmp /var/log/lastlog; do
    [[ -f "\$f" ]] && : > "\$f" 2>/dev/null || true
  done
  ok "SSH 日志/记录：已清空"
}

clean_tmp(){
  sec "清理 tmp"
  local c1 c2
  c1=\$(find /tmp -mindepth 1 -mtime +"\$TMP_DELETE_DAYS" -delete 2>/dev/null | wc -l || true)
  c2=\$(find /var/tmp -mindepth 1 -mtime +"\$TMP_DELETE_DAYS" -delete 2>/dev/null | wc -l || true)
  ok "/tmp 删除：\${c1:-0}"
  ok "/var/tmp 删除：\${c2:-0}"
}

clean_pkg_cache(){
  sec "清理包缓存"
  if command -v apt-get >/dev/null 2>&1; then apt-get clean >/dev/null 2>&1 || true; apt-get autoclean >/dev/null 2>&1 || true; ok "apt：完成"; return 0; fi
  if command -v dnf >/dev/null 2>&1; then dnf clean all -y >/dev/null 2>&1 || true; ok "dnf：完成"; return 0; fi
  if command -v yum >/dev/null 2>&1; then yum clean all -y >/dev/null 2>&1 || true; ok "yum：完成"; return 0; fi
  if command -v pacman >/dev/null 2>&1; then pacman -Sc --noconfirm >/dev/null 2>&1 || true; ok "pacman：完成"; return 0; fi
  if command -v zypper >/dev/null 2>&1; then zypper clean --all >/dev/null 2>&1 || true; ok "zypper：完成"; return 0; fi
  ok "包缓存：跳过"
}

clean_var_cache(){
  sec "清理 /var/cache"
  [[ -d /var/cache ]] || { ok "/var/cache：跳过"; return 0; }
  local del
  del=\$(find /var/cache -type f -mtime +"\$CACHE_OLD_DAYS" -delete 2>/dev/null | wc -l || true)
  ok "/var/cache 删除：\${del:-0}"
}

clean_www_backups(){
  sec "删除网站备份"
  local total_del=0

  for root in "\${WWW_DIRS[@]}"; do
    [[ -d "\$root" ]] || continue

    for kw in "\${BACKUP_DIR_KEYWORDS[@]}"; do
      while IFS= read -r d; do
        [[ -d "\$d" ]] || continue
        c=\$(find "\$d" -type f -size +"\${DELETE_BACKUP_MIN_SIZE_MB}"M -delete 2>/dev/null | wc -l || true)
        total_del=\$((total_del + c))
      done < <(find "\$root" -type d -iname "*\${kw}*" 2>/dev/null || true)
    done

    for ext in "\${BACKUP_EXTS[@]}"; do
      c=\$(find "\$root" -type f -iname "*.\${ext}" -size +"\${DELETE_BACKUP_MIN_SIZE_MB}"M -delete 2>/dev/null | wc -l || true)
      total_del=\$((total_del + c))
    done
  done

  ok "网站备份删除：\$total_del"
}

clean_memory(){
  sec "清理内存缓存"
  sync || true
  [[ -w /proc/sys/vm/drop_caches ]] && echo "\$DROP_CACHES_LEVEL" > /proc/sys/vm/drop_caches || true
  ok "内存缓存：完成"
}

main(){
  USED_BEFORE="\$(get_used_bytes)"

  sec "清理前快照"
  snapshot_disk
  snapshot_mem
  line

  clean_journald_all
  delete_rotated_logs
  truncate_all_var_log
  clean_ssh_login_records
  clean_tmp
  clean_pkg_cache
  clean_var_cache
  clean_www_backups
  clean_memory

  sync || true

  USED_AFTER="\$(get_used_bytes)"
  SAVED=\$(( USED_BEFORE - USED_AFTER ))

  sec "清理后快照"
  snapshot_disk
  snapshot_mem
  line

  sec "节省空间"
  ok "总节省：\$(bytes_to_human "\$SAVED")"
  ok "已添加定时任务：每天 ${CRON_TIME} 执行"
  ok "完成 ✅"
}
main
EOF

  chmod 755 "$LOCAL_SCRIPT"
}

setup_cron(){
  local cron_line="${CRON_SCHEDULE} bash ${LOCAL_SCRIPT} >/dev/null 2>&1"
  tmpfile="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$LOCAL_SCRIPT" > "$tmpfile" || true
  echo "$cron_line" >> "$tmpfile"
  crontab "$tmpfile"
  rm -f "$tmpfile"
}

run_now(){
  sec "开始清理"
  bash "$LOCAL_SCRIPT"
}

main(){
  need_root
  ensure_deps
  write_local_clean_script
  setup_cron
  run_now
}

main
