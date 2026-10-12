#!/usr/bin/env bash
# ============================================================
#  n8n 一鍵升級工具
#  流程：檢查新版 → 停止 → 備份 → 升級 → 健康檢查
#  用法：
#    n8n-upgrade            升級到最新版
#    n8n-upgrade rollback   退回上一次升級前的版本與資料
# ============================================================
set -Eeuo pipefail

# ===== 設定區（可直接改這裡，或寫在 /etc/n8n-upgrade.conf）=====
COMPOSE_DIR="/root/n8n-docker"          # docker-compose.yml 所在資料夾
SERVICE="n8n"                           # compose 裡 n8n 的服務名稱
VOLUME="n8n-docker_n8n_storage"         # n8n 資料卷名稱
BACKUP_DIR="/root/n8n-backup"           # 備份存放位置
KEEP=5                                  # 保留最近幾份備份
HEALTH_PORT=5678                        # n8n 容器內的連接埠
HEALTH_TIMEOUT=180                      # 等待啟動的最長秒數
# ==============================================================
[[ -f /etc/n8n-upgrade.conf ]] && source /etc/n8n-upgrade.conf

# 不是最高權限就自動用 sudo 重新執行
if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

# ---------- 顯示用 ----------
c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'; c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'; c_off=$'\e[0m'
step() { echo; echo "${c_blue}▶ $*${c_off}"; }
ok()   { echo "${c_green}✔ $*${c_off}"; }
warn() { echo "${c_yellow}⚠ $*${c_off}"; }
die()  { echo "${c_red}✘ $*${c_off}" >&2; exit 1; }

confirm() {
  local ans
  if [[ ! -t 0 ]] && [[ ! -e /dev/tty ]]; then
    die "需要你確認，但目前無法輸入。請直接在終端機執行。"
  fi
  read -r -p "$1（輸入 yes 繼續）：" ans </dev/tty
  [[ "$ans" == "yes" ]] || die "已取消，沒有做任何變更。"
}

compose() { docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_DIR/docker-compose.yml" "$@"; }

# ---------- 出錯時的保護 ----------
STAGE="start"
on_error() {
  local line=$1
  echo
  echo "${c_red}✘ 第 ${line} 行發生錯誤，升級中斷。${c_off}" >&2
  case "$STAGE" in
    stopped)
      warn "n8n 已被暫停但還沒升級，正在把舊版重新啟動……"
      compose start "$SERVICE" && ok "舊版已恢復運作，資料沒有變動。"
      ;;
    upgraded)
      warn "新版已啟動但檢查沒通過。請把上面的訊息截圖，或執行：n8n-upgrade rollback 退回舊版"
      ;;
  esac
}
trap 'on_error $LINENO' ERR

# ---------- 共用檢查 ----------
preflight() {
  command -v docker >/dev/null || die "找不到 docker。"
  docker compose version >/dev/null 2>&1 || die "找不到 docker compose。"
  [[ -f "$COMPOSE_DIR/docker-compose.yml" ]] || die "找不到設定檔：$COMPOSE_DIR/docker-compose.yml"
  docker volume inspect "$VOLUME" >/dev/null 2>&1 || die "找不到資料卷：$VOLUME"
  mkdir -p "$BACKUP_DIR"
}

container_id() { compose ps -aq "$SERVICE" | head -n1; }

wait_healthy() {
  local cid waited=0
  cid=$(container_id)
  while (( waited < HEALTH_TIMEOUT )); do
    if docker exec "$cid" node -e \
      "fetch('http://127.0.0.1:${HEALTH_PORT}/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 3; waited=$((waited + 3))
    printf '.'
  done
  echo
  return 1
}

