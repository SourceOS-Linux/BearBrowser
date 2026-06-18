/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearVaultParent — credential broker that reads from the OS keychain.
 *
 * Receives BearVault:LookupCredential from the content process with the
 * current hostname, queries the OS credential store, and returns username +
 * password directly to the child for form filling.
 *
 * macOS: `security find-internet-password -s {host} -g` (Keychain Services CLI)
 * Linux: `secret-tool lookup server {host}` (libsecret / GNOME Keyring)
 *
 * The password is never logged and the child clears it from memory after use.
 * No credentials are written; this is a read-only integration.
 */

export class BearVaultParent extends JSWindowActorParent {
  async receiveMessage(msg) {
    switch (msg.name) {
      case "BearVault:LookupCredential":
        return this.#lookup(msg.data.host);
    }
  }

  async #lookup(host) {
    if (!host || typeof host !== "string") return null;

    // Strip leading www. so "www.example.com" matches "example.com" entries
    const domain = host.replace(/^www\./, "");

    try {
      if (Services.appinfo.OS === "Darwin") {
        return await this.#lookupMacOS(domain);
      }
      return await this.#lookupLinux(domain);
    } catch {
      return null;
    }
  }

  // Returns { username, password } or null
  async #lookupMacOS(domain) {
    // -w: print only password to stdout
    const pwProc = await Subprocess.call({
      command: "/usr/bin/security",
      arguments: ["find-internet-password", "-s", domain, "-w"],
      environmentAppend: true,
      stderr: "pipe",
    });
    await pwProc.wait();
    const password = (await pwProc.stdout.readString()).trim();
    if (!password) return null;

    // Get account name from the full record (printed to stderr by -g)
    const acctProc = await Subprocess.call({
      command: "/usr/bin/security",
      arguments: ["find-internet-password", "-s", domain],
      environmentAppend: true,
      stderr: "pipe",
    });
    await acctProc.wait();
    const info = await acctProc.stdout.readString();
    const acctMatch = info.match(/"acct"<blob>="([^"]+)"/);
    const username = acctMatch?.[1] ?? "";

    return { username, password };
  }

  async #lookupLinux(domain) {
    // secret-tool is part of libsecret-tools package
    const proc = await Subprocess.call({
      command: "/usr/bin/secret-tool",
      arguments: ["lookup", "server", domain],
      environmentAppend: true,
      stderr: "pipe",
    });
    await proc.wait();
    const password = (await proc.stdout.readString()).trim();
    if (!password) return null;

    // secret-tool doesn't give us the username from this call;
    // return empty string — child will leave username field unchanged.
    return { username: "", password };
  }
}
