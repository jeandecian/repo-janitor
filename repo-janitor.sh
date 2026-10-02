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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENABLE_TAGGING=false
FORCE_REFETCH=false
CUSTOM_TOKEN_FILE=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tag)
            ENABLE_TAGGING=true
            shift
            ;;
        --refresh)
            FORCE_REFETCH=true
            shift
            ;;
        --token-file)
            CUSTOM_TOKEN_FILE="$2"
            shift 2
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

set -- "${POSITIONAL_ARGS[@]}"

WORKSPACE="${1:-.}"
MAX_DEPTH="${2:-2}"

if [ ! -d "$WORKSPACE" ]; then
    echo "${RED}Error: Directory '$WORKSPACE' does not exist.${NC}" >&2
    exit 1
fi

CACHE_DIR="${SCRIPT_DIR}/.cache"
mkdir -p "$CACHE_DIR"

tag_folder() {
    local folder_path="$1"
    local color="$2"

    if [ "$ENABLE_TAGGING" = true ] && [[ "$OSTYPE" == "darwin"* ]]; then
        local abs_path
        abs_path="$(cd "$folder_path" 2>/dev/null && pwd)" || return

        case "$color" in
            "Green")  index=6 ;;
            "Red")    index=2 ;;
            "Yellow") index=3 ;;
            "Purple") index=5 ;;
            *)        index=0 ;;
        esac

        osascript -e "tell application \"Finder\"
            set theItem to (POSIX file \"$abs_path\" as alias)
            set label index of theItem to 0
            set label index of theItem to $index
        end tell" &>/dev/null
    fi
}

AUTH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
token_source=""

if [ -n "$AUTH_TOKEN" ]; then
    token_source="environment variable"
elif [ -n "$CUSTOM_TOKEN_FILE" ] && [ -f "$CUSTOM_TOKEN_FILE" ]; then
    AUTH_TOKEN=$(tr -d '\r\n' < "$CUSTOM_TOKEN_FILE")
    token_source="custom file ($CUSTOM_TOKEN_FILE)"
elif [ -f "${SCRIPT_DIR}/.github_token" ]; then
    AUTH_TOKEN=$(tr -d '\r\n' < "${SCRIPT_DIR}/.github_token")
    token_source="script directory (${SCRIPT_DIR}/.github_token)"
elif [ -f "${WORKSPACE}/.github_token" ]; then
    AUTH_TOKEN=$(tr -d '\r\n' < "${WORKSPACE}/.github_token")
    token_source="workspace directory (${WORKSPACE}/.github_token)"
elif [ -f "TOKEN" ]; then
    AUTH_TOKEN=$(tr -d '\r\n' < "TOKEN")
    token_source="current directory (TOKEN)"
elif [ -f "${HOME}/.github_token" ]; then
    AUTH_TOKEN=$(tr -d '\r\n' < "${HOME}/.github_token")
    token_source="home directory (~/.github_token)"
fi

if [ -n "$AUTH_TOKEN" ]; then
    echo "${GREEN}[INFO]${NC} Token loaded successfully from $token_source."
else
    echo "${YELLOW}[WARN]${NC} No token found. Unauthenticated queries will only retrieve public repositories."
fi

resolved_path="$(cd "$WORKSPACE" && pwd)"
echo "${BLUE}[INFO]${NC} Scanning workspace (depth: $MAX_DEPTH): $resolved_path"

local_git_dirs=()
while IFS= read -r line; do
    [ -n "$line" ] && local_git_dirs+=("$line")
done <<EOF
$(find "$WORKSPACE" -maxdepth "$MAX_DEPTH" -name ".git" -type d 2>/dev/null | sort)
EOF

if [ "${#local_git_dirs[@]}" -eq 0 ]; then
    echo "${YELLOW}[WARN] No Git repositories found in $resolved_path.${NC}"
    exit 0
fi

detected_username=""
for gitdir in "${local_git_dirs[@]}"; do
    [ -z "$gitdir" ] && continue
    repo_path="$(dirname "$gitdir")"
    remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)
    
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/ ]]; then
        detected_username="${BASH_REMATCH[1]}"
        break
    fi
