#!/bin/bash
# Creates a KVM/libvirt virtual machine on a Debian host, interactively.
#
# - vCPU count asked (default 4, or fewer if the host has fewer; up to the host's logical processors);
#   CPU model host-passthrough (nested virtualization works if the host allows it);
# - memory size (static), number of disks and their sizes are asked;
# - disks are thin qcow2: <VMName>.qcow2 (system), <VMName>-Data.qcow2, <VMName>-Data2.qcow2, ...;
#   all stored in <Folder>/<VMName>/;
# - UEFI firmware (q35); Secure Boot on request (off by default; Microsoft keys enrolled, for Windows and Linux);
# - virtual TPM 2.0 on request (off by default; needs swtpm);
# - guest OS type: Linux (virtio disks and network) or Windows (SATA disks, e1000e network, no extra drivers);
# - network: a host bridge (e.g. br0) or a libvirt network, or not connected;
# - static MAC address 52:54:00:xx:xx:xx, unique among VMs on this host;
# - VM does not start automatically when the host starts;
# - on host shutdown guests are shut down, not saved (host-wide libvirt-guests setting, changed on request);
# - optional ISO attached as the first boot device: the latest Debian netinst (downloaded only if it is
#   not in ISO_DIR yet or its SHA256 does not match) or any other ISO file;
# - unattended Debian install: an image built once from the netinst with a preseed (rebuilt only for a new
#   Debian version or new settings); the installer asks only the hostname, domain, user name and password,
#   the first disk becomes the system disk (LVM), the other disks are left untouched;
# - optional start of the VM at the end (default Yes).
#
# Run as root:  sudo bash new-vm.sh
# The whole script is a function, so it also works as:  wget -qO- <url> | sudo bash

