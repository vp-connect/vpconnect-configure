#!/usr/bin/env bash
# 03_getconfigure
#
# Клонирует или обновляет репозиторий конфигурации и переключается на ветку
# VPCONFIGURE_GIT_BRANCH (freebsd | debian | centos), затем git pull.
# После клонирования каталог .git удаляется (на целевой системе история не нужна).
# Если целевой путь уже есть и это git-репозиторий — выполняется fetch/pull. Иначе при непустом
# пути (файл, каталог с файлами) он удаляется и выполняется новое клонирование; пустой каталог
# сохраняется и в него клонируют.
#
# Сначала stdout: одна строка result:…; message:… (и доп. поля), пояснения — stderr.
#
# Использование:
#   bash ./03_getconfigure.sh
#   bash ./03_getconfigure.sh --repo URL --dir PATH
#   bash ./03_getconfigure.sh -r URL -d ~/vpconnect-configure
#
# Переменные окружения (опционально, перекрывают умолчания до разбора CLI):
#   VPCONFIGURE_REPO_URL — URL репозитория
#   VPCONFIGURE_INSTALL_DIR — каталог клона

set -euo pipefail

DEFAULT_REPO='https://github.com/vp-connect/vpconnect-configure.git'
DEFAULT_DIR='./vpconnect-configure'

