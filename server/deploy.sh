#!/bin/bash

RED='\033[38;5;196m'
CRIMSON='\033[38;5;124m'
ASH='\033[38;5;237m'
NC='\033[0m'

step() { echo -ne "${ASH}[wait]${NC} $1..."; }
ok()   { echo -e "\r\033[2K${RED}[${RED}✓${NC}]${NC} $1"; }
fail() { echo -e "\r\033[2K${CRIMSON}[${CRIMSON}✗${NC}]${NC} $1"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 не установлен"; }

[ "$EUID" -ne 0 ] && fail "Требуются права root!"

CHANGE_PORT=0
while getopts "p" opt; do
    case $opt in
        p) CHANGE_PORT=1 ;;
    esac
done

optimize_network() {
    step "Оптимизация сетевого стека и включение BBR"
    need sysctl

    modprobe nf_conntrack >/dev/null 2>&1 || true
    modprobe tcp_bbr >/dev/null 2>&1 || true

    # bbr2/bbr3 есть только на кастомных ядрах (не mainline) — берём лучшее из доступного
    AVAIL_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    if echo "$AVAIL_CC" | grep -qw bbr3; then
        CC=bbr3
    elif echo "$AVAIL_CC" | grep -qw bbr2; then
        CC=bbr2
    else
        CC=bbr
    fi

    cat > /etc/sysctl.d/99-vps-optimize.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $CC
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

# UDP-буферы под QUIC/Hysteria2 — под DPI-шейпинг важнее не терять пакеты в очереди
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.rmem_max = 134217728

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
# ECN на 2026 год чаще мешает, чем помогает: часть оборудования ТСПУ/операторских
# миддлбоксов в РФ манглит ECN-биты, это добавляет ретрансмиты и джиттер на QUIC/Reality.
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 2
net.ipv4.tcp_rfc1337 = 1

# conntrack — под прокси-сервер с сотнями/тысячами клиентов дефолт слишком мал
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
    sysctl --system >/dev/null 2>&1

    # лимиты открытых файлов — при tcp_max_tw_buckets/conntrack в миллионах дефолтный nofile=1024 душит процесс
    cat > /etc/security/limits.d/99-vps-optimize.conf << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-nofile.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

    ACTUAL_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$ACTUAL_CC" = "$CC" ]; then
        ok "Сетевой стек оптимизирован ($ACTUAL_CC активен)"
    else
        ok "Сетевой стек настроен ($CC не поддержан ядром, используется $ACTUAL_CC)"
    fi
}

setup_ufw() {
    step "Настройка Firewall (UFW)"
    need ufw
    sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw default allow routed >/dev/null 2>&1
    # 22 держим открытым всегда — если порт не меняем (-p не передан), не рубим себе SSH
    ufw allow 22 >/dev/null 2>&1
    for port in 2244 443 2053 2083 2087 2096; do
        ufw allow "$port" >/dev/null 2>&1
    done
    ufw allow from 185.23.19.69 to any port 2222 >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    ok "UFW активен, IPv6 отключен, порты открыты"
}

setup_ssh_port() {
    step "Настройка SSH порта"
    [ -f /etc/ssh/sshd_config ] || fail "sshd_config не найден"
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true
    sed -i 's/^#Port 22/Port 2244/; s/^Port 22$/Port 2244/' /etc/ssh/sshd_config
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart sshd >/dev/null 2>&1 || true
    else
        service ssh restart >/dev/null 2>&1 || true
    fi
    ok "SSH порт: 2244"
}

