#!/bin/bash
#
# github-backup.sh — GitHub mirror engine for BLACKBOX
#
# Mirrors every repository the token owner can access (owner, collaborator,
# organization member) as a bare `git clone --mirror` under $BASE.
#
# Requirements : bash 4.4+, curl 7.55+, git, jq, ssh
#                GitHub token in $TOKEN_FILE, SSH key authorized on GitHub
# Exit codes   : 0 = success, 1 = finished with repo errors, 2 = fatal error
# Environment  : NO_COLOR=1 disables colors (auto-disabled when not a TTY)

set -uo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────

BASE="/volume1/Archivum"
TOKEN_FILE="$HOME/.config/github/token"
LOG_DIR="$BASE/_logs"
LOG_KEEP=30
LOCK_DIR="/tmp/github-backup.lock"
API="https://api.github.com"

RUN_ID=$(date '+%Y-%m-%d_%H-%M-%S')
LOG="$LOG_DIR/github-backup-$RUN_ID.log"
W=64

# Never hang on a credential or host-key prompt (cron / Task Scheduler)
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=20"

# ─── Colors ────────────────────────────────────────────────────────────────

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    IS_TTY=1
    R=$'\033[0m' B=$'\033[1m' D=$'\033[2m'
    RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' BLU=$'\033[34m'
    MAG=$'\033[35m' CYN=$'\033[36m' WHT=$'\033[97m'
else
    IS_TTY=0
    R= B= D= RED= GRN= YEL= BLU= MAG= CYN= WHT=
fi

# ─── UI helpers ────────────────────────────────────────────────────────────

rep() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }

box_top()    { printf '%s╭%s╮%s\n' "$CYN" "$(rep ─ "$W")" "$R"; }
box_sep()    { printf '%s├%s┤%s\n' "$CYN" "$(rep ─ "$W")" "$R"; }
box_bottom() { printf '%s╰%s╯%s\n' "$CYN" "$(rep ─ "$W")" "$R"; }
box_blank()  { printf '%s│%*s│%s\n' "$CYN" "$W" '' "$R"; }

