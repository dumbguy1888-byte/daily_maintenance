#!/usr/bin/env bash
# ============================================================
# XUBUNTU HARDWARE AND CYBERSECURITY HEALTH DIAGNOSTIC
# FIXED VERSION — with opt-in auto-fix (Section 12.5)
#
# Run:
#   chmod +x run_maintenance.sh
#   ./run_maintenance.sh
#
# Double-click supported through Xfce Terminal.
# Report: ~/logging/hardware-report-YYYYMMDD-HHMMSS.txt
#
# PASS  = Check completed and no issue detected
# AMBER = Warning, incomplete check, or investigation required
# FAIL  = Serious finding requiring investigation
#
# Default run is READ-ONLY: does not change system configuration.
# Auto-fix is opt-in only: pass --fix (prompts per fix unless --yes).
# See --help for all flags.
# ============================================================

# ------------------------- ARGUMENT PARSING -------------------
# Parsed BEFORE the terminal relaunch so "$@" can be passed through.
FIX_MODE=0
DRY_RUN=0
AUTO_YES=0
FIX_FIREWALL_ONLY=0
FIX_UPDATES=0
SHOW_HELP=0

print_help() {
    cat <<'HELP_EOF'
Usage: xubuntu_hardware_cybersec_diagnose_fixed.sh [OPTIONS]

Xubuntu hardware + cybersecurity health diagnostic (read-only by default).

Options:
  --help                  Show this help and exit (0)
  --fix                   Opt-in auto-fix: after the assessment, attempt
                          fixes ONLY for problems detected in this run,
                          prompting before each fix unless --yes is given.
  --fix-dry-run           Show what --fix would do, change nothing.
                          Implies no ufw/apt/chmod calls. Safe to test.
  --yes, -y               Answer yes to every fix prompt (use with --fix).
  --fix-firewall-only     With --fix: only attempt the firewall fix.
  --fix-updates           With --fix: also allow apt update && apt upgrade
                          when package updates are pending. Without this
                          flag, updates are report-only. Warns it can
                          take minutes.

Default (no --fix): read-only diagnostic, no changes are made.
Auto-fix never touches: SMART failures, temperature, disk-full,
ACPI errors, SUID files, persistence entries, listening services
(other than via the firewall), or anything destructive.
A fix attempt is not a verified PASS until you re-run the script.

Examples:
  ./xubuntu_hardware_cybersec_diagnose_fixed.sh
  ./xubuntu_hardware_cybersec_diagnose_fixed.sh --fix-dry-run
  sudo ./xubuntu_hardware_cybersec_diagnose_fixed.sh --fix
  sudo ./xubuntu_hardware_cybersec_diagnose_fixed.sh --fix --fix-firewall-only --yes
  sudo ./xubuntu_hardware_cybersec_diagnose_fixed.sh --fix --fix-updates
HELP_EOF
}

for arg in "$@"; do
    case "$arg" in
        --help|-h) SHOW_HELP=1 ;;
        --fix) FIX_MODE=1 ;;
        --fix-dry-run) DRY_RUN=1; FIX_MODE=1 ;;
        --yes|-y) AUTO_YES=1 ;;
        --fix-firewall-only) FIX_FIREWALL_ONLY=1; FIX_MODE=1 ;;
        --fix-updates) FIX_UPDATES=1 ;;
        *) echo "Unknown option: $arg" >&2; echo "Run with --help for usage." >&2; exit 2 ;;
    esac
done

if [[ "$SHOW_HELP" -eq 1 ]]; then
    print_help
    exit 0
fi

# ------------------------- CONFIGURATION ---------------------

CPU_LOAD_AMBER=1.5
CPU_LOAD_FAIL=2.0
MEMORY_AMBER=20
MEMORY_FAIL=10
SWAP_AMBER=50
SWAP_FAIL=80
DISK_AMBER=90
DISK_FAIL=95
TEMP_AMBER=85
TEMP_FAIL=95

# ------------------------- TERMINAL ---------------------------
# Pass "$@" through the relaunch so double-click with args still works.

if [[ -z "${HW_DIAG_IN_TERMINAL:-}" && ! -t 1 ]]; then
    if command -v xfce4-terminal >/dev/null 2>&1; then
        SCRIPT="$(readlink -f "$0")"
        CMD_ARGS=""
        for a in "$@"; do
            CMD_ARGS="$CMD_ARGS $(printf '%q' "$a")"
        done
        HW_DIAG_IN_TERMINAL=1 xfce4-terminal \
            --title="Xubuntu Hardware Diagnostic" \
            --hold \
            --command="bash \"$SCRIPT\"$CMD_ARGS"
        exit 0
    fi
fi

# ------------------------- FIX ENGINE -------------------------
# log_fix / confirm_fix / try_fix.
# Never runs sudo silently: commands that need root are run via sudo,
# which prompts the user itself, or the user runs the whole script
# with sudo. Fix attempts never crash the script.

FIX_ATTEMPTED=0
FIX_SUCCEEDED=0
FIX_FAILED=0
FIX_SKIPPED=0
declare -a FIX_LOG=()

log_fix() {
    echo "[FIX] $1"
    FIX_LOG+=("$1")
}

confirm_fix() {
    # $1 = human-readable description. Returns 0 = proceed, 1 = skip.
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 1
    fi
    if [[ "$AUTO_YES" -eq 1 ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        echo "[FIX] Skipped (no terminal to confirm): $1"
        return 1
    fi
    local ans=""
    read -rp "Apply fix: $1? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

try_fix() {
    # try_fix "Name" "Description" "command to run"
    local name="$1" desc="$2" cmd="$3"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] Would run: $cmd   ($desc)"
        FIX_LOG+=("DRY-RUN (skipped, no change): $name — $cmd")
        FIX_SKIPPED=$((FIX_SKIPPED + 1))
        return 0
    fi
    if ! confirm_fix "$desc"; then
        log_fix "Skipped by user / no confirmation: $name"
        FIX_SKIPPED=$((FIX_SKIPPED + 1))
        return 0
    fi
    FIX_ATTEMPTED=$((FIX_ATTEMPTED + 1))
    log_fix "Attempting: $name — $cmd"
    local rc=0
    # Intentionally run the (internally fixed, not user-supplied) command.
    # Failures are recorded, never fatal.
    # No `set -e` anywhere in this script: a failing fix must be
    # recorded, never fatal. Do not re-enable errexit here.
    bash -c "$cmd"
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        log_fix "Succeeded: $name"
        FIX_SUCCEEDED=$((FIX_SUCCEEDED + 1))
    else
        log_fix "FAILED (exit $rc): $name — command was: $cmd"
        FIX_FAILED=$((FIX_FAILED + 1))
    fi
    return 0
}

has_finding() {
    # has_finding "substring" — true if a RESULT_NAME contains it and
    # its status is AMBER or FAIL (i.e. a problem actually detected).
    local needle="$1"
    local i
    for i in "${!RESULT_NAME[@]}"; do
        if [[ "${RESULT_NAME[$i]}" == *"$needle"* && \
              ( "${RESULT_STATUS[$i]}" == "AMBER" || "${RESULT_STATUS[$i]}" == "FAIL" ) ]]; then
            return 0
        fi
    done
    return 1
}

# ------------------------- INITIALIZATION ---------------------

mkdir -p "$HOME/logging" || {
    echo "Cannot create $HOME/logging"
    exit 1
}

OUT="$HOME/logging/hardware-report-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

PASS_COUNT=0
AMBER_COUNT=0
FAIL_COUNT=0
declare -a RESULT_STATUS=()
declare -a RESULT_NAME=()
declare -a RESULT_DETAIL=()
declare -a RESULT_ACTION=()

HARDWARE_NAME="$(hostname)"

have() { command -v "$1" >/dev/null 2>&1; }

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

result() {
    local status="$1" name="$2" detail="$3" action="${4:-}"

    case "$status" in
        PASS)  PASS_COUNT=$((PASS_COUNT + 1)); echo "[PASS]  $name" ;;
        AMBER) AMBER_COUNT=$((AMBER_COUNT + 1)); echo "[AMBER] $name" ;;
        FAIL)  FAIL_COUNT=$((FAIL_COUNT + 1)); echo "[FAIL]  $name" ;;
        *) echo "[ERROR] Invalid result status: $status"; return 1 ;;
    esac

    echo "        $detail"
    if [[ -n "$action" && "$status" != "PASS" ]]; then
        echo "        ACTION: $action"
    fi

    RESULT_STATUS+=("$status")
    RESULT_NAME+=("$name")
    RESULT_DETAIL+=("$detail")
    RESULT_ACTION+=("$action")
}

