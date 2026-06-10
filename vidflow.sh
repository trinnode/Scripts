#!/bin/bash

# ==============================================================================
# VidFlow (vidflow.sh)
# Description: Premium, visual, and fail-safe batch downloader for YouTube 
#              media with dual-mode input, live progress tracking, and 
#              intelligent dynamic directory management.
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
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${BOLD}${WHITE}  🌊  V i d F l o w   -   A d v a n c e d   M e d i a   F e t c h e r  🌊  ${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${BLUE}  ► Quality: 720p Max (Best Video + Best Audio)           ${CYAN}║${NC}"
    echo -e "${CYAN}║${BLUE}  ► Base Path: ~/Videos/                                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${BLUE}  ► Features: Live Progress, Smart Routing, Batch Mode    ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
}

print_separator() {
    echo -e "\n${DIM}${CYAN}────────────────────────────────────────────────────────────────${NC}"
}

check_deps() {
    if ! command -v yt-dlp &> /dev/null; then
        echo -e "${RED}╭─ ${BOLD}✖ CRITICAL ERROR${NC}"
        echo -e "${RED}╰─${NC} ${YELLOW}yt-dlp is not installed.${NC}"
        echo -e "   ${DIM}Install it first:${NC}"
        echo -e "   ${CYAN}• Ubuntu/Debian:${NC} sudo apt install yt-dlp"
        echo -e "   ${CYAN}• macOS:${NC}         brew install yt-dlp"
        echo -e "   ${CYAN}• Generic:${NC}       sudo wget https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -O /usr/local/bin/yt-dlp && sudo chmod a+rx /usr/local/bin/yt-dlp\n"
        exit 1
    fi
}

sanitize() {
    # Removes invalid filename characters and trims leading/trailing whitespace
    echo "$1" | tr -d '/\\?*<>|"' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed 's/ \+/ /g'
}

get_playlist_name() {
    local url="$1"
    local pname
    # Silent metadata fetch
    pname=$(yt-dlp --print "%(playlist_title)s" "$url" 2>/dev/null)
    
    if [[ -z "$pname" || "$pname" == "NA" ]]; then
        pname=$(yt-dlp --print "%(channel)s" "$url" 2>/dev/null)
    fi
    
    if [[ -z "$pname" || "$pname" == "NA" ]]; then
        pname="VidFlow_Download_$(date +%Y%m%d_%H%M%S)"
    fi
    
    sanitize "$pname"
}

is_playlist() {
    local url="$1"
    local pid
    pid=$(yt-dlp --print "%(playlist_id)s" "$url" 2>/dev/null)
    if [[ "$pid" != "NA" && -n "$pid" ]]; then
        return 0 # True
    else
        return 1 # False
    fi
}

# --- Input Collection ---
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
                if [[ "$has_content" == true ]]; then
                    break
                fi
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
    check_deps

    local BASE_DIR="$HOME/Videos"
    mkdir -p "$BASE_DIR"

    # 1. Directory Configuration
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

    # 2. URL Collection
    collect_urls

    if [[ ${#URLS[@]} -eq 0 ]]; then
        echo -e "\n${RED}╭─ ${BOLD}✖ ABORTED${NC}"
        echo -e "${RED}╰─${NC} No URLs were provided. Exiting.\n"
        exit 0
    fi

    echo -e "\n${GREEN}✔ Successfully queued ${BOLD}${#URLS[@]}${NC}${GREEN} URL(s) for processing.${NC}"
    sleep 1.5

    # 3. Processing Downloads
    print_separator
    echo -e "${BOLD}${WHITE}🚀 INITIATING DOWNLOAD SEQUENCE${NC}"
    print_separator

    local success_count=0
    local fail_count=0

    for url in "${URLS[@]}"; do
        echo -e "\n${BOLD}${MAGENTA}🔍 ANALYZING:${NC} ${WHITE}$url${NC}"
        echo -e "${DIM}Checking metadata and routing...${NC}"
        
        local target_dir=""
        local dl_format="-f bestvideo[height<=720]+bestaudio/best[height<=720]"
        local dl_output=""

        if is_playlist "$url"; then
            echo -e "${BLUE}↳ Type:${NC} ${BOLD}Playlist${NC}"
            local plist_name
            plist_name=$(get_playlist_name "$url")
            target_dir="$BASE_DIR/$plist_name"
            mkdir -p "$target_dir"
            dl_output="-o \"%(playlist_index)s - %(title)s.%(ext)s\""
        else
            echo -e "${BLUE}↳ Type:${NC} ${BOLD}Single Video${NC}"
            target_dir="$SINGLE_DIR"
            dl_output="" # yt-dlp uses default title for singles
        fi
        
        echo -e "${BLUE}↳ Target:${NC} ${UNDERLINE}${CYAN}$target_dir${NC}"
        echo -e "${GREEN}⬇️  Starting download...${NC}\n"

        # Execute yt-dlp WITH live output (no /dev/null redirection)
        # We evaluate the string to properly handle the optional dl_output
        eval yt-dlp -P "\"$target_dir\"" $dl_format $dl_output "\"$url\""
        
        # Check exit status of yt-dlp
        if [[ $? -eq 0 ]]; then
            echo -e "\n${GREEN}✅ SUCCESS:${NC} Download completed without errors."
            ((success_count++))
        else
            echo -e "\n${RED}❌ FAILED:${NC} yt-dlp encountered an error (check output above)."
            ((fail_count++))
        fi
        
        print_separator
    done

    # 4. Final Summary
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${BOLD}${WHITE}  🏁  D O W N L O A D   S E S S I O N   C O M P L E T E  🏁  ${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}✔ Successful:${NC} ${BOLD}${success_count}${NC}"
    if [[ $fail_count -gt 0 ]]; then
        echo -e "${CYAN}║${NC}  ${RED}✖ Failed:${NC}    ${BOLD}${fail_count}${NC}"
    fi
    echo -e "${CYAN}║${NC}  ${BLUE}► Root Directory:${NC} ${UNDERLINE}${CYAN}$BASE_DIR${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main "$@"