done

if [ -z "$detected_username" ]; then
    detected_username=$(git config user.name 2>/dev/null || true)
fi

fetch_remote_manifest() {
    local username="$1"
    local cache_file="${CACHE_DIR}/${username}.json"
    local temp_page="${CACHE_DIR}/temp_page_${username}.json"
    local master_file="${CACHE_DIR}/master_${username}.json"
    local max_age=86400
    local perform_fetch=false

    if [ -f "$cache_file" ]; then
        local cached_count
        cached_count=$(jq 'length' "$cache_file" 2>/dev/null || echo 0)
        if [ "$cached_count" -eq 0 ]; then
            perform_fetch=true
        fi
    else
        perform_fetch=true
    fi

    if [ "$FORCE_REFETCH" = true ]; then
        perform_fetch=true
    elif [ "$perform_fetch" = false ]; then
        local file_time
        if [[ "$OSTYPE" == "darwin"* ]]; then
            file_time=$(stat -f %m "$cache_file")
        else
            file_time=$(stat -c %Y "$cache_file")
        fi
        local now
        now=$(date +%s)
        local age=$((now - file_time))

        if [ "$age" -gt "$max_age" ]; then
            perform_fetch=true
        fi
    fi

    if [ "$perform_fetch" = true ]; then
        echo "${BLUE}[INFO]${NC} Cache stale or missing. Fetching repositories from GitHub API..." >&2
        echo "[]" > "$master_file"
        local page=1

        while :; do
            if [ -n "$AUTH_TOKEN" ]; then
                curl -s -H "Authorization: bearer $AUTH_TOKEN" \
                     -H "Accept: application/vnd.github+json" \
                     "https://api.github.com/user/repos?per_page=100&page=${page}&affiliation=owner,collaborator,organization_member" > "$temp_page"
            else
                curl -s -H "Accept: application/vnd.github+json" \
                     "https://api.github.com/users/${username}/repos?per_page=100&page=${page}" > "$temp_page"
            fi

            local page_count
            page_count=$(jq 'length' "$temp_page" 2>/dev/null || echo 0)

            if [ "$page_count" -eq 0 ]; then
                break
            fi

            jq -s '.[0] + .[1]' "$master_file" "$temp_page" > "${master_file}.tmp" && mv "${master_file}.tmp" "$master_file"

            if [ "$page_count" -lt 100 ]; then
                break
            fi

            page=$((page + 1))
        done

        rm -f "$temp_page"

        local final_count
        final_count=$(jq 'length' "$master_file" 2>/dev/null || echo 0)
        if [ "$final_count" -gt 0 ]; then
            mv "$master_file" "$cache_file"
        else
            rm -f "$master_file"
        fi
    fi

    if [ -f "$cache_file" ]; then
        local items_count
        items_count=$(jq 'length' "$cache_file" 2>/dev/null || echo 0)
        if [ "$items_count" -gt 0 ]; then
            echo "${GREEN}[INFO]${NC} Cache read successfully (${cache_file}): ${items_count} remote repos." >&2
        fi
    fi

    if command -v jq &>/dev/null && [ -f "$cache_file" ] && jq -e '. | if type=="array" then true else false end' "$cache_file" >/dev/null 2>&1; then
        echo "$cache_file"
    else
        echo ""
    fi
}

MANIFEST_FILE=""
if [ -n "$detected_username" ]; then
    MANIFEST_FILE=$(fetch_remote_manifest "$detected_username")
fi

echo "${BLUE}[INFO]${NC} Analyzing ${#local_git_dirs[@]} local repositories..."
echo ""

safe_repos=()
dirty_repos=()
unpushed_repos=()
noremote_repos=()
not_found_repos=()

repo_count=0

