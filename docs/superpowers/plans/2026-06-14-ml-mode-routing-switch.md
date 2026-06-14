# `ml mode` 路由模式切换子命令 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `ml` CLI 新增统一的 `ml mode` 子命令,覆盖 auto / fixed_ip / fixed_region / favorites 全部 4 种路由模式的查看与切换。

**Architecture:** `ml` CLI 的 Python 源码内嵌在 `install.sh:181-1492`(`cat > /usr/bin/ml <<'EOF'` quoted heredoc,原样写入 `/usr/bin/ml`)。新增三个纯/半纯辅助函数与一个分发主函数,`auto`/`fixed_ip` 直接复用现有 `auto_mode()`/`fix_node()`,`fixed_region`/`favorites` 新增辅助。所有分支只 `restart_service()`、绝不写 `force_refresh.flag`,由后端 `collector_loop` 既定语义(优先复用缓存可用节点、有可用则跳过拉取)自动满足"切换后有可用节点不重新拉取"。

**Tech Stack:** Python 3(标准库),bash heredoc;测试用标准库 `unittest`(从 `install.sh` 提取 ml 段动态加载,无需 root)。

**测试约定(全计划通用):** 所有 `unittest` 测试通过 `tests/test_ml_routing.py` 内的 `load_ml_module()` helper,从 `install.sh` 提取 ml 段加载为模块。纯函数与分发逻辑可在非 root 下单测;含 `input()`/`restart_service()` 的交互函数以 `py_compile` + 逻辑走查验证。运行命令统一:`python3 -m unittest tests.test_ml_routing -v`。

参考 spec:`docs/superpowers/specs/2026-06-14-ml-mode-routing-switch-design.md`

---

## File Structure

- **Modify** `install.sh`(ml 段 181-1492 内):
  - 新增常量 `ROUTING_MODE_ALIASES`、`ROUTING_MODE_MENU`
  - 新增函数 `_normalize_routing_mode`、`_collect_countries`、`_resolve_country`、`_set_fixed_region`、`_set_favorites`、`set_routing_mode`
  - 修改 `main()` 命令分发(约 1389)、交互菜单 `options`/`node_keys`(约 1395-1416)、未知命令提示串(约 1392)
- **Create** `tests/test_ml_routing.py`:单测纯函数与分发逻辑

新函数建议插入位置:紧接现有 `set_iptype()` 之后(约 `install.sh:653`,`IP_TYPE` 相关定义之后、`ping_ip` 之前),与既有节点管理子命令同区。

---

## Task 1: 模式名归一化纯函数 `_normalize_routing_mode`

**Files:**
- Create: `tests/test_ml_routing.py`
- Modify: `install.sh`(ml 段内新增常量与函数)

- [ ] **Step 1: 写失败测试(含 load helper)**

创建 `tests/test_ml_routing.py`:

