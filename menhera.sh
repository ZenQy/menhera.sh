#!/bin/bash
set -Eeuo pipefail
# disable command path hashing as we are going to move fast and break things
set +h

# config
TEMP_ROOTFS_DISTRO="debian"
TEMP_ROOTFS_FLAVOR="bullseye"
WORKDIR="/tmp/menhera"
ROOTFS=""
SSHD="dropbear" # or "openssh"

declare -A ARCH_MAP=(
    ["x86_64"]="amd64"
    ["aarch64"]="arm64"
)

# internal global variables
OLDROOT="/"
NEWROOT=""

MACHINE_TYPE=$(uname -m)
ARCH_ID=${ARCH_MAP[$MACHINE_TYPE]:-$MACHINE_TYPE}

# fix possible PATH problems
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

menhera::reset_sshd_config() {
    cat > /etc/ssh/sshd_config <<EOF
PermitRootLogin yes
AcceptEnv LANG LC_*
EOF
    return 0
}

# environment compatibility
menhera::__compat_restart_ssh() {
    if [ -x "$(command -v systemctl)" ]; then
        ! systemctl daemon-reload
        ! systemctl stop ssh
        ! systemctl stop sshd # RPM distro compatiblity

        if [ "${SSHD}" = "openssh" ]; then
            ! systemctl enable ssh
            ! systemctl reset-failed ssh
            if ! systemctl restart ssh; then
                >&2 echo "[-] SSH daemon start failed, try resetting config..."
                menhera::reset_sshd_config
                if ! systemctl restart ssh; then
                    >&2 echo "[!] SSH daemon fail to start, dropping you to a shell; please manually launch a forking SSH daemon and exit."
                    sh
                fi
            fi
        elif [ "${SSHD}" = "dropbear" ]; then
            # Don't rely on systemd anymore; use daemon fork instead.
            # This is due to newer version of systemd trying to read executables from the old rootfs
            # thus failing with exit status 203. (Observed on CentOS 8 Stream.)
            if ! dropbear -E -m -K 10; then
                >&2 echo "[!] SSH daemon fail to start, dropping you to a shell; please manually launch a forking SSH daemon and exit."
                sh
            fi
        fi
    else
        >&2 echo "[-] ERROR: Cannot restart SSH server, init system not recoginzed"
        return 1
    fi

    >&2 echo "[+] SSH daemon started"
    return 0
}

menhera::__compat_reload_init() {
    if [ -x "$(command -v systemctl)" ]; then
        systemctl daemon-reexec
        >&2 echo "[+] Reloaded SystemD"
    elif [ -x "$(command -v telinit)" ]; then
        telinit u
        >&2 echo "[+] Reloaded init"
    else
        >&2 echo "[-] ERROR: Cannot re-exec init, init system not recognized"
        return 1
    fi

    return 0
}

# fetch URL and output its body to stdout
menhera::__compat_download_stdout() {
    if command -v wget > /dev/null; then
        wget -qO- --show-progress "$1"
    elif command -v curl > /dev/null; then
        curl -L "$1"
    else
        >&2 echo "[-] ERROR: No compatible download program is installed, try install curl or wget"
	    return 127
    fi

    return 0
}

# fetch URL and put the content to a file
menhera::__compat_download_file() {
    if command -v wget > /dev/null; then
        wget --continue -q --show-progress -O "$2" "$1"
    elif command -v curl > /dev/null; then
        curl -L -C - -o "$2" "$1"
    else
        >&2 echo "[-] ERROR: No compatible download program is installed, try install curl or wget"
        return 127
    fi

    return 0
}

# helper functions
# https://stackoverflow.com/a/3232082/2646069
menhera::confirm() {
    # call with a prompt string or use a default
    read -r -p "${1:-Are you sure? [y/N]} " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            true
            ;;
        *)
            false
            ;;
    esac
}

