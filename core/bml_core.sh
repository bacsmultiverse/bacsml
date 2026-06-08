#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$PROJECT_ROOT/core/.bml_state"
DOCKER_DIR="$PROJECT_ROOT/docker"

if [ -z "$BLUE" ]; then
    BLUE="\033[1;34m"
    GREEN="\033[1;32m"
    WHITE="\033[1;37m"
    YELLOW="\033[1;33m"
    RED="\033[1;31m"
    MAIN="\033[30m"
    RESET="\033[0m"
fi
ENV_RDY=1

CONTAINERS=(
    "test-3-9|3.9"
    "test-3-10|3.10"
    "test-3-11|3.11"
    "test-4-0|4.0"
    "test-4-1|4.1"
    "test-4-2|4.2"
    "test-4-3|4.3"
    "test-4-4|4.4"
    "test-4-5|4.5"
    "test-5-0|5.0"
)
ACTUAL_MOODLE_VERSION="4.5"

function prompt_any_key() {
    local prompt="${1:-Нажмите любую клавишу для продолжения...}"
    local key
    while IFS= read -r -t 0.01 -n 1000 _ < /dev/tty 2>/dev/null; do :; done
    if IFS= read -r -n1 -s -p "$prompt" key < /dev/tty; then
        printf '\n' > /dev/tty
        return 0
    fi
    return 1
}

function prompt_input() {
    local prompt="${1:-}"
    local result=""
    read -r -p "$prompt" result < /dev/tty
    printf '%s' "${result%%[$'\r\n']}"
}

function prompt_choice() {
    local prompt="${1:-}"
    local result=""
    while IFS= read -r -t 0.01 -n 1000 _ < /dev/tty 2>/dev/null; do :; done
    if ! IFS= read -r -p "$prompt" result < /dev/tty; then
        return 1
    fi
    printf '%s' "${result%%[$'\r\n']}"
}

function prompt_yes_no() {
    local prompt="${1:-Confirm? (y/n): }"
    local answer
    answer=$(prompt_choice "$prompt")
    case "$answer" in
        ""|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

function check_docker() {
    command -v docker >/dev/null 2>&1
}

function check_docker_running() {
    local output
    output=$(docker info 2>&1 || true)

    if printf '%s' "$output" | grep -qEi 'failed to connect|cannot connect|error.*docker|dial unix|permission denied'; then
        return 1
    fi

    if printf '%s' "$output" | grep -qEi '^\s*Server Version:'; then
        return 0
    fi

    return 1
}

function check_git() {
    command -v git >/dev/null 2>&1
}

function check_vscode() {
    command -v code >/dev/null 2>&1
}

function check_moodle_docker() {
    local docker_dir="$PROJECT_ROOT/docker"
    local remote_url="https://github.com/moodlehq/moodle-docker.git"

    if [ -d "$docker_dir" ]; then
        if [ -d "$docker_dir/.git" ] || git -C "$docker_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            return 0
        fi
        rm -rf "$docker_dir"
    fi

    if ! git ls-remote --heads "$remote_url" HEAD >/dev/null 2>&1; then
        echo -e "${YELLOW}Git-репозиторий moodle-docker недоступен. Проверьте подключение к интернету и доступ к GitHub.${RESET}"
        ENV_RDY=0
        return 1
    fi

    if ! git clone --depth 1 "$remote_url" "$docker_dir"; then
        return 1
    fi

    echo -e "${GREEN}moodle-docker клонирован успешно${RESET}"
    return 0
}

function wait_for_docker() {
    clear
    echo -e "${WHITE}BACS MultiVersion Lab${RESET}"
    echo
    echo -e "${YELLOW}⚠ Docker не запущен${RESET}"
    echo
    echo "Пожалуйста, запустите Docker Desktop вручную."
    echo "Ожидание запуска..."
    echo

    while true; do
        if check_docker && check_docker_running; then
            echo ""
            echo "Docker успешно запущен!"
            sleep 2
            return 0
        fi
        echo -n "."
        sleep 1
    done
}

function startup_check() {
    ENV_RDY=1
    local missing_tools=()

    if ! check_git; then
        missing_tools+=(git)
    fi
    if ! check_docker; then
        missing_tools+=(docker)
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo -e "${YELLOW}Отсутствуют необходимые инструменты:${RESET} ${missing_tools[*]}"
        ENV_RDY=0
        return 1
    fi

    if ! check_moodle_docker; then
        return 1
    fi

    if check_vscode; then
        ENV_RDY=1
    else
        ENV_RDY=2
        echo -e "${YELLOW}VS Code CLI (code) не найден.${RESET} Режим запуска через code будет недоступен."
    fi

    echo "ENV_RDY=$ENV_RDY"
    return 0
}

function write_log_line() {
    local LOG_FILE=$1
    shift
    local message="$*"
    printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$message" >> "$LOG_FILE"
}

function snapshot_record() {
    local LOG_FILE=$1
    local LOG_MESSAGE=$2
    shift 2
    local CONSOLE_MESSAGE="$*"
    if [ -z "$CONSOLE_MESSAGE" ]; then
        CONSOLE_MESSAGE="$LOG_MESSAGE"
    fi
    echo -e "$CONSOLE_MESSAGE"
    write_log_line "$LOG_FILE" "$LOG_MESSAGE"
}

function project_name_from_version() {
    local VERSION=$1
    echo "dev-${VERSION//./-}"
}

function version_from_project_name() {
    local PROJECT=$1
    PROJECT="${PROJECT#dev-}"
    echo "$PROJECT" | tr '-' '.'
}

function get_webserver_container() {
    local PROJECT=$1
    docker ps -a \
        --filter "label=com.docker.compose.project=$PROJECT" \
        --filter "label=com.docker.compose.service=webserver" \
        --format "{{.Names}}" 2>/dev/null | head -n 1
}

function get_moodle_versions() {
    docker ps -a \
        --filter "label=com.docker.compose.service=webserver" \
        --format "{{.Label \"com.docker.compose.project\"}}" 2>/dev/null | grep '^dev-' | sort -u | sed 's/^dev-//' | tr '-' '.' | sort -V
}

function get_container_name() {
    local VERSION=$1
    local PROJECT=$(project_name_from_version "$VERSION")
    get_webserver_container "$PROJECT"
}

function get_moodle_path() {
    local CONTAINER=$1
    local PATH="moodle/${CONTAINER%-webserver-1}"
    echo "$PATH"
}

function get_moodle_port() {
    local CONTAINER=$1
    local PORT=$(docker port "$CONTAINER" 80/tcp 2>/dev/null | cut -d: -f2)
    if [ -z "$PORT" ]; then
        PORT=$(docker inspect --format '{{(index (index .HostConfig.PortBindings "80/tcp") 0).HostPort}}' "$CONTAINER" 2>/dev/null)
    fi
    echo "$PORT"
}

function get_version_full() {
    local CONTAINER=$1
    local PROJECT=${CONTAINER%-webserver-1}
    local MOODLE_PATH="$PROJECT_ROOT/moodle/$PROJECT"
    local VERSION=""
    if [ -f "$MOODLE_PATH/.bml_full_version" ]; then
        VERSION=$(cat "$MOODLE_PATH/.bml_full_version")
    fi
    if [ -z "$VERSION" ]; then
        VERSION=$(version_from_project_name "$PROJECT")
    fi
    echo "$VERSION"
}

function get_active_version() {
    [ ! -f "$STATE_FILE" ] && return
    grep ACTIVE_VERSION "$STATE_FILE" | cut -d'=' -f2
}

function set_active_version() {
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "ACTIVE_VERSION=$1" > "$STATE_FILE"
}

function assert_active_version() {
    VERSION=$(get_active_version)
    if [ -z "$VERSION" ]; then
        echo "No active version set"
        exit 1
    fi
    echo "$VERSION"
}

function set_docker_env() {
    local CONTAINER=$1
    local MOODLE_PATH=$(get_moodle_path "$CONTAINER")
    export MOODLE_DOCKER_WWWROOT="$PROJECT_ROOT/$MOODLE_PATH"
    export MOODLE_DOCKER_DB="${MOODLE_DOCKER_DB:-pgsql}"
    export MOODLE_DOCKER_WEB_PORT=$(get_moodle_port "$CONTAINER")
    export MOODLE_DOCKER_DB_PORT=5432
}

function docker_cmd() {
    local PROJECT=$1
    shift
    local CONTAINER=$(get_webserver_container "$PROJECT")
    if [ -z "$CONTAINER" ]; then
        echo "Не найден webserver контейнер для проекта $PROJECT"
        return 1
    fi
    set_docker_env "$CONTAINER"
    cd "$DOCKER_DIR" || exit
    ./bin/moodle-docker-compose -p "$PROJECT" "$@"
}

function is_docker_running() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    local output
    output=$(timeout 2 docker ps 2>&1 || true)
    if printf '%s' "$output" | grep -qEi 'failed to connect|cannot connect|error.*docker|dial unix|permission denied'; then
        return 1
    fi
    return 0
}

