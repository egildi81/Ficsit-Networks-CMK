const VERSION = "1.4.1";
// ── Navigation sections ───────────────────────────────────────
const _trainPages    = ['page-monitor', 'page-history', 'page-stats'];
const _stockagePages = ['page-stockage-info', 'page-stockage-config'];
const _sectionPages  = ['page-stockage-info', 'page-stockage-config', 'page-power', 'page-dispatch', 'page-logs'];

// Couleurs tags FIN / FIN tag colors
const LOG_TAG_COLORS = {
    LOGGER:     '#33cc55',
    DETAIL:     '#4488ff',
    TRAIN_TAB:  '#cccc00',
    DISPATCH:   '#00cccc',
    STOCKAGE:   '#aa44aa',
    CENTRAL:    '#4499cc',
    TRAIN_STATS:'#ff8800',
    TRAIN_MAP:  '#44cc99',
    POWER_MON:  '#ff66aa',
    STARTER:    '#cc2222',
};
let _lastTrainPage    = 'page-monitor';
let _lastStockagePage = 'page-stockage-info';

function switchSection(name, btn) {
    document.querySelectorAll('.section-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    const trainsTabs   = document.getElementById('trains-tabs');
    const stockageTabs = document.getElementById('stockage-tabs');
    // Masquer toutes les pages / Hide all pages
    _trainPages.forEach(id => document.getElementById(id).classList.remove('active'));
    _sectionPages.forEach(id => document.getElementById(id).classList.remove('active'));
    if (name === 'trains') {
        trainsTabs.style.display   = '';
        stockageTabs.style.display = 'none';
        document.getElementById(_lastTrainPage).classList.add('active');
    } else if (name === 'stockage') {
        trainsTabs.style.display   = 'none';
        stockageTabs.style.display = '';
        document.getElementById(_lastStockagePage).classList.add('active');
    } else {
        trainsTabs.style.display   = 'none';
        stockageTabs.style.display = 'none';
        document.getElementById('page-' + name).classList.add('active');
        if (name === 'logs') refreshLogs();
    }
}

// ── Navigation onglets (sous STOCKAGE) ────────────────────────
function switchStockTab(name, btn) {
    _stockagePages.forEach(id => document.getElementById(id).classList.remove('active'));
    document.querySelectorAll('#stockage-tabs .tab').forEach(t => t.classList.remove('active'));
    _lastStockagePage = 'page-stockage-' + name;
    document.getElementById(_lastStockagePage).classList.add('active');
    btn.classList.add('active');
}

// ── Navigation onglets (sous TRAINS) ─────────────────────────
function switchTab(name, btn) {
    _trainPages.forEach(id => document.getElementById(id).classList.remove('active'));
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    _lastTrainPage = 'page-' + name;
    document.getElementById(_lastTrainPage).classList.add('active');
    btn.classList.add('active');
}

// ── Utilitaires ──────────────────────────────────────────────
function fmt(sec) {
    sec = Math.max(0, Math.round(sec));
    const m = Math.floor(sec / 60), s = sec % 60;
    return `${m}:${String(s).padStart(2, '0')}`;
}

function fmtNumMobile(n) {
    n = Math.floor(n || 0);
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 10000)   return Math.floor(n / 1000) + 'k';
    if (n >= 1000)    return (n / 1000).toFixed(1) + 'k';
    return String(n);
}
function fmtUptime(sec) {
    sec = Math.floor(sec || 0);
    const h = Math.floor(sec / 3600);
    const m = Math.floor(sec / 60) % 60;
    const s = sec % 60;
    return `${h}h${String(m).padStart(2,'0')}m${String(s).padStart(2,'0')}s`;
}

