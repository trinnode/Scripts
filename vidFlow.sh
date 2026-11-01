#!/bin/bash
#
# ==============================================================================
# VidFlow v3.1 — Premium YouTube batch downloader
# Tagline: pick a profile, drop your links, get sharp files. Every time.
# Profiles: 720p / 1080p (h264-sorted mp4 merge) / Audio-only (mp3/m4a/opus)
#
# Engine notes:
#   * yt-dlp is resolved to a *verified working* binary. Updates download to a
#     temp file, are size- and version-validated, then atomically moved into
#     place. A failed/truncated update can never destroy a working install.
#   * Default player clients (full-res) + mweb fallback; ffmpeg merge; JS-runtime
#     preflight so 720p+ never silently degrades to 360p.
# ==============================================================================

set -u
VERSION="3.1.0"

# ---------------------------------------------------------------- palette ----
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
  CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; PINK='\033[38;5;213m'; ORANGE='\033[38;5;214m'
  GRAY='\033[0;90m'; WHITE='\033[1;37m'; NC='\033[0m'
  BOLD='\033[1m'; DIM='\033[2m'; UNDERLINE='\033[4m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; PINK=''; ORANGE=''
  GRAY=''; WHITE=''; NC=''; BOLD=''; DIM=''; UNDERLINE=''
fi
CHECK="${GREEN}✔${NC}"; CROSS="${RED}✖${NC}"; ARROW="${CYAN}▶${NC}"
DOT="${DIM}•${NC}"

# ------------------------------------------------------------------ state ----
URLS=()
YTDLP_COOKIE_ARGS=()
FAILED_URLS=()
QUALITY_HEIGHT="1080"
QUALITY_LABEL="1080p · Best video ≤1080p + best audio"
FORMAT_SELECTOR="bv*[height<=1080]+ba/b[height<=1080]/b"
FORMAT_SORT="res:1080,fps,vcodec:h264,acodec:m4a"
DL_MODE="video"          # video | audio
AUDIO_FORMAT="mp3"       # mp3 | m4a | opus
COOKIE_LABEL="none"
SINGLE_LABEL="MyVideos"
SKIP_CONFIRM=false
NO_UPDATE=false
FORCE_REPAIR=false
BASE_DIR="$HOME/Videos"
LOG_FILE=""
SESSION_START=0

# yt-dlp binary management
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
LOCAL_BIN_DIR="$HOME/.local/bin"
LOCAL_YTDLP="$LOCAL_BIN_DIR/yt-dlp"
YTDLP_STAMP="$LOCAL_BIN_DIR/.ytdlp-stamp"
YTDLP_BIN="yt-dlp"       # resolved at runtime to a verified binary
YTDLP_VER=""
YTDLP_ATTEMPT_STAMP="$LOCAL_BIN_DIR/.ytdlp-attempt"
REFRESH_RETRY_AFTER=$(( 24 * 3600 ))   # don't hammer a slow network more than daily
REFRESH_TIMEOUT=60                     # seconds; GitHub can be very slow on some links
REPAIR_TIMEOUT=600                     # --repair is allowed to be patient
MAX_VER_AGE=$(( 30 * 86400 ))          # refresh when the binary is 30+ days old

# ============================================================ UI primitives ==
BOX_IN=62                       # inner width of framed boxes (visible chars)
BOX_W=$(( BOX_IN + 2 ))

