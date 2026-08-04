/**
 * Bear Spaces — background.js
 * Tab workspace logic: space CRUD, tab assignment, hide/show, persistence,
 * context menu wiring, memory-mesh ping.
 *
 * SPDX-License-Identifier: MIT
 * Author: mdheller
 */

"use strict";

// ─── Constants ────────────────────────────────────────────────────────────────

const STORAGE_KEY_SPACES   = "bear_spaces";
const STORAGE_KEY_ACTIVE   = "bear_active_space";
const STORAGE_KEY_TAB_MAP  = "bear_tab_space_map";
const MESH_URL             = "http://localhost:7788/api/append";
const CONTEXT_MENU_ASSIGN  = "bear-spaces-assign";

// ─── In-memory state (re-hydrated from storage on startup) ────────────────────

let spaces    = {};   // { [spaceId]: { id, name, color?, createdAt } }
let activeId  = null; // currently visible space id (null = "all tabs" / no filter)
let tabMap    = {};   // { [tabId]: spaceId }

// ─── Storage helpers ──────────────────────────────────────────────────────────

async function loadState() {
  const data = await browser.storage.local.get([
    STORAGE_KEY_SPACES,
    STORAGE_KEY_ACTIVE,
    STORAGE_KEY_TAB_MAP,
  ]);
  spaces   = data[STORAGE_KEY_SPACES]  || {};
  activeId = data[STORAGE_KEY_ACTIVE]  || null;
  tabMap   = data[STORAGE_KEY_TAB_MAP] || {};
}

async function saveSpaces() {
  await browser.storage.local.set({ [STORAGE_KEY_SPACES]: spaces });
}

async function saveActive() {
  await browser.storage.local.set({ [STORAGE_KEY_ACTIVE]: activeId });
}

async function saveTabMap() {
  await browser.storage.local.set({ [STORAGE_KEY_TAB_MAP]: tabMap });
}

// ─── Space CRUD ───────────────────────────────────────────────────────────────

function genId() {
  return "sp_" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
}

async function createSpace(name) {
  const id = genId();
  spaces[id] = { id, name: name.trim(), createdAt: Date.now() };
  await saveSpaces();
  rebuildContextMenu();
  return spaces[id];
}

async function renameSpace(spaceId, newName) {
  if (!spaces[spaceId]) throw new Error("Unknown space: " + spaceId);
  spaces[spaceId].name = newName.trim();
  await saveSpaces();
  rebuildContextMenu();
  return spaces[spaceId];
}

async function deleteSpace(spaceId) {
  if (!spaces[spaceId]) return;

  // Unassign all tabs in this space
  const affected = Object.entries(tabMap)
    .filter(([, sid]) => sid === spaceId)
    .map(([tabId]) => Number(tabId));

  for (const tabId of affected) {
    delete tabMap[tabId];
  }
  await saveTabMap();

  // Show the now-orphaned tabs if this was the active space
  if (activeId === spaceId) {
    await showAllTabs();
    activeId = null;
    await saveActive();
  }

  delete spaces[spaceId];
  await saveSpaces();
  rebuildContextMenu();
}

// ─── Tab assignment ───────────────────────────────────────────────────────────

async function assignTab(tabId, spaceId) {
  tabMap[tabId] = spaceId;
  await saveTabMap();

  // If a space is currently active and this tab doesn't belong to it, hide it
  if (activeId && spaceId !== activeId) {
    try { await browser.tabs.hide(tabId); } catch (_) {}
  } else if (activeId && spaceId === activeId) {
    try { await browser.tabs.show(tabId); } catch (_) {}
  }
}

async function unassignTab(tabId) {
  delete tabMap[tabId];
  await saveTabMap();
  // If a space is active, show the now-unassigned tab (it goes to "limbo")
  if (activeId) {
    try { await browser.tabs.show(tabId); } catch (_) {}
  }
}

// ─── Space switching ──────────────────────────────────────────────────────────

async function switchToSpace(spaceId) {
  if (!spaces[spaceId]) return;

  const prevId  = activeId;
  activeId      = spaceId;
  await saveActive();

  const allTabs = await browser.tabs.query({ currentWindow: true });

  const toShow = [];
  const toHide = [];

  for (const tab of allTabs) {
    const assignedSpace = tabMap[tab.id];
    if (assignedSpace === spaceId) {
      toShow.push(tab.id);
    } else if (assignedSpace && assignedSpace !== spaceId) {
      // Only hide tabs explicitly assigned to a different space
      toHide.push(tab.id);
    }
    // Unassigned tabs stay visible (they float in no space)
  }

  // Show space tabs first so at least one tab is visible before we hide others
  for (const id of toShow) {
    try { await browser.tabs.show(id); } catch (_) {}
  }
  for (const id of toHide) {
    try { await browser.tabs.hide(id); } catch (_) {}
  }

  // Activate the first visible tab of the new space
  if (toShow.length) {
    try { await browser.tabs.update(toShow[0], { active: true }); } catch (_) {}
  }

  // Memory-mesh ping (fire-and-forget, swallow all errors)
  meshPing(spaceId, toShow.length);
}

async function showAllTabs() {
  const all = await browser.tabs.query({ currentWindow: true });
  for (const tab of all) {
    try { await browser.tabs.show(tab.id); } catch (_) {}
  }
}

