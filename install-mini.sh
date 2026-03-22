#!/usr/bin/env bash
set -euo pipefail

# install-mini.sh - Minimal installation for Claude Code Bridge
#
# This script does ONLY what's necessary to run CCB from the repo:
# 1. Checks Python version
# 2. Installs skills to centralized ~/.claude/skills
# 3. Optionally installs watchdog (for file watching)
# 4. Adds repo/bin to PATH in your shell config
# 5. Optional tmux/wezterm integration (shows exact changes before asking)
#
# What it DOES NOT do:
# - Copy files anywhere (uses repo directly)
# - Modify CLAUDE.md, AGENTS.md, .clinerules
# - Modify settings.json permissions

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
show_preview() { echo -e "${BLUE}[PREVIEW]${NC} $1"; }

# Detect user's login shell (not the shell running this script)
detect_shell() {
  local login_shell
  login_shell="$(basename "${SHELL:-/bin/bash}")"

  case "$login_shell" in
    zsh|bash|fish) echo "$login_shell" ;;
    *) echo "bash" ;;
  esac
}

# Get config file for current shell
get_shell_config() {
  local shell
  shell="$(detect_shell)"

  case "$shell" in
    zsh)
      echo "${ZDOTDIR:-$HOME}/.zshrc"
      ;;
    bash)
      # Try .bashrc, fallback to .bash_profile
      if [[ -f "$HOME/.bashrc" ]]; then
        echo "$HOME/.bashrc"
      else
        echo "$HOME/.bash_profile"
      fi
      ;;
    fish)
      echo "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/ccb.fish"
      ;;
    *)
      echo "$HOME/.profile"
      ;;
  esac
}

# Check Python version
check_python() {
  local python_version
  if ! python_version=$(python3 --version 2>&1); then
    error "Python 3 not found!"
    error "Please install Python 3.10 or later"
    return 1
  fi

  local major minor
  major=$(echo "$python_version" | awk '{print $2}' | cut -d. -f1)
  minor=$(echo "$python_version" | awk '{print $2}' | cut -d. -f2)

  if [[ "$major" -lt 3 ]] || [[ "$major" -eq 3 && "$minor" -lt 10 ]]; then
    error "$python_version found, but Python 3.10+ is required"
    return 1
  fi

  info "Python version OK: $python_version"
  return 0
}

