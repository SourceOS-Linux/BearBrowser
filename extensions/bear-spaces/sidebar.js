/**
 * Bear Spaces — sidebar.js
 * Renders the spaces UI and communicates with background.js via runtime messages.
 *
 * SPDX-License-Identifier: MIT
 * Author: mdheller
 */

"use strict";

// ─── State (local mirror of background state) ─────────────────────────────────

let state = {
  spaces:      {},
  activeId:    null,
  tabsInSpace: {},
  tabMap:      {},
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

function msg(type, extra = {}) {
  return browser.runtime.sendMessage({ type, ...extra });
}

function toast(text, durationMs = 2000) {
  const el = document.getElementById("toast");
  el.textContent = text;
  el.classList.add("show");
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => el.classList.remove("show"), durationMs);
}

function escHtml(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ─── Data refresh ─────────────────────────────────────────────────────────────

async function refresh() {
  state = await msg("GET_STATE");
  render();
}

// ─── Rendering ────────────────────────────────────────────────────────────────

function render() {
  const list      = document.getElementById("spaces-list");
  const empty     = document.getElementById("empty-state");
  const showAllBtn = document.getElementById("btn-show-all");

  const spaceArr = Object.values(state.spaces).sort((a, b) => a.createdAt - b.createdAt);

  // Empty state
  empty.classList.toggle("visible", spaceArr.length === 0);

  // "All tabs" button highlight
  showAllBtn.classList.toggle("active", !state.activeId);

  // Remove old cards (keep #empty-state)
  list.querySelectorAll(".space-card").forEach((el) => el.remove());

  for (const space of spaceArr) {
    const card = buildSpaceCard(space);
    list.appendChild(card);
  }
}

function buildSpaceCard(space) {
  const isActive  = space.id === state.activeId;
  const tabs      = state.tabsInSpace[space.id] || [];
  const expanded  = isActive || tabs.length > 0;

  const card = document.createElement("div");
  card.className = "space-card" + (isActive ? " is-active" : "") + (expanded ? " expanded" : "");
  card.dataset.spaceId = space.id;

  // ── Header row
  const header = document.createElement("div");
  header.className = "space-header";

  const dot = document.createElement("div");
  dot.className = "space-dot";

  const nameEl = document.createElement("span");
  nameEl.className = "space-name";
  nameEl.textContent = space.name;

  const countEl = document.createElement("span");
  countEl.className = "space-count";
  countEl.textContent = tabs.length;
  countEl.title = `${tabs.length} tab${tabs.length !== 1 ? "s" : ""} in this space`;

  // Action buttons (rename, delete)
  const actions = document.createElement("div");
  actions.className = "space-actions";

  const btnRename = document.createElement("button");
  btnRename.title = "Rename";
  btnRename.innerHTML = "&#9998;"; // pencil
  btnRename.addEventListener("click", (e) => {
    e.stopPropagation();
    startRename(card, space, nameEl);
  });

  const btnDelete = document.createElement("button");
  btnDelete.className = "btn-delete";
  btnDelete.title = "Delete space";
  btnDelete.innerHTML = "&#215;"; // ×
  btnDelete.addEventListener("click", (e) => {
    e.stopPropagation();
    confirmDelete(space);
  });

  actions.appendChild(btnRename);
  actions.appendChild(btnDelete);

  header.appendChild(dot);
  header.appendChild(nameEl);
  header.appendChild(countEl);
  header.appendChild(actions);

  // Click header = switch to this space
  header.addEventListener("click", async () => {
    if (isActive) {
      // Toggle expand/collapse tab list
      card.classList.toggle("expanded");
      return;
    }
    await msg("SWITCH_SPACE", { spaceId: space.id });
    await refresh();
    toast(`Switched to "${space.name}"`);
  });

  // ── Tab list
  const tabsEl = document.createElement("div");
  tabsEl.className = "space-tabs";

  if (tabs.length === 0) {
    const empty = document.createElement("div");
    empty.style.cssText = "color:var(--text-muted);font-size:11px;padding:4px 0;";
    empty.textContent = "No tabs assigned yet.";
    tabsEl.appendChild(empty);
  } else {
    for (const tab of tabs) {
      tabsEl.appendChild(buildTabItem(tab, space.id));
    }
  }

  // ── Quick-assign button
  const btnAssign = document.createElement("button");
  btnAssign.className = "btn-assign-current";
  btnAssign.textContent = "+ Assign current tab here";
  btnAssign.addEventListener("click", async (e) => {
    e.stopPropagation();
    await msg("ASSIGN_CURRENT_TAB", { spaceId: space.id });
    await refresh();
    toast(`Current tab assigned to "${space.name}"`);
  });

  card.appendChild(header);
  card.appendChild(tabsEl);
  card.appendChild(btnAssign);

  return card;
}

function buildTabItem(tab, spaceId) {
  const item = document.createElement("div");
  item.className = "tab-item";

  // Favicon
  if (tab.favIconUrl) {
    const img = document.createElement("img");
    img.className = "tab-favicon";
    img.src = tab.favIconUrl;
    img.alt = "";
    img.onerror = () => img.replaceWith(faviconFallback());
    item.appendChild(img);
  } else {
    item.appendChild(faviconFallback());
  }

  const title = document.createElement("span");
  title.className = "tab-title";
  title.textContent = tab.title || tab.url || "(no title)";
  title.title = tab.url || "";

  const btnRemove = document.createElement("button");
  btnRemove.className = "btn-tab-remove";
  btnRemove.title = "Remove from space";
  btnRemove.innerHTML = "&#215;";
  btnRemove.addEventListener("click", async (e) => {
    e.stopPropagation();
    await msg("UNASSIGN_TAB", { tabId: tab.id });
    await refresh();
    toast("Tab removed from space");
  });

  item.appendChild(title);
  item.appendChild(btnRemove);
  return item;
}

function faviconFallback() {
  const el = document.createElement("div");
  el.className = "tab-favicon-fallback";
  el.innerHTML = "&#128196;"; // page icon
  return el;
}

// ─── Inline rename ────────────────────────────────────────────────────────────

function startRename(card, space, nameEl) {
  const input = document.createElement("input");
  input.className = "rename-input";
  input.type = "text";
  input.value = space.name;
  input.maxLength = 40;
  input.spellcheck = false;

  nameEl.replaceWith(input);
  input.focus();
  input.select();

  async function commit() {
    const newName = input.value.trim();
    if (newName && newName !== space.name) {
      await msg("RENAME_SPACE", { spaceId: space.id, name: newName });
      toast(`Renamed to "${newName}"`);
    }
    await refresh();
  }

  input.addEventListener("blur", commit);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter")  { e.preventDefault(); input.blur(); }
    if (e.key === "Escape") { input.value = space.name; input.blur(); }
  });
}