async function exitSpaceFilter() {
  await showAllTabs();
  activeId = null;
  await saveActive();
}

// ─── Memory-mesh ping ─────────────────────────────────────────────────────────

function meshPing(spaceId, tabCount) {
  const space = spaces[spaceId];
  if (!space) return;

  const event = {
    ts:   new Date().toISOString(),
    type: "space-switch",
    title: `switched to ${space.name} space`,
    data: { space: space.name, space_id: spaceId, tab_count: tabCount },
  };

  fetch(MESH_URL, {
    method:  "POST",
    headers: { "Content-Type": "application/json" },
    body:    JSON.stringify(event),
  }).catch(() => { /* silently swallow */ });
}

// ─── Context menu ─────────────────────────────────────────────────────────────

function rebuildContextMenu() {
  browser.contextMenus.removeAll().then(() => {
    browser.contextMenus.create({
      id:       CONTEXT_MENU_ASSIGN,
      title:    "Assign tab to Space",
      contexts: ["tab", "page"],
    });

    const spaceList = Object.values(spaces);
    if (spaceList.length === 0) {
      browser.contextMenus.create({
        id:       "bear-spaces-assign-empty",
        parentId: CONTEXT_MENU_ASSIGN,
        title:    "(no spaces yet — create one in sidebar)",
        contexts: ["tab", "page"],
        enabled:  false,
      });
    } else {
      for (const space of spaceList) {
        browser.contextMenus.create({
          id:       `bear-spaces-assign-${space.id}`,
          parentId: CONTEXT_MENU_ASSIGN,
          title:    space.name,
          contexts: ["tab", "page"],
        });
      }

      browser.contextMenus.create({
        id:       "bear-spaces-assign-separator",
        parentId: CONTEXT_MENU_ASSIGN,
        type:     "separator",
        contexts: ["tab", "page"],
      });

      browser.contextMenus.create({
        id:       "bear-spaces-unassign",
        parentId: CONTEXT_MENU_ASSIGN,
        title:    "Remove from space",
        contexts: ["tab", "page"],
      });
    }
  });
}

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!tab) return;

  if (info.menuItemId === "bear-spaces-unassign") {
    await unassignTab(tab.id);
    return;
  }

  if (info.menuItemId.startsWith("bear-spaces-assign-")) {
    const spaceId = info.menuItemId.replace("bear-spaces-assign-", "");
    if (spaces[spaceId]) {
      await assignTab(tab.id, spaceId);
    }
  }
});

// ─── Tab lifecycle cleanup ────────────────────────────────────────────────────

browser.tabs.onRemoved.addListener(async (tabId) => {
  if (tabMap[tabId]) {
    delete tabMap[tabId];
    await saveTabMap();
  }
});

// When a new tab is created in an active space, auto-assign it to that space
browser.tabs.onCreated.addListener(async (tab) => {
  if (activeId && spaces[activeId]) {
    await assignTab(tab.id, activeId);
  }
});

// ─── Message API (called by sidebar.js) ──────────────────────────────────────

browser.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  handleMessage(msg).then(sendResponse).catch((err) => {
    sendResponse({ error: err.message });
  });
  return true; // keep channel open for async response
});

async function handleMessage(msg) {
  switch (msg.type) {
    case "GET_STATE": {
      const allTabs = await browser.tabs.query({ currentWindow: true });
      const tabsInSpace = {};
      for (const tab of allTabs) {
        const sid = tabMap[tab.id];
        if (!sid) continue;
        if (!tabsInSpace[sid]) tabsInSpace[sid] = [];
        tabsInSpace[sid].push({ id: tab.id, title: tab.title, url: tab.url, favIconUrl: tab.favIconUrl });
      }
      return { spaces, activeId, tabsInSpace, tabMap };
    }

    case "CREATE_SPACE": {
      const space = await createSpace(msg.name);
      return { space };
    }

    case "RENAME_SPACE": {
      const space = await renameSpace(msg.spaceId, msg.name);
      return { space };
    }

    case "DELETE_SPACE": {
      await deleteSpace(msg.spaceId);
      return { ok: true };
    }

    case "SWITCH_SPACE": {
      await switchToSpace(msg.spaceId);
      return { ok: true, activeId };
    }

    case "EXIT_FILTER": {
      await exitSpaceFilter();
      return { ok: true };
    }

    case "ASSIGN_CURRENT_TAB": {
      const [tab] = await browser.tabs.query({ currentWindow: true, active: true });
      if (tab) await assignTab(tab.id, msg.spaceId);
      return { ok: true };
    }

    case "UNASSIGN_TAB": {
      await unassignTab(msg.tabId);
      return { ok: true };
    }

    default:
      throw new Error("Unknown message type: " + msg.type);
  }
}

// ─── Browser-action click opens sidebar ──────────────────────────────────────

browser.browserAction.onClicked.addListener(() => {
  browser.sidebarAction.toggle();
});

// ─── Startup ─────────────────────────────────────────────────────────────────

(async () => {
  await loadState();
  rebuildContextMenu();

  // Seed default spaces if brand new install
  if (Object.keys(spaces).length === 0) {
    await createSpace("Work");
    await createSpace("Personal");
    await createSpace("Research");
  }

  // Re-apply hide state after browser restart
  if (activeId && spaces[activeId]) {
    await switchToSpace(activeId);
  }
})();