# ============================================================
#  升級
# ============================================================
do_upgrade() {
  preflight

  step "檢查目前版本"
  local cid image old_id old_ver new_id new_ver
  cid=$(container_id)
  [[ -n "$cid" ]] || die "找不到 n8n 容器，請確認 COMPOSE_DIR 和 SERVICE 設定。"
  image=$(docker inspect -f '{{.Config.Image}}' "$cid")
  old_id=$(docker inspect -f '{{.Image}}' "$cid")
  old_ver=$(docker run --rm --entrypoint n8n "$old_id" --version | tail -n1)
  ok "目前版本：$old_ver"

  step "下載最新版（舊版仍在運作，推播不受影響）"
  compose pull "$SERVICE"
  new_id=$(docker image inspect -f '{{.Id}}' "$image")
  if [[ "$new_id" == "$old_id" ]]; then
    ok "已經是最新版（$old_ver），不需要升級。"
    exit 0
  fi
  new_ver=$(docker run --rm --entrypoint n8n "$new_id" --version | tail -n1)
  ok "最新版本：$new_ver"

  if [[ "${old_ver%%.*}" != "${new_ver%%.*}" ]]; then
    warn "這次是「大版本」升級（$old_ver → $new_ver），可能有不相容的改動。"
    warn "建議先看官方的升級說明，或先問 Claude。"
    confirm "確定要繼續嗎？"
  fi

  step "保留舊版程式，萬一要退回可以用"
  docker images n8n-rollback --format '{{.Tag}}' | grep -vx "$old_ver" \
    | xargs -r -I{} docker rmi "n8n-rollback:{}" >/dev/null 2>&1 || true
  docker tag "$old_id" "n8n-rollback:$old_ver"
  ok "已保留：n8n-rollback:$old_ver"

  step "暫停 n8n"
  compose stop "$SERVICE"
  STAGE="stopped"

  step "備份資料"
  local name
  name="n8n_${old_ver}_$(date +%Y%m%d-%H%M%S).tar.gz"
  docker run --rm -v "$VOLUME":/data:ro -v "$BACKUP_DIR":/backup alpine \
    tar czf "/backup/$name" -C /data .
  [[ -s "$BACKUP_DIR/$name" ]] || die "備份檔是空的！"
  tar tzf "$BACKUP_DIR/$name" >/dev/null || die "備份檔損壞！"
  echo "$old_ver"            > "$BACKUP_DIR/.last_version"
  echo "$name"               > "$BACKUP_DIR/.last_backup"
  echo "$image"              > "$BACKUP_DIR/.last_image"
  ok "備份完成：$BACKUP_DIR/$name（$(du -h "$BACKUP_DIR/$name" | cut -f1)）"

  step "啟動新版"
  compose up -d "$SERVICE"
  STAGE="upgraded"

  step "等待 n8n 啟動完成"
  if ! wait_healthy; then
    warn "等了 ${HEALTH_TIMEOUT} 秒還沒啟動完成，最後的紀錄："
    docker logs --tail 40 "$(container_id)" || true
    die "升級後檢查沒通過。可以執行：n8n-upgrade rollback 退回 $old_ver"
  fi
  echo
  STAGE="done"
  ok "n8n 運作正常"

  step "清理舊備份（保留最近 $KEEP 份）"
  ls -1t "$BACKUP_DIR"/n8n_*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
  ok "完成"

  echo
  echo "${c_green}════════════════════════════════════${c_off}"
  echo "${c_green}  升級成功：$old_ver → $new_ver${c_off}"
  echo "${c_green}════════════════════════════════════${c_off}"
  echo "請到 n8n 後台確認各流程都是「啟用」狀態，並手動測試一次。"
  echo "如果有問題，執行：n8n-upgrade rollback"
}

# ============================================================
#  退回
# ============================================================
do_rollback() {
  preflight
  [[ -f "$BACKUP_DIR/.last_version" ]] || die "找不到上一次升級的紀錄，無法退回。"
  local ver name image
  ver=$(cat "$BACKUP_DIR/.last_version")
  name=$(cat "$BACKUP_DIR/.last_backup")
  image=$(cat "$BACKUP_DIR/.last_image")
  [[ -s "$BACKUP_DIR/$name" ]] || die "找不到備份檔：$BACKUP_DIR/$name"
  docker image inspect "n8n-rollback:$ver" >/dev/null 2>&1 || die "找不到舊版程式 n8n-rollback:$ver"

  warn "將退回到 $ver，並把資料還原成升級前的備份：$name"
  warn "升級之後才新增或修改的工作流程、執行紀錄會消失。"
  confirm "確定要退回嗎？"

  step "暫停 n8n"
  compose stop "$SERVICE"

  step "還原資料"
  docker run --rm -v "$VOLUME":/data -v "$BACKUP_DIR":/backup alpine sh -c \
    "find /data -mindepth 1 -delete && tar xzf /backup/$name -C /data && chown -R 1000:1000 /data"
  ok "資料已還原"

  step "切回舊版程式並啟動"
  docker tag "n8n-rollback:$ver" "$image"
  compose up -d "$SERVICE"
  if wait_healthy; then
    echo
    ok "已退回 $ver，n8n 運作正常。"
    warn "注意：下次執行 n8n-upgrade 會再升到最新版。"
  else
    docker logs --tail 40 "$(container_id)" || true
    die "退回後仍無法正常啟動，請把上面的訊息截圖給 Claude。"
  fi
}

case "${1:-upgrade}" in
  upgrade)  do_upgrade ;;
  rollback) do_rollback ;;
  -h|--help|help)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "不認識的指令：$1（可用：upgrade、rollback）" ;;
esac
