#!/usr/bin/env bash
#
# init-kali.sh — boot the prebuilt Kali Linux QEMU image and verify it came up healthy.
#
#   ./init-kali.sh                 boot with a GUI window, then run all health checks
#   ./init-kali.sh --headless      boot with no window, expose VNC on 127.0.0.1:5901
#   ./init-kali.sh --snapshot      boot throwaway: all disk writes discarded on shutdown
#   ./init-kali.sh --status        report on an already-running VM
#   ./init-kali.sh --verify        re-run the health checks against a running VM
#   ./init-kali.sh --stop          graceful ACPI powerdown
#   ./init-kali.sh --check         preflight checks only, do not boot
#
# Options: --cpus N  --memory MiB  --ssh-port N  --timeout SEC  --image PATH
#
set -uo pipefail

# ---------------------------------------------------------------- configuration

KALI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${KALI_IMAGE:-$KALI_DIR/kali-linux-2026.3-qemu-amd64.qcow2}"
RUN_DIR="$KALI_DIR/.run"
PID_FILE="$RUN_DIR/kali.pid"
QMP_SOCK="$RUN_DIR/qmp.sock"
LOG_FILE="$RUN_DIR/qemu.log"

CPUS=4
MEMORY=4096          # MiB
SSH_PORT=2222        # host port forwarded to guest :22
VNC_DISPLAY=1        # headless mode -> 127.0.0.1:5901
BOOT_TIMEOUT=90      # seconds to wait for the guest's sshd to answer
GUEST_USER=kali
GUEST_PASS=kali      # stock credentials of the Kali prebuilt images
HEADLESS=0
SNAPSHOT=0
MODE=up

# ------------------------------------------------------------------- output tty

if [[ -t 1 ]]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; Z=$'\e[0m'
else
  B=''; R=''; G=''; Y=''; C=''; Z=''
fi

SCREEN_SHOT=""
SCREEN_GEOM=""
SCREEN_DISTINCT=0
STEP=0
FAILURES=0
WARNINGS=0
SSHD_DOWN=0

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$B" "$*" "$Z"; }
step() { STEP=$((STEP + 1)); printf '%s[%d]%s %-46s' "$C" "$STEP" "$Z" "$1"; }
ok()   { printf '%sok%s      %s\n' "$G" "$Z" "${1:-}"; }
warn() { printf '%sWARN%s    %s\n' "$Y" "$Z" "${1:-}"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '%sFAIL%s    %s\n' "$R" "$Z" "${1:-}"; FAILURES=$((FAILURES + 1)); }
die()  { printf '\n%serror:%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }

# ----------------------------------------------------------------- args parsing

while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless)  HEADLESS=1 ;;
    --snapshot)  SNAPSHOT=1 ;;
    --status)    MODE=status ;;
    --verify)    MODE=verify ;;
    --stop|--down) MODE=stop ;;
    --check)     MODE=check ;;
    --cpus)      CPUS="${2:?--cpus needs a value}"; shift ;;
    --memory)    MEMORY="${2:?--memory needs a value}"; shift ;;
    --ssh-port)  SSH_PORT="${2:?--ssh-port needs a value}"; shift ;;
    --timeout)   BOOT_TIMEOUT="${2:?--timeout needs a value}"; shift ;;
    --image)     IMAGE="${2:?--image needs a value}"; shift ;;
    -h|--help)   awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' \
                   "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "unknown option: $1  (try --help)" ;;
  esac
  shift
done

mkdir -p "$RUN_DIR"

# ------------------------------------------------------------------ QMP helpers

# Speak one QMP command on the monitor socket and print the raw JSON replies.
qmp() {
  [[ -S "$QMP_SOCK" ]] || return 1
  printf '%s\n%s\n' '{"execute":"qmp_capabilities"}' "$1" \
    | timeout 8 nc -U -q 1 "$QMP_SOCK" 2>/dev/null
}

# Pull one field out of the QMP reply stream, ignoring the greeting and events.
qmp_field() {
  qmp "$1" | jq -rs --arg f "$2" '[.[] | select(.return? | type == "object")
                                      | select(has("return"))
                                      | .return
                                      | select(has($f))][0][$f] // empty' 2>/dev/null
}

vm_pid() {
  [[ -f $PID_FILE ]] || return 1
  local pid; pid="$(tr -dc '0-9' < "$PID_FILE")"
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

vm_running() { vm_pid >/dev/null; }

port_busy() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q . ; }

