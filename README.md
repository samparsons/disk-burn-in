# disk-burnin-fedora

A single-file bash script for **destructive** HDD burn-in on Fedora/Linux: SMART self-tests plus optional `badblocks -wsv`. Safe by default (no destructive steps unless you pass `--run`).

---

## ⚠️ Important disclaimer

**This script was created with AI assistance.** It has not been independently audited for correctness or safety.

- **Use at your own risk.** You are responsible for verifying the script's behavior before running it on any drive.
- **Destructive use:** With `--run`, the script will **erase the entire disk**. Double-check the device path and that no critical data is on the drive.
- **Review the code** before use. Prefer running in plan/dry-run mode first and validating on a test system if possible.
- **No warranty.** The authors and contributors provide this script "as is" without any guarantee of fitness for a particular purpose.

---

## What it does

`scripts/disk-burnin-fedora.sh` runs:

- SMART short test  
- (Optional) SMART conveyance test (often unsupported on USB bridges)  
- SMART long/extended test  
- For HDDs (rotational): destructive **badblocks -wsv** (multi-pass by default)  
- SMART short + long again after badblocks  

It writes:

- Per-drive logs under `run-logs/`
- Machine-readable status JSON under `run-status/<MODEL>_<SERIAL>/status.json`

Optional: with `REPO_DIR` and `AUTO_PUSH=1`, it can mirror status into a git repo and push for GitHub "push email" notifications.

## Requirements

- **Required:** `smartctl` (smartmontools), `badblocks` (e2fsprogs), `lsblk`, `awk`, `sed`, `grep`, `date`, `python3`
- **Optional:** `tmux` (for parallel runs), git + SSH (for auto status push)

Install on Fedora:

```bash
sudo dnf install smartmontools e2fsprogs util-linux python3
```

## Quick start (safe)

1. **Identify the drive**

   ```bash
   lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,ROTA,MOUNTPOINT
   ```

2. **Plan only (no SMART, no badblocks)**

   ```bash
   sudo ./scripts/disk-burnin-fedora.sh --device /dev/sdX --plan
   ```

3. **SMART-only (non-destructive)**

   ```bash
   sudo ./scripts/disk-burnin-fedora.sh --device /dev/sdX
   ```

4. **Full run (DESTRUCTIVE — erases the drive)**

   ```bash
   sudo ./scripts/disk-burnin-fedora.sh --device /dev/sdX --run
   ```

## Options

| Option | Description |
|--------|-------------|
| `--device PATH` | Block device (e.g. `/dev/sdb`). Must be whole-disk, not a partition. |
| `--plan` | Print plan/ETA only. No SMART tests, no badblocks. |
| `--run` | Perform destructive steps (badblocks). **Without this, data is not erased.** |
| `--no-badblocks` | Skip badblocks even for HDDs (SMART-only). |
| `--patterns default\|single` | `default` = 4-pass (thorough), `single` = 1-pass (faster). |
| `--abort-smart` | Abort any in-progress SMART test before starting. |
| `--self-test` | Test status output and optional git push; does not touch disks. |

See `./scripts/disk-burnin-fedora.sh --help` for full usage.

## Safety

- The script **refuses to run on mounted partitions**; unmount first.
- Always confirm the device path (e.g. with `lsblk`). Using the wrong device can destroy data.
- Prefer stable paths like `/dev/disk/by-id/...` when using USB docks (device names can change).

## Inspiration and references

This script draws on ideas and patterns from existing open-source disk burn-in and testing projects:

- **[Spearfoot/disk-burnin-and-testing](https://github.com/Spearfoot/disk-burnin-and-testing)** — POSIX shell script: SMART short → badblocks → SMART extended; dry-run by default; widely used reference.
- **[dak180/disk-burnin-and-testing](https://github.com/dak180/disk-burnin-and-testing)** — Bash burn-in script (including [topic/burnin](https://github.com/dak180/disk-burnin-and-testing/blob/topic/burnin/README.md)): SMART short → conveyance → extended → badblocks → SMART again; inspired by TrueNAS community burn-in testing; dry-run by default, tmux for multiple drives.
- **[ezonakiusagi/bht](https://github.com/ezonakiusagi/bht)** — Bulk HDD testing with badblocks: launches multiple badblocks instances, status checks, optional email notifications when tests complete.
- **[zaggynl/hddtest](https://github.com/zaggynl/hddtest)** — Linux HDD torture test (SMART + destructive badblocks), FreeNAS-style.
- **[jasontbradshaw – Hard Drive burn-in script (Gist)](https://gist.github.com/jasontbradshaw/3ca8abeee59a961b5b8a)** — Burn-in for new drives and pre–full-disk encryption.

The flow (SMART → badblocks → SMART) and use of `badblocks -wsv` follow common practice from these projects; this version adds Fedora/Linux defaults, USB-dock considerations, optional git status push, and tmux-based parallel runs.

---

**Again:** This project was AI-assisted. Review the script, understand what it does, and use caution when deploying it.
