#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
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
echo "${BLUE}[INFO]${NC} Analyzing repositories..."
echo ""

safe_repos=""
dirty_repos=""
unpushed_repos=""
noremote_repos=""

repo_count=0
safe_count=0
dirty_count=0
unpushed_count=0
noremote_count=0

while read -r gitdir; do
    [ -z "$gitdir" ] && continue
    repo_path="$(dirname "$gitdir")"
    repo_count=$((repo_count + 1))

    uncommitted=$(git -C "$repo_path" status --porcelain 2>/dev/null)
    unpushed=$(git -C "$repo_path" log @{u}.. --oneline 2>/dev/null || true)
    has_remote=$(git -C "$repo_path" remote 2>/dev/null)

    if [ -z "$has_remote" ]; then
        noremote_repos="${noremote_repos}    $repo_path\n"
        noremote_count=$((noremote_count + 1))
    elif [ -n "$uncommitted" ]; then
        dirty_repos="${dirty_repos}    $repo_path\n"
        dirty_count=$((dirty_count + 1))
    elif [ -n "$unpushed" ]; then
        unpushed_repos="${unpushed_repos}    $repo_path\n"
        unpushed_count=$((unpushed_count + 1))
    else
        safe_repos="${safe_repos}    $repo_path\n"
        safe_count=$((safe_count + 1))
    fi

done <<EOF
$(find "$WORKSPACE" -maxdepth "$MAX_DEPTH" -name ".git" -type d 2>/dev/null | sort)
EOF

if [ $safe_count -gt 0 ]; then
    echo "${GREEN}[SAFE TO DELETE] Clean working tree & up to date ($safe_count):${NC}"
    echo "$safe_repos"
fi

if [ $dirty_count -gt 0 ]; then
    echo "${YELLOW}[DIRTY] Uncommitted or untracked changes exist ($dirty_count):${NC}"
    echo "$dirty_repos"
fi

if [ $unpushed_count -gt 0 ]; then
    echo "${RED}[UNPUSHED] Local commits exist ahead of upstream ($unpushed_count):${NC}"
    echo "$unpushed_repos"
fi

if [ $noremote_count -gt 0 ]; then
    echo "${PURPLE}[NO REMOTE] No tracking remote configured ($noremote_count):${NC}"
    echo "$noremote_repos"
fi

echo "${BLUE}[INFO]${NC} Total repositories: $repo_count | Safe to delete: $safe_count"
