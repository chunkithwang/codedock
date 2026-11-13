#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="codedock"
BUNDLE_ID="com.codedock.app"
LOG_PREDICATE="process == \"$APP_NAME\""
TELEMETRY_PREDICATE="subsystem BEGINSWITH \"com.codedock\" OR subsystem == \"$BUNDLE_ID\""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

usage() {
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

wait_for_pid() {
    local attempt
    local pid
    for attempt in {1..40}; do
        pid="$(pgrep -x "$APP_NAME" | head -n 1 || true)"
        if [ -n "$pid" ]; then
            echo "$pid"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

stop_existing_app() {
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true

    local attempt
    for attempt in {1..20}; do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done

    echo "codedock did not exit cleanly before rebuild." >&2
    return 1
}

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
        ;;
    *)
        usage
        exit 2
        ;;
esac

stop_existing_app
cd "$ROOT_DIR"
./build.sh

if [ ! -x "$APP_BINARY" ]; then
    echo "Built app is missing its executable: $APP_BINARY" >&2
    exit 1
fi

case "$MODE" in
    run)
        open_app
        echo "Launched: $APP_BUNDLE"
        ;;
    --debug|debug)
        open_app
        if pid="$(wait_for_pid)"; then
            lldb -p "$pid"
        else
            echo "codedock did not stay running after launch." >&2
            exit 1
        fi
        ;;
    --logs|logs)
        open_app
        if ! pid="$(wait_for_pid)"; then
            echo "codedock did not stay running after launch." >&2
            exit 1
        fi
        echo "codedock is running (PID $pid). Streaming logs..."
        /usr/bin/log stream --info --style compact --predicate "$LOG_PREDICATE"
        ;;
    --telemetry|telemetry)
        open_app
        if ! pid="$(wait_for_pid)"; then
            echo "codedock did not stay running after launch." >&2
            exit 1
        fi
        echo "codedock is running (PID $pid). Streaming telemetry..."
        /usr/bin/log stream --info --style compact --predicate "$TELEMETRY_PREDICATE"
        ;;
    --verify|verify)
        open_app
        if pid="$(wait_for_pid)"; then
            echo "Verified: codedock is running (PID $pid)."
        else
            echo "codedock did not stay running after launch." >&2
            exit 1
        fi
        ;;
esac
