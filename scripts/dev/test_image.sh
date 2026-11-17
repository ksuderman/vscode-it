#!/bin/bash
# Verify the image the way Galaxy's Docker runner uses it, in both modes.
#
#   test_image.sh [IMAGE]      default: @CONTAINER@ from tool/macros.xml
#
# Exits non-zero if any check fails.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG=${1:-$(sed -n 's|.*@CONTAINER@">\([^<]*\)<.*|\1|p' "$HERE/../../tool/macros.xml")}
S=$(mktemp -d)
P="--platform linux/amd64"
PORT=${PORT:-3300}
# The restrictions config/job_conf.yml recommends for a multi-user server. The
# sessions below run under them, so a change that needs a capability or a
# setuid helper fails here first.
HARDEN="--cap-drop=ALL --security-opt=no-new-privileges"
FAILED=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1 ($2)"; else echo "FAIL $1: got '$2', wanted '$3'"; FAILED=1; fi; }
wait_for() { # url -> last http code, after up to 60s
    local code=000 i
    for i in $(seq 1 30); do
        code=$(curl -s -o /dev/null -w '%{http_code}' "$1")
        [ "$code" = 200 ] && break
        sleep 2
    done
    echo "$code"
}
# Simulate Galaxy's docker run: tool_script.sh as the command, uid 10001, the job
# directory mounted and used as the working directory. $1 is the EP_PATH line.
launch() {
    JOB=$(mktemp -d "$S/jobdir.XXXX"); chmod 777 "$JOB"
    mkdir -p "$JOB/inputs"; printf 'chr1\t1\t2\n' > "$JOB/inputs/dataset_1.dat"
    cat > "$JOB/tool_script.sh" << TS
$1
export GALAXY_URL=http://example.invalid/galaxy API_KEY=fake HISTORY_ID=abc
mkdir -p workspace/inputs && ln -sf /jobdir/inputs/dataset_1.dat 'workspace/inputs/regions.bed' && exec /opt/galaxy-vscode/start.sh
TS
    CID=$(docker run -d $P $HARDEN --user 10001:10001 -w /jobdir -v "$JOB:/jobdir" -p "$PORT:3000" "$IMG" /bin/sh /jobdir/tool_script.sh)
}
finish() {
    docker logs "$CID" 2>&1 | grep -i "error\|denied" | head -3
    docker rm -f "$CID" > /dev/null
    chmod -R u+w "$JOB" 2>/dev/null; rm -rf "$JOB"
}

echo "== image: $IMG"
docker inspect "$IMG" --format 'Entrypoint={{json .Config.Entrypoint}} Cmd={{json .Config.Cmd}} User={{.Config.User}}' || exit 1

echo "== 1. a command passed to docker run must execute (not be swallowed)"
out=$(docker run --rm $P "$IMG" /bin/sh -c 'echo COMMAND-RAN; for c in python3 R gcloud micromamba conda-pack batch; do command -v $c; done | wc -l')
check "command ran" "$(echo "$out" | head -1)" COMMAND-RAN
check "python3, R, gcloud, micromamba, conda-pack, batch on PATH" "$(echo "$out" | tail -1 | tr -d ' ')" 6
out=$(docker run --rm $P -e GALAXY_BATCH_BUCKET=gs://b -e GALAXY_BATCH_PROJECT=p -e GALAXY_BATCH_REGION=r "$IMG" \
    /bin/sh -c 'batch run --dry-run --cpus 2 Rscript x.R | grep -c -e "\"imageUri\": \"$GALAXY_VSCODE_IMAGE\"" -e "\"cpuMilli\": 2000"')
check "batch run --dry-run uses this image and the requested CPUs" "$out" 2
out=$(docker run --rm $P "$IMG" python3 -c 'import bioblend, ipykernel, numpy, pandas, scipy, sklearn, matplotlib, seaborn; print("IMPORTS-OK")' 2>&1 | tail -1)
check "python data stack imports" "$out" IMPORTS-OK

echo "== 1b. no route to root, including for uid 1000 (the base image's sudo user)"
out=$(docker run --rm $P --user 1000:1000 "$IMG" /bin/sh -c 'command -v sudo; find / -xdev -type f -perm /6000 2>/dev/null; echo END' | tr '\n' ' ')
check "no sudo, no setuid or setgid files" "$out" "END "

echo "== 2. path mode: EP_PATH as Galaxy injects it (no trailing slash)"
launch 'export EP_PATH=/galaxy/its/ep/1/tok'
check "GET /galaxy/its/ep/1/tok/" "$(wait_for "http://localhost:$PORT/galaxy/its/ep/1/tok/")" 200
# The server also answers the workbench page at "/" itself, so probe another path.
check "GET /other (outside the base path)" "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/other")" 404
check "input link" "$(readlink "$JOB/workspace/inputs/regions.bed")" /jobdir/inputs/dataset_1.dat
check "workspace README written" "$(ls "$JOB/workspace/README.md" > /dev/null 2>&1 && echo yes)" yes
check "README leaves out Batch off Google Cloud" "$(grep -c -e 'send it to Batch' -e 'gcloud auth revoke' "$JOB/workspace/README.md" | tr -d ' ')" 1
check "settings.json written" "$(ls "$JOB/home/data/User/settings.json" > /dev/null 2>&1 && echo yes)" yes
finish

echo "== 3. domain mode: Galaxy injects an EMPTY EP_PATH; start.sh must serve from /"
launch 'export EP_PATH='
check "GET /" "$(wait_for "http://localhost:$PORT/")" 200
finish

echo "== 4. EP_PATH unset altogether"
launch 'unset EP_PATH'
check "GET /" "$(wait_for "http://localhost:$PORT/")" 200
finish

rmdir "$S" 2>/dev/null
[ "$FAILED" = 0 ] && echo "== all checks passed" || echo "== FAILURES above"
exit "$FAILED"