for gitdir in "${local_git_dirs[@]}"; do
    [ -z "$gitdir" ] && continue
    repo_path="$(dirname "$gitdir")"
    repo_count=$((repo_count + 1))

    uncommitted=$(git -C "$repo_path" status --porcelain 2>/dev/null)
    unpushed=$(git -C "$repo_path" log @{u}.. --oneline 2>/dev/null || true)
    has_remote=$(git -C "$repo_path" remote 2>/dev/null)
    remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)

    remote_found=false
    if [ -n "$MANIFEST_FILE" ] && [ -n "$remote_url" ]; then
        clean_remote_path=$(echo "$remote_url" | sed -E 's/\.git$//; s#/$##; s#^.*github\.com[:/]##i')
        repo_name=$(basename "$clean_remote_path")

        exists_in_json=$(jq -r \
            --arg rpath "$clean_remote_path" \
            --arg rname "$repo_name" \
            '.[] | select(
                ((.full_name | ascii_downcase) == ($rpath | ascii_downcase)) or
                ((.name | ascii_downcase) == ($rname | ascii_downcase)) or
                ((.ssh_url | ascii_downcase) | contains($rpath | ascii_downcase)) or
                ((.clone_url | ascii_downcase) | contains($rpath | ascii_downcase))
            ) | .name' "$MANIFEST_FILE" 2>/dev/null | head -n 1)

        if [ -n "$exists_in_json" ]; then
            remote_found=true
        fi
    fi

    if [ -z "$has_remote" ]; then
        noremote_repos+=("    $repo_path")
        tag_folder "$repo_path" "Yellow"

    elif [ -n "$MANIFEST_FILE" ] && [ "$remote_found" = false ]; then
        not_found_repos+=("    $repo_path")
        tag_folder "$repo_path" "Purple"

    elif [ -n "$uncommitted" ]; then
        file_count=$(echo "$uncommitted" | grep -c .)
        entry="    $repo_path ($file_count file(s) changed)"

        if [ "$file_count" -lt 5 ]; then
            while read -r line; do
                [ -n "$line" ] && entry="${entry}"$'\n'"        └── $line"
            done <<< "$uncommitted"
        fi

        dirty_repos+=("$entry")
        tag_folder "$repo_path" "Yellow"
    elif [ -n "$unpushed" ]; then
        unpushed_repos+=("    $repo_path")
        tag_folder "$repo_path" "Red"
    else
        safe_repos+=("    $repo_path")
        tag_folder "$repo_path" "Green"
    fi
done

if [ "${#safe_repos[@]}" -gt 0 ]; then
    echo "${GREEN}[SAFE TO DELETE - REMOTE CLEAN] Clean working tree & verified on remote (${#safe_repos[@]}):${NC}"
    for item in "${safe_repos[@]}"; do
        echo "$item"
    done
    echo ""
fi

if [ "${#dirty_repos[@]}" -gt 0 ]; then
    echo "${YELLOW}[REMOTE - DIRTY] Uncommitted or untracked changes exist (${#dirty_repos[@]}):${NC}"
    for item in "${dirty_repos[@]}"; do
        echo "$item"
    done
    echo ""
fi

if [ "${#unpushed_repos[@]}" -gt 0 ]; then
    echo "${RED}[REMOTE - UNPUSHED] Local commits exist ahead of upstream (${#unpushed_repos[@]}):${NC}"
    for item in "${unpushed_repos[@]}"; do
        echo "$item"
    done
    echo ""
fi

if [ "${#not_found_repos[@]}" -gt 0 ]; then
    echo "${PURPLE}[NOT FOUND IN REMOTE] Has tracking remote URL, but missing from remote API (${#not_found_repos[@]}):${NC}"
    for item in "${not_found_repos[@]}"; do
        echo "$item"
    done
    echo ""
fi

if [ "${#noremote_repos[@]}" -gt 0 ]; then
    echo "${YELLOW}[NO REMOTE] No tracking remote configured (${#noremote_repos[@]}):${NC}"
    for item in "${noremote_repos[@]}"; do
        echo "$item"
    done
    echo ""
fi

echo "${BLUE}[INFO]${NC} Total local repositories scanned: $repo_count | Total safe to delete: ${#safe_repos[@]}"
