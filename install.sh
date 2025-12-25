#!/usr/bin/env bash
set -euo pipefail

############################################
# One-Click Setup:
# - Install cron if missing (per distro)
# - Install safe cleaner script
# - Configure journald keep 1 day (if systemd exists)
# - Setup cron job: daily 04:00
############################################

CLEAN_SCRIPT_PATH="/usr/local/sbin/safe_clean_full.sh"
CRON_LOG="/var/log/safe_clean_full.log"
CRON_SCHEDULE="0 4 * * *"
CRON_CMD="$CLEAN_SCRIPT_PATH >> $CRON_LOG 2>&1"

# You can change these default values:
JOURNAL_KEEP_DAYS="1"
JOURNAL_MAX_SIZE="200M"
LOGROTATE_DELETE_DAYS="3"
TMP_DELETE_DAYS="7"
OLD_CACHE_DAYS="30"

log(){ echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){ echo -e "\033[1;31m[ERR ]\033[0m $*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root: sudo bash $0"
    exit 1
  fi
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then echo "zypper"
  else echo "unknown"
  fi
}

install_cron_if_missing() {
  # Determine if cron service exists
  # Debian/Ubuntu: cron
  # RHEL/CentOS/Fedora: cronie (service: crond)
  # Arch: cronie
  # openSUSE: cron / cronie
  if command -v crontab >/dev/null 2>&1; then
    log "cron already installed (crontab found)."
    return 0
  fi

  local pm
  pm="$(detect_pkg_mgr)"
  log "cron not found. Installing via package manager: $pm"

  case "$pm" in
    apt)
      apt-get update -y
      apt-get install -y cron
      systemctl enable --now cron || true
      ;;
    dnf)
      dnf install -y cronie
      systemctl enable --now crond || true
      ;;
    yum)
      yum install -y cronie
      systemctl enable --now crond || true
      ;;
    pacman)
      pacman -Sy --noconfirm cronie
      systemctl enable --now cronie || systemctl enable --now crond || true
      ;;
    zypper)
      zypper --non-interactive install cron || zypper --non-interactive install cronie
      systemctl enable --now cron || systemctl enable --now crond || true
      ;;
    *)
      err "Cannot detect package manager to install cron. Please install cron manually."
      exit 1
      ;;
  esac

  if command -v crontab >/dev/null 2>&1; then
    log "cron installed successfully."
  else
    err "cron installation failed (crontab still missing)."
    exit 1
  fi
}

deploy_clean_script() {
  log "Deploying cleaner script to: $CLEAN_SCRIPT_PATH"

  cat > "$CLEAN_SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

############################################
# Safe Linux Full Cleaner
# - Logs keep 1 day (journald vacuum)
# - Optional backup, dry-run, interactive
# - Multi-distro package cache clean
# - Do NOT delete critical directory structure
############################################

DRY_RUN=false
INTERACTIVE=false
BACKUP=false
CLEAN_ALL=false
BACKUP_DIR="/root/system_cleanup_backup_$(date +%F_%H%M%S)"

# Default Retention / Limits
JOURNAL_KEEP_DAYS="__JOURNAL_KEEP_DAYS__"
JOURNAL_MAX_SIZE="__JOURNAL_MAX_SIZE__"
LOGROTATE_DELETE_DAYS="__LOGROTATE_DELETE_DAYS__"
TMP_DELETE_DAYS="__TMP_DELETE_DAYS__"
OLD_CACHE_DAYS="__OLD_CACHE_DAYS__"

log(){ echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){ echo -e "\033[1;31m[ERR ]\033[0m $*"; }

run_cmd() {
  local cmd="$*"
  if $DRY_RUN; then
    echo "[DRY-RUN] $cmd"
  else
    eval "$cmd"
  fi
}

confirm() {
  if ! $INTERACTIVE; then return 0; fi
  read -rp ">>> Run this section? [y/N] " ans
  [[ "$ans" =~ ^[yY]$ ]]
}

usage(){
cat <<EOFUSAGE
Usage: sudo bash $0 [options]
  --dry-run          Preview without deleting anything
  --interactive      Ask before each module runs
  --backup           Backup key logs before cleaning
  --backup-dir DIR   Specify backup dir
  --clean-all        Enable extra cleanup (docker/npm/pip/gradle)
  --only-logs        Only clean logs
  --only-cache       Only clean caches
  --only-tmp         Only clean tmp

Examples:
  sudo $0 --dry-run --interactive
  sudo $0 --only-logs
EOFUSAGE
}

RUN_LOGS=true
RUN_CACHE=true
RUN_TMP=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --interactive) INTERACTIVE=true; shift ;;
    --backup) BACKUP=true; shift ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    --clean-all) CLEAN_ALL=true; shift ;;
    --only-logs) RUN_LOGS=true; RUN_CACHE=false; RUN_TMP=false; shift ;;
    --only-cache) RUN_LOGS=false; RUN_CACHE=true; RUN_TMP=false; shift ;;
    --only-tmp) RUN_LOGS=false; RUN_CACHE=false; RUN_TMP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  err "Run as root (sudo)."
  exit 1
