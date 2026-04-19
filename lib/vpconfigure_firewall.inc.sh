#!/usr/bin/env bash
# shellcheck shell=bash
# Общие firewall-хелперы для centos-ветки (firewalld).
# Функции идемпотентны: проверяют наличие правила перед добавлением.

vp_firewalld_is_active() {
  command -v firewall-cmd >/dev/null 2>&1 || return 1
  systemctl is-active --quiet firewalld 2>/dev/null
}

vp_firewalld_has_port() {
  local port=$1
  local proto=${2:-tcp}
  vp_firewalld_is_active || return 1
  firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -qx "${port}/${proto}"
}

vp_firewalld_add_port() {
  local port=$1
  local proto=${2:-tcp}
  vp_firewalld_is_active || return 1
  if vp_firewalld_has_port "$port" "$proto"; then
    return 0
  fi
  firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || return 1
  firewall-cmd --add-port="${port}/${proto}" >/dev/null 2>&1 || return 1
  firewall-cmd --reload >/dev/null 2>&1 || return 1
}
