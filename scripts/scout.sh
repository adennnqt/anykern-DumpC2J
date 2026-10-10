#!/bin/bash
set -eo pipefail

BUILDER_DIR="${GITHUB_WORKSPACE}/builder"
source "${BUILDER_DIR}/scripts/functions.sh"

MANIFEST="${BUILDER_DIR}/scripts/checkpoint/manifest.json"
[ -f "$MANIFEST" ] || error "scout: manifest.json not found at ${MANIFEST}"

CURL_AUTH=()
if [ -n "${GH_TOKEN:-}" ]; then CURL_AUTH=(-H "Authorization: token $GH_TOKEN"); fi

latest_sha_or_empty() {
    local label="$1" url="$2" jq_filter="$3"
    local body_file http_code curl_exit sha

    body_file="$(mktemp)"
    if http_code=$(curl -sL -o "$body_file" -w '%{http_code}' --max-time 20 "${CURL_AUTH[@]}" "$url"); then
        curl_exit=0
    else
        curl_exit=$?
    fi

    if [ "$curl_exit" -ne 0 ] || [ "$http_code" != "200" ]; then
        warn "scout: couldn't reach upstream for ${label} (curl exit ${curl_exit}, HTTP ${http_code:-000}) — using pinned ref"
        rm -f "$body_file"; echo ""; return 0
    fi

    sha=$(jq -r "$jq_filter" "$body_file" 2>/dev/null)
    rm -f "$body_file"
    if [ -z "$sha" ] || [ "$sha" = "null" ]; then
        warn "scout: couldn't parse latest ${label} commit — using pinned ref"
        echo ""; return 0
    fi
    echo "$sha"
}

ref_exists() {
    local url_template="$1" sha="$2"
    local repo_base branch compare_url status
    [ -n "$sha" ] && [ "$sha" != "null" ] || return 1

    case "$url_template" in
        *api.github.com*/commits/*)
            repo_base="${url_template%/commits/*}"
            branch="${url_template##*/commits/}"
            compare_url="${repo_base}/compare/${branch}...${sha}"
            status=$(curl -sL --max-time 15 "${CURL_AUTH[@]}" "$compare_url" 2>/dev/null | jq -r '.status // empty')
            [ "$status" = "identical" ] || [ "$status" = "behind" ]
            ;;
        *)
            local check_url http_code
            check_url="${url_template%/*}/${sha}"
            http_code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 15 "${CURL_AUTH[@]}" "$check_url" 2>/dev/null) || return 1
            [ "$http_code" = "200" ]
            ;;
    esac
}

log_commits_since() {
    local prefix="$1" base="$2" head="$3" url_template="$4"
    [ -n "$base" ] || return 0
    case "$url_template" in
        *api.github.com*/commits/*)
            repo_base="${url_template%/commits/*}"
            compare_url="${repo_base}/compare/${base}...${head}"
            body=$(curl -sL --max-time 20 "${CURL_AUTH[@]}" "$compare_url" 2>/dev/null) || return 0
            n=$(echo "$body" | jq -r '[.commits[]?.commit.message]|length' 2>/dev/null || echo 0)
            case "$n" in ''|0|null)
                log "${prefix}: can't list commits ${base:0:12}..${head:0:12} (rate-limited?)"
                return 0
                ;;
            esac
            log "${prefix}: ${n} upstream commit(s) between ${base:0:12}..${head:0:12}:"
            echo "$body" | jq -r '.commits[]?.commit.message // empty' 2>/dev/null | head -10 | sed 's/^/\t- /' || true
            [ "$n" -le 10 ] || log "${prefix}:   ... and $((n - 10)) more"
            ;;
    esac
}

resolve_component() {
    local key="$1" prefix="$2" latest="$3" url_template="$4"
    local good bad_list is_bad ref candidate manual

    good=$(jq -r ".${key}.good" "$MANIFEST")
    bad_list=$(jq -c ".${key}.bad" "$MANIFEST")
    manual=$(jq -r ".${key}.manual // false" "$MANIFEST")

    if [ -n "$good" ] && [ "$good" != "null" ] && [ -n "$url_template" ]; then
        if ! ref_exists "$url_template" "$good"; then
            warn "${prefix}: pinned good ${good:0:12} no longer in remote (force-push/rewrite upstream?) — treat as unpinned"
            good=""
        fi
    fi

    if [ "$manual" = "true" ]; then
        [ -n "$good" ] || error "scout: ${key} is manual-pinned but has no good pin."
        ref="$good"; candidate="false"
        log "${prefix}: manual-pinned ${ref:0:12} (bump deliberately, coordinates with kernel hooks)"
    elif [ -n "$latest" ] && [ "$latest" != "null" ]; then
        is_bad=$(echo "$bad_list" | jq --arg sha "$latest" 'any(. == $sha)')
        if [ "$is_bad" = "true" ]; then
            if [ -n "$good" ]; then
                ref="$good"; candidate="false"
                warn "${prefix}: latest ${latest:0:12} known-bad — falling back to pinned ${good:0:12}"
            else
                ref="$latest"; candidate="true"
                warn "${prefix}: latest ${latest:0:12} known-bad & no pin yet — last-resort: testing it anyway"
            fi
        else
            ref="$latest"
            if [ "$latest" = "$good" ]; then
                candidate="false"
                log "${prefix}: up to date at ${latest:0:12}"
            else
                candidate="true"
                log "${prefix}: building latest ${latest:0:12} (previous pin: ${good:-none})"
                log_commits_since "$prefix" "$good" "$latest" "$url_template"
            fi
        fi
    elif [ -n "$good" ]; then
        ref="$good"; candidate="false"
        log "${prefix}: no latest resolvable — using pinned ${good:0:12}"
    else
        error "scout: no resolvable ref for ${key} (no latest, no pin)"
    fi

    echo "${prefix}_REF=${ref}" >> "$GITHUB_ENV"
    echo "CANDIDATE_${prefix}=${candidate}" >> "$GITHUB_ENV"
}

scout_track() {
  local key="$1" prefix="$2"
  local label url filter latest manual
  manual=$(jq -r ".${key}.manual // false" "$MANIFEST")
  url=$(source_url "$key")
  if [ "$manual" != "true" ]; then
    label=$(source_label "$key")
    filter=$(source_filter "$key")
    latest=$(latest_sha_or_empty "$label" "$url" "$filter")
  else
    latest=""
  fi
  resolve_component "$key" "$prefix" "$latest" "$url"
}

case "$ROOT" in
  sukisu)
    if [ "$VARIANT" == "susfs" ]; then
      scout_track "sukisu_susfs" "SUKISU_SUSFS"
    else
      scout_track "sukisu_root" "SUKISU_ROOT"
    fi
    ;;
  bakasu)
    if [ "$VARIANT" == "susfs" ]; then
      scout_track "bakasu_susfs" "BAKASU_SUSFS"
    else
      scout_track "bakasu_root" "BAKASU_ROOT"
    fi
    ;;
  ksu-next)
    if [ "$VARIANT" == "susfs" ]; then
      scout_track "ksunext_susfs" "KSUNEXT_SUSFS"
    else
      scout_track "ksunext_root" "KSUNEXT_ROOT"
    fi
    ;;
  *)
    log "scout: ROOT=none — nothing to track"
    ;;
esac

if [ "$VARIANT" == "susfs" ]; then
  scout_track "susfs4ksu" "SUSFS4KSU"
fi
