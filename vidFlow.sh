#!/bin/bash

# ==============================================================================
# VidFlow (vidflow.sh) v2.3
# Description: Premium, visual, and fail-safe batch downloader for YouTube
#              media with auto-install, dual-mode input, smart routing,
#              and 720p / 1080p quality selection.
# ==============================================================================

# --- Vibrant Color & Effect Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
UNDERLINE='\033[4m'

# Global array to hold URLs
URLS=()
# Global array for yt-dlp authentication arguments
YTDLP_COOKIE_ARGS=()
# Global quality selection (default 1080p)
QUALITY_HEIGHT="1080"
QUALITY_LABEL="1080p Max (Best Video + Best Audio)"
FORMAT_SELECTOR="bestvideo[height<=1080]+bestaudio/best[height<=1080]"

# --- Visual Helper Functions ---
print_header() {
    clear
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${BOLD}${WHITE}  🌊  V i d F l o w   -   A d v a n c e d   M e d i a   F e t c h e r  🌊  ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${MAGENTA}║${CYAN}  ► Quality:${NC} ${WHITE}${QUALITY_LABEL}             ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║${CYAN}  ► Base Path:${NC} ${WHITE}~/Videos/                                    ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║${CYAN}  ► Features:${NC} ${WHITE}Auto-Install, Live Progress, Smart Routing   ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}\n"
}

print_separator() {
    echo -e "\n${DIM}${CYAN}────────────────────────────────────────────────────────────────${NC}"
}

# --- Dependency Auto-Installer ---
ensure_deps() {
    local need_ffmpeg=false
    if ! command -v ffmpeg &> /dev/null; then need_ffmpeg=true; fi

    # FORCE INSTALL LATEST yt-dlp BINARY TO BYPASS BROKEN APT VERSIONS
    echo -e "${CYAN}Ensuring latest official yt-dlp binary is installed...${NC}"
    mkdir -p "$HOME/.local/bin"
    curl -sL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o "$HOME/.local/bin/yt-dlp"
    chmod a+rx "$HOME/.local/bin/yt-dlp"
    
    # Ensure ~/.local/bin is in PATH for this session
    export PATH="$HOME/.local/bin:$PATH"

    if [[ "$need_ffmpeg" == true ]]; then
        echo -e "${YELLOW}⚠ Missing dependency: ffmpeg${NC}"
        echo -e "${CYAN}Attempting to install ffmpeg...${NC}\n"
        if command -v apt &> /dev/null; then
            sudo apt update && sudo apt install -y ffmpeg
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y ffmpeg
        elif command -v pacman &> /dev/null; then
            sudo pacman -Sy --noconfirm ffmpeg
        elif command -v brew &> /dev/null; then
            brew install ffmpeg
        else
            echo -e "${RED}✖ Please install FFmpeg manually via your system package manager.${NC}"
            exit 1
        fi
    fi

    # Verify installation
    if command -v yt-dlp &> /dev/null; then
        local ytdlp_version
        ytdlp_version=$(yt-dlp --version)
        echo -e "\n${GREEN}✔ yt-dlp (v${ytdlp_version}) successfully installed/updated.${NC}"
        echo -e "${GREEN}✔ Dependencies verified.${NC}\n"
    else
        echo -e "\n${RED}✖ Failed to install yt-dlp. Please check your internet connection.${NC}"
        exit 1
    fi
    sleep 1
}

sanitize() {
    echo "$1" | tr -d '/\\?*<>|"' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed 's/ \+/ /g'
}

get_playlist_name() {
    local url="$1"
    local pname
    pname=$(yt-dlp "${YTDLP_COOKIE_ARGS[@]}" --playlist-items 1 --no-warnings --print "%(playlist_title)s" "$url" 2>/dev/null | head -n 1)
    
    if [[ -z "$pname" || "$pname" == "NA" ]]; then
        pname=$(yt-dlp "${YTDLP_COOKIE_ARGS[@]}" --playlist-items 1 --no-warnings --print "%(channel)s" "$url" 2>/dev/null | head -n 1)
    fi
    
    if [[ -z "$pname" || "$pname" == "NA" ]]; then
        pname="VidFlow_Download_$(date +%Y%m%d_%H%M%S)"
    fi
    
    sanitize "$pname"
}

is_playlist() {
    local url="$1"
    local pid
    pid=$(yt-dlp "${YTDLP_COOKIE_ARGS[@]}" --playlist-items 1 --no-warnings --print "%(playlist_id)s" "$url" 2>/dev/null | head -n 1)
    if [[ "$pid" != "NA" && -n "$pid" ]]; then
        return 0
    else
        return 1
    fi
}

