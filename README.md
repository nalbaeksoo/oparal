# oparal

This project provides a Bash script for running shell or SQL files found under alphabetical subdirectories. Files are executed in numeric order and more jobs are started while CPU and memory usage remain below configured thresholds.

## Usage

```
./oparal.sh [options]
```

Options:

- `-c NN`  CPU usage threshold percentage. New tasks start while usage is below this value (default: 85).
- `-m NN`  Memory usage threshold percentage. New tasks start while usage is below
   this value (default: 80). Memory usage excludes file cache using
   `/proc/meminfo`'s `MemAvailable`.
- `-d DIR` Root directory containing `a`..`z` subdirectories (default: `./`).
- `-i MODE` Interactive mode. `Y` asks before processing each directory, `A` runs all directories without prompts (default: `Y`). When interactive mode is used the script completes all tasks in that directory before prompting for the next. When standard input is not a terminal (for example when running with `nohup`), mode automatically becomes `A`.
- `-p NN`  Maximum concurrent processes (default: 200).
- `-op NN` Number of slave processes to run in parallel. Use `1` for serial execution.
- `-us USER` SQL*Plus username (default: `system`).
- `-pa PASS` SQL*Plus password (default: `manager`).
- `-id ID`  Custom instance identifier. When omitted, a unique ID is auto-generated.
- `-hist FILE` Results CSV to base task ordering on. Defaults to the most recent file.
- `-h`     Show help.

SQL files are executed with `sqlplus USER/PASS < file` and their output is suppressed unless an error occurs.

The script scans every directory from `a` to `z` under the specified root. Files must be named like `00001-something-sh-N` or `00002-title-sql-N`. Shell files are run with `sh file` while SQL files are executed using `sqlplus USER/PASS < file`. Files are processed in numeric order and after completion the trailing `N` is changed to `Y`.
Start and completion messages are written only to the error log so that the console remains uncluttered.

During execution a progress line appears every 10 seconds. It shows how many tasks have completed, the current CPU and memory usage, and how many slave processes are running out of the configured limit. CPU usage comes from `top -bn1` and memory usage excludes file cache via `/proc/meminfo`. Values below `0.05%` round up to `0.1%`. When finished, a results file named `YYYYMMDD_HHMM_INSTANCE.result.csv` records start time, end time and duration for each file. The instance identifier keeps results from concurrent runs separate.
The number of running jobs is calculated from child processes of the main script so it works even when launched via `nohup` or in other noninteractive environments.

If result files exist in `.parallel_logs`, the script lists each file and indicates which one achieved the shortest total duration. It then asks whether to reorder tasks using the selected results file (either the one given with `-hist` or the latest file).

Pressing `Ctrl+C` stops the script and all slave processes. The cleanup routine
terminates the progress monitor and every background job along with all of their
child processes so no SQL*Plus tasks or sleeps remain running.
