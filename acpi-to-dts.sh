#!/bin/bash
#
# ACPI to DTS Converter for Sky1 (Orion O6/O6N)
#
# This script parses ACPI DSDT and hardware extraction data to generate
# a Device Tree Source file for mainline Linux kernel.
#
# Usage: ./acpi-to-dts.sh <extraction_dir> [output.dts]
#
# The extraction_dir should contain output from extract-hw-info.sh run in ACPI mode.
#
# Requirements: gawk (GNU awk) - mawk is not compatible
#

# Note: Using set +e because some subcommands may return non-zero
# (e.g., grep when no matches found) which shouldn't abort the script
set +e

# Check for gawk (GNU awk) - required for match() with array capture
if ! awk --version 2>/dev/null | grep -q "GNU Awk"; then
    echo "[ERROR] This script requires GNU awk (gawk)." >&2
    echo "        Install with: sudo apt install gawk" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTION_DIR="${1:?Usage: $0 <extraction_dir> [output.dts]}"
OUTPUT_DTS="${2:-$EXTRACTION_DIR/generated.dts}"

# Reference DTS for structure (if available)
REFERENCE_DTS=""
if [[ -f /tmp/hw-extract-dt/devicetree/extracted.dts ]]; then
    REFERENCE_DTS="/tmp/hw-extract-dt/devicetree/extracted.dts"
fi

#############################################################################
# ACPI HID to Device Tree Compatible String Mapping
#############################################################################

declare -A ACPI_TO_DT_COMPAT=(
    # I2C Controllers (Cadence)
    ["CIXH200B"]="cdns,i2c-r1p14"

    # GPIO Controllers
    ["CIXH1002"]="cix,sky1-gpio"      # S5 domain GPIO
    ["CIXH1003"]="cix,sky1-gpio"      # Main GPIO

    # UART (ARM PL011)
    ["ARMH0011"]="arm,pl011"

    # PCIe Root Ports
    ["CIXH2020"]="cix,sky1-pcie"

    # USB Controllers
    ["CIXH5010"]="cix,sky1-dwc3"      # DWC3 wrapper
    ["CIXH5000"]="snps,dwc3"          # Synopsys DWC3
    ["CIXH5001"]="cix,sky1-usb-phy"   # USB PHY

    # Display
    ["CIXH502F"]="cix,linlon-dp"      # DisplayPort
    ["CIXH5040"]="cix,linlon-dc"      # Display Controller
    ["CIXH5041"]="cix,linlon-dpu"     # DPU

    # Clocks and Reset
    ["CIXHA010"]="cix,sky1-cru"       # Clock Reset Unit
    ["CIXHA018"]="cix,sky1-cru"       # CRU variant
    ["CIXHA019"]="cix,sky1-pdc"       # Power Domain Controller
    ["CIXHA020"]="cix,sky1-reset"     # Reset controller (S5)
    ["CIXHA021"]="cix,sky1-reset"     # Reset controller (FCH)
    ["CIXA1019"]="cix,sky1-reset"     # Reset controller

    # Mailbox
    ["CIXHA001"]="cix,sky1-mailbox"

    # Thermal
    ["CIXH6000"]="cix,sky1-thermal"
    ["CIXH6011"]="cix,sky1-tsensor"

    # GPU
    ["CIXH4000"]="arm,mali-valhall-csf"

    # VPU / Video
    ["CIXH3010"]="cix,sky1-vpu"
    ["CIXH3025"]="cix,sky1-vcodec"
    ["CIXH3026"]="cix,sky1-jpeg"

    # Audio
    ["CIXH3020"]="cix,sky1-i2s"
    ["CIXH3021"]="cix,sky1-audio-dsp"

    # Native Ethernet MAC
    ["CIXH7020"]="cix,sky1-gmac"

    # Pinctrl/Pinmux
    ["CIXH1006"]="cix,sky1-pinctrl"
    ["CIXH1007"]="cix,sky1-pinctrl-s5"

    # Watchdog
    ["CIXH2001"]="cix,sky1-wdt"

    # SPI
    ["CIXH2011"]="cdns,spi-r1p6"

    # PWM
    ["CIXH2023"]="cix,sky1-pwm"

    # Timer
    ["CIXH2034"]="cix,sky1-timer"

    # DMA
    ["CIXH6020"]="arm,pl330"

    # RTC
    ["CIXH6060"]="cix,sky1-rtc"
    ["CIXH6061"]="cix,sky1-rtc-wrapper"

    # SMMU
    ["CIXH2030"]="arm,smmu-v3"
    ["CIXH2031"]="arm,smmu-v3-pmcg"
    ["CIXH2032"]="arm,smmu-v3"
    ["CIXH2033"]="arm,smmu-v3"

    # ISP / Camera
    ["CIXH4010"]="cix,sky1-isp"

    # AIPU / NPU
    ["CIXHA002"]="cix,sky1-aipu"

    # Board-specific devices (from SSDT)
    ["CIXH200D"]="cix,sky1-usb-pd"     # USB-C PD controller
    ["CIXH6070"]="cix,sky1-sound"      # Sound card
    ["ACPI0011"]="gpio-keys"           # Generic Buttons
    ["PNP0C0C"]="gpio-keys"            # Power Button (ACPI standard)
    ["ERTC0000"]="haoyu,hym8563"       # External I2C RTC

    # PRP0001 devices get their compatible from _DSD, handled specially
    ["PRP0001"]="PRP0001"              # Generic DT-compatible device
)

# Base address to node name mapping
declare -A ADDR_TO_NODE=(
    ["04010000"]="i2c0"
    ["04020000"]="i2c1"
    ["04030000"]="i2c2"
    ["04040000"]="i2c3"
    ["04050000"]="i2c4"
    ["04060000"]="i2c5"
    ["04070000"]="i2c6"
    ["04080000"]="i2c7"
    ["04090000"]="spi0"
    ["040a0000"]="spi1"
    ["040b0000"]="uart0"
    ["040c0000"]="uart1"
    ["040d0000"]="uart2"
    ["040e0000"]="uart3"
    ["04110000"]="pwm0"
    ["04120000"]="gpio0"
    ["04130000"]="gpio1"
    ["04140000"]="gpio2"
    ["04150000"]="gpio3"
    ["04170000"]="pinctrl"
    ["04190000"]="dma0"
    ["05060000"]="mailbox0"
    ["05070000"]="mailbox1"
    ["06590000"]="mailbox_pm"
    ["065a0000"]="mailbox_pm2"
    ["07000000"]="audio_dsp"
    ["07010000"]="dma_audio"
    ["07070000"]="i2s0"
    ["07080000"]="i2s1"
    ["070a0000"]="i2s2"
    ["070b0000"]="i2s3"
    ["070c0000"]="hda"
    ["09010000"]="usb_dwc3_0"
    ["09080000"]="usb_dwc3_1"
    ["090f0000"]="usb_dwc3_2"
    ["09160000"]="usb_dwc3_3"
    ["091d0000"]="usb_dwc3_4"
    ["091e0000"]="usb_dwc3_5"
    ["09260000"]="usb_dwc3_6"
    ["09290000"]="usb_dwc3_7"
    ["092c0000"]="usb_dwc3_8"
    ["092f0000"]="usb_dwc3_9"
    ["0a010000"]="pcie0"
    ["0a070000"]="pcie1"
    ["0a0c0000"]="pcie2"
    ["0a130000"]="pcie3"
    ["0a1a0000"]="pcie4"
    ["14010000"]="dc0"
    ["14064000"]="dp0"
    ["14080000"]="dc1"
    ["140d4000"]="dp1"
    ["140f0000"]="dc2"
    ["14144000"]="dp2"
    ["14160000"]="dc3"
    ["141b4000"]="dp3"
    ["141d0000"]="dc4"
    ["14224000"]="dp4"
    ["14230000"]="vpu"
    ["14260000"]="aipu"
    ["14340000"]="isp"
    ["15000000"]="gpu"
    ["16000000"]="pdc"
    ["16003000"]="watchdog"
    ["16004000"]="gpio_s5_0"
    ["16005000"]="gpio_s5_1"
    ["16006000"]="gpio_s5_2"
    ["16007000"]="pinctrl_s5"
)

# Device-specific extracted data (populated by DSDT parser)
declare -A DEVICE_CLOCKS      # device -> "clock_id:clock_name"
declare -A DEVICE_RESETS      # device -> "rst_controller:rst_id:rst_name"
declare -A DEVICE_PINCTRL     # device -> "pinctrl_group"
declare -A DEVICE_DSD         # device -> "prop=value,prop=value"
declare -A DEVICE_GPIO        # device -> "controller:pin" (from GpioIo)
declare -A DEVICE_CHILDREN    # parent_device -> "child1:addr,child2:addr" (nested devices)
declare -A CHILD_DEVICE_DSD   # child_device -> "prop=value,prop=value"

#############################################################################
# Helper Functions
#############################################################################

log() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# Convert hex string to decimal
hex_to_dec() {
    local hex="${1#0x}"
    printf "%d" "0x$hex" 2>/dev/null || echo "0"
}

# Convert GIC IRQ number to SPI number (SPI interrupts start at 32)
irq_to_spi() {
    local irq="$1"
    if [[ -n "$irq" && "$irq" =~ ^[0-9]+$ && "$irq" -gt 32 ]]; then
        echo $((irq - 32))
    else
        echo "0"
    fi
}