fi

disk_report() {
  log "Disk usage snapshot:"
  run_cmd "df -hT | sed -n '1p;/^\\/dev/p'"
  run_cmd "du -sh /var/log 2>/dev/null || true"
  run_cmd "du -sh /var/cache 2>/dev/null || true"
  run_cmd "du -sh /tmp /var/tmp 2>/dev/null || true"
}

do_backup() {
  $BACKUP || { warn "Backup disabled."; return 0; }
  confirm || { warn "Skip backup."; return 0; }

  log "Backing up important logs to: $BACKUP_DIR"
  run_cmd "mkdir -p '$BACKUP_DIR'"

  run_cmd "tar -czf '$BACKUP_DIR/var_log_important.tgz' \
      /var/log/syslog /var/log/messages /var/log/auth.log /var/log/secure \
      /var/log/kern.log /var/log/dmesg 2>/dev/null || true"

  run_cmd "tar -czf '$BACKUP_DIR/journal.tgz' /var/log/journal 2>/dev/null || true"
  log "Backup done."
}

clean_journal() {
  command -v journalctl >/dev/null 2>&1 || { warn "journalctl missing, skip journald cleanup."; return 0; }
  confirm || { warn "Skip journal cleanup."; return 0; }

  log "Cleaning journald: keep ${JOURNAL_KEEP_DAYS} day(s), max ${JOURNAL_MAX_SIZE}"
  run_cmd "journalctl --vacuum-time=${JOURNAL_KEEP_DAYS}d"
  run_cmd "journalctl --vacuum-size=${JOURNAL_MAX_SIZE}"
}

clean_var_log_rotated() {
  confirm || { warn "Skip /var/log rotated cleanup."; return 0; }

  log "Deleting rotated log files in /var/log older than ${LOGROTATE_DELETE_DAYS} days"
  run_cmd "find /var/log -type f \\( \
     -name '*.gz' -o -name '*.xz' -o -name '*.old' -o -name '*.1' -o -name '*.2' -o -name '*.3' \
   \\) -mtime +${LOGROTATE_DELETE_DAYS} -print -delete 2>/dev/null || true"
}

clean_core_dumps() {
  confirm || { warn "Skip core dump cleanup."; return 0; }
  log "Cleaning systemd-coredump (if exists)"
  if command -v coredumpctl >/dev/null 2>&1; then
    run_cmd "coredumpctl purge || true"
  fi
  run_cmd "find /var/lib/systemd/coredump -type f -print -delete 2>/dev/null || true"
}

clean_tmp() {
  confirm || { warn "Skip tmp cleanup."; return 0; }
  log "Cleaning /tmp and /var/tmp older than ${TMP_DELETE_DAYS} days"
  run_cmd "find /tmp -mindepth 1 -mtime +${TMP_DELETE_DAYS} -print -delete 2>/dev/null || true"
  run_cmd "find /var/tmp -mindepth 1 -mtime +${TMP_DELETE_DAYS} -print -delete 2>/dev/null || true"
}

clean_pkg_cache() {
  confirm || { warn "Skip package cache cleanup."; return 0; }
  log "Cleaning package manager caches..."

  if command -v apt-get >/dev/null 2>&1; then
    run_cmd "apt-get clean"
    run_cmd "apt-get autoclean"
    $CLEAN_ALL && run_cmd "apt-get -y autoremove" || warn "Skip apt autoremove (enable --clean-all)."
  fi
  if command -v dnf >/dev/null 2>&1; then run_cmd "dnf clean all"; fi
  if command -v yum >/dev/null 2>&1; then run_cmd "yum clean all"; fi
  if command -v pacman >/dev/null 2>&1; then run_cmd "pacman -Sc --noconfirm"; fi
  if command -v zypper >/dev/null 2>&1; then run_cmd "zypper clean --all"; fi
}

clean_system_cache() {
  confirm || { warn "Skip system cache cleanup."; return 0; }
  log "Cleaning system caches (safe subset)"
  if [[ -d /var/cache ]]; then
    run_cmd "find /var/cache -type f -mtime +${OLD_CACHE_DAYS} -print -delete 2>/dev/null || true"
  fi
}

clean_user_caches() {
  confirm || { warn "Skip user cache cleanup."; return 0; }
  log "Cleaning user caches (~/.cache), thumbnails (safe subset)"

  while IFS=: read -r _ _ uid _ _ home _; do
    [[ "$uid" -lt 1000 ]] && continue
    [[ ! -d "$home" ]] && continue

    run_cmd "rm -rf '$home/.cache/thumbnails' 2>/dev/null || true"

    if [[ -d "$home/.cache" ]]; then
      run_cmd "find '$home/.cache' -type f -mtime +${OLD_CACHE_DAYS} -print -delete 2>/dev/null || true"
    fi
  done < /etc/passwd
}

