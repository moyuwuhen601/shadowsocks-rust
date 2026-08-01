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
- 更新或重配失败时自动恢复原内核、配置和 systemd 状态
- 启动后同时检查 systemd 状态及实际 TCP/UDP 监听
- 仅删除脚本自行创建的服务账户，不影响同名的既有账户

## 支持环境

- Debian / Ubuntu（使用 `apt`）
- 正在运行的 systemd
- `x86_64`、`aarch64`、`armv7l`、`i686`、`loongarch64`、`riscv64`

其他发行版目前不会自动安装依赖。

## 使用方法

```bash
curl -fLO https://raw.githubusercontent.com/moyuwuhen601/shadowsocks-rust/main/shadowsocks-rust.sh
chmod +x shadowsocks-rust.sh
sudo ./shadowsocks-rust.sh
```

脚本包含交互式配置，必须在终端中以 root 权限运行；请勿使用
`curl ... | bash`。下载完成后再执行也便于先检查脚本内容。

首次使用选择 `1. 安装 / 重置配置`。如果已有配置，只想更新内核，请选择
`2. 更新内核`。更新后的服务未能正常启动或未同时监听要求的 TCP/UDP 端口时，脚本会
自动恢复原内核并尝试重新启动原服务。

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
报错，不再留下无效服务。若配置、服务单元或内核更新后健康检查失败，相关变更会作为
同一事务回滚。

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
| 脚本状态与账户标记 | `/var/lib/shadowsocks-rust` |

配置文件包含密码，脚本会将其权限设置为 `0640`，仅允许 root 和专用服务账户读取。
卸载时只会移除带有脚本管理标记的用户和组；BBR 属于系统级网络设置，脚本会保留它并
给出提示，不会因卸载 Shadowsocks 而修改其他服务使用中的拥塞控制配置。

## 安全与可靠性

- 内核先下载到临时目录，完成校验、解压和 `--version` 验证后才原子替换。
- 配置变更前会保存原配置、备注、服务单元、目录权限及服务启停状态。
- 健康检查等待服务稳定后，通过主进程 PID 验证目标端口的 TCP/UDP 监听。
- BBR 仅加载脚本自己的 `/etc/sysctl.d/99-shadowsocks-bbr.conf`，不会执行全局
  `sysctl --system`。
- systemd 服务启用基础沙箱和权限收敛，同时保留 Shadowsocks 正常运行所需能力。

## 本地检查

```bash
bash -n shadowsocks-rust.sh tests/run.sh
shellcheck -x shadowsocks-rust.sh tests/run.sh
bash tests/run.sh
```
