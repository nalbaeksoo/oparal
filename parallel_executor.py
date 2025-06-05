import argparse
import os
import subprocess
import time
import csv
import re
from datetime import datetime
import shutil


def parse_args():
    parser = argparse.ArgumentParser(description="Execute shell/sql files in parallel until CPU and memory thresholds")
    parser.add_argument('-c', type=int, default=85, help='CPU usage threshold percent (default: 85)')
    parser.add_argument('-m', type=int, default=80, help='Memory usage threshold percent (default: 80)')
    parser.add_argument('-d', default='./main', help='Root directory containing a-z subdirectories (default: ./main)')
    parser.add_argument('-i', default='Y', choices=['Y', 'A'], help='Interactive mode: Y ask per directory, A run all (default: Y)')
    return parser.parse_args()


def list_directories(root):
    dirs = []
    if not os.path.isdir(root):
        return dirs
    for name in os.listdir(root):
        if re.fullmatch(r'[a-z]', name) and os.path.isdir(os.path.join(root, name)):
            dirs.append(name)
    dirs.sort()
    return dirs


def list_files(dir_path):
    files = []
    for f in os.listdir(dir_path):
        m = re.match(r'^(\d{5}-.+-(?:sh|sql)-)([NY])$', f)
        if m and m.group(2) == 'N':
            files.append(f)
    files.sort()
    return files


def run_command(path):
    if path.endswith('.sql'):
        return subprocess.Popen(['bash', '-c', f'echo executing SQL {path}'])
    else:
        return subprocess.Popen(['bash', path])


def rename_done(path):
    base = os.path.basename(path)
    new_base = re.sub(r'N$', 'Y', base)
    new_path = os.path.join(os.path.dirname(path), new_base)
    os.rename(path, new_path)
    return new_base


def format_time(ts):
    return datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M:%S')


def read_cpu_mem():
    with open('/proc/stat') as f:
        cpu_line = f.readline()
    cpu_parts = [float(x) for x in cpu_line.strip().split()[1:]]
    idle = cpu_parts[3]
    total = sum(cpu_parts)
    time.sleep(0.1)
    with open('/proc/stat') as f:
        cpu_line2 = f.readline()
    cpu_parts2 = [float(x) for x in cpu_line2.strip().split()[1:]]
    idle2 = cpu_parts2[3]
    total2 = sum(cpu_parts2)
    cpu_usage = 100 * (1 - (idle2 - idle) / (total2 - total)) if total2 != total else 0
    with open('/proc/meminfo') as f:
        meminfo = f.read()
    mem_total = int(re.search(r'MemTotal:\s+(\d+)', meminfo).group(1))
    mem_available = int(re.search(r'MemAvailable:\s+(\d+)', meminfo).group(1))
    mem_usage = 100 * (mem_total - mem_available) / mem_total
    return cpu_usage, mem_usage


def read_disk():
    usage = shutil.disk_usage('/')
    return 100 * usage.used / usage.total


def read_net():
    with open('/proc/net/dev') as f:
        lines = f.readlines()[2:]
    sent = recv = 0
    for line in lines:
        parts = line.split()
        recv += int(parts[1])
        sent += int(parts[9])
    return sent, recv


def main():
    args = parse_args()
    root = args.d
    cpu_limit = args.c
    mem_limit = args.m
    interactive = args.i

    dirs = list_directories(root)
    total_files = sum(len(list_files(os.path.join(root, d))) for d in dirs)

    results = []
    completed = 0
    last_report = time.time()
    ask_each = True if interactive == 'Y' else False

    for d in dirs:
        dir_path = os.path.join(root, d)
        if ask_each:
            resp = input(f"Execute directory {d}? [y/n/a/q]: ").strip().lower()
            if resp == 'q':
                return
            if resp == 'a':
                ask_each = False
            if resp == 'n':
                continue
        files = list_files(dir_path)
        index = 0
        running = {}
        while index < len(files) or running:
            cpu, mem = read_cpu_mem()
            if cpu < cpu_limit and mem < mem_limit and index < len(files):
                f = files[index]
                full = os.path.join(dir_path, f)
                start = time.time()
                proc = run_command(full)
                running[proc] = (full, start)
                index += 1
            finished = []
            for proc, (path, st) in running.items():
                if proc.poll() is not None:
                    end = time.time()
                    rename_done(path)
                    results.append({
                        'directory': d,
                        'file': os.path.basename(path),
                        'start': format_time(st),
                        'end': format_time(end),
                        'duration': f"{end - st:.2f}"
                    })
                    completed += 1
                    finished.append(proc)
            for proc in finished:
                running.pop(proc)
            now = time.time()
            if now - last_report >= 10:
                disk = read_disk()
                sent, recv = read_net()
                progress = (completed / total_files * 100) if total_files else 100
                print(f"Progress: {progress:.1f}% | CPU {cpu:.1f}% | MEM {mem:.1f}% | DISK {disk:.1f}% | NET sent {sent} recv {recv}")
                last_report = now
            time.sleep(0.5)
    if results:
        print("\nExecution summary:")
        for r in results:
            print(f"{r['directory']}/{r['file']} start:{r['start']} end:{r['end']} duration:{r['duration']}s")
        with open('execution_report.csv', 'w', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=['directory', 'file', 'start', 'end', 'duration'])
            writer.writeheader()
            for r in results:
                writer.writerow(r)
        print("CSV report written to execution_report.csv")


if __name__ == '__main__':
    main()
