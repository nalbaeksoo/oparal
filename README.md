# oparal

This repository contains a simple parallel queue implementation using a shell script and AWK.

## Script

`parallel_queue.sh` reads a list of shell commands from a file and executes them in parallel using a specified level of concurrency. AWK is used to feed the commands into a FIFO queue that multiple worker processes consume.

### Usage

```bash
./parallel_queue.sh [-n concurrency] tasks_file
```

- `concurrency`: Number of worker processes (defaults to 2).
- `tasks_file`: A text file where each line is a command to run.

### Example

Create a file `tasks.txt` with commands:

```bash
sleep 1 && echo one
sleep 2 && echo two
sleep 3 && echo three
```

Run the queue with two workers:

```bash
./parallel_queue.sh -n 2 tasks.txt
```

The script will print which worker runs each command and execute them concurrently.
