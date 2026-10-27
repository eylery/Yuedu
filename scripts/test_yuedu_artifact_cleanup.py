import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("cleanup", Path(__file__).with_name("yuedu_clean_artifacts.py"))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def test_only_old_managed_completed_runs_are_selected(self):
        with tempfile.TemporaryDirectory() as directory:
            runs = Path(directory)
            for index in range(5):
                run = runs / str(index)
                run.mkdir()
                (run / "yuedu-validation.json").write_text(json.dumps({"managedBy": "yuedu_test.sh"}))
                os.utime(run, (100 + index, 100 + index))
            (runs / "0" / "active.pid").write_text(str(os.getpid()))
            os.utime(runs / "0", (100, 100))
            (runs / "source-fixtures").mkdir()
            (runs / "alias").symlink_to(runs / "1", target_is_directory=True)
            self.assertEqual({p.name for p in cleanup.candidates(runs, now=200)}, {"1", "2"})
            self.assertTrue((runs / "1").exists(), "Planning must not mutate any files")

    def test_age_limit_keeps_latest_completed_run(self):
        with tempfile.TemporaryDirectory() as directory:
            runs = Path(directory)
            for index in range(3):
                run = runs / str(index)
                run.mkdir()
                (run / "yuedu-validation.json").write_text('{"managedBy":"yuedu_test.sh"}')
                os.utime(run, (index + 1, index + 1))
            self.assertEqual({p.name for p in cleanup.candidates(runs, keep=5, now=900000)}, {"0", "1"})


if __name__ == "__main__":
    unittest.main()
