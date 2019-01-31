#!/bin/sh

set -u

check_root() {
    if [ "$(id -ru)" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

error_fatal() {
    # shellcheck disable=SC2039
    local msg="$1"
    [ -z "${msg}" ] && msg="Unknown error"
    if which lava-test-raise;then
        lava-test-raise "${msg}"
    else
        printf "FATAL ERROR: %s\n" "${msg}" >&2
    fi
    exit 1
}

error_msg() {
    # shellcheck disable=SC2039
    local msg="$1"
    [ -z "${msg}" ] && msg="Unknown error"
    printf "ERROR: %s\n" "${msg}" >&2
    exit 1
}

info_msg() {
    # shellcheck disable=SC2039
    local msg="$1"
    [ -z "${msg}" ] && msg="Unknown info"
    printf "INFO: %s\n" "${msg}" >&1
}

report_pass() {
    [ "$#" -ne 1 ] && error_msg "Usage: report_pass test_case"
    # shellcheck disable=SC2039
    local test_case="$1"
    echo "${test_case} pass" | tee -a "${RESULT_FILE}"
}

dist_name() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        dist=$(. /etc/os-release && echo "${ID}")
    elif [ -x /usr/bin/lsb_release ]; then
        dist="$(lsb_release -si)"
    elif [ -f /etc/lsb-release ]; then
        # shellcheck disable=SC1091
        dist="$(. /etc/lsb-release && echo "${DISTRIB_ID}")"
    elif [ -f /etc/debian_version ]; then
        dist="debian"
    elif [ -f /etc/fedora-release ]; then
        dist="fedora"
    elif [ -f /etc/centos-release ]; then
        dist="centos"
    else
        dist="unknown"
        warn_msg "Unsupported distro: cannot determine distribution name"
    fi

    # convert dist to lower case
    dist=$(echo ${dist} | tr '[:upper:]' '[:lower:]')
    case "${dist}" in
        rpb*) dist="oe-rpb" ;;
    esac
}

install_deps() {
    # shellcheck disable=SC2039
    local pkgs="$1"
    [ -z "${pkgs}" ] && error_msg "Usage: install_deps pkgs"
    # skip_install parmater is optional.
    # shellcheck disable=SC2039
    local skip_install="${2:-false}"

    if [ "${skip_install}" = "True" ] || [ "${skip_install}" = "true" ]; then
        info_msg "install_deps skipped"
    else
        ! check_root && \
            error_msg "About to install packages, please run this script as root."
        info_msg "Installing ${pkgs}"
        dist_name
        case "${dist}" in
          debian|ubuntu)
            last_apt_time=/tmp/apt-get-updated.last
            apt_cache_time=21600 # 6 hours
            # Only run apt-get update if it hasn't been run in $apt_cache_time seconds
            if [ ! -e ${last_apt_time} ] || \
               [ "$(stat --format=%Y ${last_apt_time})" -lt $(( $(date +%s) - apt_cache_time )) ]; then
                DEBIAN_FRONTEND=noninteractive apt-get update -q -y && touch ${last_apt_time}
            fi
            # shellcheck disable=SC2086
            DEBIAN_FRONTEND=noninteractive apt-get install -q -y ${pkgs}
            ;;
          centos)
            # shellcheck disable=SC2086
            yum -e 0 -y install ${pkgs}
            ;;
          fedora)
            # shellcheck disable=SC2086
            dnf -e 0 -y install ${pkgs}
            ;;
          *)
            warn_msg "Unsupported distro: ${dist}! Package installation skipped."
            ;;
        esac
        # shellcheck disable=SC2181
        if [ $? -ne 0 ]; then
            error_msg "Failed to install dependencies, exiting..."
        fi
    fi
}

create_out_dir() {
    [ -z "$1" ] && error_msg "Usage: create_out_dir output_dir"
    # shellcheck disable=SC2039
    local OUTPUT=$1
    [ -d "${OUTPUT}" ] &&
        mv "${OUTPUT}" "${OUTPUT}_$(date -r "${OUTPUT}" +%Y%m%d%H%M%S)"
    mkdir -p "${OUTPUT}"
    [ -d "${OUTPUT}" ] || error_msg "Could not create output directory ${OUTPUT}"
}

install() {
    dist_name
    # shellcheck disable=SC2154
    case "${dist}" in
        debian|ubuntu)
            install_deps lrzsz libdevice-serialport-perl expect fastboot
            ;;
        *)
            warn_msg "No package installation support on ${dist}"
            ;;
    esac
}

OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE
IMAGE="aarch64/ubuntu"

usage() {
    echo "$0 [-d <directory with u-boot binaries>] [-u <u-boot.img>] [-m <MLO>]" 1>&2
    exit 1
}

while getopts "u:m:d:h" o; do
    case "$o" in
        u) UBOOT_IMAGE="${OPTARG}" ;;
        m) MLO_IMAGE="${OPTARG}" ;;
		d) UBOOT_DIR="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

! check_root && error_msg "You need to be root to run this script."
create_out_dir "${OUTPUT}"

install

if [ ! -d "${UBOOT_DIR}" ]; then
	error_fatal "${UBOOT_DIR} doesn't exist"
fi

TTY=$(find /dev/ -xdev -name "ttyUSB*" -type c -print -quit)

if [ -f "${UBOOT_DIR}/${UBOOT_IMAGE}" ]; then
	cp "${UBOOT_DIR}/${UBOOT_IMAGE}" .
else
	error_fatal "${UBOOT_DIR}/${UBOOT_IMAGE} not found"
fi
./serial-download "${TTY}" || error_fatal "recovery failure"
report_pass "download_uboot_to_memory"
./u-boot_fastboot.expect "${TTY}"
report_pass "start_fastboot"
fastboot devices
fastboot oem format || error_fatal "oem format failed"
report_pass "format_emmc"
fastboot flash xloader "${UBOOT_DIR}/${MLO_IMAGE}" || error_fatal "xloader flash failed"
report_pass "flash_xloader"
fastboot flash bootloader "${UBOOT_DIR}/${UBOOT_IMAGE}" || error_fatal "bootloader flash failed"
report_pass "flash_bootloader"
