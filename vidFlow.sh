#!/bin/bash
#
# ==============================================================================
# VidFlow v3.0 — Premium YouTube batch downloader
# Tagline: pick a profile, drop your links, get sharp files. Every time.
# Profiles: 720p / 1080p (h264-sorted mp4 merge) / Audio-only (mp3/m4a/opus)
# Core engine: yt-dlp default clients (full-res) + mweb fallback, ffmpeg merge,
#              JS-runtime preflight so 720p+ never silently becomes 360p.
# ==============================================================================

set -u
VERSION="3.0.0"

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
BASE_DIR="$HOME/Videos"
LOG_FILE=""
SESSION_START=0

# ============================================================ UI primitives ==
BOX_W=66
hr()    { echo -e "${DIM}${CYAN}$(printf '─%.0s' $(seq 1 $BOX_W))${NC}"; }
hr2()   { echo -e "\n${DIM}${CYAN}$(printf '─%.0s' $(seq 1 $BOX_W))${NC}"; }
pad_to() { # $1 text (plain, no escapes), $2 width -> prints padded plain text
  local txt="$1" w="$2" n=${#1}
  printf '%s' "$txt"; (( n < w )) && printf '%*s' $(( w - n )) ''
}

ui_banner() {
  clear
  echo -e "${MAGENTA}╔$(printf '═%.0s' $(seq 1 $BOX_W))╗${NC}"
  echo -e "${MAGENTA}║${NC}${BOLD}${WHITE}   🌊  V i d F l o w  ${PINK}·${WHITE}  A d v a n c e d   M e d i a   F e t c h e r   🌊${NC}   ${MAGENTA}║${NC}"
  echo -e "${MAGENTA}║${NC}  ${DIM}pick a profile · drop your links · get sharp files${NC}            ${DIM}v${VERSION}${NC}  ${MAGENTA}║${NC}"
  echo -e "${MAGENTA}╠$(printf '═%.0s' $(seq 1 $BOX_W))╣${NC}"
  echo -e "${MAGENTA}║${NC}  ${CYAN}profile${NC}  ${WHITE}${QUALITY_LABEL}${NC}"
  echo -e "${MAGENTA}║${NC}  ${CYAN}mode${NC}     ${WHITE}${DL_MODE}${NC}${DIM}  ·  audio codec: ${AUDIO_FORMAT}  ·  cookies: ${COOKIE_LABEL}${NC}"
  echo -e "${MAGENTA}║${NC}  ${CYAN}library${NC}   ${WHITE}${BASE_DIR}/${SINGLE_LABEL}${NC} ${DIM}(singles)${NC}"
  echo -e "${MAGENTA}╚$(printf '═%.0s' $(seq 1 $BOX_W))╝${NC}"
  echo ""
}

ui_step() { # $1 "1/5" $2 title $3 subtitle
  echo -e "${BOLD}${PINK}━━━ STEP $1 · $2 ━━━${NC}${DIM} $3${NC}"
}
ui_ok()   { echo -e "${CHECK} $1"; }
ui_warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
ui_err()  { echo -e "${CROSS} ${RED}$1${NC}"; }
ui_info() { echo -e "${CYAN}ℹ${NC} $1"; }
ui_kv()   { # $1 key $2 value
  echo -e "  ${CYAN}$1${NC}  $2"
}
ui_card_top()    { echo -e "${MAGENTA}╭$(printf '─%.0s' $(seq 1 $BOX_W))╮${NC}"; }
ui_card_bottom() { echo -e "${MAGENTA}╰$(printf '─%.0s' $(seq 1 $BOX_W))╯${NC}"; }

# progress bar: $1 current $2 total $3 width
ui_bar() {
  local cur=$1 tot=$2 w=${3:-28} filled empty pct
  (( tot <= 0 )) && tot=1; (( cur < 0 )) && cur=0; (( cur > tot )) && cur=$tot
  pct=$(( cur * 100 / tot )); filled=$(( cur * w / tot )); empty=$(( w - filled ))
  printf "${GREEN}%s${NC}${GRAY}%s${NC} ${BOLD}%3d%%${NC}" \
    "$(printf '█%.0s' $(seq 1 $filled 2>/dev/null) 2>/dev/null)" \
    "$(printf '░%.0s' $(seq 1 $empty 2>/dev/null) 2>/dev/null)" "$pct"
}

# spinner wrapper: with_spinner "message" cmd args...
with_spinner() {
  local msg="$1"; shift
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  "$@" & local pid=$!
  while kill -0 $pid 2>/dev/null; do
    printf "\r  ${CYAN}%s${NC} %s" "${frames:$(( i % ${#frames} )):1}" "$msg"
    i=$(( i + 1 )); sleep 0.08
  done
  wait $pid; local code=$?
  printf "\r%*s\r" 60 ""
  return $code
}

# ================================================================ core utils ==
sanitize() {
  echo "$1" | tr -d '/\\?*<>|"' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed 's/ \+/ /g'
}

valid_url() { # $1 -> 0 if looks like a url
  [[ "$1" =~ ^https?://[^[:space:]]+$ ]]
}

dedupe_urls() { # removes dupes + blanks, keeps order; operates on URLS[]
  local -A seen=(); local out=() u
  for u in "${URLS[@]}"; do
    u=$(echo "$u" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -z "$u" ]] && continue
    if [[ -z "${seen[$u]:-}" ]]; then seen[$u]=1; out+=("$u"); fi
  done
  URLS=("${out[@]}")
}

apply_profile() { # $1 normalized choice -> sets globals (testable, no I/O)
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

# build_ytdlp_args <out_array_name> <target_dir> [extra...]
# Constructs the primary-attempt arg list. Testable via --dry-run.
build_ytdlp_args() {
  local -n _out=$1; local _target=$2; shift 2
  _out=(
    -P "$_target"
    -f "$FORMAT_SELECTOR"
    --merge-output-format mp4
    --no-warnings --progress --newline
    --console-title
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
  command -v ffmpeg &>/dev/null || need_ffmpeg=true
  command -v ffprobe &>/dev/null || need_ffmpeg=true

  if [[ "$NO_UPDATE" != true ]]; then
    ui_info "Refreshing yt-dlp (official binary, bypasses stale apt builds)…"
    mkdir -p "$HOME/.local/bin"
    if curl -sL --max-time 60 https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
        -o "$HOME/.local/bin/yt-dlp"; then
      chmod a+rx "$HOME/.local/bin/yt-dlp"
    else
      ui_warn "Could not refresh yt-dlp (network?). Continuing with installed copy."
    fi
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if [[ "$need_ffmpeg" == true ]]; then
    ui_warn "ffmpeg/ffprobe missing — installing…"
    if command -v apt &>/dev/null; then
      sudo apt update && sudo apt install -y ffmpeg
    elif command -v dnf &>/dev/null; then
      sudo dnf install -y ffmpeg
    elif command -v pacman &>/dev/null; then
      sudo pacman -Sy --noconfirm ffmpeg
    elif command -v brew &>/dev/null; then
      brew install ffmpeg
    else
      ui_err "No supported package manager. Install ffmpeg manually."
      return 1
    fi
  fi

  # status table
  local yv="missing" fv="missing" js="missing"
  command -v yt-dlp &>/dev/null && yv="v$(yt-dlp --version 2>/dev/null)"
  command -v ffmpeg &>/dev/null && fv="v$(ffmpeg -version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
  for r in deno node quickjs qjs; do command -v $r &>/dev/null && { js="$r"; break; }; done
  ui_kv "yt-dlp   " "${WHITE}$yv${NC}"
  ui_kv "ffmpeg   " "${WHITE}$fv${NC}"
  if [[ "$js" == "missing" ]]; then
    ui_kv "js engine" "${YELLOW}none — 720p/1080p may hide (only 360p served). Install deno.${NC}"
    echo -e "  ${DIM}curl -fsSL https://deno.land/install.sh | sh  →  add ~/.deno/bin to PATH${NC}"
  else
    ui_kv "js engine" "${WHITE}$js${NC} ${DIM}(HD formats unlocked)${NC}"
  fi
  command -v yt-dlp &>/dev/null || { ui_err "yt-dlp unavailable. Check network and retry."; return 1; }
  command -v ffmpeg &>/dev/null || { ui_err "ffmpeg unavailable. Install it and retry."; return 1; }
  echo ""
}

# --------------------------------------------------------------- metadata ---
get_playlist_name() {
  local url="$1" pname
  pname=$(yt-dlp "${YTDLP_COOKIE_ARGS[@]}" --playlist-items 1 --no-warnings --socket-timeout 15 \
    --print "%(playlist_title)s" "$url" 2>/dev/null | head -n 1)
  if [[ -z "$pname" || "$pname" == "NA" ]]; then
    pname=$(yt-dlp "${YTDLP_COOKIE_ARGS[@]}" --playlist-items 1 --no-warnings --socket-timeout 15 \
      --print "%(channel)s" "$url" 2>/dev/null | head -n 1)
  fi
  [[ -z "$pname" || "$pname" == "NA" ]] && pname="VidFlow_Playlist_$(date +%Y%m%d_%H%M%S)"
  sanitize "$pname"
}

is_playlist() {
  local url="$1" pid
  pid=$(yt-dlp "${YTDLP_COOKIE_ARGS[@]}" --playlist-items 1 --no-warnings --socket-timeout 15 \
    --print "%(playlist_id)s" "$url" 2>/dev/null | head -n 1)
  [[ "$pid" != "NA" && -n "$pid" ]]
}

verify_resolution() { # $1 dir -> prints verified height or ""
  local dir="$1" nf vh
  nf=$(find "$dir" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.webm" \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
  [[ -n "${nf:-}" && -f "$nf" ]] || return 1
  vh=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$nf" 2>/dev/null | head -n1)
  [[ "$vh" =~ ^[0-9]+$ ]] || return 1
  echo "$vh"
  return 0
}

# ============================================================== flow steps ==
step_destination() {
  ui_step "1/5" "Library folder" "singles land here · playlists get their own folder"
  local input="${PRESET_DIR:-}"
  if [[ -z "$input" ]]; then
    read -r -p "$(echo -e "${ARROW} Folder for ${BOLD}single videos${NC} ${DIM}(in ~/Videos)${NC}${ARROW} ")" input
  fi
  input=$(sanitize "$input")
  [[ -z "$input" ]] && { input="MyVideos"; ui_warn "Empty — using '${input}'."; }
  SINGLE_LABEL="$input"
  mkdir -p "$BASE_DIR/$SINGLE_LABEL"
  ui_ok "Singles → ${UNDERLINE}${CYAN}$BASE_DIR/$SINGLE_LABEL${NC}"
  echo ""
}

step_profile() {
  ui_step "2/5" "Download profile" "video merges to mp4 · audio extracts with metadata"
  if [[ -n "${PRESET_PROFILE:-}" ]]; then
    if apply_profile "$(echo "$PRESET_PROFILE" | tr '[:upper:]' '[:lower:]')"; then
      ui_ok "Profile → ${BOLD}${QUALITY_LABEL}${NC}"
      if [[ "$DL_MODE" == "audio" && -n "${PRESET_AUDIO_FMT:-}" ]]; then
        case "$(echo "$PRESET_AUDIO_FMT" | tr '[:upper:]' '[:lower:]')" in
          mp3|m4a|opus) AUDIO_FORMAT=$(echo "$PRESET_AUDIO_FMT" | tr '[:upper:]' '[:lower:]')
            QUALITY_LABEL="Audio only · best audio → ${AUDIO_FORMAT^^}"
            ui_ok "Audio codec → ${BOLD}${AUDIO_FORMAT}${NC}";;
        esac
      fi
      echo ""; return 0
    else
      ui_warn "Ignoring invalid --quality '${PRESET_PROFILE}'."
    fi
  fi
  echo -e "  ${CYAN}[1]${NC} ${BOLD}720p${NC}   ${DIM}fast · compact — great for phones & drafts${NC}"
  echo -e "  ${CYAN}[2]${NC} ${BOLD}1080p${NC}  ${DIM}sharpest — h264-prioritised mp4 merge ${GREEN}(recommended)${NC}"
  echo -e "  ${CYAN}[3]${NC} ${BOLD}Audio · MP3${NC}  ${DIM}universal player support${NC}"
  echo -e "  ${CYAN}[4]${NC} ${BOLD}Audio · M4A${NC}  ${DIM}closest to YouTube's native audio${NC}"
  echo -e "  ${CYAN}[5]${NC} ${BOLD}Audio · OPUS${NC} ${DIM}smallest files, best quality/size${NC}"
  local c
  read -r -p "$(echo -e "  ${ARROW} Pick ${DIM}[1-5, default 2]${NC}${ARROW} ")" c
  c=$(echo "$c" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -z "$c" ]] && c="2"
  if apply_profile "$c"; then
    ui_ok "Profile → ${BOLD}${QUALITY_LABEL}${NC}"
  else
    ui_warn "Unknown '${c}' — falling back to 1080p."
    apply_profile "2"
    ui_ok "Profile → ${BOLD}${QUALITY_LABEL}${NC}"
  fi
  echo ""
}

step_cookies() {
  ui_step "3/5" "Anti-bot cookies" "optional · raises success rate on age-gated/busy IPs"
  local b="${PRESET_COOKIES:-}"
  if [[ -z "$b" ]]; then
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
  else
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
  # filter + dedupe
  local kept=() x dropped=0
  for x in "${URLS[@]}"; do valid_url "$x" && kept+=("$x") || ((dropped++)); done
  URLS=("${kept[@]}"); dedupe_urls
  (( dropped > 0 )) && ui_warn "${dropped} invalid line(s) dropped."
  ui_ok "Queue ready — ${BOLD}${#URLS[@]}${NC} unique link(s)."
  echo ""
}

step_review() {
  ui_step "5/5" "Launch check" "everything below is exactly what will run"
  ui_card_top
  echo -e "  ${CYAN}profile${NC}   ${WHITE}${QUALITY_LABEL}${NC}"
  echo -e "  ${CYAN}engine${NC}    ${DIM}${FORMAT_SELECTOR}${NC}${FORMAT_SORT:+ ${DIM}sorted: ${FORMAT_SORT}${NC}}"
  echo -e "  ${CYAN}singles${NC}   ${WHITE}$BASE_DIR/$SINGLE_LABEL${NC}  ${DIM}· playlists auto-folder${NC}"
  echo -e "  ${CYAN}cookies${NC}   ${WHITE}${COOKIE_LABEL}${NC}  ${DIM}· queue: ${#URLS[@]} link(s)${NC}"
  local i=1
  for u in "${URLS[@]:0:5}"; do echo -e "  ${DIM}$i.${NC} ${CYAN}${u:0:72}${NC}"; i=$((i+1)); done
  (( ${#URLS[@]} > 5 )) && echo -e "  ${DIM}… +$(( ${#URLS[@]} - 5 )) more${NC}"
  ui_card_bottom
  if [[ "$SKIP_CONFIRM" == true ]]; then ui_ok "Auto-confirmed (--yes). Igniting…"; return 0; fi
  local go
  read -r -p "$(echo -e "  ${ARROW} ${BOLD}Launch downloads?${NC} ${DIM}[Enter = go · e = add more links]${NC}${ARROW} ")" go
  if [[ "$go" =~ ^[Ee]$ ]]; then step_urls; step_review; return $?; fi
  echo ""
}

# ============================================================== downloader ==
download_one() { # $1 url $2 index $3 total $4 single_dir -> 0 ok
  local url="$1" idx="$2" tot="$3" single_dir="$4"
  echo -e "\n${BOLD}${PINK}▸ [$idx/$tot]${NC} ${WHITE}${url:0:100}${NC}"
  local target_dir="" is_pl=false plist=""
  if with_spinner "Detecting playlist vs single…" is_playlist "$url"; then
    is_pl=true
    plist=$(get_playlist_name "$url")
    target_dir="$BASE_DIR/$plist"
    mkdir -p "$target_dir"
    echo -e "  ${BLUE}◆ type${NC}   ${BOLD}playlist${NC} ${DIM}→ ${WHITE}$plist${NC}"
  else
    target_dir="$single_dir"
    echo -e "  ${BLUE}◆ type${NC}   ${BOLD}single${NC}"
  fi
  ui_kv "◆ dist" "${UNDERLINE}${CYAN}$target_dir${NC}"
  ui_kv "◆ spec" "${DIM}$FORMAT_SELECTOR${NC}"

  local args=()
  build_ytdlp_args args "$target_dir"
  [[ "$is_pl" == true ]] && args+=(-o "%(playlist_index)s - %(title)s.%(ext)s")
  args+=("$url")

  echo -e "  ${GREEN}⬇ downloading…${NC} ${DIM}(live yt-dlp progress below)${NC}"
  hr
  yt-dlp "${args[@]}" 2>&1 | tee -a "$LOG_FILE"
  local code=${PIPESTATUS[0]}
  hr

  if (( code != 0 )); then
    ui_warn "Primary engine failed (code $code) — retrying via ${BOLD}mweb${NC} client…"
    local fb=()
    build_ytdlp_args fb "$target_dir" --extractor-args "youtube:player_client=mweb"
    [[ "$is_pl" == true ]] && fb+=(-o "%(playlist_index)s - %(title)s.%(ext)s")
    fb+=("$url")
    yt-dlp "${fb[@]}" 2>&1 | tee -a "$LOG_FILE"
    code=${PIPESTATUS[0]}
  fi

  if (( code == 0 )) && [[ "$DL_MODE" == "video" ]]; then
    local vh=""
    vh=$(verify_resolution "$target_dir" || true)
    if [[ "$vh" =~ ^[0-9]+$ ]]; then
      if (( vh < QUALITY_HEIGHT )); then
        ui_warn "Got ${BOLD}${vh}p${NC}${YELLOW} but asked ${QUALITY_HEIGHT}p.${NC} ${DIM}YouTube withheld HD (js/PO-token/SABR?) — try: yt-dlp -F '$url'${NC}"
      else
        ui_ok "Verified ${BOLD}${vh}p${NC} ${DIM}— sharp as requested.${NC}"
      fi
    fi
  fi

  if (( code == 0 )); then echo -e "${CHECK} ${BOLD}done${NC} ${DIM}[$idx/$tot]${NC}"; else
    echo -e "${CROSS} ${RED}failed${NC} ${DIM}[$idx/$tot] code $code${NC}"; FAILED_URLS+=("$url")
  fi
  ui_bar "$idx" "$tot"; echo -e "  ${DIM}overall${NC}"
  return $code
}

run_downloads() {
  local single_dir="$BASE_DIR/$SINGLE_LABEL"
  mkdir -p "$single_dir"
  LOG_FILE="$BASE_DIR/.vidflow_$(date +%Y%m%d_%H%M%S).log"
  : > "$LOG_FILE"
  SESSION_START=$(date +%s)
  ui_banner
  echo -e "${BOLD}${WHITE}🚀  DOWNLOAD SEQUENCE  ${NC}${DIM}· ${#URLS[@]} item(s) · log: $(basename "$LOG_FILE")${NC}"
  hr2
  local ok=0 fail=0 i=0
  for url in "${URLS[@]}"; do
    i=$(( i + 1 ))
    if download_one "$url" "$i" "${#URLS[@]}" "$single_dir"; then ok=$((ok+1)); else fail=$((fail+1)); fi
  done
  local secs=$(( $(date +%s) - SESSION_START ))
  printf -v dur '%02d:%02d' $(( secs / 60 )) $(( secs % 60 ))
  echo ""
  echo -e "${MAGENTA}╔$(printf '═%.0s' $(seq 1 $BOX_W))╗${NC}"
  echo -e "${MAGENTA}║${NC}${BOLD}${WHITE}   🏁  S E S S I O N   C O M P L E T E   ·   ${dur} elapsed  🏁${NC}      ${MAGENTA}║${NC}"
  echo -e "${MAGENTA}╠$(printf '═%.0s' $(seq 1 $BOX_W))╣${NC}"
  echo -e "${MAGENTA}║${NC}   ${CHECK} success  ${BOLD}$ok${NC}   ${CROSS} failed   ${BOLD}$fail${NC}   ${DOT}  ${BLUE}library${NC}  ${UNDERLINE}${CYAN}$BASE_DIR${NC}"
  if (( fail > 0 )); then
    echo -e "${MAGENTA}║${NC}   ${RED}failed links (also in log):${NC}"
    local f; for f in "${FAILED_URLS[@]}"; do echo -e "${MAGENTA}║${NC}   ${DIM}• $f${NC}"; done
    echo -e "${MAGENTA}║${NC}   ${YELLOW}💡 429/bot-check? Re-run with --cookies chrome or a VPN, then retry.${NC}"
  fi
  echo -e "${MAGENTA}║${NC}   ${DIM}log: $LOG_FILE${NC}"
  echo -e "${MAGENTA}╚$(printf '═%.0s' $(seq 1 $BOX_W))╝${NC}"
  echo ""
}

# ================================================================== CLI =====
usage() {
  cat <<'EOF'
VidFlow v3 — premium YouTube batch downloader

Usage:
  vidFlow [options]

Options:
  -q, --quality P     720 | 1080 | audio | 1..5  (default: 1080)
  -a, --audio-format F  mp3 | m4a | opus          (default: mp3, audio mode)
  -d, --dir NAME        singles folder in ~/Videos (default: MyVideos)
  -c, --cookies B       chrome|firefox|brave|edge|opera|vivaldi|safari
  -b, --batch FILE      read URLs from file (one or many per line)
  -y, --yes             skip launch confirmation
      --no-update       skip yt-dlp self-refresh
      --dry-run         print resolved engine args, download nothing
  -h, --help            this help
  -v, --version         version

Examples:
  vidFlow -q 1080 -d MusicVideos --cookies chrome
  vidFlow -q audio -a opus -b links.txt -y
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q|--quality) PRESET_PROFILE="${2:-}"; shift 2 ;;
      -a|--audio-format) PRESET_AUDIO_FMT="${2:-}"; shift 2 ;;
      -d|--dir) PRESET_DIR="${2:-}"; shift 2 ;;
      -c|--cookies) PRESET_COOKIES="${2:-}"; shift 2 ;;
      -b|--batch) PRESET_BATCH_FILE="${2:-}"; shift 2 ;;
      -y|--yes) SKIP_CONFIRM=true; shift ;;
      --no-update) NO_UPDATE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage; exit 0 ;;
      -v|--version) echo "VidFlow v$VERSION"; exit 0 ;;
      *) echo -e "${CROSS} Unknown option: $1 (see --help)"; exit 2 ;;
    esac
  done
}

