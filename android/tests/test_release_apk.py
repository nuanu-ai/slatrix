import struct
import subprocess
import unittest
import zipfile
from pathlib import Path


ANDROID = Path(__file__).resolve().parents[1]
APK = ANDROID / "app/build/outputs/apk/release/app-release-unsigned.apk"


def section_names(elf):
    """Section names of a 64-bit little-endian ELF file, such as an arm64 Android library."""
    (header_table,) = struct.unpack_from("<Q", elf, 0x28)
    header_size, header_count, names_header = struct.unpack_from("<HHH", elf, 0x3A)
    (names,) = struct.unpack_from("<Q", elf, header_table + names_header * header_size + 0x18)
    offsets = (struct.unpack_from("<I", elf, header_table + index * header_size)[0] for index in range(header_count))
    return {elf[names + offset:elf.index(b"\0", names + offset)].decode() for offset in offsets}


class ReleaseApkTests(unittest.TestCase):
    def test_release_ships_only_stripped_arm64_libraries(self):
        result = subprocess.run(
            [str(ANDROID / "gradlew"), ":app:assembleRelease", "--offline", "--console=plain"],
            cwd=ANDROID,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=1800,
        )
        self.assertEqual(result.returncode, 0, result.stdout[-5000:])
        with zipfile.ZipFile(APK) as apk:
            abis = {name.split("/")[1] for name in apk.namelist() if name.startswith("lib/")}
            self.assertEqual({"arm64-v8a"}, abis)
            sections = section_names(apk.read("lib/arm64-v8a/libmatrix_sdk_ffi.so"))
        self.assertIn(".dynsym", sections)
        self.assertNotIn(".symtab", sections)


if __name__ == "__main__":
    unittest.main()