function esc(s) {
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// ── Rendu colonnes temps réel ────────────────────────────────
function renderTrains(trains) {
    const groups = { moving: [], docked: [], stopped: [] };
    trains.forEach(t => (groups[t.status] || groups.stopped).push(t));
    groups.moving.sort((a, b) => a.speed - b.speed);  // plus lent en haut

    document.getElementById('cnt-moving').textContent  = groups.moving.length;
    document.getElementById('cnt-docked').textContent  = groups.docked.length;
    document.getElementById('cnt-stopped').textContent = groups.stopped.length;

    const empty = '<div class="empty-row">Aucun</div>';

    document.getElementById('col-moving').innerHTML = groups.moving.length
        ? groups.moving.map(t => `
            <div class="train-row">
                <div class="train-name">
                    <span class="dot ${t.speed > 100 ? 'dot-fast' : 'dot-slow'}"></span>
                    ${esc(t.name)}
                </div>
                <div class="train-sub">
                    <span class="${t.speed > 100 ? 'spd-fast' : 'spd-slow'}">${t.speed} km/h</span>
                    <span>→ ${esc(t.station)}</span>
                    <span>${t.wagons} wagon${t.wagons > 1 ? 's' : ''}</span>
                </div>
            </div>`).join('') : empty;

    document.getElementById('col-docked').innerHTML = groups.docked.length
        ? groups.docked.map(t => `
            <div class="train-row">
                <div class="train-name">
                    <span class="dot dot-docked"></span>
                    ${esc(t.name)}
                </div>
                <div class="train-sub">
                    <span class="clr-blue">→ ${esc(t.station)}</span>
                    <span>${t.wagons} wagon${t.wagons > 1 ? 's' : ''}</span>
                </div>
            </div>`).join('') : empty;

    document.getElementById('col-stopped').innerHTML = groups.stopped.length
        ? groups.stopped.map(t => `
            <div class="train-row">
                <div class="train-name">
                    <span class="dot dot-stopped"></span>
                    ${esc(t.name)}
                </div>
                <div class="train-sub">
                    <span class="spd-none">Arrêté</span>
                    <span>${esc(t.station)}</span>
                    <span>${t.wagons} wagon${t.wagons > 1 ? 's' : ''}</span>
                </div>
            </div>`).join('') : empty;

}

// ── Rendu historique ─────────────────────────────────────────
const openCards = new Set();

function renderTrips(trips) {
    const container = document.getElementById('trips-list');
    const entries = Object.entries(trips || {});
    if (!entries.length) {
        container.innerHTML = '<div class="empty-row">Aucun trajet enregistré</div>';
        return;
    }

    let totalTrips = 0;
    let html = '';

    for (const [trainName, segs] of entries) {
        const isOpen = openCards.has(trainName);
        const segEntries = Object.entries(segs || {});
        let segHtml = '';

        for (const [seg, tripArr] of segEntries) {
            if (!tripArr || !tripArr.length) continue;
            totalTrips += tripArr.length;
            const durations = tripArr.map(t => Number(t.duration));
            const mn = Math.min(...durations), mx = Math.max(...durations);
            const avg = Math.floor(durations.reduce((a, b) => a + b, 0) / durations.length);
            const last = tripArr[0];
            const invParts = last.inv ? Object.entries(last.inv).map(([k, v]) => `<span>${esc(k)} ×${v}</span>`).join('') : '';

            segHtml += `
                <div class="segment">
                    <div class="seg-title">${esc(seg)} &nbsp;(${tripArr.length} trajet${tripArr.length > 1 ? 's' : ''})</div>
                    <div class="seg-stats">min ${fmt(mn)} · moy ${fmt(avg)} · max ${fmt(mx)} · ${last.wagons || '?'} wagon${last.wagons > 1 ? 's' : ''}</div>
                    ${invParts ? `<div class="seg-inv">${invParts}</div>` : ''}
                </div>`;
        }

        html += `
            <div class="train-card">
                <div class="train-card-header ${isOpen ? 'open' : ''}" onclick="toggleCard(this,'${esc(trainName).replace(/'/g,"\\'")}')">
                    <span class="tname">${esc(trainName)}</span>
                    <span class="tmeta">${segEntries.length} segment${segEntries.length > 1 ? 's' : ''}</span>
                    <span class="arrow">▶</span>
                </div>
                <div class="segments ${isOpen ? 'open' : ''}">${segHtml || '<div class="empty-row">Aucun segment</div>'}</div>
            </div>`;
    }

    container.innerHTML = html;
}

function toggleCard(el, name) {
    const seg = el.nextElementSibling;
    const open = !seg.classList.contains('open');
    seg.classList.toggle('open', open);
    el.classList.toggle('open', open);
    open ? openCards.add(name) : openCards.delete(name);
}

// ── Stats réseau — données calculées par LOGGER, affichage uniquement ────────
function renderStats(trains, stats, updatedAt) {
    const s = stats || {};

    // Trains (compteurs depuis LOGGER via stats)
    document.getElementById('st-moving').textContent  = s.movingCnt  ?? '—';
    document.getElementById('st-docked').textContent  = s.dockedCnt  ?? '—';
    document.getElementById('st-stopped').textContent = s.stoppedCnt ?? '—';
    document.getElementById('st-total').textContent   = s.totalCnt   ?? '—';

    // Performance
    const avgSpeed = s.avgSpeed || 0;
    const durCnt   = s.durCnt   || 0;
    const avgDur   = s.avgDur   || 0;
    const avgInv   = s.avgInv   || 0;

    document.getElementById('st-perf-title').textContent = 'PERFORMANCE' + (durCnt > 0 ? ' (' + durCnt + ' trajets)' : '');

    const speedEl = document.getElementById('st-speed');
    speedEl.textContent = avgSpeed > 0 ? avgSpeed + ' km/h' : '—';
    speedEl.className = 'stats-bigval ' + (avgSpeed > 150 ? 'clr-green' : avgSpeed > 80 ? 'clr-yellow' : 'clr-red');
    const barEl = document.getElementById('st-speed-bar');
    barEl.style.width = Math.min(avgSpeed / 200, 1) * 100 + '%';
    barEl.className = 'stats-bar ' + (avgSpeed > 150 ? 'bar-green' : avgSpeed > 80 ? 'bar-yellow' : 'bar-red');

    document.getElementById('st-dur').textContent = durCnt > 0 ? fmt(avgDur) : 'N/A';
    const isMobile = _isMobile;
    const fmtI = n => isMobile ? fmtNumMobile(n) : String(n);
    document.getElementById('st-inv').textContent = avgInv > 0 ? fmtI(avgInv) + ' items' : '—';
    const totalInv = s.totalInv || 0;
    document.getElementById('st-inv-total').textContent = totalInv > 0 ? fmtI(totalInv) + ' items' : '—';

    // Score (calculé par LOGGER)
    const scoreHistory = s.scoreHistory || [];
    const score = scoreHistory.length > 0 ? scoreHistory[scoreHistory.length - 1] : (s.score ?? null);
    const scoreEl = document.getElementById('st-score');
    scoreEl.textContent = score !== null ? score : '—';
    scoreEl.className = 'stats-score ' + (score >= 80 ? 'clr-green' : score >= 60 ? 'clr-yellow' : score !== null ? 'clr-red' : '');

    // Confiance (calculée par LOGGER)
    const confLabels = {
        'HAUTE': 'clr-green', 'BONNE': 'clr-green',
        'FAIBLE': 'clr-yellow', 'INEXISTANTE': 'clr-red'
    };
    const confEl = document.getElementById('st-conf');
    confEl.textContent = s.conf || 'INCONNUE';
    confEl.className = 'stats-bigval ' + (confLabels[s.conf] || '');

    // Uptime (depuis LOGGER)
    document.getElementById('st-uptime').textContent = 'UP: ' + fmtUptime(s.uptime);

    // Graphique historique (depuis LOGGER)
    document.getElementById('st-hist-cnt').textContent = `(${scoreHistory.length} mesures)`;
    const canvas = document.getElementById('st-hist-canvas');
    canvas.width = canvas.offsetWidth || 900;
    const ctx = canvas.getContext('2d');
    const w = canvas.width, h = canvas.height;
    ctx.clearRect(0, 0, w, h);
    if (!scoreHistory.length) {
        ctx.fillStyle = '#333'; ctx.font = '13px monospace';
        ctx.fillText('En attente des données...', 16, h / 2 + 5);
    } else {
        const colW = Math.floor((w - 32) / scoreHistory.length);
        scoreHistory.forEach((sc, i) => {
            const bh = Math.floor((h - 4) * sc / 100);
            const bx = 16 + i * colW;
            ctx.fillStyle = '#0d0d0d';
            ctx.fillRect(bx, 0, colW - 2, h - 4);
            if (bh > 0) {
                ctx.fillStyle = sc >= 80 ? '#22cc22' : sc >= 60 ? '#cccc22' : '#cc2222';
                ctx.fillRect(bx, h - 4 - bh, colW - 2, bh);
            }
        });
    }
}

// ── Utilitaire : table Lua vide sérialisée en {} côté Python → toujours un tableau
function toArr(v) { return Array.isArray(v) ? v : []; }

// ── Check Perf ───────────────────────────────────────────────
// ~100 entrées/min tous tags confondus (mesuré en production)
const PERF_ENTRIES_PER_MIN = 100;

function openCheckPerf() {
    document.getElementById('perf-modal').classList.add('open');
    loadCheckPerf(15, document.querySelector('.perf-range-btn.active'));
}

async function loadCheckPerf(minutes, btn) {
    document.querySelectorAll('.perf-range-btn').forEach(b => b.classList.remove('active'));
    if (btn) btn.classList.add('active');
    document.getElementById('perf-body').innerHTML = 'Chargement…';
    const limit = Math.min(Math.ceil(minutes * PERF_ENTRIES_PER_MIN), 8000);
    try {
        const r = await fetch(`/api/perf/trains?limit=${limit}&minutes=${minutes}`);
        const d = await r.json();
        document.getElementById('perf-body').innerHTML = renderCheckPerf(d, minutes);
    } catch(e) {
        document.getElementById('perf-body').innerHTML = `<span style="color:#f44">Erreur : ${e}</span>`;
    }
}

function closeCheckPerf() {
    document.getElementById('perf-modal').classList.remove('open');
}

function renderCheckPerf(d, minutes) {
    const VERDICT_COLOR = { critical: '#f44', warning: '#fa0', info: '#888', ok: '#33cc55' };
    const VERDICT_ICON  = { critical: '🔴', warning: '🟠', info: '🟡', ok: '🟢' };

    const dur = d.duration_min != null ? `${d.duration_min} min réels` : `~${minutes} min demandées`;
    let html = `<div style="color:#666;font-size:0.76em;margin-bottom:10px">
        ${esc(d.period.from)} → ${esc(d.period.to)}
        &nbsp;·&nbsp; <span style="color:#ffaa0088">${dur}</span>
        &nbsp;·&nbsp; ${d.total_trips} trajets
    </div>`;

    for (const [i, t] of d.trains.entries()) {
        const c  = VERDICT_COLOR[t.verdict] || '#888';
        const ic = VERDICT_ICON[t.verdict]  || '⚪';
        const stations = t.stations.join(' ↔ ');
        html += `
        <div style="margin-bottom:10px;border-left:3px solid ${c};padding-left:10px">
            <div style="display:flex;align-items:center;gap:8px;margin-bottom:3px">
                <span style="color:#555;font-size:0.7em;font-weight:700">#${i+1}</span>
                <span style="color:#ddd;font-size:0.85em;font-weight:700">${esc(t.name)}</span>
                <span style="font-size:0.75em">${ic}</span>
                <span style="color:${c};font-size:0.72em;font-weight:600">${esc(t.label)}</span>
            </div>
            <div style="color:#555;font-size:0.72em;font-family:monospace;margin-bottom:2px">
                ${esc(stations)}
            </div>
            <div style="display:flex;gap:14px;font-size:0.72em;color:#666">
                <span>${t.trips} trajets</span>
                <span>${t.avg_dur}s moy</span>
                <span>${t.wagons} wagons</span>
                <span>${t.empty_pct}% vides</span>
                ${t.item ? `<span style="color:#555">${esc(t.item)}</span>` : ''}
            </div>
        </div>`;
    }
    return html;
}

// ── Rapport DISPATCH ─────────────────────────────────────────
async function dpReport() {
    document.getElementById('dp-report-body').innerHTML = 'Chargement…';
    document.getElementById('dp-report-modal').classList.add('open');
    try {
        const r = await fetch('/api/dispatch/report');
        const d = await r.json();
        document.getElementById('dp-report-body').innerHTML = renderDpReport(d);
    } catch(e) {
        document.getElementById('dp-report-body').innerHTML = `<span style="color:#f44">Erreur : ${e}</span>`;
    }
}

function closeDpReport() {
    document.getElementById('dp-report-modal').classList.remove('open');
}

function renderDpReport(d) {
    const SEV_COLOR = { high: '#f44', medium: '#fa0', low: '#888' };
    const SEV_LABEL = { high: 'CRITIQUE', medium: 'ATTENTION', low: 'INFO' };

    let html = `<div style="color:#666;font-size:0.76em;margin-bottom:10px">
        ${esc(d.period.from)} → ${esc(d.period.to)} &nbsp;·&nbsp;
        ${d.dispatch_count} logs DISPATCH sur ${d.total_analyzed} analysés
    </div>`;

    // Badge santé global
    const statusColor = d.healthy ? '#33cc55' : (d.high_count > 0 ? '#f44' : '#fa0');
    const statusText  = d.healthy ? '✓ Aucun problème détecté' :
        `${d.high_count} critique(s) · ${d.medium_count} attention(s)`;
    html += `<div style="padding:8px 12px;border-radius:6px;background:${statusColor}22;border:1px solid ${statusColor}44;color:${statusColor};font-weight:700;font-size:0.85em;margin-bottom:14px">${statusText}</div>`;

    // Issues
    if (d.issues.length === 0) {
        html += `<div style="color:#555;font-size:0.82em">Aucune anomalie dans la fenêtre analysée.</div>`;
    } else {
        for (const issue of d.issues) {
            const c = SEV_COLOR[issue.severity] || '#888';
            const l = SEV_LABEL[issue.severity] || issue.severity;
            html += `<div style="margin-bottom:12px;border-left:3px solid ${c};padding-left:10px">
                <div style="display:flex;align-items:center;gap:8px;margin-bottom:4px">
                    <span style="color:${c};font-size:0.7em;font-weight:700;letter-spacing:1px">${l}</span>
                    <span style="color:#ccc;font-size:0.82em;font-weight:600">${esc(issue.label)}</span>
                    <span style="color:#666;font-size:0.72em">${issue.count}×</span>
                </div>`;
            for (const e of issue.entries) {
                html += `<div style="color:#888;font-size:0.72em;font-family:monospace;padding:2px 0;border-bottom:1px solid #1a1a1a;word-break:break-word">
                    <span style="color:#555">${esc(e.ts)}</span> ${esc(e.msg)}
                </div>`;
            }
            html += `</div>`;
        }
    }

    // Dernières décisions par route
    if (d.last_decisions.length > 0) {
        html += `<div style="color:#00cccc;font-size:0.72em;font-weight:700;letter-spacing:1px;margin:14px 0 6px">DERNIÈRES DÉCISIONS</div>`;
        for (const dec of d.last_decisions) {
            const c = dec.verdict === 'GO' ? '#33cc55' : '#888';
            const routeM = dec.msg.match(/^\[([^\]]+)\//);
            const route = routeM ? routeM[1] : '?';
            html += `<div style="font-family:monospace;font-size:0.72em;color:#777;padding:3px 0;border-bottom:1px solid #1a1a1a;word-break:break-word">
                <span style="color:${c};font-weight:700">${esc(dec.verdict)}</span>
                <span style="color:#00cccc88"> [${esc(route)}]</span>
                <span style="color:#555"> ${esc(dec.ts)}</span><br>${esc(dec.msg)}
            </div>`;
        }
    }

    return html;
}

// ── Modal détail zone stockage ───────────────────────────────
let _stockageCache = [];

function openStockModal(zoneName) {
    const z = _stockageCache.find(z => z.zone === zoneName);
    if (!z) return;
    const fill = z.fillRate ?? 0;
    const fillColor = fill >= 80 ? '#ee3333' : fill >= 50 ? '#eeee22' : '#22ee22';

    document.getElementById('stock-modal-title').textContent = zoneName;
    const fillEl = document.getElementById('stock-modal-fill');
    fillEl.textContent = fill + '%';
    fillEl.style.color = fillColor;
    document.getElementById('stock-modal-bar').style.cssText = `width:${fill}%;background:${fillColor}`;
    document.getElementById('stock-modal-meta').textContent =
        `${z.slotsUsed ?? '?'} / ${z.slotsTotal ?? '?'} slots · ${z.totalItems ?? '?'} items`;

    let bodyHtml;
    if (z.subzones && z.subzones.length > 1) {
        bodyHtml = z.subzones.map(sz => {
            const szFill = sz.fillRate ?? 0;
            const szColor = szFill >= 80 ? '#ee3333' : szFill >= 50 ? '#eeee22' : '#22ee22';
            const allSzItems = toArr(sz.items).length ? toArr(sz.items) : toArr(sz.topItems);
            return `<div class="stock-modal-subzone">
                <div class="stock-modal-subzone-header">
                    <span class="stock-modal-subzone-name">${esc(sz.name)}</span>
                    <span class="stock-fill" style="color:${szColor}">${szFill}%</span>
                </div>
                <div class="stock-modal-subzone-meta">${sz.slotsUsed ?? '?'} / ${sz.slotsTotal ?? '?'} slots · ${sz.totalItems ?? '?'} items</div>
                ${allSzItems.length
                    ? allSzItems.map(it => `<div class="stock-item-row"><span class="stock-item-name">${esc(it.name)}</span><span class="stock-item-count">${it.count}</span><span class="stock-item-pct">${it.pct}%</span></div>`).join('')
                    : '<div class="stock-empty">Aucun item</div>'}
            </div>`;
        }).join('');
    } else {
        const allItems = toArr(z.items).length ? toArr(z.items) : toArr(z.topItems);
        bodyHtml = allItems.length
            ? allItems.map(it => `
                <div class="stock-item-row">
                    <span class="stock-item-name">${esc(it.name)}</span>
                    <span class="stock-item-count">${it.count}</span>
                    <span class="stock-item-pct">${it.pct}%</span>
                </div>`).join('')
            : '<div class="stock-empty">Aucun item</div>';
    }
    document.getElementById('stock-modal-body').innerHTML = bodyHtml;

    document.getElementById('stock-modal').classList.add('open');
}

function closeStockModal() {
    document.getElementById('stock-modal').classList.remove('open');
}

// ── Toggle vue stockage (compact / détaillée) ─────────────────
let _stockCompact = true;

function toggleStockView() {
    _stockCompact = !_stockCompact;
    document.getElementById('stock-view-btn').textContent = _stockCompact ? 'Vue détaillée' : 'Vue compacte';
    renderStockageInfo(_stockageZoneConfig, _stockageCentralCache);
}

// ── Purge manuelle des zones inactives ────────────────────────
async function purgeStockage() {
    const btn = document.querySelector('.stock-purge-btn');
    btn.disabled = true;
    btn.textContent = '...';
    try {
        const r = await fetch('/api/stockage-purge', { method: 'POST' });
        const d = await r.json();
        btn.textContent = d.removed > 0 ? `${d.removed} supprimée(s)` : 'Rien à purger';
    } catch(e) {
        btn.textContent = 'Erreur';
    }
    setTimeout(() => { btn.disabled = false; btn.textContent = 'Purger les inactives'; }, 2500);
}

// ── Ordre des cards stockage (persisté côté serveur) ─────────
let _stockageOrder = [];

function _sortByOrder(stockage) {
    if (!_stockageOrder.length) return stockage;
    const sorted = [];
    _stockageOrder.forEach(name => {
        const z = stockage.find(z => (z.zone || '?') === name);
        if (z) sorted.push(z);
    });
    stockage.forEach(z => { if (!_stockageOrder.includes(z.zone || '?')) sorted.push(z); });
    return sorted;
}

let _dragSetup = false;
let _isDragging = false;
function _setupStockageDrag() {
    if (_dragSetup) return;
    _dragSetup = true;
    const grid = document.getElementById('stockage-grid');
    let dragSrc = null;

    grid.addEventListener('dragstart', e => {
        const card = e.target.closest('.stock-card[draggable]');
        if (!card) return;
        dragSrc = card;
        _isDragging = true;
        card.classList.add('dragging');
        e.dataTransfer.effectAllowed = 'move';
    });
    grid.addEventListener('dragend', () => {
        _isDragging = false;
        grid.querySelectorAll('.stock-card').forEach(c => {
            c.classList.remove('dragging', 'drag-over');
        });
        dragSrc = null;
    });
    grid.addEventListener('dragover', e => {
        e.preventDefault();
        const card = e.target.closest('.stock-card[draggable]');
        if (!card || card === dragSrc) return;
        grid.querySelectorAll('.stock-card').forEach(c => c.classList.remove('drag-over'));
        card.classList.add('drag-over');
    });
    grid.addEventListener('dragleave', e => {
        const card = e.target.closest('.stock-card');
        if (card) card.classList.remove('drag-over');
    });
    grid.addEventListener('drop', e => {
        e.preventDefault();
        const card = e.target.closest('.stock-card[draggable]');
        if (!card || card === dragSrc) return;
        const cards = [...grid.querySelectorAll('.stock-card[draggable]')];
        const si = cards.indexOf(dragSrc), di = cards.indexOf(card);
        grid.insertBefore(dragSrc, si < di ? card.nextSibling : card);
        _stockageOrder = [...grid.querySelectorAll('.stock-card[draggable]')].map(c => c.dataset.zone);
        fetch('/api/stockage-order', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(_stockageOrder) });
        grid.querySelectorAll('.stock-card').forEach(c => c.classList.remove('drag-over'));
    });
}

// ── Rendu stockage ───────────────────────────────────────────
function renderStockage(stockage) {
    const grid = document.getElementById('stockage-grid');
    if (!grid) return;
    _stockageCache = stockage;
    if (!stockage || !stockage.length) {
        grid.innerHTML = '<div class="stock-empty">Aucune zone de stockage connectée</div>';
        return;
    }
    if (_isDragging) return;  // ne pas re-render pendant un drag en cours
    const sorted = _sortByOrder(stockage);
    const now = Date.now() / 1000;
    grid.innerHTML = sorted.map(z => {
        const stale = z.server_ts && (now - z.server_ts) > 120;
        const fill = z.fillRate ?? 0;
        const fillColor = fill >= 80 ? '#ee3333' : fill >= 50 ? '#eeee22' : '#22ee22';
        let itemsBlock;
        if (z.subzones && z.subzones.length > 1) {
            if (_stockCompact) {
                // Compact : top 3 sous-zones par remplissage, barre + % seulement
                const topSz = [...z.subzones]
                    .sort((a, b) => (b.fillRate ?? 0) - (a.fillRate ?? 0))
                    .slice(0, 3);
                itemsBlock = `<div class="stock-subzones">${topSz.map(sz => {
                    const szFill = sz.fillRate ?? 0;
                    const szColor = szFill >= 80 ? '#ee3333' : szFill >= 50 ? '#eeee22' : '#22ee22';
                    return `<div class="stock-subzone">
                        <div class="stock-subzone-header"><span class="stock-subzone-name">${esc(sz.name)}</span><span class="stock-subzone-fill" style="color:${szColor}">${szFill}%</span></div>
                        <div class="stock-subzone-bar-bg"><div class="stock-subzone-bar" style="width:${szFill}%;background:${szColor}"></div></div>
                    </div>`;
                }).join('')}</div>`;
            } else {
                // Détaillé : toutes les sous-zones avec top 3 ressources
                itemsBlock = `<div class="stock-subzones">${z.subzones.map(sz => {
                    const szFill = sz.fillRate ?? 0;
                    const szColor = szFill >= 80 ? '#ee3333' : szFill >= 50 ? '#eeee22' : '#22ee22';
                    const szTop = toArr(sz.topItems);
                    return `<div class="stock-subzone">
                        <div class="stock-subzone-header"><span class="stock-subzone-name">${esc(sz.name)}</span><span class="stock-subzone-fill" style="color:${szColor}">${szFill}%</span></div>
                        <div class="stock-subzone-bar-bg"><div class="stock-subzone-bar" style="width:${szFill}%;background:${szColor}"></div></div>
                        <div class="stock-subzone-meta">${sz.slotsUsed ?? '?'} / ${sz.slotsTotal ?? '?'} slots · ${sz.totalItems ?? '?'} items</div>
                        ${szTop.map(it => `<div class="stock-item-row"><span class="stock-item-name">${esc(it.name)}</span><span class="stock-item-count">${it.count}</span><span class="stock-item-pct">${it.pct}%</span></div>`).join('')}
                    </div>`;
                }).join('')}</div>`;
            }
        } else {
            const topItems = toArr(z.topItems);
            const inner = topItems.length
                ? topItems.map(it => `<div class="stock-item-row"><span class="stock-item-name">${esc(it.name)}</span><span class="stock-item-count">${it.count}</span><span class="stock-item-pct">${it.pct}%</span></div>`).join('')
                : '<div class="stock-empty">Aucun item</div>';
            itemsBlock = `<div class="stock-items">${inner}</div>`;
        }
        return `
            <div class="stock-card${stale ? ' stock-stale' : ''}" draggable="true" data-zone="${esc(z.zone || '?')}" onclick="openStockModal('${esc(z.zone || '?')}')" title="Voir tous les items">
                <div class="stock-card-header">
                    <span class="stock-zone">${esc(z.zone || '?')}${z.duplicate ? ' ⚠️' : ''}</span>
                    <span class="stock-fill" style="color:${fillColor}">${fill}%</span>
                </div>
                <div class="stock-bar-bg"><div class="stock-bar" style="width:${fill}%;background:${fillColor}"></div></div>
                <div class="stock-meta">${z.slotsUsed ?? '?'} / ${z.slotsTotal ?? '?'} slots · ${z.totalItems ?? '?'} items</div>
                ${itemsBlock}
            </div>`;
    }).join('');
    _setupStockageDrag();
}

// ── INFO zones configurées ────────────────────────────────────
function renderStockageInfo(zoneConfig, centralData) {
    const grid = document.getElementById('stockage-grid');
    if (!grid) return;
    const zones = zoneConfig && zoneConfig.zones;
    if (!zones || !zones.length) {
        grid.innerHTML = '<div class="stock-empty">Aucune zone configurée — définissez vos zones dans l\'onglet Configuration</div>';
        return;
    }
    // Lookup conteneurs par nick / Container lookup by nick
    const byNick = {};
    for (const c of ((centralData && centralData.containers) || [])) byNick[c.nick] = c;

    const now = Date.now() / 1000;
    const stale = centralData && centralData.server_ts && (now - centralData.server_ts) > 120;

    function aggr(nicks) {
        let slotsTotal = 0, slotsUsed = 0, totalItems = 0;
        const items = {};
        for (const nick of nicks) {
            const c = byNick[nick]; if (!c) continue;
            slotsTotal += c.slotsTotal || 0;
            slotsUsed  += c.slotsUsed  || 0;
            totalItems += c.totalItems  || 0;
            for (const [id, item] of Object.entries(c.items || {})) {
                if (!items[id]) items[id] = { name: item.name, count: 0 };
                items[id].count += item.count;
            }
        }
        const fillRate = slotsTotal > 0 ? Math.floor(slotsUsed / slotsTotal * 1000) / 10 : 0;
        return { slotsTotal, slotsUsed, fillRate, totalItems, items };
    }

    grid.innerHTML = zones.map(zone => {
        const allNicks = [...(zone.containers || []), ...((zone.subzones || []).flatMap(sz => sz.containers || []))];
        const za = aggr(allNicks);
        const fill = za.fillRate, fillColor = fill >= 80 ? '#ee3333' : fill >= 50 ? '#eeee22' : '#22ee22';

        let itemsBlock;
        if (zone.subzones && zone.subzones.length > 0) {
            const parts = [];
            if (zone.containers && zone.containers.length) parts.push({ name: 'Principal', ...aggr(zone.containers) });
            for (const sz of zone.subzones) parts.push({ name: sz.name, ...aggr(sz.containers || []) });
            itemsBlock = `<div class="stock-subzones">${parts.map(sz => {
                const sf = sz.fillRate ?? 0, sc = sf >= 80 ? '#ee3333' : sf >= 50 ? '#eeee22' : '#22ee22';
                return `<div class="stock-subzone">
                    <div class="stock-subzone-header"><span class="stock-subzone-name">${esc(sz.name)}</span><span class="stock-subzone-fill" style="color:${sc}">${sf}%</span></div>
                    <div class="stock-subzone-bar-bg"><div class="stock-subzone-bar" style="width:${sf}%;background:${sc}"></div></div>
                    <div class="stock-subzone-meta">${sz.slotsUsed} / ${sz.slotsTotal} slots · ${sz.totalItems} items</div>
                </div>`;
            }).join('')}</div>`;
        } else {
            const top = Object.values(za.items).sort((a, b) => b.count - a.count).slice(0, 5);
            itemsBlock = `<div class="stock-items">${top.length
                ? top.map(it => `<div class="stock-item-row"><span class="stock-item-name">${esc(it.name)}</span><span class="stock-item-count">${it.count}</span></div>`).join('')
                : '<div class="stock-empty">Aucun item</div>'}</div>`;
        }
        return `
            <div class="stock-card${stale ? ' stock-stale' : ''}">
                <div class="stock-card-header"><span class="stock-zone">${esc(zone.name)}</span><span class="stock-fill" style="color:${fillColor}">${fill}%</span></div>
                <div class="stock-bar-bg"><div class="stock-bar" style="width:${fill}%;background:${fillColor}"></div></div>
                <div class="stock-meta">${za.slotsUsed} / ${za.slotsTotal} slots · ${za.totalItems} items</div>
                ${itemsBlock}
            </div>`;
    }).join('');
}

// ── Config DnD ───────────────────────────────────────────────
let _stkZones    = [];     // [{id, name, containers:[nick], subzones:[{id, name, containers:[nick]}]}]
let _stkAllConts = [];     // [{satellite, nick, slotsTotal, slotsUsed, fillRate, totalItems}]
let _stkDragNick = null;   // nick du conteneur en cours de drag / nick of dragged container
let _stkIdCnt    = 0;

function _stkAssigned() {
    const s = new Set();
    for (const z of _stkZones) {
        z.containers.forEach(n => s.add(n));
        z.subzones.forEach(sz => sz.containers.forEach(n => s.add(n)));
    }
    return s;
}
function _stkRemoveNick(nick) {
    for (const z of _stkZones) {
        z.containers = z.containers.filter(n => n !== nick);
        z.subzones.forEach(sz => { sz.containers = sz.containers.filter(n => n !== nick); });
    }
}
function _stkDragStart(ev, nick) { _stkDragNick = nick; ev.target.classList.add('dragging'); ev.dataTransfer.effectAllowed = 'move'; }
function _stkDragEnd(ev)         { ev.target.classList.remove('dragging'); _stkDragNick = null; }
function _stkLeave(ev)           { if (!ev.currentTarget.contains(ev.relatedTarget)) ev.currentTarget.classList.remove('drag-over'); }
function _stkDrop(ev, zoneId, szId) {
    ev.preventDefault();
    ev.currentTarget.classList.remove('drag-over');
    if (!_stkDragNick) return;
    _stkRemoveNick(_stkDragNick);
    if (zoneId >= 0) {
        const z = _stkZones.find(z => z.id === zoneId);
        if (!z) return;
        if (szId < 0) z.containers.push(_stkDragNick);
        else { const sz = z.subzones.find(s => s.id === szId); if (sz) sz.containers.push(_stkDragNick); }
    }
    _stkRenderConfig();
}
function _stkAddZone()             { _stkZones.push({ id: _stkIdCnt++, name: 'Nouvelle zone', containers: [], subzones: [] }); _stkRenderConfig(); }
function _stkRemoveZone(id)        { _stkZones = _stkZones.filter(z => z.id !== id); _stkRenderConfig(); }
function _stkAddSubzone(zid)       { const z = _stkZones.find(z => z.id === zid); if (z) z.subzones.push({ id: _stkIdCnt++, name: 'Sous-zone', containers: [] }); _stkRenderConfig(); }
function _stkRemoveSubzone(zid, sid) { const z = _stkZones.find(z => z.id === zid); if (z) z.subzones = z.subzones.filter(s => s.id !== sid); _stkRenderConfig(); }
function _stkRenameZone(id, v)       { const z = _stkZones.find(z => z.id === id); if (z) z.name = v; }
function _stkRenameSz(zid, sid, v)   { const z = _stkZones.find(z => z.id === zid); if (z) { const s = z.subzones.find(s => s.id === sid); if (s) s.name = v; } }

function _stkContCard(c, zoneId, szId) {
    const fill = c.fillRate ?? 0, color = fill >= 80 ? '#ee3333' : fill >= 50 ? '#eeee22' : '#22ee22';
    return `<div class="stk-cont-card" draggable="true"
                 ondragstart="_stkDragStart(event,'${esc(c.nick)}')" ondragend="_stkDragEnd(event)"
                 title="${esc(c.satellite || '')} — ${c.slotsUsed ?? 0}/${c.slotsTotal ?? 0} slots">
        <div class="stk-cont-nick">${esc(c.nick)}</div>
        <div class="stk-cont-meta">${esc(c.satellite || '')}${fill > 0 ? ' · ' + fill + '%' : ''}</div>
        ${fill > 0 ? `<div class="stk-cont-bar-bg"><div class="stk-cont-bar" style="width:${fill}%;background:${color}"></div></div>` : ''}
    </div>`;
}
function _stkDropArea(zoneId, szId, nickList) {
    const cards = nickList.map(nick => {
        const c = _stkAllConts.find(c => c.nick === nick) || { nick, satellite: '', fillRate: 0, slotsTotal: 0, slotsUsed: 0 };
        return _stkContCard(c, zoneId, szId);
    }).join('');
    return `<div class="stk-drop-area"
                 ondragover="event.preventDefault()"
                 ondragenter="this.classList.add('drag-over')"
                 ondragleave="_stkLeave(event)"
                 ondrop="_stkDrop(event,${zoneId},${szId})">
        ${cards}<div class="stk-drop-hint">${nickList.length ? '' : 'Glisser ici'}</div>
    </div>`;
}

function _stkRenderConfig() {
    const el = document.getElementById('stockage-config-content');
    if (!el) return;
    const assigned = _stkAssigned();
    const pool = _stkAllConts.filter(c => !assigned.has(c.nick));

    const zonesHtml = _stkZones.map(z => `
        <div class="stk-zone-card">
            <div class="stk-zone-header">
                <input class="stk-zone-name-input" value="${esc(z.name)}" placeholder="Nom de la zone" onchange="_stkRenameZone(${z.id},this.value)">
                <button class="stk-btn-sm" onclick="_stkAddSubzone(${z.id})">+ Sous-zone</button>
                <button class="stk-btn-sm stk-btn-del" onclick="_stkRemoveZone(${z.id})">✕</button>
            </div>
            ${_stkDropArea(z.id, -1, z.containers)}
            ${z.subzones.map(sz => `
                <div class="stk-subzone-card">
                    <div class="stk-subzone-header">
                        <input class="stk-subzone-name-input" value="${esc(sz.name)}" placeholder="Nom" onchange="_stkRenameSz(${z.id},${sz.id},this.value)">
                        <button class="stk-btn-sm stk-btn-del" onclick="_stkRemoveSubzone(${z.id},${sz.id})">✕</button>
                    </div>
                    ${_stkDropArea(z.id, sz.id, sz.containers)}
                </div>`).join('')}
        </div>`).join('') || '<div class="stock-empty" style="margin-top:8px">Cliquez sur "+ Zone" pour commencer</div>';

    const poolCards = pool.map(c => _stkContCard(c, -1, -1)).join('')
        || '<div class="stk-drop-hint">Tous assignés</div>';

    el.innerHTML = `
        <div class="stk-cfg-actions">
            <button class="stock-purge-btn" onclick="_stkAddZone()">+ Zone</button>
            <button class="stock-purge-btn" onclick="_saveStockageZoneConfig()">Sauvegarder</button>
            <span id="stk-cfg-status" style="font-size:0.78em;color:#888"></span>
        </div>
        <div class="stk-cfg-layout">
            <div class="stk-cfg-pool">
                <div class="stk-cfg-pool-title">Disponibles</div>
                <div class="stk-drop-area" style="flex-direction:column"
                     ondragover="event.preventDefault()"
                     ondragenter="this.classList.add('drag-over')"
                     ondragleave="_stkLeave(event)"
                     ondrop="_stkDrop(event,-1,-1)">${poolCards}</div>
            </div>
            <div class="stk-cfg-zones">${zonesHtml}</div>
        </div>`;
}

function renderStockageConfig(discovery, centralData, zoneConfig) {
    // Construire la liste des conteneurs depuis les données CENTRAL ou la découverte
    // Build container list from CENTRAL data or discovery
    if (centralData && centralData.containers && centralData.containers.length) {
        _stkAllConts = centralData.containers;
    } else {
        _stkAllConts = (discovery || []).flatMap(d =>
            (d.containers || []).map(nick => ({ satellite: d.satellite, nick, slotsTotal: 0, slotsUsed: 0, fillRate: 0, totalItems: 0, items: {} }))
        );
    }
    // Init zones depuis config serveur / Init zones from server config
    const cfgZones = zoneConfig && zoneConfig.zones;
    _stkIdCnt = 0; _stkZones = [];
    if (cfgZones && cfgZones.length) {
        for (const z of cfgZones) {
            _stkZones.push({
                id: _stkIdCnt++, name: z.name,
                containers: [...(z.containers || [])],
                subzones: (z.subzones || []).map(sz => ({ id: _stkIdCnt++, name: sz.name, containers: [...(sz.containers || [])] }))
            });
        }
    }
    _stkRenderConfig();
}

function _saveStockageZoneConfig() {
    const config = {
        zones: _stkZones.map(z => ({
            name: z.name,
            containers: z.containers,
            subzones: z.subzones.map(sz => ({ name: sz.name, containers: sz.containers }))
        }))
    };
    fetch('/api/stockage/zone-config', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(config) })
        .then(r => {
            const st = document.getElementById('stk-cfg-status');
            if (!r.ok) { if (st) st.textContent = `Erreur HTTP ${r.status}`; return; }
            _stockageZoneConfig = config;
            _prevJson.stockage_info = null;  // forcer re-render INFO / force INFO re-render
            if (st) { st.textContent = 'Sauvegardé ✓'; setTimeout(() => { if (st) st.textContent = ''; }, 2000); }
        })
        .catch(() => { const st = document.getElementById('stk-cfg-status'); if (st) st.textContent = 'Erreur réseau'; });
}

