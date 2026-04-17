#!/bin/sh
set -e

# 00_bashinstall.sh
#
# Проверяет bash; при отсутствии ставит пакет.
# На Linux дополнительно гарантирует ``ss`` (пакет iproute2 / iproute) для предпроверки портов
# в vpconnect-install (после этого скрипта, до 01_getosversion.sh).
# Список ОС и версий совпадает с 01_getosversion.sh (только поддерживаемые).
# Запуск до появления bash: sh ./00_bashinstall.sh
# Сначала на stdout — строка result:…, затем (при необходимости) подсказки в stderr.

vp_sanitize() {
	printf '%s' "$1" | tr ';' ','
}

# Доп. поля: vp_result_line status "msg" "key:value" ...
vp_result_line() {
	_st=$1
	shift
	_msg=$(vp_sanitize "$1")
	shift
	_line="result:${_st}; message:${_msg}"
	while [ $# -gt 0 ]; do
		_kv=$(vp_sanitize "$1")
		_line="${_line}; ${_kv}"
		shift
	done
	printf '%s\n' "$_line"
}

die() {
	vp_result_line error "$*"
	exit 1
}

lc() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

trim_quotes() {
	_v=$1
	_v=$(printf '%s' "$_v" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
	printf '%s' "$_v"
}

install_debian_family() {
	DEBIAN_FRONTEND=noninteractive
	export DEBIAN_FRONTEND
	apt-get update -y
	apt-get install -y bash iproute2
}

install_debian_iproute2_only() {
	DEBIAN_FRONTEND=noninteractive
	export DEBIAN_FRONTEND
	apt-get update -y
	apt-get install -y iproute2
}

install_rhel_family() {
	if command -v dnf >/dev/null 2>&1; then
		dnf install -y bash iproute
	elif command -v yum >/dev/null 2>&1; then
		yum install -y bash iproute
	else
		die "Neither dnf nor yum found (RHEL-like)"
	fi
}

install_rhel_iproute_only() {
	if command -v dnf >/dev/null 2>&1; then
		dnf install -y iproute
	elif command -v yum >/dev/null 2>&1; then
		yum install -y iproute
	else
		die "Neither dnf nor yum found (RHEL-like)"
	fi
}

freebsd_major() {
	_m=$(freebsd-version 2>/dev/null | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
	[ -n "$_m" ] || _m=$(uname -r | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
	printf '%s' "$_m"
}

freebsd_pkg_failed_hint() {
	cat >&2 <<'HINT'
pkg could not fetch the catalogue (404 / meta.txz Not Found / Unable to update repository).

Common causes:
 • Release is EOL or unsupported: official packages may be gone — upgrade the OS (e.g. FreeBSD 13/14+) or fix repo URLs.
 • Wrong or stale mirror in pkg config — edit repo files under /usr/local/etc/pkg/repos/ (often change "quarterly" to "latest" in the url line), then: pkg update -f

Docs: https://docs.freebsd.org/en/books/handbook/pkgng/
HINT
}

install_freebsd() {
	_maj=$(freebsd_major)
	[ -n "$_maj" ] || die "Cannot detect FreeBSD version"
	case "$_maj" in
	13|14) ;;
	*) die "Unsupported FreeBSD version: $_maj (supported: 13, 14)" ;;
	esac
	if ! command -v pkg >/dev/null 2>&1; then
		POST_NOTE="run pkg bootstrap if needed: /usr/sbin/pkg bootstrap -f"
	fi
	if ! env ASSUME_ALWAYS_YES=yes pkg install -y bash; then
		vp_result_line error "pkg install bash failed"
		freebsd_pkg_failed_hint
		exit 1
	fi
}

# Установить iproute2/iproute, если нет ss (та же матрица ОС, что install_linux).
ensure_linux_ss() {
	command -v ss >/dev/null 2>&1 && return 0
	[ -r /etc/os-release ] || die "Cannot read /etc/os-release"
	# shellcheck disable=SC1091
	. /etc/os-release

	id=$(lc "$(trim_quotes "${ID:-}")")
	version_id=$(trim_quotes "${VERSION_ID:-}")
	id_like=$(lc "$(trim_quotes "${ID_LIKE:-}")")

	[ -n "$id" ] || die "OS ID is empty in /etc/os-release"
	[ -n "$version_id" ] || die "OS VERSION_ID is empty in /etc/os-release"

	case "$id" in
	ubuntu)
		case "$version_id" in
		22.04|24.04|26.04) install_debian_iproute2_only ;;
		*) die "Unsupported Ubuntu version: $version_id (supported LTS: 22.04, 24.04, 26.04)" ;;
		esac
		;;

	debian)
		case "$version_id" in
		12|13) install_debian_iproute2_only ;;
		*) die "Unsupported Debian version: $version_id (supported: 12, 13)" ;;
		esac
		;;

	linuxmint|pop|kali|raspbian|elementary|zorin|devuan)
		case " $id_like " in
		*" debian "*|*" ubuntu "*) install_debian_iproute2_only ;;
		*) die "Unsupported Debian-like distro: ID=$id (ID_LIKE=$id_like)" ;;
		esac
		;;

	almalinux)
		case "$version_id" in
		9*|10*) install_rhel_iproute_only ;;
		*) die "Unsupported AlmaLinux version: $version_id (supported: 9, 10)" ;;
		esac
		;;

	rocky)
		case "$version_id" in
		8*|9*) install_rhel_iproute_only ;;
		*) die "Unsupported Rocky Linux version: $version_id (supported: 8, 9)" ;;
		esac
		;;

	centos)
		die "CentOS Linux is end-of-life; use Rocky Linux, AlmaLinux, Oracle Linux, or RHEL"
		;;

	vzlinux|virtuozzo)
		case "$version_id" in
		8*) install_rhel_iproute_only ;;
		*) die "Unsupported VzLinux/Virtuozzo version: $version_id (supported: 8.x)" ;;
		esac
		;;

	ol|eurolinux|cloudlinux)
		case "$version_id" in
		8*|9*|10*) install_rhel_iproute_only ;;
		*) die "Unsupported $id version: $version_id (supported: 8.x–10.x)" ;;
		esac
		;;

	amzn)
		case "$version_id" in
		2) die "Amazon Linux 2 is not supported; use Amazon Linux 2023 or newer" ;;
		*) install_rhel_iproute_only ;;
		esac
		;;

	rhel)
		case "$version_id" in
		8*|9*|10*) install_rhel_iproute_only ;;
		*) die "Unsupported RHEL version: $version_id (supported: 8, 9, 10)" ;;
		esac
		;;

	fedora)
		case "$version_id" in
		3[9]|4[0-9]|5[0-9]|6[0-9]) install_rhel_iproute_only ;;
		*) die "Unsupported Fedora version: $version_id (supported: 39+)" ;;
		esac
		;;

	scientific)
		die "Scientific Linux is end-of-life; migrate to Rocky Linux or AlmaLinux"
		;;

	*)
		case " $id_like " in
		*" debian "*|*" ubuntu "*) install_debian_iproute2_only ;;
		*" rhel "*|*" fedora "*) install_rhel_iproute_only ;;
		*" centos "*)
			die "Unsupported: ID_LIKE suggests CentOS Linux (EOL); use Rocky Linux, AlmaLinux, or Oracle Linux"
			;;
		*) die "Unsupported Linux distro for iproute install: ID=$id (ID_LIKE=$id_like)" ;;
		esac
		;;
	esac
}

