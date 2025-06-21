#!/usr/bin/env bash
# Work directory isolated parallel execution script. Each job runs in its own
# forked process so the script never relies on threads.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly WORK_DIR="$(pwd)"  # current working directory
readonly INSTANCE_ID="${USER:-$(id -un)}_$(hostname)_$$_$(date +%s%N)"

# Per-work-directory paths
readonly LOCK_DIR="${WORK_DIR}/.parallel_locks"
readonly LOG_DIR="${WORK_DIR}/.parallel_logs"

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
  -op NUM  processes launched per batch before checking limits (default 1)
  -us USER  sqlplus username (default system)
  -pa PASS  sqlplus password (default manager)
  -h  show this help
USAGE
}

# Default values
cpu_threshold=85
mem_threshold=80
root_dir="./"
interactive_mode="Y"
max_processes=200
open_batch=1
sql_user="system"
sql_pass="manager"

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -c) cpu_threshold=$2; shift 2;;
    -m) mem_threshold=$2; shift 2;;
    -d) root_dir=$2; shift 2;;
    -i) interactive_mode=$2; shift 2;;
    -p) max_processes=$2; shift 2;;
    -op) open_batch=$2; shift 2;;
    -us) sql_user=$2; shift 2;;
    -pa) sql_pass=$2; shift 2;;
    -h) usage; exit 0;;
    *) usage; exit 1;;
  esac
done

# Unique instance identifier for log files
readonly FINAL_INSTANCE_ID="$INSTANCE_ID"

# Paths scoped to the current working directory
readonly FINAL_LOCK_DIR="$LOCK_DIR"
readonly FINAL_LOG_DIR="$LOG_DIR"
readonly FINAL_GLOBAL_LOCK="$GLOBAL_LOCK"

# Instance-specific files
readonly results="${FINAL_LOG_DIR}/$(date +%Y%m%d_%H%M)_${FINAL_INSTANCE_ID}.result.csv"
readonly error_log="${FINAL_LOG_DIR}/$(date +%Y%m%d_%H%M)_${FINAL_INSTANCE_ID}.error.log"
readonly progress_file="${FINAL_LOCK_DIR}/progress_${FINAL_INSTANCE_ID}"
readonly started_file="${FINAL_LOCK_DIR}/started_${FINAL_INSTANCE_ID}"
readonly error_file="${FINAL_LOCK_DIR}/errors_${FINAL_INSTANCE_ID}"
readonly final_pid_file="${FINAL_LOCK_DIR}/${SCRIPT_NAME}.${FINAL_INSTANCE_ID}.pid"
readonly current_dir_file="${FINAL_LOCK_DIR}/currentdir_${FINAL_INSTANCE_ID}"

# Write PID file for instance tracking
echo $$ > "$final_pid_file"

check_running_instances() {
    local count=0
    echo "=== Running Instances ==="
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
    top -bn1 2>/dev/null \
        | awk '/^%?Cpu/ {for(i=1;i<=NF;i++) if($i ~ /id/) {idle=$(i-1); gsub(/,/, "", idle); usage=100-idle; if(usage<0) usage=0; printf "%.1f", usage; exit}}' \
        || echo "0.0"
}

get_mem_usage() {
    # Calculate memory usage excluding file cache (buffers, cached pages, reclaimable)
    awk '/MemTotal/{t=$2}/MemFree/{f=$2}/Buffers/{b=$2}/^Cached/{c=$2}/SReclaimable/{s=$2} END{used=t-f-b-c-s; if(t>0) print int(used*100/t); else print 0}' /proc/meminfo 2>/dev/null || echo "0"
}

count_errors() {
    grep -iE 'error|fatal|ORA-' "$error_log" 2>/dev/null | wc -l
}

