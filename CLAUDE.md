思源笔记多用户 Docker 管理脚本，用于多人共享同一台服务器运行思源笔记。

## 文件结构

- `siyuan-manager.sh` — 主管理脚本
- `users.conf` — 用户配置文件（权限 600）
- `test.sh` — 测试脚本（60 项，全部 mock Docker 命令）
- `index.md` — 首页 Markdown 内容（可选）
- `extras.conf` — 额外端口映射（可选）
- `images/` — 本地镜像 tar（`b3log-siyuan.tar`, `nginx-alpine.tar`, `alpine.tar`），linux/amd64
- `.gitignore` — 忽略测试临时目录、备份目录、nginx 配置

## 配置文件格式

```
# username:password[:port[:image]]
alice:pass123                           # 自动分配端口，默认镜像
bob:bob456:6810                         # 指定端口
charlie:mypw:6812:custom/siyuan:v3      # 全自定义
```

## extras.conf 格式

```
# 标签:端口[:路径]
监控面板:8080
文件管理:9000:/files

# 标签:URL — 外部服务器
外部服务:https://example.com/api
```

## 命令

| 命令 | 说明 |
|------|------|
| `start <user\|all>` | 启动容器 |
| `stop <user\|all> [--rm] [--data]` | 停止容器（--rm 删除容器，--data 删除数据） |
| `restart <user\|all>` | 重启容器 |
| `status` | 查看运行状态 |
| `list` | 列出用户及访问地址 |
| `archive <user\|all>` | 备份数据 |
| `restore <user> <file>` | 恢复数据 |
| `archives` | 列出备份文件 |
| `add <user> <pw> [port] [img]` | 添加用户到配置文件 |
| `remove <user> [--data]` | 从配置文件移除用户（--data 清理容器数据） |

## 核心设计

- 每个用户独立容器 `siyuan-{username}` 和 volume `siyuan-data-{username}`
- 基础端口 6806，按配置顺序递增，也可在配置文件中指定
- 镜像统一在脚本头部变量定义：`DEFAULT_IMAGE`（思源）、`NGINX_IMAGE`（代理）、`ALPINE_IMAGE`（备份/恢复）
- 容器参数：`--workspace=/siyuan/workspace --lang=zh_CN`
- 访问授权码通过环境变量 `SIYUAN_ACCESS_AUTH_CODE` 传入（值为密码）
- 数据通过 Docker volume 持久化，容器删除后数据不丢失
- 通过 `add`/`remove` 命令管理用户配置，`remove --data` 会同时清理容器和数据卷
- 容器加入 `siyuan-net` 网络，便于容器间通信
- `read_user_fields` 一次读取用户所有字段（端口、镜像、密码），避免重复解析配置文件
- `with_users` 统一处理 `all` 和单用户分发逻辑

## nginx 代理

- 代理自动管理：`start`、`add`、`remove` 操作会自动更新 nginx 配置
- 代理已运行时使用热重载（`nginx -s reload`），无需重启容器
- 所有笔记停止后代理容器自动删除，下次 `start` 时重新创建
- 首页 `/` 展示所有用户列表，点击跳转到对应端口
- `/siyuan/{user}` 301 重定向到 `http://host:{port}`，不修改思源内容
- 思源笔记不支持子路径部署（无 servePath），因此采用端口重定向而非路径代理
- 支持 `index.md` 自定义首页内容（Markdown 自动转 HTML）
- 支持 `extras.conf` 映射其他端口到首页（格式：`标签:端口[:路径]`）

## 注意事项

- 脚本使用 `set -euo pipefail`，管道中使用 `grep -q` 需配合 `|| true` 包裹左侧命令（参见 `docker_ps` 等包装函数），否则 SIGPIPE 会导致管道失败
- 通配符使用 `all` 而非 `*`，避免 shell glob 展开
- 配置文件中密码明文存储，权限需设为 600
- 启动时检测端口占用，避免与已有服务冲突
- 可通过环境变量 `SIYUAN_CONFIG_FILE` 和 `SIYUAN_BACKUP_DIR` 覆盖配置和备份路径
