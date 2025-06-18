#!/usr/bin/env bash
# Work directory isolated parallel execution script

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly WORK_DIR="$(pwd)"  # current working directory
readonly INSTANCE_ID="${USER:-$(id -un)}_$(hostname)_$$_$(date +%s%N)"

# Per-work-directory paths
readonly LOCK_DIR="${WORK_DIR}/.parallel_locks"
readonly LOG_DIR="${WORK_DIR}/.parallel_logs"
readonly PID_FILE="${LOCK_DIR}/${SCRIPT_NAME}.${INSTANCE_ID}.pid"

# Global lock per working directory
readonly GLOBAL_LOCK="${LOCK_DIR}/global.lock"

# Create necessary directories in current work directory
mkdir -p "$LOCK_DIR" "$LOG_DIR"

usage() {
  cat <<USAGE
Usage: $0 [options]
  -c  CPU usage threshold percent (default 85)
  -m  memory usage threshold percent (default 80)
  -d  root directory containing a-z subdirectories (default ./)
  -i  interactive mode (Y ask each dir, A process all without asking)
  -p  maximum concurrent processes (default 200)
  -us USER  sqlplus username (default system)
  -pa PASS  sqlplus password (default manager)
  -id INSTANCE_ID  unique instance identifier (auto-generated)
  -isolation MODE  isolation mode (workdir/global) (default workdir)
  -h  show this help

Isolation modes:
  workdir - Each working directory is completely isolated
  global  - All instances share locks regardless of working directory
USAGE
}

# Default values
cpu_threshold=85
mem_threshold=80
root_dir="./"
interactive_mode="Y"
max_processes=200
sql_user="system"
sql_pass="manager"
custom_instance_id=""
isolation_mode="workdir"

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -c) cpu_threshold=$2; shift 2;;
    -m) mem_threshold=$2; shift 2;;
    -d) root_dir=$2; shift 2;;
    -i) interactive_mode=$2; shift 2;;
    -p) max_processes=$2; shift 2;;
    -us) sql_user=$2; shift 2;;
    -pa) sql_pass=$2; shift 2;;
    -id) custom_instance_id=$2; shift 2;;
    -isolation) isolation_mode=$2; shift 2;;
    -h) usage; exit 0;;
    *) usage; exit 1;;
  esac
done

# Validate isolation mode
if [ "$isolation_mode" != "workdir" ] && [ "$isolation_mode" != "global" ]; then
    echo "Error: Invalid isolation mode. Use 'workdir' or 'global'" >&2
    exit 1
fi

# Use custom instance ID if provided
if [ -n "$custom_instance_id" ]; then
    readonly FINAL_INSTANCE_ID="$custom_instance_id"
else
    readonly FINAL_INSTANCE_ID="$INSTANCE_ID"
fi

# Adjust paths based on isolation mode
if [ "$isolation_mode" = "global" ]; then
    readonly FINAL_LOCK_DIR="/tmp/.parallel_locks_global"
    readonly FINAL_LOG_DIR="${WORK_DIR}/.parallel_logs"
    readonly FINAL_GLOBAL_LOCK="/tmp/.parallel_locks_global/global.lock"
    mkdir -p "$FINAL_LOCK_DIR"
else
    readonly FINAL_LOCK_DIR="$LOCK_DIR"
    readonly FINAL_LOG_DIR="$LOG_DIR"
    readonly FINAL_GLOBAL_LOCK="$GLOBAL_LOCK"
fi

# Instance-specific files
readonly results="${FINAL_LOG_DIR}/$(date +%Y%m%d_%H%M)_${FINAL_INSTANCE_ID}.result.csv"
readonly error_log="${FINAL_LOG_DIR}/$(date +%Y%m%d_%H%M)_${FINAL_INSTANCE_ID}.error.log"
readonly progress_file="${FINAL_LOCK_DIR}/progress_${FINAL_INSTANCE_ID}"
readonly started_file="${FINAL_LOCK_DIR}/started_${FINAL_INSTANCE_ID}"
readonly error_file="${FINAL_LOCK_DIR}/errors_${FINAL_INSTANCE_ID}"
readonly final_pid_file="${FINAL_LOCK_DIR}/${SCRIPT_NAME}.${FINAL_INSTANCE_ID}.pid"

