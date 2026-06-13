#!/usr/bin/env bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# 1. Check root permissions
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误: 必须以 root 权限运行此脚本。请使用: sudo bash $0${PLAIN}"
    exit 1
fi

# 2. Check OS distribution and set package manager
OS_TYPE=""
PKG_MGR=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
fi

case "$OS_TYPE" in
    ubuntu|debian)
        PKG_MGR="apt-get"
        export DEBIAN_FRONTEND=noninteractive
        ;;
    alpine)
        PKG_MGR="apk"
        ;;
    centos|rhel|rocky|almalinux|fedora|ol|amzn)
        if command -v dnf >/dev/null 2>&1; then
            PKG_MGR="dnf"
        else
            PKG_MGR="yum"
        fi
        ;;
    *)
        echo -e "${RED}错误: 不支持的操作系统 ($OS_TYPE)！目前仅支持 Ubuntu/Debian/Alpine/CentOS/RHEL/Rocky/AlmaLinux/Fedora/OracleLinux/AmazonLinux。${PLAIN}"
        exit 1
        ;;
esac

echo -e "${BLUE}==========================================================${PLAIN}"
echo -e "${BLUE}        欢迎使用 AimiliVPN 一键源码部署与管理脚本${PLAIN}"
echo -e "${BLUE}==========================================================${PLAIN}"

# 3. Configure GitHub Repository URL
# Default to the official repository (baoweise-bot/aimili-vpngate)
DEFAULT_USER="baoweise-bot"
DEFAULT_REPO="aimili-vpngate"

# Allow custom repository override via command line arguments
GITHUB_USER="${1:-${DEFAULT_USER}}"
GITHUB_REPO="${2:-${DEFAULT_REPO}}"

GITHUB_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"

echo -e "\n${YELLOW}[1/4] 正在安装系统基础依赖...${PLAIN}"
if [ "$PKG_MGR" = "apt-get" ]; then
    echo -e "  -> 正在运行 apt-get update 更新软件源清单..."
    apt-get update -q || true
    echo -e "  -> 正在运行 apt-get install 安装基础依赖包..."
    apt-get install -y openvpn curl git ca-certificates iptables iproute2 psmisc python3
elif [ "$PKG_MGR" = "apk" ]; then
    echo -e "  -> 正在运行 apk update 更新软件源清单..."
    apk update || true
    echo -e "  -> 正在运行 apk add 安装基础依赖包..."
    # bash is required for this script itself and some internal logic
    apk add openvpn curl git ca-certificates iptables iproute2 psmisc python3 bash
elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
    echo -e "  -> 正在运行 $PKG_MGR 安装基础依赖包..."
    if [ "$OS_TYPE" != "fedora" ] && [ "$OS_TYPE" != "amzn" ]; then
        echo -e "     -> 正在安装 EPEL 软件源 (以支持 openvpn)..."
        $PKG_MGR install -y epel-release || true
    fi
    # Try installing packages. Note: iproute or iproute2
    $PKG_MGR install -y openvpn curl git ca-certificates iptables iproute psmisc python3 || \
    $PKG_MGR install -y openvpn curl git ca-certificates iptables iproute2 psmisc python3
fi

# 4. Clone or pull the repository
INSTALL_DIR="/opt/aimilivpn"
# 默认部署分支（在 bate 分支设为 bate；在 main 分支设为 main）
DEFAULT_DEPLOY_BRANCH="main"

