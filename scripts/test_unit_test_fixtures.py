import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

import unit_test_fixtures as fixtures


class FixtureReclamationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.container = Path(self.temporary.name)
        child = subprocess.Popen([sys.executable, "-I", "-c", "pass"])
        self.dead_pid = child.pid
        child.wait(timeout=10)
        self.run_id, self.root = self.make_run(self.dead_pid)
        self.other_id, self.other_root = self.make_run(self.dead_pid)
        self.support = self.container / "Library/Application Support/metadata.store"
        self.support.parent.mkdir(parents=True)
        self.support.write_bytes(b"user data")

    def make_run(self, pid):
        run_id = str(uuid.uuid4())
        root = self.container / "tmp/CornellNoteTestRuns" / run_id
        root.mkdir(parents=True)
        (root / "owner.json").write_text(json.dumps({"schema": 1, "runID": run_id, "hostPID": pid}))
        database = root / "CornellNoteTests-fixture/generations/store/metadata.store"
        database.parent.mkdir(parents=True)
        database.write_bytes(b"fixture database")
        return run_id, root

    def test_finished_host_cleanup_removes_only_selected_run(self):
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "")):
            fixtures.cleanup_run(self.container, self.run_id)
        self.assertFalse(self.root.exists())
        self.assertEqual((self.other_root / "CornellNoteTests-fixture/generations/store/metadata.store").read_bytes(), b"fixture database")
        self.assertEqual(self.support.read_bytes(), b"user data")

    def test_live_host_is_refused_before_file_inspection_or_deletion(self):
        run_id, root = self.make_run(os.getpid())
        with patch.object(subprocess, "run") as inspect:
            with self.assertRaises(RuntimeError):
                fixtures.cleanup_run(self.container, run_id)
            inspect.assert_not_called()
        self.assertTrue(root.exists())

    def test_open_files_or_uncertain_lsof_result_preserve_run(self):
        for result in [
            subprocess.CompletedProcess([], 0, "open fixture handle", ""),
            subprocess.CompletedProcess([], 1, "", "inspection failed"),
            subprocess.CompletedProcess([], 2, "", ""),
        ]:
            with self.subTest(result=result), patch.object(subprocess, "run", return_value=result):
                with self.assertRaises(RuntimeError):
                    fixtures.cleanup_run(self.container, self.run_id)
                self.assertTrue(self.root.exists())

    def test_missing_or_invalid_owner_preserves_run(self):
        marker = self.root / "owner.json"
        for data in [None, "broken JSON", "{}", json.dumps({"schema": 1, "runID": self.other_id, "hostPID": self.dead_pid}), json.dumps({"schema": 1, "runID": self.run_id, "hostPID": -1})]:
            with self.subTest(data=data):
                if marker.exists():
                    marker.unlink()
                if data is not None:
                    marker.write_text(data)
                with self.assertRaises((RuntimeError, ValueError, FileNotFoundError)):
                    fixtures.cleanup_run(self.container, self.run_id)
                self.assertTrue(self.root.exists())

    def test_invalid_run_identifiers_cannot_select_other_paths(self):
        for run_id in ["../..", "", "../../Library/Application Support", self.run_id.upper()]:
            with self.subTest(run_id=run_id):
                with self.assertRaises(ValueError):
                    fixtures.run_root(self.container, run_id)
        self.assertTrue(self.root.exists())
        self.assertEqual(self.support.read_bytes(), b"user data")

    def test_symlinked_run_or_owner_is_refused(self):
        link_id = str(uuid.uuid4())
        link = self.root.parent / link_id
        link.symlink_to(self.other_root, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            fixtures.cleanup_run(self.container, link_id)
        marker = self.root / "owner.json"
        marker.unlink()
        marker.symlink_to(self.other_root / "owner.json")
        with self.assertRaises(RuntimeError):
            fixtures.cleanup_run(self.container, self.run_id)
        self.assertTrue(self.other_root.exists())

    def test_symlinked_runs_parent_is_refused(self):
        alias = self.container / "alias"
        (alias / "tmp").mkdir(parents=True)
        (alias / "tmp/CornellNoteTestRuns").symlink_to(self.root.parent, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            fixtures.cleanup_run(alias, self.run_id)
        self.assertTrue(self.root.exists())

    def test_metrics_and_deletion_do_not_follow_internal_symlinks(self):
        (self.root / "external").symlink_to(self.support.parent, target_is_directory=True)
        stats = fixtures.measure_run(self.root)
        expected_bytes = sum(os.lstat(path).st_size for path in [self.root / "owner.json", self.root / "CornellNoteTests-fixture/generations/store/metadata.store", self.root / "external"])
        self.assertEqual(stats["files"], 3)
        self.assertEqual(stats["directories"], 4)
        self.assertEqual(stats["bytes"], expected_bytes)
        self.assertGreaterEqual(stats["allocated_bytes"], 0)
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "")):
            fixtures.cleanup_run(self.container, self.run_id)
        self.assertFalse(self.root.exists())
        self.assertEqual(self.support.read_bytes(), b"user data")

    def test_failed_process_inspection_preserves_run(self):
        with patch.object(os, "kill", side_effect=PermissionError("cannot inspect process")):
            with self.assertRaises(RuntimeError):
                fixtures.cleanup_run(self.container, self.run_id)
        self.assertTrue(self.root.exists())


if __name__ == "__main__":
    unittest.main()