# Check if extraction directory is valid
check_extraction_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || error "Extraction directory not found: $dir"
    [[ -f "$dir/00-summary.txt" ]] || error "Not a valid extraction directory (missing 00-summary.txt)"

    if ! grep -q "Boot mode: ACPI" "$dir/00-summary.txt" 2>/dev/null; then
        log "WARNING: Extraction may not be from ACPI mode boot"
    fi

    [[ -f "$dir/acpi/DSDT.dsl" ]] || error "DSDT.dsl not found - was iasl installed during extraction?"

    # Disassemble SSDT files if they exist as binary (not already .dsl)
    for ssdt in "$dir/acpi/SSDT"*; do
        [[ -f "$ssdt" ]] || continue
        [[ "$ssdt" == *.dsl ]] && continue
        local ssdt_dsl="${ssdt}.dsl"
        if [[ ! -f "$ssdt_dsl" ]]; then
            log "Disassembling $(basename "$ssdt")..."
            iasl -p "$ssdt_dsl" -d "$ssdt" 2>/dev/null || true
            # iasl adds .dsl automatically, so rename if needed
            [[ -f "${ssdt_dsl}.dsl" ]] && mv "${ssdt_dsl}.dsl" "$ssdt_dsl"
        fi
    done
}

#############################################################################
# DSDT Parser - More Sophisticated Version
#############################################################################

# Parse all devices from DSDT with full resource info
extract_dsdt_devices() {
    local dsdt_file="$1"
    local output_file="$2"

    log "Parsing DSDT for device definitions..."

    # Advanced awk parser for DSDT
    awk '
    BEGIN {
        device = ""
        hid = ""
        uid = 0
        in_device = 0
        in_crs = 0
        in_interrupt = 0
        base_addr = ""
        size = ""
        interrupt = ""
        device_count = 0
    }

    # Track device blocks
    /^[[:space:]]*Device \([A-Z0-9]+\)/ {
        # Emit previous device
        if (device != "" && hid != "" && hid !~ /^PNP/) {
            printf "%s|%s|%d|%s|%s|%s\n", device, hid, uid, tolower(base_addr), tolower(size), interrupt
            device_count++
        }

        # Start new device
        match($0, /Device \(([A-Z0-9]+)\)/, arr)
        device = arr[1]
        hid = ""
        uid = 0
        base_addr = ""
        size = ""
        interrupt = ""
        in_device = 1
        in_crs = 0
        in_interrupt = 0
    }

    # Parse HID
    in_device && /Name \(_HID,/ {
        if (match($0, /"([^"]+)"/, arr)) {
            hid = arr[1]
        }
    }

    # Parse UID - handle both hex and decimal
    in_device && /Name \(_UID,/ {
        if (match($0, /0x([0-9A-Fa-f]+)/, arr)) {
            uid = strtonum("0x" arr[1])
        } else if (match($0, /[[:space:]]([0-9]+)[[:space:]]*\)/, arr)) {
            uid = arr[1]
        } else if (/Zero/) {
            uid = 0
        } else if (/One/) {
            uid = 1
        }
    }

    # Parse Memory32Fixed for base address
    in_device && /Memory32Fixed/ {
        in_crs = 1
        crs_step = 0
    }

    in_crs && /0x[0-9A-Fa-f]{8}/ {
        if (match($0, /0x([0-9A-Fa-f]{8})/, arr)) {
            if (crs_step == 0 && base_addr == "") {
                base_addr = arr[1]
                crs_step = 1
            } else if (crs_step == 1 && size == "") {
                size = arr[1]
                in_crs = 0
            }
        }
    }

    # Parse Interrupt - look for ResourceConsumer pattern
    in_device && /Interrupt \(ResourceConsumer/ {
        in_interrupt = 1
    }

    # Capture interrupt number (appears as standalone hex on its own line)
    in_interrupt && /^[[:space:]]*0x[0-9A-Fa-f]+,$/ {
        if (match($0, /0x([0-9A-Fa-f]+)/, arr)) {
            interrupt = strtonum("0x" arr[1])
            in_interrupt = 0
        }
    }

    END {
        # Emit last device
        if (device != "" && hid != "" && hid !~ /^PNP/) {
            printf "%s|%s|%d|%s|%s|%s\n", device, hid, uid, tolower(base_addr), tolower(size), interrupt
            device_count++
        }
        print "# Total devices: " device_count > "/dev/stderr"
    }
    ' "$dsdt_file" > "$output_file"

    # Sort and remove duplicates (keep first occurrence)
    sort -t'|' -k2,2 -k3,3n -u "$output_file" -o "$output_file"

    log "Extracted $(grep -c '^[^#]' "$output_file" 2>/dev/null || echo 0) unique devices"
}

# Extract CLKT (Clock Table), RSTL (Reset List), PinGroupFunction, and _DSD
extract_device_properties() {
    local dsdt_file="$1"

    log "Extracting device properties (clocks, resets, pinctrl, DSD)..."

    # Parse with awk - one pass for all properties
    local props
    props=$(awk '
    BEGIN {
        device = ""
        in_clkt = 0
        in_rstl = 0
        in_dsd = 0
        clkt_brace = 0
        rstl_brace = 0
        dsd_brace = 0
    }

    # Track current device
    /^[[:space:]]*Device \([A-Z0-9]+\)/ {
        if (match($0, /Device \(([A-Z0-9]+)\)/, arr)) {
            device = arr[1]
        }
    }

    # CLKT parsing - clock table
    device != "" && /Name \(CLKT,/ && !/Package \(0x00\)/ {
        in_clkt = 1
        clkt_brace = 0
        clkt_id = ""
        clkt_name = ""
    }

    in_clkt {
        # Count braces in the original line
        line = $0
        gsub(/[^{]/, "", line)
        clkt_brace += length(line)
        line = $0
        gsub(/[^}]/, "", line)
        clkt_brace -= length(line)

        # Match hex number (clock ID) - skip lines with "Package"
        if (!/Package/ && match($0, /^[[:space:]]*(0x[0-9A-Fa-f]+),?[[:space:]]*$/, arr)) {
            if (clkt_id == "") clkt_id = strtonum(arr[1])
        }

        # Match clock name string (on its own line, not in Package)
        if (!/Package/ && match($0, /^[[:space:]]*"([^"]*)"/, arr)) {
            if (clkt_name == "" && arr[1] != "") clkt_name = arr[1]
        }

        # End of CLKT - look for closing `})`
        if (/\}\)[[:space:]]*$/) {
            if (clkt_id != "") {
                printf "CLKT|%s|%s|%s\n", device, clkt_id, clkt_name
            }
            in_clkt = 0
        }
    }

    # RSTL parsing - reset list
    device != "" && /Name \(RSTL,/ && !/Package \(0x00\)/ {
        in_rstl = 1
        rstl_brace = 0
        rstl_ctrl = ""
        rstl_id = ""
        rstl_name = ""
    }

    in_rstl {
        # Count braces
        line = $0
        gsub(/[^{]/, "", line)
        rstl_brace += length(line)
        line = $0
        gsub(/[^}]/, "", line)
        rstl_brace -= length(line)

        # RST controller reference (RST0 or RST1) - on its own line
        if (!/Package/ && match($0, /^[[:space:]]*(RST[0-9]),?[[:space:]]*$/, arr)) {
            if (rstl_ctrl == "") rstl_ctrl = arr[1]
        }

        # Reset ID (hex number) - on its own line after controller
        if (rstl_ctrl != "" && !/Package/ && match($0, /^[[:space:]]*(0x[0-9A-Fa-f]+),?[[:space:]]*$/, arr)) {
            if (rstl_id == "") rstl_id = strtonum(arr[1])
        }

        # Reset name (string) - on its own line
        if (rstl_id != "" && match($0, /^[[:space:]]*"([^"]+)"[[:space:]]*$/, arr)) {
            if (rstl_name == "") rstl_name = arr[1]
        }

        # End of RSTL - look for closing `})`
        if (/\}\)[[:space:]]*$/) {
            if (rstl_ctrl != "" && rstl_id != "") {
                printf "RSTL|%s|%s|%s|%s\n", device, rstl_ctrl, rstl_id, rstl_name
            }
            in_rstl = 0
        }
    }

    # PinGroupFunction parsing in _CRS
    device != "" && /PinGroupFunction/ {
        in_pgf = 1
    }

    in_pgf && /"[a-z][a-z0-9_-]*"/ {
        if (match($0, /"([a-z][a-z0-9_-]*)"/, arr)) {
            pgf_name = arr[1]
            printf "PINCTRL|%s|%s\n", device, pgf_name
        }
        in_pgf = 0
    }

    # _DSD parsing - Device Specific Data
    device != "" && /Name \(_DSD,/ {
        in_dsd = 1
        dsd_brace = 0
        dsd_key = ""
        dsd_pairs = ""
    }

    in_dsd {
        # Count braces
        line = $0
        gsub(/[^{]/, "", line)
        dsd_brace += length(line)
        line = $0
        gsub(/[^}]/, "", line)
        dsd_brace -= length(line)

        # Key-value on same line: "key", value  or  "key", "value"
        if (match($0, /"([A-Za-z][A-Za-z0-9_-]*)",[[:space:]]*$/, arr)) {
            dsd_key = arr[1]
        }

        # Value on next line after key
        if (dsd_key != "") {
            if (match($0, /^[[:space:]]+(0x[0-9A-Fa-f]+)/, arr)) {
                dsd_val = strtonum(arr[1])
                if (dsd_pairs != "") dsd_pairs = dsd_pairs ","
                dsd_pairs = dsd_pairs dsd_key "=" dsd_val
                dsd_key = ""
            } else if (match($0, /^[[:space:]]+"([^"]*)"/, arr)) {
                dsd_val = arr[1]
                if (dsd_pairs != "") dsd_pairs = dsd_pairs ","
                dsd_pairs = dsd_pairs dsd_key "=" dsd_val
                dsd_key = ""
            }
        }

        # End of _DSD - look for closing `)` or `})`
        if (dsd_brace <= 0 && /\}?\)[[:space:]]*$/) {
            if (dsd_pairs != "") {
                printf "DSD|%s|%s\n", device, dsd_pairs
            }
            in_dsd = 0
            dsd_pairs = ""
        }
    }

    # GpioIo parsing - extract GPIO controller and pin
    /GpioIo/ && device != "" {
        in_gpio = 1
        gpio_ctrl = ""
        gpio_pin = ""
    }

    in_gpio && /\\_SB\./ {
        # GPIO controller reference: "\\_SB.GPI3"
        if (match($0, /\\_SB\.([A-Z0-9]+)/, arr)) {
            gpio_ctrl = arr[1]
        }
    }

    in_gpio && /Pin list/ { in_gpio_pin = 1 }

    in_gpio_pin && /0x[0-9A-Fa-f]+/ {
        if (match($0, /0x([0-9A-Fa-f]+)/, arr)) {
            gpio_pin = strtonum("0x" arr[1])
            if (gpio_ctrl != "") {
                printf "GPIO|%s|%s|%s\n", device, gpio_ctrl, gpio_pin
            }
            in_gpio_pin = 0
            in_gpio = 0
        }
    }

    # Track top-level devices (8 spaces / 2 tabs indentation)
    /^        Device \([A-Z0-9]+\)/ {
        if (match($0, /Device \(([A-Z0-9]+)\)/, arr)) {
            current_parent = arr[1]
        }
    }

    # Track child devices (12 spaces / 3 tabs indentation)
    /^            Device \([A-Z0-9]+\)/ {
        if (match($0, /Device \(([A-Z0-9]+)\)/, arr)) {
            child_name = arr[1]
            parent_for_child = current_parent
            in_child = 1
            child_addr = ""
            child_compat = ""
            wait_compat = 0
        }
    }

    # Child device _ADR (address)
    in_child && /Name \(_ADR,/ {
        if (match($0, /0x([0-9A-Fa-f]+)/, arr)) {
            child_addr = strtonum("0x" arr[1])
        } else if (/One/) {
            child_addr = 1
        } else if (/Zero/) {
            child_addr = 0
        }
    }

    # Child device _DSD compatible - mark to read next line
    in_child && /"compatible",/ {
        wait_compat = 1
        next
    }

    # Read compatible value on next line
    in_child && wait_compat {
        if (match($0, /"([a-z][a-z0-9,.-]*)"/, arr)) {
            child_compat = arr[1]
            printf "CHILD|%s|%s|%s|%s\n", parent_for_child, child_name, child_addr, child_compat
            wait_compat = 0
            in_child = 0
        }
    }

    ' "$dsdt_file")

    # Populate associative arrays
    local clk_count=0 rst_count=0 pin_count=0 dsd_count=0 gpio_count=0 child_count=0

    while IFS='|' read -r type device val1 val2 val3 val4; do
        [[ -z "$type" ]] && continue

        case "$type" in
            CLKT)
                DEVICE_CLOCKS["$device"]="${val1}:${val2}"
                ((clk_count++)) || true
                ;;
            RSTL)
                DEVICE_RESETS["$device"]="${val1}:${val2}:${val3}"
                ((rst_count++)) || true
                ;;
            PINCTRL)
                # Append if multiple pinctrl groups
                if [[ -n "${DEVICE_PINCTRL[$device]}" ]]; then
                    DEVICE_PINCTRL["$device"]="${DEVICE_PINCTRL[$device]},${val1}"
                else
                    DEVICE_PINCTRL["$device"]="$val1"
                fi
                ((pin_count++)) || true
                ;;
            DSD)
                DEVICE_DSD["$device"]="$val1"
                ((dsd_count++)) || true
                ;;
            GPIO)
                # val1=controller (GPI0/GPI3), val2=pin number
                if [[ -n "${DEVICE_GPIO[$device]}" ]]; then
                    DEVICE_GPIO["$device"]="${DEVICE_GPIO[$device]},${val1}:${val2}"
                else
                    DEVICE_GPIO["$device"]="${val1}:${val2}"
                fi
                ((gpio_count++)) || true
                ;;
            CHILD)
                # device=parent, val1=child_name, val2=addr, val3=compatible
                if [[ -n "${DEVICE_CHILDREN[$device]}" ]]; then
                    DEVICE_CHILDREN["$device"]="${DEVICE_CHILDREN[$device]},${val1}:${val2}"
                else
                    DEVICE_CHILDREN["$device"]="${val1}:${val2}"
                fi
                CHILD_DEVICE_DSD["${device}_${val1}"]="compatible=${val3}"
                ((child_count++)) || true
                ;;
        esac
    done <<< "$props"

    log "Extracted: $clk_count clocks, $rst_count resets, $pin_count pinctrl, $dsd_count DSD, $gpio_count gpio, $child_count children"
}

