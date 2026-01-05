#!/usr/bin/env bash
set -euo pipefail

# disk-burnin-fedora.sh
# Destructive burn-in for HDDs on Fedora/Linux: SMART tests + optional badblocks -wsv.
# SAFE BY DEFAULT: does nothing destructive unless you pass --run.
#
# Designed for use with a single external USB dock (one drive at a time).
#
# Requirements: smartctl (smartmontools), badblocks (e2fsprogs), lsblk, awk, sed, grep, date, timeout
#
# Optional: git + ssh deploy key (for auto status push), tmux (for running in a session)

VERSION="0.1.0"

RUN=0
PLAN=0
ABORT_SMART=0
DEVICE=""
MULTI_DEVICES=""
SELF_TEST=0
DEV_TAG=""

# Default output locations live under the burn-in repo root to avoid cluttering /opt/yams/.
# Repo layout (default):
#   /opt/yams/scripts/disk-burn-in/
#     run-logs/
#     run-status/
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/run-logs}"
STATUS_DIR="${STATUS_DIR:-$REPO_ROOT/run-status}"
REPO_DIR="${REPO_DIR:-}"                 # if set, will write status into this repo and optionally commit+push
GIT_REMOTE="${GIT_REMOTE:-}"             # e.g. github.com-yams-burnin:<you>/<repo>.git (via ssh config alias) OR full git@ url
GIT_BRANCH="${GIT_BRANCH:-main}"
AUTO_PUSH="${AUTO_PUSH:-0}"              # 1 to commit+push on checkpoints
SMART_CONVEYANCE="${SMART_CONVEYANCE:-0}" # 1 to attempt conveyance test (often unsupported/meaningless via USB bridges)
BADBLOCKS="${BADBLOCKS:-1}"              # 1 to run badblocks for HDDs
BB_BLOCK_SIZE="${BB_BLOCK_SIZE:-8192}"
BB_BATCH_BLOCKS="${BB_BATCH_BLOCKS:-32768}"  # -c value (blocks per batch); tune if needed
BB_PATTERNS="${BB_PATTERNS:-default}"    # "default" (4-pass) or "single" (1-pass, faster, less thorough)
ETA_SAMPLE_MIB="${ETA_SAMPLE_MIB:-2048}" # size of read sample (MiB) to estimate throughput
ETA_SAMPLE_OFFSET_GIB="${ETA_SAMPLE_OFFSET_GIB:-16}" # skip first GiB (often slower) when sampling

usage() {
  cat <<'EOF'
disk-burnin-fedora.sh - destructive drive burn-in with logs + optional git status pushes

USAGE:
  sudo ./disk-burnin-fedora.sh --device /dev/sdX --plan     # PLAN ONLY (no SMART, no badblocks; safe)
  sudo ./disk-burnin-fedora.sh --device /dev/sdX            # SMART-ONLY (non-destructive)
  sudo ./disk-burnin-fedora.sh --device /dev/sdX --run      # FULL RUN (DESTRUCTIVE: includes badblocks)
  sudo ./disk-burnin-fedora.sh --multi "/dev/sdb /dev/sdc" --run # PARALLEL RUN in tmux
  ./disk-burnin-fedora.sh --self-test                       # NO DISK REQUIRED: tests status JSON + optional git auto-push

Options:
  --device PATH          Block device (e.g. /dev/sdb). MUST be whole-disk, not a partition.
  --multi "LIST"         Space-separated list of devices to test in parallel via tmux.
  --plan                 Print plan/ETA only. Does NOT start SMART tests and does NOT run badblocks.
  --abort-smart          If a SMART self-test is already running, abort it first (smartctl -X) then proceed.
  --run                  Actually perform destructive steps (badblocks). Without this, it only prints planned actions + ETA.
  --self-test            Run an end-to-end self-test of status generation and (if enabled) git commit+push. Does NOT touch disks.
  --no-badblocks         Skip badblocks even for HDDs (SMART-only).
  --patterns default|single
                          badblocks patterns: default=4-pass (slowest, most thorough), single=1-pass (faster, less thorough).
  --log-dir DIR          Log output directory (default: <repo>/run-logs)
  --repo-dir DIR         If set, write status files into this git repo folder (for push-email notifications).

Environment variables (optional):
  AUTO_PUSH=1            Commit+push status at checkpoints (requires git + SSH auth configured).
  GIT_REMOTE=...         Remote URL or ssh alias (e.g. git@github.com:you/repo.git).
  GIT_BRANCH=main        Branch to push to.
  SMART_CONVEYANCE=1     Attempt conveyance test (often unsupported via USB).

SAFETY:
  - This WILL ERASE the drive if you use --run and badblocks is enabled.
  - Refuses to run if the device has mounted partitions.

STATUS OUTPUT:
  Writes status JSON to: /opt/yams/burnin-status/<model>_<serial>/status.json
  If REPO_DIR is set, also mirrors into <repo>/status/<model>_<serial>/status.json for easy git pushing.
EOF
}

