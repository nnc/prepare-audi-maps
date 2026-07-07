#!/usr/bin/env zsh
#
# prepare-audi-maps.zsh — prepare a USB drive for Audi / VW MIB2 navigation
# map updates on macOS.
#
# Verifies an official map package ZIP, formats a USB drive (MBR + ExFAT),
# copies the package to the USB root, and strips all macOS metadata that is
# known to make MIB2 head units reject the drive.
#
# Requirements: macOS 13 (Ventura) or newer, stock system tools only.
#
# Exit codes: 0 success, 1 error, 130 interrupted.

set -euo pipefail
setopt EXTENDED_GLOB

# Prevent macOS from generating AppleDouble (._*) companion files where possible.
export COPYFILE_DISABLE=1

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

readonly VERSION='1.0.2'
readonly SCRIPT_NAME="${0:t}"
readonly USB_LABEL='AUDIMAPS'          # ExFAT volume label applied when formatting
readonly MOUNT_WAIT_SECS=30            # max seconds to wait for the volume to mount
readonly -a METADATA_DIRS=('.Spotlight-V100' '.Trashes' '.fseventsd' '__MACOSX')

# Log file lives next to wherever the user invoked the script.
LOG_FILE="${PWD}/prepare-audi-maps.log"

# --------------------------------------------------------------------------
# Mutable state
# --------------------------------------------------------------------------

ZIP_PATH=''            # absolute path to the map package ZIP
ZIP_SHA256=''          # SHA-256 of the ZIP
TMP_DIR=''             # scratch directory, removed on exit
PKG_WRAPPER=''         # '.' if metainfo2.txt is at ZIP root, else the wrapper dir name
PKG_ROOT=''            # extracted directory whose contents go to the USB root
PKG_REGION=''          # human-readable region guess from the ZIP name
PKG_BYTES=0            # uncompressed package size in bytes (0 = unknown)
SELECTED_DISK=''       # whole-disk identifier chosen by the user (e.g. disk4)
SELECTED_MEDIA=''      # hardware media name of the chosen disk
SELECTED_CAP=''        # human-readable capacity of the chosen disk
SELECTED_BYTES=0       # capacity of the chosen disk in bytes
MOUNT_POINT=''         # mount point of the target volume after formatting

# Parallel arrays describing detected USB disks (1-indexed, zsh style).
typeset -ga USB_DEVS USB_MEDIA USB_VOLS USB_FS USB_CAPS USB_BYTES

# Option flags.
VERIFY_COPY=0
DRY_RUN=0
SKIP_FORMAT=0
NO_EJECT=0
VERBOSE=0
QUIET=0

# --------------------------------------------------------------------------
# Colours & output
# --------------------------------------------------------------------------

# Enables ANSI colours only when stdout is a terminal and NO_COLOR is unset.
setup_colors() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m';   C_RESET=$'\033[0m'
    else
        C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
    fi
    typeset -gr C_RED C_GREEN C_YELLOW C_BLUE C_BOLD C_RESET
}

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Appends one line to the log file; never fails the script.
log_file() { print -r -- "[$(timestamp)] $1" >> "$LOG_FILE" 2>/dev/null || true; }

# Informational step message (suppressed by --quiet).
info() {
    if (( ! QUIET )); then print -r -- "${C_BLUE}==>${C_RESET} $*"; fi
    log_file "[INFO] $*"
}

# Success message (suppressed by --quiet).
ok() {
    if (( ! QUIET )); then print -r -- "${C_GREEN}✓${C_RESET} $*"; fi
    log_file "[ OK ] $*"
}

# Warning; always shown, never fatal.
warn() {
    print -r -- "${C_YELLOW}! $*${C_RESET}" >&2
    log_file "[WARN] $*"
}

# Error message; always shown.
error() {
    print -r -- "${C_RED}✗ $*${C_RESET}" >&2
    log_file "[ERR ] $*"
}

# Fatal error: log, print, exit.
die() { error "$@"; exit 1; }

# Extra diagnostics, shown only with --verbose but always logged.
debug() {
    if (( VERBOSE )); then print -r -- "${C_BLUE}  [debug]${C_RESET} $*"; fi
    log_file "[DBG ] $*"
}

# Plain output that is part of the UI (menus, summaries); shown even in quiet
# mode when it is required for interaction.
say() { print -r -- "$@"; }

print_banner() {
    if (( QUIET )); then return 0; fi
    say "${C_BOLD}==========================================="
    say " Audi / VW MIB2 Map USB Creator"
    say " Version ${VERSION}"
    say "===========================================${C_RESET}"
}

# --------------------------------------------------------------------------
# Traps & cleanup
# --------------------------------------------------------------------------

# Removes the scratch directory. Runs on every exit path.
cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        debug "Removing temporary directory: $TMP_DIR"
        rm -rf -- "$TMP_DIR" || true
    fi
}

on_interrupt() {
    print ''
    error 'Interrupted. Cleaning up.'
    exit 130
}

on_unexpected_error() {
    error "An unexpected error occurred. Details may be in: $LOG_FILE"
}

trap cleanup EXIT
trap on_interrupt INT TERM
trap on_unexpected_error ZERR

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