install_linux() {
	[ -r /etc/os-release ] || die "Cannot read /etc/os-release"
	# shellcheck disable=SC1091
	. /etc/os-release

	id=$(lc "$(trim_quotes "${ID:-}")")
	version_id=$(trim_quotes "${VERSION_ID:-}")
	id_like=$(lc "$(trim_quotes "${ID_LIKE:-}")")

	[ -n "$id" ] || die "OS ID is empty in /etc/os-release"
	[ -n "$version_id" ] || die "OS VERSION_ID is empty in /etc/os-release"

	case "$id" in
	ubuntu)
		case "$version_id" in
		22.04|24.04|26.04) install_debian_family ;;
		*) die "Unsupported Ubuntu version: $version_id (supported LTS: 22.04, 24.04, 26.04)" ;;
		esac
		;;

	debian)
		case "$version_id" in
		12|13) install_debian_family ;;
		*) die "Unsupported Debian version: $version_id (supported: 12, 13)" ;;
		esac
		;;

	linuxmint|pop|kali|raspbian|elementary|zorin|devuan)
		case " $id_like " in
		*" debian "*|*" ubuntu "*) install_debian_family ;;
		*) die "Unsupported Debian-like distro: ID=$id (ID_LIKE=$id_like)" ;;
		esac
		;;

	almalinux)
		case "$version_id" in
		9*|10*) install_rhel_family ;;
		*) die "Unsupported AlmaLinux version: $version_id (supported: 9, 10)" ;;
		esac
		;;

	rocky)
		case "$version_id" in
		8*|9*) install_rhel_family ;;
		*) die "Unsupported Rocky Linux version: $version_id (supported: 8, 9)" ;;
		esac
		;;

	centos)
		die "CentOS Linux is end-of-life; use Rocky Linux, AlmaLinux, Oracle Linux, or RHEL"
		;;

	vzlinux|virtuozzo)
		case "$version_id" in
		8*) install_rhel_family ;;
		*) die "Unsupported VzLinux/Virtuozzo version: $version_id (supported: 8.x)" ;;
		esac
		;;

	ol|eurolinux|cloudlinux)
		case "$version_id" in
		8*|9*|10*) install_rhel_family ;;
		*) die "Unsupported $id version: $version_id (supported: 8.x–10.x)" ;;
		esac
		;;

	amzn)
		case "$version_id" in
		2) die "Amazon Linux 2 is not supported; use Amazon Linux 2023 or newer" ;;
		*) install_rhel_family ;;
		esac
		;;

	rhel)
		case "$version_id" in
		8*|9*|10*) install_rhel_family ;;
		*) die "Unsupported RHEL version: $version_id (supported: 8, 9, 10)" ;;
		esac
		;;

	fedora)
		case "$version_id" in
		3[9]|4[0-9]|5[0-9]|6[0-9]) install_rhel_family ;;
		*) die "Unsupported Fedora version: $version_id (supported: 39+)" ;;
		esac
		;;

	scientific)
		die "Scientific Linux is end-of-life; migrate to Rocky Linux or AlmaLinux"
		;;

	*)
		case " $id_like " in
		*" debian "*|*" ubuntu "*) install_debian_family ;;
		*" rhel "*|*" fedora "*) install_rhel_family ;;
		*" centos "*)
			die "Unsupported: ID_LIKE suggests CentOS Linux (EOL); use Rocky Linux, AlmaLinux, or Oracle Linux"
			;;
		*) die "Unsupported Linux distro for bash install: ID=$id (ID_LIKE=$id_like)" ;;
		esac
		;;
	esac
}

POST_NOTE=""
NEED_BASH=1
if command -v bash >/dev/null 2>&1; then
	NEED_BASH=0
fi

if [ "$NEED_BASH" -eq 1 ]; then
	case "$(uname -s)" in
	Linux)
		install_linux
		;;
	FreeBSD)
		install_freebsd
		;;
	*)
		die "Unsupported OS: $(uname -s)"
		;;
	esac
fi

case "$(uname -s)" in
Linux)
	ensure_linux_ss
	;;
esac

command -v bash >/dev/null 2>&1 || die "bash not found in PATH after install"
_p=$(command -v bash)
_ver=$(bash --version | head -n 1 | tr ';' ',')

if [ "$NEED_BASH" -eq 1 ]; then
	_msg="bash установлен; на Linux также установлены iproute2/iproute (команда ss), где применимо"
else
	_msg="bash уже установлен; при необходимости установлен iproute2/iproute для ss (Linux)"
fi

vp_result_line success "$_msg" "path:${_p}" "version:${_ver}"
if [ -n "${POST_NOTE:-}" ]; then
	printf 'Note: %s\n' "$POST_NOTE" >&2
fi
