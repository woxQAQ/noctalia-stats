"""Integration scenarios for the collector protocol and complete Luau entries."""

from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "stats"
COLLECTOR = PLUGIN / "bin/noctalia-stats-collector"


class PluginScenarios(unittest.TestCase):
    def test_manifest_catalog_and_languages_agree(self):
        manifest = tomllib.loads((PLUGIN / "plugin.toml").read_text())
        catalog = tomllib.loads((ROOT / "catalog.toml").read_text())["plugin"][0]
        for key in ("id", "name", "version", "plugin_api"):
            self.assertEqual(manifest[key], catalog[key])
        en = json.loads((PLUGIN / "translations/en.json").read_text())
        zh = json.loads((PLUGIN / "translations/zh-Hans.json").read_text())
        self.assertEqual(set(en), set(zh))
        for kind in ("widget", "panel", "service"):
            for entry in manifest[kind]:
                self.assertTrue((PLUGIN / entry["entry"]).is_file())

    def test_complete_service_and_ui_lifecycle(self):
        luau = shutil.which("luau")
        self.assertIsNotNone(luau, "Run checks inside nix develop; Luau is required")
        translations = json.loads((PLUGIN / "translations/en.json").read_text())
        parts = ["SOURCES = {}", "TRANSLATIONS = {}", "STYLES = {}"]
        manifest = tomllib.loads((PLUGIN / "plugin.toml").read_text())
        for widget in manifest["widget"]:
            for setting in widget["setting"]:
                if setting["key"] in ("display", "capacity_display"):
                    name = widget["id"]
                    if name == "disk" and setting["key"] == "display": name = "disk_io"
                    choices = ",".join(json.dumps(option["value"]) for option in setting["options"])
                    parts.append(f'STYLES[{json.dumps(name)}] = {{{choices}}}')
        for path in PLUGIN.rglob("*.luau"):
            name = json.dumps(path.relative_to(PLUGIN).as_posix())
            parts.append(f"SOURCES[{name}] = [====[{path.read_text()}]====]")
        for key, value in translations.items():
            parts.append(f"TRANSLATIONS[{json.dumps(key)}] = {json.dumps(value, ensure_ascii=False)}")
        parts.append((ROOT / "tests/scenarios.luau").read_text())
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "scenario.luau"
            script.write_text("\n".join(parts))
            result = subprocess.run([luau, str(script)], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS:", result.stdout)

    def test_process_collector_protocol_with_procfs_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            pid = proc / "42"
            pid.mkdir()
            fields = ["0"] * 30
            fields[0] = "R"
            fields[11], fields[12], fields[19], fields[21] = "100", "25", "99999", "16"
            (pid / "stat").write_text("42 (worker ) 中文 name) " + " ".join(fields))
            (pid / "io").write_text("read_bytes: 4096\nwrite_bytes: 8192\n")
            (proc / "version").write_text("not a PID")
            (proc / "43").mkdir()  # A process that disappeared before stat was read.
            result = subprocess.run(
                [str(COLLECTOR), "processes", "--io", "--proc-root", str(proc)],
                capture_output=True, text=True, timeout=5, check=True,
            )
            snapshot = json.loads(result.stdout)
            self.assertEqual(snapshot["version"], 1)
            self.assertEqual(len(snapshot["processes"]), 1)
            row = snapshot["processes"][0]
            self.assertEqual(row["name"], "worker ) 中文 name")
            self.assertEqual(row["start"], "99999")
            self.assertEqual(row["cpuSeconds"], 125 / os.sysconf("SC_CLK_TCK"))
            self.assertEqual(row["rssBytes"], 16 * os.sysconf("SC_PAGE_SIZE"))
            self.assertEqual(row["readBytes"], 4096)
            self.assertEqual(row["writeBytes"], 8192)

    def test_network_collector_selects_one_usable_ipv6(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            (proc / "net").mkdir()
            (proc / "net/if_inet6").write_text(
                "20010db8000000000000000000000002 01 40 00 01 fixture0\n"
                "20010db8000000000000000000000001 01 40 00 80 fixture0\n"
                "20010db8000000000000000000000003 01 40 00 40 fixture0\n"
                "fe800000000000000000000000000001 01 40 20 80 fixture0\n"
            )
            result = subprocess.run([str(COLLECTOR), "network", "--proc-root", str(proc)],
                                    capture_output=True, text=True, check=True, timeout=5)
            data = json.loads(result.stdout)
            self.assertEqual(data["interfaces"]["fixture0"]["ipv6"], "2001:db8::1")

    def test_process_collector_live_protocol(self):
        result = subprocess.run(
            [str(COLLECTOR), "processes"],
            capture_output=True, text=True, timeout=10, check=True,
        )
        snapshot = json.loads(result.stdout)
        self.assertGreater(len(snapshot["processes"]), 0)
        self.assertGreater(snapshot["sampledAt"], 0)
        self.assertGreaterEqual(snapshot["scanMs"], 0)
        identities = {(row["pid"], row["start"]) for row in snapshot["processes"]}
        self.assertEqual(len(identities), len(snapshot["processes"]))
        for row in snapshot["processes"]:
            self.assertGreaterEqual(row["rssBytes"], 0)
            self.assertGreaterEqual(row["cpuSeconds"], 0)


if __name__ == "__main__":
    unittest.main()