# ============================================================
# HEADER AND MACHINE IDENTIFICATION
# ============================================================

section "XUBUNTU HARDWARE AND CYBERSECURITY HEALTH DIAGNOSTIC"

echo "Date:         $(date)"
echo "Hostname:     $HARDWARE_NAME"
echo "OS:           $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Unknown}")"
echo "Kernel:       $(uname -r)"
echo "Architecture: $(uname -m)"
echo "Report:       $OUT"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Mode:         --fix-dry-run (no changes will be made)"
elif [[ "$FIX_MODE" -eq 1 ]]; then
    echo "Mode:         --fix (opt-in auto-fix enabled; prompts unless --yes)"
else
    echo "Mode:         read-only (default, no changes)"
fi

echo
echo "DIAGNOSTIC THRESHOLDS"
echo "CPU load:       AMBER > 1.5x logical CPUs; FAIL > 2.0x"
echo "Available RAM:  AMBER < 20%; FAIL < 10%"
echo "Swap used:      AMBER > 50%; FAIL > 80%"
echo "Filesystem:     AMBER >= 90%; FAIL >= 95%"
echo "Temperature:    AMBER >= 85C; FAIL >= 95C"
echo "Note: thresholds are screening rules, not component-specific limits."

section "1. SYSTEM AND FIRMWARE"

uptime
echo
echo "--- DMI system information ---"

if have dmidecode; then
    # FIXED (audit bug): the original ran the same dmidecode command in
    # both the root and non-root branches. One call now; non-root is
    # reported as AMBER with "run with sudo" instead of pretending it worked.
    DMI_OUTPUT="$(dmidecode -t system -t bios -t baseboard 2>&1)"
    DMI_RC=$?
    echo "$DMI_OUTPUT"
    if [[ "$DMI_RC" -eq 0 && -n "$DMI_OUTPUT" ]]; then
        result PASS "DMI information" "System and firmware identification data collected."
    elif [[ "$EUID" -ne 0 ]]; then
        result AMBER "DMI information" "dmidecode could not read all firmware information (not run as root)." \
            "Run with sudo if you need the complete SMBIOS information."
    else
        result AMBER "DMI information" "dmidecode could not read all firmware information." \
            "Run with sudo if you need the complete SMBIOS information."
    fi
else
    result AMBER "DMI information" "dmidecode is not installed." \
        "Install using: sudo apt install dmidecode"
fi

if have inxi; then
    echo
    echo "--- inxi hardware summary ---"
    inxi -Fxxxz
    result PASS "System summary" "inxi hardware and operating-system summary collected."
else
    result AMBER "System summary" "inxi is not installed." \
        "Install using: sudo apt install inxi"
fi

# ============================================================
# 2. CPU
# ============================================================

section "2. CPU PERFORMANCE"

CPU_CORES="$(nproc 2>/dev/null || echo 1)"
LOAD_1="$(awk '{print $1}' /proc/loadavg)"
CPU_LOAD_LIMIT="$(awk -v c="$CPU_CORES" -v t="$CPU_LOAD_AMBER" 'BEGIN {printf "%.2f",c*t}')"
CPU_LOAD_FAIL_LIMIT="$(awk -v c="$CPU_CORES" -v t="$CPU_LOAD_FAIL" 'BEGIN {printf "%.2f",c*t}')"

echo "Logical CPUs: $CPU_CORES"
echo "Load average: $(cat /proc/loadavg)"
echo
lscpu | head -25
echo
ps aux --sort=-%cpu | head -11

if awk -v l="$LOAD_1" -v t="$CPU_LOAD_FAIL_LIMIT" 'BEGIN {exit !(l > t)}'; then
    result FAIL "CPU load" "1-minute load $LOAD_1 exceeds $CPU_LOAD_FAIL_LIMIT." \
        "Inspect CPU-heavy and I/O-waiting processes using top or htop."
elif awk -v l="$LOAD_1" -v t="$CPU_LOAD_LIMIT" 'BEGIN {exit !(l > t)}'; then
    result AMBER "CPU load" "1-minute load $LOAD_1 exceeds $CPU_LOAD_LIMIT." \
        "Review running processes and system workload."
else
    result PASS "CPU load" "1-minute load $LOAD_1 is within the configured threshold."
fi

if have mpstat; then
    echo
    mpstat -P ALL 1 1
else
    result AMBER "Per-core CPU detail" "mpstat is unavailable." \
        "Install using: sudo apt install sysstat"
fi

# ============================================================
# 3. MEMORY AND SWAP
# ============================================================

section "3. MEMORY"

free -h
echo
ps aux --sort=-%mem | head -11

MEM_TOTAL="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
MEM_AVAILABLE="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
MEM_AVAILABLE_PERCENT="$(awk -v a="$MEM_AVAILABLE" -v t="$MEM_TOTAL" \
    'BEGIN {if (t>0) printf "%.1f",a/t*100; else print "0"}')"

echo
echo "Available memory: ${MEM_AVAILABLE_PERCENT}%"

if awk -v v="$MEM_AVAILABLE_PERCENT" -v t="$MEMORY_FAIL" 'BEGIN {exit !(v < t)}'; then
    result FAIL "Available RAM" "Only ${MEM_AVAILABLE_PERCENT}% memory is available." \
        "Identify memory-heavy processes and reduce memory pressure."
elif awk -v v="$MEM_AVAILABLE_PERCENT" -v t="$MEMORY_AMBER" 'BEGIN {exit !(v < t)}'; then
    result AMBER "Available RAM" "Available memory is ${MEM_AVAILABLE_PERCENT}%." \
        "Review memory usage and unnecessary concurrent workloads."
else
    result PASS "Available RAM" "${MEM_AVAILABLE_PERCENT}% memory is available."
fi

SWAP_TOTAL="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
SWAP_FREE="$(awk '/SwapFree/ {print $2}' /proc/meminfo)"