# Parse I2C devices from i2cdetect output
parse_i2c_devices() {
    local i2c_file="$1"

    # Extract detected I2C addresses per bus
    awk '
    /^--- i2c-[0-9]+ ---/ {
        match($0, /i2c-([0-9]+)/, arr)
        bus = arr[1]
        next
    }
    /^[0-9]+:/ && bus != "" {
        for (i = 2; i <= NF; i++) {
            if ($i ~ /^[0-9a-f][0-9a-f]$/ && $i != "--" && $i != "UU") {
                printf "%d|0x%s\n", bus, $i
            }
        }
    }
    ' "$i2c_file" 2>/dev/null
}

# Parse GPIO pin configurations
parse_gpio_config() {
    local gpio_file="$1"

    # Extract GPIO chip info
    awk '
    /^gpiochip[0-9]+/ {
        chip = $1
        gsub(/:/, "", chip)
    }
    /line[[:space:]]+[0-9]+:/ && chip != "" {
        match($0, /line[[:space:]]+([0-9]+):[[:space:]]+"([^"]*)"[[:space:]]+([a-z]+)[[:space:]]+([a-z]+)/, arr)
        if (arr[1] != "") {
            printf "%s|%s|%s|%s|%s\n", chip, arr[1], arr[2], arr[3], arr[4]
        }
    }
    ' "$gpio_file" 2>/dev/null
}

#############################################################################
# SSDT PRP0001 Device Extractor
#############################################################################

# Storage for board-specific devices from SSDT
declare -A SSDT_REGULATORS=()    # name -> "gpio_ctrl|gpio_pin|voltage_uv|always_on"
declare -A SSDT_LEDS=()          # name -> "gpio_ctrl|gpio_pin|trigger"
declare -A SSDT_BUTTONS=()       # name -> "gpio_ctrl|gpio_pin|linux_code"