# jobs
menhera::get_rootfs() {
    if [ -n ${ROOTFS} ]; then 
        >&2 echo "[*] Getting rootfs URL..."

        # forgive me for parsing HTML with these shit
        # and hope it works
        ROOTFS_TIME=$(menhera::__compat_download_stdout "https://images.linuxcontainers.org/images/${TEMP_ROOTFS_DISTRO}/${TEMP_ROOTFS_FLAVOR}/${ARCH_ID}/default/?C=M;O=D" | grep -oP '(\d{8}_\d{2}:\d{2})' | head -n 1)
        
        ROOTFS="https://images.linuxcontainers.org/images/${TEMP_ROOTFS_DISTRO}/${TEMP_ROOTFS_FLAVOR}/${ARCH_ID}/default/${ROOTFS_TIME}/rootfs.squashfs"
    else 
        >&2 echo "[+] \$ROOTFS is set to '$ROOTFS'"
    fi

    return 0
}

menhera::sync_filesystem() {
    >&2 echo "[*] Syncing..."
    sync
    sync

    return 0
}

menhera::prepare_environment() {
    >&2 echo "[*] Loading kernel modules..."
    modprobe overlay
    modprobe squashfs

    sysctl kernel.panic=10
    sysctl kernel.sysrq=1

    >&2 echo "[*] Creating workspace in '${WORKDIR}'..."
    # workspace
    mkdir -p "${WORKDIR}"
    mount -t tmpfs -o size=100% tmpfs "${WORKDIR}"

    # new rootfs
    mkdir -p "${WORKDIR}/newroot"
    # readonly part of new rootfs
    mkdir -p "${WORKDIR}/newrootro"
    # writeable part of new rootfs
    mkdir -p "${WORKDIR}/newrootrw"
    # overlayfs workdir
    mkdir -p "${WORKDIR}/overlayfs_workdir"

    >&2 echo "[*] Downloading temporary rootfs..."
    menhera::__compat_download_file "${ROOTFS}" "${WORKDIR}/rootfs.squashfs"

    return 0
}

menhera::mount_new_rootfs() {
    >&2 echo "[*] Mounting temporary rootfs..."
    mount -t squashfs "${WORKDIR}/rootfs.squashfs" "${WORKDIR}/newrootro"
    mount -t overlay overlay -o rw,lowerdir="${WORKDIR}/newrootro",upperdir="${WORKDIR}/newrootrw",workdir="${WORKDIR}/overlayfs_workdir" "${WORKDIR}/newroot"

    NEWROOT="${WORKDIR}/newroot"

    return 0
}

menhera::install_software() {
    >&2 echo "[*] Installing SSH Server into new rootfs..."

    # disable APT cache
    echo -e 'Dir::Cache "";\nDir::Cache::archives "";' > "${NEWROOT}/etc/apt/apt.conf.d/00_disable-cache-directories"

    DEBIAN_FRONTEND=noninteractive chroot "${NEWROOT}" apt-get update -y
    if [ "${SSHD}" = "openssh" ]; then
        DEBIAN_FRONTEND=noninteractive chroot "${NEWROOT}" apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y openssh-server
    elif [ "${SSHD}" = "dropbear" ]; then
        DEBIAN_FRONTEND=noninteractive chroot "${NEWROOT}" apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y dropbear-bin

        # convert dropbear key format (if possible; only ed25519 is known to work)
        mkdir -p "${NEWROOT}/etc/dropbear"
        ! chroot "${NEWROOT}" dropbearconvert openssh dropbear "/etc/ssh/ssh_host_rsa_key" "/etc/dropbear/dropbear_rsa_host_key"
        ! chroot "${NEWROOT}" dropbearconvert openssh dropbear "/etc/ssh/ssh_host_dsa_key" "/etc/dropbear/dropbear_dss_host_key"
        ! chroot "${NEWROOT}" dropbearconvert openssh dropbear "/etc/ssh/ssh_host_ecdsa_key" "/etc/dropbear/dropbear_ecdsa_host_key"
        ! chroot "${NEWROOT}" dropbearconvert openssh dropbear "/etc/ssh/ssh_host_ed25519_key" "/etc/dropbear/dropbear_ed25519_host_key"
    fi

    return 0
}