if [[ "$SWAP_TOTAL" -gt 0 ]]; then
    SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))
    SWAP_PERCENT="$(awk -v u="$SWAP_USED" -v t="$SWAP_TOTAL" 'BEGIN {printf "%.1f",u/t*100}')"
    swapon --show

    if awk -v v="$SWAP_PERCENT" -v t="$SWAP_FAIL" 'BEGIN {exit !(v > t)}'; then
        result FAIL "Swap usage" "${SWAP_PERCENT}% of configured swap is used." \
            "Investigate memory pressure and processes using swap."
    elif awk -v v="$SWAP_PERCENT" -v t="$SWAP_AMBER" 'BEGIN {exit !(v > t)}'; then
        result AMBER "Swap usage" "${SWAP_PERCENT}% of configured swap is used." \
            "Check whether sustained swapping is affecting performance."
    else
        result PASS "Swap usage" "${SWAP_PERCENT}% of configured swap is used."
    fi
else
    result AMBER "Swap configuration" "No swap space is configured." \
        "Review whether swap is appropriate for this workload."
fi

if have vmstat; then
    echo
    vmstat 1 2
fi

# ============================================================
# 4. STORAGE
# ============================================================

section "4. DISK AND FILESYSTEM HEALTH"

df -hT
echo
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
echo
df -i
echo
echo "--- Filesystem capacity checks (virtual filesystems excluded) ---"

while read -r filesystem mountpoint usage; do
    [[ "$usage" =~ ^[0-9]+$ ]] || continue

    if [[ "$usage" -ge "$DISK_FAIL" ]]; then
        result FAIL "Disk space: $mountpoint" "${usage}% filesystem usage." \
            "Inspect large files and free space; back up important data before deleting anything."
    elif [[ "$usage" -ge "$DISK_AMBER" ]]; then
        result AMBER "Disk space: $mountpoint" "${usage}% filesystem usage." \
            "Investigate large directories and remove only unnecessary files."
    else
        result PASS "Disk space: $mountpoint" "${usage}% filesystem usage."
    fi
done < <(
    df -P -x tmpfs -x devtmpfs -x efivarfs -x proc -x sysfs \
        -x overlay -x squashfs -x devpts -x cgroup -x cgroup2 |
    awk 'NR>1 {print $1, $6, $5}' | sed 's/%//'
)

echo
echo "--- Largest directories on root filesystem ---"
du -xhd1 / 2>/dev/null | sort -rh | head -10

if have smartctl; then
    echo
    echo "--- SMART health ---"
    SMART_CHECKED=0
    SMART_FAILED=0
    SMART_SKIPPED=0

    while read -r device type; do
        [[ "$type" == "disk" ]] || continue
        SMART_CHECKED=$((SMART_CHECKED + 1))

        if [[ "$EUID" -eq 0 ]]; then
            SMART_OUTPUT="$(smartctl -H "$device" 2>&1)"
            SMART_RC=$?
        elif sudo -n true 2>/dev/null; then
            SMART_OUTPUT="$(sudo -n smartctl -H "$device" 2>&1)"
            SMART_RC=$?
        else
            echo "SMART permission unavailable: $device"
            SMART_SKIPPED=$((SMART_SKIPPED + 1))
            continue
        fi

        echo
        echo "Device: $device"
        echo "$SMART_OUTPUT"

        if echo "$SMART_OUTPUT" | grep -qiE \
            'SMART overall-health self-assessment test result: FAILED|SMART Health Status:.*(FAILED|BAD)'; then
            SMART_FAILED=$((SMART_FAILED + 1))
        elif [[ "$SMART_RC" -ne 0 ]] || ! echo "$SMART_OUTPUT" | grep -qiE 'PASSED|OK'; then
            SMART_SKIPPED=$((SMART_SKIPPED + 1))
        fi
    done < <(lsblk -dnpo NAME,TYPE)

    if [[ "$SMART_FAILED" -gt 0 ]]; then
        result FAIL "SMART disk health" "$SMART_FAILED disk(s) reported a SMART health failure." \
            "Back up important data immediately and investigate disk replacement."
    elif [[ "$SMART_CHECKED" -eq 0 ]]; then
        result AMBER "SMART disk health" "No physical disk was checked." \
            "Check device visibility and whether the storage device supports SMART."
    elif [[ "$SMART_SKIPPED" -gt 0 ]]; then
        result AMBER "SMART disk health" "$SMART_SKIPPED disk check(s) were inconclusive." \
            "Run with appropriate permissions and inspect the SMART output above."
    else
        result PASS "SMART disk health" "All checked disks reported healthy SMART status."
    fi
else
    result AMBER "SMART disk health" "smartctl is not installed." \
        "Install using: sudo apt install smartmontools"
fi

# ============================================================
# 5. GPU
# ============================================================

section "5. GPU"

if have lspci; then
    GPU_INFO="$(lspci | grep -iE 'vga|3d|display' || true)"
    if [[ -n "$GPU_INFO" ]]; then
        echo "$GPU_INFO"
        result PASS "GPU detection" "Graphics controller detected."
    else
        result AMBER "GPU detection" "No graphics controller was identified by lspci." \
            "Check PCI device visibility and graphics hardware."
    fi
else
    result AMBER "GPU detection" "lspci is unavailable." \
        "Install using: sudo apt install pciutils"
fi

if have nvidia-smi; then
    echo
    nvidia-smi
    if nvidia-smi >/dev/null 2>&1; then
        result PASS "NVIDIA driver" "NVIDIA driver utility responded successfully."
    else
        result FAIL "NVIDIA driver" "nvidia-smi failed." \
            "Investigate NVIDIA driver installation and kernel compatibility."
    fi
elif have glxinfo; then
    RENDER_INFO="$(glxinfo 2>/dev/null | grep -i 'OpenGL renderer' || true)"
    echo "$RENDER_INFO"
    if [[ -n "$RENDER_INFO" ]]; then
        result PASS "Graphics rendering" "OpenGL renderer information is available."
    else
        result AMBER "Graphics rendering" "OpenGL renderer information is unavailable." \
            "Check graphics drivers and the active display session."
    fi
else
    result AMBER "Graphics rendering" "Neither nvidia-smi nor glxinfo is available." \
        "Install mesa-utils if OpenGL renderer information is required."
fi

# ============================================================
# 6. TEMPERATURE
# ============================================================

section "6. TEMPERATURE"

if have sensors; then
    SENSOR_OUTPUT="$(sensors 2>&1)"
    echo "$SENSOR_OUTPUT"

    MAX_TEMP="$(echo "$SENSOR_OUTPUT" | awk '
        /^[[:space:]]*[^:]+:/ && !/(high|crit|alarm|hyst|emergency)/ {
            if (match($0, /[+-]?[0-9]+([.][0-9]+)?°C/)) {
                value = substr($0, RSTART, RLENGTH)
                gsub(/[+°C]/, "", value)
                if (count == 0 || value > maximum) maximum = value
                count++
            }
        }
        END {if (count > 0) printf "%.1f", maximum}
    ')"

    if [[ -n "$MAX_TEMP" ]]; then
        if awk -v v="$MAX_TEMP" -v t="$TEMP_FAIL" 'BEGIN {exit !(v >= t)}'; then
            result FAIL "Temperature" "Highest reported current sensor temperature: ${MAX_TEMP}C." \
                "Check cooling, fan operation, airflow and thermal throttling."
        elif awk -v v="$MAX_TEMP" -v t="$TEMP_AMBER" 'BEGIN {exit !(v >= t)}'; then
            result AMBER "Temperature" "Highest reported current sensor temperature: ${MAX_TEMP}C." \
                "Inspect cooling and monitor temperatures under load."
        else
            result PASS "Temperature" "Highest reported current sensor temperature: ${MAX_TEMP}C."
        fi
    else
        result AMBER "Temperature" "No readable current temperature measurement was found." \
            "Check sensor support and lm-sensors configuration."
    fi