setup_bash_customs() {
    step "Интеграция q.sh"
    sed -i '/alias q=/d' /root/.bashrc
    sed -i '/^PS1=/d' /root/.bashrc
    cat >> /root/.bashrc << 'EOF'

alias q='/root/q.sh'
alias status='q status'
alias start='q start all'
alias stop='q stop all'
alias restart='q restart all'
alias clear='q clear'
alias zip='q zip'
alias db='q db'
alias st='q st'
alias sr='sudo reboot'

alias la='ls -la --color=auto'
alias ll='ls -lh --color=auto'
alias l='ls -CF --color=auto'
alias lt='ls -lhtr --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'
alias df='df -h'
alias du='du -h'
alias free='free -m'
alias ports='ss -tulnp'
alias logs='journalctl -f'
alias reload='source /root/.bashrc'
alias diff='diff --color=auto'
alias ip='ip --color=auto'
alias cat='cat'
alias myip='curl -s https://api.ipify.org; echo'
alias path='echo -e ${PATH//:/\\n}'
alias ..2='cd ../..'
alias ..3='cd ../../..'
alias h='history'
alias c='clear'
alias psg='ps aux | grep -v grep | grep -i'
alias untar='tar -xvf'
alias sha='sha256sum'
alias speed='curl -o /dev/null -s -w "%{speed_download}\n" http://speedtest.tele2.net/10MB.zip'

# распаковка любого архива одной командой
extract() {
    [ -f "$1" ] || { echo "файл не найден: $1"; return 1; }
    case "$1" in
        *.tar.bz2) tar xjf "$1"   ;;
        *.tar.gz)  tar xzf "$1"   ;;
        *.tar.xz)  tar xJf "$1"   ;;
        *.tar)     tar xf "$1"    ;;
        *.bz2)     bunzip2 "$1"   ;;
        *.rar)     unrar x "$1"   ;;
        *.gz)      gunzip "$1"    ;;
        *.zip)     unzip "$1"     ;;
        *.7z)      7z x "$1"      ;;
        *) echo "не знаю как распаковать: $1" ;;
    esac
}

mkcd() { mkdir -p "$1" && cd "$1" || return; }

export LS_COLORS='di=38;5;33:ln=38;5;51:so=38;5;199:pi=38;5;226:ex=38;5;196:bd=38;5;208:cd=38;5;208:su=38;5;196:sg=38;5;196:tw=38;5;33:ow=38;5;33:*.tar=38;5;196:*.tgz=38;5;196:*.zip=38;5;196:*.gz=38;5;196:*.bz2=38;5;196:*.xz=38;5;196:*.7z=38;5;196:*.rar=38;5;196:*.sh=38;5;226:*.py=38;5;226:*.js=38;5;226:*.ts=38;5;226:*.go=38;5;226:*.rs=38;5;226:*.json=38;5;51:*.yaml=38;5;51:*.yml=38;5;51:*.toml=38;5;51:*.conf=38;5;51:*.env=38;5;51:*.ini=38;5;51:*.log=38;5;242:*.md=38;5;255:*.txt=38;5;255:*.png=38;5;199:*.jpg=38;5;199:*.jpeg=38;5;199:*.gif=38;5;199:*.svg=38;5;199:*.mp4=38;5;199:*.mkv=38;5;199:*.sql=38;5;208:*.db=38;5;208:*.crt=38;5;220:*.pem=38;5;220:*.key=38;5;196'

export GREP_COLORS='mt=1;38;5;196:fn=38;5;33:ln=38;5;242:se=38;5;242'

export LESS='-R'
export LESS_TERMCAP_mb=$'\033[38;5;196m'
export LESS_TERMCAP_md=$'\033[1;38;5;196m'
export LESS_TERMCAP_me=$'\033[0m'
export LESS_TERMCAP_se=$'\033[0m'
export LESS_TERMCAP_so=$'\033[38;5;226;48;5;52m'
export LESS_TERMCAP_ue=$'\033[0m'
export LESS_TERMCAP_us=$'\033[4;38;5;51m'

export GCC_COLORS='error=1;38;5;196:warning=1;38;5;226:note=1;38;5;51:caret=1;38;5;196:locus=38;5;242:quote=38;5;88'

export MANPAGER='less -R'
export MANROFFOPT='-c'

# история: без дублей, с временными метками, побольше глубина
export HISTCONTROL=ignoredups:erasedups
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTTIMEFORMAT='%F %T  '
shopt -s histappend
shopt -s checkwinsize