box_center() {  # text [color] — text must be ASCII for correct alignment
    local t=$1 c=${2:-$WHT} l r
    l=$(( (W - ${#t}) / 2 )); r=$(( W - ${#t} - l ))
    printf '%s│%s%*s%s%s%s%*s%s│%s\n' "$CYN" "$R" "$l" '' "$c$B" "$t" "$R" "$r" '' "$CYN" "$R"
}

box_row() {  # label value [color] — value must be ASCII for correct alignment
    local label=$1 value=$2 c=${3:-$WHT} pad
    pad=$(( W - 24 - ${#value} )); (( pad < 0 )) && pad=0
    printf '%s│%s  %s%-22s%s%s%s%s%*s%s│%s\n' \
        "$CYN" "$R" "$D" "$label" "$R" "$c$B" "$value" "$R" "$pad" '' "$CYN" "$R"
}

section() {
    printf '\n%s%s▌ %s%s\n' "$MAG" "$B" "$1" "$R"
    printf '%s%s%s\n' "$D" "$(rep ─ $((W + 2)))" "$R"
}

ok()   { printf '  %s✓%s %-16s %s\n' "$GRN" "$R" "$1" "${2:-}"; }
info() { printf '  %s•%s %-16s %s\n' "$BLU" "$R" "$1" "${2:-}"; }
warn() { printf '  %s!%s %-16s %s%s%s\n' "$YEL" "$R" "$1" "$YEL" "${2:-}" "$R"; }

die() {
    printf '\n  %s%s✗ FATAL%s  %s\n' "$RED" "$B" "$R" "$*"
    printf '  %sLog: %s%s\n\n' "$D" "$LOG" "$R"
    exit 2
}

bar() {  # current total width
    local fill=$(( $1 * $3 / $2 ))
    printf '%s%s%s%s%s' "$CYN" "$(rep █ "$fill")" "$D" "$(rep ░ $(($3 - fill)))" "$R"
}

human_kb() {
    awk -v k="${1:-0}" 'BEGIN {
        split("KB MB GB TB", u, " "); i = 1
        while (k >= 1024 && i < 4) { k /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), k, u[i]
    }'
}

fmt_dur() {
    local s=$1
    if   (( s >= 3600 )); then printf '%dh %02dm %02ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
    elif (( s >= 60 ));   then printf '%dm %02ds' $((s / 60)) $((s % 60))
    else                       printf '%ds' "$s"
    fi
}

# Token goes through stdin so it never shows up in `ps`
gh_api() {
    printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -fsSL \
        --retry 3 --retry-delay 2 --connect-timeout 15 \
        -H @- \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$API$1"
}

refs() { git --git-dir="$1" for-each-ref --format='%(objectname) %(refname)' 2>/dev/null; }

# ─── Setup: logging & lock ─────────────────────────────────────────────────

mkdir -p "$BASE" "$LOG_DIR" || { echo "Cannot create $LOG_DIR" >&2; exit 2; }

(( IS_TTY )) && clear

# Everything goes to the terminal and, stripped of colors, to the log file
exec > >(tee >(awk '{ gsub(/\033\[[0-9;]*[A-Za-z]/, ""); print; fflush() }' >> "$LOG")) 2>&1
TEE_PID=$!

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    OLD_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        die "Another backup is already running (PID $OLD_PID)"
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" || die "Cannot create lock: $LOCK_DIR"
fi
echo $$ > "$LOCK_DIR/pid"

TMP=$(mktemp "/tmp/github-repos-XXXXXX") || die "Cannot create temp file"

cleanup() {
    rm -f "$TMP"
    rm -rf "$LOCK_DIR"
    exec 1>&- 2>&-
    wait "$TEE_PID" 2>/dev/null
}
trap cleanup EXIT

# ─── Banner ────────────────────────────────────────────────────────────────

box_top
box_blank
box_center "G I T H U B    M I R R O R    E N G I N E" "$CYN"
box_center "BLACKBOX" "$WHT"
box_blank
box_bottom
printf '   %sStarted%s   %s\n' "$D" "$R" "$(date '+%Y-%m-%d %H:%M:%S')"
printf '   %sHost%s      %s\n' "$D" "$R" "$(hostname)"
printf '   %sTarget%s    %s\n' "$D" "$R" "$BASE"
printf '   %sLog%s       %s\n' "$D" "$R" "$LOG"

START=$SECONDS

# ─── System check ──────────────────────────────────────────────────────────

section "SYSTEM CHECK"

for cmd in curl git jq ssh; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

ok "git"  "$(git --version | awk '{print $3}')"
ok "curl" "$(curl --version | awk 'NR==1 {print $2}')"
ok "jq"   "$(jq --version 2>&1 | sed 's/^jq-//')"
ok "ssh"  "$(ssh -V 2>&1 | awk -F'[ ,]' '{print $1}')"

[ -s "$TOKEN_FILE" ] || die "GitHub token missing: $TOKEN_FILE"
TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
ok "token" "$TOKEN_FILE"

DISK=$(df -k "$BASE" | awk 'NR==2 {print $4, $2}')
ok "disk" "$(human_kb "${DISK%% *}") free of $(human_kb "${DISK##* }")"

# ─── GitHub API ────────────────────────────────────────────────────────────

section "GITHUB API"

USER_JSON=$(gh_api /user) || die "GitHub API request failed (invalid token or no network)"
GH_USER=$(jq -r '.login // empty' <<< "$USER_JSON")
GH_NAME=$(jq -r '.name // empty' <<< "$USER_JSON")
[ -n "$GH_USER" ] || die "Invalid GitHub token"

ok "account" "${B}$GH_USER${R}${GH_NAME:+ ${D}($GH_NAME)${R}}"

RATE=$(gh_api /rate_limit 2>/dev/null | jq -r '.resources.core | "\(.remaining) / \(.limit)"' 2>/dev/null)
info "rate limit" "${RATE:-n/a}"

# ─── GitHub SSH ────────────────────────────────────────────────────────────

section "GITHUB SSH"

SSH_OUT=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -T git@github.com 2>&1 < /dev/null || true)

if grep -q "successfully authenticated" <<< "$SSH_OUT"; then
    SSH_USER=$(sed -n 's/^Hi \([^!]*\)!.*/\1/p' <<< "$SSH_OUT")
    ok "ssh auth" "key belongs to ${B}${SSH_USER:-?}${R}"
    if [ -n "$SSH_USER" ] && [ "$SSH_USER" != "$GH_USER" ]; then
        warn "mismatch" "SSH key user differs from token user ($GH_USER)"
    fi
else
    printf '  %s%s%s\n' "$D" "$SSH_OUT" "$R"
    die "GitHub SSH authentication failed"
fi

# ─── Repository discovery ──────────────────────────────────────────────────

section "REPOSITORY DISCOVERY"

PAGE=1
while :; do
    RESPONSE=$(gh_api "/user/repos?per_page=100&page=$PAGE&sort=full_name&visibility=all&affiliation=owner%2Ccollaborator%2Corganization_member") \
        || die "GitHub API request failed (page $PAGE)"

    COUNT=$(jq 'length' <<< "$RESPONSE" 2>/dev/null) || die "Unexpected API response (page $PAGE)"
    info "page $PAGE" "$COUNT repos"

    (( COUNT == 0 )) && break

    jq -r '.[] | [
        .full_name,
        .ssh_url,
        (if .private  then "private" else "public" end),
        (if .fork     then 1 else 0 end),
        (if .archived then 1 else 0 end),
        .size
    ] | @tsv' <<< "$RESPONSE" >> "$TMP"

    (( COUNT < 100 )) && break
    PAGE=$((PAGE + 1))
done

TOTAL=$(wc -l < "$TMP" | tr -d ' ')

if (( TOTAL == 0 )); then
    printf '\n  %s%sNo repositories found for %s.%s\n\n' "$YEL" "$B" "$GH_USER" "$R"
    exit 0
fi

read -r N_PRIV N_PUB N_FORK N_ARCH API_KB < <(awk -F'\t' '
    { if ($3 == "private") p++; else u++; f += $4; a += $5; s += $6 }
    END { printf "%d %d %d %d %d\n", p, u, f, a, s }' "$TMP")

# Repo names that occur under several owners get an "owner__" prefix
DUPES=$(awk -F'\t' '{ n = $2; sub(/.*\//, "", n); sub(/\.git$/, "", n); c[n]++ }
    END { for (k in c) if (c[k] > 1) print k }' "$TMP")

echo
ok "found" "${GRN}${B}$TOTAL repositories${R}"
info "visibility" "${YEL}$N_PRIV private${R}  ${D}/${R}  $N_PUB public"
info "special" "$N_FORK forks  ${D}/${R}  $N_ARCH archived"
info "size on GitHub" "~$(human_kb "$API_KB")"
[ -n "$DUPES" ] && warn "name clash" "$(tr '\n' ' ' <<< "$DUPES")-> owner__name.git"

# ─── Mirroring ─────────────────────────────────────────────────────────────

section "MIRRORING"

CLONED=0 UPDATED=0 UNCHANGED=0 FAILED=0 I=0
FAILED_LIST=()
declare -A EXPECTED=()

while IFS=$'\t' read -r -u 3 FULL URL VIS FORK ARCH SIZE; do
    [ -z "$URL" ] && continue
    I=$((I + 1))
    T0=$SECONDS

    NAME=${URL##*/}; NAME=${NAME%.git}
    OWNER=${FULL%%/*}
    if [ -n "$DUPES" ] && grep -qxF "$NAME" <<< "$DUPES"; then
        TARGET="$BASE/${OWNER}__${NAME}.git"
    else
        TARGET="$BASE/$NAME.git"
    fi
    EXPECTED["${TARGET##*/}"]=1

    TAGS=$([ "$VIS" = private ] && printf '%sprivate%s' "$YEL" "$R" || printf '%spublic%s' "$D" "$R")
    [ "$FORK" = 1 ] && TAGS+=" ${D}·${R} ${BLU}fork${R}"
    [ "$ARCH" = 1 ] && TAGS+=" ${D}·${R} ${MAG}archived${R}"

    printf '\n  %s %s%*d/%d%s  %s%s%s  %s\n' \
        "$(bar "$I" "$TOTAL" 12)" "$D" "${#TOTAL}" "$I" "$TOTAL" "$R" "$WHT$B" "$FULL" "$R" "$TAGS"

    STATUS="" DETAIL="" OUT=""

    if git --git-dir="$TARGET" rev-parse --is-bare-repository >/dev/null 2>&1; then
        git --git-dir="$TARGET" remote set-url origin "$URL" >/dev/null 2>&1 \
            || git --git-dir="$TARGET" remote add origin "$URL" >/dev/null 2>&1

        BEFORE=$(refs "$TARGET")
        if OUT=$(git --git-dir="$TARGET" remote update --prune 2>&1 < /dev/null); then
            AFTER=$(refs "$TARGET")
            if [ "$BEFORE" = "$AFTER" ]; then
                STATUS=unchanged
                UNCHANGED=$((UNCHANGED + 1))
            else
                read -r ADD MOD DEL < <(awk '
                    NF < 2 { next }
                    FILENAME == ARGV[1] { b[$2] = $1; next }
                    { seen[$2] = 1; if (!($2 in b)) a++; else if (b[$2] != $1) m++ }
                    END { for (k in b) if (!(k in seen)) d++; print a + 0, m + 0, d + 0 }
                ' <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))
                STATUS=updated
                DETAIL="${GRN}+$ADD${R} ${YEL}~$MOD${R} ${RED}-$DEL${R} refs"
                UPDATED=$((UPDATED + 1))
            fi
        else
            STATUS=failed
            DETAIL="fetch failed"
        fi
    else
        if [ -e "$TARGET" ]; then
            # Something that is not a valid bare repo is in the way — keep it, never delete
            mv -- "$TARGET" "$TARGET.broken-$RUN_ID"
            warn "moved aside" "${TARGET##*/}.broken-$RUN_ID"
        fi
        if OUT=$(git clone --mirror "$URL" "$TARGET" 2>&1 < /dev/null); then
            STATUS=cloned
            DETAIL="$(human_kb "$(du -sk "$TARGET" | cut -f1)")"
            CLONED=$((CLONED + 1))
        else
            rm -rf -- "$TARGET"
            STATUS=failed
            DETAIL="clone failed"
        fi
    fi

    DT="${D}$(fmt_dur $((SECONDS - T0)))${R}"

    case $STATUS in
        cloned)    printf '     %s✓ %-11s%s %s  %s\n' "$GRN$B" "cloned"     "$R" "$DETAIL" "$DT" ;;
        updated)   printf '     %s✓ %-11s%s %s  %s\n' "$GRN"    "updated"    "$R" "$DETAIL" "$DT" ;;
        unchanged) printf '     %s= %-11s%s %s\n'     "$D"      "up to date" "$R" "$DT" ;;
        failed)
            REASON=$(grep -v '^[[:space:]]*$' <<< "$OUT" | tail -n 1)
            printf '     %s✗ %-11s%s %s  %s\n' "$RED$B" "FAILED" "$R" "$DETAIL" "$DT"
            grep -v '^[[:space:]]*$' <<< "$OUT" | tail -n 5 | sed "s/^/       ${D}│${R} /"
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$FULL|${REASON:-unknown error}")
            ;;
    esac
done 3< "$TMP"

# ─── Orphans: local mirrors no longer visible on GitHub ────────────────────

ORPHANS=()
for d in "$BASE"/*.git; do
    [ -d "$d" ] || continue
    [ -n "${EXPECTED[${d##*/}]:-}" ] || ORPHANS+=("${d##*/}")
done

# ─── Summary ───────────────────────────────────────────────────────────────

DURATION=$((SECONDS - START))
MIRROR_KB=$(du -skc "$BASE"/*.git 2>/dev/null | tail -n 1 | cut -f1)
DISK=$(df -k "$BASE" | awk 'NR==2 {print $4}')

echo
box_top
box_center "S U M M A R Y" "$CYN"
box_sep
box_row "Account"          "$GH_USER"
box_row "Repositories"     "$TOTAL  ($N_PRIV private, $N_PUB public)"
box_sep
box_row "Cloned (new)"     "$CLONED"    "$GRN"
box_row "Updated"          "$UPDATED"   "$GRN"
box_row "Up to date"       "$UNCHANGED" "$WHT"
if (( FAILED > 0 )); then
    box_row "Failed"       "$FAILED"    "$RED"
else
    box_row "Failed"       "0"          "$D"
fi
if (( ${#ORPHANS[@]} > 0 )); then
    box_row "Orphaned mirrors" "${#ORPHANS[@]}" "$YEL"
fi
box_sep
box_row "Mirror size"      "$(human_kb "${MIRROR_KB:-0}")"
box_row "Disk free"        "$(human_kb "${DISK:-0}")"
box_row "Duration"         "$(fmt_dur "$DURATION")" "$YEL"
box_row "Finished"         "$(date '+%Y-%m-%d %H:%M:%S')"
box_bottom

if (( FAILED > 0 )); then
    section "FAILED REPOSITORIES"
    for entry in "${FAILED_LIST[@]}"; do
        printf '  %s✗%s %s%s%s\n' "$RED" "$R" "$B" "${entry%%|*}" "$R"
        printf '    %s%s%s\n' "$D" "${entry#*|}" "$R"
    done
fi

if (( ${#ORPHANS[@]} > 0 )); then
    section "ORPHANED MIRRORS"
    printf '  %sNot on GitHub anymore (deleted, renamed or access lost) — kept as-is:%s\n' "$D" "$R"
    for o in "${ORPHANS[@]}"; do
        printf '  %s!%s %s\n' "$YEL" "$R" "$o"
    done
fi

# ─── Log rotation ──────────────────────────────────────────────────────────

ls -1t "$LOG_DIR"/github-backup-*.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)) |
    while IFS= read -r f; do rm -f -- "$f"; done

# ─── Result ────────────────────────────────────────────────────────────────

echo
if (( FAILED == 0 )); then
    printf '  %s%s✓ COMPLETED SUCCESSFULLY%s\n' "$GRN" "$B" "$R"
    printf '  %sLog: %s%s\n\n' "$D" "$LOG" "$R"
    exit 0
else
    printf '  %s%s✗ COMPLETED WITH %d ERROR(S)%s\n' "$RED" "$B" "$FAILED" "$R"
    printf '  %sLog: %s%s\n\n' "$D" "$LOG" "$R"
    exit 1
fi
