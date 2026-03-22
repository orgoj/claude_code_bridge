# Fix: install-mini.sh bugs (commit 6f175ac)

## Context
Mini install promises repo-based installation with global `ccb` command. Several bugs prevent this from working correctly.

## Fixes

### 1. CRITICAL: `ccb` command not available
- `setup_path()` adds `$REPO_ROOT/bin` to PATH, but `ccb` is at repo root
- **Fix:** Symlink `$REPO_ROOT/ccb` → `$REPO_ROOT/bin/ccb` during install (matches "no copying" model)
- File: `install-mini.sh` — add to `setup_path()` or separate step before PATH setup

### 2. BUG: Fish shell gets bash syntax
- `get_shell_config()` correctly detects fish, but `setup_path()` and `show_path_preview()` always emit `export`
- **Fix:** Shell-specific emitters — bash/zsh use `export`, fish uses `set -gx`
- Files: `install-mini.sh` lines ~165 and ~197

### 3. BUG: tmux integration (3 sub-issues)
- `config/tmux-ccb-minimal.conf:7` — hardcoded personal path, should be `@CCB_BIN_DIR@`
- `install-mini.sh:297` — `.processed` file written into repo tree (dirties `git status`)
  - **Fix:** Write to `~/.config/ccb/tmux-ccb-minimal.conf`
- `install-mini.sh:296` — uses `run -b` (shell command) instead of `source-file` (tmux config)
- Files: `config/tmux-ccb-minimal.conf`, `install-mini.sh` `install_tmux()` and `show_tmux_preview()`

### 4. MINOR: Aggressive `rm -rf` in skill install
- `install_skills()` line ~142 deletes non-symlink dirs without warning
- **Fix:** Warn and skip non-symlink directories, only replace existing symlinks

## Files to modify
- `install-mini.sh` — fixes 1, 2, 3 (installer side), 4
- `config/tmux-ccb-minimal.conf` — fix 3 (placeholder)

## Verification
- Run mini install with PATH enabled → `command -v ccb` works
- `git status` clean after tmux install (no `.processed` in repo)
- Fish config file contains `set -gx` syntax (if fish available, otherwise inspect output)
- `~/.tmux.conf` contains `source-file`, not `run -b`

## Out of scope
- CCB skill for "invisible" usage — separate follow-up