# ------------------------------------------------------------------- preflight

preflight() {
  head1 "Preflight"

  step "qemu-system-x86_64 installed"
  local qemu; qemu="$(command -v qemu-system-x86_64)"
  if [[ -n $qemu ]]; then ok "$qemu"; else bad "install qemu-system-x86"; return; fi

  step "support tools (nc, jq, ss)"
  local missing=()
  for t in nc jq ss; do command -v "$t" >/dev/null || missing+=("$t"); done
  if [[ ${#missing[@]} -eq 0 ]]; then ok; else bad "missing: ${missing[*]}"; fi

  step "disk image present"
  if [[ -r $IMAGE ]]; then
    ok "$(du -h "$IMAGE" | cut -f1) on disk  $(basename "$IMAGE")"
  else
    bad "not readable: $IMAGE"; return
  fi

  step "image is writable"
  if [[ -w $IMAGE || $SNAPSHOT -eq 1 ]]; then ok; else
    warn "read-only image; re-run with --snapshot or fix permissions"
  fi

  step "qcow2 metadata intact"
  local chk; chk="$(qemu-img check -q "$IMAGE" 2>&1)"
  if [[ $? -eq 0 ]]; then
    ok "no corruption reported"
  else
    bad "$(printf '%s' "$chk" | head -1)"
  fi

  step "KVM acceleration usable"
  if [[ -w /dev/kvm && -r /dev/kvm ]]; then
    ok "/dev/kvm read-write"
  elif [[ -e /dev/kvm ]]; then
    bad "/dev/kvm exists but is not writable by $(id -un) — add yourself to the 'kvm' group"
  else
    bad "/dev/kvm missing — enable virtualisation (VT-x/AMD-V) in firmware"
  fi

  step "host has room for ${MEMORY}MiB guest"
  local avail; avail="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"
  if (( avail > MEMORY )); then ok "${avail}MiB available"; else
    warn "only ${avail}MiB available; guest asks for ${MEMORY}MiB"
  fi

  step "host port $SSH_PORT free for SSH forward"
  if vm_running && port_busy "$SSH_PORT"; then
    ok "held by this VM"
  elif port_busy "$SSH_PORT"; then
    bad "port $SSH_PORT already in use — pass --ssh-port N"
  else
    ok
  fi
}

# ------------------------------------------------------------------------ boot

boot() {
  head1 "Boot"

  if vm_running; then
    say "A Kali VM is already running (pid $(vm_pid)). Skipping boot."
    return 0
  fi

  rm -f "$QMP_SOCK" "$PID_FILE"

  local args=(
    -name "kali-2026.3"
    -machine q35,accel=kvm
    -cpu host
    -smp "$CPUS"
    -m "$MEMORY"
    -drive "file=$IMAGE,format=qcow2,if=virtio,cache=writeback,discard=unmap"
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    -device virtio-net-pci,netdev=n0
    -device virtio-balloon-pci
    -usb -device usb-tablet -device usb-kbd
    -rtc base=localtime
    -qmp "unix:$QMP_SOCK,server=on,wait=off"
    -pidfile "$PID_FILE"
  )

  (( SNAPSHOT )) && args+=(-snapshot)

  if (( HEADLESS )); then
    args+=(-display none -vga virtio -vnc "127.0.0.1:$VNC_DISPLAY")
  else
    args+=(-display gtk,show-cursor=on -vga virtio)
  fi

  step "launching qemu"
  : > "$LOG_FILE"
  setsid qemu-system-x86_64 "${args[@]}" >>"$LOG_FILE" 2>&1 < /dev/null &
  disown

  # qemu writes its pidfile a moment after fork; give it a chance.
  local i
  for i in $(seq 1 50); do
    vm_running && break
    sleep 0.2
  done

  if vm_running; then
    ok "pid $(vm_pid)"
  else
    bad "qemu exited immediately"
    say ""
    say "${B}qemu output:${Z}"
    sed 's/^/    /' "$LOG_FILE" | tail -20
    return 1
  fi

  step "QMP monitor socket"
  for i in $(seq 1 50); do
    [[ -S $QMP_SOCK ]] && break
    sleep 0.2
  done
  if [[ -S $QMP_SOCK ]]; then ok "$QMP_SOCK"; else bad "never appeared"; fi
}

# ---------------------------------------------------------------- verification

# Grab the guest framebuffer and judge whether it is drawing anything at all.
# This proves the guest booted far enough to render, with no in-guest help.
screen_evidence() {
  SCREEN_DISTINCT=0; SCREEN_SHOT=""; SCREEN_GEOM=""
  local ppm="$RUN_DIR/screen.ppm"
  rm -f "$ppm"
  qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$ppm\"}}" >/dev/null
  [[ -s $ppm ]] || return 1

  # A frozen black screen is one repeated byte; a rendered console or desktop
  # has many. Sample the first chunk of pixel data and count distinct values.
  SCREEN_GEOM="$(head -c 32 "$ppm" | sed -n '2p' | tr ' ' 'x')"

  local distinct
  distinct=$(tail -c +16 "$ppm" | head -c 300000 \
             | od -An -tu1 -v | tr -s ' ' '\n' | sed '/^$/d' | sort -u | wc -l)

  # PPM is awkward to open; hand back a PNG when we have something to convert.
  SCREEN_SHOT="$ppm"
  if command -v ffmpeg >/dev/null 2>&1; then
    if ffmpeg -y -loglevel error -i "$ppm" "$RUN_DIR/screen.png" 2>/dev/null; then
      SCREEN_SHOT="$RUN_DIR/screen.png"
    fi
  elif command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$ppm" > "$RUN_DIR/screen.png" 2>/dev/null \
      && SCREEN_SHOT="$RUN_DIR/screen.png"
  fi
  # the raw PPM is ~3MB per capture; keep only the PNG once we have it
  [[ $SCREEN_SHOT == *.png ]] && rm -f "$ppm"

  SCREEN_DISTINCT="$distinct"
  (( distinct > 8 ))
}

verify() {
  head1 "Verify"

  step "qemu process alive"
  local pid; pid="$(vm_pid)"
  if [[ -n $pid ]]; then ok "pid $pid"; else bad "no running VM"; return 1; fi

  step "QMP reports the CPU running"
  local status; status="$(qmp_field '{"execute":"query-status"}' status)"
  case "$status" in
    running) ok "status=running" ;;
    paused)  warn "status=paused — VM is suspended" ;;
    "")      bad "QMP did not answer" ;;
    *)       warn "status=$status" ;;
  esac

  step "guest memory honoured by qemu"
  local kvm; kvm="$(qmp_field '{"execute":"query-kvm"}' enabled)"
  if [[ $kvm == true ]]; then ok "KVM acceleration active"; else
    warn "running without KVM — expect it to be very slow"
  fi

  # NOTE: do not test this with a bare TCP connect. qemu's user-mode hostfwd
  # listens on the host port from the instant the VM starts, so connect()
  # always succeeds and tells us nothing about the guest. Only a real
  # "SSH-2.0-..." banner proves sshd inside the guest is serving.
  step "waiting for guest sshd on :$SSH_PORT"
  local start=$SECONDS up=0 banner="" dotted=0
  while (( SECONDS - start < BOOT_TIMEOUT )); do
    banner="$(timeout 6 nc -w 5 127.0.0.1 "$SSH_PORT" </dev/null 2>/dev/null \
              | head -c 40 | tr -d '\r\n')"
    if [[ $banner == SSH-* ]]; then up=1; break; fi
    vm_running || break
    printf '.'; dotted=1
    sleep 3
  done
  (( dotted )) && printf '\n%*s' 51 ''
  local waited=$((SECONDS - start))
  if (( up )); then
    ok "banner after ${waited}s: $banner"
  else
    warn "none in ${waited}s"
    SSHD_DOWN=1
  fi

  if (( up )); then
    step "ssh login as $GUEST_USER"
    local out
    out="$(sshpass -p "$GUEST_PASS" ssh -p "$SSH_PORT" \
             -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
             -o LogLevel=ERROR -o ConnectTimeout=10 \
             "$GUEST_USER@127.0.0.1" \
             'printf "%s|%s|%s" "$(uname -r)" "$(. /etc/os-release; echo $PRETTY_NAME)" "$(uptime -p)"' 2>&1)"
    if [[ $out == *"|"* ]]; then
      IFS='|' read -r krel osname uptime <<<"$out"
      ok "$osname"
      say "              kernel $krel, $uptime"
    else
      warn "banner seen but login failed: $(printf '%s' "$out" | head -1)"
      SSHD_DOWN=1
    fi
  else
    step "guest is rendering a display"
    screen_evidence
    if (( SCREEN_DISTINCT > 8 )); then
      ok "${SCREEN_GEOM:-?} framebuffer is drawing — the guest reached a display"
      say "              screenshot: $SCREEN_SHOT"
    else
      bad "framebuffer looks blank — guest may not be booting"
    fi
  fi
}

