"""Red-before-fix and parity tests for eb-keep-logs --syslog / EB_KEEP_LOGS_SYSLOG."""

from __future__ import annotations

import os
import re
import shutil
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = os.environ.get("TOOL_BIN", str(ROOT / "eb-keep-logs"))

RFC5424_RE = re.compile(
    r"^<(\d+)>1 "
    r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z) "
    r"(\S+) "
    r"(eb-keep-logs) "
    r"(\d+|-) "
    r"([A-Z0-9_]+) "
    r"(\[ebKeepLogs@([0-9]+) [^\]]*\]) "
    r"(.*)$"
)


def _parse_sd(sd_block: str) -> dict[str, str]:
    m = re.match(r"^\[ebKeepLogs@[0-9]+ (.*)\]$", sd_block)
    assert m is not None, sd_block
    inner = m.group(1)
    out: dict[str, str] = {}
    i = 0
    while i < len(inner):
        while i < len(inner) and inner[i] == " ":
            i += 1
        if i >= len(inner):
            break
        eq = inner.index("=", i)
        key = inner[i:eq]
        assert inner[eq + 1] == '"', inner[i:]
        j = eq + 2
        chars: list[str] = []
        while j < len(inner):
            ch = inner[j]
            if ch == "\\":
                chars.append(inner[j + 1])
                j += 2
            elif ch == '"':
                j += 1
                break
            else:
                chars.append(ch)
                j += 1
        out[key] = "".join(chars)
        i = j
    return out


def _parse_journal(raw: bytes) -> dict[str, str]:
    out: dict[str, str] = {}
    i = 0
    while i < len(raw):
        nl = raw.index(b"\n", i)
        line = raw[i:nl]
        if b"=" in line:
            k, v = line.split(b"=", 1)
            out[k.decode("ascii")] = v.decode("utf-8")
            i = nl + 1
        else:
            k = line.decode("ascii")
            n = int.from_bytes(raw[nl + 1 : nl + 9], "little")
            out[k] = raw[nl + 9 : nl + 9 + n].decode("utf-8")
            assert raw[nl + 9 + n : nl + 10 + n] == b"\n"
            i = nl + 10 + n
    return out


class KeepLogsSyslogTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="eb-keep-logs-syslog-")
        self.bindir = os.path.join(self.work, "bin")
        self.logdir = os.path.join(self.work, "logs")
        self.ebtmp = os.path.join(self.work, "ebtmp")
        os.makedirs(self.bindir)
        os.makedirs(self.logdir)
        os.makedirs(os.path.join(self.ebtmp, "eb-1", "run-shell-cmd-output", "make-1"))
        self.eb_log = os.path.join(self.work, "easybuild-Foo.log")
        with open(self.eb_log, "w", encoding="utf-8") as handle:
            handle.write("error: secret-license-KEY-12345 invalid\n")
        with open(
            os.path.join(self.ebtmp, "eb-1", "run-shell-cmd-output", "make-1", "out.txt"),
            "w",
            encoding="utf-8",
        ) as handle:
            handle.write("cmd output secret-license-KEY-12345\n")
        with open(os.path.join(self.logdir, "Foo-1.0.stdout.log"), "w", encoding="utf-8") as handle:
            handle.write(
                f"output -> {self.ebtmp}/eb-1/run-shell-cmd-output/make-1/out.txt\n"
            )
        eb_stub = os.path.join(self.bindir, "eb")
        with open(eb_stub, "w", encoding="utf-8") as handle:
            handle.write(f"#!/bin/bash\necho {self.eb_log}\n")
        os.chmod(eb_stub, 0o755)

    def tearDown(self):
        shutil.rmtree(self.work, ignore_errors=True)

    def _dgram(self, name: str):
        path = os.path.join(self.work, name)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.bind(path)
        sock.settimeout(2.0)
        return sock, path

    def _env(self, **extra: str) -> dict[str, str]:
        env = dict(os.environ)
        env["PATH"] = self.bindir + ":" + env.get("PATH", "")
        env["EASYBUILD_TMPDIR"] = self.ebtmp
        env.pop("EB_KEEP_LOGS_SYSLOG", None)
        env.update(extra)
        return env

    def _run(self, args: list[str], env: dict[str, str]):
        return subprocess.run(
            [TOOL, *args],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    def test_failed_keeps_logs_and_emits_rfc5424(self):
        sock, path = self._dgram("failed.sock")
        try:
            proc = self._run(
                ["failed", f"--syslog=unix://{path}", "1", "Foo-1.0", self.logdir],
                self._env(SLURM_JOB_ID="555", SLURM_STEP_ID="2"),
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            raw = sock.recv(65536).decode("utf-8")
            self.assertNotIn("secret-license-KEY-12345", raw)
            m = RFC5424_RE.fullmatch(raw)
            self.assertIsNotNone(m, raw)
            assert m is not None
            self.assertEqual(m.group(1), "12")  # facility=1 (user), severity=4 (warning)
            self.assertEqual(m.group(6), "EB_KEEP_FAILED")
            sd = _parse_sd(m.group(7))
            self.assertEqual(sd["cmd"], "failed")
            self.assertEqual(sd["status"], "1")
            self.assertEqual(sd["name"], "Foo-1.0")
            self.assertEqual(sd["kept"], "2")
            self.assertEqual(sd["licensed"], "2")
            self.assertEqual(sd["ebout"], "1")
            self.assertEqual(sd["cmdout"], "1")
            self.assertEqual(sd["meson"], "0")
            self.assertEqual(sd["reason"], "kept")
            self.assertEqual(sd["job"], "555")
            self.assertEqual(sd["step"], "2")
        finally:
            sock.close()

    def test_failed_no_eb_emits_eb_keep_none_and_status_zero_is_silent(self):
        sock, path = self._dgram("none.sock")
        try:
            empty_bin = os.path.join(self.work, "empty")
            os.makedirs(empty_bin)
            env = self._env(PATH=empty_bin, EB_KEEP_LOGS_SYSLOG=f"unix://{path}")
            p_none = self._run(["failed", "3", "Missing-1.0", self.logdir], env)
            self.assertEqual(p_none.returncode, 0, p_none.stderr)
            raw = sock.recv(65536).decode("utf-8")
            m = RFC5424_RE.fullmatch(raw)
            self.assertIsNotNone(m, raw)
            assert m is not None
            self.assertEqual(m.group(6), "EB_KEEP_NONE")
            sd = _parse_sd(m.group(7))
            self.assertEqual(sd["kept"], "0")
            self.assertEqual(sd["reason"], "no-eb")

            p_ok = self._run(["failed", "0", "Ok-1.0", self.logdir], env)
            self.assertEqual(p_ok.returncode, 0)
            sock.settimeout(0.2)
            with self.assertRaises(socket.timeout):
                sock.recv(65536)
        finally:
            sock.close()

    def test_rotate_emits_journald_fields(self):
        sock, path = self._dgram("rotate.sock")
        try:
            rot_root = os.path.join(self.work, "runs")
            os.makedirs(os.path.join(rot_root, "20261001_120000"))
            os.makedirs(os.path.join(rot_root, "20260901_120000"))
            with open(os.path.join(rot_root, "20261001_120000", "a.log"), "w") as handle:
                handle.write("build log\n")
            with open(os.path.join(rot_root, "20260901_120000", "old.log"), "w") as handle:
                handle.write("old log\n")
            env = self._env(
                TZ="UTC",
                EB_KEEP_LOGS_NOW="1791936000",  # 2026-10-14 00:00:00 UTC
                EB_KEEP_LOGS_SYSLOG=f"journal+unix://{path}",
            )
            proc = self._run(
                ["rotate", rot_root, "--compress-after", "10", "--delete-after", "30"],
                env,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            fields = _parse_journal(sock.recv(65536))
            for k in fields:
                self.assertFalse(k.startswith("_"))
            self.assertEqual(fields["PRIORITY"], "6")
            self.assertEqual(fields["SYSLOG_IDENTIFIER"], "eb-keep-logs")
            self.assertEqual(fields["MSGID"], "EB_ROTATE_DONE")
            self.assertEqual(fields["EB_KEEP_CMD"], "rotate")
            self.assertEqual(fields["EB_ROTATE_COMPRESSED"], "1")
            self.assertEqual(fields["EB_ROTATE_DELETED"], "1")
        finally:
            sock.close()

    def test_tcp_octet_counting_and_udp(self):
        # The emitter writes the frame into a buffer. Unix datagram tests
        # cover the RFC 5424 text; this one keeps the octet count and the
        # one-datagram shape.
        tcp_path = os.path.join(self.work, "tcp.frame")
        env = self._env(EB_KEEP_LOGS_SYSLOG_CAPTURE=tcp_path)
        proc = self._run(
            ["failed", "--syslog", "tcp://127.0.0.1:9", "1", "Foo-1.0", self.logdir],
            env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        frame = Path(tcp_path).read_text(encoding="utf-8")
        n_s, body = frame.split(" ", 1)
        self.assertEqual(int(n_s), len(body.encode("utf-8")))

        udp_path = os.path.join(self.work, "udp.frame")
        env["EB_KEEP_LOGS_SYSLOG_CAPTURE"] = udp_path
        proc2 = self._run(
            ["failed", "--syslog=udp://127.0.0.1:9", "1", "Foo-1.0", self.logdir],
            env,
        )
        self.assertEqual(proc2.returncode, 0, proc2.stderr)
        raw = Path(udp_path).read_text(encoding="utf-8")
        self.assertEqual(raw, body)

    def test_bad_syslog_target_refused_and_unreachable_non_fatal(self):
        bad = self._run(
            ["failed", "--syslog=bogus://target", "1", "Foo-1.0", self.logdir],
            self._env(),
        )
        self.assertEqual(bad.returncode, 2)
        self.assertIn("syslog", bad.stderr.lower())

        missing = self._run(
            ["failed", "--syslog=unix:///nonexistent/eb-keep-logs.sock", "1", "Foo-1.0", self.logdir],
            self._env(),
        )
        self.assertEqual(missing.returncode, 0)
        self.assertTrue(os.path.isfile(os.path.join(self.logdir, "Foo-1.0.failed.ebout.log")))

    def test_custom_syslog_pen_and_invalid_pen_refused(self):
        sock, path = self._dgram("pen.sock")
        try:
            proc = self._run(
                ["failed", f"--syslog=unix://{path}", "1", "Foo-1.0", self.logdir],
                self._env(EB_KEEP_LOGS_SYSLOG_PEN="55555"),
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            raw = sock.recv(65536).decode("utf-8")
            m = RFC5424_RE.fullmatch(raw)
            self.assertIsNotNone(m, raw)
            assert m is not None
            self.assertEqual(m.group(8), "55555")
            self.assertIn("[ebKeepLogs@55555 ", raw)
        finally:
            sock.close()

        bad_pen = self._run(
            ["failed", f"--syslog=unix://{path}", "1", "Foo-1.0", self.logdir],
            self._env(EB_KEEP_LOGS_SYSLOG_PEN="0"),
        )
        self.assertEqual(bad_pen.returncode, 2)
        self.assertIn("EB_KEEP_LOGS_SYSLOG_PEN", bad_pen.stderr)


if __name__ == "__main__":
    unittest.main()