# Extract PRP0001 devices (regulators, LEDs) from SSDT files
extract_prp0001_devices() {
    local ssdt_file="$1"

    [[ -f "$ssdt_file" ]] || return 0

    log "Extracting PRP0001 devices from $(basename "$ssdt_file")..."

    # Parse PRP0001 devices with their _DSD compatible and GPIO resources
    local result
    result=$(awk '
    BEGIN {
        device = ""
        in_prp0001 = 0
        in_dsd = 0
        in_crs = 0
        compatible = ""
        reg_name = ""
        voltage = ""
        always_on = 0
        gpio_ctrl = ""
        gpio_pin = ""
        led_trigger = ""
        wait_value = ""
    }

    # Track device entry
    /Device \([A-Z0-9]+\)/ {
        if (match($0, /Device \(([A-Z0-9]+)\)/, arr)) {
            # Output previous device if it was a regulator or LED
            if (in_prp0001 && compatible != "") {
                if (compatible == "regulator-fixed" && reg_name != "") {
                    printf "REG|%s|%s|%s|%s|%s\n", reg_name, gpio_ctrl, gpio_pin, voltage, always_on
                } else if (compatible == "gpio-leds") {
                    printf "LEDS|%s|%s|%s\n", device, gpio_ctrl, gpio_pin
                }
            }
            device = arr[1]
            in_prp0001 = 0
            in_dsd = 0
            in_crs = 0
            compatible = ""
            reg_name = ""
            voltage = ""
            always_on = 0
            gpio_ctrl = ""
            gpio_pin = ""
            led_trigger = ""
        }
    }

    # Check for PRP0001 HID
    /Name \(_HID, "PRP0001"\)/ {
        in_prp0001 = 1
    }

    # Track _CRS section for GPIO
    in_prp0001 && /Name \(_CRS,/ { in_crs = 1 }
    # End _CRS on closing }) which marks end of ResourceTemplate
    in_prp0001 && in_crs && /^[[:space:]]*\}\)/ { in_crs = 0 }

    # Extract GPIO controller from GpioIo
    in_prp0001 && in_crs && /\\_SB\.GPI[0-9]/ {
        if (match($0, /\\_SB\.(GPI[0-9])/, arr)) {
            gpio_ctrl = arr[1]
        }
    }

    # Extract GPIO pin from pin list
    in_prp0001 && in_crs && /Pin list/ { in_pin_list = 1; next }
    in_prp0001 && in_pin_list && /0x[0-9A-Fa-f]+/ {
        if (match($0, /0x([0-9A-Fa-f]+)/, arr)) {
            gpio_pin = strtonum("0x" arr[1])
        }
        in_pin_list = 0
    }

    # Track _DSD section
    in_prp0001 && /Name \(_DSD,/ { in_dsd = 1 }

    # Extract compatible
    in_prp0001 && in_dsd && /"compatible",/ { wait_value = "compatible"; next }
    in_prp0001 && in_dsd && wait_value == "compatible" {
        if (match($0, /"([a-z][a-z0-9-]*)"/, arr)) {
            compatible = arr[1]
            wait_value = ""
        }
    }

    # Extract regulator-name
    in_prp0001 && in_dsd && /"regulator-name",/ { wait_value = "reg_name"; next }
    in_prp0001 && in_dsd && wait_value == "reg_name" {
        if (match($0, /"([^"]+)"/, arr)) {
            reg_name = arr[1]
            wait_value = ""
        }
    }

    # Extract regulator voltage
    in_prp0001 && in_dsd && /"regulator-min-microvolt",/ { wait_value = "voltage"; next }
    in_prp0001 && in_dsd && wait_value == "voltage" {
        if (match($0, /0x([0-9A-Fa-f]+)/, arr)) {
            voltage = strtonum("0x" arr[1])
            wait_value = ""
        } else if (match($0, /([0-9]+)/, arr)) {
            voltage = arr[1]
            wait_value = ""
        }
    }

    # Check for regulator-always-on
    in_prp0001 && in_dsd && /"regulator-always-on"/ {
        always_on = 1
    }

    END {
        # Output last device
        if (in_prp0001 && compatible != "") {
            if (compatible == "regulator-fixed" && reg_name != "") {
                printf "REG|%s|%s|%s|%s|%s\n", reg_name, gpio_ctrl, gpio_pin, voltage, always_on
            } else if (compatible == "gpio-leds") {
                printf "LEDS|%s|%s|%s\n", device, gpio_ctrl, gpio_pin
            }
        }
    }
    ' "$ssdt_file")

    # Parse results into associative arrays
    local reg_count=0 led_count=0
    while IFS='|' read -r type val1 val2 val3 val4 val5; do
        [[ -z "$type" ]] && continue
        case "$type" in
            REG)
                SSDT_REGULATORS["$val1"]="${val2}|${val3}|${val4}|${val5}"
                ((reg_count++)) || true
                ;;
            LEDS)
                # For LEDs we need to parse individual LED entries separately
                ((led_count++)) || true
                ;;
        esac
    done <<< "$result"

    log "  Found $reg_count regulators, $led_count LED devices"
}

