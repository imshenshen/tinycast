#!/usr/bin/env python3
"""Exercise fork-sync against disposable repositories and a local upstream."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / ".claude/skills/fork-sync/scripts/fork_sync.py"


class ForkSyncTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="tinycast-fork-sync-")
        self.addCleanup(self.scratch.cleanup)
        root = Path(self.scratch.name)
        self.source = root / "source"
        self.remote = root / "upstream.git"
        self.fork = root / "fork"
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.source.mkdir()
        self.git(self.source, "init", "-b", "main")
        self.configure(self.source)
        self.base = self.commit(self.source, "shared.txt", "base")
        self.git(root, "clone", "--bare", str(self.source), str(self.remote))
        self.git(root, "clone", str(self.remote), str(self.fork))
        self.configure(self.fork)
        self.git(self.fork, "remote", "rename", "origin", "upstream")
        self.script = self.fork / ".claude/skills/fork-sync/scripts/fork_sync.py"
        self.script.parent.mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.script)
        self.state_path = self.script.parent.parent / "state.json"
        self.write_state({
            "upstreamRemote": "upstream", "upstreamBranch": "main",
            "baseCommit": self.base, "baseTag": None,
            "lastCheck": None, "lastCheckedUpstream": None,
            "pending": [], "ported": [], "dropped": [],
        })

    def git(self, directory, *args):
        return subprocess.run(
            ["git", "-C", str(directory), *args], env=self.env,
            text=True, capture_output=True, check=True,
        ).stdout.strip()

    def configure(self, directory):
        self.git(directory, "config", "user.name", "Fork Sync Test")
        self.git(directory, "config", "user.email", "fork-sync@example.invalid")
        self.git(directory, "config", "commit.gpgsign", "false")
        self.git(directory, "config", "core.hooksPath", os.devnull)

    def commit(self, directory, filename, content):
        (directory / filename).write_text(content)
        self.git(directory, "add", filename)
        self.git(directory, "commit", "-m", content)
        return self.git(directory, "rev-parse", "HEAD")

    def advance(self, label):
        sha = self.commit(self.source, "shared.txt", label)
        self.git(self.source, "push", str(self.remote), "main")
        return sha

    def cli(self, *args, succeeds=True):
        result = subprocess.run(
            [sys.executable, "-I", str(self.script), *args], cwd=self.fork,
            env=self.env, text=True, capture_output=True,
        )
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result.stdout + result.stderr

    def state(self):
        return json.loads(self.state_path.read_text())

    def write_state(self, state):
        self.state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")

    def apply_first(self):
        first = self.advance("first update")
        self.cli("check")
        local = self.commit(self.fork, "shared.txt", "fork adaptation")
        self.cli(
            "mark-applied", first[:10], "non-AI subset", "--commit", local,
            "--validation", "build passed; baseline tests remain",
        )
        return first, local

    def test_incremental_checks_keep_applied_records_and_refresh_overlap(self):
        first, local = self.apply_first()
        original = self.state()["pending"][0]
        second = self.advance("second update")
        output = self.cli("check")
        state = self.state()
        self.assertIn(f"扫描起点  : {first}", output)
        self.assertIn(f"下次增量  : {second}", output)
        self.assertEqual(state["baseCommit"], self.base)
        self.assertEqual(state["lastCheckedUpstream"], second)
        self.assertEqual([e["sha"] for e in state["pending"]], [first, second])
        applied = state["pending"][0]
        self.assertEqual(applied["implementation"], original["implementation"])
        self.assertEqual(applied["implementation"]["localCommit"], local)
        self.assertEqual(applied["firstSeen"], original["firstSeen"])
        self.assertEqual(applied["overlap"], ["shared.txt"])
        self.cli("check")
        self.assertEqual(self.state()["pending"], state["pending"])

    def test_status_is_read_only_and_separates_selection_from_validation(self):
        first, local = self.apply_first()
        second = self.advance("second update")
        self.cli("check")
        before = self.state_path.read_bytes()
        self.git(self.fork, "remote", "set-url", "upstream", str(self.remote / "missing"))
        output = self.cli("status")
        self.assertEqual(before, self.state_path.read_bytes())
        candidates, applied = output.split("--- 已实施、待验证（不要重复移植）---")
        self.assertIn("待选择      : 1", output)
        self.assertIn("已实施待验证: 1", output)
        self.assertIn(second[:7], candidates)
        self.assertNotIn(first[:7], candidates)
        self.assertIn(first[:7], applied)
        self.assertIn(local, applied)
        self.assertIn("non-AI subset", applied)
        self.assertIn("baseline tests remain", applied)

    def test_missing_or_diverged_checkpoint_preserves_implementation(self):
        first, local = self.apply_first()
        original = self.state()
        for checkpoint in ["f" * 40, local]:
            with self.subTest(checkpoint=checkpoint):
                state = json.loads(json.dumps(original))
                state["lastCheckedUpstream"] = checkpoint
                self.write_state(state)
                output = self.cli("check")
                pending = self.state()["pending"]
                self.assertIn(f"扫描起点  : {self.base}", output)
                self.assertEqual(len(pending), 1)
                self.assertEqual(pending[0]["sha"], first)
                self.assertEqual(pending[0]["implementation"], original["pending"][0]["implementation"])
                self.assertEqual(pending[0]["firstSeen"], original["pending"][0]["firstSeen"])

    def test_mark_applied_updates_notes_without_losing_validation_details(self):
        first, _ = self.apply_first()
        state = self.state()
        state["pending"][0]["implementation"]["validation"]["focused"] = "passed"
        self.write_state(state)
        applied_at = state["pending"][0]["implementation"]["appliedAt"]
        self.cli("mark-applied", first, "updated scope", "--validation", "new result")
        implementation = self.state()["pending"][0]["implementation"]
        self.assertEqual(implementation["appliedAt"], applied_at)
        self.assertEqual(implementation["note"], "updated scope")
        self.assertEqual(implementation["validation"], {"focused": "passed", "summary": "new result"})
        before = self.state_path.read_bytes()
        self.cli("mark-applied", first, "bad", "--commit", "missing", "--validation", "bad", succeeds=False)
        self.assertEqual(before, self.state_path.read_bytes())

    def test_rescan_keeps_verified_and_dropped_commits_out_of_pending(self):
        first, _ = self.apply_first()
        second = self.advance("second update")
        self.cli("check")
        self.cli("mark-ported", first, "validated subset")
        self.cli("drop", second, "not selected")
        state = self.state()
        self.assertEqual(state["ported"][0]["implementation"]["status"], "validated")
        self.assertEqual(state["ported"][0]["implementation"]["note"], "non-AI subset")
        state["lastCheckedUpstream"] = "f" * 40
        self.write_state(state)
        self.cli("check")
        self.assertEqual(self.state()["pending"], [])
        self.assertEqual(self.state()["ported"], state["ported"])
        self.assertEqual(self.state()["dropped"], state["dropped"])

    def test_unrelated_upstream_refuses_to_advance_checkpoint(self):
        self.apply_first()
        before = self.state_path.read_bytes()
        self.git(self.source, "checkout", "--orphan", "unrelated")
        self.commit(self.source, "shared.txt", "unrelated history")
        self.git(self.source, "push", "--force", str(self.remote), "HEAD:main")
        self.cli("check", succeeds=False)
        self.assertEqual(before, self.state_path.read_bytes())


if __name__ == "__main__":
    unittest.main(verbosity=2)
