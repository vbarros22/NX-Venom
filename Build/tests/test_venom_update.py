"""Offline tests for Build/venom_update.py. Run with `make test`."""

import contextlib
import io
import json
import sys
import tempfile
import unittest
import urllib.request
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import venom_update as vu  # noqa: E402


class YamlParserTests(unittest.TestCase):
  def parse(self, text):
    return vu.parse_yaml(text, Path("test.yaml"))

  def test_trailing_comment_does_not_leak_into_value(self):
    data = self.parse("enabled: false # disabled for now\nrelease: latest  # pin later\n")
    self.assertIs(data["enabled"], False)
    self.assertEqual(data["release"], "latest")

  def test_hash_inside_quotes_or_words_is_kept(self):
    data = self.parse('a: "x # y"\nb: \'p # q\'\nc: C#sharp\n')
    self.assertEqual(data, {"a": "x # y", "b": "p # q", "c": "C#sharp"})

  def test_comment_only_lines_inside_blocks(self):
    data = self.parse("install:\n  # note\n  mappings:\n    - from: a  # src\n      to: b\n")
    self.assertEqual(data, {"install": {"mappings": [{"from": "a", "to": "b"}]}})

  def test_flow_lists(self):
    data = self.parse('aliases: [ams, "a, b", 3]\nempty: []\n')
    self.assertEqual(data["aliases"], ["ams", "a, b", 3])
    self.assertEqual(data["empty"], [])

  def test_all_repository_manifests_load(self):
    manifests = vu.load_manifests()
    self.assertTrue(manifests)
    for manifest in manifests:
      self.assertIsInstance(manifest.get("enabled", True), bool, manifest["name"])
      self.assertTrue(manifest["install"]["mappings"], manifest["name"])


class TokenScopeTests(unittest.TestCase):
  def test_token_only_sent_to_api(self):
    with mock.patch.object(vu, "github_token", return_value="secret"):
      self.assertIn("Authorization", vu.github_headers("https://api.github.com/repos/a/b/releases/latest"))
      self.assertNotIn("Authorization", vu.github_headers("https://github.com/a/b/releases/download/v1/x.zip"))

  def redirect(self, source, target):
    request = urllib.request.Request(source, headers={"Authorization": "Bearer secret"})
    return vu.StripAuthOnRedirect().redirect_request(request, None, 302, "Found", {}, target)

  def test_authorization_dropped_on_cross_host_redirect(self):
    new_request = self.redirect("https://api.github.com/x", "https://objects.githubusercontent.com/y")
    self.assertFalse(new_request.has_header("Authorization"))

  def test_authorization_kept_on_same_host_redirect(self):
    new_request = self.redirect("https://api.github.com/x", "https://api.github.com/y")
    self.assertTrue(new_request.has_header("Authorization"))


