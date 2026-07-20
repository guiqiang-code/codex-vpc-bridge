#!/bin/sh

set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-vpc-bridge-target.XXXXXX")
fake_bin="$test_root/bin"
test_home="$test_root/home"
fixture="$project_dir/tests/fixtures/target-command"
config="$test_home/.codex/config.toml"

cleanup() {
    rm -rf "$test_root"
}
trap cleanup 0 1 2 15

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

mkdir -p "$fake_bin" "$test_home/.codex"
for command_name in uname id tmux codex git curl node npm; do
    ln -s "$fixture" "$fake_bin/$command_name"
done

printf '%s\n' \
    'model = "existing-model"' \
    'approval_policy = "on-request"' \
    'sandbox_mode = "workspace-write"' \
    '' \
    '[profiles.safe]' \
    'approval_policy = "on-request"' \
    'sandbox_mode = "read-only"' > "$config"

run_installer() {
    HOME="$test_home" \
        PATH="$fake_bin:/usr/bin:/bin" \
        "$project_dir/scripts/install-target-linux.sh" \
        --codex-method npm \
        --skip-system-packages >/dev/null
}

run_installer
cp "$config" "$test_root/first-config.toml"
run_installer

cmp "$test_root/first-config.toml" "$config" >/dev/null ||
    fail 'repeated installation changed config.toml'

[ "$(grep -c '^# >>> codex-vpc-bridge full access >>>$' "$config")" -eq 1 ] ||
    fail 'managed full-access block was duplicated'
[ "$(grep -c '^approval_policy = "never"$' "$config")" -eq 1 ] ||
    fail 'approval_policy was not set exactly once'
[ "$(grep -c '^sandbox_mode = "danger-full-access"$' "$config")" -eq 1 ] ||
    fail 'sandbox_mode was not set exactly once'

grep -F 'model = "existing-model"' "$config" >/dev/null ||
    fail 'existing top-level config was removed'
grep -F '[profiles.safe]' "$config" >/dev/null ||
    fail 'existing profile was removed'
grep -F 'approval_policy = "on-request"' "$config" >/dev/null ||
    fail 'profile approval policy was removed'
grep -F 'sandbox_mode = "read-only"' "$config" >/dev/null ||
    fail 'profile sandbox mode was removed'

printf '%s\n' 'PASS: target full-access config is idempotent and preserves existing settings'
