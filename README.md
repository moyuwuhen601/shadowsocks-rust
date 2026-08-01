# Shadowsocks-Rust 一键管理脚本

面向 Debian/Ubuntu + systemd 的 Shadowsocks-Rust 安装、更新和管理脚本。脚本会从
[shadowsocks/shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust/releases)
下载与当前 CPU 架构匹配的官方发布包。

## 功能

- 安装或更新最新的 `ssserver`
- 生成 Shadowsocks 配置、SIP002 链接和二维码
- 管理 systemd 服务及查看实时日志
- 支持 AES-GCM、ChaCha20-Poly1305 和 Shadowsocks 2022
- 可选开启 BBR
- 校验官方 SHA-256，验证可执行文件后再原子安装
- 使用独立的低权限账户运行服务

## 支持环境

- Debian / Ubuntu（使用 `apt`）
- systemd
- `x86_64`、`aarch64`、`armv7l`、`i686`、`loongarch64`、`riscv64`

其他发行版目前不会自动安装依赖。

## 使用方法

```bash
curl -fLO https://raw.githubusercontent.com/moyuwuhen601/shadowsocks-rust/main/shadowsocks-rust.sh
chmod +x shadowsocks-rust.sh
sudo ./shadowsocks-rust.sh
```

首次使用选择 `1. 安装 / 重置配置`。如果已有配置，只想更新内核，请选择
`2. 更新内核`。

## 修复 `status=203/EXEC`

以下错误表示 systemd 指定的可执行文件不存在：

```text
Unable to locate executable '/usr/local/bin/ssserver'
Failed at step EXEC
status=203/EXEC
```

旧版脚本没有安装解压 `.tar.xz` 所需的 `xz-utils`，也没有在解压或移动失败后中止，
因此可能在 `ssserver` 不存在时仍创建并启动 service。更新脚本后重新运行：已有有效配置
可选择 `2` 修复并保留配置；尚未配置或希望重置时选择 `1`。新版会在每一步失败时明确
报错，不再留下无效服务。

可使用下面的命令手动确认状态：

```bash
test -x /usr/local/bin/ssserver && /usr/local/bin/ssserver --version
systemctl status shadowsocks-rust --no-pager
journalctl -u shadowsocks-rust -n 50 --no-pager
```

## 文件位置

| 用途 | 路径 |
|---|---|
| 内核 | `/usr/local/bin/ssserver` |
| 配置 | `/etc/shadowsocks-rust/config.json` |
| 备注 | `/etc/shadowsocks-rust/remarks` |
| systemd 单元 | `/etc/systemd/system/shadowsocks-rust.service` |

配置文件包含密码，脚本会将其权限设置为 `0640`，仅允许 root 和专用服务账户读取。
