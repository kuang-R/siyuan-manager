#!/bin/bash
# 测试脚本 - 模拟 Docker 环境测试 siyuan-manager.sh 功能

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TEST_DIR/siyuan-manager.sh"
TMP="$TEST_DIR/.test-tmp"

PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() { rm -rf "$TMP" "$TEST_DIR/.test-backups"; }
trap cleanup EXIT

setup() {
    cleanup
    mkdir -p "$TMP/bin" "$TMP/backups"
    cat > "$TMP/bin/docker" <<'MOCKEOF'
#!/bin/bash
echo "$@" >> "$TMP/docker.log"
case "$1" in
    info) exit 0 ;;
    ps) ;;
    volume)
        case "$2" in
            create) ;;
            ls)
                for v in siyuan-data-alice siyuan-data-bob siyuan-data-charlie siyuan-data-u1 siyuan-data-u2 siyuan-data-u3; do
                    echo "$v"
                done
                ;;
            rm) ;;
        esac
        ;;
    start|stop|rm|run|port|network) ;;
esac
exit 0
MOCKEOF
    sed "s|\$TMP|$TMP|g" "$TMP/bin/docker" > "$TMP/bin/docker.tmp" && mv "$TMP/bin/docker.tmp" "$TMP/bin/docker"
    chmod +x "$TMP/bin/docker"

    # mock ss/lsof，避免真实端口占用影响测试
    cat > "$TMP/bin/ss" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$TMP/bin/lsof" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TMP/bin/ss" "$TMP/bin/lsof"
}

# 运行脚本（输出写入文件，避免 $(...) 子shell 影响管道）
run_script() {
    >"$TMP/output.txt"
    PATH="$TMP/bin:$PATH" \
    SIYUAN_CONFIG_FILE="$TMP/test-users.conf" \
    SIYUAN_BACKUP_DIR="$TMP/backups" \
    bash "$SCRIPT" "$@" >>"$TMP/output.txt" 2>&1 || true
}

out() { cat "$TMP/output.txt"; }

assert_contains() {
    local output="$1" expected="$2" msg="$3"
    if echo "$output" | grep -q "$expected"; then
        echo -e "${GREEN}PASS${NC} $msg"
        PASS=$((PASS+1))
    else
        echo -e "${RED}FAIL${NC} $msg"
        echo "  expected: '$expected'"
        echo "  output:   '$output'"
        FAIL=$((FAIL+1))
    fi
}

assert_not_contains() {
    local output="$1" expected="$2" msg="$3"
    if ! echo "$output" | grep -q "$expected"; then
        echo -e "${GREEN}PASS${NC} $msg"
        PASS=$((PASS+1))
    else
        echo -e "${RED}FAIL${NC} $msg"
        echo "  unexpected: '$expected'"
        FAIL=$((FAIL+1))
    fi
}

assert_docker_called() {
    if grep -q "$1" "$TMP/docker.log" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC} $2"
        PASS=$((PASS+1))
    else
        echo -e "${RED}FAIL${NC} $2 (docker not called with: '$1')"
        FAIL=$((FAIL+1))
    fi
}

clear_log() { echo "" > "$TMP/docker.log"; }

# ============================================================
echo "=========================================="
echo "  siyuan-manager.sh 功能测试"
echo "=========================================="
echo ""

# ---- 基础功能 ----
echo -e "${YELLOW}[基础功能]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
alice:pass123
bob:bob456:6810
charlie:mypw:6812:custom/siyuan:v3
CFGEOF

run_script --help; o=$(out)
assert_contains "$o" "用法" "help 显示用法"

run_script; o=$(out)
assert_contains "$o" "用法" "无参数显示用法"

run_script xyz; o=$(out)
assert_contains "$o" "未知命令" "未知命令报错"

run_script start nobody; o=$(out)
assert_contains "$o" "不存在于配置文件中" "不存在的用户报错"

# ---- 参数校验 ----
echo ""
echo -e "${YELLOW}[参数校验]${NC}"

run_script start; o=$(out)
assert_contains "$o" "用法" "start 缺少参数"

run_script stop; o=$(out)
assert_contains "$o" "用法" "stop 缺少参数"

run_script archive; o=$(out)
assert_contains "$o" "用法" "archive 缺少参数"

