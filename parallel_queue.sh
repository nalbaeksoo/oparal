#!/bin/bash
# parallel_queue.sh - simple parallel queue using shell and awk
# Usage: parallel_queue.sh [-n concurrency] tasks_file

set -e

concurrency=2
usage() {
  echo "Usage: $0 [-n concurrency] tasks_file" >&2
  exit 1
}

while getopts "n:" opt; do
  case "$opt" in
    n) concurrency="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

[ $# -eq 1 ] || usage

tasks_file="$1"

[ -f "$tasks_file" ] || { echo "Task file $tasks_file not found" >&2; exit 1; }

pipe=$(mktemp -u)
mkfifo "$pipe"

# Launch producer with AWK
awk '{print}' "$tasks_file" > "$pipe" &
producer_pid=$!

# Launch workers
for i in $(seq "$concurrency"); do
  (
    while IFS= read -r cmd; do
      echo "[worker $i] $cmd"
      eval "$cmd"
    done < "$pipe"
  ) &
  pids="$pids $!"
done

wait "$producer_pid"

# Close the pipe for writing to signal EOF to workers
exec 3>"$pipe"
exec 3>&-

wait $pids
rm "$pipe"
