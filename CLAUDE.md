思源笔记多用户 Docker 管理脚本，用于多人共享同一台服务器运行思源笔记。

## 文件结构

- `siyuan-manager.sh` — 主管理脚本
- `users.conf` — 用户配置文件（权限 600）
- `test.sh` — 测试脚本

## 配置文件格式

```
# username:password[:port[:image]]
alice:pass123                           # 自动分配端口，默认镜像
bob:bob456:6810                         # 指定端口
charlie:mypw:6812:custom/siyuan:v3      # 全自定义
```

## 命令

| 命令 | 说明 |
|------|------|
| `start <user\|all>` | 启动容器 |
| `stop <user\|all>` | 停止容器 |
| `restart <user\|all>` | 重启容器 |
| `status` | 查看运行状态 |
| `list` | 列出用户及访问地址 |
| `archive <user\|all>` | 备份数据 |
| `restore <user> <file>` | 恢复数据 |
| `archives` | 列出备份文件 |
| `delete <user\|all> [--data]` | 删除容器（--data 同时删数据） |

## 核心设计

- 每个用户独立容器 `siyuan-{username}` 和 volume `siyuan-data-{username}`
- 基础端口 6806，按配置顺序递增，也可在配置文件中指定
- 默认镜像 `b3log/siyuan`，可配置自定义镜像
- 容器参数：`--workspace=/siyuan/workspace --lang=zh_CN`
- 访问授权码通过环境变量 `SIYUAN_ACCESS_AUTH_CODE` 传入（值为密码）
- 数据通过 Docker volume 持久化，容器删除后数据不丢失
- 可通过环境变量 `SIYUAN_CONFIG_FILE` 和 `SIYUAN_BACKUP_DIR` 覆盖配置和备份路径

## 注意事项

- 脚本使用 `set -euo pipefail`，管道中使用 `grep -q` 需配合 `|| true` 包裹左侧命令，否则 SIGPIPE 会导致管道失败
- 通配符使用 `all` 而非 `*`，避免 shell glob 展开
- 配置文件中密码明文存储，权限需设为 600
