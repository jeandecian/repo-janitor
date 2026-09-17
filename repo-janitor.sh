#!/usr/bin/env bash

RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "=================================================="
echo "                 REPO JANITOR CLI                 "
echo "              Local Workspace Cleanup             "
echo "=================================================="

WORKSPACE="${1:-.}"
MAX_DEPTH="${2:-2}"

if [ ! -d "$WORKSPACE" ]; then
    echo "${RED}Error: Directory '$WORKSPACE' does not exist.${NC}" >&2
    exit 1
fi

resolved_path="$(cd "$WORKSPACE" && pwd)"
echo "${BLUE}[INFO]${NC} Scanning (depth: $MAX_DEPTH) $resolved_path"
echo "${BLUE}[INFO]${NC} Found repositories:"

repo_count=0

while read -r gitdir; do
    [ -z "$gitdir" ] && continue
    repo_path="$(dirname "$gitdir")"
    
    echo "${BLUE}[INFO]${NC}    $repo_path"
    repo_count=$((repo_count + 1))
done <<EOF
$(find "$WORKSPACE" -maxdepth "$MAX_DEPTH" -name ".git" -type d 2>/dev/null | sort)
EOF

echo "${BLUE}[INFO]${NC} Total repositories found: $repo_count"
