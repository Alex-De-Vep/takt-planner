#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

version=0.1.9
previous=0.1.8
root=/opt/takt-server
install_dir="$root/app"
env_file="$root/config/server.env"
candidate=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
ready_url=http://127.0.0.1:3030/health/ready
public_origin=https://takt-server.tail037e91.ts.net

compose() {
    docker compose --project-name takt-server --project-directory "$install_dir" \
        --env-file "$env_file" -f "$install_dir/compose.yaml" "$@"
}

ready_version() {
    curl --max-time 5 --fail --silent --show-error "$ready_url" |
        python3 -c 'import json,sys; health=json.load(sys.stdin); print(health["version"] if health["status"]=="ready" else "")'
}

check_config() {
    curl --fail --silent --show-error --max-time 8 http://127.0.0.1:3030/v1/config |
        python3 -c 'import json,sys;c=json.load(sys.stdin);assert c["protocolVersion"]==1 and c["serverVersion"]==sys.argv[1] and c["limits"]["maxNoteFormatVersion"]==1 and c["limits"]["noteEventsVersion"]==1 and c["limits"]["taskEventsVersion"]==1 and c["limits"]["refreshOperationVersion"]==1' "$version"
}

check_support() {
    compose exec -T api node --input-type=module -e 'import {loadConfig} from "./dist/config.js"; if (!loadConfig().supportEmail) throw new Error("MAIL_FROM must identify a single mailbox");'
    [[ $(compose exec -T db psql -X -U planner -d planner -At -c "SELECT name FROM schema_migrations WHERE name='008_support_requests.sql'") == '008_support_requests.sql' ]]
    curl --fail --silent --show-error --max-time 8 http://127.0.0.1:3030/v1/openapi.json |
        python3 -c 'import json,sys; spec=json.load(sys.stdin); assert spec["paths"]["/v1/support/requests"]["post"]["responses"]["200"]["content"]["application/json"]["schema"]["$ref"] == "#/components/schemas/SupportReceipt"'
}

if [[ $EUID != 0 ]]; then
    echo "Run this upgrade with sudo." >&2
    exit 1
fi
exec 9>"$root/.upgrade.lock"
flock -n 9

running=$(ready_version)
if [[ $running == "$version" ]]; then
    check_config
    check_support
    exit
fi
if [[ $running != "$previous" || $candidate == "$install_dir" ]]; then
    echo "Expected the installed Takt Server $previous and a separate staging folder." >&2
    exit 1
fi

# Reuse the live host, volume, database and port settings.
[[ $(compose exec -T api node -e 'console.log(new URL(process.env.PUBLIC_BASE_URL).origin)') == "$public_origin" ]]
[[ $(compose ps -q db) != "" ]]
docker image inspect "takt-server:$version" >/dev/null
(cd "$candidate" && sha256sum -c SHA256SUMS >/dev/null)

backup="$root/releases/$previous-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 "$backup"
next=$(mktemp -d "$root/.app-$version.XXXXXXXX")
cp -a "$candidate/." "$next/"
chown -R root:root "$next"
chmod 755 "$next"
python3 - "$install_dir/compose.yaml" "$next/compose.yaml" "$previous" "$version" <<'PY'
from pathlib import Path
import re
import sys

source, target, previous, version = sys.argv[1:]
compose = Path(source).read_text()
images = [f'takt-server:{previous}', 'takt-server:${PLANNER_SERVER_VERSION:-' + previous + '}']
pattern = r"(?m)^(  image: )(?:" + "|".join(map(re.escape, images)) + r")$"
updated, count = re.subn(pattern, lambda match: f"{match[1]}takt-server:{version}", compose)
if count != 1:
    raise SystemExit("Unexpected image configuration in installed compose.yaml.")
Path(target).write_text(updated)
PY

maintenance=0
worker_stopped=0
cleanup() {
    local status=$?
    trap - EXIT
    if (( status != 0 )); then
        echo "Upgrade failed. Starting the previous application with the existing volumes." >&2
        if [[ -d "$backup/app" ]]; then
            if [[ -d "$install_dir" ]]; then mv -- "$install_dir" "$backup/failed-app"; fi
            mv -- "$backup/app" "$install_dir"
        fi
        if (( maintenance )); then
            compose exec -T api node dist/main.js maintenance off ||
                compose run --rm -T --no-deps --pull never migrate node dist/main.js maintenance off
        fi
        if (( worker_stopped )); then
            compose up -d --no-build --pull never --no-deps --wait --wait-timeout 90 api worker
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

compose exec -T api node dist/main.js maintenance on
maintenance=1
worker_stopped=1
compose stop worker
compose exec -T db pg_dump -U planner -d planner -Fc > "$backup/database.dump"
compose exec -T db pg_restore --list < "$backup/database.dump" > "$backup/database.contents"
compose exec -T api tar -C /data -cf - blobs > "$backup/blobs.tar"
tar -tf "$backup/blobs.tar" > "$backup/blobs.contents"
(cd "$backup" && sha256sum database.dump blobs.tar > SHA256SUMS && sha256sum -c SHA256SUMS)

mv -- "$install_dir" "$backup/app"
mv -- "$next" "$install_dir"
compose config --quiet
compose run --rm -T --no-deps --pull never migrate
compose exec -T api node dist/main.js maintenance off
maintenance=0
compose up -d --no-build --pull never --no-deps --wait --wait-timeout 90 api worker
[[ $(ready_version) == "$version" ]]
check_config
check_support

trap - EXIT INT TERM
printf 'Takt Server %s is ready. Upgrade backup: %s\n' "$version" "$backup"