// ── Power ─────────────────────────────────────────────────────
const _POWER_HIST_MAX = 120;
const _powerHist = { prod: [], cons: [], cap: [], maxCons: [] };
let _lastPowerHistTime = 0;  // timestamp client (Date.now) du dernier ajout historique

function _fmtTime(sec) {
    sec = Math.max(0, Math.floor(sec || 0));
    const h = Math.floor(sec / 3600);
    const m = Math.floor(sec / 60) % 60;
    const s = sec % 60;
    if (h > 0) return `${h}h${String(m).padStart(2,'0')}m`;
    return `${m}m${String(s).padStart(2,'0')}s`;
}

function renderPower(p, loggerUpdatedAt) {
    const nodata = document.getElementById('pw-nodata');
    if (!p) {
        nodata.style.display = '';
        document.getElementById('pw-stale').textContent = '';
        return;
    }
    nodata.style.display = 'none';

    // Indicateur fraîcheur (basé sur logger_updated_at — timestamp Python Unix)
    const staleEl = document.getElementById('pw-stale');
    if (loggerUpdatedAt) {
        const ageSec = Math.round(Date.now() / 1000 - loggerUpdatedAt);
        staleEl.textContent = `MAJ: ${ageSec}s`;
        staleEl.style.color = ageSec > 30 ? '#ee3333' : '#555';
    } else {
        staleEl.textContent = '';
    }

    // Stats MW
    const fmtMW = v => v != null ? (+v).toFixed(1) + ' MW' : '—';
    document.getElementById('pw-prod').textContent = fmtMW(p.prod);
    document.getElementById('pw-cons').textContent = fmtMW(p.cons);
    document.getElementById('pw-cap').textContent  = fmtMW(p.cap);
    document.getElementById('pw-maxc').textContent = fmtMW(p.maxCons);

    // Barre charge (conso / capacité)
    const loadPct = p.cap > 0 ? Math.min(100, Math.round(p.cons / p.cap * 100)) : 0;
    const loadCol = loadPct > 90 ? '#ee3333' : loadPct > 75 ? '#eeee22' : '#22ee22';
    document.getElementById('pw-load-bar').style.cssText = `width:${loadPct}%;background:${loadCol}`;
    document.getElementById('pw-load-pct').textContent   = loadPct + '%';

    // Batteries
    const battEl = document.getElementById('pw-batt');
    if (p.hasBatt) {
        battEl.style.display = '';
        const pct = +(p.battPct ?? 0);
        const col = pct < 33 ? '#ee3333' : pct < 80 ? '#ffaa22' : '#22ee22';
        document.getElementById('pw-batt-pct').textContent   = pct.toFixed(1) + '%';
        document.getElementById('pw-batt-pct').style.color   = col;
        document.getElementById('pw-batt-store').textContent =
            `${(+p.battStore).toFixed(1)} / ${(+p.battCap).toFixed(1)} MWh`;
        document.getElementById('pw-batt-bar').style.cssText =
            `width:${Math.min(100, pct)}%;background:${col}`;

        let fluxHtml = '';
        if ((p.battOut || 0) > 0) {
            fluxHtml = `<span style="color:#ee3333">▼ Décharge ${(+p.battOut).toFixed(1)} MW`;
            if (p.tEmpty > 0) fluxHtml += ` &nbsp;·&nbsp; Vide dans ${_fmtTime(p.tEmpty)}`;
            fluxHtml += '</span>';
        } else if ((p.battIn || 0) > 0) {
            fluxHtml = `<span style="color:#22ee22">▲ Charge ${(+p.battIn).toFixed(1)} MW`;
            if (p.tFull > 0) fluxHtml += ` &nbsp;·&nbsp; Plein dans ${_fmtTime(p.tFull)}`;
            fluxHtml += '</span>';
        } else {
            fluxHtml = '<span style="color:#555">En attente</span>';
        }
        document.getElementById('pw-batt-flux').innerHTML = fluxHtml;
    } else {
        battEl.style.display = 'none';
    }

    // Historique : une entrée toutes les 5s côté client (indépendant du ts POWER_MON)
    // History: one entry every 5s client-side (independent of POWER_MON ts)
    const now = Date.now();
    if (now - _lastPowerHistTime >= 5000) {
        _lastPowerHistTime = now;
        ['prod', 'cons', 'cap', 'maxCons'].forEach(k => {
            _powerHist[k].push(+(p[k] || 0));
            if (_powerHist[k].length > _POWER_HIST_MAX) _powerHist[k].shift();
        });
        _drawPowerChart();  // redraw uniquement quand l'historique change / only redraw when history updates
    } else if (_powerHist.prod.length < 2) {
        _drawPowerChart();  // premier rendu : affiche le message d'attente / first render: show waiting message
    }
}

