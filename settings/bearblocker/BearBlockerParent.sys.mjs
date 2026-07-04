/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearBlockerParent — parent-side coordinator for cosmetic filtering.
 *
 * Receives telemetry from BearBlockerChild about cosmetic rule application.
 * In agent-runtime profile this forwards events to BearBlockerPolicy for
 * receipt generation. In human-secure profile it is a lightweight no-op beyond
 * logging in debug builds.
 */

const lazy = {};

ChromeUtils.defineESModuleGetters(lazy, {
  BearBlockerPolicy: "resource:///actors/BearBlockerPolicy.sys.mjs",
});

export class BearBlockerParent extends JSWindowActorParent {
  receiveMessage(msg) {
    switch (msg.name) {
      case "BearBlocker:CosmeticApplied":
        this.#onCosmeticApplied(msg.data);
        break;
      case "BearBlocker:NetworkBlocked":
        this.#onNetworkBlocked(msg.data);
        break;
    }
  }

  #onCosmeticApplied({ url }) {
    if (!url || !this.#isAgentRuntime()) {
      return;
    }
    lazy.BearBlockerPolicy.recordCosmeticEvent(url).catch(() => {});
  }

  #onNetworkBlocked({ url, rule }) {
    lazy.BearBlockerPolicy.recordNetworkBlock(url, rule).catch(() => {});
  }

  #isAgentRuntime() {
    try {
      return Services.prefs.getBoolPref(
        "bearbrowser.runtime.agent",
        false
      );
    } catch {
      return false;
    }
  }
}
