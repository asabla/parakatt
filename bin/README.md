# Stable release launcher

`parakatt-launcher` is the executable shipped in the published `v0.6.1` app ZIP. It is reused without recompiling or signing so that the next package keeps the executable identity from that release.

Provenance:

- Release: https://github.com/asabla/parakatt/releases/tag/v0.6.1
- Asset: `Parakatt-0.6.1-arm64.zip`
- Asset SHA-256: `01507a14602a10c7a2233a769aa1fa41a55f94cdb773e463bd7c0df0cce33d95`
- Executable SHA-256: `e9f56b1a0349a826822ef364a809e5ace94b6daec3a6971028bdf5f3b447e39c`
- Code Directory hash: `8d1d178478c980fb83a02cc8aa0eb6c2f6d12532`
- Architecture: arm64. Minimum macOS: 14.0.

The launcher source and entitlements are unchanged from `v0.6.1`. The previous checked-in binary had a different Code Directory hash. It was not the executable in that published release. Release preparation restored the published executable after checking the asset checksum, deployment target, entitlements, and embedded signature.

Run `python3 scripts/verify-launcher.py` to check the recorded identity. Package verification also checks the executable in the app. Do not run `make launcher` during routine release preparation. An unchanged identity reduces the permission update risk; it does not replace a test of permissions across an installed update.
