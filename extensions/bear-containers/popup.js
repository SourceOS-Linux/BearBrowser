// SPDX-License-Identifier: MIT
// Bear Containers — popup.js
// author: mdheller
//
// NOTE: `browser.contextualIdentities` requires the user to have enabled
// Container Tabs in LibreWolf: Preferences → Privacy → Enable Container Tabs.
// Without it the API is undefined and this popup shows an instructional notice.

'use strict';

// ---------------------------------------------------------------------------
// Container color name → CSS hex
// ---------------------------------------------------------------------------
const COLOR_HEX = {
  blue:      '#2196F3',
  orange:    '#FF9800',
  pink:      '#E91E63',
  green:     '#4CAF50',
  purple:    '#9C27B0',
  turquoise: '#009688',
  red:       '#F44336',
  yellow:    '#FFEB3B',
};

// Ordered list for the color picker in "new container" form
const COLOR_ORDER = ['blue', 'orange', 'pink', 'green', 'purple', 'turquoise', 'red', 'yellow'];

// ---------------------------------------------------------------------------
// DOM refs
// ---------------------------------------------------------------------------
const $  = id => document.getElementById(id);
const apiWarning      = $('api-warning');
const currentSection  = $('current-section');
const currentDot      = $('current-dot');
const currentName     = $('current-name');
const listSection     = $('list-section');
const containerList   = $('container-list');
const newSection      = $('new-section');
const newContainerBtn = $('new-container-btn');
const newForm         = $('new-form');
const newNameInput    = $('new-name');
const colorPicker     = $('color-picker');
const cancelNewBtn    = $('cancel-new-btn');
const confirmNewBtn   = $('confirm-new-btn');
const statusEl        = $('status');

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
let currentCookieStoreId = 'firefox-default';
let selectedColor = 'blue';

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

/** Resolve color hex from a container identity object. */
function dotColor(identity) {
  return COLOR_HEX[identity.color] || identity.colorCode || '#888';
}

/** Show a transient status message in the popup footer. */
function showStatus(msg, type = 'success') {
  statusEl.textContent = msg;
  statusEl.className = `status ${type}`;
  statusEl.classList.remove('hidden');
  setTimeout(() => statusEl.classList.add('hidden'), 2200);
}

/** Send a message to background.js and await the response. */
function bgMessage(payload) {
  return browser.runtime.sendMessage(payload);
}

// ---------------------------------------------------------------------------
// API availability guard
// ---------------------------------------------------------------------------

async function checkAPI() {
  // Try to list containers — if the API is missing this throws or returns nothing
  try {
    const containers = await bgMessage({ type: 'GET_CONTAINERS' });
    if (!Array.isArray(containers)) throw new Error('no array');
    return true;
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Render current container
// ---------------------------------------------------------------------------

async function renderCurrent() {
  try {
    const identity = await bgMessage({ type: 'GET_TAB_CONTAINER' });
    if (identity && identity.cookieStoreId !== 'firefox-default') {
      currentCookieStoreId = identity.cookieStoreId;
      currentDot.style.backgroundColor = dotColor(identity);
      currentName.textContent = identity.name;
    } else {
      currentCookieStoreId = 'firefox-default';
      currentDot.style.backgroundColor = '#6e7681';
      currentName.textContent = 'No Container (default)';
    }
    currentSection.classList.remove('hidden');
  } catch (e) {
    currentSection.classList.remove('hidden');
    currentName.textContent = 'Unknown';
  }
}

// ---------------------------------------------------------------------------
// Render container list
// ---------------------------------------------------------------------------

async function renderList() {
  containerList.innerHTML = '';

  let containers;
  try {
    containers = await bgMessage({ type: 'GET_CONTAINERS' });
  } catch (_) {
    containers = [];
  }

  if (!Array.isArray(containers) || containers.length === 0) {
    const li = document.createElement('li');
    li.textContent = 'No containers found.';
    li.style.color = '#6e7681';
    li.style.cursor = 'default';
    containerList.appendChild(li);
    listSection.classList.remove('hidden');
    return;
  }

  for (const c of containers) {
    const li = document.createElement('li');
    if (c.cookieStoreId === currentCookieStoreId) {
      li.classList.add('active-container');
    }

    const dot = document.createElement('span');
    dot.className = 'dot';
    dot.style.backgroundColor = dotColor(c);

    const label = document.createElement('span');
    label.textContent = c.name;

    li.appendChild(dot);
    li.appendChild(label);

    li.addEventListener('click', async () => {
      if (c.cookieStoreId === currentCookieStoreId) return; // already here
      try {
        const result = await bgMessage({ type: 'SWITCH_CONTAINER', cookieStoreId: c.cookieStoreId });
        if (result && result.ok) {
          // Tab was closed and reopened — popup closes automatically with the tab
          window.close();
        } else {
          showStatus(result?.error || 'Switch failed', 'error');
        }
      } catch (e) {
        showStatus('Switch failed: ' + String(e), 'error');
      }
    });

    containerList.appendChild(li);
  }

  listSection.classList.remove('hidden');
}

// ---------------------------------------------------------------------------
// New container form
// ---------------------------------------------------------------------------

function buildColorPicker() {
  colorPicker.innerHTML = '';
  for (const color of COLOR_ORDER) {
    const swatch = document.createElement('button');
    swatch.type = 'button';
    swatch.className = 'color-swatch' + (color === selectedColor ? ' selected' : '');
    swatch.style.backgroundColor = COLOR_HEX[color];
    swatch.title = color;
    swatch.setAttribute('aria-label', color);
    swatch.addEventListener('click', () => {
      selectedColor = color;
      document.querySelectorAll('.color-swatch').forEach(s => s.classList.remove('selected'));
      swatch.classList.add('selected');
    });
    colorPicker.appendChild(swatch);
  }
}

newContainerBtn.addEventListener('click', () => {
  newSection.classList.add('hidden');
  selectedColor = 'blue';
  buildColorPicker();
  newNameInput.value = '';
  newForm.classList.remove('hidden');
  newNameInput.focus();
});

cancelNewBtn.addEventListener('click', () => {
  newForm.classList.add('hidden');
  newSection.classList.remove('hidden');
});

confirmNewBtn.addEventListener('click', async () => {
  const name = newNameInput.value.trim();
  if (!name) {
    newNameInput.focus();
    return;
  }
  confirmNewBtn.disabled = true;
  confirmNewBtn.textContent = 'Creating…';
  try {
    const result = await bgMessage({
      type:  'CREATE_CONTAINER',
      name,
      color: selectedColor,
      icon:  'circle',
    });
    if (result && result.ok) {
      newForm.classList.add('hidden');
      newSection.classList.remove('hidden');
      await renderList();
      showStatus(`Container "${name}" created`, 'success');
    } else {
      showStatus(result?.error || 'Create failed', 'error');
    }
  } catch (e) {
    showStatus('Create failed: ' + String(e), 'error');
  } finally {
    confirmNewBtn.disabled = false;
    confirmNewBtn.textContent = 'Create';
  }
});

// Allow Enter key to confirm
newNameInput.addEventListener('keydown', e => {
  if (e.key === 'Enter') confirmNewBtn.click();
  if (e.key === 'Escape') cancelNewBtn.click();
});

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

async function init() {
  const apiAvailable = await checkAPI();

  if (!apiAvailable) {
    // contextualIdentities unavailable — show instructional notice only
    apiWarning.classList.remove('hidden');
    return;
  }

  await renderCurrent();
  await renderList();
  newSection.classList.remove('hidden');
}

init();
