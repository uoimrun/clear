#!/usr/bin/env bash
set -euo pipefail

############################################################
# 一键执行 = 立刻清理 + 过程输出 + 前后对比 + 节省空间统计
# 同时：
# 1) 脚本下载/保存到 /root/clear/ （必须留在本地）
# 2) 清理系统日志/SSH日志/缓存/tmp/包缓存/内存缓存
# 3) 删除网站备份大文件（www备份、tar/zip/sql/backup等）
# 4) 写入 cron：每天 04:00 自动执行同样清理
############################################################

# ====== 存放位置（你要求 root 中） ======
BASE_DIR="/root/clear"
LOCAL_SCRIPT="${BASE_DIR}/clean.sh"
LOG_FILE="${BASE_DIR}/clean_run.log"
CRON_SCHEDULE="0 4 * * *"

# ====== 清理策略（你要狠） ======
JOURNAL_KEEP_DAYS="1"
JOURNAL_MAX_SIZE="150M"
ROTATE_DELETE_DAYS="1"     # rotate只留1天
TMP_DELETE_DAYS="3"
CACHE_OLD_DAYS="30"
TRUNCATE_IF_BIGGER_MB="1"  # SSH日志这类超过1MB就清空（更狠）
DROP_CACHES_LEVEL="3"      # 内存缓存清理强度：3最狠

# ====== 网站备份清理（重点） ======
# 你可以按实际情况增加路径
WWW_DIRS=(
  "/www"
  "/www/wwwroot"
  "/var/www"
  "/home/www"
)

# 常见备份目录关键字（遇到就删里面的大文件）
BACKUP_DIR_KEYWORDS=("backup" "backups" "bak" "dump" "dumps" "archive" "archives")

# 常见备份大文件后缀（遇到就删）
BACKUP_EXTS=("tar" "tar.gz" "tgz" "zip" "7z" "rar" "gz" "bz2" "xz" "sql" "sql.gz" "dump" "bak")

# 删除备份文件的最小大小阈值（避免误删小文件）
DELETE_BACKUP_MIN_SIZE_MB="10"

# ====== 输出控制 ======
SHOW_DELETED_LIST="true"   # true会打印删除的文件路径（有点刷屏，但你要看过程）
SILENT_CRON="true"         # 定时任务执行时是否把输出写到本地LOG_FILE（避免邮件）

# ====== 美化输出 ======
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
  sec "检查依赖（存在就跳过）"
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "缺少 curl/wget，安装 curl..."
    install_pkg curl
  else
    ok "curl/wget 已存在 ✅"
  fi

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
  else
    ok "cron 已存在 ✅"
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

truncate_if_big(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  local size_mb
  size_mb=$(du -m "$f" 2>/dev/null | awk "{print \$1}" || echo 0)
  if [[ "${size_mb:-0}" -ge "$TRUNCATE_IF_BIGGER_MB" ]]; then
    : > "$f" || true
    ok "已清空：$f（原 ${size_mb}MB）"
  else
    ok "跳过：$f（${size_mb}MB，小于阈值）"
  fi
}

