#!/bin/bash

# ==============================================================================
# VidFlow (vidflow.sh)
# Description: Premium, visual, and fail-safe batch downloader for YouTube 
#              media with auto-install, dual-mode input, and smart routing.
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

# --- Visual Helper Functions ---
print_header() {
    clear
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${BOLD}${WHITE}  🌊  V i d F l o w   -   A d v a n c e d   M e d i a   F e t c h e r  🌊  ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${MAGENTA}║${CYAN}  ► Quality:${NC} ${WHITE}720p Max (Best Video + Best Audio)             ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║${CYAN}  ► Base Path:${NC} ${WHITE}~/Videos/                                    ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║${CYAN}  ► Features:${NC} ${WHITE}Auto-Install, Live Progress, Smart Routing   ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}\n"
}

print_separator() {
    echo -e "\n${DIM}${CYAN}────────────────────────────────────────────────────────────────${NC}"
}

# --- Dependency Auto-Installer ---
ensure_deps() {
    local need_ytdlp=false
    local need_ffmpeg=false

    if ! command -v yt-dlp &> /dev/null; then need_ytdlp=true; fi
    if ! command -v ffmpeg &> /dev/null; then need_ffmpeg=true; fi

    if [[ "$need_ytdlp" == false && "$need_ffmpeg" == false ]]; then
        return 0
    fi

    echo -e "${YELLOW}⚠ Missing dependencies detected.${NC}"
    [[ "$need_ytdlp" == true ]] && echo -e "  ${RED}✖${NC} yt-dlp (Required for downloading)"
    [[ "$need_ffmpeg" == true ]] && echo -e "  ${RED}✖${NC} ffmpeg (Required for merging 720p video+audio)"
    echo -e "${CYAN}Attempting to install missing dependencies...${NC}\n"
    sleep 1

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            local brew_packages=()
            [[ "$need_ytdlp" == true ]] && brew_packages+=("yt-dlp")
            [[ "$need_ffmpeg" == true ]] && brew_packages+=("ffmpeg")
            brew install "${brew_packages[@]}"
        else
            echo -e "${RED}✖ Homebrew not found. Please install Homebrew first: https://brew.sh${NC}"
            exit 1
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if command -v apt &> /dev/null; then
            local apt_packages=()
            [[ "$need_ytdlp" == true ]] && apt_packages+=("yt-dlp")
            [[ "$need_ffmpeg" == true ]] && apt_packages+=("ffmpeg")
            sudo apt update && sudo apt install -y "${apt_packages[@]}"
        elif command -v dnf &> /dev/null; then
            local dnf_packages=()
            [[ "$need_ytdlp" == true ]] && dnf_packages+=("yt-dlp")
            [[ "$need_ffmpeg" == true ]] && dnf_packages+=("ffmpeg")
            sudo dnf install -y "${dnf_packages[@]}"
        elif command -v pacman &> /dev/null; then
            local pacman_packages=()
            [[ "$need_ytdlp" == true ]] && pacman_packages+=("yt-dlp")
            [[ "$need_ffmpeg" == true ]] && pacman_packages+=("ffmpeg")
            sudo pacman -Sy --noconfirm "${pacman_packages[@]}"
        else
            # Fallback: download binary manually
            echo -e "${YELLOW}No supported package manager found. Downloading binaries...${NC}"
            mkdir -p "$HOME/.local/bin"
            if [[ "$need_ytdlp" == true ]]; then
                curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o "$HOME/.local/bin/yt-dlp"
                chmod a+rx "$HOME/.local/bin/yt-dlp"
                export PATH="$HOME/.local/bin:$PATH"
            fi
            if [[ "$need_ffmpeg" == true ]]; then
                echo -e "${RED}✖ FFmpeg cannot be auto-installed via binary fallback.${NC}"
                echo -e "${YELLOW}Please install FFmpeg manually via your package manager.${NC}"
                exit 1
            fi
        fi
    else
        echo -e "${RED}✖ Unsupported OS for auto-installation.${NC}"
        exit 1
    fi

    # Verify installation
    if ! command -v yt-dlp &> /dev/null; then
        echo -e "\n${RED}✖ Failed to install yt-dlp. Please install it manually.${NC}"
        exit 1
    fi
    echo -e "\n${GREEN}✔ Dependencies successfully installed and verified.${NC}\n"
    sleep 1.5
}

sanitize() {
    echo "$1" | tr -d '/\\?*<>|"' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed 's/ \+/ /g'
}

get_playlist_name() {
    local url="$1"
    local pname
    # FIX: Added --playlist-items 1 to prevent fetching metadata for every video, 
    # which was causing the directory name to repeat (e.g., "Name Name Name").
    pname=$(yt-dlp --playlist-items 1 --no-warnings --print "%(playlist_title)s" "$url" 2>/dev/null | head -n 1)
    
    if [[ -z "$pname" || "$pname" == "NA" ]]; then
        pname=$(yt-dlp --playlist-items 1 --no-warnings --print "%(channel)s" "$url" 2>/dev/null | head -n 1)
    fi
    
    if [[ -z "$pname" || "$pname" == "NA" ]]; then
        pname="VidFlow_Download_$(date +%Y%m%d_%H%M%S)"
    fi
    
    sanitize "$pname"
}

is_playlist() {
    local url="$1"
    local pid
    # FIX: Added --playlist-items 1 for instant metadata checking on massive playlists
    pid=$(yt-dlp --playlist-items 1 --no-warnings --print "%(playlist_id)s" "$url" 2>/dev/null | head -n 1)
    if [[ "$pid" != "NA" && -n "$pid" ]]; then
        return 0
    else
        return 1
    fi
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

        yt-dlp -P "$target_dir" \
               -f "bestvideo[height<=720]+bestaudio/best[height<=720]" \
               "${dl_output[@]}" \
               "$url"
        
        if [[ $? -eq 0 ]]; then
            echo -e "\n${GREEN}✅ SUCCESS:${NC} Download completed without errors."
            ((success_count++))
        else
            echo -e "\n${RED}❌ FAILED:${NC} yt-dlp encountered an error (check output above)."
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