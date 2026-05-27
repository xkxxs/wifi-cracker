# wifi-cracker

WiFi 密码字典破解工具，TUI 图形界面。

## 功能

- 扫描附近 WiFi，选择目标
- 内置精选字典 + 完整字典 + 自定义字典
- 实时进度条，支持随时停止
- 找到密码自动保存

## 安装

```bash
bash wifi_crack_install.sh
```

安装后输入 `wifitui` 启动。

## 依赖

- NetworkManager (nmcli)
- wpa_supplicant + wpa_cli

Ubuntu/Debian 自带，Armbian 同样适用。

## 使用

```bash
wifitui
```

首次运行需输入 sudo 密码（用于操作网卡），存储在 `~/.config/wifi-cracker/config.json`。