usage() {
    cat <<EOF
${SCRIPT_NAME} ${VERSION} — prepare a USB drive for Audi / VW MIB2 map updates

USAGE:
    ${SCRIPT_NAME} [options] [map-package.zip]

    With no ZIP argument the script asks for one interactively.

OPTIONS:
    --verify-copy    After copying, re-compare source and USB with checksums.
    --dry-run        Validate the ZIP and show the plan; change nothing.
    --skip-format    Do not format; require an existing ExFAT/FAT32 volume.
    --no-eject       Leave the USB mounted when finished.
    -v, --verbose    Extra diagnostics.
    -q, --quiet      Only warnings, errors and prompts.
    -h, --help       Show this help.
    --version        Show version.

EXAMPLES:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} HIGH2_P450_EU_202625.zip
    ${SCRIPT_NAME} --verify-copy "~/Downloads/HIGH2_P450_EU_202625.zip"

NOTES:
    Formatting erases the selected USB drive completely. The script only
    proceeds after you select the disk and type YES.

    Extraction needs free space in \$TMPDIR at least equal to the unpacked
    package size. Set TMPDIR to another volume if the boot disk is tight.

    A log is written to: prepare-audi-maps.log (current directory).
EOF
}

# Verifies the platform and the required tools exist before doing anything.
preflight() {
    [[ "$(uname -s)" == 'Darwin' ]] || die 'This tool supports macOS only.'
    local cmd
    for cmd in diskutil plutil unzip rsync shasum mktemp df; do
        command -v "$cmd" > /dev/null 2>&1 || die "Required command not found: $cmd"
    done
    # Optional tools are checked at use time (dot_clean, mdutil).
    if ! touch "$LOG_FILE" 2>/dev/null; then
        warn "Cannot write log file at $LOG_FILE — logging disabled."
        LOG_FILE='/dev/null'
    fi
}

# Extracts one value from a plist string by keypath; prints it on stdout.
# Returns non-zero (and prints nothing) when the keypath does not exist.
# For arrays, the 'raw' format prints the element count.
plist_get() {
    local plist="$1" keypath="$2"
    print -r -- "$plist" | plutil -extract "$keypath" raw -o - - 2>/dev/null
}

# Formats a byte count as a decimal-unit human size (matching diskutil).
human_size() {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB TB", u, " ");
        s = b + 0; i = 1;
        while (s >= 1000 && i < 5) { s /= 1000; i++ }
        if (i == 1) printf "%d %s", s, u[i]; else printf "%.1f %s", s, u[i];
    }'
}

# Escapes a string for safe use inside an extended regular expression.
re_escape() { print -r -- "$1" | sed -e 's/[][\.|$(){}?+*^]/\\&/g'; }

# Runs a command in the background with a spinner, capturing all of its
# output into $RUN_OUTPUT and appending it to the log.
# Usage: run_with_spinner "message" cmd [args...]   Returns the command status.
RUN_OUTPUT=''
run_with_spinner() {
    local msg="$1"; shift
    local outfile rc=0 pid
    outfile="$(mktemp "${TMP_DIR:-${TMPDIR:-/tmp}}/pam-out.XXXXXX")"

    "$@" > "$outfile" 2>&1 &
    pid=$!

    if [[ -t 1 ]] && (( ! QUIET )); then
        local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=1
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r%s%s%s %s ' "$C_BLUE" "${frames[i]}" "$C_RESET" "$msg"
            (( i = i % ${#frames} + 1 ))
            sleep 0.1
        done
        printf '\r\033[K'
    else
        info "$msg"
    fi

    wait "$pid" || rc=$?
    RUN_OUTPUT="$(< "$outfile")"
    rm -f -- "$outfile"
    log_file "[CMD ] $* (exit $rc)"
    if [[ -n "$RUN_OUTPUT" ]]; then
        print -r -- "$RUN_OUTPUT" | tail -n 50 >> "$LOG_FILE" 2>/dev/null || true
    fi
    return $rc
}

# Requires an interactive terminal for prompts; dies otherwise.
require_tty() {
    [[ -t 0 ]] || die "$1 requires an interactive terminal."
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------

parse_args() {
    local end_of_opts=0
    while (( $# > 0 )); do
        if (( end_of_opts )); then
            [[ -z "$ZIP_PATH" ]] || die 'Only one ZIP file may be given.'
            ZIP_PATH="$1"; shift; continue
        fi
        case "$1" in
            -h|--help)      usage; exit 0 ;;
            --version)      print -r -- "${SCRIPT_NAME} ${VERSION}"; exit 0 ;;
            --verify-copy)  VERIFY_COPY=1 ;;
            --dry-run)      DRY_RUN=1 ;;
            --skip-format)  SKIP_FORMAT=1 ;;
            --no-eject)     NO_EJECT=1 ;;
            -v|--verbose)   VERBOSE=1 ;;
            -q|--quiet)     QUIET=1 ;;
            --)             end_of_opts=1 ;;
            -*)             die "Unknown option: $1 (see --help)" ;;
            *)              [[ -z "$ZIP_PATH" ]] || die 'Only one ZIP file may be given.'
                            ZIP_PATH="$1" ;;
        esac
        shift
    done
    if (( VERBOSE && QUIET )); then
        die '--verbose and --quiet are mutually exclusive.'
    fi
}

# --------------------------------------------------------------------------
# ZIP input & verification
# --------------------------------------------------------------------------

