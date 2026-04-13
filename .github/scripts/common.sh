#!/usr/bin/env bash
# Shared logging utilities for GitHub Actions CI scripts

# ANSI colors — GitHub Actions runner supports them in raw logs;
# disable when not in a terminal and not explicitly forced
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "1" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

log_info()    { echo -e "${BLUE}ℹ️  INFO${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_success() { echo -e "${GREEN}✅ SUCCESS${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warning() { echo -e "${YELLOW}⚠️  WARNING${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error()   { echo -e "${RED}❌ ERROR${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

log_section() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$*"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# error_exit <exit_code> <message>
error_exit() {
  local code="${1:-1}"; shift
  log_error "$*"
  exit "$code"
}
