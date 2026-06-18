/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * BearNavParent — handles privileged actions requested by BearNavChild.
 *
 * Currently: focuses the URL bar on BearNav:FocusUrlBar (the '/' shortcut).
 */

export class BearNavParent extends JSWindowActorParent {
  receiveMessage(msg) {
    if (msg.name !== "BearNav:FocusUrlBar") return;
    try {
      const browser = this.browsingContext?.top?.embedderElement;
      const win = browser?.ownerGlobal;
      win?.gURLBar?.focus();
      win?.gURLBar?.select();
    } catch {
      // Non-fatal — URL bar may not exist in all window types
    }
  }
}
