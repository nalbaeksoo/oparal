#!/usr/bin/env bash
# Work directory isolated parallel execution script

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly WORK_DIR="$(pwd)"  # current working directory
readonly MAIN_PID=$$
readonly INSTANCE_ID="${USER:-$(id -un)}_$(hostname)_${MAIN_PID}_$(date +%s%N)"

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
  -op N  number of slave processes to run in parallel (alias for -p)
  -us USER  sqlplus username (default system)
  -pa PASS  sqlplus password (default manager)
  -id INSTANCE_ID  unique instance identifier (auto-generated)
  -hist FILE  results CSV to use for task ordering
  -h  show this help
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
history_csv=""

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -c) cpu_threshold=$2; shift 2;;
    -m) mem_threshold=$2; shift 2;;
    -d) root_dir=$2; shift 2;;
    -i) interactive_mode=$2; shift 2;;
    -p) max_processes=$2; shift 2;;
    -op) max_processes=$2; shift 2;;
    -us) sql_user=$2; shift 2;;
    -pa) sql_pass=$2; shift 2;;
    -id) custom_instance_id=$2; shift 2;;
    -hist) history_csv=$2; shift 2;;
    -h) usage; exit 0;;
    *) usage; exit 1;;
  esac
done


# Use custom instance ID if provided
if [ -n "$custom_instance_id" ]; then
    readonly FINAL_INSTANCE_ID="$custom_instance_id"
else
    readonly FINAL_INSTANCE_ID="$INSTANCE_ID"
fi

# Paths for this working directory
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
readonly total_file="${FINAL_LOCK_DIR}/total_${FINAL_INSTANCE_ID}"

# Previous run durations mapping
declare -A PREV_DURATION=()
result_files=()
while IFS= read -r f; do
  result_files+=("$f")