# Extract ACPI0011 (Generic Buttons) and individual LED entries
extract_buttons_and_leds() {
    local ssdt_file="$1"

    [[ -f "$ssdt_file" ]] || return 0

    # Check for ACPI0011 (gpio-keys) device
    if grep -q '_HID.*ACPI0011' "$ssdt_file" 2>/dev/null; then
        log "  Found ACPI0011 (GPIO buttons) device"
        # Extract button GPIO from GpioInt resource
        local btn_info
        btn_info=$(gawk '
        /_HID,.*ACPI0011/ { in_btns = 1; in_crs = 0 }
        in_btns && /^[[:space:]]*Device \(/ { in_btns = 0 }
        in_btns && /_CRS,/ { in_crs = 1 }
        in_btns && in_crs && /^[[:space:]]*\}\)/ { in_crs = 0 }
        in_btns && in_crs && /GPI[0-9]/ {
            if (match($0, /(GPI[0-9])/, arr)) gpio_ctrl = arr[1]
        }
        in_btns && in_crs && /Pin list/ { in_pin = 1; next }
        in_btns && in_crs && in_pin && /0x[0-9A-Fa-f]+/ {
            if (match($0, /0x([0-9A-Fa-f]+)/, arr)) {
                printf "%s|%s\n", gpio_ctrl, strtonum("0x" arr[1])
            }
            in_pin = 0
        }
        ' "$ssdt_file" | head -1)

        if [[ -n "$btn_info" ]]; then
            SSDT_BUTTONS["power"]="$btn_info|116"  # KEY_POWER = 116
        fi
    fi

    # Extract individual LED entries from LEDS device with full GPIO info
    local led_result
    led_result=$(gawk '
    BEGIN { in_leds = 0; res_count = 0 }
    /Device \(LEDS\)/ { in_leds = 1; in_crs = 0; next }
    in_leds && /Device \([A-Z0-9]+\)/ && !/Device \(LEDS\)/ { in_leds = 0 }

    # Track _CRS section
    in_leds && /Name \(_CRS,/ { in_crs = 1 }
    in_leds && in_crs && /^[[:space:]]*\}\)/ { in_crs = 0 }

    # Collect GPIO resources - each GpioIo can have multiple pins
    in_leds && in_crs && /\\_SB\.GPI[0-9]/ {
        if (match($0, /\\_SB\.(GPI[0-9])/, arr)) current_ctrl = arr[1]
    }
    in_leds && in_crs && /Pin list/ { in_pin_list = 1; next }
    in_leds && in_crs && in_pin_list {
        while (match($0, /0x([0-9A-Fa-f]+)/, arr)) {
            gpio_res[res_count] = current_ctrl
            gpio_pin[res_count] = strtonum("0x" arr[1])
            res_count++
            $0 = substr($0, RSTART + RLENGTH)
        }
        if (/\}/) in_pin_list = 0
    }

    # Match LED definitions
    in_leds && /Name \(LED[0-9],/ {
        led_idx = ""; led_label = ""; led_trigger = ""; led_active = 0
        if (match($0, /Name \(LED([0-9])/, arr)) led_idx = arr[1]
    }
    in_leds && led_idx != "" && /"label",/ { getline; if (match($0, /"([^"]+)"/, arr)) led_label = arr[1] }
    in_leds && led_idx != "" && /"linux,default-trigger",/ { getline; if (match($0, /"([^"]+)"/, arr)) led_trigger = arr[1] }

    # Parse gpios package: {^LEDS, res_idx, pin_idx, active_level}
    in_leds && led_idx != "" && /"gpios",/ {
        getline; getline; getline  # Skip Package, {, ^LEDS
        getline; res_idx = (/One/ ? 1 : 0)
        getline; pin_in_res = (/One/ ? 1 : 0)
        getline; led_active = (/One/ ? 0 : 1)

        # Calculate actual GPIO index from resource index + pin offset
        actual_idx = 0
        cnt = 0
        for (j = 0; j < res_count; j++) {
            if (cnt == res_idx) { actual_idx = j + pin_in_res; break }
            if (j+1 < res_count && gpio_res[j+1] != gpio_res[j]) cnt++
            else if (j+1 >= res_count) cnt++
        }

        if (led_label != "" && actual_idx < res_count) {
            printf "LED|%s|%s|%d|%s|%d\n", led_label, gpio_res[actual_idx], gpio_pin[actual_idx], led_trigger, led_active
        }
        led_idx = ""
    }
    ' "$ssdt_file")

    while IFS='|' read -r type label ctrl pin trigger active; do
        [[ "$type" == "LED" && -n "$label" ]] && SSDT_LEDS["$label"]="${ctrl}|${pin}|${trigger}|${active}"
    done <<< "$led_result"
}

#############################################################################
# DTS Generator Functions
#############################################################################

generate_dts_header() {
    local board_model="$1"
    local board_compat="$2"

    cat << 'EOF'
// SPDX-License-Identifier: (GPL-2.0-only OR MIT)
/*
EOF
    cat << EOF
 * Device Tree Source for $board_model
 *
 * Auto-generated from ACPI DSDT by acpi-to-dts.sh
 * Generated: $(date -Iseconds)
 *
 * This file was created from hardware extraction data.
 * Manual review and adjustment is required before use.
 *
 * Preprocessing required (from kernel source directory):
 *   cpp -nostdinc -I include -undef -x assembler-with-cpp \\
 *       board.dts | dtc -I dts -O dtb -o board.dtb -
 */

/dts-v1/;

#include <dt-bindings/interrupt-controller/arm-gic.h>

/ {
	#address-cells = <2>;
	#size-cells = <2>;
	model = "$board_model";
	compatible = "$board_compat", "cix,sky1";
	interrupt-parent = <&gic>;

	aliases {
		serial0 = &uart0;
		serial1 = &uart1;
		serial2 = &uart2;
		serial3 = &uart3;
		i2c0 = &i2c0;
		i2c1 = &i2c1;
		i2c2 = &i2c2;
		i2c3 = &i2c3;
		i2c4 = &i2c4;
		i2c5 = &i2c5;
		i2c6 = &i2c6;
	};

	chosen {
		stdout-path = "serial2:115200n8";
	};

	memory@80000000 {
		device_type = "memory";
		/* Memory size populated by bootloader */
		reg = <0x0 0x80000000 0x4 0x00000000>;  /* 16GB max */
	};

	cpus {
		#address-cells = <2>;
		#size-cells = <0>;

		/* CPU topology from ACPI PPTT:
		 * 4x Cortex-A720 (big cores) + 8x Cortex-A520 (little cores)
		 * big.LITTLE configuration
		 */
EOF
}

# Generate CPU nodes
generate_cpu_nodes() {
    local system_info="$1"

    # Parse CPU info from extraction
    local core_count=$(grep -oE "Cores: [0-9]+" "$system_info" 2>/dev/null | grep -oE "[0-9]+" || echo "12")

    for ((i=0; i<core_count; i++)); do
        local cpu_type="cortex-a520"
        [[ $i -lt 4 ]] && cpu_type="cortex-a720"

        cat << EOF

		cpu$i: cpu@$i {
			device_type = "cpu";
			compatible = "arm,$cpu_type";
			reg = <0x0 0x$i>;
			enable-method = "psci";
		};
EOF
    done

    cat << 'EOF'
	};

	psci {
		compatible = "arm,psci-1.0";
		method = "smc";
	};

	timer {
		compatible = "arm,armv8-timer";
		interrupts = <GIC_PPI 13 IRQ_TYPE_LEVEL_LOW>,
			     <GIC_PPI 14 IRQ_TYPE_LEVEL_LOW>,
			     <GIC_PPI 11 IRQ_TYPE_LEVEL_LOW>,
			     <GIC_PPI 10 IRQ_TYPE_LEVEL_LOW>;
	};
EOF
}

# Generate GIC node
generate_gic_node() {
    cat << 'EOF'

	gic: interrupt-controller@30000000 {
		compatible = "arm,gic-v3";
		#interrupt-cells = <3>;
		interrupt-controller;
		reg = <0x0 0x30000000 0x0 0x10000>,  /* GICD */
		      <0x0 0x30080000 0x0 0x200000>; /* GICR */
		interrupts = <GIC_PPI 9 IRQ_TYPE_LEVEL_LOW>;
	};
EOF
}

# Generate SoC node with all peripherals
generate_soc_node() {
    local devices_file="$1"
    local extraction_dir="$2"

    cat << 'EOF'

	soc@0 {
		compatible = "simple-bus";
		#address-cells = <2>;
		#size-cells = <2>;
		ranges;
		dma-ranges;
EOF

    # Generate I2C controllers
    generate_i2c_controllers "$devices_file" "$extraction_dir"

    # Generate UART controllers
    generate_uart_controllers "$devices_file"

    # Generate GPIO controllers
    generate_gpio_controllers "$devices_file"

    # Generate USB controllers
    generate_usb_controllers "$devices_file"

    # Generate PCIe controllers
    generate_pcie_controllers "$devices_file"

    # Generate Display controllers
    generate_display_controllers "$devices_file"

    # Generate other peripherals
    generate_misc_peripherals "$devices_file"

    cat << 'EOF'
	}; /* end soc@0 */
EOF
}

generate_i2c_controllers() {
    local devices_file="$1"
    local extraction_dir="$2"

    echo ""
    echo "		/* I2C Controllers */"

    # Parse I2C devices detected
    local i2c_devices_file=$(mktemp)
    if [[ -f "$extraction_dir/06-i2c.txt" ]]; then
        parse_i2c_devices "$extraction_dir/06-i2c.txt" > "$i2c_devices_file"
    fi

    grep "CIXH200B" "$devices_file" 2>/dev/null | sort -t'|' -k3,3n | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        local irq_spi=$(irq_to_spi "$irq")
        local dev_name="I2C$uid"

        # Extract clock info
        local clk_info="${DEVICE_CLOCKS[$dev_name]:-}"
        local clk_id="" clk_name=""
        if [[ -n "$clk_info" ]]; then
            clk_id="${clk_info%%:*}"
            clk_name="${clk_info#*:}"
        fi

        # Extract reset info
        local rst_info="${DEVICE_RESETS[$dev_name]:-}"
        local rst_ctrl="" rst_id="" rst_name=""
        if [[ -n "$rst_info" ]]; then
            rst_ctrl="${rst_info%%:*}"
            local rest="${rst_info#*:}"
            rst_id="${rest%%:*}"
            rst_name="${rest#*:}"
        fi

        # Extract pinctrl
        local pinctrl="${DEVICE_PINCTRL[$dev_name]:-}"

        # Extract clock-frequency from DSD
        local dsd="${DEVICE_DSD[$dev_name]:-}"
        local clock_freq="400000"  # default
        if [[ "$dsd" =~ clock-frequency=([0-9]+) ]]; then
            clock_freq="${BASH_REMATCH[1]}"
        fi

        cat << EOF

		i2c$uid: i2c@$addr {
			compatible = "cdns,i2c-r1p14";
			reg = <0x0 0x$addr 0x0 0x$size>;
			interrupts = <GIC_SPI $irq_spi IRQ_TYPE_LEVEL_HIGH>;
EOF

        # Add clock reference if available
        if [[ -n "$clk_id" ]]; then
            echo "			clocks = <&cru $clk_id>;"
            if [[ -n "$clk_name" ]]; then
                echo "			clock-names = \"$clk_name\";"
            fi
        fi

        # Add reset reference if available
        if [[ -n "$rst_id" ]]; then
            local rst_phandle="rst0"
            [[ "$rst_ctrl" == "RST1" ]] && rst_phandle="rst1"
            echo "			resets = <&$rst_phandle $rst_id>;"
            if [[ -n "$rst_name" ]]; then
                echo "			reset-names = \"$rst_name\";"
            fi
        fi

        # Add pinctrl reference if available
        if [[ -n "$pinctrl" ]]; then
            local pin_group="${pinctrl%%,*}"  # take first group
            echo "			pinctrl-names = \"default\";"
            echo "			pinctrl-0 = <&$pin_group>;"
        fi

        cat << EOF
			#address-cells = <1>;
			#size-cells = <0>;
			clock-frequency = <$clock_freq>;
			status = "okay";
EOF

        # Add detected I2C devices
        grep "^$uid|" "$i2c_devices_file" 2>/dev/null | while IFS='|' read -r bus dev_addr; do
            cat << EOF

			/* Device at $dev_addr detected by i2cdetect */
			device@${dev_addr#0x} {
				reg = <$dev_addr>;
				/* TODO: identify device and add compatible */
			};
EOF
        done

        cat << 'EOF'
		};
EOF
    done

    rm -f "$i2c_devices_file"
}

generate_uart_controllers() {
    local devices_file="$1"

    echo ""
    echo "		/* UART Controllers (ARM PL011) */"

    grep "ARMH0011" "$devices_file" 2>/dev/null | sort -t'|' -k3,3n | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        local irq_spi=$(irq_to_spi "$irq")
        local dev_name="COM$((uid-1))"  # COM0 has UID=1, COM1 has UID=2, etc.

        # Map UID to uart name: UID=1→uart0, UID=2→uart1, UID=3→uart2 (console)
        local uart_idx=$((uid-1))
        local uart_name="uart$uart_idx"
        local status="disabled"
        [[ $uid -eq 3 ]] && status="okay"  # uart2 (COM2/UID3) is console

        # Extract clock info (UARTs typically have 2 clocks)
        local clk_info="${DEVICE_CLOCKS[$dev_name]:-}"
        local clk_id=""
        if [[ -n "$clk_info" ]]; then
            clk_id="${clk_info%%:*}"
        fi

        # Extract reset info
        local rst_info="${DEVICE_RESETS[$dev_name]:-}"
        local rst_ctrl="" rst_id="" rst_name=""
        if [[ -n "$rst_info" ]]; then
            rst_ctrl="${rst_info%%:*}"
            local rest="${rst_info#*:}"
            rst_id="${rest%%:*}"
            rst_name="${rest#*:}"
        fi

        # Extract pinctrl
        local pinctrl="${DEVICE_PINCTRL[$dev_name]:-}"

        cat << EOF

		$uart_name: serial@$addr {
			compatible = "arm,pl011", "arm,primecell";
			reg = <0x0 0x$addr 0x0 0x$size>;
			interrupts = <GIC_SPI $irq_spi IRQ_TYPE_LEVEL_HIGH>;
EOF

        # Add clock reference if available
        if [[ -n "$clk_id" ]]; then
            echo "			clocks = <&cru $clk_id>, <&cru $clk_id>;"
            echo "			clock-names = \"uartclk\", \"apb_pclk\";"
        else
            echo "			clocks = <&clk_uart>, <&clk_uart>;"
            echo "			clock-names = \"uartclk\", \"apb_pclk\";"
        fi

        # Add reset reference if available
        if [[ -n "$rst_id" ]]; then
            local rst_phandle="rst0"
            [[ "$rst_ctrl" == "RST1" ]] && rst_phandle="rst1"
            echo "			resets = <&$rst_phandle $rst_id>;"
            if [[ -n "$rst_name" ]]; then
                echo "			reset-names = \"$rst_name\";"
            fi
        fi

        # Add pinctrl reference if available
        if [[ -n "$pinctrl" ]]; then
            local pin_group="${pinctrl%%,*}"
            echo "			pinctrl-names = \"default\";"
            echo "			pinctrl-0 = <&$pin_group>;"
        fi

        cat << EOF
			status = "$status";
		};
EOF
    done
}

generate_gpio_controllers() {
    local devices_file="$1"

    echo ""
    echo "		/* GPIO Controllers */"

    # Main GPIO (CIXH1003)
    grep "CIXH1003" "$devices_file" 2>/dev/null | sort -t'|' -k3,3n | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        local irq_spi=$(irq_to_spi "$irq")
        local dev_name="GPI$uid"

        # Extract clock info
        local clk_info="${DEVICE_CLOCKS[$dev_name]:-}"
        local clk_id=""
        if [[ -n "$clk_info" ]]; then
            clk_id="${clk_info%%:*}"
        fi

        # Extract reset info
        local rst_info="${DEVICE_RESETS[$dev_name]:-}"
        local rst_ctrl="" rst_id="" rst_name=""
        if [[ -n "$rst_info" ]]; then
            rst_ctrl="${rst_info%%:*}"
            local rest="${rst_info#*:}"
            rst_id="${rest%%:*}"
            rst_name="${rest#*:}"
        fi

        cat << EOF

		gpio$uid: gpio@$addr {
			compatible = "cix,sky1-gpio";
			reg = <0x0 0x$addr 0x0 0x$size>;
			interrupts = <GIC_SPI $irq_spi IRQ_TYPE_LEVEL_HIGH>;
EOF

        if [[ -n "$clk_id" ]]; then
            echo "			clocks = <&cru $clk_id>;"
        fi

        if [[ -n "$rst_id" ]]; then
            local rst_phandle="rst0"
            [[ "$rst_ctrl" == "RST1" ]] && rst_phandle="rst1"
            echo "			resets = <&$rst_phandle $rst_id>;"
            if [[ -n "$rst_name" ]]; then
                echo "			reset-names = \"$rst_name\";"
            fi
        fi

        cat << EOF
			gpio-controller;
			#gpio-cells = <2>;
			interrupt-controller;
			#interrupt-cells = <2>;
			status = "okay";
		};
EOF
    done

    # S5 domain GPIO (CIXH1002)
    grep "CIXH1002" "$devices_file" 2>/dev/null | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        local irq_spi=$(irq_to_spi "$irq")
        local dev_name="GP5$uid"  # S5 domain

        # Extract reset info
        local rst_info="${DEVICE_RESETS[$dev_name]:-}"
        local rst_ctrl="" rst_id="" rst_name=""
        if [[ -n "$rst_info" ]]; then
            rst_ctrl="${rst_info%%:*}"
            local rest="${rst_info#*:}"
            rst_id="${rest%%:*}"
            rst_name="${rest#*:}"
        fi

        cat << EOF

		gpio_s5_$uid: gpio@$addr {
			compatible = "cix,sky1-gpio";
			reg = <0x0 0x$addr 0x0 0x$size>;
			interrupts = <GIC_SPI $irq_spi IRQ_TYPE_LEVEL_HIGH>;
EOF

        if [[ -n "$rst_id" ]]; then
            local rst_phandle="rst0"
            [[ "$rst_ctrl" == "RST1" ]] && rst_phandle="rst1"
            echo "			resets = <&$rst_phandle $rst_id>;"
        fi

        cat << EOF
			gpio-controller;
			#gpio-cells = <2>;
			status = "okay";
		};
EOF
    done
}

generate_usb_controllers() {
    local devices_file="$1"

    echo ""
    echo "		/* USB Controllers (Synopsys DWC3) */"

    grep "CIXH5010" "$devices_file" 2>/dev/null | sort -t'|' -k3,3n | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        local irq_spi=$(irq_to_spi "$irq")

        cat << EOF

		usb$uid: usb@$addr {
			compatible = "cix,sky1-dwc3";
			reg = <0x0 0x$addr 0x0 0x$size>;
			interrupts = <GIC_SPI $irq_spi IRQ_TYPE_LEVEL_HIGH>;
			dr_mode = "host";
			snps,dis_u2_susphy_quirk;
			snps,dis_u3_susphy_quirk;
			status = "okay";
		};
EOF
    done
}

generate_pcie_controllers() {
    local devices_file="$1"

    echo ""
    echo "		/* PCIe Controllers */"

    grep "CIXH2020" "$devices_file" 2>/dev/null | sort -t'|' -k3,3n | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        local irq_spi=$(irq_to_spi "$irq")

        cat << EOF

		pcie$uid: pcie@$addr {
			compatible = "cix,sky1-pcie";
			reg = <0x0 0x$addr 0x0 0x$size>;
			interrupts = <GIC_SPI $irq_spi IRQ_TYPE_LEVEL_HIGH>;
			#address-cells = <3>;
			#size-cells = <2>;
			device_type = "pci";
			bus-range = <0x0 0xff>;
			num-lanes = <1>;  /* Adjust based on slot */
			status = "okay";
		};
EOF
    done
}

generate_display_controllers() {
    local devices_file="$1"

    echo ""
    echo "		/* Display Controllers */"

    # DisplayPort controllers
    grep "CIXH502F" "$devices_file" 2>/dev/null | sort -t'|' -k3,3n | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        local irq_spi=$(irq_to_spi "$irq")

        cat << EOF

		dp$uid: dp@$addr {
			compatible = "cix,linlon-dp";
			reg = <0x0 0x$addr 0x0 0x$size>;
			interrupts = <GIC_SPI $irq_spi IRQ_TYPE_LEVEL_HIGH>;
			status = "okay";
		};
EOF
    done
}

generate_misc_peripherals() {
    local devices_file="$1"

    echo ""
    echo "		/* Miscellaneous Peripherals */"

    # Watchdog
    grep "CIXH2001" "$devices_file" 2>/dev/null | head -1 | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        local irq_spi=$(irq_to_spi "$irq")

        cat << EOF

		watchdog: watchdog@$addr {
			compatible = "cix,sky1-wdt";
			reg = <0x0 0x$addr 0x0 0x$size>;
			interrupts = <GIC_SPI $irq_spi IRQ_TYPE_LEVEL_HIGH>;
			status = "disabled";
		};
EOF
    done

    # Thermal
    grep "CIXH6000" "$devices_file" 2>/dev/null | head -1 | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        cat << EOF

		thermal: thermal@$addr {
			compatible = "cix,sky1-thermal";
			reg = <0x0 0x$addr 0x0 0x$size>;
			#thermal-sensor-cells = <1>;
			status = "okay";
		};
EOF
    done

    # GPU
    grep "CIXH4000" "$devices_file" 2>/dev/null | head -1 | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        local irq_spi=$(irq_to_spi "$irq")

        cat << EOF

		gpu: gpu@$addr {
			compatible = "arm,mali-valhall-csf";
			reg = <0x0 0x$addr 0x0 0x$size>;
			interrupts = <GIC_SPI $irq_spi IRQ_TYPE_LEVEL_HIGH>;
			status = "okay";
		};
EOF
    done

    # GMAC / Ethernet MAC controllers with PHY child nodes
    grep "CIXH7020" "$devices_file" 2>/dev/null | sort -t'|' -k3,3n | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        local irq_spi=$(irq_to_spi "$irq")
        local gmac_idx=$((uid))
        local gmac_name="gmac${gmac_idx}"
        local dev_name="MAC${uid}"

        # Get DSD properties (phy-mode, etc.)
        local dsd="${DEVICE_DSD[$dev_name]:-}"
        local phy_mode="rgmii-id"
        if [[ "$dsd" =~ phy-mode=([^,]+) ]]; then
            phy_mode="${BASH_REMATCH[1]}"
        fi

        # Get pinctrl
        local pinctrl="${DEVICE_PINCTRL[$dev_name]:-}"

        # Get GPIO (reset)
        local gpio="${DEVICE_GPIO[$dev_name]:-}"

        # Get child PHY device
        local children="${DEVICE_CHILDREN[$dev_name]:-}"
        local phy_addr=""
        local phy_compat=""
        if [[ -n "$children" ]]; then
            local child_name="${children%%:*}"
            phy_addr="${children#*:}"
            phy_addr="${phy_addr%%,*}"
            local child_dsd="${CHILD_DEVICE_DSD[${dev_name}_${child_name}]:-}"
            if [[ "$child_dsd" =~ compatible=([^,]+) ]]; then
                phy_compat="${BASH_REMATCH[1]}"
            fi
        fi

        cat << EOF

		$gmac_name: ethernet@$addr {
			compatible = "cix,sky1-gmac";
			reg = <0x0 0x$addr 0x0 0x$size>;
			interrupts = <GIC_SPI $irq_spi IRQ_TYPE_LEVEL_HIGH>;
EOF
        if [[ -n "$pinctrl" ]]; then
            echo "			pinctrl-names = \"default\";"
            echo "			pinctrl-0 = <&${pinctrl}>;"
        fi
        echo "			phy-mode = \"$phy_mode\";"
        if [[ -n "$phy_addr" ]]; then
            echo "			phy-handle = <&phy${gmac_idx}>;"
        fi
        echo "			status = \"disabled\";"

        # Add MDIO bus with PHY child
        if [[ -n "$phy_addr" && -n "$phy_compat" ]]; then
            cat << EOF

			mdio {
				compatible = "snps,dwmac-mdio";
				#address-cells = <1>;
				#size-cells = <0>;

				phy${gmac_idx}: ethernet-phy@${phy_addr} {
					compatible = "$phy_compat";
					reg = <${phy_addr}>;
				};
			};
EOF
        fi
        echo "		};"
    done
}

# Generate fixed regulators from SSDT PRP0001 devices
generate_regulators_from_ssdt() {
    [[ ${#SSDT_REGULATORS[@]} -eq 0 ]] && return

    echo ""
    echo "	/* Fixed Regulators (from ACPI SSDT) */"

    for reg_name in "${!SSDT_REGULATORS[@]}"; do
        local data="${SSDT_REGULATORS[$reg_name]}"
        local gpio_ctrl gpio_pin voltage always_on
        IFS='|' read -r gpio_ctrl gpio_pin voltage always_on <<< "$data"

        # Convert GPI0-6 to proper phandle names
        local gpio_phandle=""
        case "$gpio_ctrl" in
            GPI0) gpio_phandle="fch_gpio0" ;;
            GPI1) gpio_phandle="fch_gpio1" ;;
            GPI2) gpio_phandle="fch_gpio2" ;;
            GPI3) gpio_phandle="fch_gpio3" ;;
            GPI4) gpio_phandle="s5_gpio0" ;;
            GPI5) gpio_phandle="s5_gpio2" ;;
            GPI6) gpio_phandle="s5_gpio1" ;;
            *) gpio_phandle="$gpio_ctrl" ;;
        esac

        # Sanitize regulator name for node name
        local node_name="${reg_name//-/_}"
        node_name="${node_name// /_}"

        cat << EOF

	${node_name}: regulator-${node_name} {
		compatible = "regulator-fixed";
		regulator-name = "${reg_name}";
EOF
        if [[ -n "$voltage" && "$voltage" != "0" ]]; then
            cat << EOF
		regulator-min-microvolt = <${voltage}>;
		regulator-max-microvolt = <${voltage}>;
EOF
        fi

        if [[ -n "$gpio_phandle" && -n "$gpio_pin" && "$gpio_pin" != "0" ]]; then
            cat << EOF
		gpio = <&${gpio_phandle} ${gpio_pin} GPIO_ACTIVE_HIGH>;
		enable-active-high;
EOF
        fi

        if [[ "$always_on" == "1" ]]; then
            echo "		regulator-always-on;"
        fi

        echo "	};"
    done
}

# Generate GPIO keys from SSDT ACPI0011 device
generate_gpio_keys_from_ssdt() {
    [[ ${#SSDT_BUTTONS[@]} -eq 0 ]] && return

    echo ""
    echo "	/* GPIO Keys (from ACPI SSDT) */"
    echo "	gpio-keys {"
    echo "		compatible = \"gpio-keys\";"

    for btn_name in "${!SSDT_BUTTONS[@]}"; do
        local data="${SSDT_BUTTONS[$btn_name]}"
        local gpio_ctrl gpio_pin linux_code
        IFS='|' read -r gpio_ctrl gpio_pin linux_code <<< "$data"

        # Convert GPI to phandle
        local gpio_phandle=""
        case "$gpio_ctrl" in
            GPI0) gpio_phandle="fch_gpio0" ;;
            GPI1) gpio_phandle="fch_gpio1" ;;
            GPI2) gpio_phandle="fch_gpio2" ;;
            GPI3) gpio_phandle="fch_gpio3" ;;
            GPI4) gpio_phandle="s5_gpio0" ;;
            GPI5) gpio_phandle="s5_gpio2" ;;
            GPI6) gpio_phandle="s5_gpio1" ;;
            *) gpio_phandle="$gpio_ctrl" ;;
        esac

        cat << EOF

		button-${btn_name} {
			label = "${btn_name}";
			linux,code = <${linux_code}>;
			gpios = <&${gpio_phandle} ${gpio_pin} GPIO_ACTIVE_LOW>;
			wakeup-source;
		};