ts() { date -Is; }

die() { echo "$(ts) ERROR: $*" >&2; exit 1; }
note() { echo "$(ts) ==> $*"; }

log_note() {
  # Like note(), but also append to LOG_FILE when available (helps debugging failures).
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$(ts) ==> $*" | tee -a "$LOG_FILE"
  else
    note "$@"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Must run as root (use sudo)."
}

SMARTCTL_ARGS=()

detect_smartctl_args() {
  # Use smartctl's own scan output to choose the right -d TYPE for this device (e.g. -d sat).
  # Example: /dev/sda -d sat # /dev/sda [SAT], ATA device
  local line args
  line="$(smartctl --scan-open 2>/dev/null | awk -v dev="$DEVICE" '$1==dev {print; exit}')" || true
  if [[ -n "$line" ]]; then
    args="$(echo "$line" | awk '{
      for (i=2; i<=NF; i++) {
        if ($i=="#") break;
        printf "%s%s", (i==2?"":" "), $i
      }
    }')"
    if [[ -n "$args" ]]; then
      # shellcheck disable=SC2206
      SMARTCTL_ARGS=($args)
      return 0
    fi
  fi
  SMARTCTL_ARGS=()
}

is_usb_transport() {
  [[ "$(lsblk -dn -o TRAN "$DEVICE" 2>/dev/null | head -n1 || true)" == "usb" ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device) DEVICE="${2:-}"; shift 2;;
      --multi) MULTI_DEVICES="${2:-}"; shift 2;;
      --plan) PLAN=1; shift;;
      --abort-smart) ABORT_SMART=1; shift;;
      --run) RUN=1; shift;;
      --self-test) SELF_TEST=1; shift;;
      --no-badblocks) BADBLOCKS=0; shift;;
      --patterns) BB_PATTERNS="${2:-}"; shift 2;;
      --log-dir) LOG_DIR="${2:-}"; shift 2;;
      --repo-dir) REPO_DIR="${2:-}"; shift 2;;
      -h|--help) usage; exit 0;;
      *) die "Unknown option: $1";;
    esac
  done

  if [[ "$SELF_TEST" == "1" ]]; then
    return 0
  fi

  [[ -n "$DEVICE" ]] || [[ -n "$MULTI_DEVICES" ]] || die "--device or --multi is required (or use --self-test)"
  
  # Only validate DEVICE if it's set (not using --multi)
  if [[ -n "$DEVICE" ]]; then
    [[ -b "$DEVICE" ]] || die "Not a block device: $DEVICE"
    [[ "$DEVICE" =~ ^/dev/ ]] || die "Device must be under /dev (got: $DEVICE)"

    # disallow partitions (e.g. /dev/sdb1, /dev/nvme0n1p1)
    if [[ "$DEVICE" =~ [0-9]$ ]] || [[ "$DEVICE" =~ p[0-9]+$ ]]; then
      die "Refusing to run on a partition. Provide the whole-disk device like /dev/sdb (got: $DEVICE)"
    fi
  fi

  case "$BB_PATTERNS" in
    default|single) ;;
    *) die "--patterns must be 'default' or 'single' (got: $BB_PATTERNS)";;
  esac
}