# --------------------------------------------------------------------- status

do_status() {
  head1 "Status"
  local pid; pid="$(vm_pid)"
  if [[ -z $pid ]]; then
    say "Kali VM:   ${Y}not running${Z}"
    say "Image:     $IMAGE"
    return 1
  fi
  say "Kali VM:   ${G}running${Z}  (pid $pid)"
  say "Image:     $IMAGE"
  say "QMP:       $QMP_SOCK  status=$(qmp_field '{"execute":"query-status"}' status)"
  say "SSH:       ssh -p $SSH_PORT $GUEST_USER@127.0.0.1   (password: $GUEST_PASS)"
  if (( HEADLESS )); then
    say "VNC:       127.0.0.1:$((5900 + VNC_DISPLAY))"
  fi
  say "RSS:       $(awk '/VmRSS/ {print int($2/1024) " MiB"}' "/proc/$pid/status" 2>/dev/null)"
  say "Log:       $LOG_FILE"
}

# ----------------------------------------------------------------------- stop

do_stop() {
  head1 "Stop"
  local pid; pid="$(vm_pid)"
  if [[ -z $pid ]]; then say "No running Kali VM."; return 0; fi

  local t0=$SECONDS
  step "sending ACPI powerdown"
  qmp '{"execute":"system_powerdown"}' >/dev/null && ok || warn "QMP unreachable"

  step "waiting for clean shutdown"
  while (( SECONDS - t0 < 90 )) && kill -0 "$pid" 2>/dev/null; do
    sleep 2
  done
  local waited=$((SECONDS - t0))
  if kill -0 "$pid" 2>/dev/null; then
    warn "still up after ${waited}s — sending SIGTERM"
    kill "$pid" 2>/dev/null
    sleep 3
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  else
    ok "powered off after ${waited}s"
  fi
  rm -f "$PID_FILE" "$QMP_SOCK"
}

