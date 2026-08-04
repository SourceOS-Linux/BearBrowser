// SPDX-License-Identifier: MIT
// Bear Containers — background.js
// author: mdheller
//
// Core logic for Multi-Account Containers in BearBrowser (LibreWolf/Firefox MV2).
// Requires contextualIdentities to be enabled in browser preferences.

'use strict';

// ---------------------------------------------------------------------------
// Container color map (contextualIdentities color name → hex)
// ---------------------------------------------------------------------------
const COLOR_MAP = {
  blue:      '#2196F3',
  orange:    '#FF9800',
  pink:      '#E91E63',
  green:     '#4CAF50',
  purple:    '#9C27B0',
  turquoise: '#009688',
  red:       '#F44336',
  yellow:    '#FFEB3B',
};

// Emoji badge per color for context menu labels
const COLOR_EMOJI = {
  blue:      '🔵',
  orange:    '🟠',
  pink:      '🩷',
  green:     '🟢',
  purple:    '🟣',
  turquoise: '🩵',
  red:       '🔴',
  yellow:    '🟡',
};

// Default containers to create on first install
const DEFAULT_CONTAINERS = [
  { name: 'Personal',  color: 'blue',   icon: 'fingerprint' },
  { name: 'Work',      color: 'orange', icon: 'briefcase'   },
  { name: 'Shopping',  color: 'pink',   icon: 'cart'        },
  { name: 'Banking',   color: 'green',  icon: 'dollar'      },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Return true if the contextualIdentities API is available. */
function hasContainersAPI() {
  return typeof browser !== 'undefined' &&
    typeof browser.contextualIdentities !== 'undefined';
}

/** Fetch all contextual identities (containers). */
async function getContainers() {
  if (!hasContainersAPI()) return [];
  try {
    return await browser.contextualIdentities.query({});
  } catch (e) {
    console.error('[bear-containers] getContainers failed:', e);
    return [];
  }
}

/**
 * Re-open a tab inside a different container.
 * Closes the old tab after the new one opens.
 *
 * @param {number} tabId        - Tab to reassign
 * @param {string} cookieStoreId - Target container's cookieStoreId
 */
async function assignTabToContainer(tabId, cookieStoreId) {
  try {
    const tab = await browser.tabs.get(tabId);
    const newTab = await browser.tabs.create({
      url:         tab.url || 'about:newtab',
      cookieStoreId,
      index:       tab.index + 1,
      active:      true,
      windowId:    tab.windowId,
    });

    // Track mapping: tabId → cookieStoreId
    const key = `tab_${newTab.id}`;
    await browser.storage.local.set({ [key]: cookieStoreId });

    // Remove original tab
    await browser.tabs.remove(tabId);

    return newTab;
  } catch (e) {
    console.error('[bear-containers] assignTabToContainer failed:', e);
    throw e;
  }
}

/** Resolve a container's display name from its cookieStoreId. */
async function containerNameForStore(cookieStoreId) {
  if (!hasContainersAPI()) return cookieStoreId;
  try {
    const identity = await browser.contextualIdentities.get(cookieStoreId);
    return identity ? identity.name : cookieStoreId;
  } catch (_) {
    return cookieStoreId;
  }
}

/** Fire-and-forget memory mesh ping on container switch. */
function pingMemoryMesh(containerName) {
  fetch('http://localhost:7788/api/append', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      ts:    new Date().toISOString(),
      type:  'container-switch',
      title: 'switched to ' + containerName + ' container',
      data:  { container: containerName },
    }),
  }).catch(() => { /* ignore — mesh may not be running */ });
}

// ---------------------------------------------------------------------------
// Context menu: "Open in Container ▶" with per-container submenu
// ---------------------------------------------------------------------------

async function rebuildContextMenu() {
  await browser.contextMenus.removeAll();

  browser.contextMenus.create({
    id:       'bear-containers-root',
    title:    'Open in Container ▶',
    contexts: ['page', 'link'],
  });

  const containers = await getContainers();
  for (const c of containers) {
    const emoji = COLOR_EMOJI[c.color] || '⬜';
    browser.contextMenus.create({
      id:       `bear-container-${c.cookieStoreId}`,
      parentId: 'bear-containers-root',
      title:    `${emoji} ${c.name}`,
      contexts: ['page', 'link'],
    });
  }
}

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  const prefix = 'bear-container-';
  if (!info.menuItemId.startsWith(prefix)) return;

  const cookieStoreId = info.menuItemId.slice(prefix.length);
  const targetTabId   = tab ? tab.id : null;

  if (info.linkUrl && tab) {
    // Open link URL in the selected container (new tab, don't close current)
    await browser.tabs.create({
      url:         info.linkUrl,
      cookieStoreId,
      index:       tab.index + 1,
      active:      true,
      windowId:    tab.windowId,
    });
  } else if (targetTabId !== null) {
    // Reopen current page in the selected container
    await assignTabToContainer(targetTabId, cookieStoreId);
  }

  const name = await containerNameForStore(cookieStoreId);
  pingMemoryMesh(name);
});

