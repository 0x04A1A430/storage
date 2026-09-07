#!/bin/bash

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

BLOOD='\033[38;5;196m'
CRIMSON='\033[38;5;124m'
DARK='\033[38;5;52m'
RUST='\033[38;5;131m'
ASH='\033[38;5;237m'
NC='\033[0m'

SUCCESS="${BLOOD}✓${NC}"
ERROR="${CRIMSON}✗${NC}"
ARROW="${BLOOD}→${NC}"

WHITELIST_FILE="/opt/.whitelist"

services_registry() {
    echo "we|weather|app|/root/bot/weather|python3 main.py|@weatcybot"
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
                            output_msg="${RUST}[!] $sname уже работает${NC}"
                        else
                            app_start "$sname" "$sdir" "$scmd"
                            sleep 0.5
                            app_running "$sname" && output_msg="${BLOOD}[${SUCCESS}]${NC} $sname запущен ${ASH}($sinfo)${NC}" || output_msg="${CRIMSON}[${ERROR}]${NC} $sname ошибка"
                        fi
                    else
                        systemctl start "$sname" 2>/dev/null
                        output_msg="${BLOOD}[${SUCCESS}]${NC} $sname запущен ${ASH}($sinfo)${NC}"
                    fi
                    ;;
                stop)
                    if [[ "$stype" == "app" ]]; then
                        app_stop "$sname"
                    else
                        systemctl stop "$sname" 2>/dev/null
                    fi
                    output_msg="${BLOOD}[${SUCCESS}]${NC} $sname остановлен"
                    ;;
                restart)
                    if [[ "$stype" == "app" ]]; then
                        app_stop "$sname"
                        sleep 0.3
                        app_start "$sname" "$sdir" "$scmd"
                        sleep 0.5
                        app_running "$sname" && output_msg="${BLOOD}[${SUCCESS}]${NC} $sname перезапущен ${ASH}($sinfo)${NC}" || output_msg="${CRIMSON}[${ERROR}]${NC} $sname ошибка"
                    else
                        systemctl restart "$sname" 2>/dev/null
                        output_msg="${BLOOD}[${SUCCESS}]${NC} $sname перезапущен ${ASH}($sinfo)${NC}"
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
    echo -e "${CRIMSON}СТАТУС СИСТЕМЫ:${NC}\n"
    printf "${ASH}%-12s %-20s %-30s${NC}\n" "СЕРВИС" "ИНФО" "МЕТРИКИ"
    echo -e "${DARK}----------------------------------------------------------------------${NC}"

    services_registry | while read -r line; do
        IFS='|' read -r sid sname stype sdir scmd sinfo <<< "$line"
        if [[ "$stype" == "app" ]]; then
            if app_running "$sname"; then
                session_info=$(tmux list-panes -t "$sname" -F "#{pane_active}" 2>/dev/null || echo "0")
                printf "${BLOOD}[${SUCCESS}] %-9s${NC} ${ASH}%-20s${NC} ${RUST}%-30s${NC}\n" "$sname" "$sinfo" "RUNNING (tmux)"
            else
                printf "${ASH}[${ERROR}] %-9s${NC} ${ASH}%-20s${NC} ${CRIMSON}%-30s${NC}\n" "$sname" "$sinfo" "OFFLINE"
            fi
        else
            if systemctl is-active --quiet "$sname"; then
                active=$(systemctl show "$sname" --property=ActiveEnterTimestamp --value | awk '{print $1" "$2}')
                printf "${BLOOD}[${SUCCESS}] %-9s${NC} ${ASH}%-20s${NC} ${RUST}Active: %-22s${NC}\n" "$sname" "$sinfo" "$active"
            else
                printf "${ASH}[${ERROR}] %-9s${NC} ${ASH}%-20s${NC} ${CRIMSON}%-30s${NC}\n" "$sname" "$sinfo" "OFFLINE"
            fi
        fi
    done
    echo ""
}

# ---------- WHITELIST ----------

whitelist_init() { touch "$WHITELIST_FILE"; }

whitelist_add() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        echo -e "${CRIMSON}[${ERROR}]${NC} Укажи путь: $0 white add /root/bot"
        return 1
    fi
    local p
    p=$(realpath -m "$raw")
    whitelist_init
    if grep -qxF "$p" "$WHITELIST_FILE"; then
        echo -e "${RUST}[!] Уже в белом списке: $p${NC}"
    else
        echo "$p" >> "$WHITELIST_FILE"
        echo -e "${BLOOD}[${SUCCESS}]${NC} Добавлено в белый список: ${ASH}$p${NC}"
    fi
}