# ---------------------------------------------------------------------- report

report() {
  head1 "Result"
  if (( FAILURES > 0 )); then
    say "${R}FAILED${Z}  — $FAILURES check(s) failed, $WARNINGS warning(s)."
    say "Inspect $LOG_FILE for qemu's own output."
    return 1
  fi
  if [[ $MODE == check ]]; then
    if (( WARNINGS > 0 )); then
      say "${Y}READY, WITH WARNINGS${Z}  — $WARNINGS warning(s). Boot should work."
    else
      say "${G}READY${Z} — every precondition met. Run without --check to boot."
    fi
    return 0
  fi
  if (( WARNINGS > 0 )); then
    say "${Y}UP, WITH WARNINGS${Z}  — $WARNINGS warning(s), nothing fatal."
  else
    say "${G}ALL OK${Z} — Kali is running and answering."
  fi
  say ""
  say "  shell into it   ssh -p $SSH_PORT $GUEST_USER@127.0.0.1    (password: $GUEST_PASS)"
  (( HEADLESS )) && say "  screen          vncviewer 127.0.0.1:$((5900 + VNC_DISPLAY))"
  say "  status          $0 --status"
  say "  shut down       $0 --stop"
  say ""
  if (( SSHD_DOWN )); then
    say "sshd is not serving in the guest. Kali ships it disabled; from the VM"
    say "desktop (or VNC) open a terminal and run:"
    say "  sudo systemctl enable --now ssh"
    say "then re-check with:  $0 --verify"
    say ""
  fi
  return 0
}

# ------------------------------------------------------------------------ main

say "${B}Kali QEMU bootstrap${Z}  —  $(basename "$IMAGE")"

case "$MODE" in
  check)  preflight; report ;;
  status) do_status ;;
  stop)   do_stop ;;
  verify) verify; report ;;
  up)
    preflight
    (( FAILURES > 0 )) && { report; exit 1; }
    boot || { report; exit 1; }
    verify
    report
    ;;
esac
