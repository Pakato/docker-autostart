#!/bin/sh
# autostart - bring back Docker containers stuck in created / exited / restarting.
# Complements Docker restart policies and willfarrell/autoheal (which only ever
# looks at RUNNING containers with health=unhealthy).
set -u

INTERVAL="${INTERVAL:-30}"
STARTUP_DELAY="${STARTUP_DELAY:-5}"
CONTAINER_LABEL="${CONTAINER_LABEL:-autostart}"
STATES="${STATES:-created,exited}"
SKIP_EXIT_ZERO="${SKIP_EXIT_ZERO:-true}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
ATTEMPT_RESET="${ATTEMPT_RESET:-3600}"
RESTARTING_GRACE="${RESTARTING_GRACE:-300}"
RESTARTING_ACTION="${RESTARTING_ACTION:-notify}"
FLAP_THRESHOLD="${FLAP_THRESHOLD:-5}"
FLAP_WINDOW="${FLAP_WINDOW:-600}"
FLAP_ACTION="${FLAP_ACTION:-notify}"
APPRISE_URL="${APPRISE_URL:-}"
DRY_RUN="${DRY_RUN:-false}"
STATE_DIR="${STATE_DIR:-/var/lib/autostart}"
HEARTBEAT="${HEARTBEAT:-/tmp/autostart.alive}"
CURL_ERR=/tmp/autostart.curlerr

mkdir -p "$STATE_DIR"

RUNNING=1
trap 'RUNNING=0' TERM INT

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
now() { date +%s; }

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

notify() {
    [ -n "$APPRISE_URL" ] || return 0
    _body=$(json_escape "$1")
    _type="${2:-info}"
    # No -f: capture the HTTP status instead of a generic exit code, so a
    # broken endpoint says WHY in the log instead of just "failed".
    _code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        -d "{\"title\":\"autostart\",\"body\":\"$_body\",\"type\":\"$_type\"}" \
        "$APPRISE_URL" 2>"$CURL_ERR")
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        log "WARN   notification failed: $(tr -d '\r\n' <"$CURL_ERR") (curl exit $_rc)"
    elif [ "$_code" -lt 200 ] || [ "$_code" -ge 300 ]; then
        log "WARN   notification rejected: HTTP $_code from $APPRISE_URL"
    fi
}

counter_get() { if [ -f "$STATE_DIR/$1.count" ]; then cat "$STATE_DIR/$1.count"; else echo 0; fi; }
counter_clear() { rm -f "$STATE_DIR/$1.count" "$STATE_DIR/$1.last" "$STATE_DIR/$1.restarting" "$STATE_DIR/$1.gaveup"; }

counter_bump() {
    _n=$(($(counter_get "$1") + 1))
    echo "$_n" >"$STATE_DIR/$1.count"
    now >"$STATE_DIR/$1.last"
    echo "$_n"
}

counter_expired() {
    [ -f "$STATE_DIR/$1.last" ] || return 1
    [ $(($(now) - $(cat "$STATE_DIR/$1.last"))) -ge "$ATTEMPT_RESET" ]
}

try_start() {
    _id="$1"
    _name="$2"
    _reason="$3"

    quarantined "$_id" && return 0

    if [ "$MAX_ATTEMPTS" -gt 0 ]; then
        counter_expired "$_id" && counter_clear "$_id"
        if [ "$(counter_get "$_id")" -ge "$MAX_ATTEMPTS" ]; then
            # Given up until it comes back up or ATTEMPT_RESET elapses. Say so
            # once, rather than going quiet and looking like everything is fine.
            if [ ! -f "$STATE_DIR/$_id.gaveup" ]; then
                : >"$STATE_DIR/$_id.gaveup"
                log "GIVEUP $_name failed $MAX_ATTEMPTS starts in a row ($_reason) - leaving it alone"
                notify "Gave up on $_name after $MAX_ATTEMPTS failed starts ($_reason). It needs attention." "failure"
            fi
            return 0
        fi
    fi

    _n=$(counter_bump "$_id")

    if [ "$DRY_RUN" = "true" ]; then
        log "DRY    would start $_name ($_reason) attempt $_n"
        return 0
    fi

    if docker start "$_id" >/dev/null 2>&1; then
        log "START  $_name ($_reason) attempt $_n -> ok"
        notify "Started $_name ($_reason), attempt $_n" "success"
    else
        log "FAIL   $_name ($_reason) attempt $_n -> docker start returned an error"
        notify "Could not start $_name ($_reason), attempt $_n/$MAX_ATTEMPTS" "failure"
    fi
}

