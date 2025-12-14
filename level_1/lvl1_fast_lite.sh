#!/usr/bin/env bash
set -Eeuo pipefail

APP_PATH="${APP_PATH:-./app_linux_amd64}"
APP_NAME="${APP_NAME:-$(basename "$APP_PATH")}"

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
PATH_HTTP="${PATH_HTTP:-/}"

QUICK_DURATIONS="${QUICK_DURATIONS:-100 500 1000}"
QUICK_RUNS="${QUICK_RUNS:-2}"
DO_LONG="${DO_LONG:-1}"
LONG_DURATION="${LONG_DURATION:-2400}"
LONG_RUNS="${LONG_RUNS:-1}"

BASELINE_SEC="${BASELINE_SEC:-5}"
WARMUP_SEC="${WARMUP_SEC:-5}"
RUN_PAUSE_SEC="${RUN_PAUSE_SEC:-10}"

# sampling intervals
SAMPLE_SEC_SHORT="${SAMPLE_SEC_SHORT:-2}"
SAMPLE_SEC_LONG="${SAMPLE_SEC_LONG:-10}"
LONG_THRESHOLD_SEC="${LONG_THRESHOLD_SEC:-600}"

# load defaults
WRK_THREADS="${WRK_THREADS:-1}"
WRK_CONNECTIONS="${WRK_CONNECTIONS:-10}"

# curl fallback: single worker
CURL_TIMEOUT="${CURL_TIMEOUT:-2}"
CURL_SLEEP_MS="${CURL_SLEEP_MS:-30}"

START_APP="${START_APP:-1}"
PID="${PID:-}"

TS="$(date +%Y%m%d_%H%M%S)"
OUTROOT="${OUTROOT:-lvl1_stable_${TS}}"
mkdir -p "$OUTROOT"

log(){ echo "[$(date +'%F %T')] $*" | tee -a "$OUTROOT/_run.log" >&2; }

LOWPRIO=(nice -n 10)
if command -v ionice >/dev/null 2>&1; then
  LOWPRIO=(ionice -c3 nice -n 10)
fi

port_listening() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltn 2>/dev/null | grep -qE ":${PORT}\b"
}

pick_sample() {
  local duration="$1"
  if (( duration > LONG_THRESHOLD_SEC )); then echo "$SAMPLE_SEC_LONG"; else echo "$SAMPLE_SEC_SHORT"; fi
}

ceil_div() { local a="$1" b="$2"; echo $(( (a + b - 1) / b )); }

resolve_pid_by_name() {
  local p=""
  if command -v pidof >/dev/null 2>&1; then
    p="$(pidof "$APP_NAME" 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [[ -z "$p" ]] && command -v pgrep >/dev/null 2>&1; then
    p="$(pgrep -xo "$APP_NAME" 2>/dev/null || true)"
  fi
  echo "$p"
}

start_app_if_needed() {
  if port_listening; then
    log "WARN: :$PORT already listening -> reusing existing server (START_APP=0)."
    START_APP=0
    return 0
  fi

  if [[ "$START_APP" != "1" ]]; then
    log "ERROR: :$PORT not listening and START_APP=0. Start app manually or set START_APP=1."
    exit 1
  fi

  log "Starting app: $APP_PATH"
  ( "$APP_PATH" >"$OUTROOT/app_stdout.log" 2>"$OUTROOT/app_stderr.log" & echo $! >"$OUTROOT/app.pid" )
  PID="$(cat "$OUTROOT/app.pid")"
  log "Initial PID=$PID; waiting for :$PORT ..."

  for _ in $(seq 1 100); do
    if port_listening; then
      if ! kill -0 "$PID" 2>/dev/null; then
        local p2; p2="$(resolve_pid_by_name)"
        if [[ -n "$p2" ]]; then PID="$p2"; log "Port up; initial PID died; using PID=$PID"; fi
      fi
      return 0
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
      log "ERROR: app died before opening :$PORT. Last stderr:"
      tail -n 80 "$OUTROOT/app_stderr.log" 2>/dev/null || true
      exit 1
    fi
    sleep 0.1
  done

  log "ERROR: app did not open :$PORT in time. Last stderr:"
  tail -n 80 "$OUTROOT/app_stderr.log" 2>/dev/null || true
  exit 1
}

