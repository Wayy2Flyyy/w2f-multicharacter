const app = document.getElementById('app');
const hint = document.getElementById('hint');
const detailsPanel = document.getElementById('detailsPanel');
const skySpawnPanel = document.getElementById('skySpawnPanel');
const skySpawnGrid = document.getElementById('skySpawnGrid');

const charName = document.getElementById('charName');
const charJob = document.getElementById('charJob');
const charCash = document.getElementById('charCash');
const charSlot = document.getElementById('charSlot');
const charBank = document.getElementById('charBank');
const charPlaytime = document.getElementById('charPlaytime');
const charLocation = document.getElementById('charLocation');

const spawnBtn = document.getElementById('spawnBtn');
const closeDetailsBtn = document.getElementById('closeDetailsBtn');

const resourceName = typeof GetParentResourceName === 'function'
    ? GetParentResourceName()
    : 'w2f-multicharacter';

let detailsVisible = false;
let skyMode = false;
let spawnBusy = false;
let hoveredSlot = null;
let selectedSlot = null;

function post(endpoint, data = {}) {
    return fetch(`https://${resourceName}/${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data),
    });
}

function setVisible(el, visible) {
    if (!el) return;
    el.classList.toggle('hidden', !visible);
    el.classList.toggle('visible', visible);
}

function showApp() {
    app.classList.remove('hidden');
    app.classList.add('visible');
}

function hideApp() {
    app.classList.add('hidden');
    app.classList.remove('visible');
}

function showCharacterDetails(data) {
    if (!data) return;
    detailsVisible = true;
    charName.textContent = data.name || 'Unknown';
    charJob.textContent = data.job || 'Unemployed';
    charCash.textContent = data.cash || '$0';
    charSlot.textContent = data.slot ? `#${data.slot}` : '—';
    charBank.textContent = data.bank || '$0';
    charPlaytime.textContent = data.playtime || '0m';
    charLocation.textContent = data.lastLocation || 'Unknown';

    setVisible(detailsPanel, true);
    detailsPanel.classList.add('fade-in');
    setVisible(hint, !skyMode);
}

function hideCharacterDetails() {
    detailsVisible = false;
    detailsPanel.classList.remove('fade-in');
    setVisible(detailsPanel, false);
    if (!skyMode) setVisible(hint, true);
}

function buildSkyCards(spawns) {
    skySpawnGrid.innerHTML = '';
    (spawns || []).forEach((spawn) => {
        const card = document.createElement('button');
        card.type = 'button';
        card.className = 'sky-card';
        card.dataset.id = spawn.id;
        card.innerHTML = `
            <span class="sky-card-label">${spawn.label}</span>
            <span class="sky-card-desc">${spawn.description || ''}</span>
        `;
        card.addEventListener('click', () => {
            if (spawnBusy) return;
            spawnBusy = true;
            card.classList.add('selected');
            post('chooseSkySpawn', { id: spawn.id });
        });
        card.addEventListener('mouseenter', () => card.classList.add('hover'));
        card.addEventListener('mouseleave', () => card.classList.remove('hover'));
        skySpawnGrid.appendChild(card);
    });
}

function showSkySpawnOptions(data) {
    skyMode = true;
    spawnBusy = false;
    setVisible(hint, false);
    hideCharacterDetails();
    buildSkyCards(data?.spawns || data);
    setVisible(skySpawnPanel, true);
    skySpawnPanel.classList.add('fade-in');
}

function hideSkySpawnOptions() {
    skyMode = false;
    skySpawnPanel.classList.remove('fade-in');
    setVisible(skySpawnPanel, false);
}

function beginSpawnSequence() {
    spawnBusy = true;
    hideCharacterDetails();
    app.classList.add('spawning');
}

function resetSelectionUI() {
    detailsVisible = false;
    skyMode = false;
    spawnBusy = false;
    hoveredSlot = null;
    selectedSlot = null;
    hideCharacterDetails();
    hideSkySpawnOptions();
    app.classList.remove('spawning');
    hideApp();
}

function spawnFailed() {
    spawnBusy = false;
    skyMode = false;
    app.classList.remove('spawning');
    setVisible(skySpawnPanel, false);
    setVisible(hint, true);
    showApp();
}

const handlers = {
    showSelection: (data) => {
        showApp();
        setVisible(hint, data?.showControlHints !== false);
    },
    showCharacterDetails: (data) => {
        showApp();
        showCharacterDetails(data);
    },
    hideCharacterDetails: () => hideCharacterDetails(),
    hideSelectionHints: () => setVisible(hint, false),
    showSkySpawnOptions: (data) => {
        showApp();
        showSkySpawnOptions(data);
    },
    hideSkySpawnOptions: () => hideSkySpawnOptions(),
    updateHoveredPed: (data) => {
        hoveredSlot = data?.slot ?? null;
        document.body.dataset.hoveredSlot = hoveredSlot ?? '';
    },
    updateSelectedPed: (data) => {
        selectedSlot = data?.slot ?? null;
        document.body.dataset.selectedSlot = selectedSlot ?? '';
    },
    beginSpawnSequence: () => beginSpawnSequence(),
    resetSelectionUI: () => resetSelectionUI(),
    spawnFailed: () => spawnFailed(),
};

window.addEventListener('message', (event) => {
    const { action, data } = event.data || {};
    const handler = handlers[action];
    if (handler) handler(data);
});

spawnBtn.addEventListener('click', () => {
    if (spawnBusy || !detailsVisible) return;
    beginSpawnSequence();
    post('pressSpawn');
});

closeDetailsBtn.addEventListener('click', () => {
    post('cancelDetails');
});

document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && detailsVisible && !skyMode) {
        post('cancelDetails');
    }
});

// Start hidden until client opens selection
