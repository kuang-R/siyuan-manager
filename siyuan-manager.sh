#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SIYUAN_CONFIG_FILE:-$SCRIPT_DIR/users.conf}"
EXTRAS_FILE="$SCRIPT_DIR/extras.conf"
INDEX_MD="$SCRIPT_DIR/index.md"
BASE_PORT=6806
DEFAULT_IMAGE="b3log/siyuan"
SIYUAN_PORT=6806
PROXY_PORT=80
NETWORK="siyuan-net"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    cat <<EOF
用法: $0 <command> [args]

命令:
  start <username|all>    启动指定用户的思源笔记容器（all 表示所有用户）
  stop <username|all> [--rm] [--data]  停止容器（--rm 删除容器，--data 删除数据）
  restart <username|all>  重启指定用户的思源笔记容器（all 表示所有用户）
  status                查看所有用户容器的运行状态
  list                  列出所有用户及其访问地址
  archive <username|all>  备份指定用户的数据（all 表示所有用户）
  restore <username> <file>  从备份文件恢复用户数据
  archives              列出所有备份文件
  add <user> <password> [port] [image]  添加用户到配置文件
  remove <username> [--data]  从配置文件移除用户（--data 同时清理容器和数据）

注: nginx 代理会自动管理，无需手动操作

配置文件: $CONFIG_FILE
格式: username:password[:port[:image]]
EOF
    exit 0
}

# 读取配置文件，跳过空行和注释行
read_config() {
    grep -v '^\s*#' "$CONFIG_FILE" | grep -v '^\s*$' || true
}

# 获取用户端口（配置中指定或自动分配）
get_user_port() {
    local target="$1"
    local idx=0
    read_config | while IFS=':' read -r u p port img; do
        if [ "$u" = "$target" ]; then
            if [ -n "${port:-}" ]; then
                echo "$port"
            else
                echo $((BASE_PORT + idx))
            fi
            return
        fi
        idx=$((idx + 1))
    done
}

# 获取用户镜像（配置中指定或默认）
get_user_image() {
    local target="$1"
    read_config | while IFS=':' read -r u p port img; do
        if [ "$u" = "$target" ]; then
            if [ -n "${img:-}" ]; then
                echo "$img"
            else
                echo "$DEFAULT_IMAGE"
            fi
            return
        fi
    done
}

# 获取用户密码
get_user_password() {
    local target="$1"
    read_config | while IFS=':' read -r u p port img; do
        if [ "$u" = "$target" ]; then
            echo "$p"
            return
        fi
    done
}

# 检查用户是否存在于配置文件中
user_exists() {
    read_config | grep -q "^$1:"
}

# 获取所有用户名
get_all_users() {
    read_config | while IFS=':' read -r u p port img; do
        echo "$u"
    done
}

# 读取额外端口映射配置 label:port[:path]
# 检查端口是否可用
port_available() {
    local port="$1"
    # 检查宿主机端口是否被占用（兼容 Linux/macOS）
    if command -v ss &>/dev/null; then
        ! ss -tlnp 2>/dev/null | grep -q ":$port "
    elif command -v lsof &>/dev/null; then
        ! lsof -i ":$port" -sTCP:LISTEN &>/dev/null
    else
        true
    fi
}

read_extras() {
    [ -f "$EXTRAS_FILE" ] && grep -v '^\s*#' "$EXTRAS_FILE" | grep -v '^\s*$' || true
}

# 简单 Markdown → HTML 转换
md_to_html() {
    [ ! -f "$INDEX_MD" ] && return
    local in_list=false
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            if $in_list; then echo '</ul>'; in_list=false; fi
            continue
        fi
        case "$line" in
            '### '*)
                if $in_list; then echo '</ul>'; in_list=false; fi
                line="${line#\#\#\# }"
                echo "<h4>$(echo "$line" | sed 's/</\&lt;/g; s/>/\&gt;/g')</h4>"
                ;;
            '## '*)
                if $in_list; then echo '</ul>'; in_list=false; fi
                line="${line#\#\# }"
                echo "<h3>$(echo "$line" | sed 's/</\&lt;/g; s/>/\&gt;/g')</h3>"
                ;;
            '# '*)
                if $in_list; then echo '</ul>'; in_list=false; fi
                line="${line#\# }"
                echo "<h2>$(echo "$line" | sed 's/</\&lt;/g; s/>/\&gt;/g')</h2>"
                ;;
            '- '*)
                $in_list || { echo '<ul>'; in_list=true; }
                line="${line#- }"
                echo "<li>$(echo "$line" | sed 's/</\&lt;/g; s/>/\&gt;/g')</li>"
                ;;
            *)
                if $in_list; then echo '</ul>'; in_list=false; fi
                line=$(echo "$line" | sed 's/</\&lt;/g; s/>/\&gt;/g; s/\[\([^]]*\)\](\([^)]*\))/<a href="\2">\1<\/a>/g; s/`\([^`]*\)`/<code>\1<\/code>/g')
                echo "<p>$line</p>"
                ;;
        esac
    done < "$INDEX_MD"
    if $in_list; then echo '</ul>'; fi
}