run_script add; o=$(out)
assert_contains "$o" "用法" "add 缺少参数"

run_script remove; o=$(out)
assert_contains "$o" "用法" "remove 缺少参数"

run_script restore alice /nonexistent; o=$(out)
assert_contains "$o" "不存在" "restore 文件不存在"

# ---- 404 错误处理 ----
echo ""
echo -e "${YELLOW}[404/错误处理]${NC}"

run_script start nobody; o=$(out)
assert_contains "$o" "不存在于配置文件中" "start 不存在的用户"

run_script stop nobody; o=$(out)
assert_contains "$o" "不存在于配置文件中" "stop 不存在的用户"

run_script restart nobody; o=$(out)
assert_contains "$o" "不存在于配置文件中" "restart 不存在的用户"

run_script archive nobody; o=$(out)
assert_contains "$o" "不存在于配置文件中" "archive 不存在的用户"

run_script remove nobody; o=$(out)
assert_contains "$o" "不存在于配置文件中" "remove 不存在的用户"

run_script restore nobody /nonexistent; o=$(out)
assert_contains "$o" "不存在于配置文件中" "restore 不存在的用户报错"

run_script add alice; o=$(out)
assert_contains "$o" "用法" "add 缺少密码"

# ---- 容器启动参数 ----
echo ""
echo -e "${YELLOW}[容器启动参数]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
alice:pass123
bob:bob456:6810
charlie:mypw:6812:custom/siyuan:v3
CFGEOF

run_script start alice
assert_docker_called "siyuan-alice" "容器名 siyuan-alice"
assert_docker_called "6806:6806" "自动分配端口 6806"
assert_docker_called "b3log/siyuan" "默认镜像"
assert_docker_called "SIYUAN_ACCESS_AUTH_CODE=pass123" "设置授权码"
assert_docker_called "lang=zh_CN" "默认中文"
assert_docker_called "siyuan-data-alice" "volume 命名正确"
assert_docker_called "siyuan-net" "容器加入网络"

clear_log; run_script start bob
assert_docker_called "6810:6806" "自定义端口 6810"

clear_log; run_script start charlie
assert_docker_called "custom/siyuan:v3" "自定义镜像"
assert_docker_called "6812:6806" "自定义端口 6812"

# ---- list 命令 ----
echo ""
echo -e "${YELLOW}[list 命令]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
alice:pass123
bob:bob456:6810
charlie:mypw:6812:custom/siyuan:v3
CFGEOF

run_script list; o=$(out)
assert_contains "$o" "alice" "list 显示 alice"
assert_contains "$o" "bob" "list 显示 bob"
assert_contains "$o" "charlie" "list 显示 charlie"
assert_contains "$o" "6806" "list 显示端口 6806"
assert_contains "$o" "6810" "list 显示端口 6810"
assert_contains "$o" "b3log/siyuan" "list 显示默认镜像"
assert_contains "$o" "custom/siyuan:v3" "list 显示自定义镜像"

# ---- 自动代理 ----
echo ""
echo -e "${YELLOW}[自动代理]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
alice:pass1
bob:pass2
CFGEOF

# start 容器时自动启动代理
run_script start alice; o=$(out)
assert_contains "$o" "nginx 代理已就绪" "start 自动启动代理"
assert_docker_called "siyuan-proxy" "代理容器已创建"

# 验证 nginx 配置文件
assert_contains "$(cat "$TMP/../nginx/nginx.conf" 2>/dev/null || echo '')" "alice" "nginx 配置包含 alice"
assert_contains "$(cat "$TMP/../nginx/nginx.conf" 2>/dev/null || echo '')" "6806" "nginx 配置包含端口 6806"

# ---- all 通配符 ----
echo ""
echo -e "${YELLOW}[all 通配符]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
alice:pass1
bob:pass2
CFGEOF

run_script start all; o=$(out)
assert_contains "$o" "=== 用户: alice ===" "all start 处理 alice"
assert_contains "$o" "=== 用户: bob ===" "all start 处理 bob"

clear_log; run_script stop all; o=$(out)
assert_contains "$o" "=== 用户: alice ===" "all stop 处理 alice"

clear_log; run_script restart all; o=$(out)
assert_contains "$o" "=== 用户: alice ===" "all restart 处理 alice"

