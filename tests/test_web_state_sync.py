import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


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


if __name__ == "__main__":
    unittest.main()