device_has_mounts() {
  # Any mounted partitions on the device?
  local m
  m="$(lsblk -nr -o MOUNTPOINT "$DEVICE" 2>/dev/null | awk 'NF{print}' | head -n 1 || true)"
  [[ -n "$m" ]]
}

get_smart_field() {
  # $1 = regex (first match), prints value after colon
  local re="$1"
  if [[ "${PLAN:-0}" == "1" ]]; then
    return 0
  fi
  smartctl "${SMARTCTL_ARGS[@]}" -i "$DEVICE" 2>/dev/null | sed -n "s/.*$re[[:space:]]*:[[:space:]]*//p" | head -n 1
}

get_model_serial() {
  local model serial
  model="$(get_smart_field 'Device Model|Model Family|Model Number|Product')"
  serial="$(get_smart_field 'Serial Number')"
  [[ -n "$model" ]] || model="$(lsblk -dn -o MODEL "$DEVICE" 2>/dev/null | head -n1 | tr -d '\r')"
  [[ -n "$serial" ]] || serial="$(lsblk -dn -o SERIAL "$DEVICE" 2>/dev/null | head -n1 | tr -d '\r')"
  [[ -n "$model" ]] || model="UNKNOWN_MODEL"
  [[ -n "$serial" ]] || serial="UNKNOWN_SERIAL"
  # sanitize for path
  model="${model// /_}"
  model="$(echo "$model" | tr -cd 'A-Za-z0-9._-')"
  serial="$(echo "$serial" | tr -cd 'A-Za-z0-9._-')"
  echo "$model" "$serial"
}

is_rotational() {
  local rota
  rota="$(lsblk -dn -o ROTA "$DEVICE" 2>/dev/null | head -n1 || true)"
  [[ "$rota" == "1" ]]
}

choose_badblocks_block_size() {
  # Some badblocks builds effectively cap the number of addressable blocks.
  # For very large disks, small block sizes (e.g. 4096) can overflow and fail with:
  #   "Value too large to be stored in data type"
  #
  # We pick the smallest power-of-two multiple of the requested BB_BLOCK_SIZE
  # that keeps the block count under a conservative 32-bit signed max.
  #
  # You can still override by setting BB_BLOCK_SIZE explicitly; this function only increases it.
  local size_bytes
  size_bytes="$(blockdev --getsize64 "$DEVICE" 2>/dev/null || echo 0)"
  [[ "$size_bytes" -gt 0 ]] || { echo "$BB_BLOCK_SIZE"; return 0; }

  local max_blocks=2147483647  # conservative
  local bs="$BB_BLOCK_SIZE"

  # integer ceil(size/bs) without floating point:
  local blocks=$(( (size_bytes + bs - 1) / bs ))
  while [[ "$blocks" -gt "$max_blocks" ]]; do
    bs=$((bs * 2))
    blocks=$(( (size_bytes + bs - 1) / bs ))
    if [[ "$bs" -gt 1048576 ]]; then
      die "Refusing: required badblocks block size exceeded 1MiB to avoid overflow. (disk too large?)"
    fi
  done

  echo "$bs"
}

json_escape() {
  python3 - <<'PY' "$1"
import json,sys
print(json.dumps(sys.argv[1]))
PY
}

write_status() {
  local phase="$1" msg="$2" ok="${3:-1}"
  local ts; ts="$(date -Is)"

  mkdir -p "$STATUS_DIR/$ID"
  local status_file="$STATUS_DIR/$ID/status.json"
  local status_txt="$STATUS_DIR/$ID/status.txt"

  cat >"$status_file" <<EOF
{
  "id": $(json_escape "$ID"),
  "device": $(json_escape "$DEVICE"),
  "phase": $(json_escape "$phase"),
  "ok": $ok,
  "message": $(json_escape "$msg"),
  "timestamp": $(json_escape "$ts")
}
EOF

  # Human-readable status (easy to glance at)
  if [[ "$ok" == "1" ]]; then
    printf '%s | OK   | %s | %s\n' "$ts" "$phase" "$msg" >"$status_txt"
  else
    printf '%s | FAIL | %s | %s\n' "$ts" "$phase" "$msg" >"$status_txt"
  fi

  if [[ -n "${REPO_DIR:-}" ]]; then
    mkdir -p "$REPO_DIR/status/$ID"
    cp -f "$status_file" "$REPO_DIR/status/$ID/status.json"
    cp -f "$status_txt"  "$REPO_DIR/status/$ID/status.txt"
  fi

  if [[ "${AUTO_PUSH:-0}" == "1" ]]; then
    git_checkpoint "$phase" "$msg" || true
  fi
}