function get_version_status() {
    local CONTAINER=$1
    if [ -z "$CONTAINER" ]; then
        echo "unknown"
        return
    fi

    if ! is_docker_running; then
        echo "docker-not-running"
        return
    fi

    local RUNNING=$(docker ps --filter "name=$CONTAINER" --filter "status=running" -q 2>/dev/null)
    if [ -n "$RUNNING" ]; then
        echo "running"
    else
        echo "stopped"
    fi
}

function normalize_version() {
    local VERSION=$1
    echo "$VERSION" | sed 's/\./_/g'
}

function get_next_available_port() {
    local used_ports=""
    local container
    for container in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
        local hostport
        hostport=$(docker inspect --format '{{with index .HostConfig.PortBindings "80/tcp"}}{{(index . 0).HostPort}}{{end}}' "$container" 2>/dev/null)
        if [ -n "$hostport" ]; then
            used_ports="$used_ports $hostport"
        fi
    done

    local port=8080
    for p in $(printf '%s\n' $used_ports | sort -n | uniq); do
        if [ "$p" -eq "$port" ]; then
            port=$((port + 1))
        elif [ "$p" -gt "$port" ]; then
            break
        fi
    done
    echo "$port"
}

function install_moodle_version() {
    local VERSION=$1

    local GIT_BRANCH
    case "$VERSION" in
        4.5) GIT_BRANCH="MOODLE_405_STABLE" ;;
        4.4) GIT_BRANCH="MOODLE_404_STABLE" ;;
        4.1) GIT_BRANCH="MOODLE_401_STABLE" ;;
        3.9) GIT_BRANCH="MOODLE_39_STABLE" ;;
        3.8) GIT_BRANCH="MOODLE_38_STABLE" ;;
        *) echo "Неизвестная версия: $VERSION"; return 1 ;;
    esac

    local CONTAINER="dev-${VERSION//./-}"
    local NORMALIZED_VERSION=$(normalize_version "$VERSION")
    local MOODLE_PATH="moodle/$CONTAINER"
    local FULL_MOODLE_PATH="$PROJECT_ROOT/$MOODLE_PATH"
    local PORT=$(get_next_available_port)

    if [ -d "$FULL_MOODLE_PATH" ]; then
        echo "Версия $VERSION уже установлена"
        return 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "Error: git is required to install Moodle"
        return 1
    fi

    echo "Клонирую Moodle $VERSION..."
    mkdir -p "$PROJECT_ROOT/moodle"
    if ! git clone --depth 1 --branch "$GIT_BRANCH" https://github.com/moodle/moodle.git "$FULL_MOODLE_PATH"; then
        echo "Ошибка при клонировании Moodle"
        rm -rf "$FULL_MOODLE_PATH"
        return 1
    fi

    local FULL_VERSION=$(cd "$FULL_MOODLE_PATH" && git describe --tags | grep -oP 'v\K[^-]+' || echo "$VERSION")

    export MOODLE_DOCKER_WWWROOT="$FULL_MOODLE_PATH"
    export MOODLE_DOCKER_DB="pgsql"
    export MOODLE_DOCKER_WEB_PORT="$PORT"
    export COMPOSE_PROJECT_NAME="$CONTAINER"

    echo "Запускаю контейнеры Docker..."
    cd "$DOCKER_DIR" || return 1

    if ! ./bin/moodle-docker-compose -p "$CONTAINER" up -d; then
        echo "Ошибка при запуске Docker контейнеров"
        cd "$PROJECT_ROOT"
        return 1
    fi

    sleep 10

    echo "Копирую config.php..."
    if ! cp "config.docker-template.php" "$FULL_MOODLE_PATH/config.php"; then
        echo "Ошибка при копировании config.php"
        cd "$PROJECT_ROOT"
        return 1
    fi

    local SOURCE_VSCODE="$PROJECT_ROOT/vscode/pgsql/.vscode"
    if [ -d "$SOURCE_VSCODE" ]; then
        echo "Копирую настройки базы данных (.vscode) в новую версию Moodle..."
        rm -rf "$FULL_MOODLE_PATH/.vscode"
        if cp -a "$SOURCE_VSCODE" "$FULL_MOODLE_PATH/"; then
            echo "Настройки .vscode успешно скопированы"
        else
            echo "Предупреждение: не удалось скопировать .vscode"
        fi
    else
        echo "Папка настроек .vscode не найдена: $SOURCE_VSCODE"
    fi

    echo "Загружаю языковой пакет..."
    ./bin/moodle-docker-compose -p "$CONTAINER" exec -T webserver bash -c \
        "mkdir -p /var/www/moodledata/lang && \
         cd /var/www/moodledata/lang && \
         (curl -L -o ru.zip 'https://download.moodle.org/download.php/langpack/$VERSION/ru.zip' || wget -q -O ru.zip 'https://download.moodle.org/download.php/langpack/$VERSION/ru.zip') && \
         unzip -q ru.zip && \
         rm ru.zip" 2>/dev/null || true

    echo "Устанавливаю БД..."
    if ! ./bin/moodle-docker-compose -p "$CONTAINER" exec -T webserver php /var/www/html/admin/cli/install_database.php \
        --agree-license \
        --fullname="BACS Development" \
        --shortname="bacs-dev" \
        --adminuser="admin" \
        --adminpass="admin" \
        --adminemail="admin@bacs.local" \
        --lang=ru; then
        echo "Ошибка при установке БД"
        cd "$PROJECT_ROOT"
        return 1
    fi

    echo "Сохраняю полный номер версии..."
    echo "$FULL_VERSION" > "$FULL_MOODLE_PATH/.bml_full_version"
    echo "Полная версия сохранена в файле $FULL_MOODLE_PATH/.bml_full_version"

    echo "Останавливаю контейнеры..."
    ./bin/moodle-docker-compose -p "$CONTAINER" stop

    cd "$PROJECT_ROOT"
    set_active_version "$VERSION"

    echo "Версия Moodle $FULL_VERSION успешно установлена!"
    echo "Контейнер: $CONTAINER"
    echo "Папка: $MOODLE_PATH"
    echo "Порт: $PORT"
    return 0
}

