#!/usr/bin/env bash
# Čišćenje ~/.cache po starosti + korektno zatvaranje Spotifyja pre brisanja.
# Upotreba: cache-clean.sh [--dry-run] [--keep-spotify]
set -euo pipefail
prune_to() {  # prune_to <dir> <max_mb>
  local dir="$1" maxmb="$2" curmb excess before after
  [ -d "$dir" ] || return 0
  if (( DRY == 0 )) && [ -n "$(spotify_pids)" ]; then
    log "prune: Spotify radi - preskacem ${dir/#$HOME/~}"
    return 0
  fi
  curmb=$(du -sm -- "$dir" 2>/dev/null | cut -f1) || true
  [ -z "${curmb:-}" ] && return 0
  if [ "$curmb" -le "$maxmb" ]; then
    log "prune: ${dir/#$HOME/~} ${curmb}MB <= ${maxmb}MB - OK"
    return 0
  fi
  excess=$(( (curmb - maxmb) * 1048576 )); before=$curmb
  if (( DRY )); then
    log "prune: (dry-run) ${dir/#$HOME/~} ${curmb}MB > ${maxmb}MB - obrisao bih ~$(( excess / 1048576 ))MB"
    return 0
  fi
  log "prune: ${dir/#$HOME/~} ${curmb}MB > ${maxmb}MB - brisem najstarije ~$(( excess / 1048576 ))MB"
  { find "$dir" -type f -printf '%T@ %s %p\0' 2>/dev/null | LC_ALL=C sort -z -n |
    awk -v ex="$excess" 'BEGIN{RS="\0";ORS="\0";cum=0}
      { q=$0; sub(/^[^ ]+ +[0-9]+ +/,"",q); if (cum < ex) { cum+=$2; printf "%s\0", q } }' |
    while IFS= read -r -d '' f; do rm -f -- "$f"; done ; } || true
  after=$(du -sm -- "$dir" 2>/dev/null | cut -f1) || true
  log "prune: ${dir/#$HOME/~} ${before}MB -> ${after:-?}MB"
}


CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
DRY=0
QUIT_SPOTIFY=1

for a in "$@"; do
  case "$a" in
    -n|--dry-run)   DRY=1 ;;
    --keep-spotify) QUIT_SPOTIFY=0 ;;
    *) printf 'Nepoznata opcija: %s\n' "$a" >&2; exit 2 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
hsz() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%sB\n' "$1"; }
du_m() { local v; v=$(du -sm -- "$1" 2>/dev/null | cut -f1) || true; printf "%s" "${v:-0}"; }

# spreči paralelno izvršavanje (tajmer vs. ručno pokretanje)
if command -v flock >/dev/null 2>&1; then
  exec 9>"${XDG_RUNTIME_DIR:-/tmp}/cache-clean.$(id -u).lock"
  flock -n 9 || { log "čišćenje je već u toku — preskačem"; exit 0; }
fi

PATHS=(
  "$CACHE/spotify"
  "$CACHE/calibre"
  "$CACHE/thumbnails"
  "$CACHE/mozilla"
  "$CACHE/firedragon"
  "$CACHE/thunderbird"
)

total() {
  local s=0 p b
  for p in "${PATHS[@]}"; do
    b=$(du -sb "$p" 2>/dev/null | cut -f1)
    s=$(( s + ${b:-0} ))
  done
  printf '%s\n' "$s"
}

spotify_pids() {
  { pgrep -x spotify 2>/dev/null; pgrep -f 'com\.spotify\.Client' 2>/dev/null; } | sort -u || true
}

if (( QUIT_SPOTIFY )) && (( DRY == 0 )); then
  pids=$(spotify_pids) || true
  if [ -n "$pids" ]; then
    log "Spotify radi (PID: $(echo "$pids" | tr '\n' ' '))— zatvaram"
    kill -TERM $pids 2>/dev/null
    for _ in $(seq 1 20); do
      [ -z "$(spotify_pids)" ] && break
      sleep 0.5
    done
    left=$(spotify_pids) || true
    if [ -n "$left" ]; then
      log "TERM nije pomogao — šaljem KILL"
      kill -KILL $left 2>/dev/null
      sleep 1
    fi
    log "Spotify zatvoren"
  fi
fi

before=$(total)
log "pre: $(hsz "$before")"

if (( DRY )); then
  log "DRY-RUN - nista se ne brise"
  prune_to "$CACHE/spotify/Data"           800
  prune_to "$CACHE/spotify/Browser/Cache"  150
  rc=0
  systemd-tmpfiles --user --clean --dry-run || rc=$?
else
  prune_to "$CACHE/spotify/Data"           800
  prune_to "$CACHE/spotify/Browser/Cache"  150
  rc=0
  systemd-tmpfiles --user --clean || rc=$?
fi

after=$(total)
log "posle: $(hsz "$after")"
if [ "$after" -lt "$before" ]; then
  log "oslobođeno: $(hsz "$((before - after))")"
fi
log "Data: $(du_m "$CACHE/spotify/Data")MB | BrowserCache: $(du_m "$CACHE/spotify/Browser/Cache")MB"
exit "$rc"