# Docker 命令包装，末尾 || true 防止 pipefail + grep -q 时 SIGPIPE 导致管道失败
docker_ps()      { docker ps --format '{{.Names}}' 2>/dev/null || true; }
docker_ps_a()    { docker ps -a --format '{{.Names}}' 2>/dev/null || true; }
docker_vols()    { docker volume ls --format '{{.Name}}' 2>/dev/null || true; }

container_name() {
    echo "siyuan-$1"
}

volume_name() {
    echo "siyuan-data-$1"
}

cmd_start() {
    local user="$1"

    if ! user_exists "$user"; then
        echo -e "${RED}错误: 用户 '$user' 不存在于配置文件中${NC}"
        exit 1
    fi

    local port
    port=$(get_user_port "$user")
    local image
    image=$(get_user_image "$user")
    local password
    password=$(get_user_password "$user")
    local cname
    cname=$(container_name "$user")
    local vname
    vname=$(volume_name "$user")

    # 检查容器是否已在运行
    if ! port_available "$port" && ! docker_ps_a | grep -q "^${cname}$"; then
        echo -e "${RED}错误: 端口 $port 已被占用${NC}"
        exit 1
    fi

    if docker_ps | grep -q "^${cname}$"; then
        echo -e "${YELLOW}容器 $cname 已在运行中${NC}"
        echo "访问地址: http://localhost:$port"
        ensure_proxy
        return
    fi

    # 检查容器是否已存在（已停止）
    if docker_ps_a | grep -q "^${cname}$"; then
        echo "启动已存在的容器 $cname ..."
        docker start "$cname"
    else
        ensure_network
        # 确保 volume 存在
        docker volume create "$vname" > /dev/null 2>&1 || true

        echo "创建并启动容器 $cname (镜像: $image, 端口: $port) ..."
        docker run -d \
            --name "$cname" \
            --network "$NETWORK" \
            -p "${port}:${SIYUAN_PORT}" \
            -v "${vname}:/siyuan/workspace" \
            -e SIYUAN_ACCESS_AUTH_CODE="$password" \
            --restart unless-stopped \
            "$image" \
            --workspace=/siyuan/workspace \
            --lang=zh_CN
    fi

    echo -e "${GREEN}容器 $cname 启动成功${NC}"
    echo "访问地址: http://localhost:$port"
    echo "密码: $password"

    ensure_proxy
}

cmd_stop() {
    local user="$1"
    local remove_container=false
    local remove_data=false
    shift

    while [ $# -gt 0 ]; do
        case "$1" in
            --rm)   remove_container=true ;;
            --data) remove_data=true; remove_container=true ;;
        esac
        shift
    done

    if ! user_exists "$user"; then
        echo -e "${RED}错误: 用户 '$user' 不存在于配置文件中${NC}"
        exit 1
    fi

    local cname
    cname=$(container_name "$user")
    local vname
    vname=$(volume_name "$user")

    if docker_ps | grep -q "^${cname}$"; then
        echo "停止容器 $cname ..."
        docker stop "$cname"
        echo -e "${GREEN}容器 $cname 已停止${NC}"
    fi

    if $remove_container; then
        if docker_ps_a | grep -q "^${cname}$"; then
            echo "删除容器 $cname ..."
            docker rm "$cname" > /dev/null 2>&1 || docker rm -f "$cname" > /dev/null 2>&1 || true
            echo -e "${GREEN}容器 $cname 已删除${NC}"
        fi
    fi

    if $remove_data; then
        if docker_vols | grep -q "^${vname}$"; then
            echo "删除数据卷 $vname ..."
            docker volume rm "$vname" > /dev/null 2>&1 || true
            echo -e "${GREEN}数据卷 $vname 已删除${NC}"
        fi
    fi

    prune_proxy
}