# 自动检测本地已安装版本当前所在的分支
CURRENT_BRANCH=""
if [ -d "${INSTALL_DIR}/.git" ]; then
    CURRENT_BRANCH=$(cd "${INSTALL_DIR}" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
fi
DEPLOY_BRANCH="${CURRENT_BRANCH:-$DEFAULT_DEPLOY_BRANCH}"

echo -e "\n${YELLOW}[2/4] 正在从 GitHub 部署源代码到 ${INSTALL_DIR} (目标分支: ${DEPLOY_BRANCH})...${PLAIN}"
if [ -f "${INSTALL_DIR}/.local_dev" ]; then
    echo -e "${GREEN}检测到本地开发模式 (.local_dev)，跳过 git pull/reset 保持本地修改。${PLAIN}"
else
    if [ -d "${INSTALL_DIR}" ]; then
        echo -e "  -> 目录 ${INSTALL_DIR} 已存在，正在更新并强制覆盖本地源码..."
        cd "${INSTALL_DIR}"
        git fetch --all || true
        git checkout "${DEPLOY_BRANCH}" || git checkout -b "${DEPLOY_BRANCH}" "origin/${DEPLOY_BRANCH}" || true
        echo -e "  -> 正在强制重置本地源码至 origin/${DEPLOY_BRANCH} ..."
        if git reset --hard "origin/${DEPLOY_BRANCH}"; then
            echo -e "${GREEN}  -> 源码更新成功！${PLAIN}"
        else
            if git pull origin "${DEPLOY_BRANCH}"; then
                echo -e "${GREEN}  -> 源码更新成功！${PLAIN}"
            else
                echo -e "${YELLOW}  -> 警告: git pull/reset 失败，将保留当前本地源码并继续安装。${PLAIN}"
            fi
        fi
    else
        echo -e "  -> 正在克隆 GitHub 仓库 ${GITHUB_URL} (分支: ${DEPLOY_BRANCH}) ..."
        if git clone -b "${DEPLOY_BRANCH}" "${GITHUB_URL}" "${INSTALL_DIR}"; then
            echo -e "${GREEN}  -> 克隆成功！${PLAIN}"
        else
            echo -e "  -> 尝试默认克隆..."
            if git clone "${GITHUB_URL}" "${INSTALL_DIR}"; then
                cd "${INSTALL_DIR}"
                git checkout "${DEPLOY_BRANCH}" || git checkout -b "${DEPLOY_BRANCH}" "origin/${DEPLOY_BRANCH}" || true
                echo -e "${GREEN}  -> 克隆成功！${PLAIN}"
            else
                echo -e "${RED}  -> 错误: 无法克隆仓库 ${GITHUB_URL}，请检查网络！${PLAIN}"
                exit 1
            fi
        fi
    fi
fi

# 5. Configure Service
echo -e "\n${YELLOW}[3/4] 正在配置系统服务...${PLAIN}"
if command -v systemctl >/dev/null 2>&1; then
    echo -e "  -> 检测到 systemd，正在创建服务配置 /lib/systemd/system/aimilivpn.service ..."
    cat > /lib/systemd/system/aimilivpn.service <<EOF
[Unit]
Description=AimiliVPN OpenVPN Manager with HTTP/SOCKS5 Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 vpngate_manager.py
Restart=always
RestartSec=5
EnvironmentFile=-/etc/default/aimilivpn

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable aimilivpn.service
elif command -v rc-service >/dev/null 2>&1; then
    echo -e "  -> 检测到 OpenRC，正在创建服务配置 /etc/init.d/aimilivpn ..."
    cat > /etc/init.d/aimilivpn <<EOF
#!/sbin/openrc-run

description="AimiliVPN OpenVPN Manager with HTTP/SOCKS5 Proxy"
command="/usr/bin/python3"
command_args="${INSTALL_DIR}/vpngate_manager.py"
command_background="yes"
directory="${INSTALL_DIR}"
pidfile="/run/aimilivpn.pid"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/aimilivpn
    rc-update add aimilivpn default
else
    echo -e "${YELLOW}警告: 未能检测到 systemd 或 OpenRC，请手动管理服务。${PLAIN}"
fi

# 6. Configure global command shortcut "ml"
echo -e "\n${YELLOW}[4/4] 正在创建全局命令快捷接口 'ml'...${PLAIN}"
echo -e "  -> 正在写入管理脚本 /usr/bin/ml ..."
cat > /usr/bin/ml <<'EOF'
#!/usr/bin/env python3
import sys
import os
import socket
import subprocess
import time
import tty
import termios
import shutil

INSTALL_DIR = "/opt/aimilivpn"
LOG_FILE = "/opt/aimilivpn/vpngate_data/vpngate.log"

def generate_random_password():
    import random
    import string
    chars = string.ascii_letters + string.digits
    while True:
        pwd = "".join(random.choices(chars, k=12))
        if any(c.islower() for c in pwd) and any(c.isupper() for c in pwd) and any(c.isdigit() for c in pwd):
            return pwd

def generate_random_suffix():
    import random
    import string
    return "".join(random.choices(string.ascii_letters + string.digits, k=12))

def load_ui_cfg():
    import json
    path = "/opt/aimilivpn/vpngate_data/ui_auth.json"
    cfg = {"host": "::", "port": 8787, "secret_path": "EJsW2EeBo9lY", "password": ""}
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
                for k, v in data.items():
                    cfg[k] = v
        except Exception:
            pass
    return cfg

def save_ui_cfg(cfg):
    import json
    path = "/opt/aimilivpn/vpngate_data/ui_auth.json"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        # 原子写:先写临时文件再 os.replace,避免与后端并发截断写产生半截 JSON
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        os.replace(tmp, path)
        return True
    except Exception:
        return False

def mask_password(pwd):
    # 掩码:保留前3后2,中间打码;长度不足以安全保留时全部打码(避免短密码被原样重建)
    pwd = pwd or ""
    head, tail = 3, 2
    if len(pwd) <= head + tail:
        return "*" * len(pwd)
    return pwd[:head] + "*" * (len(pwd) - head - tail) + pwd[-tail:]

def load_state():
    import json
    path = "/opt/aimilivpn/vpngate_data/state.json"
    state = {"active_openvpn_node_id": "", "last_check_message": "", "is_connecting": False}
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
                for k, v in data.items():
                    state[k] = v
        except Exception:
            pass
    return state

def get_active_node_info():
    import json
    path = "/opt/aimilivpn/vpngate_data/nodes.json"
    state = load_state()
    active_id = state.get("active_openvpn_node_id")
    if not active_id:
        return None, None
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                nodes = json.load(f)
                for n in nodes:
                    if n.get("id") == active_id:
                        ip = n.get("ip") or n.get("remote_host")
                        loc = n.get("location") or n.get("country") or "未知"
                        return ip, loc
        except Exception:
            pass
    return None, None

# ============ 节点管理子命令(nodes / refresh / current / fix / auto) ============

NODES_PATH = "/opt/aimilivpn/vpngate_data/nodes.json"
UI_AUTH_PATH = "/opt/aimilivpn/vpngate_data/ui_auth.json"

def load_nodes():
    import json
    if not os.path.exists(NODES_PATH):
        return []
    try:
        with open(NODES_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []

def _node_latency(n):
    # 延迟用于排序:无效/未检测的排到最后
    try:
        v = int(n.get("latency_ms") or 0)
    except Exception:
        v = 0
    return v if v > 0 else 999999

def sorted_nodes():
    # 活动节点优先,其次按延迟升序、评分降序;与后端 auto_switch_node 排序口径一致
    nodes = load_nodes()
    def key(n):
        try:
            score = int(n.get("score") or 0)
        except Exception:
            score = 0
        return (0 if n.get("active") else 1, _node_latency(n), -score)
    return sorted(nodes, key=key)

def _probe_label(n):
    green = "\033[1;32m"; red = "\033[1;31m"; yellow = "\033[1;33m"; reset = "\033[0m"
    st = n.get("probe_status", "not_checked")
    if n.get("active"):
        return f"{green}● 使用中{reset}"
    if st == "available":
        return f"{green}可用{reset}"
    if st == "unavailable":
        return f"{red}不可用{reset}"
    return f"{yellow}未检测{reset}"

def _iptype_text(n):
    # 出站类型纯文本(用于表格对齐),与后端 ip_type 取值对应
    t = (n.get("ip_type") or "").strip()
    return {"residential": "住宅IP", "mobile": "住宅IP(移动)", "hosting": "机房IP"}.get(t, "未知")

def routing_mode_label(mode):
    # 路由模式语义化标签(ml status / ml current 共用,保证两处文案与配色一致)
    # auto/favorites 会自动选节点显示绿色;fixed_ip/fixed_region 为人工固定显示黄色(提示不会自动切换)
    green = "\033[1;32m"; yellow = "\033[1;33m"; reset = "\033[0m"
    labels = {
        "auto": "自动选优 (可用性失效自动切换)",
        "fixed_ip": "固定节点",
        "fixed_region": "固定地区",
        "favorites": "收藏优先",
    }
    text = labels.get(mode, mode)
    color = green if mode in ("auto", "favorites") else (yellow if mode in ("fixed_ip", "fixed_region") else "")
    return f"{color}{text}{reset}" if color else text

def load_ui_auth():
    import json
    cfg = {}
    if os.path.exists(UI_AUTH_PATH):
        try:
            with open(UI_AUTH_PATH, "r", encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception:
            cfg = {}
    return cfg if isinstance(cfg, dict) else {}

def save_ui_auth(cfg):
    import json
    os.makedirs(os.path.dirname(UI_AUTH_PATH), exist_ok=True)
    tmp = UI_AUTH_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, UI_AUTH_PATH)

def list_nodes(return_only=False):
    nodes = sorted_nodes()
    if not return_only:
        yellow = "\033[1;33m"; bold = "\033[1m"; reset = "\033[0m"; dim = "\033[2m"
        if not nodes:
            print("当前无节点缓存。请先运行 'ml refresh' 拉取节点，或确认服务已正常启动。")
            return nodes
        print("=======================================================================")
        print(f"               {bold}AimiliVPN 节点列表 (共 {len(nodes)} 个){reset}")
        print("=======================================================================")
        header = f"{'序号':<4}{'国家':<10}{'入口 IP:端口':<26}{'延迟':<10}"
        header_iptype = "出站类型" + " " * max(0, 14 - get_display_width("出站类型"))
        print(f"{bold}{header}{header_iptype}{'状态'}{reset}")
        print(f"{dim}-------------------------------------------------------------------------------{reset}")
        for i, n in enumerate(nodes, 1):
            country = n.get("country") or n.get("country_short") or "未知"
            ip = n.get("ip") or n.get("remote_host") or "-"
            port = n.get("remote_port") or ""
            endpoint = f"{ip}:{port}" if port else ip
            lat = _node_latency(n)
            lat_str = f"{lat} ms" if lat < 999999 else "-"
            # 用 get_display_width 对齐含中文的国家列与出站类型列
            country_pad = country + " " * max(0, 10 - get_display_width(country))
            iptype = _iptype_text(n)
            iptype_pad = iptype + " " * max(0, 14 - get_display_width(iptype))
            print(f"{i:<4}{country_pad}{endpoint:<26}{lat_str:<10}{iptype_pad}{_probe_label(n)}")
        print("=======================================================================")
        print(f"{dim}提示: 'ml fix <序号>' 固定节点; 'ml auto' 恢复自动切换; 'ml refresh' 重新拉取{reset}")
    return nodes

def refresh_nodes():
    # 通过重启服务触发后端维护线程立即重新拉取并检测节点
    print("正在触发节点重新拉取(将重启服务以让后端立即执行拉取与检测)...", flush=True)
    restart_service()
    print("已触发。后端正在后台异步拉取最新节点并逐一检测可用性，")
    print("通常需要数十秒至一两分钟。可稍后运行 'ml nodes' 查看最新列表，或 'ml current' 查看连接状态。")

def show_current():
    yellow = "\033[1;33m"; green = "\033[1;32m"; red = "\033[1;31m"; bold = "\033[1m"; reset = "\033[0m"; cyan = "\033[1;36m"
    state = load_state()
    cfg = load_ui_auth()
    routing_mode = cfg.get("routing_mode", "auto")
    connection_enabled = cfg.get("connection_enabled", True)
    active_ip, active_loc = get_active_node_info()
    active_id = state.get("active_openvpn_node_id") or ""
    is_connecting = state.get("is_connecting", False)

    print(f"{cyan}======================================================={reset}")
    print(f"               {cyan}当前节点状态{reset}")
    print(f"{cyan}======================================================={reset}")
    print(format_line("连接总开关", f"{green}[✓ 已启用]{reset}" if connection_enabled else f"{red}[✗ 已禁用]{reset}", label_color=cyan))
    print(format_line("路由模式", routing_mode_label(routing_mode), label_color=cyan))
    if routing_mode == "fixed_ip":
        print(format_line("固定节点 ID", cfg.get("fixed_node_id") or "(未指定)", label_color=cyan))
    ip_type = cfg.get("routing_ip_type", "all")
    iptype_color = green if ip_type == "residential" else (yellow if ip_type == "hosting" else "")
    iptype_disp = IP_TYPE_LABELS.get(ip_type, ip_type)
    iptype_val = f"{iptype_color}{iptype_disp}{reset}" if iptype_color else iptype_disp
    print(format_line("IP出站类型过滤", iptype_val, label_color=cyan))
    print(f"{cyan}-------------------------------------------------------{reset}")
    if is_connecting:
        phase = state.get("connecting_phase", "")
        if phase == "fetching":
            print(format_line("任务状态", f"{yellow}[拉取节点] 正在获取最新节点列表{reset}", label_color=cyan))
            print(format_line("任务进度", state.get("last_check_message") or "正在从 VPNGate 拉取节点...", label_color=cyan))
        elif phase == "scanning":
            done = state.get("scan_done", 0); total = state.get("scan_total", 0); avail = state.get("scan_available", 0)
            print(format_line("任务状态", f"{yellow}[检测节点池] 正在逐个测试候选节点连通性{reset}", label_color=cyan))
            bar, pct = _progress_bar(done, total)
            prog_val = f"{yellow}{bar}{reset} {pct}% ({done}/{total})" if bar else f"{done}/{total}"
            print(format_line("检测进度", prog_val, label_color=cyan))
            print(format_line("已发现可用", f"{green}{avail}{reset} 个", label_color=cyan))
        else:
            short = state.get("active_node_latency") or "连接中"
            msg = state.get("last_check_message") or "正在建立连接..."
            print(format_line("任务状态", f"{yellow}[建立连接] {short}{reset}", label_color=cyan))
            print(format_line("任务进度", f"{yellow}{msg}{reset}", label_color=cyan))
    elif active_ip:
        print(format_line("活动节点 ID", active_id, label_color=cyan))
        print(format_line("入口 IP", f"{bold}{active_ip}{reset}", label_color=cyan))
        print(format_line("节点地区", active_loc or "未知", label_color=cyan))
        latency = state.get("active_node_latency", "-")
        print(format_line("节点延迟", _latency_color(str(latency), green, yellow, red, reset), label_color=cyan))
        proxy_ok = state.get("proxy_ok", False)
        proxy_ip = state.get("proxy_ip", "-")
        if proxy_ok and proxy_ip and proxy_ip != "-":
            print(format_line("出口 IP (出站)", f"{bold}{proxy_ip}{reset}", label_color=cyan))
            pl = state.get("proxy_latency_ms", 0)
            print(format_line("本地代理延迟", _latency_color(f"{pl} ms" if pl else "检测中...", green, yellow, red, reset), label_color=cyan))
        else:
            perr = state.get("proxy_error") or "检测中/未就绪"
            print(format_line("出口 IP (出站)", f"{red}[✗ 不可用 - {perr}]{reset}", label_color=cyan))
    else:
        print(format_line("节点状态", "无活动连接", label_color=cyan))
        if routing_mode == "fixed_ip":
            fixed_id = cfg.get("fixed_node_id") or ""
            fnode = next((n for n in load_nodes() if n.get("id") == fixed_id), None) if fixed_id else None
            if fixed_id and fnode is None:
                print(format_line("固定节点诊断", f"{red}该节点已不在节点列表(可能被服务商下线){reset}", label_color=cyan))
                print(f"{yellow}  固定模式不会自动切换;可运行 'ml switch'/'ml auto' 切换,或 'ml fix <其它序号>' 重新固定。{reset}")
            elif fnode is not None and fnode.get("probe_status") == "unavailable":
                print(format_line("固定节点诊断", f"{red}该节点当前检测为不可用{reset}", label_color=cyan))
                print(f"{yellow}  固定模式不会自动切换;可运行 'ml switch'/'ml auto' 切换,或 'ml fix <其它序号>' 重新固定。{reset}")
    print(f"{cyan}======================================================={reset}")

def _resolve_node(selector):
    # selector 可为列表序号(1-based,基于 sorted_nodes)或节点 ID,返回匹配节点或 None
    nodes = sorted_nodes()
    sel = str(selector).strip()
    if sel.isdigit():
        idx = int(sel)
        if 1 <= idx <= len(nodes):
            return nodes[idx - 1]
        return None
    for n in nodes:
        if n.get("id") == sel:
            return n
    return None

def fix_node(selector=None):
    nodes = sorted_nodes()
    if not nodes:
        print("当前无节点缓存，无法固定。请先运行 'ml refresh' 拉取节点。")
        return
    if selector is None:
        list_nodes()
        try:
            selector = input("\n请输入要固定的节点【序号】或【节点 ID】(直接回车取消): ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n已取消。")
            return
        if not selector:
            print("已取消。")
            return
    node = _resolve_node(selector)
    if not node:
        print(f"未找到匹配的节点: {selector}。请用 'ml nodes' 查看有效序号/ID。")
        return
    cfg = load_ui_auth()
    was_disabled = not cfg.get("connection_enabled", True)
    cfg["routing_mode"] = "fixed_ip"
    cfg["fixed_node_id"] = node["id"]
    cfg["connection_enabled"] = True
    try:
        save_ui_auth(cfg)
    except Exception as e:
        print(f"写入配置失败: {e}")
        return
    country = node.get("country") or node.get("country_short") or "未知"
    ip = node.get("ip") or node.get("remote_host") or "-"
    print(f"已设置为固定节点模式 -> {country} ({ip}) [ID: {node['id']}]")
    if was_disabled:
        print("注意: 连接总开关原为【已禁用】,本次操作已重新启用连接。")
    restart_service()
    print("配置已生效，服务正在重启并连接该固定节点。可运行 'ml current' 查看状态。")

def auto_mode():
    cfg = load_ui_auth()
    prev = cfg.get("routing_mode", "auto")
    was_disabled = not cfg.get("connection_enabled", True)
    cfg["routing_mode"] = "auto"
    cfg["connection_enabled"] = True
    cfg.pop("fixed_node_id", None)  # 切到 auto:清除残留固定节点,避免后续切回 fixed_ip 复用陈旧 pin
    try:
        save_ui_auth(cfg)
    except Exception as e:
        print(f"写入配置失败: {e}")
        return
    print(f"已切换到自动选优模式(原模式: {prev})。")
    print("后端将自动选择延迟最低的可用节点，当前节点不可用时会自动切换到最佳备用节点。")
    if was_disabled:
        print("注意: 连接总开关原为【已禁用】,本次操作已重新启用连接。")
    restart_service()
    print("配置已生效，服务正在重启。可运行 'ml current' 查看状态。")

def best_node(ip_type="all"):
    # 最佳节点:可用节点按延迟升序、评分降序;按 routing_ip_type 过滤以对齐后端 auto_switch_node 候选口径
    avail = [n for n in load_nodes() if n.get("probe_status") == "available"]
    if ip_type == "residential":
        avail = [n for n in avail if n.get("ip_type") in ("residential", "mobile")]
    elif ip_type == "hosting":
        avail = [n for n in avail if n.get("ip_type") == "hosting"]
    if not avail:
        return None
    def key(n):
        try:
            score = int(n.get("score") or 0)
        except Exception:
            score = 0
        return (_node_latency(n), -score)
    return sorted(avail, key=key)[0]

def switch_node():
    yellow = "\033[1;33m"; green = "\033[1;32m"; reset = "\033[0m"
    cfg = load_ui_auth()
    ip_type = cfg.get("routing_ip_type", "all")
    best = best_node(ip_type)
    if not best:
        print("当前没有【已检测为可用】的节点,无法切换。")
        print("请先运行 'ml refresh' 重新拉取并检测节点,稍候再试。")
        return
    country = best.get("country") or best.get("country_short") or "未知"
    ip = best.get("ip") or best.get("remote_host") or "-"
    lat = _node_latency(best)
    lat_str = f"{lat} ms" if lat < 999999 else "未知"
    print(f"当前最佳可用节点: {green}{country} ({ip}){reset}  延迟 {lat_str}  [ID: {best['id']}]")

    state = load_state()
    active_id = state.get("active_openvpn_node_id") or ""
    if (active_id == best["id"] and not state.get("is_connecting", False)
            and cfg.get("routing_mode") == "auto"):
        print(f"{yellow}当前已连接到该最佳节点(自动模式),无需切换。{reset}")
        return

    was_disabled = not cfg.get("connection_enabled", True)
    cfg["routing_mode"] = "auto"
    cfg["connection_enabled"] = True
    cfg.pop("fixed_node_id", None)  # 切到 auto:清除上次 ml fix 残留的固定节点,避免后续切回 fixed_ip 复用陈旧 pin
    try:
        save_ui_auth(cfg)
    except Exception as e:
        print(f"写入配置失败: {e}")
        return
    if was_disabled:
        print(f"{yellow}注意: 连接总开关原为【已禁用】,本次操作已重新启用连接。{reset}")
    print("正在切换到最佳可用节点...")
    restart_service()
    print("配置已生效,服务正在重启并连接最佳可用节点。可运行 'ml current' 查看状态。")
    print(f"{yellow}提示: 已启用自动模式,当前节点失效时会自动切换到下一个可用节点;如需锁定单一节点请用 'ml fix'。{reset}")

# IP 出站类型过滤(与 Web UI / 后端 routing_ip_type 口径一致)
IP_TYPE_ORDER = ["all", "residential", "hosting"]
IP_TYPE_LABELS = {
    "all": "所有IP (机房 + 住宅)",
    "residential": "住宅IP (静态家宽)",
    "hosting": "机房IP (普通机房)",
}

def set_iptype(value=None):
    yellow = "\033[1;33m"; green = "\033[1;32m"; reset = "\033[0m"
    cfg = load_ui_auth()
    current = cfg.get("routing_ip_type", "all")
    if value is None:
        print("=======================================================")
        print("               IP 出站类型过滤")
        print("=======================================================")
        print(f"当前: {green}{IP_TYPE_LABELS.get(current, current)}{reset}")
        for i, k in enumerate(IP_TYPE_ORDER, 1):
            mark = " (当前)" if k == current else ""
            print(f"  [{i}] {IP_TYPE_LABELS[k]}{mark}")
        print("=======================================================")
        try:
            value = input("请输入要切换到的【序号 1-3】或类型名(直接回车取消): ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n已取消。")
            return
        if not value:
            print("已取消。")
            return
    value = str(value).strip().lower()
    if value in ("1", "2", "3"):
        value = IP_TYPE_ORDER[int(value) - 1]
    if value not in IP_TYPE_LABELS:
        print(f"无效的类型: {value}。可选: all / residential / hosting (或序号 1/2/3)。")
        return
    if value == current:
        print(f"当前已是【{IP_TYPE_LABELS[value]}】,无需切换。")
        return
    cfg["routing_ip_type"] = value
    try:
        save_ui_auth(cfg)
    except Exception as e:
        print(f"写入配置失败: {e}")
        return
    print(f"IP 出站类型过滤已切换为: {IP_TYPE_LABELS[value]}")
    print(f"{yellow}说明: 该过滤在自动选节点时生效;固定节点(ml fix)不受影响。{reset}")
    restart_service()
    print("配置已生效,服务正在重启并按新过滤重新选择节点。可运行 'ml current' 查看状态。")

def ping_ip(ip):
    if not ip:
        return None
    try:
        # Run standard linux ping command with 1 packet and 2 seconds timeout
        res = subprocess.run(["ping", "-c", "1", "-W", "2", ip], capture_output=True, text=True, timeout=3)
        if res.returncode == 0:
            out = res.stdout
            lines = out.splitlines()
            for line in lines:
                if "rtt" in line or "min/avg" in line:
                    parts = line.split("=")[1].strip().split("/")
                    if len(parts) >= 2:
                        avg_rtt = float(parts[1])
                        return f"{int(avg_rtt)} ms"
            return "已响应"
        else:
            return "检测超时"
    except Exception:
        return "无法连接"

def get_public_ip():
    path = "/opt/aimilivpn/vpngate_data/public_ip.txt"
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                ip = f.read().strip()
                if ip:
                    return ip
        except Exception:
            pass
    import urllib.request
    # Try dual-stack first, then IPv6-only, then IPv4-only
    for api_url in ["https://api64.ipify.org", "https://api6.ipify.org", "https://api.ipify.org"]:
        try:
            req = urllib.request.Request(api_url, headers={"User-Agent": "curl/7.68.0"})
            with urllib.request.urlopen(req, timeout=2) as r:
                ip = r.read().decode().strip()
                if ip:
                    try:
                        os.makedirs(os.path.dirname(path), exist_ok=True)
                        with open(path, "w", encoding="utf-8") as f:
                            f.write(ip)
                    except Exception:
                        pass
                    return ip
        except Exception:
            pass
    return "您的服务器公网IP"

def _local_proxy_curl_target(proxy_port):
    # 与后端 check_proxy_health 一致:解析本地代理可连接地址
    host = os.environ.get("LOCAL_PROXY_HOST", "127.0.0.1")
    if host in ("::", "0.0.0.0", ""):
        return "127.0.0.1"
    if ":" in host:
        return f"[{host}]"
    return host

def query_exit_info(proxy_port, timeout=8):
    # 经本地 SOCKS5 代理访问 ippure,查询出口 IP 的真实归属信息
    import json, subprocess
    host = _local_proxy_curl_target(proxy_port)
    proxy_url = f"socks5h://{host}:{proxy_port}"
    cmd = ["curl", "-s", "-x", proxy_url, "https://my.ippure.com/v1/info", "--max-time", str(timeout)]
    # 本地代理若启用了认证,附带凭据(默认无)
    user = os.environ.get("LOCAL_PROXY_USER") or os.environ.get("LOCAL_PROXY_USERNAME")
    pwd = os.environ.get("LOCAL_PROXY_PASS") or os.environ.get("LOCAL_PROXY_PASSWORD")
    if user is not None and pwd is not None:
        cmd.extend(["--proxy-user", f"{user}:{pwd}"])
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 2)
        if res.returncode != 0 or not res.stdout.strip():
            return None
        data = json.loads(res.stdout.strip())
        return data if isinstance(data, dict) else None
    except Exception:
        return None

def _fraud_label(score):
    try:
        s = int(score)
    except Exception:
        return ""
    if s <= 30:
        return f"{s} [良好]"
    if s <= 60:
        return f"{s} [一般]"
    return f"{s} [较高风险]"

def check_port_listening(port):
    for host, family in [("127.0.0.1", socket.AF_INET), ("::1", socket.AF_INET6)]:
        try:
            s = socket.socket(family, socket.SOCK_STREAM)
            s.settimeout(0.2)
            s.connect((host, port))
            s.close()
            return True
        except Exception:
            pass
    return False

def get_service_pid(service_name="aimilivpn.service"):
    try:
        for pid_dir in os.listdir('/proc'):
            if pid_dir.isdigit():
                try:
                    with open(os.path.join('/proc', pid_dir, 'cmdline'), 'r') as f:
                        cmd = f.read()
                        if 'vpngate_manager.py' in cmd:
                            return pid_dir
                except Exception:
                    continue
    except Exception:
        pass
    return None

def check_service_active(service_name="aimilivpn.service"):
    return get_service_pid(service_name) is not None

def check_openvpn_process():
    try:
        for pid_dir in os.listdir('/proc'):
            if pid_dir.isdigit():
                try:
                    with open(os.path.join('/proc', pid_dir, 'cmdline'), 'r') as f:
                        cmd = f.read().replace('\x00', ' ')
                        if 'openvpn' in cmd and ('/opt/aimilivpn/vpngate_data' in cmd or '/opt/aimilivpn/vpngate_data/configs' in cmd):
                            return True
                except Exception:
                    continue
    except Exception:
        pass
    return False

def get_display_width(s):
    import re
    ansi_escape = re.compile(r'\x1b\[[0-9;]*[mGKH]')
    s_clean = ansi_escape.sub('', s)
    width = 0
    for char in s_clean:
        if ord(char) > 127:
            width += 2
        else:
            width += 1
    return width

def format_line(label, value, target_width=26, label_color=""):
    prefix = "  ● "
    w = get_display_width(label)
    padding = " " * max(0, target_width - w)
    if label_color:
        return f"{prefix}{label_color}{label}\033[0m{padding}:  {value}"
    return f"{prefix}{label}{padding}:  {value}"

def print_line(text=""):
    print(f"{text}\033[K")

def _latency_color(val, green, yellow, red, reset):
    import re
    m = re.match(r'^\s*(\d+)', str(val))
    if not m:
        return val
    n = int(m.group(1))
    c = green if n <= 150 else (yellow if n <= 400 else red)
    return f"{c}{val}{reset}"

def _progress_bar(done, total, width=20):
    # 返回 (进度条字符串, 百分比);total<=0 时返回 ("", 0)
    try:
        done = int(done); total = int(total)
    except (TypeError, ValueError):
        return "", 0
    if total <= 0:
        return "", 0
    pct = max(0, min(100, int(done * 100 / total)))
    filled = int(width * pct / 100)
    return "█" * filled + "░" * (width - filled), pct

def print_status(with_exit_info=False):
    cfg = load_ui_cfg()
    ui_port = cfg.get("port", 8787)
    secret_path = cfg.get("secret_path", "EJsW2EeBo9lY")
    proxy_port = cfg.get("proxy_port", 7928)
    state = load_state()
    is_connecting = state.get("is_connecting", False)
    ui_auth = load_ui_auth()
    routing_ip_type = ui_auth.get("routing_ip_type", "all")
    routing_mode = ui_auth.get("routing_mode", "auto")
    
    gateway_ok = check_port_listening(proxy_port)
    service_ok = check_service_active("aimilivpn.service")
    openvpn_ok = check_openvpn_process()
    pid = get_service_pid("aimilivpn.service")
    
    active_ip, active_loc = get_active_node_info()
    latency = state.get("active_node_latency", "测试中...") if active_ip else "无活动连接"
    
    green = "\033[1;32m"
    red = "\033[1;31m"
    reset = "\033[0m"
    bold = "\033[1m"
    yellow = "\033[1;33m"
    cyan = "\033[1;36m"
    sep = f"{cyan}======================================================={reset}"

    backend_status = f"{green}[✓ 已激活] (PID: {pid}){reset}" if (service_ok and pid) else f"{red}[✗ 未启动]{reset}"

    if is_connecting:
        gateway_status = f"{yellow}[! 切换中...]{reset}"
        openvpn_status = f"{yellow}[! {state.get('active_node_latency') or '连接中'}...]{reset}"
    else:
        gateway_status = f"{green}[✓ 已激活]{reset}" if gateway_ok else f"{red}[✗ 未启动]{reset}"
        openvpn_status = f"{green}[✓ 已连接]{reset}" if openvpn_ok else f"{red}[✗ 未连接]{reset}"

    print_line(sep)
    print_line(f"               {cyan}AimiliVPN 管理终端 v2.0{reset}                  ")
    print_line(sep)
    print_line(f"{cyan}【核心服务状态】{reset}")
    print_line(format_line(f"代理网关 (Port {proxy_port})", gateway_status, label_color=cyan))
    print_line(format_line(f"管理后台 (Port {ui_port})", backend_status, label_color=cyan))
    print_line(format_line("连接核心 (OpenVPN)", openvpn_status, label_color=cyan))
    
    host_cfg = cfg.get("host", "::")
    if host_cfg in ("127.0.0.1", "localhost"):
        login_ip = "127.0.0.1"
    elif host_cfg == "::1":
        login_ip = "[::1]"
    elif host_cfg == "::":
        login_ip = get_public_ip()
    else:
        login_ip = f"[{host_cfg}]" if ":" in host_cfg else host_cfg
    print_line(format_line("网页登录地址", f"{yellow}http://{login_ip}:{ui_port}/{secret_path}/{reset}", label_color=cyan))
    print_line(format_line("网页管理账号", f"{bold}{cfg.get('username', '未配置')}{reset}", label_color=cyan))
    curr_pwd = cfg.get("password", "")
    masked_pwd = mask_password(curr_pwd)
    print_line(format_line("网页管理密码", masked_pwd, label_color=cyan))
    print_line()
    print_line(f"{cyan}【活动节点状态】{reset}")
    print_line(format_line("路由模式", routing_mode_label(routing_mode), label_color=cyan))
    if is_connecting:
        phase = state.get("connecting_phase", "")
        if phase == "fetching":
            print_line(format_line("任务状态", f"{yellow}[拉取节点] 正在获取最新节点列表{reset}", label_color=cyan))
            print_line(format_line("任务进度", state.get('last_check_message') or "正在从 VPNGate 拉取节点...", label_color=cyan))
        elif phase == "scanning":
            done = state.get("scan_done", 0); total = state.get("scan_total", 0); avail = state.get("scan_available", 0)
            print_line(format_line("任务状态", f"{yellow}[检测节点池] 正在逐个测试候选节点连通性{reset}", label_color=cyan))
            bar, pct = _progress_bar(done, total)
            prog_val = f"{yellow}{bar}{reset} {pct}% ({done}/{total})" if bar else f"{done}/{total}"
            print_line(format_line("检测进度", prog_val, label_color=cyan))
            print_line(format_line("已发现可用", f"{green}{avail}{reset} 个", label_color=cyan))
        else:
            short = state.get("active_node_latency") or "连接中"
            detail = state.get('last_check_message') or '正在建立加密隧道并验证路由规则...'
            print_line(format_line("任务状态", f"{yellow}[建立连接] {short}{reset}", label_color=cyan))
            print_line(format_line("任务进度", f"{yellow}{detail}{reset}", label_color=cyan))
    elif active_ip:
        proxy_ip = state.get("proxy_ip", "-")
        proxy_latency = state.get("proxy_latency_ms", 0)
        proxy_ok = state.get("proxy_ok", False)

        ip_type_disp = {"all": "所有IP (all)", "residential": "住宅IP (residential)", "hosting": "机房IP (hosting)"}.get(routing_ip_type, routing_ip_type)
        outtype_color = green if routing_ip_type == "residential" else (yellow if routing_ip_type == "hosting" else "")
        ip_type_val = f"{outtype_color}{ip_type_disp}{reset}" if outtype_color else ip_type_disp
        print_line(format_line("IP 出站类型", ip_type_val, label_color=cyan))
        print_line(format_line("节点 IP (入口)", f"{bold}{active_ip}{reset}", label_color=cyan))
        print_line(format_line("节点地区", active_loc, label_color=cyan))
        print_line(format_line("节点延迟 (直连测试)", _latency_color(latency, green, yellow, red, reset), label_color=cyan))
        if proxy_ok and proxy_ip and proxy_ip != "-":
            print_line(format_line("出口 IP (出站)", f"{bold}{proxy_ip}{reset}", label_color=cyan))
            # 出口归属详情:仅 ml status 页面经本地代理实时查询 ippure
            if with_exit_info:
                info = query_exit_info(proxy_port)
                if info:
                    asn = info.get("asn")
                    org = info.get("asOrganization") or ""
                    asn_str = f"AS{asn} {org}".strip() if asn else (org or "-")
                    print_line(format_line("出口归属 (ASN)", asn_str, label_color=cyan))
                    print_line(format_line("出口国家", info.get("country") or "-", label_color=cyan))
                    is_res = info.get("isResidential")
                    ip_kind = "住宅IP" if is_res else "机房IP"
                    kind_color = green if is_res else yellow
                    broadcast = "是" if info.get("isBroadcast") else "否"
                    print_line(format_line("IP 类型", f"{kind_color}{ip_kind}{reset} · 广播: {broadcast}", label_color=cyan))
                    fraud = _fraud_label(info.get("fraudScore"))
                    if fraud:
                        if "[良好]" in fraud:
                            fc, fs = green, "✓"
                        elif "[一般]" in fraud:
                            fc, fs = yellow, "!"
                        else:
                            fc, fs = red, "✗"
                        print_line(format_line("欺诈评分", f"{fc}{fs} {fraud}{reset}", label_color=cyan))
                else:
                    print_line(format_line("出口归属 (ASN)", f"{yellow}[! 查询失败/超时]{reset}", label_color=cyan))
            print_line(format_line("本地代理延迟", _latency_color(f"{proxy_latency} ms" if proxy_latency else "检测中...", green, yellow, red, reset), label_color=cyan))
        else:
            proxy_err = state.get("proxy_error") or "检测中/未就绪"
            print_line(format_line("出口 IP (出站)", f"{red}[✗ 不可用 - {proxy_err}]{reset}", label_color=cyan))
    else:
        print_line(format_line("节点状态", "无活动连接", label_color=cyan))
    print_line()
    local_proxy = state.get("local_proxy", f"http://127.0.0.1:{proxy_port}")
    import urllib.parse
    try:
        parsed = urllib.parse.urlsplit(local_proxy)
        proxy_host = parsed.hostname or "127.0.0.1"
        proxy_port = parsed.port or proxy_port
    except Exception:
        proxy_host = "127.0.0.1"
        proxy_port = proxy_port
    
    if proxy_host == "::":
        proxy_addr = "127.0.0.1"
    elif ":" in proxy_host:
        proxy_addr = f"[{proxy_host}]"
    else:
        proxy_addr = proxy_host

    print_line(f"{cyan}【使用方法】{reset}")
    print_line(f"  {bold}export http_proxy=http://{proxy_addr}:{proxy_port}{reset}")
    print_line(f"  {bold}export https_proxy=http://{proxy_addr}:{proxy_port}{reset}")
    print_line(f"  # 也可用于 SOCKS5: socks5://{proxy_addr}:{proxy_port}")
    print_line(sep)

def run_service_cmd(cmd):
    if shutil.which("systemctl"):
        subprocess.run(["systemctl", cmd, "aimilivpn.service"])
    elif shutil.which("rc-service"):
        subprocess.run(["rc-service", "aimilivpn", cmd])
    else:
        print("未检测到支持的服务管理器 (systemd/OpenRC)")

def start_service():
    print("正在启动 AimiliVPN 服务...", flush=True)
    run_service_cmd("start")
    print("已发送启动指令。")
    time.sleep(1)

def stop_service():
    print("正在停止 AimiliVPN 服务...", flush=True)
    run_service_cmd("stop")
    print("已发送停止指令。")
    time.sleep(1)

def restart_service():
    print("正在重启 AimiliVPN 服务...", flush=True)
    run_service_cmd("restart")
    print("已发送重启指令。")
    time.sleep(1)

def show_logs():
    print("正在查看 AimiliVPN 日志 (按 Ctrl+C 退出)...", flush=True)
    if os.path.exists(LOG_FILE):
        try:
            subprocess.run(["tail", "-f", "-n", "50", LOG_FILE])
        except KeyboardInterrupt:
            pass
    else:
        print(f"日志文件不存在: {LOG_FILE}")
        time.sleep(2)

def update_service():
    print("正在获取远程更新并检测版本...", flush=True)
    if os.path.exists(INSTALL_DIR):
        try:
            os.chdir(INSTALL_DIR)
            if not os.path.exists(".git"):
                print("错误: 当前安装目录不是 Git 仓库，无法通过 Git 更新。")
                time.sleep(3)
                return
            
            # Fetch remote origin updates
            subprocess.run(["git", "fetch", "--all"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            # Detect remote branch (prefer current local branch, fallback to origin/main or origin/master)
            curr = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True)
            branch = curr.stdout.strip() if curr.returncode == 0 else ""
            if not branch or branch == "HEAD":
                branch = "main"
                for b in ["main", "master"]:
                    chk = subprocess.run(["git", "rev-parse", "--verify", f"origin/{b}"], capture_output=True, text=True)
                    if chk.returncode == 0:
                        branch = b
                        break
            
            local_commit = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
            remote_commit = subprocess.run(["git", "rev-parse", f"origin/{branch}"], capture_output=True, text=True).stdout.strip()
            
            if local_commit == remote_commit:
                print("\n【版本状态】当前已是最新版本，无需更新！")
                override = input("是否强制重新拉取代码并覆盖安装？(y/N): ").strip().lower()
                if override != 'y':
                    print("已取消更新。")
                    time.sleep(1.5)
                    return
            else:
                print(f"\n【检测到更新】本地版本: {local_commit[:8]}，远程最新版本: {remote_commit[:8]}")
                confirm = input("是否确认开始更新并重启服务？(Y/n): ").strip().lower()
                if confirm not in ('', 'y', 'yes'):
                    print("已取消更新。")
                    time.sleep(1.5)
                    return
            
            print(f"\n正在强制重置本地代码至 origin/{branch} ...", flush=True)
            subprocess.run(["git", "reset", "--hard", f"origin/{branch}"], check=True)
            
            # Clean up python cache files
            print("正在清理 Python 缓存 (pycache)...", flush=True)
            subprocess.run(["find", ".", "-type", "d", "-name", "__pycache__", "-exec", "rm", "-rf", "{}", "+"], check=False)
            
            print("代码拉取成功，正在重新运行安装脚本...", flush=True)
            subprocess.run(["bash", "install.sh"])
            print("更新已完成！")
            time.sleep(2)
        except Exception as e:
            print(f"更新失败: {e}")
            time.sleep(4)
    else:
        print(f"未找到安装目录: {INSTALL_DIR}")
        time.sleep(2)

def uninstall_service():
    confirm = input("确定要完全卸载 AimiliVPN 吗？(y/N): ")
    if confirm.lower() == 'y':
        print("正在完全卸载 AimiliVPN...", flush=True)
        stop_service()
        if shutil.which("systemctl"):
            subprocess.run(["systemctl", "disable", "aimilivpn.service"])
            try:
                os.unlink("/lib/systemd/system/aimilivpn.service")
            except Exception:
                pass
        elif shutil.which("rc-service"):
            subprocess.run(["rc-update", "del", "aimilivpn"])
            try:
                os.unlink("/etc/init.d/aimilivpn")
            except Exception:
                pass
        try:
            os.unlink("/usr/bin/ml")
        except Exception:
            pass
        subprocess.run(["rm", "-rf", INSTALL_DIR])
        print("AimiliVPN 已卸载！")
        sys.exit(0)
    else:
        print("已取消卸载。")
        time.sleep(1)

def ask_restart():
    ans = input("配置已保存。是否立即重启服务生效？(Y/n): ").strip().lower()
    if ans in ('', 'y', 'yes'):
        print("正在重启 AimiliVPN 服务...", flush=True)
        restart_service()
        print("服务已重启。")
        time.sleep(1.5)

def configure_web():
    cfg = load_ui_cfg()
    while True:
        print("\033[H\033[J", end="")
        print("=======================================================")
        print("               网页绑定与地址后缀配置                  ")
        print("=======================================================")
        print(f"  [1] 切换绑定地址 (当前: {cfg.get('host', '0.0.0.0')})")
        print(f"  [2] 随机重置安全后缀 (当前: {cfg.get('secret_path', '')})")
        print("  [3] 返回主菜单")
        print("=======================================================")
        print("请直接输入数字键 [1-3] 快速执行：", end="", flush=True)
        
        key = getch()
        if key == '1':
            print("\033[H\033[J", end="")
            print("选择网页登录绑定地址：")
            print("  1. 仅允许本地 IPv4 登录 (127.0.0.1 - 更安全)")
            print("  2. 允许 IPv4 公网登录 (0.0.0.0)")
            print("  3. 允许 IPv4 & IPv6 双栈公网登录 (:: - 推荐)")
            print("  4. 仅允许本地 IPv6 登录 (::1)")
            sel = input("请选择 (1/2/3/4, 默认3): ").strip()
            if sel == '1':
                cfg['host'] = "127.0.0.1"
            elif sel == '2':
                cfg['host'] = "0.0.0.0"
            elif sel == '4':
                cfg['host'] = "::1"
            else:
                cfg['host'] = "::"
            save_ui_cfg(cfg)
            print(f"绑定地址已更新为: {cfg['host']}")
            ask_restart()
            break
        elif key == '2':
            print("\033[H\033[J", end="")
            new_path = generate_random_suffix()
            cfg['secret_path'] = new_path
            save_ui_cfg(cfg)
            print("安全登录后缀已随机重置成功！")
            print(f"您的全新安全登录后缀为: {new_path}")
            display_host = cfg['host']
            if ":" in display_host:
                display_host = f"[{display_host}]"
            print(f"新的访问路径为: http://{display_host}:{cfg['port']}/{new_path}/")
            ask_restart()
            break
        elif key == '3' or key == 'q' or key == '\x03':
            break

def configure_port():
    cfg = load_ui_cfg()
    while True:
        print("\033[H\033[J", end="")
        print("=======================================================")
        print("                      端口配置菜单                     ")
        print("=======================================================")
        print(f"1) 网页管理端口: {cfg.get('port', 8787)}")
        print(f"2) 代理出站端口: {cfg.get('proxy_port', 7928)}")
        print("3) 返回主菜单")
        print("-------------------------------------------------------")
        key = input("请选择操作 (1-3): ").strip()
        if key == '1':
            try:
                val = input("请输入新的网页管理端口 (1-65535, 按回车取消): ").strip()
                if val:
                    port = int(val)
                    if 1 <= port <= 65535:
                        if port == int(cfg.get('proxy_port', 7928)):
                            print("错误: 网页管理端口不能与代理出站端口相同。")
                            time.sleep(2)
                            continue
                        cfg['port'] = port
                        save_ui_cfg(cfg)
                        print(f"网页管理端口已更新为: {port}")
                        ask_restart()
                    else:
                        print("错误: 端口范围必须在 1 至 65535 之间。")
                        time.sleep(2)
            except ValueError:
                print("错误: 输入必须是数字。")
                time.sleep(2)
        elif key == '2':
            try:
                val = input("请输入新的代理出站端口 (1024-65535, 按回车取消): ").strip()
                if val:
                    port = int(val)
                    if 1024 <= port <= 65535:
                        if port == int(cfg.get('port', 8787)):
                            print("错误: 代理出站端口不能与网页管理端口相同。")
                            time.sleep(2)
                            continue
                        cfg['proxy_port'] = port
                        save_ui_cfg(cfg)
                        print(f"代理出站端口已更新为: {port}")
                        ask_restart()
                    else:
                        print("错误: 端口范围必须在 1024 至 65535 之间。")
                        time.sleep(2)
            except ValueError:
                print("错误: 输入必须是数字。")
                time.sleep(2)
        elif key == '3' or key == 'q' or key == '\x03':
            break

def configure_credentials():
    cfg = load_ui_cfg()
    while True:
        print("\033[H\033[J", end="")
        print("=======================================================")
        print("                    管理账号密码管理                   ")
        print("=======================================================")
        curr_uname = cfg.get('username', '未配置')
        curr_pwd = cfg.get('password', '')
        masked_pwd = mask_password(curr_pwd)
        print(f"当前管理账号: {curr_uname}")
        print(f"当前管理密码: {masked_pwd}")
        print("  [1] 自定义修改账号密码")
        print("  [2] 随机重置安全密码")
        print("  [3] 返回主菜单")
        print("=======================================================")
        print("请直接输入数字键 [1-3] 快速执行：", end="", flush=True)
        
        key = getch()
        if key == '1':
            print("\033[H\033[J", end="")
            new_uname = input(f"请输入新管理账号 (回车默认 {curr_uname}): ").strip()
            if not new_uname:
                new_uname = curr_uname
            new_pwd = input("请输入新管理密码 (不能为空): ").strip()
            if not new_pwd:
                print("错误: 密码不能为空！")
                time.sleep(2)
                continue
            cfg['username'] = new_uname
            cfg['password'] = new_pwd
            save_ui_cfg(cfg)
            print("账号密码修改成功！")
            print(f"您的新管理账号: {new_uname}")
            print(f"您的新管理密码: {new_pwd}")
            input("\n按任意键返回菜单...")
        elif key == '2':
            print("\033[H\033[J", end="")
            new_pwd = generate_random_password()
            cfg['password'] = new_pwd
            save_ui_cfg(cfg)
            print("密码随机重置成功！")
            print(f"您的全新12位安全密码为: {new_pwd}")
            print("密码已保存在本地，不需要重启服务，刷新浏览器即可登录。")
            input("\n按任意键返回菜单...")
        elif key == '3' or key == 'q' or key == '\x03':
            break

def getch():
    fd = sys.stdin.fileno()
    try:
        old_settings = termios.tcgetattr(fd)
    except termios.error:
        ch = sys.stdin.read(1)
        return ch if ch else "q"
    try:
        tty.setraw(sys.stdin.fileno())
        ch = sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    return ch if ch else "q"

def getch_timeout(timeout=1.0):
    import select
    fd = sys.stdin.fileno()
    try:
        old_settings = termios.tcgetattr(fd)
    except termios.error:
        try:
            r, _, _ = select.select([sys.stdin], [], [], timeout)
            if r:
                ch = sys.stdin.read(1)
                if not ch:
                    time.sleep(timeout)
                    return None
                return ch
        except Exception:
            time.sleep(timeout)
        return None
    try:
        tty.setraw(fd)
        r, _, _ = select.select([sys.stdin], [], [], timeout)
        if r:
            ch = sys.stdin.read(1)
            if not ch:
                return None
            return ch
        return None
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

def get_status_state():
    cfg = load_ui_cfg()
    state = load_state()
    proxy_port = cfg.get("proxy_port", 7928)
    return (
        cfg.get("port", 8787),
        cfg.get("secret_path", "EJsW2EeBo9lY"),
        cfg.get("username", "未配置"),
        cfg.get("password", ""),
        cfg.get("host", "0.0.0.0"),
        state.get("is_connecting", False),
        state.get("active_openvpn_node_id", ""),
        state.get("last_check_message", ""),
        state.get("active_node_latency", ""),
        state.get("proxy_ip", "-"),
        state.get("proxy_latency_ms", 0),
        state.get("proxy_ok", False),
        check_port_listening(proxy_port),
        check_service_active("aimilivpn.service"),
        check_openvpn_process(),
        get_service_pid("aimilivpn.service")
    )

def main():
    if os.geteuid() != 0:
        print("错误: 必须以 root 权限运行此命令。")
        sys.exit(1)
        
    if len(sys.argv) > 1:
        cmd = sys.argv[1].lower()
        if cmd == "start":
            start_service()
        elif cmd == "stop":
            stop_service()
        elif cmd == "restart":
            restart_service()
        elif cmd == "status":
            print("\033[?1049h\033[?25l\033[H\033[J", end="", flush=True)
            try:
                while True:
                    print("\033[H\033[J", end="")
                    print("\033[1;33m正在查询出口 IP 归属信息(经本地代理)...\033[0m", flush=True)
                    print_status(with_exit_info=True)
                    print_line("\n\033[1;33m提示: 当前为静态页面。按 [回车键/Enter] 手动刷新状态，按 [q] 或 [Ctrl+C] 退出...\033[0m")
                    print("\033[J", end="", flush=True)
                    
                    key = getch()
                    if key in ('q', 'Q', '\x03'):
                        break
                    if key in ('\r', '\n', '\x0a', '\x0d'):
                        continue
            except KeyboardInterrupt:
                pass
            finally:
                print("\033[?1049l\033[?25h", end="", flush=True)
        elif cmd == "logs":
            show_logs()
        elif cmd == "update":
            update_service()
        elif cmd == "uninstall":
            uninstall_service()
        elif cmd == "web":
            configure_web()
        elif cmd == "port":
            configure_port()
        elif cmd == "password":
            configure_credentials()
        elif cmd == "nodes":
            list_nodes()
        elif cmd == "refresh":
            refresh_nodes()
        elif cmd == "current":
            show_current()
        elif cmd == "fix":
            fix_node(sys.argv[2] if len(sys.argv) > 2 else None)
        elif cmd == "auto":
            auto_mode()
        elif cmd == "switch":
            switch_node()
        elif cmd == "iptype":
            set_iptype(sys.argv[2] if len(sys.argv) > 2 else None)
        else:
            print("未知命令。可用命令: start, stop, restart, status, logs, update, uninstall, web, port, password, nodes, refresh, current, fix, auto, switch, iptype")
        sys.exit(0)
        
    options = {
        '1': ("启动服务 (ml start)", start_service),
        '2': ("停止服务 (ml stop)", stop_service),
        '3': ("重启服务 (ml restart)", restart_service),
        '4': ("日志监控 (ml logs)", show_logs),
        '5': ("网页配置 (ml web)", configure_web),
        '6': ("端口配置 (ml port)", configure_port),
        '7': ("账号密码 (ml password)", configure_credentials),
        '8': ("一键更新 (ml update)", update_service),
        '9': ("完全卸载 (ml uninstall)", uninstall_service),
        'n': ("节点列表 (ml nodes)", list_nodes),
        'r': ("重新拉取节点 (ml refresh)", refresh_nodes),
        'c': ("当前节点状态 (ml current)", show_current),
        'f': ("固定节点 (ml fix)", fix_node),
        's': ("切换到最佳节点 (ml switch)", switch_node),
        't': ("IP出站类型过滤 (ml iptype)", set_iptype),
        'a': ("自动切换模式 (ml auto)", auto_mode),
        '0': ("退出终端", None)
    }
    # 菜单分组显示顺序(服务管理 / 节点管理)
    service_keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9']
    node_keys = ['n', 'r', 'c', 'f', 's', 't', 'a']
    
    # Enter alternate buffer and hide cursor
    print("\033[?1049h\033[?25l\033[H\033[J", end="", flush=True)
    try:
        need_redraw = True
        while True:
            if need_redraw:
                print("\033[H", end="")
                print_status()
                
                bold = "\033[1m"
                reset = "\033[0m"
                green = "\033[1;32m"
                
                print_line(f"【{bold}终端指令菜单栏{reset}】")
                print_line(f"  {bold}— 服务管理 —{reset}")
                for key in service_keys:
                    name, _ = options[key]
                    print_line(f"  {green}[{key}]{reset} {name}")
                print_line(f"  {bold}— 节点管理 —{reset}")
                for key in node_keys:
                    name, _ = options[key]
                    print_line(f"  {green}[{key}]{reset} {name}")
                print_line(f"  {green}[0]{reset} {options['0'][0]}")
                print_line("=======================================================")
                print_line("提示: 当前为静态页面。按 [回车键/Enter] 手动刷新状态。")
                print("请直接输入数字键 [0-9] 或字母键 [n/r/c/f/s/t/a] 快速选择执行：\033[K", end="", flush=True)
                print("\033[J", end="", flush=True)
                need_redraw = False
                
            try:
                key = getch()
            except KeyboardInterrupt:
                break
                
            if key == '\x03' or key == 'q' or key == 'Q':
                break
                
            if key == '0':
                break
                
            if key in ('\r', '\n', '\x0a', '\x0d'):
                need_redraw = True
                continue

            # 字母键归一化为小写,便于匹配 n/r/c/f/a(不影响转义序列与控制字符)
            if len(key) == 1 and key.isalpha():
                key = key.lower()

            if key in options:
                name, func = options[key]
                if func is None:
                    break
                    
                # Temporarily restore normal terminal scrollback and show cursor
                print("\033[?1049l\033[?25h", end="", flush=True)
                print(f"正在执行: {name}...\n")
                
                try:
                    func()
                except Exception as e:
                    print(f"执行出错: {e}")
                    
                if func not in (start_service, stop_service, restart_service,
                                configure_web, configure_port, configure_credentials, show_logs, update_service):
                    input("\n操作已完成，按回车键返回主菜单...")
                    
                # Re-enter alternate buffer and hide cursor
                print("\033[?1049h\033[?25l\033[H\033[J", end="", flush=True)
                need_redraw = True
    finally:
        # Exit alternate buffer and show cursor on exit
        print("\033[?1049l\033[?25h", end="", flush=True)

if __name__ == "__main__":
    main()
EOF
chmod +x /usr/bin/ml

# 7. Configure Custom parameters (First-time installation check)
AUTH_FILE="${INSTALL_DIR}/vpngate_data/ui_auth.json"
mkdir -p "${INSTALL_DIR}/vpngate_data"

is_custom="n"
if [ ! -f "$AUTH_FILE" ]; then
    if [ -t 0 ]; then
        echo -e "\n${YELLOW}检测到是首次安装，是否需要自定义配置网页端参数（端口/安全后缀/登录账号密码）？${PLAIN}"
        read -p "是否自定义配置？[y/N]: " is_custom
    else
        echo -e "\n${YELLOW}检测到是非交互式/无TTY环境安装，已自动跳过网页端参数自定义配置，采用默认随机参数部署。${PLAIN}"
    fi
    
    # Initialize defaults
    UI_PORT=8787
    # generate random secret suffix (12 chars alphanumeric)
    SECRET_PATH=$(python3 -c "import random, string; print(''.join(random.choices(string.ascii_letters + string.digits, k=12)))")
    # generate random password
    UI_PASSWORD=$(python3 -c "
import random, string
chars = string.ascii_letters + string.digits
while True:
    pwd = ''.join(random.choices(chars, k=12))
    if any(c.islower() for c in pwd) and any(c.isupper() for c in pwd) and any(c.isdigit() for c in pwd):
        print(pwd)
        break
")
    UI_USERNAME=$(python3 -c "
import random, string
chars = string.ascii_letters + string.digits
while True:
    uname = ''.join(random.choices(chars, k=12))
    if uname[0].isalpha() and any(c.islower() for c in uname) and any(c.isupper() for c in uname) and any(c.isdigit() for c in uname):
        print(uname)
        break
")

    if [[ "$is_custom" =~ ^[Yy]$ ]]; then
        # Step-by-step custom inputs
        # 1. Custom port
        while true; do
            read -p "请输入自定义管理端口 [1-65535, 默认 8787]: " input_port
            if [ -z "$input_port" ]; then
                UI_PORT=8787
                break
            fi
            if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
                UI_PORT=$input_port
                break
            else
                echo -e "${RED}输入错误: 端口必须是 1 到 65535 之间的数字！${PLAIN}"
            fi
        done
        
        # 2. Custom suffix
        while true; do
            read -p "请输入网页登录自定义安全后缀 [字母与数字组合, 默认随机]: " input_suffix
            if [ -z "$input_suffix" ]; then
                break
            fi
            if [[ "$input_suffix" =~ ^[A-Za-z0-9]+$ ]]; then
                SECRET_PATH=$input_suffix
                break
            else
                echo -e "${RED}输入错误: 后缀仅能由英文字母和数字组成！${PLAIN}"
            fi
        done
        
        # 3. Custom login username and password
        read -p "请输入登录账号 [默认 $UI_USERNAME]: " input_user
        if [ -n "$input_user" ]; then
            UI_USERNAME=$input_user
        fi
        
        while true; do
            read -p "请输入登录密码 [默认随机生成, 建议包含字母、数字与符号]: " input_pass
            if [ -z "$input_pass" ]; then
                break
            fi
            if [ ${#input_pass} -ge 4 ]; then
                UI_PASSWORD=$input_pass
                break
            else
                echo -e "${RED}输入错误: 密码长度不能少于 4 位！${PLAIN}"
            fi
        done
    fi

    # Write config JSON. Values are passed as argv to avoid breaking Python code
    # when username/password contain quotes, backslashes, or shell metacharacters.
    python3 - "$AUTH_FILE" "$UI_PORT" "$SECRET_PATH" "$UI_USERNAME" "$UI_PASSWORD" <<'PY'
import json
import sys

auth_file, ui_port, secret_path, username, password = sys.argv[1:6]
cfg = {
    "host": "::",
    "port": int(ui_port),
    "proxy_port": 7928,
    "secret_path": secret_path,
    "username": username,
    "password": password,
}
with open(auth_file, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
fi

# 8. Start service
# 8.5 Optimize network parameters (rp_filter for policy routing)
echo -e "\n正在优化网络参数 (配置反向路径过滤 rp_filter=2 以支持策略路由)..."
if [ -d "/etc/sysctl.d" ]; then
    cat > /etc/sysctl.d/99-aimilivpn.conf <<EOF
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
    sysctl -p /etc/sysctl.d/99-aimilivpn.conf >/dev/null 2>&1 || true
else
    # Fallback to appending to /etc/sysctl.conf
    if ! grep -q "net.ipv4.conf.all.rp_filter" /etc/sysctl.conf; then
        echo "" >> /etc/sysctl.conf
        echo "net.ipv4.conf.all.rp_filter = 2" >> /etc/sysctl.conf
        echo "net.ipv4.conf.default.rp_filter = 2" >> /etc/sysctl.conf
    else
        sed -i 's/net.ipv4.conf.all.rp_filter\s*=\s*[0-9]/net.ipv4.conf.all.rp_filter = 2/g' /etc/sysctl.conf
        sed -i 's/net.ipv4.conf.default.rp_filter\s*=\s*[0-9]/net.ipv4.conf.default.rp_filter = 2/g' /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1 || true
fi
# Apply to currently active interfaces dynamically (prefer native proc write for BusyBox/Alpine compatibility)
echo "2" > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
echo "2" > /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null || sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true
if [ -d "/proc/sys/net/ipv4/conf" ]; then
    for dev_dir in /proc/sys/net/ipv4/conf/*; do
        dev_name=$(basename "$dev_dir")
        echo "2" > "/proc/sys/net/ipv4/conf/${dev_name}/rp_filter" 2>/dev/null || sysctl -w net.ipv4.conf.${dev_name}.rp_filter=2 >/dev/null 2>&1 || true
    done
fi

echo -e "\n正在启动 AimiliVPN 服务并初始化网络..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart aimilivpn.service || true
elif command -v rc-service >/dev/null 2>&1; then
    rc-service aimilivpn restart || true
fi

# Wait and poll for node loading and active connection
echo -e "\n正在等待 AimiliVPN 首次获取节点并建立加密通道 (此过程可能需要 5-30 秒)..."
ACTIVE_ID=""
LAST_MSG=""
for i in {1..90}; do
    if [ -f "${INSTALL_DIR}/vpngate_data/state.json" ]; then
        ACTIVE_ID=$(python3 -c "import json; print(json.load(open('${INSTALL_DIR}/vpngate_data/state.json')).get('active_openvpn_node_id', ''))" 2>/dev/null || echo "")
        IS_CONN=$(python3 -c "import json; print(json.load(open('${INSTALL_DIR}/vpngate_data/state.json')).get('is_connecting', False))" 2>/dev/null || echo "False")
        CUR_MSG=$(python3 -c "import json; print(json.load(open('${INSTALL_DIR}/vpngate_data/state.json')).get('last_check_message', ''))" 2>/dev/null || echo "")
        
        if [ "$IS_CONN" = "False" ] || [ "$IS_CONN" = "false" ]; then
            if [ -n "$ACTIVE_ID" ]; then
                echo -e "  -> ${GREEN}[已就绪]${PLAIN} 首次节点连接成功，活动节点: ${GREEN}$ACTIVE_ID${PLAIN}"
                break
            else
                if [ -n "$CUR_MSG" ] && [ "$CUR_MSG" != "$LAST_MSG" ]; then
                    echo -e "  -> 提示: ${YELLOW}${CUR_MSG}${PLAIN}"
                    LAST_MSG="$CUR_MSG"
                fi
            fi
        else
            if [ -n "$CUR_MSG" ] && [ "$CUR_MSG" != "$LAST_MSG" ]; then
                echo -e "  -> 状态: ${YELLOW}${CUR_MSG}${PLAIN}"
                LAST_MSG="$CUR_MSG"
            fi
        fi
    else
        echo -n "."
    fi
    sleep 1
done
if [ -z "$ACTIVE_ID" ]; then
    echo -e "  -> ${YELLOW}[加载超时]${PLAIN} 首次节点获取或连接超时，将在后台继续尝试..."
fi

SECRET_PATH="EJsW2EeBo9lY"
USERNAME="未配置"
PASSWORD="未配置"
UI_PORT=8787
PROXY_PORT=7928
AUTH_FILE="${INSTALL_DIR}/vpngate_data/ui_auth.json"
if [ -f "$AUTH_FILE" ]; then
    SECRET_PATH=$(python3 -c "import json; print(json.load(open('$AUTH_FILE')).get('secret_path', 'EJsW2EeBo9lY'))" 2>/dev/null || echo "EJsW2EeBo9lY")
    USERNAME=$(python3 -c "import json; print(json.load(open('$AUTH_FILE')).get('username', '未配置'))" 2>/dev/null || echo "未配置")
    PASSWORD=$(python3 -c "import json; print(json.load(open('$AUTH_FILE')).get('password', '未配置'))" 2>/dev/null || echo "未配置")
    UI_PORT=$(python3 -c "import json; print(json.load(open('$AUTH_FILE')).get('port', 8787))" 2>/dev/null || echo "8787")
    PROXY_PORT=$(python3 -c "import json; print(json.load(open('$AUTH_FILE')).get('proxy_port', 7928))" 2>/dev/null || echo "7928")
fi

# Get VPS public IP
echo -e "正在获取 VPS 公网 IP..."
PUBLIC_IP=$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://ifconfig.me || curl -s --max-time 3 icanhazip.com || echo "您的服务器公网IP")
echo -n "$PUBLIC_IP" > "${INSTALL_DIR}/vpngate_data/public_ip.txt"

# Get VPS public IPv6
echo -e "正在获取 VPS 公网 IPv6..."
PUBLIC_IPV6=$(curl -6 -s --max-time 3 https://api.ipify.org || curl -6 -s --max-time 3 https://ifconfig.me || curl -6 -s --max-time 3 icanhazip.com || echo "")

echo -e "\n${GREEN}==========================================================${PLAIN}"
echo -e "${GREEN}             AimiliVPN 源码一键部署已完成！${PLAIN}"
echo -e "${GREEN}==========================================================${PLAIN}"
echo -e "  * 网页控制面板:  ${BLUE}http://${PUBLIC_IP}:${UI_PORT}/${SECRET_PATH}/${PLAIN}"
if [ -n "$PUBLIC_IPV6" ]; then
    echo -e "  * 网页控制面板(IPv6):  ${BLUE}http://[${PUBLIC_IPV6}]:${UI_PORT}/${SECRET_PATH}/${PLAIN}"
fi
echo -e "  * 网页管理账号:  ${YELLOW}${USERNAME}${PLAIN}"
echo -e "  * 网页管理密码:  ${YELLOW}${PASSWORD}${PLAIN}"
echo -e "  * HTTP/SOCKS5 代理端口:  ${BLUE}http://127.0.0.1:${PROXY_PORT}/${PLAIN}  或  ${BLUE}http://[::1]:${PROXY_PORT}/${PLAIN}"
echo -e " --------------------------------------------------------"
echo -e "  * 快速状态指令:   ${YELLOW}ml status${PLAIN}  或  ${YELLOW}ml${PLAIN}"
echo -e "  * 查看实时日志:   ${YELLOW}ml logs${PLAIN}"
echo -e "  * 停止服务:       ${YELLOW}ml stop${PLAIN}"
echo -e "  * 重启服务:       ${YELLOW}ml restart${PLAIN}"
echo -e " --------------------------------------------------------"
echo -e "  * 节点列表:       ${YELLOW}ml nodes${PLAIN}"
echo -e "  * 重新拉取节点:   ${YELLOW}ml refresh${PLAIN}"
echo -e "  * 当前节点状态:   ${YELLOW}ml current${PLAIN}"
echo -e "  * 固定某个节点:   ${YELLOW}ml fix <序号|ID>${PLAIN}"
echo -e "  * 切换到最佳节点: ${YELLOW}ml switch${PLAIN}"
echo -e "  * IP出站类型过滤: ${YELLOW}ml iptype <all|residential|hosting>${PLAIN}"
echo -e "  * 恢复自动切换:   ${YELLOW}ml auto${PLAIN}"
echo -e "=========================================================="
echo