# ASCII-ify any fancy glyphs so width math is locale/byte safe inside boxes.
ascii_safe() {
  printf '%s' "$1" | sed -e 's/≤/<=/g' -e 's/≥/>=/g' -e 's/·/|/g' \
                         -e 's/→/->/g' -e 's/…/.../g' -e 's/✔/ok/g' -e 's/✖/x/g'
}
strip_ansi() { # accepts an argument or stdin
  if (( $# )); then printf '%s' "$1"; else cat; fi | sed 's/\x1b\[[0-9;]*m//g'
}

box_top()  { echo -e "${MAGENTA}╭$(printf '─%.0s' $(seq 1 $BOX_IN))╮${NC}"; }
box_bot()  { echo -e "${MAGENTA}╰$(printf '─%.0s' $(seq 1 $BOX_IN))╯${NC}"; }
box_sep()  { echo -e "${MAGENTA}├$(printf '─%.0s' $(seq 1 $BOX_IN))┤${NC}"; }
box_row() { # $1 = content (may contain ANSI); always padded to BOX_IN
  local txt plain n pad
  txt=$(ascii_safe "$1")
  plain=$(strip_ansi "$txt")
  n=${#plain}
  if (( n > BOX_IN )); then txt="${plain:0:$BOX_IN}"; n=$BOX_IN; fi
  pad=$(( BOX_IN - n )); (( pad < 0 )) && pad=0
  printf '%s│%s%s%*s%s│%s\n' "$MAGENTA" "$NC" "$txt" "$pad" "" "$MAGENTA" "$NC"
}

hr()  { echo -e "${DIM}${CYAN}$(printf '─%.0s' $(seq 1 $BOX_W))${NC}"; }
hr2() { echo -e "\n${DIM}${CYAN}$(printf '─%.0s' $(seq 1 $BOX_W))${NC}"; }

ui_banner() {
  clear
  echo ""
  echo -e "   ${BOLD}${WHITE}🌊  V I D F L O W  🌊${NC}"
  echo -e "   ${DIM}advanced media fetcher  ·  v${VERSION}${NC}"
  echo ""
  box_top
  box_row "  ${CYAN}profile${NC}   ${WHITE}$(ascii_safe "$QUALITY_LABEL")${NC}"
  box_row "  ${CYAN}mode${NC}      ${WHITE}${DL_MODE}${NC}  ${DIM}|  audio: ${AUDIO_FORMAT}  |  cookies: ${COOKIE_LABEL}${NC}"
  box_row "  ${CYAN}engine${NC}    ${DIM}${YTDLP_BIN}  (v${YTDLP_VER:-?})${NC}"
  box_row "  ${CYAN}library${NC}   ${WHITE}$(ascii_safe "$BASE_DIR/$SINGLE_LABEL")${NC}"
  box_bot
  echo ""
}

ui_step() { echo -e "${BOLD}${PINK}━━━ STEP $1 · $2 ━━━${NC}${DIM} $3${NC}"; }
ui_ok()   { echo -e "${CHECK} $1"; }
ui_warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
ui_err()  { echo -e "${CROSS} ${RED}$1${NC}"; }
ui_info() { echo -e "${CYAN}ℹ${NC} $1"; }
ui_kv()   { echo -e "  ${CYAN}$1${NC}  $2"; }

ui_bar() { # $1 current $2 total $3 width
  local cur=$1 tot=$2 w=${3:-28} filled empty pct
  (( tot <= 0 )) && tot=1; (( cur < 0 )) && cur=0; (( cur > tot )) && cur=$tot
  pct=$(( cur * 100 / tot )); filled=$(( cur * w / tot )); empty=$(( w - filled ))
  printf "%s%s%s%s %s%3d%%%s" \
    "$GREEN" "$(printf '█%.0s' $(seq 1 $filled 2>/dev/null))" \
    "$GRAY"  "$(printf '░%.0s' $(seq 1 $empty  2>/dev/null))" "$BOLD" "$pct" "$NC"
}

with_spinner() { # $1 message, rest = command
  local msg="$1"; shift
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  "$@" & local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  %s%s%s %s" "$CYAN" "${frames:$(( i % ${#frames} )):1}" "$NC" "$msg"
    i=$(( i + 1 )); sleep 0.08
  done
  wait "$pid"; local code=$?
  printf "\r%*s\r" 70 ""
  return $code
}

# ============================================================== yt-dlp mgmt ==
ytdlp_probe() { # $1 path -> echoes version; exit 0 only if the binary runs
  local p="$1" out
  [[ -f "$p" && -x "$p" ]] || return 1
  out=$("$p" --version 2>/dev/null | head -n1)
  [[ "$out" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2} ]] || return 1
  printf '%s' "$out"
}

ytdlp_stale() { # true when the resolved binary is old enough to warrant a refresh
  [[ "$FORCE_REPAIR" == true ]] && return 0
  local v="${YTDLP_VER:-}" epoch now
  [[ -z "$v" ]] && return 0
  epoch=$(date -d "${v//./-}" +%s 2>/dev/null) || return 0
  now=$(date +%s)
  (( now - epoch > MAX_VER_AGE ))
}

refresh_allowed() { # rate-limit auto-updates so a slow link cannot stall every run
  [[ "$FORCE_REPAIR" == true ]] && return 0
  [[ -f "$YTDLP_ATTEMPT_STAMP" ]] || return 0
  local last now
  last=$(cat "$YTDLP_ATTEMPT_STAMP" 2>/dev/null || echo 0)
  [[ "$last" =~ ^[0-9]+$ ]] || return 0
  now=$(date +%s)
  (( now - last > REFRESH_RETRY_AFTER ))
}

# Download to temp -> validate size+executability -> atomic move.
# Never writes over a working binary until the replacement is proven good.
# Bounded by time AND transfer speed: a stalled link aborts instead of hanging.
ytdlp_fetch() { # $1 timeout seconds, $2 retries (default 0 so timeouts don't multiply)
  local timeout="${1:-$REFRESH_TIMEOUT}" retries="${2:-0}"
  mkdir -p "$LOCAL_BIN_DIR" || return 1
  local tmp sz
  tmp=$(mktemp "$LOCAL_BIN_DIR/.yt-dlp.part.XXXXXX") || return 1
  # --speed-limit/--speed-time kill a link that is crawling; --max-time bounds
  # each transfer. Retries are opt-in because curl applies --max-time per
  # attempt, so retrying would multiply the wall-clock cost of a dead link.
  if ! curl -fsSL --connect-timeout 15 --retry "$retries" --retry-delay 2 \
        --max-time "$timeout" --speed-limit 1024 --speed-time 25 \
        -o "$tmp" "$YTDLP_URL"; then
    rm -f "$tmp"; return 1
  fi
  sz=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
  chmod +x "$tmp" 2>/dev/null
  # A real zipapp is ~3 MB. Anything small is a truncated body or an error page.
  if (( sz < 1000000 )); then rm -f "$tmp"; return 1; fi
  if ! ytdlp_probe "$tmp" >/dev/null; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$LOCAL_YTDLP" || { rm -f "$tmp"; return 1; }
  date +%s > "$YTDLP_STAMP" 2>/dev/null || true
  return 0
}

quarantine_broken() { # move a corrupt local binary aside so it cannot shadow good ones
  local bad="$LOCAL_YTDLP"
  [[ -e "$bad" ]] || return 0
  ytdlp_probe "$bad" >/dev/null && return 0
  mv -f "$bad" "${bad}.broken.$(date +%Y%m%d%H%M%S)" 2>/dev/null || rm -f "$bad" 2>/dev/null
  return 0
}

resolve_ytdlp() { # sets YTDLP_BIN + YTDLP_VER; 0 if a working binary was found
  local p v
  for p in "$LOCAL_YTDLP" /usr/local/bin/yt-dlp /usr/bin/yt-dlp /opt/homebrew/bin/yt-dlp; do
    if v=$(ytdlp_probe "$p"); then
      YTDLP_BIN="$p"; YTDLP_VER="$v"
      [[ "$p" == "$LOCAL_YTDLP" ]] && export PATH="$LOCAL_BIN_DIR:$PATH"
      return 0
    fi
  done
  p=$(command -v yt-dlp 2>/dev/null) || p=""
  if [[ -n "$p" ]] && v=$(ytdlp_probe "$p"); then
    YTDLP_BIN="$p"; YTDLP_VER="$v"; return 0
  fi
  return 1
}

ensure_ytdlp() { # refresh (bounded + validated) with graceful degradation
  local have_working=false
  resolve_ytdlp >/dev/null 2>&1 && have_working=true

  if [[ "$NO_UPDATE" != true ]] && refresh_allowed && \
     { [[ "$have_working" != true ]] || ytdlp_stale; }; then
    # Record the attempt up front so a slow/blocked link is not retried every run.
    date +%s > "$YTDLP_ATTEMPT_STAMP" 2>/dev/null || true
    if [[ "$have_working" == true ]]; then
      ui_info "Checking yt-dlp for updates (≤${REFRESH_TIMEOUT}s; skipped if the link is slow)…"
    else
      ui_info "Fetching yt-dlp (≤${REFRESH_TIMEOUT}s)…"
    fi
    if ytdlp_fetch "$REFRESH_TIMEOUT"; then
      ui_ok "yt-dlp updated and verified."
      resolve_ytdlp >/dev/null 2>&1 || true
    elif [[ "$have_working" == true ]]; then
      ui_info "Update skipped — continuing with working copy v${YTDLP_VER}."
      echo -e "  ${DIM}Slow GitHub link? Try: pipx install yt-dlp  (or run 'vidFlow --repair' on a faster network)${NC}"
    fi
  fi

  if resolve_ytdlp; then return 0; fi

  # Nothing usable yet — one patient attempt, then fail with guidance.
  ui_warn "No working yt-dlp found. Attempting a patient install (≤${REPAIR_TIMEOUT}s)…"
  if ytdlp_fetch "$REPAIR_TIMEOUT" && resolve_ytdlp; then
    ui_ok "yt-dlp installed."
    return 0
  fi
  quarantine_broken
  ui_err "yt-dlp is unavailable."
  echo -e "  ${DIM}Fix with any of:${NC}"
  echo -e "  ${DIM}  vidFlow --repair${NC}"
  echo -e "  ${DIM}  pipx install yt-dlp        (or)  python3 -m pip install --user -U yt-dlp${NC}"
  echo -e "  ${DIM}  sudo apt install yt-dlp${NC}"
  return 1
}

# ================================================================ core utils ==
sanitize() {
  echo "$1" | tr -d '/\\?*<>|"' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed 's/ \+/ /g'
}

valid_url() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }

dedupe_urls() {
  local -A seen=(); local out=() u
  for u in "${URLS[@]}"; do
    u=$(echo "$u" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -z "$u" ]] && continue
    if [[ -z "${seen[$u]:-}" ]]; then seen[$u]=1; out+=("$u"); fi
  done
  URLS=("${out[@]}")
}

apply_profile() { # $1 normalized choice -> sets globals (pure, testable)
  local c="$1"
  case "$c" in
    1|720|720p)
      DL_MODE="video"; QUALITY_HEIGHT="720"
      QUALITY_LABEL="720p · Best video ≤720p + best audio"
      FORMAT_SELECTOR="bv*[height<=720]+ba/b[height<=720]/b"
      FORMAT_SORT="res:720,fps,vcodec:h264,acodec:m4a" ;;
    ""|2|1080|1080p)
      DL_MODE="video"; QUALITY_HEIGHT="1080"
      QUALITY_LABEL="1080p · Best video ≤1080p + best audio"
      FORMAT_SELECTOR="bv*[height<=1080]+ba/b[height<=1080]/b"
      FORMAT_SORT="res:1080,fps,vcodec:h264,acodec:m4a" ;;
    3|audio|mp3)
      DL_MODE="audio"; AUDIO_FORMAT="mp3"; QUALITY_HEIGHT="0"
      QUALITY_LABEL="Audio only · best audio → MP3"
      FORMAT_SELECTOR="ba/b"; FORMAT_SORT="" ;;
    4|m4a|aac)
      DL_MODE="audio"; AUDIO_FORMAT="m4a"; QUALITY_HEIGHT="0"
      QUALITY_LABEL="Audio only · best audio → M4A"
      FORMAT_SELECTOR="ba/b"; FORMAT_SORT="" ;;
    5|opus)
      DL_MODE="audio"; AUDIO_FORMAT="opus"; QUALITY_HEIGHT="0"
      QUALITY_LABEL="Audio only · best audio → OPUS"
      FORMAT_SELECTOR="ba/b"; FORMAT_SORT="" ;;
    *) return 1 ;;
  esac
  return 0
}

