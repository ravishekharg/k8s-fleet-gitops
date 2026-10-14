#!/usr/bin/env bash
# Publish the current fleet/ directory to the lab Git server as one commit: what a merged PR is.
#   bash scripts/push-fleet.sh "message"
set -euo pipefail
cd "$(dirname "$0")/.."
GIT_PORT=${GIT_PORT:-3300}
GIT_AUTH="fleet:fleet-lab-only"
url="http://$GIT_AUTH@localhost:$GIT_PORT/fleet/fleet.git"
work=$(mktemp -d)
git clone -q "$url" "$work" 2>/dev/null || git -C "$work" init -q -b main
rm -rf "$work/fleet" && cp -r fleet "$work/fleet"
git -C "$work" add -A
if git -C "$work" -c user.name=fleet -c user.email=fleet@example.com commit -qm "${1:-update fleet}"; then
  git -C "$work" push -q "$url" HEAD:main 2>&1 | sed "s/${GIT_AUTH#*:}/***/g"
  echo "   pushed: $(git -C "$work" log -1 --format='%h %s')"
else
  echo "   nothing to push"
fi
rm -rf "$work"