dry_run_dump() {
  ensure_deps >/dev/null 2>&1 || true
  [[ -n "${PRESET_PROFILE:-}" ]] && apply_profile "$(echo "$PRESET_PROFILE" | tr '[:upper:]' '[:lower:]')" || true
  if [[ -n "${PRESET_AUDIO_FMT:-}" ]]; then
    case "$(echo "$PRESET_AUDIO_FMT" | tr '[:upper:]' '[:lower:]')" in
      mp3|m4a|opus) AUDIO_FORMAT=$(echo "$PRESET_AUDIO_FMT" | tr '[:upper:]' '[:lower:]')
        [[ "$DL_MODE" == "audio" ]] && QUALITY_LABEL="Audio only · best audio → ${AUDIO_FORMAT^^}";;
    esac
  fi
  local args=(); build_ytdlp_args args "<target_dir>"
  echo "profile : $QUALITY_LABEL"
  echo "mode    : $DL_MODE (audio codec: $AUDIO_FORMAT)"
  echo "format  : $FORMAT_SELECTOR"
  echo "sort    : ${FORMAT_SORT:-<none>}"
  echo "cookies : ${YTDLP_COOKIE_ARGS[*]:-<none>}"
  printf 'yt-dlp'
  printf ' %q' "${args[@]}"; echo ' <URL>'
}

# ================================================================== main ====
main() {
  trap 'echo ""; ui_warn "Interrupted. Queue progress kept — re-run to resume."; exit 130' INT
  parse_args "$@"
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
