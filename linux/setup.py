"""The wheel contains ELF libraries and must never be tagged as platform-independent."""

import shutil
from pathlib import Path

from setuptools import Distribution, setup
from setuptools.command.build_py import build_py


class NativeDistribution(Distribution):
    def has_ext_modules(self):
        return True


class BuildDesktop(build_py):
    def run(self):
        native = Path(__file__).parent / "parakatt_linux/_native"
        for name in ("parakatt_core.py", "libparakatt_core.so"):
            if not (native / name).is_file():
                raise RuntimeError("Run make linux-native before building the desktop package")
        # setuptools can reuse build_lib across wheel builds. Remove the previous
        # native payload so an upgraded wheel cannot retain an old runtime.
        build_native = Path(self.build_lib) / "parakatt_linux/_native"
        if build_native.exists():
            shutil.rmtree(build_native)
        super().run()


setup(distclass=NativeDistribution, cmdclass={"build_py": BuildDesktop})
