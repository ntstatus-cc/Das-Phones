#!/data/data/com.termux/files/usr/bin/bash
#
# phone-miner — one-shot cpuminer-opt installer for Termux (Android, aarch64)
#
# Builds the latest cpuminer-opt from source (tpfuemp fork by default), installs
# a `miner` command, and sets the miner to start on boot via Termux:Boot.
#
# Quick start (replace the pool and wallet):
#   bash install.sh yespoweradvc stratum+tcp://POOL:PORT YOUR_WALLET
#
# Or point every phone at one shared config file you control:
#   bash install.sh --remote https://raw.githubusercontent.com/YOU/REPO/main/fleet.conf
#
# Optional environment overrides:
#   SRC_REPO=https://github.com/other/cpuminer-opt.git   build a different fork
#   SRC_REF=<commit or tag>                               pin a known-good version
#
set -eo pipefail

MDIR="$HOME/.miner"
CTL="${PREFIX:-}/bin/miner"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ -n "${PREFIX:-}" ] && [ -d "$PREFIX/bin" ] || die "Run this inside the Termux app."
[ "$(uname -m)" = "aarch64" ] || die "Needs a 64-bit ARM phone (aarch64). This one reports $(uname -m)."

# --script-only: refresh just the `miner` command (no packages, no rebuild)
SCRIPT_ONLY=""
[ "$1" = "--script-only" ] && { SCRIPT_ONLY=1; shift; }

# ---------------------------------------------------------------- packages
if [ -z "$SCRIPT_ONLY" ]; then
  say "Installing build tools (a few minutes on first run)"
  pkg update -y
  apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
  pkg install -y clang make autoconf automake libtool binutils libcurl libgmp git curl
fi

mkdir -p "$MDIR/profiles"

# ---------------------------------------------------------------- miner command
say "Installing the 'miner' command"
cat > "$CTL" <<'MINER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# miner — control script installed by phone-miner/install.sh
MDIR="$HOME/.miner"
BIN="$MDIR/cpuminer"
SRC_DIR="$MDIR/cpuminer-opt"
PROF="$MDIR/profiles"
ACTIVE_FILE="$MDIR/active"
SETTINGS="$MDIR/settings.conf"
PIDFILE="$MDIR/run.pid"
SRC_REPO_FILE="$MDIR/src_repo"
LOG="$MDIR/miner.log"

PROFILE_KEYS="ALGO POOL WALLET PASS THREADS AFFINITY EXTRA"
SETTING_KEYS="THREADS AFFINITY WORKER CONF_URL CHECK_MIN"

# Read KEY=VALUE lines into C_<KEY> variables. Nothing in the file is executed:
# only whitelisted keys are accepted and values are stored as plain text.
readconf() {
  local file="$1" allowed="$2" line k v
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    k="${line%%=*}"; k="${k// /}"
    v="${line#*=}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    v="${v#\"}"; v="${v%\"}"
    case " $allowed " in *" $k "*) printf -v "C_$k" '%s' "$v" ;; esac
  done < "$file"
  return 0
}

setkv() {  # setkv FILE KEY VALUE
  local file="$1" key="$2" val="$3"
  touch "$file"
  grep -v "^${key}=" "$file" > "$file.tmp" || true
  [ -n "$val" ] && printf '%s=%s\n' "$key" "$val" >> "$file.tmp"
  mv "$file.tmp" "$file"
}

# The background loop writes its own PID; check it is still that loop
# (after a reboot an old PID can belong to some other process).
running() {
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
    && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "miner run"
}
miner_up() { pgrep -f "^$BIN " >/dev/null; }
# Remove anything left by the older screen-based version.
legacy_cleanup() {
  if command -v screen >/dev/null; then
    screen -S miner -X quit >/dev/null 2>&1; screen -wipe >/dev/null 2>&1
  fi
}
active()  { cat "$ACTIVE_FILE" 2>/dev/null; }

