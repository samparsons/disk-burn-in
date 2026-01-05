# Fedora Drive Burn-in (SMART + badblocks) for YAMS

This repo adds a Fedora-friendly burn-in script for testing new HDDs (e.g. 28TB) via a USB dock.

**WARNING:** The "full" test is **destructive**. It will erase the entire disk.

## What it does

`scripts/disk-burnin-fedora.sh` runs:

- SMART short test
- (Optional) SMART conveyance test (often unsupported on USB bridges)
- SMART long/extended test
- For HDDs (rotational): destructive `badblocks -wsv` (multi-pass by default)
- SMART short + long again after `badblocks`

It writes:
- A detailed per-drive log under `/opt/yams/scripts/disk-burn-in/run-logs/`
- A machine-readable status JSON under `/opt/yams/scripts/disk-burn-in/run-status/<MODEL>_<SERIAL>/status.json`

If you enable git auto-push (`REPO_DIR` + `AUTO_PUSH=1`), it additionally mirrors status into:
- `/opt/yams/scripts/disk-burn-in/status/<MODEL>_<SERIAL>/status.json`
so it can be committed and pushed for GitHub “push email” notifications.

## Quick start (safe dry-run)

1) Identify the drive:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,ROTA,MOUNTPOINT
```

2) Dry run (prints ETA + planned steps):

```bash
sudo /opt/yams/scripts/disk-burn-in/scripts/disk-burnin-fedora.sh --device /dev/sdX --plan
```

Self-test (no disk required; good for validating git auto-push alerts):

```bash
cd /opt/yams/scripts/disk-burn-in
export REPO_DIR=/opt/yams/scripts/disk-burn-in
export AUTO_PUSH=1
export GIT_REMOTE=origin
export GIT_BRANCH=main
./scripts/disk-burnin-fedora.sh --self-test
```

3) Real run (DESTRUCTIVE):

```bash
sudo /opt/yams/scripts/disk-burn-in/scripts/disk-burnin-fedora.sh --device /dev/sdX --run
```

## Fast vs thorough

Default is **thorough**:
- `badblocks` patterns = `default` (multi-pass)

To reduce time at the cost of coverage:

```bash
sudo /opt/yams/scripts/disk-burn-in/scripts/disk-burnin-fedora.sh --device /dev/sdX --run --patterns single
```

To skip badblocks entirely (SMART-only):

```bash
sudo /opt/yams/scripts/disk-burn-in/scripts/disk-burnin-fedora.sh --device /dev/sdX --run --no-badblocks
```

## GitHub “push email” notifications (auto-push)

If you want email notifications via GitHub when checkpoints complete/fail, the script can:
- write `status/<MODEL>_<SERIAL>/status.json` into a git repo folder
- commit + push at each checkpoint

Prereqs:
- You must have a repo you can push to (typically a **fork**)
- Configure SSH deploy key with write access

Environment variables:

```bash
export REPO_DIR=/path/to/your/cloned/repo
export AUTO_PUSH=1
export GIT_REMOTE=origin
export GIT_BRANCH=main
```

## Notes on speed

With a single USB dock, CPU is rarely the bottleneck. The limiting factors are:
- sustained sequential throughput of the drive
- USB/SATA bridge and port
- how many full-disk passes you choose (badblocks multi-pass can take **many days**)

## Notes on USB stability (important)

Some USB/SATA bridges are flaky during SMART long tests. Two practical tips:

- Avoid running `smartctl` in a tight loop (e.g., every 10s) while a long test is running; frequent SMART queries can stress some bridges and correlate with “Aborted by host”.
- Prefer checking SMART progress infrequently (e.g., every 30–60 minutes), and rely on the script’s built-in polling (it already polls long tests slowly on USB).


