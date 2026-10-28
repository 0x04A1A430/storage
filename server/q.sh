#!/bin/bash
#
# q.sh — server control template.
# Copy to /root/q.sh, chmod +x, then:
#   - fill services_registry() below;
#   - set TG_BOT_TOKEN, TG_CHAT_ID and ZIP_PASSWORD in /opt/.env;
#   - optionally override BOT_DIR / BACKUP_DIR / OPENCODE_*.
#

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

ENV_FILE="/opt/.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "$ENV_FILE"
    set +a
fi

# --- palette ---------------------------------------------------------------
# Claude Code-like typography and motion, but a blood-red palette.
UI_TTY=0
UI_UNICODE=0
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    UI_TTY=1
    if [[ "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* ]]; then
        BLOOD=$'\033[38;2;193;18;31m'    # blood red
        CRIMSON=$'\033[38;2;230;57;70m'  # bright blood
        DARK=$'\033[38;2;74;17;20m'      # dark wine
        RUST=$'\033[38;2;164;22;26m'     # deep red
        ASH=$'\033[38;2;201;184;184m'
        OK=$'\033[38;2;255;107;107m'     # light blood for success
        WARN=$'\033[38;2;255;140;66m'    # ember
        TEXT=$'\033[38;2;245;230;230m'
        MUTED=$'\033[38;2;154;143;143m'
    elif [[ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]]; then
        BLOOD=$'\033[38;5;160m'
        CRIMSON=$'\033[38;5;196m'
        DARK=$'\033[38;5;52m'
        RUST=$'\033[38;5;124m'
        ASH=$'\033[38;5;250m'
        OK=$'\033[38;5;203m'
        WARN=$'\033[38;5;208m'
        TEXT=$'\033[38;5;255m'
        MUTED=$'\033[38;5;245m'
    else
        BLOOD=$'\033[91m'
        CRIMSON=$'\033[31m'
        DARK=$'\033[90m'
        RUST=$'\033[31m'
        ASH=$'\033[37m'
        OK=$'\033[91m'
        WARN=$'\033[33m'
        TEXT=$'\033[97m'
        MUTED=$'\033[90m'
    fi
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
else
    BLOOD='' CRIMSON='' DARK='' RUST='' ASH='' OK='' WARN='' TEXT='' MUTED=''
    BOLD='' DIM='' NC=''
fi

if [[ "$(locale charmap 2>/dev/null || true)" == "UTF-8" ]]; then
    UI_UNICODE=1
    ICON_OK='✓'
    ICON_ERR='✗'
    ICON_INFO='·'
    ICON_WARN='!'
    ICON_MARK='✻'
    SPIN_FRAMES=( '✢' '✳' '✶' '✻' '✽' )
else
    ICON_OK='+'
    ICON_ERR='x'
    ICON_INFO='*'
    ICON_WARN='!'
    ICON_MARK='*'
    SPIN_FRAMES=( '|' '/' '-' '\\' )
fi

SUCCESS="${OK}${ICON_OK}${NC}"
ERROR="${CRIMSON}${ICON_ERR}${NC}"
ARROW="${BLOOD}>${NC}"

# --- ui helpers ------------------------------------------------------------
ui_hr() {
    local width
    width=$(tput cols 2>/dev/null || true)
    [[ -z "$width" || "$width" -le 0 ]] 2>/dev/null && width=${COLUMNS:-56}
    (( width > 72 )) && width=72
    (( width < 24 )) && width=24
    printf '%s\n' "${DARK}$(printf '%*s' "$((width - 2))" '' | tr ' ' '-')${NC}"
}

ui_banner() {
    local title="${1:-HOST CONTROL}"
    local subtitle="${2:-system toolkit}"
    echo
    printf '  %s  %s\n' "${BLOOD}${ICON_MARK}${NC}" "${BOLD}${TEXT}${title}${NC}"
    printf '     %s\n' "${MUTED}${subtitle}${NC}"
}

ui_section() {
    local title="$1"
    echo
    printf '  %s %s\n' "${BLOOD}>${NC}" "${BOLD}${TEXT}${title}${NC}"
}

ui_ok()   { printf '  %s %s\n' "${OK}${ICON_OK}${NC}" "$*"; }
ui_warn() { printf '  %s %s\n' "${WARN}${ICON_WARN}${NC}" "$*"; }
ui_err()  { printf '  %s %s\n' "${CRIMSON}${ICON_ERR}${NC}" "$*"; }
ui_info() { printf '  %s %s\n' "${MUTED}${ICON_INFO}${NC}" "$*"; }

spin_run() {
    local label="$1"
    shift
    local frame=0 pid rc start elapsed

    if [[ "$UI_TTY" -ne 1 ]]; then
        "$@" >/dev/null 2>&1
        rc=$?
        if [[ $rc -eq 0 ]]; then
            ui_ok "$label"
        else
            ui_err "$label"
        fi
        return $rc
    fi

    start=$SECONDS
    "$@" >/dev/null 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$((SECONDS - start))
        printf '\r  %s %s %s\033[K' \
            "${BLOOD}${SPIN_FRAMES[frame]}${NC}" "$label" "${DIM}${elapsed}s${NC}"
        frame=$(( (frame + 1) % ${#SPIN_FRAMES[@]} ))
        sleep 0.09
    done
    wait "$pid"
    rc=$?
    elapsed=$((SECONDS - start))
    if [[ $rc -eq 0 ]]; then
        printf '\r  %s %s %s\033[K\n' "${OK}${ICON_OK}${NC}" "$label" "${DIM}${elapsed}s${NC}"
    else
        printf '\r  %s %s %s\033[K\n' "${CRIMSON}${ICON_ERR}${NC}" "$label" "${DIM}${elapsed}s${NC}"
    fi
    return $rc
}

WHITELIST_FILE="/opt/.whitelist"
BOT_DIR="${BOT_DIR:-/root/bot}"
BACKUP_DIR="${BACKUP_DIR:-/root/backup}"
ZIP_PASSWORD="${ZIP_PASSWORD:-}"

services_registry() {
    # Формат: id|name|type|dir|command|info
    # type = app (tmux) или имя systemd-сервиса.
    # Пример:
    # echo "web|myapp|app|/root/bot/myapp|python3 main.py|@mybot"
    :
}

app_running() { tmux has-session -t "$1" 2>/dev/null; }
app_start() {
    local sname=$1
    local sdir=$2
    local scmd=$3
    tmux new-session -d -s "$sname" "cd '$sdir' && $scmd"
}
app_stop() {
    local sname=$1
    tmux kill-session -t "$sname" 2>/dev/null || true
}

update_line() {
    local line_num=$1
    local text=$2
    echo -ne "\033[${line_num}A\r\033[2K${text}"
    echo -ne "\033[${line_num}B\r"
}

manage_service() {
    local action=$1
    local target_id=$2
    local output_msg=""

    while read -r line; do
        IFS='|' read -r sid sname stype sdir scmd sinfo <<< "$line"
        if [[ "$sid" == "$target_id" || "$sname" == "$target_id" ]]; then
            case $action in
                start)
                    if [[ "$stype" == "app" ]]; then
                        if app_running "$sname"; then
                            output_msg="${WARN}[!]${NC} $sname ${MUTED}already running${NC}"
                        else
                            app_start "$sname" "$sdir" "$scmd"
                            sleep 0.5
                            app_running "$sname" && output_msg="${OK}[+]${NC} $sname ${MUTED}started${NC} ${DARK}($sinfo)${NC}" || output_msg="${CRIMSON}[x]${NC} $sname ${CRIMSON}start failed${NC}"
                        fi
                    else
                        systemctl start "$sname" 2>/dev/null
                        output_msg="${OK}[+]${NC} $sname ${MUTED}started${NC} ${DARK}($sinfo)${NC}"
                    fi
                    ;;
                stop)
                    if [[ "$stype" == "app" ]]; then
                        app_stop "$sname"
                    else
                        systemctl stop "$sname" 2>/dev/null
                    fi
                    output_msg="${CRIMSON}[-]${NC} $sname ${MUTED}stopped${NC}"
                    ;;
                restart)
                    if [[ "$stype" == "app" ]]; then
                        app_stop "$sname"
                        sleep 0.3
                        app_start "$sname" "$sdir" "$scmd"
                        sleep 0.5
                        app_running "$sname" && output_msg="${BLOOD}[~]${NC} $sname ${MUTED}restarted${NC} ${DARK}($sinfo)${NC}" || output_msg="${CRIMSON}[x]${NC} $sname ${CRIMSON}restart failed${NC}"
                    else
                        systemctl restart "$sname" 2>/dev/null
                        output_msg="${BLOOD}[~]${NC} $sname ${MUTED}restarted${NC} ${DARK}($sinfo)${NC}"
                    fi
                    ;;
            esac
            echo -e "$output_msg"
            return
        fi
    done < <(services_registry)
}

bulk_action() {
    local action=$1
    local services=()
    while read -r line; do services+=("$line"); done < <(services_registry)
    local total=${#services[@]}
    ui_banner "SERVICES" "action: $action / total: $total"

    if [[ "$action" == "start" ]]; then
        for line in "${services[@]}"; do
            IFS='|' read -r sid sname stype sdir scmd sinfo <<< "$line"
            manage_service "$action" "$sid"
        done
    else
        for line in "${services[@]}"; do
            IFS='|' read -r sid sname stype sdir scmd sinfo <<< "$line"
            echo -e "${ASH}[wait]${NC} ..."
        done
        local idx=0
        for line in "${services[@]}"; do
            IFS='|' read -r sid sname stype sdir scmd sinfo <<< "$line"
            local offset=$((total - idx))
            local res=$(manage_service "$action" "$sid")
            update_line "$offset" "$res"
            ((idx++))
        done
    fi
}

show_status() {
    ui_banner "SYSTEM STATUS" "live services & processes"
    echo
    while read -r line; do
        IFS='|' read -r sid sname stype sdir scmd sinfo <<< "$line"
        if [[ "$stype" == "app" ]]; then
            if app_running "$sname"; then
                printf '  %s %s  %s  %s\n' \
                    "${OK}${ICON_OK}${NC}" "${BOLD}${TEXT}${sname}${NC}" \
                    "${MUTED}${sinfo}${NC}" "${OK}RUNNING${NC} ${DARK}(tmux)${NC}"
            else
                printf '  %s %s  %s  %s\n' \
                    "${CRIMSON}${ICON_ERR}${NC}" "${BOLD}${TEXT}${sname}${NC}" \
                    "${MUTED}${sinfo}${NC}" "${CRIMSON}OFFLINE${NC}"
            fi
        else
            if systemctl is-active --quiet "$sname"; then
                active=$(systemctl show "$sname" --property=ActiveEnterTimestamp --value | awk '{print $1" "$2}')
                printf '  %s %s  %s  %s %s\n' \
                    "${OK}${ICON_OK}${NC}" "${BOLD}${TEXT}${sname}${NC}" \
                    "${MUTED}${sinfo}${NC}" "${OK}ACTIVE${NC}" "${DARK}${active}${NC}"
            else
                printf '  %s %s  %s  %s\n' \
                    "${CRIMSON}${ICON_ERR}${NC}" "${BOLD}${TEXT}${sname}${NC}" \
                    "${MUTED}${sinfo}${NC}" "${CRIMSON}OFFLINE${NC}"
            fi
        fi
    done < <(services_registry)
    echo
    ui_hr
    printf '  %s %s\n' "${MUTED}tip:${NC}" "${ASH}q.sh status | q.sh start all | q.sh opn${NC}"
    echo
}

# ---------- WHITELIST ----------

whitelist_init() { touch "$WHITELIST_FILE"; }

whitelist_add() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        ui_err "Укажи путь: $0 white add /root/bot"
        return 1
    fi
    local p
    p=$(realpath -m "$raw")
    whitelist_init
    if grep -qxF "$p" "$WHITELIST_FILE"; then
        ui_warn "уже в белом списке: $p"
    else
        echo "$p" >> "$WHITELIST_FILE"
        ui_ok "добавлено в белый список: $p"
    fi
}

whitelist_del() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        ui_err "Укажи путь: $0 white del /root/bot"
        return 1
    fi
    local p
    p=$(realpath -m "$raw")
    whitelist_init
    if is_always_whitelisted "$p"; then
        ui_warn "встроенная защита, удалить нельзя: $p"
        return 1
    fi
    if grep -qxF "$p" "$WHITELIST_FILE"; then
        grep -vxF "$p" "$WHITELIST_FILE" > "${WHITELIST_FILE}.tmp" && mv "${WHITELIST_FILE}.tmp" "$WHITELIST_FILE"
        ui_ok "удалено из белого списка: $p"
    else
        ui_warn "не найдено в белом списке: $p"
    fi
}

whitelist_show() {
    whitelist_init
    ui_banner "WHITELIST" "protected paths & user entries"
    printf '  %s %s\n' "${BLOOD}>${NC}" "${BOLD}${TEXT}ВСТРОЕННЫЕ ЗАЩИТЫ${NC}"
    local p
    for p in "${ALWAYS_WHITELIST_PATHS[@]}"; do
        printf '    %s %s\n' "${OK}+${NC}" "$p"
    done
    echo
    printf '  %s %s\n' "${BLOOD}>${NC}" "${BOLD}${TEXT}ПОЛЬЗОВАТЕЛЬСКИЙ СПИСОК${NC}"
    if [[ ! -s "$WHITELIST_FILE" ]]; then
        printf "    ${MUTED}(пусто)${NC}\n"
    else
        nl -w2 -s'. ' "$WHITELIST_FILE"
    fi
    echo
}

# Постоянный белый список (системно защищённые имена)
ALWAYS_WHITELIST_NAMES=(
    "q.sh"
    ".bashrc"
    ".profile"
    "key.json"
    ".secrets"
    "bot"
    ".ssh"
)

# Критичные пути OpenCode: настройки и данные не должны удаляться.
# Кэш (/root/.cache/opencode) и /tmp/opencode сюда не входят — это мусор.
ALWAYS_WHITELIST_PATHS=(
    "/root/.config/opencode"
    "/root/.local/share/opencode"
    "/root/.local/state/opencode"
    "/root/.opencode"
)

is_always_whitelisted() {
    local target
    target=$(realpath -m "$1")
    local p
    for p in "${ALWAYS_WHITELIST_PATHS[@]}"; do
        [[ "$target" == "$p" || "$target" == "$p"/* ]] && return 0
    done

    local base
    base=$(basename -- "$target")
    local n
    for n in "${ALWAYS_WHITELIST_NAMES[@]}"; do
        [[ "$base" == "$n" ]] && return 0
    done
    return 1
}

# Проверка нахождения пути в белом списке
is_whitelisted() {
    local target
    target=$(realpath -m "$1")
    whitelist_init

    # Защита самого скрипта и файла белого списка
    [[ "$target" == "$WHITELIST_FILE" ]] && return 0
    [[ "$target" == "$(realpath -m "$0")" ]] && return 0

    is_always_whitelisted "$target" && return 0

    local w
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        if [[ "$target" == "$w" || "$target" == "$w"/* ]]; then
            return 0
        fi
    done < "$WHITELIST_FILE"
    return 1
}

# Путь является родителем защищённого пути? Тогда его нельзя удалять целиком,
# нужно зайти внутрь и вычистить только лишнее.
is_ancestor_of_protected() {
    local target
    target=$(realpath -m "$1")
    local p
    for p in "${ALWAYS_WHITELIST_PATHS[@]}"; do
        [[ "$p" == "$target"/* ]] && return 0
    done

    whitelist_init
    local w
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        [[ "$w" == "$target"/* ]] && return 0
    done < "$WHITELIST_FILE"
    return 1
}

CLEAN_REMOVED=0
CLEAN_SKIPPED=0

clean_dir() {
    local dir="$1"
    local item target

    shopt -s dotglob nullglob
    for item in "$dir"/*; do
        [[ -e "$item" || -L "$item" ]] || continue
        target=$(realpath -m "$item")

        if is_whitelisted "$target"; then
            printf '  %s %s\n' "${ASH}[skip]${NC}" "${item} ${DARK}(белый список)${NC}"
            ((CLEAN_SKIPPED++))
            continue
        fi

        if is_ancestor_of_protected "$target"; then
            clean_dir "$item"
            continue
        fi

        rm -rf -- "$item"
        printf '  %s %s\n' "${OK}${ICON_OK}${NC}" "удалено: ${item}"
        ((CLEAN_REMOVED++))
    done
    shopt -u dotglob nullglob
}

# ---------- CLEAN ----------

clear_system() {
    whitelist_init
    CLEAN_REMOVED=0
    CLEAN_SKIPPED=0
    ui_banner "CLEANUP" "safe system & cache cleanup"

    local disk_before
    disk_before=$(df -m / | awk 'NR==2 {print $3}')

    ui_section "Система"
    spin_run "apt autoremove / autoclean / clean" \
        bash -c 'apt-get autoremove --purge -y >/dev/null 2>&1; apt-get autoclean -y >/dev/null 2>&1; apt-get clean >/dev/null 2>&1'

    spin_run "journalctl: 1d / 20M" \
        bash -c 'journalctl --vacuum-time=1d >/dev/null 2>&1; journalctl --vacuum-size=20M >/dev/null 2>&1'

    spin_run "временные файлы: /tmp, /var/tmp" \
        bash -c 'rm -rf /var/log/*.gz /var/log/*.1 /var/log/*.old /var/log/journal/*/*.journal~ /tmp/* /var/tmp/* 2>/dev/null; find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null'

    ui_section "Контейнеры и пакеты"
    if command -v docker >/dev/null 2>&1; then
        spin_run "docker system prune" docker system prune -f
    else
        ui_info "docker не установлен"
    fi
    if command -v snap >/dev/null 2>&1; then
        spin_run "snap: удаление устаревших ревизий" \
            bash -c 'snap list --all 2>/dev/null | awk "/disabled/{print \$1, \$3}" | while read -r n r; do snap remove "$n" --revision="$r" >/dev/null 2>&1; done'
    fi

    ui_section "Кэши и мусор проектов"
    spin_run "кэши Python/Node и __pycache__" \
        bash -c "find '$BOT_DIR' -type d -name '__pycache__' -prune -exec rm -rf -- {} + 2>/dev/null; find '$BOT_DIR' -type d \( -name '.pytest_cache' -o -name '.ruff_cache' \) -prune -exec rm -rf -- {} + 2>/dev/null; rm -rf /root/.npm/_cacache /root/.npm/_logs /root/.cache/pip /root/.cache/uv /root/.cache/yarn /root/.cache/node-gyp /root/.local/share/Trash /root/.thumbnails 2>/dev/null"

    ui_section "Очистка /root"
    ui_info "настройки и данные OpenCode защищены"
    clean_dir /root

    echo
    spin_run "зомби-процессы" \
        bash -c 'ps -A -o stat,ppid | grep -e "^[Zz]" | awk "{print \$2}" | xargs -r kill -9 2>/dev/null || true'

    local disk_after
    disk_after=$(df -m / | awk 'NR==2 {print $3}')
    local freed_disk=$((disk_before - disk_after))
    [[ $freed_disk -lt 0 ]] && freed_disk=0

    echo
    ui_hr
    printf '  %s %s\n' "${OK}${ICON_OK}${NC}" "${BOLD}${TEXT}ОЧИСТКА ЗАВЕРШЕНА${NC}"
    printf "    ${MUTED}удалено:${NC} ${BLOOD}%s${NC}   ${MUTED}пропущено:${NC} ${RUST}%s${NC}   ${MUTED}освобождено:${NC} ${OK}%s MB${NC}\n" \
        "$CLEAN_REMOVED" "$CLEAN_SKIPPED" "$freed_disk"
    ui_hr
}

create_backup() {
    # Проверка наличия переменных окружения Telegram
    if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        ui_banner "BACKUP" "telegram archive"
        ui_err "Не заданы переменные в $ENV_FILE (нужны TG_BOT_TOKEN и TG_CHAT_ID)"
        return 1
    fi
    if [[ -z "$ZIP_PASSWORD" ]]; then
        ui_banner "BACKUP" "telegram archive"
        ui_err "Не задан ZIP_PASSWORD в $ENV_FILE"
        return 1
    fi

    ui_banner "BACKUP" "bot + scripts + /opt -> Telegram"

    local timestamp=$(date +"%d.%m_%H.%M")
    local tar_name="backup_$timestamp.tar.gz"
    local zip_name="backup_$timestamp.zip"
    local backup_dir="$BACKUP_DIR"
    local tar_path="$backup_dir/$tar_name"
    local zip_path="$backup_dir/$zip_name"

    mkdir -p "$backup_dir"

    ui_section "Архив"
    local sh_files=()
    while IFS= read -r f; do sh_files+=("$f"); done < <(find /root -maxdepth 1 -name "*.sh" 2>/dev/null)

    spin_run "создание tar.gz" \
        tar --warning=no-file-changed \
        --exclude="*/.venv"        --exclude="*/.venv/*" \
        --exclude="*/venv"         --exclude="*/venv/*" \
        --exclude="*/node_modules" --exclude="*/node_modules/*" \
        --exclude="*/__pycache__"  --exclude="*/__pycache__/*" \
        --exclude="*/.pytest_cache" --exclude="*/.pytest_cache/*" \
        --exclude="*/.ruff_cache"  --exclude="*/.ruff_cache/*" \
        --exclude="*/.mypy_cache"  --exclude="*/.mypy_cache/*" \
        --exclude="*/.cache"       --exclude="*/.cache/*" \
        --exclude="*/.git"         --exclude="*/.git/*" \
        --exclude="*/.claude"      --exclude="*/.claude/*" \
        --exclude="*/vault"        --exclude="*/vault/*" \
        --exclude="*/logs"         --exclude="*/logs/*" \
        --exclude="*/bot.tar.gz" \
        --exclude="*/music.db" \
        --exclude="*/music.db-*" \
        --exclude="*.log" \
        -czf "$tar_path" \
        "$BOT_DIR" \
        "${sh_files[@]}" \
        /opt/

    if [[ ! -f "$tar_path" ]]; then
        ui_err "ошибка создания архива"
        return 1
    fi
    ui_ok "архив: $(du -h "$tar_path" | cut -f1)"

    spin_run "упаковка в zip" zip -j -P "$ZIP_PASSWORD" "$zip_path" "$tar_path"
    rm -f "$tar_path"

    if [[ ! -f "$zip_path" ]]; then
        ui_err "ошибка создания zip"
        return 1
    fi
    local size=$(du -h "$zip_path" | cut -f1)
    ui_ok "zip: $zip_name ($size)"

    ui_section "Telegram"
    ui_info "отправка..."

    local max_part=$((45 * 1024 * 1024))
    local filesize
    filesize=$(stat -c%s "$zip_path" 2>/dev/null || echo 0)
    local parts=()
    if (( filesize > max_part )); then
        ui_info "архив больше 45 MB - делю на части"
        split -b 45M -d -a 2 "$zip_path" "${zip_path}.part"
        for part in "${zip_path}".part*; do
            [[ -e "$part" ]] && parts+=("$part")
        done
    else
        parts=("$zip_path")
    fi

    local total=${#parts[@]}
    if (( total == 0 )); then
        ui_err "не удалось подготовить файл к отправке"
        return 1
    fi
    local idx=0
    local failed=0
    local tg_result

    for part in "${parts[@]}"; do
        ((idx++))
        local caption="backup $timestamp"
        if (( total > 1 )); then
            caption="$caption - part $idx/$total (cat *.part* > backup.zip)"
        fi
        local curl_params=(-F "document=@$part" -F "chat_id=$TG_CHAT_ID" -F "caption=$caption")
        [[ -n "$TG_THREAD_ID" ]] && curl_params+=(-F "message_thread_id=$TG_THREAD_ID")

        tg_result=$(curl -s "${curl_params[@]}" "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument")
        if echo "$tg_result" | grep -q '"ok":true'; then
            ui_ok "отправлено: $(basename "$part")"
        else
            ui_err "ошибка отправки $(basename "$part"): $tg_result"
            failed=1
        fi
    done

    if (( failed == 0 )); then
        rm -rf "$backup_dir"
        ui_ok "бэкап отправлен в Telegram"
    else
        ui_warn "часть файлов оставлена для повторной отправки: $backup_dir"
        return 1
    fi
}

install_cron() {
    local script_path
    script_path=$(realpath "$0")
    local cron_line="0 4 * * * $script_path zip >> $BACKUP_DIR/cron.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "$script_path zip"; echo "$cron_line") | crontab -
    ui_banner "CRON" "automatic backup"
    ui_ok "ежедневно в 04:00"
}

open_opencode() {
    local session="${1:-${OPENCODE_TMUX_SESSION:-opencode}}"
    local dir="${OPENCODE_DIR:-$PWD}"
    local cmd="${OPENCODE_CMD:-opencode}"

    ui_banner "OPENCODE" "tmux session: $session"

    if ! command -v tmux >/dev/null 2>&1; then
        ui_err "tmux не установлен"
        return 1
    fi
    if ! command -v "$cmd" >/dev/null 2>&1; then
        ui_err "opencode не найден в PATH"
        return 1
    fi

    if tmux has-session -t "$session" 2>/dev/null; then
        ui_info "сессия уже существует, подключаюсь"
    else
        tmux new-session -d -s "$session" -n opencode -c "$dir" "$cmd"
        sleep 0.4
        if ! tmux has-session -t "$session" 2>/dev/null; then
            ui_err "не удалось создать сессию (opencode завершился?)"
            return 1
        fi
        ui_ok "сессия создана: $session"
    fi

    if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "$session"
    else
        tmux attach-session -t "$session"
    fi
}

case $1 in
    start|stop|restart)
        if [[ -z "$2" ]]; then echo "Usage: $0 start <id|all>"; else
            [[ "$2" == "all" ]] && bulk_action "$1" || manage_service "$1" "$2"
        fi
        ;;
    status|st) show_status ;;
    clear)     clear_system ;;
    white)
        case $2 in
            add)        whitelist_add "$3" ;;
            del|remove) whitelist_del "$3" ;;
            list|"")    whitelist_show ;;
            *) echo "Usage: $0 white [add|del|list] <path>" ;;
        esac
        ;;
    zip)       create_backup ;;
    cron)      install_cron ;;
    opn|open)  open_opencode "${2:-}" ;;
    help|*)
        ui_banner "Q.SH" "host control / services / cleanup / backup"
        printf '  %s\n' "${BLOOD}[SERVICES]${NC}"
        printf '    %s  %s\n' "${ASH}start|stop|restart <id|all>${NC}" "${MUTED}- управление сервисами${NC}"
        printf '    %s  %s\n' "${ASH}status | st${NC}" "${MUTED}- статус и аптайм${NC}"
        printf '  %s\n' "${BLOOD}[OPENCODE]${NC}"
        printf '    %s  %s\n' "${ASH}opn [session]${NC}" "${MUTED}- открыть tmux-сессию opencode${NC}"
        printf '  %s\n' "${BLOOD}[MAINTENANCE]${NC}"
        printf '    %s  %s\n' "${ASH}clear${NC}" "${MUTED}- очистка (настройки OpenCode защищены)${NC}"
        printf '    %s  %s\n' "${ASH}zip${NC}" "${MUTED}- бэкап bot + sh + /opt -> Telegram${NC}"
        printf '    %s  %s\n' "${ASH}cron${NC}" "${MUTED}- автобэкап в 04:00${NC}"
        printf '  %s\n' "${BLOOD}[WHITELIST]${NC}"
        printf '    %s  %s\n' "${ASH}white add|del|list <path>${NC}" "${MUTED}- защищённые пути${NC}"
        echo
        ;;
esac