git_checkpoint() {
  [[ -n "${REPO_DIR:-}" ]] || return 0
  [[ -d "$REPO_DIR/.git" ]] || return 0
  [[ -n "${GIT_REMOTE:-}" ]] || return 0

  ( cd "$REPO_DIR"
    # Retry loop to handle multiple drives pushing to the same repo
    local retry=0
    local max_retries=10
    while [ $retry -lt $max_retries ]; do
      # Check if git is locked
      if [ -f .git/index.lock ]; then
        sleep $((RANDOM % 5 + 2))
        retry=$((retry + 1))
        continue
      fi

      git add "status/$ID/status.json" "status/$ID/status.txt" >/dev/null 2>&1 || true
      if ! git status --porcelain | grep -q .; then
        return 0 # Nothing to commit
      fi

      if git commit -m "burnin($ID): $1" >/dev/null 2>&1; then
        if git push "$GIT_REMOTE" "HEAD:$GIT_BRANCH" >/dev/null 2>&1; then
          return 0 # Success
        fi
      fi
      
      retry=$((retry + 1))
      sleep $((RANDOM % 10 + 5))
    done
    note "Warning: Failed to push git checkpoint for $ID after $max_retries attempts (lock contention?)"
  )
}

estimate_eta() {
  # Estimate total time based on:
  # - quick sequential read sample throughput
  # - number of full passes (badblocks patterns)
  #
  # Note: This is a rough estimate; USB bridges, SMR behavior, and thermal throttling can shift it.
  local sample_bytes sample_mib="$ETA_SAMPLE_MIB"
  local skip_gib="$ETA_SAMPLE_OFFSET_GIB"
  local bs=$((1024*1024)) # 1 MiB

  sample_bytes=$((sample_mib * bs))

  local size_bytes
  size_bytes="$(blockdev --getsize64 "$DEVICE" 2>/dev/null || echo 0)"
  [[ "$size_bytes" -gt 0 ]] || { echo "ETA: unknown (could not read device size)"; return 0; }

  local mib_per_s
  if [[ "${PLAN:-0}" == "1" ]]; then
    # PLAN mode: don't touch the disk (no dd sample).
    # Use a conservative default so the user has a ballpark.
    mib_per_s=200
    echo "Estimated sequential read throughput: ~${mib_per_s} MiB/s (PLAN mode: assumed; no disk I/O sample)"
  else
    # time dd read sample
    local start end elapsed
    start="$(date +%s)"
    # read sample from offset to avoid outer tracks and bridge cache effects
    dd if="$DEVICE" of=/dev/null bs=$bs count="$sample_mib" skip=$((skip_gib*1024)) iflag=direct status=none 2>/dev/null || true
    end="$(date +%s)"
    elapsed=$((end - start))
    [[ "$elapsed" -gt 0 ]] || elapsed=1
    mib_per_s=$((sample_mib / elapsed))
    [[ "$mib_per_s" -gt 0 ]] || mib_per_s=1
    echo "Estimated sequential read throughput: ~${mib_per_s} MiB/s (sampled ${sample_mib} MiB)"
  fi

  # full-disk pass time (seconds): size_bytes / (mib_per_s * MiB)
  local pass_s
  pass_s=$(( size_bytes / (mib_per_s * bs) ))

  local passes=0
  if [[ "$BADBLOCKS" == "1" ]] && is_rotational; then
    if [[ "$BB_PATTERNS" == "default" ]]; then
      # badblocks -w: write+read per pattern; 4 patterns => 8 passes
      passes=8
    else
      # single pattern => 2 passes (write+read)
      passes=2
    fi
  fi

  local total_s="$pass_s"
  if [[ "$passes" -gt 0 ]]; then
    total_s=$((pass_s * passes))
  else
    total_s=0
  fi

  echo "Estimated full-disk pass time: ~${pass_s}s (~$((pass_s/3600))h)"
  if [[ "$passes" -gt 0 ]]; then
    echo "Estimated badblocks time (${BB_PATTERNS}, ${passes} passes): ~${total_s}s (~$((total_s/3600))h)"
  else
    echo "Badblocks: disabled or non-rotational; no badblocks ETA."
  fi
}

