#!/bin/bash
# ==========================================
# Java Service Manager Script
# 用法1（兼容）：./service.sh start|stop|restart|status|reload
# 用法2（传参）：./service.sh start|stop|restart|status|reload  <jar路径>
# ==========================================

set -euo pipefail
. /etc/profile           &>/dev/null
. /etc/rc.d/init.d/functions
. /server/scripts/get_project_mem.sh &>/dev/null

# --------- 1. 入参解析 ---------
# 第1个参数一定是动作
ACTION="${1:-}"
shift || true

# 第2个参数可选：jar 包路径（相对/绝对均可）
JAR_ARG="${1:-}"   # 若为空则走“老逻辑”

# 老模式：脚本目录名即项目名
LEGACY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEGACY_PROJECT="$(basename "$LEGACY_DIR")"
LEGACY_JAR="$LEGACY_DIR/${LEGACY_PROJECT}.jar"

# 根据是否传 jar 决定最终变量
if [[ -n $JAR_ARG ]]; then
    JAR_PATH="$(realpath "$JAR_ARG")"   # 绝对路径
    PROJECT_NAME="$(basename "$JAR_ARG" .jar)"  # 去掉 .jar 后缀
    PID_DIR="$(dirname "$JAR_PATH")/pid"
else
    JAR_PATH="$LEGACY_JAR"
    PROJECT_NAME="$LEGACY_PROJECT"
    PID_DIR="$(dirname "$LEGACY_DIR")/pid"
fi

# --------- 2. 基础变量 ---------
JAVA_HOME=/opt/primeton/jdk1.8.0_401
JAVA="$JAVA_HOME/bin/java"

mkdir -p "$PID_DIR"
PID_FILE="$PID_DIR/${PROJECT_NAME}.pid"
LOG_FILE="$(dirname "$JAR_PATH")/${PROJECT_NAME}.log"

# --------- 3. 内存参数 ---------
MEM="$(get_mem "$PROJECT_NAME" 2>/dev/null || true)"
[[ $MEM =~ ^[0-9]+$ ]] || MEM=512

JAVA_OPTS="-Xms${MEM}m -Xmx${MEM}m"
JAVA_OPTS+=" -XX:MetaspaceSize=128m -XX:MaxMetaspaceSize=256m"
JAVA_OPTS+=" -XX:+UnlockExperimentalVMOptions -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
JAVA_OPTS+=" -Duser.timezone=GMT+08"

# --------- 4. 通用函数 ---------
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

rotate_log() {
    [[ -f $LOG_FILE ]] || return 0
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    [[ $size -gt 104857600 ]] && mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d-%H%M%S)"
}

check_pid() {
    [[ -f $PID_FILE ]] || return 1
    local pid
    pid=$(cat "$PID_FILE")
    kill -0 "$pid" 2>/dev/null || return 1
    grep -qF "$JAR_PATH" "/proc/$pid/cmdline" 2>/dev/null
}

# --------- 5. 主操作函数 ---------
start_service() {
    if check_pid; then
        echo "Service already running with PID $(cat "$PID_FILE")"
        return 0
    fi

    [[ -f $JAR_PATH ]] || { echo "Jar file not found: $JAR_PATH" ; exit 1; }

    rotate_log
    log "Starting $PROJECT_NAME ..."
    nohup "$JAVA" $JAVA_OPTS -jar "$JAR_PATH" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    if check_pid; then
        action "Service $PROJECT_NAME started with PID $(cat "$PID_FILE")" /bin/true
    else
        action "Service $PROJECT_NAME failed to start" /bin/false
    fi
}

stop_service() {
    if ! check_pid; then
        action "Service $PROJECT_NAME not running" /bin/true
        rm -f "$PID_FILE"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    log "Stopping $PROJECT_NAME (SIGTERM) PID=$pid ..."
    kill -TERM "$pid"

    local i=0
    while kill -0 "$pid" &>/dev/null && (( i++ < 10 )); do sleep 1; done

    if kill -0 "$pid" &>/dev/null; then
        log "Force kill (SIGKILL) PID=$pid ..."
        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    action "Service $PROJECT_NAME stopped" /bin/true
}

status_service() {
    if check_pid; then
        echo "Service $PROJECT_NAME running with PID $(cat "$PID_FILE")"
    else
        echo "Service $PROJECT_NAME not running"
        [[ -f $PID_FILE ]] && rm -f "$PID_FILE"
    fi
}

restart_service() {
    stop_service
    sleep 1
    start_service
}

reload_service() {
    if check_pid; then
        local pid
        pid=$(cat "$PID_FILE")
        log "Reloading $PROJECT_NAME (SIGUSR2) PID=$pid"
        kill -USR2 "$pid"
    else
        echo "Service $PROJECT_NAME not running, nothing to reload"
    fi
}

# --------- 6. 命令入口 ---------
case "$ACTION" in
    start|stop|restart|reload|status)
        ${ACTION}_service
        ;;
    *)
        echo "Usage:"
        echo "  $0 {start|stop|restart|status|reload}"
        echo "  $0 {start|stop|restart|status|reload} <jar路径>"
        exit 1
        ;;
esac