# Detect Python environment: managed (mise/pyenv/asdf) vs system
detect_python_env() {
  local python3_path
  python3_path="$(command -v python3 2>/dev/null || true)"

  if [[ -z "$python3_path" ]]; then
    echo "none"
  elif [[ "$python3_path" == "$HOME"/* ]]; then
    echo "managed"  # mise, pyenv, asdf — Python under $HOME
  elif command -v apt-get >/dev/null 2>&1; then
    echo "system-deb"
  else
    echo "system-other"
  fi
}

# Show watchdog install preview
show_watchdog_preview() {
  local py_env
  py_env="$(detect_python_env)"

  echo ""
  show_preview "Watchdog installation (better file watching performance):"
  case "$py_env" in
    managed)
      echo "  • Managed Python detected (mise/pyenv/asdf)"
      echo "  • Command: python3 -m pip install watchdog"
      ;;
    system-deb)
      echo "  • System Python on Debian/Ubuntu"
      echo "  • Command: sudo apt-get install python3-watchdog"
      ;;
    system-other)
      echo "  • System Python"
      echo "  • Command: python3 -m pip install --user watchdog"
      ;;
  esac
  echo ""
}

# Install watchdog for file watching (optional)
install_watchdog() {
  local py_env
  py_env="$(detect_python_env)"

  info "Installing watchdog..."

  case "$py_env" in
    managed)
      if python3 -m pip install -q watchdog; then
        info "✓ watchdog installed (via pip, managed Python)"
        return 0
      fi
      ;;
    system-deb)
      if sudo apt-get install -y -q python3-watchdog; then
        info "✓ watchdog installed (via apt)"
        return 0
      fi
      ;;
    system-other)
      if python3 -m pip install -q --user watchdog; then
        info "✓ watchdog installed (via pip --user)"
        return 0
      fi
      ;;
  esac

  warn "Could not install watchdog (will use polling, which is slower)"
  warn "To install manually: pip install watchdog  OR  apt-get install python3-watchdog"
}

# Check if skills are already installed (all symlinks present)
check_skills_installed() {
  local central_skills="$HOME/.claude/skills"
  local skill_types=("claude_skills" "codex_skills" "droid_skills")

  [[ -d "$central_skills" ]] || return 1

  for skill_type in "${skill_types[@]}"; do
    local source_dir="$REPO_ROOT/$skill_type"
    [[ -d "$source_dir" ]] || continue

    for skill_dir in "$source_dir"/*; do
      [[ -d "$skill_dir" ]] || continue
      [[ -f "$skill_dir/SKILL.md" ]] || continue

      local skill_name
      skill_name="$(basename "$skill_dir")"
      local dest_dir="$central_skills/$skill_name"

      # Missing or broken symlink → not fully installed
      if [[ ! -L "$dest_dir" ]]; then
        return 1
      fi
    done
  done

  return 0
}

# Install skills to centralized location
install_skills() {
  local central_skills="$HOME/.claude/skills"
  local skills_installed=0

  mkdir -p "$central_skills"

  info "Installing skills to centralized location: $central_skills"

  # List of skill directories to install
  local skill_types=("claude_skills" "codex_skills" "droid_skills")

  for skill_type in "${skill_types[@]}"; do
    local source_dir="$REPO_ROOT/$skill_type"

    if [[ ! -d "$source_dir" ]]; then
      continue
    fi

    # Find all skill subdirectories (containing SKILL.md)
    for skill_dir in "$source_dir"/*; do
      if [[ ! -d "$skill_dir" ]]; then
        continue
      fi

      local skill_name
      skill_name="$(basename "$skill_dir")"

      # Check if it's a valid skill (has SKILL.md)
      if [[ ! -f "$skill_dir/SKILL.md" ]]; then
        continue
      fi

      local dest_dir="$central_skills/$skill_name"

      # Remove old symlink if exists; skip real directories (user content)
      if [[ -L "$dest_dir" ]]; then
        rm -f "$dest_dir"
      elif [[ -d "$dest_dir" ]]; then
        warn "Skipping skill '$skill_name': $dest_dir is a real directory (not a symlink). Remove it manually to reinstall."
        continue
      fi

      # Create symlink to repo skill
      ln -s "$skill_dir" "$dest_dir"
      info "✓ Linked skill: $skill_name → $skill_dir"
      skills_installed=$((skills_installed + 1))
    done
  done

  if [[ $skills_installed -eq 0 ]]; then
    warn "No skills found to install"
  else
    info "✓ Installed $skills_installed skill(s)"
  fi

  return 0
}

# Ensure bin/ccb symlink exists (independent of PATH setup)
ensure_ccb_symlink() {
  local ccb_symlink="$REPO_ROOT/bin/ccb"
  if [[ -L "$ccb_symlink" ]]; then
    : # already a symlink, leave it
  elif [[ -e "$ccb_symlink" ]]; then
    warn "Skipping bin/ccb symlink (non-symlink file exists)"
  else
    ln -sf "$REPO_ROOT/ccb" "$ccb_symlink"
    info "✓ Linked bin/ccb → ccb"
  fi
}

# Add repo/bin to PATH
setup_path() {
  local shell_config
  shell_config="$(get_shell_config)"

  local current_shell
  current_shell="$(detect_shell)"

  local path_line
  if [[ "$current_shell" == "fish" ]]; then
    path_line="set -gx PATH \"$REPO_ROOT/bin\" \$PATH"
  else
    path_line="export PATH=\"$REPO_ROOT/bin:\$PATH\""
  fi

  # Check if already configured
  if grep -q "ccb_REPO_BIN_PATH_MARKER" "$shell_config" 2>/dev/null; then
    info "PATH already configured in $shell_config"
    return 0
  fi

  # Create parent directory for fish config if needed
  if [[ "$current_shell" == "fish" ]]; then
    mkdir -p "$(dirname "$shell_config")"
  fi

  info "Adding CCB to PATH in $shell_config"
  {
    echo ""
    echo "# CCB - Claude Code Bridge (managed by install-mini.sh)"
    echo "# ccb_REPO_BIN_PATH_MARKER - do not remove this line"
    echo "$path_line"
  } >> "$shell_config"

  info "✓ Added to PATH (restart shell or run: source $shell_config)"
  return 0
}

# Show what will be added to shell config
show_path_preview() {
  local shell_config
  shell_config="$(get_shell_config)"

  local current_shell
  current_shell="$(detect_shell)"

  local path_line
  if [[ "$current_shell" == "fish" ]]; then
    path_line="set -gx PATH \"$REPO_ROOT/bin\" \$PATH"
  else
    path_line="export PATH=\"$REPO_ROOT/bin:\$PATH\""
  fi

  echo ""
  show_preview "The following will be added to your shell config:"
  echo "  Symlink: $REPO_ROOT/bin/ccb → $REPO_ROOT/ccb"
  echo "  File: $shell_config"
  echo ""
  echo "  # CCB - Claude Code Bridge (managed by install-mini.sh)"
  echo "  # ccb_REPO_BIN_PATH_MARKER - do not remove this line"
  echo "  $path_line"
  echo ""
}

# Optional: Install wezterm integration
install_wezterm() {
  local cfg_root="${XDG_CONFIG_HOME:-$HOME/.config}"
  local env_file="$cfg_root/ccb/env"

  # Detect wezterm path
  local wezterm_path=""
  if command -v wezterm >/dev/null 2>&1; then
    wezterm_path="$(command -v wezterm)"
  elif [[ -f "/mnt/c/Program Files/WezTerm/wezterm.exe" ]]; then
    wezterm_path="/mnt/c/Program Files/WezTerm/wezterm.exe"
  fi

  if [[ -z "$wezterm_path" ]]; then
    warn "WezTerm not found, skipping"
    return 1
  fi

  mkdir -p "$(dirname "$env_file")"
  echo "CODEX_WEZTERM_BIN=${wezterm_path}" > "$env_file"
  info "✓ Cached WezTerm path: $wezterm_path"
  return 0
}

# Show what will be done for wezterm
show_wezterm_preview() {
  local cfg_root="${XDG_CONFIG_HOME:-$HOME/.config}"
  local env_file="$cfg_root/ccb/env"

  local wezterm_path=""
  if command -v wezterm >/dev/null 2>&1; then
    wezterm_path="$(command -v wezterm)"
  elif [[ -f "/mnt/c/Program Files/WezTerm/wezterm.exe" ]]; then
    wezterm_path="/mnt/c/Program Files/WezTerm/wezterm.exe"
  fi

  echo ""
  show_preview "WezTerm integration:"
  echo "  • Create directory: $(dirname "$env_file")"
  echo "  • Create file: $env_file"
  echo "  • Content: CODEX_WEZTERM_BIN=$wezterm_path"
  echo "  • Purpose: Cache WezTerm executable path for CCB"
  echo ""
}

# Optional: Install tmux integration (symlinks, no copying)
install_tmux() {
  local tmux_conf="$HOME/.tmux.conf"
  local tmux_ccb="$REPO_ROOT/config/tmux-ccb-minimal.conf"

  if [[ ! -f "$tmux_ccb" ]]; then
    warn "tmux config not found at $tmux_ccb"
    return 1
  fi

  if ! command -v tmux >/dev/null 2>&1; then
    warn "tmux not installed, skipping"
    return 1
  fi

  # Symlink helper scripts from config/ to bin/ (not copy!)
  for script in ccb-status.sh ccb-border.sh ccb-git.sh ccb-tmux-on.sh ccb-tmux-off.sh; do
    local src="$REPO_ROOT/config/$script"
    local dest="$REPO_ROOT/bin/$script"

    if [[ -f "$src" ]]; then
      # Remove existing symlink or file
      if [[ -L "$dest" ]]; then
        rm -f "$dest"
      elif [[ -e "$dest" ]]; then
        warn "Skipping $script (non-symlink exists in bin/)"
        continue
      fi

      # Create symlink
      if ln -s "$src" "$dest" 2>/dev/null; then
        info "✓ Linked bin/$script → config/$script"
      else
        warn "Failed to symlink $script"
      fi
    fi
  done

  # Update @CCB_BIN_DIR@ placeholder in tmux config
  local ccb_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ccb"
  local processed_conf="$ccb_config_dir/tmux-ccb-minimal.conf"
  mkdir -p "$ccb_config_dir"
  sed "s|@CCB_BIN_DIR@|$REPO_ROOT/bin|g" "$tmux_ccb" > "$processed_conf"

  # Source the config
  if ! grep -q "tmux-ccb-minimal.conf" "$tmux_conf" 2>/dev/null; then
    {
      echo ""
      echo "# CCB tmux integration (minimal)"
      echo "source-file $processed_conf"
    } >> "$tmux_conf"
    info "✓ Added tmux config to $tmux_conf"
  else
    info "tmux already configured"
  fi

  info "Reload tmux config: prefix + :source-file ~/.tmux.conf"
}

show_tmux_preview() {
  local tmux_conf="$HOME/.tmux.conf"
  local tmux_ccb="$REPO_ROOT/config/tmux-ccb-minimal.conf"

  if [[ ! -f "$tmux_ccb" ]]; then
    return 1
  fi

  if ! command -v tmux >/dev/null 2>&1; then
    return 1
  fi

  echo ""
  show_preview "tmux integration will:"
  echo "  1. Symlink scripts from config/ to bin/ (not copy):"
  echo "     • ccb-status.sh   - Custom status line"
  echo "     • ccb-border.sh   - Dynamic pane borders"
  echo "     • ccb-git.sh      - Fast git status"
  echo "     • ccb-tmux-on.sh  - Enable theming"
  echo "     • ccb-tmux-off.sh - Disable theming"
  echo ""
  echo "  2. Add to $tmux_conf:"
  echo "     # CCB tmux integration (minimal)"
  echo "     source-file ${XDG_CONFIG_HOME:-$HOME/.config}/ccb/tmux-ccb-minimal.conf"
  echo ""
  echo "  3. tmux-ccb-minimal.conf contains:"
  echo "     • Only: set @ccb_bin_dir for CCB theming"
  echo "     • Does NOT change mouse, keys, colors, etc."
  echo ""
  echo "  Theme only active while CCB is running (auto toggle)"
  echo ""
}

# Main installation
main() {
  echo "======================================"
  echo "CCB Minimal Installation"
  echo "======================================"
  echo ""

  check_python || exit 1

  # Skills (check if already installed before asking)
  if check_skills_installed; then
    info "✓ Skills already installed in ~/.claude/skills/"
  else
    echo ""
    show_preview "Skills installation:"
    echo "  • Symlink skills from repo to ~/.claude/skills/"
    echo "  • Allows all agents to use the same skills"
    echo ""
    read -p "Install centralized skills? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      install_skills
    else
      warn "Skipping skills installation"
    fi
  fi

  # Watchdog (optional, only ask if not installed)
  if python3 -c "import watchdog" >/dev/null 2>&1; then
    info "✓ watchdog already installed"
  else
    show_watchdog_preview
    read -p "Install watchdog? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      install_watchdog
    fi
  fi

  # Ensure bin/ccb symlink always exists
  ensure_ccb_symlink

  # PATH setup (check if already in $PATH)
  if [[ ":$PATH:" == *":$REPO_ROOT/bin:"* ]]; then
    info "✓ $REPO_ROOT/bin already in PATH"
  else
    show_path_preview
    read -p "Add CCB to PATH? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      setup_path
    fi
  fi

  # WezTerm (optional, check if already configured)
  if command -v wezterm >/dev/null 2>&1 || [[ -f "/mnt/c/Program Files/WezTerm/wezterm.exe" ]]; then
    local env_file="${XDG_CONFIG_HOME:-$HOME/.config}/ccb/env"
    if [[ -f "$env_file" ]]; then
      info "✓ WezTerm integration already configured"
    else
      show_wezterm_preview
      read -p "Install WezTerm integration? [y/N] " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        install_wezterm
      fi
    fi
  fi

  # tmux (optional, check if already configured)
  if command -v tmux >/dev/null 2>&1 && [[ -f "$REPO_ROOT/config/tmux-ccb-minimal.conf" ]]; then
    if grep -q "tmux-ccb-minimal.conf" "$HOME/.tmux.conf" 2>/dev/null; then
      info "✓ tmux integration already configured"
    else
      show_tmux_preview
      read -p "Install tmux integration? [y/N] " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        install_tmux
      fi
    fi
  fi

  echo ""
  echo "======================================"
  info "Installation complete!"
  echo "======================================"
  echo ""
  echo "  Try: ccb --help, ask --help, ping --help"
  echo ""
}

main "$@"
