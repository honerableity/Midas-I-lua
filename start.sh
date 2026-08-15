#!/bin/bash
# Midas-I startup script
# Pulls latest code from GitHub, then runs bot.
# .env and deps/ stay untouched — they are untracked, git reset --hard
# only affects files that are tracked in the repo.

set -e

if [ -d ".git" ]; then
  echo "[start.sh] pulling latest code..."
  git fetch origin main
  git reset --hard origin/main
else
  echo "[start.sh] no .git found, skipping pull"
fi

if [ ! -f ".env" ]; then
  echo "[start.sh] WARNING: .env not found, bot may fail to start"
fi

if [ ! -d "deps" ]; then
  echo "[start.sh] WARNING: deps/ not found, run 'lit install' first"
fi

echo "[start.sh] starting bot..."
exec ./luvit main.lua
