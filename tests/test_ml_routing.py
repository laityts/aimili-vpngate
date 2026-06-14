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


if __name__ == "__main__":
    unittest.main()
