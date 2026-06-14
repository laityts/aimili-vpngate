# 设计:`ml mode` 路由模式切换子命令

日期:2026-06-14
范围:`install.sh`(内嵌的 `ml` CLI Python 脚本)

## 1. 背景与目标

`ml` CLI 当前只能切换到 4 种路由模式中的 2 种:

| 模式值 | 文案 | 含义 | 现有 CLI 入口 |
|--------|------|------|--------------|
| `auto` | 自动选优 | 自动选延迟最低的可用节点,失效自动切换 | `ml auto` / `ml switch` |
| `fixed_ip` | 固定节点 | 锁定指定节点,绝不自动切换 | `ml fix <序号\|ID>` |
| `fixed_region` | 固定地区 | 只连选定国家的节点 | ❌ 仅 Web 面板 |
| `favorites` | 收藏优先 | 只在收藏节点中选择/切换 | ❌ 仅 Web 面板 |

模式取值的权威校验在 `vpngate_manager.py:5708`,CLI 侧标签在 `install.sh:329` 的 `routing_mode_label()`。

目标:新增统一子命令 `ml mode`,覆盖全部 4 种模式的查看与切换,补齐 CLI 与 Web 面板的能力差距。`ml auto`、`ml fix` 原命令保留为快捷方式。

## 2. 命令形态

```
ml mode                        # 交互菜单:显示当前模式 + 4 个编号项,输入编号或模式名
ml mode auto                   # 直接切到自动选优
ml mode fixed_ip <序号|ID>     # 固定节点(别名: fix)
ml mode fixed_region <国家>    # 固定地区(别名: region)
ml mode favorites              # 收藏优先(别名: fav)
```

### 别名

模式名输入(命令行参数与交互菜单)统一归一化,接受全名与别名:

| 规范值 | 接受的输入 |
|--------|-----------|
| `auto` | `auto` |
| `fixed_ip` | `fixed_ip`、`fix` |
| `fixed_region` | `fixed_region`、`region` |
| `favorites` | `favorites`、`fav` |

外加交互菜单里的编号 `1`/`2`/`3`/`4`。输入不区分大小写。

## 3. 交互菜单

无参 `ml mode` 时,仿照现有 `set_iptype()`(`install.sh:613`)的风格:

```
=======================================================
               路由模式切换
=======================================================
当前: 自动选优 (可用性失效自动切换)
  [1] auto          自动选优 (失效自动切换)
  [2] fixed_ip      固定节点 (锁定不切换)
  [3] fixed_region  固定地区 (只连指定国家)
  [4] favorites     收藏优先 (只连收藏节点)
=======================================================
请输入要切换到的【序号 1-4】或模式名(直接回车取消):
```

"当前:" 一行复用 `routing_mode_label()` 的带色完整标签。直接回车 / EOF / Ctrl+C → 打印"已取消"并返回(与 `set_iptype` 一致)。

## 4. 各模式行为

写配置时所有分支统一:`connection_enabled = True`、`pop("fixed_node_id", None)`(切到非固定模式时清理上次 `ml fix` 残留,与 `auto_mode()` 一致;`fixed_ip` 分支由 `fix_node` 自行写入 `fixed_node_id`)、`save_ui_auth(cfg)` → `restart_service()` → 提示"可运行 ml current 查看状态"。若原 `connection_enabled` 为 False,额外提示"已重新启用连接"。

| 模式 | 实现 |
|------|------|
| `auto` | 直接调用现有 `auto_mode()`(`install.sh:531`),不重复实现 |
| `fixed_ip` | 直接调用现有 `fix_node(selector)`(`install.sh:494`);无 selector 时其自带"列节点 + 输入序号/ID"交互 |
| `fixed_region` | 新辅助 `_set_fixed_region(country=None)`,见 §5 |
| `favorites` | 新辅助 `_set_favorites()`,见 §6 |

## 5. `fixed_region` 行为与国家输入解析

1. `nodes = sorted_nodes()`;为空 → 提示"当前无节点缓存,请先运行 'ml refresh' 拉取节点",返回。
2. 从节点收集去重国家:键为 `n.get("country")`(后端已存中文名,见 `vpngate_manager.py:729` 的 `country_zh`),值为节点数。按国家名排序展示编号列表(含节点数),风格同 `populateRoutingCountries`(Web 端)。
3. `country` 参数为空(交互态)→ 列出编号列表并提示"输入【序号】或国家名/两位代码(直接回车取消)"。
4. 解析用户输入 `sel`:
   - 纯数字且在范围内 → 取对应列表项的中文国家名;
   - 否则在 `nodes` 中匹配 `country`(中文,忽略大小写)**或** `country_short`(如 `JP`,忽略大小写)→ 取该节点的规范中文 `country`;
   - 均不匹配 → 打印"无效国家"并重新列出可选国家,返回。