function _drawPowerChart() {
    const canvas = document.getElementById('pw-chart');
    if (!canvas) return;
    canvas.width  = canvas.offsetWidth  || 800;
    canvas.height = canvas.offsetHeight || 400;
    const ctx = canvas.getContext('2d');
    const w = canvas.width, h = canvas.height;
    const P = { t: 24, r: 12, b: 24, l: 52 };
    const cw = w - P.l - P.r, ch = h - P.t - P.b;

    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = '#0d0d0d';
    ctx.fillRect(0, 0, w, h);

    const n = _powerHist.prod.length;
    if (n < 2) {
        ctx.fillStyle = '#444'; ctx.font = '13px monospace'; ctx.textAlign = 'center';
        ctx.fillText('En attente des données…', w / 2, h / 2 + 5);
        return;
    }

    // Max
    let maxVal = 10;
    ['prod', 'cons', 'cap', 'maxCons'].forEach(k => {
        maxVal = Math.max(maxVal, Math.max(..._powerHist[k]));
    });
    maxVal *= 1.12;

    // Grille Y
    const GRID = 4;
    ctx.strokeStyle = '#1a1a1a'; ctx.lineWidth = 1;
    ctx.fillStyle = '#444'; ctx.font = '11px monospace'; ctx.textAlign = 'right';
    for (let i = 0; i <= GRID; i++) {
        const y = P.t + ch - (i / GRID) * ch;
        ctx.beginPath(); ctx.moveTo(P.l, y); ctx.lineTo(P.l + cw, y); ctx.stroke();
        ctx.fillText(Math.round(maxVal * i / GRID) + ' MW', P.l - 4, y + 4);
    }

    // Courbes (ordre : cap gris en dernier pour ne pas masquer les autres)
    const series = [
        { key: 'cap',     color: '#444444', label: 'Capacité',   lw: 1.5 },
        { key: 'maxCons', color: '#4499ff', label: 'Conso max',  lw: 1.5 },
        { key: 'prod',    color: '#ffffff', label: 'Production', lw: 2.5 },
        { key: 'cons',    color: '#ff8800', label: 'Conso',      lw: 2.5 },
    ];
    series.forEach(({ key, color, lw }) => {
        const data = _powerHist[key];
        if (!data.length) return;
        ctx.strokeStyle = color; ctx.lineWidth = lw;
        ctx.beginPath();
        data.forEach((v, i) => {
            const x = P.l + (i / (n - 1)) * cw;
            const y = P.t + ch - (v / maxVal) * ch;
            i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
        });
        ctx.stroke();
    });

    // Légende (coin haut droit)
    ctx.textAlign = 'right';
    let lx = P.l + cw;
    series.slice().reverse().forEach(({ color, label }) => {
        ctx.fillStyle = color; ctx.font = 'bold 11px monospace';
        ctx.fillText(label, lx, P.t + 14);
        lx -= ctx.measureText(label).width + 14;
    });
}

