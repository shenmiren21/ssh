#!/bin/bash
# =======================================================================
# 一体化 Java Service 管理脚本（单文件版）
# 用法：
#   ./service.sh start|stop|restart|status|reload [-f|--foreground] [jar]
#   ./service.sh install        # 一键注册 systemd + logrotate
# =======================================================================

set -euo pipefail
. /etc/profile           &>/dev/null
. /etc/rc.d/init.d/functions
. /server/scripts/get_project_mem.sh &>/dev/null || true

# ---------------------- 0. 防止并发 ----------------------
LOCK_DIR=/var/lock
[[ -d $LOCK_DIR ]] || mkdir -p "$LOCK_DIR"
exec 200>"$LOCK_DIR/java_service_script.lock"
flock -n 200 || { echo "Another instance is running" >&2; exit 1; }

# ---------------------- 1. 参数解析 ----------------------
ACTION="${1:-}"
shift || true

# 解析 -f/--foreground
FOREGROUND=0
if [[ ${1:-} =~ ^(-f|--foreground)$ ]]; then
    FOREGROUND=1
    shift || true
fi

JAR_ARG="${1:-}"

# ---------------------- 2. 兼容旧目录 --------------------
LEGACY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEGACY_PROJECT="$(basename "$LEGACY_DIR")"
LEGACY_JAR="$LEGACY_DIR/${LEGACY_PROJECT}.jar"

if [[ -n $JAR_ARG ]]; then
    JAR_PATH="$(realpath "$JAR_ARG")"
    PROJECT_NAME="$(basename "$JAR_ARG" .jar)"
    PID_DIR="$(dirname "$JAR_PATH")/pid"
else
    JAR_PATH="$LEGACY_JAR"
    PROJECT_NAME="$LEGACY_PROJECT"
    PID_DIR="$(dirname "$LEGACY_DIR")/pid"
fi

# ---------------------- 3. 基础变量 ----------------------
JAVA_HOME=/opt/primeton/jdk1.8.0_401
JAVA="$JAVA_HOME/bin/java"
[[ -x $JAVA ]] || JAVA=$(command -v java)

mkdir -p "$PID_DIR"
PID_FILE="$PID_DIR/${PROJECT_NAME}.pid"
LOG_FILE="$(dirname "$JAR_PATH")/${PROJECT_NAME}.log"

# ---------------------- 4. JVM 参数 ----------------------
MEM="$(get_mem "$PROJECT_NAME" 2>/dev/null || true)"
[[ $MEM =~ ^[0-9]+$ ]] || MEM=512
JAVA_OPTS="-Xms${MEM}m -Xmx${MEM}m"
JAVA_OPTS+=" -XX:MetaspaceSize=128m -XX:MaxMetaspaceSize=256m"
JAVA_OPTS+=" -XX:+UnlockExperimentalVMOptions -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
JAVA_OPTS+=" -Duser.timezone=GMT+08"

# ---------------------- 5. 工具函数 ----------------------
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

rotate_log() {
    [[ -f $LOG_FILE ]] || return 0
    local size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    [[ $size -gt 104857600 ]] && mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d-%H%M%S)"
}

check_pid() {
    [[ -f $PID_FILE ]] || return 1
    local pid=$(cat "$PID_FILE")
    kill -0 "$pid" 2>/dev/null || return 1
    grep -qF -- "$JAR_PATH" "/proc/$pid/cmdline" 2>/dev/null
}

sig_caught() {
    local pid=$1 sig=$2
    local sigcgt=$(awk '/^SigCgt:/ {print $2}' "/proc/$pid/status" 2>/dev/null || return 1)
    local mask=$((16#${sigcgt##* }))
    case $sig in
        USR2) (( (mask >> 30) & 1 )) && return 0 ;;
    esac
    return 1
}

print_log_tail() { [[ -s $LOG_FILE ]] && { echo "---- recent log ----"; tail -20 "$LOG_FILE"; }; }

# ---------------------- 6. 主操作函数 --------------------
start_service() {
    check_pid && { echo "Service already running (PID $(cat "$PID_FILE"))"; return 0; }
    [[ -f $JAR_PATH ]] || { echo "Jar not found: $JAR_PATH" >&2; exit 1; }

    rotate_log
    log "Starting $PROJECT_NAME ..."

    if (( FOREGROUND )); then
        exec "$JAVA" $JAVA_OPTS -jar "$JAR_PATH"
    else
        nohup "$JAVA" $JAVA_OPTS -jar "$JAR_PATH" >> "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
        sleep 2
        if check_pid; then
            action "Service $PROJECT_NAME started (PID $(cat "$PID_FILE"))" /bin/true
        else
            action "Service $PROJECT_NAME failed to start" /bin/false
            print_log_tail
            exit 1
        fi
    fi
}

stop_service() {
    check_pid || { action "Service not running" /bin/true; rm -f "$PID_FILE"; return 0; }
    local pid=$(cat "$PID_FILE")
    log "Stopping $PROJECT_NAME (SIGTERM) PID=$pid"
    kill -TERM "$pid"
    local i=0
    while kill -0 "$pid" &>/dev/null && (( i++ < 10 )); do sleep 1; done
    if kill -0 "$pid" &>/dev/null; then
        log "Force kill (SIGKILL) PID=$pid"
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    action "Service $PROJECT_NAME stopped" /bin/true
}

status_service() {
    if check_pid; then
        echo "Service $PROJECT_NAME running (PID $(cat "$PID_FILE"))"
    else
        echo "Service $PROJECT_NAME not running"
        [[ -f $PID_FILE ]] && rm -f "$PID_FILE"
    fi
}

restart_service() { stop_service; sleep 1; start_service; }

reload_service() {
    check_pid || { echo "Service not running" >&2; return 1; }
    local pid=$(cat "$PID_FILE")
    if sig_caught "$pid" USR2; then
        log "Reloading $PROJECT_NAME (SIGUSR2) PID=$pid"
        kill -USR2 "$pid"
    else
        echo "Service does not catch SIGUSR2, reload aborted" >&2
        return 1
    fi
}

# ---------------------- 7. 安装函数 ----------------------
install_service() {
    local unit_file="/etc/systemd/system/${PROJECT_NAME}.service"
    local logrotate_file="/etc/logrotate.d/${PROJECT_NAME}"

    cat > "$unit_file" <<EOF
[Unit]
Description=Java Service - $PROJECT_NAME
After=network.target

[Service]
Type=forking
PIDFile=$PID_FILE
ExecStart=$LEGACY_DIR/service.sh start
ExecStop=$LEGACY_DIR/service.sh stop
ExecReload=$LEGACY_DIR/service.sh reload
User=$(whoami)
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > "$logrotate_file" <<EOF
$LOG_FILE {
    daily
    rotate 30
    compress
    missingok
    copytruncate
    notifempty
}
EOF

    systemctl daemon-reload
    echo "systemd unit installed: $unit_file"
    echo "logrotate config installed: $logrotate_file"
    echo "Run: systemctl enable --now $PROJECT_NAME"
}

# ---------------------- 8. 主入口 ------------------------
case "$ACTION" in
    start|stop|restart|status|reload)
        ${ACTION}_service
        ;;
    install)
        install_service
        ;;
    *)
        echo "Usage:"
        echo "  $0 {start|stop|restart|status|reload} [-f|--foreground] [jar]"
        echo "  $0 install   # 安装 systemd unit + logrotate"
        exit 1
        ;;
esac