smart_run_and_wait() {
  local test="$1" label="$2"
  write_status "smart_${test}_start" "Starting SMART ${label} test"
  log_note "Starting SMART ${label} test: smartctl ${SMARTCTL_ARGS[*]} -t $test $DEVICE"

  if [[ "${ABORT_SMART:-0}" == "1" ]]; then
    log_note "ABORT_SMART=1: aborting any in-progress SMART self-test before starting (${label})"
    smartctl "${SMARTCTL_ARGS[@]}" -X "$DEVICE" >/dev/null 2>&1 || true
    sleep 2
  fi

  # Start test and capture output so we can detect "can't start" conditions.
  local start_out
  start_out="$(smartctl "${SMARTCTL_ARGS[@]}" -t "$test" "$DEVICE" 2>&1 | tee -a "$LOG_FILE" || true)"
  if echo "$start_out" | grep -qi "Can't start self-test without aborting current test"; then
    if [[ "${ABORT_SMART:-0}" == "1" ]]; then
      log_note "A SMART test is already running; aborting and retrying start once..."
      smartctl "${SMARTCTL_ARGS[@]}" -X "$DEVICE" >/dev/null 2>&1 || true
      sleep 2
      start_out="$(smartctl "${SMARTCTL_ARGS[@]}" -t "$test" "$DEVICE" 2>&1 | tee -a "$LOG_FILE" || true)"
    fi
    if echo "$start_out" | grep -qi "Can't start self-test without aborting current test"; then
      write_status "smart_${test}_failed" "SMART ${label} could not start (another test already running)" 0
      die "SMART ${label} could not start because another test is running. Abort with: smartctl -X $DEVICE, then retry (or add --abort-smart)."
    fi
  fi

  # Poll until it finishes. For long tests we must be fail-closed: do not proceed unless completion is confirmed.
  local max_wait=$((60*60*72)) # 72h cap
  local waited=0
  local poll_interval=300 # 5 minutes
  local initial_grace=60  # avoid immediate polling; some USB bridges behave badly under SMART queries
  local last_progress=""

  local test_pattern=""
  case "$test" in
    short) test_pattern="Short offline";;
    long|extended) test_pattern="Extended offline";;
    conveyance) test_pattern="Conveyance";;
  esac

  # Long tests on USB are especially sensitive; poll less frequently.
  if is_usb_transport && [[ "$test" != "short" ]]; then
    poll_interval=1800
  fi

  sleep "$initial_grace"
  waited=$((waited + initial_grace))

  while [[ "$waited" -lt "$max_wait" ]]; do
    local status_out selftest_log test_result

    status_out="$(smartctl "${SMARTCTL_ARGS[@]}" -c "$DEVICE" 2>/dev/null | tr -d '\r' || true)"
    [[ -n "$status_out" ]] && echo "$status_out" >>"$LOG_FILE"

    selftest_log="$(smartctl "${SMARTCTL_ARGS[@]}" -l selftest "$DEVICE" 2>/dev/null | tr -d '\r' || true)"
    [[ -n "$selftest_log" ]] && echo "$selftest_log" >>"$LOG_FILE"

    # If we can't read the selftest log (USB/SAT hiccup), keep waiting; don't proceed to badblocks.
    if [[ -z "$selftest_log" ]]; then
      log_note "WARNING: smartctl -l selftest returned empty; retrying..."
      sleep "$poll_interval"
      waited=$((waited + poll_interval))
      continue
    fi

    test_result="$(echo "$selftest_log" | grep -i "$test_pattern" | head -1 || true)"

    # Completed
    if echo "$test_result" | grep -qi "Completed without error"; then
      break
    fi

    # In progress (prefer selftest log; use -c output only for progress percentage)
    if echo "$test_result" | grep -qi "Self-test routine in progress"; then
      local progress
      progress="$(echo "$status_out" | grep -oE "[0-9]+% of test remaining" | head -1 || true)"
      if [[ -n "$progress" ]] && [[ "$progress" != "$last_progress" ]]; then
        log_note "SMART ${label} test progress: $progress"
        last_progress="$progress"
      fi
      sleep "$poll_interval"
      waited=$((waited + poll_interval))
      continue
    fi

    # Aborted/failed (do NOT proceed)
    if echo "$test_result" | grep -qiE "Aborted|Interrupted|Fatal|error"; then
      write_status "smart_${test}_failed" "SMART ${label} test aborted/failed: $test_result" 0
      die "SMART ${label} test aborted/failed: $test_result"
    fi

    # Unknown state, keep waiting.
    sleep "$poll_interval"
    waited=$((waited + poll_interval))
  done

  if [[ "$waited" -ge "$max_wait" ]]; then
    write_status "smart_${test}_failed" "SMART ${label} timed out after ${max_wait}s" 0
    die "SMART ${label} timed out after ${max_wait}s"
  fi

  smartctl "${SMARTCTL_ARGS[@]}" -a "$DEVICE" 2>/dev/null | tee -a "$LOG_FILE" >/dev/null || true
  write_status "smart_${test}_done" "SMART ${label} test completed"
}

