#!/usr/bin/env bash
# Install the VS Code interactive tool into a Galaxy server's tool directory.
#
#   install.sh [--mode path|domain] [--container IMAGE] [--tool-path DIR]
#
# Copies tool/ to <tool-path>/interactive/vscode/ with the macros tokens set for
# the chosen mode, and prints the configuration that still has to be merged by
# hand (galaxy.yml, job_conf.yml, nginx). Does not touch any Galaxy config file.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mode=path
container=""
tool_path=""

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) mode=$2; shift 2 ;;
        --container) container=$2; shift 2 ;;
        --tool-path) tool_path=$2; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

case "$mode" in
    path) requires_domain=False ;;
    domain) requires_domain=True ;;
    *) echo "--mode must be path or domain" >&2; exit 1 ;;
esac

if [[ -z "$tool_path" ]]; then
    for candidate in "${GALAXY_ROOT:-}/tools" ./tools; do
        [[ -n "$candidate" && -d "$candidate" ]] && tool_path=$candidate && break
    done
fi
[[ -n "$tool_path" && -d "$tool_path" ]] || { echo "pass --tool-path <Galaxy tool_path> (usually <galaxy root>/tools)" >&2; exit 1; }

dest="$tool_path/interactive/vscode"
mkdir -p "$dest"
cp "$here/tool/interactivetool_vscode.xml" "$here/tool/vscode.png" "$dest/"
sed -e "s|<token name=\"@REQUIRES_DOMAIN@\">[^<]*</token>|<token name=\"@REQUIRES_DOMAIN@\">$requires_domain</token>|" \
    "$here/tool/macros.xml" > "$dest/macros.xml"
if [[ -n "$container" ]]; then
    sed -i.bak -e "s|<token name=\"@CONTAINER@\">[^<]*</token>|<token name=\"@CONTAINER@\">$container</token>|" "$dest/macros.xml"
    rm -f "$dest/macros.xml.bak"
fi

cat <<MSG
Installed to $dest ($mode mode, container $(sed -n 's|.*@CONTAINER@">\([^<]*\)<.*|\1|p' "$dest/macros.xml")).

Still to do by hand:
  1. Toolbox: add to a tool conf (see $here/config/tool_conf.xml):
       <tool file="interactive/vscode/interactivetool_vscode.xml" />
  2. galaxy.yml: merge the settings for $mode mode from $here/config/galaxy.yml
     (interactivetools_enable, interactivetools_map, proxy settings).
  3. Job routing: a Docker-enabled or Kubernetes destination, see
     $here/config/job_conf.yml or $here/config/tpv_rules.yml.
  4. Conventional servers: gx-it-proxy plus the $mode-mode nginx fragment in
     $here/config/nginx.conf. Domain mode also needs the wildcard DNS record and
     certificate described there.
Then restart Galaxy (tool XML is read at startup).
MSG
