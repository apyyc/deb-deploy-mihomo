# 更新记录

## v0.3.x —— 整理成文（当前）

目录从 `mihomo/` 改名为 `deploy-mihomo/`，补 README 和 CHANGELOG。未动脚本逻辑。

- 脚本名定为 `deploy-mihomo.sh`。
- 明确 config.yaml 是源头，/etc/mihomo/config.yaml 是守护进程读取的副本。
- 文档点出 `external-controller` 用 `0.0.0.0:9090`，仅本机使用建议改回 `127.0.0.1`。

遗留：`/root/clashctl` 为更早独立部署，脚本不接管，可自行删除。

## v0.2.x —— 换 systemd 管进程

将 mihomo 从 cron @reboot + nohup 改为 systemd 服务。开机自启、崩溃自动重启、日志进 journald。

- 重写 `/etc/systemd/system/mihomo.service`（原指向旧 `/root/clashctl`），改为 `ExecStart=/usr/local/bin/mihomo -f /etc/mihomo/config.yaml`。
- `enable` 时自动移除 crontab `@reboot mihomo.sh`。
- `prune` 删除旧 `/usr/bin/mihomo`。
- 修复：迁移初期 systemd 用 8 月旧配置（无 `port: 7890`），`config` 覆盖后 7890 正常监听。

遗留：deb 包自带 `/usr/lib/systemd/system/mihomo.service`（disabled、inactive）未启用，属包残留，与 deploy 版注意区分。

## v0.1.x —— 从 proxyctl.sh 长出 install/config

根目录原 `proxyctl.sh` 仅把系统代理环境变量指向 Clash/mihomo 端口。本项目升级为完整管理：

- 新增 `install` / `update`：按架构下载内核，默认锁 `v1.19.30`（`DEFAULT_VERSION` 可改），装到 `/usr/local/bin/mihomo`，`mihomo -v` 校验。
- 新增 `config` / `config pull`：部署 config.yaml 到 /etc/mihomo 并 `mihomo -t` 校验；可反向回收。
- 保留 proxyctl 的 on/off/enable/disable，现同时管 systemd 服务与代理环境变量。
- 下载加 `curl -C -` 续传、`--retry-all-errors`，代理失败后自动直连兜底。
- 沿用标记块写法，幂等不叠块；清除时兼容旧 proxyctl 块。

## 起源

git 最早一笔 `8543257`：`proxyctl.sh — Clash GUI 代理管理脚本（本机/局域网通用）`。只做系统代理环境变量（start/stop/enable/disable/status）。同目录另有 `mihomo.sh`（一行 nohup）、`mihomo.log`、`config.yaml`（MihomoProPlus v6-20260131，原者 YYDS666，修改 HenryChiao）。这套"配置 + nohup + 文件日志"的雏形即今日项目替代对象。