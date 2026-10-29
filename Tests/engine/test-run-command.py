"""Exercise the real launcher with small child processes; no models or Mac are needed."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("engine_command", Path(__file__).with_name("run-command.py"))
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="engine launcher ")
        self.root = Path(self.directory.name)
        self.record = self.root / "debugger arguments.json"
        self.debugger = self.root / "debugger.py"
        self.debugger.write_text(
            "import json, pathlib, sys\n"
            f"pathlib.Path({str(self.record)!r}).write_text(json.dumps(sys.argv[1:]))\n",
            encoding="utf-8",
        )

    def tearDown(self):
        self.directory.cleanup()

    def command(self, code):
        return [sys.executable, "-c", f"import sys; sys.exit({code})", "kernel path", "samples", "output path", "--memory-export"]

    def test_success_and_failed_checks_do_not_launch_debugger(self):
        for code in (0, 1):
            with self.subTest(code=code):
                self.assertEqual(launcher.run_command(self.command(code), debugger=(sys.executable, str(self.debugger))), code)
                self.assertFalse(self.record.exists())

    def test_crash_preserves_exact_arguments_and_original_status(self):
        command = self.command(134)
        self.assertEqual(launcher.run_command(command, debugger=(sys.executable, str(self.debugger))), 134)
        recorded = json.loads(self.record.read_text())
        self.assertEqual(recorded[recorded.index("--") + 1:], command)

    def test_missing_debugger_keeps_original_failure(self):
        self.assertEqual(launcher.run_command(self.command(134), debugger=(str(self.root / "missing-debugger"),)), 134)

    def test_timed_out_debugger_keeps_original_failure(self):
        self.debugger.write_text("import time; time.sleep(20)\n", encoding="utf-8")
        started = time.monotonic()
        self.assertEqual(launcher.run_command(self.command(134), debugger=(sys.executable, str(self.debugger)), timeout=0.2), 134)
        self.assertLess(time.monotonic() - started, 5)


if __name__ == "__main__":
    unittest.main()