done < <(ls -1 ${FINAL_LOG_DIR}/*.result.csv 2>/dev/null || true)

best_results=""
best_total=""
for f in "${result_files[@]}"; do
  total=$(awk -F, 'NR>1{sum+=$5} END{print sum+0}' "$f" 2>/dev/null)
  if [ -z "$best_total" ] || [ "$total" -lt "$best_total" ]; then
    best_total="$total"
    best_results="$f"
  fi
done

latest_results="$(ls -1t ${FINAL_LOG_DIR}/*.result.csv 2>/dev/null | head -n 1 || true)"
selected_results=""
if [ -n "$history_csv" ]; then
  selected_results="$history_csv"
else
  selected_results="$latest_results"
fi

# Write PID file for instance tracking
echo "$MAIN_PID" > "$final_pid_file"

if [ -n "$selected_results" ] && [ -f "$selected_results" ]; then
    while IFS=',' read -r d f s e dur rest; do
        [ "$d" = "directory" ] && continue
        abs="$(readlink -f "$d/$f" 2>/dev/null || echo '')"
        [ -n "$abs" ] && PREV_DURATION["$abs"]="$dur"
    done < "$selected_results"
fi

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

get_instance_processes() {
  local cnt
  cnt=$(jobs -rp | wc -l)
  if [ -n "${mon_pid:-}" ]; then
    cnt=$((cnt > 0 ? cnt-1 : 0))
  fi
  echo "$cnt"
}

get_cpu_usage() {
  local l1 l2 idle1 idle2 total1 total2 diff_idle diff_total
  read -r l1 < /proc/stat || { echo 0; return; }
  sleep 0.1
  read -r l2 < /proc/stat || { echo 0; return; }
  idle1=$(awk '{print $5}' <<< "$l1")
  idle2=$(awk '{print $5}' <<< "$l2")
  total1=$(awk '{for(i=2;i<=NF;i++) s+=$i; print s}' <<< "$l1")
  total2=$(awk '{for(i=2;i<=NF;i++) s+=$i; print s}' <<< "$l2")
  diff_idle=$((idle2-idle1))
  diff_total=$((total2-total1))
  [ "$diff_total" -le 0 ] && diff_total=1
  local pct
  pct=$(awk -v i=$diff_idle -v t=$diff_total 'BEGIN{printf "%.2f", (1 - i/t)*100}')
  if [ "$pct" = "0.00" ]; then
    echo "0.1"
  else
    awk -v p="$pct" 'BEGIN{printf "%.1f", p}'
  fi
}

get_mem_usage() {
    awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{if(t>0) print int((t-a)/t*100); else print 0}' /proc/meminfo 2>/dev/null || echo "0"
}

progress_monitor() {
    echo "Starting progress monitor for instance: $FINAL_INSTANCE_ID"
    echo "Work directory: $WORK_DIR"
    while true; do
        sleep 10
        local total completed forked errors cpu mem running workdir_procs
        total=$(cat "$total_file" 2>/dev/null || echo "0")
        completed=$(cat "$progress_file" 2>/dev/null || echo "0")
        forked=$(cat "$started_file" 2>/dev/null || echo "0")
        errors=$(cat "$error_file" 2>/dev/null || echo "0")
        cpu=$(get_cpu_usage)
        mem=$(get_mem_usage)
        running=$(get_instance_processes)
        workdir_procs=$(get_workdir_script_processes)
        printf "[%s] Progress: %d/%d (%d%%) CPU:%.1f%% MEM:%d%% Local:%d WorkDir:%d ERR:%d\n" \
               "$FINAL_INSTANCE_ID" "$completed" "$total" \
               "$([ "$total" -gt 0 ] && echo $(( completed * 100 / total )) || echo "100")" \
               "$cpu" "$mem" "$running" "$workdir_procs" "$errors"
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
    if [[ "$f" == *-sql-* ]]; then
        if ! sqlplus -S "$sql_user/$sql_pass" < "$f" > /dev/null 2>>"$error_log"; then
            status=FAILED
            echo "[error] SQL execution failed for $f" >> "$error_log"
            local errors
            errors=$(cat "$error_file" 2>/dev/null || echo "0")
            echo $((errors + 1)) > "$error_file"
        fi
    else
        if ! sh "$f" 2>>"$error_log"; then
            status=FAILED
            echo "[error] Shell execution failed for $f" >> "$error_log"
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
            echo "[warning] Could not rename $f to $new" >> "$error_log"
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
        pkill -P "$mon_pid" 2>/dev/null || true
        sleep 1
        kill -9 "$mon_pid" 2>/dev/null || true
        pkill -9 -P "$mon_pid" 2>/dev/null || true
    fi

    local pid
    for pid in $(jobs -p); do
        kill "$pid" 2>/dev/null || true
        pkill -P "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in $(jobs -p); do
        kill -9 "$pid" 2>/dev/null || true
        pkill -9 -P "$pid" 2>/dev/null || true
    done

    pkill -9 -P $$ 2>/dev/null || true
    wait 2>/dev/null || true

    rm -f "$progress_file" "$started_file" "$error_file" "$total_file" "${results}.lock"
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
echo "0" > "$total_file"
echo "directory,file,start,end,duration,status,instance,workdir" > "$results"

if [ ! -t 0 ] && [ "$interactive_mode" = "Y" ]; then
    interactive_mode="A"
fi

trap cleanup EXIT INT TERM

check_running_instances

# Gather task list
# Prepare dynamic task counter
echo "0" > "$total_file"

if [ ${#result_files[@]} -gt 0 ]; then
  echo "Available result files:"
  for rf in "${result_files[@]}"; do
    t=$(awk -F, 'NR>1{sum+=$5} END{print sum+0}' "$rf" 2>/dev/null)
    printf "  %s total:%ss\n" "$(basename "$rf")" "$t"
  done
  if [ -n "$best_results" ]; then
    echo "Best total duration: ${best_total:-0}s from $(basename "$best_results")"
  fi
  if [ -n "$selected_results" ]; then
    echo "Selected results file: $(basename "$selected_results")"
  fi
fi

progress_monitor &
mon_pid=$!

use_history="n"
if [ -n "$selected_results" ] && [ -t 0 ] && [ ${#PREV_DURATION[@]} -gt 0 ]; then
    read -p "Reorder tasks based on durations from $(basename "$selected_results")? [y/N] " ans
    case $ans in
        Y|y) use_history="y" ;;
    esac
fi

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

    DIR_TASKS=()
    while IFS= read -r -d '' f; do
        [[ "$f" == *-Y ]] && continue
        DIR_TASKS+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f \( -name '*-sh-*' -o -name '*-sql-*' \) -print0 2>/dev/null | sort -z)

    if [ ${#DIR_TASKS[@]} -eq 0 ]; then
        continue
    fi

    curr_total=$(cat "$total_file" 2>/dev/null || echo "0")
    echo $((curr_total + ${#DIR_TASKS[@]})) > "$total_file"

    if [ "$use_history" = "y" ]; then
        mapfile -t DIR_TASKS < <(
            for f in "${DIR_TASKS[@]}"; do
                abs="$(readlink -f "$f")"
                dur="${PREV_DURATION[$abs]:-0}"
                printf '%010d:%s\n' "$dur" "$f"
            done | sort -t: -k1,1nr | cut -d: -f2-
        )
    fi

    for f in "${DIR_TASKS[@]}"; do
        if is_file_being_processed "$f"; then
            echo "[skip] $(basename "$f") (locked by another instance)"
            continue
        fi
        while true; do
            cpu=$(get_cpu_usage)
            cpu_int=${cpu%.*}
            mem=$(get_mem_usage)
            running=$(get_instance_processes)
            limit_procs=$(get_workdir_script_processes)
            if [ "$cpu_int" -lt "$cpu_threshold" ] && \
               [ "$mem" -lt "$mem_threshold" ] && \
               [ "$running" -lt "$max_processes" ] && \
               [ "$limit_procs" -le $((max_processes * 2)) ]; then
                break
            fi
            sleep 1
        done
        started=$(cat "$started_file" 2>/dev/null || echo "0")
        echo $((started + 1)) > "$started_file"
        execute_file "$f" &
        sleep 0.5
    done
    wait
done

echo "Instance $FINAL_INSTANCE_ID completed (workdir: $WORK_DIR)."