build_ytdlp_args() { # <out_array_name> <target_dir> [extra...]
  local -n _out=$1; local _target=$2; shift 2
  _out=(
    -P "$_target"
    -f "$FORMAT_SELECTOR"
    --merge-output-format mp4
    --no-warnings --progress --newline
    --retries 3 --retry-sleep 2 --socket-timeout 20
    --concurrent-fragments 4
  )
  [[ -n "$FORMAT_SORT" ]] && _out+=(-S "$FORMAT_SORT")
  if [[ "$DL_MODE" == "audio" ]]; then
    _out+=(-x --audio-format "$AUDIO_FORMAT" --audio-quality 0 --embed-metadata)
  else
    _out+=(--remux-video mp4 --embed-metadata)
  fi
  _out+=("${YTDLP_COOKIE_ARGS[@]}" "$@")
}

# ------------------------------------------------------------------ deps ----
ensure_deps() {
  ui_step "0/5" "System check" "yt-dlp · ffmpeg · js runtime"
  local need_ffmpeg=false
  command -v ffmpeg  &>/dev/null || need_ffmpeg=true
  command -v ffprobe &>/dev/null || need_ffmpeg=true

  ensure_ytdlp || return 1

  if [[ "$need_ffmpeg" == true ]]; then
    ui_warn "ffmpeg/ffprobe missing — installing…"
    if   command -v apt    &>/dev/null; then sudo apt update && sudo apt install -y ffmpeg
    elif command -v dnf    &>/dev/null; then sudo dnf install -y ffmpeg
    elif command -v pacman &>/dev/null; then sudo pacman -Sy --noconfirm ffmpeg
    elif command -v brew   &>/dev/null; then brew install ffmpeg
    else
      ui_err "No supported package manager. Install ffmpeg manually."
      return 1
    fi
  fi

  local fv="missing" js="missing" r
  command -v ffmpeg &>/dev/null && fv="v$(ffmpeg -version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
  for r in deno node quickjs qjs; do command -v "$r" &>/dev/null && { js="$r"; break; }; done

  ui_kv "yt-dlp   " "${WHITE}v${YTDLP_VER}${NC} ${DIM}(${YTDLP_BIN})${NC}"
  ui_kv "ffmpeg   " "${WHITE}${fv}${NC}"
  if [[ "$js" == "missing" ]]; then
    ui_kv "js engine" "${YELLOW}none — 720p/1080p may be withheld (360p only)${NC}"
    echo -e "  ${DIM}curl -fsSL https://deno.land/install.sh | sh   then add ~/.deno/bin to PATH${NC}"
  else
    ui_kv "js engine" "${WHITE}${js}${NC} ${DIM}(HD formats unlocked)${NC}"
  fi
  command -v ffmpeg &>/dev/null || { ui_err "ffmpeg unavailable. Install it and retry."; return 1; }
  echo ""
}

