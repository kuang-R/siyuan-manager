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
    start|stop|rm|run|port) ;;
esac
exit 0
MOCKEOF
    sed -i '' "s|\$TMP|$TMP|g" "$TMP/bin/docker"
    chmod +x "$TMP/bin/docker"
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

run_script delete; o=$(out)
assert_contains "$o" "用法" "delete 缺少参数"

run_script archive; o=$(out)
assert_contains "$o" "用法" "archive 缺少参数"

run_script restore alice /nonexistent; o=$(out)
assert_contains "$o" "不存在" "restore 文件不存在"

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

# ---- status 命令 ----
echo ""
echo -e "${YELLOW}[status 命令]${NC}"

run_script status; o=$(out)
assert_contains "$o" "用户名" "status 显示表头"
assert_contains "$o" "alice" "status 显示 alice"

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

clear_log; run_script delete all; o=$(out)
assert_contains "$o" "=== 用户: alice ===" "all delete 处理 alice"

clear_log; run_script archive all; o=$(out)
assert_contains "$o" "=== 用户: alice ===" "all archive 处理 alice"

# ---- delete --data ----
echo ""
echo -e "${YELLOW}[delete --data]${NC}"

setup
cat > "$TMP/test-users.conf" <<'CFGEOF'
alice:pass1
CFGEOF

run_script delete alice --data; o=$(out)
assert_contains "$o" "删除数据卷" "delete --data 删除数据卷"

run_script delete alice; o=$(out)
assert_not_contains "$o" "删除数据卷" "delete 不加 --data 不删卷"

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

echo ""
echo "=========================================="
echo -e "  结果: ${GREEN}$PASS 通过${NC}, ${RED}$FAIL 失败${NC}"
echo "=========================================="

[ "$FAIL" -eq 0 ] || exit 1