choose_quality() {
    echo -e "${BOLD}${GREEN}STEP 1.5: Quality Selection${NC}"
    echo -e "${CYAN}  [1]${NC} ${WHITE}720p${NC} ${DIM}(faster, smaller file)${NC}"
    echo -e "${CYAN}  [2]${NC} ${WHITE}1080p${NC} ${DIM}(best quality, larger file)${NC}"
    read -r -p "$(echo -e "${CYAN}▶ Choose quality ${DIM}[1/2, default: 2]${NC}${CYAN}: ${NC}")" q_choice

    # Normalize input: allow "1", "2", "720", "720p", "1080", "1080p"
    q_choice=$(echo "$q_choice" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    case "$q_choice" in
        1|720|720p)
            QUALITY_HEIGHT="720"
            QUALITY_LABEL="720p (Best Video <=720p + Best Audio)"
            FORMAT_SELECTOR="bestvideo[height<=720]+bestaudio/best[height<=720]"
            ;;
        ""|2|1080|1080p)
            QUALITY_HEIGHT="1080"
            QUALITY_LABEL="1080p Max (Best Video + Best Audio)"
            FORMAT_SELECTOR="bestvideo[height<=1080]+bestaudio/best[height<=1080]"
            ;;
        *)
            echo -e "${YELLOW}⚠ Invalid choice '${q_choice}'. Defaulting to 1080p.${NC}"
            QUALITY_HEIGHT="1080"
            QUALITY_LABEL="1080p Max (Best Video + Best Audio)"
            FORMAT_SELECTOR="bestvideo[height<=1080]+bestaudio/best[height<=1080]"
            ;;
    esac
    echo -e "${GREEN}✔ Quality set to:${NC} ${BOLD}${QUALITY_LABEL}${NC}\n"
}

