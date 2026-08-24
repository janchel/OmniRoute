#!/usr/bin/env bash
# cleanup-dev-space.sh — reclaim disk from regenerable build artifacts.
#
# Cleans ONLY these three categories:
#   1. Docker build cache — stale layers from repeated image builds.
#      Keeps the most recent KEEP_CACHE bytes so the next rebuild stays fast.
#   2. Dangling Docker images (`<none>:<none>`) — untagged leftovers from old
#      builds. Images referenced by any container are never touched.
#   3. npm download cache (~/.npm) — packages re-download on demand.
#
# NEVER touches:
#   - Tagged/named images (e.g. omniroute:base, redis:*)
#   - Containers and volumes (your data)
#   - node_modules (hardlink pool shared between checkout and worktrees)
#   - Bind-mounted app data (e.g. ~/.omniroute) or git object store
#
# Usage:
#   scripts/dev/cleanup-dev-space.sh [--dry-run] [--yes] [--keep-storage SIZE]
#
# Env:  KEEP_CACHE=5GB   default bytes kept of freshest build cache

set -euo pipefail

KEEP_CACHE="${KEEP_CACHE:-5GB}"
DRY_RUN=0
ASSUME_YES=0

usage() {
	sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--yes|-y)
		ASSUME_YES=1
		shift
		;;
	--keep-storage)
		KEEP_CACHE="${2:?--keep-storage needs a size, e.g. 5GB}"
		shift 2
		;;
	-h|--help)
		usage
		;;
	*)
		echo "Unknown option: $1 (see --help)" >&2
		exit 2
		;;
	esac
done

run() {
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[dry-run] $*"
	else
		echo "\$ $*"
		"$@"
	fi
}

disk_free() {
	df -h / | awk 'NR==2 {print $4 " free (" 100-$5 "% used)"}'
}

echo "=== Dev space cleanup ==="
echo "Disk before: $(disk_free)"

if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
	printf 'This will prune docker build cache (keeping %s), dangling images,\nand the npm cache. Continue? [y/N] ' "$KEEP_CACHE"
	read -r REPLY
	case "$REPLY" in
	y|Y|yes|Yes) ;;
	*) echo "Aborted."; exit 1 ;;
	esac
fi

echo ""
echo "--- 1/3: Docker build cache (keeping ${KEEP_CACHE} of newest entries) ---"
if command -v docker >/dev/null 2>&1; then
	run docker builder prune -f --keep-storage "$KEEP_CACHE"
else
	echo "docker not found — skipping"
fi

echo ""
echo "--- 2/3: Dangling (<none>) images ---"
if command -v docker >/dev/null 2>&1; then
	run docker image prune -f
else
	echo "docker not found — skipping"
fi

echo ""
echo "--- 3/3: npm download cache ---"
if command -v npm >/dev/null 2>&1; then
	run npm cache clean --force
else
	echo "npm not found — skipping"
fi

echo ""
docker system df 2>/dev/null || true
echo "Disk after:  $(disk_free)"
