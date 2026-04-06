#!/usr/bin/env bash
# shellcheck shell=bash
# Идемпотентные проверки ufw: не добавлять второе правило для того же порта/протокола.

vp_ufw_has_port() {
  local port=$1
  local proto=${2:-tcp}
  command -v ufw >/dev/null 2>&1 || return 1
  LANG=C ufw status 2>/dev/null | grep -qF "${port}/${proto}"
}