clear_log; run_script stop all --rm --data; o=$(out)
assert_contains "$o" "=== 用户: alice ===" "all stop --rm --data 处理 alice"

clear_log; run_script archive all; o=$(out)
assert_contains "$o" "=== 用户: alice ===" "all archive 处理 alice"

# ---- stop --rm/--data ----
echo ""
echo -e "${YELLOW}[stop --rm/--data]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
alice:pass1
CFGEOF

run_script stop alice --rm --data; o=$(out)
assert_contains "$o" "删除数据卷" "stop --rm --data 删除数据卷"

run_script stop alice --rm; o=$(out)
assert_not_contains "$o" "删除数据卷" "stop --rm 不删数据卷"

# ---- add/remove ----
echo ""
echo -e "${YELLOW}[add/remove 用户管理]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
alice:pass1
CFGEOF

run_script add bob pass2 6810; o=$(out)
assert_contains "$o" "已添加" "add 新用户成功"
assert_contains "$(grep 'bob' "$TMP/test-users.conf")" "bob:pass2:6810" "add 写入配置正确"

run_script add alice pass2; o=$(out)
assert_contains "$o" "已存在" "add 重复用户报错"

run_script list; o=$(out)
assert_contains "$o" "bob" "add 后 list 显示新用户"

clear_log; run_script remove bob --data; o=$(out)
assert_contains "$o" "已从配置文件中移除" "remove --data 移除用户并清理"
assert_docker_called "siyuan-proxy" "remove 后更新代理"

run_script remove bob; o=$(out)
assert_contains "$o" "不存在于配置文件中" "remove 不存在的用户报错"

# ---- status 命令 ----
echo ""
echo -e "${YELLOW}[status 命令]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
alice:alice123
CFGEOF

run_script status; o=$(out)
assert_contains "$o" "alice" "status 显示 alice"

# ---- 注释和空行 ----
echo ""
echo -e "${YELLOW}[配置文件解析]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
# 用户列表

alice:alice123

# 这是注释
bob:bob456

charlie:chpw
CFGEOF

run_script list; o=$(out)
assert_contains "$o" "alice" "跳过注释空行 - alice"
assert_contains "$o" "bob" "跳过注释空行 - bob"
assert_contains "$o" "charlie" "跳过注释空行 - charlie"

# ---- 端口递增 ----
echo ""
echo -e "${YELLOW}[端口自动分配]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
u1:p1
u2:p2
u3:p3
CFGEOF

run_script list; o=$(out)
assert_contains "$o" "6806" "第1个用户 6806"
assert_contains "$o" "6807" "第2个用户 6807"
assert_contains "$o" "6808" "第3个用户 6808"

# ---- display_name 显示名称 ----
echo ""
echo -e "${YELLOW}[display_name]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
alice:pass1
bob:pass2:6810::Bob笔记
CFGEOF

run_script list; o=$(out)
assert_contains "$o" "alice" "display_name 未设置时回退用户名"
assert_contains "$o" "Bob笔记" "display_name 设置时显示自定义名称"

# ---- extras 中文标签 slug ----
echo ""
echo -e "${YELLOW}[extras 中文标签]${NC}"

# 纯中文标签 slug 不应为空（否则链接变成 /e/）
setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
alice:pass1
CFGEOF

# 创建 extras.conf 含中文标签
cat > "$TEST_DIR/extras.conf" <<'EXTRAF'
监控面板:8080
文件管理:9000:/files
外部服务:https://example.com/api
EXTRAF

run_script start alice; o=$(out)

# 验证 nginx 配置中不存在空的 /e/ 路径
nginx_conf=$(cat "$TEST_DIR/nginx/nginx.conf" 2>/dev/null || echo '')
assert_not_contains "$nginx_conf" "location /e/ {" "extras 中文标签 slug 不为空"
assert_not_contains "$nginx_conf" '[0-9]:/' "extras 重定向 URL 无多余冒号"

# 清理
rm -f "$TEST_DIR/extras.conf" "$TEST_DIR/nginx/nginx.conf"

echo ""
echo "=========================================="
echo -e "  结果: ${GREEN}$PASS 通过${NC}, ${RED}$FAIL 失败${NC}"
echo "=========================================="

[ "$FAIL" -eq 0 ] || exit 1