write_local_clean_script(){
  mkdir -p "$BASE_DIR"
  cat > "$LOCAL_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

JOURNAL_KEEP_DAYS="${JOURNAL_KEEP_DAYS}"
JOURNAL_MAX_SIZE="${JOURNAL_MAX_SIZE}"
ROTATE_DELETE_DAYS="${ROTATE_DELETE_DAYS}"
TMP_DELETE_DAYS="${TMP_DELETE_DAYS}"
CACHE_OLD_DAYS="${CACHE_OLD_DAYS}"
TRUNCATE_IF_BIGGER_MB="${TRUNCATE_IF_BIGGER_MB}"
DROP_CACHES_LEVEL="${DROP_CACHES_LEVEL}"
SHOW_DELETED_LIST="${SHOW_DELETED_LIST}"
DELETE_BACKUP_MIN_SIZE_MB="${DELETE_BACKUP_MIN_SIZE_MB}"

C_RESET="\\033[0m"
C_GREEN="\\033[1;32m"
C_YELLOW="\\033[1;33m"
C_RED="\\033[1;31m"
C_CYAN="\\033[1;36m"
C_GRAY="\\033[0;37m"
C_BOLD="\\033[1m"

ok(){ echo -e "\${C_GREEN}[信息]\${C_RESET} \$*"; }
warn(){ echo -e "\${C_YELLOW}[警告]\${C_RESET} \$*"; }
err(){ echo -e "\${C_RED}[错误]\${C_RESET} \$*"; }
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

truncate_if_big(){
  local f="\$1"
  [[ -f "\$f" ]] || return 0
  local size_mb
  size_mb=\$(du -m "\$f" 2>/dev/null | awk "{print \\\$1}" || echo 0)
  if [[ "\${size_mb:-0}" -ge "\$TRUNCATE_IF_BIGGER_MB" ]]; then
    : > "\$f" || true
    ok "已清空：\$f（原 \${size_mb}MB）"
  else
    ok "跳过：\$f（\${size_mb}MB，小于阈值）"
  fi
}

clean_journal(){
  sec "清理 journald（只保留 \${JOURNAL_KEEP_DAYS} 天 / 最大 \${JOURNAL_MAX_SIZE}）"
  if command -v journalctl >/dev/null 2>&1; then
    local before after
    before=\$(journalctl --disk-usage 2>/dev/null | sed "s/.*take up //" || true)
    ok "journald 清理前：\${before:-未知}"
    journalctl --vacuum-time="\${JOURNAL_KEEP_DAYS}d" || true
    journalctl --vacuum-size="\${JOURNAL_MAX_SIZE}" || true
    after=\$(journalctl --disk-usage 2>/dev/null | sed "s/.*take up //" || true)
    ok "journald 清理后：\${after:-未知}"
  else
    warn "未找到 journalctl，跳过"
  fi
}

clean_rotate_logs(){
  sec "删除 /var/log rotate 历史日志（> \${ROTATE_DELETE_DAYS} 天）"
  local before after del
  before=\$(get_dir_size /var/log)
  if [[ "\$SHOW_DELETED_LIST" == "true" ]]; then
    del=\$(find /var/log -type f \\( -name "*.gz" -o -name "*.xz" -o -name "*.old" -o -name "*.1" -o -name "*.2" -o -name "*.3" \\) \
      -mtime +"\${ROTATE_DELETE_DAYS}" -print -delete 2>/dev/null | wc -l || true)
  else
    del=\$(find /var/log -type f \\( -name "*.gz" -o -name "*.xz" -o -name "*.old" -o -name "*.1" -o -name "*.2" -o -name "*.3" \\) \
      -mtime +"\${ROTATE_DELETE_DAYS}" -delete 2>/dev/null | wc -l || true)
  fi
  after=\$(get_dir_size /var/log)
  ok "删除 rotate 文件数：\${del:-0}"
  ok "本模块节省：\$(bytes_to_human \$((before-after)))"
}

clean_active_logs(){
  sec "清空活跃日志（SSH/auth/secure 等）"
  truncate_if_big /var/log/auth.log
  truncate_if_big /var/log/secure
  truncate_if_big /var/log/syslog
  truncate_if_big /var/log/messages
  truncate_if_big /var/log/kern.log
  truncate_if_big /var/log/daemon.log
  truncate_if_big /var/log/dpkg.log
  truncate_if_big /var/log/apt/history.log
  truncate_if_big /var/log/apt/term.log
  truncate_if_big /var/log/nginx/access.log
  truncate_if_big /var/log/nginx/error.log
}

clean_ssh_records(){
  sec "清空登录记录（wtmp/btmp/lastlog）"
  for f in /var/log/wtmp /var/log/btmp /var/log/lastlog; do
    if [[ -f "\$f" ]]; then
      local sz
      sz=\$(du -h "\$f" 2>/dev/null | awk "{print \\\$1}" || echo "?")
      : > "\$f" || true
      ok "已清空：\$f（原 \${sz}）"
    fi
  done
}

clean_tmp(){
  sec "清理 tmp（/tmp /var/tmp，> \${TMP_DELETE_DAYS} 天）"
  local c1 c2
  c1=\$(find /tmp -mindepth 1 -mtime +"\${TMP_DELETE_DAYS}" -print -delete 2>/dev/null | wc -l || true)
  c2=\$(find /var/tmp -mindepth 1 -mtime +"\${TMP_DELETE_DAYS}" -print -delete 2>/dev/null | wc -l || true)
  ok "/tmp 删除：\${c1:-0}"
  ok "/var/tmp 删除：\${c2:-0}"
}

clean_pkg_cache(){
  sec "清理包管理器缓存"
  if command -v apt-get >/dev/null 2>&1; then apt-get clean || true; apt-get autoclean || true; ok "apt 完成"; return 0; fi
  if command -v dnf >/dev/null 2>&1; then dnf clean all -y || true; ok "dnf 完成"; return 0; fi
  if command -v yum >/dev/null 2>&1; then yum clean all -y || true; ok "yum 完成"; return 0; fi
  if command -v pacman >/dev/null 2>&1; then pacman -Sc --noconfirm || true; ok "pacman 完成"; return 0; fi
  if command -v zypper >/dev/null 2>&1; then zypper clean --all || true; ok "zypper 完成"; return 0; fi
  warn "未识别包管理器，跳过"
}

clean_var_cache(){
  sec "清理 /var/cache（> \${CACHE_OLD_DAYS} 天旧文件）"
  [[ -d /var/cache ]] || { warn "/var/cache 不存在"; return 0; }
  local before after del
  before=\$(get_dir_size /var/cache)
  if [[ "\$SHOW_DELETED_LIST" == "true" ]]; then
    del=\$(find /var/cache -type f -mtime +"\${CACHE_OLD_DAYS}" -print -delete 2>/dev/null | wc -l || true)
  else
    del=\$(find /var/cache -type f -mtime +"\${CACHE_OLD_DAYS}" -delete 2>/dev/null | wc -l || true)
  fi
  after=\$(get_dir_size /var/cache)
  ok "删除缓存文件数：\${del:-0}"
  ok "本模块节省：\$(bytes_to_human \$((before-after)))"
}

clean_www_backups(){
  sec "删除网站备份大文件（>= \${DELETE_BACKUP_MIN_SIZE_MB}MB）"
  local total_del=0

  # 目录列表由 install.sh 注入
  declare -a WWW_DIRS=(__WWW_DIRS__)
  declare -a BACKUP_DIR_KEYWORDS=(__BACKUP_DIR_KEYWORDS__)
  declare -a BACKUP_EXTS=(__BACKUP_EXTS__)

  # 1) 优先清理包含 backup 关键词的目录
  for root in "\${WWW_DIRS[@]}"; do
    [[ -d "\$root" ]] || continue
    for kw in "\${BACKUP_DIR_KEYWORDS[@]}"; do
      while IFS= read -r d; do
        [[ -d "\$d" ]] || continue
        ok "备份目录命中：\$d"
        if [[ "\$SHOW_DELETED_LIST" == "true" ]]; then
          c=\$(find "\$d" -type f -size +"\${DELETE_BACKUP_MIN_SIZE_MB}"M -print -delete 2>/dev/null | wc -l || true)
        else
          c=\$(find "\$d" -type f -size +"\${DELETE_BACKUP_MIN_SIZE_MB}"M -delete 2>/dev/null | wc -l || true)
        fi
        total_del=\$((total_del + c))
      done < <(find "\$root" -type d -iname "*\${kw}*" 2>/dev/null || true)
    done
  done

  # 2) 清理 www 下常见备份后缀的大文件
  for root in "\${WWW_DIRS[@]}"; do
    [[ -d "\$root" ]] || continue
    for ext in "\${BACKUP_EXTS[@]}"; do
      if [[ "\$SHOW_DELETED_LIST" == "true" ]]; then
        c=\$(find "\$root" -type f -iname "*.\${ext}" -size +"\${DELETE_BACKUP_MIN_SIZE_MB}"M -print -delete 2>/dev/null | wc -l || true)
      else
        c=\$(find "\$root" -type f -iname "*.\${ext}" -size +"\${DELETE_BACKUP_MIN_SIZE_MB}"M -delete 2>/dev/null | wc -l || true)
      fi
      total_del=\$((total_del + c))
    done
  done

  ok "网站备份文件删除数量（>=阈值）：\$total_del"
}

clean_memory(){
  sec "清理内存缓存（drop_caches=\${DROP_CACHES_LEVEL}）"
  if [[ ! -w /proc/sys/vm/drop_caches ]]; then
    warn "无法写入 drop_caches，跳过"
    return 0
  fi
  ok "清理前内存："; free -h || true
  sync || true
  echo "\${DROP_CACHES_LEVEL}" > /proc/sys/vm/drop_caches || true
  ok "清理后内存："; free -h || true
}

main(){
  USED_BEFORE="\$(get_used_bytes)"
  VARLOG_BEFORE="\$(get_dir_size /var/log)"
  VARCACHE_BEFORE="\$(get_dir_size /var/cache)"
  TMP_BEFORE="\$(get_dir_size /tmp)"

  sec "清理前快照"
  snapshot_disk
  snapshot_mem
  line

  clean_journal
  clean_rotate_logs
  clean_active_logs
  clean_ssh_records
  clean_tmp
  clean_pkg_cache
  clean_var_cache
  clean_www_backups
  clean_memory

  sync || true

  USED_AFTER="\$(get_used_bytes)"
  VARLOG_AFTER="\$(get_dir_size /var/log)"
  VARCACHE_AFTER="\$(get_dir_size /var/cache)"
  TMP_AFTER="\$(get_dir_size /tmp)"

  SAVED=\$(( USED_BEFORE - USED_AFTER ))
  SAVED_LOG=\$(( VARLOG_BEFORE - VARLOG_AFTER ))
  SAVED_CACHE=\$(( VARCACHE_BEFORE - VARCACHE_AFTER ))
  SAVED_TMP=\$(( TMP_BEFORE - TMP_AFTER ))

  sec "清理后快照"
  snapshot_disk
  snapshot_mem
  line

  sec "清理总结（节省空间）"
  ok "总节省：\$(bytes_to_human "\$SAVED")"
  ok "/var/log 节省：\$(bytes_to_human "\$SAVED_LOG")"
  ok "/var/cache 节省：\$(bytes_to_human "\$SAVED_CACHE")"
  ok "/tmp 节省：\$(bytes_to_human "\$SAVED_TMP")"
  line
  ok "完成 ✅"
}
main
EOF

  # 注入数组内容
  # bash数组用空格分隔，需要带引号
  local dirs keywords exts
  dirs=$(printf '"%s" ' "${WWW_DIRS[@]}")
  keywords=$(printf '"%s" ' "${BACKUP_DIR_KEYWORDS[@]}")
  exts=$(printf '"%s" ' "${BACKUP_EXTS[@]}")

  sed -i \
    -e "s|__WWW_DIRS__|${dirs}|g" \
    -e "s|__BACKUP_DIR_KEYWORDS__|${keywords}|g" \
    -e "s|__BACKUP_EXTS__|${exts}|g" \
    "$LOCAL_SCRIPT"

  chmod 755 "$LOCAL_SCRIPT"
  ok "已保存清理脚本到本地：${C_BLUE}${LOCAL_SCRIPT}${C_RESET}"
}

setup_cron(){
  sec "设置定时任务：每天凌晨 04:00 自动清理"
  local cron_cmd
  if [[ "$SILENT_CRON" == "true" ]]; then
    cron_cmd="${CRON_SCHEDULE} bash ${LOCAL_SCRIPT} >> ${LOG_FILE} 2>&1"
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE" || true
  else
    cron_cmd="${CRON_SCHEDULE} bash ${LOCAL_SCRIPT}"
  fi

  tmpfile="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$LOCAL_SCRIPT" > "$tmpfile" || true
  echo "$cron_cmd" >> "$tmpfile"
  crontab "$tmpfile"
  rm -f "$tmpfile"

  ok "cron 已写入 ✅：${C_BLUE}${cron_cmd}${C_RESET}"
}

run_now(){
  sec "现在立刻开始清理（你要的一键执行就清）"
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