# --------------------------------------------------------------- metadata ---
get_playlist_name() {
  local url="$1" pname
  pname=$("$YTDLP_BIN" "${YTDLP_COOKIE_ARGS[@]}" --playlist-items 1 --no-warnings --socket-timeout 15 \
    --print "%(playlist_title)s" "$url" 2>/dev/null | head -n 1)
  if [[ -z "$pname" || "$pname" == "NA" ]]; then
    pname=$("$YTDLP_BIN" "${YTDLP_COOKIE_ARGS[@]}" --playlist-items 1 --no-warnings --socket-timeout 15 \
      --print "%(channel)s" "$url" 2>/dev/null | head -n 1)
  fi
  [[ -z "$pname" || "$pname" == "NA" ]] && pname="VidFlow_Playlist_$(date +%Y%m%d_%H%M%S)"
  sanitize "$pname"
}

is_playlist() {
  local url="$1" pid
  pid=$("$YTDLP_BIN" "${YTDLP_COOKIE_ARGS[@]}" --playlist-items 1 --no-warnings --socket-timeout 15 \
    --print "%(playlist_id)s" "$url" 2>/dev/null | head -n 1)
  [[ "$pid" != "NA" && -n "$pid" ]]
}

verify_resolution() { # $1 dir -> prints height of newest video file
  local dir="$1" nf vh
  nf=$(find "$dir" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.webm" \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
  [[ -n "${nf:-}" && -f "$nf" ]] || return 1
  vh=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$nf" 2>/dev/null | head -n1)
  [[ "$vh" =~ ^[0-9]+$ ]] || return 1
  echo "$vh"
}

# Turn a raw yt-dlp error into an actionable hint (the old build always cried 429).
diagnose_failure() { # $1 log file, $2 last code
  local log="$1" code="$2" tail_txt
  tail_txt=$(tail -n 8 "$log" 2>/dev/null)
  if grep -qiE 'null bytes|SyntaxError|BadZipFile|zipfile|No module named' <<<"$tail_txt"; then
    echo "yt-dlp binary is corrupted (truncated download). Run: vidFlow --repair"
  elif grep -qiE 'HTTP Error 429|Too Many Requests' <<<"$tail_txt"; then
    echo "Rate-limited by YouTube. Retry with --cookies chrome, or use a VPN."
  elif grep -qiE 'Sign in to confirm|not a bot|confirm you.re not a bot' <<<"$tail_txt"; then
    echo "Bot check triggered. Retry with --cookies chrome."
  elif grep -qiE 'Requested format is not available' <<<"$tail_txt"; then
    echo "Format withheld by YouTube for this session (needs a JS runtime / PO token)."
  elif grep -qiE 'Private video|Video unavailable|removed by the uploader' <<<"$tail_txt"; then
    echo "Video is private, removed, or region-locked."
  elif grep -qiE 'getaddrinfo|Temporary failure|Connection refused|timed out' <<<"$tail_txt"; then
    echo "Network/DNS problem. Check your connection and retry."
  else
    echo "Exit code ${code}. Last output: ${tail_txt##*$'\n'}"
  fi
}

# ============================================================== flow steps ==
step_destination() {
  ui_step "1/5" "Library folder" "singles land here · playlists get their own folder"
  local input="${PRESET_DIR:-}"
  if [[ -z "$input" && "$SKIP_CONFIRM" != true ]]; then
    read -r -p "$(echo -e "${ARROW} Folder for ${BOLD}single videos${NC} ${DIM}(in ~/Videos)${NC}${ARROW} ")" input
  fi
  input=$(sanitize "$input")
  if [[ -z "$input" ]]; then
    input="MyVideos"
    [[ "$SKIP_CONFIRM" != true ]] && ui_warn "Empty — using '${input}'."
  fi
  SINGLE_LABEL="$input"
  mkdir -p "$BASE_DIR/$SINGLE_LABEL"
  ui_ok "Singles → ${UNDERLINE}${CYAN}$BASE_DIR/$SINGLE_LABEL${NC}"
  echo ""
}

step_profile() {
  ui_step "2/5" "Download profile" "video merges to mp4 · audio extracts with metadata"
  if [[ -n "${PRESET_PROFILE:-}" ]]; then
    if apply_profile "$(echo "$PRESET_PROFILE" | tr '[:upper:]' '[:lower:]')"; then
      if [[ "$DL_MODE" == "audio" && -n "${PRESET_AUDIO_FMT:-}" ]]; then
        case "$(echo "$PRESET_AUDIO_FMT" | tr '[:upper:]' '[:lower:]')" in
          mp3|m4a|opus) AUDIO_FORMAT=$(echo "$PRESET_AUDIO_FMT" | tr '[:upper:]' '[:lower:]')
            QUALITY_LABEL="Audio only · best audio → ${AUDIO_FORMAT^^}" ;;
        esac
      fi
      ui_ok "Profile → ${BOLD}${QUALITY_LABEL}${NC}"
      echo ""; return 0
    fi
    ui_warn "Ignoring invalid --quality '${PRESET_PROFILE}'."
  fi
  echo -e "  ${CYAN}[1]${NC} ${BOLD}720p${NC}   ${DIM}fast · compact — great for phones & drafts${NC}"
  echo -e "  ${CYAN}[2]${NC} ${BOLD}1080p${NC}  ${DIM}sharpest — h264-prioritised mp4 merge ${GREEN}(recommended)${NC}"
  echo -e "  ${CYAN}[3]${NC} ${BOLD}Audio · MP3${NC}  ${DIM}universal player support${NC}"
  echo -e "  ${CYAN}[4]${NC} ${BOLD}Audio · M4A${NC}  ${DIM}closest to YouTube's native audio${NC}"
  echo -e "  ${CYAN}[5]${NC} ${BOLD}Audio · OPUS${NC} ${DIM}smallest files, best quality/size${NC}"
  local c=""
  if [[ "$SKIP_CONFIRM" != true ]]; then
    read -r -p "$(echo -e "  ${ARROW} Pick ${DIM}[1-5, default 2]${NC}${ARROW} ")" c
  fi
  c=$(echo "$c" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -z "$c" ]] && c="2"
  if ! apply_profile "$c"; then
    ui_warn "Unknown '${c}' — falling back to 1080p."
    apply_profile "2"
  fi
  ui_ok "Profile → ${BOLD}${QUALITY_LABEL}${NC}"
  echo ""
}

