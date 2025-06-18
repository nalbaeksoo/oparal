# oparal

This project provides a Bash script for running shell or SQL files found under alphabetical subdirectories. Files are executed in numeric order and more jobs are started while CPU and memory usage remain below configured thresholds.

## Usage

```
./oparal.sh [options]
```

Options:

- `-c NN`  CPU usage threshold percentage. New tasks start while usage is below this value (default: 85).
- `-m NN`  Memory usage threshold percentage. New tasks start while usage is below this value (default: 80).
- `-d DIR` Root directory containing `a`..`z` subdirectories (default: `./`).
- `-i MODE` Interactive mode. `Y` asks before processing each directory, `A` runs all directories without prompts (default: `Y`). When standard input is not a terminal (for example when running with `nohup`), mode automatically becomes `A`.
- `-p NN`  Maximum concurrent processes (default: 200).
- `-us USER` SQL*Plus username (default: `system`).
- `-pa PASS` SQL*Plus password (default: `manager`).
- `-id ID`  Custom instance identifier. When omitted, a unique ID is auto-generated.
- `-h`     Show help.

The script scans every directory from `a` to `z` under the specified root. Files must be named like `00001-something-sh-N` or `00002-title-sql-N`. Shell files are run with `sh` while SQL files are executed via `sqlplus USER/PASS @file`. Files are processed in numeric order and after completion the trailing `N` is changed to `Y`.

During execution a progress line appears every 10 seconds showing completed percentage, the number of running slave processes and how many have been forked in total, along with current CPU, memory, disk and network statistics. When finished a results file named `YYYYMMDD_HHMM_INSTANCE.result.csv` is written, containing start time, end time and duration for each file. The instance identifier keeps results from concurrent runs separate.
