#!/usr/bin/env bash

set -euo pipefail

script_name=$(basename "$0")

usage() {
    printf '%s\n' "Usage: $script_name --target <user@host> [--identity <private-key>] [--profile <shell-profile>]"
    printf '%s\n' "Example: $script_name --target ubuntu@10.0.1.10"
}

target=""
identity=""
profile=""

while (( $# > 0 )); do
    case "$1" in
        --target)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            target=$2
            shift 2
            ;;
        --identity)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            identity=$2
            shift 2
            ;;
        --profile)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            profile=$2
            shift 2
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

if [[ -z "$target" || "$target" != *@* || "$target" =~ [[:space:]] ]]; then
    printf 'Target must use the form user@host: %s\n' "$target" >&2
    exit 2
fi

target_user=${target%%@*}
target_host=${target#*@}
if [[ -z "$target_user" || -z "$target_host" || "$target_host" == *@* ]]; then
    printf 'Target must use the form user@host: %s\n' "$target" >&2
    exit 2
fi

if [[ -n "$identity" ]]; then
    if [[ "$identity" == "~/"* ]]; then
        identity="$HOME/${identity:2}"
    elif [[ "$identity" != /* ]]; then
        identity="$PWD/$identity"
    fi
    if [[ ! -f "$identity" ]]; then
        printf 'Private key not found: %s\n' "$identity" >&2
        exit 2
    fi
    identity=$(cd "$(dirname "$identity")" && pwd -P)/$(basename "$identity")
fi

if [[ -z "$profile" ]]; then
    case "${SHELL##*/}" in
        zsh) profile="$HOME/.zshrc" ;;
        *) profile="$HOME/.bashrc" ;;
    esac
elif [[ "$profile" == "~/"* ]]; then
    profile="$HOME/${profile:2}"
elif [[ "$profile" != /* ]]; then
    profile="$PWD/$profile"
fi

ssh_dir="$HOME/.ssh"
ssh_config="$ssh_dir/config"
ssh_start="# >>> codex-vpc-bridge jump ssh >>>"
ssh_end="# <<< codex-vpc-bridge jump ssh <<<"
shell_start="# >>> codex-vpc-bridge tmux shortcuts >>>"
shell_end="# <<< codex-vpc-bridge tmux shortcuts <<<"

umask 077
mkdir -p "$ssh_dir" "$(dirname "$profile")"
touch "$ssh_config" "$profile"

strip_managed_block() {
    local file_path=$1
    local start=$2
    local end=$3
    local output=$4
    awk -v start="$start" -v end="$end" '
        $0 == start { managed = 1; next }
        $0 == end { managed = 0; next }
        !managed { print }
    ' "$file_path" > "$output"
}

identity_lines=""
if [[ -n "$identity" ]]; then
    identity_lines=$(printf '    IdentityFile "%s"\n    IdentitiesOnly yes' "$identity")
fi

ssh_block=$(cat <<EOF
$ssh_start
Host target
    HostName $target_host
    User $target_user
$identity_lines
$ssh_end
EOF
)

shell_block=""
IFS= read -r -d '' shell_block <<'EOF' || true
# >>> codex-vpc-bridge tmux shortcuts >>>
unalias l a k n 2>/dev/null || true

_tmux_session_by_number() {
    if [ "$#" -ne 1 ]; then
        printf '%s\n' 'Session number must be a positive integer.' >&2
        return 2
    fi
    case "$1" in
        ''|*[!0-9]*)
            printf '%s\n' 'Session number must be a positive integer.' >&2
            return 2
            ;;
    esac
    if [ "$1" -lt 1 ]; then
        printf '%s\n' 'Session number must be a positive integer.' >&2
        return 2
    fi

    local output
    output=$(command ssh target "tmux list-sessions -F '#{session_name}'") || return
    if [ -z "$output" ]; then
        printf '%s\n' 'No tmux sessions are available.' >&2
        return 2
    fi

    local session
    session=$(printf '%s\n' "$output" | sed -n "${1}p")
    if [ -z "$session" ]; then
        printf 'Session number %s does not exist. Run l to see available sessions.\n' "$1" >&2
        return 2
    fi
    case "$session" in
        *[!A-Za-z0-9_-]*)
            printf 'Unsupported tmux session name: %s\n' "$session" >&2
            return 2
            ;;
    esac

    TMUX_SESSION_NAME=$session
}

l() {
    local output
    output=$(command ssh target tmux list-sessions) || return
    printf '%s\n' "$output" | nl -w1 -s'. '
}

a() {
    if [ "$#" -ne 1 ]; then
        printf '%s\n' 'Usage: a <session-number>' >&2
        return 2
    fi

    _tmux_session_by_number "$1" || return
    TERM=xterm-256color command ssh -t target "tmux attach-session -t $TMUX_SESSION_NAME"
}

k() {
    if [ "$#" -ne 1 ]; then
        printf '%s\n' 'Usage: k <session-number>' >&2
        return 2
    fi

    _tmux_session_by_number "$1" || return
    command ssh target "tmux kill-session -t $TMUX_SESSION_NAME" || return
    l
}

n() {
    if [ "$#" -ne 1 ]; then
        printf '%s\n' 'Usage: n <session-name>' >&2
        return 2
    fi
    case "$1" in
        ''|*[!A-Za-z0-9_-]*)
            printf '%s\n' 'Usage: n <session-name>; use letters, numbers, underscores, or hyphens.' >&2
            return 2
            ;;
    esac

    TERM=xterm-256color command ssh -t target "tmux new-session -s $1"
}
# <<< codex-vpc-bridge tmux shortcuts <<<
EOF

ssh_clean=$(mktemp)
profile_clean=$(mktemp)
trap 'rm -f "$ssh_clean" "$profile_clean"' EXIT

strip_managed_block "$ssh_config" "$ssh_start" "$ssh_end" "$ssh_clean"
{
    printf '%s\n' "$ssh_block"
    if [[ -s "$ssh_clean" ]]; then
        printf '\n'
        cat "$ssh_clean"
    fi
} > "$ssh_config"
chmod 600 "$ssh_config"

strip_managed_block "$profile" "$shell_start" "$shell_end" "$profile_clean"
{
    cat "$profile_clean"
    if [[ -s "$profile_clean" ]]; then
        printf '\n'
    fi
    printf '%s\n' "$shell_block"
} > "$profile"

printf 'Installed target SSH host in %s\n' "$ssh_config"
printf 'Installed remote tmux shortcuts in %s\n' "$profile"
printf 'Reload with: source %s\n' "$profile"
if [[ -z "$identity" ]]; then
    printf '%s\n' 'Authentication uses SSH agent forwarding or the jump host default SSH credentials.'
fi
