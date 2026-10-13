# aion2-wine-compat

`compat_cpuid.c`, `tests/compat_test.c` and `LICENSE` are copied unchanged from
[Yuki-fox/aion2-wine-compat](https://github.com/Yuki-fox/aion2-wine-compat) at commit
`7ecbdef829bd619b7ef3f95db8ed5c2287d4b799` (MIT).

AION 2's NC Guard runs a 64→32-bit `CPUID` trampoline at start-up that Rosetta does not execute,
which leaves the game hanging after `initialize:: done`. The dylib interposes `sigaction` for
Wine's ntdll.so handlers, recognises that exact trampoline and delivers the access violation
Windows would raise. It does not touch game files or NC Guard.

`make aion2-compat` builds `out/compat_cpuid.dylib` (x86_64, the game runs under Rosetta);
`make aion2-compat-tests` runs the upstream test. The installer puts the dylib at
`~/Library/Application Support/notproton/aion2-compat/compat_cpuid.dylib`, and the run script
inserts it for AppID 3393110 only. `NOTPROTON_AION2_COMPAT=0` in the launch options leaves it out.