EOF
    done
    echo "	};"
}

# Generate GPIO LEDs from SSDT
generate_gpio_leds_from_ssdt() {
    [[ ${#SSDT_LEDS[@]} -eq 0 ]] && return

    echo ""
    echo "	/* GPIO LEDs (from ACPI SSDT) */"
    echo "	gpio-leds {"
    echo "		compatible = \"gpio-leds\";"

    for led_label in "${!SSDT_LEDS[@]}"; do
        local data="${SSDT_LEDS[$led_label]}"
        local gpio_ctrl gpio_pin trigger active_low
        IFS='|' read -r gpio_ctrl gpio_pin trigger active_low <<< "$data"

        # Convert GPIO controller to phandle (GPI4 -> s5_gpio0, GPI5 -> s5_gpio2, etc)
        local gpio_phandle=""
        case "$gpio_ctrl" in
            GPI0) gpio_phandle="fch_gpio0" ;;
            GPI1) gpio_phandle="fch_gpio1" ;;
            GPI2) gpio_phandle="fch_gpio2" ;;
            GPI3) gpio_phandle="fch_gpio3" ;;
            GPI4) gpio_phandle="s5_gpio0" ;;
            GPI5) gpio_phandle="s5_gpio2" ;;
            *) gpio_phandle="gpio" ;;
        esac

        local active_flag
        if [[ "$active_low" == "1" ]]; then
            active_flag="GPIO_ACTIVE_LOW"
        else
            active_flag="GPIO_ACTIVE_HIGH"
        fi

        # Sanitize label for node name
        local node_name="${led_label//[:]/_}"
        node_name="${node_name//[ ]/_}"

        cat << EOF

		led-${node_name} {
			label = "${led_label}";
			gpios = <&${gpio_phandle} ${gpio_pin} ${active_flag}>;
EOF
        [[ -n "$trigger" && "$trigger" != "none" ]] && echo "			linux,default-trigger = \"${trigger}\";"
        echo "		};"
    done
    echo "	};"
}