# Write PID file for instance tracking
echo $$ > "$final_pid_file"

check_running_instances() {
    local count=0
    echo "=== Running Instances ==="
    echo "Isolation mode: $isolation_mode"
    echo "Work directory: $WORK_DIR"
    echo "Lock directory: $FINAL_LOCK_DIR"
    echo "Checking pattern: ${FINAL_LOCK_DIR}/${SCRIPT_NAME}.*.pid"
    for pid_file in "${FINAL_LOCK_DIR}"/${SCRIPT_NAME}.*.pid; do
        [ -f "$pid_file" ] || continue
        local pid instance_id workdir
        pid=$(cat "$pid_file" 2>/dev/null || echo "")
        instance_id=$(basename "$pid_file" .pid | sed "s/${SCRIPT_NAME}.//")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            count=$((count + 1))
            workdir=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo "unknown")
            printf "  Instance: %s (PID: %s, WorkDir: %s)\n" "$instance_id" "$pid" "$workdir"
        else
            rm -f "$pid_file"
        fi
    done
    echo "Total active instances: $count"
    echo "========================="
    return 0
}

is_file_being_processed() {
    local file="$1"
    local abs_file_path
    abs_file_path="$(readlink -f "$file")"
    for lock_file in "${FINAL_LOCK_DIR}"/file_*.lock; do
        [ -f "$lock_file" ] || continue
        local lock_content
        lock_content="$(cat "$lock_file" 2>/dev/null || echo "")"
        if [ -n "$lock_content" ]; then
            local lock_file_path lock_pid
            lock_file_path="$(echo "$lock_content" | cut -d: -f2)"
            lock_pid="$(echo "$lock_content" | cut -d: -f3)"
            if [ "$abs_file_path" = "$lock_file_path" ]; then
                if kill -0 "$lock_pid" 2>/dev/null; then
                    return 0
                else
                    rm -f "$lock_file"
                fi
            fi
        fi
    done
    return 1
}

mark_file_processing() {
    local file="$1"
    local abs_file_path="$(readlink -f "$file")"
    local base_name="$(basename "$file")"
    local file_lock="${FINAL_LOCK_DIR}/file_${FINAL_INSTANCE_ID}_${base_name}_$$.lock"
    echo "${FINAL_INSTANCE_ID}:${abs_file_path}:$$" > "$file_lock"
}

unmark_file_processing() {
    local file="$1"
    local base_name="$(basename "$file")"
    local file_lock="${FINAL_LOCK_DIR}/file_${FINAL_INSTANCE_ID}_${base_name}_$$.lock"
    rm -f "$file_lock"
}

get_total_script_processes() {
    local total=0
    for pid_file in "${FINAL_LOCK_DIR}"/${SCRIPT_NAME}.*.pid; do
        [ -f "$pid_file" ] || continue
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            local children
            children=$(pgrep -P "$pid" 2>/dev/null | wc -l)
            total=$((total + children))
        fi
    done
    echo "$total"
}

get_workdir_script_processes() {
    local total=0
    for pid_file in "${FINAL_LOCK_DIR}"/${SCRIPT_NAME}.*.pid; do
        [ -f "$pid_file" ] || continue
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            local proc_workdir
            proc_workdir=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo "")
            if [ "$proc_workdir" = "$WORK_DIR" ]; then
                local children
                children=$(pgrep -P "$pid" 2>/dev/null | wc -l)
                total=$((total + children))
            fi
        fi
    done
    echo "$total"
}

get_cpu_usage() {
    awk '/^cpu /{idle=$5; tot=$2+$3+$4+$5+$6+$7+$8+$9+$10; print int(100 - idle*100/tot)}' /proc/stat 2>/dev/null || echo "0"
}

get_mem_usage() {
    awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{if(t>0) print int((t-a)/t*100); else print 0}' /proc/meminfo 2>/dev/null || echo "0"
}

