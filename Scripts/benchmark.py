# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Measure what menu bar monitors cost while they sit there.

    uv run Scripts/benchmark.py                      # AirStats against whatever else is running
    uv run Scripts/benchmark.py --samples 160        # the count the write-up used
    uv run Scripts/benchmark.py --group Foo=Foo,Bar  # measure some other app

This reproduces the method behind the numbers in the comparison write-up at
https://airstats.app/blog/airstat-vs-stats-vs-istat-menus. It is not the
transcript of that run: it will report what the apps on *your* Mac cost right now, and
those figures will differ from the published ones because they depend on the hardware,
the macOS version and what else the machine is doing. Reproducing the ranking is the
point; reproducing the digits is not to be expected.

Every app is measured by a single `top -l 2 -s 1` invocation per interval, which is the
one thing here that cannot be varied without changing what the numbers mean:

- One invocation covering every process means all the apps share an identical measuring
  window, so a busy moment lands on all of them or on none of them. Sampling each app
  with its own `top` would let them be measured over different seconds and call the
  difference a result.
- `-l 2` and discarding the first sample matters because `top`'s opening sample reports
  CPU accumulated since the process launched rather than over the interval. Reading it
  flatters whichever app was started most recently and can be off by orders of
  magnitude.

A menu bar monitor is itself a process reading the kernel, so this measures the observer
along with everything else. `top` reads through the same interfaces the apps do.
"""

import argparse
import platform
import re
import statistics
import subprocess
import sys

# An app can be several processes, and a suite that splits its work across a helper
# would look cheap if only its front-most process were counted. Each group sums every
# process whose name matches any of its patterns. iStat Menus ships a status bar app and
# a daemon, which is why its row in the write-up is labelled a suite.
DEFAULT_GROUPS = {
    "AirStats": ["AirStats"],
    "Stats": ["Stats"],
    "iStat Menus (suite)": ["iStat Menus*", "iStatMenus*"],
}

MEM_UNITS = {"B": 1 / 1024**2, "K": 1 / 1024, "M": 1.0, "G": 1024.0, "T": 1024.0**2}


def find_pids(patterns):
    """Every running pid whose executable name matches one of `patterns`.

    A pattern matches the whole process name, or its beginning when it ends in `*`.
    Substring matching is deliberately not offered: `Stats` occurs inside both
    `systemstats` and `AirStats`, so a looser rule silently sums the app under test
    into the app it is being compared against and reports the total as the rival's
    cost. The wildcard exists for suites whose helpers share a prefix, and for names
    long enough that `ps` truncates them.

    Matching is on the process name rather than the full command line so that this
    script, which has the app names in its own arguments, never matches itself.
    """
    pids = {}
    listing = subprocess.run(
        ["ps", "-axco", "pid=,comm="], capture_output=True, text=True, check=True
    ).stdout
    for line in listing.splitlines():
        pid, _, name = line.strip().partition(" ")
        name = name.strip()
        for pattern in patterns:
            target, wildcard = pattern.rstrip("*").lower(), pattern.endswith("*")
            hit = name.lower().startswith(target) if wildcard else name.lower() == target
            if hit:
                pids[int(pid)] = name
                break
    return pids


def parse_memory(raw):
    """`top`'s MEM column to MiB. Values look like `11M`, `1.5G` or `144M+`."""
    raw = raw.rstrip("+-")
    match = re.fullmatch(r"([\d.]+)([BKMGT]?)", raw)
    if not match:
        return None
    value, unit = match.groups()
    return float(value) * MEM_UNITS.get(unit or "B", 1.0)


def sample(pids):
    """One `top` interval. Returns {pid: (cpu_percent, mib, threads)}.

    `-l 2` prints two sample blocks and only the second describes the interval, so the
    rows after the last header line are the ones read.
    """
    args = ["top", "-l", "2", "-s", "1", "-stats", "pid,command,cpu,mem,th"]
    for pid in pids:
        args += ["-pid", str(pid)]

    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    lines = out.splitlines()
    headers = [i for i, line in enumerate(lines) if line.startswith("PID")]
    if len(headers) < 2:
        raise RuntimeError("top printed fewer than two sample blocks")

    readings = {}
    for line in lines[headers[-1] + 1 :]:
        fields = line.split()
        if len(fields) < 5 or not fields[0].isdigit():
            continue
        pid, cpu, mem, threads = int(fields[0]), fields[-3], fields[-2], fields[-1]
        try:
            readings[pid] = (float(cpu), parse_memory(mem), int(threads))
        except ValueError:
            continue
    return readings