// ── Diff par section — évite les renders inutiles si les données n'ont pas changé
// ── Per-section diff — skips renders when data is unchanged
const _prevJson = { trains: null, trips: null, stats: null, stockage_info: null, stockage_discovery: null, power: null, dispatch: null };
let _stockageZoneConfig  = [];   // config persistée : [{satellite, zone, label}, ...]
let _stockageCentralCache = null; // dernières données CENTRAL pour toggleStockView

// ── Boucle de rafraîchissement ───────────────────────────────
let errors = 0;

// ── Perf debug — mesure fetch + render, log console + footer ─
let _perfLog = '';  // dernière ligne de perf, affichée dans le footer

function _t(label, fn) {
    const t0 = performance.now();
    fn();
    return Math.round(performance.now() - t0);
}

async function refresh() {
    const t0 = performance.now();
    try {
        const tFetch0 = performance.now();
        const r = await fetch('/api/data');
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const data = await r.json();
        const tFetch = Math.round(performance.now() - tFetch0);
        errors = 0;

        const st = document.getElementById('status');
        if (!data.logger_updated_at) {
            st.innerHTML = '● <span class="status-lbl">En attente</span>';
            st.className = '';
        } else {
            const ageSec = Math.round((Date.now() / 1000) - data.logger_updated_at);
            let ageStr = ageSec < 60 ? `${ageSec}s` : `${Math.floor(ageSec/60)}min${ageSec%60 ? ' '+ageSec%60+'s' : ''}`;
            if (ageSec <= 10) {
                st.innerHTML = `● <span class="status-lbl">En direct</span>  (${ageStr})`;
                st.className = 'ok';
            } else if (ageSec <= 60) {
                st.innerHTML = `● <span class="status-lbl">Retard</span>  (${ageStr})`;
                st.className = 'late';
            } else {
                st.innerHTML = `● <span class="status-lbl">Hors ligne</span>  (${ageStr})`;
                st.className = 'err';
            }
        }

        if (data.site_title) {
            document.title = data.site_title;
            document.querySelector('header h1').textContent = data.site_title;
        }
        if (Array.isArray(data.stockage_order) && !_isDragging) _stockageOrder = data.stockage_order;

        // Diff par section : render uniquement si le payload a changé
        // Per-section diff: only render if payload changed
        const _tj  = JSON.stringify(data.trains        || []);
        const _rj  = JSON.stringify(data.trips         || {});
        const _sj  = JSON.stringify(data.stats         || {});
        const _zij  = JSON.stringify({ c: data.stockage_central || null, z: data.stockage_zone_config || [] });
        const _zdj  = JSON.stringify(data.stockage_discovery || []);
        const _pj   = JSON.stringify(data.power              || null);
        const _dj  = JSON.stringify({ d: data.dispatch || null, r: data.dispatch_routes ?? null });

        const rTimes = {};
        if (_tj !== _prevJson.trains)   { _prevJson.trains   = _tj;  rTimes.trains   = _t('trains',   () => renderTrains(data.trains || [])); }
        if (_rj !== _prevJson.trips)    { _prevJson.trips    = _rj;  rTimes.trips    = _t('trips',    () => renderTrips(data.trips || {})); }
        if (_sj !== _prevJson.stats)    { _prevJson.stats    = _sj;  rTimes.stats    = _t('stats',    () => renderStats(data.trains || [], data.stats || {}, data.logger_updated_at)); }
        if (_zij !== _prevJson.stockage_info) {
            _prevJson.stockage_info = _zij;
            _stockageZoneConfig  = data.stockage_zone_config || _stockageZoneConfig;
            _stockageCentralCache = data.stockage_central || null;
            rTimes.stockage = _t('stk-info', () => renderStockageInfo(_stockageZoneConfig, _stockageCentralCache));
            // Mettre à jour les fill rates dans le pool config si la page est visible
            // Update fill rates in config pool if config page is visible
            if (_stockageCentralCache && _stockageCentralCache.containers) {
                _stkAllConts = _stockageCentralCache.containers;
                if (document.getElementById('page-stockage-config').classList.contains('active')) _stkRenderConfig();
            }
        }
        if (_zdj !== _prevJson.stockage_discovery) {
            _prevJson.stockage_discovery = _zdj;
            _t('stk-cfg', () => renderStockageConfig(data.stockage_discovery || [], _stockageCentralCache, _stockageZoneConfig));
        }
        if (_pj !== _prevJson.power)    { _prevJson.power    = _pj;  rTimes.power    = _t('power',    () => renderPower(data.power || null, data.logger_updated_at)); }
        _dpUpdateLists(data);
        if (_dj !== _prevJson.dispatch) { _prevJson.dispatch = _dj;  rTimes.dispatch = _t('dispatch', () => renderDispatch(data.dispatch || null, data.dispatch_routes ?? null)); }
        if (document.getElementById('page-logs').classList.contains('active')) { refreshLogs(); }

        const tTotal = Math.round(performance.now() - t0);
        const rParts = Object.entries(rTimes).map(([k, v]) => `${k}:${v}ms`).join(' ');
        _perfLog = `fetch:${tFetch}ms${rParts ? '  rendu:['+rParts+']' : '  rendu:skipped'}  total:${tTotal}ms`;
        if (tTotal > 200) console.warn('[PERF slow]', _perfLog);

        document.getElementById('footer').textContent =
            new Date().toLocaleTimeString() + '  |  ' + _perfLog;

        if (data.error) console.warn('LOGGER:', data.error);
    } catch (e) {
        errors++;
        const st = document.getElementById('status');
        st.textContent = `⚠ Erreur serveur (${errors})`;
        st.className = 'err';
    }
}