```python
import importlib.util
import os
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_ml_module():
    """从 install.sh 提取 /usr/bin/ml 的 Python 段并加载为模块(无需 root)。"""
    path = os.path.join(REPO, "install.sh")
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith("cat > /usr/bin/ml"):
            start = i + 1
            break
    if start is None:
        raise RuntimeError("未找到 ml 脚本 heredoc 起始行")
    end = None
    for j in range(start, len(lines)):
        if lines[j].strip() == "EOF":
            end = j
            break
    if end is None:
        raise RuntimeError("未找到 ml 脚本 heredoc 结束 EOF")
    code = "\n".join(lines[start:end])
    tmp = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False, encoding="utf-8")
    tmp.write(code)
    tmp.close()
    spec = importlib.util.spec_from_file_location("ml_cli", tmp.name)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestNormalizeRoutingMode(unittest.TestCase):
    def setUp(self):
        self.ml = load_ml_module()

    def test_full_names(self):
        n = self.ml._normalize_routing_mode
        self.assertEqual(n("auto"), "auto")
        self.assertEqual(n("fixed_ip"), "fixed_ip")
        self.assertEqual(n("fixed_region"), "fixed_region")
        self.assertEqual(n("favorites"), "favorites")

    def test_aliases(self):
        n = self.ml._normalize_routing_mode
        self.assertEqual(n("fix"), "fixed_ip")
        self.assertEqual(n("region"), "fixed_region")
        self.assertEqual(n("fav"), "favorites")

    def test_numbers(self):
        n = self.ml._normalize_routing_mode
        self.assertEqual(n("1"), "auto")
        self.assertEqual(n("2"), "fixed_ip")
        self.assertEqual(n("3"), "fixed_region")
        self.assertEqual(n("4"), "favorites")

    def test_case_and_space_insensitive(self):
        n = self.ml._normalize_routing_mode
        self.assertEqual(n("  AUTO "), "auto")
        self.assertEqual(n("Fix"), "fixed_ip")

    def test_invalid_and_none(self):
        n = self.ml._normalize_routing_mode
        self.assertIsNone(n("bogus"))
        self.assertIsNone(n(""))
        self.assertIsNone(n(None))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `python3 -m unittest tests.test_ml_routing -v`
Expected: FAIL —— `AttributeError: module 'ml_cli' has no attribute '_normalize_routing_mode'`

- [ ] **Step 3: 实现常量与函数**

在 `install.sh` 的 ml 段内、`set_iptype()` 之后(约 653 行)插入:

```python
# 路由模式切换(ml mode):覆盖 auto/fixed_ip/fixed_region/favorites 四种模式。
# 别名与编号统一归一化为规范模式值;输入不区分大小写、忽略首尾空白。
ROUTING_MODE_ALIASES = {
    "auto": "auto", "1": "auto",
    "fixed_ip": "fixed_ip", "fix": "fixed_ip", "2": "fixed_ip",
    "fixed_region": "fixed_region", "region": "fixed_region", "3": "fixed_region",
    "favorites": "favorites", "fav": "favorites", "4": "favorites",
}
# 交互菜单展示顺序与简短描述(规范模式值 -> 描述);"当前:" 行另用 routing_mode_label() 带色全标签。
ROUTING_MODE_MENU = [
    ("auto", "自动选优 (失效自动切换)"),
    ("fixed_ip", "固定节点 (锁定不切换)"),
    ("fixed_region", "固定地区 (只连指定国家)"),
    ("favorites", "收藏优先 (只连收藏节点)"),
]

def _normalize_routing_mode(value):
    # 归一化模式输入:全名/别名/编号 -> 规范模式值;无法识别返回 None
    if value is None:
        return None
    return ROUTING_MODE_ALIASES.get(str(value).strip().lower())
```

- [ ] **Step 4: 运行测试,确认通过**

Run: `python3 -m unittest tests.test_ml_routing -v`
Expected: PASS(5 个 test 全绿)

- [ ] **Step 5: 提交**

```bash
git add tests/test_ml_routing.py install.sh
git commit -m "feat(ml): 新增路由模式名归一化 _normalize_routing_mode 与别名常量"
```

---

## Task 2: 国家收集与解析 `_collect_countries` / `_resolve_country`

**Files:**
- Modify: `install.sh`(ml 段内新增两函数)
- Modify: `tests/test_ml_routing.py`(新增测试类)

- [ ] **Step 1: 写失败测试**

在 `tests/test_ml_routing.py` 的 `if __name__` 之前追加:

```python
class TestCountryResolve(unittest.TestCase):
    def setUp(self):
        self.ml = load_ml_module()
        self.nodes = [
            {"country": "日本", "country_short": "JP"},
            {"country": "日本", "country_short": "JP"},
            {"country": "美国", "country_short": "US"},
            {"country": "", "country_short": ""},   # 空国家应被跳过
            {"country": "韩国", "country_short": "KR"},
        ]

    def test_collect_countries_dedup_count_sorted(self):
        cs = self.ml._collect_countries(self.nodes)
        names = [c["name"] for c in cs]
        # 去重且按名称排序(中文按 Unicode 码点)
        self.assertEqual(names, sorted(names))
        self.assertIn("日本", names)
        self.assertIn("美国", names)
        self.assertIn("韩国", names)
        self.assertNotIn("", names)
        jp = next(c for c in cs if c["name"] == "日本")
        self.assertEqual(jp["count"], 2)
        self.assertEqual(jp["shorts"], {"JP"})

    def test_resolve_by_index(self):
        cs = self.ml._collect_countries(self.nodes)
        first = cs[0]["name"]
        self.assertEqual(self.ml._resolve_country("1", cs), first)
        self.assertIsNone(self.ml._resolve_country("99", cs))
        self.assertIsNone(self.ml._resolve_country("0", cs))

    def test_resolve_by_chinese_name(self):
        cs = self.ml._collect_countries(self.nodes)
        self.assertEqual(self.ml._resolve_country("日本", cs), "日本")

    def test_resolve_by_short_code_case_insensitive(self):
        cs = self.ml._collect_countries(self.nodes)
        self.assertEqual(self.ml._resolve_country("jp", cs), "日本")
        self.assertEqual(self.ml._resolve_country("US", cs), "美国")

    def test_resolve_invalid(self):
        cs = self.ml._collect_countries(self.nodes)
        self.assertIsNone(self.ml._resolve_country("法国", cs))
        self.assertIsNone(self.ml._resolve_country("", cs))
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `python3 -m unittest tests.test_ml_routing.TestCountryResolve -v`
Expected: FAIL —— `AttributeError: ... has no attribute '_collect_countries'`

