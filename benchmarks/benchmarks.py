"""Time eb-keep-logs on the inputs its tests and fixtures already use.

why and history read tests/fixtures/build-logs. loads, runs, usage and
pending use the records from tests/test_loads.sh, tests/test_runs.sh,
tests/test_usage.sh and tests/test_pending.sh. usage repeats that
install layout so the scan walks a module tree, and the log parsers
repeat their record so the read is the work.
"""

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOGS = ROOT / "tests" / "fixtures" / "build-logs"

# Copies of one test record, so parsing is the timed work.
LOAD_COPIES = 4000
RUN_COPIES = 2000
PENDING_COPIES = 2000
# Extra Name/Version directories in the layout tests/test_usage.sh builds.
USAGE_EXTRA = 200

# tests/test_loads.sh
LOAD_LOG = """\
Nov 17 12:00:01 login01 ModuleUsageTracking: user=alice module=GROMACS/2024.1 path=/cvmfs/g.lua host=login01 time=1731840001.250000
this line is not a record
user=bob module=GCC/13.2.0 path=/cvmfs/host=not-a-field.lua host=login02 time=1731840002.000000
user=cara module=GROMACS/2024.1 path=/other.lua host=login01 time=1731840099.5
user=dana module=GROMACS/2024.1 path=/missing-host.lua time=1
"""

# tests/test_runs.sh
RUN_LOG = """\
{
  "userT": {
    "cwd": "/lustre/medusa/faheymr",
    "exec_path": "/lustre/medusa/faheymr/hello_world",
    "start_time": 1428766963,
    "syshost": "darter",
    "user": "faheymr"
  }
}
{
  "function": ["MPI_Init"],
  "resultT": { "exec_path": "/lustre/medusa/faheymr/hello_world", "build_user": "faheymr" }
}
{
  "userT": {
    "exec_path": "/opt/site/bin/gmx",
    "start_time": "1428767000.5",
    "syshost": "login01",
    "user": "ada"
  }
}
"""

# tests/test_pending.sh, the dry-run that still has builds.
PENDING_LOG = """\
== Temporary log file in case of crash /tmp/eb-3lh496ml/easybuild-hxmie76g.log
Dry run: printing build status of easyconfigs and dependencies
CFGS=/Volumes/work/easybuild-easyconfigs/easybuild/easyconfigs
 * [x] $CFGS/z/zlib/zlib-1.2.12.eb (module: zlib/1.2.12)
 * [x] $CFGS/m/M4/M4-1.4.19.eb (module: M4/1.4.19)
 * [ ] $CFGS/f/flex/flex-2.6.4.eb (module: flex/2.6.4)
 * [F] $CFGS/b/binutils/binutils-2.39.eb (module: binutils/2.39)
 * [R] $CFGS/g/GCC/GCC-13.2.0.eb (module: GCC/13.2.0)
"""


def binary():
    override = os.environ.get("EB_KEEP_LOGS_BIN")
    if override:
        return override
    path = ROOT / "zig-out" / "bin" / "eb-keep-logs"
    if not path.is_file():
        raise RuntimeError("zig build -Drelease=true has not produced zig-out/bin/eb-keep-logs")
    return str(path)


def run(args):
    proc = subprocess.run(
        [binary(), *args],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode()[-2000:])


class KeepLogs:
    def setup(self):
        self._tmp = tempfile.mkdtemp(prefix="eb-keep-logs-asv-")
        root = Path(self._tmp)
        self.loads = root / "moduleUsage.log"
        self.loads.write_text(LOAD_LOG * LOAD_COPIES)
        self.runs = root / "runs.json"
        self.runs.write_text(RUN_LOG * RUN_COPIES)
        self.pending = root / "dry.txt"
        self.pending.write_text(PENDING_LOG * PENDING_COPIES)
        self.software, self.modules, self.xalt, self.lmod = _usage_tree(root)

    def teardown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def time_why_failed_run(self):
        run(["why", str(LOGS / "20261117_041222")])

    def time_history_package(self):
        run(["history", "hello", "--root", str(LOGS)])

    def time_loads_module(self):
        run(["loads", "--module", "GROMACS/2024.1", str(self.loads)])

    def time_runs_exec(self):
        run(["runs", "--exec", "hello_world", str(self.runs)])

    def time_usage_tree(self):
        run(
            [
                "usage",
                "--software",
                str(self.software),
                "--modules",
                str(self.modules),
                "--since",
                "100",
                str(self.xalt),
                str(self.lmod),
            ]
        )

    def time_pending_dry_run(self):
        run(["pending", str(self.pending)])


def _usage_tree(root):
    """The install tree and records from tests/test_usage.sh, plus more packages."""
    software = root / "software"
    modules = root / "modules"
    for module in ("Foo/1.0", "Bar/2.0", "Old/1.0", "Never/3.0"):
        (software / module).mkdir(parents=True)
    (modules / "Foo").mkdir(parents=True)
    (modules / "Bar").mkdir(parents=True)
    (modules / "Foo" / "1.0.lua").write_text("")
    (modules / "Bar" / "2.0.lua").write_text("")
    for i in range(USAGE_EXTRA):
        name = f"Pkg{i}"
        (software / name / "1.0").mkdir(parents=True)
        (modules / name).mkdir(parents=True)
        (modules / name / "1.0.lua").write_text("")
    xalt = root / "xalt.json"
    lmod = root / "lmod.log"
    xalt.write_text(
        "\n".join(
            [
                '{"userT":{"user":"a","exec_path":"%s/Foo/1.0/bin/foo","start_time":200}}'
                % software,
                '{"userT":{"user":"b","exec_path":"%s/Old/1.0/bin/old","start_time":"50"}}'
                % software,
                '{"package_path":"%s/Never/3.0"}' % software,
                "",
            ]
        )
    )
    lmod.write_text(
        "\n".join(
            [
                "user=c module=Bar/2.0 path=%s/Bar/2.0.lua host=n1 time=300" % modules,
                "user=d module=Outside/1.0 path=/other/Outside/1.0.lua host=n2 time=400",
                "user=e module=Never/3.0 path=%s/Never/3.0.lua host=n3 time=nan" % modules,
                "",
            ]
        )
    )
    return software, modules, xalt, lmod