else
    result AMBER "Temperature" "lm-sensors is not installed." \
        "Install using: sudo apt install lm-sensors"
fi

# ============================================================
# 7. POWER AND BATTERY
# ============================================================

section "7. POWER AND BATTERY"

if have upower; then
    UPOWER_OUTPUT="$(upower -d 2>&1)"
    echo "$UPOWER_OUTPUT"

    # FIXED (audit bug): the original assigned BATTERY_PRESENT and
    # AC_ONLINE but never used them. They are removed; the checks below
    # use the upower output directly.
    if echo "$UPOWER_OUTPUT" | grep -q 'line-power'; then
        if echo "$UPOWER_OUTPUT" | grep -A12 'line-power' | grep -q 'online:[[:space:]]*yes'; then
            result PASS "AC adapter detection" "UPower reports the AC adapter online."
        else
            result AMBER "AC adapter detection" "UPower did not report the AC adapter online." \
                "Check the power connection and refresh status with upower -d."
        fi
    else
        result AMBER "AC adapter detection" "UPower did not expose a line-power device." \
            "Check whether the machine exposes AC adapter status through the kernel."
    fi

    if echo "$UPOWER_OUTPUT" | grep -q 'battery'; then
        if echo "$UPOWER_OUTPUT" | grep -A20 'battery' | grep -q 'present:[[:space:]]*yes'; then
            result PASS "Battery detection" "UPower reports a battery present."
        else
            result AMBER "Battery detection" "Battery presence could not be confirmed." \
                "Check battery reporting and power-management support."
        fi
    else
        result AMBER "Battery detection" "UPower did not expose a battery device." \
            "This may be normal on a desktop; verify the machine type."
    fi
else
    result AMBER "Power monitoring" "UPower is unavailable." \
        "Install using: sudo apt install upower"
fi

# ============================================================
# 8. USB
# ============================================================

section "8. USB CONTROLLERS AND DEVICES"

if have lsusb; then
    echo "--- USB devices ---"
    lsusb
    echo
    echo "--- USB topology and drivers ---"
    USB_TREE="$(lsusb -t 2>&1)"
    echo "$USB_TREE"

    ROOT_HUBS="$(echo "$USB_TREE" | grep -c 'Class=root_hub' || true)"
    USB_DEVICE_LINES="$(lsusb | grep -v '^$' | grep -Evc 'Linux Foundation.*root hub' || true)"

    if [[ "$ROOT_HUBS" -gt 0 ]]; then
        result PASS "USB host controllers" "$ROOT_HUBS USB root hub(s) detected."
    else
        result AMBER "USB host controllers" "No USB root hub was identified in lsusb -t." \
            "Inspect xHCI/EHCI controller detection and kernel logs."
    fi

    if [[ "$USB_DEVICE_LINES" -gt 0 ]]; then
        result PASS "USB device enumeration" "$USB_DEVICE_LINES non-root USB device(s) listed."
    else
        result AMBER "USB device enumeration" "No external USB devices are currently listed." \
            "Connect a known working USB device if you want to test port operation."
    fi
else
    result AMBER "USB diagnostics" "lsusb is unavailable." \
        "Install using: sudo apt install usbutils"
fi

# ============================================================
# 9. NETWORK
# ============================================================

section "9. NETWORK"

echo "--- Interfaces ---"
ip -br a
echo
echo "--- Routes ---"
ip route
echo
echo "--- Listening ports ---"
if have ss; then ss -tulpn 2>/dev/null | head -25; fi

ACTIVE_INTERFACES="$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | wc -l)"
if [[ "$ACTIVE_INTERFACES" -gt 0 ]]; then
    result PASS "Network interfaces" "$ACTIVE_INTERFACES non-loopback interface(s) detected."
else
    result FAIL "Network interfaces" "No non-loopback network interfaces detected." \
        "Check network adapter, cable, Wi-Fi and drivers."
fi

if have ping; then
    if ping -c 4 -W 3 8.8.8.8 >/dev/null 2>&1; then
        result PASS "Internet connectivity" "External IP connectivity test succeeded."
    else
        result AMBER "Internet connectivity" "Unable to reach 8.8.8.8." \
            "Check gateway, router, firewall and internet connection; ICMP may be blocked."
    fi
else
    result AMBER "Internet connectivity" "ping is unavailable." \
        "Install using: sudo apt install iputils-ping"
fi

# ============================================================
# 10. KERNEL, ACPI AND HARDWARE ERRORS
# ============================================================

section "10. KERNEL, ACPI AND HARDWARE ERRORS"

echo "--- Recent kernel messages ---"
dmesg 2>/dev/null | tail -50 || true

echo
echo "--- Kernel error-level messages this boot ---"

if have journalctl; then
    KERNEL_ERRORS="$(journalctl -k -p err -b --no-pager 2>/dev/null || true)"
else
    KERNEL_ERRORS="$(dmesg 2>/dev/null | grep -iE 'error|failed|critical|hardware error' || true)"
fi

if [[ -n "$KERNEL_ERRORS" ]]; then
    echo "$KERNEL_ERRORS"
else
    echo "No kernel error-level messages found."
fi

ACPI_COUNT="$(printf '%s\n' "$KERNEL_ERRORS" | grep -ciE 'ACPI BIOS Error|ACPI Error|AE_NOT_FOUND' || true)"
AC_ADAPTER_PROBE_COUNT="$(printf '%s\n' "$KERNEL_ERRORS" | grep -ciE 'ACPI0003.*probe.*failed|probe with driver ac failed' || true)"

SEVERE_LINES="$(printf '%s\n' "$KERNEL_ERRORS" | grep -iE \
    'hardware error|machine check|mce:|I/O error|Buffer I/O error|nvme.*(I/O|error|fail)|ata[0-9.]*:.*error|thermal.*critical|uncorrected.*error' || true)"
SEVERE_COUNT="$(printf '%s\n' "$SEVERE_LINES" | grep -c . || true)"

if [[ "$SEVERE_COUNT" -gt 0 ]]; then
    echo
    echo "--- Serious hardware-related matches ---"
    echo "$SEVERE_LINES"
    result FAIL "Kernel hardware errors" "$SEVERE_COUNT serious hardware/storage/thermal log match(es) found." \
        "Investigate the exact messages above. Back up important data if storage I/O errors are present."
else
    result PASS "Serious kernel hardware errors" "No configured high-risk hardware-error signatures found in kernel error-level messages."
fi

if [[ "$ACPI_COUNT" -gt 0 ]]; then
    result AMBER "ACPI firmware warnings" "$ACPI_COUNT ACPI-related error message(s) found; these indicate firmware/ACPI table or method problems, not proof of failed hardware." \
        "Check BIOS updates for the exact machine model. If USB, battery and AC operation work, monitor rather than disabling ACPI."
else
    result PASS "ACPI firmware warnings" "No ACPI-related errors found in kernel error-level messages."
fi

if [[ "$AC_ADAPTER_PROBE_COUNT" -gt 0 ]]; then
    if have upower && upower -d 2>/dev/null | grep -A12 'line-power' | grep -q 'online:[[:space:]]*yes'; then
        result AMBER "AC adapter driver probe" "ACPI AC adapter driver probe error was logged, but UPower currently reports line power online." \
            "Treat as a driver/firmware warning. Monitor power reporting; investigate further only if adapter or battery status becomes incorrect."
    else
        result AMBER "AC adapter driver probe" "ACPI AC adapter driver probe error was logged and working AC status is not confirmed." \
            "Check power reporting, adapter connection and BIOS/firmware support."
    fi
