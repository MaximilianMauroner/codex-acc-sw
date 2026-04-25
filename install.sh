#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="MaximilianMauroner"
REPO_NAME="codex-acc-sw"
COMMAND_NAME="codex-account-switch"

die() { echo "[ERR] $*" >&2; exit 1; }
note() { echo "[*] $*"; }
ok() { echo "[OK] $*"; }

usage() {
  cat <<EOF
Install ${COMMAND_NAME} from GitHub releases.

Usage: install.sh [OPTIONS]

Options:
  --prefix PATH      Install under PATH
  --alias            Also install the 'acc-sw' alias
  --no-alias         Do not install the 'acc-sw' alias
  --user             Install into ~/.local
  --system           Install into /usr/local
  --version VERSION  Install a specific release tag (for example: v0.1.0)
  -h, --help         Show this help

Environment:
  PREFIX             Same as --prefix
  VERSION            Same as --version
  INSTALL_ALIAS      Set to 1 to install the 'acc-sw' alias

Examples:
  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/install.sh | bash -s -- --alias
  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/install.sh | bash -s -- --version v0.1.0
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

resolve_default_prefix() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "/usr/local"
  else
    echo "${HOME}/.local"
  fi
}

resolve_latest_version() {
  python3 - <<'PY'
import json
import urllib.request

headers = {"User-Agent": "codex-account-switch-installer"}
release_url = "https://api.github.com/repos/MaximilianMauroner/codex-acc-sw/releases/latest"
tags_url = "https://api.github.com/repos/MaximilianMauroner/codex-acc-sw/tags"

def fetch(url):
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)

try:
    payload = fetch(release_url)
    tag = payload.get("tag_name")
    if tag:
        print(tag)
        raise SystemExit(0)
except Exception:
    pass

try:
    tags = fetch(tags_url)
    if tags and tags[0].get("name"):
        print(tags[0]["name"])
        raise SystemExit(0)
except Exception:
    pass

raise SystemExit("No GitHub release or tag found. Create a tag such as v0.1.0 first.")
PY
}

PREFIX="${PREFIX:-}"
VERSION="${VERSION:-}"
INSTALL_ALIAS="${INSTALL_ALIAS:-0}"

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --prefix)
      shift
      [[ $# -gt 0 ]] || die "--prefix requires a path"
      PREFIX="$1"
      ;;
    --alias)
      INSTALL_ALIAS="1"
      ;;
    --no-alias)
      INSTALL_ALIAS="0"
      ;;
    --user)
      PREFIX="${HOME}/.local"
      ;;
    --system)
      PREFIX="/usr/local"
      ;;
    --version)
      shift
      [[ $# -gt 0 ]] || die "--version requires a tag"
      VERSION="$1"
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift
done

need_cmd bash
need_cmd curl
need_cmd tar
need_cmd make
need_cmd python3

PREFIX="${PREFIX:-$(resolve_default_prefix)}"
VERSION="${VERSION:-$(resolve_latest_version)}"

case "$INSTALL_ALIAS" in
  0|1) ;;
  *) die "INSTALL_ALIAS must be 0 or 1" ;;
esac

TARBALL_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/tags/${VERSION}.tar.gz"
TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

note "Downloading ${COMMAND_NAME} ${VERSION}..."
curl -fsSL "$TARBALL_URL" -o "${TMPDIR}/release.tar.gz"
tar -xzf "${TMPDIR}/release.tar.gz" -C "$TMPDIR"

SRC_DIR="${TMPDIR}/${REPO_NAME}-${VERSION#v}"
if [[ ! -d "$SRC_DIR" ]]; then
  SRC_DIR="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
fi
[[ -d "$SRC_DIR" ]] || die "Failed to unpack release archive"

note "Installing into ${PREFIX}..."
make -C "$SRC_DIR" install "PREFIX=${PREFIX}" "INSTALL_ALIAS=${INSTALL_ALIAS}"

ok "Installed ${COMMAND_NAME} ${VERSION}."
echo "  binary: ${PREFIX}/bin/${COMMAND_NAME}"
echo "  helper: ${PREFIX}/libexec/${COMMAND_NAME}"
if [[ "$INSTALL_ALIAS" == "1" ]]; then
  echo "  alias:  ${PREFIX}/bin/acc-sw"
fi

case ":${PATH}:" in
  *":${PREFIX}/bin:"*) ;;
  *)
    echo
    echo "Add ${PREFIX}/bin to PATH if needed:"
    echo "  export PATH=\"${PREFIX}/bin:\$PATH\""
    ;;
esac
