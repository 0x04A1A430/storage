#!/bin/bash
#
# deploy.sh - server bootstrap in Claude Code style (blood-red).
# Reproduces the current server baseline: network tuning, UFW, SSH, Docker,
# fail2ban, q.sh, MOTD, cron and rkn-guard.
#
set -uo pipefail

[ "$EUID" -ne 0 ] && { echo "Требуются права root"; exit 1; }

SSH_PORT=2244
CHANGE_SSH=1
WITH_RKN=1
DAILY_REBOOT=0
UPDATE_Q=0
ENV_FILE="/opt/.env"
Q_URL="https://raw.githubusercontent.com/0x04A1A430/storage/main/server/q.sh"
RKN_APP_URL="https://raw.githubusercontent.com/Flecksis/rkn-guard/master/app%20install.sh"
RKN_MANAGER_URL="https://raw.githubusercontent.com/Flecksis/rkn-guard/master/install.sh"
RKN_LIST_GOV="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
RKN_LIST_SCAN="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
RKN_LIST_SKIPA="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list"

usage() {
    cat <<'EOF'
Usage: deploy.sh [options]

  --ssh-port PORT     SSH port (default: 2244)
  --keep-ssh-port     не менять SSH-порт
  --no-rkn            не устанавливать/обновлять rkn-guard
  --reboot-daily      добавить ежедневный reboot в 04:05
  --update-q          перезаписать /root/q.sh из storage
  -h, --help          эта справка
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-port) SSH_PORT="${2:?}"; shift 2 ;;
        --keep-ssh-port) CHANGE_SSH=0; shift ;;
        --no-rkn) WITH_RKN=0; shift ;;
        --reboot-daily) DAILY_REBOOT=1; shift ;;
        --update-q) UPDATE_Q=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1"; usage; exit 1 ;;
    esac
done

