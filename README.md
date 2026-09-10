# OpenVPN 自動建置（Linux / macOS）

在 Linux 或 macOS 上安裝 **OpenVPN 伺服器** 或 **用戶端**。  
伺服器用帳號 + 密碼 + OTP（TOTP）驗證；密碼由 Go 程式做 PBKDF2 雜湊，不會存明文。

## 需要什麼

- 伺服器：root（`sudo`）、TUN 裝置；macOS 當伺服器時需 [Homebrew](https://brew.sh)
- 用戶端：Linux 用 `sudo`；macOS 可匯入 Tunnelblick / OpenVPN Connect
- 雲端主機請在安全組放行對應埠（預設 **UDP 1194**）

## 安裝伺服器

```bash
sudo ./openvpn-setup.sh
```

選 **1) 伺服器**。也可以：

```bash
sudo ./openvpn-setup.sh server
```

裝完會進入帳號管理，請自行輸入帳號、密碼，並用驗證器 App 掃描 OTP QR。

## 帳號 / OTP

```bash
sudo ./openvpn-setup.sh users
```

- 新增、刪除帳號
- 修改密碼
- 重設 / 再顯示 OTP

連線時：帳號照填；**密碼欄填「登入密碼 + 6 碼 OTP」**  
例如密碼 `hello12`、OTP `123456` → 輸入 `hello12123456` 或 `hello12 123456`。

## 用戶端

把伺服器上的 `/etc/openvpn/clients/client.ovpn` 拷過來後：

```bash
sudo ./openvpn-setup.sh client --ovpn ./client.ovpn
```

macOS 也可把 `.ovpn` 匯入 [Tunnelblick](https://tunnelblick.net/) 或 [OpenVPN Connect](https://openvpn.net/client/)。

## 目錄說明

| 路徑 | 用途 |
|---|---|
| `openvpn-setup.sh` | 安裝與管理腳本 |
| `ovpn-passwd/` | Go 帳號／密碼／OTP 工具（含 Linux / macOS 預編譯檔） |

## 其他指令

```bash
sudo ./openvpn-setup.sh status
sudo ./openvpn-setup.sh list-users
sudo ./openvpn-setup.sh add-user
sudo ./openvpn-setup.sh otp alice
sudo ./openvpn-setup.sh uninstall
./openvpn-setup.sh help
```