5. 写 `routing_mode = "fixed_region"`、`force_country = <规范中文名>`,按 §4 通用流程保存并重启。
6. 提示示例:`已切换到「固定地区: 日本」(该国家缓存中有 N 个节点)`。

**为何存中文名:** 后端筛选 `_select_available_candidates`(`vpngate_manager.py:1401-1406`)按 `n.country == force_country` 或其翻译匹配;节点 `country` 字段本就是中文名,故存中文名可被直接命中,无需在 CLI 引入翻译表。接受 `country_short` 仅为输入便利,落库时一律换算为规范中文名。

## 6. `favorites` 行为(空收藏处理)

1. `cfg = load_ui_auth()`;`fav_ids = cfg.get("favorite_node_ids", [])`。
2. `fav_ids` 为空 → **拒绝切换**,提示:"当前没有任何收藏节点,无法启用收藏优先模式。请先在 Web 面板收藏节点后再试(CLI 暂不管理收藏)。" 返回。
3. 非空 → 按 §4 通用流程写 `routing_mode = "favorites"` 并保存重启;提示含收藏节点数。

不改动 `fav_fail_fallback`(保持现状,仍由 Web 面板管理)。

## 7. 拉取行为约束(关键)

**本命令所有分支只 `restart_service()`,绝不写 `force_refresh.flag`。**

依据后端 `collector_loop`(`vpngate_manager.py:1859`):重启首轮在"无活动连接且无强制刷新标记"时走 `maintain_valid_nodes(prefer_cached=True)`,按**新的** `ui_cfg`(含新 `routing_mode`/`force_country`)筛选缓存可用节点,有可用即直连、跳过拉取;仅当新模式下无可用缓存节点时才拉取补齐。

因此"切换模式后有可用节点就不重新拉取"由后端既定语义自动满足,新命令无需任何拉取相关代码——只要不写强制刷新标记即可(与 `auto_mode`/`fix_node` 一致)。`ml refresh` 仍是唯一显式强制拉取入口。

## 8. 集成改动点(均在 `install.sh`)

1. 新增常量:`ROUTING_MODE_ORDER = ["auto", "fixed_ip", "fixed_region", "favorites"]` 与菜单标签/别名映射(供菜单展示与输入归一化)。
2. 新增 `set_routing_mode(value=None, arg=None)` 主函数 + 辅助 `_set_fixed_region(country=None)`、`_set_favorites()`。
3. `main()` 命令分发(`install.sh:1389` 附近)新增:
   `elif cmd == "mode": set_routing_mode(sys.argv[2] if len(sys.argv) > 2 else None, sys.argv[3] if len(sys.argv) > 3 else None)`
4. 交互主菜单 `options`(`install.sh:1395`)新增 `'m': ("路由模式切换 (ml mode)", set_routing_mode)`,并把 `'m'` 加入 `node_keys`。
5. 未知命令提示串(`install.sh:1392`)补上 `mode`。

## 9. 不做的事(YAGNI)

- 不改动 `routing_ip_type`、`fav_fail_fallback`(各由 `ml iptype`、Web 面板管理)。
- 不在 CLI 增删收藏节点(收藏仍由 Web 面板管理)。
- 不为 `ml mode` 增加强制拉取选项(`ml refresh` 已覆盖)。
- 不重写 `auto_mode`/`fix_node`,直接复用。

## 10. 边界与错误处理

- 无节点缓存:`fixed_ip`(经 `fix_node`)与 `fixed_region` 均提示先 `ml refresh`。
- 写配置失败:沿用现有 `try/except` + "写入配置失败: {e}" 模式。
- 交互取消(回车/EOF/Ctrl+C):统一打印"已取消"。
- 无效模式名:打印可用模式列表(全名 + 别名)。

## 11. 验证方式

- 不依赖真机/root 服务运行验证。
- 提取 `install.sh` 内嵌 Python 段做 `py_compile` 语法校验,或对改动函数做等价语法检查。
- 对各分支(含别名归一化、编号解析、国家解析、空收藏拒绝、`force_country` 落库值)做逻辑走查,核对与后端筛选口径(`_select_available_candidates`)一致。
- 无法静态确认的运行时行为(restart 后实际复用/拉取)明确标注为"未真机验证",仅以代码逻辑推理说明。