# --- palette ---------------------------------------------------------------
UI_TTY=0
UI_UNICODE=0
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    UI_TTY=1
    if [[ "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* ]]; then
        BLOOD=$'\033[38;2;193;18;31m'
        CRIMSON=$'\033[38;2;230;57;70m'
        DARK=$'\033[38;2;74;17;20m'
        ASH=$'\033[38;2;201;184;184m'
        OK=$'\033[38;2;255;107;107m'
        WARN=$'\033[38;2;255;140;66m'
        TEXT=$'\033[38;2;245;230;230m'
        MUTED=$'\033[38;2;154;143;143m'
    elif [[ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]]; then
        BLOOD=$'\033[38;5;160m'; CRIMSON=$'\033[38;5;196m'
        DARK=$'\033[38;5;52m'; ASH=$'\033[38;5;250m'
        OK=$'\033[38;5;203m'; WARN=$'\033[38;5;208m'
        TEXT=$'\033[38;5;255m'; MUTED=$'\033[38;5;245m'
    else
        BLOOD=$'\033[91m'; CRIMSON=$'\033[31m'; DARK=$'\033[90m'
        ASH=$'\033[37m'; OK=$'\033[91m'; WARN=$'\033[33m'
        TEXT=$'\033[97m'; MUTED=$'\033[90m'
    fi
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    BLOOD='' CRIMSON='' DARK='' ASH='' OK='' WARN='' TEXT='' MUTED=''
    BOLD='' DIM='' NC=''
fi

if [[ "$(locale charmap 2>/dev/null || true)" == "UTF-8" ]]; then
    UI_UNICODE=1
    ICON_OK='✓'; ICON_ERR='✗'; ICON_INFO='·'; ICON_MARK='✻'
    SPIN_FRAMES=( '✢' '✳' '✶' '✻' '✽' )
else
    ICON_OK='+'; ICON_ERR='x'; ICON_INFO='*'; ICON_MARK='*'
    SPIN_FRAMES=( '|' '/' '-' '\\' )
fi

ui_hr() {
    local width
    width=$(tput cols 2>/dev/null || true)
    [[ -z "$width" || "$width" -le 0 ]] 2>/dev/null && width=${COLUMNS:-56}
    (( width > 72 )) && width=72
    (( width < 24 )) && width=24
    printf '%s\n' "${DARK}$(printf '%*s' "$((width - 2))" '' | tr ' ' '-')${NC}"
}
ui_banner() {
    echo
    printf '  %s  %s\n' "${BLOOD}${ICON_MARK}${NC}" "${BOLD}${TEXT}${1}${NC}"
    printf '     %s\n' "${MUTED}${2}${NC}"
}
ui_section() { echo; printf '  %s %s\n' "${BLOOD}>${NC}" "${BOLD}${TEXT}${1}${NC}"; }
ui_ok()   { printf '  %s %s\n' "${OK}${ICON_OK}${NC}" "$*"; }
ui_warn() { printf '  %s %s\n' "${WARN}!${NC}" "$*"; }
ui_err()  { printf '  %s %s\n' "${CRIMSON}${ICON_ERR}${NC}" "$*"; }
ui_info() { printf '  %s %s\n' "${MUTED}${ICON_INFO}${NC}" "$*"; }

spin_run() {
    local label="$1"; shift
    local frame=0 pid rc start elapsed log
    log="${LOG_FILE:-/dev/null}"
    if [[ "$UI_TTY" -ne 1 ]]; then
        "$@" >>"$log" 2>&1; rc=$?
        [[ $rc -eq 0 ]] && ui_ok "$label" || ui_err "$label"
        return $rc
    fi
    start=$SECONDS
    "$@" >>"$log" 2>&1 & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$((SECONDS - start))
        printf '\r  %s %s %s\033[K' "${BLOOD}${SPIN_FRAMES[frame]}${NC}" "$label" "${DIM}${elapsed}s${NC}"
        frame=$(( (frame + 1) % ${#SPIN_FRAMES[@]} ))
        sleep 0.09
    done
    wait "$pid"; rc=$?; elapsed=$((SECONDS - start))
    if [[ $rc -eq 0 ]]; then
        printf '\r  %s %s %s\033[K\n' "${OK}${ICON_OK}${NC}" "$label" "${DIM}${elapsed}s${NC}"
    else
        printf '\r  %s %s %s\033[K\n' "${CRIMSON}${ICON_ERR}${NC}" "$label" "${DIM}${elapsed}s${NC}"
    fi
    return $rc
}

fail() { ui_err "$*"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
mkdir -p /var/log
LOG_FILE="/var/log/deploy-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

ui_banner "SERVER DEPLOY" "bootstrap / network / security / rkn"
ui_info "лог: $LOG_FILE"

# --- base packages ---------------------------------------------------------
setup_packages() {
    ui_section "Базовые пакеты"
    spin_run "apt update" apt-get update -y || fail "apt update"
    spin_run "установка пакетов" apt-get install -y --no-install-recommends \
        curl wget git jq unzip zip ca-certificates gnupg lsb-release \
        software-properties-common apt-transport-https ufw fail2ban \
        unattended-upgrades htop tmux rsyslog ipset whois net-tools \
        dnsutils iproute2 cron certbot ffmpeg || fail "установка пакетов"
    systemctl enable --now rsyslog >/dev/null 2>&1 || true
}

setup_timezone() {
    ui_section "Время и NTP"
    spin_run "timezone Europe/Saratov" timedatectl set-timezone Europe/Saratov || true
    spin_run "включение NTP" timedatectl set-ntp true || true
}

setup_network() {
    ui_section "Сеть и лимиты"
    modprobe nf_conntrack >/dev/null 2>&1 || true
    modprobe tcp_bbr >/dev/null 2>&1 || true
    local avail cc=bbr
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    echo "$avail" | grep -qw bbr3 && cc=bbr3
    echo "$avail" | grep -qw bbr2 && [[ "$cc" == bbr ]] && cc=bbr2

    cat > /etc/sysctl.d/99-vps-optimize.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $cc
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 32768
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 8192 262144 134217728
net.ipv4.tcp_wmem = 8192 262144 134217728
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_orphans = 819200
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_synack_retries = 2
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.core.somaxconn = 65535
net.ipv4.tcp_abort_on_overflow = 0
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 2
net.ipv4.tcp_rfc1337 = 1
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
    spin_run "sysctl --system" sysctl --system || true

    cat > /etc/security/limits.d/99-vps-optimize.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-nofile.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-size.conf <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
EOF
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    ui_ok "сеть, лимиты и journald настроены"
}

setup_swap() {
    ui_section "Swap"
    if swapon --show 2>/dev/null | grep -q .; then
        ui_info "swap уже активен — пропускаю"
        return
    fi
    if [[ ! -f /swapfile ]]; then
        spin_run "создание /swapfile 2G" fallocate -l 2G /swapfile || fail "fallocate swap"
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ui_ok "swap 2G создан"
    fi
}

setup_docker() {
    ui_section "Docker"
    if ! command -v docker >/dev/null 2>&1; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || fail "docker gpg"
        chmod a+r /etc/apt/keyrings/docker.asc
        . /etc/os-release
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list
        spin_run "apt update (docker)" apt-get update -y || fail "apt update docker"
        spin_run "установка docker" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || fail "docker install"
    else
        ui_info "docker уже установлен"
    fi
    if [[ ! -f /etc/docker/daemon.json ]]; then
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json <<'EOF'
{
  "ipv6": false,
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
EOF
        systemctl restart docker >/dev/null 2>&1 || true
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    ui_ok "docker готов: $(docker --version 2>/dev/null | awk '{print $3}')"
}

setup_ufw() {
    ui_section "Firewall"
    sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw default allow routed >/dev/null 2>&1
    ufw allow "$SSH_PORT/tcp" >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1

    local current_port="${SSH_CONNECTION##* }"
    if [[ -n "$current_port" && "$current_port" != "$SSH_PORT" ]]; then
        ufw allow "$current_port/tcp" >/dev/null 2>&1 || true
        ui_warn "текущий SSH-порт $current_port оставлен открытым до проверки"
    fi
    ufw --force enable >/dev/null 2>&1
    ui_ok "UFW: deny incoming, allow $SSH_PORT/tcp, 443/tcp"
}

setup_ssh() {
    ui_section "SSH"
    if (( CHANGE_SSH == 0 )); then
        ui_info "SSH-порт не меняю"
        return
    fi
    cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)" 2>/dev/null || true
    if grep -qE '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
        sed -i -E "s/^[[:space:]]*Port[[:space:]]+[0-9]+/Port $SSH_PORT/" /etc/ssh/sshd_config
    else
        printf '\nPort %s\n' "$SSH_PORT" >> /etc/ssh/sshd_config
    fi
    for line in \
        'MaxAuthTries 3' \
        'LoginGraceTime 20' \
        'X11Forwarding no' \
        'ClientAliveInterval 300' \
        'ClientAliveCountMax 2' \
        'PrintLastLog no'; do
        key=${line%% *}
        grep -qE "^[[:space:]]*${key}[[:space:]]" /etc/ssh/sshd_config || echo "$line" >> /etc/ssh/sshd_config
    done
    if ! sshd -t 2>/dev/null; then
        ui_err "sshd_config не прошёл проверку — восстанавливаю backup"
        cp -a "$(ls -t /etc/ssh/sshd_config.bak.* | head -1)" /etc/ssh/sshd_config
        fail "SSH не изменён"
    fi
    sed -i 's/^PrintLastLog yes/PrintLastLog no/' /etc/ssh/sshd_config 2>/dev/null || true
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
    ui_ok "SSH слушает порт $SSH_PORT"
    ui_warn "проверь вход на новом порту перед закрытием старого"
}

setup_fail2ban() {
    ui_section "Fail2ban"
    cat > /etc/fail2ban/jail.d/99-deploy.conf <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
banaction = nftables
banaction_allports = nftables[type=allports]
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
EOF
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true
    ui_ok "fail2ban: jail sshd, nftables, 5 попыток"
}

setup_unattended() {
    ui_section "Автообновления"
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    ui_ok "unattended-upgrades включён"
}

setup_qsh() {
    ui_section "q.sh и shell"
    if [[ ! -f /root/q.sh || "$UPDATE_Q" -eq 1 ]]; then
        spin_run "загрузка q.sh" curl -fsSL "$Q_URL" -o /root/q.sh || fail "не удалось скачать q.sh"
        chmod +x /root/q.sh
        ui_ok "q.sh установлен"
    else
        ui_info "q.sh уже есть — не перезаписываю"
    fi

    if [[ -f /root/q.sh ]]; then
        cat > /usr/local/bin/opn <<'EOF'
#!/bin/bash
exec /root/q.sh opn "$@"
EOF
        chmod +x /usr/local/bin/opn
    fi

    [[ -s /etc/vps_ip ]] || curl -s --max-time 3 https://api.ipify.org > /etc/vps_ip 2>/dev/null || \
        ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' > /etc/vps_ip || echo "N/A" > /etc/vps_ip

    if ! grep -q "alias q=" /root/.bashrc 2>/dev/null; then
        cat >> /root/.bashrc <<'EOF'

# >>> q.sh aliases >>>
alias q='/root/q.sh'
alias status='q status'
alias start='q start all'
alias stop='q stop all'
alias restart='q restart all'
alias clear='q clear'
alias zip='q zip'
alias st='q st'
alias ports='ss -tulnp'
alias logs='journalctl -f'
alias myip='cat /etc/vps_ip 2>/dev/null; echo'
alias reload='source /root/.bashrc'
# <<< q.sh aliases <<<
EOF
    fi
    ui_ok "shell-алиасы и opn готовы"
}

setup_motd() {
    ui_section "MOTD"
    chmod -x /etc/update-motd.d/* 2>/dev/null || true
    : > /etc/motd
    touch /root/.hushlogin
    cat > /etc/profile.d/motd.sh <<'EOF'
#!/bin/bash
[ -t 1 ] || return
case "$-" in *i*) ;; *) return ;; esac

R='\033[38;5;160m'; M='\033[38;5;245m'; T='\033[38;5;255m'; N='\033[0m'
IP=$(cat /etc/vps_ip 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
UP=$(uptime -p 2>/dev/null | sed 's/^up //')
LOAD=$(awk '{print $1" "$2" "$3}' /proc/loadavg)
MEM=$(free -m | awk '/^Mem:/ {printf "%s/%s MiB", $3, $2}')
DISK=$(df -hP / | awk '$NF=="/"{print $3"/"$2" ("$5")"}')
svc() { systemctl is-active --quiet "$1" && printf "${R}%s${N}" "$2" || printf "${M}%s${N}" "$2"; }

printf "\n  ${R}✻${N}  ${T}%s${N}\n" "$(hostname)"
printf "     ${M}%s  ·  uptime %s${N}\n" "${IP:-N/A}" "${UP:-?}"
printf "     ${M}cpu${N} %s   ${M}mem${N} %s   ${M}disk${N} %s\n" "$LOAD" "$MEM" "$DISK"
printf "     docker %s   fail2ban %s   rkn %s\n\n" "$(svc docker docker)" "$(svc fail2ban fail2ban)" "$(svc antiscan-aggregate.timer rkn)"
EOF
    chmod +x /etc/profile.d/motd.sh
    ui_ok "MOTD установлен"
}

setup_rkn() {
    ui_section "RKN-GUARD"
    if (( WITH_RKN == 0 )); then
        ui_info "пропущено (--no-rkn)"
        return
    fi
    apt-get install -y rsyslog ipset whois >/dev/null 2>&1 || true
    systemctl enable --now rsyslog >/dev/null 2>&1 || true

    if ! command -v rkn-guard >/dev/null 2>&1; then
        spin_run "установка rkn-guard" bash -c "curl -fsSL '$RKN_APP_URL' | bash" || fail "rkn-guard install"
        spin_run "правила rkn-guard" rkn-guard full -u "$RKN_LIST_GOV" -u "$RKN_LIST_SCAN" -u "$RKN_LIST_SKIPA" --enable-logging || ui_warn "rkn-guard: проверь списки"
    else
        spin_run "обновление списков rkn-guard" rkn-guard update -u "$RKN_LIST_GOV" -u "$RKN_LIST_SCAN" -u "$RKN_LIST_SKIPA" || ui_warn "rkn-guard update"
    fi

    spin_run "менеджер rkn" curl -fsSL "$RKN_MANAGER_URL" -o /opt/rkn-guard-manager.sh || true
    chmod +x /opt/rkn-guard-manager.sh 2>/dev/null || true
    cat > /usr/local/bin/rkn <<'EOF'
#!/usr/bin/env bash
exec /opt/rkn-guard-manager.sh "$@"
EOF
    chmod +x /usr/local/bin/rkn

    mkdir -p /var/log
    touch /var/log/iptables-scanners-{ipv4,ipv6}.log /opt/rkn-guard-manual.list
    chown syslog:adm /var/log/iptables-scanners-*.log 2>/dev/null || true
    chmod 640 /var/log/iptables-scanners-*.log 2>/dev/null || true
    systemctl restart antiscan-aggregate.service >/dev/null 2>&1 || true
    systemctl restart antiscan-aggregate.timer >/dev/null 2>&1 || true
    ui_ok "rkn-guard готов (rkn — меню)"
}

setup_cron() {
    ui_section "Cron"
    local tmp
    tmp=$(mktemp)
    crontab -l 2>/dev/null | grep -v 'q.sh zip' | grep -v 'q.sh start' > "$tmp"
    echo "@reboot sleep 30 && cd /root && /root/q.sh start all" >> "$tmp"
    grep -q 'certbot renew' "$tmp" || echo "0 4 * * 0 /usr/bin/certbot renew --quiet > /dev/null 2>&1" >> "$tmp"
    echo "0 4 * * * cd /root && /root/q.sh zip >> /var/log/q-backup.log 2>&1" >> "$tmp"
    if [[ -x /opt/rw-backup-restore/backup-restore.sh ]] && ! grep -q 'rw-backup-restore/backup-restore.sh backup' "$tmp"; then
        echo "0 4 * * * /opt/rw-backup-restore/backup-restore.sh backup >> /var/log/rw_backup_cron.log 2>&1" >> "$tmp"
    fi
    if (( DAILY_REBOOT == 1 )) && ! grep -q '/sbin/reboot' "$tmp"; then
        echo "5 4 * * * /sbin/reboot" >> "$tmp"
    fi
    crontab "$tmp"
    rm -f "$tmp"
    ui_ok "cron: q.sh zip, certbot, reboot (если включён)"
}

summary() {
    ui_section "Готово"
    ui_ok "сервер настроен"
    ui_info "SSH: $SSH_PORT/tcp | UFW: $SSH_PORT,443"
    ui_info "Docker: $(docker --version 2>/dev/null | awk '{print $3}')"
    ui_info "Fail2ban: $(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | xargs)"
    command -v rkn-guard >/dev/null 2>&1 && ui_info "rkn-guard: $(rkn-guard --version 2>/dev/null | awk '{print $NF}')"
    ui_hr
    ui_warn "если менял SSH-порт — проверь новый вход, затем закрой старый порт"
}

setup_packages
setup_timezone
setup_network
setup_swap
setup_docker
setup_ufw
setup_ssh
setup_fail2ban
setup_unattended
setup_qsh
setup_motd
setup_rkn
setup_cron
summary
