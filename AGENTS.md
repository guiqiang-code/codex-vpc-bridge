# AGENTS.md

## Scope

These instructions apply to the entire `codex-vpc-bridge` repository.

## Primary instruction

This repository is operated by an Agent, not followed as a human tutorial.

Before installing, diagnosing, or changing the project:

1. Read `README.md` completely.
2. Treat its execution boundaries, required inputs, success criteria, and reporting contract as mandatory.
3. Read the platform-specific script before executing it.

## Task routing

- Mac client deployment: use `scripts/install-client-macos.sh`.
- Windows client deployment: use `scripts/install-client-windows.ps1`.
- Linux jump deployment: use `scripts/install-jump-linux.sh`.
- Linux target runtime deployment: use `scripts/install-target-linux.sh`.
- End-to-end deployment: configure the client, prepare SSH agent forwarding, install on jump, then prepare target.

Do not replace the scripts with hand-written SSH or shell configuration unless diagnosing a confirmed script defect.

## Safety requirements

- Never read, print, commit, or upload private-key contents.
- Never copy the client's private key to jump.
- Do not modify cloud networking, security groups, firewalls, or sshd unless the user explicitly expands the task.
- Preserve configuration outside the repository-managed marker blocks.
- Do not create or kill real tmux sessions during installation verification.
- Do not read or display Codex authentication caches, API keys, or access tokens.
- On target, install only the packages declared by `scripts/install-target-linux.sh`.
- Use read-only checks first when diagnosing connection failures.

## Completion rule

Writing configuration files is not sufficient. Report completion only after the applicable success criteria in
`README.md` pass. If remote access or infrastructure prevents verification, report partial completion and identify
the exact failed boundary.

## Project changes

When changing installers:

1. Keep all platform implementations behaviorally consistent.
2. Preserve idempotent managed-block replacement.
3. Run syntax checks for every locally available shell.
4. Test repeated installation in a temporary home/profile.
5. Update `README.md` whenever inputs, side effects, commands, or verification behavior changes.
