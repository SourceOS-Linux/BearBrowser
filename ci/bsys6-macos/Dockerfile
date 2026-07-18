# bsys6-macos — the BearBrowser macOS CROSS-COMPILE build image.
#
# Extends the sovereign Linux build image (bsys6, which carries clang/rust/node)
# with the Mach-O cross toolchain so `epsilon` can build macOS binaries without any
# Apple hardware. See docs/macos-cross-build.md.
#
# Inputs are sovereign:
#   - base image: our bsys6 (move to zot: registry.<sovereign>/bearbrowser/bsys6)
#   - macOS SDK: pulled from zot at build time (vendored by
#     scripts/vendor-macos-sdk-to-zot.sh), NOT from Apple/Mozilla CDNs.
#   - cctools-port: built from source (pinned commit) — Mach-O ld64, lipo, etc.
#
# Build (once, then push to zot):
#   docker build -t <zot>/bearbrowser/bsys6-macos:<sdkver> \
#     --build-arg MACOS_SDK_REF=<zot>/bearbrowser/toolchains/macos-sdk:<sdkver> \
#     ci/bsys6-macos
#   docker push <zot>/bearbrowser/bsys6-macos:<sdkver>
#
# TODO(validate-on-epsilon): cctools-port build flags + SDK layout are the pieces
# that need a round or two of tuning on the runner. Marked inline.

ARG BSYS6_REF=codeberg.org/bearbrowser/bsys6:dind
FROM ${BSYS6_REF}

ARG CCTOOLS_PORT_COMMIT=986f30fce1042ad9cba1f7e78d54f8709f7e6428
ARG MACOS_SDK_DIR=/opt/bearbrowser/macos-sdk
ARG CCTOOLS_PREFIX=/opt/bearbrowser/cctools

ENV BEARBROWSER_MACOS_SDK=${MACOS_SDK_DIR}
ENV PATH=${CCTOOLS_PREFIX}/bin:${PATH}

# 1. Build deps for cctools-port + the cross toolchain.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential cmake clang llvm-dev libssl-dev libxml2-dev \
      uuid-dev zlib1g-dev python3 xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 2. cctools-port (Mach-O binutils: ld64, lipo, install_name_tool, …). Pinned.
#    apple-libtapi is a prerequisite for modern ld64.
RUN git clone https://github.com/tpoechtrager/apple-libtapi.git /tmp/libtapi \
    && cd /tmp/libtapi && INSTALLPREFIX=${CCTOOLS_PREFIX} ./build.sh && ./install.sh \
    && git clone https://github.com/tpoechtrager/cctools-port.git /tmp/cctools \
    && cd /tmp/cctools && git checkout ${CCTOOLS_PORT_COMMIT} \
    && cd cctools \
    && ./configure --prefix=${CCTOOLS_PREFIX} \
         --with-libtapi=${CCTOOLS_PREFIX} \
         --target=aarch64-apple-darwin \
    && make -j"$(nproc)" && make install \
    && rm -rf /tmp/libtapi /tmp/cctools
# TODO(validate-on-epsilon): confirm --target triple + that ld64 lands as
# ${CCTOOLS_PREFIX}/bin/aarch64-apple-darwin-ld; the cross mozconfig points here.

# 3. The macOS SDK, pulled from OUR registry (zot) as an OCI artifact. The image
#    build must have the SDK available at ${MACOS_SDK_DIR}. Two supported ways:
#    (a) mount/copy a pre-pulled SDK dir into the build context, or
#    (b) `oras pull ${MACOS_SDK_REF}` here (requires oras + zot creds at build).
#    We keep it explicit + sovereign — never fetch from swcdn/Mozilla.
ARG MACOS_SDK_REF=""
COPY sdk/ ${MACOS_SDK_DIR}/
# If COPY-based, `sdk/` is populated by the image build step from zot:
#   oras pull "$MACOS_SDK_REF" -o ci/bsys6-macos/sdk
# (see scripts/vendor-macos-sdk-to-zot.sh for the push side).

RUN test -f "${MACOS_SDK_DIR}/SDKSettings.plist" \
    || echo "WARNING: ${MACOS_SDK_DIR} has no SDKSettings.plist — SDK not staged; \
pull it from zot before building (see docs/macos-cross-build.md)"

LABEL org.sourceos.bearbrowser.image="bsys6-macos" \
      org.sourceos.bearbrowser.purpose="cross-compile BearBrowser to macOS on Linux"
