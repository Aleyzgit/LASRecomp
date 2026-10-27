"""Exercise the production font loader using generated, asset-free sfnt fixtures."""
import os
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def fixture(family, cff=False, broken_cmap=False):
    name = family.encode('utf-16-be')
    names = struct.pack('>HHH6H', 0, 1, 18, 3, 1, 0x409, 1, len(name), 0) + name
    cmap = struct.pack('>HHHHI', 0, 1, 3, 10, 0xffffffff if broken_cmap else 12)
    cmap += struct.pack('>HHIII6I', 12, 0, 40, 0, 2, 0x20, 0x20, 1, 0x25a1, 0x25a1, 2)
    tables = {b'name': names, b'cmap': cmap, b'CFF ' if cff else b'glyf': b'\0' * 4}
    data = bytearray(struct.pack('>IHHHH', 0x4f54544f if cff else 0x10000, len(tables), 0, 0, 0))
    pos = 12 + 16 * len(tables)
    for tag, value in tables.items():
        data += tag + struct.pack('>III', 0, pos, len(value))
        pos += (len(value) + 3) & ~3
    for value in tables.values():
        data += value + bytes((-len(value)) % 4)
    return data


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    exe = tmp / ('font-test.exe' if os.name == 'nt' else 'font-test')
    subprocess.run(shlex.split(os.environ.get('CC', 'clang')) +
                   ['-std=gnu11', '-Iruntime', 'tools/test_game_font.c', 'runtime/game_font.c', 'runtime/game_font_import.c',
                    '-o', str(exe), '-pthread'], cwd=ROOT, check=True)
    (tmp / 'fonts').mkdir()
    (tmp / 'incoming').mkdir()
    original_source = fixture('Imported by picker fixture')
    (tmp / 'incoming/imported.ttf').write_bytes(original_source)
    (tmp / 'incoming/custom.ttf').write_bytes(fixture('Different file fixture'))
    (tmp / 'fallback.ttf').write_bytes(fixture('Fallback fixture'))
    (tmp / 'fonts/custom.ttf').write_bytes(fixture('Custom fixture'))
    (tmp / 'fonts/nintendo_udsg-r_std_003.ttf').write_bytes(fixture('Imported fixture'))
    (tmp / 'fonts/nintendo_ext_003.ttf').write_bytes(fixture('Button icons fixture'))
    (tmp / 'fonts/override.ttf').write_bytes(fixture('Environment fixture'))
    collection = bytearray(fixture('Collection fixture'))
    for i in range(struct.unpack_from('>H', collection, 4)[0]):
        pos = 12 + 16*i + 8
        struct.pack_into('>I', collection, pos, struct.unpack_from('>I', collection, pos)[0] + 16)
    (tmp / 'fonts/collection.ttc').write_bytes(b'ttcf' + struct.pack('>III', 0x10000, 1, 16) + collection)
    packed = fixture('Packed fixture')
    words = struct.pack('>II', 0x7f9a0218, len(packed)) + packed
    words += bytes((-len(words)) % 4)
    encoded = b''.join(struct.pack('>I', word ^ 0x49621806)
                       for (word,) in struct.iter_unpack('>I', words))
    (tmp / 'fonts/packed.bfttf').write_bytes(encoded)
    (tmp / 'fonts/broken.ttf').write_bytes(b'not a font at all')
    (tmp / 'fonts/cff.ttf').write_bytes(fixture('CFF fixture', cff=True))
    (tmp / 'fonts/bad-cmap.ttf').write_bytes(fixture('Broken cmap', broken_cmap=True))
    (tmp / 'fonts/bad-collection.ttc').write_bytes(b'ttcf' + struct.pack('>III', 0, 1, 0xffffffff))
    cases = [('auto', 'Imported fixture'), ('system', 'system'), ('custom.ttf', 'Custom fixture'),
             ('missing.ttf', 'Imported fixture'), ('cff.ttf', 'Imported fixture'),
             ('../outside.ttf', 'Imported fixture')]
    env = dict(os.environ)
    env.pop('LARECOMP_FONT', None)
    # The same menu selection can serve every game language; the Recomp menu itself is English.
    for language in ['ja', 'en-US', 'es', 'fr', 'de', 'it', 'nl', 'ru', 'ko', 'zh-Hans', 'zh-Hant']:
        for choice, expected in cases:
            subprocess.run([str(exe), choice, expected, language], cwd=tmp, env=env, check=True, capture_output=True)
    env['LARECOMP_FONT'] = 'fonts/override.ttf'
    subprocess.run([str(exe), 'custom.ttf', 'Environment fixture'], cwd=tmp, env=env, check=True, capture_output=True)
    assert (tmp / 'incoming/imported.ttf').read_bytes() == original_source
    assert (tmp / 'fonts/imported.ttf').read_bytes() == original_source
    assert (tmp / 'fonts/custom.ttf').read_bytes() == fixture('Custom fixture')
    print(f'{11 * len(cases) + 1} font selection cases passed; malformed inputs and reset checked in every run')