handle_restarting() {
    _id="$1"
    _name="$2"
    quarantined "$_id" && return 0
    _f="$STATE_DIR/$_id.restarting"
    [ -f "$_f" ] || now >"$_f"
    [ $(($(now) - $(cat "$_f"))) -ge "$RESTARTING_GRACE" ] || return 0

    if [ "$RESTARTING_ACTION" = "restart" ] && [ "$DRY_RUN" != "true" ]; then
        log "CYCLE  $_name stuck restarting > ${RESTARTING_GRACE}s -> docker restart"
        docker restart "$_id" >/dev/null 2>&1 ||
            log "FAIL   $_name docker restart returned an error"
        notify "$_name was stuck restarting for over ${RESTARTING_GRACE}s; cycled it" "warning"
    else
        log "WARN   $_name stuck restarting > ${RESTARTING_GRACE}s (crash loop)"
        notify "$_name has been in a restart loop for over ${RESTARTING_GRACE}s and needs attention" "warning"
    fi
    rm -f "$_f"
}

# --- flap detection ---------------------------------------------------------
# Six restarts in five minutes is a broken container, not a container that
# needs restarting harder. Detection watches .State.StartedAt rather than
# counting our own attempts, so it catches the loop no matter who is driving
# it: our retries, a Docker restart policy, or an external healer such as
# willfarrell/autoheal hammering a container whose health check cannot pass.
#
# A container that trips the threshold is quarantined: we stop touching it and
# say so once. Quarantine lifts on its own after it has run for a whole
# FLAP_WINDOW without restarting and without being unhealthy.

quarantined() { [ -f "$STATE_DIR/$1.quarantine" ]; }

flap_quarantine() {
    _id="$1"
    _name="$2"
    _n="$3"
    _health="$4"
    : >"$STATE_DIR/$_id.quarantine"

    if [ "$FLAP_ACTION" = "stop" ] && [ "$DRY_RUN" != "true" ]; then
        if docker stop "$_id" >/dev/null 2>&1; then
            log "QUAR   $_name flapped $_n times in ${FLAP_WINDOW}s (health=$_health) -> stopped, no further restarts"
            notify "$_name restarted $_n times in ${FLAP_WINDOW}s (health=$_health). Stopped it - restarting it again will not fix it." "failure"
        else
            log "QUAR   $_name flapped $_n times but docker stop returned an error"
            notify "$_name is in a restart loop ($_n restarts in ${FLAP_WINDOW}s) and could not be stopped. It needs attention." "failure"
        fi
    else
        log "QUAR   $_name flapped $_n times in ${FLAP_WINDOW}s (health=$_health) -> will not restart it again"
        notify "$_name restarted $_n times in ${FLAP_WINDOW}s (health=$_health). Not restarting it again - it needs attention." "failure"
    fi
}

flap_recover() {
    _id="$1"
    _name="$2"
    quarantined "$_id" || {
        rm -f "$STATE_DIR/$_id.flaps" "$STATE_DIR/$_id.flapwin"
        return 0
    }
    log "OK     $_name has run ${FLAP_WINDOW}s without flapping -> lifting quarantine"
    notify "$_name has been stable for ${FLAP_WINDOW}s; watching it normally again" "success"
    rm -f "$STATE_DIR/$_id.quarantine" "$STATE_DIR/$_id.flaps" "$STATE_DIR/$_id.flapwin"
}

flap_observe() {
    _id="$1"
    _name="$2"
    _status="$3"
    _started="$4"
    _health="$5"

    _prev=""
    [ -f "$STATE_DIR/$_id.started" ] && _prev=$(cat "$STATE_DIR/$_id.started")
    printf '%s' "$_started" >"$STATE_DIR/$_id.started"

    if [ -z "$_prev" ]; then
        now >"$STATE_DIR/$_id.stable" # first sighting, nothing to compare against
        return 0
    fi

    if [ "$_prev" != "$_started" ]; then
        now >"$STATE_DIR/$_id.stable"

        _win=0
        [ -f "$STATE_DIR/$_id.flapwin" ] && _win=$(cat "$STATE_DIR/$_id.flapwin")
        if [ $(($(now) - _win)) -ge "$FLAP_WINDOW" ]; then
            now >"$STATE_DIR/$_id.flapwin" # start a fresh window
            echo 0 >"$STATE_DIR/$_id.flaps"
        fi

        _n=0
        [ -f "$STATE_DIR/$_id.flaps" ] && _n=$(cat "$STATE_DIR/$_id.flaps")
        _n=$((_n + 1))
        echo "$_n" >"$STATE_DIR/$_id.flaps"
        log "FLAP   $_name restarted ($_n in the last ${FLAP_WINDOW}s, health=$_health)"

        if [ "$FLAP_THRESHOLD" -gt 0 ] && [ "$_n" -ge "$FLAP_THRESHOLD" ] && ! quarantined "$_id"; then
            flap_quarantine "$_id" "$_name" "$_n" "$_health"
        fi
        return 0
    fi

    # StartedAt unchanged. Only a container that is actually running can be
    # recovering - a quarantined one we stopped would otherwise look "stable"
    # forever and let itself back out.
    [ "$_status" = "running" ] || return 0
    [ "$_health" = "unhealthy" ] && return 0

    _stable=0
    [ -f "$STATE_DIR/$_id.stable" ] && _stable=$(cat "$STATE_DIR/$_id.stable")
    [ $(($(now) - _stable)) -ge "$FLAP_WINDOW" ] || return 0
    flap_recover "$_id" "$_name"
}

