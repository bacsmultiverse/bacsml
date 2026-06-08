#!/bin/bash

# Wrapper for test-version setup/cleanup after moving helper scripts into core
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -f "$SCRIPT_DIR/bml_core.sh" ]; then
    echo "[ERROR] Не найден bml_core.sh в $SCRIPT_DIR"
    exit 1
fi

source "$SCRIPT_DIR/bml_core.sh"

if [ "$1" == "--auto" ] || [ "$1" == "-a" ]; then
    setup_all_versions
    exit $?
elif [ "$1" == "--list" ] || [ "$1" == "-l" ]; then
    list_installed_versions
    exit 0
elif [ "$1" == "--cleanup" ] || [ "$1" == "-c" ]; then
    cleanup_versions
    exit 0
else
    main_menu
fi