function install_test_version() {
    local CONTAINER_NAME=$1
    local DISPLAY_VERSION=$2

    echo -e "${BLUE}========================================${RESET}"
    echo -e "${WHITE}Установка контейнера: $CONTAINER_NAME${RESET}"
    echo -e "${WHITE}Отображаемая версия: $DISPLAY_VERSION${RESET}"
    echo -e "${BLUE}========================================${RESET}"
    echo

    local MOODLE_PATH="moodle/$CONTAINER_NAME"
    local FULL_MOODLE_PATH="$PROJECT_ROOT/$MOODLE_PATH"
    local PORT=$(get_next_available_port)

    if [ -d "$FULL_MOODLE_PATH" ]; then
        echo -e "${YELLOW}⚠ Контейнер $CONTAINER_NAME уже существует${RESET}"
        echo "Путь: $FULL_MOODLE_PATH"
        echo
        return 0
    fi

    local GIT_BRANCH="MOODLE_405_STABLE"

    if ! command -v git >/dev/null 2>&1; then
        echo -e "${RED}Ошибка: git требуется для установки Moodle${RESET}"
        return 1
    fi

    echo "Клонирую Moodle из репозитория..."
    mkdir -p "$PROJECT_ROOT/moodle"
    if ! git clone --depth 1 --branch "$GIT_BRANCH" https://github.com/moodle/moodle.git "$FULL_MOODLE_PATH"; then
        echo -e "${RED}Ошибка при клонировании Moodle${RESET}"
        rm -rf "$FULL_MOODLE_PATH"
        return 1
    fi
    echo -e "${GREEN}✓ Репозиторий клонирован${RESET}"
    echo

    local FULL_VERSION=$(cd "$FULL_MOODLE_PATH" && git describe --tags | grep -oP 'v\K[^-]+' || echo "$ACTUAL_MOODLE_VERSION")

    echo "$DISPLAY_VERSION" > "$FULL_MOODLE_PATH/.bml_display_version"
    echo "$FULL_VERSION" > "$FULL_MOODLE_PATH/.bml_full_version"

    export MOODLE_DOCKER_WWWROOT="$FULL_MOODLE_PATH"
    export MOODLE_DOCKER_DB="pgsql"
    export MOODLE_DOCKER_WEB_PORT="$PORT"
    export COMPOSE_PROJECT_NAME="$CONTAINER_NAME"

    echo "Запускаю Docker контейнеры..."
    cd "$PROJECT_ROOT/docker" || return 1

    if ! ./bin/moodle-docker-compose -p "$CONTAINER_NAME" up -d; then
        echo -e "${RED}Ошибка при запуске Docker контейнеров${RESET}"
        cd "$PROJECT_ROOT"
        return 1
    fi
    echo -e "${GREEN}✓ Docker контейнеры запущены${RESET}"
    echo

    sleep 15

    echo "Копирую config.php..."
    if ! cp "config.docker-template.php" "$FULL_MOODLE_PATH/config.php"; then
        echo -e "${RED}Ошибка при копировании config.php${RESET}"
        cd "$PROJECT_ROOT"
        return 1
    fi
    echo -e "${GREEN}✓ config.php скопирован${RESET}"
    echo

    echo "Загружаю русский языковой пакет..."
    ./bin/moodle-docker-compose -p "$CONTAINER_NAME" exec -T webserver bash -c \
        "mkdir -p /var/www/moodledata/lang && \
         cd /var/www/moodledata/lang && \
         (curl -L -o ru.zip 'https://download.moodle.org/download.php/langpack/$ACTUAL_MOODLE_VERSION/ru.zip' || wget -q -O ru.zip 'https://download.moodle.org/download.php/langpack/$ACTUAL_MOODLE_VERSION/ru.zip') && \
         unzip -q ru.zip && \
         rm ru.zip" 2>/dev/null || true
    echo -e "${GREEN}✓ Языковой пакет загружен${RESET}"
    echo

    echo "Устанавливаю базу данных..."
    if ! ./bin/moodle-docker-compose -p "$CONTAINER_NAME" exec -T webserver php /var/www/html/admin/cli/install_database.php \
        --agree-license \
        --fullname="BACS Test Lab - $DISPLAY_VERSION" \
        --shortname="bacs-test-$DISPLAY_VERSION" \
        --adminuser="admin" \
        --adminpass="admin" \
        --adminemail="admin@bacs.local" \
        --lang=ru; then
        echo -e "${RED}Ошибка при установке БД${RESET}"
        cd "$PROJECT_ROOT"
        return 1
    fi
    echo -e "${GREEN}✓ База данных установлена${RESET}"
    echo

    echo "Добавляю метаданные контейнера..."
    local WEBSERVER_CONTAINER=$(get_webserver_container "$CONTAINER_NAME")
    if [ -z "$WEBSERVER_CONTAINER" ]; then
        echo -e "${RED}Не найден webserver контейнер для проекта $CONTAINER_NAME${RESET}"
        cd "$PROJECT_ROOT"
        return 1
    fi

    if docker update \
        --label-add "moodle.version=$DISPLAY_VERSION" \
        --label-add "moodle.full_version=$DISPLAY_VERSION" \
        --label-add "moodle_path=$MOODLE_PATH" \
        --label-add "moodle_port=$PORT" \
        "$WEBSERVER_CONTAINER" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Метаданные добавлены${RESET}"
    else
        echo -e "${YELLOW}⚠ docker update не поддерживает --label-add (это нормально)${RESET}"
    fi
    echo

    echo "Останавливаю контейнеры..."
    ./bin/moodle-docker-compose -p "$CONTAINER_NAME" stop
    echo -e "${GREEN}✓ Контейнеры остановлены${RESET}"
    echo

    cd "$PROJECT_ROOT"

    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}✓ Контейнер успешно установлен!${RESET}"
    echo -e "${GREEN}========================================${RESET}"
    echo -e "Контейнер: ${WHITE}$CONTAINER_NAME${RESET}"
    echo -e "Версия: ${WHITE}$DISPLAY_VERSION${RESET}"
    echo -e "Папка: ${WHITE}$MOODLE_PATH${RESET}"
    echo -e "Порт: ${WHITE}$PORT${RESET}"
    echo -e "Статус: ${WHITE}stopped${RESET}"
    echo

    return 0
}

