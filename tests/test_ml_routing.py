import importlib.util
import io
import os
import tempfile
import unittest
from unittest import mock

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
    try:
        spec.loader.exec_module(mod)
    finally:
        os.unlink(tmp.name)
    return mod


class TestNormalizeRoutingMode(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ml = load_ml_module()

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


class TestCountryResolve(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ml = load_ml_module()

    def setUp(self):
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


class TestBestNodeSelection(unittest.TestCase):
    def setUp(self):
        self.ml = load_ml_module()

    def test_best_node_skips_backoff_nodes(self):
        nodes = [
            {
                "id": "node-a",
                "probe_status": "available",
                "latency_ms": 1,
                "score": 100,
                "unavailable_until": 9999999999,
            },
            {
                "id": "node-b",
                "probe_status": "available",
                "latency_ms": 50,
                "score": 1,
            },
        ]
        with mock.patch.object(self.ml, "load_nodes", return_value=nodes):
            self.assertEqual(self.ml.best_node()["id"], "node-b")


class TestExitInfoDisplay(unittest.TestCase):
    def setUp(self):
        self.ml = load_ml_module()

    def test_current_shows_ippure_exit_info(self):
        state = {
            "active_openvpn_node_id": "node-1",
            "active_node_latency": "80 ms",
            "is_connecting": False,
            "proxy_ok": True,
            "proxy_ip": "198.51.100.8",
            "proxy_latency_ms": 18,
        }
        info = {
            "asn": 64500,
            "asOrganization": "Example ASN",
            "country": "Japan",
            "isResidential": True,
            "isBroadcast": False,
            "fraudScore": 12,
        }
        with (
            mock.patch.object(self.ml, "load_state", return_value=state),
            mock.patch.object(self.ml, "load_ui_auth", return_value={
                "proxy_port": 12345,
                "routing_mode": "auto",
                "connection_enabled": True,
                "routing_ip_type": "all",
            }),
            mock.patch.object(self.ml, "get_active_node_info", return_value=("203.0.113.7", "日本")),
            mock.patch.object(self.ml, "query_exit_info", return_value=info) as query_exit_info,
            mock.patch("sys.stdout", new=io.StringIO()) as stdout,
        ):
            self.ml.show_current()

        query_exit_info.assert_called_once_with(12345)
        output = stdout.getvalue()
        self.assertIn("出口归属 (ASN)", output)
        self.assertIn("AS64500 Example ASN", output)
        self.assertIn("出口国家", output)
        self.assertIn("Japan", output)
        self.assertIn("IP 类型", output)
        self.assertIn("住宅IP", output)
        self.assertIn("欺诈评分", output)
        self.assertIn("12 [良好]", output)

    def test_status_does_not_query_ippure_exit_info(self):
        state = {
            "active_openvpn_node_id": "node-1",
            "active_node_latency": "80 ms",
            "is_connecting": False,
            "proxy_ok": True,
            "proxy_ip": "198.51.100.8",
            "proxy_latency_ms": 18,
        }
        with (
            mock.patch.object(self.ml, "load_ui_cfg", return_value={
                "host": "127.0.0.1",
                "port": 8787,
                "secret_path": "secret",
                "username": "admin",
                "password": "password",
                "proxy_port": 12345,
            }),
            mock.patch.object(self.ml, "load_ui_auth", return_value={
                "routing_mode": "auto",
                "routing_ip_type": "all",
            }),
            mock.patch.object(self.ml, "load_state", return_value=state),
            mock.patch.object(self.ml, "get_active_node_info", return_value=("203.0.113.7", "日本")),
            mock.patch.object(self.ml, "check_port_listening", return_value=True),
            mock.patch.object(self.ml, "check_service_active", return_value=True),
            mock.patch.object(self.ml, "check_openvpn_process", return_value=True),
            mock.patch.object(self.ml, "get_service_pid", return_value=1234),
            mock.patch.object(self.ml, "query_exit_info") as query_exit_info,
            mock.patch("sys.stdout", new=io.StringIO()) as stdout,
        ):
            self.ml.print_status()

        query_exit_info.assert_not_called()
        output = stdout.getvalue()
        self.assertIn("出口 IP (出站)", output)
        self.assertNotIn("出口归属 (ASN)", output)
        self.assertNotIn("欺诈评分", output)


if __name__ == "__main__":
    unittest.main()
