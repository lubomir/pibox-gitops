#!/bin/sh
set -eu

STATE_DIR="${STATE_DIR:-/var/lib/docker/.lru-state}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-7}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-FORGEJO-ACTIONS-TASK-}"

EVENT_FILE="${EVENT_FILE:-/tmp/docker-image-lru-events}"

# Start dind
dockerd-entrypoint.sh 2>&1 &

# Wait for it to be ready
until docker info >/dev/null 2>&1; do
  sleep 2
done

if [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR"

    echo "Initializing image usage metadata"

    docker image ls -q |
    sort -u |
    while IFS= read -r image_id; do
        [ -n "$image_id" ] || continue
        touch "$STATE_DIR/$image_id"
    done
fi

# Record every Forgejo Actions container created while the job runs.
# We listen for "create" rather than "start" because containers may be
# destroyed before the cleanup phase.
docker events \
    --filter 'type=container' \
    --filter 'event=create' \
    --format '{{.Actor.ID}} {{.Actor.Attributes.name}} {{.Actor.Attributes.image}}' \
    > "$EVENT_FILE" &

EVENT_PID=$!

cleanup() {
    kill "$EVENT_PID" 2>/dev/null || true
    wait "$EVENT_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Give the event listener a moment to connect before the runner starts
# creating containers.
sleep 1

# Signal to forgejo that dind is ready.
touch /certs/ready

echo "Watching for Forgejo Actions containers..."

# Wait for the Forgejo runner to finish.
while pgrep forgejo-runner >/dev/null 2>&1; do
    sleep 10
done

# Stop the event listener and make sure all events have been written.
kill "$EVENT_PID" 2>/dev/null || true
wait "$EVENT_PID" 2>/dev/null || true
trap - EXIT INT TERM

# Record image usage for containers created by this Forgejo job.
#
# We deliberately inspect the recorded container IDs rather than querying
# docker events again: the containers may already have been destroyed.
if [ -s "$EVENT_FILE" ]; then
    while IFS=' ' read -r container_id container_name image; do
        case "$container_name" in
            "$CONTAINER_PREFIX"*)
                ;;
            *)
                continue
                ;;
        esac

        [ -n "$image" ] || continue

        image_id="$(docker inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"

        if [ -n "$image_id" ]; then
            echo "Marking image as used: $image -> $image_id ($container_name)"
            touch "$STATE_DIR/$image_id"
        else
            echo "Could not resolve image: '$image' for $container_name"
        fi
    done < "$EVENT_FILE"
fi

echo "Removing stopped Forgejo Actions containers..."

echo "---"
docker ps -a
echo "---"

now="$(date +%s)"
max_age_sec=$((MAX_AGE_DAYS * 86400))

docker ps -aq --filter "name=$CONTAINER_PREFIX" |
while IFS= read -r container_id; do
    [ -n "$container_id" ] || continue
    state=$(docker inspect --format "{{.State.Status}}" "$container_id")
    case "$state" in
        exited)
            ts="$(docker inspect --format "{{.State.FinishedAt}}" "$container_id")"
            ;;
        created)
            ts="$(docker inspect --format "{{.Created}}" "$container_id")"
            ;;
        *)
            continue
            ;;
    esac

    ts_sec="$(date -d "$ts" +%s)"
    age=$((now - ts_sec))

    if [ "$age" -lt "$max_age_sec" ]; then
        continue
    fi

    container_name="$(
        docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | sed 's#^/##'
    )"

    echo "Removing $state container: $container_name ($container_id)"
    docker rm "$container_id"
done

echo "Pruning stale images..."

find "$STATE_DIR" \
    -type f \
    -mtime "+$MAX_AGE_DAYS" \
    -print |
while IFS= read -r state_file; do
    image_id="${state_file##*/}"

    if ! docker image inspect "$image_id" >/dev/null 2>&1; then
        echo "Removing stale metadata: $image_id"
        rm -f "$state_file"
        continue
    fi

    echo "Removing unused image: $image_id"

    if docker image rm "$image_id"; then
        rm -f "$state_file"
    else
        echo "Could not remove $image_id; retaining metadata"
    fi
done

rm -f "$EVENT_FILE"