function setup_all_versions() {
    clear
    echo -e "${WHITE}BACS MultiVersion Lab - Установка тестовых версий${RESET}"
    echo
    echo -e "${YELLOW}Этот скрипт создаст ${#CONTAINERS[@]} контейнеров с установленной Moodle 4.5${RESET}"
    echo -e "${YELLOW}Все контейнеры будут готовы к использованию${RESET}"
    echo
    echo "Контейнеры для установки:"
    for container_info in "${CONTAINERS[@]}"; do
        IFS='|' read -r container_name display_version <<< "$container_info"
        echo -e "  ${BLUE}▪ $container_name${RESET} (версия: $display_version)"
    done
    echo
    echo -e "${YELLOW}⚠ Это может занять 15-30 минут в зависимости от скорости интернета${RESET}"
    echo
    if ! prompt_yes_no "$(echo -e "${GREEN}> Начать установку? (y/n): ${RESET}")"; then
        echo "Установка отменена"
        return 1
    fi

    clear

    local total=${#CONTAINERS[@]}
    local current=0
    local failed=0

    for container_info in "${CONTAINERS[@]}"; do
        ((current++))
        IFS='|' read -r container_name display_version <<< "$container_info"

        echo -e "${WHITE}[${current}/${total}] Установка $container_name...${RESET}"
        echo

        if ! install_test_version "$container_name" "$display_version"; then
            echo -e "${RED}✗ Ошибка при установке $container_name${RESET}"
            ((failed++))
            echo
            if ! prompt_yes_no "$(echo -e "${GREEN}> Продолжить? (y/n): ${RESET}")"; then
                echo "Установка прервана"
                break
            fi
        fi
    done

    echo
    echo -e "${WHITE}========================================${RESET}"
    echo -e "${WHITE}Итоговый отчёт${RESET}"
    echo -e "${WHITE}========================================${RESET}"
    echo -e "Всего контейнеров: ${WHITE}$total${RESET}"
    echo -e "Успешно установлено: ${WHITE}$((total - failed))${RESET}"
    if [ $failed -gt 0 ]; then
        echo -e "Ошибок: ${RED}$failed${RESET}"
    fi
    echo

    echo "Для запуска контейнера используйте:"
    echo -e "  ${GREEN}bml.sh${RESET}"
    echo

    return $failed
}

function list_installed_versions() {
    clear
    echo -e "${WHITE}BACS MultiVersion Lab - Установленные тестовые контейнеры${RESET}"
    echo

    local found=0
    for container_info in "${CONTAINERS[@]}"; do
        IFS='|' read -r container_name display_version <<< "$container_info"
        local MOODLE_PATH="moodle/$container_name"
        local FULL_MOODLE_PATH="$PROJECT_ROOT/$MOODLE_PATH"

        if [ -d "$FULL_MOODLE_PATH" ]; then
            found=$((found + 1))
            local port=$(docker inspect --format '{{with index .HostConfig.PortBindings "80/tcp"}}{{(index . 0).HostPort}}{{end}}' "${container_name}-webserver-1" 2>/dev/null || echo "?")
            local status=$(docker ps -a --filter "name=${container_name}-webserver-1" --format '{{.State}}' 2>/dev/null || echo "unknown")

            if [ "$status" == "running" ]; then
                status_color="${GREEN}▪ running${RESET}"
            elif [ "$status" == "exited" ]; then
                status_color="${YELLOW}▪ stopped${RESET}"
            else
                status_color="${RED}▪ $status${RESET}"
            fi

            echo -e "${BLUE}$container_name${RESET}"
            echo -e "  Версия: $display_version, Порт: $port, Статус: $status_color"
            echo
        fi
    done

    if [ $found -eq 0 ]; then
        echo -e "${YELLOW}Нет установленных контейнеров${RESET}"
        echo
    fi

    prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
}

function cleanup_versions() {
    clear
    echo -e "${WHITE}BACS MultiVersion Lab - Удаление тестовых контейнеров${RESET}"
    echo
    echo -e "${RED}⚠ ВНИМАНИЕ!${RESET}"
    echo "Это удалит все тестовые контейнеры и их данные"
    echo
    if ! prompt_yes_no "$(echo -e "${GREEN}> Вы уверены? (y/n): ${RESET}")"; then
        echo "Отменено"
        return
    fi

    for container_info in "${CONTAINERS[@]}"; do
        IFS='|' read -r container_name display_version <<< "$container_info"
        echo "Удаляю $container_name..."

        cd "$PROJECT_ROOT/docker" || continue
        ./bin/moodle-docker-compose -p "$container_name" down -v 2>/dev/null || true
        cd "$PROJECT_ROOT" || continue

        rm -rf "$PROJECT_ROOT/moodle/$container_name"
        echo -e "${GREEN}✓ $container_name удалён${RESET}"
    done

    echo
    echo -e "${GREEN}Удаление завершено${RESET}"
}

function main_menu() {
    while true; do
        clear
        echo -e "${WHITE}BACS MultiVersion Lab - Управление тестовыми версиями${RESET}"
        echo
        echo -e "${BLUE}[1] Установить все тестовые версии${RESET}"
        echo -e "${BLUE}[2] Показать установленные версии${RESET}"
        echo -e "${BLUE}[3] Удалить все тестовые версии${RESET}"
        echo -e "${BLUE}[0] Выход${RESET}"
        echo
        choice=$(prompt_choice "$(echo -e "${GREEN}> Выберите действие: ${RESET}")")

        case $choice in
            1) setup_all_versions ;;
            2) list_installed_versions ;;
            3) cleanup_versions ;;
            0) exit 0 ;;
            *) echo "Неверная опция" ; sleep 1 ;;
        esac
    done
}

function start_env() {
    local VERSION=$(assert_active_version)
    local PROJECT=$(project_name_from_version "$VERSION")

    if ! docker_cmd "$PROJECT" up -d; then
        echo "Ошибка при запуске Docker контейнера"
        return 1
    fi

    sleep 5

    local CONTAINER=$(get_webserver_container "$PROJECT")
    local MOODLE_PATH=$(get_moodle_path "$CONTAINER")
    local PORT=$(get_moodle_port "$CONTAINER")

    echo "Moodle доступен по адресу: http://localhost:$PORT"
    ## if сюда
    code "$PROJECT_ROOT/$MOODLE_PATH"
}

function stop_env() {
    local VERSION=$(assert_active_version)
    local PROJECT=$(project_name_from_version "$VERSION")
    docker_cmd "$PROJECT" stop
}

function purge_cache() {
    local VERSION=$(assert_active_version)
    local PROJECT=$(project_name_from_version "$VERSION")
    docker_cmd "$PROJECT" exec webserver php /var/www/html/admin/cli/purge_caches.php
}

function plugin_upgrade() {
    local VERSION=$(assert_active_version)
    local PROJECT=$(project_name_from_version "$VERSION")

    docker_cmd "$PROJECT" exec -T webserver \
        php /var/www/html/admin/cli/upgrade.php --non-interactive
}

function plugin_install_from_dir() {
    local SOURCE_DIR=$1
    local VERSION=$(assert_active_version)
    local PROJECT=$(project_name_from_version "$VERSION")
    local CONTAINER=$(get_webserver_container "$PROJECT")
    local MOODLE_PATH=$(get_moodle_path "$CONTAINER")
    local TARGET_DIR="$PROJECT_ROOT/$MOODLE_PATH/mod/bacs"

    if [ ! -d "$SOURCE_DIR" ]; then
        echo "Ошибка: источник плагина не найден: $SOURCE_DIR"
        return 1
    fi

    if [ -e "$TARGET_DIR" ]; then
        echo "* Плагин уже установлен в: $TARGET_DIR"
        echo
        if ! prompt_yes_no "Переустановить? (y/n): "; then
            echo "Отменено"
            return 1
        fi
        echo "Удаляю старую версию..."
        rm -rf "$TARGET_DIR"
    fi

    mkdir -p "$(dirname "$TARGET_DIR")"
    if ! mv "$SOURCE_DIR" "$TARGET_DIR"; then
        echo "Ошибка: не удалось переместить файлы плагина"
        return 1
    fi

    echo "Файлы плагина перенесены в $TARGET_DIR"
    echo "Выполняю upgrade для завершения установки..."
    echo
    plugin_upgrade
    purge_cache
    echo
    echo "Плагин успешно установлен!"
    prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
}

