#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PYTHON="${PYTHON:-python3}"
TIMEOUT="${TIMEOUT:-30}"
BOOT_ARGS="${BOOT_ARGS:-}"

IBSS="${IBSS:-$ROOT/artifacts/ibss.yolodfu.bin}"
PONGO_CONTAINER="${PONGO_CONTAINER:-$ROOT/artifacts/pongo-container.bin}"
KPF="${KPF:-$ROOT/artifacts/checkra1n-kpf-pongo}"
RAMDISK="${RAMDISK:-$ROOT/artifacts/ramdisk.dmg}"
BINPACK="${BINPACK:-$ROOT/artifacts/binpack.dmg}"

SEND_PONGO="$ROOT/components/yolodfu/tools/send_pongo.py"
PONGOTERM="$ROOT/components/PongoOS/scripts/pongoterm"

die() { echo "error: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_file() { [[ -f "$1" ]] || die "missing artifact: $1 (run make artifacts)"; }

usb_has() {
    ioreg -p IOUSB -l 2>/dev/null |
        awk -v marker="$1" 'index($0, marker) { found = 1 } END { exit !found }'
}

wait_usb() {
    local marker="$1" label="$2" deadline=$((SECONDS + TIMEOUT))
    while (( SECONDS < deadline )); do
        usb_has "$marker" && return 0
        sleep 1
    done
    die "timed out waiting for $label"
}

need_cmd ioreg
need_cmd irecovery
need_cmd make
need_cmd "$PYTHON"
for file in "$IBSS" "$PONGO_CONTAINER" "$KPF" "$RAMDISK" "$BINPACK" \
            "$SEND_PONGO"; do
    need_file "$file"
done

query="$(irecovery -q 2>/dev/null || true)"
grep -Fq 'CPID: 0x8020' <<<"$query" || die "T8020 DFU device not found"
grep -Fq 'MODE: DFU' <<<"$query" || die "device is not in DFU mode"
grep -Fq 'PWND: usbliter8' <<<"$query" || \
    die "DFU is not pwned; run usbliter8 with the RP2350 and reconnect to this host"
unset query

if [[ ! -x "$PONGOTERM" ]]; then
    make -C "$ROOT/components/PongoOS/scripts" pongoterm
fi

echo '[1/4] Booting patched iBSS'
"$PYTHON" - "$IBSS" << 'PYEOF'
import sys, usb.core
DFU_DNLOAD, DFU_ABORT, CUSTOM_BOOT = 1, 4, 8

with open(sys.argv[1], "rb") as f:
    data = f.read()

dev = usb.core.find(idProduct=0x1227)
if not dev:
    raise SystemExit("no DFU device")

offset = 0
while offset < len(data):
    chunk = data[offset:offset + 0x800]
    dev.ctrl_transfer(0x21, DFU_DNLOAD, 0, 0, chunk, 1000)
    offset += len(chunk)
    print(f"\rsent - 0x{offset:x}", end="")
print()
dev.ctrl_transfer(0x21, DFU_DNLOAD, 0, 0, None, 100)

try:
    dev.ctrl_transfer(0x21, CUSTOM_BOOT, 0, 0, None, 100)
except usb.core.USBError:
    pass

try:
    dev.ctrl_transfer(0x21, DFU_ABORT, 0, 0, None, 100)
except usb.core.USBError:
    pass
PYEOF

wait_usb 'YOLO:checkra1n' yoloDFU
echo '       yoloDFU found'

echo '[2/4] Sending Pongo container'
"$PYTHON" "$SEND_PONGO" "$PONGO_CONTAINER"
wait_usb '"USB Product Name" = "PongoOS USB Device"' PongoOS
echo '       PongoOS found'

echo '[3/4] Loading KPF and jbinit artifacts'
{
    printf 'fuse lock\n'
    printf '/send %s\nmodload\npalera1n_flags 0x2\n' "$KPF"
    printf '/send %s\nramdisk\n' "$RAMDISK"
    printf '/send %s\noverlay\n' "$BINPACK"
    if [[ -n "$BOOT_ARGS" ]]; then
        printf 'xargs %s\n' "$BOOT_ARGS"
    else
        printf 'xargs\n'
    fi
    printf 'bootx\n'
} | "$PONGOTERM" &
term_pid=$!
trap 'kill "$term_pid" 2>/dev/null || true' EXIT

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
    if ! kill -0 "$term_pid" 2>/dev/null; then
        wait "$term_pid" 2>/dev/null || true
        die "pongoterm exited before bootx handoff"
    fi
    if ! usb_has '"USB Product Name" = "PongoOS USB Device"'; then
        echo '[4/4] bootx sent; PongoOS USB disconnected'
        kill "$term_pid" 2>/dev/null || true
        wait "$term_pid" 2>/dev/null || true
        trap - EXIT
        echo ''
        echo '  Apple TV is booting jailbroken tvOS'
        echo '  palera1n Loader should appear on screen'
        echo ''
        echo '  After bootstrap, connect via SSH:'
        echo '    ssh root@<apple-tv-ip>  (password: alpine)'
        exit 0
    fi
    sleep 1
done

die "PongoOS did not leave USB after bootx"
