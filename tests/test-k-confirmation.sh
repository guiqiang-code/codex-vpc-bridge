#!/bin/sh

set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-vpc-bridge-k.XXXXXX")
fake_bin="$project_dir/tests/fixtures"
log_file="$test_root/ssh.log"

cleanup() {
    rm -rf "$test_root"
}
trap cleanup 0 1 2 15

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

reset_log() {
    rm -f "$log_file"
    touch "$log_file"
}

assert_single_managed_block() {
    profile_path=$1
    count=$(grep -c '^# >>> codex-vpc-bridge tmux shortcuts >>>$' "$profile_path")
    [ "$count" -eq 1 ] ||
        fail "$profile_path: repeated installation created $count managed blocks"
}

run_k() {
    shell_path=$1
    profile_path=$2
    input=$3

    printf '%s' "$input" |
        HOME=$(dirname "$profile_path") \
        PROFILE_PATH="$profile_path" \
        FAKE_SSH_LOG="$log_file" \
        PATH="$fake_bin:$PATH" \
        "$shell_path" -c '. "$PROFILE_PATH"; k 1'
}

assert_default_kills() {
    shell_path=$1
    profile_path=$2

    reset_log
    run_k "$shell_path" "$profile_path" '
' >/dev/null
    grep -F 'tmux kill-session -t pop-dev1' "$log_file" >/dev/null ||
        fail "$shell_path: Enter did not confirm kill"
}

assert_no_cancels() {
    shell_path=$1
    profile_path=$2

    reset_log
    run_k "$shell_path" "$profile_path" 'n
' >/dev/null
    [ ! -s "$log_file" ] || fail "$shell_path: n unexpectedly killed a session"
}

assert_eof_cancels() {
    shell_path=$1
    profile_path=$2

    reset_log
    if HOME=$(dirname "$profile_path") \
        PROFILE_PATH="$profile_path" \
        FAKE_SSH_LOG="$log_file" \
        PATH="$fake_bin:$PATH" \
        "$shell_path" -c '. "$PROFILE_PATH"; k 1' </dev/null >/dev/null 2>&1; then
        fail "$shell_path: EOF unexpectedly succeeded"
    fi
    [ ! -s "$log_file" ] || fail "$shell_path: EOF unexpectedly killed a session"
}

assert_attach_restores_terminal() {
    shell_path=$1
    profile_path=$2
    output_file="$test_root/attach-output"

    reset_log
    if HOME=$(dirname "$profile_path") \
        PROFILE_PATH="$profile_path" \
        FAKE_SSH_LOG="$log_file" \
        FAKE_SSH_ATTACH_EXIT=23 \
        PATH="$fake_bin:$PATH" \
        "$shell_path" -c '. "$PROFILE_PATH"; a 1' > "$output_file"; then
        fail "$shell_path: a discarded the failed SSH status"
    else
        status=$?
    fi

    [ "$status" -eq 23 ] || fail "$shell_path: a returned $status instead of SSH status 23"
    grep -F 'tmux attach-session -t pop-dev1' "$log_file" >/dev/null ||
        fail "$shell_path: a did not attach the selected session"
    grep -F "$(printf '\033[?1000l')" "$output_file" >/dev/null ||
        fail "$shell_path: a did not disable terminal mouse tracking"
    grep -F "$(printf '\033[?1049l')" "$output_file" >/dev/null ||
        fail "$shell_path: a did not leave the alternate screen"
}

bash_home="$test_root/bash-home"
mkdir -p "$bash_home"
HOME="$bash_home" SHELL=/bin/bash \
    "$project_dir/scripts/install-jump-linux.sh" --target ubuntu@target.example >/dev/null
HOME="$bash_home" SHELL=/bin/bash \
    "$project_dir/scripts/install-jump-linux.sh" --target ubuntu@target.example >/dev/null

assert_single_managed_block "$bash_home/.bashrc"
assert_default_kills /bin/bash "$bash_home/.bashrc"
assert_no_cancels /bin/bash "$bash_home/.bashrc"
assert_eof_cancels /bin/bash "$bash_home/.bashrc"
assert_attach_restores_terminal /bin/bash "$bash_home/.bashrc"

if command -v zsh >/dev/null 2>&1; then
    zsh_home="$test_root/zsh-home"
    mkdir -p "$zsh_home/.ssh"
    touch "$zsh_home/.ssh/id_rsa"
    HOME="$zsh_home" \
        "$project_dir/scripts/install-client-macos.sh" \
        --jump ubuntu@jump.example \
        --target ubuntu@target.example \
        --identity "$zsh_home/.ssh/id_rsa" >/dev/null
    HOME="$zsh_home" \
        "$project_dir/scripts/install-client-macos.sh" \
        --jump ubuntu@jump.example \
        --target ubuntu@target.example \
        --identity "$zsh_home/.ssh/id_rsa" >/dev/null

    assert_single_managed_block "$zsh_home/.zshrc"
    assert_default_kills "$(command -v zsh)" "$zsh_home/.zshrc"
    assert_no_cancels "$(command -v zsh)" "$zsh_home/.zshrc"
    assert_eof_cancels "$(command -v zsh)" "$zsh_home/.zshrc"
    assert_attach_restores_terminal "$(command -v zsh)" "$zsh_home/.zshrc"
fi

printf '%s\n' 'PASS: tmux shortcuts confirm kills and restore the terminal after attach'
