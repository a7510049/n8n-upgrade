# n8n 一鍵升級工具

自己用的小工具：一條指令完成 n8n（Docker Compose 版）的備份、升級與檢查，出問題可一鍵退回。

## 安裝

```bash
sudo curl -fsSL https://raw.githubusercontent.com/a7510049/n8n-upgrade/main/n8n-upgrade.sh -o /usr/local/bin/n8n-upgrade
sudo chmod +x /usr/local/bin/n8n-upgrade
```

## 使用

```bash
n8n-upgrade            # 升級到最新版
n8n-upgrade rollback   # 退回上一次升級前的版本與資料
```

## 流程

1. 下載新版（已是最新就直接結束）
2. 跨大版本時先詢問確認
3. 保留舊版程式 → 暫停 → 備份資料 → 啟動新版
4. 確認 n8n 正常運作，舊備份只留最近 5 份
5. 中途出錯會自動把舊版重新啟動

## 設定

預設值寫在腳本開頭的「設定區」，也可以寫在 `/etc/n8n-upgrade.conf` 覆蓋：

```bash
COMPOSE_DIR="/root/n8n-docker"
VOLUME="n8n-docker_n8n_storage"
BACKUP_DIR="/root/n8n-backup"
KEEP=5
```

## 注意

- 避開排程推播的時間執行，升級時 n8n 會停約一分鐘
- 不要執行 `docker compose down -v`，會刪除資料卷