run_badblocks() {
  write_status "badblocks_start" "Starting badblocks destructive test (THIS ERASES DATA)"
  note "Running badblocks (DESTRUCTIVE): $DEVICE"

  local bb_file="$LOG_DIR/burnin-${DEV_TAG}-${ID}-$(date +%Y-%m-%d-%s).bb"
  local effective_bs
  effective_bs="$(choose_badblocks_block_size)"
  if [[ "$effective_bs" != "$BB_BLOCK_SIZE" ]]; then
    note "Adjusted badblocks block size from $BB_BLOCK_SIZE to $effective_bs to avoid large-disk overflow."
    echo "Adjusted badblocks block size from $BB_BLOCK_SIZE to $effective_bs to avoid large-disk overflow." | tee -a "$LOG_FILE"
  fi

  local bb_cmd=(badblocks -wsv -b "$effective_bs" -c "$BB_BATCH_BLOCKS" -o "$bb_file")

  if [[ "$BB_PATTERNS" == "single" ]]; then
    # One-pass pattern (0xaa). This is faster but less thorough than default multi-pattern.
    bb_cmd+=( -t 0xaa )
  fi

  bb_cmd+=( "$DEVICE" )

  echo "badblocks output file: $bb_file" | tee -a "$LOG_FILE"
  printf 'COMMAND: %q ' "${bb_cmd[@]}" | tee -a "$LOG_FILE"; echo | tee -a "$LOG_FILE"

  if [[ "$RUN" != "1" ]]; then
    note "DRY RUN: would execute badblocks now"
    write_status "badblocks_skipped" "DRY RUN: badblocks not executed" 1
    return 0
  fi

  # badblocks can take days; tee to log
  if "${bb_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
    write_status "badblocks_done" "badblocks completed successfully"
  else
    write_status "badblocks_failed" "badblocks reported errors (see log + .bb file)" 0
    die "badblocks failed. See: $LOG_FILE and $bb_file"
  fi
}

