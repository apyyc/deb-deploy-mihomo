# deploy-mihomo

在 Debian 上安装、部署、管理 mihomo（Clash Meta 内核）的脚本。

原 `mihomo/` 目录，内含一份 `config.yaml`、`proxyctl.sh`（只管系统代理环境变量）、`mihomo.sh`（nohup 拉起进程）。现合并为 `deploy-mihomo.sh`：内核下载、配置部署、systemd 服务与系统代理环境变量一并管理。

## 目录结构

```
deploy-mihomo/
├── config.yaml        # 配置源头；守护进程实际读部署后的 /etc/mihomo/config.yaml
└── deploy-mihomo.sh   # 主脚本
```

脚本会改动以下系统位置（需 root）：

| 位置 | 用途 |
|------|------|
| `/usr/local/bin/mihomo` | 内核二进制 |
| `/etc/mihomo/config.yaml` | 守护进程读取的配置副本 |
| `/etc/systemd/system/mihomo.service` | systemd 服务单元（on/enable 时生成） |
| `/etc/environment` | 系统级代理环境变量 |
| `/etc/profile.d/proxy.sh` | 登录 shell 加载的代理 export |

## 用法

```bash
sudo ./deploy-mihomo.sh enable    # 装内核 + 部署配置 + 起服务 + 开机自启 + 写代理环境（缺项自动补）
./deploy-mihomo.sh status         # 查看状态
sudo ./deploy-mihomo.sh off       # 停服务并清代理环境变量
sudo ./deploy-mihomo.sh on        # 再开
```

## 子命令

| 子命令 | 作用 |
|--------|------|
| `install [版本]` | 下载安装 mihomo；默认装锁定版本，可传版本临时指定 |
| `update [版本]` | 强制重装 |
| `config` | 部署项目 config.yaml 到 /etc/mihomo 并校验 |
| `config pull` | 回收线上配置回项目 |
| `test` | 校验 /etc/mihomo/config.yaml 语法 |
| `on` / `start` | 起服务 + 写代理环境变量 |
| `off` / `stop` | 停服务 + 清代理环境变量 |
| `enable` | 开机自启 + on |
| `disable` | 清开机自启 + off |
| `restart` | 重启服务 |
| `status` | 汇总状态 |
| `logs [-f]` | 查看日志（journalctl） |
| `edit` | 编辑 /etc/mihomo/config.yaml，保存后询问是否重启 |
| `prune` | 清理旧 /usr/bin/mihomo、crontab @reboot 条目 |

## 版本与架构

- 锁定版本在脚本顶部 `DEFAULT_VERSION`（当前 `v1.19.30`）。
- 自动识别 amd64 / arm64 / armv7 / 386，按 `mihomo-linux-<arch>-<版本>.gz` 下载，装后 `mihomo -v` 校验一致性。
- releases 无 sha256 资产，完整性以版本号校验兜底。

## 下载

本机代理链路拉 GitHub 大文件会 SSL 中断。脚本用 `curl -C -` 续传 + `--retry-all-errors`，代理连续失败后自动直连重试一次。

## 配置

`config.yaml` 为 MihomoProPlus（v6-20260131），`proxy-providers` 填入机场订阅链接。`external-controller` 为 `0.0.0.0:9090`，仅本机使用建议改回 `127.0.0.1:9090`。

## 边界

- 写系统文件、起服务需 root。
- `edit` 依赖交互式终端。
- `on` 时会识别并停掉 systemd 之外的旧 mihomo 进程，转交 systemd 接管。
- 遗留 `/root/clashctl`（更早独立部署）不在脚本管理范围，可自行删除。