- [ ] **Step 3: 实现两个纯函数**

在 `install.sh` 的 `_normalize_routing_mode` 之后插入:

```python
def _collect_countries(nodes):
    # 从缓存节点收集去重国家:name=中文国家名(后端已存中文),count=节点数,shorts=该国家的 country_short 集合
    by_name = {}
    for n in nodes:
        name = (n.get("country") or "").strip()
        if not name:
            continue
        entry = by_name.setdefault(name, {"name": name, "count": 0, "shorts": set()})
        entry["count"] += 1
        short = (n.get("country_short") or "").strip()
        if short:
            entry["shorts"].add(short)
    return [by_name[k] for k in sorted(by_name.keys())]

def _resolve_country(sel, countries):
    # 解析用户输入 -> 规范中文国家名;支持序号(1-based)/中文名/两位代码(忽略大小写),无匹配返回 None
    sel = str(sel).strip()
    if not sel:
        return None
    if sel.isdigit():
        idx = int(sel)
        if 1 <= idx <= len(countries):
            return countries[idx - 1]["name"]
        return None
    low = sel.lower()
    for c in countries:
        if c["name"].lower() == low or low in {s.lower() for s in c["shorts"]}:
            return c["name"]
    return None
```

- [ ] **Step 4: 运行测试,确认通过**

Run: `python3 -m unittest tests.test_ml_routing -v`
Expected: PASS(Task 1 + Task 2 全部 test 绿)

- [ ] **Step 5: 提交**

```bash
git add tests/test_ml_routing.py install.sh
git commit -m "feat(ml): 新增国家收集与解析 _collect_countries/_resolve_country"
```

---

## Task 3: `fixed_region` / `favorites` 切换辅助函数

**Files:**
- Modify: `install.sh`(ml 段内新增 `_set_fixed_region`、`_set_favorites`)

含 `input()`/`save_ui_auth()`/`restart_service()` 副作用,以 `py_compile` + 逻辑走查验证(不写自动化端到端测试)。

- [ ] **Step 1: 实现 `_set_fixed_region`**

在 `_resolve_country` 之后插入:

```python
def _set_fixed_region(country=None):
    yellow = "\033[1;33m"; green = "\033[1;32m"; reset = "\033[0m"
    nodes = sorted_nodes()
    if not nodes:
        print("当前无节点缓存，无法设置固定地区。请先运行 'ml refresh' 拉取节点。")
        return
    countries = _collect_countries(nodes)
    if not countries:
        print("当前缓存节点均无国家信息,无法设置固定地区。请先运行 'ml refresh' 重新拉取。")
        return
    if country is None or not str(country).strip():
        print("=======================================================")
        print("               固定地区 - 选择国家")
        print("=======================================================")
        for i, c in enumerate(countries, 1):
            print(f"  [{i}] {c['name']} ({c['count']}个节点)")
        print("=======================================================")
        try:
            country = input("请输入要锁定的国家【序号】或国家名/两位代码(直接回车取消): ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n已取消。")
            return
        if not country:
            print("已取消。")
            return
    name = _resolve_country(country, countries)
    if name is None:
        print(f"未找到匹配的国家: {country}。可选国家如下:")
        for i, c in enumerate(countries, 1):
            print(f"  [{i}] {c['name']} ({c['count']}个节点)")
        return
    cfg = load_ui_auth()
    was_disabled = not cfg.get("connection_enabled", True)
    cfg["routing_mode"] = "fixed_region"
    cfg["force_country"] = name
    cfg["connection_enabled"] = True
    cfg.pop("fixed_node_id", None)
    try:
        save_ui_auth(cfg)
    except Exception as e:
        print(f"写入配置失败: {e}")
        return
    cnt = next((c["count"] for c in countries if c["name"] == name), 0)
    print(f"已切换到「固定地区: {green}{name}{reset}」(该国家缓存中有 {cnt} 个节点)。")
    if was_disabled:
        print("注意: 连接总开关原为【已禁用】,本次操作已重新启用连接。")
    restart_service()
    print("配置已生效，服务正在重启并优先在该地区的缓存可用节点中连接。可运行 'ml current' 查看状态。")
    print(f"{yellow}说明: 若该地区当前无可用缓存节点,后端会自动拉取补齐;有可用节点时则直接复用,不重新拉取。{reset}")
```

