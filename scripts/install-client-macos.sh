#!/bin/zsh

set -euo pipefail

script_name=${0:t}

usage() {
    print -r -- "Usage: $script_name --jump <user@host> --target <user@host> [--identity <private-key>]"
    print -r -- "Example: $script_name --jump ubuntu@jump.example.com --target ubuntu@10.0.1.10"
}

jump=""
target=""
identity="$HOME/.ssh/id_rsa"

while (( $# > 0 )); do
    case "$1" in
        --jump)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            jump=$2
            shift 2
            ;;
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
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 -r -- "Unknown argument: $1"
            usage >&2
            exit 2
            ;;
    esac
done

validate_destination() {
    local label=$1
    local value=$2
    if [[ "$value" != *@* || "$value" == *[[:space:]]* ]]; then
        print -u2 -r -- "$label must use the form user@host: $value"
        exit 2
    fi

    local user=${value%%@*}
    local host=${value#*@}
    if [[ -z "$user" || -z "$host" || "$host" == *@* ]]; then
        print -u2 -r -- "$label must use the form user@host: $value"
        exit 2
    fi
}

[[ -n "$jump" && -n "$target" ]] || { usage >&2; exit 2; }
validate_destination jump "$jump"
validate_destination target "$target"

jump_user=${jump%%@*}
jump_host=${jump#*@}
target_user=${target%%@*}
target_host=${target#*@}

case "$identity" in
    "~/"*) identity="$HOME/${identity:2}" ;;
esac
identity=${identity:A}
if [[ ! -f "$identity" ]]; then
    print -u2 -r -- "Private key not found: $identity"
    exit 2
fi

ssh_dir="$HOME/.ssh"
ssh_config="$ssh_dir/config"
zshrc="$HOME/.zshrc"
ssh_start="# >>> codex-vpc-bridge client ssh >>>"
ssh_end="# <<< codex-vpc-bridge client ssh <<<"
shell_start="# >>> codex-vpc-bridge tmux shortcuts >>>"
shell_end="# <<< codex-vpc-bridge tmux shortcuts <<<"

umask 077
mkdir -p "$ssh_dir"
touch "$ssh_config" "$zshrc"

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

ssh_block=$(cat <<EOF
$ssh_start
Host jump
    HostName $jump_host
    User $jump_user
    IdentityFile "$identity"
    IdentitiesOnly yes
    ForwardAgent yes

Host target
    HostName $target_host
    User $target_user
    IdentityFile "$identity"
    IdentitiesOnly yes
    ProxyJump jump
$ssh_end
EOF
)

shell_block=$(cat <<'EOF'
# >>> codex-vpc-bridge tmux shortcuts >>>
unalias l a k n 2>/dev/null || true

_tmux_session_by_number() {
    if [[ $# -ne 1 || $1 != <-> || $1 -lt 1 ]]; then
        print -u2 'Session number must be a positive integer.'
        return 2
    fi

    local output
    output=$(command ssh target "tmux list-sessions -F '#{session_name}'") || return
    if [[ -z "$output" ]]; then
        print -u2 'No tmux sessions are available.'
        return 2
    fi

    local -a sessions
    sessions=("${(@f)output}")
    if (( $1 > ${#sessions} )); then
        print -u2 "Session number $1 does not exist. Run l to see available sessions."
        return 2
    fi

    REPLY=${sessions[$1]}
}

l() {
    local output
    output=$(command ssh target tmux list-sessions) || return
    print -r -- "$output" | command nl -w1 -s'. '
}

a() {
    if [[ $# -ne 1 ]]; then
        print -u2 'Usage: a <session-number>'
        return 2
    fi

    _tmux_session_by_number "$1" || return
    local session=$REPLY
    TERM=xterm-256color command ssh -t target "tmux attach-session -t ${(q)session}"
}

k() {
    if [[ $# -ne 1 ]]; then
        print -u2 'Usage: k <session-number>'
        return 2
    fi

    _tmux_session_by_number "$1" || return
    local session=$REPLY
    command ssh target "tmux kill-session -t ${(q)session}" || return
    l
}

n() {
    if [[ $# -ne 1 || -z "$1" || "$1" == *[^A-Za-z0-9_-]* ]]; then
        print -u2 'Usage: n <session-name>; use letters, numbers, underscores, or hyphens.'
        return 2
    fi

    TERM=xterm-256color command ssh -t target "tmux new-session -s ${(q)1}"
}
# <<< codex-vpc-bridge tmux shortcuts <<<
EOF
)

ssh_clean=$(mktemp "${TMPDIR:-/tmp}/codex-vpc-bridge-ssh.XXXXXX")
zsh_clean=$(mktemp "${TMPDIR:-/tmp}/codex-vpc-bridge-zsh.XXXXXX")
trap 'rm -f "$ssh_clean" "$zsh_clean"' EXIT

strip_managed_block "$ssh_config" "$ssh_start" "$ssh_end" "$ssh_clean"
{
    print -r -- "$ssh_block"
    if [[ -s "$ssh_clean" ]]; then
        print
        cat "$ssh_clean"
    fi
} > "$ssh_config"
chmod 600 "$ssh_config"

strip_managed_block "$zshrc" "$shell_start" "$shell_end" "$zsh_clean"
{
    cat "$zsh_clean"
    if [[ -s "$zsh_clean" ]]; then
        print
    fi
    print -r -- "$shell_block"
} > "$zshrc"

print -r -- "Installed client SSH hosts in $ssh_config"
print -r -- "Installed remote tmux shortcuts in $zshrc"
print -r -- "Reload with: source $zshrc"
