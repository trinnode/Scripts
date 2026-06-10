#!/bin/bash

# ==============================================================================
# YTDL Batch Fetcher (ytdl.sh)
# Description: Intelligent, fail-safe batch downloader for YouTube videos 
#              and playlists with dual-mode input and dynamic directory management.
# ==============================================================================

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Global array to hold URLs
URLS=()

# --- Helper Functions ---
print_header() {
    clear
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${BOLD}${MAGENTA}               YTDL BATCH FETCHER                 ${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${BLUE} ► Format: 720p max (bestvideo+bestaudio)${NC}"
    echo -e "${BLUE} ► Base:    ~/Videos/${NC}"
    echo -e "${CYAN}============================================================${NC}\n"
}

check_deps() {
    if ! command -v yt-dlp &> /dev/null; then
        echo -e "${RED}✖ ERROR: yt-dlp is not installed.${NC}"
        echo -e "${YELLOW}  Install it first:${NC}"
        echo -e "  ${CYAN}sudo apt install yt-dlp${NC} (Debian/Ubuntu)"
        echo -e "  ${CYAN}brew install yt-dlp${NC} (macOS)"
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
    pname=$(yt-dlp --print "%(playlist_title)s" "$url" 2>/dev/null)
    
    # Fallback to channel name if playlist title is unavailable
    if [[ -z "$pname" || "$pname" == "NA" ]]; then
        pname=$(yt-dlp --print "%(channel)s" "$url" 2>/dev/null)
    fi
    
    # Final fallback to timestamped name
    if [[ -z "$pname" || "$pname" == "NA" ]]; then
        pname="YouTube_Download_$(date +%Y%m%d_%H%M%S)"
    fi
    
    sanitize "$pname"
}

is_playlist() {
    local url="$1"
    local pid
    pid=$(yt-dlp --print "%(playlist_id)s" "$url" 2>/dev/null)
    if [[ "$pid" != "NA" && -n "$pid" ]]; then
        return 0 # True, it is a playlist
    else
        return 1 # False, it is a single video
    fi
}

collect_urls() {
    echo -e "${BOLD}${GREEN}STEP 2: Enter URLs${NC}"
    read -r -p "$(echo -e "${CYAN}▶ Do you have a list of links to paste all at once? (y/N): ${NC}")" batch_mode
    
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
                    break # Blank line after content means we are done
                fi
            else
                has_content=true
                batch_input+="$trimmed_line "
            fi
        done
        
        # Split the batch input string into the global URLS array
        read -r -a URLS <<< "$batch_input"
        
    else
        echo -e "\n${YELLOW}ℹ Paste URLs one by one.${NC}"
        echo -e "${YELLOW}ℹ Press ${BOLD}Enter 3 times${NC}${YELLOW} consecutively to finish.${NC}\n"
        
        local empty_count=0
        while true; do
            read -r -p "$(echo -e "${CYAN}▶ URL: ${NC}")" raw_url
            local url
            url=$(echo "$raw_url" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

            if [[ -z "$url" ]]; then
                ((empty_count++))
                if [[ $empty_count -ge 3 ]]; then
                    echo -e "\n${GREEN}✔ Input finished.${NC}\n"
                    break
                else
                    local remaining=$((3 - empty_count))
                    echo -e "${YELLOW}⚠ Empty input. Press Enter $remaining more time(s) to finish.${NC}"
                fi
            else
                empty_count=0
                URLS+=("$url")
                echo -e "${GREEN}✔ Added: ${CYAN}$url${NC}"
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
    read -r -p "$(echo -e "${CYAN}▶ Folder name for SINGLE videos (inside ~/Videos/): ${NC}")" chosen_dir
    
    chosen_dir=$(sanitize "$chosen_dir")
    if [[ -z "$chosen_dir" ]]; then
        chosen_dir="MyVideos"
        echo -e "${YELLOW}⚠ No name provided. Defaulting to '${chosen_dir}'.${NC}"
    fi
    
    local SINGLE_DIR="$BASE_DIR/$chosen_dir"
    mkdir -p "$SINGLE_DIR"
    echo -e "${GREEN}✔ Singles will save to: ${CYAN}$SINGLE_DIR${NC}\n"

    # 2. URL Collection
    collect_urls

    if [[ ${#URLS[@]} -eq 0 ]]; then
        echo -e "${RED}✖ No URLs provided. Exiting.${NC}"
        exit 0
    fi

    echo -e "${GREEN}✔ Detected ${#URLS[@]} URL(s) to process.${NC}\n"
    sleep 1

    # 3. Processing Downloads
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${BOLD}STARTING DOWNLOADS${NC}"
    echo -e "${CYAN}============================================================${NC}\n"

    local success_count=0
    local fail_count=0

    for url in "${URLS[@]}"; do
        echo -e "${BOLD}${MAGENTA}Processing:${NC} ${CYAN}$url${NC}"
        
        if is_playlist "$url"; then
            echo -e "${BLUE}↳ Type: ${BOLD}Playlist${NC}"
            local plist_name
            plist_name=$(get_playlist_name "$url")
            local target_dir="$BASE_DIR/$plist_name"
            mkdir -p "$target_dir"
            echo -e "${BLUE}↳ Target: ${CYAN}$target_dir${NC}"
            
            # Playlist Download Command
            if yt-dlp -P "$target_dir" \
                       -f "bestvideo[height<=720]+bestaudio/best[height<=720]" \
                       -o "%(playlist_index)s - %(title)s.%(ext)s" \
                       "$url" > /dev/null 2>&1; then
                echo -e "${GREEN}✔ Success: $plist_name${NC}\n"
                ((success_count++))
            else
                # Fallback to show error if it fails silently
                yt-dlp -P "$target_dir" -f "bestvideo[height<=720]+bestaudio/best[height<=720]" -o "%(playlist_index)s - %(title)s.%(ext)s" "$url"
                echo -e "${RED}✖ Failed: $plist_name${NC}\n"
                ((fail_count++))
            fi
        else
            echo -e "${BLUE}↳ Type: ${BOLD}Single Video${NC}"
            local target_dir="$SINGLE_DIR"
            echo -e "${BLUE}↳ Target: ${CYAN}$target_dir${NC}"
            
            # Single Video Download Command
            if yt-dlp -P "$target_dir" \
                       -f "bestvideo[height<=720]+bestaudio/best[height<=720]" \
                       "$url" > /dev/null 2>&1; then
                echo -e "${GREEN}✔ Success: Single Video${NC}\n"
                ((success_count++))
            else
                # Fallback to show error if it fails silently
                yt-dlp -P "$target_dir" -f "bestvideo[height<=720]+bestaudio/best[height<=720]" "$url"
                echo -e "${RED}✖ Failed: Single Video${NC}\n"
                ((fail_count++))
            fi
        fi
    done

    # 4. Final Summary
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${BOLD}${GREEN}SESSION COMPLETE${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}✔ Successful: ${success_count}${NC}"
    if [[ $fail_count -gt 0 ]]; then
        echo -e "${RED}✖ Failed:    ${fail_count}${NC}"
    fi
    echo -e "${BLUE}► Files saved in: ${CYAN}$BASE_DIR${NC}"
    echo -e "${CYAN}============================================================${NC}\n"
}

# Run main function
main "$@"