cmd_add() {
    local user="$1"
    local password="$2"
    local port="${3:-}"
    local image="${4:-}"

    if user_exists "$user"; then
        echo -e "${RED}错误: 用户 '$user' 已存在${NC}"
        exit 1
    fi

    local line="$user:$password"
    [ -n "$port" ]  && line="$line:$port"
    [ -n "$image" ] && line="$line:$image"

    echo "$line" >> "$CONFIG_FILE"
    echo -e "${GREEN}用户 '$user' 已添加${NC}"
    ensure_proxy
}

cmd_remove() {
    local user="$1"
    local clean_data=false
    if [ "${2:-}" = "--data" ]; then
        clean_data=true
    fi

    if ! user_exists "$user"; then
        echo -e "${RED}错误: 用户 '$user' 不存在于配置文件中${NC}"
        exit 1
    fi

    if $clean_data; then
        local cname vname
        cname=$(container_name "$user")
        vname=$(volume_name "$user")

        docker stop "$cname" > /dev/null 2>&1 || true
        docker rm -f "$cname" > /dev/null 2>&1 || true
        docker volume rm "$vname" > /dev/null 2>&1 || true
        echo "已清理容器和数据卷"
    fi

    # 从配置文件中移除该用户行
    sed -i '' "/^${user}:/d" "$CONFIG_FILE"
    echo -e "${GREEN}用户 '$user' 已从配置文件中移除${NC}"
    ensure_proxy
}

ensure_network() {
    docker network create "$NETWORK" > /dev/null 2>&1 || true
}

nginx_dir() { echo "$SCRIPT_DIR/nginx"; }
proxy_name() { echo "siyuan-proxy"; }