// ── DISPATCH ─────────────────────────────────────────────────
let _dpRoutesConfig  = [];   // config routes — source de vérité pour l'affichage
let _dpLiveRoutes    = null; // état temps réel depuis DISPATCH (via LOGGER)
let _dpEditingIndex  = -1;   // index route en cours d'édition (-1 = aucune)
let _dpKnownStations = new Set();
let _dpKnownBuffers  = new Map();  // Map<value, label> — value=nom réel, label=affichage avec parent / value=actual name, label=display with parent
let _dpKnownTrains   = new Set();

function _dpUpdateLists(data) {
    if (data.trips) {
        Object.values(data.trips).forEach(segs => {
            Object.keys(segs).forEach(seg => {
                const m = seg.match(/^(.+)->(.+)$/);
                if (m) { _dpKnownStations.add(m[1]); _dpKnownStations.add(m[2]); }
            });
        });
    }
    if (Array.isArray(data.trains)) {
        data.trains.forEach(t => {
            if (t.station) _dpKnownStations.add(t.station);
            if (t.name)    _dpKnownTrains.add(t.name);
        });
    }
    if (Array.isArray(data.stockage)) {
        data.stockage.forEach(z => {
            if (!z.zone) return;
            _dpKnownBuffers.set(z.zone, z.zone);  // zone principale / main zone
            // Sous-zones : valeur = "(PARENT) nom" (clé unique, une seule ligne dans datalist)
            // Sub-zones: value = "(PARENT) name" (unique key, single line in datalist)
            if (z.subzones) z.subzones.forEach(sz => {
                if (sz.name) { const lbl = `(${z.zone}) ${sz.name}`; _dpKnownBuffers.set(lbl, lbl); }
            });
        });
    }
    const _refreshDl = (id, set) => {
        const dl = document.getElementById(id);
        if (!dl) return;
        const existing = new Set([...dl.options].map(o => o.value));
        [...set].filter(v => !existing.has(v)).sort().forEach(v => {
            const opt = document.createElement('option'); opt.value = v; dl.appendChild(opt);
        });
    };
    // Datalist buffers : map value→label pour affichage sous-zones / buffer datalist: value→label for sub-zone display
    const dlBuf = document.getElementById('dp-dl-buffers');
    if (dlBuf) {
        const existingBuf = new Set([...dlBuf.options].map(o => o.value));
        [..._dpKnownBuffers.entries()]
            .filter(([v]) => !existingBuf.has(v))
            .sort(([, la], [, lb]) => la.localeCompare(lb))
            .forEach(([value]) => {
                const opt = document.createElement('option');
                opt.value = value;  // value = label → une seule ligne dans Chrome / value = label → single line in Chrome
                dlBuf.appendChild(opt);
            });
    }
    _refreshDl('dp-dl-stations', _dpKnownStations);
    _refreshDl('dp-dl-trains',   _dpKnownTrains);
}