- [ ] **Step 2: 实现 `_set_favorites`**

在 `_set_fixed_region` 之后插入:

```python
def _set_favorites():
    yellow = "\033[1;33m"; green = "\033[1;32m"; reset = "\033[0m"
    cfg = load_ui_auth()
    fav_ids = cfg.get("favorite_node_ids", []) or []
    if not fav_ids:
        print("当前没有任何收藏节点,无法启用收藏优先模式。")
        print(f"{yellow}请先在 Web 面板收藏节点后再试(CLI 暂不管理收藏)。{reset}")
        return
    was_disabled = not cfg.get("connection_enabled", True)
    cfg["routing_mode"] = "favorites"
    cfg["connection_enabled"] = True
    cfg.pop("fixed_node_id", None)
    try:
        save_ui_auth(cfg)
    except Exception as e:
        print(f"写入配置失败: {e}")
        return
    print(f"已切换到「{green}收藏优先{reset}」模式(当前收藏 {len(fav_ids)} 个节点)。")
    if was_disabled:
        print("注意: 连接总开关原为【已禁用】,本次操作已重新启用连接。")
    restart_service()
    print("配置已生效，服务正在重启并优先在收藏节点中连接。可运行 'ml current' 查看状态。")
```

- [ ] **Step 3: 语法校验(提取 ml 段 py_compile)**

Run:
```bash
python3 - <<'PY'
import py_compile, tempfile, os
lines = open("install.sh", encoding="utf-8").read().splitlines()
start = next(i for i, l in enumerate(lines) if l.startswith("cat > /usr/bin/ml")) + 1
end = next(j for j in range(start, len(lines)) if lines[j].strip() == "EOF")
code = "\n".join(lines[start:end])
tmp = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False, encoding="utf-8")
tmp.write(code); tmp.close()
py_compile.compile(tmp.name, doraise=True)
print("py_compile OK")
PY
```
Expected: 输出 `py_compile OK`,无异常

- [ ] **Step 4: 逻辑走查(对照 spec §5/§6)**

确认:`fixed_region` 落库 `force_country` 为规范中文名(与后端 `_select_available_candidates` 的 `n.country` 匹配口径一致);`favorites` 空收藏时拒绝且不写配置;两者均 `pop fixed_node_id`、`connection_enabled=True`、`restart_service()`、不写 `force_refresh.flag`。

- [ ] **Step 5: 提交**

```bash
git add install.sh
git commit -m "feat(ml): 新增 fixed_region/favorites 切换辅助 _set_fixed_region/_set_favorites"
```

---

## Task 4: 分发主函数 `set_routing_mode`(mock 验证分发)

**Files:**
- Modify: `install.sh`(ml 段内新增 `set_routing_mode`)
- Modify: `tests/test_ml_routing.py`(新增分发测试类)

- [ ] **Step 1: 写失败测试(mock 拦截副作用分支)**

在 `tests/test_ml_routing.py` 的 `if __name__` 之前追加:

