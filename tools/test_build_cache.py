"""Compile/run the production cache logic with synthetic inputs."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory() as tmp:
    tmp=Path(tmp).absolute()
    exe=tmp/('cache-test.exe' if os.name=='nt' else 'cache-test')
    cxx=shlex.split(os.environ.get('CXX','clang++'))
    subprocess.run(cxx+['-x','c++','-std=c++17','-pthread','-Iruntime',
                        'runtime/build_cache.cpp','tools/test_build_cache.cpp',
                        '-o',str(exe)],cwd=root,check=True)
    data = tmp/'data'
    if os.name == 'nt':
        target, linked = tmp/'target', tmp/'junction'
        target.mkdir()
        assert target.resolve().is_relative_to(tmp.resolve())
        subprocess.run(['cmd', '/c', 'mklink', '/J', str(linked), str(target)],
                       check=True, stdout=subprocess.DEVNULL)
        data = linked/'data'
    subprocess.run([str(exe),str(data)],check=True)