if [ -z "$(cat /dev/shm/.vps_ip 2>/dev/null)" ]; then
    curl -s --max-time 3 https://api.ipify.org > /dev/shm/.vps_ip 2>/dev/null || echo "?" > /dev/shm/.vps_ip
fi
_VPS_IP=$(cat /dev/shm/.vps_ip)

# ветка git в промпте, если репозиторий и git установлены
_git_branch() {
    command -v git >/dev/null 2>&1 || return
    local b
    b=$(git symbolic-ref --short HEAD 2>/dev/null) || return
    printf ' (%s)' "$b"
}

# цвет хоста меняется, если запущено под настоящим root в интерактивной сессии без sudo-обёртки — просто визуальный маркер
PROMPT_COMMAND='__p="$PWD"; if [ "$__p" = "/root" ]; then _D="~"; else __p="${__p/#\/root\//~\/}"; IFS=/ read -ra __a <<< "$__p"; __n=${#__a[@]}; if [ $__n -gt 4 ]; then _D=".../${__a[$__n-3]}/${__a[$__n-2]}/${__a[$__n-1]}"; else _D="$__p"; fi; fi; _GB=$(_git_branch)'
PS1="\[\033[38;5;196m\]cy6su\[\033[38;5;242m\][\[\033[38;5;88m\]${_VPS_IP}\[\033[38;5;242m\]@\[\033[38;5;196m\]\${_D}\[\033[38;5;208m\]\${_GB}\[\033[38;5;242m\]] \[\033[38;5;196m\]→\[\033[0m\] "
EOF
    ok "Алиасы, цвета и функции добавлены в .bashrc"
}

disable_ubuntu_motd() {
    step "Отключение стандартного MOTD Ubuntu"
    sed -i 's/PrintLastLog yes/PrintLastLog no/' /etc/ssh/sshd_config 2>/dev/null || true
    command -v systemctl >/dev/null 2>&1 && systemctl restart sshd >/dev/null 2>&1 || true
    ok "Стандартное MOTD отключено"
    touch /root/.hushlogin
}