main() {
set -uo pipefail

# --- VM settings ---
DEFAULT_CPU=4
DEFAULT_MEM_GB=8
DEFAULT_DISKS=2
DEFAULT_SIZES_GB=(60 200)   # defaults for disk 1, 2, ...
EXTRA_DISK_GB=100           # default for disks beyond the list above
MAX_DISKS=16
MAX_DISK_GB=65536
DEFAULT_ROOT=/var/lib/libvirt/images
DEFAULT_BRIDGE=br0
ISO_DIR=/var/lib/libvirt/images/iso   # downloaded Debian images are kept here
DEBIAN_URL=https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/
GUESTS_CONF=/etc/default/libvirt-guests

YELLOW=$'\e[33m'; GREEN=$'\e[32m'; RED=$'\e[31m'; GRAY=$'\e[90m'; RESET=$'\e[0m'

warn() { echo "  ${YELLOW}$*${RESET}"; }
die()  { echo; printf '%s\n' "${RED}Error: $*${RESET}"; exit 1; }
# Input ended (Ctrl+D or closed terminal): stop the whole script, also from inside $(...)
eof()  { echo >&2; echo "Input ended, nothing was created." >&2; kill -TERM $$; exit 1; }

# Prompt with a pre-filled, editable default value (readline, Tab completes paths)
read_prefilled() {
  local prompt=$1 default=$2 value
  read -r -e -p "$prompt: " -i "$default" value || eof
  printf '%s' "${value:-$default}"
}

# Prompt for an integer in [min, max] with a default; repeats until the input is valid
read_number() {
  local prompt=$1 default=$2 min=$3 max=$4 raw
  while true; do
    read -r -p "$prompt [$default]: " raw || eof
    raw=${raw//[[:space:]]/}
    [ -z "$raw" ] && { echo "$default"; return; }
    if [[ $raw =~ ^[0-9]+$ ]] && [ "$raw" -ge "$min" ] && [ "$raw" -le "$max" ]; then
      echo "$((10#$raw))"; return
    fi
    warn "Enter a whole number from $min to $max." >&2
  done
}

# Yes/No prompt; Enter returns the default (y or n)
read_yes_no() {
  local prompt=$1 default=$2 hint raw
  [ "$default" = y ] && hint="Y/n" || hint="y/N"
  while true; do
    read -r -p "$prompt [$hint]: " raw || eof
    raw=$(tr '[:upper:]' '[:lower:]' <<<"${raw//[[:space:]]/}")
    [ -z "$raw" ] && raw=$default
    case $raw in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
    warn "Enter y or n." >&2
  done
}

# Offer to install missing packages
need_packages() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  echo "Missing packages: ${missing[*]}"
  read_yes_no "Install them now?" y || return 1
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
}

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash $0"
command -v virsh >/dev/null || die "libvirt is not installed (virsh not found)."
need_packages virtinst qemu-utils ovmf || die "Required packages are not installed."

# --- VM name ---
while true; do
  read -r -p "VM name [VM01]: " VM_NAME || eof
  VM_NAME=$(xargs <<<"$VM_NAME")
  VM_NAME=${VM_NAME:-VM01}
  if [[ ! $VM_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    warn "Use letters, digits, dot, hyphen and underscore only."; continue
  fi
  virsh dominfo "$VM_NAME" &>/dev/null && die "VM '$VM_NAME' already exists."
  break
done

# --- Folder where VMs are stored (a <VMName> subfolder is created in it) ---
# Repeats until the path is valid and has no <VMName> subfolder yet; the last entry is pre-filled again
PATH_PROMPT=$DEFAULT_ROOT
while true; do
  ROOT_PATH=$(read_prefilled "Folder for virtual machines" "$PATH_PROMPT")
  ROOT_PATH=${ROOT_PATH%/}
  PATH_PROMPT=$ROOT_PATH
  if [[ $ROOT_PATH != /* ]]; then
    warn "Specify a full path, e.g. $DEFAULT_ROOT"; continue
  fi
  if [ ! -d "$ROOT_PATH" ]; then
    warn "Folder '$ROOT_PATH' not found. Choose another folder."; continue
  fi
  VM_DIR=$ROOT_PATH/$VM_NAME
  if [ -e "$VM_DIR" ]; then
    warn "Folder '$VM_DIR' already exists. Choose another folder."; continue
  fi
  break
done

# --- vCPU count (1 to the host's logical processors; default 4 or the host maximum if lower) ---
HOST_CPU=$(nproc --all)
CPU_COUNT=$(read_number "vCPU count (host: $HOST_CPU)" $((DEFAULT_CPU < HOST_CPU ? DEFAULT_CPU : HOST_CPU)) 1 "$HOST_CPU")

# --- Memory (static, limited to the host's physical memory) ---
HOST_MEM_GB=$(awk '/^MemTotal:/{printf "%d", $2/1048576}' /proc/meminfo)
FREE_MEM_GB=$(awk '/^MemAvailable:/{printf "%d", $2/1048576}' /proc/meminfo)
[ "$HOST_MEM_GB" -ge 1 ] || HOST_MEM_GB=1
MEM_GB=$(read_number "Memory, GB (host: $HOST_MEM_GB GB, free: $FREE_MEM_GB GB)" \
  $((DEFAULT_MEM_GB < HOST_MEM_GB ? DEFAULT_MEM_GB : HOST_MEM_GB)) 1 "$HOST_MEM_GB")
[ "$MEM_GB" -gt "$FREE_MEM_GB" ] && warn "Warning: only $FREE_MEM_GB GB is free now; the VM may fail to start."

# --- Disks ---
DISK_COUNT=$(read_number "Number of disks" "$DEFAULT_DISKS" 1 "$MAX_DISKS")
DISK_PATHS=(); DISK_SIZES=()
for ((i = 1; i <= DISK_COUNT; i++)); do
  case $i in
    1) name="$VM_NAME.qcow2" ;;
    2) name="$VM_NAME-Data.qcow2" ;;
    *) name="$VM_NAME-Data$((i - 1)).qcow2" ;;
  esac
  def=${DEFAULT_SIZES_GB[i - 1]:-$EXTRA_DISK_GB}
  size=$(read_number "  Disk $i ($name) size, GB" "$def" 1 "$MAX_DISK_GB")
  DISK_PATHS+=("$VM_DIR/$name"); DISK_SIZES+=("$size")
done
DISK_FREE_GB=$(df -P -BG "$ROOT_PATH" | awk 'NR==2{sub("G","",$4); print $4}')
DISK_TOTAL_GB=0; for s in "${DISK_SIZES[@]}"; do DISK_TOTAL_GB=$((DISK_TOTAL_GB + s)); done
[ "$DISK_TOTAL_GB" -gt "$DISK_FREE_GB" ] && \
  warn "Note: disks total $DISK_TOTAL_GB GB, free in '$ROOT_PATH': $DISK_FREE_GB GB (disks are thin, space is used as data is written)."

# --- Guest OS type ---
echo "Guest OS:"
echo "  [1] Linux (virtio disks and network)"
echo "  [2] Windows (SATA disks, e1000e network; no extra drivers needed)"
OS_TYPE=$(read_number "OS number" 1 1 2)

# --- Network: host bridges and libvirt networks ---
NET_ARGS=(); NET_LABELS=()
for b in /sys/class/net/*/bridge; do
  [ -e "$b" ] || continue
  br=$(basename "$(dirname "$b")")
  [[ $br == virbr* ]] && continue   # bridges of libvirt networks are listed below
  NET_ARGS+=("bridge=$br"); NET_LABELS+=("$br - same LAN as the host, IP from the router, reachable from the LAN")
done
while read -r net; do
  [ -n "$net" ] || continue
  mode=$(virsh net-dumpxml "$net" 2>/dev/null | sed -n "s/.*<forward mode='\([a-z]*\)'.*/\1/p" | head -n1)
  case $mode in
    nat)   desc="NAT: internet only, not reachable from the LAN" ;;
    "")    desc="isolated: only the host and VMs on this network" ;;
    *)     desc="libvirt network, mode $mode" ;;
  esac
  NET_ARGS+=("network=$net"); NET_LABELS+=("$net - $desc")
done < <(virsh net-list --all --name 2>/dev/null)

NET=""; NET_LABEL="no network"
if [ ${#NET_ARGS[@]} -gt 0 ]; then
  echo "Available networks:"
  default_net=1
  for ((i = 0; i < ${#NET_ARGS[@]}; i++)); do
    echo "  [$((i + 1))] ${NET_LABELS[i]}"
    [ "${NET_ARGS[i]}" = "bridge=$DEFAULT_BRIDGE" ] && default_net=$((i + 1))
  done
  echo "  [0] no network"
  n=$(read_number "Network number" "$default_net" 0 ${#NET_ARGS[@]})
  if [ "$n" -gt 0 ]; then NET=${NET_ARGS[n - 1]}; NET_LABEL=${NET_LABELS[n - 1]}; fi
else
  warn "No bridge or libvirt network found; the VM will not be connected."
fi

# --- Secure Boot ---
SECURE_BOOT=no
read_yes_no "Enable Secure Boot?" n && SECURE_BOOT=yes

# --- Virtual TPM ---
TPM=no
if read_yes_no "Enable virtual TPM?" n; then
  if need_packages swtpm swtpm-tools; then TPM=yes
  else TPM_WARNING="Virtual TPM was not enabled: swtpm is not installed."
  fi
fi

# --- Installation ISO ---
# Download with a green progress bar (percent, MB, speed); the cursor is hidden while it is drawn
download() {
  local url=$1 out=$2 total pid size last=0 speed=0 width filled pct line rc done_bar rest_bar
  total=$(curl -fsSLI "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "content-length:" {n = $2} END {print n + 0}')
  curl -fsSL -o "$out" "$url" &
  pid=$!
  printf '\e[?25l'
  trap 'kill $pid 2>/dev/null; rm -f "$out"; printf "\e[?25h\n"; exit 130' INT TERM
  draw() {
    size=$(stat -c %s "$out" 2>/dev/null || echo 0)
    width=$(( $(tput cols 2>/dev/null || echo 80) - 34 ))
    [ "$width" -gt 60 ] && width=60
    [ "$width" -lt 10 ] && width=10
    if [ "$total" -gt 0 ]; then
      pct=$((size * 100 / total)); filled=$((size * width / total))
      line=$(printf '%3d%%  %d/%d MB  %d MB/s' "$pct" $((size / 1048576)) $((total / 1048576)) "$speed")
    else
      pct=0; filled=0
      line=$(printf '%d MB  %d MB/s' $((size / 1048576)) "$speed")
    fi
    done_bar=$(printf '%*s' "$filled" ''); rest_bar=$(printf '%*s' $((width - filled)) '')
    printf '\r  %s%s%s%s%s %s\e[K' "$GREEN" "${done_bar// /█}" "$GRAY" "${rest_bar// /░}" "$RESET" "$line"
  }
  while kill -0 "$pid" 2>/dev/null; do
    draw
    sleep 1
    size=$(stat -c %s "$out" 2>/dev/null || echo 0)
    speed=$(( (size - last) / 1048576 )); last=$size
  done
  wait "$pid"; rc=$?
  [ "$rc" -eq 0 ] && draw
  printf '\e[?25h\n'
  trap - INT TERM
  return "$rc"
}

# Latest Debian netinst: reused from ISO_DIR if already downloaded and its SHA256 matches, otherwise downloaded
get_debian_iso() {
  local sums name file expected actual
  need_packages curl || return 1
  mkdir -p "$ISO_DIR"
  echo "Looking up the current Debian image on cdimage.debian.org..."
  sums=$(curl -fsSL --max-time 30 "${DEBIAN_URL}SHA256SUMS" 2>/dev/null) || sums=""
  name=$(grep -o 'debian-[0-9.]*-amd64-netinst\.iso' <<<"$sums" | head -n1)
  if [ -z "$name" ]; then
    # No connection: use the newest image already downloaded, if any
    file=$(ls -1 "$ISO_DIR"/debian-*-amd64-netinst.iso 2>/dev/null | sort -V | tail -n1)
    if [ -n "$file" ]; then
      warn "cdimage.debian.org is not reachable; using the downloaded $file (not checked for a newer version)."
      ISO=$file; return 0
    fi
    warn "cdimage.debian.org is not reachable and no Debian image is in $ISO_DIR."
    return 1
  fi
  file=$ISO_DIR/$name
  expected=$(awk -v n="$name" '$2 == n {print $1}' <<<"$sums")
  if [ -f "$file" ]; then
    echo -n "Found $file, verifying SHA256... "
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [ "$actual" = "$expected" ]; then echo "OK"; ISO=$file; return 0; fi
    echo "mismatch, downloading again."
  fi
  echo "Downloading $name to $ISO_DIR..."
  if ! download "$DEBIAN_URL$name" "$file.part"; then
    rm -f "$file.part"; warn "Download failed."; return 1
  fi
  echo -n "Verifying SHA256... "
  actual=$(sha256sum "$file.part" | cut -d' ' -f1)
  if [ "$actual" != "$expected" ]; then
    rm -f "$file.part"; echo; warn "Checksum mismatch, the download was removed."; return 1
  fi
  mv -f "$file.part" "$file"; chmod 644 "$file"
  echo "OK"
  ISO=$file
}

# Answers for the unattended Debian installation in a VM. The installer asks only the hostname, domain,
# user name and password; the first disk of the VM becomes the system disk, the other disks are left untouched.
write_preseed() {
  cat <<'EOF'
#### Language, country, keyboard
d-i debian-installer/language string en
d-i debian-installer/country string UA
d-i debian-installer/locale string en_US.UTF-8
d-i localechooser/supported-locales multiselect en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us

#### Network via DHCP; the hostname and domain are asked, with debian offered as the default hostname
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string debian
d-i netcfg/get_hostname seen false
d-i hw-detect/load_firmware boolean true

#### Package mirror
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

#### User: root login disabled, so the user is added to the sudo group
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/user-fullname string

#### Time
d-i clock-setup/utc boolean true
d-i time/zone string Europe/Kyiv
d-i clock-setup/ntp boolean true

#### System disk: the first disk of the VM (vda/sda); set right before partitioning, when the disks are detected
d-i partman/early_command string d=$(list-devices disk | head -n1); debconf-set partman-auto/disk "$d"; debconf-set grub-installer/bootdev "$d"

#### Partitioning: LVM on the whole system disk without confirmations
d-i partman-auto/method string lvm
d-i partman-auto-lvm/guided_size string max
d-i partman-auto/choose_recipe select atomic
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

#### Packages
d-i apt-setup/cdrom/set-first boolean false
d-i apt-setup/cdrom/set-next boolean false
d-i apt-setup/cdrom/set-failed boolean false
popularity-contest popularity-contest/participate boolean false
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string sudo qemu-guest-agent
d-i pkgsel/upgrade select full-upgrade

#### Boot loader
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true

#### After installation: login on serial port ttyS0 (virsh console), sudo without re-asking the password for the session,
#### kernel messages also on the serial console, boot progress shown, GRUB menu for 2 s
d-i preseed/late_command string \
  in-target systemctl enable serial-getty@ttyS0.service; \
  echo 'Defaults timestamp_timeout=-1' > /target/etc/sudoers.d/timeout; \
  chmod 440 /target/etc/sudoers.d/timeout; \
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet systemd.show_status=true console=tty0 console=ttyS0,115200"/' /target/etc/default/grub; \
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /target/etc/default/grub; \
  in-target update-grub

# Eject the ISO at the end and reboot into the installed system without the "Installation complete" screen
d-i cdrom-detect/eject boolean true
d-i finish-install/reboot_in_progress note
EOF
}

# Builds <debian-version>-vm-<hash>.iso from the netinst in $ISO: preseed added to the installer initrd,
# boot menu reduced to "Install" waiting for Enter. The hash changes when these functions change,
# so the image is rebuilt only for a new Debian version or new settings.
build_vm_iso() {
  local src=$ISO hash out work f i
  need_packages xorriso cpio || return 1
  hash=$(declare -f write_preseed build_vm_iso | sha256sum | cut -c1-8)
  out=$ISO_DIR/$(basename "${src%-amd64-netinst.iso}")-vm-$hash.iso
  if [ -f "$out" ]; then
    echo "Using the prepared image $out"
    ISO=$out; return 0
  fi
  echo "Preparing the unattended installation image (about a minute)..."
  work=$(mktemp -d)
  mkdir -p "$work/extra"
  write_preseed > "$work/extra/preseed.cfg"
  local map=()
  # Preseed appended to the initrd of the text and graphical installers
  for i in install.amd/initrd.gz install.amd/gtk/initrd.gz; do
    f=$work/$(tr / _ <<<"$i")
    xorriso -osirrox on -indev "$src" -extract "/$i" "$f" &>/dev/null || continue
    chmod u+w "$f"
    (cd "$work/extra" && find . -mindepth 1 | cpio -o -H newc -R 0:0 --quiet | gzip) >> "$f"
    map+=(-map "$f" "/$i")
  done
  # UEFI boot menu: only "Install", no timeout, language and keyboard answered on the kernel command line
  f=$work/grub.cfg
  if [ ${#map[@]} -eq 0 ] || ! xorriso -osirrox on -indev "$src" -extract /boot/grub/grub.cfg "$f" &>/dev/null; then
    rm -rf "$work"; warn "'$src' does not look like a Debian netinst image."; return 1
  fi
  chmod u+w "$f"
  awk '
    skip { d += gsub(/{/, "{") - gsub(/}/, "}"); if (d <= 0) skip = 0; next }
    /^[[:space:]]*(menuentry|submenu)[[:space:]]/ && $0 !~ /'"'"'Install'"'"'/ {
      d = gsub(/{/, "{") - gsub(/}/, "}"); if (d > 0) skip = 1; next }
    { print }' "$f" > "$f.new" && mv "$f.new" "$f"
  sed -i "s#\(/install.amd/vmlinuz\)#\1 locale=en_US.UTF-8 keymap=us#" "$f"
  sed -i "/^[[:space:]]*menuentry.*'Install'.*{/a\\    echo 'Loading the installer, please wait...'" "$f"
  printf '\nset timeout=-1\nset default="Install"\n' >> "$f"
  map+=(-map "$f" /boot/grub/grub.cfg)
  if ! xorriso -indev "$src" -outdev "$out.part" "${map[@]}" -boot_image any replay &>/dev/null; then
    rm -rf "$work" "$out.part"; warn "Building the image failed."; return 1
  fi
  rm -rf "$work"
  mv -f "$out.part" "$out"; chmod 644 "$out"
  # Earlier prepared images are no longer needed
  for f in "$ISO_DIR"/debian-*-vm-*.iso; do [ "$f" = "$out" ] || rm -f "$f"; done
  echo "Saved $out"
  ISO=$out
}

# Another ISO file (repeats until the file exists or the field is cleared)
ask_iso_path() {
  local start prompt
  [ -d "$ISO_DIR" ] && start=$ISO_DIR/ || start=$ROOT_PATH/
  prompt=$start
  while true; do
    ISO=$(read_prefilled "Path to ISO (clear the field = back)" "$prompt")
    [ "$ISO" = "$start" ] && ISO=""
    [ -z "$ISO" ] && return 1
    prompt=$ISO
    [ -f "$ISO" ] && return 0
    warn "File '$ISO' not found. Enter another path or clear the field to go back."
  done
}

ISO=""; ISO_MODE=""
while true; do
  echo "Installation ISO:"
  if [ "$OS_TYPE" = 1 ]; then
    echo "  [1] Debian, unattended install (asks only hostname, domain, user and password)"
    echo "  [2] Debian, standard installer"
    echo "  [3] Another ISO file"
    echo "  [0] None"
    choice=$(read_number "ISO number" 1 0 3)
  else
    echo "  [1] ISO file"
    echo "  [0] None"
    choice=$(read_number "ISO number" 1 0 1)
    [ "$choice" = 1 ] && choice=3
  fi
  case $choice in
    1) get_debian_iso && build_vm_iso && { ISO_MODE=unattended; break; } ;;
    2) get_debian_iso && break ;;
    3) ask_iso_path && break ;;
    0) ISO=""; break ;;
  esac
  ISO=""
done
# QEMU runs as libvirt-qemu: the file and its folders must be readable by it
if [ -n "$ISO" ] && id libvirt-qemu &>/dev/null && ! runuser -u libvirt-qemu -- test -r "$ISO"; then
  warn "Warning: '$ISO' is not readable by the libvirt-qemu user; the VM may fail to start."
fi

# --- Host shutdown behaviour (host-wide, applies to all VMs) ---
# libvirt-guests defaults: ON_BOOT=start (restarts VMs that were running), ON_SHUTDOWN=suspend (saves state)
conf_value() { grep -E "^[[:space:]]*$1=" "$GUESTS_CONF" 2>/dev/null | tail -n1 | cut -d= -f2 | tr -d '"'; }
ON_BOOT=$(conf_value ON_BOOT); ON_BOOT=${ON_BOOT:-start}
ON_SHUTDOWN=$(conf_value ON_SHUTDOWN); ON_SHUTDOWN=${ON_SHUTDOWN:-suspend}
if [ "$ON_BOOT" != ignore ] || [ "$ON_SHUTDOWN" != shutdown ]; then
  echo "${GRAY}Note: host now uses ON_BOOT=$ON_BOOT, ON_SHUTDOWN=$ON_SHUTDOWN in $GUESTS_CONF (applies to all VMs).${RESET}"
  if read_yes_no "Shut down guests on host shutdown and do not restart them on boot?" y; then
    CHANGE_GUESTS_CONF=yes
  fi
fi

# --- Unique static MAC address in the libvirt range 52:54:00 ---
USED_MACS=$(for d in $(virsh list --all --name); do virsh domiflist "$d" 2>/dev/null | awk 'NR>2{print tolower($5)}'; done)
while true; do
  MAC=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
  grep -qx "$MAC" <<<"$USED_MACS" || break
done

# --- Build virt-install arguments ---
if [ "$OS_TYPE" = 1 ]; then
  OSINFO=linux2022; DISK_BUS=virtio; NIC_MODEL=virtio
else
  OSINFO=win10; DISK_BUS=sata; NIC_MODEL=e1000e
fi

ARGS=(
  --name "$VM_NAME"
  --osinfo "detect=on,require=off,name=$OSINFO"
  --machine q35
  --vcpus "$CPU_COUNT"
  --cpu host-passthrough
  --memory $((MEM_GB * 1024))
  --boot "uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=$SECURE_BOOT,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=$SECURE_BOOT"
  --graphics vnc,listen=127.0.0.1
  --console pty,target.type=serial
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0
  --import
  --noautoconsole
  --print-xml
)
# ISO is the first boot device; for the unattended install it is the last one: the empty system disk
# does not boot, so the ISO starts, and after the installation the VM boots from the disk even with the ISO attached
if [ "$ISO_MODE" = unattended ]; then ISO_ORDER=$((DISK_COUNT + 1)); DISK_ORDER=1; else ISO_ORDER=1; DISK_ORDER=2; fi
[ -n "$ISO" ] && ARGS+=(--disk "path=$ISO,device=cdrom,bus=sata,readonly=on,boot.order=$ISO_ORDER")
for ((i = 0; i < DISK_COUNT; i++)); do
  ARGS+=(--disk "path=${DISK_PATHS[i]},format=qcow2,bus=$DISK_BUS,cache=none,discard=unmap,boot.order=$((i + DISK_ORDER))")
done
if [ -n "$NET" ]; then ARGS+=(--network "$NET,model=$NIC_MODEL,mac=$MAC"); else ARGS+=(--network none); fi
# virt-install adds a TPM to UEFI VMs by default, so "none" is passed explicitly
if [ "$TPM" = yes ]; then ARGS+=(--tpm "backend.type=emulator,backend.version=2.0,model=tpm-crb"); else ARGS+=(--tpm none); fi

# --- Create disks ---
DEFINED=no
trap '[ "$DEFINED" = no ] && [ -d "$VM_DIR" ] && rm -rf -- "$VM_DIR"' EXIT
mkdir -p "$VM_DIR"
for ((i = 0; i < DISK_COUNT; i++)); do
  qemu-img create -q -f qcow2 -o preallocation=metadata "${DISK_PATHS[i]}" "${DISK_SIZES[i]}G" \
    || die "Could not create disk '${DISK_PATHS[i]}'."
done

# --- Define the VM (created, not started) ---
XML=$(virt-install "${ARGS[@]}" 2>&1) || die "virt-install failed: $XML"
DEF_OUT=$(virsh define /dev/stdin <<<"$XML" 2>&1) || die "virsh define failed: $DEF_OUT"
DEFINED=yes
trap - EXIT
virsh refresh-pool default &>/dev/null || true

# Do not start the VM automatically when the host starts
virsh autostart --disable "$VM_NAME" >/dev/null

# Host-wide: shut down guests on host shutdown, do not restart them on boot
if [ "${CHANGE_GUESTS_CONF:-}" = yes ]; then
  [ -f "$GUESTS_CONF" ] && [ ! -e "$GUESTS_CONF.bak" ] && cp "$GUESTS_CONF" "$GUESTS_CONF.bak"
  touch "$GUESTS_CONF"
  for kv in ON_BOOT=ignore ON_SHUTDOWN=shutdown; do
    k=${kv%%=*}
    # Replace active lines; commented examples are left as they are
    if grep -qE "^[[:space:]]*$k=" "$GUESTS_CONF"; then
      sed -i -E "s|^[[:space:]]*$k=.*|$kv|" "$GUESTS_CONF"
    else
      echo "$kv" >> "$GUESTS_CONF"
    fi
  done
  systemctl enable --now libvirt-guests.service &>/dev/null || true
fi

# --- Summary ---
nested=$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null | head -n1)
case $nested in Y|1) nested="available" ;; *) nested="not enabled on the host" ;; esac
xml=$(virsh dumpxml "$VM_NAME")
echo
echo "${GREEN}VM '$VM_NAME' created.${RESET}"
echo
printf '  %-19s %s\n' "VM folder:" "$VM_DIR"
printf '  %-19s %s\n' "vCPU:" "$(virsh vcpucount "$VM_NAME" --maximum --config) (host-passthrough, nested: $nested)"
printf '  %-19s %s\n' "Memory:" "$MEM_GB GB (static)"
printf '  %-19s %s\n' "Firmware:" "UEFI, Secure Boot: $([ "$SECURE_BOOT" = yes ] && echo On || echo Off)"
printf '  %-19s %s\n' "Virtual TPM:" "$(grep -q '<tpm ' <<<"$xml" && echo On || echo Off)"
OS_ID=$(sed -nE 's|.*<libosinfo:os id="https?://[^/]+/([^"]*)".*|\1|p' <<<"$xml")
printf '  %-19s %s\n' "Guest OS:" "$([ "$OS_TYPE" = 1 ] && echo Linux || echo Windows) (osinfo: ${OS_ID:-generic})"
autostart=$(virsh dominfo "$VM_NAME" | awk -F': *' '/^Autostart/{print $2}')
printf '  %-19s %s\n' "Autostart:" "$([ "$autostart" = enable ] && echo On || echo Off)"
printf '  %-19s %s\n' "Host shutdown/boot:" "ON_BOOT=$(v=$(conf_value ON_BOOT); echo "${v:-start}"), ON_SHUTDOWN=$(v=$(conf_value ON_SHUTDOWN); echo "${v:-suspend}")"
if [ -n "$NET" ]; then
  printf '  %-19s %s\n' "MAC address:" "$MAC (static)"
fi
printf '  %-19s %s\n' "Network:" "$NET_LABEL"
for ((i = 0; i < DISK_COUNT; i++)); do
  printf '  %-19s %s\n' "Disk:" "${DISK_PATHS[i]} (${DISK_SIZES[i]} GB, qcow2 thin, $DISK_BUS)"
done
if [ "$ISO_MODE" = unattended ]; then
  printf '  %-19s %s\n' "ISO:" "$ISO (unattended Debian install, boots after the disks)"
elif [ -n "$ISO" ]; then
  printf '  %-19s %s\n' "ISO:" "$ISO (first boot device)"
fi
[ -n "${TPM_WARNING:-}" ] && { echo; warn "$TPM_WARNING"; }

# --- Start the VM (green prompt, default Yes) ---
echo
while true; do
  read -r -p "${GREEN}Start VM '$VM_NAME' now? [Y/n]: ${RESET}" answer || answer=n
  answer=$(tr '[:upper:]' '[:lower:]' <<<"${answer//[[:space:]]/}")
  case $answer in ''|y|yes|n|no) break ;; esac
done
if [[ $answer == "" || $answer == y || $answer == yes ]]; then
  if out=$(virsh start "$VM_NAME" 2>&1); then
    echo "VM '$VM_NAME' started. Console: Cockpit > Virtual machines > $VM_NAME, or: virsh console $VM_NAME"
    [ "$ISO_MODE" = unattended ] && echo "In the console press Enter in the boot menu, then enter the hostname, domain, user name and password."
  else
    echo "${RED}VM '$VM_NAME' was created but could not be started: $out${RESET}"
    exit 1
  fi
else
  echo "VM '$VM_NAME' was not started."
fi
}

# Read answers from the terminal, also when the script itself comes from a pipe (curl | bash)
main "$@" </dev/tty