whitelist_del() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        echo -e "${CRIMSON}[${ERROR}]${NC} Укажи путь: $0 white del /root/bot"
        return 1
    fi
    local p
    p=$(realpath -m "$raw")
    whitelist_init
    if grep -qxF "$p" "$WHITELIST_FILE"; then
        grep -vxF "$p" "$WHITELIST_FILE" > "${WHITELIST_FILE}.tmp" && mv "${WHITELIST_FILE}.tmp" "$WHITELIST_FILE"
        echo -e "${BLOOD}[${SUCCESS}]${NC} Удалено из белого списка: ${ASH}$p${NC}"
    else
        echo -e "${RUST}[!] Не найдено в белом списке: $p${NC}"
    fi
}

whitelist_show() {
    whitelist_init
    echo -e "${CRIMSON}БЕЛЫЙ СПИСОК (не удаляется при clear):${NC}"
    if [[ ! -s "$WHITELIST_FILE" ]]; then
        echo -e "${ASH}(пусто)${NC}"
    else
        nl -w2 -s'. ' "$WHITELIST_FILE"
    fi
}

# Постоянный белый список (системно защищённые имена)
ALWAYS_WHITELIST_NAMES=(
    "q.sh"
    ".bashrc"
    ".profile"
    "key.json"
    ".secrets"
    "bot"
    "remnawave"
    "remnawave-bot"
    "Heroku"
    "pornbot"
    ".ssh"
)

