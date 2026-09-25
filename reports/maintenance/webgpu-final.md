# Speech benchmark

Commit: 6b287adfb7357a6323652147846d55b330ba7f9c (dirty=False)

Hardware: Apple M3 Max. OS: macOS-27.0-arm64-arm-64bit-Mach-O (26A428).

Model: parakeet-tdt-0.6b-v3, revision `8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce`. Backend: WebGpu.

Runtime lock SHA-256: `cacb830ec4dff04dca81614bd222f6246355d434e1c65d3f3aa23b2ea6e80f54`. Worker SHA-256: `21e4e5f8b4a4ee74eaeaae73b8fe9453483b174752b984b852abafdefb364379`.

| Language | WER | Median seconds | p95 seconds | Real-time factor |
|---|---:|---:|---:|---:|
| en_us | 0.0500 | 0.1005 | 0.1494 | 0.0101 |
| sv_se | 0.1324 | 0.1069 | 0.1573 | 0.0100 |

Cold runs use new processes; the OS file cache is not purged. Peak memory is the process maximum RSS from macOS time. Preview compute times exclude audio arrival; audio times report how much audio was available. UI latency requires separate Instruments measurements.