progress_monitor() {
    echo "Starting progress monitor for instance: $FINAL_INSTANCE_ID"
    echo "Work directory: $WORK_DIR"
    echo "Isolation mode: $isolation_mode"
    local total
    total=$(find "$root_dir" -maxdepth 2 -type f \( -name '*-sh-N' -o -name '*-sql-N' \) 2>/dev/null | wc -l)
    while true; do
        sleep 10
        local completed forked errors cpu mem running workdir_procs total_procs
        completed=$(cat "$progress_file" 2>/dev/null || echo "0")
        forked=$(cat "$started_file" 2>/dev/null || echo "0")
        errors=$(cat "$error_file" 2>/dev/null || echo "0")
        cpu=$(get_cpu_usage)
        mem=$(get_mem_usage)
        running=$(jobs -r 2>/dev/null | wc -l)
        running=$(( running > 0 ? running-1 : 0 ))
        if [ "$isolation_mode" = "workdir" ]; then
            workdir_procs=$(get_workdir_script_processes)
            printf "[%s] Progress: %d/%d (%d%%) CPU:%d%% MEM:%d%% Local:%d WorkDir:%d ERR:%d\n" \
                   "$FINAL_INSTANCE_ID" "$completed" "$total" \
                   "$([ "$total" -gt 0 ] && echo $(( completed * 100 / total )) || echo "100")" \
                   "$cpu" "$mem" "$running" "$workdir_procs" "$errors"
        else
            total_procs=$(get_total_script_processes)
            printf "[%s] Progress: %d/%d (%d%%) CPU:%d%% MEM:%d%% Local:%d Global:%d ERR:%d\n" \
                   "$FINAL_INSTANCE_ID" "$completed" "$total" \
                   "$([ "$total" -gt 0 ] && echo $(( completed * 100 / total )) || echo "100")" \
                   "$cpu" "$mem" "$running" "$total_procs" "$errors"
        fi
    done
}

execute_file() {
    local f="$1"
    if is_file_being_processed "$f"; then
        echo "[skip] $f (being processed by another instance)"
        return 0
    fi
    mark_file_processing "$f"
    local start end dur status=SUCCESS new
    start=$(date +%s)
    echo "[start] $f (instance: $FINAL_INSTANCE_ID, workdir: $WORK_DIR)" | tee -a "$error_log"
    if [[ "$f" == *-sql-* ]]; then
        if ! sqlplus -S "$sql_user/$sql_pass" @"$f" 2>>"$error_log"; then
            status=FAILED
            echo "[error] SQL execution failed for $f" | tee -a "$error_log"
            local errors
            errors=$(cat "$error_file" 2>/dev/null || echo "0")
            echo $((errors + 1)) > "$error_file"
        fi
    else
        if ! bash "$f" 2>>"$error_log"; then
            status=FAILED
            echo "[error] Shell execution failed for $f" | tee -a "$error_log"
            local errors
            errors=$(cat "$error_file" 2>/dev/null || echo "0")
            echo $((errors + 1)) > "$error_file"
        fi
    fi
    end=$(date +%s)
    dur=$((end-start))
    (
        flock -x 200
        new="${f%?}Y"
        if [ -f "$f" ] && ! mv "$f" "$new" 2>>"$error_log"; then
            echo "[warning] Could not rename $f to $new" | tee -a "$error_log"
        fi
    ) 200>"$FINAL_GLOBAL_LOCK"
    echo "[done] $f (${dur}s) - $status (instance: $FINAL_INSTANCE_ID)" | tee -a "$error_log"
    (
        flock -x 200
        echo "$(dirname "$f"),$(basename "$f"),$(date -d @$start +%F\ %T),$(date -d @$end +%F\ %T),$dur,$status,$FINAL_INSTANCE_ID,$WORK_DIR" >> "$results"
        local completed
        completed=$(cat "$progress_file" 2>/dev/null || echo "0")
        echo $((completed + 1)) > "$progress_file"
    ) 200>>"${results}.lock"
    unmark_file_processing "$f"
}

cleanup() {
    echo "Cleaning up instance: $FINAL_INSTANCE_ID (workdir: $WORK_DIR)"
    if [ -n "${mon_pid:-}" ]; then
        kill "$mon_pid" 2>/dev/null || true
    fi
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    rm -f "$progress_file" "$started_file" "$error_file" "${results}.lock"
    rm -f "${FINAL_LOCK_DIR}"/file_${FINAL_INSTANCE_ID}_*.lock
    rm -f "$final_pid_file"
    if [ -f "$results" ]; then
        local total_completed total_errors
        total_completed=$(wc -l < "$results" 2>/dev/null || echo "1")
        total_completed=$((total_completed - 1))
        if ! total_errors=$(grep -c "FAILED" "$results" 2>/dev/null); then
            total_errors=0
        fi
        printf '\n=== INSTANCE %s SUMMARY ===\n' "$FINAL_INSTANCE_ID"
        printf 'Work directory: %s\n' "$WORK_DIR"
        printf 'Isolation mode: %s\n' "$isolation_mode"
        printf 'Total completed: %d\n' "$total_completed"
        printf 'Total errors: %d\n' "$total_errors"
        printf 'Results: %s\n' "$results"
        printf 'Error log: %s\n' "$error_log"
    fi
}

