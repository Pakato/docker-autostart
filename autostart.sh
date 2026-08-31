#!/bin/sh
# autostart - bring back Docker containers stuck in created / exited / restarting.
# Complements Docker restart policies and willfarrell/autoheal (which only ever
# looks at RUNNING containers with health=unhealthy).
set -u

INTERVAL="${INTERVAL:-30}"
CONTAINER_LABEL="${CONTAINER_LABEL:-autostart}"
STATES="${STATES:-created,exited}"
SKIP_EXIT_ZERO="${SKIP_EXIT_ZERO:-true}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
ATTEMPT_RESET="${ATTEMPT_RESET:-3600}"
RESTARTING_GRACE="${RESTARTING_GRACE:-300}"
RESTARTING_ACTION="${RESTARTING_ACTION:-notify}"
APPRISE_URL="${APPRISE_URL:-}"
DRY_RUN="${DRY_RUN:-false}"
STATE_DIR="${STATE_DIR:-/var/lib/autostart}"
HEARTBEAT="${HEARTBEAT:-/tmp/autostart.alive}"

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
    curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
        -d "{\"title\":\"autostart\",\"body\":\"$_body\",\"type\":\"$_type\"}" \
        "$APPRISE_URL" >/dev/null 2>&1 ||
        log "WARN   notification failed"
}

counter_get() { if [ -f "$STATE_DIR/$1.count" ]; then cat "$STATE_DIR/$1.count"; else echo 0; fi; }
counter_clear() { rm -f "$STATE_DIR/$1.count" "$STATE_DIR/$1.last" "$STATE_DIR/$1.restarting"; }

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

    if [ "$MAX_ATTEMPTS" -gt 0 ]; then
        counter_expired "$_id" && counter_clear "$_id"
        if [ "$(counter_get "$_id")" -ge "$MAX_ATTEMPTS" ]; then
            return 0 # given up until it comes back up or ATTEMPT_RESET elapses
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

sweep() {
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
log "states=$STATES interval=${INTERVAL}s max_attempts=$MAX_ATTEMPTS skip_exit_zero=$SKIP_EXIT_ZERO dry_run=$DRY_RUN"

docker version >/dev/null 2>&1 || {
    log "FATAL  cannot talk to the Docker API - check the socket mount or DOCKER_HOST"
    exit 1
}

while [ "$RUNNING" -eq 1 ]; do
    touch "$HEARTBEAT"
    sweep
    prune_state
    sleep "$INTERVAL" &
    wait $! 2>/dev/null || true
done

log "shutting down"
