#!/bin/sh

# Keep pmon.service in "activating" until the AG9032v1 platform API and the
# daemons which consume it are usable.  On the first boot, docker_init may need
# to install or repair the platform wheel before supervisord can start them.
set -eu

timeout_seconds="${PMON_READY_TIMEOUT_SECONDS:-600}"
interval_seconds="${PMON_READY_INTERVAL_SECONDS:-5}"
docker_bin="${DOCKER_BIN:-/usr/bin/docker}"

case "${timeout_seconds}" in
    *[!0-9]* | 0)
        echo "Invalid pmon readiness timeout/interval: ${timeout_seconds}/${interval_seconds}" >&2
        exit 2
        ;;
esac
case "${interval_seconds}" in
    *[!0-9]* | 0)
        echo "Invalid pmon readiness timeout/interval: ${timeout_seconds}/${interval_seconds}" >&2
        exit 2
        ;;
esac

log()
{
    echo "ag9032v1 pmon readiness: $*"
    if command -v logger >/dev/null 2>&1; then
        logger -t ag9032v1-pmon-ready -- "$*" || true
    fi
}

elapsed=0
last_status="pmon container is not running"

while [ "${elapsed}" -lt "${timeout_seconds}" ]; do
    if [ "$("${docker_bin}" inspect --format '{{.State.Running}}' pmon 2>/dev/null || true)" = "true" ]; then
        if "${docker_bin}" exec pmon python3 -c \
            'from sonic_platform.platform import Platform' >/dev/null 2>&1; then
            last_status="$("${docker_bin}" exec pmon supervisorctl status \
                psud thermalctld xcvrd 2>&1 || true)"
            running_count="$(printf '%s\n' "${last_status}" | \
                awk '$2 == "RUNNING" { count++ } END { print count + 0 }')"
            if [ "${running_count}" -eq 3 ]; then
                log "Platform API, psud, thermalctld, and xcvrd are ready"
                exit 0
            fi
        else
            last_status="Platform API import is not ready"
        fi
    fi

    sleep "${interval_seconds}"
    elapsed=$((elapsed + interval_seconds))
done

log "timed out after ${timeout_seconds}s; last observed state: ${last_status}"
exit 1
