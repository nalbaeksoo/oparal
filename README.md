# oparal

This repository provides a simple parallel execution tool for running shell or SQL scripts organized in alphabetic subdirectories.

## Script: `parallel_executor.py`

```
usage: parallel_executor.py [-h] [-c C] [-m M] [-d D] [-i {Y,A}]
```

Options:
- `-c` CPU usage threshold percent (default: 85)
- `-m` Memory usage threshold percent (default: 80)
- `-d` Root directory containing `a`-`z` subdirectories (default: `./main`)
- `-i` Interactive mode: `Y` ask before entering each directory, `A` run all without prompts

The script scans directories named `a` through `z` under the specified root. Within each directory it executes files matching the pattern `00001-description-sh-N` or `00001-description-sql-N` in numeric order. Files already marked with `-Y` are skipped. When a file completes it is renamed so the trailing flag becomes `Y`.

Multiple scripts may run in parallel while the system CPU and memory usage stay below the specified thresholds. Progress, including basic system metrics, is printed every 10 seconds. After completion a CSV report `execution_report.csv` contains the start time, end time and duration for each executed file.
