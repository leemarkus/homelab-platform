#!/usr/bin/env python3
"""Offline regression test of the actual template against storage fixtures."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "scripts/fixtures/longhorn-multipath"
template = (ROOT / "ansible/roles/k3s_node/templates/multipath.conf.j2").read_text()
# Parse the hierarchy before interpreting any selector. Tokenization preserves
# quoted regexes; braces inside quotes cannot change the section structure.
tokens = re.findall(r'"[^"\\]*(?:\\.[^"\\]*)*"|[{}]|[^\s{}"#]+|#[^\n]*', template)
tokens = [token for token in tokens if not token.startswith("#")]


def parse_block(index=0, nested=False):
    entries = []
    while index < len(tokens):
        key = tokens[index]
        if key == "}":
            assert nested, "Unexpected closing brace"
            return entries, index + 1
        assert key != "{" and not key.startswith('"'), "Expected section or selector"
        index += 1
        assert index < len(tokens), f"Missing value for {key}"
        if tokens[index] == "{":
            value, index = parse_block(index + 1, nested=True)
        else:
            value = tokens[index]
            assert value.startswith('"') and value.endswith('"'), f"Expected quoted value for {key}"
            index += 1
        entries.append((key, value))
    assert not nested, "Unclosed block"
    return entries, index


sections, _ = parse_block()
assert len(sections) == 1 and sections[0][0] == "blacklist", "Expected single top-level blacklist section"
devices = sections[0][1]
assert isinstance(devices, list) and len(devices) == 1 and devices[0][0] == "device", "Expected exactly one device block in blacklist"
selectors = devices[0][1]
assert isinstance(selectors, list) and len(selectors) == 2 and {key for key, _ in selectors} == {"vendor", "product"}, "Expected vendor and product in the same device block"
assert all(isinstance(value, str) for _, value in selectors), "Selectors must be quoted values"
# These anchored expressions use syntax shared by Python and POSIX ERE.
patterns = {key: re.compile(value[1:-1]) for key, value in selectors}
print("PASS structure: single blacklist with one device containing vendor and product")


def excluded(vendor, product):
    return bool(patterns["vendor"].search(vendor) and patterns["product"].search(product))


for case, expected in (("worker-longhorn", {"sdc", "sdd"}), ("worker-ordinary", set())):
    disks = {}
    for line in (FIXTURES / f"{case}.lsblk").read_text().splitlines()[1:]:
        fields = line.split()
        if fields[1] == "disk":
            disks[fields[0]] = fields[2:4]
    matched = {name for name, identity in disks.items() if excluded(*identity)}
    assert matched == expected, (case, matched, expected)
    assert not excluded(*disks["sda"]), "OS disk must never be blacklisted"
    assert not excluded(*disks["sdb"]), "Replica disk must never be blacklisted"
    # Cross-check mapped path identities against lsblk; after exclusion no
    # fixture Longhorn map should remain a candidate for multipath claiming.
    maps = (FIXTURES / f"{case}.multipath").read_text()
    headers = re.findall(r"^mpath\w+ \([^\n]+\) dm-\d+ (\S+),(\S+)$", maps, re.M)
    paths = set(re.findall(r"\d+:\d+:\d+:\d+ (sd\w+) \d+:\d+", maps))
    assert paths == expected, (case, paths)
    assert len(headers) == len(expected)
    assert all(excluded(*identity) for identity in headers)
    print(f"PASS {case}: excluded={','.join(sorted(matched)) or 'none'}; OS sda and data sdb preserved")

for identity in (("QEMU", "QEMU_HARDDISK"), ("IET", "OTHER"),
                 ("OTHER", "VIRTUAL-DISK"), ("IET-extra", "VIRTUAL-DISK"),
                 ("IET", "VIRTUAL-DISK-extra"), ("", "")):
    assert not excluded(*identity), identity
assert excluded("IET", "VIRTUAL-DISK")
# No devnode rule: swapping sda/sdc names leaves the OS vendor/product excluded
# from the blacklist and the Longhorn identity matched.
assert not excluded("QEMU", "QEMU_HARDDISK") and excluded("IET", "VIRTUAL-DISK")
print("PASS exact vendor AND product, near misses, and device-rename independence")
print("PASS all fixture checks (2 Longhorn devices; 4 ordinary disks protected)")