run_self_test() {
  # Self-test intentionally does not require root and does not touch any disks.
  need_cmd date
  # python3 is optional for normal runs, but required for JSON escaping here.
  need_cmd python3

  mkdir -p "$STATUS_DIR"

  local ts model serial
  ts="$(date +%Y-%m-%d-%s)"
  model="SELFTEST"
  serial="$ts"
  ID="${model}_${serial}"
  DEVICE="(self-test)"
  DEV_TAG="selftest"
  LOG_FILE="$LOG_DIR/burnin-${ID}.log"

  note "SELF-TEST mode (no disks touched)"
  note "Status dir: $STATUS_DIR"
  if [[ -n "${REPO_DIR:-}" ]]; then
    note "Repo dir: $REPO_DIR"
  fi
  if [[ "${AUTO_PUSH:-0}" == "1" ]]; then
    note "AUTO_PUSH=1: will attempt commit+push (requires git + remote access)"
  else
    note "AUTO_PUSH=0: will NOT push (set AUTO_PUSH=1 to test git alerts)"
  fi

  write_status "selftest_start" "Self-test started"
  sleep 1
  write_status "selftest_checkpoint" "Self-test checkpoint (if you see this as a push-email, alerts are wired)"
  sleep 1
  write_status "selftest_complete" "Self-test completed successfully" 1

  note "SELF-TEST complete. Status file:"
  echo "  $STATUS_DIR/$ID/status.json"
}

run_parallel() {
  need_cmd tmux
  if [[ "${PLAN:-0}" == "1" ]]; then
    note "PLAN mode with --multi: not launching tmux; printing per-device plans."
    for dev in $MULTI_DEVICES; do
      "$0" --device "$dev" --plan --patterns "$BB_PATTERNS"
      echo
    done
    return 0
  fi

  local session="burnin_$(date +%s)"
  note "Launching parallel tests for: $MULTI_DEVICES"
  note "Tmux session: $session"

  # Validate all devices first
  for dev in $MULTI_DEVICES; do
    [[ -n "$dev" ]] || continue
    [[ -b "$dev" ]] || die "Not a block device: $dev"
    [[ "$dev" =~ ^/dev/ ]] || die "Device must be under /dev (got: $dev)"
    # disallow partitions
    if [[ "$dev" =~ [0-9]$ ]] || [[ "$dev" =~ p[0-9]+$ ]]; then
      die "Refusing to run on a partition. Provide the whole-disk device like /dev/sdb (got: $dev)"
    fi
  done

  # Pass all existing env vars into the script
  local env_str=""
  [[ -n "${REPO_DIR:-}" ]] && env_str+="REPO_DIR='$REPO_DIR' "
  [[ -n "${AUTO_PUSH:-0}" ]] && env_str+="AUTO_PUSH='$AUTO_PUSH' "
  [[ -n "${GIT_REMOTE:-}" ]] && env_str+="GIT_REMOTE='$GIT_REMOTE' "
  [[ -n "${GIT_BRANCH:-}" ]] && env_str+="GIT_BRANCH='$GIT_BRANCH' "
  [[ -n "${BADBLOCKS:-1}" ]] && env_str+="BADBLOCKS='$BADBLOCKS' "
  [[ -n "${BB_BLOCK_SIZE:-}" ]] && env_str+="BB_BLOCK_SIZE='$BB_BLOCK_SIZE' "

  local first=1
  for dev in $MULTI_DEVICES; do
    local cmd="sudo $env_str $0 --device $dev"
    [[ "${ABORT_SMART:-0}" == "1" ]] && cmd+=" --abort-smart"
    [[ "$RUN" == "1" ]] && cmd+=" --run"
    [[ "$BB_PATTERNS" != "default" ]] && cmd+=" --patterns $BB_PATTERNS"

    if [[ $first -eq 1 ]]; then
      tmux new-session -d -s "$session" -n "$(basename "$dev")" "$cmd; read -p 'Press enter to close window' -r"
      first=0
    else
      tmux new-window -t "$session" -n "$(basename "$dev")" "$cmd; read -p 'Press enter to close window' -r"
    fi
  done

  note "Parallel sessions started. Attach with: sudo tmux attach -t $session"
  note "You can see live progress in each tmux window."
}