# 生成 nginx 配置
generate_nginx_conf() {
    local dir
    dir=$(nginx_dir)
    mkdir -p "$dir"

    # 生成首页 HTML（通过独立文件，方便嵌入 markdown 和 extras）
    local index_html="$dir/index.html"
    cat > "$index_html" <<'HEADEOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Siyuan</title>
<style>body{font-family:sans-serif;max-width:600px;margin:60px auto;padding:20px}
h2,h3,h4{color:#333;margin:16px 0 8px}
a.block{display:block;padding:12px 16px;margin:4px 0;background:#f0f0f0;
border-radius:6px;text-decoration:none;color:#333;font-size:16px}
a.block:hover{background:#e0e0e0}
p{color:#555;line-height:1.6}
ul{margin:4px 0;padding-left:20px}
li{margin:2px 0}code{background:#eee;padding:1px 4px;border-radius:3px}
hr{margin:20px 0;border:none;border-top:1px solid #eee}
</style></head><body>
HEADEOF

    # 插入 index.md 内容
    if [ -f "$INDEX_MD" ]; then
        md_to_html >> "$index_html"
    fi

    # 思源用户列表
    echo '<h2>思源笔记</h2>' >> "$index_html"
    read_config | while IFS=':' read -r u p port img; do
        local assigned_port
        assigned_port=$(get_user_port "$u")
        echo "<a class=\"block\" href=\"/siyuan/$u\">$u <span style=\"color:#999;font-size:14px\">:$assigned_port</span></a>" >> "$index_html"
    done

    # extras 额外链接
    if [ -f "$EXTRAS_FILE" ] && [ -n "$(read_extras)" ]; then
        echo '<hr><h3>其他服务</h3>' >> "$index_html"
        read_extras | while IFS=':' read -r label port path; do
            local slug
            slug=$(echo "$label" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')
            echo "<a class=\"block\" href=\"/e/$slug\">$label <span style=\"color:#999;font-size:14px\">:$port${path:-}</span></a>" >> "$index_html"
        done
    fi

    cat >> "$index_html" <<'HEADEOF'
</body></html>
HEADEOF

    # 生成 nginx.conf
    cat > "$dir/nginx.conf" <<'NGINXEOF'
events { worker_connections 1024; }

http {
    server {
        listen 80;

        location = / {
            root /homepage;
            try_files /index.html =404;
            default_type text/html;
            charset utf-8;
        }

NGINXEOF

    # siyuan 重定向
    read_config | while IFS=':' read -r u p port img; do
        local assigned_port
        assigned_port=$(get_user_port "$u")
        cat >> "$dir/nginx.conf" <<LOCATIONEOF

        location /siyuan/$u {
            return 301 http://\$host:$assigned_port;
        }
LOCATIONEOF
    done

    # extras 重定向
    if [ -f "$EXTRAS_FILE" ]; then
        read_extras | while IFS=':' read -r label port path; do
            local slug
            slug=$(echo "$label" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')
            cat >> "$dir/nginx.conf" <<LOCATIONEOF

        location /e/$slug {
            return 301 http://\$host:$port${path:-};
        }
LOCATIONEOF
        done
    fi

    cat >> "$dir/nginx.conf" <<'NGINXEOF'
    }
}
NGINXEOF
}

# 没有运行中的 siyuan 容器时关闭代理
prune_proxy() {
    local cname
    cname=$(proxy_name)

    # 检查是否有 siyuan 笔记容器在运行（排除代理自身）
    local running
    running=$(docker_ps | grep "^siyuan-" | grep -v "^${cname}$" || true)

    if [ -z "$running" ]; then
        if docker_ps_a | grep -q "^${cname}$"; then
            echo "没有运行中的笔记，删除代理容器..."
            docker rm -f "$cname" > /dev/null 2>&1 || true
        fi
    fi
}

# 确保代理运行并配置最新
ensure_proxy() {
    local cname
    cname=$(proxy_name)
    local dir
    dir=$(nginx_dir)

    generate_nginx_conf

    if docker_ps | grep -q "^${cname}$"; then
        # 已在运行，重载配置
        docker exec "$cname" nginx -s reload 2>/dev/null || true
        return
    fi

    if docker_ps_a | grep -q "^${cname}$"; then
        docker start "$cname" > /dev/null
    else
        docker run -d \
            --name "$cname" \
            -p "${PROXY_PORT}:80" \
            -v "$dir/nginx.conf:/etc/nginx/nginx.conf:ro" \
            -v "$dir/index.html:/homepage/index.html:ro" \
            --restart unless-stopped \
            nginx:alpine > /dev/null
    fi

    echo -e "${GREEN}nginx 代理已就绪: http://localhost:$PROXY_PORT${NC}"
}

cmd_restart() {
    local user="$1"
    cmd_stop "$user"
    echo ""
    cmd_start "$user"
}

cmd_status() {
    printf "%-15s %-12s %-8s %-20s\n" "用户名" "状态" "端口" "镜像"
    printf "%-15s %-12s %-8s %-20s\n" "-----" "----" "----" "-----"

    read_config | while IFS=':' read -r u p port img; do
        local cname
        cname=$(container_name "$u")
        local status="停止"
        local port_str="-"

        if docker_ps | grep -q "^${cname}$"; then
            status="${GREEN}运行中${NC}"
            port_str=$(docker port "$cname" "$SIYUAN_PORT" 2>/dev/null | sed 's/.*://' || echo "-")
        fi

        printf "%-15s " "$u"
        echo -ne "$status"
        printf " %-8s %-20s\n" "$port_str" "${img:-$DEFAULT_IMAGE}"
    done
}

cmd_list() {
    local proxy_running=false
    docker_ps | grep -q "^$(proxy_name)$" && proxy_running=true

    printf "%-15s %-8s %-30s %-20s\n" "用户名" "端口" "访问地址" "镜像"
    printf "%-15s %-8s %-30s %-20s\n" "-----" "----" "--------" "----"

    read_config | while IFS=':' read -r u p port img; do
        local assigned_port
        assigned_port=$(get_user_port "$u")
        local img_display="${img:-$DEFAULT_IMAGE}"
        if $proxy_running; then
            printf "%-15s %-8s http://localhost:%s  %-20s\n" "$u" "$assigned_port" "http://localhost:$PROXY_PORT/siyuan/$u/" "$img_display"
        else
            printf "%-15s %-8s http://localhost:%s  %-20s\n" "$u" "$assigned_port" "$assigned_port" "$img_display"
        fi
    done
}

BACKUP_DIR="${SIYUAN_BACKUP_DIR:-$SCRIPT_DIR/backups}"

cmd_archive() {
    local user="$1"

    if ! user_exists "$user"; then
        echo -e "${RED}错误: 用户 '$user' 不存在于配置文件中${NC}"
        exit 1
    fi

    local cname
    cname=$(container_name "$user")
    local vname
    vname=$(volume_name "$user")
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/siyuan-${user}-${ts}.tar.gz"

    mkdir -p "$BACKUP_DIR"

    # 检查容器是否在运行，运行中则先停止
    local was_running=false
    if docker_ps | grep -q "^${cname}$"; then
        was_running=true
        echo "容器 $cname 正在运行，先停止..."
        docker stop "$cname"
    fi

    echo "正在备份 $user 的数据..."
    docker run --rm \
        -v "${vname}:/data" \
        -v "$BACKUP_DIR:/backup" \
        alpine \
        tar czf "/backup/$(basename "$backup_file")" -C /data .

    echo -e "${GREEN}备份完成: $backup_file${NC}"

    # 如果之前是运行状态，重新启动
    if $was_running; then
        echo "重新启动容器 $cname ..."
        docker start "$cname"
    fi
}

cmd_restore() {
    local user="$1"
    local backup_file="$2"

    if ! user_exists "$user"; then
        echo -e "${RED}错误: 用户 '$user' 不存在于配置文件中${NC}"
        exit 1
    fi

    if [ ! -f "$backup_file" ]; then
        echo -e "${RED}错误: 备份文件 '$backup_file' 不存在${NC}"
        exit 1
    fi

    local cname
    cname=$(container_name "$user")
    local vname
    vname=$(volume_name "$user")

    # 停止容器（如果在运行）
    if docker_ps | grep -q "^${cname}$"; then
        echo "停止容器 $cname ..."
        docker stop "$cname"
    fi

    # 清空 volume 数据
    echo "清空现有数据..."
    docker run --rm -v "${vname}:/data" alpine sh -c 'rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null || true'

    # 恢复数据
    echo "正在从 $backup_file 恢复数据..."
    docker run --rm \
        -v "${vname}:/data" \
        -v "$(dirname "$backup_file"):/backup:ro" \
        alpine \
        tar xzf "/backup/$(basename "$backup_file")" -C /data

    echo -e "${GREEN}数据恢复完成${NC}"
    echo "使用 '$0 start $user' 启动容器"
}

cmd_archives() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo "暂无备份文件"
        return
    fi

    printf "%-40s %-10s\n" "文件名" "大小"
    printf "%-40s %-10s\n" "----" "----"

    for f in "$BACKUP_DIR"/*.tar.gz; do
        [ -f "$f" ] || continue
        local fname size
        fname=$(basename "$f")
        size=$(du -h "$f" | cut -f1)
        printf "%-40s %-10s\n" "$fname" "$size"
    done
}

# 主入口
if [ $# -eq 0 ]; then
    usage
fi

# 检查 Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}错误: 未找到 Docker，请先安装 Docker${NC}"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo -e "${RED}错误: Docker 未运行或无权限访问${NC}"
    exit 1
fi

# 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}错误: 配置文件 $CONFIG_FILE 不存在${NC}"
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    start)
        [ $# -lt 1 ] && { echo -e "${RED}用法: $0 start <username|all>${NC}"; exit 1; }
        if [ "$1" = "all" ]; then
            get_all_users | while read -r u; do
                echo -e "${YELLOW}=== 用户: $u ===${NC}"
                cmd_start "$u"
                echo ""
            done
        else
            cmd_start "$1"
        fi
        ;;
    stop)
        [ $# -lt 1 ] && { echo -e "${RED}用法: $0 stop <username|all> [--rm] [--data]${NC}"; exit 1; }
        if [ "$1" = "all" ]; then
            shift
            get_all_users | while read -r u; do
                echo -e "${YELLOW}=== 用户: $u ===${NC}"
                cmd_stop "$u" "$@"
                echo ""
            done
        else
            cmd_stop "$@"
        fi
        ;;
    restart)
        [ $# -lt 1 ] && { echo -e "${RED}用法: $0 restart <username|all>${NC}"; exit 1; }
        if [ "$1" = "all" ]; then
            get_all_users | while read -r u; do
                echo -e "${YELLOW}=== 用户: $u ===${NC}"
                cmd_restart "$u"
                echo ""
            done
        else
            cmd_restart "$1"
        fi
        ;;
    status)
        cmd_status
        ;;
    list)
        cmd_list
        ;;
    archive)
        [ $# -lt 1 ] && { echo -e "${RED}用法: $0 archive <username|all>${NC}"; exit 1; }
        if [ "$1" = "all" ]; then
            get_all_users | while read -r u; do
                echo -e "${YELLOW}=== 用户: $u ===${NC}"
                cmd_archive "$u"
                echo ""
            done
        else
            cmd_archive "$1"
        fi
        ;;
    restore)
        [ $# -lt 2 ] && { echo -e "${RED}用法: $0 restore <username> <备份文件>${NC}"; exit 1; }
        cmd_restore "$1" "$2"
        ;;
    archives)
        cmd_archives
        ;;
    add)
        [ $# -lt 2 ] && { echo -e "${RED}用法: $0 add <username> <password> [port] [image]${NC}"; exit 1; }
        cmd_add "$@"
        ;;
    remove)
        [ $# -lt 1 ] && { echo -e "${RED}用法: $0 remove <username> [--data]${NC}"; exit 1; }
        cmd_remove "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo -e "${RED}未知命令: $COMMAND${NC}"
        usage
        ;;
esac