validate_inputs() {
    if [[ ! "$cpu_threshold" =~ ^[0-9]+$ ]] || [ "$cpu_threshold" -lt 1 ] || [ "$cpu_threshold" -gt 100 ]; then
        echo "Error: CPU limit must be 1-100" >&2
        exit 1
    fi
    if [[ ! "$mem_threshold" =~ ^[0-9]+$ ]] || [ "$mem_threshold" -lt 1 ] || [ "$mem_threshold" -gt 100 ]; then
        echo "Error: Memory limit must be 1-100" >&2
        exit 1
    fi
    if [ ! -d "$root_dir" ]; then
        echo "Error: Directory '$root_dir' does not exist" >&2
        exit 1
    fi
    if [[ ! "$max_processes" =~ ^[0-9]+$ ]] || [ "$max_processes" -lt 1 ]; then
        echo "Error: Max processes must be a positive integer" >&2
        exit 1
    fi
}

get_password() {
    if [ -n "$sql_pass" ]; then
        return
    fi
    if [ -n "${SQL_PASSWORD:-}" ]; then
        sql_pass="$SQL_PASSWORD"
    elif [ -f "${HOME}/.sqlpass" ]; then
        sql_pass="$(cat "${HOME}/.sqlpass")"
    else
        echo -n "Enter SQL password for user '$sql_user': "
        read -s sql_pass
        echo
    fi
    if [ -z "$sql_pass" ]; then
        echo "Error: Password cannot be empty" >&2
        exit 1
    fi
}

validate_inputs
get_password

echo "0" > "$progress_file"
echo "0" > "$started_file"
echo "0" > "$error_file"
echo "directory,file,start,end,duration,status,instance,workdir" > "$results"

if [ ! -t 0 ] && [ "$interactive_mode" = "Y" ]; then
    interactive_mode="A"
fi

trap cleanup EXIT INT TERM

check_running_instances

progress_monitor &
mon_pid=$!

for dir in $(find "$root_dir" -maxdepth 1 -type d -regex '.*/[a-z]' | sort); do
    if [ "$interactive_mode" = "Y" ]; then
        read -p "Process directory $(basename "$dir")? [Y/N/A] " ans
        case $ans in
            Y|y) ;;
            N|n) continue ;;
            A|a) interactive_mode="A" ;;
            *) continue ;;
        esac
    fi
    while IFS= read -r -d '' f; do
        [[ "$f" == *-Y ]] && continue
        if is_file_being_processed "$f"; then
            echo "[skip] $(basename "$f") (locked by another instance)"
            continue
        fi
        while true; do
            cpu=$(get_cpu_usage)
            mem=$(get_mem_usage)
            running=$(jobs -r 2>/dev/null | wc -l)
            running=$(( running > 0 ? running-1 : 0 ))
            if [ "$isolation_mode" = "workdir" ]; then
                limit_procs=$(get_workdir_script_processes)
            else
                limit_procs=$(get_total_script_processes)
            fi
            if [ "$cpu" -lt "$cpu_threshold" ] && \
               [ "$mem" -lt "$mem_threshold" ] && \
               [ "$running" -lt "$max_processes" ] && \
               [ "$limit_procs" -lt $((max_processes * 2)) ]; then
                break
            fi
            sleep 1
        done
        started=$(cat "$started_file" 2>/dev/null || echo "0")
        echo $((started + 1)) > "$started_file"
        execute_file "$f" &
    done < <(find "$dir" -maxdepth 1 -type f \( -name '*-sh-*' -o -name '*-sql-*' \) -print0 2>/dev/null | sort -z)
    wait
done

wait
echo "Instance $FINAL_INSTANCE_ID completed (workdir: $WORK_DIR)."