main() {
  parse_args "$@"

  if [[ -n "$MULTI_DEVICES" ]]; then
    run_parallel
    return 0
  fi

  if [[ "$SELF_TEST" == "1" ]]; then
    run_self_test
    return 0
  fi

  if [[ "${PLAN:-0}" == "1" ]]; then
    need_cmd lsblk
    need_cmd blockdev
    need_cmd awk
    need_cmd sed
    need_cmd grep
    need_cmd date

    if device_has_mounts; then
      lsblk "$DEVICE" >&2 || true
      die "Refusing: $DEVICE has mounted partitions. Unmount first."
    fi

    read -r MODEL SERIAL < <(get_model_serial)
    ID="${MODEL}_${SERIAL}"
    DEV_TAG="$(basename "$DEVICE")"

    note "PLAN mode (no SMART tests, no badblocks)."
    note "Device: $DEVICE"
    note "Model/Serial: $MODEL / $SERIAL"
    note "Would run: SMART short -> (optional conveyance) -> SMART long"
    if is_rotational && [[ "$BADBLOCKS" == "1" ]]; then
      note "Would run (only with --run): badblocks (${BB_PATTERNS}) + post-SMART tests"
    else
      note "Would skip badblocks (non-rotational or disabled)."
    fi
    note "ETA estimation (rough):"
    estimate_eta
    return 0
  fi

  require_root
  need_cmd smartctl
  need_cmd lsblk
  need_cmd badblocks
  need_cmd blockdev
  need_cmd dd
  need_cmd awk
  need_cmd sed
  need_cmd grep
  need_cmd date
  need_cmd python3

  if device_has_mounts; then
    lsblk "$DEVICE" >&2 || true
    die "Refusing: $DEVICE has mounted partitions. Unmount first."
  fi

  mkdir -p "$LOG_DIR" "$STATUS_DIR"

  detect_smartctl_args

  read -r MODEL SERIAL < <(get_model_serial)
  ID="${MODEL}_${SERIAL}"
  DEV_TAG="$(basename "$DEVICE")"
  DEV_TAG="$(echo "$DEV_TAG" | tr -cd 'A-Za-z0-9._-')"
  [[ -n "$DEV_TAG" ]] || DEV_TAG="dev"
  LOG_FILE="$LOG_DIR/burnin-${DEV_TAG}-${ID}-$(date +%Y-%m-%d-%s).log"

  note "Device: $DEVICE"
  note "Model/Serial: $MODEL / $SERIAL"
  note "Log: $LOG_FILE"
  note "Status: $STATUS_DIR/$ID/status.json"
  if [[ "$RUN" != "1" ]]; then
    note "Mode: SMART-only (non-destructive). SMART tests will run; badblocks will NOT run unless you add --run."
    note "If you want plan-only (no SMART tests), add --plan."
  else
    note "Mode: RUN (DESTRUCTIVE). Data on $DEVICE WILL be erased."
  fi

  smartctl "${SMARTCTL_ARGS[@]}" -i "$DEVICE" 2>/dev/null | tee -a "$LOG_FILE" >/dev/null || true
  smartctl "${SMARTCTL_ARGS[@]}" -a "$DEVICE" 2>/dev/null | tee -a "$LOG_FILE" >/dev/null || true

  note "ETA estimation (rough):"
  estimate_eta | tee -a "$LOG_FILE"

  write_status "start" "Burn-in started"

  smart_run_and_wait short "short"
  if [[ "$SMART_CONVEYANCE" == "1" ]]; then
    smart_run_and_wait conveyance "conveyance"
  fi
  smart_run_and_wait long "extended/long"

  if is_rotational && [[ "$BADBLOCKS" == "1" ]]; then
    run_badblocks
    smart_run_and_wait short "short (post-badblocks)"
    if [[ "$SMART_CONVEYANCE" == "1" ]]; then
      smart_run_and_wait conveyance "conveyance (post-badblocks)"
    fi
    smart_run_and_wait long "extended/long (post-badblocks)"
  else
    note "Skipping badblocks (non-rotational or disabled)."
    write_status "badblocks_skipped" "badblocks skipped (non-rotational or disabled)" 1
  fi

  write_status "complete" "Burn-in completed successfully" 1
  note "DONE. Log: $LOG_FILE"
}

main "$@"


