/**
 * W2F Multicharacter NUI controller.
 *
 * Phase 5 rewrite:
 *   - All result messages (`createCharacterResult`, `spawnFailed`, …) accept
 *     the new `{ ok, error, payload }` envelope from W2F.Nui.SendResult.
 *   - Every busy flag has a hard timeout that auto-recovers the UI if Lua
 *     never replies (defensive: a Lua-side stall can no longer wedge the UI).
 *   - `spawnFailed` surfaces the server's error string instead of silently
 *     re-showing the hint bar.
 *   - Toast queue + transient surface for status, warnings, and errors.
 *   - Accessibility: focus management for modals, aria-live error region,
 *     keyboard-trap inside the delete + create panels.
 *   - Sky-grid is now scrollable on small viewports (CSS already, but the
 *     payload may also include a long list).
 */

const dom = {
    app: document.getElementById('app'),
    hint: document.getElementById('hint'),
    hologram: document.getElementById('hologram'),
    actionBar: document.getElementById('actionBar'),
    skySpawnPanel: document.getElementById('skySpawnPanel'),
    skySpawnGrid: document.getElementById('skySpawnGrid'),

    holoName: document.getElementById('holoName'),
    holoJob: document.getElementById('holoJob'),
    holoSlot: document.getElementById('holoSlot'),
    holoCash: document.getElementById('holoCash'),
    holoBank: document.getElementById('holoBank'),
    holoPlaytime: document.getElementById('holoPlaytime'),
    holoLocation: document.getElementById('holoLocation'),

    spawnBtn: document.getElementById('spawnBtn'),
    deleteBtn: document.getElementById('deleteBtn'),
    closeDetailsBtn: document.getElementById('closeDetailsBtn'),

    confirmDelete: document.getElementById('confirmDelete'),
    confirmDeleteBtn: document.getElementById('confirmDeleteBtn'),
    confirmCancelBtn: document.getElementById('confirmCancelBtn'),
    confirmInput: document.getElementById('confirmInput'),
    confirmName: document.getElementById('confirmName'),

    createPanel: document.getElementById('createPanel'),
    createForm: document.getElementById('createForm'),
    createSlotLabel: document.getElementById('createSlotLabel'),
    createNationality: document.getElementById('createNationality'),
    createBirthdate: document.getElementById('createBirthdate'),
    createGender: document.getElementById('createGender'),
    createError: document.getElementById('createError'),
    createCancelBtn: document.getElementById('createCancelBtn'),
};

const resourceName =
    typeof GetParentResourceName === 'function'
        ? GetParentResourceName()
        : 'w2f-multicharacter';

const state = {
    selectionActive: false,
    skyMode: false,
    spawnBusy: false,
    selectedSlot: null,
    selectedCharacterName: null,
    createOpen: false,
    createSlot: null,
    createBusy: false,
    createConfig: null,
    confirmOpen: false,
    confirmBusy: false,
    lastFocus: null,
};

/** Busy-flag watchdogs (ms after which we force-clear the flag locally). */
const TIMEOUTS = {
    spawn: 20000,
    create: 12000,
    confirm: 20000,
};
const timers = {};

function clearTimer(key) {
    if (timers[key]) {
        clearTimeout(timers[key]);
        timers[key] = null;
    }
}

function armTimer(key, ms, onTrip) {
    clearTimer(key);
    timers[key] = setTimeout(() => {
        timers[key] = null;
        onTrip();
    }, ms);
}