setup_motd() {
    step "Создание MOTD"
    chmod -x /etc/update-motd.d/* 2>/dev/null || true
    rm -f /etc/motd /etc/update-motd.d/* 2>/dev/null || true

    cat > /etc/profile.d/motd.sh << 'EOF'
#!/bin/bash
[ -z "$PS1" ] && return

LOGO_COLOR='\033[38;5;160m'
DARK_RED='\033[38;5;88m'
GRAY='\033[38;5;242m'
NC='\033[0m'

TERM_WIDTH=$(stty size 2>/dev/null | awk '{print $2}')
[ -z "$TERM_WIDTH" ] || [ "$TERM_WIDTH" -lt 40 ] && TERM_WIDTH=120
LOGO_WIDTH=68
LEFT_INDENT=3
RIGHT_INDENT=3

LOGO_PAD_VAL=$(( (TERM_WIDTH - LOGO_WIDTH) / 2 ))
[ $LOGO_PAD_VAL -lt 0 ] && LOGO_PAD_VAL=0
LOGO_PAD=$(printf '%*s' "$LOGO_PAD_VAL" "")
LEFT_PAD=$(printf '%*s' "$LEFT_INDENT" "")

print_row() {
    local label="$1" value="$2"
    local spacer=$(( TERM_WIDTH - LEFT_INDENT - 20 - ${#value} - RIGHT_INDENT ))
    [ $spacer -lt 1 ] && spacer=1
    printf "${LEFT_PAD}${GRAY}%-20s${NC}%s${DARK_RED}%s${NC}\n" \
        "$label" "$(printf '%*s' "$spacer" "")" "$value"
}

printf "%s%s\n" "$LOGO_PAD" "[0;37;40m  ▄▄[0;90;47m▒▓[0;90;40m█▓▒▒▒▒▒▓█[0;97;47m▓[0;37;40m [0;97;47m█▓▒▓▓[0;37;40m     [0;90;40m█░░░░[0;90;47m▓[0;37;40m   ▄▄[0;90;47m▒▓[0;90;40m█▓▒▒▒▒▒▓█[0;97;47m▓[0;37;40m   ▄▄[0;90;47m▒▓[0;90;40m█▓▒▒▒▒▒▓█[0;97;47m▓[0;37;40m [0;97;47m▒[0;37;41m███[0;97;40m▒[0;37;40m     [0;90;47m▓[0;90;40m▒▒░░░[0m"
printf "%s%s\n" "$LOGO_PAD" "[0;37;40m▄[0;37;41m██[0;97;47m░▒▓██▓▒░[0;90;40m▒▒▒▒[0;97;47m▒[0;37;40m [0;97;47m▓[0;37;41m▓▓▓[0;97;47m▒[0;37;40m     [0;90;47m▓[0;90;40m▒▒▒▒[0;90;47m▒[0;37;40m ▄[0;37;41m██[0;97;47m░▒▓██▓▒░[0;90;40m▒▒▒▒[0;97;47m▒[0;37;40m ▄[0;37;41m▓▓[0;97;47m░▒▓██▓▒░[0;90;40m▒▒▒▒[0;97;47m▒[0;37;40m [0;97;47m▓[0;37;41m▓▓▓[0;97;47m▒[0;37;40m     [0;90;47m░[0;90;40m▓▒▒░░[0m"
printf "%s%s\n" "$LOGO_PAD" "[0;97;40m█[0;37;41m▓▓▓[0;97;47m░[0;37;40m▀    [0;90;47m░[0;90;40m▓▓▓▓[0;97;47m░[0;37;40m [0;97;47m▒[0;37;41m▒▒▒[0;97;47m░[0;37;40m     [0;90;47m░[0;90;40m▓▓▓▓[0;90;47m░[0;37;40m [0;97;40m█[0;37;41m▓▓▓[0;97;47m░[0;37;40m▀    [0;90;47m░[0;90;40m▓▓▓▓[0;97;47m░[0;37;40m [0;97;40m█[0;37;41m▒▒▒[0;97;47m░[0;37;40m▀    [0;90;47m░[0;90;40m▓▓▓▓[0;97;47m░[0;37;40m [0;97;40m█[0;37;41m▒▒▒[0;97;47m░[0;37;40m     [0;90;47m░[0;90;40m▓▓▒▒░[0m"
printf "%s%s\n" "$LOGO_PAD" "[0;97;47m▓[0;37;41m▒▒▒[0;90;47m░[0;37;40m     [0;90;47m▒[0;90;40m████[0;90;47m░[0;37;40m [0;97;47m▓[0;37;41m░░░[0;90;47m░▒[0;90;40m▄▄▄▄[0;90;47m▒[0;90;40m████[0;90;47m░[0;37;40m [0;97;47m▓[0;37;41m▒▒▒[0;90;47m░[0;90;40m▄▄▄▄▄▄▄▄[0;37;40m    [0;97;47m▓[0;37;41m░░░[0;90;47m░▒[0;90;40m▄▄▄▄▄▄[0;37;40m     [0;97;47m▓[0;37;41m░░░[0;90;47m░[0;37;40m     [0;90;47m▒[0;90;40m██▓▒▒[0m"
printf "%s%s\n" "$LOGO_PAD" "[0;97;47m▒[0;37;41m░░░[0;90;47m▒[0;37;40m     [0;90;40m▀▀▀▀▀▀[0;37;40m ▀[0;90;41m░░░[0;90;47m▒▓[0;90;41m▓▓▓▒[0;90;47m▓[0;90;40m████[0;90;47m▒[0;37;40m [0;97;47m▒[0;37;41m░░░░░[0;31;40m█[0;90;41m░░▒▒▓▓[0;90;40m██[0;37;40m  ▀[0;90;41m░░░[0;90;47m▒▓[0;90;41m▓▓▓▒[0;90;47m▓[0;90;40m███▄[0;37;40m  [0;97;47m▒[0;90;41m░░░[0;90;47m▒[0;37;40m     [0;90;47m▓[0;90;40m██▓▒▒[0m"
printf "%s%s\n" "$LOGO_PAD" "[0;97;47m░[0;90;41m░░░[0;90;47m▓[0;37;40m     [0;90;40m▄▄▄▄▄▄[0;37;40m           [0;90;40m▓▓▓▓▓[0;90;47m▓[0;37;40m [0;97;47m░[0;90;41m░░░[0;90;47m▓[0;90;40m▀[0;37;40m   [0;90;40m▀█▓▓▓▓▌[0;37;40m [0;90;40m▄▄▄▄▄[0;37;40m    [0;90;40m▀▓▓▓▓█▌[0;37;40m [0;97;47m░[0;90;41m▒▒▒[0;90;47m▓[0;37;40m     [0;90;40m█▓▓█▓▒[0m"
printf "%s%s\n" "$LOGO_PAD" "[0;90;47m░[0;90;41m▒▒▒░[0;37;40m     [0;90;40m█▒▒▒▒[0;90;47m█[0;37;40m [0;90;47m░[0;90;41m▒▒▒░[0;37;40m     [0;90;40m█▒▒▒▒[0;90;47m█[0;37;40m [0;90;47m░[0;90;41m▒▒▒░[0;37;40m     [0;90;40m█▒▒▒▒[0;90;47m█[0;37;40m [0;90;47m░[0;90;41m▒▒▒░[0;37;40m     [0;90;40m█▒▒▒▒[0;90;47m█[0;37;40m [0;90;47m░[0;90;41m▓▓▓[0;90;40m█▌[0;37;40m   [0;90;40m▐█▓▓▓▒░[0m"
printf "%s%s\n" "$LOGO_PAD" "[0;90;40m▀[0;90;41m▓▓▓▓[0;90;40m█▄▄▄▄▓░░░░▓[0;37;40m [0;90;40m▀[0;90;41m▓▓▓▓[0;90;40m█▄▄▄█▓▒▒░░░[0;37;40m [0;90;40m▀[0;90;41m▓▓▓▓[0;90;40m█▄▄▄█▓░░░░[0;37;40m  [0;90;40m▀[0;90;41m▓▓▓▓[0;90;40m█▄▄▄█▓▒▒░░░[0;37;40m [0;90;40m▀▓[0;31;40m▒▒▒[0;90;40m█▄▄▄█▓█▓▒░[0;37;40m [0m"
printf "%s%s\n" "$LOGO_PAD" "[0;37;40m  [0;90;40m▀▀▓▓▓▒▒▒░░░░░▒[0;37;40m   [0;90;40m▀▀▓▓▓▒▒▒▒▒░░[0;37;40m     [0;90;40m▀▀▓▓▓▒▒▒░░░░[0;37;40m     [0;90;40m▀▀▓▓▓▒▒▒▒▒░░[0;37;40m     [0;90;40m▀▀▓[0;31;40m▒[0;90;40m▓█▓▓██▒░[0;37;40m  [0m"

UPTIME=$(uptime -p | sed 's/up //')
LOAD=$(awk '{print $1" "$2" "$3}' /proc/loadavg)
USERS=$(who | wc -l)
MEM=$(free -m | awk '/^Mem:/ {printf "%s/%s MiB (%.1f%%)", $3, $2, $3*100/$2}')
DISK=$(df -h / | awk '$NF=="/"{printf "%s/%s (%s)", $3,$2,$5}')
CPU=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}')
IP=$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 ifconfig.me || echo "N/A")

print_row "Uptime" "$UPTIME"
print_row "Users" "$USERS online"
echo ""
print_row "CPU Load" "$LOAD"
print_row "CPU Usage" "${CPU:-N/A}"
print_row "Memory" "$MEM"
print_row "Disk /" "$DISK"
print_row "Public IP" "$IP"
echo
EOF

    chmod +x /etc/profile.d/motd.sh
    ok "MOTD установлен (profile.d)"
}

optimize_network
setup_ufw
if [ "$CHANGE_PORT" -eq 1 ]; then
    setup_ssh_port
fi
setup_bash_customs
disable_ubuntu_motd
setup_motd
