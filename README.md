# oparal

This project provides a Bash script for running shell or SQL files found under alphabetical subdirectories. Each task executes in its own forked process so the script can run many jobs in parallel while CPU and memory usage remain below configured thresholds. Files are processed in numeric order based on their filename.

## Usage

```
./oparal.sh [options]
```

Options:

- `-c NN`  CPU usage threshold percentage (default: 85).
- `-m NN`  Memory usage threshold percentage (default: 80).
- `-d DIR` Root directory containing `a`..`z` subdirectories (default: `./`).
- `-i MODE` Interactive mode. `Y` asks before processing each directory, `A` runs all directories without prompts (default: `Y`). When standard input is not a terminal (for example when running with `nohup`), mode automatically becomes `A`.
- `-p NN`  Maximum concurrent processes (default: 200).
- `-op NN` Number of processes launched in each batch before resource checks (default: 1).
- `-us USER` SQL*Plus username (default: `system`).
- `-pa PASS` SQL*Plus password (default: `manager`).
- `-h`     Show help.

New tasks are launched when **any** of CPU usage, memory usage, or the number of
running processes drops below its corresponding limit. This OR condition lets
the script take advantage of whichever resource becomes available first.

The script scans every directory from `a` to `z` under the specified root. Files must be named like `00001-N-something.sh` or `00002-N-title.sql`. Shell files are run with `sh` while SQL files are executed via `sqlplus USER/PASS`. Output from both kinds of tasks is checked for lines containing `error`, `fatal`, or Oracle codes starting with `ORA-`; any matches are appended to the error log. Files are processed in numeric order. After completion, the `-N-` flag in the filename is replaced with `-Y-` while keeping the rest of the name intact.

During execution a progress line appears every 10 seconds. It shows the number of completed files, CPU and memory usage, how many slave processes are running out of the configured limit, the directory being processed, and how many log lines include the words "error" or "fatal" (case is ignored) or contain an Oracle error message beginning with `ORA-`. The running count reflects tasks that have started but not yet finished. CPU usage comes from the `top` command and memory usage excludes the Linux file cache (Buffers, Cached, and SReclaimable from `/proc/meminfo`).

```
Progress: 03/10 (30%) CPU:20.0% MEM:50% Running:2/200 WorkDir:c ERR:0
```

When finished a results file named `YYYYMMDD_HHMM_INSTANCE.result.csv` is written containing start time, end time, and duration for each file. The instance identifier is generated automatically so results from concurrent runs remain separate. The summary prints a **Total errors** value based on how many lines in the error log contain `error`, `fatal`, or start with `ORA-`. Those lines remain in the error log for review.