function renderDispatch(dispatch, routesConfig) {
    // Badges config/safeMode
    const badgeCfg  = document.getElementById('dp-badge-config');
    const badgeSafe = document.getElementById('dp-badge-safe');
    if (dispatch && dispatch.configOk) {
        badgeCfg.textContent = 'Config OK'; badgeCfg.className = 'dp-badge ok';
    } else {
        badgeCfg.textContent = dispatch ? 'Config manquante' : 'LOGGER hors ligne';
        badgeCfg.className = 'dp-badge err';
    }
    if (dispatch && dispatch.safeMode) {
        badgeSafe.style.display = ''; badgeSafe.className = 'dp-badge warn'; badgeSafe.textContent = 'SAFE MODE';
    } else {
        badgeSafe.style.display = 'none';
    }
    // Live routes depuis DISPATCH
    _dpLiveRoutes = (dispatch && dispatch.routes && dispatch.routes.length > 0) ? dispatch.routes : null;
    // Ne pas toucher la config ni re-rendre si éditeur ouvert (évite d'écraser les saisies en cours)
    // Do not update config or re-render if editor is open (prevents overwriting in-progress edits)
    if (_dpEditingIndex >= 0) return;
    // Met à jour si le serveur a des données, OU si on n'a encore rien chargé (premier poll)
    // Update if server has data, OR if we haven't loaded anything yet (first poll)
    if (Array.isArray(routesConfig) && (routesConfig.length > 0 || _dpRoutesConfig.length === 0)) {
        _dpRoutesConfig = routesConfig;
    }
    renderDpRoutes();
}

function renderDpRoutes() {
    const container = document.getElementById('dp-routes');
    container.innerHTML = '';
    if (_dpRoutesConfig.length === 0) {
        container.innerHTML = '<div style="color:#444;padding:20px 14px;font-size:0.82em;text-align:center">Aucune route configurée — cliquez sur + Route</div>';
        return;
    }
    _dpRoutesConfig.forEach((r, i) => {
        const live      = _dpLiveRoutes && _dpLiveRoutes.find(lr => lr.name === r.name);
        const isEditing = _dpEditingIndex === i;

        // Badge statut / Status badge
        const badge = live
            ? `<span class="dp-badge ok">● Live</span>`
            : `<span class="dp-badge warn">⏳ En attente</span>`;

        // Stats header
        const statsHtml = live
            ? `<span class="dp-route-stat">ETA ${Math.round(live.eta?.avg||0)}s ±${Math.round(live.eta?.sigma||0)}s</span>
               <span class="dp-route-stat">buf: ${live.buffer?.items||0} · drain: ${(live.buffer?.drain||0).toFixed(2)}/s</span>
               <span class="dp-badge ${live.enRoute>0?'ok':''}"> ${live.enRoute||0}/${live.maxEnRoute||1} en route</span>`
            : `<span class="dp-route-meta">${r.park||'?'} → ${r.delivery||'?'} · buf: ${r.buffer||'?'}${(r.trains&&r.trains.length)?' · trains: '+r.trains.join(', '):''}</span>`;

        // Lignes trains (quand live disponible) / Train rows (when live available)
        const trainsHtml = live ? toArr(live.trains).map(st => {
            const phase    = st.phase||'?';
            const phaseCls = phase==='PARK'?'park':phase==='EN_ROUTE'?'route':phase==='DELIVERY'?'delivery':'unknown';
            const dec      = st.decision==='go'?'Go':st.decision==='hold'?'Hold':'Idle';
            const decCls   = st.decision==='go'?'dec-go':st.decision==='hold'?'dec-hold':'dec-idle';
            return `<div class="dp-train-row">
                <span class="dp-train-name">${st.name}</span>
                <span class="dp-train-phase ${phaseCls}">${phase}</span>
                <span class="dp-train-decision ${decCls}">${dec}</span>
                <div class="dp-btns">
                    <button class="dp-btn go"   onclick="sendDispatchCmd('force_go','${st.name}','${r.name}')">GO</button>
                    <button class="dp-btn hold" onclick="sendDispatchCmd('force_hold','${st.name}','${r.name}')">HOLD</button>
                    <button class="dp-btn rec"  onclick="sendDispatchCmd('recovery','${st.name}','${r.name}')">REC</button>
                </div>
            </div>`;
        }).join('') : '';

        // Formulaire inline (si cette route est en édition) / Inline edit form
        const editHtml = isEditing ? `
            <div class="dp-inline-editor">
                <div class="dp-edit-field">
                    <label>Nom</label>
                    <input class="dp-input" id="dp-ei-name-${i}" value="${r.name||''}">
                </div>
                <div class="dp-edit-field">
                    <label>PARK</label>
                    <input class="dp-input" id="dp-ei-park-${i}" value="${r.park||''}" list="dp-dl-stations">
                </div>
                <div class="dp-edit-field">
                    <label>DELIVERY</label>
                    <input class="dp-input" id="dp-ei-delivery-${i}" value="${r.delivery||''}" list="dp-dl-stations">
                </div>
                <div class="dp-edit-field">
                    <label>Buffer</label>
                    <input class="dp-input" id="dp-ei-buffer-${i}" value="${r.buffer||''}" list="dp-dl-buffers">
                </div>
                <div class="dp-edit-field dp-ef-max">
                    <label>Max</label>
                    <input class="dp-input" id="dp-ei-max-${i}" type="number" min="1" max="10" value="${r.maxEnRoute||1}">
                </div>
                <div class="dp-edit-field">
                    <label>Trains</label>
                    <input class="dp-input" id="dp-ei-trains-${i}" value="${(r.trains||[]).join(', ')}" placeholder="T1, T2, ..." list="dp-dl-trains">
                </div>
                <div class="dp-editor-actions">
                    <button class="dp-save-btn" onclick="dpSaveInlineEdit(${i})">💾 Sauvegarder</button>
                    <button class="dp-btn" onclick="dpCancelEdit()">Annuler</button>
                </div>
            </div>` : '';

        container.insertAdjacentHTML('beforeend', `
        <div class="dp-route" id="dp-route-card-${i}">
            <div class="dp-route-header">
                <span class="dp-route-name">${r.name||'(sans nom)'}</span>
                ${badge}
                ${statsHtml}
                <div class="dp-btns">
                    <button class="dp-btn" onclick="dpToggleEdit(${i})" title="Éditer">✎</button>
                    <button class="dp-btn del" onclick="dpDeleteRoute(${i})" title="Supprimer">✕</button>
                </div>
            </div>
            ${trainsHtml}
            ${editHtml}
        </div>`);
    });
}