clean_extra_dev_cache() {
  $CLEAN_ALL || { warn "Extra cleanup disabled (enable --clean-all)."; return 0; }
  confirm || { warn "Skip extra dev cleanup."; return 0; }

  log "Extra cleanup: pip/npm/gradle/docker"

  if command -v pip >/dev/null 2>&1; then run_cmd "pip cache purge || true"; fi
  if command -v pip3 >/dev/null 2>&1; then run_cmd "pip3 cache purge || true"; fi
  if command -v npm >/dev/null 2>&1; then run_cmd "npm cache clean --force || true"; fi

  while IFS=: read -r _ _ uid _ _ home _; do
    [[ "$uid" -lt 1000 ]] && continue
    [[ ! -d "$home" ]] && continue
    [[ -d "$home/.gradle/caches" ]] && run_cmd "find '$home/.gradle/caches' -type f -mtime +30 -print -delete 2>/dev/null || true"
  done < /etc/passwd

  if command -v docker >/dev/null 2>&1; then
    warn "Docker prune will remove unused images/containers."
    run_cmd "docker system prune -af || true"
  fi
}

log "Start cleanup: DRY_RUN=$DRY_RUN INTERACTIVE=$INTERACTIVE BACKUP=$BACKUP CLEAN_ALL=$CLEAN_ALL"
disk_report
do_backup

if $RUN_LOGS; then
  log "===== LOGS CLEAN ====="
  clean_journal
  clean_var_log_rotated
  clean_core_dumps
fi

if $RUN_TMP; then
  log "===== TMP CLEAN ====="
  clean_tmp
fi

if $RUN_CACHE; then
  log "===== CACHE CLEAN ====="
  clean_pkg_cache
  clean_system_cache
  clean_user_caches
  clean_extra_dev_cache
fi

disk_report
log "Cleanup done."
EOF

  # Replace placeholders with our default values
  sed -i \
    -e "s/__JOURNAL_KEEP_DAYS__/${JOURNAL_KEEP_DAYS}/g" \
    -e "s/__JOURNAL_MAX_SIZE__/${JOURNAL_MAX_SIZE}/g" \
    -e "s/__LOGROTATE_DELETE_DAYS__/${LOGROTATE_DELETE_DAYS}/g" \
    -e "s/__TMP_DELETE_DAYS__/${TMP_DELETE_DAYS}/g" \
    -e "s/__OLD_CACHE_DAYS__/${OLD_CACHE_DAYS}/g" \
    "$CLEAN_SCRIPT_PATH"

  chmod 755 "$CLEAN_SCRIPT_PATH"
  log "Cleaner script installed."
}

configure_journald_keep_1day() {
  # Only if systemd exists
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemd not found (systemctl missing). Skip journald config."
    return 0
  fi

  local conf="/etc/systemd/journald.conf"
  log "Configuring journald retention to 1 day: $conf"

  # Backup original if not yet
  if [[ -f "$conf" ]] && [[ ! -f "${conf}.bak_safe_clean" ]]; then
    cp -a "$conf" "${conf}.bak_safe_clean"
    log "Backup journald.conf -> ${conf}.bak_safe_clean"
  fi

  # Ensure keys in [Journal]
  # Use a safe approach: add [Journal] if missing; then set/replace keys
  grep -q "^\[Journal\]" "$conf" 2>/dev/null || echo -e "\n[Journal]" >> "$conf"

  # Replace or append settings
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
  log "journald configured & restarted."
}

setup_cron_job() {
  log "Setting up cron job for daily 04:00..."

  # Ensure log file exists
  touch "$CRON_LOG"
  chmod 644 "$CRON_LOG" || true

  # Install the cron entry idempotently
  local tmpfile
  tmpfile="$(mktemp)"

  # Export existing crontab, filter old entry, add new one
  crontab -l 2>/dev/null | grep -vF "$CLEAN_SCRIPT_PATH" > "$tmpfile" || true
  echo "$CRON_SCHEDULE $CRON_CMD" >> "$tmpfile"
  crontab "$tmpfile"
  rm -f "$tmpfile"

  log "Cron job installed:"
  log "  $CRON_SCHEDULE $CRON_CMD"
}

show_result() {
  log "DONE."
  log "Cleaner script: $CLEAN_SCRIPT_PATH"
  log "Cron log file:  $CRON_LOG"
  log ""
  log "You can test run:"
  log "  sudo $CLEAN_SCRIPT_PATH --dry-run --interactive"
  log ""
  log "Check cron entry:"
  log "  sudo crontab -l"
  log ""
  log "View run logs:"
  log "  tail -n 200 $CRON_LOG"
}

main() {
  require_root
  install_cron_if_missing
  deploy_clean_script
  configure_journald_keep_1day
  setup_cron_job
  show_result
}

main "$@"