fi

OTHER_ERROR_LINES="$(printf '%s\n' "$KERNEL_ERRORS" | grep -iE 'error|failed|critical' |
    grep -viE 'ACPI BIOS Error|ACPI Error|AE_NOT_FOUND|ACPI0003.*probe.*failed|probe with driver ac failed|hardware error|machine check|mce:|I/O error|Buffer I/O error|nvme.*(I/O|error|fail)|ata[0-9.]*:.*error|thermal.*critical|uncorrected.*error' || true)"

if [[ -n "$OTHER_ERROR_LINES" ]]; then
    echo
    echo "--- Other kernel error-level messages requiring review ---"
    echo "$OTHER_ERROR_LINES"
    result AMBER "Other kernel errors" "Other kernel error-level messages were found and are listed above." \
        "Review each message and determine whether the affected device or driver is functioning correctly."
fi

# ============================================================
# 11. CYBERSECURITY HEALTH AND INTRUSION ANALYSIS
# Read-only checks. No firewall, account, service, or file changes.
# ============================================================

section "11. CYBERSECURITY HEALTH AND INTRUSION ANALYSIS"

echo "Scope: read-only local checks; findings are indicators, not proof of compromise."
echo "No automatic blocking, deletion, process termination, or configuration changes."

# 11.1 Firewall posture
section "11.1 FIREWALL POSTURE"
FIREWALL_ACTIVE=0
if have ufw; then
    UFW_STATUS="$(ufw status verbose 2>&1)"
    echo "$UFW_STATUS"
    if echo "$UFW_STATUS" | grep -q '^Status: active'; then
        FIREWALL_ACTIVE=1
    fi
else
    echo "UFW is not installed."
fi

if have nft; then
    echo
    echo "--- nftables ruleset (first 160 lines) ---"
    NFT_OUTPUT="$(nft list ruleset 2>&1 || true)"
    printf '%s\n' "$NFT_OUTPUT" | head -160
    if printf '%s\n' "$NFT_OUTPUT" | grep -qE '(^|[[:space:]])(chain|table)[[:space:]]'; then
        FIREWALL_ACTIVE=1
    fi
fi

if have iptables; then
    echo
    echo "--- iptables filter policies ---"
    IPT_OUTPUT="$(iptables -S 2>&1 || true)"
    printf '%s\n' "$IPT_OUTPUT" | head -100
    if printf '%s\n' "$IPT_OUTPUT" | grep -qE '^-A (INPUT|FORWARD|OUTPUT)'; then
        FIREWALL_ACTIVE=1
    fi
fi

if [[ "$FIREWALL_ACTIVE" -eq 1 ]]; then
    result PASS "Firewall rules present" "UFW is active or nftables/iptables rules were detected. This does not prove the rules are correctly restrictive."
else
    result AMBER "Firewall posture" "No active UFW firewall or recognizable nftables/iptables rules were detected." \
        "Review whether a host firewall is appropriate. If desired, configure UFW deliberately after checking required services and network access."
fi

# 11.2 Listening services and externally-bound sockets
section "11.2 LISTENING SERVICES AND NETWORK EXPOSURE"
if have ss; then
    LISTEN_OUTPUT="$(ss -H -lntup 2>&1 || true)"
    if [[ -n "$LISTEN_OUTPUT" ]]; then
        printf '%s\n' "$LISTEN_OUTPUT"
    else
        echo "No TCP/UDP listening sockets reported."
    fi
    EXTERNAL_LISTENERS="$(printf '%s\n' "$LISTEN_OUTPUT" | awk '$0 ~ /0\.0\.0\.0:|\[::\]:|\*:([0-9]+)|:::([0-9]+)/ {print}')"
    EXTERNAL_LISTENER_COUNT="$(printf '%s\n' "$EXTERNAL_LISTENERS" | grep -c . || true)"
    if [[ "$EXTERNAL_LISTENER_COUNT" -gt 0 ]]; then
        echo
        echo "--- Listeners bound to all interfaces (review each service) ---"
        printf '%s\n' "$EXTERNAL_LISTENERS"
        result AMBER "Externally-bound listening services" "$EXTERNAL_LISTENER_COUNT listener(s) appear bound to all IPv4/IPv6 interfaces; this is exposure evidence, not proof of unauthorised access." \
            "Identify each process and confirm the service is required, patched, authenticated and restricted by firewall rules where appropriate."
    else
        result PASS "Externally-bound listening services" "No listeners clearly bound to all interfaces were identified by the socket check."
    fi
else
    result AMBER "Listening-service inspection" "The ss utility is unavailable." \
        "Install using: sudo apt install iproute2"
fi

# 11.3 SSH configuration and service
section "11.3 SSH SECURITY"
if have sshd; then
    SSH_CONFIG="$(sshd -T 2>&1 || true)"
    if printf '%s\n' "$SSH_CONFIG" | grep -q '^permitrootlogin '; then
        ROOT_LOGIN="$(printf '%s\n' "$SSH_CONFIG" | awk '$1=="permitrootlogin" {print $2; exit}')"
        PASS_AUTH="$(printf '%s\n' "$SSH_CONFIG" | awk '$1=="passwordauthentication" {print $2; exit}')"
        PUBKEY_AUTH="$(printf '%s\n' "$SSH_CONFIG" | awk '$1=="pubkeyauthentication" {print $2; exit}')"
        echo "Effective sshd settings:"
        echo "  PermitRootLogin: $ROOT_LOGIN"
        echo "  PasswordAuthentication: $PASS_AUTH"
        echo "  PubkeyAuthentication: $PUBKEY_AUTH"
        if [[ "$ROOT_LOGIN" == "yes" || "$PASS_AUTH" == "yes" ]]; then
            result AMBER "SSH authentication hardening" "sshd effective configuration allows root login and/or password authentication (root=$ROOT_LOGIN, password=$PASS_AUTH)." \
                "If SSH is needed, consider disabling direct root login and using key-based authentication after confirming you have a working alternative access path."
        else
            result PASS "SSH authentication hardening" "sshd does not report direct root login or password authentication enabled. Verify the effective settings and intended access policy."
        fi
    else
        echo "$SSH_CONFIG"
        result AMBER "SSH configuration inspection" "sshd is present but effective configuration could not be read." \
            "Run sudo sshd -T manually and review the SSH configuration."
    fi
else
    echo "OpenSSH server binary not found."
    result PASS "SSH server exposure" "No sshd server binary was found; SSH server-specific checks are not applicable."
fi

if have systemctl; then
    SSH_SERVICE_STATE="$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || true)"
    echo "SSH service state: ${SSH_SERVICE_STATE:-not active/not found}"
    if [[ "$SSH_SERVICE_STATE" == "active" ]]; then
        echo "SSH service is active. Confirm that remote access is intentional."
    fi
fi

# 11.4 Privileged accounts and sudo access
section "11.4 PRIVILEGED ACCOUNTS AND SUDO ACCESS"
echo "--- Accounts with UID 0 ---"
UID0_ACCOUNTS="$(awk -F: '$3==0 {print $1 ": UID=" $3 ", GID=" $4 ", home=" $6 ", shell=" $7}' /etc/passwd)"
printf '%s\n' "$UID0_ACCOUNTS"
UID0_COUNT="$(printf '%s\n' "$UID0_ACCOUNTS" | grep -c . || true)"
if [[ "$UID0_COUNT" -gt 1 ]]; then
    result FAIL "Additional UID 0 accounts" "$UID0_COUNT accounts have UID 0; accounts other than root have full root-equivalent identity." \
        "Verify every UID 0 account immediately. If any is unauthorised, preserve evidence and investigate before disabling or deleting it."