function dpToggleEdit(i) {
    _dpEditingIndex = (_dpEditingIndex === i) ? -1 : i;
    renderDpRoutes();
}

function dpCancelEdit() {
    // Si nouvelle route vide non sauvegardée → la retirer / Remove unsaved empty new route
    if (_dpEditingIndex >= 0) {
        const r = _dpRoutesConfig[_dpEditingIndex];
        if (!r.name && !r.park && !r.delivery && !r.buffer) _dpRoutesConfig.splice(_dpEditingIndex, 1);
    }
    _dpEditingIndex = -1;
    renderDpRoutes();
}

function dpSaveInlineEdit(i) {
    const r = _dpRoutesConfig[i];
    r.name       = document.getElementById(`dp-ei-name-${i}`).value.trim();
    r.park       = document.getElementById(`dp-ei-park-${i}`).value.trim();
    r.delivery   = document.getElementById(`dp-ei-delivery-${i}`).value.trim();
    r.buffer     = document.getElementById(`dp-ei-buffer-${i}`).value.trim();
    r.maxEnRoute = +document.getElementById(`dp-ei-max-${i}`).value || 1;
    const trainsRaw = document.getElementById(`dp-ei-trains-${i}`).value.trim();
    r.trains     = trainsRaw ? trainsRaw.split(',').map(s => s.trim()).filter(s => s) : [];
    r.enabled    = true;
    _dpEditingIndex = -1;
    renderDpRoutes();
    dpSaveRoutes(true);
}

function dpDeleteRoute(i) {
    if (!confirm(`Supprimer la route "${_dpRoutesConfig[i].name||'(sans nom)'}" ?`)) return;
    _dpRoutesConfig.splice(i, 1);
    if (_dpEditingIndex === i)    _dpEditingIndex = -1;
    else if (_dpEditingIndex > i) _dpEditingIndex--;
    renderDpRoutes();
    dpSaveRoutes(true);
}

function dpNewRoute() {
    _dpRoutesConfig.push({ name:'', park:'', delivery:'', buffer:'', maxEnRoute:1, trains:[], enabled:true });
    _dpEditingIndex = _dpRoutesConfig.length - 1;
    renderDpRoutes();
    // Focus automatique sur le champ Nom / Auto-focus on the Name field
    setTimeout(() => { const el = document.getElementById(`dp-ei-name-${_dpEditingIndex}`); if (el) el.focus(); }, 50);
}

async function dpSaveRoutes(triggerReload=false) {
    // Guard: ne jamais sauvegarder si aucune route avec contenu (évite d'écraser le JSON au chargement)
    // Guard: never save if no route has any content (prevents overwriting JSON on page load)
    const hasContent = _dpRoutesConfig.length > 0 && _dpRoutesConfig.some(r => r.name || r.park || r.delivery || r.buffer);
    if (!hasContent) return;
    const statusEl = document.getElementById('dp-save-status');
    if (statusEl) statusEl.textContent = 'Sauvegarde...';
    try {
        const resp = await fetch('/api/dispatch/routes', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(_dpRoutesConfig),
        });
        const d = await resp.json();
        if (d.status === 'ok') {
            const msg = d.save_warning ? `⚠ Mémoire OK mais fichier échoué: ${d.save_warning}` : `✓ Sauvegardé (${d.count})`;
            if (statusEl) { statusEl.textContent = msg; setTimeout(() => { if(statusEl) statusEl.textContent=''; }, d.save_warning ? 8000 : 3000); }
            // Reload DISPATCH uniquement sur demande explicite (bouton), pas sur auto-save
            // Trigger DISPATCH reload only on explicit user action, not on auto-save
            if (triggerReload) setTimeout(() => sendDispatchCmd('reload', null, null), 800);
        } else {
            if (statusEl) statusEl.textContent = '✗ Erreur serveur';
            console.error('dpSaveRoutes error:', d);
        }
    } catch(e) {
        if (statusEl) statusEl.textContent = '✗ Erreur réseau';
        console.error('dpSaveRoutes network error:', e);
    }
}

async function sendDispatchCmd(cmd, train, route) {
    try {
        await fetch('/api/dispatch/command', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ cmd, train, route }),
        });
    } catch(e) { console.warn('CMD err:', e); }
}

// ── Cache window.innerWidth (mis à jour sur resize uniquement) ──
// ── Cache window.innerWidth (updated on resize only) ────────────
// ── LOGS FIN ─────────────────────────────────────────────────
let _logSeenTotal = 0;   // nb total d'entrées vues depuis le serveur / total entries seen from server
let _logFetching  = false;

function _appendLogEntries(entries) {
    const el = document.getElementById('logs-list');
    if (!el || !entries.length) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
    entries.forEach(e => {
        const col = LOG_TAG_COLORS[e.tag] || (e.tag && e.tag.startsWith('SAT:') ? '#44cc88' : '#888');
        const div = document.createElement('div');
        div.style.cssText = 'border-bottom:1px solid #181818;padding:2px 0';
        div.innerHTML = `<span style="color:#fff;margin-right:8px">${e.ts}</span>`
            + `<span style="color:${col};font-weight:700;min-width:100px;display:inline-block">${e.tag}</span> `
            + `<span style="color:#fff">${e.msg.replace(/</g,'&lt;')}</span>`;
        el.appendChild(div);
    });
    if (atBottom) el.scrollTop = el.scrollHeight;
}

async function refreshLogs() {
    if (_logFetching) return;
    _logFetching = true;
    try {
        const url = _logSeenTotal === 0
            ? '/api/logs?limit=500'
            : `/api/logs?after=${_logSeenTotal}&limit=2000`;
        const r = await fetch(url);
        const d = await r.json();
        // Reset si serveur redémarré (total plus petit) / reset if server restarted
        if (d.total < _logSeenTotal) {
            document.getElementById('logs-list').innerHTML = '';
            _logSeenTotal = 0;
        }
        if (d.logs?.length) {
            _appendLogEntries(d.logs);
            _logSeenTotal = d.start + d.logs.length;
        }
    } catch(e) { console.warn('refreshLogs error', e); }
    finally { _logFetching = false; }
}

let _isMobile = window.innerWidth < 600;
window.addEventListener('resize', () => { _isMobile = window.innerWidth < 600; });

// ── Polling avec pause si onglet caché ───────────────────────
// ── Polling with pause when tab is hidden ────────────────────
let _pollInterval = null;
function _startPolling() {
    if (_pollInterval) return;
    _pollInterval = setInterval(refresh, 2000);
}
function _stopPolling() {
    if (_pollInterval) { clearInterval(_pollInterval); _pollInterval = null; }
}
document.addEventListener('visibilitychange', () => {
    if (document.hidden) { _stopPolling(); }
    else { refresh(); _startPolling(); }
});

refresh();
_startPolling();
