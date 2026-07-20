#!/bin/sh

set -eu

script_name=$(basename "$0")
codex_install_url="https://chatgpt.com/codex/install.sh"
codex_method="standalone"
skip_system_packages=0
installer_file=""
config_temp=""

usage() {
    printf '%s\n' "Usage: $script_name [--codex-method standalone|npm] [--skip-system-packages]"
    printf '%s\n' "Default: install tmux and the official standalone Codex CLI for the current non-root user."
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$installer_file" ] && [ -f "$installer_file" ]; then
        rm -f "$installer_file"
    fi
    if [ -n "$config_temp" ] && [ -f "$config_temp" ]; then
        rm -f "$config_temp"
    fi
}

trap cleanup 0 1 2 15

while [ "$#" -gt 0 ]; do
    case "$1" in
        --codex-method)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            codex_method=$2
            shift 2
            ;;
        --skip-system-packages)
            skip_system_packages=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$codex_method" in
    standalone|npm) ;;
    *)
        printf 'Unsupported Codex install method: %s\n' "$codex_method" >&2
        usage >&2
        exit 2
        ;;
esac

[ "$(uname -s)" = "Linux" ] || die "This installer only supports Linux targets."
[ "$(id -u)" -ne 0 ] || die "Run this script as the intended non-root Codex user; it uses sudo only for system packages."

os_id="unknown"
os_version="unknown"
if [ -r /etc/os-release ]; then
    os_id=$(sed -n 's/^ID=//p' /etc/os-release | head -n 1 | tr -d '"')
    os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n 1 | tr -d '"')
fi

printf 'Detected target: %s %s (%s), %s\n' "$os_id" "$os_version" "$(uname -s)" "$(uname -m)"

run_as_root() {
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "System packages are missing and sudo is unavailable. Install tmux, curl, and CA certificates, then rerun with --skip-system-packages."
    fi
}

install_system_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        run_as_root apt-get update
        run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y tmux curl ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        run_as_root dnf install -y tmux curl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        run_as_root yum install -y tmux curl ca-certificates
    elif command -v zypper >/dev/null 2>&1; then
        run_as_root zypper --non-interactive install tmux curl ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        run_as_root apk add --no-cache tmux curl ca-certificates
    elif command -v pacman >/dev/null 2>&1; then
        run_as_root pacman -S --needed --noconfirm tmux curl ca-certificates
    else
        die "Unsupported package manager. Install tmux, curl, and CA certificates with the native package manager, then rerun with --skip-system-packages."
    fi
}

missing_system_commands=""
command -v tmux >/dev/null 2>&1 || missing_system_commands="$missing_system_commands tmux"
command -v curl >/dev/null 2>&1 || missing_system_commands="$missing_system_commands curl"

if [ -n "$missing_system_commands" ]; then
    if [ "$skip_system_packages" -eq 1 ]; then
        die "Missing required commands:$missing_system_commands"
    fi
    printf 'Installing required system packages for:%s\n' "$missing_system_commands"
    install_system_packages
fi

command -v tmux >/dev/null 2>&1 || die "tmux is still unavailable after package installation."
command -v curl >/dev/null 2>&1 || die "curl is still unavailable after package installation."

printf 'tmux ready: %s\n' "$(tmux -V)"

PATH="$HOME/.local/bin:$HOME/bin:$HOME/.codex/packages/standalone/current:$PATH"
export PATH

case "$codex_method" in
    standalone)
        installer_file=$(mktemp "${TMPDIR:-/tmp}/codex-install.XXXXXX")
        printf 'Downloading the official Codex standalone installer from %s\n' "$codex_install_url"
        if ! curl -fsSL "$codex_install_url" -o "$installer_file"; then
            die "Unable to download the official Codex installer. Verify target access to chatgpt.com or retry with --codex-method npm when Node.js and npm are already available."
        fi
        if ! CODEX_NON_INTERACTIVE=1 sh "$installer_file" </dev/null; then
            die "The official Codex standalone installer failed."
        fi
        ;;
    npm)
        command -v node >/dev/null 2>&1 || die "Node.js is required for --codex-method npm."
        command -v npm >/dev/null 2>&1 || die "npm is required for --codex-method npm."
        if ! npm install -g @openai/codex; then
            die "npm installation failed. Do not retry with sudo; fix the current user's npm global prefix or use the standalone method."
        fi
        ;;
esac

command -v codex >/dev/null 2>&1 || die "Codex was installed but is not on PATH. Add the installer-reported bin directory to the user's shell profile and retry."

printf 'Codex ready: %s\n' "$(codex --version)"

configure_codex_full_access() {
    codex_dir="$HOME/.codex"
    config_file="$codex_dir/config.toml"
    block_start="# >>> codex-vpc-bridge full access >>>"
    block_end="# <<< codex-vpc-bridge full access <<<"

    umask 077
    mkdir -p "$codex_dir"
    touch "$config_file"
    config_temp=$(mktemp "$codex_dir/config.toml.XXXXXX")

    awk -v start="$block_start" -v end="$block_end" '
        BEGIN {
            print start
            print "approval_policy = \"never\""
            print "sandbox_mode = \"danger-full-access\""
            print end
            print ""
            root = 1
        }
        $0 == start { managed = 1; next }
        $0 == end { managed = 0; after_managed = 1; next }
        managed { next }
        after_managed && $0 == "" { after_managed = 0; next }
        after_managed { after_managed = 0 }
        root && $0 ~ /^\[/ { root = 0 }
        root && $0 ~ /^[[:space:]]*(approval_policy|sandbox_mode)[[:space:]]*=/ { next }
        { print }
    ' "$config_file" > "$config_temp"

    mv "$config_temp" "$config_file"
    config_temp=""
    chmod 600 "$config_file"
    codex --strict-config --version >/dev/null
    printf 'Codex default access: approval_policy=never, sandbox_mode=danger-full-access\n'
}

configure_codex_full_access

if command -v git >/dev/null 2>&1; then
    printf 'Git available: %s\n' "$(git --version)"
else
    printf '%s\n' 'Warning: Git is not installed. Codex can run, but Git is recommended for development checkpoints.' >&2
fi

if codex login status >/dev/null 2>&1; then
    printf '%s\n' 'Codex authentication: ready'
else
    printf '%s\n' 'Codex authentication: pending'
    printf '%s\n' 'For this headless target, run: codex login --device-auth'
fi

printf '%s\n' 'Target setup complete. Start a tmux session, then run codex from the project directory.'
