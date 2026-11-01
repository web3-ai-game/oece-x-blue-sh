# oece-x-blue.sh 開發回執 / Dev handoff

當前版本：**v2.0.0**。單檔 `oece-x-blue.sh`。UI 為繁體中文 / English。

公開倉庫不記錄真實帳號名、雲商資源 ID、公網 IP、部署路徑或私人信箱。示例帳號用 `deploy`。示例 IP 用 RFC 5737（`203.0.113.0/24`、`198.51.100.0/24`、`192.0.2.0/24`）。

## 續開發

```bash
cd oece-x-blue-sh
bash -n oece-x-blue.sh
shellcheck -S warning oece-x-blue.sh
```

`--help` / `--version` 不需要 root。其餘路徑在 `bootstrap` 要求 root。

## 版本狀態

| 階段 | 內容 | 狀態 |
|------|------|------|
| P1 | 32 項評分 + 面板 + Lynis | 完成 |
| P2 | preflight + rollback + manifest + 基礎/標準加固 | 完成 |
| P3 | CrowdSec / fail2ban / 蜜罐 / endlessh / 防火牆 | 完成 |
| P4 | 告警、日報、IOC、取證、封禁、緊急鎖定 | 完成 |
| P5 | 選單 6 / 7 / 21、雙語、dry-run、開源規格 | v2.0.0 完成 |

## 語言

優先序：`--lang` / `OECE_LANG` > `/etc/oece-x/lang` > `LANG`。

`zh_CN` 與任何 `zh*` 落到 `zh-Hant`。`en*` 落到 `en`。首次互動且沒有偏好檔時詢問一次，10 秒逾時寫入繁體。`--audit` 不提問。

選單標題走 `t()`。系統鍵名（sshd、ufw、路徑）保持英文。`--audit` 末行固定為：

```text
score=<pct> got=<n> max=<n>
```

日報只解析這一行。

## 2.0.0 行為變更

- 蜜罐 `AllowUsers` 保留已有有效公鑰、且不在誘餌名單的帳號，操作者確認後才寫入。
- 封禁拒絕當前 `SSH_CONNECTION` 來源，IP 必須通過 `is_ip`。
- 緊急鎖定保留 80/443。reset 前把 UFW numbered 狀態寫進回滾點。
- Cloudflare-only 在清單少於 5 段或含非法字元時不改防火牆。寫入失敗還原 `ufw.d`。
- CrowdSec 改走 packagecloud 倉庫與 `signed-by`，不再執行遠端安裝腳本。社群情報仍預設關閉。
- `blue_confirm` 只 `atrm` `/var/lib/oece-x/rollback.at` 裡的 job id。
- 回滾路徑必須是 `/var/backups/oece-x/20YYMMDD-HHMMSS` 真實目錄。符號連結拒絕。
- `sshd_set` / `env_set` 寫暫存檔再 `mv`。env 值以單引號轉義。
- 登入地理查詢預設關閉，只有 `LOGIN_GEO_LOOKUP=1` 才外傳來源 IP。
- 評分顏色與評級統一為 90 / 75 / 60 / 40。
- `--dry-run` 會跳過 `sshd_set` 與 `env_set` 的寫入。其餘危險模塊仍會在確認前提示，不要把它當成完整沙箱。

## 驗證紅線

SSH、防火牆、帳戶類操作不在生產機測試。用一次性測試機，或帶 systemd 的特權容器。

鎖門逃生：

1. 測試機跑標準加固。
2. 不要執行 `--confirm`。
3. 等回滾窗口結束。
4. 確認 sshd drop-in、`ssh.socket`、ufw、fail2ban 回到加固前，原憑證仍可登入。
5. 銷毀測試機與一次性 SSH 金鑰。

本機 macOS 只跑 `bash -n`、`shellcheck`、`--help`、`--version` 與非 root `--audit`（應在寫系統前拒絕）。

## 發佈

短命令若要指向本檔，由維護者在自己的主機上放置單檔副本並設定對應的 location。本倉庫不記錄該主機的路徑。

`curl | bash` 仍是未校驗便利入口。發布 SHA256 之前，選單 21 只比較 `SCRIPT_VERSION`，不覆蓋本機檔。

## 合規

不加代理或繞過封鎖。不硬編碼金鑰。不遙測。蜜罐資料只留本機。CrowdSec 社群情報預設關閉。