load_all() {
  unset C_ALGO C_POOL C_WALLET C_PASS C_THREADS C_AFFINITY C_EXTRA C_WORKER C_CONF_URL C_CHECK_MIN
  readconf "$SETTINGS" "$SETTING_KEYS" || true
  local s_threads="$C_THREADS" s_aff="$C_AFFINITY"
  local name; name="$(active)"
  [ -n "$name" ] || return 1
  readconf "$PROF/$name.conf" "$PROFILE_KEYS" || return 1
  # Per-phone settings win over the profile for threads and affinity.
  [ -n "$s_threads" ] && C_THREADS="$s_threads"
  [ -n "$s_aff" ] && C_AFFINITY="$s_aff"
  [ -n "$C_ALGO" ] && [ -n "$C_POOL" ] && [ -n "$C_WALLET" ]
}

build_cmd() {
  local user="$C_WALLET"
  [ -n "$C_WORKER" ] && user="$C_WALLET.$C_WORKER"
  CMD=("$BIN" -a "$C_ALGO" -o "$C_POOL" -u "$user" -p "${C_PASS:-x}")
  [ -n "$C_THREADS" ] && CMD+=(-t "$C_THREADS")
  [ -n "$C_AFFINITY" ] && CMD+=(--cpu-affinity "$C_AFFINITY")
  if [ -n "$C_EXTRA" ]; then local extra; read -ra extra <<< "$C_EXTRA"; CMD+=("${extra[@]}"); fi
}

# Download the shared fleet config. Returns 0 only when it changed.
sync_remote() {
  readconf "$SETTINGS" "$SETTING_KEYS" || true
  [ -n "$C_CONF_URL" ] || return 1
  local tmp="$MDIR/.remote.tmp"
  curl -fsSL --max-time 20 "$C_CONF_URL" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  grep -q '^ALGO=' "$tmp" || { rm -f "$tmp"; return 1; }
  if cmp -s "$tmp" "$PROF/remote.conf"; then rm -f "$tmp"; return 1; fi
  mv "$tmp" "$PROF/remote.conf"
  return 0
}

cmd_run() {  # the background loop started by 'miner start'
  echo $$ > "$PIDFILE"
  local pid="" waited
  # 'miner stop' (TERM) also stops the cpuminer process.
  trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"; exit 0' INT TERM HUP
  # termux-wake-lock can hang right after boot; never let it block mining.
  command -v termux-wake-lock >/dev/null && { timeout 15 termux-wake-lock >/dev/null 2>&1 & }
  while true; do
    sync_remote || true
    if ! [ -x "$BIN" ]; then echo "[miner] no cpuminer binary yet — run: miner update"; sleep 60 & wait $!; continue; fi
    if ! load_all; then echo "[miner] no complete profile active — run: miner add / miner use"; sleep 60 & wait $!; continue; fi
    build_cmd
    echo "[miner] $(date '+%F %T') starting profile '$(active)': ${CMD[*]}"
    "${CMD[@]}" --no-color &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 30 & wait $!   # interruptible, so 'miner stop' acts at once
      waited=$((waited + 30))
      # Keep the log small: past 2 MB, cut it back to the newest ~200 KB.
      # The log is opened in append mode, so trimming it in place is safe.
      if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 2000000 ]; then
        tail -c 200000 "$LOG" > "$LOG.trim" && cat "$LOG.trim" > "$LOG"; rm -f "$LOG.trim"
      fi
      if [ -n "$C_CONF_URL" ] && [ "$(active)" = "remote" ] && [ "$waited" -ge $(( ${C_CHECK_MIN:-15} * 60 )) ]; then
        waited=0
        if sync_remote; then echo "[miner] fleet config changed — restarting"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; break; fi
      fi
    done
    wait "$pid" 2>/dev/null
    echo "[miner] $(date '+%F %T') miner exited — restarting in 10 s"
    sleep 10 & wait $!
  done
}

