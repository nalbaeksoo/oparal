#!/usr/bin/env bash
# Execute shell and SQL files in alphabetical directories with simple CPU/memory
# based parallelism. Only bash and awk are used.

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
  -h  show this help
USAGE
}

cpu_limit=85
mem_limit=80
root="./"
interactive="Y"
max_proc=200
sql_user="system"
sql_pass="manager"

while [ $# -gt 0 ]; do
  case "$1" in
    -c) cpu_limit=$2; shift 2;;
    -m) mem_limit=$2; shift 2;;
    -d) root=$2; shift 2;;
    -i) interactive=$2; shift 2;;
    -p) max_proc=$2; shift 2;;
    -us) sql_user=$2; shift 2;;
    -pa) sql_pass=$2; shift 2;;
    -h) usage; exit 0;;
    *) usage; exit 1;;
  esac
done

# disable prompts when running without a terminal (e.g. via nohup)
if [ ! -t 0 ] && [ "$interactive" = "Y" ]; then
  interactive="A"
fi

# internal counters
completed=0
started=0
progress_file=$(mktemp)
started_file=$(mktemp)
results="$(date +%Y%m%d_%H%M).result.csv"

echo "0" > "$progress_file"
echo "0" > "$started_file"
echo "directory,file,start,end,duration" > "$results"

get_cpu_usage() {
  awk '/^cpu /{idle=$5; tot=$2+$3+$4+$5+$6+$7+$8+$9+$10; print int(100 - idle*100/tot)}' /proc/stat
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
  read rx0 tx0 < <(get_net_stats)
  total=$(find "$root" -maxdepth 2 -type f \( -name '*-sh-N' -o -name '*-sql-N' \) | wc -l)
  while true; do
    sleep 10
    completed=$(cat "$progress_file")
    forked=$(cat "$started_file")
    cpu=$(get_cpu_usage)
    mem=$(get_mem_usage)
    disk=$(get_disk_usage)
    running=$(jobs -r | wc -l)
    running=$(( running > 0 ? running-1 : 0 ))
    read rx1 tx1 < <(get_net_stats)
    rx=$((rx1-rx0))
    tx=$((tx1-tx0))
    rx0=$rx1; tx0=$tx1
    if [ "$total" -gt 0 ]; then
      progress=$(( completed * 100 / total ))
    else
      progress=100
    fi
    echo "Progress: $completed/$total (${progress}%) CPU:${cpu}% MEM:${mem}% DISK:${disk} NET:${rx}/${tx} RUN:${running} FORK:${forked}"
  done
}

execute_file() {
  f="$1"
  start=$(date +%s)
  echo "[start] $f"
  if [[ "$f" == *-sql-* ]]; then
    sqlplus "$sql_user/$sql_pass" @"$f"
  else
    sh "$f"
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
  rm -f "$progress_file" "$started_file"
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
      running=$(( running > 0 ? running-1 : 0 ))
      if [ "$cpu" -lt "$cpu_limit" ] && \
         [ "$mem" -lt "$mem_limit" ] && \
         [ "$running" -lt "$max_proc" ]; then
        break
      fi
      sleep 1
    done
    started=$((started+1))
    echo "$started" > "$started_file"
    execute_file "$f" &
  done
  wait
done

wait
kill $mon_pid

printf '\nResults written to %s\n' "$results"