class SandboxTestCase(unittest.TestCase):
  """Points the updater at a throwaway repository root with fake components."""

  def setUp(self):
    self.tmp = Path(tempfile.mkdtemp())
    self.root = self.tmp / "repo"
    (self.root / "Build" / "components").mkdir(parents=True)
    (self.root / "Sources" / "NXVenom").mkdir(parents=True)
    self.assets = self.tmp / "assets"
    self.assets.mkdir()
    build = self.root / "Build"
    patches = {
      "ROOT_DIR": self.root,
      "COMPONENTS_DIR": build / "components",
      "STATE_PATH": build / "state.json",
      "CACHE_DIR": build / "cache",
      "WORK_DIR": build / "work",
      "API_CACHE_DIR": build / "cache" / "github-api",
    }
    for name, value in patches.items():
      patcher = mock.patch.object(vu, name, value)
      patcher.start()
      self.addCleanup(patcher.stop)
    self.failing = set()
    for name, fake in (("resolve_component", self.fake_resolve), ("download_asset", self.fake_download)):
      patcher = mock.patch.object(vu, name, side_effect=fake)
      patcher.start()
      self.addCleanup(patcher.stop)

  def tearDown(self):
    import shutil
    shutil.rmtree(self.tmp, ignore_errors=True)

  def add_component(self, name, destination, content="new"):
    (self.assets / f"{name}.bin").write_text(content)
    (self.root / "Build" / "components" / f"{name}.yaml").write_text(
      f'name: "{name}"\n'
      'category: "Core"\n'
      'source:\n'
      '  type: "github-release"\n'
      f'  repo: "test/{name}"\n'
      'assets:\n'
      f'  - pattern: "{name}.bin"\n'
      '    type: "file"\n'
      'install:\n'
      '  mappings:\n'
      f'    - asset: "{name}.bin"\n'
      f'      from: "{name}.bin"\n'
      f'      to: "{destination}"\n'
    )

  def fake_resolve(self, component):
    name = component["name"]
    if name in self.failing:
      vu.fail(f"simulated network failure for {name}")
    return {
      "component": component, "name": name, "repo": f"test/{name}",
      "source_type": "github-release", "version": "v2", "revision": "r2",
      "html_url": None,
      "assets": [{"name": f"{name}.bin", "pattern": f"{name}.bin", "url": "", "size": None, "type": "file"}],
    }

  def fake_download(self, component_name, target, asset):
    return self.assets / asset["name"], "cached"

  def run_cli(self, *argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
      code = vu.main(list(argv))
    return code, out.getvalue(), err.getvalue()

  def state(self):
    path = self.root / "Build" / "state.json"
    return json.loads(path.read_text()) if path.exists() else None


class AtomicUpdateTests(SandboxTestCase):
  def test_successful_update_applies_all_and_records_state(self):
    self.add_component("alpha", "Sources/NXVenom/alpha.bin")
    self.add_component("beta", "Sources/NXVenom/beta.bin")
    code, _, err = self.run_cli("update")
    self.assertEqual(code, 0, err)
    self.assertEqual((self.root / "Sources/NXVenom/alpha.bin").read_text(), "new")
    self.assertEqual(set(self.state()["components"]), {"alpha", "beta"})

  def test_protected_path_aborts_before_any_write(self):
    self.add_component("alpha", "Sources/NXVenom/alpha.bin")
    self.add_component("zeta", "Sources/NXVenom/atmosphere/config/system_settings.ini")
    code, _, err = self.run_cli("update")
    self.assertEqual(code, 1)
    self.assertIn("nothing was changed", err)
    self.assertFalse((self.root / "Sources/NXVenom/alpha.bin").exists())
    self.assertIsNone(self.state())

  def test_failure_in_later_component_aborts_before_any_write(self):
    self.add_component("alpha", "Sources/NXVenom/alpha.bin")
    self.add_component("zeta", "Sources/NXVenom/zeta.bin")
    self.failing.add("zeta")
    code, _, err = self.run_cli("update")
    self.assertEqual(code, 1)
    self.assertIn("zeta", err)
    self.assertFalse((self.root / "Sources/NXVenom/alpha.bin").exists())
    self.assertIsNone(self.state())

  def test_dry_run_writes_nothing(self):
    self.add_component("alpha", "Sources/NXVenom/alpha.bin")
    code, out, err = self.run_cli("update", "--dry-run")
    self.assertEqual(code, 0, err)
    self.assertIn("No files changed", out)
    self.assertFalse((self.root / "Sources/NXVenom/alpha.bin").exists())
    self.assertIsNone(self.state())


class CheckIsolationTests(SandboxTestCase):
  def test_one_failing_component_does_not_hide_the_others(self):
    self.add_component("alpha", "Sources/NXVenom/alpha.bin")
    self.add_component("zeta", "Sources/NXVenom/zeta.bin")
    self.failing.add("alpha")
    code, out, _ = self.run_cli("check")
    self.assertEqual(code, 1)
    self.assertIn("ERROR", out)
    self.assertIn("simulated network failure for alpha", out)
    zeta_row = next(line for line in out.splitlines() if line.strip().startswith("zeta"))
    self.assertIn("UPDATE", zeta_row)


if __name__ == "__main__":
  unittest.main()
