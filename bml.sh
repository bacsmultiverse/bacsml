#!/bin/bash

source "$(dirname "$0")/core/bml_core.sh"

BLUE="\033[1;34m"
GREEN="\033[1;32m"
MAIN="\033[30m"
YELLOW="\033[1;33m"
RESET="\033[0m"

function main_menu() {
    while true; do
        clear
        echo -e "${MAIN}BACS MultiVersion Lab - главное меню${RESET}"
        echo
        echo -e "${BLUE}[1] Выбрать версию Moodle${RESET}"
        echo -e "${BLUE}[2] Управление окружением${RESET}"
        echo -e "${BLUE}[3] Управление плагином${RESET}"
        echo -e "${BLUE}[4] Управление снимками состояния${RESET}"
        echo -e "${BLUE}[5] Проверить код плагина${RESET}"
        echo -e "${BLUE}[6] Управление тестовыми версиями${RESET}"
        echo -e "${BLUE}[7] Запустить тест совместимости${RESET}"
        echo -e "${BLUE}[e] Выход${RESET}"
        echo
        choice=$(prompt_choice "$(echo -e "${GREEN}> Выберите действие: ${RESET}")")

        case $choice in
            1) select_version ;;
            2) env_menu ;;
            3) plugin_menu ;;
            4) snapshot_menu ;;
            5) plugin_check ;;
            6) bash "$(dirname "$0")/core/bml_setupversions.sh" ;;
            7) compatibility_test ;;
            e|E) exit 0 ;;
            *) echo "Неверная опция" ; sleep 1 ;;
        esac
    done
}

function select_version() {
    clear
    echo -e "${MAIN}BACS MultiVersion Lab - выбор версии Moodle${RESET}"
    echo

    local versions=($(get_moodle_versions))
    local active_version=$(get_active_version)
    local i=1

    if [ ${#versions[@]} -eq 0 ]; then
        echo "Нет установленных версий Moodle"
        echo
        echo -e "${BLUE}[0] Установить новую версию${RESET}"
        echo -e "${BLUE}[b] Назад${RESET}"
        echo
        
        local num=""
        num=$(prompt_choice "$(echo -e "${GREEN}> Выберите действие: ${RESET}")")
        
        if [ "$num" == "0" ]; then
            install_new_version_menu
        elif [ "$num" == "b" ] || [ "$num" == "B" ]; then
            return
        else
            echo "Неверная опция"
            sleep 1
        fi
        return
    fi

    for v in "${versions[@]}"; do
        local container=$(get_container_name "$v")
        local status=$(get_version_status "$container")
        local active_marker=""
        if [ "$v" == "$active_version" ]; then
            active_marker=" (активная)"
        fi

        if [ "$status" == "docker-not-running" ]; then
            status="docker не запущен"
        fi

        echo -e "${BLUE}[$i] Moodle $v - $status$active_marker${RESET}"
        ((i++))
    done

    echo
    echo -e "${BLUE}[0] Установить новую версию${RESET}"
    echo -e "${BLUE}[b] Назад${RESET}"
    echo

    local num=""
    num=$(prompt_choice "$(echo -e "${GREEN}> Выберите действие: ${RESET}")")
    
    if [ "$num" == "0" ]; then
        install_new_version_menu
        return
    fi
    if [ "$num" == "b" ] || [ "$num" == "B" ]; then
        return
    fi

    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#versions[@]}" ]; then
        echo "Неверная опция"
        sleep 1
        return
    fi

    local selected_version=${versions[$((num-1))]}
    set_active_version "$selected_version"

    echo "ОК Активная версия: $selected_version"
    sleep 1
}

function install_new_version_menu() {
    clear
    echo -e "${MAIN}BACS MultiVersion Lab - установка новой версии Moodle${RESET}"
    echo
    echo -e "${BLUE}[1] Moodle 5.0${RESET}"
    echo -e "${BLUE}[2] Moodle 4.5${RESET}"
    echo -e "${BLUE}[3] Moodle 4.4${RESET}"
    echo -e "${BLUE}[4] Moodle 4.3${RESET}"
    echo -e "${BLUE}[5] Moodle 4.2${RESET}"
    echo -e "${BLUE}[6] Moodle 4.1${RESET}"
    echo -e "${BLUE}[7] Moodle 4.0${RESET}"
    echo -e "${BLUE}[8] Moodle 3.11${RESET}"
    echo -e "${BLUE}[9] Moodle 3.10${RESET}"
    echo -e "${BLUE}[10] Moodle 3.9${RESET}"
    echo -e "${BLUE}[b] Назад${RESET}"
    echo
    
    v=""
    v=$(prompt_choice "$(echo -e "${GREEN}> Выберите версию: ${RESET}")")
    
    local version
    case "$v" in
        1) version="5.0" ;;
        2) version="4.5" ;;
        3) version="4.4" ;;
        4) version="4.3" ;;
        5) version="4.2" ;;
        6) version="4.1" ;;
        7) version="4.0" ;;
        8) version="3.11" ;;
        9) version="3.10" ;;
        10) version="3.9" ;;
        b|B) return ;;
        *) echo "Неверная опция"; sleep 1; return ;;
    esac
    
    clear
    echo -e "${MAIN}BACS MultiVersion Lab - установка Moodle $version${RESET}"
    echo
    echo "Это может занять несколько минут..."
    echo
    
    if install_moodle_version "$version"; then
        echo
        echo -e "${GREEN}Установка завершена успешно!${RESET}"
        echo "Версия Moodle $version готова к использованию."
        prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
    else
        echo
        echo -e "${YELLOW}Ошибка: установка не удалась${RESET}"
        prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
    fi
}

