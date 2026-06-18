/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearBlockerPolicy — PolicyFabric bridge for governed blocking.
 *
 * Called by BearBlockerParent when the agent-runtime profile is active.
 * Generates automation receipts for each block event and optionally consults
 * PolicyFabric for uncertain (non-important) matches before allowing/blocking.
 *
 * Exit-code contract from PolicyFabric:
 *   0 = allow   → pass through
 *   2 = hold    → suspend request until human approves via hold-queue UI
 *   3 = deny    → block unconditionally
 *
 * Receipt schema: browser-automation-receipt.schema.json
 */

const RECEIPT_LOG_PATH = PathUtils.join(
  PathUtils.profileDir,
  "bearblocker-receipts.jsonl"
);

function nowISO() {
  return new Date().toISOString();
}

async function appendReceipt(record) {
  try {
    const line = JSON.stringify(record) + "\n";
    const encoder = new TextEncoder();
    await IOUtils.write(RECEIPT_LOG_PATH, encoder.encode(line), {
      mode: "append",
    });
  } catch (e) {
    console.error("BearBlockerPolicy: receipt write failed", e);
  }
}

export const BearBlockerPolicy = {
  async recordNetworkBlock(url, rule) {
    await appendReceipt({
      schema: "browser-automation-receipt/v1",
      timestamp: nowISO(),
      event: "network_block",
      url,
      rule: rule ?? null,
      profile: "agent-runtime",
    });
  },

  async recordCosmeticEvent(url) {
    await appendReceipt({
      schema: "browser-automation-receipt/v1",
      timestamp: nowISO(),
      event: "cosmetic_applied",
      url,
      profile: "agent-runtime",
    });
  },

  /**
   * Consult PolicyFabric for a borderline request. Returns "allow", "hold",
   * or "deny". Falls back to "deny" on error so uncertain matches default safe.
   *
   * @param {string} url - The request URL.
   * @param {string} [rule] - The matched filter rule, if known.
   * @returns {Promise<"allow"|"hold"|"deny">}
   */
  async consultPolicy(url, rule) {
    try {
      const policyPath = Services.prefs.getStringPref(
        "bearbrowser.policy.executable",
        ""
      );
      if (!policyPath) {
        return "deny";
      }
      const proc = await Subprocess.call({
        command: policyPath,
        arguments: [
          "--action=network_request",
          `--url=${url}`,
          `--rule=${rule ?? ""}`,
        ],
        environmentAppend: true,
      });
      const { exitCode } = await proc.wait();
      if (exitCode === 0) {
        return "allow";
      }
      if (exitCode === 2) {
        return "hold";
      }
      return "deny";
    } catch {
      return "deny";
    }
  },
};