is_always_whitelisted() {
    local base
    base=$(basename -- "$1")
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

# ---------- CLEAN ----------

clear_system() {
    whitelist_init
    echo -e "${CRIMSON}ОЧИСТКА СИСТЕМЫ${NC}"

    local disk_before
    disk_before=$(df -m / | awk 'NR==2 {print $3}')

    echo -ne "${ASH}[*]${NC} Пакеты (apt autoremove, autoclean, clean)..."
    apt-get autoremove --purge -y >/dev/null 2>&1
    apt-get autoclean -y >/dev/null 2>&1
    apt-get clean >/dev/null 2>&1
    echo -e "\r\033[2K${BLOOD}[${SUCCESS}]${NC} apt autoremove / autoclean / clean выполнены"

    echo -ne "${ASH}[*]${NC} Журналы (journalctl: 1d / 20M)..."
    journalctl --vacuum-time=1d >/dev/null 2>&1
    journalctl --vacuum-size=20M >/dev/null 2>&1
    echo -e "\r\033[2K${BLOOD}[${SUCCESS}]${NC} journalctl очищен"

    echo -ne "${ASH}[*]${NC} Логи и временные файлы (/tmp, /var/tmp, .cache)..."
    rm -rf /var/log/*.gz /var/log/*.1 /var/log/*.old /var/log/journal/*/*.journal~ /tmp/* /var/tmp/* /root/.cache/* 2>/dev/null
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
    echo -e "\r\033[2K${BLOOD}[${SUCCESS}]${NC} Логи и временные файлы очищены"

    echo -ne "${ASH}[*]${NC} Docker и Snap..."
    if command -v docker >/dev/null 2>&1; then
        docker system prune -f >/dev/null 2>&1 || true
    fi
    if command -v snap >/dev/null 2>&1; then
        snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r n r; do
            snap remove "$n" --revision="$r" >/dev/null 2>&1
        done
    fi
    apt-get autoremove --purge -y >/dev/null 2>&1
    echo -e "\r\033[2K${BLOOD}[${SUCCESS}]${NC} Docker / Snap проверены"

    local removed=0 skipped=0
    shopt -s dotglob nullglob
    for item in /root/*; do
        [[ -e "$item" ]] || continue
        if is_whitelisted "$item"; then
            echo -e "${ASH}[skip]${NC} $item ${DARK}(белый список)${NC}"
            ((skipped++))
        else
            rm -rf -- "$item"
            echo -e "${BLOOD}[${SUCCESS}]${NC} удалено: ${ASH}$item${NC}"
            ((removed++))
        fi
    done
    shopt -u dotglob nullglob

    echo -ne "${ASH}[*]${NC} Зомби-процессы..."
    local z_count
    z_count=$(ps -A -o stat | grep -c '^[Zz]')
    ps -A -o stat,ppid | grep -e '^[Zz]' | awk '{print $2}' | xargs -r kill -9 2>/dev/null
    echo -e "\r\033[2K${BLOOD}[${SUCCESS}]${NC} Зомби-процессы: $z_count убрано"

    local disk_after
    disk_after=$(df -m / | awk 'NR==2 {print $3}')
    local freed_disk=$((disk_before - disk_after))
    [[ $freed_disk -lt 0 ]] && freed_disk=0

    echo -e "\n${CRIMSON}ИТОГ:${NC} Удалено объектов: ${BLOOD}$removed${NC}, пропущено: ${RUST}$skipped${NC}, освобождено диска: ${BLOOD}${freed_disk} MB${NC}"
}

create_backup() {
    # Проверка наличия переменных окружения Telegram
    if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        echo -e "${CRIMSON}[${ERROR}]${NC} Не заданы переменные в $ENV_FILE (нужны TG_BOT_TOKEN и TG_CHAT_ID)"
        return 1
    fi

    local timestamp=$(date +"%d.%m_%H.%M")
    local tar_name="backup_$timestamp.tar.gz"
    local zip_name="backup_$timestamp.zip"
    local backup_dir="/root/backup"
    local tar_path="$backup_dir/$tar_name"
    local zip_path="$backup_dir/$zip_name"

    mkdir -p "$backup_dir"

    echo -ne "${ASH}[1/3]${NC} Создание архива..."
    local sh_files=()
    while IFS= read -r f; do sh_files+=("$f"); done < <(find /root -maxdepth 1 -name "*.sh" 2>/dev/null)

    tar --warning=no-file-changed \
        --exclude="*/.venv"        --exclude="*/.venv/*" \
        --exclude="*/__pycache__"  --exclude="*/__pycache__/*" \
        --exclude="*/.git"         --exclude="*/.git/*" \
        --exclude="*/.claude"      --exclude="*/.claude/*" \
        --exclude="*/vault"        --exclude="*/vault/*" \
        --exclude="*/logs"         --exclude="*/logs/*" \
        -czf "$tar_path" \
        /root/bot \
        "${sh_files[@]}" \
        /opt/ 2>/dev/null

    if [[ ! -f "$tar_path" ]]; then
        echo -e "\r\033[2K${CRIMSON}[${ERROR}]${NC} Ошибка создания архива"
        return 1
    fi
    echo -e "\r\033[2K${BLOOD}[${SUCCESS}]${NC} Архив создан: $(du -h "$tar_path" | cut -f1)"

    echo -ne "${ASH}[2/3]${NC} Запаковка в zip..."
    zip -j -P "1808" "$zip_path" "$tar_path" >/dev/null 2>&1
    rm -f "$tar_path"

    if [[ ! -f "$zip_path" ]]; then
        echo -e "\r\033[2K${CRIMSON}[${ERROR}]${NC} Ошибка создания zip"
        return 1
    fi
    local size=$(du -h "$zip_path" | cut -f1)
    echo -e "\r\033[2K${BLOOD}[${SUCCESS}]${NC} ZIP готов: ${RUST}$zip_name ($size)${NC}"

    echo -ne "${ASH}[3/3]${NC} Отправка в Telegram..."
    local curl_params=(-F "document=@$zip_path" -F "chat_id=$TG_CHAT_ID")
    [[ -n "$TG_THREAD_ID" ]] && curl_params+=(-F "message_thread_id=$TG_THREAD_ID")

    local tg_result
    tg_result=$(curl -s "${curl_params[@]}" "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument")

    rm -rf "$backup_dir"

    if echo "$tg_result" | grep -q '"ok":true'; then
        echo -e "\r\033[2K${BLOOD}[${SUCCESS}]${NC} Отправлено в Telegram"
    else
        echo -e "\r\033[2K${CRIMSON}[${ERROR}]${NC} Ошибка отправки в Telegram: $tg_result"
    fi
}

install_cron() {
    local script_path
    script_path=$(realpath "$0")
    local cron_line="0 4 * * * $script_path zip >> /root/backup/cron.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "$script_path zip"; echo "$cron_line") | crontab -
    echo -e "${BLOOD}[${SUCCESS}]${NC} Крон установлен: ежедневно в 04:00"
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
    help|*)
        echo -e "${BLOOD}RED${NC}"
        echo "start|stop|restart <id|all>"
        echo "status - ресурсы и аптайм"
        echo "clear  - очистка системы и /root/, кроме путей из белого списка"
        echo "white add <path>  - добавить путь в белый список (не удалять)"
        echo "white del <path>  - убрать путь из белого списка"
        echo "white list        - показать белый список"
        echo "zip    - бэкап bot+sh+opt → tar.gz → zip(1808) → TG"
        echo "cron   - установить автобэкап в 04:00 ежедневно"
        ;;
esac