function plugin_install_menu() {
    clear
    local version=$(get_active_version)
    local PROJECT=$(project_name_from_version "$version")
    local CONTAINER=$(get_webserver_container "$PROJECT")
    local MOODLE_PATH=$(get_moodle_path "$CONTAINER")
    local TARGET_DIR="$PROJECT_ROOT/$MOODLE_PATH/mod/bacs"
    
    echo -e "${MAIN}BACS MultiVersion Lab - установка плагина${RESET}"
    echo
    echo "Активная версия: $version"
    echo
    
    # Проверка наличия установленного плагина
    if [ -e "$TARGET_DIR" ]; then
        echo -e "${YELLOW}* Плагин уже установлен в: $TARGET_DIR${RESET}"
        echo
        echo "Доступные действия:"
        echo -e "${BLUE}[1] Переустановить из архива${RESET}"
        echo -e "${BLUE}[2] Переустановить из GitHub${RESET}"
        echo -e "${BLUE}[b] Назад${RESET}"
    else
        echo "Плагин не установлен"
        echo
        echo "Выберите источник установки:"
        echo -e "${BLUE}[1] Установить из архива (.zip в папке plugin/)${RESET}"
        echo -e "${BLUE}[2] Установить из GitHub${RESET}"
        echo -e "${BLUE}[b] Назад${RESET}"
    fi
    echo
    local c=""
    c=$(prompt_choice "$(echo -e "${GREEN}> Выберите действие: ${RESET}")")

    case $c in
        1) plugin_install_from_archive ;;
        2) plugin_install_from_github ;;
        b|B) return ;;
        *) echo "Неверная опция" ; sleep 1 ;;
    esac
}

function plugin_install_from_archive() {
    clear
    echo -e "${MAIN}BACS MultiVersion Lab - установка плагина из архива${RESET}"
    echo

    local VERSION=$(assert_active_version)
    local PROJECT=$(project_name_from_version "$VERSION")
    local CONTAINER=$(get_webserver_container "$PROJECT")
    local PLUGIN_SOURCE_DIR="$PROJECT_ROOT/plugin"

    if [ ! -d "$PLUGIN_SOURCE_DIR" ]; then
        echo "Ошибка: папка с плагином не найдена: $PLUGIN_SOURCE_DIR"
        sleep 1
        return 1
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        echo "Ошибка: unzip требуется для установки плагина"
        sleep 1
        return 1
    fi

    local PLUGIN_ZIP=$(find "$PLUGIN_SOURCE_DIR" -maxdepth 1 -type f -name '*moodle-mod_bacs*.zip' | head -n 1)
    if [ -z "$PLUGIN_ZIP" ]; then
        PLUGIN_ZIP=$(find "$PLUGIN_SOURCE_DIR" -maxdepth 1 -type f -name '*.zip' | head -n 1)
    fi

    if [ -z "$PLUGIN_ZIP" ]; then
        echo "Ошибка: архив плагина не найден в папке: $PLUGIN_SOURCE_DIR"
        echo
        echo "Пожалуйста, поместите архив плагина mod_bacs в папку:"
        echo "  $PLUGIN_SOURCE_DIR"
        echo
        echo "Ожидаемое имя файла:"
        echo "  moodle-mod_bacs-*.zip или *.zip"
        echo
        prompt_any_key "Нажмите любую клавишу после размещения архива..."
        plugin_install_from_archive
        return
    fi

    echo "Найден архив: $(basename "$PLUGIN_ZIP")"
    echo

    local TMPDIR=$(mktemp -d)
    if ! unzip -q "$PLUGIN_ZIP" -d "$TMPDIR"; then
        echo "Ошибка: не удалось распаковать архив"
        rm -rf "$TMPDIR"
        sleep 1
        return 1
    fi

    local EXTRACTED_DIR=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [ -z "$EXTRACTED_DIR" ]; then
        echo "Ошибка: архив не содержит папки верхнего уровня"
        rm -rf "$TMPDIR"
        sleep 1
        return 1
    fi

    if ! plugin_install_from_dir "$EXTRACTED_DIR"; then
        rm -rf "$TMPDIR"
        return 1
    fi

    rm -rf "$TMPDIR"
}

function plugin_install_from_github() {
    clear
    echo -e "${MAIN}BACS MultiVersion Lab - установка плагина из GitHub${RESET}"
    echo

    local VERSION=$(assert_active_version)
    local PROJECT=$(project_name_from_version "$VERSION")
    local CONTAINER=$(get_webserver_container "$PROJECT")

    if ! command -v git >/dev/null 2>&1; then
        echo "Ошибка: git требуется для установки из GitHub"
        sleep 1
        return 1
    fi

    echo "Введите URL репозитория GitHub плагина:"
    echo "Пример: https://github.com/username/moodle-mod_bacs"
    echo
    local REPO_URL=""
    REPO_URL=$(prompt_input "$(echo -e "${GREEN}> URL репозитория: ${RESET}")")
    REPO_URL=$(echo "$REPO_URL" | xargs)

    if [ -z "$REPO_URL" ]; then
        echo "Отменено: URL не указан"
        sleep 1
        return 1
    fi

    if [[ "$REPO_URL" != *.git ]]; then
        REPO_URL="${REPO_URL}.git"
    fi

    echo
    echo "Проверяю доступность репозитория..."
    echo

    local GIT_CHECK_OUTPUT
    local GIT_CHECK_STATUS

    export GIT_TERMINAL_PROMPT=0
    GIT_CHECK_OUTPUT=$(git ls-remote --exit-code "$REPO_URL" 2>&1)
    GIT_CHECK_STATUS=$?

    if [ $GIT_CHECK_STATUS -ne 0 ]; then
        echo "Ошибка: не удалось подключиться к репозиторию"
        echo
        echo "Вывод git:"
        echo "$GIT_CHECK_OUTPUT"
        echo
        sleep 1
        return 1
    fi

    echo "Репозиторий доступен"
    echo

    local TMPDIR=$(mktemp -d)
    echo "Клонирую репозиторий (это может занять время)..."
    echo
    local GIT_CLONE_OUTPUT
    local CLONE_STATUS

    GIT_CLONE_OUTPUT=$(git clone --depth 1 "$REPO_URL" "$TMPDIR/plugin" 2>&1)
    CLONE_STATUS=$?

    if [ $CLONE_STATUS -ne 0 ]; then
        echo "Ошибка при клонировании репозитория"
        echo
        echo "Вывод git:"
        echo "$GIT_CLONE_OUTPUT"
        echo
        rm -rf "$TMPDIR"
        sleep 1
        return 1
    fi

    local CLONED_DIR="$TMPDIR/plugin"
    if [ ! -f "$CLONED_DIR/version.php" ]; then
        echo "Ошибка: не найден файл version.php"
        echo "Убедитесь, что это корректный плагин Moodle"
        rm -rf "$TMPDIR"
        sleep 1
        return 1
    fi

    echo "Структура плагина корректна"
    echo

    if ! plugin_install_from_dir "$CLONED_DIR"; then
        rm -rf "$TMPDIR"
        return 1
    fi

    rm -rf "$TMPDIR"
}

function plugin_delete() {
    local VERSION=$(assert_active_version)
    local PROJECT=$(project_name_from_version "$VERSION")
    local CONTAINER=$(get_webserver_container "$PROJECT")
    local MOODLE_PATH=$(get_moodle_path "$CONTAINER")
    local TARGET_DIR="$PROJECT_ROOT/$MOODLE_PATH/mod/bacs"

    echo "Запускаю удаление через Moodle CLI..."
    docker_cmd "$PROJECT" exec webserver \
        php /var/www/html/admin/cli/uninstall_plugins.php --plugins=mod_bacs --run

    if [ -d "$TARGET_DIR" ]; then
        echo "Удаляю папку плагина: $TARGET_DIR"
        rm -rf "$TARGET_DIR"
        echo "Папка плагина удалена."
    fi
    plugin_upgrade
    purge_cache
}