// ─── Delete confirmation ──────────────────────────────────────────────────────

async function confirmDelete(space) {
  // Use a simple confirm dialog — the sidebar is a trusted internal surface
  // eslint-disable-next-line no-alert
  if (!confirm(`Delete space "${space.name}"?\n\nTabs will not be closed, just unassigned.`)) return;
  await msg("DELETE_SPACE", { spaceId: space.id });
  await refresh();
  toast(`Deleted "${space.name}"`);
}

// ─── Event wiring ─────────────────────────────────────────────────────────────

document.getElementById("new-space-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = document.getElementById("new-space-input");
  const name = input.value.trim();
  if (!name) return;
  await msg("CREATE_SPACE", { name });
  input.value = "";
  await refresh();
  toast(`Created "${name}"`);
});

document.getElementById("btn-show-all").addEventListener("click", async () => {
  await msg("EXIT_FILTER");
  await refresh();
  toast("Showing all tabs");
});

// ─── Live updates: refresh when tabs change ───────────────────────────────────

// Poll storage changes so the sidebar stays in sync without a dedicated event bus
browser.storage.onChanged.addListener(() => {
  refresh();
});

// Also refresh on tab events (new tab, close tab, tab title change)
browser.tabs.onCreated.addListener(() => refresh());
browser.tabs.onRemoved.addListener(() => refresh());
browser.tabs.onUpdated.addListener((_id, info) => {
  if (info.title || info.favIconUrl || info.status === "complete") refresh();
});
browser.tabs.onActivated.addListener(() => refresh());

// ─── Boot ─────────────────────────────────────────────────────────────────────

refresh();