# Legacy: Generate fixed regulators from extraction file
generate_regulators() {
    local regulator_file="$1"

    # First output SSDT-extracted regulators
    generate_regulators_from_ssdt

    # Then add any from the extraction file that aren't in SSDT
    [[ ! -f "$regulator_file" ]] && return

    # Only add from file if no SSDT regulators found
    [[ ${#SSDT_REGULATORS[@]} -gt 0 ]] && return

    echo ""
    echo "	/* Fixed Regulators (from runtime extraction) */"

    grep -E "^[a-z_0-9-]+:" "$regulator_file" 2>/dev/null | head -20 | while read -r line; do
        local name=$(echo "$line" | cut -d: -f1 | tr '-' '_')
        local voltage=$(grep -A2 "^${name//_/-}:" "$regulator_file" | grep -oE "[0-9]+mV" | head -1)

        [[ -z "$voltage" ]] && continue
        local uv=$((${voltage%mV} * 1000))

        cat << EOF

	reg_$name: regulator-$name {
		compatible = "regulator-fixed";
		regulator-name = "$name";
		regulator-min-microvolt = <$uv>;
		regulator-max-microvolt = <$uv>;
		regulator-always-on;
	};
EOF
    done
}

# Generate panel and backlight nodes from ACPI EDP0 and DPBL devices
generate_panel_backlight() {
    local devices_file="$1"

    # Check if we have EDP0 (panel) and DPBL (backlight)
    local edp_gpio="${DEVICE_GPIO[EDP0]:-}"
    local edp_dsd="${DEVICE_DSD[EDP0]:-}"
    local edp_pinctrl="${DEVICE_PINCTRL[EDP0]:-}"

    local bl_gpio="${DEVICE_GPIO[DPBL]:-}"
    local bl_dsd="${DEVICE_DSD[DPBL]:-}"

    # Generate backlight node if DPBL exists
    if [[ -n "$bl_gpio" || -n "$bl_dsd" ]]; then
        echo ""
        echo "	/* PWM Backlight */"

        # Parse GPIO: GPI3:15 -> fch_gpio3, pin 15
        local bl_gpio_ctrl=""
        local bl_gpio_pin=""
        if [[ "$bl_gpio" =~ ^GPI([0-9]):([0-9]+) ]]; then
            local gpio_num="${BASH_REMATCH[1]}"
            bl_gpio_pin="${BASH_REMATCH[2]}"
            bl_gpio_ctrl="fch_gpio${gpio_num}"
        fi

        # Parse default brightness from DSD
        local default_brightness="200"
        if [[ "$bl_dsd" =~ default-brightness-level=([0-9]+) ]]; then
            default_brightness="${BASH_REMATCH[1]}"
        fi

        cat << EOF

	backlight: backlight {
		compatible = "pwm-backlight";
		pwms = <&pwm0 0 100000>;
		brightness-levels = <0 4 8 16 32 64 128 255>;
		default-brightness-level = <6>;
EOF
        if [[ -n "$bl_gpio_ctrl" ]]; then
            echo "		enable-gpios = <&${bl_gpio_ctrl} ${bl_gpio_pin} GPIO_ACTIVE_HIGH>;"
        fi
        cat << 'EOF'
		status = "disabled";
	};
EOF
    fi

    # Generate panel node if EDP0 exists
    if [[ -n "$edp_gpio" || -n "$edp_dsd" ]]; then
        echo ""
        echo "	/* eDP Panel */"

        # Parse timing delays from DSD
        local prepare_delay="120"
        local enable_delay="120"
        local unprepare_delay="500"
        local disable_delay="120"
        local width_mm="129"
        local height_mm="171"

        if [[ "$edp_dsd" =~ prepare-delay-ms=([0-9]+) ]]; then
            prepare_delay="${BASH_REMATCH[1]}"
        fi
        if [[ "$edp_dsd" =~ enable-delay-ms=([0-9]+) ]]; then
            enable_delay="${BASH_REMATCH[1]}"
        fi
        if [[ "$edp_dsd" =~ unprepare-delay-ms=([0-9]+) ]]; then
            unprepare_delay="${BASH_REMATCH[1]}"
        fi
        if [[ "$edp_dsd" =~ disable-delay-ms=([0-9]+) ]]; then
            disable_delay="${BASH_REMATCH[1]}"
        fi
        if [[ "$edp_dsd" =~ width-mm=([0-9]+) ]]; then
            width_mm="${BASH_REMATCH[1]}"
        fi
        if [[ "$edp_dsd" =~ height-mm=([0-9]+) ]]; then
            height_mm="${BASH_REMATCH[1]}"
        fi

        # Parse GPIO: GPI3:16 -> fch_gpio3, pin 16
        local edp_gpio_ctrl=""
        local edp_gpio_pin=""
        if [[ "$edp_gpio" =~ ^GPI([0-9]):([0-9]+) ]]; then
            local gpio_num="${BASH_REMATCH[1]}"
            edp_gpio_pin="${BASH_REMATCH[2]}"
            edp_gpio_ctrl="fch_gpio${gpio_num}"
        fi

        cat << EOF

	panel_edp: panel-edp {
		compatible = "panel-edp";
		prepare-delay-ms = <${prepare_delay}>;
		enable-delay-ms = <${enable_delay}>;
		unprepare-delay-ms = <${unprepare_delay}>;
		disable-delay-ms = <${disable_delay}>;
		width-mm = <${width_mm}>;
		height-mm = <${height_mm}>;
EOF
        if [[ -n "$edp_gpio_ctrl" ]]; then
            echo "		enable-gpios = <&${edp_gpio_ctrl} ${edp_gpio_pin} GPIO_ACTIVE_HIGH>;"
        fi
        if [[ -n "$bl_gpio" ]]; then
            echo "		backlight = <&backlight>;"
        fi
        if [[ -n "$edp_pinctrl" ]]; then
            echo "		pinctrl-names = \"default\";"
            echo "		pinctrl-0 = <&${edp_pinctrl}>;"
        fi
        cat << 'EOF'
		status = "disabled";
	};
EOF
    fi
}

# Generate placeholder clock node (fallback if CRU not found)
generate_clock_placeholder() {
    cat << 'EOF'

	/* Clock placeholder - replace with actual clock controller */
	clk_uart: clk_uart {
		compatible = "fixed-clock";
		#clock-cells = <0>;
		clock-frequency = <24000000>;
	};
EOF
}

# Generate CRU (Clock Reset Unit) and Reset controller nodes
generate_cru_and_reset_nodes() {
    local devices_file="$1"

    echo ""
    echo "	/* Clock and Reset Controllers */"

    # CRU - Clock Reset Unit - use CRU0 preferably (main clock controller)
    local cru_line
    cru_line=$(grep "CRU0|CIXHA018" "$devices_file" 2>/dev/null | head -1)
    [[ -z "$cru_line" ]] && cru_line=$(grep -E "CIXHA018|CIXHA010" "$devices_file" 2>/dev/null | head -1)

    if [[ -n "$cru_line" ]]; then
        IFS='|' read -r name hid uid addr size irq <<< "$cru_line"
        if [[ -n "$addr" && "$addr" != "00000000" ]]; then
            cat << EOF

	cru: clock-controller@$addr {
		compatible = "cix,sky1-cru";
		reg = <0x0 0x$addr 0x0 0x$size>;
		#clock-cells = <1>;
	};
EOF
        fi
    fi

    # Reset controller RST0 (S5 domain - CIXHA020)
    grep "CIXHA020" "$devices_file" 2>/dev/null | head -1 | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        cat << EOF

	rst0: reset-controller@$addr {
		compatible = "cix,sky1-reset";
		reg = <0x0 0x$addr 0x0 0x$size>;
		#reset-cells = <1>;
	};
EOF
    done

    # Reset controller RST1 (FCH domain - CIXHA021)
    grep "CIXHA021" "$devices_file" 2>/dev/null | head -1 | while IFS='|' read -r name hid uid addr size irq; do
        [[ -z "$addr" || "$addr" == "00000000" ]] && continue

        cat << EOF

	rst1: reset-controller@$addr {
		compatible = "cix,sky1-reset";
		reg = <0x0 0x$addr 0x0 0x$size>;
		#reset-cells = <1>;
	};
EOF
    done

    # Fallback clock if no CRU found
    if ! grep -qE "CIXHA018|CIXHA010" "$devices_file" 2>/dev/null; then
        generate_clock_placeholder
    fi
}

#############################################################################
# Main
#############################################################################

main() {
    check_extraction_dir "$EXTRACTION_DIR"

    local dsdt_file="$EXTRACTION_DIR/acpi/DSDT.dsl"
    local devices_tmp=$(mktemp)
    local all_acpi_files_tmp=$(mktemp)

    trap "rm -f $devices_tmp $all_acpi_files_tmp" EXIT

    # Extract devices from DSDT
    extract_dsdt_devices "$dsdt_file" "$devices_tmp"

    # Extract device properties (clocks, resets, pinctrl)
    extract_device_properties "$dsdt_file"

    # Also parse SSDT files for board-specific devices (regulators, LEDs, buttons)
    for ssdt_dsl in "$EXTRACTION_DIR/acpi/SSDT"*.dsl; do
        [[ -f "$ssdt_dsl" ]] || continue
        log "Parsing $(basename "$ssdt_dsl") for board-specific devices..."
        local ssdt_tmp=$(mktemp)
        extract_dsdt_devices "$ssdt_dsl" "$ssdt_tmp"
        local ssdt_count=$(wc -l < "$ssdt_tmp")
        if [[ $ssdt_count -gt 0 ]]; then
            cat "$ssdt_tmp" >> "$devices_tmp"
            log "  Found $ssdt_count additional devices in SSDT"
        fi
        # Also extract properties from SSDT
        extract_device_properties "$ssdt_dsl"

        # Extract PRP0001 devices (regulators, LEDs) from SSDT
        extract_prp0001_devices "$ssdt_dsl"
        extract_buttons_and_leds "$ssdt_dsl"

        rm -f "$ssdt_tmp"
    done

    log "Generating DTS to: $OUTPUT_DTS"

    # Determine board model from extraction
    local board_model="Radxa Orion O6"
    local board_compat="radxa,orion-o6"

    # Detect board variant from DMI Product Name
    if grep -qE "Product Name:.*O6N" "$EXTRACTION_DIR/01-system-info.txt" 2>/dev/null; then
        board_model="Radxa Orion O6N"
        board_compat="radxa,orion-o6n"
    fi

    {
        generate_dts_header "$board_model" "$board_compat"
        generate_cpu_nodes "$EXTRACTION_DIR/01-system-info.txt"
        generate_gic_node
        generate_cru_and_reset_nodes "$devices_tmp"
        generate_regulators "$EXTRACTION_DIR/12-regulators.txt"
        generate_gpio_keys_from_ssdt
        generate_gpio_leds_from_ssdt
        generate_panel_backlight "$devices_tmp"
        generate_soc_node "$devices_tmp" "$EXTRACTION_DIR"

        echo ""
        echo "}; /* end of root node */"

    } > "$OUTPUT_DTS"

    local line_count=$(wc -l < "$OUTPUT_DTS")
    log "Generated $line_count lines"
    log ""
    log "=== Summary ==="
    log "Board: $board_model"
    log "ACPI devices parsed: $(wc -l < "$devices_tmp")"
    log "Output file: $OUTPUT_DTS"
    log ""
    log "=== Device Summary ==="

    # Show summary by HID type
    echo "HID         | Count | Description"
    echo "------------|-------|---------------------------"
    cut -d'|' -f2 "$devices_tmp" | sort | uniq -c | sort -rn | while read -r count hid; do
        local desc="${ACPI_TO_DT_COMPAT[$hid]:-unknown}"
        printf "%-11s | %5d | %s\n" "$hid" "$count" "$desc"
    done

    log ""
    log "=== Extracted Properties ==="
    log "Clocks:  ${#DEVICE_CLOCKS[@]} devices with clock IDs"
    log "Resets:  ${#DEVICE_RESETS[@]} devices with reset IDs"
    log "Pinctrl: ${#DEVICE_PINCTRL[@]} devices with pinctrl groups"
    log "DSD:     ${#DEVICE_DSD[@]} devices with properties"

    log ""
    log "=== SSDT Board-Specific Devices ==="
    log "Regulators: ${#SSDT_REGULATORS[@]} fixed-regulator devices"
    log "Buttons:    ${#SSDT_BUTTONS[@]} GPIO key devices"
    log "LEDs:       ${#SSDT_LEDS[@]} GPIO LED devices"

    log ""
    log "Next steps:"
    log "  1. Review generated DTS for accuracy"
    log "  2. Verify interrupt numbers against GIC documentation"
    log "  3. Test compile: dtc -I dts -O dtb -o test.dtb $OUTPUT_DTS"
    if [[ -n "$REFERENCE_DTS" ]]; then
        log "  4. Compare with working DTS: diff $OUTPUT_DTS $REFERENCE_DTS"
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