else
    result PASS "UID 0 account check" "Only the standard root UID 0 account was detected. This does not validate other account permissions."
fi

echo
echo "--- Sudo and admin groups ---"
getent group sudo 2>/dev/null || true
getent group adm 2>/dev/null || true
getent group wheel 2>/dev/null || true

echo
echo "--- Sudoers files (names and permissions) ---"
ls -ld /etc/sudoers /etc/sudoers.d 2>&1 || true
find /etc/sudoers.d -maxdepth 1 -type f -printf '%M %u:%g %p\n' 2>/dev/null | head -80

# 11.5 Authentication events, failed and successful logins
section "11.5 AUTHENTICATION AND LOGIN ACTIVITY"
AUTH_LOG_AVAILABLE=0
AUTH_EVENTS=""
if have journalctl; then
    if journalctl -n 1 --no-pager >/dev/null 2>&1; then AUTH_LOG_AVAILABLE=1; fi
    AUTH_EVENTS="$(journalctl --since '24 hours ago' --no-pager 2>/dev/null | grep -iE 'Failed password|authentication failure|Invalid user|Accepted (password|publickey)|session opened for user|sudo:.*COMMAND=' || true)"
fi
if [[ -r /var/log/auth.log ]]; then
    AUTH_LOG_AVAILABLE=1
    echo "--- Recent /var/log/auth.log authentication events ---"
    grep -iE 'Failed password|authentication failure|Invalid user|Accepted (password|publickey)|sudo:.*COMMAND=' /var/log/auth.log 2>/dev/null | tail -100 || true
fi
if [[ -n "$AUTH_EVENTS" ]]; then
    echo "--- Journal authentication events (last 24 hours; latest 120) ---"
    printf '%s\n' "$AUTH_EVENTS" | tail -120
    echo
    echo "--- Source IPs associated with failed authentication (where logged) ---"
    printf '%s\n' "$AUTH_EVENTS" | grep -iE 'Failed password|Invalid user|authentication failure' | \
        grep -oE 'from ([0-9]{1,3}\.){3}[0-9]{1,3}|from [0-9a-fA-F:]{3,}' | \
        sed 's/^from //' | sort | uniq -c | sort -nr | head -20 || true
    echo "--- Source IPs associated with successful SSH authentication (where logged) ---"
    printf '%s\n' "$AUTH_EVENTS" | grep -iE 'Accepted (password|publickey)' | \
        grep -oE 'from ([0-9]{1,3}\.){3}[0-9]{1,3}|from [0-9a-fA-F:]{3,}' | \
        sed 's/^from //' | sort | uniq -c | sort -nr | head -20 || true
fi

FAILED_AUTH_COUNT="$(printf '%s\n' "$AUTH_EVENTS" | grep -ciE 'Failed password|authentication failure|Invalid user' || true)"
SUCCESS_SSH_COUNT="$(printf '%s\n' "$AUTH_EVENTS" | grep -ciE 'Accepted (password|publickey)' || true)"
echo "Failed/invalid authentication events in journal query: $FAILED_AUTH_COUNT"
echo "Successful SSH authentication events in journal query: $SUCCESS_SSH_COUNT"
if [[ "$FAILED_AUTH_COUNT" -ge 100 ]]; then
    result FAIL "Repeated authentication failures" "$FAILED_AUTH_COUNT failed/invalid authentication events were found in the last 24 hours of readable journal data." \
        "Review source IPs, usernames and timestamps. Confirm whether attempts were expected; consider rate limiting or restricting exposed remote services."
elif [[ "$FAILED_AUTH_COUNT" -ge 20 ]]; then
    result AMBER "Repeated authentication failures" "$FAILED_AUTH_COUNT failed/invalid authentication events were found in the last 24 hours of readable journal data." \
        "Review the source IPs and targeted accounts. Failed attempts alone do not prove a successful intrusion."
elif [[ "$AUTH_LOG_AVAILABLE" -eq 1 ]]; then
    result PASS "Authentication log review" "$FAILED_AUTH_COUNT failed/invalid and $SUCCESS_SSH_COUNT successful SSH authentication event(s) were found in the readable journal query. Review the event details above."
else
    result AMBER "Authentication log visibility" "No authentication events were readable; this may mean no events, restricted journal access or different logging configuration." \
        "Run the diagnostic with sudo for fuller journal access, or inspect the system's authentication log location."
fi

if have last; then
    echo
    echo "--- Recent login history ---"
    last -F -n 25 2>&1 || true
fi
if have lastb; then
    echo
    echo "--- Recent failed login history (may require root) ---"
    lastb -F -n 25 2>&1 || true
fi

# 11.6 Persistence mechanisms
section "11.6 STARTUP AND PERSISTENCE REVIEW"
echo "--- Enabled system services ---"
if have systemctl; then
    systemctl list-unit-files --type=service --state=enabled --no-pager 2>&1 | head -100
else
    echo "systemctl unavailable."
fi

echo
echo "--- System and user cron entries ---"
for f in /etc/crontab; do
    [[ -r "$f" ]] && { echo "[$f]"; sed -n '1,160p' "$f"; }
done
for d in /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
    [[ -d "$d" ]] && { echo "[$d]"; find "$d" -maxdepth 1 -type f -printf '%M %u:%g %p\n' 2>/dev/null | sort; }
done
if [[ -d "$HOME/.config/autostart" ]]; then
    echo "[$HOME/.config/autostart]"
    find "$HOME/.config/autostart" -maxdepth 1 -type f -printf '%M %u:%g %p\n' 2>/dev/null
fi
if [[ -d "$HOME/.config/systemd/user" ]]; then
    echo "[$HOME/.config/systemd/user]"
    find "$HOME/.config/systemd/user" -maxdepth 3 -type f -printf '%M %u:%g %p\n' 2>/dev/null
fi
result AMBER "Persistence review" "Enabled services and common cron/autostart locations were inventoried; legitimacy cannot be determined automatically." \
    "Review unfamiliar service names, executable paths, owners and creation times. Do not disable entries solely because they are unfamiliar."

# 11.7 SUID/SGID inventory
section "11.7 PRIVILEGED FILE INVENTORY"
echo "--- SUID/SGID files on local root filesystem (first 120) ---"
SUID_LIST="$(find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -printf '%M %u:%g %p\n' 2>/dev/null | sort)"
SUID_COUNT="$(printf '%s\n' "$SUID_LIST" | grep -c . || true)"
printf '%s\n' "$SUID_LIST" | head -120
if [[ "$SUID_COUNT" -gt 0 ]]; then
    result AMBER "SUID/SGID inventory" "$SUID_COUNT privileged-bit file(s) were found; many are legitimate operating-system files." \
        "Compare unfamiliar entries with installed package ownership and expected system defaults. Investigate unexpected files, especially in writable locations."
else
    result PASS "SUID/SGID inventory" "No SUID/SGID files were found on the root filesystem scan."
fi

# 11.8 AppArmor and security updates
section "11.8 SYSTEM HARDENING STATUS"
if have aa-status; then
    AA_OUTPUT="$(aa-status 2>&1 || true)"
    echo "$AA_OUTPUT"
    if printf '%s\n' "$AA_OUTPUT" | grep -qiE 'apparmor module is loaded|profiles are in enforce mode|profiles are loaded'; then
        result PASS "AppArmor status" "AppArmor reports loaded profiles or an active module. Review complain-mode and unconfined processes separately."
    else
        result AMBER "AppArmor status" "AppArmor status did not confirm active enforcement." \
            "Check sudo aa-status and whether AppArmor is enabled for this distribution/kernel."
    fi