progress_monitor() {
    local total width
    total=$(find "$root_dir" -maxdepth 2 -type f \( -name '*-N-*.sh' -o -name '*-N-*.sql' \) 2>/dev/null | wc -l)
    width=${#total}
    while true; do
        sleep 10
        local completed started errors cpu mem running current_dir
        completed=$(cat "$progress_file" 2>/dev/null || echo "0")
        started=$(cat "$started_file" 2>/dev/null || echo "0")
        cpu=$(get_cpu_usage)
        mem=$(get_mem_usage)
        running=$(( started - completed ))
        if [ "$running" -lt 0 ]; then
            running=0
        fi
        current_dir=$(cat "$current_dir_file" 2>/dev/null || echo "-")
        errors=$(count_errors)
        printf "Progress: %0*d/%d (%d%%) CPU:%s%% MEM:%d%% Running:%d/%d WorkDir:%s ERR:%d\n" \
               "$width" "$completed" "$total" \
               "$([ "$total" -gt 0 ] && echo $(( completed * 100 / total )) || echo "100")" \
               "$cpu" "$mem" "$running" "$max_processes" "$current_dir" "$errors"
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
    echo "[start] $f (instance: $FINAL_INSTANCE_ID, workdir: $WORK_DIR)" >> "$error_log"
    local abs_file tmp_out
    abs_file="$(readlink -f "$f")"
    tmp_out=$(mktemp)
    if [[ "$f" == *.sql ]]; then
        sqlplus -S "$sql_user/$sql_pass" @"$abs_file" >"$tmp_out" 2>&1 || status=FAILED
    else
        sh "$abs_file" >"$tmp_out" 2>&1 || status=FAILED
    fi
    if grep -iE 'error|fatal|ORA-' "$tmp_out" >>"$error_log"; then
        status=FAILED
        local errors
        errors=$(cat "$error_file" 2>/dev/null || echo "0")
        echo $((errors + 1)) > "$error_file"
    fi
    rm -f "$tmp_out"
    end=$(date +%s)
    dur=$((end-start))
    (
        flock -x 200
        local dir base new
        dir=$(dirname "$abs_file")
        base=$(basename "$abs_file")
        new="${dir}/${base/-N-/-Y-}"
        if [ -f "$abs_file" ] && ! mv "$abs_file" "$new" 2>>"$error_log"; then
            echo "[warning] Could not rename $abs_file to $new" | tee -a "$error_log"
        fi
    ) 200>"$FINAL_GLOBAL_LOCK"
    echo "[done] $f (${dur}s) - $status (instance: $FINAL_INSTANCE_ID)" >> "$error_log"
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
    rm -f "$progress_file" "$started_file" "$error_file" "${results}.lock" "$current_dir_file"
    rm -f "${FINAL_LOCK_DIR}"/file_${FINAL_INSTANCE_ID}_*.lock
    rm -f "$final_pid_file"
    if [ -f "$results" ]; then
        local total_completed total_errors
        total_completed=$(wc -l < "$results" 2>/dev/null || echo "1")
        total_completed=$((total_completed - 1))
        if ! total_errors=$(grep -iE 'error|fatal|ORA-' "$error_log" 2>/dev/null | wc -l); then
            total_errors=0
        fi
        printf '\n=== INSTANCE %s SUMMARY ===\n' "$FINAL_INSTANCE_ID"
        printf 'Work directory: %s\n' "$WORK_DIR"
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
    if [[ ! "$open_batch" =~ ^[0-9]+$ ]] || [ "$open_batch" -lt 1 ]; then
        echo "Error: Batch size must be a positive integer" >&2
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
echo "" > "$current_dir_file"

if [ ! -t 0 ] && [ "$interactive_mode" = "Y" ]; then
    interactive_mode="A"
fi

trap cleanup EXIT INT TERM

check_running_instances

progress_monitor &
mon_pid=$!

wait_for_jobs() {
    for job in $(jobs -p); do
        [ "$job" != "$mon_pid" ] && wait "$job"
    done
}

for dir in $(find "$root_dir" -maxdepth 1 -type d -regex '.*/[a-z]' | sort); do
    echo "$(basename "$dir")" > "$current_dir_file"
    if [ "$interactive_mode" = "Y" ]; then
        read -p "Process directory $(basename "$dir")? [Y/N/A] " ans
        case $ans in
            Y|y) ;;
            N|n) continue ;;
            A|a) interactive_mode="A" ;;
            *) continue ;;
        esac
    fi
    mapfile -d '' files < <(find "$dir" -maxdepth 1 -type f \( -name '*-N-*.sh' -o -name '*-N-*.sql' -o -name '*-Y-*.sh' -o -name '*-Y-*.sql' \) -print0 2>/dev/null | sort -z)
    idx=0
    while [ $idx -lt ${#files[@]} ]; do
        while true; do
            cpu=$(get_cpu_usage)
            cpu_int=$(printf '%.0f' "$cpu")
            mem=$(get_mem_usage)
            running=$(jobs -r 2>/dev/null | wc -l)
            running=$(( running > 0 ? running-1 : 0 ))
            limit_procs=$(get_workdir_script_processes)
            if { [ "$cpu_int" -lt "$cpu_threshold" ] || \
                 [ "$mem" -lt "$mem_threshold" ] || \
                 [ "$running" -lt "$max_processes" ]; } && \
               [ "$limit_procs" -lt $((max_processes * 2)) ]; then
                break
            fi
            sleep 1
        done

        batch=0
        while [ $batch -lt "$open_batch" ] && [ $idx -lt ${#files[@]} ]; do
            f="${files[idx]}"
            idx=$((idx + 1))
            [[ $(basename "$f") == *-Y-* ]] && continue
            if is_file_being_processed "$f"; then
                echo "[skip] $(basename "$f") (locked by another instance)"
                continue
            fi
            started=$(cat "$started_file" 2>/dev/null || echo "0")
            echo $((started + 1)) > "$started_file"
            execute_file "$f" &
            batch=$((batch + 1))
        done
    done

    wait_for_jobs
    echo "" > "$current_dir_file"
done

wait_for_jobs
echo "Instance $FINAL_INSTANCE_ID completed (workdir: $WORK_DIR)."
