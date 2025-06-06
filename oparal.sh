#!/usr/bin/env bash
# Execute shell and SQL files in alphabetical directories with simple CPU/memory
# based parallelism. Only bash and awk are used.

usage() {
  cat <<USAGE
Usage: $0 [-c CPU] [-m MEM] [-d DIR] [-i MODE] [-p MAX] [-h]
  -c  CPU usage threshold percent (default 85)
  -m  memory usage threshold percent (default 80)
  -d  root directory containing a-z subdirectories (default ./)
  -i  interactive mode (Y ask each dir, A process all without asking)
  -p  maximum concurrent processes (default 200)
  -h  show this help
USAGE
}

cpu_limit=85
mem_limit=80
root="./"
interactive="Y"
max_proc=200

while getopts "c:m:d:i:p:h" opt; do
  case $opt in
    c) cpu_limit=$OPTARG ;;
    m) mem_limit=$OPTARG ;;
    d) root=$OPTARG ;;
    i) interactive=$OPTARG ;;
    p) max_proc=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND-1))

# internal counters
completed=0
progress_file=$(mktemp)
results="$(date +%Y%m%d_%H%M).result.csv"

echo "0" > "$progress_file"
echo "directory,file,start,end,duration" > "$results"

init_cpu_stats() {
  read _ user nice sys idle rest < /proc/stat
  prev_total=$((user+nice+sys+idle))
  prev_idle=$idle
}

get_cpu_usage() {
  read _ user nice sys idle rest < /proc/stat
  total=$((user+nice+sys+idle))
  diff_total=$((total-prev_total))
  diff_idle=$((idle-prev_idle))
  [ $diff_total -gt 0 ] || diff_total=1
  usage=$(( (1000*(diff_total-diff_idle)/diff_total +5)/10 ))
  prev_total=$total
  prev_idle=$idle
  echo $usage
}

get_mem_usage() {
  awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print int((t-a)/t*100)}' /proc/meminfo
}

get_disk_usage() {
  df -P "$root" | awk 'NR==2{print $5}'
}

get_net_stats() {
  awk 'NR>2{rx+=$2;tx+=$10}END{print rx,tx}' /proc/net/dev
}

progress_monitor() {
  init_cpu_stats
  read rx0 tx0 < <(get_net_stats)
  total=$(find "$root" -maxdepth 2 -type f \( -name '*-sh-*' -o -name '*-sql-*' \) | wc -l)
  while true; do
    sleep 10
    completed=$(cat "$progress_file")
    cpu=$(get_cpu_usage)
    mem=$(get_mem_usage)
    disk=$(get_disk_usage)
    running=$(jobs -r | wc -l)
    read rx1 tx1 < <(get_net_stats)
    rx=$((rx1-rx0))
    tx=$((tx1-tx0))
    rx0=$rx1; tx0=$tx1
    progress=$(( completed * 100 / total ))
    echo "Progress: $completed/$total (${progress}%) CPU:${cpu}% MEM:${mem}% DISK:${disk} NET:${rx}/${tx} RUN:${running}"
  done
}

execute_file() {
  f="$1"
  start=$(date +%s)
  echo "[start] $f"
  if [[ "$f" == *.sql-* ]]; then
    bash "$f" # placeholder for SQL execution
  else
    bash "$f"
  fi
  end=$(date +%s)
  dur=$((end-start))
  new="${f%?}Y"
  mv "$f" "$new"
  echo "[done] $f (${dur}s)"
  echo "$(dirname "$f"),$(basename "$f"),$(date -d @$start +%F\ %T),$(date -d @$end +%F\ %T),$dur" >> "$results"
  completed=$((completed+1))
  echo "$completed" > "$progress_file"
}

progress_monitor &
mon_pid=$!

cleanup() {
  kill $mon_pid 2>/dev/null
  kill $(jobs -p) 2>/dev/null
  wait $mon_pid 2>/dev/null
  rm -f "$progress_file"
}

trap cleanup EXIT INT TERM

for dir in $(find "$root" -maxdepth 1 -type d -regex '.*/[a-z]' | sort); do
  if [ "$interactive" = "Y" ]; then
    read -p "Process directory $(basename "$dir")? [Y/N/A] " ans
    case $ans in
      Y|y) ;;
      N|n) continue ;;
      A|a) interactive="A" ;;
      *) ;;
    esac
  fi
  files=$(find "$dir" -maxdepth 1 -type f \( -name '*-sh-*' -o -name '*-sql-*' \) | sort)
  for f in $files; do
    [[ "$f" == *-Y ]] && continue
    while true; do
      cpu=$(get_cpu_usage)
      mem=$(get_mem_usage)
      running=$(jobs -r | wc -l)
      if [ "$cpu" -lt "$cpu_limit" ] && \
         [ "$mem" -lt "$mem_limit" ] && \
         [ "$running" -lt "$max_proc" ]; then
        break
      fi
      sleep 1
    done
    execute_file "$f" &
  done
  wait
done

wait
kill $mon_pid

printf '\nResults written to %s\n' "$results"