step_cookies() {
  ui_step "3/5" "Anti-bot cookies" "optional · raises success rate on age-gated/busy IPs"
  local b="${PRESET_COOKIES:-}"
  if [[ -z "$b" && "$SKIP_CONFIRM" != true ]]; then
    echo -e "  ${DIM}chrome · firefox · brave · edge · opera · vivaldi · safari — or leave empty${NC}"
    read -r -p "$(echo -e "  ${ARROW} Browser for cookies ${DIM}[Enter = skip]${NC}${ARROW} ")" b
  fi
  b=$(echo "$b" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [[ -n "$b" ]]; then
    if [[ "$b" =~ ^(chrome|firefox|brave|edge|opera|vivaldi|safari)$ ]]; then
      YTDLP_COOKIE_ARGS=("--cookies-from-browser" "$b")
      COOKIE_LABEL="$b"
      ui_ok "Cookies ← ${BOLD}${b}${NC}"
    else
      ui_warn "Unknown browser '${b}' — continuing without cookies."
    fi
  elif [[ "$SKIP_CONFIRM" != true ]]; then
    ui_info "Skipping cookies. ${DIM}(If downloads 429, re-run with --cookies chrome.)${NC}"
  fi
  echo ""
}

step_urls() {
  ui_step "4/5" "Your links" "batch paste or one-by-one · dupes auto-removed"
  if [[ -n "${PRESET_BATCH_FILE:-}" && -f "$PRESET_BATCH_FILE" ]]; then
    mapfile -t URLS < <(grep -oE 'https?://[^[:space:]]+' "$PRESET_BATCH_FILE")
    dedupe_urls
    ui_ok "Loaded ${BOLD}${#URLS[@]}${NC} link(s) from ${CYAN}${PRESET_BATCH_FILE}${NC}"
    echo ""; return 0
  fi
  local mode
  read -r -p "$(echo -e "  ${ARROW} Paste a ${BOLD}batch list${NC} all at once? ${DIM}(y/N)${NC}${ARROW} ")" mode
  if [[ "$mode" =~ ^[Yy]$ ]]; then
    echo -e "  ${DIM}Paste links (spaces or new lines) · ${BOLD}blank Enter${NC}${DIM} finishes.${NC}"
    local batch="" has=false line t
    while IFS= read -r line; do
      t=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      if [[ -z "$t" ]]; then
        [[ "$has" == true ]] && break
      else
        has=true; batch+="$t "
      fi
    done
    # shellcheck disable=SC2206
    URLS=($batch)
  else
    echo -e "  ${DIM}Paste one per line · ${BOLD}3× Enter${NC}${DIM} finishes.${NC}"
    local empty=0 raw u
    while true; do
      read -r -p "$(echo -e "  ${ARROW} link ${DIM}(${#URLS[@]} queued)${NC}${ARROW} ")" raw
      u=$(echo "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      if [[ -z "$u" ]]; then
        ((empty++))
        if (( empty >= 3 )); then echo ""; break; fi
        ui_warn "Empty — ${DIM}$(( 3 - empty )) more blank Enter(s) to finish.${NC}"
      elif ! valid_url "$u"; then
        ui_warn "Doesn't look like a URL — skipped: ${DIM}${u:0:80}${NC}"
      else
        empty=0; URLS+=("$u")
        echo -e "  ${CHECK} queued ${DIM}[${#URLS[@]}]${NC} ${CYAN}${u:0:90}${NC}"
      fi
    done
  fi
  local kept=() x dropped=0
  for x in "${URLS[@]}"; do valid_url "$x" && kept+=("$x") || ((dropped++)); done
  URLS=("${kept[@]}"); dedupe_urls
  (( dropped > 0 )) && ui_warn "${dropped} invalid line(s) dropped."
  ui_ok "Queue ready — ${BOLD}${#URLS[@]}${NC} unique link(s)."
  echo ""
}

step_review() {
  ui_step "5/5" "Launch check" "everything below is exactly what will run"
  box_top
  box_row "  ${CYAN}profile${NC}   ${WHITE}$(ascii_safe "$QUALITY_LABEL")${NC}"
  box_row "  ${CYAN}engine${NC}    ${DIM}$(ascii_safe "$FORMAT_SELECTOR")${NC}"
  [[ -n "$FORMAT_SORT" ]] && box_row "  ${CYAN}sort${NC}      ${DIM}$(ascii_safe "$FORMAT_SORT")${NC}"
  box_row "  ${CYAN}singles${NC}   ${WHITE}$(ascii_safe "$BASE_DIR/$SINGLE_LABEL")${NC}"
  box_row "  ${CYAN}cookies${NC}   ${WHITE}${COOKIE_LABEL}${NC}  ${DIM}|  queue: ${#URLS[@]} link(s)${NC}"
  box_sep
  local i=1
  for u in "${URLS[@]:0:4}"; do box_row "  ${DIM}${i}.${NC} ${CYAN}${u:0:56}${NC}"; i=$((i+1)); done
  (( ${#URLS[@]} > 4 )) && box_row "  ${DIM}... +$(( ${#URLS[@]} - 4 )) more${NC}"
  box_bot
  if [[ "$SKIP_CONFIRM" == true ]]; then ui_ok "Auto-confirmed (--yes). Igniting…"; return 0; fi
  local go
  read -r -p "$(echo -e "  ${ARROW} ${BOLD}Launch downloads?${NC} ${DIM}[Enter = go · e = add more links]${NC}${ARROW} ")" go
  if [[ "$go" =~ ^[Ee]$ ]]; then step_urls; step_review; return $?; fi
  echo ""
}

# ============================================================== downloader ==
download_one() { # $1 url $2 index $3 total $4 single_dir
  local url="$1" idx="$2" tot="$3" single_dir="$4"
  echo -e "\n${BOLD}${PINK}▸ [$idx/$tot]${NC} ${WHITE}${url:0:100}${NC}"
  local target_dir="" is_pl=false plist=""
  if with_spinner "Detecting playlist vs single…" is_playlist "$url"; then
    is_pl=true
    plist=$(get_playlist_name "$url")
    target_dir="$BASE_DIR/$plist"
    mkdir -p "$target_dir"
    ui_kv "◆ type" "${BOLD}playlist${NC} ${DIM}→ ${WHITE}${plist}${NC}"
  else
    target_dir="$single_dir"
    ui_kv "◆ type" "${BOLD}single${NC}"
  fi
  ui_kv "◆ dist" "${UNDERLINE}${CYAN}${target_dir}${NC}"
  ui_kv "◆ spec" "${DIM}${FORMAT_SELECTOR}${NC}"

  local args=()
  build_ytdlp_args args "$target_dir"
  [[ "$is_pl" == true ]] && args+=(-o "%(playlist_index)s - %(title)s.%(ext)s")
  args+=("$url")

  echo -e "  ${GREEN}⬇ downloading…${NC} ${DIM}(live progress below)${NC}"
  hr
  "$YTDLP_BIN" "${args[@]}" 2>&1 | tee -a "$LOG_FILE"
  local code=${PIPESTATUS[0]}
  hr

  if (( code != 0 )); then
    ui_warn "Primary engine failed (code ${code}) — retrying via mweb client…"
    local fb=()
    build_ytdlp_args fb "$target_dir" --extractor-args "youtube:player_client=mweb"
    [[ "$is_pl" == true ]] && fb+=(-o "%(playlist_index)s - %(title)s.%(ext)s")
    fb+=("$url")
    "$YTDLP_BIN" "${fb[@]}" 2>&1 | tee -a "$LOG_FILE"
    code=${PIPESTATUS[0]}
  fi

  if (( code == 0 )) && [[ "$DL_MODE" == "video" ]]; then
    local vh=""
    vh=$(verify_resolution "$target_dir" || true)
    if [[ "$vh" =~ ^[0-9]+$ ]]; then
      if (( vh < QUALITY_HEIGHT )); then
        ui_warn "Got ${BOLD}${vh}p${NC}${YELLOW} but asked ${QUALITY_HEIGHT}p.${NC} ${DIM}YouTube withheld HD — check with: yt-dlp -F '$url'${NC}"
      else
        ui_ok "Verified ${BOLD}${vh}p${NC} ${DIM}— sharp as requested.${NC}"
      fi
    fi
  fi

  if (( code == 0 )); then
    echo -e "${CHECK} ${BOLD}done${NC} ${DIM}[$idx/$tot]${NC}"
  else
    echo -e "${CROSS} ${RED}failed${NC} ${DIM}[$idx/$tot] code $code${NC}"
    echo -e "  ${YELLOW}↳ $(diagnose_failure "$LOG_FILE" "$code")${NC}"
    FAILED_URLS+=("$url")
  fi
  echo -ne "  ${DIM}processed${NC} "; ui_bar "$idx" "$tot"
  echo -e "  ${DIM}(${#FAILED_URLS[@]} failed so far)${NC}"
  return $code
}

run_downloads() {
  local single_dir="$BASE_DIR/$SINGLE_LABEL"
  mkdir -p "$single_dir"
  LOG_FILE="$BASE_DIR/.vidflow_$(date +%Y%m%d_%H%M%S).log"
  : > "$LOG_FILE"
  SESSION_START=$(date +%s)
  ui_banner
  echo -e "${BOLD}${WHITE}🚀  DOWNLOAD SEQUENCE${NC} ${DIM}· ${#URLS[@]} item(s) · log: $(basename "$LOG_FILE")${NC}"
  hr2
  local ok=0 fail=0 i=0
  for url in "${URLS[@]}"; do
    i=$(( i + 1 ))
    if download_one "$url" "$i" "${#URLS[@]}" "$single_dir"; then ok=$((ok+1)); else fail=$((fail+1)); fi
  done
  local secs=$(( $(date +%s) - SESSION_START ))
  printf -v dur '%02d:%02d' $(( secs / 60 )) $(( secs % 60 ))
  echo ""
  box_top
  box_row "  ${BOLD}${WHITE}SESSION COMPLETE${NC}   ${DIM}${dur} elapsed${NC}"
  box_sep
  box_row "  ${GREEN}success${NC}  ${BOLD}${ok}${NC}      ${RED}failed${NC}  ${BOLD}${fail}${NC}"
  box_row "  ${CYAN}library${NC}  $(ascii_safe "$BASE_DIR")"
  box_row "  ${CYAN}log${NC}      ${DIM}$(ascii_safe "$LOG_FILE")${NC}"
  if (( fail > 0 )); then
    box_sep
    box_row "  ${RED}Failed:${NC}"
    local f
    for f in "${FAILED_URLS[@]}"; do box_row "  ${DIM}- $(ascii_safe "$f")${NC}"; done
    box_row "  ${YELLOW}Re-run those links once the cause is fixed.${NC}"
  fi
  box_bot
  echo ""
}

# ================================================================== CLI =====
usage() {
  cat <<'EOF'
VidFlow v3.1 — premium YouTube batch downloader

Usage:
  vidFlow [options]

Options:
  -q, --quality P       720 | 1080 | audio | 1..5   (default: 1080)
  -a, --audio-format F  mp3 | m4a | opus            (default: mp3, audio mode)
  -d, --dir NAME        singles folder in ~/Videos  (default: MyVideos)
  -c, --cookies B       chrome|firefox|brave|edge|opera|vivaldi|safari
  -b, --batch FILE      read URLs from a file
  -y, --yes             skip launch confirmation
      --no-update       skip the yt-dlp self-refresh
      --repair          force a verified reinstall of yt-dlp
      --dry-run         print resolved engine args, download nothing
  -h, --help            this help
  -v, --version         version

Examples:
  vidFlow -q 1080 -d MusicVideos --cookies chrome
  vidFlow -q audio -a opus -b links.txt -y
  vidFlow --repair
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q|--quality)      PRESET_PROFILE="${2:-}"; shift 2 ;;
      -a|--audio-format) PRESET_AUDIO_FMT="${2:-}"; shift 2 ;;
      -d|--dir)          PRESET_DIR="${2:-}"; shift 2 ;;
      -c|--cookies)      PRESET_COOKIES="${2:-}"; shift 2 ;;
      -b|--batch)        PRESET_BATCH_FILE="${2:-}"; shift 2 ;;
      -y|--yes)          SKIP_CONFIRM=true; shift ;;
      --no-update)       NO_UPDATE=true; shift ;;
      --repair)          FORCE_REPAIR=true; shift ;;
      --dry-run)         DRY_RUN=true; shift ;;
      -h|--help)         usage; exit 0 ;;
      -v|--version)      echo "VidFlow v${VERSION}"; exit 0 ;;
      *) echo -e "${CROSS} Unknown option: $1 (see --help)"; exit 2 ;;
    esac
  done
}

