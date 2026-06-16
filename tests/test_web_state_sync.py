import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO = Path(__file__).resolve().parents[1]


def load_manager(data_dir: Path):
    old_data_dir = os.environ.get("VPNGATE_DATA_DIR")
    os.environ["VPNGATE_DATA_DIR"] = str(data_dir)
    sys.path.insert(0, str(REPO))
    try:
        spec = importlib.util.spec_from_file_location(
            f"vpngate_manager_test_{id(data_dir)}",
            REPO / "vpngate_manager.py",
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        try:
            sys.path.remove(str(REPO))
        except ValueError:
            pass
        if old_data_dir is None:
            os.environ.pop("VPNGATE_DATA_DIR", None)
        else:
            os.environ["VPNGATE_DATA_DIR"] = old_data_dir


def write_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


class TestWebStateSync(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.data_dir = Path(self.tmp.name)
        self.manager = load_manager(self.data_dir)
        self.manager.active_openvpn_node_id = ""
        self.manager.is_connecting = False

    def tearDown(self):
        self.tmp.cleanup()

    def test_get_state_keeps_runtime_active_node_id(self):
        write_json(self.manager.NODES_FILE, [{"id": "node-a"}])
        write_json(self.manager.STATE_FILE, {"active_openvpn_node_id": ""})

        self.manager.active_openvpn_node_id = "node-a"

        state = self.manager.get_state()

        self.assertEqual(state["active_openvpn_node_id"], "node-a")

    def test_get_state_uses_persisted_active_node_id_when_memory_is_empty(self):
        write_json(self.manager.NODES_FILE, [{"id": "node-a"}])
        write_json(self.manager.STATE_FILE, {"active_openvpn_node_id": "node-a"})

        state = self.manager.get_state()

        self.assertEqual(state["active_openvpn_node_id"], "node-a")

    def test_get_state_falls_back_to_active_node_flag(self):
        write_json(
            self.manager.NODES_FILE,
            [{"id": "node-a", "active": False}, {"id": "node-b", "active": True}],
        )
        write_json(self.manager.STATE_FILE, {"active_openvpn_node_id": ""})

        state = self.manager.get_state()

        self.assertEqual(state["active_openvpn_node_id"], "node-b")

    def test_get_state_ignores_stale_persisted_id_not_in_nodes(self):
        write_json(self.manager.NODES_FILE, [{"id": "node-b", "active": True}])
        write_json(self.manager.STATE_FILE, {"active_openvpn_node_id": "missing-node"})

        state = self.manager.get_state()

        self.assertEqual(state["active_openvpn_node_id"], "node-b")

    def test_available_node_for_auto_route(self):
        nodes = [{"id": "node-a", "probe_status": "available", "active": False}]
        ui_cfg = {"routing_mode": "auto", "routing_ip_type": "all"}

        self.assertTrue(self.manager._has_available_node_for_current_route(nodes, ui_cfg))

    def test_available_node_for_fixed_ip_requires_fixed_node(self):
        nodes = [
            {"id": "node-a", "probe_status": "available", "active": False},
            {"id": "node-b", "probe_status": "unavailable", "active": False},
        ]

        self.assertTrue(self.manager._has_available_node_for_current_route(
            nodes,
            {"routing_mode": "fixed_ip", "fixed_node_id": "node-a"},
        ))
        self.assertFalse(self.manager._has_available_node_for_current_route(
            nodes,
            {"routing_mode": "fixed_ip", "fixed_node_id": "node-b"},
        ))

    def test_available_node_for_route_respects_ip_type_filter(self):
        nodes = [{"id": "node-a", "probe_status": "available", "ip_type": "hosting", "active": False}]

        self.assertFalse(self.manager._has_available_node_for_current_route(
            nodes,
            {"routing_mode": "auto", "routing_ip_type": "residential"},
        ))

    def test_available_candidates_skip_backoff_nodes(self):
        nodes = [
            {
                "id": "node-a",
                "probe_status": "available",
                "latency_ms": 1,
                "unavailable_until": 9999999999,
                "active": False,
            },
            {
                "id": "node-b",
                "probe_status": "available",
                "latency_ms": 50,
                "active": False,
            },
        ]

        candidates = self.manager._select_available_candidates(
            nodes,
            {"routing_mode": "auto", "routing_ip_type": "all"},
        )

        self.assertEqual([n["id"] for n in candidates], ["node-b"])

    def test_fixed_ip_availability_skips_backoff_node(self):
        nodes = [
            {
                "id": "node-a",
                "probe_status": "available",
                "unavailable_until": 9999999999,
                "active": False,
            }
        ]

        self.assertFalse(self.manager._has_available_node_for_current_route(
            nodes,
            {"routing_mode": "fixed_ip", "fixed_node_id": "node-a"},
        ))

    def test_mark_node_unavailable_sets_backoff(self):
        node = {"id": "node-a", "ip": "203.0.113.1"}

        self.manager.mark_node_unavailable(node, "connect timeout")

        self.assertEqual(node["probe_status"], "unavailable")
        self.assertEqual(node["probe_message"], "connect timeout")
        self.assertTrue(node["last_failed_at"] > 0)
        self.assertTrue(node["unavailable_until"] > node["last_failed_at"])
        self.assertTrue(self.manager.node_in_backoff(node))

    def test_clear_node_backoff_resets_backoff_fields(self):
        node = {"id": "node-a", "last_failed_at": 123, "unavailable_until": 9999999999}

        self.manager.clear_node_backoff(node)

        self.assertEqual(node["last_failed_at"], 0)
        self.assertEqual(node["unavailable_until"], 0)
        self.assertFalse(self.manager.node_in_backoff(node))

    def test_clear_node_backoff_removes_persistent_blacklist_entry(self):
        node = {"id": "node-a", "ip": "203.0.113.1"}
        self.manager.mark_node_unavailable(node, "connect timeout")

        self.assertIn("node-a", self.manager.load_blacklist())

        self.manager.clear_node_backoff(node)

        self.assertNotIn("node-a", self.manager.load_blacklist())

    def test_fixed_ip_backoff_skips_refresh_and_keeps_cached_node(self):
        node = {
            "id": "node-a",
            "probe_status": "unavailable",
            "last_failed_at": 123,
            "unavailable_until": 9999999999,
        }
        write_json(self.manager.NODES_FILE, [node])

        with mock.patch.object(
            self.manager,
            "load_ui_config",
            return_value={
                "routing_mode": "fixed_ip",
                "fixed_node_id": "node-a",
                "connection_enabled": True,
            },
        ), mock.patch.object(
            self.manager,
            "fetch_candidates",
            side_effect=AssertionError("退避中的固定节点不应触发节点拉取"),
        ):
            msg = self.manager.maintain_valid_nodes()

        self.assertIn("固定节点 node-a 正在失败退避期内", msg)
        self.assertEqual([n["id"] for n in self.manager.read_nodes()], ["node-a"])

    def test_fixed_ip_retry_failure_skips_refresh_and_keeps_cached_node(self):
        node = {
            "id": "node-a",
            "probe_status": "available",
            "last_failed_at": 0,
            "unavailable_until": 0,
        }
        write_json(self.manager.NODES_FILE, [node])

        with mock.patch.object(
            self.manager,
            "load_ui_config",
            return_value={
                "routing_mode": "fixed_ip",
                "fixed_node_id": "node-a",
                "connection_enabled": True,
            },
        ), mock.patch.object(
            self.manager,
            "connect_node",
            side_effect=RuntimeError("connect timeout"),
        ), mock.patch.object(
            self.manager,
            "fetch_candidates",
            side_effect=AssertionError("固定节点重连失败后不应触发节点拉取"),
        ):
            msg = self.manager.maintain_valid_nodes()

        self.assertIn("固定节点 node-a 重连失败", msg)
        self.assertEqual([n["id"] for n in self.manager.read_nodes()], ["node-a"])


if __name__ == "__main__":
    unittest.main()
