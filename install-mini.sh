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

# Detect shell
detect_shell() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    echo "zsh"
  elif [[ -n "${FISH_VERSION:-}" ]]; then
    echo "fish"
  elif [[ -n "${BASH_VERSION:-}" ]]; then
    echo "bash"
  else
    echo "unknown"
  fi
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

# Install watchdog for file watching (optional)
install_watchdog() {
  info "Installing watchdog (for better file watching performance)..."
  if python3 -m pip install -q watchdog 2>/dev/null; then
    info "✓ watchdog installed"
  elif python3 -m pip show watchdog >/dev/null 2>&1; then
    info "✓ watchdog already installed"
  else
    warn "Could not install watchdog (will use polling, which is slower)"
    warn "To install manually: python3 -m pip install watchdog --user"
  fi
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

      # Remove old symlink or directory if exists
      if [[ -L "$dest_dir" ]]; then
        rm -f "$dest_dir"
      elif [[ -d "$dest_dir" ]]; then
        rm -rf "$dest_dir"
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

# Add repo/bin to PATH
setup_path() {
  local shell_config
  shell_config="$(get_shell_config)"

  local path_line="export PATH=\"$REPO_ROOT/bin:\$PATH\""
  local pythonpath_line="export PYTHONPATH=\"$REPO_ROOT/lib\${PYTHONPATH:+:\$PYTHONPATH}\""

  # Check if already configured
  if grep -q "ccb_REPO_BIN_PATH_MARKER" "$shell_config" 2>/dev/null; then
    info "PATH already configured in $shell_config"
    return 0
  fi

  # Create parent directory for fish config if needed
  if [[ "$(detect_shell)" == "fish" ]]; then
    mkdir -p "$(dirname "$shell_config")"
  fi

  info "Adding CCB to PATH in $shell_config"
  {
    echo ""
    echo "# CCB - Claude Code Bridge (managed by install-mini.sh)"
    echo "# ccb_REPO_BIN_PATH_MARKER - do not remove this line"
    echo "$path_line"
    echo "$pythonpath_line"
  } >> "$shell_config"

  info "✓ Added to PATH (restart shell or run: source $shell_config)"
  return 0
}

# Show what will be added to shell config
show_path_preview() {
  local shell_config
  shell_config="$(get_shell_config)"

  echo ""
  show_preview "The following will be added to your shell config:"
  echo "  File: $shell_config"
  echo ""
  echo "  # CCB - Claude Code Bridge (managed by install-mini.sh)"
  echo "  # ccb_REPO_BIN_PATH_MARKER - do not remove this line"
  echo "  export PATH=\"$REPO_ROOT/bin:\$PATH\""
  echo "  export PYTHONPATH=\"$REPO_ROOT/lib\${PYTHONPATH:+:\$PYTHONPATH}\""
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
      echo "run -b '$processed_conf'"
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
  echo "     run -b '${XDG_CONFIG_HOME:-$HOME/.config}/ccb/tmux-ccb-minimal.conf'"
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

  # Skills (ask first)
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

  # Watchdog (optional, only ask if not installed)
  echo ""
  if python3 -m pip show watchdog >/dev/null 2>&1; then
    info "✓ watchdog already installed"
  else
    read -p "Install watchdog for better file watching? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      install_watchdog
    fi
  fi

  # PATH setup (show preview first)
  show_path_preview
  read -p "Add CCB to PATH? [Y/n] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    setup_path
  fi

  # WezTerm (optional, show preview)
  if command -v wezterm >/dev/null 2>&1 || [[ -f "/mnt/c/Program Files/WezTerm/wezterm.exe" ]]; then
    show_wezterm_preview
    read -p "Install WezTerm integration? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      install_wezterm
    fi
  fi

  # tmux (optional, show preview)
  if command -v tmux >/dev/null 2>&1 && [[ -f "$REPO_ROOT/config/tmux-ccb-minimal.conf" ]]; then
    show_tmux_preview
    read -p "Install tmux integration? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      install_tmux
    fi
  fi

  echo ""
  echo "======================================"
  info "Installation complete!"
  echo "======================================"
  echo ""
  echo "What was done:"
  echo "  ✓ Python version checked"
  if [[ -d "$HOME/.claude/skills" ]]; then
    echo "  ✓ Skills installed to: ~/.claude/skills/"
  fi
  # Only show PATH setup if it was actually configured
  if ! grep -q "ccb_REPO_BIN_PATH_MARKER" "$(get_shell_config)" 2>/dev/null; then
    echo "  ⚠ PATH not configured (user declined)"
  else
    echo "  ✓ $REPO_ROOT/bin added to PATH"
    echo "  ✓ $REPO_ROOT/lib added to PYTHONPATH"
  fi
  echo ""
  echo "To start using:"
  echo "  1. Restart your shell, or run:"
  echo "     export PATH=\"$REPO_ROOT/bin:\$PATH\""
  echo "     export PYTHONPATH=\"$REPO_ROOT/lib\${PYTHONPATH:+:\$PYTHONPATH}\""
  echo ""
  echo "  2. Try:"
  echo "     ask --help"
  echo "     ping --help"
  echo "     pend --help"
  echo ""
  echo "Scripts location: $REPO_ROOT/bin/"
  echo "Skills (centralized): ~/.claude/skills/"
  echo ""
}

main "$@"