```python
from unittest import mock


class TestSetRoutingModeDispatch(unittest.TestCase):
    def setUp(self):
        self.ml = load_ml_module()

    def _patches(self):
        # 拦截四个会产生副作用的分支目标,断言分发正确
        return (
            mock.patch.object(self.ml, "auto_mode"),
            mock.patch.object(self.ml, "fix_node"),
            mock.patch.object(self.ml, "_set_fixed_region"),
            mock.patch.object(self.ml, "_set_favorites"),
        )

    def test_dispatch_auto(self):
        p = self._patches()
        with p[0] as auto, p[1] as fix, p[2] as region, p[3] as fav:
            self.ml.set_routing_mode("auto")
            auto.assert_called_once_with()
            fix.assert_not_called()
            region.assert_not_called()
            fav.assert_not_called()

    def test_dispatch_fixed_ip_with_selector(self):
        p = self._patches()
        with p[0] as auto, p[1] as fix, p[2] as region, p[3] as fav:
            self.ml.set_routing_mode("fix", "3")
            fix.assert_called_once_with("3")
            auto.assert_not_called()

    def test_dispatch_fixed_region_with_country(self):
        p = self._patches()
        with p[0] as auto, p[1] as fix, p[2] as region, p[3] as fav:
            self.ml.set_routing_mode("region", "JP")
            region.assert_called_once_with("JP")
            fav.assert_not_called()

    def test_dispatch_favorites(self):
        p = self._patches()
        with p[0] as auto, p[1] as fix, p[2] as region, p[3] as fav:
            self.ml.set_routing_mode("fav")
            fav.assert_called_once_with()
            region.assert_not_called()

    def test_dispatch_invalid_calls_nothing(self):
        p = self._patches()
        with p[0] as auto, p[1] as fix, p[2] as region, p[3] as fav:
            self.ml.set_routing_mode("bogus")
            auto.assert_not_called()
            fix.assert_not_called()
            region.assert_not_called()
            fav.assert_not_called()
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `python3 -m unittest tests.test_ml_routing.TestSetRoutingModeDispatch -v`
Expected: FAIL —— `AttributeError: ... has no attribute 'set_routing_mode'`

- [ ] **Step 3: 实现分发主函数**

在 `_set_favorites` 之后插入:

```python
def set_routing_mode(value=None, arg=None):
    green = "\033[1;32m"; reset = "\033[0m"
    if value is None:
        cfg = load_ui_auth()
        current = cfg.get("routing_mode", "auto")
        print("=======================================================")
        print("               路由模式切换")
        print("=======================================================")
        print(f"当前: {routing_mode_label(current)}")
        for i, (key, desc) in enumerate(ROUTING_MODE_MENU, 1):
            mark = " (当前)" if key == current else ""
            print(f"  [{i}] {key:<14}{desc}{mark}")
        print("=======================================================")
        try:
            value = input("请输入要切换到的【序号 1-4】或模式名(直接回车取消): ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n已取消。")
            return
        if not value:
            print("已取消。")
            return
    mode = _normalize_routing_mode(value)
    if mode is None:
        print(f"无效的路由模式: {value}。可选: auto / fixed_ip(fix) / fixed_region(region) / favorites(fav),或序号 1-4。")
        return
    if mode == "auto":
        auto_mode()
    elif mode == "fixed_ip":
        fix_node(arg)
    elif mode == "fixed_region":
        _set_fixed_region(arg)
    elif mode == "favorites":
        _set_favorites()
```

- [ ] **Step 4: 运行测试,确认通过**

Run: `python3 -m unittest tests.test_ml_routing -v`
Expected: PASS(Task 1/2/4 全部 test 绿)

- [ ] **Step 5: 提交**

```bash
git add tests/test_ml_routing.py install.sh
git commit -m "feat(ml): 新增路由模式分发主函数 set_routing_mode"
```

---

## Task 5: 接线 main() 分发、交互菜单与提示串

**Files:**
- Modify: `install.sh`(`main()` 命令分发约 1389、`options`/`node_keys` 约 1395-1416、未知命令提示约 1392)

- [ ] **Step 1: 在命令分发中接入 `mode`**

定位 `install.sh` 中(约 1389):

```python
        elif cmd == "iptype":
            set_iptype(sys.argv[2] if len(sys.argv) > 2 else None)
```

在其后、`else:` 之前插入:

```python
        elif cmd == "mode":
            set_routing_mode(
                sys.argv[2] if len(sys.argv) > 2 else None,
                sys.argv[3] if len(sys.argv) > 3 else None,
            )
