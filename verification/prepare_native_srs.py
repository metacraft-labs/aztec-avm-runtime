#!/usr/bin/env python3
"""Real original SRS acquisition; no mocks or replacement curve points.

Run inside the owning devshell. Derive compiler/link arguments from the built
original vm2_tests constructor and use only an exclusive, new output directory.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import traceback
import time
import shutil

G2_SHA = '01797bfc4de5a96f0e516a9ea4537d18786dc30cb991aca4274c95822b69c32f'
BUILD = Path(sys.argv[1]).resolve(strict=True)
PARENT = Path(sys.argv[2]).resolve(strict=True)
SOURCE = Path(__file__).with_name('native_srs_provision.cpp')
OUT = Path(tempfile.mkdtemp(prefix='native-srs-', dir=PARENT))
DATA = OUT / 'crs'
DATA.mkdir()
RECEIPT = {'scope': 'verified original SRS prerequisite only', 'output': str(OUT), 'commands': []}

def record(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise RuntimeError(f'Expected regular file: {path}')
    return {'size': info.st_size, 'mode': stat.S_IMODE(info.st_mode),
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}

def save():
    (OUT / 'receipt.json').write_text(json.dumps(RECEIPT, indent=2) + '\n')

def field(block, key):
    match = re.search(r'^  ' + re.escape(key) + r' = (.*)$', block, re.M)
    if not match:
        raise RuntimeError(f'Missing Ninja field: {key}')
    return shlex.split(match[1])

def run(label, argv):
    row = {'label': label, 'argv': argv, 'cwd': str(BUILD)}
    RECEIPT['commands'].append(row)
    save()
    with (OUT / (label + '.stdout')).open('xb') as stdout, (OUT / (label + '.stderr')).open('xb') as stderr:
        child = subprocess.Popen(argv, cwd=BUILD, stdout=stdout, stderr=stderr)
        try:
            row['pid'] = child.pid
        finally:
            row['exit'] = child.wait()
    row['stdout'] = record(OUT / (label + '.stdout'))
    row['stderr'] = record(OUT / (label + '.stderr'))
    save()
    if row['exit'] != 0:
        raise RuntimeError(f'{label} failed: {row["exit"]}; see {OUT}')

try:
    def directory_identity(path):
        value = path.lstat()
        if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid():
            raise RuntimeError(f'Owned directory type/UID refusal: {path}')
        return {'device': value.st_dev, 'inode': value.st_ino,
                'mode': stat.S_IMODE(value.st_mode), 'uid': value.st_uid}
    directory_bindings = {str(path): directory_identity(path) for path in [OUT, DATA]}
    RECEIPT['directoryBindings'] = directory_bindings
    curl_name = shutil.which('curl')
    if not curl_name:
        raise RuntimeError('Declared curl unavailable')
    curl = Path(curl_name).resolve(strict=True)
    if not str(curl).startswith('/nix/store/'):
        raise RuntimeError('Immutable declared curl required')
    ninja = BUILD / 'build.ninja'
    cache = BUILD / 'CMakeCache.txt'
    text = ninja.read_text()
    compiler = Path(re.search(r'^CMAKE_CXX_COMPILER:STRING=(.+)$', cache.read_text(), re.M)[1])
    start = text.index('build src/barretenberg/srs/CMakeFiles/srs_objects.dir/factories/get_bn254_crs.cpp.o:')
    compile_block = text[start:text.index('\n\n', start)]
    start = text.index('build bin/vm2_tests ')
    link_block = text[start:text.index('\n\n', start)]
    libraries = field(link_block, 'LINK_LIBRARIES')
    if 'lib/libsrs.a' not in libraries:
        raise RuntimeError('Original SRS archive absent from vm2_tests link closure')
    flags = field(compile_block, 'FLAGS')
    if '-std=gnu++20' not in flags:
        raise RuntimeError('Unexpected original C++ language contract')
    archives = [Path(v) if Path(v).is_absolute() else BUILD / v for v in libraries if not v.startswith('-')]
    principals = {str(p): record(p) for p in [SOURCE, Path(__file__), ninja, cache, compiler.resolve(strict=True), Path(sys.executable).resolve(strict=True), curl, *archives]}
    RECEIPT['principals'] = principals
    RECEIPT['originalArchiveOrder'] = libraries
    linkflags = [('--dependency-file=' + str(OUT / 'link.d')) if v.startswith('--dependency-file=') else v for v in field(link_block, 'LINK_FLAGS')]
    binary = OUT / 'provision'
    run('compile', [str(compiler), *field(compile_block, 'DEFINES'), *flags,
                    *field(compile_block, 'INCLUDES'), '-UNDEBUG', '-MMD', '-MF',
                    str(OUT / 'provision.d'), str(SOURCE), '-o', str(binary), *linkflags, *libraries])
    principals[str(binary)] = record(binary)
    dep = (OUT / 'provision.d').read_text().replace('\\\n', ' ')
    for name in shlex.split(dep.split(':', 1)[1]):
        path = (BUILD / name).resolve(strict=True)
        principals[str(path)] = record(path)
    # Refuse any compile-time directory/principal replacement before curl writes.
    for path, expected in directory_bindings.items():
        if directory_identity(Path(path)) != expected:
            raise RuntimeError(f'Changed setup directory before G2 acquisition: {path}')
    for path, expected in principals.items():
        if record(path) != expected:
            raise RuntimeError(f'Changed setup principal before G2 acquisition: {path}')
    # Use exactly the original bootstrap's primary/fallback URLs and retry count.
    acquired = False
    for attempt in range(1, 4):
        for host in ['https://crs.aztec-cdn.foundation', 'https://crs.aztec-labs.com']:
            result = subprocess.run([str(curl), '-s', '-f', '-o', str(DATA / 'bn254_g2.dat'),
                                     host + '/g2.dat'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            RECEIPT.setdefault('g2Acquisition', []).append({'attempt': attempt, 'url': host + '/g2.dat',
                'exit': result.returncode, 'stderr': result.stderr.decode(errors='replace')})
            if result.returncode == 0:
                acquired = True
                break
        if acquired:
            break
        if attempt < 3:
            time.sleep(5)
    if not acquired:
        raise RuntimeError('Original G2 acquisition failed on both endpoints after three attempts')
    g2 = record(DATA / 'bn254_g2.dat')
    if g2['size'] != 128 or g2['sha256'] != G2_SHA:
        raise RuntimeError('Canonical G2 size/hash refusal')
    for p, expected in principals.items():
        if record(p) != expected:
            raise RuntimeError(f'Changed setup principal: {p}')
    for path, expected in directory_bindings.items():
        if directory_identity(Path(path)) != expected:
            raise RuntimeError(f'Changed setup directory: {path}')
    run('acquire', [str(binary), str(DATA)])
    for path, expected in directory_bindings.items():
        if directory_identity(Path(path)) != expected:
            raise RuntimeError(f'Changed setup directory: {path}')
    expected_sizes = {'bn254_g1_compressed.dat': (1 << 22) * 32,
                      'bn254_g1.dat': (1 << 22) * 64,
                      'bn254_g2.dat': 128, 'grumpkin_g1_v2.flat.dat': (1 << 18) * 64}
    RECEIPT['datasets'] = {name: record(DATA / name) for name in expected_sizes}
    if any(RECEIPT['datasets'][name]['size'] != size for name, size in expected_sizes.items()):
        raise RuntimeError('Original SRS dataset size refusal')
    for p, expected in principals.items():
        if record(p) != expected:
            raise RuntimeError(f'Changed setup principal: {p}')
    RECEIPT['result'] = 'PASS prerequisite only'
except BaseException:
    RECEIPT['error'] = traceback.format_exc()
    RECEIPT['result'] = 'FAIL prerequisite'
finally:
    save()
    print(OUT / 'receipt.json', file=sys.stderr)
# Publish the exclusive path even on failure: original offline tests must not
# fall back to an inherited or shared successful dataset.
print(DATA)
if RECEIPT['result'] != 'PASS prerequisite only':
    raise SystemExit(1)