resolve_pid() {
  if [[ -n "${PID:-}" ]]; then return 0; fi
  PID="$(resolve_pid_by_name || true)"
  if [[ -z "${PID:-}" ]]; then
    log "WARN: PID not resolved by name. pidstat will be skipped."
  else
    log "Resolved PID=$PID"
  fi
}

check_tools() {
  : > "$OUTROOT/MISSING_TOOLS.txt"
  for c in ss mpstat sar pidstat vmstat wrk curl; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "$c" >> "$OUTROOT/MISSING_TOOLS.txt"
    fi
  done
  if [[ -s "$OUTROOT/MISSING_TOOLS.txt" ]]; then
    log "WARN: missing tools listed in $OUTROOT/MISSING_TOOLS.txt (script will still run)."
  fi
}

snapshot() {
  {
    echo "### TIME: $(date -Ins)"
    free -h || true
    if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
      ps -p "$PID" -o pid,ppid,cmd,%cpu,%mem,etime,stat || true
      ps -o nlwp= -p "$PID" || true
    else
      echo "PID not available or not running"
    fi
    command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -E ":${PORT}\b" || true
  } > "$OUTDIR/snapshot.txt" 2>&1 || true
}

collect_metrics() {
  local tag="$1" duration="$2" interval="$3"
  if (( interval <= 0 )); then interval=1; fi
  if (( interval > duration )); then interval="$duration"; fi
  local count; count="$(ceil_div "$duration" "$interval")"
  log "Metrics($tag): duration=${duration}s interval=${interval}s count=${count}"

  local pids=()

  if command -v mpstat >/dev/null 2>&1; then
    ( "${LOWPRIO[@]}" mpstat -P ALL "$interval" "$count" > "$OUTDIR/${tag}_mpstat.txt" 2>&1 ) & pids+=("$!")
  fi
  if command -v sar >/dev/null 2>&1; then
    ( "${LOWPRIO[@]}" sar -q "$interval" "$count" > "$OUTDIR/${tag}_sar_q.txt" 2>&1 ) & pids+=("$!")
  fi
  if command -v vmstat >/dev/null 2>&1; then
    ( "${LOWPRIO[@]}" vmstat "$interval" "$count" > "$OUTDIR/${tag}_vmstat.txt" 2>&1 ) & pids+=("$!")
  fi
  if command -v pidstat >/dev/null 2>&1 && [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
    ( "${LOWPRIO[@]}" pidstat -u -w -p "$PID" "$interval" "$count" > "$OUTDIR/${tag}_pidstat_uw.txt" 2>&1 ) & pids+=("$!")
  fi

  for p in "${pids[@]:-}"; do wait "$p" || true; done
}

run_load_wrk() {
  local seconds="$1"
  local url="http://${HOST}:${PORT}${PATH_HTTP}"
  "${LOWPRIO[@]}" wrk -t"$WRK_THREADS" -c"$WRK_CONNECTIONS" -d"${seconds}s" "$url" > "$OUTDIR/measured_load.txt" 2>&1 || true
}

run_load_curl() {
  local seconds="$1"
  local url="http://${HOST}:${PORT}${PATH_HTTP}"
  {
    echo "### TIME: $(date -Ins)"
    echo "### url=$url timeout=${CURL_TIMEOUT}s sleep_ms=$CURL_SLEEP_MS"
  } > "$OUTDIR/measured_load.txt"
  local end=$((SECONDS + seconds))
  local ok=0 fail=0
  while (( SECONDS < end )); do
    if curl -sS -m "$CURL_TIMEOUT" "$url" -o /dev/null; then ok=$((ok+1)); else fail=$((fail+1)); fi
    if (( CURL_SLEEP_MS > 0 )); then sleep 0.0"$CURL_SLEEP_MS" 2>/dev/null || sleep 0.03; fi
  done
  echo "ok=$ok fail=$fail" >> "$OUTDIR/measured_load.txt"
}

heartbeat_wait() {
  local pid="$1" label="$2"
  while kill -0 "$pid" 2>/dev/null; do
    log "… still running: $label (pid=$pid)"
    sleep 30
  done
}

one_run() {
  local duration="$1" run_id="$2" runs_total="$3"
  OUTDIR="$OUTROOT/${duration}s/run_${run_id}"
  mkdir -p "$OUTDIR"

  local interval; interval="$(pick_sample "$duration")"

  log "=== duration=${duration}s run=${run_id}/${runs_total} interval=${interval}s (OUTDIR=$OUTDIR) ==="

  snapshot

  collect_metrics "baseline" "$BASELINE_SEC" "$interval"

  # warmup load (no metrics)
  if (( WARMUP_SEC > 0 )); then
    log "Warmup load ${WARMUP_SEC}s"
    if command -v wrk >/dev/null 2>&1; then
      "${LOWPRIO[@]}" wrk -t"$WRK_THREADS" -c"$WRK_CONNECTIONS" -d"${WARMUP_SEC}s" "http://${HOST}:${PORT}${PATH_HTTP}" > "$OUTDIR/warmup_load.txt" 2>&1 || true
    else
      run_load_curl "$WARMUP_SEC" || true
      mv "$OUTDIR/measured_load.txt" "$OUTDIR/warmup_load.txt" 2>/dev/null || true
    fi
  fi

  # measured: metrics + load in parallel
  log "Starting measured load for ${duration}s…"
  ( collect_metrics "load" "$duration" "$interval" ) & local mpid=$!
  if command -v wrk >/dev/null 2>&1; then
    ( run_load_wrk "$duration" ) & local lpid=$!
  else
    ( run_load_curl "$duration" ) & local lpid=$!
  fi

  ( heartbeat_wait "$lpid" "load ${duration}s" ) & local hpid=$!

  wait "$lpid" || true
  kill "$hpid" 2>/dev/null || true
  wait "$mpid" || true

  snapshot
  echo "DONE $(date -Ins)" > "$OUTDIR/DONE.marker"
  log "Run finished: duration=${duration}s run=${run_id}"
}

main() {
  log "OUTROOT=$OUTROOT"
  log "Baseline=${BASELINE_SEC}s Warmup=${WARMUP_SEC}s"
  log "Quick: $QUICK_DURATIONS x $QUICK_RUNS runs; Long: DO_LONG=$DO_LONG duration=$LONG_DURATION x $LONG_RUNS"
  log "Load: wrk(t=$WRK_THREADS c=$WRK_CONNECTIONS) else curl(single loop)"

  check_tools
  start_app_if_needed
  resolve_pid

  for d in $QUICK_DURATIONS; do
    for r in $(seq 1 "$QUICK_RUNS"); do
      one_run "$d" "$r" "$QUICK_RUNS"
      if (( r < QUICK_RUNS )); then sleep "$RUN_PAUSE_SEC"; fi
    done
  done

  if (( DO_LONG == 1 )); then
    for r in $(seq 1 "$LONG_RUNS"); do
      one_run "$LONG_DURATION" "$r" "$LONG_RUNS"
      if (( r < LONG_RUNS )); then sleep "$RUN_PAUSE_SEC"; fi
    done
  fi

  log "All done."
  log "You should have DONE.marker files. Example:"
  find "$OUTROOT" -name DONE.marker -maxdepth 4 -print | head -n 20 || true
}

main "$@"