cmd_update() {
  local repo ref
  repo="${SRC_REPO:-$(cat "$SRC_REPO_FILE" 2>/dev/null)}"
  repo="${repo:-https://github.com/tpfuemp/cpuminer-opt.git}"
  ref="${SRC_REF:-}"
  echo "$repo" > "$SRC_REPO_FILE"
  set -e
  if [ -d "$SRC_DIR/.git" ] && [ "$(git -C "$SRC_DIR" remote get-url origin)" = "$repo" ]; then
    git -C "$SRC_DIR" fetch --depth 1 origin "${ref:-HEAD}"
    git -C "$SRC_DIR" reset --hard FETCH_HEAD
  else
    rm -rf "$SRC_DIR"
    git clone --depth 1 "$repo" "$SRC_DIR"
    if [ -n "$ref" ]; then
      git -C "$SRC_DIR" fetch --depth 1 origin "$ref"
      git -C "$SRC_DIR" checkout -q FETCH_HEAD
    fi
  fi
  set +e
  echo "[miner] building $(git -C "$SRC_DIR" log -1 --format='%h %cd' --date=short) from $repo"
  cd "$SRC_DIR" || exit 1
  if [ -f build-termux.sh ]; then
    bash build-termux.sh || EXTRA_CFLAGS="-std=gnu17" bash build-termux.sh
  else
    # Forks without the Termux script: same flags it would pick.
    ./autogen.sh && CC=clang CXX=clang++ CFLAGS="-O3 -march=armv8-a+crypto -Wall -flax-vector-conversions" \
      CXXFLAGS="-O3 -march=armv8-a+crypto" ./configure --with-curl="$PREFIX" && make -j"$(nproc)"
  fi
  [ -x "$SRC_DIR/cpuminer" ] || { echo "[miner] BUILD FAILED — nothing was replaced"; exit 1; }
  cp "$SRC_DIR/cpuminer" "$BIN.new" && mv "$BIN.new" "$BIN"
  echo "[miner] installed: $("$BIN" --version 2>/dev/null | head -1)"
  if running; then pkill -f "^$BIN " ; echo "[miner] restarted on the new build"; fi
  return 0
}

usage() {
cat <<EOF
miner — phone mining control

  miner start | stop | restart     start/stop the background miner
  miner log                        watch the miner (Ctrl+C stops watching, not mining)
  miner status                     what's running and with which settings
  miner add NAME ALGO POOL WALLET [PASS]
                                   save a coin profile
  miner use NAME                   switch to a saved profile (restarts)
  miner list                       saved profiles (* = active)
  miner set KEY VALUE              per-phone setting: THREADS, AFFINITY, WORKER,
                                   CONF_URL, CHECK_MIN   (empty VALUE clears it)
  miner remote URL                 follow a shared fleet config file
  miner update                     rebuild from the newest source
  miner algos                      algorithms this build supports
  miner boot on|off                start automatically when the phone boots
EOF
}