```

- [ ] **Step 2: 更新未知命令提示串**

定位(约 1392):

```python
            print("未知命令。可用命令: start, stop, restart, status, logs, update, uninstall, web, port, password, nodes, refresh, current, fix, auto, switch, iptype")
```

改为(末尾加 `, mode`):

```python
            print("未知命令。可用命令: start, stop, restart, status, logs, update, uninstall, web, port, password, nodes, refresh, current, fix, auto, switch, iptype, mode")
```

- [ ] **Step 3: 交互主菜单加入 `路由模式切换`**

定位 `options` 字典中(约 1411):

```python
        'a': ("自动切换模式 (ml auto)", auto_mode),
        '0': ("退出终端", None)
```

改为(在 `'a'` 后、`'0'` 前插入 `'m'`):

```python
        'a': ("自动切换模式 (ml auto)", auto_mode),
        'm': ("路由模式切换 (ml mode)", set_routing_mode),
        '0': ("退出终端", None)
```

定位 `node_keys`(约 1416):

```python
    node_keys = ['n', 'r', 'c', 'f', 's', 't', 'a']
```

改为:

```python
    node_keys = ['n', 'r', 'c', 'f', 's', 't', 'a', 'm']
```

- [ ] **Step 4: 整体语法校验 + 全部单测**

Run:
```bash
python3 - <<'PY'
import py_compile, tempfile
lines = open("install.sh", encoding="utf-8").read().splitlines()
start = next(i for i, l in enumerate(lines) if l.startswith("cat > /usr/bin/ml")) + 1
end = next(j for j in range(start, len(lines)) if lines[j].strip() == "EOF")
tmp = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False, encoding="utf-8")
tmp.write("\n".join(lines[start:end])); tmp.close()
py_compile.compile(tmp.name, doraise=True)
print("py_compile OK")
PY
python3 -m unittest tests.test_ml_routing -v
bash -n install.sh && echo "bash -n OK"
```
Expected: `py_compile OK`、全部单测 PASS、`bash -n OK`(确认 heredoc 未被破坏、shell 语法正确)

- [ ] **Step 5: 逻辑走查(对照 spec §8)**

确认:命令行 `ml mode`(交互)、`ml mode auto`、`ml mode fix 3`、`ml mode region JP`、`ml mode fav` 均能正确分发;交互主菜单按 `m` 触发 `set_routing_mode`;`mode` 出现在未知命令提示中。无法真机验证 `restart` 后实际复用/拉取行为,以代码逻辑(§7)说明,标注"未真机验证"。

- [ ] **Step 6: 提交**

```bash
git add install.sh
git commit -m "feat(ml): 接入 ml mode 命令分发、交互菜单项与提示串"
```

---

## Self-Review(已执行)

**Spec 覆盖核对:**
- §2 命令形态 → Task 4(分发)+ Task 5(命令行接线)✓
- §2 别名 → Task 1(`ROUTING_MODE_ALIASES`)✓
- §3 交互菜单 → Task 4(`set_routing_mode` value=None 分支)✓
- §4 各模式行为/通用写配置 → auto/fixed_ip 复用现有(Task 4 分发);fixed_region/favorites(Task 3)✓
- §5 国家解析(中文名落库、序号/代码) → Task 2 + Task 3 ✓
- §6 空收藏拒绝 → Task 3 `_set_favorites` ✓
- §7 不写 force_refresh.flag → Task 3 实现中无 flag 写入,Task 3 Step 4 / Task 5 Step 5 走查确认 ✓
- §8 集成改动点(分发/菜单/node_keys/提示) → Task 5 ✓
- §9 不改 routing_ip_type/fav_fail_fallback → 各函数实现未触碰 ✓
- §10 边界(无缓存/写失败/取消/无效模式) → Task 3、Task 4 实现覆盖 ✓
- §11 验证方式 → 各 Task 的 unittest + py_compile + 走查 ✓

**占位符扫描:** 无 TBD/TODO,所有代码步骤含完整代码。✓

**类型/命名一致性:** `_normalize_routing_mode`、`_collect_countries`(返回含 `name`/`count`/`shorts` 的 dict 列表)、`_resolve_country`、`_set_fixed_region`、`_set_favorites`、`set_routing_mode(value, arg)` 在 Task 间签名/字段一致;`ROUTING_MODE_ALIASES`/`ROUTING_MODE_MENU` 引用一致。✓