else
    result AMBER "AppArmor status" "aa-status is unavailable; AppArmor enforcement could not be verified." \
        "Install/enable AppArmor only after confirming compatibility with the installed Ubuntu release."
fi

if have apt; then
    UPGRADABLE_COUNT="$(apt list --upgradable 2>/dev/null | awk 'NR>1 {n++} END {print n+0}')"
    SECURITY_UPDATES="$(apt list --upgradable 2>/dev/null | grep -ciE 'security|ubuntu[0-9]+-security' || true)"
    echo "Upgradable packages: $UPGRADABLE_COUNT"
    echo "Packages with security indication in listing: $SECURITY_UPDATES"
    if [[ "$SECURITY_UPDATES" -gt 0 ]]; then
        result AMBER "Security updates" "$SECURITY_UPDATES package(s) appear to have security-related updates; package metadata may be stale." \
            "Review apt update output and install appropriate security updates after checking package changes. This diagnostic does not install updates."
    elif [[ "$UPGRADABLE_COUNT" -gt 0 ]]; then
        result AMBER "Package updates" "$UPGRADABLE_COUNT package(s) are upgradable; the list may include security and non-security updates." \
            "Review sudo apt update and apt list --upgradable, then apply appropriate updates."
    else
        result PASS "Package update inventory" "No upgradable packages were reported by the current local APT package lists; package-list freshness was not verified."
    fi
else
    result AMBER "Package update inventory" "APT is unavailable; package update status could not be checked." \
        "Check the package manager used by this system."
fi

if have systemctl; then
    AUTO_UPDATE_STATE="$(systemctl is-enabled unattended-upgrades 2>/dev/null || true)"
    echo "unattended-upgrades service enabled state: ${AUTO_UPDATE_STATE:-not found}"
    if [[ "$AUTO_UPDATE_STATE" == "enabled" ]]; then
        result PASS "Automatic update service" "unattended-upgrades service is enabled; verify its configuration and logs."
    else
        result AMBER "Automatic update service" "unattended-upgrades service is not reported enabled." \
            "Consider configuring automatic security updates if appropriate for your workload and maintenance policy."
    fi
fi

# 11.9 Malware/rootkit tooling availability (not a clean bill of health)
section "11.9 MALWARE SCANNER AVAILABILITY"
SCANNER_FOUND=0
for scanner in clamscan rkhunter chkrootkit; do
    if have "$scanner"; then
        SCANNER_FOUND=1
        echo "$scanner: $(command -v "$scanner")"
    else
        echo "$scanner: not installed"
    fi
done
if [[ "$SCANNER_FOUND" -eq 1 ]]; then
    result PASS "Malware scanning tools" "At least one scanner is installed. This script does not run a full malware scan or certify the system clean."
else
    result AMBER "Malware scanning tools" "No ClamAV, rkhunter or chkrootkit command was detected." \
        "If malware scanning is required, choose a maintained scanner and review its false-positive and update requirements."
fi

# ============================================================
# 12.5 AUTO-FIX — function definition (called after Section 12)
# Runs ONLY with --fix / --fix-firewall-only. Attempts fixes ONLY
# for problems actually detected in this run (RESULT_* arrays).
# NEVER auto-fixes: SMART failures, temperature, disk-full, ACPI
# errors, SUID files, persistence entries, listening services
# (other than via the firewall), or anything destructive.
# ============================================================

run_auto_fix() {
    section "12.5 AUTO-FIX (OPT-IN)"
    echo "Auto-fix is opt-in. Only problems detected in this run are attempted."
    echo "Dry-run: $([[ "$DRY_RUN" -eq 1 ]] && echo yes || echo no) — Firewall-only: $([[ "$FIX_FIREWALL_ONLY" -eq 1 ]] && echo yes || echo no)"

    # --- Firewall: inactive / not installed ---
    if has_finding "Firewall posture"; then
        echo
        echo "--- Fix: firewall ---"
        if ! have ufw; then
            try_fix "Install UFW" "Install the ufw package (apt)" \
                "sudo apt update && sudo apt install -y ufw"
        fi
        # Allow SSH FIRST if sshd is active, before enabling the firewall.
        if have systemctl; then
            local ssh_state=""
            ssh_state="$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || true)"
            if [[ "$ssh_state" == "active" ]]; then
                try_fix "Allow SSH in UFW" "Allow SSH before enabling UFW (avoids locking yourself out)" \
                    "sudo ufw allow ssh"
            fi
        fi
        try_fix "UFW default deny incoming" "Set UFW default policy: deny incoming" \
            "sudo ufw default deny incoming"
        try_fix "UFW allow outgoing" "Set UFW default policy: allow outgoing" \
            "sudo ufw allow outgoing"
        if [[ "$AUTO_YES" -eq 1 ]]; then
            try_fix "Enable UFW" "Enable UFW (--force, because --yes was given)" \
                "sudo ufw --force enable"
        else
            try_fix "Enable UFW" "Enable UFW" \
                "sudo ufw enable"
        fi
        # Verify (read-only check, not a fix attempt).
        if [[ "$DRY_RUN" -eq 0 ]] && have ufw; then
            echo "--- Verifying firewall ---"
            ufw status verbose 2>&1 | head -20 || true
            if ufw status verbose 2>&1 | grep -q '^Status: active'; then
                log_fix "Verified: UFW is now active"
            else
                log_fix "Verification: UFW is NOT active after the fix attempt — re-check manually"
                FIX_FAILED=$((FIX_FAILED + 1))
            fi
        fi
    else
        echo "Firewall: no firewall problem detected in this run — nothing to fix."
    fi

    if [[ "$FIX_FIREWALL_ONLY" -eq 1 ]]; then
        log_fix "Firewall-only mode: skipping non-firewall fixes"
        return 0
    fi

    # --- ~/.ssh permissions (detected directly here; the original
    # script has no ~/.ssh-permissions check, so the fix phase checks
    # the filesystem itself and only fixes a wrong mode it finds) ---
    if [[ -d "$HOME/.ssh" ]]; then
        echo
        echo "--- Fix: ~/.ssh permissions ---"
        local ssh_mode=""
        ssh_mode="$(stat -c %a "$HOME/.ssh" 2>/dev/null || echo "")"
        if [[ -n "$ssh_mode" && "$ssh_mode" != "700" ]]; then
            try_fix "Fix ~/.ssh permissions" "chmod 700 ~/.ssh (currently $ssh_mode)" \
                "chmod 700 \"$HOME/.ssh\""
        fi
        local keyfile key_mode
        for keyfile in "$HOME"/.ssh/id_rsa "$HOME"/.ssh/id_ed25519 "$HOME"/.ssh/id_ecdsa; do
            if [[ -f "$keyfile" ]]; then
                key_mode="$(stat -c %a "$keyfile" 2>/dev/null || echo "")"
                if [[ -n "$key_mode" && "$key_mode" != "600" ]]; then
                    try_fix "Fix SSH private key permissions" "chmod 600 $keyfile (currently $key_mode)" \
                        "chmod 600 \"$keyfile\""
                fi
            fi
        done
    fi

    # --- Unattended-upgrades not enabled ---
    if has_finding "Automatic update service"; then
        echo
        echo "--- Fix: automatic security updates ---"
        try_fix "Install unattended-upgrades" "Install unattended-upgrades (apt)" \
            "sudo apt install -y unattended-upgrades"
        try_fix "Enable unattended-upgrades" "Enable the unattended-upgrades service" \
            "sudo systemctl enable unattended-upgrades"
    fi

    # --- Package updates: ONLY with --fix-updates ---
    if has_finding "Package updates" || has_finding "Security updates"; then
        echo
        echo "--- Fix: package updates ---"
        if [[ "$FIX_UPDATES" -eq 1 ]]; then
            echo "WARNING: apt upgrade can take several minutes and may restart services."
            try_fix "Apply package updates" "apt update && apt upgrade -y (can take minutes)" \
                "sudo apt update && sudo apt upgrade -y"
        else
            log_fix "Skipped: package updates pending, but --fix-updates was not passed (report-only)"
            FIX_SKIPPED=$((FIX_SKIPPED + 1))
        fi
    fi

    # Deliberately NOT auto-fixed (report-only): SMART failures,
    # temperature, disk-full, ACPI errors, SUID files, persistence
    # entries, listening services other than via the firewall.
    echo
    echo "Not auto-fixed (report-only by design): SMART failures, temperature,"
    echo "disk-full, ACPI errors, SUID files, persistence entries, and"
    echo "listening services other than via the firewall."
    return 0
}

