# n8n 一鍵升級工具

自己用的小工具：一條指令完成 n8n（Docker Compose 版）的備份、升級與檢查，出問題可一鍵退回，也能設定每週自動升級小版本。

## 安裝 / 更新

```bash
sudo curl -fsSL https://raw.githubusercontent.com/a7510049/n8n-upgrade/main/n8n-upgrade.sh -o /usr/local/bin/n8n-upgrade
sudo chmod +x /usr/local/bin/n8n-upgrade
```

## 使用

```bash
n8n-upgrade              # 手動升級到最新版
n8n-upgrade auto         # 自動模式：只升小版本，大版本只通知；失敗自動退回
n8n-upgrade rollback     # 退回上一次升級前的版本與資料
n8n-upgrade schedule     # 開啟每週自動升級
n8n-upgrade unschedule   # 關閉每週自動升級
n8n-upgrade test-notify  # 測試 Telegram 通知
```

## 自動升級的規則

- 小版本（例如 2.42 → 2.43）：自動備份並升級
- 大版本（例如 2 → 3）：**不升級**，只傳一次 Telegram 通知
- 升級後啟動失敗：自動還原舊版程式與資料，並通知
- 預設每週日凌晨 03:17（台灣時間）執行，紀錄在 `/var/log/n8n-upgrade.log`

## 設定

建立 `/etc/n8n-upgrade.conf`，只寫需要改的項目即可：

```bash
COMPOSE_DIR="/root/n8n-docker"
VOLUME="n8n-docker_n8n_storage"
BACKUP_DIR="/root/n8n-backup"
KEEP=5

SCHEDULE_DAY="sunday"
SCHEDULE_TIME="03:17"

TG_TOKEN="機器人代碼"
TG_CHAT="群組ID"
TG_THREAD=""   # 群組主題 ID，沒有就留空
```

改了排程時間後，要再執行一次 `n8n-upgrade schedule` 才會生效。

## 注意

- 升級時 n8n 會停約一分鐘，排程請避開推播時間
- 不要執行 `docker compose down -v`，會刪除資料卷
