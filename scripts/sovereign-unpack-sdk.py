#!/usr/bin/env python3
"""BearBrowser sovereign unpack-sdk shim.

Drop-in replacement for Firefox's taskcluster/scripts/misc/unpack-sdk.py, installed
into the extracted source by the macOS build workflow (.github/workflows/nightly-dmg.yml) AFTER `make dir` and
BEFORE `make bootstrap`.

WHY: the stock unpack-sdk.py downloads the macOS SDK from Apple's swcdn (403s for
CI runners) or — with MOZ_AUTOMATION — Mozilla's internal proxy (403 off their
network). We already provision the LICENSED macOS SDK from the build machine's
Xcode into $BEARBROWSER_MACOS_SDK (scripts/provision-macos-sdk.sh). This shim
satisfies the toolchain from that local SDK — no network fetch, no external CDN,
sovereign + reproducible.

Called exactly like the original: unpack-sdk.py <url> <sha512> <extract_prefix> [out_dir]
The original extracts files under `extract_prefix`, strips the prefix, and writes
them to `out_dir` — i.e. `out_dir` becomes the SDK root. We populate `out_dir` with
symlinks to our provisioned SDK's top-level entries (fast; no multi-GB copy). We
ignore <url>/<sha512> deliberately — the SDK is licensed and provided locally.
"""
import os
import sys


def main(argv):
    if len(argv) < 3:
        sys.exit("sovereign-unpack-sdk: expected <url> <sha512> <extract_prefix> [out_dir]")
    out_dir = argv[3] if len(argv) > 3 else "."

    src = os.environ.get("BEARBROWSER_MACOS_SDK", "")
    if not src or not os.path.isdir(src):
        sys.exit(
            "sovereign-unpack-sdk: BEARBROWSER_MACOS_SDK is unset or not a directory "
            f"(got {src!r}). scripts/provision-macos-sdk.sh must run first."
        )

    os.makedirs(out_dir, exist_ok=True)
    linked = 0
    for item in os.listdir(src):
        dst = os.path.join(out_dir, item)
        if os.path.lexists(dst):
            continue
        os.symlink(os.path.join(src, item), dst)
        linked += 1

    print(
        f"sovereign-unpack-sdk: populated {out_dir} from licensed SDK {src} "
        f"({linked} entries symlinked) — no network fetch",
        flush=True,
    )


if __name__ == "__main__":
    main(sys.argv[1:])