# Normalises a user-supplied path: strips surrounding quotes, unescapes
# spaces from terminal drag-and-drop, expands a leading tilde.
normalize_path() {
    local p="$1"
    p="${p## }"; p="${p%% }"                       # trim spaces
    if [[ "$p" == \"*\" || "$p" == \'*\' ]]; then  # strip matching quotes
        p="${p[2,-2]}"
    fi
    p="${p//\\ / }"                                # drag-and-drop escapes
    if [[ "$p" == '~' || "$p" == '~/'* ]]; then    # tilde expansion
        p="${HOME}${p#\~}"
    fi
    print -r -- "$p"
}

# Ensures ZIP_PATH points at a readable ZIP; prompts interactively if absent.
resolve_zip() {
    if [[ -z "$ZIP_PATH" ]]; then
        require_tty 'Selecting a map package'
        say ''
        say 'Enter the path to the map package ZIP (you can drag & drop it here):'
        local answer=''
        read -r 'answer?ZIP file: ' || die 'No input received.'
        ZIP_PATH="$answer"
    fi
    ZIP_PATH="$(normalize_path "$ZIP_PATH")"
    [[ -n "$ZIP_PATH" ]] || die 'No ZIP file given.'
    [[ -e "$ZIP_PATH" ]] || die "File not found: $ZIP_PATH"
    [[ -f "$ZIP_PATH" ]] || die "Not a regular file: $ZIP_PATH"
    [[ -r "$ZIP_PATH" ]] || die "File is not readable: $ZIP_PATH"
    ZIP_PATH="${ZIP_PATH:A}"    # absolute, symlinks resolved
    if [[ "${ZIP_PATH:l}" != *.zip ]]; then
        warn "File does not have a .zip extension: ${ZIP_PATH:t}"
    fi
    info "Map package: ${ZIP_PATH}"
    log_file "[ZIP ] $ZIP_PATH"
}

# Tests archive integrity with unzip -t; aborts on any failure.
verify_zip() {
    if ! run_with_spinner 'Testing ZIP integrity (unzip -t)...' unzip -tq "$ZIP_PATH"; then
        error 'The ZIP archive is damaged or incomplete.'
        die   'Re-download the map package and try again.'
    fi
    ok 'ZIP verified'
}

# Computes and prints the SHA-256 of the ZIP.
compute_sha256() {
    run_with_spinner 'Computing SHA-256 checksum...' shasum -a 256 "$ZIP_PATH" \
        || die 'Failed to compute SHA-256.'
    ZIP_SHA256="${RUN_OUTPUT%% *}"
    [[ "$ZIP_SHA256" == [0-9a-f](#c64) ]] || die 'Could not parse shasum output.'
    say "SHA-256: ${C_BOLD}${ZIP_SHA256}${C_RESET}"
    log_file "[SHA ] $ZIP_SHA256"
}

# --------------------------------------------------------------------------
# Package layout detection (from the ZIP listing, before extraction)
# --------------------------------------------------------------------------

# Locates the package root inside the archive without extracting it.
# Accepts:
#   metainfo2.txt at the ZIP root                         -> PKG_WRAPPER='.'
#   metainfo2.txt inside exactly one wrapper directory    -> PKG_WRAPPER=<dir>
# Mib1/Mib2 directories carry their own metainfo2.txt copies as part of the
# package payload, so they are never wrapper candidates and a root
# metainfo2.txt always wins. Anything else is rejected.
analyze_zip_layout() {
    local listing
    listing="$(unzip -Z1 "$ZIP_PATH")" || die 'Could not read the ZIP file listing.'

    local root_hit=0
    grep -qx 'metainfo2\.txt' <<< "$listing" && root_hit=1

    local -a wrappers
    wrappers=(${(f)"$(grep -E '^[^/]+/metainfo2\.txt$' <<< "$listing" \
                      | sed 's|/metainfo2\.txt$||' | grep -viE '^(__MACOSX|mib[12])$' \
                      | sort -u || true)"})

    if (( root_hit )); then
        PKG_WRAPPER='.'
    elif (( ${#wrappers} == 1 )); then
        PKG_WRAPPER="${wrappers[1]}"
    elif (( ${#wrappers} > 1 )); then
        die "Ambiguous package: metainfo2.txt found in more than one wrapper directory (${wrappers[*]})."
    else
        die 'metainfo2.txt not found at the ZIP root or inside a wrapper directory — this does not look like a MIB2 map package.'
    fi
    debug "Package wrapper directory: ${PKG_WRAPPER}"

    # Quick pre-extraction sanity check for Mib1/Mib2 (authoritative check
    # happens again on the extracted files).
    local prefix=''
    [[ "$PKG_WRAPPER" != '.' ]] && prefix="$(re_escape "$PKG_WRAPPER")/"
    local mib_found=0
    grep -qiE "^${prefix}mib1(/|$)" <<< "$listing" && mib_found=1
    grep -qiE "^${prefix}mib2(/|$)" <<< "$listing" && mib_found=1
    (( mib_found )) || die 'Neither Mib1 nor Mib2 found in the package.'

    # Uncompressed size from the unzip summary line; best-effort only.
    local total_line
    total_line="$(unzip -l "$ZIP_PATH" 2>/dev/null | tail -n 1 || true)"
    local bytes="${${(z)total_line}[1]:-}"
    if [[ "$bytes" == <-> ]]; then
        PKG_BYTES="$bytes"
        debug "Uncompressed package size: $(human_size "$PKG_BYTES")"
    else
        warn 'Could not determine the uncompressed package size; skipping space checks.'
    fi

    ok 'Package structure detected'
}

# Guesses the map region from the ZIP file name (informational only).
detect_region() {
    local name="${${ZIP_PATH:t}:u}"
    case "$name" in
        (*_EU_*|*_ECE_*)     PKG_REGION='Europe' ;;
        (*_NAR_*|*_NA_*|*_USA_*) PKG_REGION='North America' ;;
        (*_JP_*|*_JPN_*)     PKG_REGION='Japan' ;;
        (*_CN_*|*_CHN_*)     PKG_REGION='China' ;;
        (*_KR_*|*_KOR_*)     PKG_REGION='Korea' ;;
        (*_AUNZ_*|*_AU_*)    PKG_REGION='Australia / New Zealand' ;;
        (*_ROW_*)            PKG_REGION='Rest of World' ;;
        (*)                  PKG_REGION='Unknown (not encoded in file name)' ;;
    esac
}

# --------------------------------------------------------------------------
# Extraction & validation
# --------------------------------------------------------------------------

# Verifies there is enough free space at the given path for the package.
check_free_space() {
    local where="$1" need="$2" label="$3"
    (( need > 0 )) || return 0
    local avail_kb
    avail_kb="$(df -Pk "$where" | awk 'NR == 2 { print $4 }')"
    [[ "$avail_kb" == <-> ]] || { warn "Could not check free space on ${label}."; return 0; }
    local avail=$(( avail_kb * 1024 ))
    # 5% headroom for filesystem overhead.
    local need_pad=$(( need + need / 20 ))
    if (( avail < need_pad )); then
        die "Not enough free space on ${label}: need ~$(human_size "$need_pad"), have $(human_size "$avail")."
    fi
    debug "Free space on ${label}: $(human_size "$avail") (need ~$(human_size "$need_pad"))"
}

# Extracts the ZIP into the scratch directory and sets PKG_ROOT.
extract_zip() {
    local dest="$TMP_DIR/extract"
    mkdir -p -- "$dest"
    check_free_space "$TMP_DIR" "$PKG_BYTES" 'the temporary directory (set TMPDIR to change it)'

    local rc=0
    run_with_spinner 'Extracting package to a temporary directory...' \
        unzip -q "$ZIP_PATH" -d "$dest" -x '__MACOSX/*' || rc=$?
    if (( rc > 1 )); then    # unzip exit 1 means warnings only
        die "Extraction failed (unzip exit code $rc)."
    elif (( rc == 1 )); then
        warn 'unzip reported warnings during extraction (continuing).'
    fi

    if [[ "$PKG_WRAPPER" == '.' ]]; then
        PKG_ROOT="$dest"
    else
        PKG_ROOT="$dest/$PKG_WRAPPER"
    fi
    [[ -d "$PKG_ROOT" ]] || die "Extracted package directory not found: $PKG_ROOT"
    ok 'Package extracted'
}

# Validates the extracted package and prints the content summary.
validate_package() {
    [[ -f "$PKG_ROOT/metainfo2.txt" ]] || die 'metainfo2.txt missing after extraction.'

    # Case-insensitive lookup: FAT/ExFAT and APFS default are case-insensitive.
    local -a mib1 mib2
    mib1=("$PKG_ROOT"/(#i)mib1(N/))
    mib2=("$PKG_ROOT"/(#i)mib2(N/))
    (( ${#mib1} || ${#mib2} )) || die 'Neither Mib1 nor Mib2 directory found in the package.'

    say ''
    say "${C_BOLD}Package summary${C_RESET}"
    say "  Region:   ${PKG_REGION}"
    if (( PKG_BYTES > 0 )); then
        say "  Size:     $(human_size "$PKG_BYTES") (uncompressed)"
    fi
    say '  Contains:'
    say "    ${C_GREEN}✓${C_RESET} metainfo2.txt"
    (( ${#mib1} )) && say "    ${C_GREEN}✓${C_RESET} ${mib1[1]:t}"
    (( ${#mib2} )) && say "    ${C_GREEN}✓${C_RESET} ${mib2[1]:t}"
    local extra
    for extra in "$PKG_ROOT"/*(N); do
        case "${extra:t:l}" in
            (metainfo2.txt|mib1|mib2) ;;
            (*) say "    ${C_YELLOW}•${C_RESET} ${extra:t} (extra item, will be copied)" ;;
        esac
    done
    say ''
    log_file "[PKG ] root=$PKG_ROOT region=$PKG_REGION mib1=${#mib1} mib2=${#mib2}"
}

# --------------------------------------------------------------------------
# USB detection & selection
# --------------------------------------------------------------------------

# Populates the USB_* arrays with every external physical USB whole-disk.
# Parses diskutil's plist output via plutil — no fragile text scraping.
detect_usb_disks() {
    USB_DEVS=() USB_MEDIA=() USB_VOLS=() USB_FS=() USB_CAPS=() USB_BYTES=()

    local plist count
    plist="$(diskutil list -plist external physical)" || die 'diskutil failed.'
    count="$(plist_get "$plist" 'AllDisksAndPartitions')" || count=0
    debug "External physical disks reported by diskutil: $count"

    local i dev dinfo bus internal virtual media size
    for (( i = 0; i < count; i++ )); do
        dev="$(plist_get "$plist" "AllDisksAndPartitions.$i.DeviceIdentifier")" || continue
        dinfo="$(diskutil info -plist "$dev")" || continue

        bus="$(plist_get "$dinfo" 'BusProtocol')"           || bus=''
        internal="$(plist_get "$dinfo" 'Internal')"         || internal='true'
        virtual="$(plist_get "$dinfo" 'VirtualOrPhysical')" || virtual=''
        if [[ "$bus" != 'USB' || "$internal" != 'false' || "$virtual" == 'Virtual' ]]; then
            debug "Skipping $dev (bus=$bus internal=$internal virtual=$virtual)"
            continue
        fi

        media="$(plist_get "$dinfo" 'MediaName')" || media='Unknown device'
        size="$(plist_get "$dinfo" 'TotalSize')"  || size=0

        # First mounted partition provides the volume name and filesystem.
        local vol='(no mounted volume)' fs='—'
        local pkey pcount j pdev pinfo mp
        for pkey in 'Partitions' 'APFSVolumes'; do
            pcount="$(plist_get "$plist" "AllDisksAndPartitions.$i.$pkey")" || pcount=0
            for (( j = 0; j < pcount; j++ )); do
                pdev="$(plist_get "$plist" "AllDisksAndPartitions.$i.$pkey.$j.DeviceIdentifier")" || continue
                pinfo="$(diskutil info -plist "$pdev")" || continue
                mp="$(plist_get "$pinfo" 'MountPoint')" || mp=''
                [[ -n "$mp" ]] || continue
                vol="$(plist_get "$pinfo" 'VolumeName')"     || vol='(unnamed)'
                fs="$(plist_get "$pinfo" 'FilesystemName')"  || fs='Unknown'
                break
            done
            [[ "$vol" != '(no mounted volume)' ]] && break
        done

        USB_DEVS+=("$dev")
        USB_MEDIA+=("$media")
        USB_VOLS+=("$vol")
        USB_FS+=("$fs")
        USB_CAPS+=("$(human_size "$size")")
        USB_BYTES+=("$size")
    done
    return 0
}

# Prints the numbered menu of detected drives.
print_usb_menu() {
    say ''
    say "${C_BOLD}Detected USB drives:${C_RESET}"
    local i
    for (( i = 1; i <= ${#USB_DEVS}; i++ )); do
        say "  ${C_BOLD}$i)${C_RESET} ${USB_MEDIA[i]}  (${USB_DEVS[i]})"
        say "     Volume:     ${USB_VOLS[i]}"
        say "     Filesystem: ${USB_FS[i]}"
        say "     Capacity:   ${USB_CAPS[i]}"
    done
    say ''
}

# Detects drives (rescanning interactively until one appears) and lets the
# user pick one by number. Sets SELECTED_*.
select_usb_disk() {
    info 'Scanning for USB drives...'
    detect_usb_disks

    while (( ${#USB_DEVS} == 0 )); do
        if (( DRY_RUN )); then
            warn 'No USB drives detected (dry run — continuing anyway).'
            return 0
        fi
        require_tty 'USB drive selection'
        warn 'No USB drives detected.'
        local answer=''
        read -r 'answer?Insert a USB drive and press Enter to rescan (or type q to abort): ' \
            || die 'Aborted.'
        [[ "${answer:l}" == 'q' ]] && die 'Aborted by user.'
        detect_usb_disks
    done

    print_usb_menu

    local choice=1
    if (( ${#USB_DEVS} > 1 )); then
        require_tty 'USB drive selection'
        while true; do
            read -r "choice?Choose drive [1-${#USB_DEVS}]: " || die 'Aborted.'
            if [[ "$choice" == <-> ]] && (( choice >= 1 && choice <= ${#USB_DEVS} )); then
                break
            fi
            error "Invalid selection: '$choice'"
        done
    else
        info "One USB drive found — selecting it."
    fi

    SELECTED_DISK="${USB_DEVS[choice]}"
    SELECTED_MEDIA="${USB_MEDIA[choice]}"
    SELECTED_CAP="${USB_CAPS[choice]}"
    SELECTED_BYTES="${USB_BYTES[choice]}"
    log_file "[USB ] $SELECTED_DISK ($SELECTED_MEDIA, $SELECTED_CAP)"

    if (( PKG_BYTES > 0 && SELECTED_BYTES > 0 && SELECTED_BYTES < PKG_BYTES )); then
        die "The selected drive ($SELECTED_CAP) is smaller than the package ($(human_size "$PKG_BYTES"))."
    fi
}

# Final safety gate before any destructive operation: requires typing YES.
confirm_erase() {
    say ''
    say "${C_RED}${C_BOLD}The following drive will be COMPLETELY ERASED:${C_RESET}"
    say "  Volume:   ${USB_VOLS[${USB_DEVS[(ie)$SELECTED_DISK]}]:-—}"
    say "  Device:   ${SELECTED_MEDIA}"
    say "  Disk:     ${SELECTED_DISK}"
    say "  Capacity: ${SELECTED_CAP}"
    say ''
    require_tty 'Format confirmation'
    local answer=''
    read -r 'answer?Type YES (uppercase) to erase this drive, anything else aborts: ' || true
    [[ "$answer" == 'YES' ]] || die 'Aborted — the drive was not modified.'
}

# --------------------------------------------------------------------------
# Formatting
# --------------------------------------------------------------------------

# Erases the selected disk as MBR + ExFAT with the standard label.
format_disk() {
    info "Formatting ${SELECTED_DISK} as ExFAT (MBR)..."
    diskutil unmountDisk "$SELECTED_DISK" > /dev/null 2>&1 || true
    if ! run_with_spinner "Erasing ${SELECTED_DISK}..." \
            diskutil eraseDisk ExFAT "$USB_LABEL" MBR "$SELECTED_DISK"; then
        error "diskutil eraseDisk failed:"
        print -r -- "$RUN_OUTPUT" >&2
        # macOS blocks disk erasure for apps without the Removable Volumes
        # permission; surface the actionable fix instead of a generic error.
        if [[ "$RUN_OUTPUT" == *'restricted by Sandbox'* || "$RUN_OUTPUT" == *'-69464'* ]]; then
            say ''
            say "${C_YELLOW}Your terminal app is not allowed to erase removable drives.${C_RESET}"
            say 'Fix: System Settings → Privacy & Security → Files & Folders →'
            say '     your terminal app → enable "Removable Volumes"'
            say '     (or grant it Full Disk Access), then QUIT and REOPEN the'
            say '     terminal app and re-run this command.'
            die 'Formatting blocked by macOS privacy settings.'
        fi
        die 'Formatting failed. Re-insert the drive and try again.'
    fi
    ok "Formatted ${SELECTED_DISK} (ExFAT, MBR, label ${USB_LABEL})"
}

# Confirms partition scheme + filesystem after formatting and resolves the
# mount point. Aborts if anything is not as requested.
verify_format() {
    local dinfo scheme
    dinfo="$(diskutil info -plist "$SELECTED_DISK")" || die 'diskutil info failed after formatting.'
    scheme="$(plist_get "$dinfo" 'Content')" || scheme=''
    if [[ "$scheme" != 'FDisk_partition_scheme' ]]; then
        die "Partition scheme is '$scheme', expected MBR (FDisk_partition_scheme)."
    fi

    local plist pdev
    plist="$(diskutil list -plist "$SELECTED_DISK")" || die 'diskutil list failed after formatting.'
    pdev="$(plist_get "$plist" 'AllDisksAndPartitions.0.Partitions.0.DeviceIdentifier')" \
        || die 'No partition found after formatting.'

    resolve_mount_point "$pdev" 1
    ok "Verified: MBR partition scheme, ExFAT filesystem, mounted at ${MOUNT_POINT}"
}

# Waits for the given partition to mount, verifies its filesystem and sets
# MOUNT_POINT. Second arg: 1 = require ExFAT exactly, 0 = allow ExFAT/FAT32.
resolve_mount_point() {
    local pdev="$1" strict="$2"
    local pinfo fstype mp='' waited=0

    while (( waited < MOUNT_WAIT_SECS )); do
        pinfo="$(diskutil info -plist "$pdev")" || die "diskutil info failed for $pdev."
        mp="$(plist_get "$pinfo" 'MountPoint')" || mp=''
        [[ -n "$mp" ]] && break
        if (( waited == 5 )); then
            diskutil mount "$pdev" > /dev/null 2>&1 || true
        fi
        sleep 1
        (( waited++ )) || true
    done
    [[ -n "$mp" ]] || die "The volume on $pdev did not mount within ${MOUNT_WAIT_SECS}s."

    fstype="$(plist_get "$pinfo" 'FilesystemType')" || fstype=''
    if (( strict )); then
        [[ "$fstype" == 'exfat' ]] || die "Filesystem is '$fstype', expected exfat."
    else
        [[ "$fstype" == 'exfat' || "$fstype" == 'msdos' ]] \
            || die "Filesystem is '$fstype'; MIB2 needs ExFAT or FAT32. Run without --skip-format."
    fi
    MOUNT_POINT="$mp"
    log_file "[MNT ] $pdev at $MOUNT_POINT ($fstype)"
}

# --skip-format path: use the drive's existing first mounted partition after
# checking that its filesystem is MMI-compatible.
use_existing_volume() {
    info "Skipping format (--skip-format); checking the existing volume..."
    local plist pdev
    plist="$(diskutil list -plist "$SELECTED_DISK")" || die 'diskutil list failed.'
    pdev="$(plist_get "$plist" 'AllDisksAndPartitions.0.Partitions.0.DeviceIdentifier')" \
        || die "No partition found on ${SELECTED_DISK}."

    local scheme dinfo
    dinfo="$(diskutil info -plist "$SELECTED_DISK")" || die 'diskutil info failed.'
    scheme="$(plist_get "$dinfo" 'Content')" || scheme=''
    if [[ "$scheme" != 'FDisk_partition_scheme' ]]; then
        warn "Partition scheme is '$scheme', not MBR — some MIB2 units reject GPT drives."
    fi

    resolve_mount_point "$pdev" 0

    say ''
    say "Existing files on the drive will be kept; the package will be copied on top."
    require_tty 'Copy confirmation'
    local answer=''
    read -r "answer?Copy the package to ${MOUNT_POINT}? [y/N]: " || true
    [[ "${answer:l}" == 'y' || "${answer:l}" == 'yes' ]] || die 'Aborted.'
}

# --------------------------------------------------------------------------
# Spotlight, copy, cleanup
# --------------------------------------------------------------------------

# Turns off Spotlight indexing for the volume via .metadata_never_index,
# planted before any package data lands. mdutil -i off is deliberately NOT
# used: on modern macOS it *creates* .Spotlight-V100 (to store the disabled
# flag), and on FSKit exFAT mounts that directory cannot be deleted without
# root — leaving behind exactly the metadata this tool exists to remove.
disable_indexing() {
    info 'Disabling Spotlight indexing on the USB...'
    touch -- "$MOUNT_POINT/.metadata_never_index" \
        || warn 'Could not create .metadata_never_index.'
    # Suppress fseventsd journal writes at eject time as well.
    mkdir -p -- "$MOUNT_POINT/.fseventsd" 2>/dev/null || true
    touch -- "$MOUNT_POINT/.fseventsd/no_log" 2>/dev/null || true
    ok 'Spotlight indexing disabled'
}

# Copies the package to the USB root with rsync. Uses conservative flags that
# work with both classic rsync and the openrsync shipped since macOS 15.4.
# Timestamps are preserved (-t); re-running resumes, skipping complete files.
copy_package() {
    info "Copying package to ${MOUNT_POINT} ..."
    check_free_space "$MOUNT_POINT" "$PKG_BYTES" 'the USB drive'

    local -a flags=(-r -t)
    if (( VERBOSE )); then flags+=(-v); fi
    if [[ -t 1 ]] && (( ! QUIET )); then flags+=(--progress); fi
    local pat
    for pat in '.DS_Store' '._*' "${METADATA_DIRS[@]}"; do
        flags+=(--exclude "$pat")
    done

    if ! rsync "${flags[@]}" "$PKG_ROOT/" "$MOUNT_POINT/"; then
        die 'rsync failed while copying to the USB. Re-run to resume the copy.'
    fi
    ok 'Package copied'
}

# Removes every piece of macOS metadata from the USB. Order matters: the
# guard files go in first (each new file gets a com.apple.provenance xattr,
# which exFAT stores as a ._ AppleDouble companion), so the ._* sweep must be
# the very last write on the volume.
clean_metadata() {
    info 'Removing macOS metadata from the USB...'

    # Merge/remove AppleDouble files (on ExFAT they carry the xattrs).
    if command -v dot_clean > /dev/null 2>&1; then
        dot_clean -m "$MOUNT_POINT" 2>/dev/null \
            || warn 'dot_clean reported errors (continuing).'
    fi

    local d
    for d in "${METADATA_DIRS[@]}"; do
        rm -rf -- "$MOUNT_POINT/$d" 2>/dev/null || true
    done

    # Guard files: stop Spotlight and fseventsd from writing again on eject.
    touch -- "$MOUNT_POINT/.metadata_never_index" 2>/dev/null || true
    mkdir -p -- "$MOUNT_POINT/.fseventsd" 2>/dev/null || true
    touch -- "$MOUNT_POINT/.fseventsd/no_log" 2>/dev/null || true

    # Clear extended attributes everywhere. Deleting ._ files alone is not
    # enough: macOS keeps the xattrs (com.apple.provenance et al.) cached and
    # writes them back as fresh ._ files when the volume is unmounted.
    if command -v xattr > /dev/null 2>&1; then
        xattr -rc "$MOUNT_POINT" 2>/dev/null || true
        xattr -c "$MOUNT_POINT" 2>/dev/null || true
    fi

    # Final sweep, after every other write.
    find "$MOUNT_POINT" -name '.DS_Store' -type f -delete 2>/dev/null || true
    find "$MOUNT_POINT" -name '._*' -delete 2>/dev/null || true

    # Anything still present here could make the MMI reject the drive.
    local -a leftovers
    leftovers=("$MOUNT_POINT"/.DS_Store(N) "$MOUNT_POINT"/._*(N)
               "$MOUNT_POINT"/.Spotlight-V100(N) "$MOUNT_POINT"/.Trashes(N))
    if (( ${#leftovers} )); then
        warn "macOS metadata could not be fully removed: ${leftovers[*]:t}"
        warn 'Some MMI units may reject the drive; consider re-running.'
    else
        ok 'macOS metadata removed'
    fi
}

# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------

# Confirms the USB root is a valid MIB2 layout: metainfo2.txt present, no
# accidental wrapper directory, package directories in place.
verify_usb_layout() {
    info 'Verifying the USB layout...'
    sync

    [[ -f "$MOUNT_POINT/metainfo2.txt" ]] \
        || die 'metainfo2.txt is missing from the USB root — the MMI will not detect the update.'

    # A directory on the USB root that itself contains metainfo2.txt means
    # the package was copied inside a wrapper folder — the MMI would miss it.
    # Mib1/Mib2 are exempt: they legitimately carry their own copies.
    local d
    for d in "$MOUNT_POINT"/*(N/); do
        [[ "${d:t}" == (#i)mib<1-2> ]] && continue
        if [[ -f "$d/metainfo2.txt" ]]; then
            die "Wrapper directory detected on the USB: ${d:t}/ contains metainfo2.txt. The package must sit at the USB root."
        fi
    done

    local -a mib
    mib=("$MOUNT_POINT"/(#i)mib<1-2>(N/))
    (( ${#mib} )) || die 'No Mib1/Mib2 directory found on the USB root.'

    say ''
    say "${C_BOLD}USB root contents:${C_RESET}"
    ls -lA "$MOUNT_POINT" | sed 's/^/  /'
    say ''
    ok 'USB layout verified'
}

# --verify-copy: full checksum comparison of source vs USB via rsync -c -n.
verify_copy_checksums() {
    info 'Verifying the copy with checksums (this reads every byte twice)...'
    sync

    local -a flags=(-r -c -n -v)
    local pat
    for pat in '.DS_Store' '._*' "${METADATA_DIRS[@]}"; do
        flags+=(--exclude "$pat")
    done

    local out
    out="$(rsync "${flags[@]}" "$PKG_ROOT/" "$MOUNT_POINT/" 2>&1)" \
        || die 'rsync checksum comparison failed to run.'

    # rsync -v -n prints headers/summary lines around the changed-file list
    # (classic rsync and openrsync use different ones); strip them and
    # whatever remains is a real difference.
    local diffs
    diffs="$(print -r -- "$out" \
        | grep -Ev '^(sending incremental file list|building file list|Transfer starting: .*|created directory .*|sent .*|total size .*|speedup .*)?$' \
        | grep -vx './' || true)"

    if [[ -n "$diffs" ]]; then
        error 'Checksum verification found differences between source and USB:'
        print -r -- "$diffs" | sed 's/^/  /' >&2
        die 'The copy is NOT identical. Re-run the tool to repair it.'
    fi
    ok 'Checksum verification passed — USB matches the source exactly'
}

# --------------------------------------------------------------------------
# Finish
# --------------------------------------------------------------------------

# Flushes writes and ejects the drive so it is safe to remove.
eject_disk() {
    if (( NO_EJECT )); then
        info "Leaving the drive mounted at ${MOUNT_POINT} (--no-eject)."
        return 0
    fi
    info 'Ejecting the USB drive...'
    sync
    if diskutil eject "$SELECTED_DISK" > /dev/null 2>&1; then
        ok 'Ejected — safe to unplug'
    else
        warn "Could not eject ${SELECTED_DISK}; eject it manually in Finder before unplugging."
    fi
}

# Prints the dry-run plan instead of doing any destructive work.
print_dry_run_plan() {
    say ''
    say "${C_BOLD}Dry run — no changes were made. The real run would:${C_RESET}"
    local target='<selected USB disk>'
    [[ -n "$SELECTED_DISK" ]] && target="${SELECTED_DISK} (${SELECTED_MEDIA}, ${SELECTED_CAP})"
    if (( SKIP_FORMAT )); then
        say "  1. Use the existing ExFAT/FAT32 volume on ${target}"
    else
        say "  1. Erase ${target} as MBR + ExFAT, label ${USB_LABEL}"
    fi
    say '  2. Disable Spotlight indexing on the volume'
    say "  3. Copy the package ($(human_size "$PKG_BYTES")) to the USB root with rsync"
    say '  4. Remove all macOS metadata (.DS_Store, ._*, .Spotlight-V100, .Trashes, .fseventsd)'
    say '  5. Verify metainfo2.txt sits at the USB root with no wrapper directory'
    if (( VERIFY_COPY )); then
        say '  6. Compare source and USB with checksums (rsync -c)'
    fi
    say '  Final step: eject the drive'
    say ''
}

main() {
    setup_colors
    parse_args "$@"
    preflight

    log_file '============================================================'
    log_file "[RUN ] ${SCRIPT_NAME} ${VERSION} started (pid $$, args: ${*:-none})"
    local started_at; started_at="$(timestamp)"

    print_banner

    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prepare-audi-maps.XXXXXX")"
    debug "Temporary directory: $TMP_DIR"

    # 1. Package
    resolve_zip
    verify_zip
    compute_sha256
    analyze_zip_layout
    detect_region

    if (( ! DRY_RUN )); then
        extract_zip
        validate_package
    else
        say ''
        say "${C_BOLD}Package summary (from ZIP listing)${C_RESET}"
        say "  Region:  ${PKG_REGION}"
        if [[ "$PKG_WRAPPER" == '.' ]]; then
            say '  Layout:  package files at ZIP root'
        else
            say "  Layout:  wrapper directory '${PKG_WRAPPER}/' (contents will go to the USB root)"
        fi
    fi

    # 2. Target drive
    select_usb_disk

    if (( DRY_RUN )); then
        print_dry_run_plan
        log_file "[RUN ] dry run finished (started $started_at)"
        return 0
    fi

    # 3. Format (or adopt existing volume)
    if (( SKIP_FORMAT )); then
        use_existing_volume
    else
        confirm_erase
        format_disk
        verify_format
    fi

    # 4. Write
    disable_indexing
    copy_package
    clean_metadata

    # 5. Verify
    verify_usb_layout
    if (( VERIFY_COPY )); then
        verify_copy_checksums
    fi

    # 6. Done
    eject_disk

    local ended_at; ended_at="$(timestamp)"
    log_file "[RUN ] finished OK (start $started_at, end $ended_at)"
    say ''
    say "${C_GREEN}${C_BOLD}Done.${C_RESET} Insert the USB into the car and start the update from"
    say 'MMI: MENU → Setup MMI → System maintenance → System update.'
    say "Log: ${LOG_FILE}"
}

# Run only when executed directly; sourcing the file (for tests) loads the
# functions without side effects.
if [[ "${ZSH_EVAL_CONTEXT:-toplevel}" == 'toplevel' ]]; then
    main "$@"
fi
