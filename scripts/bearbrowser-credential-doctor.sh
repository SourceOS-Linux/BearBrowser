#!/usr/bin/env bash
set -euo pipefail

os="$(uname -s)"

printf 'BearBrowser credential doctor\n'
printf 'os=%s\n' "$os"
printf 'principle=no BearBrowser-owned password or payment vault by default\n'
printf 'principle=biometric unlock is OS-mediated; BearBrowser receives allow/deny only\n'

case "$os" in
  Darwin)
    printf '\nmacOS credential backends\n'
    if command -v security >/dev/null 2>&1; then
      printf 'ok: Keychain Services CLI -> %s\n' "$(command -v security)"
    else
      printf 'missing: security CLI for Keychain Services\n'
    fi

    if command -v bioutil >/dev/null 2>&1; then
      printf 'ok: biometric utility -> %s\n' "$(command -v bioutil)"
      bioutil -r 2>/dev/null | sed 's/^/info: /' || true
    else
      printf 'optional-missing: bioutil; Touch ID may still be available through LocalAuthentication APIs\n'
    fi

    if command -v sw_vers >/dev/null 2>&1; then
      sw_vers | sed 's/^/info: /'
    fi
    ;;
  Linux)
    printf '\nLinux credential backends\n'
    if command -v secret-tool >/dev/null 2>&1; then
      printf 'ok: Secret Service/libsecret CLI -> %s\n' "$(command -v secret-tool)"
    else
      printf 'optional-missing: secret-tool; install libsecret tooling for Secret Service checks\n'
    fi

    if command -v qdbus >/dev/null 2>&1; then
      printf 'ok: qdbus -> %s\n' "$(command -v qdbus)"
      if qdbus org.kde.kwalletd5 >/dev/null 2>&1 || qdbus org.kde.kwalletd6 >/dev/null 2>&1; then
        printf 'ok: KWallet D-Bus service visible\n'
      else
        printf 'optional-missing: KWallet D-Bus service not visible\n'
      fi
    else
      printf 'optional-missing: qdbus for KWallet checks\n'
    fi

    if command -v busctl >/dev/null 2>&1; then
      if busctl --user list 2>/dev/null | grep -q 'org.freedesktop.secrets'; then
        printf 'ok: Secret Service D-Bus service visible\n'
      else
        printf 'optional-missing: Secret Service D-Bus service not visible\n'
      fi
    else
      printf 'optional-missing: busctl for Secret Service checks\n'
    fi

    if command -v fido2-token >/dev/null 2>&1; then
      printf 'ok: FIDO2 tooling -> %s\n' "$(command -v fido2-token)"
    else
      printf 'optional-missing: fido2-token for hardware authenticator checks\n'
    fi
    ;;
  *)
    printf '\ninfo: unsupported OS for credential backend checks: %s\n' "$os"
    ;;
esac

printf '\nAgent runtime posture\n'
printf 'ok: agent-runtime must not inherit human credentials\n'
printf 'ok: agent-runtime credentials must be policy-brokered and session-scoped\n'
printf 'ok: credential events must not contain secret values\n'