function post(endpoint, data = {}) {
    return fetch(`https://${resourceName}/${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data),
    }).catch((err) => {
        console.warn(`[w2f-mc] post(${endpoint}) failed`, err);
    });
}

function setVisible(el, visible) {
    if (!el) return;
    el.classList.toggle('hidden', !visible);
    el.classList.toggle('visible', visible);
    if (!visible) {
        el.setAttribute('aria-hidden', 'true');
    } else {
        el.removeAttribute('aria-hidden');
    }
}

function showApp() {
    dom.app.classList.remove('hidden');
    dom.app.classList.add('visible');
}

function hideApp() {
    dom.app.classList.add('hidden');
    dom.app.classList.remove('visible');
}

function pad2(n) {
    n = Number(n);
    if (!isFinite(n) || n < 0) return '00';
    return n < 10 ? `0${n}` : String(n);
}

/* ============================================================
 * Toast surface (used by spawn errors + Lua-side W2F.Nui.Toast).
 * ============================================================ */
let toastContainer = null;
function ensureToastContainer() {
    if (toastContainer) return toastContainer;
    toastContainer = document.createElement('div');
    toastContainer.id = 'w2fToasts';
    toastContainer.className = 'w2f-toasts';
    toastContainer.setAttribute('aria-live', 'polite');
    toastContainer.setAttribute('aria-atomic', 'false');
    document.body.appendChild(toastContainer);
    return toastContainer;
}

function showToast(level, message, durationMs = 4200) {
    if (!message) return;
    const root = ensureToastContainer();
    const node = document.createElement('div');
    node.className = `w2f-toast w2f-toast-${level || 'info'}`;
    node.textContent = String(message);
    root.appendChild(node);
    requestAnimationFrame(() => node.classList.add('shown'));
    const ttl = Math.max(1500, Number(durationMs) || 4200);
    setTimeout(() => {
        node.classList.remove('shown');
        node.addEventListener('transitionend', () => node.remove(), { once: true });
        setTimeout(() => node.remove(), 800);
    }, ttl);
}

/* ============================================================
 * Hologram
 * ============================================================ */
function applyHologramData(data) {
    if (!data) return;
    const name = data.name || 'Unknown';
    state.selectedCharacterName = name;
    dom.holoName.textContent = name;
    dom.holoName.setAttribute('data-text', name);
    dom.holoJob.textContent = data.job || 'Unemployed';
    dom.holoSlot.textContent = data.slot ? pad2(data.slot) : '00';
    dom.holoCash.textContent = data.cash || '$0';
    dom.holoBank.textContent = data.bank || '$0';
    dom.holoPlaytime.textContent = data.playtime || '0m';
    dom.holoLocation.textContent = data.lastLocation || 'Unknown';
}

let glitchTimer = null;
function startGlitchLoop() {
    stopGlitchLoop();
    const tick = () => {
        if (!dom.hologram.classList.contains('hidden')) {
            dom.hologram.classList.remove('glitching');
            void dom.hologram.offsetWidth;
            dom.hologram.classList.add('glitching');
        }
        glitchTimer = setTimeout(tick, 2200 + Math.random() * 5200);
    };
    glitchTimer = setTimeout(tick, 1400);
}

function stopGlitchLoop() {
    if (glitchTimer) {
        clearTimeout(glitchTimer);
        glitchTimer = null;
    }
    dom.hologram.classList.remove('glitching');
}

function showHologram(data) {
    if (state.createOpen) return;
    applyHologramData(data);
    setVisible(dom.hologram, true);
    dom.hologram.classList.remove('appear');
    void dom.hologram.offsetWidth;
    dom.hologram.classList.add('appear');
    setVisible(dom.actionBar, true);
    setVisible(dom.hint, false);
    startGlitchLoop();
}

function hideHologram() {
    setVisible(dom.hologram, false);
    setVisible(dom.actionBar, false);
    stopGlitchLoop();
    if (!state.skyMode && state.selectionActive) setVisible(dom.hint, true);
}

function updateHologramPosition(payload) {
    if (!payload || payload.visible === false) {
        setVisible(dom.hologram, false);
        return;
    }
    if (payload.data) applyHologramData(payload.data);
    if (dom.hologram.classList.contains('hidden')) {
        setVisible(dom.hologram, true);
        dom.hologram.classList.remove('appear');
        void dom.hologram.offsetWidth;
        dom.hologram.classList.add('appear');
    }
    const x = Math.max(0, Math.min(1, payload.x || 0)) * 100;
    const y = Math.max(0, Math.min(1, payload.y || 0)) * 100;
    const scale = Math.max(0.4, Math.min(1.6, payload.scale || 1));
    dom.hologram.style.left = `${x}%`;
    dom.hologram.style.top = `${y}%`;
    dom.hologram.style.transform = `translate(0, 0) scale(${scale})`;
}

/* ============================================================
 * Confirm-delete modal
 * ============================================================ */
function openConfirmDelete() {
    if (!state.selectedSlot || state.confirmOpen) return;
    state.confirmOpen = true;
    state.lastFocus = document.activeElement;
    dom.confirmInput.value = '';
    dom.confirmDeleteBtn.disabled = true;
    dom.confirmName.textContent = state.selectedCharacterName || 'this character';
    setVisible(dom.confirmDelete, true);
    setTimeout(() => dom.confirmInput.focus(), 30);
}

function closeConfirmDelete() {
    state.confirmOpen = false;
    state.confirmBusy = false;
    clearTimer('confirm');
    setVisible(dom.confirmDelete, false);
    dom.confirmInput.value = '';
    dom.confirmDeleteBtn.disabled = true;
    if (state.lastFocus && document.contains(state.lastFocus)) {
        try {
            state.lastFocus.focus();
        } catch (_) {
            /* focus restoration is best-effort */
        }
    }
}

/* ============================================================
 * Sky picker
 * ============================================================ */
function escapeHtml(value) {
    return String(value ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function buildSkyCards(spawns) {
    dom.skySpawnGrid.innerHTML = '';
    (spawns || []).forEach((spawn) => {
        const card = document.createElement('button');
        card.type = 'button';
        const isApartment = spawn.kind === 'apartment';
        card.className = `sky-card${isApartment ? ' sky-card-apartment' : ''}`;
        card.dataset.id = spawn.id;
        card.setAttribute('aria-label', spawn.label || 'Spawn');
        const tag = isApartment
            ? '<span class="sky-card-tag">APARTMENT</span>'
            : '';
        card.innerHTML = `
            ${tag}
            <span class="sky-card-label">${escapeHtml(spawn.label)}</span>
            <span class="sky-card-desc">${escapeHtml(spawn.description || '')}</span>
        `;
        card.addEventListener('click', () => {
            if (state.spawnBusy) return;
            state.spawnBusy = true;
            card.classList.add('selected');
            dom.skySpawnPanel.classList.add('closing');
            //- Watchdog: if Lua never replies in 20s we recover the UI.
            armTimer('spawn', TIMEOUTS.spawn, () => {
                showToast('error', 'Spawn timed out, please try again.');
                spawnFailed({ error: 'timeout' });
            });
            post('chooseSkySpawn', { id: spawn.id });
        });
        card.addEventListener('mouseenter', () => {
            card.classList.add('hover');
            post('previewSkySpawn', { id: spawn.id });
        });
        card.addEventListener('mouseleave', () => {
            card.classList.remove('hover');
            post('previewSkySpawn', { id: null });
        });
        dom.skySpawnGrid.appendChild(card);
    });
}

function showSkySpawnOptions(data) {
    state.skyMode = true;
    state.spawnBusy = false;
    clearTimer('spawn');
    setVisible(dom.hint, false);
    setVisible(dom.actionBar, false);

    //- Accept either the legacy `{spawns}` shape or the new `{entries}` one
    //- from W2F.Nui.BuildSkySpawnPayload.
    const spawns = (data && (data.spawns || data.entries)) || data || [];
    const isNew = !!(data && data.isNewCharacter);

    dom.skySpawnPanel.classList.toggle('first-spawn', isNew);
    const title = dom.skySpawnPanel.querySelector('.sky-title');
    if (title) {
        title.textContent =
            (data && data.title) ||
            (isNew ? 'Choose Your First Spawn' : 'Select Deployment Zone');
    }
    buildSkyCards(spawns);
    setVisible(dom.skySpawnPanel, true);
    dom.skySpawnPanel.classList.add('fade-in');
    //- Reset scroll so we don't keep a stale offset between sessions.
    dom.skySpawnGrid.scrollTop = 0;
}

function hideSkySpawnOptions() {
    state.skyMode = false;
    clearTimer('spawn');
    post('previewSkySpawn', { id: null });
    dom.skySpawnPanel.classList.remove('closing');
    dom.skySpawnPanel.classList.remove('fade-in');
    setVisible(dom.skySpawnPanel, false);
}

function beginSpawnSequence() {
    if (state.spawnBusy) return;
    state.spawnBusy = true;
    hideHologram();
    dom.app.classList.add('spawning');
    armTimer('spawn', TIMEOUTS.spawn, () => {
        showToast('error', 'Spawn timed out, please try again.');
        spawnFailed({ error: 'timeout' });
    });
}

function resetSelectionUI() {
    state.selectionActive = false;
    state.skyMode = false;
    state.spawnBusy = false;
    state.selectedSlot = null;
    state.selectedCharacterName = null;
    state.confirmBusy = false;
    state.createBusy = false;
    Object.keys(timers).forEach(clearTimer);
    hideHologram();
    hideSkySpawnOptions();
    closeCreatePanel();
    closeConfirmDelete();
    dom.app.classList.remove('spawning');
    hideApp();
}

/* ============================================================
 * Create panel
 * ============================================================ */
function populateNationalities(cfg) {
    if (!dom.createNationality || !cfg) return;
    dom.createNationality.innerHTML = '';
    const list = cfg.nationalities || ['American'];
    list.forEach((nat) => {
        const opt = document.createElement('option');
        opt.value = nat;
        opt.textContent = nat;
        if (nat === (cfg.defaultNationality || list[0])) {
            opt.selected = true;
        }
        dom.createNationality.appendChild(opt);
    });
}

function showCreateError(msg) {
    if (!dom.createError) return;
    if (!msg) {
        dom.createError.textContent = '';
        dom.createError.classList.add('hidden');
        return;
    }
    dom.createError.textContent = msg;
    dom.createError.classList.remove('hidden');
}

function openCreatePanel(data) {
    state.createOpen = true;
    state.createBusy = false;
    state.lastFocus = document.activeElement;
    document.body.classList.add('create-mode');
    closeConfirmDelete();
    state.createSlot = data?.slot ?? null;
    if (data?.config) state.createConfig = data.config;
    if (dom.createSlotLabel && state.createSlot != null) {
        dom.createSlotLabel.textContent = pad2(state.createSlot);
    }
    populateNationalities(state.createConfig || {});
    if (dom.createBirthdate && state.createConfig) {
        dom.createBirthdate.min = state.createConfig.birthdateMin || '1940-01-01';
        dom.createBirthdate.max = state.createConfig.birthdateMax || '2006-12-31';
        dom.createBirthdate.value = state.createConfig.birthdateMax || '2006-12-31';
    }
    showCreateError('');
    if (dom.createForm) dom.createForm.reset();
    populateNationalities(state.createConfig || {});
    setVisible(dom.hint, false);
    setVisible(dom.hologram, false);
    setVisible(dom.actionBar, false);
    setVisible(dom.createPanel, true);
    dom.createPanel.classList.add('fade-in');
    setTimeout(() => {
        document.getElementById('createFirst')?.focus();
    }, 50);
}

function closeCreatePanel(restoreHints) {
    state.createOpen = false;
    state.createSlot = null;
    state.createBusy = false;
    clearTimer('create');
    document.body.classList.remove('create-mode');
    if (dom.createPanel) {
        dom.createPanel.classList.remove('fade-in');
        setVisible(dom.createPanel, false);
    }
    showCreateError('');
    if (restoreHints !== false && state.selectionActive && !state.skyMode) setVisible(dom.hint, true);
    if (state.lastFocus && document.contains(state.lastFocus)) {
        try {
            state.lastFocus.focus();
        } catch (_) {
            /* best-effort */
        }
    }
}

/* ============================================================
 * Result handlers (envelope-aware)
 * ============================================================ */
function asEnvelope(payload) {
    //- Accept either the new `{ok, error, payload}` shape OR the legacy
    //- bare `{message: '...'}` shape we used before Phase 5.
    if (payload && typeof payload === 'object' && 'ok' in payload) {
        return {
            ok: !!payload.ok,
            error: payload.error || payload.message || null,
            payload: payload.payload,
        };
    }
    if (payload && typeof payload === 'object') {
        return { ok: false, error: payload.message || null, payload };
    }
    return { ok: false, error: null, payload: null };
}

function spawnFailed(data) {
    state.spawnBusy = false;
    state.skyMode = false;
    clearTimer('spawn');
    dom.app.classList.remove('spawning');
    setVisible(dom.skySpawnPanel, false);
    setVisible(dom.hint, true);
    showApp();
    const env = asEnvelope(data);
    if (env.error) {
        const msg = humanizeError(env.error, 'Spawn failed.');
        showToast('error', msg, 5500);
    }
}

function createCharacterResult(data) {
    const env = asEnvelope(data);
    state.createBusy = false;
    clearTimer('create');
    if (env.ok) {
        //- Lua transitions us out of the create panel on success; we just
        //- make sure no stale error sticks around.
        showCreateError('');
        return;
    }
    if (env.error) {
        showCreateError(humanizeError(env.error, 'Could not create character.'));
    }
}

function humanizeError(code, fallback) {
    if (!code) return fallback || 'Something went wrong.';
    const map = {
        rate_limited: 'You are doing that too fast — slow down a moment.',
        denied_ownership: 'That character does not belong to you.',
        missing_slot: 'No empty slot available.',
        slot_in_use: 'That slot was just taken — please pick another.',
        name_taken: 'That name is already in use.',
        invalid_name: 'Names must contain only letters, hyphens, and apostrophes.',
        invalid_birthdate: 'Please pick a valid date of birth.',
        invalid_payload: 'Some details look invalid — double-check the form.',
        load_failed: 'Could not load that character; please try another.',
        timeout: 'Timed out waiting for the server.',
        apartment_unavailable: 'Apartment is currently unavailable — choose another spawn.',
        appearance_failed: 'Appearance customization did not save.',
        unknown: fallback || 'Something went wrong.',
    };
    return map[String(code)] || fallback || String(code);
}

/* ============================================================
 * Inbound message dispatcher
 * ============================================================ */
const handlers = {
    showSelection: (data) => {
        state.selectionActive = true;
        if (data?.createConfig) state.createConfig = data.createConfig;
        showApp();
        setVisible(dom.hint, data?.showControlHints !== false);
    },

    openCreateCharacter: (data) => {
        showApp();
        openCreatePanel(data);
    },

    closeCreateCharacter: () => closeCreatePanel(false),

    showCharacterDetails: (data) => {
        showApp();
        showHologram(data);
    },

    hideCharacterDetails: () => hideHologram(),

    hideSelectionHints: () => setVisible(dom.hint, false),

    updateHologram: (payload) => updateHologramPosition(payload),

    showSkySpawnOptions: (data) => {
        showApp();
        showSkySpawnOptions(data);
    },

    hideSkySpawnOptions: () => hideSkySpawnOptions(),

    updateHoveredPed: (data) => {
        document.body.dataset.hoveredSlot = data?.slot ?? '';
    },

    updateSelectedPed: (data) => {
        state.selectedSlot = data?.slot ?? null;
        document.body.dataset.selectedSlot = state.selectedSlot ?? '';

        if (state.selectedSlot === null) {
            hideHologram();
            closeConfirmDelete();
            state.selectedCharacterName = null;
        }
    },

    beginSpawnSequence: () => beginSpawnSequence(),

    resetSelectionUI: () => resetSelectionUI(),

    setVisible: (data) => {
        if (data && data.visible === false) {
            hideApp();
            return;
        }
        if (data && data.visible === true) {
            showApp();
        }
    },

    hide: () => hideApp(),

    spawnFailed: (data) => spawnFailed(data),

    createCharacterResult: (data) => createCharacterResult(data),

    toast: (data) => {
        if (!data) return;
        showToast(data.level || 'info', data.message, data.durationMs);
    },

    characterDeleted: () => {
        state.confirmBusy = false;
        clearTimer('confirm');
        closeConfirmDelete();
    },

    characterDeleteFailed: (data) => {
        state.confirmBusy = false;
        clearTimer('confirm');
        dom.confirmDeleteBtn.disabled = false;
        showToast('error', data?.error || 'Failed to delete character.');
    },
};

window.addEventListener('message', (event) => {
    const { action, data } = event.data || {};
    const handler = handlers[action];

    if (!handler) return;

    try {
        handler(data);
    } catch (err) {
        console.warn(`[w2f-mc] handler ${action} threw`, err);
    }
});

/* ============================================================
 * Button wiring
 * ============================================================ */
dom.spawnBtn.addEventListener('click', () => {
    if (state.spawnBusy || state.selectedSlot === null) return;
    beginSpawnSequence();
    post('pressSpawn');
});

dom.closeDetailsBtn.addEventListener('click', () => {
    if (state.spawnBusy) return;
    post('cancelDetails');
});

dom.deleteBtn?.addEventListener('click', () => {
    if (state.spawnBusy || state.selectedSlot === null) return;
    openConfirmDelete();
});

dom.confirmCancelBtn?.addEventListener('click', () => {
    if (state.confirmBusy) return;
    closeConfirmDelete();
});

dom.confirmInput?.addEventListener('input', () => {
    dom.confirmDeleteBtn.disabled =
        dom.confirmInput.value.trim().toUpperCase() !== 'DELETE';
});

dom.confirmDeleteBtn?.addEventListener('click', () => {
    if (state.confirmBusy) return;
    if (dom.confirmInput.value.trim().toUpperCase() !== 'DELETE') return;
    state.confirmBusy = true;
    dom.confirmDeleteBtn.disabled = true;
    armTimer('confirm', TIMEOUTS.confirm, () => {
        state.confirmBusy = false;
        dom.confirmDeleteBtn.disabled = false;
        showToast('error', 'Delete timed out — please retry.');
    });
    post('deleteCharacter');
});

dom.createCancelBtn?.addEventListener('click', () => {
    if (state.createBusy) return;
    post('cancelCreateCharacter');
    closeCreatePanel();
});

dom.createForm?.addEventListener('submit', (e) => {
    e.preventDefault();
    if (state.createBusy || state.createSlot == null) return;
    state.createBusy = true;
    showCreateError('');
    const firstname = document.getElementById('createFirst')?.value?.trim();
    const lastname = document.getElementById('createLast')?.value?.trim();
    const nationality = dom.createNationality?.value;
    const gender = dom.createGender?.value;
    const birthdate = dom.createBirthdate?.value;
    if (!firstname || !lastname || !birthdate) {
        state.createBusy = false;
        showCreateError('Please fill in all required fields.');
        return;
    }
    armTimer('create', TIMEOUTS.create, () => {
        state.createBusy = false;
        showCreateError('Timed out — please try again.');
    });
    post('submitCreateCharacter', {
        slot: state.createSlot,
        firstname,
        lastname,
        nationality,
        gender,
        birthdate,
    });
});

/* ============================================================
 * Keyboard
 * ============================================================ */
document.addEventListener('keydown', (e) => {
    if (state.skyMode || state.spawnBusy) {
        //- Allow Escape to abort an in-flight spawn (Lua-side recoverable).
        if (state.skyMode && e.key === 'Escape' && !state.spawnBusy) {
            post('cancelSkySpawn');
        }
        return;
    }
    if (state.confirmOpen) {
        if (e.key === 'Escape' && !state.confirmBusy) {
            closeConfirmDelete();
        } else if (
            e.key === 'Enter' &&
            !state.confirmBusy &&
            dom.confirmInput.value.trim().toUpperCase() === 'DELETE'
        ) {
            state.confirmBusy = true;
            dom.confirmDeleteBtn.disabled = true;
            armTimer('confirm', TIMEOUTS.confirm, () => {
                state.confirmBusy = false;
                dom.confirmDeleteBtn.disabled = false;
            });
            post('deleteCharacter');
        }
        return;
    }
    if (state.createOpen) {
        if (e.key === 'Escape' && !state.createBusy) {
            post('cancelCreateCharacter');
            closeCreatePanel();
        }
        return;
    }
    if (e.key === 'Escape' && state.selectedSlot !== null) {
        post('cancelDetails');
    } else if ((e.key === 'Enter' || e.key === ' ') && state.selectedSlot !== null) {
        beginSpawnSequence();
        post('pressSpawn');
    } else if (
        (e.key === 'Delete' || e.key === 'Del') &&
        state.selectedSlot !== null &&
        !state.createOpen
    ) {
        openConfirmDelete();
    }
});

/* ============================================================
 * Boot
 * ============================================================ */
function notifyNuiReady() {
    post('nuiReady', {});
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', notifyNuiReady);
} else {
    notifyNuiReady();
}