dry_run_dump() {
  resolve_ytdlp >/dev/null 2>&1 || true
  [[ -n "${PRESET_PROFILE:-}" ]] && apply_profile "$(echo "$PRESET_PROFILE" | tr '[:upper:]' '[:lower:]')" || true
  if [[ -n "${PRESET_AUDIO_FMT:-}" && "$DL_MODE" == "audio" ]]; then
    case "$(echo "$PRESET_AUDIO_FMT" | tr '[:upper:]' '[:lower:]')" in
      mp3|m4a|opus) AUDIO_FORMAT=$(echo "$PRESET_AUDIO_FMT" | tr '[:upper:]' '[:lower:]')
        QUALITY_LABEL="Audio only · best audio → ${AUDIO_FORMAT^^}" ;;
    esac
  fi
  local args=(); build_ytdlp_args args "<target_dir>"
  echo "profile : $QUALITY_LABEL"
  echo "mode    : $DL_MODE (audio codec: $AUDIO_FORMAT)"
  echo "format  : $FORMAT_SELECTOR"
  echo "sort    : ${FORMAT_SORT:-<none>}"
  echo "yt-dlp  : ${YTDLP_BIN} (v${YTDLP_VER:-unresolved})"
  echo "cookies : ${YTDLP_COOKIE_ARGS[*]:-<none>}"
  printf '%s' "$(basename "$YTDLP_BIN")"
  printf ' %q' "${args[@]}"; echo ' <URL>'
}