// ---------------------------------------------------------------------------
// Message listener — popup communicates via runtime messages
// ---------------------------------------------------------------------------

browser.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  switch (msg.type) {
    case 'GET_CONTAINERS':
      getContainers().then(sendResponse);
      return true; // async

    case 'GET_TAB_CONTAINER': {
      browser.tabs.query({ active: true, currentWindow: true })
        .then(async ([tab]) => {
          if (!tab) return sendResponse({ cookieStoreId: 'firefox-default', name: 'No Container', color: 'blue' });
          const cookieStoreId = tab.cookieStoreId || 'firefox-default';
          if (!hasContainersAPI() || cookieStoreId === 'firefox-default') {
            return sendResponse({ cookieStoreId: 'firefox-default', name: 'No Container', color: 'blue' });
          }
          try {
            const identity = await browser.contextualIdentities.get(cookieStoreId);
            sendResponse(identity || { cookieStoreId, name: 'Unknown', color: 'blue' });
          } catch (_) {
            sendResponse({ cookieStoreId, name: 'Unknown', color: 'blue' });
          }
        });
      return true;
    }

    case 'SWITCH_CONTAINER': {
      browser.tabs.query({ active: true, currentWindow: true })
        .then(async ([tab]) => {
          if (!tab) return sendResponse({ ok: false, error: 'No active tab' });
          try {
            await assignTabToContainer(tab.id, msg.cookieStoreId);
            const name = await containerNameForStore(msg.cookieStoreId);
            pingMemoryMesh(name);
            sendResponse({ ok: true });
          } catch (e) {
            sendResponse({ ok: false, error: String(e) });
          }
        });
      return true;
    }

    case 'CREATE_CONTAINER': {
      if (!hasContainersAPI()) return sendResponse({ ok: false, error: 'API unavailable' });
      browser.contextualIdentities.create({
        name:  msg.name  || 'New Container',
        color: msg.color || 'blue',
        icon:  msg.icon  || 'circle',
      }).then(async (identity) => {
        await rebuildContextMenu();
        sendResponse({ ok: true, identity });
      }).catch(e => sendResponse({ ok: false, error: String(e) }));
      return true;
    }

    default:
      return false;
  }
});

// ---------------------------------------------------------------------------
// Startup: create default containers if none exist
// ---------------------------------------------------------------------------

async function initDefaultContainers() {
  if (!hasContainersAPI()) {
    console.warn('[bear-containers] contextualIdentities API not available. ' +
      'Enable Container Tabs in LibreWolf Preferences → Privacy.');
    return;
  }

  const existing = await getContainers();
  if (existing.length > 0) {
    // Containers already exist — skip seeding
    return;
  }

  console.log('[bear-containers] Seeding default containers…');
  for (const def of DEFAULT_CONTAINERS) {
    try {
      await browser.contextualIdentities.create({
        name:  def.name,
        color: def.color,
        icon:  def.icon,
      });
      console.log(`[bear-containers] Created container: ${def.name}`);
    } catch (e) {
      console.error(`[bear-containers] Failed to create ${def.name}:`, e);
    }
  }
}

browser.runtime.onInstalled.addListener(async () => {
  await initDefaultContainers();
  await rebuildContextMenu();
  console.log('[bear-containers] Extension installed/updated.');
});

// Rebuild menu on startup (persists across browser sessions)
browser.runtime.onStartup.addListener(async () => {
  await rebuildContextMenu();
});

// Update tab→container mapping when tab navigates
browser.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (changeInfo.status !== 'complete') return;
  if (!tab.cookieStoreId || tab.cookieStoreId === 'firefox-default') return;
  const key = `tab_${tabId}`;
  await browser.storage.local.set({ [key]: tab.cookieStoreId });
});

// Clean up mapping when tab closes
browser.tabs.onRemoved.addListener(async (tabId) => {
  const key = `tab_${tabId}`;
  await browser.storage.local.remove(key);
});
