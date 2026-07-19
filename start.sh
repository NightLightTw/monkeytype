#!/usr/bin/env bash
# 一鍵啟動本地 monkeytype 全套服務：Docker(MongoDB+Redis) + 前端(3000) + 後端(5005)
# 注意：Ctrl+C 只會停止前後端 dev server；MongoDB/Redis 容器會繼續在背景執行。
#       要停容器：cd backend && docker compose -f docker/compose.db-only.yml down
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_WAIT_TIMEOUT=90
DB_WAIT_TIMEOUT=60

fail() { echo "✖ $1" >&2; exit 1; }

# ── 前置檢查：必要工具 ──────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || fail "找不到 docker CLI，請先安裝 Docker Desktop"
docker compose version >/dev/null 2>&1 || fail "找不到 docker compose plugin，請更新 Docker Desktop"
command -v brew >/dev/null 2>&1 || fail "找不到 Homebrew（需要它定位 node@24）"
command -v lsof >/dev/null 2>&1 || fail "找不到 lsof，無法檢查埠佔用"
command -v firebase >/dev/null 2>&1 || fail "找不到 firebase CLI（離線登入需要），請執行：npm i -g firebase-tools"

NODE24_PREFIX="$(brew --prefix node@24 2>/dev/null)" || fail "Homebrew 未安裝 node@24（brew install node@24）"
[ -x "$NODE24_PREFIX/bin/node" ] || fail "node@24 不完整：$NODE24_PREFIX/bin/node 不存在"
export PATH="$NODE24_PREFIX/bin:$PATH"

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" = "24" ] || fail "Node 主版本需為 24，目前是 $(node -v)"

command -v pnpm >/dev/null 2>&1 || fail "找不到 pnpm，請執行 corepack enable --install-directory $NODE24_PREFIX/bin"
REQUIRED_PNPM="$(node -p "require('$REPO_DIR/package.json').packageManager.split('@')[1]")"
ACTUAL_PNPM="$(pnpm --version)" || fail "無法執行 pnpm --version"
[ "$ACTUAL_PNPM" = "$REQUIRED_PNPM" ] || fail "pnpm 需為 ${REQUIRED_PNPM}（package.json packageManager），目前是 $ACTUAL_PNPM"

# ── 前置檢查：必要檔案 ──────────────────────────────────────────────
COMPOSE_FILE="$REPO_DIR/backend/docker/compose.db-only.yml"
ENV_FILE="$REPO_DIR/backend/.env"
KEY_FILE="$REPO_DIR/backend/src/credentials/serviceAccountKey.json"
[ -f "$COMPOSE_FILE" ] || fail "缺少 $COMPOSE_FILE"
[ -f "$ENV_FILE" ] || fail "缺少 ${ENV_FILE}（請從 backend/example.env 複製）"
[ -f "$KEY_FILE" ] || echo "⚠ 找不到 ${KEY_FILE}，後端可啟動但帳號登入會失敗" >&2

# ── 前置處理：埠佔用（自動停掉舊 dev server 後重啟） ────────────────
# 只自動停止 node 生態的程序（node/pnpm/turbo/vite/tsx）；其他程序佔用則報錯，避免誤殺無關服務。
free_port() {
  local port="$1" pids pid comm waited
  pids="$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  [ -z "$pids" ] && return 0
  for pid in $pids; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$comm" in
      *node* | *pnpm* | *turbo* | *vite* | *tsx*) ;;
      *) fail "埠 $port 被非 dev server 程序佔用（PID ${pid}：${comm:-unknown}），不自動停止，請手動處理" ;;
    esac
  done
  echo "▶ 埠 $port 已有舊 dev server（PID: ${pids}），正在停止..."
  kill $pids 2>/dev/null || true
  waited=0
  while lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge 10 ]; then
      echo "  溫和停止逾時，強制結束..."
      kill -9 $pids 2>/dev/null || true
      sleep 1
      if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        fail "無法釋放埠 ${port}，請手動檢查：lsof -nP -iTCP:$port -sTCP:LISTEN"
      fi
      break
    fi
  done
  echo "✔ 埠 $port 已釋放"
}
for port in 3000 5005 9099 4000; do free_port "$port"; done