vp_sanitize_msg() {
  local s="$*"
  s="${s//;/,}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

vp_result_line() {
  local status=$1
  shift
  local msg
  msg="$(vp_sanitize_msg "$1")"
  shift
  local out="result:${status}; message:${msg}"
  while [[ $# -gt 0 ]]; do
    out+="; $(vp_sanitize_msg "$1")"
    shift
  done
  printf '%s\n' "$out"
}

die() {
  vp_result_line error "$*"
  exit 1
}

usage() {
  vp_result_line success "Справка выведена в stderr"
  cat >&2 <<EOF
Клонирование или обновление репозитория vpconnect-configure.

  -r, --repo URL   URL git (по умолчанию ${DEFAULT_REPO})
  -d, --dir PATH   каталог (по умолчанию ${DEFAULT_DIR})

Нужна переменная VPCONFIGURE_GIT_BRANCH из 01_getosversion.sh (freebsd, debian, centos).

Пример:
  export VPCONFIGURE_GIT_BRANCH=debian
  bash ./03_getconfigure.sh -d /root/vpconnect-configure
EOF
}

expand_tilde() {
  local p=$1
  if [[ "$p" == '~' || "$p" == ~/* ]]; then
    p="${p/\~/$HOME}"
  fi
  printf '%s' "$p"
}

require_git() {
  command -v git >/dev/null 2>&1 || die "git не найден в PATH, сначала 02_gitinstall.sh"
}

require_branch_var() {
  local b="${VPCONFIGURE_GIT_BRANCH:-}"
  [[ -n "$b" ]] || die "VPCONFIGURE_GIT_BRANCH не задана, сначала 01_getosversion.sh"
  b="${b,,}"
  case "$b" in
    freebsd|debian|centos) printf '%s' "$b" ;;
    *) die "Неверная VPCONFIGURE_GIT_BRANCH: ${VPCONFIGURE_GIT_BRANCH:-} (нужно freebsd, debian или centos)" ;;
  esac
}

assert_branch_matches_os() {
  local branch=$1
  local sys
  sys="$(uname -s)"
  case "$branch" in
    freebsd)
      [[ "$sys" == FreeBSD ]] || die "VPCONFIGURE_GIT_BRANCH=freebsd, но uname: $sys"
      ;;
    debian|centos)
      [[ "$sys" == Linux ]] || die "VPCONFIGURE_GIT_BRANCH=$branch, но uname: $sys (ожидался Linux)"
      ;;
  esac
}

# Есть ли в каталоге хотя бы один элемент (включая скрытые). Только для обычных каталогов.
dir_is_nonempty() (
  [[ -d "${1:-}" ]] || exit 1
  shopt -s dotglob nullglob 2>/dev/null || true
  local -a entries=( "$1"/* )
  [[ ${#entries[@]} -gt 0 ]]
)

# Проверка наличия ветки на origin после fetch (refs/remotes/origin/$branch).
remote_branch_exists() {
  local dir=$1
  local branch=$2
  git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/${branch}"
}

clone_repo() {
  local repo=$1
  local dir=$2
  local branch=$3
  local parent
  parent="$(dirname -- "$dir")"
  [[ -d "$parent" ]] || mkdir -p "$parent" || die "Не удалось создать каталог: $parent"

  if [[ -e "$dir" ]]; then
    [[ -d "$dir" ]] || die "Путь для clone существует и не каталог: $dir"
    dir_is_nonempty "$dir" && die "Внутренняя ошибка: каталог для clone не пуст: $dir"
  fi

  local err
  if ! err=$(GIT_TERMINAL_PROMPT=0 git clone \
    --branch "$branch" \
    --single-branch \
    --origin origin \
    "$repo" "$dir" 2>&1); then
    printf '%s\n' "$err" >&2
    case "$err" in
      *"Remote branch"* | *"remote branch"* | *"not found in upstream"* | *"Couldn't find remote ref"*)
        die "На удалённом репозитории нет ветки ${branch}, создайте её на origin или проверьте URL"
        ;;
      *"Could not resolve host"* | *"unable to access"* | *"Connection refused"* | *"timed out"* | *"Network is unreachable"* | *"Could not connect"*)
        die "Нет доступа к репозиторию по сети или DNS, проверьте соединение и URL"
        ;;
      *"Authentication failed"* | *"could not read Username"* | *"403"* | *"401"*)
        die "Отказ доступа к репозиторию, проверьте права и credentials для ${repo}"
        ;;
    esac
    die "git clone не выполнен: $(vp_sanitize_msg "$err")"
  fi
}

# Удаляет метаданные git после клона. В git нет отдельной команды «снять репозиторий» — удаляем каталог .git.
remove_git_dir() {
  local dir=$1
  local gitmeta="${dir}/.git"
  [[ -e "$gitmeta" ]] || return 0
  rm -rf -- "$gitmeta" || die "Не удалось удалить ${gitmeta}"
}

update_repo() {
  local dir=$1
  local repo=$2
  local branch=$3

  [[ -d "${dir}/.git" ]] || die "Каталог не git-репозиторий: $dir"

  local err
  if ! err=$(git -C "$dir" remote set-url origin "$repo" 2>&1); then
    printf '%s\n' "$err" >&2
    die "Не удалось установить URL remote origin"
  fi

  if ! err=$(GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch origin 2>&1); then
    printf '%s\n' "$err" >&2
    case "$err" in
      *"Could not resolve host"* | *"unable to access"* | *"Connection refused"* | *"timed out"* | *"Network is unreachable"* | *"Could not connect"*)
        die "git fetch не выполнен, нет доступа к сети или к origin"
        ;;
      *"Authentication failed"* | *"could not read Username"* | *"403"* | *"401"*)
        die "Отказ доступа при fetch, проверьте credentials для ${repo}"
        ;;
    esac
    die "git fetch не выполнен: $(vp_sanitize_msg "$err")"
  fi

  if ! remote_branch_exists "$dir" "$branch"; then
    die "На origin нет ветки ${branch}, выполните git push с машины разработки или выберите другую ветку"
  fi

  if ! err=$(git -C "$dir" checkout "$branch" 2>&1); then
    printf '%s\n' "$err" >&2
    die "Не удалось переключиться на ветку ${branch}: $(vp_sanitize_msg "$err")"
  fi

  if ! err=$(GIT_TERMINAL_PROMPT=0 git -C "$dir" pull --ff-only origin "$branch" 2>&1); then
    printf '%s\n' "$err" >&2
    if [[ "$err" == *"Not possible to fast-forward"* || "$err" == *"non-fast-forward"* ]]; then
      die "Ветка ${branch} разошлась с origin, нужно вручную: git pull с rebase или merge в $dir"
    fi
    die "git pull не выполнен: $(vp_sanitize_msg "$err")"
  fi
}

main() {
  local repo="${VPCONFIGURE_REPO_URL:-$DEFAULT_REPO}"
  local target_dir="${VPCONFIGURE_INSTALL_DIR:-$DEFAULT_DIR}"
  local branch

  while [[ $# -gt 0 ]]; do
    case $1 in
      -r|--repo)
        [[ $# -ge 2 ]] || die "После $1 нужен URL"
        repo=$2
        shift 2
        ;;
      -d|--dir)
        [[ $# -ge 2 ]] || die "После $1 нужен путь"
        target_dir=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Неизвестный аргумент: $1"
        ;;
    esac
  done

  target_dir="$(expand_tilde "$target_dir")"

  require_git
  branch="$(require_branch_var)"
  assert_branch_matches_os "$branch"

  export GIT_TERMINAL_PROMPT=0

  local short

  if [[ -d "${target_dir}/.git" ]]; then
    printf 'Обновление существующего репозитория: %s\n' "$target_dir" >&2
    update_repo "$target_dir" "$repo" "$branch"
    short="$(git -C "$target_dir" rev-parse --short HEAD 2>/dev/null || printf '?')"
  else
    if [[ -e "$target_dir" ]]; then
      if [[ -f "$target_dir" || -L "$target_dir" ]] || { [[ -d "$target_dir" ]] && dir_is_nonempty "$target_dir"; }; then
        printf 'Путь %s уже занят (не git или не пустой каталог), удаляю и клонирую заново\n' "$target_dir" >&2
        rm -rf -- "$target_dir" || die "Не удалось удалить: $target_dir"
      fi
    fi
    printf 'Клонирование в %s, ветка %s\n' "$target_dir" "$branch" >&2
    clone_repo "$repo" "$target_dir" "$branch"
    short="$(git -C "$target_dir" rev-parse --short HEAD 2>/dev/null || printf '?')"
    printf 'Удаление каталога .git (история репозитория на целевой системе не нужна)\n' >&2
    remove_git_dir "$target_dir"
  fi
  vp_result_line success "репозиторий готов" "path:${target_dir}" "branch:${branch}" "commit:${short}" "remote:${repo}"
}

main "$@"