case "$1" in
  run) cmd_run ;;
  start)
    if running; then echo "Already running. 'miner log' to watch."; exit 0; fi
    legacy_cleanup; pkill -f "^$BIN " 2>/dev/null; rm -f "$PIDFILE"
    nohup "$0" run >> "$LOG" 2>&1 < /dev/null &
    sleep 1
    if running; then echo "Started. 'miner log' to watch."; else echo "Failed to start. Last log lines:"; tail -n 15 "$LOG"; fi ;;
  stop)
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    running && kill "$pid" 2>/dev/null
    sleep 1; pkill -f "^$BIN " 2>/dev/null; legacy_cleanup; rm -f "$PIDFILE"
    command -v termux-wake-unlock >/dev/null && timeout 15 termux-wake-unlock >/dev/null 2>&1
    echo "Stopped." ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  log|attach|tail)
    [ -f "$LOG" ] || { echo "No log yet. 'miner start' first."; exit 0; }
    running || echo "(miner is NOT running — showing the old log. 'miner start' to start it.)"
    echo "(Ctrl+C stops watching; the miner keeps running)"
    tail -n 40 -f "$LOG" ;;
  status)
    if running; then echo "State:   running (loop PID $(cat "$PIDFILE"))"; else echo "State:   stopped"; fi
    echo "Profile: $(active)"
    if load_all; then build_cmd; echo "Command: ${CMD[*]}"; else echo "Command: (profile incomplete)"; fi
    [ -n "$C_CONF_URL" ] && echo "Fleet:   $C_CONF_URL (every ${C_CHECK_MIN:-15} min)"
    [ -x "$BIN" ] && echo "Build:   $("$BIN" --version 2>/dev/null | head -1)"
    miner_up && echo "Miner:   cpuminer process running" || echo "Miner:   cpuminer process NOT running"
    [ -f "$LOG" ] && echo "Last:    $(grep -a 'H/s' "$LOG" | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-120)" ;;
  add)
    [ $# -ge 5 ] || { echo "Usage: miner add NAME ALGO POOL WALLET [PASS]"; exit 1; }
    f="$PROF/$2.conf"; : > "$f"
    setkv "$f" ALGO "$3"; setkv "$f" POOL "$4"; setkv "$f" WALLET "$5"; setkv "$f" PASS "${6:-x}"
    echo "Saved profile '$2'. Switch to it with: miner use $2" ;;
  use)
    [ -f "$PROF/$2.conf" ] || { echo "No profile '$2'. 'miner list' shows what exists."; exit 1; }
    echo "$2" > "$ACTIVE_FILE"; echo "Active profile: $2"
    if running; then pkill -f "^$BIN "; echo "Restarting on '$2'..."; else "$0" start; fi ;;
  list)
    for f in "$PROF"/*.conf; do [ -e "$f" ] || continue; n="$(basename "$f" .conf)"
      unset C_ALGO C_POOL; readconf "$f" "$PROFILE_KEYS"
      [ "$n" = "$(active)" ] && m="*" || m=" "; printf '%s %-12s %-14s %s\n' "$m" "$n" "$C_ALGO" "$C_POOL"; done ;;
  set)
    case " $SETTING_KEYS " in *" $2 "*) ;; *) echo "Settable keys: $SETTING_KEYS"; exit 1 ;; esac
    setkv "$SETTINGS" "$2" "$3"; echo "$2=${3:-(cleared)}"; running && pkill -f "^$BIN " ;;
  remote)
    [ -n "$2" ] || { echo "Usage: miner remote URL"; exit 1; }
    setkv "$SETTINGS" CONF_URL "$2"
    if sync_remote || [ -f "$PROF/remote.conf" ]; then echo "remote" > "$ACTIVE_FILE"; echo "Following $2"
      if running; then pkill -f "^$BIN "; else "$0" start; fi
    else echo "Couldn't read a config with an ALGO= line from that URL."; exit 1; fi ;;
  update) cmd_update ;;
  algos) "$BIN" --help 2>&1 | grep -E '^ {20,}[a-z0-9-]+' ;;
  boot)
    mkdir -p "$HOME/.termux/boot"
    if [ "$2" = "off" ]; then rm -f "$HOME/.termux/boot/start-miner"; echo "Boot start off."
    else
      printf '#!/data/data/com.termux/files/usr/bin/sh\n# give Android time to bring up networking\nsleep 30\n%s start >> %s 2>&1\n' "$0" "$LOG" > "$HOME/.termux/boot/start-miner"
      chmod +x "$HOME/.termux/boot/start-miner"; echo "Boot start on (needs the Termux:Boot app opened once)."
    fi ;;
  *) usage ;;
esac
MINER_EOF
chmod +x "$CTL"

if [ -n "$SCRIPT_ONLY" ]; then
  "$CTL" boot on >/dev/null
  "$CTL" restart >/dev/null
  say "miner command updated"; "$CTL" status; exit 0
fi

# ---------------------------------------------------------------- build
say "Building cpuminer-opt (5–20 minutes on a phone)"
"$CTL" update || die "Build failed. Copy the last 30 lines above and send them over."

# ---------------------------------------------------------------- first profile
if [ "$1" = "--remote" ] && [ -n "$2" ]; then
  "$CTL" remote "$2" >/dev/null || die "Couldn't read the fleet config at $2"
elif [ $# -ge 3 ]; then
  name="$(printf '%s' "$1" | sed 's/^yespower//; s/^$/yespower/')"
  "$CTL" add "$name" "$1" "$2" "$3" "${4:-x}" >/dev/null
  echo "$name" > "$MDIR/active"
  [ -n "$5" ] && "$CTL" set THREADS "$5" >/dev/null
fi

"$CTL" boot on >/dev/null
[ -n "$(cat "$MDIR/active" 2>/dev/null)" ] && "$CTL" start >/dev/null

say "Done"
"$CTL" status
cat <<EOF

Next:
  miner log        watch hashrate (Ctrl+A then D to leave it running)
  miner usage      all commands
Open the Termux:Boot app once so the miner starts after a reboot.
EOF