# ── 1. 確保 Docker daemon 在跑（含 timeout） ────────────────────────
if ! docker info >/dev/null 2>&1; then
  echo "▶ Docker 未啟動，正在打開 Docker Desktop..."
  open -a Docker || fail "無法啟動 Docker Desktop"
  waited=0
  until docker info >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    [ "$waited" -lt "$DOCKER_WAIT_TIMEOUT" ] || fail "等待 Docker daemon 超過 ${DOCKER_WAIT_TIMEOUT}s，請手動檢查 Docker Desktop"
  done
fi
echo "✔ Docker 就緒"

# ── 2. 啟動 MongoDB + Redis 並等待可連線 ────────────────────────────
echo "▶ 啟動 MongoDB + Redis..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d

waited=0
until docker exec monkeytype-mongodb mongosh --quiet --eval 'quit(db.runCommand({ping:1}).ok === 1 ? 0 : 1)' >/dev/null 2>&1 \
   && [ "$(docker exec monkeytype-redis redis-cli ping 2>/dev/null)" = "PONG" ]; do
  sleep 2
  waited=$((waited + 2))
  [ "$waited" -lt "$DB_WAIT_TIMEOUT" ] || fail "等待 MongoDB/Redis 可連線超過 ${DB_WAIT_TIMEOUT}s。請檢查 docker logs monkeytype-mongodb / monkeytype-redis；需要清理容器時執行：cd \"$REPO_DIR/backend\" && docker compose -f docker/compose.db-only.yml down"
done
echo "✔ MongoDB + Redis 可連線"

# ── 2.5 同步 Anki 卡片成打字內容（非致命：失敗只警告，不擋啟動） ────
ANKI_SYNC_SCRIPT="$REPO_DIR/../youtube-anki-mining/sync_monkeytype.py"
ANKI_SYNC_PYTHON="$REPO_DIR/../youtube-anki-mining/.venv/bin/python"
if [ -f "$ANKI_SYNC_SCRIPT" ] && [ -x "$ANKI_SYNC_PYTHON" ]; then
  anki_ready() { curl -s -m 2 -X POST -d '{"action":"version","version":6}' http://127.0.0.1:8765 2>/dev/null | grep -q '"error": *null'; }
  if ! anki_ready; then
    echo "▶ Anki 未開啟，嘗試啟動（同步打字內容用）..."
    open -a Anki 2>/dev/null || true
    waited=0
    until anki_ready; do
      sleep 2
      waited=$((waited + 2))
      [ "$waited" -lt 30 ] && continue
      break
    done
  fi
  if anki_ready; then
    echo "▶ 同步 Anki 卡片 → monkeytype..."
    "$ANKI_SYNC_PYTHON" "$ANKI_SYNC_SCRIPT" || echo "⚠ Anki 同步失敗，沿用上次的內容" >&2
  else
    echo "⚠ AnkiConnect 30 秒內未就緒，略過同步（沿用上次的內容）" >&2
  fi
fi

# ── 3. 啟動 Firebase Auth Emulator（本地離線登入） ──────────────────
EMU_DATA="$REPO_DIR/.firebase-emulator-data"
FIREBASE_PROJECT="$(sed -n 's/.*projectId: "\(.*\)".*/\1/p' "$REPO_DIR/frontend/src/ts/constants/firebase-config.ts")"
[ -n "$FIREBASE_PROJECT" ] || fail "無法從 firebase-config.ts 讀取 projectId"

echo "▶ 啟動 Firebase Auth Emulator（project: ${FIREBASE_PROJECT}）..."
EMU_ARGS=(emulators:start --only auth --project "$FIREBASE_PROJECT" --export-on-exit "$EMU_DATA")
[ -d "$EMU_DATA" ] && EMU_ARGS+=(--import "$EMU_DATA")
(cd "$REPO_DIR" && firebase "${EMU_ARGS[@]}" >"$REPO_DIR/.firebase-emulator.log" 2>&1) &

waited=0
until curl -s http://127.0.0.1:9099/ >/dev/null 2>&1; do
  sleep 1
  waited=$((waited + 1))
  [ "$waited" -lt 60 ] || fail "Auth Emulator 60 秒內未就緒，請檢查 ${REPO_DIR}/.firebase-emulator.log"
done
echo "✔ Auth Emulator 就緒（帳號管理介面：http://localhost:4000）"

# ── 4. 啟動前端 (3000) + 後端 (5005) ───────────────────────────────
echo "▶ 啟動前端 http://localhost:3000 與後端 http://localhost:5005 ..."
echo "  （初次啟動需編譯，請稍等；Ctrl+C 結束前後端與 Emulator，資料庫容器會留在背景）"
cd "$REPO_DIR"
exec pnpm dev
