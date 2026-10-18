"""Independent Windows launches keep separate logs; a relaunched child appends to its parent's log."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

if os.name != 'nt':
    raise SystemExit('This regression requires Windows')
root = Path(__file__).resolve().parents[1]
source = (root/'runtime/platform/windows.c').read_text()
logging = source[source.index('static char g_log_path[MAX_PATH];'):source.index('// The recompiled game code')]
harness = r'''
#include <windows.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <io.h>
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
    subprocess.run(shlex.split(os.environ.get('CC', 'clang')) + ['-std=gnu11', '-O1', str(cfile), '-o', str(exe)], check=True)
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
        log = temporary/f'lasrecomp-{process.pid}.log'
        assert log.exists(), 'Independent GUI launches did not get separate logs'
        assert log.read_text().splitlines() == [f'stdout:independent-{i}', f'stderr:independent-{i}']

    parent = start('parent'); finish(parent)
    lines = (temporary/f'lasrecomp-{parent.pid}.log').read_text().splitlines()
    assert lines == ['stdout:parent', 'stderr:parent', 'stdout:child', 'stderr:child', 'parent-after-child'], lines
    assert len(list(temporary.glob('lasrecomp-*.log'))) == 3, 'Relaunch created another log'
    assert finish(start('console')) == (b'stdout:console\r\n', b'stderr:console\r\n')
    finish(start('reject', env | {'LASRECOMP_LOG_FILE': 'x'*300}))
    finish(start('reject', env | {'LASRECOMP_LOG_FILE': str(temporary/'missing/log.txt')}))
    assert len(list(temporary.glob('*.log'))) == 3
print('PASS: separate GUI logs, inherited relaunch log, stdout/stderr, console pipes and failed paths')