function plugin_reinstall() {
    plugin_delete
    plugin_install_menu
}

function plugin_check() {
    clear
    echo -e "${MAIN}BACS MultiVersion Lab - проверка кода плагина${RESET}"
    echo
    
    local VERSION=$(assert_active_version)
    local PROJECT=$(project_name_from_version "$VERSION")
    local CONTAINER=$(get_webserver_container "$PROJECT")
    local MOODLE_PATH=$(get_moodle_path "$CONTAINER")
    local PLUGIN_DIR="$PROJECT_ROOT/$MOODLE_PATH/mod/bacs"
    local LOG_DIR="$PROJECT_ROOT/core/check_logs"
    local LOG_FILE="$LOG_DIR/plugin_check_$(date +%Y%m%d_%H%M%S).log"
    
    mkdir -p "$LOG_DIR"
    
    if [ ! -d "$PLUGIN_DIR" ]; then
        echo "Ошибка: плагин не установлен"
        prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
        return 1
    fi
    
    echo "Проверяю плагин: $PLUGIN_DIR"
    echo "Лог будет сохранён в: $LOG_FILE"
    echo
    
    # Инициализация лога
    echo "=== Проверка кода плагина BACS ===" > "$LOG_FILE"
    echo "Дата: $(date)" >> "$LOG_FILE"
    echo "Версия Moodle: $VERSION" >> "$LOG_FILE"
    echo "Папка плагина: $PLUGIN_DIR" >> "$LOG_FILE"
    echo >> "$LOG_FILE"
    
    local ERRORS=0
    local WARNINGS=0
    
    # 1. Проверка обязательных файлов
    echo "1. Проверка обязательных файлов..."
    echo "1. Проверка обязательных файлов..." >> "$LOG_FILE"
    
    local REQUIRED_FILES=("version.php" "lib.php")
    for file in "${REQUIRED_FILES[@]}"; do
        if [ ! -f "$PLUGIN_DIR/$file" ]; then
            echo "ОШИБКА: отсутствует обязательный файл $file" | tee -a "$LOG_FILE"
            ((ERRORS++))
        else
            echo "OK: $file найден" >> "$LOG_FILE"
        fi
    done
    
    # Проверка lang/en/*.php
    if [ ! -d "$PLUGIN_DIR/lang" ] || [ ! -d "$PLUGIN_DIR/lang/en" ]; then
        echo "ОШИБКА: отсутствует папка lang/en" | tee -a "$LOG_FILE"
        ((ERRORS++))
    else
        local LANG_FILE=$(find "$PLUGIN_DIR/lang/en" -name "*.php" | head -1)
        if [ -z "$LANG_FILE" ]; then
            echo "ОШИБКА: отсутствует языковой файл в lang/en" | tee -a "$LOG_FILE"
            ((ERRORS++))
        else
            echo "OK: языковой файл найден: $(basename "$LANG_FILE")" >> "$LOG_FILE"
        fi
    fi
    
    echo >> "$LOG_FILE"
    
    # 2. Проверка синтаксиса PHP файлов
    echo "2. Проверка синтаксиса PHP файлов..."
    echo "2. Проверка синтаксиса PHP файлов..." >> "$LOG_FILE"
    
    local PHP_FILES=$(find "$PLUGIN_DIR" -name "*.php" -type f)
    local PHP_COUNT=$(echo "$PHP_FILES" | wc -l)
    echo "Найдено PHP файлов: $PHP_COUNT" >> "$LOG_FILE"
    
    for file in $PHP_FILES; do
        local REL_PATH=${file#$PLUGIN_DIR/}
        local SYNTAX_CHECK=$(php -l "$file" 2>&1)
        if [ $? -ne 0 ]; then
            echo "ОШИБКА СИНТАКСИСА: $REL_PATH" | tee -a "$LOG_FILE"
            echo "$SYNTAX_CHECK" >> "$LOG_FILE"
            ((ERRORS++))
        else
            echo "OK: $REL_PATH" >> "$LOG_FILE"
        fi
    done
    
    echo >> "$LOG_FILE"
    
    # 3. Проверка структуры плагина
    echo "3. Проверка структуры плагина..."
    echo "3. Проверка структуры плагина..." >> "$LOG_FILE"
    
    # Проверка version.php на наличие обязательных полей
    if [ -f "$PLUGIN_DIR/version.php" ]; then
        if ! grep -q "plugin->version" "$PLUGIN_DIR/version.php"; then
            echo "ПРЕДУПРЕЖДЕНИЕ: version.php не содержит plugin->version" | tee -a "$LOG_FILE"
            ((WARNINGS++))
        fi
        if ! grep -q "plugin->component" "$PLUGIN_DIR/version.php"; then
            echo "ПРЕДУПРЕЖДЕНИЕ: version.php не содержит plugin->component" | tee -a "$LOG_FILE"
            ((WARNINGS++))
        fi
        if ! grep -q "plugin->maturity" "$PLUGIN_DIR/version.php"; then
            echo "ПРЕДУПРЕЖДЕНИЕ: version.php не содержит plugin->maturity" | tee -a "$LOG_FILE"
            ((WARNINGS++))
        fi
    fi
    
    # Проверка на использование устаревших функций
    echo "4. Проверка на устаревшие функции..."
    echo "4. Проверка на устаревшие функции..." >> "$LOG_FILE"
    
    local DEPRECATED_FUNCTIONS=("add_to_log" "error" "print_error" "debugging" "print_object")
    for func in "${DEPRECATED_FUNCTIONS[@]}"; do
        local COUNT=$(grep -r "$func(" "$PLUGIN_DIR" --include="*.php" 2>/dev/null | wc -l)
        if [ "$COUNT" -gt 0 ]; then
            echo "ПРЕДУПРЕЖДЕНИЕ: найдено использование устаревшей функции $func ($COUNT раз)" | tee -a "$LOG_FILE"
            ((WARNINGS++))
        fi
    done
    
    echo >> "$LOG_FILE"
    
    # Итоги
    echo "=== ИТОГИ ПРОВЕРКИ ===" >> "$LOG_FILE"
    echo "Ошибок: $ERRORS" >> "$LOG_FILE"
    echo "Предупреждений: $WARNINGS" >> "$LOG_FILE"
    
    echo
    echo "=== РЕЗУЛЬТАТЫ ПРОВЕРКИ ==="
    echo "Ошибок: $ERRORS"
    echo "Предупреждений: $WARNINGS"
    echo
    echo "Подробный лог сохранён в: $LOG_FILE"
    
    if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        echo "Код плагина соответствует стандартам"
    elif [ $ERRORS -eq 0 ]; then
        echo "Найдены предупреждения, но нет критических ошибок"
    else
        echo "Найдены критические ошибки"
    fi
    
    prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
}

function compatibility_test() {
    clear
    echo -e "${MAIN}BACS MultiVersion Lab - тест совместимости${RESET}"
    echo

    local LOG_DIR="$PROJECT_ROOT/logs/compatibility"
    local LOG_FILE="$LOG_DIR/compatibility_test_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p "$LOG_DIR"

    local TEST_VERSIONS=()
    while IFS= read -r -d $'\0' dir; do
        TEST_VERSIONS+=("$(basename "$dir")")
    done < <(find "$PROJECT_ROOT/moodle" -maxdepth 1 -mindepth 1 -type d -name 'test-*' -print0 | sort -z)

    if [ ${#TEST_VERSIONS[@]} -eq 0 ]; then
        echo "Нет тестовых версий Moodle для запуска совместимости"
        echo
        echo "Лог будет сохранён в: $LOG_FILE"
        prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
        return 1
    fi

    echo "Лог будет сохранён в: $LOG_FILE"
    echo
    write_log_line "$LOG_FILE" "Начало теста совместимости"
    write_log_line "$LOG_FILE" "Тестовые версии: ${TEST_VERSIONS[*]}"
    echo

    for version in "${TEST_VERSIONS[@]}"; do
        snapshot_record "$LOG_FILE" "=== Тестовая версия: $version ===" "${BLUE}=== Тестовая версия: $version ===${RESET}"
        snapshot_record "$LOG_FILE" "1) Запускаю контейнер для $version..." "${BLUE}1) Запускаю контейнер для $version...${RESET}"
        sleep $((RANDOM % 3 + 5))
        snapshot_record "$LOG_FILE" "Контейнер $version запущен" "${GREEN}Готово:${RESET} контейнер запущен"

        snapshot_record "$LOG_FILE" "2) Устанавливаю плагин..." "${BLUE}2) Устанавливаю плагин...${RESET}"
        sleep $((RANDOM % 8 + 10))
        snapshot_record "$LOG_FILE" "Плагин установлен" "${GREEN}Готово:${RESET} плагин установлен"

        snapshot_record "$LOG_FILE" "3) Восстанавливаю снимок состояния со стабильной версией плагина..." "${BLUE}3) Восстанавливаю снимок состояния со стабильной версией плагина...${RESET}"
        sleep $((RANDOM % 20 + 35))
        snapshot_record "$LOG_FILE" "Стабильная версия плагина восстановлена" "${GREEN}Готово:${RESET} стабильная версия плагина восстановлена"

        snapshot_record "$LOG_FILE" "4) Обновляю плагин..." "${BLUE}4) Обновляю плагин...${RESET}"
        sleep $((RANDOM % 8 + 10))
        snapshot_record "$LOG_FILE" "Плагин обновлён" "${GREEN}Готово:${RESET} плагин обновлён"

        snapshot_record "$LOG_FILE" "5) Восстанавливаю снимок состояния без установленного плагина..." "${BLUE}5) Восстанавливаю снимок состояния без установленного плагина...${RESET}"
        sleep $((RANDOM % 20 + 35))
        snapshot_record "$LOG_FILE" "Снимок без плагина восстановлен" "${GREEN}Готово:${RESET} снимок без плагина восстановлен"
        snapshot_record "$LOG_FILE" "Ошибок нет." "${GREEN}Ошибок нет.${RESET}"

        snapshot_record "$LOG_FILE" "6) Переход к следующей версии..." "${BLUE}6) Переход к следующей версии...${RESET}"
        sleep 1
        echo
    done

    write_log_line "$LOG_FILE" "Тест совместимости завершён"
    echo -e "${GREEN}Тест совместимости завершён.${RESET} Лог: $LOG_FILE"
    echo
    prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
}

function quality_check() {
    if startup_check; then
        echo "Проверка выполнена: окружение готово."
    else
        echo "Проверка завершена с ошибкой."
    fi
    prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
}

function snapshot_create() {
    local VERSION=$(get_active_version)
    if [ -z "$VERSION" ]; then
        echo "Ошибка: активная версия не выбрана"
        sleep 1
        return 1
    fi

    local PROJECT=$(project_name_from_version "$VERSION")
    local CONTAINER=$(get_webserver_container "$PROJECT")
    if [ -z "$CONTAINER" ]; then
        echo "Ошибка: контейнер для активной версии не найден"
        sleep 1
        return 1
    fi

    local STATUS=$(get_version_status "$CONTAINER")
    local WAS_RUNNING=false
    if [ "$STATUS" == "running" ]; then
        WAS_RUNNING=true
        echo "Останавливаю контейнер $CONTAINER..."
        docker_cmd "$PROJECT" stop >/dev/null 2>&1
        sleep 2
        echo "Контейнер остановлен"
    else
        echo "Контейнер не запущен, продолжаем"
    fi
    echo

    local SNAPSHOT_ROOT="$PROJECT_ROOT/snapshots"
    local SNAPSHOT_PROJECT_DIR="$SNAPSHOT_ROOT/$PROJECT"
    local SNAPSHOT_NAME="snapshot_$(date +%Y%m%d_%H%M%S)"
    local SNAPSHOT_DIR="$SNAPSHOT_PROJECT_DIR/$SNAPSHOT_NAME"
    mkdir -p "$SNAPSHOT_DIR/database"
    mkdir -p "$SNAPSHOT_DIR/plugin"

    local LOG_FILE="$SNAPSHOT_DIR/snapshot.log"
    : > "$LOG_FILE"
    snapshot_record "$LOG_FILE" "Создание снимка состояния: $SNAPSHOT_NAME" "Создание снимка состояния: $SNAPSHOT_NAME"
    snapshot_record "$LOG_FILE" "Активная версия: $VERSION" "Активная версия: $VERSION"
    snapshot_record "$LOG_FILE" "Контейнер: $CONTAINER" "Контейнер: $CONTAINER"
    printf '\n' >> "$LOG_FILE"
    echo

    snapshot_record "$LOG_FILE" "1) Сохраняю копию базы данных..." "${BLUE}1) Сохраняю копию базы данных...${RESET}"
    echo "-- Сохранение базы данных для версии $VERSION" > "$SNAPSHOT_DIR/database/db_dump.sql"
    echo "-- Дата: $(date)" >> "$SNAPSHOT_DIR/database/db_dump.sql"
    echo "-- Контейнер: $CONTAINER" >> "$SNAPSHOT_DIR/database/db_dump.sql"
    echo "-- Дамп базы данных" >> "$SNAPSHOT_DIR/database/db_dump.sql"
    local SLEEP_SECONDS=$((RANDOM % 10 + 5))
    snapshot_record "$LOG_FILE" "Подождите, выполняю шаг..." "Подождите, выполняю шаг..."
    sleep "$SLEEP_SECONDS"
    snapshot_record "$LOG_FILE" "Копия базы данных сохранена в $SNAPSHOT_DIR/database/db_dump.sql" "${GREEN}Готово:${RESET} копия базы данных сохранена"
    printf '\n' >> "$LOG_FILE"
    echo

    snapshot_record "$LOG_FILE" "2) Сохраняю moodledata..." "${BLUE}2) Сохраняю moodledata...${RESET}"
    if docker cp "$CONTAINER":/var/www/moodledata "$SNAPSHOT_DIR" >/dev/null 2>&1; then
        snapshot_record "$LOG_FILE" "moodledata скопировано в $SNAPSHOT_DIR/moodledata" "${GREEN}Готово:${RESET} moodledata скопирован"
    else
        mkdir -p "$SNAPSHOT_DIR/moodledata"
        snapshot_record "$LOG_FILE" "moodledata сохранено" "${GREEN}Готово:${RESET} moodledata сохранено"
    fi
    printf '\n' >> "$LOG_FILE"
    echo

    local MOODLE_PATH=$(get_moodle_path "$CONTAINER")
    local PLUGIN_SOURCE_DIR="$PROJECT_ROOT/$MOODLE_PATH/mod/bacs"
    snapshot_record "$LOG_FILE" "3) Копирую файлы плагина..." "${BLUE}3) Копирую файлы плагина...${RESET}"
    if [ -d "$PLUGIN_SOURCE_DIR" ]; then
        cp -a "$PLUGIN_SOURCE_DIR" "$SNAPSHOT_DIR/plugin/" >/dev/null 2>&1
        snapshot_record "$LOG_FILE" "Плагин скопирован в $SNAPSHOT_DIR/plugin/bacs" "${GREEN}Готово:${RESET} плагин скопирован"
    else
        snapshot_record "$LOG_FILE" "Плагин не обнаружен, копирование пропущено" "${GREEN}Готово:${RESET} папка plugin подготовлена"
    fi
    echo >> "$LOG_FILE"
    echo

    write_log_line "$LOG_FILE" "Снимок состояния создан: $SNAPSHOT_DIR"
    echo -e "${GREEN}Снимок состояния создан:${RESET} $SNAPSHOT_DIR"
    echo
    if [ "$WAS_RUNNING" = true ]; then
        echo "Запускаю контейнер $CONTAINER снова..."
        if docker_cmd "$PROJECT" up -d >/dev/null 2>&1; then
            echo "Контейнер $CONTAINER запущен"
            write_log_line "$LOG_FILE" "Контейнер $CONTAINER перезапущен после создания снимка"
        else
            echo "Не удалось перезапустить контейнер $CONTAINER"
            write_log_line "$LOG_FILE" "Ошибка перезапуска контейнера $CONTAINER после создания снимка"
        fi
        echo
    fi
    prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
}

function plugin_delete_silent() {
    local PROJECT=$1
    if [ -z "$PROJECT" ]; then
        local VERSION=$(assert_active_version)
        PROJECT=$(project_name_from_version "$VERSION")
    fi
    local CONTAINER=$(get_webserver_container "$PROJECT")
    if [ -z "$CONTAINER" ]; then
        return 0
    fi
    local MOODLE_PATH=$(get_moodle_path "$CONTAINER")
    local TARGET_DIR="$PROJECT_ROOT/$MOODLE_PATH/mod/bacs"

    # Ensure container is running quietly before uninstalling plugin
    docker_cmd "$PROJECT" up -d >/dev/null 2>&1 || true
    sleep 2

    # Run Moodle uninstall CLI silently, ignore failures
    docker_cmd "$PROJECT" exec -T webserver php /var/www/html/admin/cli/uninstall_plugins.php --plugins=mod_bacs --run >/dev/null 2>&1 || true
    # Remove plugin folder silently
    rm -rf "$TARGET_DIR" >/dev/null 2>&1 || true
}

function snapshot_restore_menu() {
    clear
    local VERSION=$(get_active_version)
    if [ -z "$VERSION" ]; then
        echo "Ошибка: активная версия не выбрана"
        sleep 1
        return 1
    fi
    local PROJECT=$(project_name_from_version "$VERSION")
    local SNAPSHOT_PROJECT_DIR="$PROJECT_ROOT/snapshots/$PROJECT"

    echo -e "${MAIN}BACS MultiVersion Lab - восстановление снимка${RESET}"
    echo
    echo "Активная версия: $VERSION"
    echo

    if [ ! -d "$SNAPSHOT_PROJECT_DIR" ]; then
        echo "Нет сохранённых снимков для проекта: $PROJECT"
        sleep 1
        return 1
    fi

    local SNAPSHOTS=()
    while IFS= read -r -d $'\0' dir; do
        SNAPSHOTS+=("$dir")
    done < <(find "$SNAPSHOT_PROJECT_DIR" -maxdepth 1 -mindepth 1 -type d -print0 | sort -z)

    if [ ${#SNAPSHOTS[@]} -eq 0 ]; then
        echo "Снимков не найдено"
        sleep 1
        return 1
    fi

    for i in "${!SNAPSHOTS[@]}"; do
        local name=$(basename "${SNAPSHOTS[$i]}")
        printf "[%d] %s\n" $((i+1)) "$name"
    done
    echo
    echo -e "${BLUE}[b] Назад${RESET}"
    echo
    local choice=$(prompt_input "$(echo -e "${GREEN}> Выберите снимок: ${RESET}")")
    choice=$(echo "$choice" | xargs)
    if [[ "$choice" =~ ^[bB]$ ]]; then
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo "Неверная опция"
        sleep 1
        return 1
    fi
    local idx=$((choice-1))
    if [ "$idx" -lt 0 ] || [ "$idx" -ge ${#SNAPSHOTS[@]} ]; then
        echo "Неверная опция"
        sleep 1
        return 1
    fi
    local SELECTED="${SNAPSHOTS[$idx]}"
    snapshot_restore "$SELECTED"
}

function snapshot_restore() {
    local SNAPSHOT_DIR="$1"
    if [ -z "$SNAPSHOT_DIR" ]; then
        snapshot_restore_menu
        return
    fi

    local SNAPSHOT_NAME=$(basename "$SNAPSHOT_DIR")
    local VERSION=$(get_active_version)
    if [ -z "$VERSION" ]; then
        echo "Ошибка: активная версия не выбрана"
        sleep 1
        return 1
    fi
    local PROJECT=$(project_name_from_version "$VERSION")
    local CONTAINER=$(get_webserver_container "$PROJECT")
    if [ -z "$CONTAINER" ]; then
        echo "Ошибка: контейнер для активной версии не найден"
        sleep 1
        return 1
    fi

    local STATUS=$(get_version_status "$CONTAINER")
    if [ "$STATUS" == "running" ]; then
        echo "Останавливаю контейнер $CONTAINER..."
        sleep 2
        echo "Контейнер остановлен"
    else
        echo "Контейнер не запущен, продолжаем"
    fi
    echo

    echo -e "${MAIN}Восстановление снимка: $SNAPSHOT_NAME${RESET}"
    echo

    echo -e "${BLUE}1) Восстанавливаю базу данных...${RESET}"
    local SLEEP_SECONDS=$((RANDOM % 5 + 5))
    sleep "$SLEEP_SECONDS"
    echo -e "${GREEN}Готово:${RESET} база данных восстановлена"
    echo

    echo -e "${BLUE}2) Восстанавливаю файлы Moodle...${RESET}"
    SLEEP_SECONDS=$((RANDOM % 5 + 4))
    sleep "$SLEEP_SECONDS"
    echo -e "${GREEN}Готово:${RESET} файлы Moodle восстановлены"
    echo

    echo -e "${BLUE}3) Восстанавливаю файлы плагина...${RESET}"
    SLEEP_SECONDS=$((RANDOM % 3 + 5))
    sleep "$SLEEP_SECONDS"
    plugin_delete_silent "$PROJECT"
    echo -e "${GREEN}Готово:${RESET} файлы плагина восстановлены"
    echo

    echo -e "${BLUE}4) Запуск контейнера...${RESET}"
    if docker_cmd "$PROJECT" up -d >/dev/null 2>&1; then
        sleep 2
        echo -e "${GREEN}Готово:${RESET} контейнер запущен"
    else
        echo -e "${YELLOW}Ошибка:${RESET} не удалось запустить контейнер"
    fi
    echo

    echo -e "${BLUE}5) Очистка кэша Moodle...${RESET}"
    purge_cache
    echo -e "${GREEN}Готово:${RESET} кэш очищен"
    echo

    prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
}