collect_urls() {
    echo -e "${BOLD}${GREEN}STEP 2: URL Input${NC}"
    read -r -p "$(echo -e "${CYAN}▶ Do you have a list of links to paste all at once? ${DIM}(y/N)${NC}${CYAN}: ${NC}")" batch_mode
    
    if [[ "$batch_mode" =~ ^[Yy]$ ]]; then
        echo -e "\n${YELLOW}ℹ Paste all URLs below (separated by spaces or new lines).${NC}"
        echo -e "${YELLOW}ℹ Press ${BOLD}Enter on a blank line${NC}${YELLOW} to finish.${NC}\n"
        
        local batch_input=""
        local has_content=false
        
        while IFS= read -r line; do
            local trimmed_line
            trimmed_line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            
            if [[ -z "$trimmed_line" ]]; then
                if [[ "$has_content" == true ]]; then break; fi
            else
                has_content=true
                batch_input+="$trimmed_line "
            fi
        done
        
        read -r -a URLS <<< "$batch_input"
    else
        echo -e "\n${YELLOW}ℹ Interactive Mode: Paste URLs one by one.${NC}"
        echo -e "${YELLOW}ℹ Press ${BOLD}Enter 3 times${NC}${YELLOW} consecutively to finish.${NC}\n"
        
        local empty_count=0
        while true; do
            read -r -p "$(echo -e "${CYAN}▶ URL: ${NC}")" raw_url
            local url
            url=$(echo "$raw_url" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

            if [[ -z "$url" ]]; then
                ((empty_count++))
                if [[ $empty_count -ge 3 ]]; then
                    echo -e "\n${GREEN}✔ Input sequence finished.${NC}\n"
                    break
                else
                    local remaining=$((3 - empty_count))
                    echo -e "${YELLOW}⚠ Empty input. Press Enter $remaining more time(s) to finish.${NC}"
                fi
            else
                empty_count=0
                URLS+=("$url")
                echo -e "${GREEN}✔ Queued:${NC} ${CYAN}$url${NC}"
            fi
        done
    fi
}

# --- Main Execution ---
main() {
    print_header
    ensure_deps

    local BASE_DIR="$HOME/Videos"
    mkdir -p "$BASE_DIR"

    echo -e "${BOLD}${GREEN}STEP 1: Configuration${NC}"
    read -r -p "$(echo -e "${CYAN}▶ Folder name for SINGLE videos ${DIM}(inside ~/Videos/)${NC}${CYAN}: ${NC}")" chosen_dir
    
    chosen_dir=$(sanitize "$chosen_dir")
    if [[ -z "$chosen_dir" ]]; then
        chosen_dir="MyVideos"
        echo -e "${YELLOW}⚠ No name provided. Defaulting to '${chosen_dir}'.${NC}"
    fi
    
    local SINGLE_DIR="$BASE_DIR/$chosen_dir"
    mkdir -p "$SINGLE_DIR"
    echo -e "${GREEN}✔ Singles will route to:${NC} ${UNDERLINE}${CYAN}$SINGLE_DIR${NC}\n"

    choose_quality

    echo -e "${YELLOW}ℹ YouTube frequently blocks automated downloads (HTTP 429 / Bot check).${NC}"
    echo -e "${YELLOW}ℹ Providing browser cookies improves success rates for some users.${NC}"
    read -r -p "$(echo -e "${CYAN}▶ Enter browser name to extract cookies from ${DIM}(e.g., chrome, firefox, brave, edge, or leave blank to skip)${NC}${CYAN}: ${NC}")" browser_name
    
    browser_name=$(echo "$browser_name" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [[ -n "$browser_name" ]]; then
        if [[ "$browser_name" =~ ^(chrome|firefox|brave|edge|opera|vivaldi|safari)$ ]]; then
            YTDLP_COOKIE_ARGS=("--cookies-from-browser" "$browser_name")
            echo -e "${GREEN}✔ Will use cookies from:${NC} ${BOLD}${browser_name}${NC}\n"
        else
            echo -e "${YELLOW}⚠ Unrecognized browser '${browser_name}'. Skipping cookies.${NC}\n"
        fi
    else
        echo -e "${YELLOW}⚠ Skipping browser cookies.${NC}\n"
    fi

    collect_urls

    if [[ ${#URLS[@]} -eq 0 ]]; then
        echo -e "\n${RED}╭─ ${BOLD}✖ ABORTED${NC}"
        echo -e "${RED}╰─${NC} No URLs were provided. Exiting.\n"
        exit 0
    fi

    echo -e "\n${GREEN}✔ Successfully queued ${BOLD}${#URLS[@]}${NC}${GREEN} URL(s) for processing.${NC}"
    sleep 1.5

    print_separator
    echo -e "${BOLD}${WHITE}🚀 INITIATING DOWNLOAD SEQUENCE${NC}"
    print_separator

    local success_count=0
    local fail_count=0

    for url in "${URLS[@]}"; do
        echo -e "\n${BOLD}${MAGENTA}🔍 ANALYZING:${NC} ${WHITE}$url${NC}"
        echo -e "${DIM}Checking metadata and routing...${NC}"
        
        local target_dir=""
        local dl_output=()

        if is_playlist "$url"; then
            echo -e "${BLUE}↳ Type:${NC} ${BOLD}Playlist${NC}"
            local plist_name
            plist_name=$(get_playlist_name "$url")
            target_dir="$BASE_DIR/$plist_name"
            mkdir -p "$target_dir"
            dl_output=("-o" "%(playlist_index)s - %(title)s.%(ext)s")
        else
            echo -e "${BLUE}↳ Type:${NC} ${BOLD}Single Video${NC}"
            target_dir="$SINGLE_DIR"
            dl_output=()
        fi
        
        echo -e "${BLUE}↳ Target:${NC} ${UNDERLINE}${CYAN}$target_dir${NC}"
        echo -e "${GREEN}⬇️  Starting download...${NC}\n"

        # Primary attempt: Use web_embedded and android clients (bypasses "page needs to be reloaded")
        local ytdlp_args=(
            -P "$target_dir"
            -f "$FORMAT_SELECTOR"
            --no-warnings
            --retry-sleep 2
            --extractor-args "youtube:player_client=web_embedded,android"
        )
        
        ytdlp_args+=("${YTDLP_COOKIE_ARGS[@]}")
        
        if [[ ${#dl_output[@]} -gt 0 ]]; then
            ytdlp_args+=("${dl_output[@]}")
        fi
        
        ytdlp_args+=("$url")

        # Execute primary attempt
        yt-dlp "${ytdlp_args[@]}"
        local exit_code=$?

        # AUTO-RETRY FALLBACK: If it fails with "reloaded" or 403, retry once with NO cookies and 'default' client
        if [[ $exit_code -ne 0 ]]; then
            echo -e "\n${YELLOW}⚠ Primary attempt failed. Triggering fallback retry (no cookies, default client)...${NC}"
            sleep 2
            
            local fallback_args=(
                -P "$target_dir"
                -f "$FORMAT_SELECTOR"
                --no-warnings
                --retry-sleep 3
                --extractor-args "youtube:player_client=default"
                "$url"
            )
            
            yt-dlp "${fallback_args[@]}"
            exit_code=$?
        fi
        
        if [[ $exit_code -eq 0 ]]; then
            echo -e "\n${GREEN}✅ SUCCESS:${NC} Download completed without errors."
            ((success_count++))
        else
            echo -e "\n${RED}❌ FAILED:${NC} yt-dlp encountered an error."
            echo -e "${YELLOW}💡 TIP: YouTube may be temporarily blocking your IP. Try using a VPN or waiting a few hours.${NC}"
            ((fail_count++))
        fi
        
        print_separator
    done

    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${BOLD}${WHITE}  🏁  D O W N L O A D   S E S S I O N   C O M P L E T E  🏁  ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${MAGENTA}║${NC}  ${GREEN}✔ Successful:${NC} ${BOLD}${success_count}${NC}"
    if [[ $fail_count -gt 0 ]]; then
        echo -e "${MAGENTA}║${NC}  ${RED}✖ Failed:${NC}    ${BOLD}${fail_count}${NC}"
    fi
    echo -e "${MAGENTA}║${NC}  ${BLUE}► Root Directory:${NC} ${UNDERLINE}${CYAN}$BASE_DIR${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}\n"
}

main "$@"