menhera::copy_config() {
    >&2 echo "[*] Copying important config into new rootfs..."
    ! cp -axL --remove-destination "${OLDROOT}/etc/resolv.conf" "${NEWROOT}/etc"
    ! cp -axr "${OLDROOT}/etc/ssh" "${NEWROOT}/etc"
    ! cp -ax "${OLDROOT}/etc/"{passwd,shadow} "${NEWROOT}/etc"
    ! cp -axr "${OLDROOT}/root/.ssh" "${NEWROOT}/root"

    # fix SSH key files permission; otherwise OpenSSH server will refuse to start
    mkdir -p "${NEWROOT}/etc/ssh"
    ! chmod 600 -- "${NEWROOT}/etc/ssh/"*_key
    ! chown -R root:root -- "${NEWROOT}/root/.ssh"
    ! find "${NEWROOT}/root/.ssh" -type f -exec chmod 600 -- {} +

    chroot "${NEWROOT}" chsh -s /bin/bash root

    cat > "${NEWROOT}/etc/motd" <<EOF

Download menhera.sh at https://github.com/Jamesits/menhera.sh

!!!NOTICE!!!

This is a minimal RAM system created by menhera.sh. Feel free to format your disk, but don't blame anyone
except yourself if you lost important files or your system is broken.

If you think you've done something wrong, reboot immediately -- there is still hope. If unable to reboot using normal
commands, try "echo b > /proc/sysrq-trigger".

Your original rootfs is at "/mnt/oldroot". Be careful dealing with it. If it is still occupied, 
run "fuser -kvm /mnt/oldroot; fuser -kvm -15 /mnt/oldroot" to kill processes using the old rootfs.

Have a lot of fun...
EOF

    return 0
}

menhera::swap_root() {
    >&2 echo "[*] Swapping rootfs..."
    # prepare future mount point for our old rootfs
    mkdir -p "${WORKDIR}/newroot/mnt/oldroot"
    mount --make-rprivate /

    # swap root
    pivot_root "${WORKDIR}/newroot" "${WORKDIR}/newroot/mnt/oldroot"
    >&2 echo "[+] Rootfs replaced"
    OLDROOT="/mnt/oldroot"
    NEWROOT="/"

    # move mounts
    for i in dev proc sys run; do
        if [ -d "${OLDROOT}/$i" ]; then
            mount --move "${OLDROOT}/$i" "${NEWROOT}/$i"
        fi
    done
    mount -t tmpfs -o size=100% tmpfs "${NEWROOT}/tmp"

    mkdir -p "${WORKDIR}"
    mount --move "${OLDROOT}/${WORKDIR}" "${WORKDIR}"

    >&2 echo "[*] Restarting SSH daemon..."
    menhera::__compat_restart_ssh

    return 0
}

menhera::clear_processes() {
    >&2 echo "[*] Disabling swap..."
    swapoff -a

    >&2 echo "[*] Restarting init process..."
    menhera::__compat_reload_init
    # hope 15s is enough
    sleep 15

    >&2 echo "[*] Killing all programs still using the old root... Goodbye! See you on the other side~"
    fuser -kvm "${OLDROOT}" -15
    # in most cases the parent process of this script will be killed, so goodbye

    return 0
}

# main procedure
LIBRARY_ONLY=0

while test $# -gt 0
do
    case "$1" in
        --lib) LIBRARY_ONLY=1
            ;;
    esac
    shift
done

if [[ $LIBRARY_ONLY -eq 1 ]]; then
    # acting as a library only
    return 0
fi

if [[ $EUID -ne 0 ]]; then
    >&2 echo "[-] This script must be run as root"
    exit 1
fi

echo -e "We will start a temporary RAM system as your recovery environment."
echo -e "Note that this script will kill programs and umount filesystems without prompting."
echo -e "Please confirm:"
echo -e "\t+ You have closed all programs you can, and backed up all important data"
echo -e "\t+ You can SSH into your system as root user"
menhera::confirm || exit -1

menhera::get_rootfs
menhera::sync_filesystem

menhera::prepare_environment
menhera::mount_new_rootfs
menhera::copy_config
menhera::install_software
menhera::swap_root

echo -e "If you are connecting from SSH, please create a second session to this host use root and"
echo -e "confirm you can get a shell. Host key might change - use \"ssh-keygen -R hostname-or-ip\" to purge the"
echo -e "host key cache entry."
echo -e "After your confirmation, we are going to kill the old SSH server."

if menhera::confirm; then 
    menhera::clear_processes
else
    echo -e "Please manually issue a reboot to recover your old OS. If you believe there is a bug in menhera.sh, "
    echo -e "raise a ticket at https://github.com/Jamesits/menhera.sh/issues ."
    echo -e "Force reboot by \"echo b > /proc/sysrq-trigger\"."
    exit 1
fi
