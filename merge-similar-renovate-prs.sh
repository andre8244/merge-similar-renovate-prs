#!/usr/bin/env bash
#
# merge-similar-renovate-prs.sh
#
# Find pull requests with the same exact title across the NethServer and
# nethesis GitHub organizations, list them (open ones first, with CI check
# status), and squash-merge the ones whose checks are passing after a single
# confirmation.
#
set -euo pipefail

OWNERS=(NethServer nethesis)
LIMIT=100
ASSUME_YES=0
DRY_RUN=0
AUTO_PENDING=0
TITLE=""

usage() {
    cat <<'EOF'
Usage: merge-similar-renovate-prs.sh [options] "<pr title>"

Searches the NethServer and nethesis organizations for pull requests whose
title matches <pr title> exactly (case-insensitive), lists them with their CI
check status, and squash-merges the open ones that are ready to merge.

Options:
  -l, --limit N    maximum number of search results to fetch (default: 100)
  -y, --yes        do not ask for confirmation before merging
  -n, --dry-run    only list the pull requests, never merge
  -a, --auto       additionally enable GitHub auto-merge on pull requests whose
                   checks are still running: GitHub merges them later, on its
                   own, but only if every check ends up passing
  -h, --help       show this help

Pull requests with failing or missing checks, draft pull requests and pull
requests with conflicts are never merged. Pull requests with pending checks are
only touched with --auto.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--limit)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            LIMIT="$2"
            [[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit must be a number"
            shift 2
            ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -a|--auto)
            AUTO_PENDING=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            [[ -z "$TITLE" ]] || die "only one pull request title can be given"
            TITLE="$1"
            shift
            ;;
    esac
done

if [[ -z "$TITLE" && $# -gt 0 ]]; then
    TITLE="$1"
    shift
fi

[[ -n "$TITLE" ]] || { usage >&2; exit 2; }

command -v gh >/dev/null 2>&1 || die "gh is not installed - see https://cli.github.com"
command -v jq >/dev/null 2>&1 || die "jq is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated - run: gh auth login"

# Colors, only when writing to a terminal.
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

owner_args=()
for owner in "${OWNERS[@]}"; do
    owner_args+=(--owner "$owner")
done

# GitHub's search syntax chokes on ":", parentheses and similar characters, so
# they are replaced by spaces in the search term. Titles such as
# "chore(deps): update dependency sass to v1.104.0" would otherwise be rejected
# with "Invalid search query". The exact title match is applied afterwards on
# the results, so nothing unwanted slips through.
SEARCH_TERM="$(printf '%s' "$TITLE" | tr ':()[]{}<>"/\\,' ' ' | tr -s ' ')"
SEARCH_TERM="${SEARCH_TERM#"${SEARCH_TERM%%[![:space:]]*}"}"
SEARCH_TERM="${SEARCH_TERM%"${SEARCH_TERM##*[![:space:]]}"}"
[[ -n "$SEARCH_TERM" ]] || die "the title contains no searchable text"

echo "${C_BOLD}Searching for pull requests titled:${C_RESET} $TITLE"
echo "${C_DIM}Organizations: ${OWNERS[*]}${C_RESET}"
if [[ "$SEARCH_TERM" != "$TITLE" ]]; then
    echo "${C_DIM}Search term:   $SEARCH_TERM (special characters dropped)${C_RESET}"
fi
echo

gh search prs "${owner_args[@]}" --match title "$SEARCH_TERM" --limit "$LIMIT" \
    --json number,title,url,state,repository,isDraft,updatedAt \
    > "$SCRATCH/search.json" || die "gh search prs failed"

# gh search is fuzzy: keep only exact (case-insensitive) title matches.
jq --arg t "$TITLE" '
    [ .[]
      | select((.title | ascii_downcase) == ($t | ascii_downcase))
      | {number, title, url, state, isDraft, updatedAt,
         repo: .repository.nameWithOwner}
    ]
    | sort_by(.repo, .number)
' "$SCRATCH/search.json" > "$SCRATCH/matches.json"

total=$(jq 'length' "$SCRATCH/matches.json")
if [[ "$total" -eq 0 ]]; then
    echo "No pull requests found with that exact title."
    exit 0
fi

jq -r '.[] | select(.state == "open") | .url' "$SCRATCH/matches.json" > "$SCRATCH/open_urls.txt"
open_count=$(wc -l < "$SCRATCH/open_urls.txt" | tr -d ' ')

# Fetch merge state and check rollup for the open pull requests, in parallel.
if [[ "$open_count" -gt 0 ]]; then
    export SCRATCH
    fetch_details() {
        url="$1"
        out="$SCRATCH/detail-$(echo -n "$url" | tr -c 'A-Za-z0-9' '_').json"
        gh pr view "$url" \
            --json state,isDraft,mergeable,mergeStateStatus,statusCheckRollup \
            > "$out" 2>/dev/null || echo '{}' > "$out"
    }
    export -f fetch_details
    echo "${C_DIM}Fetching check status for $open_count open pull request(s)...${C_RESET}"
    xargs -a "$SCRATCH/open_urls.txt" -r -I{} -P 8 \
        bash -c 'fetch_details "$@"' _ {}
    echo
fi

detail_file() {
    echo "$SCRATCH/detail-$(echo -n "$1" | tr -c 'A-Za-z0-9' '_').json"
}

# Derive PASSING / PENDING / FAILING / NO CHECKS from the status check rollup.
check_status() {
    jq -r '
        (.statusCheckRollup // []) as $r
        | if ($r | length) == 0 then "NO CHECKS"
          elif ($r | map(select(
                (.__typename == "CheckRun"
                 and (.conclusion // "") as $c
                 | ["FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"]
                   | index($c) != null)
                or (.__typename == "StatusContext"
                    and ((.state // "") as $s | ["FAILURE","ERROR"] | index($s) != null))
              )) | length) > 0 then "FAILING"
          elif ($r | map(select(
                (.__typename == "CheckRun" and (.status // "") != "COMPLETED")
                or (.__typename == "StatusContext" and (.state // "") == "PENDING")
              )) | length) > 0 then "PENDING"
          else "PASSING"
          end
    ' "$1"
}

# ---------------------------------------------------------------- open PRs ---
merge_urls=()
auto_urls=()
skipped=0
index=0

echo "${C_BOLD}Open pull requests${C_RESET}"
if [[ "$open_count" -eq 0 ]]; then
    echo "  (none)"
else
    while IFS=$'\t' read -r repo number url is_draft; do
        index=$((index + 1))
        df="$(detail_file "$url")"
        status="$(check_status "$df")"
        mergeable="$(jq -r '.mergeable // "UNKNOWN"' "$df")"
        [[ "$(jq -r '.isDraft // false' "$df")" == "true" ]] && is_draft="true"

        if [[ "$is_draft" == "true" ]]; then
            label="DRAFT"; color="$C_YELLOW"; icon="*"; ready=0
        elif [[ "$mergeable" == "CONFLICTING" ]]; then
            label="CONFLICT"; color="$C_RED"; icon="!"; ready=0
        else
            case "$status" in
                PASSING)   label="PASSING";   color="$C_GREEN";  icon="+"; ready=1 ;;
                PENDING)   label="PENDING";   color="$C_YELLOW"; icon="~"; ready=0 ;;
                FAILING)   label="FAILING";   color="$C_RED";    icon="x"; ready=0 ;;
                *)         label="NO CHECKS"; color="$C_YELLOW"; icon="?"; ready=0 ;;
            esac
        fi

        printf '  [%2d] %s%s %-10s%s %-34s %s\n' \
            "$index" "$color" "$icon" "$label" "$C_RESET" "${repo}#${number}" "$url"

        if [[ "$ready" -eq 1 ]]; then
            merge_urls+=("$url")
        elif [[ "$AUTO_PENDING" -eq 1 && "$label" == "PENDING" ]]; then
            auto_urls+=("$url")
        else
            skipped=$((skipped + 1))
        fi
    done < <(jq -r '.[] | select(.state == "open")
                    | [.repo, (.number|tostring), .url, (.isDraft|tostring)]
                    | @tsv' "$SCRATCH/matches.json")
fi

# ------------------------------------------------------- closed / merged PRs ---
closed_count=$(jq '[.[] | select(.state != "open")] | length' "$SCRATCH/matches.json")
if [[ "$closed_count" -gt 0 ]]; then
    echo
    echo "${C_BOLD}Closed / merged pull requests${C_RESET} ${C_DIM}(not merged by this script)${C_RESET}"
    while IFS=$'\t' read -r repo number url state; do
        printf '  %s%-12s %-34s %s%s\n' \
            "$C_DIM" "$state" "${repo}#${number}" "$url" "$C_RESET"
    done < <(jq -r '.[] | select(.state != "open")
                    | [.repo, (.number|tostring), .url, .state]
                    | @tsv' "$SCRATCH/matches.json")
fi

echo
echo "${C_BOLD}Summary:${C_RESET} $total matching pull request(s) - $open_count open, $closed_count closed/merged"
echo "         ${#merge_urls[@]} ready to merge, $skipped open skipped (draft, conflicting, or checks not passing)"
if [[ "$AUTO_PENDING" -eq 1 ]]; then
    echo "         ${#auto_urls[@]} with pending checks, queued for auto-merge"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    echo "Dry run: nothing was merged."
    exit 0
fi

if [[ "${#merge_urls[@]}" -eq 0 && "${#auto_urls[@]}" -eq 0 ]]; then
    echo
    echo "No pull request is ready to merge. Nothing to do."
    exit 0
fi

# ------------------------------------------------------------- confirmation ---
if [[ "$ASSUME_YES" -eq 0 ]]; then
    echo
    if [[ "${#auto_urls[@]}" -gt 0 ]]; then
        printf 'Merge the %d pull request(s) marked PASSING and enable auto-merge on %d PENDING one(s)? [yes/N] ' \
            "${#merge_urls[@]}" "${#auto_urls[@]}"
    else
        printf 'Merge the %d pull request(s) marked PASSING with --squash? [yes/N] ' "${#merge_urls[@]}"
    fi
    answer=""
    if { exec 3</dev/tty; } 2>/dev/null; then
        read -r answer <&3 || true
        exec 3<&-
    else
        read -r answer || true
    fi
    case "${answer,,}" in
        y|yes) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# ------------------------------------------------------------------- merge ---
echo
merged=0
failed=0
for url in "${merge_urls[@]}"; do
    printf '  Merging %-60s ... ' "$url"
    if output=$(gh pr merge "$url" --squash --delete-branch 2>&1); then
        echo "${C_GREEN}done${C_RESET}"
        merged=$((merged + 1))
    else
        echo "${C_RED}failed${C_RESET}"
        echo "$output" | sed 's/^/      /'
        failed=$((failed + 1))
    fi
done

queued=0
for url in "${auto_urls[@]}"; do
    printf '  Auto-merge %-60s ... ' "$url"
    if output=$(gh pr merge "$url" --auto --squash --delete-branch 2>&1); then
        echo "${C_GREEN}queued${C_RESET}"
        queued=$((queued + 1))
    else
        echo "${C_RED}failed${C_RESET}"
        echo "$output" | sed 's/^/      /'
        failed=$((failed + 1))
    fi
done

echo
echo "${C_BOLD}Merged $merged / ${#merge_urls[@]}${C_RESET}, failed $failed"
if [[ "$AUTO_PENDING" -eq 1 ]]; then
    echo "${C_BOLD}Auto-merge enabled on $queued / ${#auto_urls[@]}${C_RESET} pull request(s) with pending checks"
fi
[[ "$failed" -eq 0 ]] || exit 1
