#!/usr/bin/env python3
"""Offline rebuild-version contract; no Ansible or host access."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
ROLE = ROOT / "ansible/roles/k3s_node"
# Recorded cluster evidence, 2026-10-02T18:34Z: all six production nodes.
# Update this contract with recorded cluster evidence when the pin changes.
RECORDED_CLUSTER_VERSION = "v1.34.9+k3s1"


class RebuildVersionTest(unittest.TestCase):
    def test_rebuild_matches_recorded_cluster_version(self):
        defaults = (ROLE / "defaults/main.yml").read_text()
        pins = re.findall(r"^k3s_version:\s*(\S+)\s*$", defaults, re.MULTILINE)
        self.assertEqual(pins, [RECORDED_CLUSTER_VERSION],
                         "Rebuild pin must match the recorded snapshot-producing cluster")

    def test_installer_uses_role_pin(self):
        tasks = (ROLE / "tasks/main.yml").read_text()
        versions = re.findall(r"^\s+INSTALL_K3S_VERSION:\s*(.+)$", tasks, re.MULTILINE)
        self.assertEqual(versions, ['"{{ k3s_version }}"'])


if __name__ == "__main__":
    unittest.main(verbosity=2)