print_fix_summary() {
    section "12.6 FIX SUMMARY"
    echo "Fixes attempted: $FIX_ATTEMPTED"
    echo "Fixes succeeded: $FIX_SUCCEEDED"
    echo "Fixes failed:    $FIX_FAILED"
    echo "Fixes skipped:   $FIX_SKIPPED"
    echo
    if [[ "${#FIX_LOG[@]}" -gt 0 ]]; then
        echo "--- Fix log ---"
        printf '%s\n' "${FIX_LOG[@]}"
    else
        echo "No fixes were attempted."
    fi
    echo
    echo "IMPORTANT: a fix attempt is NOT a verified PASS."
    echo "Re-run the script to verify: ./xubuntu_hardware_cybersec_diagnose_fixed.sh"
    echo "Only a re-run can confirm a problem is actually fixed."
}

# ============================================================
# 12. FINAL HEALTH ASSESSMENT
# ============================================================

section "12. FINAL HEALTH ASSESSMENT"

TOTAL=$((PASS_COUNT + AMBER_COUNT + FAIL_COUNT))
echo "TOTAL CHECKS: $TOTAL"

echo
echo "-------------------- PASS --------------------"
for i in "${!RESULT_STATUS[@]}"; do
    if [[ "${RESULT_STATUS[$i]}" == "PASS" ]]; then
        echo "[PASS] ${RESULT_NAME[$i]}"
        echo "       ${RESULT_DETAIL[$i]}"
    fi
done

echo
echo "-------------------- AMBER --------------------"
AMBER_LISTED=0
for i in "${!RESULT_STATUS[@]}"; do
    if [[ "${RESULT_STATUS[$i]}" == "AMBER" ]]; then
        AMBER_LISTED=1
        echo
        echo "[AMBER] ${RESULT_NAME[$i]}"
        echo "        FINDING: ${RESULT_DETAIL[$i]}"
        echo "        ACTION:  ${RESULT_ACTION[$i]:-Investigate this finding.}"
    fi
done
[[ "$AMBER_LISTED" -eq 1 ]] || echo "No AMBER findings."

echo
echo "-------------------- FAIL --------------------"
FAIL_LISTED=0
for i in "${!RESULT_STATUS[@]}"; do
    if [[ "${RESULT_STATUS[$i]}" == "FAIL" ]]; then
        FAIL_LISTED=1
        echo
        echo "[FAIL] ${RESULT_NAME[$i]}"
        echo "       FINDING: ${RESULT_DETAIL[$i]}"
        echo "       ACTION:  ${RESULT_ACTION[$i]:-Immediate investigation required.}"
    fi
done
[[ "$FAIL_LISTED" -eq 1 ]] || echo "No FAIL findings."

echo
echo "============================================================"
echo "OVERALL RESULT"
echo "============================================================"
echo "PASS:  $PASS_COUNT"
echo "AMBER: $AMBER_COUNT"
echo "FAIL:  $FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    OVERALL_STATUS="FAIL"
    echo "OVERALL STATUS: FAIL"
    echo "Serious findings require investigation."
elif [[ "$AMBER_COUNT" -gt 0 ]]; then
    OVERALL_STATUS="AMBER"
    echo "OVERALL STATUS: AMBER"
    echo "Warnings or incomplete checks require review."
else
    OVERALL_STATUS="PASS"
    echo "OVERALL STATUS: PASS"
    echo "All completed checks passed."
fi

# --- Auto-fix phase: only with --fix / --fix-firewall-only.
# Default run (no --fix) skips this entirely and stays read-only.
if [[ "$FIX_MODE" -eq 1 ]]; then
    run_auto_fix
    print_fix_summary
fi

# ============================================================
# 13. ACTION CHECKLIST
# (FIXED: was also labelled 12 in the original — renumbered to 13)
# ============================================================

section "13. ACTION CHECKLIST"

ACTION_NUMBER=0
for i in "${!RESULT_STATUS[@]}"; do
    if [[ "${RESULT_STATUS[$i]}" == "AMBER" || "${RESULT_STATUS[$i]}" == "FAIL" ]]; then
        ACTION_NUMBER=$((ACTION_NUMBER + 1))
        echo
        echo "[ ] $ACTION_NUMBER. [${RESULT_STATUS[$i]}] ${RESULT_NAME[$i]}"
        echo "    Finding: ${RESULT_DETAIL[$i]}"
        echo "    Action:  ${RESULT_ACTION[$i]:-Investigate this finding.}"
    fi
done

if [[ "$ACTION_NUMBER" -eq 0 ]]; then
    echo "No outstanding corrective actions."
fi

# ============================================================
# 14. REPORT FOOTER
# (FIXED: was labelled 13 in the original — renumbered to 14)
# ============================================================

section "14. REPORT"

echo "Diagnostic completed: $(date)"
echo "Hostname: $HARDWARE_NAME"
echo "Overall status: $OVERALL_STATUS"
echo "PASS: $PASS_COUNT"
echo "AMBER: $AMBER_COUNT"
echo "FAIL: $FAIL_COUNT"
if [[ "$FIX_MODE" -eq 1 ]]; then
    echo "Fixes: attempted $FIX_ATTEMPTED, succeeded $FIX_SUCCEEDED, failed $FIX_FAILED, skipped $FIX_SKIPPED"
    echo "Re-run the script to verify any fix — a fix attempt is not a verified PASS."
fi
echo
echo "Full report saved to:"
echo "$OUT"
echo
echo "Read-only diagnostic: no system configuration, accounts, services, firewall rules or source files were modified."
if [[ "$FIX_MODE" -eq 1 ]]; then
    echo "Exception: with --fix, only the fixes listed in Section 12.5/12.6 were attempted, each logged."
fi
echo "Cybersecurity findings are indicators for investigation, not proof that the system is compromised or clean."
echo
# FIXED (audit bug): the original `read -rp "Press Enter..."` hung when
# stdin was not a terminal (e.g. piped / non-interactive run).
# Only prompt when stdin is a terminal.
if [[ -t 0 ]]; then
    read -rp "Press Enter to close this window..." _
fi
