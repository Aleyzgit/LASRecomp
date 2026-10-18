"""Independent Windows logs, latest-run alias, bounded backups and inherited relaunches."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

if os.name != 'nt':
    raise SystemExit('This regression requires Windows')
root = Path(__file__).resolve().parents[1]
source = (root/'runtime/platform/windows.c').read_text()
logging = source[source.index('static char g_log_path[MAX_PATH]'):source.index('// The recompiled game code')]
harness = r'''
#include <windows.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <io.h>
#include <fcntl.h>
#include <stdint.h>
static BOOL hard_link(const char *link, const char *source, LPSECURITY_ATTRIBUTES security) {
    if (getenv("TEST_NO_HARDLINK")) { SetLastError(ERROR_NOT_SUPPORTED); return FALSE; }
    return CreateHardLinkA(link, source, security);
}
#define CreateHardLinkA hard_link
''' + logging + r'''
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    bool console = !strcmp(argv[1], "console");
    // Model a GUI launch without a console while keeping the test runner's own handles untouched.
    if (!console) SetStdHandle(STD_ERROR_HANDLE, NULL);
    log_to_file_without_console();
    if (!strcmp(argv[1], "reject")) return g_log_path[0] ? 3 : 0;
    if (console ? g_log_path[0] != 0 : g_log_path[0] == 0) return 4;
    fprintf(stdout, "stdout:%s\n", argv[1]);
    fflush(stdout);
    fprintf(stderr, "stderr:%s\n", argv[1]);
    if (!strcmp(argv[1], "parent")) {
        char exe[MAX_PATH], command[MAX_PATH + 20];
        if (!GetModuleFileNameA(NULL, exe, sizeof exe)) return 5;
        snprintf(command, sizeof command, "\"%s\" child", exe);
        STARTUPINFOA startup = {.cb = sizeof startup};
        PROCESS_INFORMATION child = {0};
        if (!CreateProcessA(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &child)) return 6;
        DWORD waited = WaitForSingleObject(child.hProcess, 10000), status = 7;
        if (waited == WAIT_TIMEOUT) TerminateProcess(child.hProcess, 8);
        GetExitCodeProcess(child.hProcess, &status);
        CloseHandle(child.hThread); CloseHandle(child.hProcess);
        if (waited != WAIT_OBJECT_0 || status) return 7;
        fprintf(stderr, "parent-after-child\n");
    } else if (!strncmp(argv[1], "independent", 11)) Sleep(500);
    else if (!strcmp(argv[1], "hold")) {
        char ready[MAX_PATH], done[MAX_PATH];
        snprintf(ready, sizeof ready, "%s.ready", g_log_path);
        snprintf(done, sizeof done, "%s.done", g_log_path);
        FILE *f = fopen(ready, "wb"); if (!f) return 8; fclose(f);
        for (int i=0; i<1000 && GetFileAttributesA(done)==INVALID_FILE_ATTRIBUTES; i++) Sleep(20);
        fprintf(stderr, "hold-finished\n");
    }
    return 0;
}
'''
build = (root/'build').resolve()
build.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='windows-logs-', dir=build) as directory:
    temporary = Path(directory).resolve()
    assert temporary.is_relative_to(build)
    cfile = temporary/'logs.c'; cfile.write_text(harness)
    exe = temporary/'logs.exe'
    subprocess.run(shlex.split(os.environ.get('CC', 'clang')) + ['-std=gnu11', '-O1', str(cfile),
                   '-Wl,--subsystem,windows', '-o', str(exe)], check=True)
    env = {k:v for k,v in os.environ.items() if k.upper() not in ('LASRECOMP_LOG_FILE', 'LASRECOMP_LOG_APPEND')}

    def start(label, environment=env):
        return subprocess.Popen([str(exe), label], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                creationflags=subprocess.CREATE_NO_WINDOW)

    def finish(process):
        try:
            out, err = process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(); raise
        assert process.returncode == 0, (process.returncode, out, err)
        return out, err

    processes = [start(f'independent-{i}') for i in range(2)]
    try:
        for process in processes: finish(process)
    finally:
        for process in processes:
            if process.poll() is None: process.kill(); process.wait()
    for i, process in enumerate(processes):
        log, = temporary.glob(f'lasrecomp-backup-*-{process.pid}.log')
        assert log.exists(), 'Independent GUI launches did not get separate logs'
        assert log.read_text().splitlines() == [f'stdout:independent-{i}', f'stderr:independent-{i}']

    parent = start('parent'); finish(parent)
    parent_log, = temporary.glob(f'lasrecomp-backup-*-{parent.pid}.log')
    lines = parent_log.read_text().splitlines()
    assert lines == ['stdout:parent', 'stderr:parent', 'stdout:child', 'stderr:child', 'parent-after-child'], lines
    assert len(list(temporary.glob('lasrecomp-*.log'))) == 3, 'Relaunch created another log'
    assert (temporary/'lasrecomp.log').read_bytes() == parent_log.read_bytes()
    assert finish(start('console')) == (b'stdout:console\r\n', b'stderr:console\r\n')
    finish(start('reject', env | {'LASRECOMP_LOG_FILE': 'x'*300}))
    finish(start('reject', env | {'LASRECOMP_LOG_FILE': str(temporary/'missing/log.txt')}))
    assert len(list(temporary.glob('*.log'))) == 4

    # A real GUI launch has invalid CRT descriptors as well as no Win32 standard
    # handles. Merely SetStdHandle(NULL) in the piped cases above doesn't model it.
    startup = subprocess.STARTUPINFO()
    startup.dwFlags = subprocess.STARTF_USESTDHANDLES | subprocess.STARTF_USESHOWWINDOW
    startup.hStdInput = startup.hStdOutput = startup.hStdError = 0
    startup.wShowWindow = subprocess.SW_HIDE
    bare = subprocess.Popen([str(exe), 'bare-gui'], env=env, startupinfo=startup,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    finish(bare)
    bare_log, = temporary.glob(f'lasrecomp-backup-*-{bare.pid}.log')
    assert bare_log.read_text().splitlines() == ['stdout:bare-gui', 'stderr:bare-gui']
    assert (temporary/'lasrecomp.log').read_bytes() == bare_log.read_bytes()

    # The alias is live while the newest session runs; pruning leaves older active
    # sessions alone, and an older exit must never replace the newest report.
    import time
    def held(environment=env):
        process = start('hold', environment)
        for _ in range(250):
            ready = list(temporary.glob(f'lasrecomp-backup-*-{process.pid}.log.ready'))
            if ready:
                return process, Path(str(ready[0])[:-6])
            assert process.poll() is None
            time.sleep(.02)
        raise AssertionError('Held process did not become ready')
    def release(process, path):
        Path(str(path)+'.done').touch()
        finish(process)

    live, live_log = held()
    try:
        assert (temporary/'lasrecomp.log').read_bytes() == live_log.read_bytes()
        for i in range(8):
            newest = start(f'rotation-{i}'); finish(newest)
        assert live_log.exists(), 'Pruning removed a running session'
        latest = (temporary/'lasrecomp.log').read_bytes()
        assert b'rotation-7' in latest
        release(live, live_log)
        assert (temporary/'lasrecomp.log').read_bytes() == latest, 'Older exit replaced the latest run'
        finish(start('prune-completed'))
        assert len(list(temporary.glob('lasrecomp-backup-*.log'))) == 5
        assert not live_log.exists()
    finally:
        if live.poll() is None: release(live, live_log)

    # FAT/exFAT fallback copies on exit and still chooses by launch order.
    fallback_env = env | {'TEST_NO_HARDLINK':'1'}
    old, old_log = held(fallback_env)
    try:
        finish(start('fallback-newest', fallback_env))
        latest = (temporary/'lasrecomp.log').read_bytes()
        assert b'fallback-newest' in latest
        release(old, old_log)
        assert (temporary/'lasrecomp.log').read_bytes() == latest
    finally:
        if old.poll() is None: release(old, old_log)
    # Legacy per-PID names are pruned too; another tool's log must be preserved.
    for i in range(10): (temporary/f'lasrecomp-{100+i}.log').write_text('legacy')
    foreign=temporary/'lasrecomp-custom.log'; foreign.write_text('keep me')
    finish(start('after-legacy'))
    managed=[p for p in temporary.glob('lasrecomp-*.log') if p != foreign]
    assert len(managed) == 5 and foreign.read_text() == 'keep me'
print('PASS: independent/relaunched writers, live latest log, five backups, active-session protection, exit ordering, fallback and legacy cleanup')