flap_scan() {
    _ids=$(docker ps -a $LABEL_FILTER --format '{{.ID}}' 2>/dev/null)
    [ -n "$_ids" ] || return 0
    docker inspect --format \
        '{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.StartedAt}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        $_ids 2>/dev/null |
        while IFS='|' read -r id name status started health; do
            [ -n "$id" ] || continue
            flap_observe "$(printf '%.12s' "$id")" "${name#/}" "$status" "$started" "$health"
        done
}

sweep() {
    flap_scan

    # anything that is up again gets a clean slate
    docker ps $LABEL_FILTER --format '{{.ID}}' 2>/dev/null | while read -r id; do
        [ -n "$id" ] && counter_clear "$id"
    done

    for state in $(echo "$STATES" | tr ',' ' '); do
        docker ps -a $LABEL_FILTER --filter "status=$state" \
            --format '{{.ID}}|{{.Names}}' 2>/dev/null |
            while IFS='|' read -r id name; do
                [ -n "$id" ] || continue
                case "$state" in
                created)
                    try_start "$id" "$name" "created"
                    ;;
                exited)
                    code=$(docker inspect -f '{{.State.ExitCode}}' "$id" 2>/dev/null || echo "?")
                    if [ "$SKIP_EXIT_ZERO" = "true" ] && [ "$code" = "0" ]; then
                        continue # finished cleanly or stopped on purpose
                    fi
                    try_start "$id" "$name" "exited code=$code"
                    ;;
                restarting)
                    handle_restarting "$id" "$name"
                    ;;
                *)
                    log "WARN   unsupported state '$state' in STATES, ignoring"
                    ;;
                esac
            done
    done
}

prune_state() {
    for f in "$STATE_DIR"/*; do
        [ -e "$f" ] || continue
        base=${f##*/}
        docker inspect "${base%%.*}" >/dev/null 2>&1 || rm -f "$f"
    done
}

if [ "$CONTAINER_LABEL" = "all" ]; then
    LABEL_FILTER=""
    log "watching ALL containers (CONTAINER_LABEL=all)"
else
    LABEL_FILTER="--filter label=${CONTAINER_LABEL}=true"
    log "watching containers labelled ${CONTAINER_LABEL}=true"
fi
log "states=$STATES interval=${INTERVAL}s startup_delay=${STARTUP_DELAY}s max_attempts=$MAX_ATTEMPTS skip_exit_zero=$SKIP_EXIT_ZERO dry_run=$DRY_RUN"
log "flap_threshold=$FLAP_THRESHOLD flap_window=${FLAP_WINDOW}s flap_action=$FLAP_ACTION"

docker version >/dev/null 2>&1 || {
    log "FATAL  cannot talk to the Docker API - check the socket mount or DOCKER_HOST"
    exit 1
}

# Give the Docker daemon and the rest of the stack a moment to settle after a
# host boot, so the first sweep does not fight containers that are already on
# their way up. The heartbeat is written first to keep HEALTHCHECK happy, and
# the sleep is backgrounded so a docker stop is still answered immediately.
if [ "$STARTUP_DELAY" -gt 0 ] && [ "$RUNNING" -eq 1 ]; then
    touch "$HEARTBEAT"
    log "waiting ${STARTUP_DELAY}s before the first sweep"
    sleep "$STARTUP_DELAY" &
    wait $! 2>/dev/null || true
fi

while [ "$RUNNING" -eq 1 ]; do
    touch "$HEARTBEAT"
    sweep
    prune_state
    sleep "$INTERVAL" &
    wait $! 2>/dev/null || true
done

log "shutting down"