function env_menu() {
    clear
    local version=$(get_active_version)
    if [ -z "$version" ]; then
        echo "Активная версия не установлена"
        prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
        return
    fi

    local container=$(get_container_name "$version")
    if [ -z "$container" ]; then
        echo "Контейнер не найден для версии $version"
        prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
        return
    fi

    local status=$(get_version_status "$container")

    if [ "$status" == "docker-not-running" ]; then
        wait_for_docker
        return
    fi

    echo -e "${MAIN}BACS MultiVersion Lab - окружение${RESET}"
    echo
    echo "Активная версия: Moodle $version"
    echo "Статус: $status"
    echo

    if [ "$status" == "running" ]; then
        local c=""
        c=$(prompt_choice "$(echo -e "${GREEN}> Остановить контейнер? (Enter = да, b = назад): ${RESET}")")
        case "$c" in
            b|B) return ;;
            "") stop_env ;;
            *) echo "Неверная опция" ; sleep 1 ; return ;;
        esac
    else
        local c=""
        c=$(prompt_choice "$(echo -e "${GREEN}> Запустить контейнер? (Enter = да, b = назад): ${RESET}")")
        case "$c" in
            b|B) return ;;
            "") start_env ;;
            *) echo "Неверная опция" ; sleep 1 ; return ;;
        esac
    fi

    prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
}

function plugin_menu() {
    clear
    local version=$(get_active_version)
    echo -e "${MAIN}BACS MultiVersion Lab - жизненный цикл плагина${RESET}"
    echo
    echo "Активная версия: $version"
    echo
    echo -e "${BLUE}[1] Установить плагин${RESET}"
    echo -e "${BLUE}[2] Обновить плагин${RESET}"
    echo -e "${BLUE}[3] Удалить плагин${RESET}"
    echo -e "${BLUE}[b] Назад${RESET}"
    echo
    local c=""
    c=$(prompt_choice "$(echo -e "${GREEN}> Выберите действие: ${RESET}")")

    case $c in
        1) plugin_install_menu ;;
        2) plugin_upgrade ;;
        3) plugin_delete_confirm ;;
        b|B) return ;;
        *) echo "Неверная опция" ; sleep 1 ;;
    esac
}

function plugin_delete_confirm() {
    clear
    local version=$(get_active_version)
    echo -e "${MAIN}BACS MultiVersion Lab - удаление плагина${RESET}"
    echo
    echo -e "${GREEN}⚠ ВНИМАНИЕ!${RESET}"
    echo "Вы собираетесь удалить плагин mod_bacs из Moodle $version"
    echo "Это действие нельзя отменить."
    echo

    local confirm=""
    confirm=$(prompt_input "$(echo -e "${GREEN}> Вы уверены? (y = удалить, всё остальное = отмена): ${RESET}")")

    if [ "$confirm" == "y" ] || [ "$confirm" == "Y" ]; then
        plugin_delete
        echo "Плагин удалён успешно."
        prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
    else
        echo "Удаление отменено."
        prompt_any_key "Нажмите любую клавишу, чтобы вернуться в меню."
    fi
}

function snapshot_menu() {
    clear
    echo -e "${MAIN}BACS MultiVersion Lab - снимки состояния${RESET}"
    echo
    echo -e "${BLUE}[1] Создать снимок${RESET}"
    echo -e "${BLUE}[2] Восстановить снимок${RESET}"
    echo
    echo -e "${BLUE}[b] Назад${RESET}"
    echo

    c=""
    c=$(prompt_choice "$(echo -e "${GREEN}> Выберите действие: ${RESET}")")

    case $c in
        1) snapshot_create ;;
        2) snapshot_restore ;;
        b|B) return ;;
        *) echo "Неверная опция" ; sleep 1 ;;
    esac
}

if ! startup_check; then
    echo ""
    echo -e "${YELLOW}Среда не готова. Установите отсутствующие инструменты и запустите снова.${RESET}"
    exit 1
fi

main_menu