def percentile(values, fraction):
    """The value below which `fraction` of the samples fall, nearest rank.

    `statistics.quantiles` interpolates between samples, which invents a CPU reading
    that `top` never reported. At these magnitudes that is the difference between a
    real 0.10% and a fabricated 0.085%.
    """
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * len(ordered)) - 1))
    return ordered[index]


def main():
    parser = argparse.ArgumentParser(
        description="Sample menu bar monitors over one shared window.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--samples", type=int, default=60,
        help="intervals to record. The write-up used 160, which takes about 3 minutes.",
    )
    parser.add_argument(
        "--group", action="append", default=[], metavar="NAME=PAT[,PAT]",
        help="add an app to measure. Repeatable. Replaces the defaults when given.",
    )
    args = parser.parse_args()

    groups = dict(DEFAULT_GROUPS)
    if args.group:
        groups = {}
        for spec in args.group:
            name, _, patterns = spec.partition("=")
            groups[name] = [p.strip() for p in patterns.split(",") if p.strip()]

    found = {name: find_pids(patterns) for name, patterns in groups.items()}
    missing = [name for name, pids in found.items() if not pids]
    found = {name: pids for name, pids in found.items() if pids}

    if not found:
        sys.exit("Nothing to measure: none of the named apps are running.")

    machine = subprocess.run(
        ["sysctl", "-n", "hw.model", "machdep.cpu.brand_string"],
        capture_output=True, text=True, check=True,
    ).stdout.split("\n")
    print(f"{machine[0]} · {machine[1]} · macOS {platform.mac_ver()[0]}")
    for name, pids in found.items():
        print(f"  {name}: {', '.join(f'{n} ({p})' for p, n in pids.items())}")
    for name in missing:
        print(f"  {name}: not running, skipped")

    # The write-up's run sat under a sustained artificial load, so its percentages
    # describe a busy machine. Printing the load average keeps the reader's run
    # comparable, or at least visibly not comparable.
    load = subprocess.run(["uptime"], capture_output=True, text=True, check=True).stdout
    print(f"  load average at start:{load.split('load averages:')[-1].rstrip()}")
    print(f"\nSampling {args.samples} intervals, one top run each.", flush=True)

    series = {name: {"cpu": [], "mem": [], "th": []} for name in found}
    every_pid = [pid for pids in found.values() for pid in pids]

    for i in range(args.samples):
        readings = sample(every_pid)
        for name, pids in found.items():
            present = [readings[p] for p in pids if p in readings]
            if not present:
                continue
            series[name]["cpu"].append(sum(r[0] for r in present))
            series[name]["mem"].append(sum(r[1] for r in present if r[1] is not None))
            series[name]["th"].append(sum(r[2] for r in present))
        print(f"\r  {i + 1}/{args.samples}", end="", flush=True)

    print("\n")
    print("| App | n | Mean CPU | Median | p95 | Max | Memory | Threads |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for name, data in sorted(series.items(), key=lambda kv: statistics.fmean(kv[1]["cpu"] or [0])):
        cpu = data["cpu"]
        if not cpu:
            continue
        print(
            f"| {name} | {len(cpu)} | {statistics.fmean(cpu):.3f}% "
            f"| {statistics.median(cpu):.2f}% | {percentile(cpu, 0.95):.2f}% "
            f"| {max(cpu):.2f}% | {statistics.median(data['mem']):.1f} MB "
            f"| {statistics.median(data['th']):.0f} |"
        )

    # Memory is reported as a median rather than a mean because these apps step up when
    # a window opens and never step back down, so a mean over a run that included one
    # such step describes a moment the app was never in.
    print("\nMemory and threads are medians over the run. A monitor whose panel has")
    print("been opened holds more than one that has only ever drawn its menu bar item.")


if __name__ == "__main__":
    main()