# ================================================================== main ====
main() {
  trap 'echo ""; ui_warn "Interrupted. Re-run to resume — yt-dlp continues partial files."; exit 130' INT
  parse_args "$@"

  if [[ "$FORCE_REPAIR" == true ]]; then
    echo -e "${BOLD}${PINK}━━━ REPAIR · yt-dlp ━━━${NC}"
    ui_info "Downloading a verified copy (≤${REPAIR_TIMEOUT}s; GitHub may be slow)…"
    quarantine_broken
    if ytdlp_fetch "$REPAIR_TIMEOUT" 2 && resolve_ytdlp; then
      ui_ok "yt-dlp repaired → ${YTDLP_BIN} (v${YTDLP_VER})"
      exit 0
    fi
    # The fetch failed, but a system copy may still be perfectly usable.
    if resolve_ytdlp; then
      ui_warn "Download failed, but a working copy is available: ${YTDLP_BIN} (v${YTDLP_VER})"
      exit 0
    fi
    ui_err "Repair failed. Check your network, or install via pipx / apt."
    exit 1
  fi

  if [[ "${DRY_RUN:-false}" == true ]]; then dry_run_dump; exit 0; fi

  ui_banner
  ensure_deps || exit 1
  step_destination
  step_profile
  step_cookies
  step_urls
  if (( ${#URLS[@]} == 0 )); then
    echo -e "\n${RED}╭─ ${BOLD}✖ ABORTED — no links queued.${NC}\n"; exit 0
  fi
  ui_ok "Locked in ${BOLD}${#URLS[@]}${NC} link(s)."
  sleep 1
  step_review
  run_downloads
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
