#!/bin/bash
# Midas-I startup script
# Pulls latest code from GitHub, then runs bot.
# .env and deps/ stay untouched — they are untracked, git reset --hard
# only affects files that are tracked in the repo.
#
# Auto-update: polls origin/main every POLL_INTERVAL seconds in the
# background. On new commit, kills the bot and execs this script again,
# which re-pulls and restarts it with fresh code. No external process
# manager required.
set -e

POLL_INTERVAL="${POLL_INTERVAL:-60}"

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

WATCHER_PID=""
if [ -d ".git" ]; then
  (
    while true; do
      sleep "$POLL_INTERVAL"
      LOCAL=$(git rev-parse HEAD)
      REMOTE=$(git ls-remote origin main | cut -f1)
      if [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
        echo "[start.sh] new commit detected ($LOCAL -> $REMOTE), restarting..."
        kill "$BOT_PID" 2>/dev/null || true
        exec "$0" "$@"
      fi
    done
  ) &
  WATCHER_PID=$!
  trap 'kill "$WATCHER_PID" 2>/dev/null || true' EXIT
fi

echo "[start.sh] starting bot..."
./luvit main.lua &
BOT_PID=$!
wait "$BOT_PID"
