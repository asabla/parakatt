"""The wheel contains ELF libraries and must never be tagged as platform-independent."""

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
        super().run()


setup(distclass=NativeDistribution, cmdclass={"build_py": BuildDesktop})
