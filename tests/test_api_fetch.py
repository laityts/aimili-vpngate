import socket
import unittest
from unittest import mock

import vpngate_manager


class TimeoutResponse:
    def __init__(self, chunks):
        self.chunks = list(chunks)

    def read(self, _size):
        if self.chunks:
            return self.chunks.pop(0)
        raise socket.timeout("timed out")


class TestApiFetch(unittest.TestCase):
    def test_partial_response_is_returned_on_timeout(self):
        response = TimeoutResponse([b"*vpn_servers\n", b"#HostName,IP\nvpn1,1.1.1.1\n"])

        with mock.patch.object(vpngate_manager, "log_to_json"), mock.patch("builtins.print"):
            text = vpngate_manager.read_api_response_text(response, "https://example.test/api")

        self.assertIn("*vpn_servers", text)
        self.assertIn("vpn1,1.1.1.1", text)

    def test_empty_timeout_is_raised(self):
        response = TimeoutResponse([])

        with self.assertRaises(socket.timeout):
            vpngate_manager.read_api_response_text(response, "https://example.test/api")


if __name__ == "__main__":
    unittest.main()
