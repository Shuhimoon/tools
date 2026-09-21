# oracle-free-vm

在本機用 **OCI CLI** 每輪檢查並試開 Oracle Always Free 目標實例（新加坡 `ap-singapore-1`）。

## 目標艦隊（僅免費）

| 名稱 | Shape | Boot |
|------|-------|------|
| `af-amd-50` | `VM.Standard.E2.1.Micro` | 50GB |
| `af-amd-100` | `VM.Standard.E2.1.Micro` | 100GB |
| `af-arm-2o12` | `VM.Standard.A1.Flex` 2 OCPU / 12GB | 50GB |

- 區域：只開新加坡（home region）
- 映像：免費 Ubuntu 24.04 Minimal（自動挑選）
- 已存在且 RUNNING 的實例不會重開
- **不會**上傳／內嵌 API 私鑰、SSH 私鑰、`.oci`、`bin/`、或以 `.` 開頭的本機檔

## 事前準備

1. 安裝 [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm)
2. 設定 `~/.oci/config` 與 API 私鑰（留在本機，不要放進本資料夾）
3. 準備一把 SSH **公鑰**（例如 `~/.ssh/oci_always_free.pub`）
4. 複製環境檔並填入：

```bash
cp .env.example .env
# 編輯 .env：OCI_COMPARTMENT_ID、OCI_SUBNET_ID、SSH_PUBLIC_KEY_FILE 等
```

## 跑一輪

```bash
cd oracle-free-vm
python3 watch.py
```

成功開到新機器時會印 `NOTIFY: created …`；容量不足／429 則印失敗原因並安靜結束（適合排程）。

## 本機排程（每 15 分鐘）

crontab 範例（台北時區）：

```cron
CRON_TZ=Asia/Taipei
*/15 * * * * cd /path/to/tools/oracle-free-vm && /usr/bin/python3 watch.py >> /tmp/oracle-free-vm.log 2>&1
```

或用 systemd timer / Task Scheduler，重點是呼叫 `python3 watch.py`。

## 安全

- 不要把 `.env`、`*.pem`、`~/.oci`、SSH 私鑰 commit 進 git
- 本目錄 `.gitignore` 已排除常見敏感與隱藏檔、`bin/`
- API 金鑰只透過本機 OCI CLI profile 讀取

## 授權／責任

Always Free 容量常缺；腳本只會在免費額度內重試。刪除／停止實例請自行操作，本腳本預設不刪機。
